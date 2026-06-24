"""
=============================================================================
GUARDAR MUESTRAS DE IMÁGENES SEGMENTADAS

Guarda para cada clase de tomate:
  - Una cuadrícula de N imágenes: original | segmentada | diferencia
  - Las imágenes segmentadas individuales (opcional, ver SAVE_INDIVIDUALS)
=============================================================================
"""

import os
import random
import numpy as np
import cv2
import matplotlib
matplotlib.use( "Agg" )
import matplotlib.pyplot as plt
from tqdm import tqdm

DATASET_ROOT      = "C:/Users/ANGEL OBANDO/Documents/Trabajo de grado/CNN/PlantVillage"
OUTPUT_DIR        = "/resultados_experimentos/imagenes_segmentadas"
SAMPLES_PER_CLASS = 5
SAVE_INDIVIDUALS  = False
SEED              = 42

os.makedirs( OUTPUT_DIR, exist_ok=True )
random.seed( SEED )


def get_tomato_folders( root ):
    folders = [ ]
    for name in os.listdir( root ):
        if name.lower( ).startswith( "tomato" ) and os.path.isdir( os.path.join( root, name ) ):
            folders.append( os.path.join( root, name ) )
    if not folders:
        raise RuntimeError(
            f"No se encontraron carpetas de tomate en '{root}'.\n"
            f"Revisa la variable DATASET_ROOT."
        )
    return sorted( folders )


def segment_leaf( img_bgr ):
    #GrabCut para aislar la hoja (mismo algoritmo que en el entrenamiento).
    h, w      = img_bgr.shape[ :2 ]
    mask      = np.zeros( ( h, w ), np.uint8 )
    margin_x  = max( int( w * 0.10 ), 5 )
    margin_y  = max( int( h * 0.10 ), 5 )
    rect      = ( margin_x, margin_y, w - 2 * margin_x, h - 2 * margin_y )
    bgd_model = np.zeros( ( 1, 65 ), np.float64 )
    fgd_model = np.zeros( ( 1, 65 ), np.float64 )
    try:
        cv2.grabCut( img_bgr, mask, rect, bgd_model, fgd_model, 5, cv2.GC_INIT_WITH_RECT )
        fg_mask = np.where(
            ( mask == cv2.GC_FGD ) | ( mask == cv2.GC_PR_FGD ), 255, 0
        ).astype( np.uint8 )
    except Exception:
        fg_mask = np.ones( ( h, w ), dtype=np.uint8 ) * 255
    result = cv2.bitwise_and( img_bgr, img_bgr, mask=fg_mask )
    return result, fg_mask


def make_comparison_grid( folder_path, class_name, n_samples=SAMPLES_PER_CLASS ):
    #n_samples filas, 3 columnas: Original | Segmentada | Máscara.
    files = [ f for f in os.listdir( folder_path )
              if f.lower( ).endswith( ( ".jpg", ".jpeg", ".png" ) ) ]
    if not files:
        return

    selected = random.sample( files, min( n_samples, len( files ) ) )

    fig, axes = plt.subplots( len( selected ), 3, figsize=( 10, 3.5 * len( selected ) ) )
    if len( selected ) == 1:
        axes = [ axes ]

    short_name = class_name.replace( "Tomato___", "" ).replace( "Tomato__", "" )
    fig.suptitle( f"Segmentación GrabCut — {short_name}", fontsize=13, fontweight="bold", y=1.01 )

    for row_idx, fname in enumerate( selected ):
        fpath        = os.path.join( folder_path, fname )
        img_bgr      = cv2.imread( fpath )
        if img_bgr is None:
            continue

        img_rgb       = cv2.cvtColor( img_bgr, cv2.COLOR_BGR2RGB )
        seg_bgr, mask = segment_leaf( img_bgr )
        seg_rgb       = cv2.cvtColor( seg_bgr, cv2.COLOR_BGR2RGB )

        ax_orig = axes[ row_idx ][ 0 ]
        ax_seg  = axes[ row_idx ][ 1 ]
        ax_mask = axes[ row_idx ][ 2 ]

        ax_orig.imshow( img_rgb )
        ax_orig.set_title( "Original", fontsize=9 )
        ax_orig.axis( "off" )

        ax_seg.imshow( seg_rgb )
        ax_seg.set_title( "Segmentada (GrabCut)", fontsize=9 )
        ax_seg.axis( "off" )

        ax_mask.imshow( mask, cmap="gray" )
        ax_mask.set_title( "Máscara", fontsize=9 )
        ax_mask.axis( "off" )

    plt.tight_layout( )
    safe_name = class_name.replace( " ", "_" )
    out_path  = os.path.join( OUTPUT_DIR, f"grid_{safe_name}.png" )
    fig.savefig( out_path, dpi=150, bbox_inches="tight" )
    plt.close( fig )
    print( f"    Guardada: grid_{safe_name}.png" )


