# RE-CUANTIZACIÓN POR SHIFT POTENCIA-DE-2 — HALLAZGO Y PROPUESTA DE FIX

**Origen: sesión CNN_training, 2026-08-04.** Este documento vive en `accelerator/` (zona de la sesión PL) aunque lo escribió CNN_training, porque el hallazgo y la propuesta son sobre el datapath de `quant_relu.vhd`, no sobre entrenamiento — mismo criterio que ya se usó con `bias_support.md`. Continúa la investigación de [[project_quantization_hw_gap]] (memoria) y `CNN/docs/analisis_ptq_simple_fase3.md`.

## El hallazgo, en una frase

**El acelerador re-cuantiza con un solo desplazamiento aritmético (potencia de 2) por capa — no con el multiplicador de punto fijo que usa el PTQ estándar de TFLite — y ese redondeo, no el bias, es la causa dominante de que el modelo pierda casi toda su accuracy al correr en hardware real.**

## Qué hace el hardware hoy (confirmado en `architecture.md`, sección "Paso 1 — Shift aritmético derecho")

```
resultado = acumulador >> shift
shift = round( log2( (S_w * S_in) / S_out ) )
```

Un solo registro `REG_SHIFT` (5 bits) por capa, compartido entre los 16 canales que corren en paralelo. El hardware nunca multiplica por el factor de escala real $M = (S_w \times S_{in})/S_{out}$ — solo puede aproximarlo a la potencia de 2 más cercana, porque desplazar bits es la única operación de re-escalado que existe en el datapath.

**No encontramos ningún documento ni discusión en el repo o en la memoria del proyecto que explique por qué se eligió esta aproximación en vez de un multiplicador real** — `quant_relu.vhd` ya aparece "COMPLETO" desde el primer registro de memoria del proyecto (2026-06-03), sin debate previo registrado. Es exactamente el tipo de decisión de origen desconocido que este documento busca evitar que se repita — de ahora en más, la decisión que se tome a partir de este hallazgo sí queda documentada con su razonamiento.

## Por qué esto NO es lo mismo que "PTQ estándar, pero en hardware"

El PTQ de TFLite (y el esquema de cuantización int8 estándar en general, a veces llamado "gemmlowp") nunca redondea $M$ a una potencia de 2. Lo descompone en dos partes:

$$M = M_0 \times 2^{-shift}, \quad M_0 \in [0.5, 1)$$

$M_0$ (la "mantisa") se cuantiza a un entero de punto fijo (TFLite usa Q31, 32 bits) y se multiplica contra el acumulador con un multiplicador entero real, redondeando después. El `shift` sigue siendo un entero pequeño (igual que hoy), pero la parte que hace el trabajo fino de precisión es $M_0$, no el shift. El acelerador de este proyecto implementa solo la mitad de ese esquema — tiene el shift, pero $M_0$ está fijo e implícito en $1.0$ (nunca se aplica), lo cual es equivalente a forzar $M$ a la potencia de 2 más cercana.

## Cuantificación del costo — evidencia real, no solo teoría

Medido por CNN_training con el simulador hardware-exacto (`CNN/src/quantization/`), sobre el modelo de producción real (MobileNetV2+HSV, 94.15% en float32/PTQ estándar):

| Fuente de error simulada | Accuracy | vs. objetivo (94.15%) |
|---|---|---|
| PTQ estándar TFLite (multiplicador de punto fijo real, sin restricciones de HW) | 94.15% | — |
| Fase 1 — datapath HW-exacto: shift potencia-2 **+ sin bias** | 11.11% | −83.04pp |
| Fase 3 — datapath HW-exacto: shift potencia-2 **+ bias correcto** (orden y escala ya arreglados en hardware) | 20.96% | −73.19pp |
| QAT Fase 2 mejor ronda — shift potencia-2 (bias orden viejo) **+ entrenamiento compensando** | 19.48% | −74.67pp |

**El bias, ya corregido en hardware (`bias_support.md`), solo recupera 9.85pp.** Corregirlo era necesario pero no alcanza ni de lejos — confirma que **el shift potencia-de-2 es el cuello de botella dominante, independiente del bias**: capando el error de bias a cero (Fase 3) la red sigue sin superar el 21% de accuracy.

