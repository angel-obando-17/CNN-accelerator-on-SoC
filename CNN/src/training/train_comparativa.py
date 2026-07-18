import os
from pathlib import Path
from typing import Callable

import numpy as np
import pandas as pd
import matplotlib
matplotlib.use( "Agg" )
import matplotlib.pyplot as plt
import tensorflow as tf
from tensorflow.keras.callbacks import EarlyStopping, ReduceLROnPlateau
from sklearn.metrics import confusion_matrix, accuracy_score

from src.common.dataset import collect_file_paths, split_paths, build_dataset, Timer
from src.common.plotting import plot_cm
from src.common.ptq import quantize_and_evaluate

from src.models.lenet import build_lenet
from src.models.mobilenetv2 import build_mobilenetv2
from src.models.efficientnet import build_efficientnet


def train_model(
        model: tf.keras.Model,
        ds_train: tf.data.Dataset,
        ds_val: tf.data.Dataset,
        model_name: str,
        epochs: int
    ) -> tuple[ tf.keras.callbacks.History, float ]:

    model.compile(
            optimizer=tf.keras.optimizers.Adam( 1e-3 ),
            loss="sparse_categorical_crossentropy",
            metrics=[ "accuracy" ]
          )

    cbs = [ EarlyStopping( monitor="val_accuracy", patience=7, restore_best_weights=True ),
            ReduceLROnPlateau( monitor="val_loss", factor=0.5, patience=3, min_lr=1e-6 ) ]

    print( f"\n  Parámetros { model_name }: { model.count_params( ):,}" )

    with Timer( f"Entrenamiento { model_name }" ) as t:
        history = model.fit(
                            ds_train,
                            validation_data=ds_val,
                            epochs=epochs,
                            callbacks=cbs,
                            verbose=1
                        )

    return history, t.elapsed


def plot_training_curves_comparativa(
        history: tf.keras.callbacks.History,
        model_name: str,
        output_dir: str
    ) -> None:

    fig, axes = plt.subplots( 1, 2, figsize=( 12, 4 ) )
    axes[ 0 ].plot( history.history[ "accuracy" ], label="Train" )
    axes[ 0 ].plot( history.history[ "val_accuracy" ], label="Val" )
    axes[ 0 ].set_title( f"Accuracy — { model_name }" )
    axes[ 0 ].set_xlabel( "Época" ); axes[ 0 ].legend( )
    axes[ 1 ].plot( history.history[ "loss" ], label="Train" )
    axes[ 1 ].plot( history.history[ "val_loss" ], label="Val" )
    axes[ 1 ].set_title( f"Loss — { model_name }" )
    axes[ 1 ].set_xlabel( "Época" ); axes[ 1 ].legend( )
    plt.tight_layout( )
    fig.savefig( os.path.join( output_dir, f"training_{ model_name }.png" ), dpi=150 )
    plt.close( fig )


def evaluate_model(
        model: tf.keras.Model,
        paths_test: np.ndarray,
        labels_test: np.ndarray,
        class_names: list[ str ],
        model_name: str,
        resolution: int,
        batch_size: int,
        output_dir: str,
        seed: int
    ) -> dict[ str, float ]:

    ds_test = build_dataset( paths_test, labels_test, resolution, batch_size, shuffle=False, seed=seed )

    with Timer( "Inferencia batch" ) as t:
        y_pred_proba = model.predict( ds_test, verbose=0 )
    y_pred = np.argmax( y_pred_proba, axis=1 )

    acc        = accuracy_score( labels_test, y_pred )
    ms_per_img = ( t.elapsed / len( paths_test ) ) * 1000

    print( f"  Accuracy float32: { acc:.4f}" )
    print( f"  Tiempo/imagen: { ms_per_img:.2f} ms" )

    cm = confusion_matrix( labels_test, y_pred )
    plot_cm( cm, class_names, f"{ model_name }_float32", output_dir )

    return { "accuracy": acc, "inference_single_ms": ms_per_img, "inference_batch_s": t.elapsed }


def generate_comparison_plot( df: pd.DataFrame, output_dir: str ) -> None:
    df_p = df[ df[ "accuracy" ] != "ERROR" ].copy( )
    df_p[ "accuracy" ] = df_p[ "accuracy" ].astype( float )
    model_names = df_p[ "model" ].unique( )
    quants      = df_p[ "quant" ].unique( )
    x     = np.arange( len( model_names ) )
    width = 0.25

    fig, ax = plt.subplots( figsize=( 14, 6 ) )
    for i, q in enumerate( quants ):
        vals = [ df_p.loc[ ( df_p[ "model" ] == m ) & ( df_p[ "quant" ] == q ), "accuracy" ].values for m in model_names ]
        vals = [ v[ 0 ] if len( v ) else 0 for v in vals ]
        bars = ax.bar( x + i * width, vals, width, label=q.upper( ) )
        for bar, val in zip( bars, vals ):
            ax.text( bar.get_x( ) + bar.get_width( ) / 2, bar.get_height( ) + 0.005,
                     f"{ val:.3f}", ha="center", va="bottom", fontsize=8 )

    ax.set_xticks( x + width )
    ax.set_xticklabels( model_names, rotation=15, ha="right" )
    ax.set_ylim( 0, 1.05 )
    ax.set_ylabel( "Accuracy" )
    ax.set_title( "Comparativa de Modelos — Dataset Segmentado U-Net (256×256)" )
    ax.legend( )
    plt.tight_layout( )
    fig.savefig( os.path.join( output_dir, "comparativa_modelos.png" ), dpi=150 )
    plt.close( fig )
    print( "  Gráfico comparativo guardado: comparativa_modelos.png" )


