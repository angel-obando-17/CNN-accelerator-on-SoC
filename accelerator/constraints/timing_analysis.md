# Análisis de timing (STA) de cnn_top

## Por qué hace falta esto además de la simulación

La simulación verifica **funcionalidad lógica**: asume que
cada flip-flop ve el dato correcto en cada flanco de reloj. El análisis de
timing estático (STA) verifica algo distinto y complementario: que la lógica
combinacional entre dos registros alcance a resolverse antes del siguiente
flanco (*setup*) y que no cambie demasiado rápido después de él (*hold*). Un
diseño puede simular perfecto y fallar en hardware real si el reloj corre más
rápido de lo que la lógica combinacional puede seguir. La STA es la que dice,
con margen medible, cuál es la frecuencia máxima segura (`Fmax`) del diseño.

## Herramienta

Vivado corre STA automáticamente durante **Implementation** (place & route).
El reporte relevante es `Report Timing Summary`, y el número clave es el
**WNS (Worst Negative Slack)**:

- `WNS >= 0` -> el diseño cumple timing al periodo constreñido (con ese margen).
- `WNS < 0` -> no cumple. El `Fmax` aproximado real es
  `1 / (periodo_constreñido - WNS)`.

Metodología: constreñir un periodo inicial, correr Implementation, leer WNS,
ajustar el periodo (más ajustado si sobra margen, más relajado si falla) y
repetir hasta converger en la frecuencia de operación real.

## Constraint inicial

Archivo: `constraints/cnn_top_clock.xdc`.

```tcl
create_clock -period 10.000 -name clk -waveform {0.000 5.000} [get_ports clk]
```

**Punto de partida: 100 MHz (periodo 10 ns).** Es un valor conservador típico
para lógica PL de complejidad moderada en Zynq-7020 (-2). Un solo dominio de
reloj — todo `cnn_top` (acelerador + `axi_lite_slave` + `dma_engine`) corre del
mismo puerto `clk`, así que basta un solo `create_clock`.

## De dónde sale el reloj en el diseño final

`cnn_top.clk` lo alimenta `FCLK_CLK0` del bloque PS7 en el Block Design de
Vivado — configurable en la pestaña "Clock Configuration" al personalizar el
PS7. El PS7 genera esa señal internamente con sus PLLs, derivadas del
oscilador externo de la tarjeta Puzhi (33.333 MHz). No hay reloj externo
directo a la PL ni IP de clocking (`Clocking Wizard`) por ahora — no hace
falta mientras todo el diseño viva en un solo dominio de reloj.

La frecuencia real de `FCLK_CLK0` se fija **después** de tener un `Fmax`
confiable de esta STA, con margen de seguridad (nunca configurar `FCLK_CLK0`
al límite exacto del `Fmax` medido).

## Sospechoso de camino crítico (hipótesis inicial, DESCARTADA por el reporte real)

`addr_generator.vhd` calcula varias multiplicaciones (`row*tile_w_pad*cin_groups`,
`co*Cin*9`, `sig_ci*9`, etc.) dentro de un proceso **combinacional**, sin
registros intermedios. Es el tipo de lógica que suele limitar `Fmax` en
diseños con multiplicaciones encadenadas — primer lugar a revisar si el WNS
sale negativo. **Resultado real (ver abajo): no es este el camino crítico.**

## Camino crítico real (confirmado, post-síntesis 2026-07-13)

A 100 MHz (10ns) **no cumple timing**: `WNS = -3.192 ns` (576 endpoints
fallando de 13939 totales) — post-síntesis, antes de place & route (número
optimista, sin retardos de ruteo todavía). `Fmax` estimado en esta etapa:
`1 / (10 - (-3.192)) ≈ 75.8 MHz`.

**Ruta**: `inst_dma_engine/inst_dma_fsm/reg_tile_y_reg[0]/C` →
`inst_dma_engine/inst_axi4_read_master/sig_ddr_addr_reg[29]/D`, pasando por
`inst_dma_engine/inst_ddr_addr_gen`. 19 niveles de lógica: **2 DSP48E1 en
cascada** (multiplicación, encadenados vía `PCOUT`/`PCIN`) + **11 CARRY4**
(suma ancha de ~32 bits para la dirección DDR completa), todo en un solo
ciclo, sin ningún registro intermedio. Coincide con lo documentado desde el
diseño original: `ddr_addr_gen.vhd` es "combinacional puro" (`dma/ddr_addr_gen`
docs) — calcula `ddr_addr` completo a partir de `tile_x`/`tile_y`/`r_local` en
una sola pasada.