Medido directamente por capa en Fase 1 (`CNN/docs/analisis_cuantizacion_fase1.md`): de las 28 capas cuantizadas, **18 tienen más de 10% de error solo por el redondeo del shift**, y **8 superan 30%** (el peor caso matemático de redondear a potencia de 2 es un factor $\sqrt2 \approx 1.41$, es decir hasta 41% de error en una sola capa). Estos errores se encadenan multiplicativamente a través de las ~28 capas — no hay ninguna capa "culpable" única, es el resultado esperado y sistemático de forzar esta restricción sobre una red que nunca la vio durante el entrenamiento.

**Nota de honestidad retrospectiva**: cuando se catalogó esta restricción por primera vez (ver [[project_quantization_hw_gap]], sección "Severidad", 2026-07-13), se la calificó como *"la menos grave — una aproximación estándar en aceleradores embebidos baratos, tolerable si el entrenamiento la simula"*. Los datos reales (arriba) contradicen esa expectativa inicial: ni siquiera QAT dedicado (3 rondas) logró que fuera tolerable. La expectativa era razonable a priori pero incorrecta en la práctica — vale la pena registrar esto explícitamente para no repetir el mismo tipo de suposición sin verificar en el futuro.

## Propuesta de fix — multiplicador de punto fijo, no redondeo a potencia de 2

**No hace falta implementar el esquema completo de TFLite (Q31, 32×32 bits) para resolver esto** — el margen de mejora disponible es enorme (de hasta 41% de error por capa a algo del orden de $2^{-N}$), así que un multiplicador bastante más angosto que el de TFLite ya sería una mejora radical:

- Mantener el `shift` entero tal como existe hoy (`REG_SHIFT`, ya verificado en hardware, no se toca esa parte del mecanismo).
- Agregar un registro nuevo por capa, **`REG_MULT`** (mantisa $M_0$ cuantizada, ancho a definir — con 16 bits el error de cuantización de $M_0$ ya es del orden de $2^{-16} \approx 0.0015\%$, muchísimo mejor que el 41% actual; incluso 8 bits ($\approx 0.4\%$ de error) sería una mejora enorme frente a lo que hay hoy).
- `quant_relu.vhd` necesita una multiplicación entera real (`acumulador × M0`) antes del shift final, en vez de solo el shift. El resultado se trunca/redondea de vuelta a la escala de salida.
- **Sigue siendo 1 multiplicador+shift por capa, compartido entre los 16 canales** — esta propuesta NO toca la limitación ya documentada y aceptada de "escala por-tensor, no por-canal" (la limitación menos grave de las 3 originales, sigue siendo razonable dejarla así).

### Costo en hardware — hay margen de sobra

El sistema completo (`cnn_accelerator` + DMA, con bias ya integrado) usa **9.09% de los 220 DSP48 disponibles** (20 de 220 — ver `accelerator/dma/docs/resource_estimate.md`), 16 de ellos ya dedicados al MAC array. Un multiplicador de re-cuantización de 16-18 bits (ancho compatible con el modo nativo 25×18 del DSP48E1, el mismo patrón de multiplicación ya usado y verificado en `mac.vhd`) agregaría como máximo 16 DSP48 más (uno por canal, en paralelo, mismo patrón que el MAC array) — dejaría el sistema en el orden de ~16% de uso de DSP, lejos de cualquier límite. **DSP no es el recurso ajustado de este diseño** (BRAM sí lo es, al 69.29% — este cambio no toca BRAM en absoluto).

## Qué cambiaría del lado de CNN_training (una vez PL decida el ancho de `REG_MULT`)

Es un cambio pequeño respecto al esquema ya construido — literalmente lo que TFLite ya calcula internamente y que hoy se descarta:

- `choose_shift()` (en `hw_quant_sim.py`/`ptq_simple.py`) pasa de "redondear $M$ a la potencia de 2 más cercana" a "descomponer $M$ en $M_0 \in [0.5,1)$ cuantizado a N bits + shift entero" — es la función `QuantizeMultiplier` estándar de TFLite/gemmlowp, bien documentada públicamente, no hay que inventar el algoritmo.
- El generador de tabla de capas del lado PS (`generate_layer_table.py`, pendiente) necesita emitir `mult` además de `shift`/`bias`/`relu6_val` por capa.
- El simulador de re-cuantización (`apply_quant_relu`) pasa de `acc >> shift` a `(acc * mult) >> (shift + N)` (con el redondeo que se decida, a definir junto con el redondeo real del hardware — mismo tipo de detalle fino que costó la Fase 3 con el bias, hay que hacerlo bien la primera vez).

## Pendiente — decisión de PL

1. Confirmar ancho de `M_0` (8/16/18 bits) — trade-off entre precisión y costo de DSP/timing, aunque con el margen de recursos disponible probablemente no sea un trade-off ajustado.
2. Diseñar el rediseño de `quant_relu.vhd` (nueva etapa de multiplicación, posible ciclo extra de latencia — mismo tipo de cuidado de timing que costó varias rondas de debugging con `DRAIN`/bug de cola-cabeza, ver `project_cnn_accelerator` memoria).
3. Definir el registro nuevo (`REG_MULT`, offset AXI-Lite libre siguiente a los ya usados) y actualizar `axi_lite_slave.vhd`.
4. Una vez el hardware tenga esto verificado en simulación, avisar a CNN_training para actualizar el simulador y volver a medir accuracy real (análogo a lo que se hizo con bias: Fase 3 después de `bias_support.md`).
5. Evaluar timing: agrega un multiplicador al camino POST, mismo camino que ya se retimeó para bias — probable que haya que re-verificar closure otra vez (ya invalidado por el cambio de bias, se acumula con este).

**How to apply:** cualquier sesión que se pregunte "¿por qué el acelerador solo tiene un shift y no un multiplicador de re-cuantización real?" — la respuesta ya no es "así se diseñó desde el principio, sin razón documentada" — es: se identificó como el cuello de botella real de accuracy (este documento), y la corrección propuesta es agregar un multiplicador de punto fijo angosto (`REG_MULT`), con margen de sobra en DSP para hacerlo sin comprometer el resto del diseño. Falta que PL lo implemente y verifique.

## Decisión de PL (2026-08-04)

Cierra los 5 puntos de "Pendiente — decisión de PL" de arriba. Escrita **antes** de tocar el RTL, a propósito — es exactamente la documentación que faltó la primera vez que se eligió el esquema de shift potencia-de-2, y no puede volver a faltar.

**1. Ancho de `M₀`: 16 bits, formato Q0.16 sin signo.** `mult_int = round(M₀ × 2¹⁶)`, con M₀∈[0.5,1) así que `mult_int` cae siempre en `[32768, 65536)`, representable exacto en 16 bits sin signo. Se descartó 8 bits (error ≈0.4%, todavía significativo frente al ruido propio de INT8) y 18 bits (mejora nula: el error de cuantizar M₀ a 16 bits ya es ≈2⁻¹⁶≈0.0015%, muy por debajo del ~0.4% de granularidad que ya mete la cuantización INT8 en sí — subir el ancho no compraría nada medible, solo costo extra). 16 también empaca limpio en los 16 bits bajos de un registro AXI-Lite de 32 bits.

**2. Punto de inserción: dentro de `quant_relu.vhd`, Paso 1 únicamente.** No se toca `accumulator_bank.vhd` ni `bias_add.vhd` — la entrada sigue siendo `bias_sum` (acc+bias), igual que hoy. Cambia solo cómo se calcula `shifted` dentro de `quant_relu.vhd`: de `acc_in >> shift` pasa a `(acc_in * mult_int) >> (shift + 16)`. `REG_SHIFT` no cambia de ancho ni de rango — sigue siendo el mismo exponente entero de siempre (5 bits); el "+16" es una constante fija de hardware (bits fraccionarios de la mantisa), no un registro nuevo.

**3. Redondeo en el shift final.** Se agrega una constante de redondeo (`+ 2^(shift_total-1)`) antes del shift final, en vez de truncar (`floor`) como hace el shift-only actual. Es una mejora real que sale casi gratis al estar ya tocando esta lógica — elimina un sesgo sistemático hacia abajo que nunca se atacó porque el shift-only original no dejaba lugar para hacerlo limpio.

