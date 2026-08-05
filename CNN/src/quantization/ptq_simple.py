"""
PTQ SIMPLE -- HARDWARE EXACTO, ORDEN REAL CORREGIDO (Fase 3)
Trabajo de Grado - Acelerador CNN en Zynq-7020

PL agrego y verifico en simulacion (ModelSim, tb_cnn_top_bias.vhd +
tb_cnn_top_hardcore.vhd, 0 fallos) un sumador de bias real en el datapath
del acelerador -- ver accelerator/cnn_accelerator/docs/bias_support.md:

    accumulator_bank (INT32) -> bias_add (+bias INT32) -> quant_relu (shift, clamp INT8, ReLU6)

El bias se suma ANTES del shift, sobre el acumulador crudo -- el orden
matematico ESTANDAR, el mismo que produce Conv+BN fusionado en float. Esto
es lo OPUESTO al orden que simulo src/quantization/hw_quant_sim.py (Fase 1,
PTQ) y la Ronda 2 de QAT (Fase 2, src/quantization/qat/): ambos sumaban el
bias DESPUES de shift+clamp+ReLU6, porque en ese momento el hardware no
tenia sumador real y ese era el unico lugar donde "cabia" sin agregar
logica. Ese compromiso le costo precision real: Fase 1 dio 11.11%
(=azar) y la mejor ronda de QAT (Fase 2) dio 19.48%, muy por debajo del
94.15% objetivo (PTQ estandar de TFLite, sin restricciones de hardware).

Con el hardware ya corregido, el orden estandar habilita usar PTQ SIMPLE
otra vez -- sin QAT, sin reentrenar nada -- fusionando Conv+BN y
cuantizando directamente el modelo de produccion normal
(src/training/train_hsv.py -> results/hsv/model_MobileNetV2_HSV_256x256.keras).
Este script mide que accuracy da eso contra el datapath hardware-exacto
que el acelerador corre HOY.

Cambio de fondo respecto a Fase 1 (no es solo mover una suma de lugar):
bias_add.vhd sumal el bias al acumulador ANTES del shift -> el bias tiene
que estar cuantizado en la escala del ACUMULADOR (s_w * s_in), no en la
escala de salida (s_out) como asumia el orden viejo. Es el mismo esquema
que usa la cuantizacion int8 estandar (TFLite: bias_scale = weight_scale *
input_scale) -- el orden real de hardware termino siendo el caso de libro,
no una aproximacion. Todo lo demas del datapath (fusion Conv+BN,
cuantizacion simetrica de pesos, shift potencia-de-2 por capa, escala del
residuo forzada por add_unit.vhd) es IDENTICO a Fase 1 y se reutiliza
directamente de hw_quant_sim.py -- solo se reimplementan aqui las 4 piezas
que dependen del orden bias-antes-del-shift: quantize_bias_acc,
make_layer_params, apply_quant_relu y build_all_params/forward_hw_sim.

Ver CNN/docs/analisis_cuantizacion_fase1.md y CNN/docs/analisis_qat_fase2.md
para el historial completo.
"""

import os
import json
import zipfile
import shutil
import tempfile
import warnings
from pathlib import Path

import numpy as np
import pandas as pd
import tensorflow as tf
from tensorflow.keras import models
from sklearn.metrics import accuracy_score, confusion_matrix

from src.common.dataset import collect_file_paths, split_paths
from src.quantization.hw_quant_sim import (
    load_image, derive_blocks, fuse_conv_bn, quantize_weight_symmetric,
    choose_shift, build_calib_extractor, calibrate, conv2d_int, dwconv2d_int,
    quantize_input_batch, export_layer_table
)

warnings.filterwarnings( "ignore" )
# hw_quant_sim.py ya desactiva TF32 (enable_tensor_float_32_execution(False))
# al importarse -- no hace falta repetirlo aqui.

INT32_MIN = -( 2 ** 31 )
INT32_MAX = ( 2 ** 31 ) - 1


