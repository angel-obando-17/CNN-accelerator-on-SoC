# Direccionamiento DDR por tile

## Decisión de arquitectura: Master simple, orquestadora hace el loop de filas (2026-07-06)

Una fila de la imagen en DDR y una fila del tile en el IFBuffer on-chip tienen strides completamente distintos (imagen completa vs. tile con padding), así que una transferencia de tile **no cabe en una sola ráfaga AXI4** — hace falta una ráfaga por fila.

Se evaluaron dos opciones para dónde vive el loop de filas:
- **Opción A (elegida)**: el AXI4 Master es un bloque simple (una ráfaga = una dirección + un largo, tal como ya está documentado en `axi4_master_role.md`). La FSM orquestadora dispara el master una vez por fila.
- Opción B: el master recibe de una vez (filas, strides, largo) y hace el loop él solo.

Se descartó la Opción B porque el costo real de la A es marginal: el overhead de la orquestadora entre ráfagas (recalcular dirección, volver a disparar) es de unos pocos ciclos, frente a cientos o miles de ciclos de transferencia real por fila (ej. 1040 beats/fila en el peor caso, `TILE_W=128, Cin=64`, bus de 64 bits). Si la orquestadora calcula la siguiente dirección mientras la ráfaga actual sigue en vuelo, el overhead se acerca a cero. Además, con la Opción A el AXI4 Master **no necesita BRAM** — es FSM + contadores en flip-flops, nada de bloques dedicados. Todo el peso de BRAM del proyecto (69.29%) es del acelerador, no del DMA.

## Suposición de layout en DDR

El feature map se guarda en DDR con el **mismo empaquetado que el IFBuffer on-chip**: HWC, 16 canales por palabra de 128 bits (`cin_groups = Cin/16` palabras por posición espacial). Esto es clave: permite copiar una ráfaga de DDR directo al buffer on-chip sin ninguna reordenación de canales.

## Restricción heredada: sin "último tile más chico"

El banco de registros del acelerador no tiene un registro de "ancho del último tile" — todos los tiles de una capa usan el mismo `TILE_W`/`TILE_H`. Esto asume `IMG_W` múltiplo exacto de `TILE_W` (e `IMG_H` de `TILE_H`). Verificado (2026-07-06) contra la arquitectura real entrenada (`CNN/tomatoV2.py`, resolución de despliegue 256×256): las dimensiones espaciales por etapa son 256→128→64→32→16, todas potencias de 2, sin ningún caso de división no exacta con `TILE_H≤8`/`TILE_W≤128`. (La variante experimental de 96×96 sí lo hubiera roto en la etapa de 12×12 — no es la resolución de despliegue, pero queda anotado por si se cambia de resolución en el futuro.)

## IFM — con halo, `TILE_H+2` ráfagas por tile

Para el tile `(tile_x, tile_y)`, cada fila local del buffer con padding (`r_local` de `0` a `TILE_H+1`) mapea a una fila real de la imagen:

```
r_global = tile_y × TILE_H + r_local − 1
```

4 condiciones de borde independientes (no solo "toca el borde o no"):

```
is_top_edge    = (tile_y = 0)
is_bottom_edge = (tile_y = NUM_TILE_Y − 1)
is_left_edge   = (tile_x = 0)
is_right_edge  = (tile_x = NUM_TILE_X − 1)
```

| Fila local | Condición | Acción |
|---|---|---|
| `r_local = 0` | `is_top_edge = 1` | No se lee DDR — cero directo en toda la banda `row_buf=0` del IFBuffer |
| `r_local = TILE_H+1` | `is_bottom_edge = 1` | No se lee DDR — cero en toda la banda `row_buf=TILE_H+1` |
| Cualquier fila válida | `is_left_edge = 1` | La ráfaga arranca en `col_buf=1` (no en 0); se escribe cero aparte en `col_buf=0` |
| Cualquier fila válida | `is_right_edge = 1` | La ráfaga termina en `col_buf=TILE_W` (no en `TILE_W+1`); se escribe cero aparte en `col_buf=TILE_W+1` |

Para una fila que sí existe en DDR:

```
ddr_addr      = DMA_ADDR_IN + r_global × (IMG_W × Cin) + col_ddr_start × Cin
col_ddr_start = tile_x × TILE_W − 1 + (is_left_edge ? 1 : 0)
burst_words   = (TILE_W + 2 − (is_left_edge?1:0) − (is_right_edge?1:0)) × cin_groups
```

El destino local usa la misma fórmula de `addr_generator.vhd` (`row_buf × tile_w_pad × cin_groups + col_buf × cin_groups`), arrancando en `col_buf = (is_left_edge?1:0)`. Para tiles interiores (ninguna condición de borde activa), la ráfaga lee la fila completa con padding y se **solapa a propósito** con el tile vecino — es el comportamiento correcto para que la ventana deslizante del kernel funcione entre tiles.

## OFM y Residual — sin halo, `TILE_H_OUT` ráfagas por tile

```
r_global_out = tile_y × TILE_H_OUT + r_local
ddr_addr      = DMA_ADDR_OUT + r_global_out × (IMG_W_OUT × Cout) + (tile_x × TILE_W_OUT) × Cout
burst_words   = TILE_W_OUT × Cout/16
```

Residual usa la misma fórmula con `DMA_ADDR_RES` (solo si `DMA_HAS_RESIDUAL=1`).

### El pooling cambia la resolución de salida

Si `DMA_POOL_EN=1` y `DMA_POOL_TYPE=0` (MaxPool 2x2, stride 2 fijo — MobileNetV2 nunca usa otro stride para pooling): `TILE_W_OUT = TILE_W >> 1`, `TILE_H_OUT = TILE_H >> 1`, `IMG_W_OUT = IMG_W >> 1`. Un simple corrimiento de 1 bit en hardware, no hace falta que el PS calcule y mande un valor aparte — por eso solo se agregaron `DMA_POOL_EN`/`DMA_POOL_TYPE` a `dma_registers.md`, no un registro de dimensión de salida.

### Caso especial GAP

El `gap_unit` acumula sobre **todos** los tiles de la capa (el flush solo ocurre después del último tile, cuando `layer_done=1`). El DMA **no debe drenar OFBuffer por tile** en capas GAP — se escribe una sola vez, al final, después del `irq_out` de la capa completa. Para MaxPool (o sin pooling) sí se drena por tile, en cada `TILE_WAIT`.

## Pesos — una sola ráfaga por capa (no por tile)

```
ddr_addr    = DMA_ADDR_W
burst_words = DMA_WEIGHT_WORDS
```

Se cargan una vez al inicio de la capa (los pesos son los mismos para todos los tiles).
