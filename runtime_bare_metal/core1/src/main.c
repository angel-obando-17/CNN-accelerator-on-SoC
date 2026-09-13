#include "intercore.h"
#include "hsv_segment.h"
#include "xil_mmu.h"
#include "xil_cache.h"
#include "xscugic.h"
#include "xil_exception.h"
#include "xparameters.h"

STATIC_ASSERT( PACKAGE_FRAME_LENGTH == ( WIDTH * HEIGHT * PACKAGING_BYTES_PER_PIXEL ) );
STATIC_ASSERT( RAW_IMAGE_LENGTH == ( WIDTH * HEIGHT * RAW_BYTES_PER_PIXEL ) );

static XScuGic Gic_Handler;
static volatile uint32_t Handler_Flag = 0x0u;

/* Interrupt Handler use only for Core1. */
static void Interrupt_Handler( void* Ref ) {
    (void) Ref;
    Handler_Flag = 0x1u;
}

static void notify_core0( XScuGic* gic_ptr, struct ocm_mailbox_t* const mailbox_ptr, enum status_t status ) {
    mailbox_ptr -> status = status;
    mailbox_ptr -> seg_done = 0x1u;
    
    dsb( );

    XScuGic_SoftwareIntr( gic_ptr, SGI_CORE1_TO_CORE0, INTERCORE_CPU0_MASK );
}

int main( void ) {
    init_tables( );
    Xil_SetTlbAttributes( (INTPTR) OCM_MAILBOX_BASE, NORM_NONCACHE );

    XScuGic_Config* Gic_Config = XScuGic_LookupConfig( XPAR_SCUGIC_0_DEVICE_ID );
    
    if( Gic_Config == NULL ) 
        while( 1 );
    
    if( XScuGic_CfgInitialize( &Gic_Handler, Gic_Config, Gic_Config -> CpuBaseAddress ) != XST_SUCCESS )
        while( 1 );
    
    Xil_ExceptionInit( );
    Xil_ExceptionRegisterHandler( XIL_EXCEPTION_ID_INT, 
                                  (Xil_ExceptionHandler) XScuGic_InterruptHandler,
                                  &Gic_Handler );

    if( XScuGic_Connect( &Gic_Handler, SGI_CORE0_TO_CORE1, Interrupt_Handler, NULL ) != XST_SUCCESS )
        while( 1 );

    XScuGic_Enable( &Gic_Handler, SGI_CORE0_TO_CORE1 );
    
    Xil_ExceptionEnable( );

    struct ocm_mailbox_t* const ocm_mailbox_ptr = ocm_pointer( );
    uint32_t last_id = FRAME_ID_NONE;
    while( 1 ) {
        while( !Handler_Flag );
        
        Handler_Flag = 0x0u;
        ocm_mailbox_ptr -> frame_ready = 0x0u;
        ocm_mailbox_ptr -> status = IN_PROCESS;
    
        uint32_t current_id = ocm_mailbox_ptr -> frame_id;

        if( last_id == current_id ) {
            notify_core0( &Gic_Handler, ocm_mailbox_ptr, FAIL_FRAME_ID_REPEAT );
            continue;
        }

        last_id = current_id;
        
        uint32_t seg_status = packaging_frame( (const uint8_t*) RAW_IMAGE_ADDRESS, 
                                               (int8_t*) PACKAGE_FRAME_ADDRESS );
        Xil_DCacheFlushRange( (INTPTR) PACKAGE_FRAME_ADDRESS, PACKAGE_FRAME_LENGTH );

        notify_core0( &Gic_Handler, ocm_mailbox_ptr, seg_status );
    }

    return 0;
}