**Implicación**: si el `Fmax` real (post-ruteo) confirma que 100 MHz no
alcanza con margen razonable, la solución de fondo es *pipelinear*
`ddr_addr_gen.vhd` (partir el cálculo en 2+ etapas registradas) — no
`addr_generator.vhd`, que resultó no ser el cuello de botella.

## Resultado definitivo post-ruteo (2026-07-13)

`WNS = -2.724 ns` a 100 MHz (896 endpoints fallando de 13939, post place & route
— este SÍ es el número real, con retardos de ruteo incluidos).
**`Fmax` real ≈ `1 / (10 - (-2.724)) ≈ 78.6 MHz`.**

Misma ruta que en post-síntesis (se corrió con más bits pero mismo cuello de
botella): `inst_dma_engine/inst_dma_fsm/reg_tile_y_reg[0]` →
`inst_ddr_addr_gen` (2×DSP48E1 en cascada + 11×CARRY4) →
`inst_axi4_read_master/sig_ddr_addr_reg[31]`. 20 niveles de lógica,
12.725ns de retardo de dato contra 10ns de periodo disponible.

**El latch (`sig_kx_reg[1]_LDC`) NO es un riesgo especial**: se revisó su
timing en el contexto completo de `cnn_top` (no aislado como antes) —
`report_timing -through` da un slack calculable normal (`-2.311ns`,
**mejor** que el del camino crítico real de `ddr_addr_gen`, sin ningún
warning de "no se puede resolver el reloj"). Se comporta como cualquier otro
registro del diseño: va a cerrar limpio en cuanto se fije una frecuencia
segura, igual que el resto. **Cerrado — no hace falta recodificar en one-hot.**

## Iteración real: acotando el Fmax con 3 puntos (2026-07-13)

Angel cuestionó (con razón) si 50 MHz dejaba demasiado margen sin probar
frente al `Fmax` estimado de ~78.6 MHz — se iteró el constraint con datos
reales en vez de quedarse con la extrapolación desde un solo punto:

| Frecuencia constreñida | Periodo | WNS (post-ruteo) | Resultado |
|---|---|---|---|
| 100 MHz | 10.000 ns | -2.724 ns | Falla (896 endpoints) |
| 78 MHz | 12.821 ns | -0.293 ns | Falla apenas (25 endpoints) |
| 75 MHz | 13.333 ns | -0.056 ns | Falla mínimo (2 endpoints, -0.078ns total) |
| **70 MHz** | **14.286 ns** | **+0.288 ns** | **Pasa — "All user specified timing constraints are met"** |

`Fmax` real ≈ 74.7 MHz (afinado con el punto de 75MHz, que falla por apenas
0.056ns). Mismo cuello de botella en los 4 casos: `ddr_addr_gen.vhd`
(2×DSP48E1 en cascada + 11×CARRY4, combinacional), alternando entre el
camino de lectura (`axi4_read_master`) y escritura (`axi4_write_master`)
según la corrida — simétrico, tiene sentido dado que ambos usan la misma
lógica de generación de dirección.

**Nota**: el punto de 75MHz se corrió únicamente para dejar registro (a
pedido explícito de Angel) — la frecuencia final elegida sigue siendo
**70MHz** (única con margen positivo real verificado), no 75MHz.

## Recomendación

**No perseguir 100 MHz para esta etapa** — el cuello de botella real
(`ddr_addr_gen.vhd`, cálculo de dirección DDR 100% combinacional en 1 ciclo)
es una decisión de arquitectura ya tomada y documentada; pipelinearlo es un
cambio de diseño no trivial (partir el cálculo en 2+ etapas registradas,
re-verificar todo el DMA) que no vale la pena invertir ahora, en la etapa de
bring-up. Coincide con lo que ya teníamos priorizado en `project_timeline`:
optimizaciones de rendimiento quedan para la fase de prácticas, no para la
ventana de vacaciones.

**Frecuencia elegida para `FCLK_CLK0`: 70 MHz** (periodo 14.286ns) —
verificada con place & route completo, pasa con margen positivo real
(no al filo del `Fmax`), y bastante más agresiva que la primera propuesta
conservadora de 50MHz. Si más adelante hace falta más throughput, revisar
pipelinear `ddr_addr_gen.vhd` como optimización futura (no bloqueante para
el bring-up).

