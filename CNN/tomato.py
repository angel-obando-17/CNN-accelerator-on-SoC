"""
=============================================================================
EXPERIMENTOS CNN - DETECCIÓN DE ENFERMEDADES EN TOMATES
Trabajo de Grado - Acelerador CNN en Zynq-7020
=============================================================================
VERSIÓN 2 — Usa tf.data con generador para no explotar la RAM.
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
OUTPUT_DIR   = "resultados_experimentos_2"
os.makedirs( OUTPUT_DIR, exist_ok=True )

RESOLUTIONS = [ 256, 128, 96 ]
BATCH_SIZE  = 32
EPOCHS      = 30
SEED        = 42
VAL_SPLIT   = 0.15
TEST_SPLIT  = 0.15
QUANT_MODES = [ "int8", "int16" ]

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
    idx = np.arange( len( file_paths ) )
    idx_tmp, idx_test = train_test_split( idx, test_size=TEST_SPLIT, random_state=SEED, stratify=labels )
    val_ratio = VAL_SPLIT / ( 1 - TEST_SPLIT )
    idx_train, idx_val = train_test_split( idx_tmp, test_size=val_ratio, random_state=SEED, stratify=np.array( labels )[ idx_tmp ] )
    fp = np.array( file_paths )
    lb = np.array( labels )
    return ( fp[ idx_train ], lb[ idx_train ], fp[ idx_val ], lb[ idx_val ], fp[ idx_test ], lb[ idx_test ] )


# SEGMENTACIÓN
def segment_leaf( img_bgr ):
    h, w = img_bgr.shape[ :2 ]
    mask = np.zeros( ( h, w ), np.uint8 )
    mx   = max( int( w * 0.10 ), 5 )
    my   = max( int( h * 0.10 ), 5 )
    rect = ( mx, my, w - 2*mx, h - 2*my )
    bgd  = np.zeros( ( 1, 65 ), np.float64 )
    fgd  = np.zeros( ( 1, 65 ), np.float64 )
    try:
        cv2.grabCut( img_bgr, mask, rect, bgd, fgd, 5, cv2.GC_INIT_WITH_RECT )
        fg = np.where( ( mask == cv2.GC_FGD ) | ( mask == cv2.GC_PR_FGD ), 255, 0 ).astype( np.uint8 )
    except Exception:
        fg = np.ones( ( h, w ), dtype=np.uint8 ) * 255
    return cv2.bitwise_and( img_bgr, img_bgr, mask=fg )


# PIPELINE tf.data
def load_and_preprocess( path, label, target_size ):
    def _load( p, sz ):
        p   = p.numpy( ).decode( "utf-8" )
        sz  = int( sz.numpy( ) )
        img = cv2.imread( p )
        if img is None:
            img = np.zeros( ( sz, sz, 3 ), dtype=np.uint8 )
        # img = segment_leaf(img)
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


# MODELO MobileNetV1
def dw_block( x, filters, strides=1, name_prefix="dw" ):
    x = layers.DepthwiseConv2D( 3, strides=strides, padding="same", use_bias=False, name=f"{name_prefix}_dw" )( x )
    x = layers.BatchNormalization( name=f"{name_prefix}_dw_bn" )( x )
    x = layers.ReLU( name=f"{name_prefix}_dw_relu" )( x )
    x = layers.Conv2D( filters, 1, padding="same", use_bias=False, name=f"{name_prefix}_pw" )( x )
    x = layers.BatchNormalization( name=f"{name_prefix}_pw_bn" )( x )
    x = layers.ReLU( name=f"{name_prefix}_pw_relu" )( x )
    return x


def build_mobilenetv1( input_size, num_classes, max_ch=64 ):
    inp = layers.Input( shape=( input_size, input_size, 3 ) )
    x   = layers.Conv2D( min( 32, max_ch ), 3, strides=2, padding="same", use_bias=False, name="conv1" )( inp )
    x   = layers.BatchNormalization( name="conv1_bn" )( x )
    x   = layers.ReLU( name="conv1_relu" )( x )
    cfg = [ ( 64,1 ),( 64,2 ),( 64,1 ),( 64,2 ),( 64,1 ),( 64,2 ),
            ( 64,1 ),( 64,1 ),( 64,1 ),( 64,1 ),( 64,1 ),( 64,2 ),( 64,1 ) ]
    for i, ( ch, s ) in enumerate( cfg ):
        x = dw_block( x, min( ch, max_ch ), strides=s, name_prefix=f"dw{i+1}" )
    x = layers.GlobalAveragePooling2D( name="gap" )( x )
    x = layers.Dense( num_classes, activation="softmax", name="output" )( x )
    return models.Model( inp, x, name=f"MobileNetV1_{input_size}" )


# ENTRENAMIENTO
def train_model( model, ds_train, ds_val ):
    model.compile(
        optimizer=tf.keras.optimizers.Adam( 1e-3 ),
        loss="sparse_categorical_crossentropy",
        metrics=[ "accuracy" ]
    )
    cbs = [
        EarlyStopping( monitor="val_accuracy", patience=7, restore_best_weights=True ),
        ReduceLROnPlateau( monitor="val_loss", factor=0.5, patience=3, min_lr=1e-6 )
    ]
    with Timer( "Entrenamiento" ) as t:
        history = model.fit( ds_train, validation_data=ds_val, epochs=EPOCHS, callbacks=cbs, verbose=1 )
    return history, t.elapsed


# EVALUACIÓN
def evaluate_model( model, ds_test, paths_test, labels_test, class_names, label, resolution ):
    results = { }
    with Timer( "Inferencia batch" ) as t:
        y_pred_proba = model.predict( ds_test, verbose=0 )
    results[ "inference_batch_s" ] = t.elapsed
    y_pred = np.argmax( y_pred_proba, axis=1 )
    results[ "accuracy" ] = accuracy_score( labels_test, y_pred )
    print( f"  Accuracy: {results[ 'accuracy' ]:.4f}" )

    times = [ ]
    for p in paths_test[ :100 ]:
        img = cv2.imread( p )
        if img is None:
            continue
        img = segment_leaf( img )
        img = cv2.resize( img, ( resolution, resolution ) )
        img = cv2.cvtColor( img, cv2.COLOR_BGR2RGB ).astype( np.float32 ) / 255.0
        t0  = time.perf_counter( )
        model.predict( img[ np.newaxis ], verbose=0 )
        times.append( time.perf_counter( ) - t0 )
    results[ "inference_single_ms" ] = np.mean( times ) * 1000 if times else 0
    print( f"  Tiempo/imagen: {results[ 'inference_single_ms' ]:.2f} ms" )

    cm = confusion_matrix( labels_test, y_pred )
    plot_cm( cm, class_names, label )
    return results


def plot_cm( cm, class_names, label ):
    short = [ re.sub( r"Tomato_+", "", n ) for n in class_names ]
    n     = len( short )
    fig, ax = plt.subplots( figsize=( max( 8, n ), max( 6, n ) ) )
    sns.heatmap( cm, annot=True, fmt="d", cmap="Blues", xticklabels=short, yticklabels=short, ax=ax )
    ax.set_xlabel( "Predicho" ); ax.set_ylabel( "Real" )
    ax.set_title( f"Confusion Matrix — {label}" )
    plt.tight_layout( )
    fig.savefig( os.path.join( OUTPUT_DIR, f"cm_{label.replace( ' ', '_' )}.png" ), dpi=150 )
    plt.close( fig )


def plot_training_curves( history, resolution ):
    fig, axes = plt.subplots( 1, 2, figsize=( 12, 4 ) )
    axes[ 0 ].plot( history.history[ "accuracy" ],     label="Train" )
    axes[ 0 ].plot( history.history[ "val_accuracy" ],  label="Val" )
    axes[ 0 ].set_title( f"Accuracy — {resolution}x{resolution}" )
    axes[ 0 ].set_xlabel( "Época" ); axes[ 0 ].legend( )
    axes[ 1 ].plot( history.history[ "loss" ],     label="Train" )
    axes[ 1 ].plot( history.history[ "val_loss" ],  label="Val" )
    axes[ 1 ].set_title( f"Loss — {resolution}x{resolution}" )
    axes[ 1 ].set_xlabel( "Época" ); axes[ 1 ].legend( )
    plt.tight_layout( )
    fig.savefig( os.path.join( OUTPUT_DIR, f"training_{resolution}x{resolution}.png" ), dpi=150 )
    plt.close( fig )


# CUANTIZACIÓN TFLite
def make_representative_dataset( paths_calib, target_size ):
    samples = list( paths_calib[ :200 ] )
    def gen( ):
        for p in samples:
            img = cv2.imread( p )
            if img is None:
                continue
            img = segment_leaf( img )
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

    with Timer( f"Conversión TFLite {qmode}" ) as t:
        tflite_model = converter.convert( )
    results[ "conversion_s" ] = t.elapsed

    model_path = os.path.join( OUTPUT_DIR, f"model_{res_label}_{qmode}.tflite" )
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

    n_eval = min( 500, len( paths_test ) )
    idx    = np.random.choice( len( paths_test ), n_eval, replace=False )
    y_pred = [ ]
    t0 = time.perf_counter( )
    for i in idx:
        img = cv2.imread( paths_test[ i ] )
        if img is None:
            y_pred.append( 0 ); continue
        # img = segment_leaf(img)
        img = cv2.resize( img, ( target_size, target_size ) )
        img = cv2.cvtColor( img, cv2.COLOR_BGR2RGB ).astype( np.float32 ) / 255.0
        y_pred.append( run_one( img ) )
    elapsed = time.perf_counter( ) - t0

    results[ "accuracy" ]            = accuracy_score( labels_test[ idx ], y_pred )
    results[ "inference_single_ms" ] = ( elapsed / n_eval ) * 1000
    print( f"  Accuracy {qmode}: {results[ 'accuracy' ]:.4f}  |  {results[ 'inference_single_ms' ]:.2f} ms/img" )
    plot_cm( confusion_matrix( labels_test[ idx ], y_pred ), class_names, f"{res_label}_{qmode}" )
    return results


# ANÁLISIS DE VIABILIDAD
def analyze_viability( df ):
    print( f"\n{'='*60}" )
    print( "  ANÁLISIS DE VIABILIDAD — ZYNQ-7020" )
    print( f"{'='*60}" )
    TARGET_ACC = 0.85
    df_c = df[ df[ "accuracy" ] != "ERROR" ].copy( )
    df_c[ "accuracy" ] = df_c[ "accuracy" ].astype( float )

    t  = df_c[ ( df_c[ "resolution" ] == "96x96" ) & ( df_c[ "quant" ] == "int8" ) ]
    print( "\n  Caso objetivo (96x96 + INT8):" )
    if not t.empty:
        acc = t[ "accuracy" ].values[ 0 ]
        ok  = acc >= TARGET_ACC
        print( f"    Accuracy: {acc:.4f}  {'    VIABLE' if ok else '    NO cumple'}" )
        if not ok:
            print( "    Alternativas:" )
            for res, q in [ ( "96x96","int16" ), ( "128x128","int8" ), ( "128x128","int16" ) ]:
                row = df_c[ ( df_c[ "resolution" ] == res ) & ( df_c[ "quant" ] == q ) ]
                if not row.empty:
                    a = row[ "accuracy" ].values[ 0 ]
                    print( f"      {res} {q.upper( )}: {a:.4f}  {'OK' if a >= TARGET_ACC else 'FAIL'}" )

    print( "\n  Pérdida de precisión por resolución:" )
    for res in df_c[ "resolution" ].unique( ):
        base = df_c[ ( df_c[ "resolution" ] == res ) & ( df_c[ "quant" ] == "float32" ) ][ "accuracy" ]
        if base.empty:
            continue
        b = base.values[ 0 ]
        s = f"    {res}  Float32={b:.4f}"
        for q in [ "int8", "int16" ]:
            r = df_c[ ( df_c[ "resolution" ] == res ) & ( df_c[ "quant" ] == q ) ][ "accuracy" ]
            if not r.empty:
                s += f"  |  {q.upper( )}={r.values[ 0 ]:.4f} (Δ={b - r.values[ 0 ]:+.4f})"
        print( s )


def generate_summary_plot( df ):
    df_p   = df[ df[ "accuracy" ] != "ERROR" ].copy( )
    df_p[ "accuracy" ] = df_p[ "accuracy" ].astype( float )
    ress   = df_p[ "resolution" ].unique( )
    quants = df_p[ "quant" ].unique( )
    x      = np.arange( len( ress ) )
    width  = 0.25
    fig, ax = plt.subplots( figsize=( 12, 6 ) )
    for i, q in enumerate( quants ):
        vals = [ df_p.loc[ ( df_p[ "resolution" ] == r ) & ( df_p[ "quant" ] == q ), "accuracy" ].values for r in ress ]
        vals = [ v[ 0 ] if len( v ) else 0 for v in vals ]
        bars = ax.bar( x + i*width, vals, width, label=q.upper( ) )
        for bar, val in zip( bars, vals ):
            ax.text( bar.get_x( ) + bar.get_width( ) / 2, bar.get_height( ) + 0.005,
                     f"{val:.3f}", ha="center", va="bottom", fontsize=8 )
    ax.set_xticks( x + width ); ax.set_xticklabels( ress )
    ax.set_ylim( 0, 1.05 ); ax.set_ylabel( "Accuracy" )
    ax.set_title( "Comparativa: Resolución × Cuantización" ); ax.legend( )
    plt.tight_layout( )
    fig.savefig( os.path.join( OUTPUT_DIR, "summary_accuracy.png" ), dpi=150 )
    plt.close( fig )


# MAIN
def run_all_experiments( ):
    print( "="*60 )
    print( "  EXPERIMENTOS CNN — TOMATE / ZYNQ-7020" )
    print( "="*60 )

    if not os.path.isdir( DATASET_ROOT ):
        print( f"[ERROR] No se encontró: '{DATASET_ROOT}'" )
        return None

    print( "\n  Indexando archivos..." )
    with Timer( "Indexado" ) as t_idx:
        file_paths, labels, class_names = collect_file_paths( DATASET_ROOT )
    labels = np.array( labels )
    print( f"  Total: {len( file_paths )} imágenes | {len( class_names )} clases" )
    print( f"  Clases: {class_names}" )

    ( paths_train, y_train, paths_val, y_val, paths_test, y_test ) = split_paths( file_paths, labels )
    print( f"  Train={len( paths_train )}  Val={len( paths_val )}  Test={len( paths_test )}" )

    summary_rows = [ ]

    for resolution in RESOLUTIONS:
        print( f"\n{'='*60}" )
        print( f"  RESOLUCIÓN: {resolution}x{resolution}" )
        print( f"{'='*60}" )
        res_label = f"{resolution}x{resolution}"
        row_base  = { "resolution": res_label }

        ds_train = build_dataset( paths_train, y_train, resolution, BATCH_SIZE, shuffle=True )
        ds_val   = build_dataset( paths_val,   y_val,   resolution, BATCH_SIZE )
        ds_test  = build_dataset( paths_test,  y_test,  resolution, BATCH_SIZE )

        model = build_mobilenetv1( resolution, len( class_names ) )
        history, train_time = train_model( model, ds_train, ds_val )
        row_base[ "train_s" ] = train_time
        plot_training_curves( history, resolution )

        print( "\n  >> Evaluación Float32" )
        with Timer( "Evaluación" ) as t_ev:
            eval_res = evaluate_model( model, ds_test, paths_test, y_test, class_names, f"{res_label}_float32", resolution )
        row_base[ "eval_s" ] = t_ev.elapsed

        model_path = os.path.join( OUTPUT_DIR, f"model_{res_label}.keras" )
        model.save( model_path )
        summary_rows.append( { **row_base, "quant": "float32",
                                "accuracy": eval_res[ "accuracy" ],
                                "inference_single_ms": eval_res[ "inference_single_ms" ],
                                "model_size_kb": os.path.getsize( model_path ) / 1024 } )

        for qmode in QUANT_MODES:
            print( f"\n  >> Cuantización {qmode.upper( )}" )
            try:
                qres = quantize_and_evaluate( model, paths_test, y_test, class_names, res_label, resolution, qmode, paths_train )
                summary_rows.append( { **row_base, "quant": qmode,
                                       "accuracy": qres[ "accuracy" ],
                                       "inference_single_ms": qres[ "inference_single_ms" ],
                                       "model_size_kb": qres[ "model_size_kb" ],
                                       "conversion_s": qres.get( "conversion_s" ) } )
            except Exception as e:
                print( f"  [WARN] {qmode} falló: {e}" )
                summary_rows.append( { **row_base, "quant": qmode,
                                       "accuracy": "ERROR",
                                       "inference_single_ms": "ERROR",
                                       "model_size_kb": "ERROR" } )
        tf.keras.backend.clear_session( )

    df       = pd.DataFrame( summary_rows )
    csv_path = os.path.join( OUTPUT_DIR, "tabla_resumen.csv" )
    df.to_csv( csv_path, index=False )
    print( f"\n{'='*60}\n  TABLA RESUMEN\n{'='*60}" )
    print( df.to_string( index=False ) )
    generate_summary_plot( df )
    return df


if __name__ == "__main__":
    df = run_all_experiments( )
    if df is not None and not df.empty:
        analyze_viability( df )
    print( f"\n  Listo. Resultados en: {OUTPUT_DIR}/" )
