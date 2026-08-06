#ifndef __CNN_REGS_H__
#define __CNN_REGS_H__

/* Peripheral Definitions for peripheral CNN_TOP_0, CNN control/status interface
 * (AXI-Lite slave "axi" -> PS M_AXI_GP0). Manually defined: Vitis's xparameters.h
 * generator only supports one BASEADDR per IP instance and does not export this
 * second AXI-Lite interface. Value confirmed against the real hardware address
 * map (system_bd.hwh, MEMRANGE for SLAVEBUSINTERFACE="axi"). If the Block Design's
 * address map ever changes, this must be updated to match. */
#define XPAR_CNN_TOP_0_AXI_BASEADDR    0x40000000
#define XPAR_CNN_TOP_0_AXI_HIGHADDR    0x40000FFF

#define REG_START           0x00
#define REG_MODE            0x04
#define REG_CIN             0x08
#define REG_MAX_INNER       0x0C
#define REG_MAX_CO          0x10
#define REG_MAX_X           0x14
#define REG_MAX_Y           0x18
#define REG_MAX_TILE_X      0x1C
#define REG_MAX_TILE_Y      0x20
#define REG_HAS_RESIDUAL    0x24
#define REG_POOL_EN         0x28
#define REG_POOL_TYPE       0x2C
#define REG_SHIFT           0x30
#define REG_RELU6_VAL       0x34
#define REG_GAP_SHIFT       0x38
#define REG_MULT            0x3C
#define REG_DONE            0x40

#endif