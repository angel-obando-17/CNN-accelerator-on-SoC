# HALLAZGO: el hardware no soporta stride real de convolución — el modelo de producción sí lo usa

**Origen: sesión PS, 2026-08-06**, mientras se diseñaba `generate_layer_table.py`
(necesita calcular `DMA_IMG_W`/`DMA_IMG_H`/`REG_MAX_X`/`REG_MAX_Y` por capa, y
para eso hace falta saber exactamente cómo cada capa reduce la resolución
espacial). Se documenta acá, en la zona de PL, porque el hallazgo es sobre una
capacidad faltante del datapath — mismo criterio que ya se usó con
`requantization_analysis.md` (escrito por otra sesión, pero sobre una
limitación de hardware). Continúa la serie de gaps hardware↔entrenamiento
iniciada en [[project_quantization_hw_gap]].

## El hallazgo, en una frase

**El acelerador y el DMA no tienen ningún mecanismo para computar convolución con stride>1 — toda la arquitectura asume stride=1 implícito — pero el modelo de producción real (`CNN/src/models/mobilenetv2.py`) usa `strides=2` de verdad en 4 capas, y esas 4 capas no tienen forma de correr fiel en el hardware tal como está hoy.**

## Parte 1 — Cómo funciona el hardware hoy (confirmado revisando RTL real, no solo docs)

Se buscó "stride" en todo `accelerator/` — aparece en 4 archivos, y en **ninguno**
se refiere a stride de convolución:

- `ddr_addr_gen.vhd`: variables `row_stride_in`/`row_stride_out` — es el
  stride de **memoria DDR** entre filas consecutivas del feature map
  (`img_w × cin` palabras), para saber cuánto saltar en DDR de una fila a la
  siguiente. No tiene relación con submuestreo de convolución.
- `ddr_addressing.md`: mismo concepto, documentado (`row_stride_in = img_w × cin`).
- `ifbuffer_padding_redesign.md`: "stride" ahí se refiere al stride de
  direccionamiento del buffer on-chip (columnas por fila del buffer), no de
  convolución.
- `architecture.md`: la única mención relevante — ver Parte 3 abajo.

**No existe ningún registro `REG_STRIDE`/`DMA_STRIDE`** ni en `cnn_regs.h` ni
en `dma_regs.h`. El `addr_generator.vhd` del acelerador (qué tap de entrada
leer para cada pixel de salida) y el `ddr_addr_gen.vhd` del DMA (qué fila de
DDR traer para cada tile) asumen los dos una correspondencia **1:1** entre
posición de salida y posición de entrada — un pixel de salida más, una fila
de entrada más. Confirmado en la fórmula real de `ddr_addressing.md`:

```
r_global = tile_y × TILE_H + r_local − 1
```

Sin ningún factor de escala. El único mecanismo que el hardware tiene para
reducir la resolución espacial de un feature map es **MaxPool 2×2**
(`REG_POOL_EN=1`, `REG_POOL_TYPE=0`) — que si se activa, corre **después**
de una convolución calculada a resolución completa (stride 1 real en el
datapath), no en lugar de ella.

## Parte 2 — Cómo se entrenó el modelo real (confirmado leyendo el código fuente)

`CNN/src/models/mobilenetv2.py`, función `build_mobilenetv2`, usa
`strides=strides` **directo** en `Conv2D`/`DepthwiseConv2D` — stride real de
TensorFlow/Keras, no una aproximación. Capas con `stride=2` real en el
modelo de producción (`model_MobileNetV2_HSV_256x256.keras`,
ver [[project_production_pipeline_hsv]]):

| Capa | Tipo | De dónde sale el stride=2 |
|---|---|---|
| `conv1` | Conv3×3 | `strides=2` hardcodeado en la primera capa |
| `irb2_dw` | DepthwiseConv3×3 | `cfg[1] = (2, 24, 2)` — tercer valor = stride |
| `irb4_dw` | DepthwiseConv3×3 | `cfg[3] = (2, 32, 2)` |
| `irb6_dw` | DepthwiseConv3×3 | `cfg[5] = (2, 64, 2)` |

