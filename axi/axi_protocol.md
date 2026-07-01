Como se ha mencionado a lo largo del proyecto, este no depende unicamente de la FPGA que viene en el SoC Zynq-7020, ya que es un trabajo de perfecta sincronizacion entre el PS, PL y la DDR3, entonces para asegurar la correcta comunicacion entre estos modulos se hara uso del protocolo AXI, protocolo estándar de la especificación AMBA de ARM, ampliamente adoptado en SoCs que integran procesadores ARM, como el Zynq-7020.

# AXI-Lite

En el Zynq-7020, el procesador ARM (PS) y la FPGA(PL) son chips separados que comparten un bus. Para que el ARM le diga, en este caso al acelerador "arranca", "usa modo Conv3x3", "aquí está la dirección de los pesos", etc., necesitan un canal de comunicación. Ese canal es AXI-Lite.

El acelerador expone una especie de "memoria pequeña" de registros. El ARM lee y escribe en esa memoria usando direcciones, igual que haría con cualquier periférico. Donde se define qué hace cada dirección.

## ¿Como Funciona?

AXI-Lite tiene 5 canales, cada uno con dos señales clave: VALID (el que envía dice "tengo dato") y READY (el que recibe dice "puedo aceptar"). La transferencia ocurre cuando ambos están en '1' al mismo tiempo. Esto se llama handshake.

Los 5 canales son:


| Canal | Dirección | Para qué |
|---|---|---|
|  AW (Address Write) | Master -> Slave |  ARM envía la dirección donde va a escribir |
|  W (Write Data) | Master -> Slave | ARM envía el dato a escribir |
| B (Write Response) | Slave -> Master | Acelerador confirma "escritura OK" |
| AR (Address Read) | Master -> Slave | ARM envía la dirección que quiere leer |
| R  (Read Data) | Slave -> Master | Acelerador devuelve el dato leído |

El SoC Zynq tiene ports dedicados para conectar el PS a la logica PL. 

- AXI-GP0/GP1 (General Purpose): el PS es Master, slave es el AXI-Lite de control. Ancho 32 bits, velocidad moderada — perfecto para registros.
- AXI-HP (High Performance): DMA será Master, el PS es Slave hacia la DDR. Ancho 64/32 bits, alta velocidad — para mover feature maps.

# Tabla de registros AXI-Lite entre PS y PL

| Offset |      Nombre      | R/W | Bits  |      Señal en        |                  Descripción                   |
|---|---|---|---|---|---|
| 0x00   | REG_START        | W   | [0]   | reg_start            | Pulso de arranque                              |
| 0x04   | REG_MODE         | W   | [1:0] | reg_mode             | 00=Conv3x3, 01=DW3x3, 10=PW1x1, 11=ADD         |
| 0x08   | REG_CIN          | W   | [6:0] | cin                  | Canales de entrada (≤64)                       |
| 0x0C   | REG_MAX_INNER    | W   | [9:0] | max_inner            | Nº de MACs válidos por pixel (Conv3x3: Cin×9,  |
| 0x10   | REG_MAX_CO       | W   | [1:0] | max_co               | Índice máximo de grupos de Cout (count−1)      |
| 0x14   | REG_MAX_X        | W   | [6:0] | max_x                | Índice máximo de columnas en el tile (count−1) |
| 0x18   | REG_MAX_Y        | W   | [2:0] | max_y                | Índice máximo de filas en el tile (count−1)    |
| 0x1C   | REG_MAX_TILE_X   | W   | [0]   | max_tile_x           | 0=un tile horizontal, 1=dos tiles horizontales |
| 0x20   | REG_MAX_TILE_Y   | W   | [4:0] | max_tile_y           | Índice máximo de tiles verticales (count−1)    |
| 0x24   | REG_HAS_RESIDUAL | W   | [0]   | reg_has_residual     | 1=esta capa tiene skip connection              |
| 0x28   | REG_POOL_EN      | W   | [0]   | reg_pool_en          | 1=habilita pool unit                           |
| 0x2C   | REG_POOL_TYPE    | W   | [0]   | reg_pool_type        | 0=MaxPool 2×2, 1=GAP                           |
| 0x30   | REG_SHIFT        | W   | [4:0] | shift                | Shift aritmético para requantización           |
| 0x34   | REG_RELU6_VAL    | W   | [7:0] | relu6_val            | Valor cap para ReLU6 (post-quant)              |
| 0x38   | REG_GAP_SHIFT    | W   | [4:0] | gap_shift            | Shift para normalización del GAP               |
| 0x40   | REG_DONE         | R   | [0]   | reg_done             | 1=acelerador terminó (también genera IRQ)      | 