"""
=============================================================================
ENTRENAMIENTO MobileNetV2 — TRES RESOLUCIONES
Trabajo de Grado - Acelerador CNN en Zynq-7020
=============================================================================
Entrena MobileNetV2 restringido (~210k params, canales <= 64) en las tres
resoluciones [256, 128, 96] con el dataset ya segmentado por U-Net.

Mismas condiciones exactas que tomato.py (segundo entrenamiento):
  - Mismo SEED=42 -> mismo split -> test set idéntico -> comparación justa
  - Mismo optimizer, lr, batch size, epochs, callbacks
  - Mismas cuantizaciones INT8 e INT16
  - Mismas métricas: accuracy, confusion matrix, tiempos

CORRECCIÓN (2026-07-13): exp_ch (canal de expansión de MobileNetV2) ahora
se capa a MAX_CH=64. La versión original (CNN/tomatoV2.py) lo dejaba sin
cap ("Sin cap."), lo que producía exp_ch=128 en los últimos 3 bloques
residuales (in_ch=64, expand_ratio=2) — viola el límite duro Cin/Cout<=64
del acelerador (co_counter de 2 bits en fsm_addr_generator.vhd, weight_buf
de 256 palabras). Ver memoria project_channel_limit_violation.md.
=============================================================================
"""

import os
import re
import time
import warnings

import numpy as np
import pandas as pd
import cv2
import matplotlib
matplotlib.use( "Agg" )
import matplotlib.pyplot as plt
import seaborn as sns
from sklearn.model_selection import train_test_split
from sklearn.metrics import confusion_matrix, accuracy_score

import tensorflow as tf
from tensorflow.keras import layers, models
from tensorflow.keras.callbacks import EarlyStopping, ReduceLROnPlateau

warnings.filterwarnings( "ignore" )

DATASET_ROOT = "/mnt/c/Users/ANGEL OBANDO/Documents/Trabajo de grado/CNN/PlantVillage_segmentado"
OUTPUT_DIR   = "/mnt/c/Users/ANGEL OBANDO/Documents/Trabajo de grado/CNN/training_correction/resultados_mobilenetv2_experimento1"

RESOLUTIONS = [ 256, 128, 96 ]
BATCH_SIZE  = 32
EPOCHS      = 30
SEED        = 42
VAL_SPLIT   = 0.15
TEST_SPLIT  = 0.15
QUANT_MODES = [ "int8", "int16" ]
MAX_CH      = 64

os.makedirs( OUTPUT_DIR, exist_ok=True )
tf.random.set_seed( SEED )
np.random.seed( SEED )


# UTILIDADES
class Timer:
    def __init__( self, label ):
        self.label = label
    def __enter__( self ):
        self.t0 = time.perf_counter( )
        return self
    def __exit__( self, *a ):
        self.elapsed = time.perf_counter( ) - self.t0
        print( f"  [ TIME ]  {self.label}: {self.elapsed:.3f}s" )


def get_all_classes( root ):
    return sorted( [ d for d in os.listdir( root ) if os.path.isdir( os.path.join( root, d ) ) ] )


def collect_file_paths( root ):
    class_names = get_all_classes( root )
    label_map   = { n: i for i, n in enumerate( class_names ) }
    file_paths, labels = [ ], [ ]
    for cn in class_names:
        folder = os.path.join( root, cn )
        for f in os.listdir( folder ):
            if f.lower( ).endswith( ( ".jpg", ".jpeg", ".png" ) ):
                file_paths.append( os.path.join( folder, f ) )
                labels.append( label_map[ cn ] )
    return file_paths, labels, class_names


def split_paths( file_paths, labels ):
    #Mismo SEED y parámetros que tomato.py → mismo test set → comparación justa.
    idx = np.arange( len( file_paths ) )
    idx_tmp, idx_test = train_test_split( idx, test_size=TEST_SPLIT, random_state=SEED, stratify=labels )
    val_ratio = VAL_SPLIT / ( 1 - TEST_SPLIT )
    idx_train, idx_val = train_test_split( idx_tmp, test_size=val_ratio, random_state=SEED, stratify=np.array( labels )[ idx_tmp ] )
    fp = np.array( file_paths )
    lb = np.array( labels )
    return ( fp[ idx_train ], lb[ idx_train ], fp[ idx_val ], lb[ idx_val ], fp[ idx_test ], lb[ idx_test ] )


