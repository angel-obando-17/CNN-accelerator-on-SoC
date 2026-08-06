#ifndef __DMA_REGS_H__
#define __DMA_REGS_H__

/* Peripheral Definitions for peripheral CNN_TOP_0, DMA control/status interface
 * (AXI-Lite slave "s_axi" -> PS M_AXI_GP1). Same value as the auto-generated
 * XPAR_CNN_TOP_0_BASEADDR in xparameters.h -- restated here with an explicit
 * name for symmetry with XPAR_CNN_TOP_0_AXI_BASEADDR above. */
#define XPAR_CNN_TOP_0_S_AXI_BASEADDR  0x80000000
#define XPAR_CNN_TOP_0_S_AXI_HIGHADDR  0x80000FFF

#define DMA_START           0x00 /* [ 0 ]    */
#define DMA_MODE            0x04 /* [ 1:0 ]  */
#define DMA_CIN             0x08 /* [ 6:0 ]  */
#define DMA_COUT            0x0C /* [ 6:0 ]  */
#define DMA_IMG_W           0x10 /* [ 8:0 ]  */
#define DMA_IMG_H           0x14 /* [ 8:0 ]  */ 
#define DMA_TILE_W          0x18 /* [ 7:0 ]  */
#define DMA_TILE_H          0x1C /* [ 3:0 ]  */
#define DMA_NUM_TILE_X      0x20 /* [ 1:0 ]  */
#define DMA_NUM_TILE_Y      0x24 /* [ 5:0 ]  */
#define DMA_HAS_RESIDUAL    0x28 /* [ 0 ]    */
#define DMA_WEIGHT_WORDS    0x2C /* [ 7:0 ]  */
#define DMA_ADDR_W          0x30 /* [ 31:0 ] */
#define DMA_ADDR_IN         0x34 /* [ 31:0 ] */
#define DMA_ADDR_OUT        0x38 /* [ 31:0 ] */
#define DMA_ADDR_RES        0x3C /* [ 31:0 ] */
#define DMA_DONE            0x40 /* [ 0 ]    */   
#define DMA_POOL_EN         0x44 /* [ 0 ]    */
#define DMA_POOL_TYPE       0x48 /* [ 0 ]    */
#define DMA_BIAS_WORDS      0x4C /* [ 7:0 ]  */
#define DMA_ADDR_BIAS       0x50 /* [ 31:0 ] */

#endif