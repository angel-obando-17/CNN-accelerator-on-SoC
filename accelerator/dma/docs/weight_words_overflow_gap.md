# HALLAZGO: `DMA_WEIGHT_WORDS` (8 bits) no alcanza para el peor caso real de PW1x1 — necesita 256, el registro solo llega a 255

**Origen: sesión PS, 2026-09-03**, durante el Paso 4 de `generate_layer_table.py`
(calcular `dma_weight_words`/`dma_addr_w` por capa, necesario antes de poder
asignar direcciones DDR). Se documenta en `dma/docs/` porque es un límite del
registro del lado DMA, no del acelerador. Tercer hallazgo de la serie
hardware↔modelo entrenado, después de `stride_support_gap.md` y
`cnn_accelerator/docs/cin_grouping_gap.md`.

## El hallazgo, en una frase

**`DMA_WEIGHT_WORDS` es un registro de 8 bits (máx `255`), pero el peor caso
real de pesos de una capa PW1x1 con `Cin=Cout=64` (que el modelo de
producción sí alcanza, 8 veces) necesita `256` palabras — un valor que el
registro no puede representar.**

## Confirmado en RTL real, no solo en la fórmula

**Ancho del registro** — `reg_bank.vhd`:

```vhdl
-- línea 46 (puerto de salida)
dma_weight_words  : out std_logic_vector(  7 downto 0 );
-- línea 89 (registro interno)
signal r2c_weight_words : std_logic_vector(  7 downto 0 );
```

8 bits de verdad, no un artefacto de la documentación (`dma_regs.h` coincide:
`DMA_WEIGHT_WORDS 0x2C /* [ 7:0 ] */`).

**Semántica: conteo literal, no `count-1` estilo AXI4** —
`axi4_read_master.vhd`, línea 78:

```vhdl
when IDLE =>
    if( start = '1' ) then
        ...
        sig_words_left <= unsigned( burst_words );
```

El valor se carga tal cual en un contador que se decrementa hasta cero
(`CHECK_MORE`: `if sig_words_left = 0 then done <= '1'`). No hay ninguna
codificación `-1` de por medio que permita que `255` represente `256`
palabras — el registro tiene que contener el número real.

**El wire interno SÍ tiene margen, la fuente no** — `ddr_addr_gen.vhd`:

```vhdl
burst_words <= "00" & weight_words;  -- "00" + 8 bits = 10 bits totales
```

El bus `burst_words` que de verdad llega al master AXI4 es de **10 bits**
(hasta 1023) — el cuello de botella real es exclusivamente el registro
`DMA_WEIGHT_WORDS` de 8 bits en `reg_bank.vhd`, que trunca el valor antes de
que llegue a ese wire más ancho.

## La fórmula y por qué 256 es alcanzable de verdad

De `architecture.md` (confirmado contra `addr_generator.vhd`):

- Conv3x3: `weight_words = num_co_groups × Cin × 9`
- DW3x3: `weight_words = num_co_groups × 9`
- PW1x1: `weight_words = num_co_groups × Cin`

con `num_co_groups = ceil(Cout / 16)`. Para PW1x1 con `Cin = Cout = 64`:
`num_co_groups = 4`, `weight_words = 4 × 64 = 256`.

`architecture.md` ya había calculado este caso (sección "Weight Buffer —
`addr_w`") pero como **índice máximo de dirección** (`addr_w^max = 255`, un
valor de dirección 0-indexado), no como **cantidad de palabras a transferir**
(`255 + 1 = 256`) — son dos números relacionados pero distintos, y
`DMA_WEIGHT_WORDS` necesita el segundo. No es un error de esa sección del
doc (la dirección máxima válida en el Weight Buffer sí es `255`, y cabe
perfecto en los 12 bits de `addr_w`), es que nadie conectó ese número con el
ancho del registro de conteo de transferencia hasta ahora.

## A quién afecta — contra la tabla de 23 capas del Paso 3

De las 23 capas ya confirmadas libres del hallazgo de `cin_grouping_gap.md`,
**8 tienen `Cin = Cout = 64` en modo PW1x1** y necesitan `weight_words=256`:

| Capa |
|---|
| `irb6_pw` |
| `irb7_exp` |
| `irb7_pw` |
| `irb8_exp` |
| `irb8_pw` |
| `irb9_exp` |
| `irb9_pw` |
| `conv_last` (fusionada con `gap`) |

Las otras 15 de las 23 no llegan a `256` (el siguiente peor caso es `128`,
en `irb5_exp`/`irb5_pw`/`irb6_exp`) y no están afectadas por este hallazgo.

`DMA_BIAS_WORDS` (también 8 bits) **no tiene el mismo problema** — el peor
caso real (`Cout=64`, bias empaquetado 4 valores INT32 por palabra de 128
bits) es `ceil(64/4)=16` palabras, muy por debajo de 255.

## Impacto — bloquea el Paso 4 de `generate_layer_table.py`

El Paso 4 (direcciones/tamaños DDR) necesita `dma_weight_words` para saber
cuánto ocupa el blob de pesos de cada capa y dónde puede empezar el
siguiente. Para las 8 capas de la tabla no se puede escribir un valor válido
en el registro — quedan bloqueadas hasta que se resuelva esto. Las otras 15
de las 23 (y las 5 ya bloqueadas por `cin_grouping_gap.md`) no cambian de
estado por este hallazgo.

## Parte 2 — RESUELTO (sesión PL, 2026-09-05): fix aplicado y verificado, más un hallazgo extra en `axi4_read_master.vhd`

Se implementó la Opción 1 (ensanchar `DMA_WEIGHT_WORDS` de 8 a 10 bits) y,
antes de darla por buena, se armó un testbench aislado (`tb_weight_words.vhd`,
scratch, no en el repo) para confirmarla en simulación: PW1x1, `Cin=Cout=64`,
`weight_words=256`, 1 pixel, activación y pesos = 1 en todos los canales
(suma esperada = 64 en cada uno de los 64 canales de salida).

**Hallazgo extra al correr el caso SIN el fix (RTL de 8 bits), para
entender exactamente cómo fallaba:** escribir `256` (`0x100`) en un
registro de 8 bits no lo "capa" a 255 — trunca a los 8 bits bajos, que da
literalmente **0** (`0x100 mod 256 = 0`). Pero el resultado NO fue "cero
pesos cargados" limpio — fue **corrupción parcial**: los canales 0-31 (2
de los 4 grupos) salieron bien, los canales 32-63 salieron indefinidos
(`'X'` en simulación). La causa: en `axi4_read_master.vhd`, la FSM entra a
`AR_ADDR` sin chequear `sig_words_left` (arranca al menos una ráfaga
siempre que `start='1'`), y el cálculo de `sig_arlen`

```vhdl
sig_arlen <= ... else std_logic_vector( resize( shift_left( sig_words_left, 1 ) - 1, 8 ) );
```

con `sig_words_left=0` calcula `0 - 1` en aritmética `unsigned`, que
**desborda a `1023`**, recortado a 8 bits da `255` → dispara una ráfaga
fantasma de 256 beats (128 palabras locales) que no debería existir. Por
eso la mitad del weight buffer sí se llenaba (por pura casualidad de que
esa ráfaga fantasma cubre exactamente la primera mitad de las 256 palabras
reales) y la otra mitad quedaba sin tocar.

Es un bug latente aparte, en `axi4_read_master.vhd` (arranca ráfaga con
`words_left=0` sin chequeo previo) — **no hace falta tocarlo**: con el
registro ya en 10 bits, `weight_words` nunca vale `0` para una capa real,
así que esa rama nunca se dispara. Queda anotado por si en el futuro
aparece otro caso legítimo con `burst_words=0`.

**Fix aplicado — 3 archivos, mecánico, 8→10 bits:**
- `dma/rtl/reg_bank.vhd`: puerto `dma_weight_words`, señal
  `r2c_weight_words`, captura de escritura (`dma_w_data(9 downto 0)`) y
  exposición de lectura (`sig_r_data <= (31 downto 10=>'0') & r2c_weight_words`).
- `dma/rtl/ddr_addr_gen.vhd`: puerto `weight_words` a 10 bits;
  `burst_words <= weight_words;` (ya no hace falta el `"00" &`, que
  desbordaría los 10 bits de `burst_words` si se dejara).