# COMPATIBILIDAD DE CARGA -- el .keras de produccion trae 'quantization_config'
# en la config de cada capa (metadata de la API nativa de cuantizacion de
# Keras 3), y la version de Keras instalada ahora mismo (3.12.0) no la
# reconoce en Layer.__init__ -> models.load_model() falla con
# "Unrecognized keyword arguments passed to Dense: {'quantization_config': None}"
# incluso cargando el .keras sin tocar nada de este script (confirmado
# reproduciendolo con models.load_model directo). No es una cuantizacion
# real aplicada al modelo (siempre vale None) -- es un desfase de version
# entre el Keras que guardo el archivo y el que esta instalado ahora. Se
# despoja esa clave de config.json in-memory (el .keras original en disco
# NO se modifica) y se carga desde una copia temporal.
def _strip_quantization_config( obj ):
    if isinstance( obj, dict ):
        obj.pop( "quantization_config", None )
        for v in obj.values( ):
            _strip_quantization_config( v )
    elif isinstance( obj, list ):
        for v in obj:
            _strip_quantization_config( v )
    return obj


def load_model_compat( path: str ):
    with tempfile.TemporaryDirectory( ) as tmp_dir:
        patched_path = os.path.join( tmp_dir, "patched.keras" )
        with zipfile.ZipFile( path, "r" ) as zin:
            config = json.loads( zin.read( "config.json" ) )
            _strip_quantization_config( config )
            with zipfile.ZipFile( patched_path, "w", zipfile.ZIP_DEFLATED ) as zout:
                for item in zin.infolist( ):
                    if item.filename == "config.json":
                        zout.writestr( item, json.dumps( config ) )
                    else:
                        zout.writestr( item, zin.read( item.filename ) )
        return models.load_model( patched_path )


# CUANTIZACION DE BIAS A ESCALA DE ACUMULADOR -- unico punto real de cambio
# respecto a hw_quant_sim.quantize_bias (que usaba s_out, la escala de
# salida post-shift). bias_add.vhd suma sobre el acumulador crudo (INT32,
# escala s_w*s_in), asi que el bias tiene que vivir en esa escala.
def quantize_bias_acc( bias_float: np.ndarray, s_w: float, s_in: float ) -> np.ndarray:
    s_acc = s_w * s_in
    if s_acc <= 0:
        return np.zeros_like( bias_float, dtype=np.int64 )
    q = np.round( bias_float / s_acc )
    q_clipped = np.clip( q, INT32_MIN, INT32_MAX )
    if np.any( q != q_clipped ):
        # bias_buf.vhd es INT32 real -- si esto dispara, hay una capa cuyo
        # bias fusionado no cabe en el registro de hardware y hace falta
        # revisar la calibracion/escala de esa capa, no solo el simulador.
        print( "  [ WARN ] bias cuantizado desborda rango INT32 en al menos un canal -- revisar escalas de esa capa." )
    return q_clipped.astype( np.int64 )


def make_layer_params(
        conv_layer, bn_layer, depthwise: bool,
        s_in: float, s_out: float, relu_en: bool, max_shift: int
    ) -> dict[ str, object ]:

    w_fused, bias_fused = fuse_conv_bn( conv_layer, bn_layer, depthwise )
    w_q, s_w = quantize_weight_symmetric( w_fused )
    shift    = choose_shift( s_w, s_in, s_out, max_shift )
    bias_q   = quantize_bias_acc( bias_fused, s_w, s_in )
    relu6_val = int( np.clip( round( 6.0 / s_out ), 0, 127 ) ) if relu_en else 0
    return {
        "w": w_q, "bias": bias_q, "shift": shift, "relu_en": relu_en,
        "relu6_val": relu6_val, "s_w": float( s_w ), "s_in": float( s_in ), "s_out": float( s_out )
    }


# Identica en estructura a hw_quant_sim.build_all_params (misma arquitectura,
# mismo hilo de escalas entre capas/bloques) -- se reimplementa aqui solo
# porque tiene que invocar el make_layer_params de este archivo (escala de
# bias distinta), no el de hw_quant_sim.py.
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


