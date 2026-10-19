#include "sw_inference.h"

#define MODE_CONV3X3	 0U
#define MODE_DW3X3		 1U
#define MODE_PW1X1		 2U

#define BYTES_PER_WORD	16U
#define MULT_FRAC_BITS	16U

#define SW_ARENA_OFFSET 0x01000000U
#define GAP_MAP_SIZE	( 16U * 16U * 64U )

static int8_t gap_map[ GAP_MAP_SIZE ];

static inline uint32_t act_offset( uint16_t y, uint16_t x, uint8_t c, uint16_t width, uint8_t channels ) {
	return (uint32_t) ( ( ( channels + BYTES_PER_WORD - 1 ) / BYTES_PER_WORD * BYTES_PER_WORD ) * ( (uint32_t) y * width + x ) + c );
}

static inline uint32_t weight_word( uint8_t mode, uint8_t co, uint8_t ci, uint8_t ky, uint8_t kx, uint8_t cin ) {
	switch( mode ) {
		case MODE_CONV3X3:
			return (uint32_t) ( co * cin  * 9 + ci * 9 + ky * 3 + kx );
		case MODE_DW3X3:
			return (uint32_t) ( co * 9 + ky * 3 + kx );
		case MODE_PW1X1:
			return (uint32_t) ( co * cin + ci );
		default:
			return 0;
	}
}

static inline int8_t weight_at( const int8_t* layer_weights, uint32_t word, uint8_t cout ) {
	return layer_weights[ ( word * BYTES_PER_WORD ) + ( cout % BYTES_PER_WORD ) ];
}

static int32_t accumulate( const struct layer_config_t* cfg, const int8_t* in, uint16_t out_y, uint16_t out_x, uint8_t cout ) {
	const int8_t* weights = (const int8_t*) (uintptr_t) cfg -> dma_addr_w;
	uint16_t in_w = cfg -> dma_img_w;
	uint16_t in_h = cfg -> dma_img_h;
	uint8_t cin = cfg -> common_cin;
	uint8_t stride = cfg -> common_stride_en ? 2 : 1;
	uint8_t pad = ( stride == 1 ) ? 1 : 0;
	uint8_t co = cout / BYTES_PER_WORD;
	int32_t acc = 0;

	switch( cfg -> common_mode ) {
		case MODE_CONV3X3:
			for( uint8_t ky = 0; ky < 3; ky++ ) {
				for( uint8_t kx = 0; kx < 3; kx++ ) {
					int32_t iy = (int32_t) out_y * stride + ky - pad;
					int32_t ix = (int32_t) out_x * stride + kx - pad;
					if( iy < 0 || iy >= in_h || ix < 0 || ix >= in_w ) continue;
					for( uint8_t ci = 0; ci < cin; ci++ ) {
						acc += in[ act_offset( (uint16_t) iy, (uint16_t) ix, ci, in_w, cin ) ] *
							   weight_at( weights, weight_word( MODE_CONV3X3, co, ci, ky, kx, cin ), cout );
					}
				}
			}
			break;
		case MODE_DW3X3:
			for( uint8_t ky = 0; ky < 3; ky++ ) {
				for( uint8_t kx = 0; kx < 3; kx++ ) {
					int32_t iy = (int32_t) out_y * stride + ky - pad;
					int32_t ix = (int32_t) out_x * stride + kx - pad;
					if( iy < 0 || iy >= in_h || ix < 0 || ix >= in_w ) continue;
					acc += in[ act_offset( (uint16_t) iy, (uint16_t) ix, cout, in_w, cin ) ] *
						   weight_at( weights, weight_word( MODE_DW3X3, co, 0, ky, kx, cin ), cout );
				}
			}
			break;
		case MODE_PW1X1:
			for( uint8_t ci = 0; ci < cin; ci++ )
				acc += in[ act_offset( out_y, out_x, ci, in_w, cin ) ] *
					   weight_at( weights, weight_word( MODE_PW1X1, co, ci, 0, 0, cin ), cout );
			break;
		default:
			break;
	}

	return acc;
}

