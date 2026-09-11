# Layout de memoria DDR — política de asignación y mapa concreto

> **Ver primero `system_memory_map.md`** para la partición del espacio de
> direcciones completo (regiones de código de cada núcleo, OCM, registros de la
> PL, arranque AMP y reglas de coherencia de cache). Este documento es el
> detalle capa por capa de la arena de activaciones, pesos y bias.

## Decisión (2026-07-11): direcciones estáticas, sin reuso, v1

Cada tensor de salida de cada capa del MobileNetV2 recibe una dirección
DDR fija y única, calculada una sola vez por el script generador en Python
(`runtime_bare_metal/scripts/generate_layer_table.py`). Ninguna dirección se
reutiliza entre capas.

### Por qué

- El modelo completo (pesos + todas las activaciones intermedias) cabe
  cómodo en los 512 MB de DDR. **Medido: 4.21 MiB de 512.**
- Evita cualquier análisis de tiempo de vida de buffers.
- Resuelve el caso de residual/skip-connection sin copias: una capa con
  residual simplemente apunta `addr_res` a la dirección donde ya vive la
  salida de la capa que lo produjo (que puede estar varias capas atrás,
  no necesariamente N-1).

### Por qué NO ping-pong / prefetch de activaciones entre capas (por ahora)

El pipeline de capas es estrictamente secuencial en el scheduler de Core0:
`DMA_START` procesa una capa completa (pesos + todos los tiles vía
TILE_WAIT + escritura de resultado) antes de que Core0 dispare el
`DMA_START` de la siguiente capa (ver `scheduler_flow.md`). No hay overlap
de software entre capas, así que no hay beneficio de tener buffers dobles
en DDR por ahora.

Esto es distinto del ping-pong de IFBuffer/OFBuffer *dentro* de una capa,
a nivel de BRAM del acelerador — ese ya está resuelto en el RTL
(`dma/tile_wait_protocol.md`, `dma/pipelining_tradeoffs.md`).

---

## Decisión (2026-09-09): el frame segmentado va a DDR, no a OCM

**Esto corrige lo que dice `Bitacora.md` (línea 143).** Ahí está escrito que
la imagen segmentada se pasa de Core 1 a Core 0 por la OCM, con la cuenta
`256 x 256 x 3 = 192 KB, cabe en los 256 KB disponibles`.

Esa cuenta ya no vale. El empaquetado en DDR acordado el 2026-09-08 es de
`ceil(C/16) · 16` bytes por píxel (Opción 1b), y `conv1` tiene `Cin = 3`, que
redondea a **16 bytes por píxel**:

```
256 x 256 x 16 B = 1 MiB   contra   256 KiB de OCM
```

No entra, por un factor de 4. Y no hay forma de esquivarlo: el DMA lee
palabras de 128 bits con ese empaquetado — no existe un modo de "3 bytes por
píxel" en el RTL.

**Consecuencia:**

- **Core 1 escribe el frame segmentado en DDR**, en `DDR_INPUT_BASE`, con
  16 B por píxel (los canales H, S, V en los 3 primeros bytes y **13 bytes de
  relleno**, que el hardware ignora porque sólo direcciona `Cin` canales).
- **La OCM queda sólo para el handshake entre cores** (el flag que Core 0
  escribe y Core 1 lee en spinlock). Son unos pocos bytes, que es para lo que
  la OCM sirve bien.

### Impacto en el tiempo de inferencia: despreciable

La pregunta natural es si leer de DDR en vez de OCM degrada los 99,4 ms
estimados (ver `../../accelerator/cnn_accelerator/docs/inference_speed_roadmap.md`).
No, por tres razones:

1. **27 de las 28 capas ya leían y escribían DDR.** Lo único que se mudó es la
   entrada de `conv1`, que se lee **una vez por imagen**.
2. **Esa lectura son 165.996 ciclos = 2,37 ms**, el **2,4 % del total**
   (636 ráfagas x 129 palabras, con el modelo medido `3 · ráfagas + 2 ·
   palabras`). Ése es el techo absoluto de lo que este cambio podría costar,
   y en realidad cuesta **cero**, porque ese costo es el mismo contra
   cualquier esclavo AXI.
3. **El modelo de costo es del lado PL, no de la memoria.** Los 2
   ciclos/palabra son el ritmo del `axi4_read_master` (palabra de 128 bits
   sobre un puerto HP de 64 bits = 2 beats). A 70 MHz eso pide **553 MB/s**,
   contra los **~2,1 GB/s** de pico de la DDR3 de esta placa (**bus de 16
   bits** a 533 MHz, un solo `MT41K256M16` — verificado contra el esquemático
   y contra la configuración del fabricante, ver `system_memory_map.md` §1.2):
   la DDR tiene casi cuatro veces el ancho de banda que el puerto le puede
   pedir.

   *(Corregido el 2026-09-10: acá decía ~4,2 GB/s, calculado sobre un bus de
   32 bits que la placa no tiene. La conclusión no cambia.)*

