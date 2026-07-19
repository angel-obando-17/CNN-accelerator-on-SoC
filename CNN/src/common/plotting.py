import os
import re

import matplotlib
matplotlib.use( "Agg" )
import seaborn as sns
import matplotlib.pyplot as plt
import numpy as np
import tensorflow as tf

def plot_cm( 
        cm: np.ndarray,
        class_names: list[ str ], 
        label: str, 
        output_dir: str ) -> None:

    short = [ re.sub( r"Tomato_+", "", n ) for n in class_names ]
    n = len( short )
    fig, ax = plt.subplots( figsize=( max( 8, n ), max( 6, n ) ) )
    
    sns.heatmap( 
            cm, 
            annot=True, 
            fmt="d", 
            cmap="Blues", 
            xticklabels=short, 
            yticklabels=short, 
            ax=ax 
        )
    
    ax.set_xlabel( "Predicho" )
    ax.set_ylabel( "Real" )
    ax.set_title( f"Confusion Matrix — { label }" )
    plt.tight_layout( )

    fig.savefig( 
            os.path.join( output_dir, f"cm_{ label }.png" ), 
            dpi=150 
        )
    
    plt.close( fig )

def plot_training_curves( 
        history: tf.keras.callbacks.History, 
        label: str, 
        output_dir: str ) -> None:

    fig, axes = plt.subplots( 1, 2, figsize=( 12, 4 ) )
    axes[ 0 ].plot( history.history[ "accuracy"], label="Train" )
    axes[ 0 ].plot( history.history[ "val_accuracy"], label="Val" )
    axes[ 0 ].set_title( f"Accuracy — { label }" )
    axes[ 0 ].set_xlabel( "Época" ); axes[ 0 ].legend( )
    axes[ 1 ].plot( history.history[ "loss" ],     label="Train" )
    axes[ 1 ].plot( history.history[ "val_loss" ],  label="Val" )
    axes[ 1 ].set_title( f"Loss — { label }" )
    axes[ 1 ].set_xlabel( "Época" ); axes[ 1 ].legend( )
    plt.tight_layout( )
    
    fig.savefig( 
            os.path.join(output_dir, f"training_{ label }.png" ), 
            dpi=150 
        )
    
    plt.close( fig )