def load_and_preprocess( path, label, target_size ):
    #Imágenes ya segmentadas por U-Net desde el dataset.
    def _load( p, sz ):
        p   = p.numpy( ).decode( "utf-8" )
        sz  = int( sz.numpy( ) )
        img = cv2.imread( p )
        if img is None:
            img = np.zeros( ( sz, sz, 3 ), dtype=np.uint8 )
        img = cv2.resize( img, ( sz, sz ) )
        img = cv2.cvtColor( img, cv2.COLOR_BGR2RGB )
        return img.astype( np.float32 ) / 255.0
    img = tf.py_function( func=_load, inp=[ path, target_size ], Tout=tf.float32 )
    img.set_shape( [ None, None, 3 ] )
    img = tf.image.resize( img, [ target_size, target_size ] )
    return img, label


def build_dataset( paths, labels, target_size, batch_size, shuffle=False ):
    ds = tf.data.Dataset.from_tensor_slices( ( paths, labels ) )
    if shuffle:
        ds = ds.shuffle( buffer_size=len( paths ), seed=SEED )
    ds = ds.map( lambda p, l: load_and_preprocess( p, l, target_size ), num_parallel_calls=tf.data.AUTOTUNE )
    return ds.batch( batch_size ).prefetch( tf.data.AUTOTUNE )


def plot_cm( cm, class_names, label ):
    short = [ re.sub( r"Tomato_+", "", n ) for n in class_names ]
    n     = len( short )
    fig, ax = plt.subplots( figsize=( max( 8, n ), max( 6, n ) ) )
    sns.heatmap( cm, annot=True, fmt="d", cmap="Blues", xticklabels=short, yticklabels=short, ax=ax )
    ax.set_xlabel( "Predicho" )
    ax.set_ylabel( "Real" )
    ax.set_title( f"Confusion Matrix — {label}" )
    plt.tight_layout( )
    fig.savefig( os.path.join( OUTPUT_DIR, f"cm_{label}.png" ), dpi=150 )
    plt.close( fig )
    print( f"  CM guardada: cm_{label}.png" )


def plot_training_curves( history, res_label ):
    fig, axes = plt.subplots( 1, 2, figsize=( 12, 4 ) )
    axes[ 0 ].plot( history.history[ "accuracy" ],    label="Train" )
    axes[ 0 ].plot( history.history[ "val_accuracy" ], label="Val" )
    axes[ 0 ].set_title( f"Accuracy — MobileNetV2 {res_label}" )
    axes[ 0 ].set_xlabel( "Época" ); axes[ 0 ].legend( )
    axes[ 1 ].plot( history.history[ "loss" ],    label="Train" )
    axes[ 1 ].plot( history.history[ "val_loss" ], label="Val" )
    axes[ 1 ].set_title( f"Loss — MobileNetV2 {res_label}" )
    axes[ 1 ].set_xlabel( "Época" ); axes[ 1 ].legend( )
    plt.tight_layout( )
    fig.savefig( os.path.join( OUTPUT_DIR, f"training_MobileNetV2_{res_label}.png" ), dpi=150 )
    plt.close( fig )
    print( f"  Curvas guardadas: training_MobileNetV2_{res_label}.png" )


# ARQUITECTURA MobileNetV2 RESTRINGIDO
def inverted_residual_block( x, filters, strides=1, expand_ratio=2, name_prefix="irb" ):
    #Bloque invertido de MobileNetV2.
    in_ch  = x.shape[ -1 ]
    exp_ch = min( in_ch * expand_ratio, MAX_CH )

    if expand_ratio != 1:
        x_exp = layers.Conv2D( exp_ch, 1, padding="same", use_bias=False, name=f"{name_prefix}_exp" )( x )
        x_exp = layers.BatchNormalization( name=f"{name_prefix}_exp_bn" )( x_exp )
        x_exp = layers.ReLU( 6.0, name=f"{name_prefix}_exp_relu6" )( x_exp )
    else:
        x_exp = x

    x_dw = layers.DepthwiseConv2D( 3, strides=strides, padding="same", use_bias=False, name=f"{name_prefix}_dw" )( x_exp )
    x_dw = layers.BatchNormalization( name=f"{name_prefix}_dw_bn" )( x_dw )
    x_dw = layers.ReLU( 6.0, name=f"{name_prefix}_dw_relu6" )( x_dw )

    x_pw = layers.Conv2D( filters, 1, padding="same", use_bias=False, name=f"{name_prefix}_pw" )( x_dw )
    x_pw = layers.BatchNormalization( name=f"{name_prefix}_pw_bn" )( x_pw )

    if strides == 1 and in_ch == filters:
        return layers.Add( name=f"{name_prefix}_add" )( [ x, x_pw ] )
    return x_pw


