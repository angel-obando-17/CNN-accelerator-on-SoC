import tensorflow as tf
from tensorflow.keras import layers, models

def build_lenet( input_size: int, num_classes: int ) -> tf.keras.Model:

    inp = layers.Input( shape=( input_size, input_size, 3 ) )
    x   = layers.Conv2D( 32, 5, padding="same", activation="relu", name="conv1" )( inp )
    x   = layers.MaxPooling2D( 2, name="pool1" )( x )
    x   = layers.Conv2D( 64, 5, padding="same", activation="relu", name="conv2" )( x )
    x   = layers.MaxPooling2D( 2, name="pool2" )( x )
    x   = layers.Conv2D( 64, 3, padding="same", activation="relu", name="conv3" )( x )
    x   = layers.MaxPooling2D( 2, name="pool3" )( x )
    x   = layers.GlobalAveragePooling2D( name="gap" )( x )
    x   = layers.Dense( 128, activation="relu", name="fc1" )( x )
    x   = layers.Dense( num_classes, activation="softmax", name="output" )( x )

    return models.Model( inp, x, name="LeNet_adapted" )
