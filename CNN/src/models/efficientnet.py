import tensorflow as tf
from tensorflow.keras import layers, models

def se_block( 
        x: tf.Tensor, 
        se_ratio: int = 4, 
        name_prefix: str = "se" 
    ) -> tf.Tensor:
    
    #Squeeze-and-Excitation block.
    ch    = x.shape[ -1 ]
    se_ch = max( 1, ch // se_ratio )
    se    = layers.GlobalAveragePooling2D( name=f"{name_prefix}_gap" )( x )
    se    = layers.Reshape( ( 1, 1, ch ), name=f"{name_prefix}_reshape" )( se )
    se    = layers.Conv2D( se_ch, 1, activation="relu", name=f"{name_prefix}_fc1" )( se )
    se    = layers.Conv2D( ch,    1, activation="sigmoid", name=f"{name_prefix}_fc2" )( se )

    return layers.Multiply( name=f"{name_prefix}_mul" )( [ x, se ] )

def mbconv_block(
        x: tf.Tensor,
        filters: int,
        strides: int = 1,
        expand_ratio: int = 2,
        se_ratio: int = 4,
        name_prefix: str = "mb",
        max_ch: int = 64
    ) -> tf.Tensor:

    in_ch  = x.shape[ -1 ]
    exp_ch = min( in_ch * expand_ratio, max_ch )

    if expand_ratio != 1:

        x_exp = layers.Conv2D(
                            exp_ch,
                            1,
                            padding="same",
                            use_bias=False,
                            name=f"{name_prefix}_exp"
                          )( x )

        x_exp = layers.BatchNormalization( name=f"{name_prefix}_exp_bn" )( x_exp )
        x_exp = layers.Activation( "swish", name=f"{name_prefix}_exp_swish" )( x_exp )
    else:
        x_exp = x

    x_dw = layers.DepthwiseConv2D(
                        3,
                        strides=strides,
                        padding="same",
                        use_bias=False,
                        name=f"{name_prefix}_dw"
                     )( x_exp )

    x_dw = layers.BatchNormalization( name=f"{name_prefix}_dw_bn" )( x_dw )
    x_dw = layers.Activation( "swish", name=f"{name_prefix}_dw_swish" )( x_dw )

    x_se = se_block( x_dw, se_ratio=se_ratio, name_prefix=f"{name_prefix}_se" )

    x_pw = layers.Conv2D(
                        filters,
                        1,
                        padding="same",
                        use_bias=False,
                        name=f"{name_prefix}_pw"
                     )( x_se )

    x_pw = layers.BatchNormalization( name=f"{name_prefix}_pw_bn" )( x_pw )

    if strides == 1 and in_ch == filters:
        return layers.Add( name=f"{name_prefix}_add" )( [ x, x_pw ] )

    return x_pw


def build_efficientnet( 
        input_size: int, 
        num_classes: int, 
        max_ch: int = 64 
    ) -> tf.keras.Model:

    inp = layers.Input( shape=( input_size, input_size, 3 ) )

    x   = layers.Conv2D(
                        min( 32, max_ch ),
                        3,
                        strides=2,
                        padding="same",
                        use_bias=False,
                        name="stem_conv"
                    )( inp )

    x   = layers.BatchNormalization( name="stem_bn" )( x )
    x   = layers.Activation( "swish", name="stem_swish" )( x )

    cfg = [
        ( 1, 16, 1 ),
        ( 2, 24, 2 ),
        ( 2, 24, 1 ),
        ( 2, 40, 2 ),
        ( 2, 40, 1 ),
        ( 2, 64, 2 ),
        ( 2, 64, 1 ),
        ( 2, 64, 1 ), ]

    for i, ( t, c, s ) in enumerate( cfg ):
        x = mbconv_block(
                x,
                min( c, max_ch ),
                strides=s,
                expand_ratio=t,
                name_prefix=f"mb{i+1}",
                max_ch=max_ch
            )

    x = layers.Conv2D( min( 64, max_ch ), 1, padding="same", use_bias=False, name="head_conv" )( x )
    x = layers.BatchNormalization( name="head_bn" )( x )
    x = layers.Activation( "swish", name="head_swish" )( x )
    x = layers.GlobalAveragePooling2D( name="gap" )( x )
    x = layers.Dense( num_classes, activation="softmax", name="output" )( x )

    return models.Model( inp, x, name="EfficientNet_reduced" )
