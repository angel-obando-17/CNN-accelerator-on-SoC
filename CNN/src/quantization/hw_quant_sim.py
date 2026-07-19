"""
SIMULADOR DE CUANTIZACION HARDWARE-EXACTA (Fase 1 - PTQ)
Trabajo de Grado - Acelerador CNN en Zynq-7020

El PTQ estandar de TFLite (usado en src/training/train_hsv.py) asume un
hardware que el acelerador real NO tiene. Verificado contra el RTL
(mac.vhd, accumulator_bank.vhd, add_unit.vhd, quant_relu.vhd):

  1. Sin bias en el MAC -> el bias se suma en software DESPUES de que el
     hardware ya aplico shift + clamp int8 + ReLU6 (quant_relu.vhd), no
     antes como en la matematica ideal de bias-antes-del-shift.
  2. Sin zero-point -> cuantizacion simetrica forzada (zero_point=0) en
     pesos y activaciones.
  3. Un solo shift (potencia de 2) por capa, compartido entre los 16
     canales en paralelo -> escala de pesos por-tensor, no por-canal.
  4. add_unit.vhd suma dos tensores INT8 crudos sin rescalar -> en los
     bloques con residual, la escala de salida de la conv de proyeccion
     se FUERZA a ser igual a la escala de entrada del bloque (no hay
     forma de rescalar el residuo guardado en DDR al sumarlo).

Este script simula ese datapath exacto capa por capa (no usa
TFLiteConverter) sobre el modelo de produccion ya entrenado
(MobileNetV2 + segmentacion HSV, 256x256, canales <=64) y compara el
accuracy resultante contra el PTQ estandar ya medido (94.15% INT8).

Resultado ya confirmado (Fase 1, 2026-07-13): 11.11% accuracy (=azar) --
el redondeo de shift a potencia de 2 acumulado en ~28 capas rompe la red
por completo. QAT (Fase 2, src/quantization/qat/) es necesario, no
opcional -- ver CNN/docs/analisis_cuantizacion_fase1.md.
"""

import os
import json
import warnings
from pathlib import Path

import numpy as np
import pandas as pd
import cv2
import tensorflow as tf
from tensorflow.keras import models
from sklearn.metrics import accuracy_score, confusion_matrix

from src.common.dataset import collect_file_paths, split_paths
from src.common.segmentation import segment_hsv

# Import registra las capas custom de QAT (FakeQuantConv2D, etc.) para que
# models.load_model() pueda deserializar un modelo QAT sin importar desde
# donde se invoque este script -- si el modelo cargado no es QAT, este
# import no tiene ningun efecto.
from src.quantization.qat import layers as _qat_layers  # noqa: F401

warnings.filterwarnings( "ignore" )

# TF32 (tensor cores, Ampere+) trunca a 10 bits de mantisa en conv2d/depthwise_conv2d,
# rompiendo la exactitud entera que la simulacion hardware necesita -- desactivar.
tf.config.experimental.enable_tensor_float_32_execution( False )


def load_image( path: str, target_size: int, segment_fn=segment_hsv ) -> np.ndarray:
    img = cv2.imread( path )
    if img is None:
        return np.zeros( ( target_size, target_size, 3 ), dtype=np.float32 )
    if segment_fn is not None:
        img = segment_fn( img )
    img = cv2.resize( img, ( target_size, target_size ) )
    img = cv2.cvtColor( img, cv2.COLOR_BGR2RGB )
    return img.astype( np.float32 ) / 255.0


# ARQUITECTURA -> metadata de canales, replica exacta de build_mobilenetv2
# (src/models/mobilenetv2.py), mismo cfg, mismo max_ch.
def derive_blocks(
        cfg: list[ tuple[ int, int, int ] ],
        max_ch: int,
        conv1_ch: int = 32
    ) -> list[ dict[ str, object ] ]:

    blocks = [ ]
    in_ch = min( conv1_ch, max_ch )
    for i, ( t, c, s ) in enumerate( cfg ):
        out_ch = min( c, max_ch )
        exp_ch = min( in_ch * t, max_ch ) if t != 1 else None
        has_residual = ( s == 1 and in_ch == out_ch )
        blocks.append( {
            "idx": i + 1, "t": t, "s": s,
            "in_ch": in_ch, "exp_ch": exp_ch, "out_ch": out_ch,
            "has_residual": has_residual
        } )
        in_ch = out_ch
    return blocks