**4. Ancho del multiplicador y costo en DSP: 2 DSP48E1 por canal (cascada automática), 32 en total — CORREGIDO tras medir, no coincide con la predicción original.** Rango real de `acc_in` (acumulador+bias) calculado por tipo de capa: peor caso Conv3x3 con Cin=64 da ≈9.3M en magnitud, cabe cómodo en 25 bits con signo — la predicción original asumía que esto alcanzaba con el puerto nativo de 25 bits del DSP48E1 y por tanto bastaba 1 DSP por canal. **Medido en síntesis real, no fue así**: `acc_in(i)` está declarado en VHDL como `signed(31 downto 0)` completo (el ancho del tipo `int32_array`, no el rango real de valores que puede tomar), y Vivado dimensiona el multiplicador según el ancho DECLARADO, no según un análisis del rango real de valores — como 32 bits excede el puerto de 25 bits del DSP48E1, la herramienta cae a cascada de 2 DSP por canal automáticamente (mismo mecanismo que ya usa `ddr_addr_gen.vhd`, aquí sin haberlo pedido a propósito). Confirmado con `report_utilization` real: **32 DSP48E1** para `quant_relu.vhd` solo (14.55% de 220 él solo). Costo total del sistema: 16 (MAC array) + 4 (DMA) + 32 (re-cuantización) = 52 de 220 DSP (23.6%) — sigue lejos de cualquier límite, así que **no se corrige** (truncar `acc_in` a un ancho fijo "seguro" para forzar 1 DSP/canal ahorraría ~16 DSP pero metería una suposición de rango sin verificar en el RTL — no vale la pena el riesgo por un recurso que sobra).

**5. Registro nuevo: `REG_MULT`, offset `0x44`, 16 bits.** Mismo patrón que los registros ya existentes de `axi_lite_slave.vhd` (siguiente offset libre después de `0x40`=DONE).

**6. Latencia — riesgo real, no la matemática.** `quant_relu.vhd` tiene hoy 1 ciclo de latencia (el shift de ancho variable ya es lógica combinacional dentro de ese ciclo). Meta: mantener el mismo 1 ciclo si STA lo permite — un DSP48E1 combinacional debería entrar de sobra en los 14.286ns de margen a 70MHz, pero **no se asume sin verificarlo con STA real**, dado el historial de bugs de timing sutiles en este datapath específico (bug de cola/cabeza, latch fantasma). Si la síntesis real no cierra, se agrega una etapa de pipeline recién ahí — no antes.

**Plan de implementación** (orden, ver `project_cnn_accelerator` memoria / sesión PL para el detalle vivo):
1. `quant_relu.vhd` — nuevo puerto `mult`, rediseño del Paso 1. Verificado AISLADO con testbench propio primero (mismo criterio que se usó con `bias_buf.vhd`/`bias_add.vhd`) antes de integrar.
2. `axi_lite_slave.vhd` — registro `REG_MULT` nuevo (offset `0x3C` real — `0x44` fue un error de la propuesta inicial, corregido al mirar el mapa de registros real de `axi_lite_slave.vhd`).
3. `cnn_accelerator.vhd` — cablear `REG_MULT` hacia el nuevo puerto `mult` de `quant_relu`.
4. Testbench de integración (estilo `tb_cnn_top_hardcore.vhd`) con casos que fuercen `M₀` no trivial (no solo potencias exactas de 2, para de verdad ejercitar la mantisa).
5. Re-verificar timing (70MHz) — ya invalidado por el cambio de bias, se acumula con este.
6. Avisar a CNN_training para actualizar `hw_quant_sim.py`/`ptq_simple.py` (la descomposición `M₀`+`shift` real, función `QuantizeMultiplier` estándar de TFLite) y volver a medir accuracy contra el modelo de producción.

## Implementación completa — 70MHz NO cerró con 1 ciclo, se agregó pipeline (2026-08-04)

