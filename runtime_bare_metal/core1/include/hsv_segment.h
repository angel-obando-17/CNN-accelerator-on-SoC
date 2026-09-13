#ifndef __HSV_SEGMENT_H__
#define __HSV_SEGMENT_H__

#include <stdint.h>

#define MAX( a, b, c ) ( (a) > (b) ? ( (a) > (c) ? (a) : (c) ) : ( (b) > (c) ? (b) : (c) ) )
#define MIN( a, b, c ) ( (a) < (b) ? ( (a) < (c) ? (a) : (c) ) : ( (b) < (c) ? (b) : (c) ) )

/* Dimension of channels. */
#define WIDTH                       0x00000100
#define HEIGHT                      0x00000100
#define RAW_BYTES_PER_PIXEL         0x00000003
#define PACKAGING_BYTES_PER_PIXEL   0x00000010

/* Segmentation constants. */

#define TABLES_ELEMENTS 0x00000100u

/* MASK_GREEN */
#define MSK_G_MIN_H   0x0000000F /* Min H value for MASK_GREEN=15  */
#define MSK_G_MIN_S   0x0000001E /* Min S value for MASK_GREEN=30  */
#define MSK_G_MIN_V   0x00000014 /* Min V value for MASK_GREEN=20  */

#define MSK_G_MAX_H   0x0000005F /* Max H value for MASK_GREEN=95  */
#define MSK_G_MAX_S   0x000000FF /* Max S value for MASK_GREEN=255 */
#define MSK_G_MAX_V   0x000000FF /* Max V value for MASK_GREEN=255 */

/* MASK_BROWN */
#define MSK_B_MIN_H   0x00000005 /* Min H value for BROWN_MASK=5   */
#define MSK_B_MIN_S   0x00000032 /* Min S value for BROWN_MASK=50  */
#define MSK_B_MIN_V   0x00000014 /* Min V value for BROWN_MASK=20  */

#define MSK_B_MAX_H   0x00000014 /* Max H value for BROWN_MASK=20  */
#define MSK_B_MAX_S   0x000000FF /* Max S value for BROWN_MASK=255 */
#define MSK_B_MAX_V   0x000000DC /* Max V value for BROWN_MASK=220 */


/* Kernel size ( 7, 7 ) */
#define KERNEL_SIZE     0x00000007
#define KERNEL_RADIUS   ( KERNEL_SIZE >> 1 )

/* Close Iteration - Dilate, Dilate, Erode, Erode */
#define CLOSE_ITERATION 0x00000002u

/* Open Iteration  - Erode, Dilate */
#define OPEN_ITERATION  0x00000001u

/* Scale Factor to multiply */
#define MULT_SCALE_FACTOR 0x0000007Fu

/* Scale Factor to divide */
#define DIV_SCALE_FACTOR  0x000000FFu

void init_tables( void );
uint32_t packaging_frame( const uint8_t* raw_image, int8_t* package_frame );

#endif