# FUSION Conv/DW + BatchNorm -> (peso_fusionado, bias_fusionado) en float.
def fuse_conv_bn( conv_layer, bn_layer, depthwise: bool ) -> tuple[ np.ndarray, np.ndarray ]:
    eps   = bn_layer.epsilon
    gamma = bn_layer.gamma.numpy( )
    beta  = bn_layer.beta.numpy( )
    mean  = bn_layer.moving_mean.numpy( )
    var   = bn_layer.moving_variance.numpy( )
    scale = gamma / np.sqrt( var + eps )
    bias  = beta - mean * scale

    if depthwise:
        w = conv_layer.kernel.numpy( )                   # (kh,kw,Cin,1)
        w_fused = w * scale.reshape( 1, 1, -1, 1 )
    else:
        w = conv_layer.kernel.numpy( )                   # (kh,kw,Cin,Cout)
        w_fused = w * scale.reshape( 1, 1, 1, -1 )

    return w_fused.astype( np.float64 ), bias.astype( np.float64 )


# CUANTIZACION -- simetrica, zero_point=0, shift potencia-de-2.
def quantize_weight_symmetric( w: np.ndarray ) -> tuple[ np.ndarray, float ]:
    max_abs = np.max( np.abs( w ) )
    scale = max_abs / 127.0 if max_abs > 0 else 1.0
    q = np.clip( np.round( w / scale ), -127, 127 ).astype( np.int64 )
    return q, scale


def choose_shift( s_w: float, s_in: float, s_out: float, max_shift: int ) -> int:
    if s_out <= 0 or s_w <= 0 or s_in <= 0:
        return 0
    m = ( s_w * s_in ) / s_out
    if m <= 0:
        return 0
    shift = int( round( -np.log2( m ) ) )
    return max( 0, min( max_shift, shift ) )


def quantize_bias( bias_float: np.ndarray, s_out: float ) -> np.ndarray:
    return np.round( bias_float / s_out ).astype( np.int64 )


def make_layer_params(
        conv_layer, bn_layer, depthwise: bool,
        s_in: float, s_out: float, relu_en: bool, max_shift: int
    ) -> dict[ str, object ]:

    w_fused, bias_fused = fuse_conv_bn( conv_layer, bn_layer, depthwise )
    w_q, s_w = quantize_weight_symmetric( w_fused )
    shift    = choose_shift( s_w, s_in, s_out, max_shift )
    bias_q   = quantize_bias( bias_fused, s_out )
    relu6_val = int( np.clip( round( 6.0 / s_out ), 0, 127 ) ) if relu_en else 0
    return {
        "w": w_q, "bias": bias_q, "shift": shift, "relu_en": relu_en,
        "relu6_val": relu6_val, "s_w": float( s_w ), "s_in": float( s_in ), "s_out": float( s_out )
    }


# CALIBRACION -- estadisticas de activacion (max-abs) usando el modelo
# float32 original (no fusionado), para tener el forward pass exacto que
# el modelo realmente vio en entrenamiento.
def build_calib_extractor( model: tf.keras.Model, blocks: list[ dict[ str, object ] ] ) -> tuple[ tf.keras.Model, list[ str ] ]:
    names = [ "conv1_relu6" ]
    for b in blocks:
        if b[ "exp_ch" ] is not None:
            names.append( f"irb{b['idx']}_exp_relu6" )
        names.append( f"irb{b['idx']}_dw_relu6" )
        names.append( f"irb{b['idx']}_pw_bn" )
    names.append( "conv_last_relu6" )
    names.append( "gap" )

    # Las capas _bn de QAT (HardwareOrderScaleQuant) devuelven 3 salidas
    # (x_out, bias, eff_scale) en vez de 1 -- solo la primera (x_out) es la
    # que hace falta calibrar aqui. Sobre el modelo estandar (no-QAT) esto
    # no tiene efecto: .output ya es un tensor unico.
    def primary_output( layer ):
        out = layer.output
        return out[ 0 ] if isinstance( out, ( list, tuple ) ) else out

    outputs = [ primary_output( model.get_layer( n ) ) for n in names ]
    extractor = models.Model( model.input, outputs )
    return extractor, names