Puntos 1-3 del plan implementados y verificados en simulación (0 fallos, `tb_cnn_top_bias.vhd`/`tb_cnn_top_hardcore.vhd`) sin cambios de latencia — pero el **punto 5 (STA real) confirmó que el riesgo del punto 6 de la sección "Decisión de PL" se materializó**: a 70MHz, `WNS=-1.658ns`, camino crítico `bias_buf→bias_add→quant_relu` (28 niveles lógicos, 2×DSP48E1 en cascada). Se probaron puntos intermedios (60MHz: `-0.371ns`; 56MHz: `-0.195ns`, el mejor encontrado; 55MHz: `-1.533ns`, peor — el placer de Vivado no se comporta monótono cerca del límite con este camino). Ninguno cierra limpio — la conclusión fue que ni bajando ~20% la frecuencia se resuelve de forma confiable, así que se agregó pipeline en vez de resignar frecuencia.

**`quant_relu.vhd` pasó de 1 a 2 ciclos de latencia**: el Paso 1 se partió en dos procesos — el primero multiplica `acc_in × mult` y registra el resultado (`product_reg`, aprovechando que el DSP48E1 puede absorber ese registro como su propio registro de salida); el segundo hace el redondeo+shift+clamp+ReLU6 sobre `product_reg`, disparado por `quant_en` retrasado 1 ciclo (`quant_en_d1`). `fsm_cnn_acc.vhd` no necesitó cambios para esto — el estado `POST` ya esperaba `post_done` por nivel, no por conteo fijo de ciclos (lección aprendida del bug de cola/cabeza original).

**Bug real encontrado al verificar con `tb_cnn_top_hardcore.vhd` tras el pipeline — 11 fallos, patrón "off por 1 tap":** `POST` pasó de durar 2 a 3 ciclos, pero el "warm-up" de `mac_valid` en `fsm_addr_generator.vhd` (que salta los primeros 2 ciclos de `ACCUM` por latencia de BRAM) seguía llegando a `1` exactamente en el mismo punto de siempre (`inner_cnt=2`) — solo que ahora ese punto cae **dentro** de `POST`, donde `mac_en` seguía forzado en 0 (solo se activaba en `COMPUTE`). Se perdía el primer tap real de cada píxel que seguía a un `POST`.

Primer intento (extender el warm-up de `fsm_addr_generator.vhd` a `{0,1,2}`) fue un callejón sin salida — el largo del loop de `inner_cnt` es fijo, extender el warm-up no recupera el tap perdido, solo mueve cuándo se pierde (probado y descartado en simulación antes de proponerlo).

**Fix real, en `fsm_cnn_acc.vhd`:** dejar que `mac_en <= mac_valid` también en el estado `POST`, no solo en `COMPUTE`. El MAC array y el camino de `POST` (`accumulator_bank`→`bias_add`→`quant_relu`) son bloques de hardware separados — no hay motivo real para que la acumulación del *siguiente* píxel espere a que `COMPUTE` empiece formalmente, y de hecho `fsm_addr_generator.vhd` ya “corre adelantado” durante `POST` desde siempre (por diseño, `addr_en` está en 1 ahí). `mux_sel` no es un problema pese a no setearse en `POST` — `input_mux.vhd` usa `reg_mode` directo, `mux_sel` es una salida descartada (conectada a `open` en `cnn_accelerator.vhd`).

**Verificación final:** `tb_cnn_top_hardcore.vhd` (6 casos, F-L) y `tb_cnn_top_bias.vhd` (5 casos, A-E) — **0 fallos en ambos**, corridos contra los archivos reales del repo. Cobertura: los 3 modos de conv (Conv3x3/DW3x3/PW1x1, distintos `max_inner`), MaxPool, GAP, múltiples grupos de canales, múltiples tiles, capas encadenadas con datos reales, saturación en varios puntos. `TILE_WAIT`/`TILE_HOLD` no se tocaron a propósito — ahí `mac_valid` es siempre 0 mientras se espera al DMA, no hay tap que perder.

**Pendiente:** re-verificar timing a 70MHz otra vez (este fix también toca el datapath, aunque no debería alargar ningún camino combinacional — `mac_en<=mac_valid` en `POST` es la misma expresión que ya existía en `COMPUTE`/`DRAIN`, solo se agrega a un estado más del `case`).