De hecho, a 553 MB/s el DMA está **saturando el puerto AXI-HP** (8 B/ciclo x
70 MHz = 560 MB/s de tope). El cuello de botella es el reloj de la PL, no la
memoria — que es exactamente lo que dice el reparto medido: 79,8 % cómputo.

> **Salvedad honesta, previa a esta decisión y que aplica a las 28 capas:**
> el modelo `3 · ráfagas + 2 · palabras` se calibró en simulación, contra un
> modelo de memoria que responde con latencia fija. La DDR real agrega
> latencia de primera palabra por ráfaga (decenas de ciclos) que el término
> de 3 ciclos/ráfaga no captura. Si esa latencia no se solapa, el costo real
> de transferencia puede ser mayor que el estimado. **El número a creer es el
> que se mida en la placa con un timer**, no éste. Pero ese riesgo existía
> igual con las otras 27 capas: no lo introduce mudar el frame a DDR.

---

## Mapa de memoria

```
0x0000_0000 .. 0x00FF_FFFF   16 MiB    código / stack / heap de Core 0 y Core 1
0x0100_0000                  51,520 B   pesos  (cnn_weights.bin)
0x0101_0000                   5,696 B   bias   (cnn_bias.bin)
0x0102_0000                   2.340 B   dense  (cnn_dense.bin) — lo usa el PS, no el DMA
0x0200_0000                   1 MiB    frame HSV: Core 1 escribe, conv1 lee
0x0210_0000 .. 0x0242803F   3.16 MiB   las 28 activaciones, contiguas
```

Las constantes, tal como las usa el generador:

```python
DDR_WEIGHTS_BASE = 0x01000000
DDR_BIAS_BASE    = 0x01010000
DDR_DENSE_BASE   = 0x01020000
DDR_INPUT_BASE   = 0x02000000
DDR_ACT_BASE     = 0x02100000
```

Los huecos entre regiones son deliberados: con bases redondas, una dirección
suelta vista en un ILA o en un `printf` se identifica de un vistazo
(`0x0100_xxxx` = peso, `0x0210_xxxx` = activación).

### Presupuesto

| | |
|---|---|
| frame HSV de entrada | 1,00 MiB |
| 28 activaciones intermedias | 3.16 MiB |
| pesos + bias | 56 KiB |
| dense | 2,3 KiB |
| **total** | **4.21 MiB de 512** |

La activación más grande es la de `conv1`, 512 KiB.

---

## Reglas de cálculo

| registro | regla |
|---|---|
| `dma_addr_w` | `DDR_WEIGHTS_BASE +` suma acumulada de `weight_words · 16` de las capas anteriores |
| `dma_addr_bias` | `DDR_BIAS_BASE +` suma acumulada de `bias_words · 16` |
| `dma_addr_in` | `DDR_INPUT_BASE` en `conv1`; en el resto, el `addr_out` de la capa anterior |
| `dma_addr_out` | `DDR_ACT_BASE +` suma acumulada de los tamaños de salida |
| `dma_addr_res` | sólo en las 5 capas con residual: el `addr_out` de la capa `_pw` anterior; `0` en las otras 23 |

Tamaño de salida de una capa:

```
bytes_salida = res_out^2 · ceil(Cout/16) · 16
```

con la única excepción de `conv_last`, que lleva GAP: su salida es **un solo
píxel** de `Cout` canales, o sea `ceil(64/16) · 16 = 64` bytes.

### Por qué `addr_res` apunta a la `_pw` anterior

Leído del `.keras` (no asumido), los cinco `Add` del modelo son:

```
irb3_add <- irb2_pw + irb3_pw        irb8_add <- irb7_add + irb8_pw
irb5_add <- irb4_pw + irb5_pw        irb9_add <- irb8_add + irb9_pw
irb7_add <- irb6_pw + irb7_pw
```

Los casos de `irb8` e `irb9` suman contra la salida de un `Add` anterior, no
contra un `_pw` "crudo" — pero como el acelerador escribe en `addr_out` el
resultado **ya sumado**, apuntar a la `_pw` anterior es exactamente la misma
dirección. Por eso las cinco siguen una regla única, sin casos especiales.

### Invariantes verificadas

- Las 28 salidas son múltiplo exacto de 16 B, así que apilarlas de forma
  contigua cumple sola el límite 15 de `hardware_limits.md` (toda dirección
  DDR alineada a 16 B).
- Los offsets de pesos y bias calculados por acumulación **coinciden capa por
  capa** con los `weight_offset`/`bias_offset` de
  `CNN/results/ptq_simple_v2/weights_manifest.json`, que los produjo
  `export_weights.py` por un camino independiente.
- Ningún tensor se solapa con otro (consecuencia directa de la política sin
  reuso).

---

## Tabla completa de direcciones

