import os
from pathlib import Path

import numpy as np
import pandas as pd
import tensorflow as tf
from tensorflow.keras.callbacks import EarlyStopping, ReduceLROnPlateau
from sklearn.metrics import confusion_matrix, accuracy_score

from src.common.dataset import collect_file_paths, split_paths, build_dataset, Timer
from src.common.plotting import plot_cm, plot_training_curves
from src.common.ptq import quantize_and_evaluate

from src.models.mobilenetv2 import build_mobilenetv2


def train_model(
        model: tf.keras.Model,
        ds_train: tf.data.Dataset,
        ds_val: tf.data.Dataset,
        label: str,
        epochs: int
    ) -> tuple[ tf.keras.callbacks.History, float ]:

    model.compile(
            optimizer=tf.keras.optimizers.Adam( 1e-3 ),
            loss="sparse_categorical_crossentropy",
            metrics=[ "accuracy" ]
          )

    cbs = [ EarlyStopping( monitor="val_accuracy", patience=7, restore_best_weights=True ),
            ReduceLROnPlateau( monitor="val_loss", factor=0.5, patience=3, min_lr=1e-6 ) ]

    print( f"  Parámetros totales: { model.count_params( ):,}" )

    with Timer( f"Entrenamiento { label }" ) as t:
        history = model.fit(
                            ds_train,
                            validation_data=ds_val,
                            epochs=epochs,
                            callbacks=cbs,
                            verbose=1
                        )

    return history, t.elapsed


def evaluate_model(
        model: tf.keras.Model,
        ds_test: tf.data.Dataset,
        paths_test: np.ndarray,
        labels_test: np.ndarray,
        class_names: list[ str ],
        label: str,
        resolution: int,
        output_dir: str
    ) -> dict[ str, float ]:

    results = { }

    with Timer( "Inferencia batch" ) as t:
        y_pred_proba = model.predict( ds_test, verbose=0 )

    results[ "inference_batch_s" ] = t.elapsed
    y_pred = np.argmax( y_pred_proba, axis=1 )
    results[ "accuracy" ] = accuracy_score( labels_test, y_pred )
    print( f"  Accuracy float32: { results[ 'accuracy' ]:.4f}" )
    results[ "inference_single_ms" ] = ( results[ "inference_batch_s" ] / len( paths_test ) ) * 1000
    print( f"  Tiempo/imagen (batch): { results[ 'inference_single_ms' ]:.4f} ms" )

    cm = confusion_matrix( labels_test, y_pred )
    plot_cm( cm, class_names, f"MobileNetV2_{ label }_float32", output_dir )
    return results


