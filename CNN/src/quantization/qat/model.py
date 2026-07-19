"""
MobileNetV2 QAT -- misma arquitectura/nombres de capa que
src/models/mobilenetv2.py (necesario para que hw_quant_sim.py pueda
cargar este modelo y hacer model.get_layer(nombre) sin cambios), pero
simulando durante el entrenamiento el orden real del hardware en cada
etapa Conv+BN(+ReLU6): escala antes de shift/clamp/ReLU6, bias despues
(ver HardwareOrderScaleQuant/QuantizedBiasAdd en layers.py y
apply_quant_relu en hw_quant_sim.py), y forzando en los bloques con
residual que la proyeccion comparta la escala de la entrada del bloque
(add_unit.vhd no rescala, ver s_out_block en
hw_quant_sim.py::build_all_params).

Cada etapa devuelve (tensor, eff_scale) -- eff_scale se propaga de bloque
en bloque para poder forzarla en las proyecciones residuales.
"""

import tensorflow as tf
from tensorflow.keras import layers, models

from src.quantization.qat.layers import (
    FakeQuantConv2D,
    FakeQuantDepthwiseConv2D,
    PowerOfTwoActQuant,
    HardwareOrderScaleQuant,
    QuantizedBiasAdd,
    ReclampToScale
)


def qat_conv_stage(
        x: tf.Tensor,
        filters: int | None,
        kernel_size: int,
        strides: int,
        depthwise: bool,
        relu_enabled: bool,
        name_prefix: str,
        max_shift: int,
        forced_eff_scale: tf.Tensor | None = None
    ) -> tuple[ tf.Tensor, tf.Tensor ]:

    if depthwise:
        conv_out = FakeQuantDepthwiseConv2D( kernel_size, strides=strides, name=name_prefix )( x )
    else:
        conv_out = FakeQuantConv2D( filters, kernel_size, strides=strides, name=name_prefix )( x )

    bn_layer = HardwareOrderScaleQuant( relu_enabled=relu_enabled, max_shift=max_shift, name=f"{ name_prefix }_bn" )

    if forced_eff_scale is not None:
        pre_bias, bias, eff_scale = bn_layer( conv_out, forced_eff_scale=forced_eff_scale )
    else:
        pre_bias, bias, eff_scale = bn_layer( conv_out )

    if relu_enabled:
        # Nodo separado solo para que hw_quant_sim.py pueda calibrar en
        # "{name_prefix}_relu6" -- mismo tensor que pre_bias, sin cambios.
        pre_bias = layers.Activation( "linear", name=f"{ name_prefix }_relu6" )( pre_bias )

    x_out = QuantizedBiasAdd( name=f"{ name_prefix }_biasadd" )( pre_bias, bias, eff_scale )
    return x_out, eff_scale


def qat_inverted_residual_block(
        x: tf.Tensor,
        x_scale: tf.Tensor,
        filters: int,
        strides: int = 1,
        expand_ratio: int = 2,
        name_prefix: str = "irb",
        max_ch: int = 64,
        max_shift: int = 31
    ) -> tuple[ tf.Tensor, tf.Tensor ]:

    in_ch  = x.shape[ -1 ]
    exp_ch = min( in_ch * expand_ratio, max_ch )

    if expand_ratio != 1:
        x_exp, _ = qat_conv_stage( x, exp_ch, 1, 1, False, True, f"{ name_prefix }_exp", max_shift )
    else:
        x_exp = x

    x_dw, _ = qat_conv_stage( x_exp, None, 3, strides, True, True, f"{ name_prefix }_dw", max_shift )

    has_residual = ( strides == 1 and in_ch == filters )

    if has_residual:
        # add_unit.vhd no rescala -- la proyeccion se fuerza a la MISMA
        # escala de la entrada del bloque, no a una propia calibrada.
        x_pw, _ = qat_conv_stage(
                x_dw, filters, 1, 1, False, False, f"{ name_prefix }_pw", max_shift,
                forced_eff_scale=x_scale
            )
        added = layers.Add( name=f"{ name_prefix }_add" )( [ x, x_pw ] )
        out   = ReclampToScale( name=f"{ name_prefix }_reclamp" )( added, x_scale )
        return out, x_scale

    x_pw, pw_scale = qat_conv_stage( x_dw, filters, 1, 1, False, False, f"{ name_prefix }_pw", max_shift )
    return x_pw, pw_scale


def build_mobilenetv2_qat(
        input_size: int,
        num_classes: int,
        max_ch: int = 64,
        max_shift: int = 31
    ) -> tf.keras.Model:

    inp = layers.Input( shape=( input_size, input_size, 3 ) )

    x, x_scale = qat_conv_stage( inp, min( 32, max_ch ), 3, 2, False, True, "conv1", max_shift )

    cfg = [ ( 1, 16, 1 ),
            ( 2, 24, 2 ),
            ( 2, 24, 1 ),
            ( 2, 32, 2 ),
            ( 2, 32, 1 ),
            ( 2, 64, 2 ),
            ( 2, 64, 1 ),
            ( 2, 64, 1 ),
            ( 2, 64, 1 ), ]

    for i, ( t, c, s ) in enumerate( cfg ):
        x, x_scale = qat_inverted_residual_block(
                x, x_scale, min( c, max_ch ), strides=s, expand_ratio=t,
                name_prefix=f"irb{ i+1 }", max_ch=max_ch, max_shift=max_shift
            )

    x, x_scale = qat_conv_stage( x, min( 64, max_ch ), 1, 1, False, True, "conv_last", max_shift )

    x = layers.GlobalAveragePooling2D( name="gap" )( x )
    x = PowerOfTwoActQuant( max_shift=max_shift, init_range=1.0, name="gap_quant" )( x )
    x = layers.Dense( num_classes, activation="softmax", name="output" )( x )

    return models.Model( inp, x, name=f"MobileNetV2_QAT_{ input_size }" )
