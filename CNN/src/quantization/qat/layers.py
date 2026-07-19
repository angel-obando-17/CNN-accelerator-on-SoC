"""
Capas de fake-quantization para QAT hardware-aware.

Ronda 2 -- ahora SI simula el orden real del hardware durante el forward
pass de entrenamiento (ver apply_quant_relu en hw_quant_sim.py):
Conv (sin bias) -> escala BN (sin centrar) -> shift+clamp int8 -> ReLU6 ->
+bias cuantizado -> re-clamp. La Ronda 1 aplicaba BN completo (con centrado
+beta) ANTES de ReLU6, como en entrenamiento estandar -- eso dejo que
ReLU6 recortara una distribucion ya centrada, distinto de lo que hace el
hardware real (que no tiene forma de centrar antes del ReLU6, porque el
MAC no tiene sumador de bias). Resultado medido de la Ronda 1: 92.81% en
float32 con ruido fake-quant, pero solo 10-11% bajo hw_quant_sim.py exacto
-- la red se volvio robusta al problema equivocado. Ver conversacion para
el diagnostico completo.

HardwareOrderScaleQuant reemplaza BatchNormalization+ReLU6: aplica solo la
escala (gamma/std) antes de shift/clamp/ReLU6, y devuelve el bias
(beta-mean*scale) por separado para que QuantizedBiasAdd lo sume DESPUES,
en el punto exacto donde el PS lo sumaria sobre el resultado ya cuantizado
del acelerador.

Ronda 3 -- agrega la restriccion de residual-forzado-a-la-misma-escala
(add_unit.vhd no rescala, ver s_out_block en hw_quant_sim.py::
build_all_params): en los bloques con conexion residual, la proyeccion
(_pw) ya no elige su propia escala via EMA, se le fuerza la MISMA escala
de la entrada del bloque (HardwareOrderScaleQuant.call(forced_eff_scale=..)).
Despues de la suma residual se re-clampea a esa misma grilla (ReclampToScale),
igual que hace forward_hw_sim tras sumar block_in+cur.

Resultado medido Ronda 2 (orden correcto, SIN esta restriccion): 19.48%
con bias / 16.74% sin bias bajo hw_quant_sim.py exacto (vs. 10-11% de la
Ronda 1) -- mejora real pero insuficiente. Esta es la ultima ronda antes
de evaluar modificar el hardware.
"""

import keras
import tensorflow as tf
from tensorflow.keras import layers


def fake_quantize_weight( w: tf.Tensor ) -> tf.Tensor:
    #Cuantizacion simetrica int8 por-tensor con straight-through estimator.
    max_abs = tf.stop_gradient( tf.reduce_max( tf.abs( w ) ) )
    scale   = tf.maximum( max_abs, 1e-8 ) / 127.0
    w_q     = tf.clip_by_value( tf.round( w / scale ), -127.0, 127.0 )
    w_dq    = w_q * scale
    return w + tf.stop_gradient( w_dq - w )


@keras.saving.register_keras_serializable( package="qat_layers" )
class FakeQuantConv2D( layers.Layer ):

    def __init__( self, filters: int, kernel_size: int, strides: int = 1, **kwargs ):
        super( ).__init__( **kwargs )
        self.filters     = filters
        self.kernel_size = kernel_size
        self.strides     = strides

    def get_config( self ) -> dict[ str, object ]:
        config = super( ).get_config( )
        config.update( { "filters": self.filters, "kernel_size": self.kernel_size, "strides": self.strides } )
        return config

    def build( self, input_shape: tf.TensorShape ) -> None:
        cin = int( input_shape[ -1 ] )
        self.kernel = self.add_weight(
                name="kernel",
                shape=( self.kernel_size, self.kernel_size, cin, self.filters ),
                initializer="glorot_uniform",
                trainable=True
            )

    def call( self, inputs: tf.Tensor ) -> tf.Tensor:
        w_fq = fake_quantize_weight( self.kernel )
        return tf.nn.conv2d( inputs, w_fq, strides=[ 1, self.strides, self.strides, 1 ], padding="SAME" )


