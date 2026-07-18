import os
import time

import numpy as np
import cv2
from typing import Callable
from sklearn.model_selection import train_test_split

import tensorflow as tf

class Timer:
    def __init__( self, label ):
        self.label = label
    def __enter__( self ):
        self.t0 = time.perf_counter( )
        return self
    def __exit__( self, *a ):
        self.elapsed = time.perf_counter( ) - self.t0
        print( f"  [ TIME ]  {self.label}: {self.elapsed:.3f}s" )

def get_all_classes( root: str ) -> list[ str ]:
    return sorted( [ dir for dir in os.listdir( root ) if os.path.isdir( os.path.join( root, dir ) ) ] )


def collect_file_paths( root: str ) -> tuple[ list[ str ], list[ int ], list[ str ] ]:

    class_names = get_all_classes( root )
    label_map   = { n: i for i, n in enumerate( class_names ) }
    file_paths, labels = [ ], [ ]

    for cn in class_names:
        folder = os.path.join( root, cn )
    
        for file in os.listdir( folder ):
    
            if file.lower( ).endswith( ( ".jpg", ".jpeg", ".png" ) ):
                file_paths.append( os.path.join( folder, file ) )
                labels.append( label_map[ cn ] )
    
    return file_paths, labels, class_names

def split_paths( 
        file_paths: list[ str ], 
        labels: np.ndarray,
        seed: int=42, 
        val_split: float=0.15, 
        test_split: float=0.15 
    ) -> tuple[ np.ndarray, np.ndarray, np.ndarray, np.ndarray, np.ndarray, np.ndarray ]:

    idx = np.arange( len( file_paths ) )

    idx_tmp, idx_test = train_test_split( 
                            idx, 
                            test_size=test_split, 
                            random_state=seed, 
                            stratify=labels 
                        )
    
    val_ratio = val_split / ( 1 - test_split )
    
    idx_train, idx_val = train_test_split( 
                            idx_tmp, 
                            test_size=val_ratio, 
                            random_state=seed, 
                            stratify=np.array( labels )[ idx_tmp ] 
                        )
    
    fp = np.array( file_paths )
    lb = np.array( labels )
    return ( fp[ idx_train ], lb[ idx_train ], fp[ idx_val ], lb[ idx_val ], fp[ idx_test ], lb[ idx_test ] )

def load_and_preprocess( 
        path: tf.Tensor, 
        label: tf.Tensor, 
        target_size: int, 
        segment_fn: Callable[ [ np.ndarray ], np.ndarray ] | None = None 
    ) -> tuple[ tf.Tensor, tf.Tensor ]:

    def _load( p: tf.Tensor, sz: tf.Tensor ) -> np.ndarray:
        p   = p.numpy( ).decode( "utf-8" )
        sz  = int( sz.numpy( ) )
        img = cv2.imread( p )

        if img is None:
            img = np.zeros( ( sz, sz, 3 ), dtype=np.uint8 )
        
        if segment_fn is not None:
            img = segment_fn( img )
        
        img = cv2.resize( img, ( sz, sz ) )
        img = cv2.cvtColor( img, cv2.COLOR_BGR2RGB )
        
        return img.astype( np.float32 ) / 255.0
    
    img = tf.py_function( func=_load, inp=[ path, target_size ], Tout=tf.float32 )
    img.set_shape( [ None, None, 3 ] )
    img = tf.image.resize( img, [ target_size, target_size ] )
    return img, label

def build_dataset( 
        paths: np.ndarray, 
        labels: np.ndarray, 
        target_size: int, 
        batch_size: int, 
        shuffle: bool = False, 
        seed: int = 42, 
        segment_fn: Callable[ [ np.ndarray ], np.ndarray ] | None = None 
    ) -> tf.data.Dataset:

    ds = tf.data.Dataset.from_tensor_slices( ( paths, labels ) )

    if shuffle:
        ds = ds.shuffle( buffer_size=len( paths ), seed=seed )
    
    ds = ds.map( lambda p, l: 
                    load_and_preprocess( 
                        p, 
                        l, 
                        target_size, 
                        segment_fn 
                    ), 
                    
                    num_parallel_calls=tf.data.AUTOTUNE 
                )
    
    return ds.batch( batch_size ).prefetch( tf.data.AUTOTUNE )