## Nota metodológica

Este análisis se corrió **fuera del proyecto real** (`out_of_context`, en un
directorio de scratch, con los mismos archivos fuente + `mac_dsp.xdc` +
`cnn_top_clock.xdc`) para no interferir con la sesión de Vivado de Angel. Los
números son representativos pero el análisis definitivo, una vez exista el
Block Design con el PS7 real, debería confirmarse corriendo Implementation
sobre el proyecto real completo (con `HD.CLK_SRC` correctamente resuelto,
cosa que en out-of-context generó warnings de "no clock buffer found").

## Latch encontrado en la resíntesis del 2026-07-13 (`sig_kx_reg[1]_LDC`)

Al resintetizar `cnn_top` después de los 2 fixes de sincronización de esta
sesión (`DRAIN` en `fsm_cnn_acc.vhd`, warm-up extendido en
`fsm_addr_generator.vhd`), el reporte de utilización mostró **1 registro
implementado como latch** (`Register as Latch: 1`) — antes no había ninguno.

**Ubicación exacta** (confirmada vía `get_cells -hierarchical -filter
{PRIMITIVE_SUBGROUP == latch}`): `inst_cnn_accelerator/inst_addr_generator/sig_kx_reg[1]_LDC`
— el bit alto (MSB) del sub-contador `sig_kx` (2 bits) dentro de
`addr_generator.vhd`.

**No es un bug de los 2 fixes de esta sesión** — ninguno de los dos toca
`addr_generator.vhd`. Confirmado con `git log` que la causa real es el fix del
`ky_kx_reset_val` (2026-07-11, PW1x1 fija `ky=kx=1` en vez de `0`) — recién
comiteado por primera vez en `864387a` (esta sesión), pero vivía sin comitear
desde el 2026-07-11. **Hipótesis fuerte de por qué nunca había aparecido
antes**: antes de ese fix, `sig_kx`/`sig_ky` reseteaban siempre a un valor
constante `"00"` (sin depender de `reg_mode`). Después del fix, el valor de
reset es él mismo una función combinacional de `reg_mode`
(`ky_kx_reset_val <= "01" when reg_mode = "10" else "00"`) — eso introduce
exactamente el patrón booleano (una condición de "set" angosta + múltiples
condiciones de "clear") que el optimizador de Vivado prefiere mapear a un
latch en vez de un flip-flop. Es decir: el latch no es nuevo por los cambios
de ESTA sesión, sino que estuvo latente desde el 2026-07-11 y nunca se había
visto reflejado en un reporte de síntesis hasta ahora.

**Investigación exhaustiva (entorno de scratch, fuera del proyecto real,
`addr_generator.vhd` sintetizado en aislado out-of-context)** — 4 variantes de
RTL probadas, **todas producen el mismo latch**:
1. RTL original.
2. Fusionar las 2 ramas de reset idénticas (`sig_counter_reset` OR
   `sig_pixel_done AND addr_en`) en una sola condición.
3. Asignación explícita a `sig_kx`/`sig_ky`/`sig_ci` en TODAS las ramas del
   `case` (sin holds implícitos por omisión).
4. Lógica de "próximo estado" separada en una señal combinacional 100%
   completa (`sig_kx_next`, etc.), alimentando un registro trivial
   (`sig_kx <= sig_kx_next`) — ni así cambió.

También se probó el atributo `dont_touch` sobre la señal para bloquear la
optimización — **empeoró** el resultado (pasó de 1 a 3 celdas tipo latch/LUT
asociadas), confirmando que no es una elección de "conveniencia" del
optimizador sino una equivalencia booleana genuina que encuentra en la
descripción, sin importar cómo se escriba.

**Conclusión**: es una decisión de mapeo tecnológico de Vivado (LDCE usa el
mismo recurso físico de slice que FDCE, así que "es gratis" para el
optimizador cuando la función lo permite), no un bug de RTL evitable con
estilo de código. La única vía de eliminarlo con certeza sería una
recodificación estructural más grande (`sig_kx`/`sig_ky` en one-hot en vez de
binario de 2 bits, que rompería el patrón booleano específico) — pendiente de
decidir si vale la pena, según lo que salga en el timing real (ver abajo).