def main(
        dataset_root: str,
        output_dir: str,
        resolution: int = 256,
        batch_size: int = 32,
        epochs: int = 30,
        quant_modes: list[ str ] = [ "int8", "int16" ],
        max_ch: int = 64,
        seed: int = 42
    ) -> None:

    print( "=" * 60 )
    print( "  COMPARATIVA DE MODELOS CNN — TOMATE / ZYNQ-7020" )
    print( "=" * 60 )

    if not os.path.isdir( dataset_root ):
        print( f"[ERROR] No se encontró: '{dataset_root}'" )
        return

    os.makedirs( output_dir, exist_ok=True )
    tf.random.set_seed( seed )
    np.random.seed( seed )

    with Timer( "Indexado de archivos" ):
        file_paths, labels, class_names = collect_file_paths( dataset_root )
    labels = np.array( labels )
    num_classes = len( class_names )
    print( f"  Total: { len( file_paths ) } imágenes | { num_classes } clases" )

    ( paths_train, y_train, paths_val, y_val, paths_test, y_test ) = split_paths(
            file_paths, labels, seed=seed
        )
    print( f"  Train={ len( paths_train ) }  Val={ len( paths_val ) }  Test={ len( paths_test ) }" )

    ds_train = build_dataset( paths_train, y_train, resolution, batch_size, shuffle=True, seed=seed )
    ds_val   = build_dataset( paths_val, y_val, resolution, batch_size, seed=seed )

    model_builders: dict[ str, Callable[ [ ], tf.keras.Model ] ] = {
        "LeNet":        lambda: build_lenet( resolution, num_classes ),
        "MobileNetV2":  lambda: build_mobilenetv2( resolution, num_classes, max_ch ),
        "EfficientNet": lambda: build_efficientnet( resolution, num_classes, max_ch ),
    }

    summary_rows: list[ dict[ str, object ] ] = [ ]

    for model_name, builder in model_builders.items( ):
        print( f"\n{ '='*60 }" )
        print( f"  MODELO: { model_name }" )
        print( f"{ '='*60 }" )

        model = builder( )

        history, train_time = train_model( model, ds_train, ds_val, model_name, epochs )
        plot_training_curves_comparativa( history, model_name, output_dir )

        model_path    = os.path.join( output_dir, f"model_{ model_name }.keras" )
        model.save( model_path )
        model_kb_full = os.path.getsize( model_path ) / 1024

        print( f"\n  >> Evaluación Float32" )
        f32 = evaluate_model( model, paths_test, y_test, class_names, model_name, resolution, batch_size, output_dir, seed )
        summary_rows.append( {
            "model": model_name,
            "params": model.count_params( ),
            "quant": "float32",
            "accuracy": f32[ "accuracy" ],
            "inference_single_ms": f32[ "inference_single_ms" ],
            "model_size_kb": model_kb_full,
            "train_s": train_time,
            "conversion_s": None
        } )

        for qmode in quant_modes:
            print( f"\n  >> Cuantización { qmode.upper( ) }" )
            try:
                qres = quantize_and_evaluate(
                            model, paths_test, y_test, class_names,
                            model_name, resolution, qmode, paths_train, output_dir
                       )
                summary_rows.append( {
                    "model": model_name,
                    "params": model.count_params( ),
                    "quant": qmode,
                    "accuracy": qres[ "accuracy" ],
                    "inference_single_ms": qres[ "inference_single_ms" ],
                    "model_size_kb": qres[ "model_size_kb" ],
                    "train_s": train_time,
                    "conversion_s": qres[ "conversion_s" ]
                } )
            except Exception as e:
                print( f"  [WARN] { qmode } falló: { e }" )
                summary_rows.append( {
                    "model": model_name, "quant": qmode,
                    "accuracy": "ERROR", "inference_single_ms": "ERROR",
                    "model_size_kb": "ERROR"
                } )

        tf.keras.backend.clear_session( )

    df = pd.DataFrame( summary_rows )
    csv_path = os.path.join( output_dir, "comparativa_modelos.csv" )
    df.to_csv( csv_path, index=False )

    print( f"\n{ '='*60 }" )
    print( "  TABLA COMPARATIVA FINAL" )
    print( f"{ '='*60 }" )
    print( df.to_string( index=False ) )
    print( f"\n  Guardada en: { csv_path }" )

    generate_comparison_plot( df, output_dir )
    print( f"\n  [ OK ] Comparativa completada. Resultados en: { output_dir }/" )


if __name__ == "__main__":
    repo_root    = Path( __file__ ).resolve( ).parents[ 2 ]
    dataset_root = str( repo_root / "data" / "segmentado_unet" )
    output_dir   = str( repo_root / "results" / "comparativa" )
    main( dataset_root, output_dir )
