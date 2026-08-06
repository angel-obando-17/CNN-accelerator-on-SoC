#ifndef __DMA_DRIVER__
#define __DMA_DRIVER__

#include "layer_table.h"

void dma_driver_config_layer( const struct layer_config_t* cfg );
void dma_driver_start( void );
void dma_driver_wait_done( void );
void dma_driver_clear_done( void );

#endif