def build_mobilenetv2( input_size, num_classes ):
    #MobileNetV2 restringido — canales <= MAX_CH=64.
    inp = layers.Input( shape=( input_size, input_size, 3 ) )
    x   = layers.Conv2D( min( 32, MAX_CH ), 3, strides=2, padding="same", use_bias=False, name="conv1" )( inp )
    x   = layers.BatchNormalization( name="conv1_bn" )( x )
    x   = layers.ReLU( 6.0, name="conv1_relu6" )( x )

    cfg = [
        ( 1, 16, 1 ),
        ( 2, 24, 2 ),
        ( 2, 24, 1 ),   # residual
        ( 2, 32, 2 ),
        ( 2, 32, 1 ),   # residual
        ( 2, 64, 2 ),
        ( 2, 64, 1 ),   # residual
        ( 2, 64, 1 ),   # residual
        ( 2, 64, 1 ),   # residual
    ]
    for i, ( t, c, s ) in enumerate( cfg ):
        x = inverted_residual_block( x, min( c, MAX_CH ), strides=s, expand_ratio=t, name_prefix=f"irb{i+1}" )

    x = layers.Conv2D( min( 64, MAX_CH ), 1, padding="same", use_bias=False, name="conv_last" )( x )
    x = layers.BatchNormalization( name="conv_last_bn" )( x )
    x = layers.ReLU( 6.0, name="conv_last_relu6" )( x )
    x = layers.GlobalAveragePooling2D( name="gap" )( x )
    x = layers.Dense( num_classes, activation="softmax", name="output" )( x )
    return models.Model( inp, x, name=f"MobileNetV2_restricted_{input_size}" )


# ENTRENAMIENTO
def train_model( model, ds_train, ds_val, res_label ):
    model.compile(
        optimizer=tf.keras.optimizers.Adam( 1e-3 ),
        loss="sparse_categorical_crossentropy",
        metrics=[ "accuracy" ]
    )
    cbs = [
        EarlyStopping( monitor="val_accuracy", patience=7, restore_best_weights=True ),
        ReduceLROnPlateau( monitor="val_loss", factor=0.5, patience=3, min_lr=1e-6 )
    ]
    print( f"  Parámetros totales: {model.count_params( ):,}" )
    with Timer( f"Entrenamiento {res_label}" ) as t:
        history = model.fit( ds_train, validation_data=ds_val, epochs=EPOCHS, callbacks=cbs, verbose=1 )
    return history, t.elapsed


# EVALUACIÓN FLOAT32
def evaluate_model( model, ds_test, paths_test, labels_test, class_names, res_label, resolution ):
    results = { }
    with Timer( "Inferencia batch" ) as t:
        y_pred_proba = model.predict( ds_test, verbose=0 )
    results[ "inference_batch_s" ] = t.elapsed
    y_pred = np.argmax( y_pred_proba, axis=1 )
    results[ "accuracy" ] = accuracy_score( labels_test, y_pred )
    print( f"  Accuracy float32: {results[ 'accuracy' ]:.4f}" )

    times = [ ]
    for p in paths_test[ :100 ]:
        img = cv2.imread( p )
        if img is None:
            continue
        img = cv2.resize( img, ( resolution, resolution ) )
        img = cv2.cvtColor( img, cv2.COLOR_BGR2RGB ).astype( np.float32 ) / 255.0
        t0  = time.perf_counter( )
        model.predict( img[ np.newaxis ], verbose=0 )
        times.append( time.perf_counter( ) - t0 )
    results[ "inference_single_ms" ] = np.mean( times ) * 1000 if times else 0
    print( f"  Tiempo/imagen: {results[ 'inference_single_ms' ]:.4f} ms" )

    cm = confusion_matrix( labels_test, y_pred )
    plot_cm( cm, class_names, f"MobileNetV2_{res_label}_float32" )
    return results