**Dato del reporte de timing aislado** (`report_timing -through
[get_cells ... PRIMITIVE_SUBGROUP==latch]`): la salida del latch alimenta el
pin `CE` (clock enable) de `sig_ci_reg[0]` — un patrón común y normalmente
benigno — pero el análisis fuera de contexto no pudo resolver el timing por
completo (`Slack: inf`, warnings de "no clock buffer on the path"), porque
faltaba el contexto real de reloj (which llega con el PS7). **Pendiente
confirmar en la corrida completa de `cnn_top` con el constraint real si esta
ruta cierra timing limpio o no.**

## Pendiente

- [ ] Corregir la referencia de `constrs_1` en `architecture_pl.xpr` (apunta
  todavía a `Downloads/mac_dsp.xdc` en vez de `constraints/mac_dsp.xdc` del
  repo) y agregar `cnn_top_clock.xdc` al mismo fileset.
- [x] Primera corrida de Implementation con el constraint de 100 MHz — anotar
  WNS, TNS, y el camino crítico reportado. **Hecho (out-of-context, scratch):
  WNS=-2.724ns post-ruteo, camino crítico en `ddr_addr_gen.vhd`.**
- [x] Iterar el periodo según el resultado hasta converger en un `Fmax` con
  margen razonable. **Iterado con 4 puntos (100/78/75/70 MHz) — `Fmax` real
  ≈ 74.7 MHz, acotado por el punto de 75MHz (falla por -0.056ns).**
- [x] Registrar aquí la frecuencia final elegida para `FCLK_CLK0` y por qué.
  **70 MHz (único punto probado con margen positivo real), ver sección
  "Recomendación" arriba.**
- [x] Confirmar si el timing de `sig_kx_reg[1]_LDC` cierra limpio en la
  corrida completa de `cnn_top`. **Sí — slack normal (-2.311ns, dentro del
  mismo rango que el resto del diseño a 100MHz), no es un caso especial. No
  hace falta recodificar en one-hot.**
- [x] Cuando exista el Block Design con el PS7 real: correr Implementation
  sobre el proyecto real completo (no out-of-context) para confirmar estos
  números. **Hecho (2026-07-14) — ver sección "Confirmación final" abajo.**

## Resultados (se va llenando con cada corrida)

| Fecha | Periodo constreñido | WNS (post-ruteo) | Camino crítico | Notas |
|---|---|---|---|---|
| 2026-07-13 | 10.000 ns (100 MHz) | -2.724 ns | `ddr_addr_gen.vhd` (2×DSP48E1 + 11×CARRY4, combinacional) | Falla feo. Corrida out-of-context en scratch, sin PS7 todavía. |
| 2026-07-13 | 12.821 ns (78 MHz) | -0.293 ns | mismo, vía `axi4_write_master` | Falla apenas — casi cierra. |
| 2026-07-13 | 13.333 ns (75 MHz) | -0.056 ns | mismo | Falla mínimo (2 endpoints) — corrida solo para dejar registro, no elegida. |
| 2026-07-13 | 14.286 ns (70 MHz) | **+0.288 ns** | mismo | **Pasa. Elegido como frecuencia final para `FCLK_CLK0`.** Corrida out-of-context en scratch, sin PS7 todavía. |
| **2026-07-14** | **14.285 ns (70.004 MHz, `clk_fpga_0`)** | **+0.187 ns** | (no revisado en detalle, presumiblemente el mismo) | **CONFIRMACIÓN FINAL — diseño real completo** (PS7 + Processor System Reset + 4×AXI Protocol Converter + `cnn_top`, Block Design implementado de verdad, no scratch). WHS=+0.042ns, PWS=+6.012ns, 0 endpoints fallando en las 3. Margen un poco más ajustado que la estimación out-of-context (0.187 vs 0.288 esperado) por la lógica extra real (PS7/resets/converters — endpoints totales subieron de ~14000 a ~19600), pero sigue positivo y seguro. |

## Confirmación final (2026-07-14)

Con el Block Design completo implementado de verdad (ya no out-of-context), el timing a 70MHz se confirma limpio: `WNS=+0.187ns`, `WHS=+0.042ns`, `WPWS=+6.012ns`, cero endpoints fallando en cualquiera de los tres. **Esto cierra el análisis de timing definitivamente** — la frecuencia de `FCLK_CLK0` queda en 70MHz, confirmada tanto en scratch (out-of-context) como en el proyecto real.

