# FASE 2 — QAT HARDWARE-AWARE

Continúa `analisis_cuantizacion_fase1.md`. Documenta el diseño, las 3 rondas de iteración, y el resultado final de la Fase 2 (QAT): entrenar la red simulando durante el forward pass las restricciones reales del acelerador, para que los pesos aprendidos compensen lo que la Fase 1 demostró que el PTQ simple no podía tolerar.

## Motivación

La Fase 1 confirmó cuantitativamente que el PTQ post-entrenamiento simple no es viable (11.11% accuracy, nivel de azar) bajo las restricciones reales del acelerador — sobre todo el redondeo de shift a potencia de 2, acumulado multiplicativamente a través de ~28 capas. La pregunta de esta fase: **¿puede la red aprender a tolerar estas restricciones si las ve durante el entrenamiento?**

De paso, esta fase debía responder una pregunta de diseño pendiente desde el hallazgo original (ver `project_quantization_hw_gap`): el acelerador no tiene sumador de bias en el MAC, y se había decidido *no* modificar el RTL para agregarlo, absorbiendo el bias en software (el PS lo suma después de que el acelerador ya aplicó shift+clamp+ReLU6). Esa decisión quedó condicionada explícitamente al resultado de esta fase — si el accuracy con QAT salía aceptable, no se justificaba tocar hardware; si salía mal, sí.

## Diseño

Implementado en `CNN/src/quantization/qat/` (`layers.py`, `model.py`, entrenado por `train_qat.py`), sobre MobileNetV2 + segmentación HSV a 256×256 (el modelo de producción). Usa fake-quantization con straight-through estimator (STE): en el forward pass se simula la distorsión de cuantización (redondeo, clamp), pero el gradiente fluye como si esa operación fuera la identidad, permitiendo que el optimizador ajuste los pesos para tolerarla.

Dos piezas cuantizadas con STE, consistentes en las 3 rondas:
- **Pesos**: cuantización simétrica int8 por-tensor (`FakeQuantConv2D`/`FakeQuantDepthwiseConv2D`), misma matemática que `quantize_weight_symmetric` en `hw_quant_sim.py`.
- **Activaciones**: escala forzada a la potencia de 2 más cercana, con un EMA (media móvil exponencial) del rango observado durante el entrenamiento en vez de una calibración posterior — la aproximación por-tensor del shift de hardware.

La evaluación final en cada ronda usa `hw_quant_sim.py` (el simulador de Fase 1, extendido con una bandera `bias_enabled` para poder correr la ablación con/sin bias sobre el mismo modelo entrenado) — es la referencia bit-exacta, independiente de las simplificaciones que cada ronda de entrenamiento haya hecho.

## Ronda 1 — pesos + activaciones cuantizados, pero orden de BN estándar

Arquitectura: `Conv (sin bias) → BatchNormalization estándar (centrado + beta) → ReLU6 → fake-quant de activación`. Es decir, cuantiza pesos y activaciones, pero dentro de una `BatchNormalization` normal — el ReLU6 sigue viendo una distribución ya centrada matemáticamente, como en entrenamiento float32 estándar.

**Resultado**: 92.81% en float32 con el ruido de cuantización simulado (la red se adaptó bien a *ese* ruido) pero solo **10.44% con bias / 11.11% sin bias** bajo `hw_quant_sim.py` exacto — prácticamente igual al 11.11% de la Fase 1 sin QAT.

**Diagnóstico**: el simulador exacto aplica el bias *después* de shift/clamp/ReLU6 (`apply_quant_relu` en `hw_quant_sim.py`) — el hardware no tiene forma de centrar la distribución antes del ReLU6, porque el MAC no tiene sumador de bias. La Ronda 1 nunca expuso a la red a esa distorsión de orden — se volvió robusta a un problema que no es el que el hardware realmente tiene. Confirmado con la ablación: con-bias y sin-bias dan prácticamente lo mismo, señal de que el bias no estaba aportando nada útil (el desorden ya había destruido la información antes de que el bias pudiera corregir algo).

## Ronda 2 — orden real de hardware