**El modelo NO tiene ninguna capa `MaxPool2D`** en ningún punto intermedio —
se revisó `build_mobilenetv2` completo, la única operación de pooling en
todo el modelo es `GlobalAveragePooling2D` al final (que es una operación
distinta, ya soportada correctamente por `gap_unit.vhd`, sin relación con
este hallazgo). Todo el submuestreo espacial intermedio (256→128→64→32→16)
se logra exclusivamente vía stride real en la convolución.

## Parte 3 — La pista que sí existía, pero apuntaba a un diseño distinto al que se entrenó

`architecture.md` (sección "Decisión clave: pool y residual nunca coexisten
en MobileNetV2") tiene esta nota, de origen no fechado con precisión:

> "revisando la tabla de capas de MobileNetV2, se encontró que las capas con
> residual connection siempre tienen stride=1... mientras que las capas con
> pooling siempre tienen stride=2..."

Esto describe una arquitectura donde el submuestreo se hace **vía MaxPool
2×2 después de una conv a stride 1** — consistente con que el hardware no
tiene otra forma de bajar resolución. Pero el modelo que efectivamente se
entrenó y quedó fijado como producción (`mobilenetv2.py`, confirmado arriba)
**no sigue ese patrón** — usa stride real, sin ningún `MaxPool2D`
intermedio. No quedó registrado en ningún lado por qué estos dos diseños
divergieron, ni cuál de los dos se decidió "de verdad" en algún momento —
parece que la nota de `architecture.md` describe una intención de diseño
temprana que el modelo finalmente entrenado no terminó siguiendo (o
viceversa, que el hardware se diseñó para un esquema que después cambió del
lado de CNN_training). Igual que con el hallazgo de `requantization_analysis.md`,
de acá en más esto queda documentado explícitamente para no repetir el
patrón de una decisión de origen no rastreable.

## Por qué NO son equivalentes "stride real" vs. "stride 1 + MaxPool 2×2"

No es una optimización que dé el mismo resultado — son dos arquitecturas de
red distintas, con pesos entrenados distintos y salidas numéricas distintas
para la misma entrada:

- **Stride real** (lo que se entrenó): la convolución se evalúa *solo* en
  las posiciones de salida submuestreadas — cada valor de salida es producto
  directo de una ventana de pesos sobre la entrada, sin ningún paso
  intermedio de agregación.
- **Stride 1 + MaxPool 2×2** (lo que el hardware puede ejecutar hoy): la
  convolución se evalúa en *todas* las posiciones (resolución completa),
  y luego se toma el máximo de cada ventana 2×2 de esos resultados — una
  operación de agregación no-lineal adicional que no existe en el grafo de
  cómputo que se entrenó.

Correr el modelo entrenado con stride real sobre un hardware que solo sabe
hacer "stride 1 + MaxPool" (sustituyendo una cosa por la otra sin reentrenar)
produciría activaciones completamente distintas a las que la red aprendió a
esperar en cada capa siguiente — mismo tipo de colapso de accuracy que ya se
vio con el shift-only de re-cuantización (`requantization_analysis.md`,
11-21% de accuracy cuando la aproximación de hardware no coincide con lo que
el modelo espera).

## Impacto — bloquea el lado PS

`generate_layer_table.py` necesita saber, capa por capa, la resolución de
entrada/salida real para calcular `DMA_IMG_W`/`DMA_IMG_H`/`REG_MAX_X`/
`REG_MAX_Y`/`REG_MAX_TILE_X`/`REG_MAX_TILE_Y`. Para las 4 capas con
stride=2 real (`conv1`, `irb2_dw`, `irb4_dw`, `irb6_dw`) no hay forma de que
el hardware actual reproduzca fielmente lo que el modelo entrenado espera —
el generador de tabla queda bloqueado en esas 4 capas hasta que se resuelva
esto, sea cual sea el camino que se elija.

## Opciones para resolver (sin decidir acá — abierto para discutir con PL y CNN_training)

1. **Reentrenar** las 4 capas afectadas como "conv/depthwise stride 1 +
   MaxPool 2×2 explícito" en `mobilenetv2.py`, para que el modelo coincida
   con lo que el hardware puede ejecutar de verdad. Costo: CNN_training
   (cambio de arquitectura + reentrenamiento + recuantización completa,
   parecido en esfuerzo a lo que ya se hizo con el límite de canales,
   ver [[project_channel_limit_violation]]).
2. **Agregar soporte real de stride al hardware** — nuevo registro
   (`REG_STRIDE`/`DMA_STRIDE`), y cambios en `addr_generator.vhd` (saltar
   posiciones de entrada) y `ddr_addr_gen.vhd` (direccionamiento DDR con
   paso >1). Costo: PL (RTL + re-verificación + re-síntesis + timing, alcance
   comparable al del multiplicador de re-cuantización).
3. Alguna otra forma de reconciliar las dos partes que no se haya
   considerado todavía.

**How to apply:** cualquier sesión (PL o CNN_training) que retome este tema
debe partir de que **el problema es real y confirmado por código fuente en
ambos lados** (RTL sin stride + modelo con stride real), no una duda
abierta — falta decidir cuál de las dos partes cede, no si el problema
existe.

---

## Parte 4 — Análisis de viabilidad de la Opción 2 (sesión PL, 2026-08-06)

Hecho a pedido de Angel, en paralelo con el mensaje dejado para CNN_training
para que evalúe el costo de la Opción 1. Se leyó el RTL real (no solo la
documentación) de `addr_generator.vhd`, `fsm_addr_generator.vhd`,
`ddr_addr_gen.vhd`, `dma_fsm.vhd`, `reg_bank.vhd`, `axi_lite_slave.vhd`,
`cnn_top.vhd`, `fsm_cnn_acc.vhd`.

### Conclusión corta

**La Opción 2 es más barata de lo que la Parte 1 de este documento hacía
temer.** No es un rediseño arquitectónico — es un cambio contenido, del
mismo orden de magnitud que `bias_support.md` o el multiplicador de
re-cuantización (`requantization_analysis.md`), **no** del orden del límite
de canales (`project_channel_limit_violation`, que sí era un callejón sin
salida de verdad). La razón de fondo: el RTL ya tiene, sin usarlo para esto,
justo el desacople que hace falta.

### Hallazgo clave 1 — el tile que pide el DMA y el tile que itera el acelerador YA son registros independientes

`ddr_addr_gen.vhd`/`reg_bank.vhd` (lado DMA) tienen su propio `tile_w`/
`tile_h` (registros `r18`/`r1c`, anchos 8b/4b) que deciden **cuánto se trae
de DDR al IFBuffer**. `addr_generator.vhd`/`axi_lite_slave.vhd` (lado
acelerador) tienen su propio `max_x`/`max_y` (7b/3b) que deciden **cuántas
posiciones de salida computa el motor**. Hoy Angel los configura para que
coincidan 1:1 (mismo tile en ambos lados) porque stride=1 nunca necesitó
otra cosa — pero nada en el RTL fuerza esa igualdad. Para stride=2, PS
simplemente configuraría el tile del DMA **al doble** de tamaño (más halo)
que el tile del acelerador, y ya — el DMA no necesita saber que existe el
concepto de stride, sigue haciendo exactamente lo que hace hoy (traer un
rectángulo de DDR), solo que con números distintos.

### Hallazgo clave 2 — la salida "a mitad de resolución" ya existe en el DMA, vía `POOL_EN`

`ddr_addr_gen.vhd` (líneas ~144-152) ya calcula `tile_w_out`/`tile_h_out`/
`img_w_out` como la mitad de los registros cuando `pool_en='1'`, para
escribir el OFM/Residual a la DDR a resolución reducida. Es exactamente el
mecanismo que un stride=2 real necesita del lado de escritura — la única
diferencia es que hoy está atado a `pool_en` (que además dispara el
datapath de `max_pool.vhd`) en vez de a un concepto más general de "esta
capa escribe a mitad de resolución". Generalizar la condición a
`pool_en='1' OR stride_en='1'` en `ddr_addr_gen.vhd` (1 punto) y
`dma_fsm.vhd` (`OFM_NEXT`, `RES_NEXT` — 2 puntos, aunque `RES_NEXT` no
debería activarse nunca en capas con stride real porque residual exige
mismas dimensiones in/out, igual que ya pasa con pool) resuelve el lado
DMA/escritura por completo. **`reg_pool_en` del acelerador se queda en 0**
para capas con stride real — no se invoca `max_pool.vhd`, el motor ya
computa directo a resolución de salida.

### Lo único que sí hay que tocar de verdad: `addr_generator.vhd`, lado de lectura del IFBuffer

Tres variables del proceso combinacional (líneas 165-234) asumen hoy
correspondencia 1:1 salida→entrada:

```vhdl
tile_w     := resize(unsigned(max_x), 8) + 1        -- deriva del registro de SALIDA
tile_w_pad := tile_w + 2
row        := resize(y_counter, 4) + resize(sig_ky, 4)
col        := resize(x_counter, 8) + resize(sig_kx, 8)
```

Con stride real, el IFBuffer que el DMA llenó es físicamente más ancho/alto
que `max_x+1`/`max_y+1` (es del tamaño que el hallazgo clave 1 describe), y
la posición de entrada que corresponde a la posición de salida `(x,y)` no es
`(x,y)` sino `(x×stride, y×stride)`. Fix, con un nuevo puerto `stride_en`
(1 bit) en `addr_generator.vhd`:

```vhdl
tile_w_eff := tile_w when stride_en='0' else shift_left(tile_w, 1)
tile_w_pad := tile_w_eff + 2
row        := (y_counter when stride_en='0' else shift_left(resize(y_counter,4),1)) + sig_ky
col        := (x_counter when stride_en='0' else shift_left(resize(x_counter,8),1)) + sig_kx
```

Tres MUX/shift condicionales, ningún multiplicador nuevo (stride solo es 1
o 2 — un shift_left basta), ningún DSP adicional. `addr_w` (pesos) y
`addr_out` (escritura OFBuffer) **no cambian** — ya están indexados en
espacio de salida (`x_counter`/`y_counter` tal cual), que es exactamente
donde deben quedarse.

### Plomería de registros — mismo patrón que `POOL_EN`/`DMA_POOL_EN`

`stride_en` necesita llegar a dos bancos de registros separados (igual que
`pool_en` hoy tiene `r28_pool_en` en `axi_lite_slave.vhd` y `r44_pool_en` en
`reg_bank.vhd`, dos copias sincronizadas por PS):
- Nuevo registro en `axi_lite_slave.vhd` (offset libre, ej. `0x40` — el
  bloque de offsets ya salta de `0x3C` a `0x40`/`0x44`/etc. según los
  registros de bias agregados después) → puerto nuevo en `cnn_accelerator`/
  `cnn_top` → `addr_generator`.
- Nuevo registro en `reg_bank.vhd` (mismo patrón que `r44_pool_en`) →
  `ddr_addr_gen`/`dma_fsm`.
No hace falta ningún registro de "ancho de tile de entrada" aparte — se
deriva combinacionalmente de `max_x`/`max_y` + `stride_en`, evitando un
registro redundante que PS tendría que mantener sincronizado a mano.

### ¿Alcanza el ancho de los contadores/registros existentes? Sí, verificado con números reales

Se armó el caso concreto de `conv1` (entrada 256×256, salida 128×128,
stride=2, Conv3x3) contra los anchos de bit reales:

- `max_y`/`y_counter` del acelerador son de **3 bits** (0-7) — ya HOY
  limitan cualquier tile de salida a ≤8 filas, con o sin stride. Eligiendo
  `TILE_H_OUT=4` (divide 128 exacto, cabe en 3 bits): `TILE_H` del lado DMA
  = `2×4=8` — cabe holgado en los 4 bits del registro (`r1c_tile_h`, máx
  15). `num_tile_y = 128/4 = 32`, cabe en los 6 bits de `num_tile_y` (máx
  63). Con halo, filas totales fetcheadas = `TILE_H+2=10`, `r_local` llega
  a 9, cabe holgado en sus 4 bits.
  - Ojo: `TILE_H_OUT=8` (el tamaño que se usa hoy en stride=1) **no**
    cabría (`TILE_H`=16 > 15, desborda el registro de 4 bits) — para capas
    con stride real, el tile de salida tiene que ser más chico que el que
    se usa hoy. No es un problema de HW, es una restricción de
    planificación que `generate_layer_table.py` debe respetar.
- `max_x`/`x_counter` son de **7 bits** (0-127), `tile_w` del DMA de 8 bits
  (0-255). Con `TILE_W_OUT=64` (divide 128 exacto): `TILE_W` del lado DMA
  = `2×64+2=130`, cabe cómodo en 8 bits. `num_tile_x=128/64=2`, cabe en los
  2 bits de `num_tile_x`.
- Capacidad de IFBuffer (13 bits, 8192 palabras — ver
  `ifbuffer_padding_redesign.md`): con el plan de arriba,
  `(130)×(10)×cin_groups`. Para `conv1` (`Cin` chico, 1 grupo de 16) ≈ 1300
  palabras — muy por debajo del límite. Para las otras 3 capas (resoluciones
  128→64, 64→32, 32→16, todas más chicas) el margen es todavía mayor. **No
  hace falta agrandar el IFBuffer** — el mismo tamaño físico que ya existe
  alcanza, solo se necesitan tiles de salida más chicos para esas 4 capas
  específicas.
- La restricción de "sin último tile más chico" (`ddr_addressing.md`) se
  sigue cumpliendo: 256, 128, 64, 32, 16 son todas potencias de 2, cualquier
  tamaño de tile potencia de 2 las divide exacto.

### Lo que NO hace falta tocar

`weight_buffer.vhd`, `outputf_buf.vhd`, `residual_buf.vhd`, `bias_buf.vhd`,
`max_pool.vhd`, `gap_unit.vhd`, `add_unit.vhd`, el protocolo `TILE_WAIT`
(`fsm_cnn_acc.vhd`/`fsm_addr_generator.vhd` no necesitan tocarse — el
`tile_boundary`/`TILE_HOLD` ya opera puramente en espacio de salida, ajeno
a stride), el camino de lectura del DMA hacia DDR (`ddr_addr_gen.vhd` caso
IFM, `"000"`) — ya funciona con cualquier `tile_w`/`tile_h` que PS le pase,
sin saber que existe stride.

### Costo real estimado

- **RTL**: `addr_generator.vhd` (3 líneas de fórmula + 1 puerto nuevo),
  `axi_lite_slave.vhd`/`reg_bank.vhd` (1 registro nuevo cada uno, copiar
  patrón de `pool_en`), `ddr_addr_gen.vhd`/`dma_fsm.vhd` (generalizar 3
  condiciones de `pool_en`), wiring mecánico en `cnn_accelerator.vhd`/
  `cnn_top.vhd`. Sin DSPs nuevos, sin crecimiento de BRAM.
- **Verificación**: un testbench nuevo end-to-end (tile fetch DMA + cómputo
  acelerador) para Conv3x3/DW3x3 con stride=2, análogo a los que ya existen
  para bias/mult. Re-síntesis y re-cierre de timing — riesgo bajo dado que
  el cambio no toca la ruta de MACs/multiplicadores (lo que sí costó
  esfuerzo real en el cierre de 70MHz con `REG_MULT`).
- **PS**: `generate_layer_table.py` necesita, para las 4 capas con stride
  real, calcular un tile de salida más chico que el default (`TILE_H_OUT≤7`
  en vez de 8) y el tile de entrada correspondiente al doble — una regla de
  planificación adicional, no un bloqueo.

### Qué falta para cerrar esto de verdad

Este análisis es de **lectura de RTL + aritmética de anchos de bit**, no de
simulación — antes de que Angel implemente nada hace falta al menos un
testbench mental/a mano de un caso Conv3x3 stride=2 completo (con números
reales de una capa, ej. `conv1`) verificando que las direcciones que arroja
la fórmula nueva caen donde deberían, igual que se hizo con cada bug
encontrado en las rondas de verificación anteriores del proyecto. También
falta confirmar contra `mobilenetv2.py` que ninguno de los 4 bloques con
stride real tiene `has_residual=1` (debería ser imposible por construcción,
pero no se verificó explícitamente en esta sesión).

**How to apply:** si Angel decide seguir por la Opción 2, este análisis es
el punto de partida — no hay que releer el RTL desde cero, el mapa de
cambios ya está acá. Si CNN_training concluye que la Opción 1 (reentrenar)
es más barata en términos de tiempo/riesgo a pesar de esto, esta sección
sigue sirviendo como referencia de cuánto costaba la alternativa, para que
la decisión quede registrada con ambos costos reales sobre la mesa.
