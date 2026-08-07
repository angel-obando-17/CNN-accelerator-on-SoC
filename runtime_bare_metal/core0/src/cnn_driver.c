#include "cnn_regs.h"
#include "cnn_driver.h"
#include "xil_io.h"

static inline void cnn_reg_write32( uint32_t offset, uint32_t value ) {
	Xil_Out32( XPAR_CNN_TOP_0_AXI_BASEADDR + offset, value );
}

void cnn_driver_config_layer( const struct layer_config_t* cfg ) {
	cnn_reg_write32( REG_MODE, 		   (uint32_t) cfg -> common_mode );
	cnn_reg_write32( REG_CIN,  		   (uint32_t) cfg -> common_cin );
	cnn_reg_write32( REG_MAX_INNER,    (uint32_t) cfg -> cnn_max_inner );
	cnn_reg_write32( REG_MAX_CO,       (uint32_t) cfg -> cnn_max_co );
	cnn_reg_write32( REG_MAX_X, 	   (uint32_t) cfg -> cnn_max_x );
	cnn_reg_write32( REG_MAX_Y, 	   (uint32_t) cfg -> cnn_max_y );
	cnn_reg_write32( REG_MAX_TILE_X,   (uint32_t) cfg -> cnn_max_tile_x );
	cnn_reg_write32( REG_MAX_TILE_Y,   (uint32_t) cfg -> cnn_max_tile_y );
	cnn_reg_write32( REG_HAS_RESIDUAL, (uint32_t) cfg -> common_has_residual );
	cnn_reg_write32( REG_POOL_EN, 	   (uint32_t) cfg -> common_pool_en );
	cnn_reg_write32( REG_POOL_TYPE,    (uint32_t) cfg -> common_pool_type );
	cnn_reg_write32( REG_SHIFT, 	   (uint32_t) cfg -> cnn_shift );
	cnn_reg_write32( REG_RELU6_VAL,    (uint32_t) cfg -> cnn_relu6_val );
	cnn_reg_write32( REG_GAP_SHIFT,    (uint32_t) cfg -> cnn_gap_shift );
	cnn_reg_write32( REG_MULT, 		   (uint32_t) cfg -> cnn_mult );
}