# ORDEN REAL DE HARDWARE: bias_add.vhd suma el bias sobre el acumulador
# crudo, ANTES del shift/clamp/ReLU6 (accumulator_bank -> bias_add ->
# quant_relu, ver bias_support.md). Unica diferencia real contra
# hw_quant_sim.apply_quant_relu -- ahi la suma estaba DESPUES del shift,
# unico orden posible cuando el hardware todavia no tenia sumador real.
def apply_quant_relu(
        acc_int64: np.ndarray, shift: int, bias_q: np.ndarray, relu_en: bool, relu6_val: int
    ) -> np.ndarray:

    biased  = acc_int64 + bias_q
    shifted = biased >> shift
    clamped = np.clip( shifted, -128, 127 )
    if relu_en:
        out = np.where( clamped < 0, 0, np.where( clamped > relu6_val, relu6_val, clamped ) )
    else:
        out = clamped
    return out.astype( np.int64 )


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
        reference_fase1_accuracy: float = 0.1111,
        batch_size: int = 32
    ) -> None:

    max_shift = ( 2 ** shift_bits ) - 1

    print( "=" * 65 )
    print( "  PTQ SIMPLE -- HARDWARE EXACTO, ORDEN REAL CORREGIDO (Fase 3)" )
    print( "  MobileNetV2 + HSV, 256x256 -- bias antes del shift (bias_add.vhd)" )
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
    model = load_model_compat( model_path )
    blocks = derive_blocks( cfg, max_ch )

    print( "\n  Calibrando escalas de activacion (imagenes de train, con HSV)..." )
    extractor, names = build_calib_extractor( model, blocks )
    calib_paths = paths_train[ :n_calib ]
    calib_images = np.array( [ load_image( p, resolution ) for p in calib_paths ], dtype=np.float32 )
    s_image_in, stats = calibrate( extractor, names, calib_images )
    print( f"  Escala de entrada (imagen): {s_image_in / 127.0:.6f}" )

    print( "\n  Fusionando Conv+BN y cuantizando pesos/bias/activaciones" )
    print( "  (simetrico, shift potencia-2, bias a escala de acumulador s_w*s_in)..." )
    params = build_all_params( model, blocks, s_image_in / 127.0, stats, max_shift )

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
    print( f"\n  Accuracy hardware-exacto (Fase 3, PTQ simple, bias corregido): {acc:.4f}" )
    print( f"  Accuracy PTQ estandar TFLite (referencia, sin restricciones de HW): {reference_ptq_accuracy:.4f}" )
    print( f"  Accuracy Fase 1 (mismo HW, orden de bias VIEJO):                   {reference_fase1_accuracy:.4f}" )
    print( f"  Diferencia vs TFLite estandar: {(acc - reference_ptq_accuracy) * 100:+.2f}pp" )
    print( f"  Diferencia vs Fase 1 (orden viejo): {(acc - reference_fase1_accuracy) * 100:+.2f}pp" )

    cm = confusion_matrix( y_test, y_pred )
    df_cm = pd.DataFrame( cm, index=class_names, columns=class_names )
    df_cm.to_csv( os.path.join( output_dir, "confusion_matrix_hw_sim.csv" ) )

    summary = pd.DataFrame( [ {
        "esquema": "ptq_simple_fase3_bias_corregido", "accuracy": acc, "n_test": len( paths_test )
    }, {
        "esquema": "hardware_exacto_fase1_bias_viejo", "accuracy": reference_fase1_accuracy, "n_test": len( paths_test )
    }, {
        "esquema": "ptq_tflite_estandar", "accuracy": reference_ptq_accuracy, "n_test": len( paths_test )
    } ] )
    summary.to_csv( os.path.join( output_dir, "resumen_comparacion.csv" ), index=False )

    print( f"\n  [ OK ] Resultados en: {output_dir}/" )


if __name__ == "__main__":
    repo_root    = Path( __file__ ).resolve( ).parents[ 2 ]
    dataset_root = str( repo_root / "data" / "raw" )
    model_path   = str( repo_root / "results" / "hsv" / "model_MobileNetV2_HSV_256x256.keras" )
    output_dir   = str( repo_root / "results" / "ptq_simple" )
    main( dataset_root, model_path, output_dir )
