#ifndef __INTERCORE_H__
#define __INTERCORE_H__

#include <stdint.h>
#include <stddef.h>

#define OCM_MAILBOX_BASE	0xFFFF0000u

/* CPUs Masks */
#define INTERCORE_CPU1_MASK	0x00000002u /* CPU1 Mask*/
#define INTERCORE_CPU0_MASK	0x00000001u /* CPU0 Mask*/

/* SGI IDs of GIC */
#define SGI_CORE0_TO_CORE1	0x00000000u
#define SGI_CORE1_TO_CORE0	0x00000001u

struct ocm_mailbox_t {
	volatile uint32_t frame_ready; /* Core0 -> Core1 */
	volatile uint32_t seg_done;    /* Core1 -> Core0 */
	volatile uint32_t frame_id;    /* Core0 -> Core1 */
	volatile uint32_t status; 	   /* Core1 -> Core0 */
};

static inline struct ocm_mailbox_t* ocm_pointer( void ) {
	struct ocm_mailbox_t* const ocm_ptr = (struct ocm_mailbox_t*) OCM_MAILBOX_BASE;
	return ocm_ptr;
}

#define CONCAT_AUX( a, b ) a##b
#define CONCAT( a, b ) CONCAT_AUX( a, b )

#define STATIC_ASSERT( cond ) \
	typedef char CONCAT( static_assertion, __LINE__ )[ ( cond ) ? 1 : -1 ]

/* Asserts to catch errors in compilation time. */
STATIC_ASSERT( sizeof( struct ocm_mailbox_t ) == 0x10u );

STATIC_ASSERT( offsetof( struct ocm_mailbox_t, frame_ready ) == 0x00u );
STATIC_ASSERT( offsetof( struct ocm_mailbox_t, seg_done ) == 0x04u );
STATIC_ASSERT( offsetof( struct ocm_mailbox_t, frame_id ) == 0x08u );
STATIC_ASSERT( offsetof( struct ocm_mailbox_t, status ) == 0x0Cu );

#endif
