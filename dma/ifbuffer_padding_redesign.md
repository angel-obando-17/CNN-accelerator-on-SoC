# Rediseño del IFBuffer para halo real (Conv3x3/DW3x3)

## El problema descubierto (2026-07-01)

El IFBuffer se dimensiono exactamente para el tile nucleo: `TILE_W × TILE_H × cin_groups = 128 × 8 × 4 = 4096` palabras, que es EXACTAMENTE la capacidad total del buffer (`ADDR_WIDTH=12` → 4096 palabras). Cero margen para halo.

El wraparound de `addr_generator.vhd` (`row`/`col` calculados con resta sin signo, `y_counter+ky-1` / `x_counter+kx-1`) "funcionaba" en los testbenches existentes solo porque usan tiles chiquitos (2×2, 4×4 con Cin=16) que dejan muchisimo espacio libre dentro de las 4096 palabras — el halo cae por casualidad en zonas sin usar. A escala completa (128×8×64) no hay ningun hueco: cualquier direccion de halo (wrap o extension normal) cae necesariamente encima de un pixel real del tile, o desborda el ancho de la señal de direccion (`addr_in`, 13 bits) y termina en otro lado igual de problematico. Verificar el punto exacto de colision a mano es delicado porque hay dos truncamientos en juego (`addr_in` de 13 bits, luego el puerto del BRAM de 12 bits) — no se intento calcular con precision, se opto por rediseñar la direccion en vez de parchear el wraparound accidental.

## El rediseño: offset explicito, sin restas

**Formula anterior** (riesgo de wraparound):
```
row = y_counter + ky − 1     -- puede dar -1, se desborda a 15 (4 bits)
col = x_counter + kx − 1     -- puede dar -1, se desborda a 255 (8 bits)
```

**Formula nueva** (offset +1, sin restas, sin desbordamiento):
```
row_buf = y_counter + ky     -- rango 0 .. TILE_H+1, nunca negativo
col_buf = x_counter + kx     -- rango 0 .. TILE_W+1, nunca negativo
```

Con esto: `row_buf=0` es la fila de halo de arriba, `row_buf=1` es la primera fila real del tile, ..., `row_buf=TILE_H+1` es la fila de halo de abajo. Mismo razonamiento para columnas (`col_buf=0` halo izquierdo, `col_buf=TILE_W+1` halo derecho). Cada posicion de halo tiene una direccion fija y predecible, sin depender de que una resta sin signo "convenientemente" de la vuelta.

## Archivos afectados

### `addr_generator.vhd`
- Quitar el `-1` en el calculo de `row`/`col` (formula nueva arriba).
- Cambiar el stride: las filas del buffer ahora tienen `TILE_W+2` columnas, no `TILE_W`. El `tile_w` usado en `term1`/`term2` para `addr_in` pasa a `tile_w + 2`.
- **`addr_out` NO cambia** — las salidas no necesitan halo, esa formula se queda igual.

### `inputf_buf.vhd`, `inputf_buf_a.vhd`, `inputf_buf_b.vhd`
- `ADDR_WIDTH` sube de 12 a 13 bits. Capacidad real necesaria: `(128+2) × (8+2) × 4 = 5200` palabras, cabe en 13 bits (8192 de capacidad).

### `cnn_accelerator.vhd`
- `dma_if_wr_addr` pasa de 12 a 13 bits.
- La conexion `rd_addr => ag_addr_in(11 downto 0)` debe usar los 13 bits completos: `ag_addr_in(12 downto 0)`. Actualmente se descarta el bit mas alto, que es parte del problema.

### Testbenches existentes
`tb_conv3x3.vhd`, `tb_dw3x3.vhd`, `tb_multilayer*.vhd`, etc. — las direcciones "raras" que precargan (255, 315, etc.) ya no significan lo mismo con la formula nueva, hay que recalcularlas. Los valores esperados de salida NO cambian (la aritmetica del computo es la misma), solo las direcciones de precarga de datos de entrada.

## Impacto en recursos

Duplicar `ADDR_WIDTH` de 12 a 13 bits probablemente casi duplica la cantidad de bloques BRAM fisicos que usa el IFBuffer (los BRAM de Xilinx crecen en profundidad por potencias de 2 al cruzar umbrales). Dado que el IFBuffer (con su ping-pong, 2 bancos) es probablemente el mayor consumidor de BRAM del acelerador, esto podria llevar el uso total de BRAM de 44.29% a un estimado de ~60-65%. Ver `dma/resource_estimate.md` (actualizado con esta correccion).

## Estado: VERIFICADO (2026-07-01)

Implementado en `addr_generator.vhd`, `inputf_buf.vhd`, `inputf_buf_a.vhd`, `inputf_buf_b.vhd`, `cnn_accelerator.vhd`. Sintetizado limpio (ver `dma/resource_estimate.md` para el impacto real en BRAM: 69.29%).

Los 8 testbenches de `tb/` se actualizaron con las nuevas direcciones (mucho mas simples que antes: rangos contiguos en vez de wraparound) y se corrigio de paso un problema aparte encontrado en el camino — 7 de los 8 testbenches nunca se habian actualizado con los puertos `tile_ready`/`tile_req` del protocolo TILE_WAIT (solo `tb_multilayer3.vhd` los tenia). Los 8 testbenches pasan sin errores:
`tb_cnn_accelerator`, `tb_conv3x3`, `tb_dw3x3`, `tb_add`, `tb_pool` (2 tests), `tb_multilayer`, `tb_multilayer2`, `tb_multilayer3` (incluye TILE_WAIT).
