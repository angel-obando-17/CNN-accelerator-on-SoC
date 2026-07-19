"""
Entrenamiento QAT hardware-aware -- MobileNetV2 + HSV, 256x256 (el modelo
de produccion, ver src/training/train_hsv.py). Entrena con fake-quant
(pesos int8 simetrico + activaciones a potencia-de-2, ver
src/quantization/qat/layers.py) para atacar el redondeo de shift que causo
el 11% de Fase 1 (ver CNN/docs/analisis_cuantizacion_fase1.md).

Al terminar, evalua el modelo resultante con el simulador hardware-exacto
(src/quantization/hw_quant_sim.py) dos veces -- con bias y sin bias -- para
responder si el acelerador necesita soporte de bias o si QAT solo alcanza.
"""

import os
from pathlib import Path

import numpy as np
import tensorflow as tf
from tensorflow.keras.callbacks import EarlyStopping, ReduceLROnPlateau
from sklearn.metrics import confusion_matrix, accuracy_score

from src.common.dataset import collect_file_paths, split_paths, build_dataset, Timer
from src.common.segmentation import segment_hsv
from src.common.plotting import plot_cm, plot_training_curves

from src.quantization.qat.model import build_mobilenetv2_qat
from src.quantization.hw_quant_sim import main as hw_sim_main


def main(
        dataset_root: str,
        output_dir: str,
        resolution: int = 256,
        batch_size: int = 32,
        epochs: int = 30,
        max_ch: int = 64,
        max_shift: int = 31,
        seed: int = 42
    ) -> None:

    print( "=" * 65 )
    print( "  ENTRENAMIENTO QAT -- MobileNetV2 + HSV, 256x256" )
    print( "  Fake-quant hardware-aware (peso simetrico + activacion potencia-2)" )
    print( "=" * 65 )

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

    ds_train = build_dataset( paths_train, y_train, resolution, batch_size, shuffle=True, seed=seed, segment_fn=segment_hsv )
    ds_val   = build_dataset( paths_val, y_val, resolution, batch_size, seed=seed, segment_fn=segment_hsv )
    ds_test  = build_dataset( paths_test, y_test, resolution, batch_size, seed=seed, segment_fn=segment_hsv )

    model = build_mobilenetv2_qat( resolution, num_classes, max_ch, max_shift )
    model.compile(
            optimizer=tf.keras.optimizers.Adam( 1e-3 ),
            loss="sparse_categorical_crossentropy",
            metrics=[ "accuracy" ]
          )
    cbs = [ EarlyStopping( monitor="val_accuracy", patience=7, restore_best_weights=True ),
            ReduceLROnPlateau( monitor="val_loss", factor=0.5, patience=3, min_lr=1e-6 ) ]

    print( f"  Parámetros: { model.count_params( ):,}" )
    with Timer( "Entrenamiento QAT" ):
        history = model.fit( ds_train, validation_data=ds_val, epochs=epochs, callbacks=cbs, verbose=1 )

    # Guardar el modelo ANTES de graficar -- si matplotlib/plotting falla
    # (ej. backend grafico roto en un entorno headless) no se pierde el
    # entrenamiento, que puede costar horas de GPU.
    keras_path = os.path.join( output_dir, "model_MobileNetV2_QAT_256x256.keras" )
    model.save( keras_path )
    print( f"  Modelo guardado: { keras_path }" )

    try:
        plot_training_curves( history, "MobileNetV2_QAT_256x256", output_dir )
    except Exception as e:
        print( f"  [WARN] No se pudo graficar curvas de entrenamiento: { e }" )

    y_pred_proba = model.predict( ds_test, verbose=0 )
    y_pred = np.argmax( y_pred_proba, axis=1 )
    acc = accuracy_score( y_test, y_pred )
    print( f"  Accuracy float32 (con ruido fake-quant, no hardware-exacto): { acc:.4f}" )
    cm = confusion_matrix( y_test, y_pred )
    try:
        plot_cm( cm, class_names, "MobileNetV2_QAT_256x256_float32", output_dir )
    except Exception as e:
        print( f"  [WARN] No se pudo graficar matriz de confusión: { e }" )

    print( f"\n  [ OK ] Modelo QAT listo en: { output_dir }/" )
    print( "  Corriendo evaluación hardware-exacta (con bias y sin bias)..." )

    hw_sim_main(
        dataset_root=dataset_root,
        model_path=keras_path,
        output_dir=os.path.join( output_dir, "hw_quant_sim_with_bias" ),
        resolution=resolution,
        seed=seed,
        max_ch=max_ch,
        bias_enabled=True
    )
    hw_sim_main(
        dataset_root=dataset_root,
        model_path=keras_path,
        output_dir=os.path.join( output_dir, "hw_quant_sim_no_bias" ),
        resolution=resolution,
        seed=seed,
        max_ch=max_ch,
        bias_enabled=False
    )

    print( "\n  [ OK ] Comparación con/sin bias lista -- revisa resumen_comparacion.csv en cada subcarpeta." )


if __name__ == "__main__":
    repo_root    = Path( __file__ ).resolve( ).parents[ 3 ]
    dataset_root = str( repo_root / "data" / "raw" )
    output_dir   = str( repo_root / "results" / "qat" )
    main( dataset_root, output_dir )