## Re-verificación post-bias (2026-08-04) — timing SIGUE cerrando, pero se encontró una regresión seria de recursos

Con el soporte de bias completo integrado (ver `bias_support.md`) y sin re-sintetizar desde el 2026-07-14, correspondía re-confirmar timing — el datapath POST cambió (`bias_add` entre `accumulator_bank` y `quant_relu`) y además se aplicaron los fixes de `co_counter_reg`/`acc_clear` en `max_pool.vhd`/`pool_unit.vhd` sin volver a sintetizar nunca.

Corrida out-of-context (mismo método de scratch, `cnn_top` completo, part `xc7z020clg400-2`, constraint sin cambios de `cnn_top_clock.xdc` a 70MHz):

| Fecha | Periodo constreñido | WNS (post-ruteo) | Camino crítico | Notas |
|---|---|---|---|---|
| **2026-08-04** | **14.286 ns (70 MHz)** | **+0.190 ns** | `inst_axi_slave/r04_mode_reg → sig_kx_reg[1]_LDC → inst_addr_generator (addr_in) → inst_if_buf/buf_b (RAMB36 ADDR)`, 15 niveles lógicos | **Pasa, con margen casi idéntico al de antes del bias (+0.187ns → +0.190ns).** El camino crítico CAMBIÓ de `ddr_addr_gen.vhd` (el de siempre) a uno nuevo por `addr_generator.vhd`→IFBuffer — probablemente placement distinto por el crecimiento del diseño, no una regresión real de ese camino específico. |

**Timing en sí: cerrado, sin drama.** Pero la utilización de recursos post-síntesis dio una sorpresa: LUT subió de ~17.5% a **35.65%**, y FF de ~3.4% a **34.86%** — un salto que ni el bias ni los fixes de `co_counter_reg` explican por su tamaño real (unos pocos cientos de LUTs/FFs esperados, no ~15000/~33000 nuevos).

### Causa raíz encontrada: `acc_clear` en `max_pool.vhd` rompe la inferencia de BRAM de `row_buf_ram`

`report_utilization -hierarchical` aisló el problema a un solo bloque: `inst_pool_unit/mp_inst` (`max_pool.vhd`) solo, **9756 LUTs y 33549 FFs** — el resto del diseño (incluyendo `bias_add`/`bias_buf`, `gap_unit`, todo el DMA) está en rangos normales.

Causa: el fix de `acc_clear` del 2026-07-30 (ver `bias_support.md`, sección del bug de `co_counter`) agregó esta rama al proceso síncrono de `max_pool.vhd`:

```vhdl
if( acc_clear = '1' ) then
    row_buf_ram  <= ( others => ( others => '0' ) );   -- limpia las 256 posiciones de un tirón
```

`row_buf_ram` es un arreglo de 256×128 bits que antes inferá limpio como 2 tiles de `RAMB36`. El patrón estándar de inferencia de BRAM (simple dual-port) en Vivado solo tolera escrituras indexadas de a una posición (`row_buf_ram(addr) <= dato`) — en cuanto aparece una rama que asigna el arreglo COMPLETO de un tirón (como este clear masivo), Vivado ya no puede mapearlo a un primitivo de memoria y cae a implementarlo como registros individuales distribuidos: 256 × 128 = 32768 flip-flops, más la lógica de selección/mux asociada (de ahí los ~9756 LUTs extra). Esto es intrínseco a cómo Vivado infiere BRAM, no un bug de la herramienta ni algo que dependiera de esta corrida en particular — iba a pasar la primera vez que alguien sintetizara después del fix de `acc_clear`, y nadie lo había hecho hasta hoy.

**Por qué nadie lo vio antes**: el fix se verificó en ModelSim (`tb_cnn_top_hardcore.vhd`, Caso F/L), que simula la lógica correctamente sin importar cómo se mapea a hardware real — un simulador no tiene forma de detectar un problema de inferencia de memoria. Solo aparece al sintetizar, y esta es la primera síntesis desde ese fix.

