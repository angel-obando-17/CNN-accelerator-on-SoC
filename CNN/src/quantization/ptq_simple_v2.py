"""
PTQ SIMPLE -- HARDWARE EXACTO, MULTIPLICADOR DE RE-CUANTIZACION REAL (Fase 4)
Trabajo de Grado - Acelerador CNN en Zynq-7020

PL implemento, verifico en simulacion (0 fallos, tb_cnn_top_bias.vhd +
tb_cnn_top_hardcore.vhd) y cerro timing a 70MHz (WNS=+0.412ns) un
multiplicador de re-cuantizacion real dentro de quant_relu.vhd -- ver
accelerator/cnn_accelerator/docs/requantization_analysis.md. Hasta ahora
(src/quantization/ptq_simple.py, Fase 3) el acelerador solo tenia un shift
aritmetico por capa, forzando el factor de escala real M=(s_w*s_in)/s_out a
la potencia de 2 mas cercana -- error de hasta 41% en una sola capa,
identificado como el cuello de botella dominante de accuracy (20.96% en
Fase 3, con el bias ya corregido). El nuevo datapath:

    accumulator_bank (INT32) -> bias_add (+bias INT32) -> quant_relu:
        (acc_con_bias * mult_int + redondeo) >> (shift + 16) -> clamp INT8 -> ReLU6

en vez de el viejo `acc_con_bias >> shift`. Es la funcion QuantizeMultiplier
estandar de TFLite/gemmlowp (descompone M = M0 * 2^-shift, M0 en [0.5,1)),
pero con mantisa de 16 bits (Q0.16 sin signo, REG_MULT offset 0x3C) en vez
de los 31 bits de TFLite -- de sobra, el error de cuantizar M0 a 16 bits es
~2^-16=0.0015%, muy por debajo del ruido propio de INT8.

Archivo nuevo y separado (mismo criterio que Fase 3): NO se toca
ptq_simple.py (queda como registro historico de Fase 3, shift-only) ni
hw_quant_sim.py (Fase 1). Se reutiliza de ambos todo lo que no depende del
multiplicador (fusion Conv+BN, cuantizacion simetrica de pesos, bias a
escala de acumulador s_w*s_in ya corregido en Fase 3, calibracion, escala
de residuo forzada por add_unit.vhd, carga del modelo). Se reimplementa
solo lo que cambia: quantize_multiplier (nueva), apply_quant_relu,
make_layer_params, build_all_params, forward_hw_sim, export_layer_table.

GAP (gap_unit.vhd) NO tiene REG_MULT -- el fix de PL fue solo dentro de
quant_relu.vhd (Paso 1), gap_unit.vhd tiene su propio acumulador y shift
independiente, sin tocar -- se mantiene shift-only, igual que en Fase 3.

Ver accelerator/cnn_accelerator/docs/requantization_analysis.md para la
especificacion completa del hardware y CNN/docs/analisis_ptq_simple_fase3.md
para el historial previo.
"""

import os
import math
import json
from pathlib import Path

import numpy as np
import pandas as pd
from sklearn.metrics import accuracy_score, confusion_matrix

from src.common.dataset import collect_file_paths, split_paths
from src.quantization.hw_quant_sim import (
    load_image, derive_blocks, fuse_conv_bn, quantize_weight_symmetric,
    build_calib_extractor, calibrate, conv2d_int, dwconv2d_int, quantize_input_batch
)
from src.quantization.ptq_simple import load_model_compat, quantize_bias_acc

INT32_MIN = -( 2 ** 31 )
INT32_MAX = ( 2 ** 31 ) - 1
MANTISSA_BITS = 16   # REG_MULT: Q0.16 sin signo, mult_int en [32768, 65536).