| capa | `addr_w` | `addr_bias` | `addr_in` | `addr_out` | `addr_res` | bytes salida |
|---|---|---|---|---|---|---|
| `conv1` | `0x01000000` | `0x01010000` | `0x02000000` | `0x02100000` | — | 524,288 |
| `irb1_dw` | `0x01000360` | `0x01010080` | `0x02100000` | `0x02180000` | — | 524,288 |
| `irb1_pw` | `0x01000480` | `0x01010100` | `0x02180000` | `0x02200000` | — | 262,144 |
| `irb2_exp` | `0x01000680` | `0x01010140` | `0x02200000` | `0x02240000` | — | 524,288 |
| `irb2_dw` | `0x01000880` | `0x010101C0` | `0x02240000` | `0x022C0000` | — | 131,072 |
| `irb2_pw` | `0x010009A0` | `0x01010240` | `0x022C0000` | `0x022E0000` | — | 131,072 |
| `irb3_exp` | `0x01000DA0` | `0x010102C0` | `0x022E0000` | `0x02300000` | — | 196,608 |
| `irb3_dw` | `0x01001220` | `0x01010380` | `0x02300000` | `0x02330000` | — | 196,608 |
| `irb3_pw` | `0x010013D0` | `0x01010440` | `0x02330000` | `0x02360000` | `0x022E0000` | 131,072 |
| `irb4_exp` | `0x010019D0` | `0x010104C0` | `0x02360000` | `0x02380000` | — | 196,608 |
| `irb4_dw` | `0x01001E50` | `0x01010580` | `0x02380000` | `0x023B0000` | — | 49,152 |
| `irb4_pw` | `0x01002000` | `0x01010640` | `0x023B0000` | `0x023BC000` | — | 32,768 |
| `irb5_exp` | `0x01002600` | `0x010106C0` | `0x023BC000` | `0x023C4000` | — | 65,536 |
| `irb5_dw` | `0x01002E00` | `0x010107C0` | `0x023C4000` | `0x023D4000` | — | 65,536 |
| `irb5_pw` | `0x01003040` | `0x010108C0` | `0x023D4000` | `0x023E4000` | `0x023BC000` | 32,768 |
| `irb6_exp` | `0x01003840` | `0x01010940` | `0x023E4000` | `0x023EC000` | — | 65,536 |
| `irb6_dw` | `0x01004040` | `0x01010A40` | `0x023EC000` | `0x023FC000` | — | 16,384 |
| `irb6_pw` | `0x01004280` | `0x01010B40` | `0x023FC000` | `0x02400000` | — | 16,384 |
| `irb7_exp` | `0x01005280` | `0x01010C40` | `0x02400000` | `0x02404000` | — | 16,384 |
| `irb7_dw` | `0x01006280` | `0x01010D40` | `0x02404000` | `0x02408000` | — | 16,384 |
| `irb7_pw` | `0x010064C0` | `0x01010E40` | `0x02408000` | `0x0240C000` | `0x02400000` | 16,384 |
| `irb8_exp` | `0x010074C0` | `0x01010F40` | `0x0240C000` | `0x02410000` | — | 16,384 |
| `irb8_dw` | `0x010084C0` | `0x01011040` | `0x02410000` | `0x02414000` | — | 16,384 |
| `irb8_pw` | `0x01008700` | `0x01011140` | `0x02414000` | `0x02418000` | `0x0240C000` | 16,384 |
| `irb9_exp` | `0x01009700` | `0x01011240` | `0x02418000` | `0x0241C000` | — | 16,384 |
| `irb9_dw` | `0x0100A700` | `0x01011340` | `0x0241C000` | `0x02420000` | — | 16,384 |
| `irb9_pw` | `0x0100A940` | `0x01011440` | `0x02420000` | `0x02424000` | `0x02418000` | 16,384 |
| `conv_last` | `0x0100B940` | `0x01011540` | `0x02424000` | `0x02428000` | — | 64 |

*(`addr_res` vacío significa que la capa no tiene residual; el hardware ignora
el registro cuando `has_residual = 0`.)*

---

## Lo que tiene que saber el runtime

- **Core 1** necesita `DDR_INPUT_BASE` y el formato de 16 B/píxel. Es el único
  productor de esa región.
- **Core 0** no necesita ninguna de estas constantes a mano: van embebidas en
  `layer_table.c`, que emite el generador.
- **Cachés:** el DMA lee y escribe DDR por el puerto HP, sin coherencia con
  las cachés de los cores. Core 1 tiene que hacer *flush* del frame después de
  escribirlo, y Core 0 *invalidate* de la salida de `conv_last` antes de leerla
  para la capa densa. Es responsabilidad del runtime, no de la tabla.

## Abierto para el futuro (no ahora)

Si más adelante se justifica optimizar memoria DDR, se puede migrar a una
política de reuso con análisis de tiempo de vida de cada tensor. Empezar
simple (v1) y sólo complicar si el trabajo de grado tiene tiempo y hace falta.
Con 4.21 MiB de 512 usados, no hay ninguna presión para hacerlo.
