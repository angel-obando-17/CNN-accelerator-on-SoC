#include "dma_regs.h"
#include "dma_driver.h"
#include "xil_io.h"

static inline void dma_reg_write32( uint32_t offset, uint32_t value ) {
	Xil_Out32( XPAR_CNN_TOP_0_S_AXI_BASEADDR + offset, value );
}

static inline uint32_t dma_reg_read32( uint32_t offset ) {
	return Xil_In32( XPAR_CNN_TOP_0_S_AXI_BASEADDR + offset );
}

void dma_driver_config_layer( const struct layer_config_t* cfg ) {
	dma_reg_write32( DMA_MODE, 		   (uint32_t) cfg -> common_mode );
	dma_reg_write32( DMA_CIN, 		   (uint32_t) cfg -> common_cin );
	dma_reg_write32( DMA_COUT, 	 	   (uint32_t) cfg -> dma_cout );
	dma_reg_write32( DMA_IMG_W, 	   (uint32_t) cfg -> dma_img_w );
	dma_reg_write32( DMA_IMG_H, 	   (uint32_t) cfg -> dma_img_h );
	dma_reg_write32( DMA_TILE_W, 	   (uint32_t) cfg -> dma_tile_w );
	dma_reg_write32( DMA_TILE_H, 	   (uint32_t) cfg -> dma_tile_h );
	dma_reg_write32( DMA_NUM_TILE_X,   (uint32_t) cfg -> dma_num_tile_x );
	dma_reg_write32( DMA_NUM_TILE_Y,   (uint32_t) cfg -> dma_num_tile_y );
	dma_reg_write32( DMA_HAS_RESIDUAL, (uint32_t) cfg -> common_has_residual );
	dma_reg_write32( DMA_WEIGHT_WORDS, (uint32_t) cfg -> dma_weight_words );
	dma_reg_write32( DMA_ADDR_W, 	   cfg -> dma_addr_w );
	dma_reg_write32( DMA_ADDR_IN, 	   cfg -> dma_addr_in );
	dma_reg_write32( DMA_ADDR_OUT, 	   cfg -> dma_addr_out );
	dma_reg_write32( DMA_ADDR_RES,     cfg -> dma_addr_res );
	dma_reg_write32( DMA_POOL_EN, 	   (uint32_t) cfg -> common_pool_en );
	dma_reg_write32( DMA_STRIDE_EN,    (uint32_t) cfg -> common_stride_en );
	dma_reg_write32( DMA_POOL_TYPE,    (uint32_t) cfg -> common_pool_type );
	dma_reg_write32( DMA_BIAS_WORDS,   (uint32_t) cfg -> dma_bias_words );
	dma_reg_write32( DMA_ADDR_BIAS,    cfg -> dma_addr_bias );
}

void dma_driver_start( void ) {
	dma_reg_write32( DMA_START, (uint32_t) 0x1 );
}

void dma_driver_wait_done( void ) {
	while( !( dma_reg_read32( DMA_DONE ) & 0x1 ) );
}

void dma_driver_clear_done( void ) {
	dma_reg_write32( DMA_DONE, (uint32_t) 0x1 );
}