**Impacto real**: el diseño sigue cabiendo (35.65%/34.86% < 100%) y el timing sigue cerrando a 70MHz, así que no bloquea nada hoy. Pero es un desperdicio severo de recursos en el chip más ajustado de la familia (BRAM ya al 73.57%, el recurso más disputado del proyecto) y reduce mucho el margen para crecimiento futuro. **No corregido en esta sesión** — es un hallazgo de síntesis, no un bug funcional, y el fix real (reestructurar cómo se limpia `row_buf_ram` sin romper la plantilla de inferencia de BRAM — por ejemplo, un clear secuencial dirigido por contador en vez de un clear de todo el arreglo en 1 ciclo, o repensar si `row_buf_ram` necesita limpiarse en absoluto dado el patrón de escritura-antes-de-lectura dentro de cada capa) requiere diseño de RTL, pendiente de que Angel lo revise y decida el approach.

**Otros números de esta corrida** (para referencia): `bias_add` — 1491 LUT, 0 FF (puramente combinacional, esperado). `bias_buf` — 0 LUT, 8×`RAMB36` (más de lo que parece "debería" costar una memoria de 16×128 bits, pero es el costo esperado de leer 4 direcciones simultáneas distintas en el mismo ciclo — el diseño replica el almacenamiento por puerto de lectura). BRAM total: 73.57% (102 `RAMB36` + 2 `RAMB18`) — sube desde 69.29% por el neto de +8 tiles de `bias_buf` y -2 tiles que `row_buf_ram` dejó de usar (ahora en FFs). DSP: 20/220 (9.09%), sin cambios.

## Cierre — multiplicador de re-cuantización + fix de `max_pool.vhd` + fix de `mac_en`/`POST`: 70MHz CIERRA (2026-08-04)

Después de: (1) el fix de una línea en `max_pool.vhd` (quitar el clear de `row_buf_ram`, ver `bias_support.md`), (2) el multiplicador de re-cuantización con pipeline de 2 ciclos en `quant_relu.vhd`, y (3) el fix de `mac_en<=mac_valid` también en `POST` de `fsm_cnn_acc.vhd` (los tres detallados en `requantization_analysis.md`) — se corrió el análisis de timing completo una vez más, mismo método de siempre (out-of-context, `cnn_top`, `xc7z020clg400-2`, `cnn_top_clock.xdc` sin cambios a 70MHz/14.286ns):

| Fecha | Periodo constreñido | WNS (post-ruteo) | Camino crítico | Notas |
|---|---|---|---|---|
| **2026-08-04** | **14.286 ns (70 MHz)** | **+0.412 ns** | `axi_slave/r04_mode_reg → sig_kx_reg[1]_LDC → addr_generator (addr_in) → IFBuffer (RAMB36 ADDR)` — el de siempre, NO el multiplicador | **PASA, con MEJOR margen que el original pre-bias (+0.187/+0.190ns → +0.412ns).** El pipeline de `quant_relu.vhd` sacó al multiplicador del camino crítico por completo — ya no aparece ni entre los peores caminos. 0 endpoints fallando de 17354 (antes del pipeline: 302 fallando). |

**Recursos de esta corrida**: LUT 10303 (19.37%), FF 4453 (4.19%), BRAM 105 tiles (75.00%), DSP 52 (23.64% — 16 MAC array + 4 DMA + 32 del multiplicador de re-cuantización). Todo con margen cómodo salvo BRAM, que sigue siendo el recurso más disputado del proyecto pero lejos de un límite real.

**Esto cierra el ciclo de trabajo completo** iniciado con el soporte de bias: bias (orden correcto) + multiplicador de re-cuantización (reemplaza el shift-only, el cuello de botella real de accuracy) + los 2 bugs de RTL encontrados en el proceso (`row_buf_ram`/BRAM, `mac_en`/`POST`) — todos verificados en simulación (0 fallos, testbenches hardcore + bias) y ahora en timing real. Pendiente: copiar todo al espejo `accelerator/`, avisar a PS de los offsets nuevos (`0x3C`=REG_MULT, `0x4C`/`0x50` de bias), avisar a CNN_training para que actualice el simulador con el multiplicador real y vuelva a medir accuracy contra el modelo de producción.

### Headroom explorado — 75MHz también cierra (2026-08-04, no aplicado)

Con el margen de +0.412ns a 70MHz, se probó qué tan alto se podría subir. Un punto adicional real (no solo estimación lineal):

| Fecha | Periodo constreñido | WNS (post-ruteo) | Camino crítico | Notas |
|---|---|---|---|---|
| 2026-08-04 | 13.333 ns (75 MHz) | **+0.232 ns** | mismo (`axi_slave→addr_generator→IFBuffer`) | **Pasa.** Fmax real estimado con este punto + el de 70MHz: ~76-77MHz. |