# CUANTIZACIÓN Y EVALUACIÓN
def make_representative_dataset( paths_calib, target_size ):
    samples = list( paths_calib[ :200 ] )
    def gen( ):
        for p in samples:
            img = cv2.imread( p )
            if img is None:
                continue
            img = cv2.resize( img, ( target_size, target_size ) )
            img = cv2.cvtColor( img, cv2.COLOR_BGR2RGB ).astype( np.float32 ) / 255.0
            yield [ img[ np.newaxis ] ]
    return gen


def quantize_and_evaluate( model, paths_test, labels_test, class_names, res_label, target_size, qmode, paths_calib ):
    results   = { }
    converter = tf.lite.TFLiteConverter.from_keras_model( model )
    rep_gen   = make_representative_dataset( paths_calib, target_size )

    if qmode == "int8":
        converter.optimizations = [ tf.lite.Optimize.DEFAULT ]
        converter.representative_dataset = rep_gen
        converter.target_spec.supported_ops = [ tf.lite.OpsSet.TFLITE_BUILTINS_INT8 ]
        converter.inference_input_type  = tf.int8
        converter.inference_output_type = tf.int8
    elif qmode == "int16":
        converter.optimizations = [ tf.lite.Optimize.DEFAULT ]
        converter.representative_dataset = rep_gen
        converter.target_spec.supported_ops = [
            tf.lite.OpsSet.EXPERIMENTAL_TFLITE_BUILTINS_ACTIVATIONS_INT16_WEIGHTS_INT8
        ]

    with Timer( f"Conversión {qmode}" ) as t:
        tflite_model = converter.convert( )
    results[ "conversion_s" ] = t.elapsed

    model_path = os.path.join( OUTPUT_DIR, f"model_MobileNetV2_{res_label}_{qmode}.tflite" )
    with open( model_path, "wb" ) as f:
        f.write( tflite_model )
    results[ "model_size_kb" ] = os.path.getsize( model_path ) / 1024
    print( f"  Tamaño {qmode}: {results[ 'model_size_kb' ]:.1f} KB" )

    interp = tf.lite.Interpreter( model_path=model_path )
    interp.allocate_tensors( )
    in_det  = interp.get_input_details( )[ 0 ]
    out_det = interp.get_output_details( )[ 0 ]

    def run_one( img_float ):
        if in_det[ "dtype" ] == np.int8:
            scale, zp = in_det[ "quantization" ]
            inp = ( img_float / scale + zp ).astype( np.int8 )
        else:
            inp = img_float.astype( np.float32 )
        interp.set_tensor( in_det[ "index" ], inp[ np.newaxis ] )
        interp.invoke( )
        out = interp.get_tensor( out_det[ "index" ] )[ 0 ]
        if out_det[ "dtype" ] == np.int8:
            scale, zp = out_det[ "quantization" ]
            out = ( out.astype( np.float32 ) - zp ) * scale
        return np.argmax( out )

    print( f"  Evaluando {len( paths_test )} imágenes en {qmode}..." )
    y_pred = [ ]
    t0     = time.perf_counter( )
    for p in paths_test:
        img = cv2.imread( p )
        if img is None:
            y_pred.append( 0 )
            continue
        img = cv2.resize( img, ( target_size, target_size ) )
        img = cv2.cvtColor( img, cv2.COLOR_BGR2RGB ).astype( np.float32 ) / 255.0
        y_pred.append( run_one( img ) )
    elapsed = time.perf_counter( ) - t0

    results[ "accuracy" ]            = accuracy_score( labels_test, y_pred )
    results[ "inference_single_ms" ] = ( elapsed / len( paths_test ) ) * 1000
    print( f"  Accuracy {qmode}: {results[ 'accuracy' ]:.4f}" )
    print( f"  Tiempo/imagen: {results[ 'inference_single_ms' ]:.4f} ms" )

    cm = confusion_matrix( labels_test, y_pred )
    plot_cm( cm, class_names, f"MobileNetV2_{res_label}_{qmode}" )
    return results