@keras.saving.register_keras_serializable( package="qat_layers" )
class FakeQuantDepthwiseConv2D( layers.Layer ):

    def __init__( self, kernel_size: int, strides: int = 1, **kwargs ):
        super( ).__init__( **kwargs )
        self.kernel_size = kernel_size
        self.strides     = strides

    def get_config( self ) -> dict[ str, object ]:
        config = super( ).get_config( )
        config.update( { "kernel_size": self.kernel_size, "strides": self.strides } )
        return config

    def build( self, input_shape: tf.TensorShape ) -> None:
        cin = int( input_shape[ -1 ] )
        self.kernel = self.add_weight(
                name="kernel",
                shape=( self.kernel_size, self.kernel_size, cin, 1 ),
                initializer="glorot_uniform",
                trainable=True
            )

    def call( self, inputs: tf.Tensor ) -> tf.Tensor:
        w_fq = fake_quantize_weight( self.kernel )
        return tf.nn.depthwise_conv2d( inputs, w_fq, strides=[ 1, self.strides, self.strides, 1 ], padding="SAME" )


@keras.saving.register_keras_serializable( package="qat_layers" )
class PowerOfTwoActQuant( layers.Layer ):
    #Cuantiza la activacion a una escala forzada a potencia-de-2, con EMA de rango y STE.

    def __init__(
            self,
            max_shift: int = 31,
            ema_decay: float = 0.99,
            init_range: float = 6.0,
            **kwargs
        ):
        super( ).__init__( **kwargs )
        self.max_shift  = max_shift
        self.ema_decay  = ema_decay
        self.init_range = init_range

    def get_config( self ) -> dict[ str, object ]:
        config = super( ).get_config( )
        config.update( {
            "max_shift": self.max_shift, "ema_decay": self.ema_decay, "init_range": self.init_range
        } )
        return config

    def build( self, input_shape: tf.TensorShape ) -> None:
        self.ema_max = self.add_weight(
                name="ema_max",
                shape=( ),
                dtype=tf.float32,
                initializer=tf.keras.initializers.Constant( self.init_range ),
                trainable=False
            )

    def call( self, inputs: tf.Tensor, training: bool | None = None ) -> tf.Tensor:
        if training:
            batch_max = tf.reduce_max( tf.abs( inputs ) )
            self.ema_max.assign( self.ema_decay * self.ema_max + ( 1.0 - self.ema_decay ) * batch_max )

        scale_ideal = tf.maximum( self.ema_max, 1e-8 ) / 127.0
        shift       = tf.clip_by_value(
                tf.round( -tf.math.log( scale_ideal ) / tf.math.log( 2.0 ) ),
                0.0, float( self.max_shift )
            )
        eff_scale = tf.pow( 2.0, -shift )

        x_q  = tf.clip_by_value( tf.round( inputs / eff_scale ), -128.0, 127.0 )
        x_dq = x_q * eff_scale
        return inputs + tf.stop_gradient( x_dq - inputs )