def calibrate(
        extractor: tf.keras.Model, names: list[ str ], calib_images: np.ndarray
    ) -> tuple[ float, dict[ str, float ] ]:

    stats = { n: 0.0 for n in names }
    input_max = 0.0
    batch = 16
    for i in range( 0, len( calib_images ), batch ):
        x = calib_images[ i:i + batch ]
        input_max = max( input_max, float( np.max( np.abs( x ) ) ) )
        outs = extractor.predict( x, verbose=0 )
        if len( names ) == 1:
            outs = [ outs ]
        for n, o in zip( names, outs ):
            stats[ n ] = max( stats[ n ], float( np.max( np.abs( o ) ) ) )
    return input_max, stats


# INT ops -- conv/dw exactas via TF (enteros representables sin perdida en
# float32 dado el rango de este modelo), shift/clamp/relu/bias en numpy con
# semantica de shift aritmetico (igual a numeric_std.shift_right en VHDL).
def conv2d_int( x_int: np.ndarray, w_int: np.ndarray, stride: int ) -> np.ndarray:
    xf = tf.cast( x_int, tf.float32 )
    wf = tf.cast( w_int, tf.float32 )
    y  = tf.nn.conv2d( xf, wf, strides=[ 1, stride, stride, 1 ], padding="SAME" )
    return tf.cast( tf.round( y ), tf.int64 ).numpy( )


def dwconv2d_int( x_int: np.ndarray, w_int: np.ndarray, stride: int ) -> np.ndarray:
    xf = tf.cast( x_int, tf.float32 )
    wf = tf.cast( w_int, tf.float32 )
    y  = tf.nn.depthwise_conv2d( xf, wf, strides=[ 1, stride, stride, 1 ], padding="SAME" )
    return tf.cast( tf.round( y ), tf.int64 ).numpy( )


def apply_quant_relu(
        acc_int64: np.ndarray, shift: int, bias_q: np.ndarray, relu_en: bool, relu6_val: int
    ) -> np.ndarray:

    shifted = acc_int64 >> shift
    clamped = np.clip( shifted, -128, 127 )
    if relu_en:
        out = np.where( clamped < 0, 0, np.where( clamped > relu6_val, relu6_val, clamped ) )
    else:
        out = clamped
    out = out + bias_q
    out = np.clip( out, -128, 127 )
    return out.astype( np.int64 )