- `dma/rtl/dma_engine.vhd`: señal interna `rb_weight_words` a 10 bits.
- Cosmético: `runtime_bare_metal/common/dma_regs.h`, comentario de
  `DMA_WEIGHT_WORDS` actualizado a `[9:0]` (avisar a PS, header compartido).

**Validación — sin romper nada:**
- `tb_weight_words.vhd` (PW1x1, Cin=Cout=64, weight_words=256): RTL viejo
  → falla exactamente como se describe arriba (canales 32-63 en `X`); RTL
  con el fix → **8/8 canales OK**.
- Suite de regresión completa (`tb_cnn_top_stride.vhd`, Casos A–H2): **sin
  ninguna regresión** — A, B, C, D, E, F, H limpios (ninguno de esos casos
  usa `weight_words>255`, así que el ensanche no los toca); F2/G/H2 con las
  mismas fallas ya conocidas de [[project_cin_grouping_gap]] (gap de
  empaquetado, no relacionado).
- Verificado también en combinación con el prototipo de la Opción 1b de
  `cin_grouping_gap.md` (Parte 7) — compone sin conflicto.

**Estado real de los archivos (2026-09-05):** los 3 cambios de RTL están
aplicados y verificados en `dma/rtl/` (la ruta que Vivado usa activamente,
confirmado contra el `.xpr`) — no hace falta ningún sync adicional para
este hallazgo (a diferencia de `addr_generator.vhd`, que vive en
`architecture_pl/architecture_pl.srcs/sources_1/new/`).

## Opciones para resolver (sin decidir acá)

1. **Ensanchar el registro** — `DMA_WEIGHT_WORDS` de 8 a 10 bits (el wire
   interno de `ddr_addr_gen.vhd` ya es de 10 bits, así que el resto del
   datapath no necesita ningún cambio). Cambio mecánico en `reg_bank.vhd`
   (ancho del puerto/señal) y `dma_regs.h` (documentar el nuevo rango). Es
   el mismo tipo de fix que viene de sizing, no de lógica — bajo riesgo.
2. **Partir la carga de pesos en 2 transferencias** para las 8 capas
   afectadas (ej. 128+128 palabras) — evita tocar el ancho del registro,
   pero le agrega una decisión de "carga en 2 partes" a `generate_layer_table.py`
   y a la FSM del DMA (que hoy asume una sola ráfaga de pesos por capa, ver
   `ddr_addressing.md`: "Pesos — una sola ráfaga por capa"). Más complejidad
   de control por evitar un cambio de 2 bits en un registro.
3. Otra reconciliación no considerada todavía.

**Impresión propia, no vinculante:** la Opción 1 se ve claramente más
simple — es literalmente ensanchar un campo que ya tiene margen de sobra en
el resto del datapath (10 bits en el wire de `ddr_addr_gen.vhd`, action
prácticamente gratis comparado con la Opción 2, que reintroduce el tipo de
complejidad de control que el proyecto viene evitando (ver la decisión de
"sin ping-pong" en `pipelining_tradeoffs.md`).

## How to apply

**RESUELTO (Parte 2, 2026-09-05).** Cualquier sesión que retome esto debe
partir de que:
- El fix (ensanche 8→10 bits en `reg_bank.vhd`/`ddr_addr_gen.vhd`/
  `dma_engine.vhd`) está **aplicado y verificado** sin regresión — no hay
  que rehacer ni redecidir esto.
- Del lado PS, `generate_layer_table.py` (Paso 4) queda **desbloqueado**
  para las 8 capas de la tabla (`irb6_pw`, `irb7_exp/pw`, `irb8_exp/pw`,
  `irb9_exp/pw`, `conv_last`) — ya se puede escribir `dma_weight_words=256`
  sin overflow. `dma_regs.h` ya documenta `[9:0]`.
- Las otras 15 de las 23 capas nunca estuvieron afectadas por esto.
- Las 5 capas que sigue bloqueando [[project_cin_grouping_gap]] son un
  hallazgo aparte (empaquetado denso, no ancho de registro) — ese doc
  también quedó RESUELTO técnicamente (Parte 7), pendiente solo de que
  Angel decida entre Opción 1b/Opción 2.
