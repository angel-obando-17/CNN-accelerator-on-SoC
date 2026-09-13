#include <string.h>
#include <stdbool.h>
#include "intercore.h"
#include "hsv_segment.h"

static uint8_t mask_buffer[ WIDTH * HEIGHT ];
static uint8_t temp_buffer[ WIDTH * HEIGHT ];
static const uint8_t kernel[ KERNEL_SIZE ] = { 0, 2, 3, 3, 3, 2, 0 };

static int32_t h_table[ TABLES_ELEMENTS ];
static int32_t s_table[ TABLES_ELEMENTS ];

struct hsv_values {
    int32_t h_value;
    int32_t s_value;
    int32_t v_value;
};

static struct hsv_values bgr_to_hsv( uint8_t b_pixel, uint8_t g_pixel, uint8_t r_pixel ) {
    struct hsv_values values;
    values.v_value = (int32_t) MAX( r_pixel, g_pixel, b_pixel );
    int32_t difference = values.v_value - (int32_t) MIN( b_pixel, g_pixel, r_pixel );
    values.s_value = ( ( difference * s_table[ values.v_value ] ) + 0x800 ) >> 12;
    
    if( values.v_value == r_pixel )
        values.h_value = g_pixel - b_pixel;
    else if( values.v_value == g_pixel )
        values.h_value = ( b_pixel - r_pixel ) + ( difference << 1 );
    else
        values.h_value = ( r_pixel - g_pixel ) + ( difference << 2 );

    values.h_value = ( ( values.h_value * h_table[ difference ] ) + 0x800 ) >> 12;
    
    if( values.h_value < 0 ) values.h_value += 180;

    return values;
}

static inline bool is_h_green_mask( int32_t h_value ) {
    return ( h_value >= MSK_G_MIN_H && h_value <= MSK_G_MAX_H );
}

static inline bool is_h_brown_mask( int32_t h_value ) {
    return ( h_value >= MSK_B_MIN_H && h_value <= MSK_B_MAX_H );
}

static inline bool is_s_green_mask( int32_t s_value ) {
    return ( s_value >= MSK_G_MIN_S && s_value <= MSK_G_MAX_S );
}

static inline bool is_s_brown_mask( int32_t s_value ) {
    return ( s_value >= MSK_B_MIN_S && s_value <= MSK_B_MAX_S );
}

static inline bool is_v_green_mask( int32_t v_value ) {
    return ( v_value >= MSK_G_MIN_V && v_value <= MSK_G_MAX_V );
}

static inline bool is_v_brown_mask( int32_t v_value ) {
    return ( v_value >= MSK_B_MIN_V && v_value <= MSK_B_MAX_V );
}

static uint8_t classification_mask( const struct hsv_values* values ) {
    if( ( is_h_green_mask( values -> h_value ) && 
          is_s_green_mask( values -> s_value ) && 
          is_v_green_mask( values -> v_value ) ) ||
        ( is_h_brown_mask( values -> h_value ) &&
          is_s_brown_mask( values -> s_value ) &&
          is_v_brown_mask( values -> v_value ) ) )
        return 0xFFu;
    else return 0;
}

static void image_mask( const uint8_t* raw_image ) {
    struct hsv_values values;
    for( uint32_t i = 0; i < WIDTH * HEIGHT; i++ ) {
        values = bgr_to_hsv( raw_image[ 3 * i ], raw_image[ ( 3 * i ) + 1 ], raw_image[ ( 3 * i ) + 2 ] ); 
        mask_buffer[ i ] = classification_mask( &values );
    }
}

static void dilate_image( const uint8_t* in_buffer, uint8_t* out_buffer ) {
    for( int16_t y = 0; y < HEIGHT; y++ ) { 
        for( int16_t x = 0; x < WIDTH; x++ ) {
            bool found = false;
            out_buffer[ ( y * WIDTH ) + x ] = 0;
            for( int8_t row = 0; row < KERNEL_SIZE && !found; row++ ) {
                int16_t row_neighbor = (int16_t) ( y + row - KERNEL_RADIUS );
                if( row_neighbor < 0 || row_neighbor > HEIGHT - 1 ) continue;
                for( int16_t col = (int16_t) ( x - kernel[ row ] ); col <= ( x + kernel[ row ] ) && !found; col++ ) {
                    if( col < 0 || col > WIDTH - 1 ) continue;
                    if( in_buffer[ ( row_neighbor * WIDTH ) + col ] == 0xFF ) {
                        out_buffer[ ( y * WIDTH ) + x ] = 0xFF;
                        found = true;
                    }
                }
            }
        }
    }
}

static void erode_image( const uint8_t* in_buffer, uint8_t* out_buffer ) {
    for( int16_t y = 0; y < HEIGHT; y++ ) { 
        for( int16_t x = 0; x < WIDTH; x++ ) {
            bool found = false;
            out_buffer[ ( y * WIDTH ) + x ] = 0xFF;
            for( int8_t row = 0; row < KERNEL_SIZE && !found; row++ ) {
                int16_t row_neighbor = (int16_t) ( y + row - KERNEL_RADIUS );
                if( row_neighbor < 0 || row_neighbor > HEIGHT - 1 ) continue;
                for( int16_t col = (int16_t) ( x - kernel[ row ] ); col <= ( x + kernel[ row ] ) && !found; col++ ) {
                    if( col < 0 || col > WIDTH - 1 ) continue;
                    if( in_buffer[ ( row_neighbor * WIDTH ) + col ] == 0 ) {
                        out_buffer[ ( y * WIDTH ) + x ] = 0;
                        found = true;
                    }
                }
            }
        }
    }
}

