# Límites duros del hardware — especificación para `generate_layer_table.py`

**Escrito 2026-09-08.** Reúne todas las restricciones que el RTL impone sobre
la configuración de una capa, derivadas leyendo anchos de registro y
profundidades de BRAM archivo por archivo.

> **Todas fallan en silencio.** No hay ni un chequeo en el RTL: pasarse de
> cualquiera de estos límites no da error, no cuelga nada y no levanta ninguna
> bandera — simplemente trunca la dirección o el valor y produce datos
> corruptos varias capas más adelante. Por eso este documento existe: el lugar
> donde se atrapan es `generate_layer_table.py`, con `assert` explícitos.

## Resumen — la tabla de asserts

Cada fila es un `assert` que el generador tiene que hacer por capa.

| # | Restricción | Origen en el RTL |
|---|---|---|
| 1 | `weight_words ≤ 256` | `weight_buf` tiene 256 palabras; direcciones truncadas a 8 bits |
| 2 | `bias_words ≤ 16` | `bias_buf` tiene 16 palabras; dirección truncada a 4 bits |
| 3 | `Cin ≤ 64` y `Cout ≤ 64` | `max_co` es de 2 bits → 4 grupos × 16 canales |
| 4 | `tile_w_out ≤ 128` | `max_x` es de 7 bits |
| 5 | `tile_h_out ≤ 8` | `max_y` es de 3 bits |
| 6 | `tile_h_out ≤ 7` **en capas con stride o pool** | `DMA_TILE_H` es de 4 bits y el tile de entrada es el doble |
| 7 | `tile_w_out ≤ 127` **en capas con stride o pool** | `DMA_TILE_W` es de 8 bits y el tile de entrada es el doble |
| 8 | `num_tile_x ≤ 2` | `max_tile_x` es de 1 bit |
| 9 | `num_tile_y ≤ 32` | `max_tile_y` es de 5 bits |
| 10 | `img_w ≤ 511` | `DMA_IMG_W` es de 9 bits |
| 11 | `(tile_w_in + 2) · cin_groups · (tile_h_in + 2) ≤ 8192` | capacidad del IFBuffer |
| 12 | `tile_w_out · tile_h_out · cout_groups ≤ 4096` | capacidad del OFBuffer y del Residual Buffer |
| 13 | `max_inner` exacto según el modo | número de operaciones de MAC por píxel |
| 14 | `max_co = ceil(Cout/16) − 1` | consistencia con `Cout` del DMA |
| 15 | todas las direcciones DDR múltiplo de **16 bytes** | palabras de 128 bits + el cálculo de frontera de 4 KB |
| 16 | empaquetado DDR de `ceil(C/16)·16` bytes por píxel | Opción 1b |

---

## 1. `weight_words ≤ 256`

`weight_buffer.vhd` declara `ADDR_WIDTH = 8` → **256 palabras** de 128 bits.
Y las dos rutas de dirección están truncadas a 8 bits:

- escritura: `dma_wb_wr_addr <= comb_wr_addr( 7 downto 0 )` (`dma_engine.vhd`)
- lectura: `rd_addr => ag_addr_w( 7 downto 0 )` (`cnn_accelerator.vhd`)

Pedir más palabras **se envuelve sobre la dirección 0** sin avisar.

Cuántas hace falta por modo (una palabra = los 16 pesos de un grupo `co`):

| Modo | Palabras | Peor caso real |
|---|---|---|
| Conv3×3 | `num_co · Cin · 9` | `conv1`: 2 · 3 · 9 = 54 |
| DW3×3 | `num_co · 9` | 4 · 9 = 36 |
| PW1×1 | `num_co · Cin` | **4 · 64 = 256 — justo en el límite** |

Las 8 capas PW1×1 con `Cin = Cout = 64` (`irb6_pw`, `irb7_exp`, `irb7_pw`,
`irb8_exp`, `irb8_pw`, `irb9_exp`, `irb9_pw`, `conv_last`) usan **exactamente**
las 256 palabras. Cero margen: cualquier capa futura con más canales o un
kernel más grande no entra.