Se reescribió la arquitectura para separar explícitamente lo que el hardware puede fundir en los pesos (la escala, `gamma/std`) de lo que no puede aplicar hasta después del PS (`beta - mean·scale`, el bias completo):

`Conv (sin bias) → escala BN (sin centrar) → shift/clamp int8 (simulado) → ReLU6 → +bias cuantizado → re-clamp`

Implementado como `HardwareOrderScaleQuant` (reemplaza `BatchNormalization`+`ReLU6`, expone `gamma`/`beta`/`moving_mean`/`moving_variance`/`epsilon` con los mismos nombres que `BatchNormalization` para que `hw_quant_sim.py::fuse_conv_bn` siga funcionando sin cambios) + `QuantizedBiasAdd` (suma el bias cuantizado en el punto exacto, re-clampea).

**Resultado**: 80.15% en float32 con ruido (bajó respecto a la Ronda 1 — la red enfrenta una distorsión genuinamente más difícil de tolerar), pero **19.48% con bias / 16.74% sin bias** bajo `hw_quant_sim.py` — casi el doble que la Ronda 1. Confirma que el orden de operaciones era una causa real. También, por primera vez, con-bias supera claramente a sin-bias (+2.8pp) — con el orden correcto, el bias sí aporta información útil.

## Ronda 3 — + escala forzada en el residuo

`add_unit.vhd` (el sumador de residual del acelerador) suma dos tensores int8 crudos sin rescalar — esto obliga a que, en los bloques con conexión residual (5 de 9: `irb3`, `irb5`, `irb7`, `irb8`, `irb9`), la escala de salida de la proyección (`_pw`) sea idéntica a la escala de entrada del bloque, no una calibrada independientemente. `hw_quant_sim.py` ya aplicaba esta restricción en la evaluación (`s_out_block = s_in if has_residual`); la Ronda 3 la agregó también al entrenamiento.

Implementado propagando `(tensor, eff_scale)` en vez de solo `tensor` a través de todo el grafo (`build_mobilenetv2_qat`), forzando `HardwareOrderScaleQuant` de las proyecciones residuales a usar la escala heredada del bloque en vez de su propia EMA, y agregando `ReclampToScale` después de la suma residual (el hardware también re-clampea ahí).

**Resultado**: 78.81% float32, **12.15% con bias / 13.56% sin bias** — retrocedió respecto a la Ronda 2. Forzar la escala le quita a esas 5 capas la libertad de encontrar un punto de cuantización razonable para sus propios datos — el costo en flexibilidad de entrenamiento superó el beneficio de fidelidad al hardware real.

## Verificación (antes de gastar tiempo de GPU en cada ronda)

Cada ronda se verificó con un smoke test end-to-end (construcción del modelo, forward pass en modo entrenamiento e inferencia, un `model.fit()` real confirmando que el gradiente mueve tanto los pesos de conv como los `gamma`/`beta` nuevos hasta la capa más profunda, guardado y recarga con salida numérica idéntica, y — a partir de la Ronda 2 — que `hw_quant_sim.py::fuse_conv_bn` corre sin error sobre el modelo recargado) antes de entregarle el script a Angel para entrenar con datos reales. Esto encontró y corrigió, antes de gastar GPU real:

- **Ronda 1**: las capas custom no se podían recargar desde disco (faltaba registro de serialización de Keras 3).
- **Ronda 2**: guardar valores intermedios (bias, escala) como atributo de instancia no sobrevive el trazado de grafos de Keras 3 (cada llamada se traza en un grafo aislado para inferir formas) — hubo que devolverlos como salidas reales de la capa. Esto generó un conflicto con `hw_quant_sim.py` (una capa con 3 salidas en vez de 1), resuelto con una función de compatibilidad (`primary_output`) en `build_calib_extractor`.
- **Ronda 3**: confirmado numéricamente (no solo por inspección de código) que la escala forzada en una proyección residual coincide exactamente con la escala de la entrada del bloque, antes de entrenar.

