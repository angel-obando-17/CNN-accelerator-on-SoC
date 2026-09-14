#include "intercore.h"
#include "dma_driver.h"
#include "cnn_driver.h"
#include "layer_table.h"

#include "xil_mmu.h"
#include "xil_cache.h"
#include "xscugic.h"
#include "xil_exception.h"
#include "xparameters.h"
#include "xil_printf.h"

#define DENSE_ADDRESS	0x01020000u
#define GAP_CHANNELS	0x00000040u
#define NUM_CLASSES		0x00000009u

/* This value is hardcoded with the reference of ptq_simple_v2/layer_quant_params.json */
#define GAP_SCALE		0.029560492733332114

static const char* const classes[ NUM_CLASSES ] = { "Tomato_Bacterial_spot", 
								     				"Tomato_Early_blight", 
													"Tomato_Late_blight", 
													"Tomato_Leaf_Mold", 
													"Tomato_Septoria_leaf_spot", 
													"Tomato_Spider_mites_Two_spotted_spider_mite", 
													"Tomato__Target_Spot", 
													"Tomato__Tomato_YellowLeaf__Curl_Virus", 
													"Tomato_healthy" 
												  };

static XScuGic Gic_Handler;
static volatile uint32_t Handler_Flag = 0x0u;

/* Interrupt Handler use only for Core0. */
static void Interrupt_Handler( void* Ref ) {
    (void) Ref;
    Handler_Flag = 0x1u;
}

static void flush_model_data( const struct layer_config_t* lyr_table ) {
	uint32_t weights_size = ( lyr_table[ NUM_LAYERS - 1 ].dma_addr_w  + ( lyr_table[ NUM_LAYERS - 1 ].dma_weight_words << 4 ) )
	                        - lyr_table[ 0 ].dma_addr_w;
	Xil_DCacheFlushRange( (INTPTR) lyr_table[ 0 ].dma_addr_w, weights_size );

	uint32_t bias_size = ( lyr_table[ NUM_LAYERS - 1 ].dma_addr_bias + ( lyr_table[ NUM_LAYERS - 1 ].dma_bias_words << 4 ) )
	                     - lyr_table[ 0 ].dma_addr_bias;
	Xil_DCacheFlushRange( (INTPTR) lyr_table[ 0 ].dma_addr_bias, bias_size );
	
}

static uint32_t request_segmentation( XScuGic* Gic, struct ocm_mailbox_t* mailbox_ptr, uint32_t id ) {
	mailbox_ptr -> frame_id = id;
	mailbox_ptr -> frame_ready = 0x1u;

	Handler_Flag = 0x0u;
	dsb( );
	XScuGic_SoftwareIntr( Gic, SGI_CORE0_TO_CORE1, INTERCORE_CPU1_MASK );

	while( !Handler_Flag );
	Handler_Flag = 0x0u;

	mailbox_ptr -> seg_done = 0x0u;
	uint32_t status_received = mailbox_ptr -> status;

	return status_received;
}

static void run_network( const struct layer_config_t* lyr_table ) {
	for( uint8_t i = 0; i < NUM_LAYERS; i++ ) {
		cnn_driver_config_layer( &lyr_table[ i ] );
		dma_driver_config_layer( &lyr_table[ i ] );
		dma_driver_start( );
		dma_driver_wait_done( );
		dma_driver_clear_done( );
	}
}

static uint8_t classify( const int8_t* gap_values, const float* dense_values ) {
	uint8_t best_class = 0;
	double best_points;
	for( uint8_t i = 0; i < NUM_CLASSES; i++ ) {
		double points = dense_values[ GAP_CHANNELS * NUM_CLASSES + i ];
		for( uint8_t j = 0; j < GAP_CHANNELS; j++ ) {
			points += ( ( gap_values[ j ] * GAP_SCALE ) * dense_values[ j * NUM_CLASSES + i ] );
		}

		if( i == 0 || points > best_points ) {
			best_class = i;
			best_points = points;
		}
	}

	return best_class;
}

int main( void ) {
	Xil_SetTlbAttributes( (INTPTR) OCM_MAILBOX_BASE, NORM_NONCACHE );

	struct ocm_mailbox_t* const ocm_mailbox_ptr = ocm_pointer( );

	ocm_mailbox_ptr -> frame_ready = 0x0u;
	ocm_mailbox_ptr -> seg_done = 0x0u;
	ocm_mailbox_ptr -> frame_id = FRAME_ID_NONE;
	ocm_mailbox_ptr -> status = 0x0u;

	XScuGic_Config* Gic_Config = XScuGic_LookupConfig( XPAR_SCUGIC_0_DEVICE_ID );

	if( Gic_Config == NULL )
	        while( 1 );

	if( XScuGic_CfgInitialize( &Gic_Handler, Gic_Config, Gic_Config -> CpuBaseAddress ) != XST_SUCCESS )
		while( 1 );

	Xil_ExceptionInit( );
	Xil_ExceptionRegisterHandler( 
		XIL_EXCEPTION_ID_INT,
		(Xil_ExceptionHandler) XScuGic_InterruptHandler,
		&Gic_Handler 
	);

	if( XScuGic_Connect( &Gic_Handler, SGI_CORE1_TO_CORE0, Interrupt_Handler, NULL ) != XST_SUCCESS )
		while( 1 );

	XScuGic_Enable( &Gic_Handler, SGI_CORE1_TO_CORE0 );

	Xil_ExceptionEnable( );

	flush_model_data( layer_table );
	if( layer_table[ 0 ].dma_addr_in != PACKAGE_FRAME_ADDRESS )
		while( 1 );

	uint32_t current_id = FRAME_ID_NONE;
	current_id++;

	uint32_t status_received = request_segmentation( &Gic_Handler, ocm_mailbox_ptr, current_id );

	if( status_received != WARNING_EMPTY_MASK && status_received != SEGMENTATION_DONE ) {
		xil_printf( "Fail Status Error: %d\n", status_received );
		while( 1 );
	}
	
	Xil_DCacheFlushRange( (INTPTR) PACKAGE_FRAME_ADDRESS, PACKAGE_FRAME_LENGTH );
	run_network( layer_table );
	
	Xil_DCacheInvalidateRange( (INTPTR) layer_table[ NUM_LAYERS - 1 ].dma_addr_out, GAP_CHANNELS );

	uint8_t index_class = classify( 
		(const int8_t*) layer_table[ NUM_LAYERS - 1 ].dma_addr_out, 
		(const float*) DENSE_ADDRESS 
	);

	xil_printf( "Frame ID: %d\n", ocm_mailbox_ptr -> frame_id );
	xil_printf( "Indice de la clase: %d\n", index_class );
	xil_printf( "Clase: %s\n", classes[ index_class ] );
	xil_printf( "Status: %d\n", status_received );

	while( 1 );

	return 0;
}
