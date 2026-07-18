import tensorflow as tf
from tensorflow.keras import layers, models

def dw_block( 
        x: tf.Tensor, 
        filters: int, 
        strides: int = 1, 
        name_prefix: str = "dw" 
    ) -> tf.Tensor:
    
    #Bloque DW + PW de MobileNetV1.
    x = layers.DepthwiseConv2D(
                    3,
                    strides=strides,
                    padding="same",
                    use_bias=False,
                    name=f"{ name_prefix }_dw"
               )( x )

    x = layers.BatchNormalization( name=f"{ name_prefix }_dw_bn" )( x )
    x = layers.ReLU( name=f"{ name_prefix }_dw_relu" )( x )

    x = layers.Conv2D(
                    filters,
                    1,
                    padding="same",
                    use_bias=False,
                    name=f"{ name_prefix }_pw"
               )( x )

    x = layers.BatchNormalization( name=f"{ name_prefix }_pw_bn" )( x )
    x = layers.ReLU( name=f"{ name_prefix }_pw_relu" )( x )
    return x

def build_mobilenetv1( input_size: int, num_classes: int, max_ch: int = 64 ) -> tf.keras.Model:
    #MobileNetV1.
    inp = layers.Input( shape=( input_size, input_size, 3 ) )
    x   = layers.Conv2D( min( 32, max_ch ), 3, strides=2, padding="same", use_bias=False, name="conv1" )( inp )
    x   = layers.BatchNormalization( name="conv1_bn" )( x )
    x   = layers.ReLU( name="conv1_relu" )( x )
    cfg = [ ( 64, 1 ),
            ( 64, 2 ),
            ( 64, 1 ),
            ( 64, 2 ),
            ( 64, 1 ),
            ( 64, 2 ),
            ( 64, 1 ),
            ( 64, 1 ),
            ( 64, 1 ),
            ( 64, 1 ),
            ( 64, 1 ),
            ( 64, 2 ),
            ( 64, 1 ) ]

    for i, ( ch, s ) in enumerate( cfg ):
        x = dw_block( x, min( ch, max_ch ), strides=s, name_prefix=f"dw{ i + 1 }" )

    x = layers.GlobalAveragePooling2D( name="gap" )( x )
    x = layers.Dense( num_classes, activation="softmax", name="output" )( x )
    return models.Model( inp, x, name=f"MobileNetV1_HSV_{ input_size }" )