Aun así, un bug de infraestructura no relacionado con QAT en sí causó la pérdida de una corrida completa: `src/common/plotting.py` no forzaba el backend `Agg` de matplotlib, y en el entorno WSL sin servidor gráfico eso producía un crash duro (`Aborted`, no capturable) al graficar — justo después de terminar el entrenamiento pero antes de guardar el modelo. Corregido forzando `Agg` y reordenando todos los scripts de entrenamiento para guardar el modelo *antes* de graficar (con las gráficas envueltas en `try/except`), para que un fallo de plotting nunca vuelva a costar una corrida de entrenamiento completa.

## Resultado final

| Ronda | Qué simula | Con bias | Sin bias | Float32 (con ruido) |
|---|---|---|---|---|
| — (Fase 1, sin QAT) | — | — | 11.11% | — |
| 1 | Pesos + activaciones cuantizados, orden de BN estándar | 10.44% | 11.11% | 92.81% |
| 2 | + orden real (escala → shift/clamp → ReLU6 → bias → re-clamp) | **19.48%** | 16.74% | 80.15% |
| 3 | + escala forzada en proyecciones residuales | 12.15% | 13.56% | 78.81% |
| Referencia | PTQ estándar TFLite (sin restricciones de hardware) | — | 94.15% | — |

## Conclusión

**QAT no alcanza.** Se atacaron las dos causas de error identificadas con mayor confianza (orden de operaciones del bias, escala forzada del residuo) y el mejor resultado (Ronda 2, 19.48%) queda a ~75 puntos porcentuales del objetivo — muy por debajo de cualquier umbral razonable de utilidad, aunque muy por encima del azar puro, confirmando que sí hay señal real aprendida, solo que insuficiente. La Ronda 3, más fiel al hardware, empeoró en vez de mejorar — señal de que seguir iterando en la misma dirección (más fidelidad de simulación durante el entrenamiento) no tiene un camino claro hacia una mejora sostenida, y de que probablemente hace falta más que ajustes de entrenamiento para cerrar esta brecha.

**Decisión (2026-07-18, acordada con Angel antes de correr la Ronda 3 como criterio de corte): agotada la vía de software, se modifica el acelerador para soportar bias en hardware.** Revierte la decisión original de no tocar el RTL (`project_cnn_accelerator`, 2026-07-13). El plan de qué archivos tocar ya estaba pre-evaluado en esa misma sesión: `bias_buf.vhd` nuevo (mismo patrón que `residual_buf.vhd`), un banco de 16 sumadores int32 entre `accumulator_bank` y `quant_relu`, registro/estado nuevo en `reg_bank.vhd`/`dma_fsm.vhd`, y retimear el camino POST en `fsm_cnn_acc.vhd` (la suma debe ir antes del shift, agregando un ciclo en la cadena `DRAIN` ya depurada). Esto reabre timing closure (cerrado a 70MHz) y probablemente el Block Design/bring-up ya armado.

## Artefactos generados

- `CNN/src/quantization/qat/layers.py` — `FakeQuantConv2D`, `FakeQuantDepthwiseConv2D`, `PowerOfTwoActQuant` (usado en GAP), `HardwareOrderScaleQuant`, `QuantizedBiasAdd`, `ReclampToScale`.
- `CNN/src/quantization/qat/model.py` — `build_mobilenetv2_qat`, misma arquitectura/nombres de capa que `src/models/mobilenetv2.py` para compatibilidad con `hw_quant_sim.py`.
- `CNN/src/quantization/qat/train_qat.py` — entrenamiento + evaluación automática con/sin bias.
- `CNN/results/qat/model_MobileNetV2_QAT_256x256.keras` — el modelo de la Ronda 3 (última corrida; los resultados de las rondas 1 y 2 no se conservaron como checkpoints separados, solo sus métricas).
- `CNN/results/qat/hw_quant_sim_with_bias/`, `CNN/results/qat/hw_quant_sim_no_bias/` — `resumen_comparacion.csv`, `confusion_matrix_hw_sim.csv`, `layer_quant_params.json` de la Ronda 3.
- `CNN/src/quantization/hw_quant_sim.py` — extendido con la bandera `bias_enabled` (ablación) y compatibilidad con capas QAT de salida múltiple (`primary_output` en `build_calib_extractor`).