# CONSTRUCCION DE PARAMETROS POR CAPA -- une calibracion + fusion + cuantizacion.
def build_all_params(
        model: tf.keras.Model, blocks: list[ dict[ str, object ] ],
        s_image_in: float, stats: dict[ str, float ], max_shift: int
    ) -> dict[ str, object ]:

    params = { }

    s_prev = stats[ "conv1_relu6" ] / 127.0
    params[ "conv1" ] = make_layer_params(
        model.get_layer( "conv1" ), model.get_layer( "conv1_bn" ), False,
        s_image_in, s_prev, True, max_shift
    )

    for b in blocks:
        idx  = b[ "idx" ]
        s_in = s_prev
        cur_s = s_in

        if b[ "exp_ch" ] is not None:
            s_exp = stats[ f"irb{idx}_exp_relu6" ] / 127.0
            params[ f"irb{idx}_exp" ] = make_layer_params(
                model.get_layer( f"irb{idx}_exp" ), model.get_layer( f"irb{idx}_exp_bn" ), False,
                cur_s, s_exp, True, max_shift
            )
            cur_s = s_exp

        s_dw = stats[ f"irb{idx}_dw_relu6" ] / 127.0
        params[ f"irb{idx}_dw" ] = make_layer_params(
            model.get_layer( f"irb{idx}_dw" ), model.get_layer( f"irb{idx}_dw_bn" ), True,
            cur_s, s_dw, True, max_shift
        )
        cur_s = s_dw

        # add_unit.vhd suma int8+int8 crudo, sin rescalar -> si el bloque
        # tiene residual, la salida de la conv de proyeccion se fuerza a
        # la MISMA escala de entrada del bloque (s_in), no a su propia
        # escala calibrada -- es lo que el hardware real exige.
        s_out_block = s_in if b[ "has_residual" ] else ( stats[ f"irb{idx}_pw_bn" ] / 127.0 )
        params[ f"irb{idx}_pw" ] = make_layer_params(
            model.get_layer( f"irb{idx}_pw" ), model.get_layer( f"irb{idx}_pw_bn" ), False,
            cur_s, s_out_block, False, max_shift
        )

        s_prev = s_out_block

    s_last = stats[ "conv_last_relu6" ] / 127.0
    params[ "conv_last" ] = make_layer_params(
        model.get_layer( "conv_last" ), model.get_layer( "conv_last_bn" ), False,
        s_prev, s_last, True, max_shift
    )

    # GAP -- acumulador propio (gap_unit.vhd), shift independiente, sin bias/relu.
    n_pixels = int( np.prod( model.get_layer( "conv_last_relu6" ).output.shape[ 1:3 ] ) )
    s_gap = stats[ "gap" ] / 127.0
    m_gap = s_last / ( n_pixels * s_gap ) if s_gap > 0 else 0
    gap_shift = max( 0, min( max_shift, int( round( -np.log2( m_gap ) ) ) ) ) if m_gap > 0 else 0
    params[ "gap" ] = { "shift": gap_shift, "s_in": float( s_last ), "s_out": float( s_gap ), "n_pixels": n_pixels }

    # Dense final -- NO corre en el acelerador (no hay unidad FC en el
    # datapath), se asume que el PS la ejecuta en float32 sobre el
    # resultado ya dequantizado del GAP.
    dense_layer = model.get_layer( "output" )
    dw, db = dense_layer.get_weights( )
    params[ "dense" ] = { "w": dw.astype( np.float64 ), "b": db.astype( np.float64 ) }

    params[ "s_image_in" ] = float( s_image_in )
    return params


# FORWARD PASS HARDWARE-EXACTO (batch de imagenes ya cuantizadas a int8).
def forward_hw_sim(
        x_int8_batch: np.ndarray, params: dict[ str, object ], blocks: list[ dict[ str, object ] ]
    ) -> np.ndarray:

    p = params[ "conv1" ]
    acc = conv2d_int( x_int8_batch, p[ "w" ], stride=2 )
    x = apply_quant_relu( acc, p[ "shift" ], p[ "bias" ], True, p[ "relu6_val" ] )

    for b in blocks:
        idx = b[ "idx" ]
        block_in = x
        cur = x

        if b[ "exp_ch" ] is not None:
            p = params[ f"irb{idx}_exp" ]
            acc = conv2d_int( cur, p[ "w" ], stride=1 )
            cur = apply_quant_relu( acc, p[ "shift" ], p[ "bias" ], True, p[ "relu6_val" ] )

        p = params[ f"irb{idx}_dw" ]
        acc = dwconv2d_int( cur, p[ "w" ], stride=b[ "s" ] )
        cur = apply_quant_relu( acc, p[ "shift" ], p[ "bias" ], True, p[ "relu6_val" ] )

        p = params[ f"irb{idx}_pw" ]
        acc = conv2d_int( cur, p[ "w" ], stride=1 )
        cur = apply_quant_relu( acc, p[ "shift" ], p[ "bias" ], False, 0 )

        if b[ "has_residual" ]:
            summed = block_in.astype( np.int64 ) + cur.astype( np.int64 )   # add_unit.vhd: int8+int8 crudo.
            cur = np.clip( summed, -128, 127 )

        x = cur

    p = params[ "conv_last" ]
    acc = conv2d_int( x, p[ "w" ], stride=1 )
    x = apply_quant_relu( acc, p[ "shift" ], p[ "bias" ], True, p[ "relu6_val" ] )

    gp = params[ "gap" ]
    acc = np.sum( x.astype( np.int64 ), axis=( 1, 2 ) )
    gap_out = np.clip( acc >> gp[ "shift" ], -128, 127 )

    gap_float = gap_out.astype( np.float64 ) * gp[ "s_out" ]
    dp = params[ "dense" ]
    logits = gap_float @ dp[ "w" ] + dp[ "b" ]
    return logits