static uint8_t* morphology( uint8_t* first_buffer, uint8_t* second_buffer ) {
    uint8_t* current_in_ptr = first_buffer;
    uint8_t* current_out_ptr = second_buffer;
    uint8_t* temp; 
    
    /* Morphology Close Iteration - Dilate, Dilate, Erode, Erode */
    for( uint8_t i = 0; i < CLOSE_ITERATION; i++ ) {
        dilate_image( current_in_ptr, current_out_ptr );
        temp = current_out_ptr;
        current_out_ptr = current_in_ptr;
        current_in_ptr = temp;
    }

    for( uint8_t i = 0; i < CLOSE_ITERATION; i++ ) {
        erode_image( current_in_ptr, current_out_ptr );
        temp = current_out_ptr;
        current_out_ptr = current_in_ptr;
        current_in_ptr = temp;
    }

    /* Morphology Open Iteration - Erode, Dilate */
    for( uint8_t i = 0; i < OPEN_ITERATION; i++ ) {
        erode_image( current_in_ptr, current_out_ptr );
        temp = current_out_ptr;
        current_out_ptr = current_in_ptr;
        current_in_ptr = temp;
    }
    
    for( uint8_t i = 0; i < OPEN_ITERATION; i++ ) {
        dilate_image( current_in_ptr, current_out_ptr );
        temp = current_out_ptr;
        current_out_ptr = current_in_ptr;
        current_in_ptr = temp;
    }

    return current_in_ptr;    
}

static inline int8_t quantize( uint8_t data, uint8_t mult, uint8_t div ) {
    return (int8_t) ( ( ( data * mult ) + ( div >> 1 ) ) / div ); 
}

static void build_frame( const uint8_t* raw_image, const uint8_t* mask, int8_t* package_frame ) {
    memset( package_frame, 0, WIDTH * HEIGHT * PACKAGING_BYTES_PER_PIXEL );

    for( uint32_t i = 0; i < WIDTH * HEIGHT; i++ ) {
        if( mask[ i ] == 0xFF ) {
            package_frame[ ( PACKAGING_BYTES_PER_PIXEL * i ) + 2 ] = quantize( 
                                                                         raw_image[ 3 * i ],
                                                                         MULT_SCALE_FACTOR, 
                                                                         DIV_SCALE_FACTOR );
            package_frame[ ( PACKAGING_BYTES_PER_PIXEL * i ) + 1 ] = quantize( 
                                                                         raw_image[ ( 3 * i ) + 1 ], 
                                                                         MULT_SCALE_FACTOR, 
                                                                         DIV_SCALE_FACTOR );
            package_frame[ ( PACKAGING_BYTES_PER_PIXEL * i ) ] = quantize( 
                                                                     raw_image[ ( 3 * i ) + 2 ], 
                                                                     MULT_SCALE_FACTOR, 
                                                                     DIV_SCALE_FACTOR );
        }
    }
}

static bool is_validate_mask( uint8_t* mask ) {
    for( uint32_t i = 0; i < WIDTH * HEIGHT; i++ ) {
        if( mask[ i ] == 0xFF ) return true;
    }

    return false;
}

void init_tables( void ) {
    h_table[ 0 ] = s_table[ 0 ] = 0;
    
    for( uint16_t i = 1; i < TABLES_ELEMENTS; i++ ) {
        h_table[ i ] = ( ( 180 * 4096 ) + ( ( 6 * i ) >> 1 ) ) / ( 6 * i );
        s_table[ i ] = ( ( 255 * 4096 ) + ( i >> 1 ) ) / i;
    }
}

uint32_t packaging_frame( const uint8_t* raw_image, int8_t* package_frame ) {
    if( raw_image == NULL ) return FAIL_IN_NULL_POINTER;
    if( package_frame == NULL ) return FAIL_OUT_NULL_POINTER; 
    
    const uintptr_t raw_frame_length = WIDTH * HEIGHT * RAW_BYTES_PER_PIXEL;
    const uintptr_t package_frame_length = WIDTH * HEIGHT * PACKAGING_BYTES_PER_PIXEL;
    
    /* Local variables to save the addresses of the pointers points, to
       compare numbers, not pointers. */
    const uintptr_t frame_in_start = (uintptr_t) raw_image;
    const uintptr_t frame_out_start = (uintptr_t) package_frame;

    /* Accelerator reeive 128-bit words, so base address must be a multiple of 16 bytes. */
    if( ( frame_out_start & 0xFu ) != 0x0u )
        return FAIL_OUT_NOT_ALIGNED_TO_16_BYTES;

    /* The output must be start inside the usable DDR. */
    if( frame_out_start < DDR_BASE_ADDRESS || frame_out_start >= DDR_TOP_ADDRESS )
        return FAIL_OUT_POINTER_OUT_OF_ZONE;

    /* The whole frame must fit before the top. */
    if( frame_out_start > DDR_TOP_ADDRESS - package_frame_length )
        return FAIL_NOT_ENOUGH_SPACE;
    
    /* The zone that starts first must end before the other begins. */
    if( frame_out_start >= frame_in_start ) {
        if( frame_out_start - frame_in_start < raw_frame_length )
            return FAIL_OVERLAP_ZONES;
    } else {
        if( frame_in_start - frame_out_start < package_frame_length )
            return FAIL_OVERLAP_ZONES;
    }

    image_mask( raw_image );
    uint8_t* final_mask = morphology( mask_buffer, temp_buffer );
    
    bool is_mask = is_validate_mask( final_mask );

    build_frame( raw_image, final_mask, package_frame );    

    if( is_mask )
        return SEGMENTATION_DONE;
    else 
        return WARNING_EMPTY_MASK;
}   