def run_resolutions(
        paths_train: np.ndarray,
        y_train: np.ndarray,
        paths_val: np.ndarray,
        y_val: np.ndarray,
        paths_test: np.ndarray,
        y_test: np.ndarray,
        class_names: list[ str ],
        num_classes: int,
        summary_rows: list[ dict[ str, object ] ],
        batch_size: int,
        output_dir: str,
        quant_modes: list[ str ],
        epochs: int,
        max_ch: int,
        resolutions: list[ int ] = [ 256, 128, 96 ],
        seed: int = 42
    ) -> None:

    for resolution in resolutions:
        res_label = f"{ resolution }x{ resolution }"
        print( f"\n{ '='*65 }" )
        print( f"  RESOLUCIÓN: { res_label }" )
        print( f"{ '='*65 }" )

        ds_train = build_dataset( paths_train, y_train, resolution, batch_size, shuffle=True, seed=seed )
        ds_val   = build_dataset( paths_val, y_val, resolution, batch_size, seed=seed )
        ds_test  = build_dataset( paths_test, y_test, resolution, batch_size, seed=seed )

        model = build_mobilenetv2( resolution, num_classes, max_ch )
        history, train_time = train_model( model, ds_train, ds_val, res_label, epochs )
        plot_training_curves( history, f"MobileNetV2_{ res_label }", output_dir )

        keras_path = os.path.join( output_dir, f"model_MobileNetV2_{ res_label }.keras" )
        model.save( keras_path )
        keras_kb = os.path.getsize( keras_path ) / 1024
        print( f"  Modelo guardado: { keras_path } ({ keras_kb:.1f} KB)" )

        print( f"\n  >> Float32" )
        f32 = evaluate_model( model, ds_test, paths_test, y_test, class_names, res_label, resolution, output_dir )
        summary_rows.append( {
            "resolucion": res_label,
            "tiempo_entrenamiento_s": train_time,
            "cuantizacion": "float32",
            "accuracy": f32[ "accuracy" ],
            "inferencia_ms_img": f32[ "inference_single_ms" ],
            "tamano_modelo_kb": keras_kb,
            "tiempo_conversion_s": None,
            "n_params": model.count_params( )
        } )

        for qmode in quant_modes:
            print( f"\n  >> { qmode.upper( ) }" )
            try:
                qres = quantize_and_evaluate(
                            model, paths_test, y_test, class_names,
                            f"MobileNetV2_{ res_label }", resolution, qmode,
                            paths_train, output_dir
                       )
                summary_rows.append( {
                    "resolucion": res_label,
                    "tiempo_entrenamiento_s": train_time,
                    "cuantizacion": qmode,
                    "accuracy": qres[ "accuracy" ],
                    "inferencia_ms_img": qres[ "inference_single_ms" ],
                    "tamano_modelo_kb": qres[ "model_size_kb" ],
                    "tiempo_conversion_s": qres[ "conversion_s" ],
                    "n_params": model.count_params( )
                } )
            except Exception as e:
                print( f"  [WARN] Cuantización { qmode } falló: { e }" )
                summary_rows.append( {
                    "resolucion": res_label,
                    "cuantizacion": qmode,
                    "accuracy": "ERROR"
                } )

        tf.keras.backend.clear_session( )


def main(
        dataset_root: str,
        output_dir: str,
        resolutions: list[ int ] = [ 256, 128, 96 ],
        batch_size: int = 32,
        epochs: int = 30,
        quant_modes: list[ str ] = [ "int8", "int16" ],
        max_ch: int = 64,
        seed: int = 42
    ) -> None:

    print( "=" * 65 )
    print( "  ENTRENAMIENTO MobileNetV2 — TRES RESOLUCIONES (dataset U-Net)" )
    print( "  Trabajo de Grado - Acelerador CNN en Zynq-7020" )
    print( "=" * 65 )

    if not os.path.isdir( dataset_root ):
        print( f"[ERROR] No se encontró el dataset: '{dataset_root}'" )
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

    summary_rows: list[ dict[ str, object ] ] = [ ]

    run_resolutions(
        paths_train, y_train, paths_val, y_val, paths_test, y_test,
        class_names, num_classes, summary_rows,
        batch_size=batch_size, output_dir=output_dir,
        quant_modes=quant_modes, epochs=epochs, max_ch=max_ch,
        resolutions=resolutions, seed=seed
    )

    df = pd.DataFrame( summary_rows )
    csv_path = os.path.join( output_dir, "tabla_MobileNetV2_resoluciones.csv" )
    df.to_csv( csv_path, index=False )

    print( f"\n{ '='*65 }" )
    print( "  TABLA RESUMEN FINAL — MobileNetV2 tres resoluciones" )
    print( f"{ '='*65 }" )
    print( df.to_string( index=False ) )
    print( f"\n  CSV guardado en: { csv_path }" )
    print( f"\n  [ OK ] Resultados en: { output_dir }/" )


if __name__ == "__main__":
    repo_root    = Path( __file__ ).resolve( ).parents[ 2 ]
    dataset_root = str( repo_root / "data" / "segmentado_unet" )
    output_dir   = str( repo_root / "results" / "mobilenetv2" )
    main( dataset_root, output_dir )