def quantize_input_batch( images_float: np.ndarray, s_image_in: float ) -> np.ndarray:
    q = np.round( images_float / s_image_in )
    q = np.clip( q, -128, 127 )
    return q.astype( np.int64 )


def export_layer_table( params: dict[ str, object ], blocks: list[ dict[ str, object ] ], path: str ) -> None:
    #Formato consumible por generate_layer_table.py (lado PS) -- shift, bias, relu6_val por capa.
    rows = [ ]

    def add_row( name: str, p: dict[ str, object ] ) -> None:
        rows.append( {
            "layer": name, "shift": p[ "shift" ], "relu_en": p[ "relu_en" ],
            "relu6_val": p[ "relu6_val" ], "s_w": p[ "s_w" ], "s_in": p[ "s_in" ], "s_out": p[ "s_out" ],
            "bias": p[ "bias" ].tolist( )
        } )

    add_row( "conv1", params[ "conv1" ] )
    for b in blocks:
        idx = b[ "idx" ]
        if f"irb{idx}_exp" in params:
            add_row( f"irb{idx}_exp", params[ f"irb{idx}_exp" ] )
        add_row( f"irb{idx}_dw", params[ f"irb{idx}_dw" ] )
        add_row( f"irb{idx}_pw", params[ f"irb{idx}_pw" ] )
    add_row( "conv_last", params[ "conv_last" ] )
    rows.append( {
        "layer": "gap", "shift": params[ "gap" ][ "shift" ], "relu_en": False, "relu6_val": 0,
        "s_w": None, "s_in": params[ "gap" ][ "s_in" ], "s_out": params[ "gap" ][ "s_out" ], "bias": None
    } )

    with open( path, "w" ) as f:
        json.dump( rows, f, indent=2 )
    print( f"  Tabla de capas exportada: {path}" )


