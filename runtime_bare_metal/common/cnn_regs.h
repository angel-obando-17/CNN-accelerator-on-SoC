#ifndef __CNN_REGS_H__
#define __CNN_REGS_H__

/* Peripheral Definitions for peripheral CNN_TOP_0 */
#define XPAR_CNN_TOP_0_AXI_BASEADDR    0x40000000
#define XPAR_CNN_TOP_0_AXI_HIGHADDR    0x40000FFF

#define REG_START           0x00 /* [ 0 ]    */
#define REG_MODE            0x04 /* [ 1:0 ]  */
#define REG_CIN             0x08 /* [ 6:0 ]  */
#define REG_MAX_INNER       0x0C /* [ 9:0 ]  */
#define REG_MAX_CO          0x10 /* [ 1:0 ]  */
#define REG_MAX_X           0x14 /* [ 6:0 ]  */
#define REG_MAX_Y           0x18 /* [ 2:0 ]  */
#define REG_MAX_TILE_X      0x1C /* [ 0 ]    */
#define REG_MAX_TILE_Y      0x20 /* [ 4:0 ]  */
#define REG_HAS_RESIDUAL    0x24 /* [ 0 ]    */
#define REG_POOL_EN         0x28 /* [ 0 ]    */
#define REG_POOL_TYPE       0x2C /* [ 0 ]    */
#define REG_SHIFT           0x30 /* [ 4:0 ]  */
#define REG_RELU6_VAL       0x34 /* [ 7:0 ]  */
#define REG_GAP_SHIFT       0x38 /* [ 4:0 ]  */
#define REG_MULT            0x3C /* [ 15:0 ] */
#define REG_DONE            0x40 /* [ 0 ]    */
#define REG_STRIDE_EN		0x44 /* [ 0 ]    */

#endif