import numpy as np
import cv2

def segment_hsv( img_bgr: np.ndarray ) -> np.ndarray:
    hsv = cv2.cvtColor( img_bgr, cv2.COLOR_BGR2HSV )

    mask_green = cv2.inRange( 
                        hsv, 
                        np.array( [ 15,  30,  20 ], 
                        dtype=np.uint8 ), 
                        np.array( [ 95, 255, 255 ], 
                        dtype=np.uint8 ) 
                     )

    mask_brown = cv2.inRange( 
                        hsv,
                        np.array( [ 5,  50,  20 ], 
                        dtype=np.uint8 ), 
                        np.array( [ 20, 255, 220 ], 
                        dtype=np.uint8 ) 
                     )

    mask   = cv2.bitwise_or( mask_green, mask_brown )
    kernel = cv2.getStructuringElement( cv2.MORPH_ELLIPSE, ( 7, 7 ) )
    mask   = cv2.morphologyEx( mask, cv2.MORPH_CLOSE, kernel, iterations=2 )
    mask   = cv2.morphologyEx( mask, cv2.MORPH_OPEN,  kernel, iterations=1 )

    return cv2.bitwise_and( img_bgr, img_bgr, mask=mask )

def segment_leaf( img_bgr: np.ndarray ) -> np.ndarray:

    h, w = img_bgr.shape[ :2 ]
    mask = np.zeros( ( h, w ), np.uint8 )
    mx   = max( int( w * 0.10 ), 5 )
    my   = max( int( h * 0.10 ), 5 )
    rect = ( mx, my, w - 2*mx, h - 2*my )
    bgd  = np.zeros( ( 1, 65 ), np.float64 )
    fgd  = np.zeros( ( 1, 65 ), np.float64 )
    
    try:
        cv2.grabCut( img_bgr, mask, rect, bgd, fgd, 5, cv2.GC_INIT_WITH_RECT )
        fg = np.where(
            ( mask == cv2.GC_FGD ) | ( mask == cv2.GC_PR_FGD ), 255, 0
        ).astype( np.uint8 )
    except Exception:
        fg = np.ones( ( h, w ), dtype=np.uint8 ) * 255
    
    return cv2.bitwise_and( img_bgr, img_bgr, mask=fg )