def save_all_individuals( folder_path, class_name ):
    #Guarda cada imagen segmentada individualmente (opcional).
    out_class_dir = os.path.join( OUTPUT_DIR, "individuales", class_name )
    os.makedirs( out_class_dir, exist_ok=True )
    files = [ f for f in os.listdir( folder_path )
              if f.lower( ).endswith( ( ".jpg", ".jpeg", ".png" ) ) ]
    for fname in tqdm( files, desc=f"    Guardando {class_name[ :35 ]}", leave=False ):
        fpath = os.path.join( folder_path, fname )
        img   = cv2.imread( fpath )
        if img is None:
            continue
        seg, _ = segment_leaf( img )
        cv2.imwrite( os.path.join( out_class_dir, fname ), seg )


def generate_mosaic_overview( folders ):
    #Mosaico general: una imagen por clase (original vs segmentada).
    n_classes = len( folders )
    fig, axes = plt.subplots( n_classes, 2, figsize=( 7, 3 * n_classes ) )
    fig.suptitle( "Vista general — Original vs Segmentada (1 muestra por clase)",
                  fontsize=12, fontweight="bold" )

    for i, folder in enumerate( folders ):
        class_name = os.path.basename( folder )
        short_name = class_name.replace( "Tomato___", "" ).replace( "Tomato__", "" )
        files = [ f for f in os.listdir( folder )
                  if f.lower( ).endswith( ( ".jpg", ".jpeg", ".png" ) ) ]
        if not files:
            continue
        fname   = random.choice( files )
        img     = cv2.imread( os.path.join( folder, fname ) )
        if img is None:
            continue
        img_rgb = cv2.cvtColor( img, cv2.COLOR_BGR2RGB )
        seg, _  = segment_leaf( img )
        seg_rgb = cv2.cvtColor( seg, cv2.COLOR_BGR2RGB )

        axes[ i ][ 0 ].imshow( img_rgb )
        axes[ i ][ 0 ].set_ylabel( short_name, fontsize=8, rotation=0, labelpad=80, va="center" )
        axes[ i ][ 0 ].set_title( "Original" if i == 0 else "", fontsize=9 )
        axes[ i ][ 0 ].axis( "off" )

        axes[ i ][ 1 ].imshow( seg_rgb )
        axes[ i ][ 1 ].set_title( "Segmentada" if i == 0 else "", fontsize=9 )
        axes[ i ][ 1 ].axis( "off" )

    plt.tight_layout( )
    out_path = os.path.join( OUTPUT_DIR, "00_mosaic_overview.png" )
    fig.savefig( out_path, dpi=150, bbox_inches="tight" )
    plt.close( fig )
    print( f"\n  Mosaico general guardado: 00_mosaic_overview.png" )


# MAIN
if __name__ == "__main__":
    print( "=" * 60 )
    print( "  GUARDANDO IMÁGENES SEGMENTADAS" )
    print( "=" * 60 )

    if not os.path.isdir( DATASET_ROOT ):
        print( f"\n[ERROR] No se encontró DATASET_ROOT = '{DATASET_ROOT}'" )
        exit( 1 )

    folders = get_tomato_folders( DATASET_ROOT )
    print( f"\n  Clases encontradas: {len( folders )}" )
    for f in folders:
        print( f"    - {os.path.basename( f )}" )

    print( "\n  Generando mosaico general..." )
    generate_mosaic_overview( folders )

    print( f"\n  Generando grids comparativos ({SAMPLES_PER_CLASS} muestras/clase)..." )
    for folder in folders:
        class_name = os.path.basename( folder )
        make_comparison_grid( folder, class_name, SAMPLES_PER_CLASS )

    if SAVE_INDIVIDUALS:
        print( "\n  Guardando imágenes individuales segmentadas..." )
        for folder in folders:
            save_all_individuals( folder, os.path.basename( folder ) )

    print( f"\n  Todo guardado en: {OUTPUT_DIR}/" )
    print( "  Archivos generados:" )
    print( "    00_mosaic_overview.png   → Mosaico general (ideal para el doc)" )
    print( "    grid_Tomato_*.png        → Comparativa original/segmentada/máscara por clase" )
    if SAVE_INDIVIDUALS:
        print( "    individuales/            → Carpetas con cada imagen segmentada" )