**No aplicado** — `FCLK_CLK0` sigue en 70MHz, el `.xsa` exportado y la documentación de PS siguen asumiendo 70MHz. Este resultado queda como margen de rendimiento disponible para una futura optimización, no como un cambio decidido. Si se retoma, hay que re-exportar el Block Design/`.xsa` con el nuevo `FCLK_CLK0` y avisar a la sesión PS.

## CONFIRMACIÓN FINAL REAL (2026-08-05) — Angel corrió Implementation sobre el proyecto real completo

Corrida por Angel directamente en Vivado (`system_bd_wrapper` como top, no `cnn_top` solo — con `cnn_top` solo como top la implementación falla porque le falta toda la infraestructura de reloj/reset del PS7, mismo motivo por el que las corridas de scratch de esta sesión necesitaban forzar un reloj falso a mano). Diseño real completo: PS7 + Processor System Reset + 4×AXI Protocol Converter + `cnn_top` (con bias + multiplicador de re-cuantización + los 2 fixes de RTL de esta sesión).

**Resultado a 70MHz: `WNS=+0.353ns`, `WHS=+0.044ns`, 0 endpoints fallando de 24024.** Un poco menos de margen que la estimación out-of-context (+0.412ns) — mismo patrón ya visto en 2026-07-14 (lógica extra de PS7/resets/converters reduce el margen un poco frente al estimado de scratch, pero se mantiene positivo). **Esto cierra el análisis de timing definitivamente para esta ronda de cambios** — confirmado tanto out-of-context (scratch) como en el proyecto real, igual que se hizo la primera vez. Con esto, el proyecto queda listo para generar bitstream y re-exportar el `.xsa`.

## Re-verificación post-stride (2026-09-02) — sigue cerrando, con menos margen

Con el soporte de stride real completo e integrado (4 puntos: registros, wiring,
`addr_generator.vhd` con el `shift_left` condicional, generalización de
`pool_en` → `pool_en OR stride_en` en `ddr_addr_gen.vhd`/`dma_fsm.vhd` — ver
`stride_support_gap.md`) y ya verificado en simulación (`tb_cnn_top_stride.vhd`,
0 fallos), correspondía re-confirmar timing antes de dar el cambio por cerrado.

Corrida out-of-context (mismo método de siempre: batch no-project, mismos
fuentes reales + `mac_dsp.xdc` + `cnn_top_clock.xdc` sin cambios, `cnn_top`
como top vía `synth_design -mode out_of_context`, part `xc7z020clg400-2`,
70MHz/14.286ns):

| Fecha | Periodo constreñido | WNS (post-ruteo) | Camino crítico | Notas |
|---|---|---|---|---|
| **2026-09-02** | **14.286 ns (70 MHz)** | **+0.234 ns** | `inst_dma_engine/inst_reg_bank(cin) → inst_ddr_addr_gen → inst_axi4_read_master(sig_ddr_addr)` — el de siempre (cálculo combinacional de dirección DDR, 2×DSP48E1+CARRY4) | **Pasa** ("All user specified timing constraints are met", 0/17356 endpoints fallando). Margen MENOR que la última corrida pre-stride (+0.412ns → +0.234ns, -0.178ns) pero sigue positivo con comodidad. El camino crítico sigue siendo el mismo de siempre, NO uno nuevo introducido por el `or stride_en` — pero ese OR sí cae en la misma zona ya ajustada del diseño, consistente con la pérdida de margen. |

**Recursos: sin cambio real** — LUT 10252 (19.27%, prácticamente igual al 19.37% de antes), FF 4455 (4.19%, igual), BRAM 105 tiles (75.00%, igual), DSP 52 (23.64%, igual). Confirma lo anticipado en `stride_support_gap.md` Parte 4: el cambio no agrega DSPs ni crece BRAM, es puramente lógica de control (muxes/shifts).

**Pendiente**: confirmar con Implementation sobre el proyecto real (`system_bd_wrapper`) una vez Angel vuelva a sintetizar el Block Design completo — histórico (ver filas de 2026-07-14 y 2026-08-05 arriba) es que el número real sale un poco más ajustado que el de scratch, pero se mantiene positivo. Si el número real también cierra, el análisis de timing para stride queda cerrado definitivamente.