@keras.saving.register_keras_serializable( package="qat_layers" )
class HardwareOrderScaleQuant( layers.Layer ):
    #Reemplaza BatchNormalization+ReLU6 con el orden real de hardware.
    #Aplica SOLO la escala (gamma/std) sobre la salida cruda del conv, antes
    #de simular shift+clamp int8 (+ReLU6 si aplica) -- el bias (beta -
    #mean*scale) NO se suma aqui, queda en self.last_bias/self.last_eff_scale
    #para que el bloque que arma el modelo lo sume DESPUES via
    #QuantizedBiasAdd, replicando que el MAC no tiene sumador de bias.
    #Expone gamma/beta/moving_mean/moving_variance/epsilon con los mismos
    #nombres que BatchNormalization para que hw_quant_sim.py::fuse_conv_bn
    #siga funcionando sin cambios.

    def __init__(
            self,
            relu_enabled: bool,
            max_shift: int = 31,
            momentum: float = 0.99,
            epsilon: float = 1e-3,
            ema_decay: float = 0.99,
            **kwargs
        ):
        super( ).__init__( **kwargs )
        self.relu_enabled = relu_enabled
        self.max_shift    = max_shift
        self.momentum     = momentum
        self.epsilon      = epsilon
        self.ema_decay    = ema_decay

    def get_config( self ) -> dict[ str, object ]:
        config = super( ).get_config( )
        config.update( {
            "relu_enabled": self.relu_enabled, "max_shift": self.max_shift,
            "momentum": self.momentum, "epsilon": self.epsilon, "ema_decay": self.ema_decay
        } )
        return config

    def build( self, input_shape: tf.TensorShape ) -> None:
        ch = int( input_shape[ -1 ] )
        self.gamma = self.add_weight( name="gamma", shape=( ch, ), initializer="ones", trainable=True )
        self.beta  = self.add_weight( name="beta", shape=( ch, ), initializer="zeros", trainable=True )
        self.moving_mean = self.add_weight( name="moving_mean", shape=( ch, ), initializer="zeros", trainable=False )
        self.moving_variance = self.add_weight( name="moving_variance", shape=( ch, ), initializer="ones", trainable=False )
        self.ema_max = self.add_weight(
                name="ema_max", shape=( ),
                initializer=tf.keras.initializers.Constant( 1.0 ), trainable=False
            )

    def call(
            self,
            inputs: tf.Tensor,
            forced_eff_scale: tf.Tensor | None = None,
            training: bool | None = None
        ) -> tf.Tensor:

        axes = list( range( len( inputs.shape ) - 1 ) )

        if training:
            batch_mean, batch_var = tf.nn.moments( inputs, axes=axes )
            self.moving_mean.assign( self.momentum * self.moving_mean + ( 1.0 - self.momentum ) * batch_mean )
            self.moving_variance.assign( self.momentum * self.moving_variance + ( 1.0 - self.momentum ) * batch_var )
            mean, var = batch_mean, batch_var
        else:
            mean, var = self.moving_mean, self.moving_variance

        scale    = self.gamma / tf.sqrt( var + self.epsilon )
        bias     = self.beta - mean * scale
        x_scaled = inputs * scale

        if forced_eff_scale is not None:
            # Bloque residual: add_unit.vhd no rescala, esta capa NO elige
            # su propia escala -- usa la de la entrada del bloque tal cual.
            eff_scale = forced_eff_scale
        else:
            if training:
                batch_max = tf.reduce_max( tf.abs( x_scaled ) )
                self.ema_max.assign( self.ema_decay * self.ema_max + ( 1.0 - self.ema_decay ) * batch_max )

            scale_ideal = tf.maximum( self.ema_max, 1e-8 ) / 127.0
            shift = tf.clip_by_value(
                    tf.round( -tf.math.log( scale_ideal ) / tf.math.log( 2.0 ) ),
                    0.0, float( self.max_shift )
                )
            eff_scale = tf.pow( 2.0, -shift )

        x_q     = tf.clip_by_value( tf.round( x_scaled / eff_scale ), -128.0, 127.0 )
        x_dq    = x_q * eff_scale
        x_quant = x_scaled + tf.stop_gradient( x_dq - x_scaled )

        if self.relu_enabled:
            relu6_grid = tf.round( 6.0 / eff_scale ) * eff_scale
            x_out = tf.clip_by_value( x_quant, 0.0, relu6_grid )
        else:
            x_out = x_quant

        # bias/eff_scale se devuelven como salidas reales de la capa (no como
        # atributos guardados en self) -- Keras 3 traza cada llamada en un
        # FuncGraph aislado para inferir shapes, y un tensor guardado en self
        # durante esa traza queda fuera de alcance para capas posteriores.
        return x_out, bias, eff_scale


@keras.saving.register_keras_serializable( package="qat_layers" )
class QuantizedBiasAdd( layers.Layer ):
    #Suma el bias DESPUES de shift/clamp/ReLU6 (orden real de hardware, ver
    #apply_quant_relu en hw_quant_sim.py) y re-clampea a la grilla int8 de
    #eff_scale. Sin pesos propios -- bias/eff_scale llegan como tensores
    #calculados por HardwareOrderScaleQuant.

    def call( self, x: tf.Tensor, bias: tf.Tensor, eff_scale: tf.Tensor ) -> tf.Tensor:
        bias_dq  = tf.round( bias / eff_scale ) * eff_scale
        bias_q   = bias + tf.stop_gradient( bias_dq - bias )
        x_biased = x + bias_q
        lo = -128.0 * eff_scale
        hi = 127.0 * eff_scale
        return tf.clip_by_value( x_biased, lo, hi )


@keras.saving.register_keras_serializable( package="qat_layers" )
class ReclampToScale( layers.Layer ):
    #Re-clampea a la grilla int8 de eff_scale despues de una suma residual
    #(forward_hw_sim en hw_quant_sim.py: summed=block_in+cur; cur=clip(
    #summed,-128,127)). Sin pesos propios -- no hace falta redondear, la
    #suma de dos valores ya alineados a eff_scale sigue en esa grilla.

    def call( self, x: tf.Tensor, eff_scale: tf.Tensor ) -> tf.Tensor:
        lo = -128.0 * eff_scale
        hi = 127.0 * eff_scale
        x_c = tf.clip_by_value( x, lo, hi )
        return x + tf.stop_gradient( x_c - x )
