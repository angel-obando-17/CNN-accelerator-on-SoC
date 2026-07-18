import tensorflow as tf
from tensorflow.keras import layers, models

def inverted_residual_block(
        x: tf.Tensor,
        filters: int,
        strides: int = 1,
        expand_ratio: int = 2,
        name_prefix: str = "irb",
        max_ch: int = 64
    ) -> tf.Tensor:
    #Bloque invertido de MobileNetV2.
    in_ch  = x.shape[ -1 ]
    exp_ch = min( in_ch * expand_ratio, max_ch )

    if expand_ratio != 1:

        x_exp = layers.Conv2D(
                            exp_ch,
                            1,
                            padding="same",
                            use_bias=False,
                            name=f"{ name_prefix }_exp"
                          )( x )

        x_exp = layers.BatchNormalization( name=f"{ name_prefix }_exp_bn" )( x_exp )
        x_exp = layers.ReLU( 6.0, name=f"{ name_prefix }_exp_relu6" )( x_exp )
    else:
        x_exp = x

    x_dw = layers.DepthwiseConv2D(
                        3,
                        strides=strides,
                        padding="same",
                        use_bias=False,
                        name=f"{ name_prefix }_dw"
                     )( x_exp )

    x_dw = layers.BatchNormalization( name=f"{ name_prefix }_dw_bn" )( x_dw )
    x_dw = layers.ReLU( 6.0, name=f"{ name_prefix }_dw_relu6" )( x_dw )

    x_pw = layers.Conv2D(
                        filters,
                        1,
                        padding="same",
                        use_bias=False,
                        name=f"{ name_prefix }_pw"
                     )( x_dw )

    x_pw = layers.BatchNormalization( name=f"{ name_prefix }_pw_bn" )( x_pw )

    if strides == 1 and in_ch == filters:
        return layers.Add( name=f"{ name_prefix }_add" )( [ x, x_pw ] )

    return x_pw

def build_mobilenetv2(
        input_size: int,
        num_classes: int,
        max_ch: int = 64
    ) -> tf.keras.Model:

    inp = layers.Input( shape=( input_size, input_size, 3 ) )

    x   = layers.Conv2D(
                        min( 32, max_ch),
                        3,
                        strides=2,
                        padding="same",
                        use_bias=False,
                        name="conv1"
                    )( inp )

    x   = layers.BatchNormalization( name="conv1_bn" )( x )
    x   = layers.ReLU( 6.0, name="conv1_relu6" )( x )

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
        x = inverted_residual_block(
                x,
                min( c, max_ch ),
                strides=s,
                expand_ratio=t,
                name_prefix=f"irb{ i+1 }",
                max_ch=max_ch
            )

    x = layers.Conv2D(
                    min( 64, max_ch ),
                    1,
                    padding="same",
                    use_bias=False,
                    name="conv_last"
                  )( x )

    x = layers.BatchNormalization( name="conv_last_bn" )( x )
    x = layers.ReLU( 6.0, name="conv_last_relu6" )( x )
    x = layers.GlobalAveragePooling2D( name="gap" )( x )
    x = layers.Dense( num_classes, activation="softmax", name="output" )( x )

    return models.Model( inp, x, name=f"MobileNetV2_HSV_{ input_size }" )