static int8_t requantize( const struct layer_config_t* cfg, int32_t acc, uint8_t cout ) {
	uint16_t mult = cfg -> cnn_mult;
	uint8_t shift = cfg -> cnn_shift;
	bool relu_en = cfg -> common_relu_en;
	int8_t relu6_val = cfg -> cnn_relu6_val;
	const int32_t* bias = (const int32_t*) (uintptr_t) cfg -> dma_addr_bias;

	int32_t biased = acc + bias[ cout ];
	int64_t product = (int64_t) biased  * mult;
	uint8_t total = shift + MULT_FRAC_BITS;
	int64_t rounded = product + ( (int64_t) 1 << ( total - 1 ) );
	int64_t shifted = rounded >> total;
	int8_t clamped;

	if( shifted > 127 )
		shifted = 127;
	else if( shifted < -128 )
		shifted = -128;

	if( relu_en ) {
		if( shifted < 0 )
			clamped = 0;
		else if( shifted > relu6_val )
			clamped = relu6_val;
		else
			clamped = (int8_t) shifted;
	} else
		clamped = (int8_t) shifted;

	return clamped;
}

static void run_layer( const struct layer_config_t* cfg, const int8_t* in, const int8_t* res, int8_t* out ) {
	uint8_t stride = cfg -> common_stride_en ? 2 : 1;
	uint16_t out_h = (uint16_t) ( cfg -> dma_img_h / stride );
	uint16_t out_w = (uint16_t) ( cfg -> dma_img_w / stride );
	uint8_t cout_pad = (uint8_t) ( ( cfg -> dma_cout + BYTES_PER_WORD - 1 ) / BYTES_PER_WORD * BYTES_PER_WORD );

	for( uint16_t y = 0; y < out_h; y++ ) {
		for( uint16_t x = 0; x  < out_w; x++ ) {
			for( uint8_t cout = 0; cout < cout_pad; cout++ ) {
				int16_t quant = requantize( cfg, accumulate( cfg, in, y, x, cout ), cout );
				if( cfg -> common_has_residual )
					quant += res[ act_offset( y, x, cout, out_w, cfg -> dma_cout ) ];
				if( quant > 127 )
					quant = 127;
				else if( quant < -128 )
					quant = -128;
				out[ act_offset( y, x, cout, out_w, cfg -> dma_cout ) ] = (int8_t) quant;
			}
		}
	}
}

static void global_avg_pool( const struct layer_config_t* cfg, const int8_t* in, int8_t* out ) {
	uint16_t img_w = cfg -> dma_img_w;
	uint16_t img_h = cfg -> dma_img_h;

	uint8_t cout = cfg -> dma_cout;
	uint8_t gap_shift = cfg -> cnn_gap_shift;

	for( uint8_t channel = 0; channel < cout; channel++ ) {
		int32_t sum = 0;
		for( uint16_t y = 0; y < img_h; y++ ) {
			for( uint16_t x = 0; x < img_w; x++ ) {
				sum += in[ act_offset( y, x, channel, img_w, cout ) ];
			}
		}
		sum = sum >> gap_shift;

		if( sum > 127 )
			sum = 127;
		else if( sum < -128 )
			sum = -128;

		out[ channel ] = (int8_t) sum;
	}
}

void sw_inference_run( const struct layer_config_t* table, const int8_t* frame, int8_t* gap_out ) {
	for( uint8_t i = 0; i < NUM_LAYERS; i++ ) {
		const struct layer_config_t* cfg = &table[ i ];
		const int8_t* in = ( i == 0 ) ? frame :
								  		(const int8_t*) (uintptr_t) ( cfg -> dma_addr_in+ SW_ARENA_OFFSET );

		int8_t* out = (int8_t*) (uintptr_t) ( cfg -> dma_addr_out + SW_ARENA_OFFSET );
		const int8_t* res = ( cfg -> common_has_residual ) ? (const int8_t*) (uintptr_t) ( cfg -> dma_addr_res + SW_ARENA_OFFSET ) :
												    		 NULL;
		if( cfg -> common_pool_en ) {
			run_layer( cfg, in, res, gap_map );
			global_avg_pool( cfg, gap_map, gap_out );
		} else
			run_layer( cfg, in, res, out );
	}
}