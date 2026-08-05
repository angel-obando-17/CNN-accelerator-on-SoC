# Tabla de registros AXI-Lite del DMA

Banco de registros propio del DMA (AXI-Lite slave separado del banco del acelerador, mismo protocolo de 5 canales documentado en `axi/axi_protocol.md`). El PS escribe esto **una sola vez por capa** y el DMA se encarga solo de iterar todos los tiles, coordinando con `tile_req`/`tile_ready` del acelerador, hasta terminar la capa completa.

| Offset | Nombre | R/W | Bits | Descripción |
|---|---|---|---|---|
| 0x00 | DMA_START | W | [0] | Pulso de arranque — dispara el procesamiento autónomo de toda la capa |
| 0x04 | DMA_MODE | W | [1:0] | Modo de la capa (mismo encoding que `reg_mode`) — determina si hace falta halo de 1px alrededor del tile |
| 0x08 | DMA_CIN | W | [6:0] | Canales de entrada |
| 0x0C | DMA_COUT | W | [6:0] | Canales de salida |
| 0x10 | DMA_IMG_W | W | [8:0] | Ancho del feature map de entrada, en píxeles |
| 0x14 | DMA_IMG_H | W | [8:0] | Alto del feature map de entrada, en píxeles |
| 0x18 | DMA_TILE_W | W | [7:0] | Ancho de tile, en píxeles |
| 0x1C | DMA_TILE_H | W | [3:0] | Alto de tile, en píxeles |
| 0x20 | DMA_NUM_TILE_X | W | [1:0] | Número de tiles horizontales |
| 0x24 | DMA_NUM_TILE_Y | W | [5:0] | Número de tiles verticales |
| 0x28 | DMA_HAS_RESIDUAL | W | [0] | 1 = esta capa tiene skip connection |
| 0x2C | DMA_WEIGHT_WORDS | W | [7:0] | Nº de palabras de 128 bits de pesos a transferir (lo calcula el PS, no el hardware) |
| 0x30 | DMA_ADDR_W | W | [31:0] | Dirección DDR de los pesos |
| 0x34 | DMA_ADDR_IN | W | [31:0] | Dirección DDR del feature map de entrada |
| 0x38 | DMA_ADDR_OUT | W | [31:0] | Dirección DDR del feature map de salida |
| 0x3C | DMA_ADDR_RES | W | [31:0] | Dirección DDR del residual (si aplica) |
| 0x40 | DMA_DONE | R | [0] | 1 = el DMA terminó toda la capa (genera IRQ hacia el PS) |
| 0x44 | DMA_POOL_EN | W | [0] | 1 = esta capa tiene pooling activo (MaxPool o GAP) |
| 0x48 | DMA_POOL_TYPE | W | [0] | 0 = MaxPool 2x2, 1 = GAP (mismo encoding que `reg_pool_type`) |
| 0x4C | DMA_BIAS_WORDS | W | [7:0] | Nº de palabras de 128 bits de bias a transferir (lo calcula el PS, no el hardware) |
| 0x50 | DMA_ADDR_BIAS | W | [31:0] | Dirección DDR de los bias |

## Por qué se duplican CIN/COUT/MODE con los registros del acelerador

El DMA es un módulo AXI-Lite separado, sin acceso directo a los registros internos de `axi_lite_slave.vhd` (el banco del acelerador). El PS ya conoce estos valores de la arquitectura del modelo, así que escribirlos dos veces es barato y mantiene los dos módulos desacoplados — cada uno se puede probar por separado.

## Lo que NO va en este banco de registros

`buf_sel` y las señales `dma_if_wr_en/addr/data`, `dma_wb_wr_en/addr/data`, etc. que ya existen en `cnn_accelerator` **no** son registros PS — los va a generar la FSM orquestadora del DMA internamente (Componente 3). No son configuración que el PS escriba, son control interno del DMA hacia el acelerador.

## Direccionamiento DDR

Las fórmulas exactas (IFM con halo, OFM/Residual, pesos) están en `dma/ddr_addressing.md`.