def main(
        dataset_root: str,
        model_path: str,
        output_dir: str,
        resolution: int = 256,
        seed: int = 42,
        n_calib: int = 200,
        max_ch: int = 64,
        shift_bits: int = 5,          # REG_SHIFT / REG_GAP_SHIFT son de 5 bits (unsigned(4 downto 0)).
        cfg: list[ tuple[ int, int, int ] ] = [
            ( 1, 16, 1 ), ( 2, 24, 2 ), ( 2, 24, 1 ), ( 2, 32, 2 ), ( 2, 32, 1 ),
            ( 2, 64, 2 ), ( 2, 64, 1 ), ( 2, 64, 1 ), ( 2, 64, 1 )
        ],
        reference_ptq_accuracy: float = 0.9415,
        batch_size: int = 32,
        bias_enabled: bool = True
    ) -> None:

    max_shift = ( 2 ** shift_bits ) - 1

    print( "=" * 65 )
    print( "  SIMULADOR DE CUANTIZACION HARDWARE-EXACTA (Fase 1)" )
    print( "  MobileNetV2 + HSV, 256x256 -- vs. PTQ estandar de TFLite" )
    print( f"  bias_enabled={bias_enabled}" )
    print( "=" * 65 )

    if not os.path.isdir( dataset_root ):
        print( f"[ERROR] No se encontro el dataset: '{dataset_root}'" )
        return
    if not os.path.exists( model_path ):
        print( f"[ERROR] No se encontro el modelo: '{model_path}'" )
        return

    os.makedirs( output_dir, exist_ok=True )
    np.random.seed( seed )

    print( "\n  Indexando archivos..." )
    file_paths, labels, class_names = collect_file_paths( dataset_root )
    labels = np.array( labels )
    paths_train, y_train, paths_val, y_val, paths_test, y_test = split_paths( file_paths, labels, seed=seed )
    print( f"  Train={len(paths_train)}  Val={len(paths_val)}  Test={len(paths_test)}" )

    print( "\n  Cargando modelo de produccion..." )
    model = models.load_model( model_path )
    blocks = derive_blocks( cfg, max_ch )

    print( "\n  Calibrando escalas de activacion (imagenes de train, con HSV)..." )
    extractor, names = build_calib_extractor( model, blocks )
    calib_paths = paths_train[ :n_calib ]
    calib_images = np.array( [ load_image( p, resolution ) for p in calib_paths ], dtype=np.float32 )
    s_image_in, stats = calibrate( extractor, names, calib_images )
    print( f"  Escala de entrada (imagen): {s_image_in / 127.0:.6f}" )

    print( "\n  Fusionando Conv+BN y cuantizando pesos/activaciones (simetrico, shift potencia-2)..." )
    params = build_all_params( model, blocks, s_image_in / 127.0, stats, max_shift )

    if not bias_enabled:
        print( "  [ ABLACION ] bias_enabled=False -- forzando bias=0 en todas las capas (simula hardware sin soporte de bias)." )
        for p in params.values( ):
            if isinstance( p, dict ) and "bias" in p and isinstance( p[ "bias" ], np.ndarray ):
                p[ "bias" ] = np.zeros_like( p[ "bias" ] )

    export_layer_table( params, blocks, os.path.join( output_dir, "layer_quant_params.json" ) )

    print( f"\n  Evaluando {len(paths_test)} imagenes de test con el datapath hardware-exacto..." )
    y_pred = [ ]
    for i in range( 0, len( paths_test ), batch_size ):
        batch_paths = paths_test[ i:i + batch_size ]
        images = np.array( [ load_image( p, resolution ) for p in batch_paths ], dtype=np.float32 )
        x_int8 = quantize_input_batch( images, s_image_in / 127.0 )
        logits = forward_hw_sim( x_int8, params, blocks )
        y_pred.extend( np.argmax( logits, axis=1 ).tolist( ) )
        if ( i // batch_size ) % 5 == 0:
            print( f"    {i + len(batch_paths)}/{len(paths_test)}..." )

    acc = accuracy_score( y_test, y_pred )
    print( f"\n  Accuracy hardware-exacto (Fase 1, PTQ): {acc:.4f}" )
    print( f"  Accuracy PTQ estandar TFLite (referencia): {reference_ptq_accuracy:.4f}" )
    print( f"  Diferencia: {(acc - reference_ptq_accuracy) * 100:+.2f}pp" )

    cm = confusion_matrix( y_test, y_pred )
    df_cm = pd.DataFrame( cm, index=class_names, columns=class_names )
    df_cm.to_csv( os.path.join( output_dir, "confusion_matrix_hw_sim.csv" ) )

    summary = pd.DataFrame( [ {
        "esquema": "hardware_exacto_fase1", "accuracy": acc, "n_test": len( paths_test )
    }, {
        "esquema": "ptq_tflite_estandar", "accuracy": reference_ptq_accuracy, "n_test": len( paths_test )
    } ] )
    summary.to_csv( os.path.join( output_dir, "resumen_comparacion.csv" ), index=False )

    print( f"\n  [ OK ] Resultados en: {output_dir}/" )


if __name__ == "__main__":
    repo_root    = Path( __file__ ).resolve( ).parents[ 2 ]
    dataset_root = str( repo_root / "data" / "raw" )
    model_path   = str( repo_root / "results" / "hsv" / "model_MobileNetV2_HSV_256x256.keras" )
    output_dir   = str( repo_root / "results" / "hw_quant_sim" )
    main( dataset_root, model_path, output_dir )