# QUANTIZEMULTIPLIER -- descompone M=(s_w*s_in)/s_out en M0*2^-shift, con
# M0 en [0.5,1) cuantizado a MANTISSA_BITS bits (mult_int) + shift entero
# (el mismo REG_SHIFT de siempre, 5 bits). math.frexp ya devuelve la
# mantisa en el rango exacto que necesitamos: m = mantissa * 2**exponent,
# 0.5 <= |mantissa| < 1 -- shift = -exponent porque M = mantissa / 2^shift.
def quantize_multiplier( m: float, max_shift: int ) -> tuple[ int, int ]:
    if m <= 0:
        return 0, 0

    mantissa, exponent = math.frexp( m )
    shift = -exponent
    mult_int = int( round( mantissa * ( 1 << MANTISSA_BITS ) ) )

    # Borde: si mantissa redondea a 1.0 exacto, mult_int se sale de rango
    # (2^16 en vez de <2^16) -- renormalizar a M0=0.5, shift+1 (equivalente).
    if mult_int == ( 1 << MANTISSA_BITS ):
        mult_int //= 2
        shift -= 1

    if shift < 0 or shift > max_shift:
        # REG_SHIFT es 5 bits sin signo (0..31), sin capacidad de shift
        # izquierdo -- si el M real cae fuera de ese rango, se clippea (se
        # pierde precision en esa capa, mismo tipo de compromiso que ya
        # aceptaba choose_shift() en Fase 1/3, no una regresion nueva).
        print( f"  [ WARN ] shift real {shift} fuera de rango [0,{max_shift}] -- clippeado (M={m:.6g})." )
        shift = max( 0, min( max_shift, shift ) )

    return mult_int, shift


def make_layer_params(
        conv_layer, bn_layer, depthwise: bool,
        s_in: float, s_out: float, relu_en: bool, max_shift: int
    ) -> dict[ str, object ]:

    w_fused, bias_fused = fuse_conv_bn( conv_layer, bn_layer, depthwise )
    w_q, s_w = quantize_weight_symmetric( w_fused )
    m = ( s_w * s_in ) / s_out if ( s_out > 0 and s_w > 0 and s_in > 0 ) else 0.0
    mult_int, shift = quantize_multiplier( m, max_shift )
    bias_q = quantize_bias_acc( bias_fused, s_w, s_in )
    relu6_val = int( np.clip( round( 6.0 / s_out ), 0, 127 ) ) if relu_en else 0
    return {
        "w": w_q, "bias": bias_q, "mult": mult_int, "shift": shift, "relu_en": relu_en,
        "relu6_val": relu6_val, "s_w": float( s_w ), "s_in": float( s_in ), "s_out": float( s_out )
    }