# MAIN
def main( ):
    print( "=" * 65 )
    print( "  ENTRENAMIENTO MobileNetV2 — TRES RESOLUCIONES" )
    print( "  Trabajo de Grado - Acelerador CNN en Zynq-7020" )
    print( "=" * 65 )

    if not os.path.isdir( DATASET_ROOT ):
        print( f"[ERROR] No se encontró el dataset: '{DATASET_ROOT}'" )
        return

    with Timer( "Indexado de archivos" ):
        file_paths, labels, class_names = collect_file_paths( DATASET_ROOT )
    labels      = np.array( labels )
    num_classes = len( class_names )
    print( f"  Total: {len( file_paths )} imágenes | {num_classes} clases" )

    ( paths_train, y_train, paths_val, y_val, paths_test, y_test ) = split_paths( file_paths, labels )
    print( f"  Train={len( paths_train )}  Val={len( paths_val )}  Test={len( paths_test )}" )

    summary_rows = [ ]

    for resolution in RESOLUTIONS:
        res_label = f"{resolution}x{resolution}"
        print( f"\n{'='*65}" )
        print( f"  RESOLUCIÓN: {res_label}" )
        print( f"{'='*65}" )

        ds_train = build_dataset( paths_train, y_train, resolution, BATCH_SIZE, shuffle=True )
        ds_val   = build_dataset( paths_val,   y_val,   resolution, BATCH_SIZE )
        ds_test  = build_dataset( paths_test,  y_test,  resolution, BATCH_SIZE )

        model = build_mobilenetv2( resolution, num_classes )

        history, train_time = train_model( model, ds_train, ds_val, res_label )
        plot_training_curves( history, res_label )

        keras_path = os.path.join( OUTPUT_DIR, f"model_MobileNetV2_{res_label}.keras" )
        model.save( keras_path )
        keras_kb = os.path.getsize( keras_path ) / 1024
        print( f"  Modelo guardado: {keras_path} ({keras_kb:.1f} KB)" )

        print( f"\n  >> Float32" )
        f32 = evaluate_model( model, ds_test, paths_test, y_test, class_names, res_label, resolution )
        summary_rows.append( {
            "resolucion":             res_label,
            "tiempo_entrenamiento_s": train_time,
            "cuantizacion":           "float32",
            "accuracy":               f32[ "accuracy" ],
            "inferencia_ms_img":      f32[ "inference_single_ms" ],
            "tamano_modelo_kb":       keras_kb,
            "tiempo_conversion_s":    None,
            "n_params":               model.count_params( )
        } )

        for qmode in QUANT_MODES:
            print( f"\n  >> {qmode.upper( )}" )
            try:
                qres = quantize_and_evaluate( model, paths_test, y_test, class_names, res_label, resolution, qmode, paths_train )
                summary_rows.append( {
                    "resolucion":             res_label,
                    "tiempo_entrenamiento_s": train_time,
                    "cuantizacion":           qmode,
                    "accuracy":               qres[ "accuracy" ],
                    "inferencia_ms_img":      qres[ "inference_single_ms" ],
                    "tamano_modelo_kb":       qres[ "model_size_kb" ],
                    "tiempo_conversion_s":    qres[ "conversion_s" ],
                    "n_params":               model.count_params( )
                } )
            except Exception as e:
                print( f"  [WARN] Cuantización {qmode} falló: {e}" )
                summary_rows.append( {
                    "resolucion":   res_label,
                    "cuantizacion": qmode,
                    "accuracy":     "ERROR"
                } )

        tf.keras.backend.clear_session( )

    df       = pd.DataFrame( summary_rows )
    csv_path = os.path.join( OUTPUT_DIR, "tabla_MobileNetV2_resoluciones.csv" )
    df.to_csv( csv_path, index=False )

    print( f"\n{'='*65}" )
    print( "  TABLA RESUMEN FINAL — MobileNetV2 tres resoluciones" )
    print( f"{'='*65}" )
    print( df.to_string( index=False ) )
    print( f"\n  CSV guardado en: {csv_path}" )
    print( f"\n  [ OK ] Resultados en: {OUTPUT_DIR}/" )


if __name__ == "__main__":
    main( )