> Éste es el límite que ya causó un bug real: `layer_table.h` declaraba
> `dma_weight_words` como `uint8_t`, donde 256 vale 0.

## 2. `bias_words ≤ 16`

`bias_buf.vhd` declara `ADDR_WIDTH = 4` → **16 palabras** de 128 bits, y
`dma_bb_wr_addr <= comb_wr_addr( 3 downto 0 )`.

Cada grupo `co` necesita 4 palabras (16 bias de 32 bits = 512 bits), y el
buffer se indexa como `rd_addr · 4 + k` con `rd_addr = co_counter`. Entonces:

```
bias_words = 4 · num_co        (máximo 4 · 4 = 16, justo en el límite)
```

**Cuidado:** hay que cargar los grupos **completos**, no sólo el primero. Con
`max_co = 1` y `bias_words = 4`, el grupo 1 lee BRAM sin inicializar y
contamina la salida con `'X'`. Los testbenches ya documentan esta trampa.

## 3. Canales ≤ 64

`max_co` es de 2 bits → como mucho 4 grupos de 16 canales. `cin` es de 7 bits
(≤ 127) pero el límite efectivo lo pone `max_co`. El modelo de producción
respeta esto: `mobilenetv2.py` capa `exp_ch = min(in_ch · expand_ratio, max_ch)`
con `max_ch = 64`.

## 4-7. Geometría del tile

Del lado del **acelerador**, el tile es el de **salida**:

- `max_x` de 7 bits → `tile_w_out ≤ 128`
- `max_y` de 3 bits → `tile_h_out ≤ 8`

Del lado del **DMA**, el tile es el de **entrada**, que en capas con `stride`
o `pool` es el doble:

- `DMA_TILE_W` de 8 bits → `tile_w_in ≤ 255` → con stride, `tile_w_out ≤ 127`
- `DMA_TILE_H` de 4 bits → `tile_h_in ≤ 15` → con stride, `tile_h_out ≤ 7`

**Consecuencia concreta para `conv1`:** su salida es de 128 columnas. Con un
solo tile haría falta `tile_w_out = 128` y por lo tanto `tile_w_in = 256`, que
no entra en los 8 bits de `DMA_TILE_W`. **`conv1` obliga a 2 tiles
horizontales** de 64 columnas cada uno.

## 8-9. Cantidad de tiles

- `max_tile_x` es **un solo bit** → **máximo 2 tiles horizontales**. El
  registro del DMA `DMA_NUM_TILE_X` es de 2 bits (hasta 3), pero el que manda
  es el del acelerador: 2.
- `max_tile_y` de 5 bits → hasta 32 tiles verticales (`DMA_NUM_TILE_Y` de 6
  bits llega a 63, pero de nuevo manda el acelerador).

Con `tile_h_out ≤ 8` y 32 tiles verticales, la altura máxima de imagen que el
hardware puede recorrer es de 256 filas de salida.

## 10. `img_w ≤ 511`

`DMA_IMG_W` es de 9 bits. La entrada de 256 entra sin problema.

## 11. Capacidad del IFBuffer

`inputf_buf_a.vhd` con `ADDR_WIDTH = 13` → **8192 palabras** de 128 bits. Lo
que ocupa un tile, con su halo de una fila/columna a cada lado:

```
(tile_w_in + 2) · cin_groups · (tile_h_in + 2) ≤ 8192
```

donde `cin_groups = ceil(Cin/16)` y `tile_*_in` es el tile de **entrada**
(el doble del de salida en capas con stride o pool).

El peor caso que los registros permiten es `(128+2) · 4 · (8+2) = 5.200`
palabras — entra, pero el margen no es infinito: una capa con stride,
`Cin = 64` y un tile grande sí se puede pasar. **Hay que evaluar la fórmula,
no confiar en que "siempre entra".**

## 12. Capacidad del OFBuffer y del Residual Buffer

