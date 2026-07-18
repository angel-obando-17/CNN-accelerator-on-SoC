import os
import time

import cv2
import numpy as np
import tensorflow as tf
from sklearn.metrics import confusion_matrix, accuracy_score

from .dataset import Timer
from .plotting import plot_cm

from typing import Callable, Generator

def make_representative_dataset( 
        paths_calib: list[ str ], 
        target_size: int, 
        segment_fn: Callable[ [ np.ndarray ], np.ndarray ] | None = None
    ) -> Callable[ [ ], Generator[ list[ np.ndarray ], None, None ] ]:

    samples = list( paths_calib[ :200 ] )

    def gen( ) -> Generator[ list[ np.ndarray ], None, None ]:
        for pict in samples:
            img = cv2.imread( pict )
            
            if img is None:
                continue
            if segment_fn is not None:
                img = segment_fn( img )
            
            img = cv2.resize( img, ( target_size, target_size ) )
            img = cv2.cvtColor( img, cv2.COLOR_BGR2RGB ).astype( np.float32 ) / 255.0
            yield [ img[ np.newaxis ] ]

    return gen

def quantize_and_evaluate( 
        model: tf.keras.Model, 
        paths_test: list[ str ], 
        labels_test: np.ndarray, 
        class_names: list[ str ], 
        label: str, 
        target_size: int, 
        qmode: str, 
        paths_calib: list[ str ],
        output_dir: str,
        segment_fn: Callable[ [ np.ndarray ], np.ndarray ] | None = None 
    ) -> dict[ str, float ]:

    results = { }
    converter = tf.lite.TFLiteConverter.from_keras_model( model )
    rep_gen   = make_representative_dataset( paths_calib, target_size, segment_fn )

    if qmode == "int8":
        converter.optimizations = [ tf.lite.Optimize.DEFAULT ]
        converter.representative_dataset = rep_gen
        converter.target_spec.supported_ops = [ tf.lite.OpsSet.TFLITE_BUILTINS_INT8 ]
        converter.inference_input_type  = tf.int8
        converter.inference_output_type = tf.int8
    elif qmode == "int16":
        converter.optimizations = [ tf.lite.Optimize.DEFAULT ]
        converter.representative_dataset = rep_gen
        converter.target_spec.supported_ops = [ tf.lite.OpsSet.EXPERIMENTAL_TFLITE_BUILTINS_ACTIVATIONS_INT16_WEIGHTS_INT8 ]

    with Timer( f"Conversión { qmode }" ) as t:
        tflite_model = converter.convert( )

    results[ "conversion_s" ] = t.elapsed

    model_path = os.path.join( output_dir, f"model_{ label }_{ qmode }.tflite" )

    with open( model_path, "wb" ) as f:
        f.write( tflite_model )

    results[ "model_size_kb" ] = os.path.getsize( model_path ) / 1024
    print( f"  Tamaño { qmode }: { results[ 'model_size_kb' ]:.1f} KB" )

    interp = tf.lite.Interpreter( model_path=model_path )
    interp.allocate_tensors( )
    in_det  = interp.get_input_details( )[ 0 ]
    out_det = interp.get_output_details( )[ 0 ]

    def run_one( img_float: np.ndarray ) -> int:
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

    print( f"  Evaluando { len( paths_test ) } imágenes en { qmode } (con HSV)..." )
    y_pred = [ ]
    t0 = time.perf_counter( )

    for path in paths_test:
        img = cv2.imread( path )
        
        if img is None:
            y_pred.append( 0 )
            continue

        if segment_fn is not None:
            img = segment_fn( img )

        img = cv2.resize( img, ( target_size, target_size ) )
        img = cv2.cvtColor( img, cv2.COLOR_BGR2RGB ).astype( np.float32 ) / 255.0
        y_pred.append(run_one( img ) )

    elapsed = time.perf_counter( ) - t0

    results[ "accuracy" ] = accuracy_score( labels_test, y_pred )
    results[ "inference_single_ms" ] = ( elapsed / len( paths_test ) ) * 1000
    print( f"  Accuracy { qmode }: { results[ 'accuracy' ]:.4f}" )
    print( f"  Tiempo/imagen: { results[ 'inference_single_ms' ]:.4f} ms" )

    cm = confusion_matrix( labels_test, y_pred )
    plot_cm( cm, class_names, f"{ label }_{ qmode }", output_dir )
    return results