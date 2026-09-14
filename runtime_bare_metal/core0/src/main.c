#include <string.h>

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
#include "ff.h"

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

static FATFS Fat_Instance;

/* Interrupt Handler use only for Core0. */
static void Interrupt_Handler( void* Ref ) {
    (void) Ref;
    Handler_Flag = 0x1u;
}

struct data_sizes {
	uint32_t weights_size;
	uint32_t bias_size;
	uint32_t dense_size;
};

static struct data_sizes calculate_sizes( const struct layer_config_t* lyr_table ) {
	struct data_sizes data;
	data.weights_size = ( lyr_table[ NUM_LAYERS - 1 ].dma_addr_w  + ( lyr_table[ NUM_LAYERS - 1 ].dma_weight_words << 4 ) )
	                    - lyr_table[ 0 ].dma_addr_w;
	data.bias_size = ( lyr_table[ NUM_LAYERS - 1 ].dma_addr_bias + ( lyr_table[ NUM_LAYERS - 1 ].dma_bias_words << 4 ) )
	                 - lyr_table[ 0 ].dma_addr_bias;
	
	data.dense_size = ( GAP_CHANNELS * NUM_CLASSES + NUM_CLASSES ) * 4;

	return data;
}

static void flush_model_data( const struct layer_config_t* lyr_table, const struct data_sizes* data ) {
	Xil_DCacheFlushRange( (INTPTR) lyr_table[ 0 ].dma_addr_w, data -> weights_size );
	Xil_DCacheFlushRange( (INTPTR) lyr_table[ 0 ].dma_addr_bias, data -> bias_size );	
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

static void load_file( const char* path, uint32_t address, size_t bytes_to_read ) {
	static FIL Fil_Instance;

	FRESULT data_open_status = f_open( &Fil_Instance, path, FA_READ );

	if( data_open_status != FR_OK ) {
		xil_printf( "ERROR: f_open failed to read %s. Code: %d\r\n", path, data_open_status );
		while( 1 );
	}

	if( f_size( &Fil_Instance ) != bytes_to_read ) {
		xil_printf( "ERROR: Incorrect file %s, size don't match.\n", path );
		while( 1 );
	}

	UINT bytes_read;
	FRESULT read_data_status = f_read( 
		&Fil_Instance, 
		(void*) address, 
		(UINT) bytes_to_read, 
		&bytes_read 
	);

	if( read_data_status == FR_OK ) {
		if( bytes_read != bytes_to_read  ) {
			xil_printf( "ERROR: Bytes requested by %s don't match.\n", path );
			while( 1 );
		}
	} else {
		xil_printf( "ERROR: f_read failded in file %s with code%d.\n", path, read_data_status );
		while( 1 );	
	}

	xil_printf( "Correct load file %s in Memory at Address 0x%08x.\n", path, address );

	f_close( &Fil_Instance );
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

	FRESULT mount_status = f_mount( &Fat_Instance, "0:/", 1 );
	if( mount_status != FR_OK ) {
		xil_printf( "Fail Mount Error: %d\n", mount_status );
		while( 1 );
	}
	
	const struct data_sizes sizes = calculate_sizes( layer_table );
	load_file( "WEIGHTS.bin", layer_table[ 0 ].dma_addr_w, sizes.weights_size );
	load_file( "BIAS.bin", layer_table[ 0 ].dma_addr_bias, sizes.bias_size );
	load_file( "DENSE.bin", DENSE_ADDRESS, sizes.dense_size );

	DIR current_dir;
	FILINFO current_file;

	FRESULT open_dir_status = f_opendir( &current_dir, "0:/IMAGES" );
	if( open_dir_status != FR_OK ) {
		xil_printf( "ERROR: Can't open directory, Code: %d.\n", open_dir_status );
		while( 1 );
	}

	flush_model_data( layer_table, &sizes );
	if( layer_table[ 0 ].dma_addr_in != PACKAGE_FRAME_ADDRESS )
		while( 1 );

	FRESULT dir_status;
	uint32_t current_id = FRAME_ID_NONE;
	for( ; ; ) {
		dir_status = f_readdir( &current_dir, &current_file );
		if( dir_status != FR_OK ) {
			xil_printf( "ERROR: Can't read directory, Code: %d\n", dir_status );
			while( 1 );
		}
		if( current_file.fname[ 0 ] == '\0' ) break;
		if( current_file.fattrib & AM_DIR ) {
			xil_printf( "	<DIR>	%s\n", current_file.fname );
			continue;
		}
		xil_printf( "File: %s\n", current_file.fname );

		if( current_file.fsize != RAW_IMAGE_LENGTH ) {
			xil_printf( "File don't match size to %d, file skip.\n", RAW_IMAGE_LENGTH );
			continue;
		}

		char file_name[ 23 ];

		strcpy( file_name, "0:/IMAGES/" );
		strcat( file_name, current_file.fname );

		load_file( file_name, RAW_IMAGE_ADDRESS, RAW_IMAGE_LENGTH );

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

		xil_printf( "Image File: %s\n", current_file.fname );
		xil_printf( "Clase: %s\n", classes[ index_class ] );
	}
	f_closedir( &current_dir );

	while( 1 );

	return 0;
}