`outputf_buf.vhd` y `residual_buf.vhd` con `ADDR_WIDTH = 12` → **4096
palabras** cada uno:

```
tile_w_out · tile_h_out · cout_groups ≤ 4096
```

El peor caso permitido, `128 · 8 · 4 = 4.096`, da **exactamente** la capacidad.
Cero margen.

## 13. `max_inner` exacto

Es la cantidad de operaciones de MAC por (píxel, grupo `co`) — no un máximo
holgado, tiene que ser el valor exacto:

| Modo | `reg_mode` | `max_inner` |
|---|---|---|
| Conv3×3 | `"00"` | `Cin · 9` |
| DW3×3 | `"01"` | `9` |
| PW1×1 | `"10"` | `Cin` |

`max_inner` es de 10 bits; el peor caso (`Conv3×3` con `Cin = 64`) da 576.

## 14. `max_co` consistente con `Cout`

`max_co` (registro del acelerador) y `Cout` (registro del DMA) describen la
misma cantidad por dos caminos distintos. Tienen que cumplir:

```
max_co = ceil(Cout / 16) − 1
```

**Esto ya causó un bug**: `GAP_FLUSH` derivaba el número de grupos de `Cout`
con `floor` mientras `gap_unit` lo derivaba de `max_co` — y con `Cout = 24`
el último grupo de canales nunca se volcaba a DDR.

## 15. Alineación de las direcciones DDR a 16 bytes

Todas las direcciones base (`DMA_ADDR_IN`, `ADDR_OUT`, `ADDR_W`, `ADDR_RES`,
`ADDR_BIAS`) tienen que ser **múltiplo de 16 bytes**. Dos razones:

1. Los buffers on-chip son de palabras de 128 bits y los masters ensamblan
   cada palabra con 2 beats de 64 bits: una base desalineada rompe el
   emparejamiento.
2. **Requisito nuevo desde el fix de la frontera de 4 KB** (2026-09-08): los
   masters calculan cuánto falta para el próximo límite de página como
   `256 − ddr_addr( 11 downto 4 )`, lo cual asume que los 4 bits bajos son
   cero. Con una base desalineada el cálculo se queda corto y la ráfaga
   vuelve a cruzar.

Los desplazamientos internos (`row_stride`, `term2`) ya son múltiplos de 16 por
construcción desde la Opción 1b, así que alcanza con alinear las bases.

## 16. Empaquetado en DDR

Desde la Opción 1b (ver [`cin_grouping_gap.md`](cin_grouping_gap.md)), cada
píxel de un feature map ocupa en DDR:

```
ceil(C / 16) · 16 bytes        (no C bytes)
```

Para las 23 capas con `Cin`/`Cout` múltiplo de 16 es lo mismo de siempre. Para
las 5 restantes (`conv1` con `Cin=3`, `irb2_pw`/`irb3_pw` con `Cout=24`,
`irb3_exp`/`irb4_exp` con `Cin=24`) hay relleno, y el generador tiene que
reservar y direccionar con ese tamaño.

**Esto incluye el frame de entrada**: Core 1 (segmentación HSV) tiene que
escribir la imagen que alimenta a `conv1` a **16 bytes por píxel** (3 reales +
13 de relleno), no a 3.

---

## Lo que NO está limitado

Para evitar búsquedas inútiles:

- `DMA_MODE` (0x04) y `DMA_IMG_H` (0x14) se guardan en `reg_bank` pero
  **ningún módulo los lee**. Escribirlos es inofensivo y no configura nada.
- `REG_START` (0x00 del acelerador) está `open` en `cnn_top.vhd`. El
  acelerador lo arranca el DMA por hardware; escribirlo desde el PS no hace
  nada. Ver `../../../runtime_bare_metal/docs/scheduler_flow.md`.
- El ancho de `addr_w` en el acelerador es de 12 bits, pero el truncamiento a
  8 bits en `cnn_accelerator.vhd` es el que manda — vale el límite 1, no 4096.
