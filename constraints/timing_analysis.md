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
- [ ] Cuando exista el Block Design con el PS7 real: correr Implementation
  sobre el proyecto real completo (no out-of-context) para confirmar estos
  números con `HD.CLK_SRC` resuelto correctamente, y aplicar el constraint
  de 50 MHz al configurar `FCLK_CLK0`.

## Resultados (se va llenando con cada corrida)

| Fecha | Periodo constreñido | WNS (post-ruteo) | Camino crítico | Notas |
|---|---|---|---|---|
| 2026-07-13 | 10.000 ns (100 MHz) | -2.724 ns | `ddr_addr_gen.vhd` (2×DSP48E1 + 11×CARRY4, combinacional) | Falla feo. Corrida out-of-context en scratch, sin PS7 todavía. |
| 2026-07-13 | 12.821 ns (78 MHz) | -0.293 ns | mismo, vía `axi4_write_master` | Falla apenas — casi cierra. |
| 2026-07-13 | 13.333 ns (75 MHz) | -0.056 ns | mismo | Falla mínimo (2 endpoints) — corrida solo para dejar registro, no elegida. |
| 2026-07-13 | 14.286 ns (70 MHz) | **+0.288 ns** | mismo | **Pasa. Elegido como frecuencia final para `FCLK_CLK0`.** |