## Confirmación final real post-stride (2026-09-02)

Con el Block Design completo re-sintetizado e implementado de verdad (no scratch), **primera corrida real: `WNS=-14.289ns`, 5098 endpoints fallando de 22973 — un fallo catastrófico, no un simple recorte de margen.**

### Falso positivo: reloj fantasma por un `.xdc` que sobrevive a desmarcarlo en Package IP

Diagnóstico (`Clock Summary`): aparecían **dos relojes** sobre lo que es físicamente la misma red — `clk_fpga_0` (el real, desde el PS7, correcto) y un `clk` separado a prácticamente la misma frecuencia (14.286ns). El `Intra`/`Inter Clock Table` confirmó que **todo `cnn_top` seguía corriendo bajo el dominio `clk`** (17348 endpoints, calza con los ~17356 del chequeo aislado) mientras `clk_fpga_0` casi no tenía nada del acelerador adentro — y el peor camino, `clk_fpga_0 → clk` (4102 endpoints, TODOS fallando), es lo que producía el WNS de -14.289ns: no es que la lógica sea más lenta, es que Vivado estaba analizando dos "relojes" no relacionados como si cruzaran de dominio.

Quitar `cnn_top_clock.xdc` del fileset `constrs_1` del proyecto principal **no alcanzó** (se probó, incluso re-sintetizando todo desde cero 3 veces) — el reloj fantasma seguía apareciendo igual.

**Causa real**: `cnn_top_clock.xdc` (el `create_clock -period 14.286 ... [get_ports clk]`, pensado únicamente para los chequeos aislados out-of-context) se había colado dentro del propio IP empaquetado durante el re-empaquetado de `cnn_top` (ver la saga completa de repackaging de esta sesión). **Desmarcar el checkbox "IsInclude" en la pestaña File Groups de Package IP NO evita que Vivado copie el archivo físico** a la carpeta de trabajo del IP (`architecture_pl.gen/.../ip/system_bd_cnn_top_1_0/src/cnn_top_clock.xdc`) — y como `cnn_top`, al vivir como IP dentro del block design, se sintetiza en su **propia corrida separada** (`system_bd_cnn_top_1_0_synth_1`, con su propio `.dcp`), ese `create_clock` quedó horneado dentro de ese checkpoint. Quitar el archivo del `constrs_1` del proyecto no toca ese ámbito — son dos alcances de constraints completamente distintos.

**Fix real**: en el editor de Package IP, quitar `cnn_top_clock.xdc` de la lista de File Groups con el botón **Remove** (no el checkbox) → **Re-Package IP** → en el Block Design, click derecho sobre la instancia → **Reset Output Products** → **Generate Output Products** (fuerza a resintetizar ese IP específico desde el `component.xml` limpio, sin el `.dcp` contaminado) → volver a correr Synthesis + Implementation sobre `system_bd_wrapper`.

**Lección para la próxima vez que se re-empaquete `cnn_top`**: la pestaña File Groups de Package IP tiene dos niveles — "está en la lista" (lo que se copia físicamente al área de trabajo del IP) y "está marcado IsInclude" (lo que queda referenciado en el `component.xml`). Para archivos que NUNCA deben viajar con el IP (como un `create_clock` pensado solo para pruebas aisladas), hay que **remover el archivo de la lista por completo**, no basta con desmarcarlo.

### Resultado real, limpio (2026-09-02)

| Fecha | Periodo constreñido | WNS (post-ruteo) | Reloj | Notas |
|---|---|---|---|---|
| **2026-09-02** | **14.285 ns (70.004 MHz, `clk_fpga_0`)** | **+0.345 ns** | Un solo dominio, limpio | **PASA — 0 endpoints fallando de 22968.** Margen prácticamente igual al de la última confirmación real pre-stride (`+0.353ns`, 2026-08-05) — el soporte de stride no le costó nada apreciable al timing real del chip completo, a pesar de que el chequeo en scratch (out-of-context, ver arriba) sí mostraba un poco menos de margen (`+0.412ns → +0.234ns`). |

**Esto cierra el análisis de timing para stride definitivamente** — confirmado tanto out-of-context (scratch, `+0.234ns`) como en el proyecto real completo (`+0.345ns`), mismo patrón de siempre. El proyecto queda listo para generar bitstream y exportar el `.xsa` con el soporte de stride integrado.
