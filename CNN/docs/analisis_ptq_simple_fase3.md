# FASE 3 — PTQ SIMPLE CON ORDEN DE BIAS CORREGIDO (hardware ya modificado)

Continúa `analisis_cuantizacion_fase1.md` y `analisis_qat_fase2.md`. Documenta el diseño y resultado de `src/quantization/ptq_simple.py`, corrido después de que PL agregó y verificó en simulación un sumador de bias real en el acelerador (`accelerator/cnn_accelerator/docs/bias_support.md`).

## Motivación

PL confirmó, leyendo `cnn_accelerator.vhd` y verificando en ModelSim (`tb_cnn_top_bias.vhd`/`tb_cnn_top_hardcore.vhd`, 0 fallos), que el datapath real es:

```
accumulator_bank (INT32) -> bias_add (+bias INT32) -> quant_relu (shift, clamp INT8, ReLU6)
```

El bias se suma **antes** del shift, sobre el acumulador crudo — el orden matemático estándar (el mismo que produce `Conv+BN` fusionado en float). Es el orden **opuesto** al que asumieron Fase 1 (`hw_quant_sim.py`) y la Ronda 2 de QAT (Fase 2): ambos sumaban el bias *después* de shift+clamp+ReLU6, porque en ese momento el hardware no tenía sumador real y ese era el único punto donde "cabía" sin agregar lógica.

Con el hardware ya corregido, la pregunta que motiva esta fase: **¿alcanza con PTQ simple (sin entrenar nada nuevo) ahora que el orden de bias es el estándar?**

## Qué cambia respecto a Fase 1 (y qué no)

`ptq_simple.py` reutiliza de `hw_quant_sim.py` todo lo que es independiente del orden de operaciones: derivación de arquitectura, fusión Conv+BN, calibración de escalas de activación, cuantización simétrica de pesos, elección de shift potencia-de-2, y el forzado de escala del residuo (`add_unit.vhd` sigue sumando INT8+INT8 crudo, sin cambios ahí).

Lo que sí cambia — no es solo mover la suma de lugar:

1. **Orden**: `apply_quant_relu` ahora suma `bias` sobre el acumulador crudo, antes del shift.
2. **Escala del bias**: como `bias_add.vhd` suma sobre el acumulador INT32 (escala $S_w \cdot S_{in}$), el bias tiene que estar cuantizado en esa escala — no en $S_{out}$ (escala de salida, post-shift) como usaba el orden viejo. Es el mismo esquema que la cuantización int8 estándar de TFLite (`bias_scale = weight_scale * input_scale`): el orden real de hardware resultó ser el caso de libro, no una aproximación nueva.

## Resultado

| Esquema | Accuracy INT8 | n_test |
|---|---|---|
| PTQ estándar TFLite (sin restricciones de HW) | 94.15% | 1350 |
| QAT Fase 2, mejor ronda (Ronda 2, orden de bias VIEJO, con entrenamiento) | 19.48% | — |
| **PTQ simple Fase 3, este simulador (orden de bias CORRECTO, sin entrenamiento)** | **20.96%** | 1350 |
| PTQ hardware-exacto Fase 1 (sin bias real, orden VIEJO) | 11.11% | 1350 |

Corregir el orden del bias solo (sin ningún ajuste de entrenamiento) recupera **+9.85pp** sobre Fase 1 (11.11% → 20.96%) — confirma que el bias sí importa, en la dirección esperada. Pero el resultado queda prácticamente empatado con el mejor resultado de QAT (19.48%, que sí entrenó para compensar la restricción, aunque con el orden de bias que ya no es el real) y sigue a **73pp** del objetivo.

La matriz de confusión (`results/ptq_simple/confusion_matrix_hw_sim.csv`) no muestra el colapso a una sola clase de Fase 1 (11.11% = 1/9 exacto) — hay algo de estructura — pero está fuertemente concentrada en 2 de las 9 clases (`Late_blight` y `Spider_mites`, que juntas absorben la mayoría de las predicciones sea cual sea la clase real): la red sigue sin sobrevivir el esquema de cuantización, no es un empate estadístico casual.

## Conclusión

**Corregir el orden y la escala del bias no alcanza por sí solo.** Esto confirma la hipótesis que ya había quedado planteada en Fase 1: el bias era un problema real (y corregirlo ayuda, +9.85pp), pero el **redondeo de shift a potencia de 2 por capa** (18 de 28 capas con >10% de error, ver `analisis_cuantizacion_fase1.md`) sigue siendo el cuello de botella dominante, y es independiente del bias — ninguna corrección de bias, sola, lo compensa.

El punto de comparación más informativo no es contra el 94.15% objetivo, sino contra QAT Ronda 2 (19.48%): esa ronda tenía el orden de bias *incorrecto* pero *entrenamiento* que aprendió a tolerar el shift potencia-de-2; Fase 3 tiene el orden de bias *correcto* pero *cero entrenamiento*. Que ambas queden en el mismo rango (~19-21%) es evidencia de que la palanca real es el entrenamiento compensando el shift, no el orden del bias.

## Siguiente paso — decisión pendiente, no tomada unilateralmente

Con el hardware ya corregido (bias real, orden estándar), la combinación no probada todavía es **QAT simulando el orden correcto** (bias antes del shift, escala de acumulador) — es decir, repetir el patrón de la Ronda 2 de Fase 2, pero con `apply_quant_relu`/`quantize_bias_acc` de este archivo en vez de los de `hw_quant_sim.py`. Es plausible que esto sí cierre una parte importante de la brecha, ya que combinaría las dos fuentes de mejora que hasta ahora se probaron por separado (bias correcto sin entrenamiento: +9.85pp; entrenamiento con bias incorrecto: +8.37pp sobre Fase 1 sin bias) — pero no hay garantía de que los efectos sean aditivos, y antes de invertir en una Ronda 4 de QAT hace falta que Angel decida si vale la pena ese tiempo de entrenamiento dado el resultado modesto de ambas mejoras por separado.

## Artefactos generados

- `src/quantization/ptq_simple.py` — el simulador (incluye `load_model_compat`, un workaround no destructivo para un desfase de versión de Keras al cargar el `.keras` de producción — ver comentario en el código).
- `results/ptq_simple/layer_quant_params.json` — tabla de shift/bias/relu6_val por capa con el esquema de Fase 3. Igual que en Fase 1, **no son los valores definitivos** hasta que se cierre la decisión de la sección anterior.
- `results/ptq_simple/confusion_matrix_hw_sim.csv`, `resumen_comparacion.csv`.