# Identica en estructura a ptq_simple.build_all_params -- se reimplementa
# aqui solo porque invoca el make_layer_params de este archivo (mult+shift
# en vez de shift solo).
def build_all_params(
        model, blocks: list[ dict[ str, object ] ],
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
        # escala calibrada -- igual que en Fase 3.
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

    # GAP -- gap_unit.vhd, sin REG_MULT, sigue shift-only (no forma parte
    # del fix de quant_relu.vhd).
    n_pixels = int( np.prod( model.get_layer( "conv_last_relu6" ).output.shape[ 1:3 ] ) )
    s_gap = stats[ "gap" ] / 127.0
    m_gap = s_last / ( n_pixels * s_gap ) if s_gap > 0 else 0
    gap_shift = max( 0, min( max_shift, int( round( -np.log2( m_gap ) ) ) ) ) if m_gap > 0 else 0
    params[ "gap" ] = { "shift": gap_shift, "s_in": float( s_last ), "s_out": float( s_gap ), "n_pixels": n_pixels }

    # Dense final -- no corre en el acelerador, PS la ejecuta en float32
    # sobre el resultado ya dequantizado del GAP.
    dense_layer = model.get_layer( "output" )
    dw, db = dense_layer.get_weights( )
    params[ "dense" ] = { "w": dw.astype( np.float64 ), "b": db.astype( np.float64 ) }

    params[ "s_image_in" ] = float( s_image_in )
    return params


# UNICO CAMBIO REAL DE DATAPATH RESPECTO A ptq_simple.apply_quant_relu:
# Paso 1 pasa de `biased >> shift` a `(biased * mult_int + redondeo) >>
# (shift+16)` -- multiplicador de punto fijo Q0.16 + redondeo round-half-up
# (el hardware real, quant_relu.vhd, no trunca -- suma 2^(shift+16-1) antes
# de desplazar). El resto (bias antes del shift, clamp, ReLU6) es identico
# a Fase 3.
def apply_quant_relu(
        acc_int64: np.ndarray, mult_int: int, shift: int, bias_q: np.ndarray,
        relu_en: bool, relu6_val: int
    ) -> np.ndarray:

    biased      = acc_int64 + bias_q
    shift_total = shift + MANTISSA_BITS
    rounding    = 1 << ( shift_total - 1 )
    product     = biased * mult_int
    shifted     = ( product + rounding ) >> shift_total
    clamped     = np.clip( shifted, -128, 127 )
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
    x = apply_quant_relu( acc, p[ "mult" ], p[ "shift" ], p[ "bias" ], True, p[ "relu6_val" ] )

    for b in blocks:
        idx = b[ "idx" ]
        block_in = x
        cur = x

        if b[ "exp_ch" ] is not None:
            p = params[ f"irb{idx}_exp" ]
            acc = conv2d_int( cur, p[ "w" ], stride=1 )
            cur = apply_quant_relu( acc, p[ "mult" ], p[ "shift" ], p[ "bias" ], True, p[ "relu6_val" ] )

        p = params[ f"irb{idx}_dw" ]
        acc = dwconv2d_int( cur, p[ "w" ], stride=b[ "s" ] )
        cur = apply_quant_relu( acc, p[ "mult" ], p[ "shift" ], p[ "bias" ], True, p[ "relu6_val" ] )

        p = params[ f"irb{idx}_pw" ]
        acc = conv2d_int( cur, p[ "w" ], stride=1 )
        cur = apply_quant_relu( acc, p[ "mult" ], p[ "shift" ], p[ "bias" ], False, 0 )

        if b[ "has_residual" ]:
            summed = block_in.astype( np.int64 ) + cur.astype( np.int64 )   # add_unit.vhd: int8+int8 crudo.
            cur = np.clip( summed, -128, 127 )

        x = cur

    p = params[ "conv_last" ]
    acc = conv2d_int( x, p[ "w" ], stride=1 )
    x = apply_quant_relu( acc, p[ "mult" ], p[ "shift" ], p[ "bias" ], True, p[ "relu6_val" ] )

    gp = params[ "gap" ]
    acc = np.sum( x.astype( np.int64 ), axis=( 1, 2 ) )
    gap_out = np.clip( acc >> gp[ "shift" ], -128, 127 )

    gap_float = gap_out.astype( np.float64 ) * gp[ "s_out" ]
    dp = params[ "dense" ]
    logits = gap_float @ dp[ "w" ] + dp[ "b" ]
    return logits


def export_layer_table( params: dict[ str, object ], blocks: list[ dict[ str, object ] ], path: str ) -> None:
    # Formato consumible por generate_layer_table.py (lado PS) -- ahora
    # incluye "mult" (REG_MULT, offset 0x3C) ademas de shift/bias/relu6_val.
    rows = [ ]

    def add_row( name: str, p: dict[ str, object ] ) -> None:
        rows.append( {
            "layer": name, "mult": p[ "mult" ], "shift": p[ "shift" ], "relu_en": p[ "relu_en" ],
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
        "layer": "gap", "mult": None, "shift": params[ "gap" ][ "shift" ], "relu_en": False, "relu6_val": 0,
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
        reference_fase1_accuracy: float = 0.1111,
        reference_fase3_accuracy: float = 0.2096,
        batch_size: int = 32
    ) -> None:

    max_shift = ( 2 ** shift_bits ) - 1

    print( "=" * 65 )
    print( "  PTQ SIMPLE -- HARDWARE EXACTO, MULTIPLICADOR REAL (Fase 4)" )
    print( "  MobileNetV2 + HSV, 256x256 -- bias + REG_MULT (Q0.16) + shift" )
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
    print( "  (simetrico, mult Q0.16 + shift, bias a escala de acumulador s_w*s_in)..." )
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
    print( f"\n  Accuracy hardware-exacto (Fase 4, mult+shift real):     {acc:.4f}" )
    print( f"  Accuracy PTQ estandar TFLite (referencia, sin HW):       {reference_ptq_accuracy:.4f}" )
    print( f"  Accuracy Fase 3 (mismo HW, shift-only):                  {reference_fase3_accuracy:.4f}" )
    print( f"  Accuracy Fase 1 (shift-only, sin bias):                  {reference_fase1_accuracy:.4f}" )
    print( f"  Diferencia vs TFLite estandar: {(acc - reference_ptq_accuracy) * 100:+.2f}pp" )
    print( f"  Diferencia vs Fase 3 (shift-only): {(acc - reference_fase3_accuracy) * 100:+.2f}pp" )

    cm = confusion_matrix( y_test, y_pred )
    df_cm = pd.DataFrame( cm, index=class_names, columns=class_names )
    df_cm.to_csv( os.path.join( output_dir, "confusion_matrix_hw_sim.csv" ) )

    summary = pd.DataFrame( [ {
        "esquema": "ptq_simple_fase4_mult_real", "accuracy": acc, "n_test": len( paths_test )
    }, {
        "esquema": "ptq_simple_fase3_shift_only", "accuracy": reference_fase3_accuracy, "n_test": len( paths_test )
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
    output_dir   = str( repo_root / "results" / "ptq_simple_v2" )
    main( dataset_root, model_path, output_dir )
