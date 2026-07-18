# FASE 1 — SIMULADOR DE CUANTIZACIÓN HARDWARE-EXACTA (PTQ)

Continúa `training_correction/analisis_correccion.md`. Documenta el diseño y resultado de `hw_quant_sim.py`, el simulador que reemplaza el PTQ estándar de TFLite por la aritmética real del acelerador, para responder la pregunta que originó la sesión CNN_training: **¿cuánto cuesta en accuracy adaptarse a las limitaciones reales del hardware?**

## Motivación

El PTQ estándar de TFLite (usado en `hsv_training.py`, 94.15% accuracy INT8) asume un hardware que el acelerador real no tiene. Verificado leyendo el RTL (`mac.vhd`, `accumulator_bank.vhd`, `add_unit.vhd`, `quant_relu.vhd`):

1. **Sin bias en el MAC.** El bias debe sumarse en software, después de que el hardware ya aplicó shift + clamp INT8 + ReLU6 — no antes, como asume la matemática ideal de cuantización.
2. **Sin zero-point.** Cuantización simétrica forzada (`zero_point = 0`) en pesos y activaciones.
3. **Un solo shift (potencia de 2) por capa**, compartido entre los 16 canales en paralelo — no hay escala distinta por canal de salida.
4. **`add_unit.vhd` suma dos tensores INT8 crudos, sin rescalar.** En los bloques con residual, esto obliga a que la escala de salida de la conv de proyección sea idéntica a la escala de entrada del bloque — no hay forma de rescalar el residuo guardado en DDR al sumarlo.

## Diseño del simulador (`hw_quant_sim.py`)

Carga el modelo de producción ya entrenado (`training_correction/resultados_hsv/model_MobileNetV2_HSV_256x256.keras`), y en vez de `TFLiteConverter`:

1. Fusiona cada Conv/DepthwiseConv + BatchNormalization en un (peso, bias) efectivo.
2. Cuantiza pesos simétrico, por-tensor (no por-canal), `zero_point=0`.
3. Calibra escalas de activación con 200 imágenes de entrenamiento (mismo preprocesamiento HSV que `hsv_training.py`), usando el modelo float original para capturar exactamente la distribución que la red aprendió.
4. Elige el shift de cada capa como la potencia de 2 más cercana al multiplicador ideal $M = (S_w \cdot S_{in})/S_{out}$.
5. En los bloques residuales, fuerza $S_{out}$ de la conv de proyección a ser igual a $S_{in}$ del bloque (restricción 4 de arriba).
6. Corre el forward pass en aritmética entera real: `conv INT8 → acumulador INT32 → shift aritmético → clamp INT8 → ReLU6 → +bias INT8 → re-clamp INT8`, capa por capa, incluyendo el GAP (acumulador propio, shift independiente) y el bloque de suma residual (INT8+INT8 crudo).
7. La capa Dense final corre fuera del acelerador (no hay unidad FC en el datapath), en float32 sobre el resultado ya dequantizado del GAP — asumido así porque es la única forma razonable dado que el acelerador no tiene esa capacidad.

## Verificación del simulador antes de confiar en el resultado

Antes de aceptar cualquier número, se verificó el simulador contra el modelo real en varios niveles (ver bitácora de depuración de la sesión):

- **Convolución + fusión BN**: comparado contra la salida real de Keras usando el input SIN cuantizar — diferencia máxima $3.8\times10^{-6}$ (ruido de punto flotante). Matemáticamente correcto.
- **Cuantización del input**: la reconstrucción (cuantizar → dequantizar) reproduce la imagen original con un error medio de $0.0008$, consistente con el paso de cuantización esperado ($S_{in}/2 \approx 0.0039$). Correcto.
- **TF32 (tensor cores, GPU Ampere)**: se sospechó que truncaba precisión en `tf.nn.conv2d`; se desactivó explícitamente (`tf.config.experimental.enable_tensor_float_32_execution(False)`) — el resultado no cambió, descartado como causa.
- **Aislamiento por capa**: comparando cada capa contra su equivalente float real, con y sin el redondeo de shift a potencia de 2, se aisló la fuente exacta de la divergencia al paso de shift, no a la convolución, no a la cuantización de pesos, no a la cuantización de input.

## El hallazgo: el redondeo de shift a potencia de 2 es el problema, y es sistemático

Midiendo, para cada una de las 28 capas cuantizadas, qué tan lejos queda el multiplicador realmente aplicado ($2^{-shift}$) del multiplicador ideal ($M$):

- **18 de 28 capas** tienen más de 10% de error solo por el redondeo del shift.
- **8 de 28 capas** superan 30% de error en una sola capa (el peor caso matemático posible para redondeo a potencia de 2 es un factor $\sqrt{2} \approx 1.41$, es decir hasta 41%).
- El promedio de los factores de error across capas es $\approx 1.0$ (no hay sesgo sistemático de sobre- o sub-estimación), pero la varianza por capa es alta.

Como estos errores son multiplicativos y se encadenan a través de las ~28 capas cuantizadas de la red (conv1 + 9 bloques × 2-3 sub-capas + conv_last + GAP), el efecto se acumula: no hay ninguna capa "culpable" única, es el resultado esperado de imponer una restricción de shift potencia-de-2 por capa sobre una red que fue entrenada sin conocimiento de esa restricción.

## Resultado

| Esquema | Accuracy INT8 | n_test |
|---|---|---|
| PTQ estándar TFLite (`hsv_training.py`) | 94.15% | 1350 |
| **PTQ hardware-exacto (Fase 1, este simulador)** | **11.11%** | 1350 |

$11.11\% = 150/1350$ — exactamente $1/9$, el mismo tamaño que cada clase en el test set balanceado. La red colapsó a predecir una única clase constante para prácticamente todas las imágenes: **nivel de azar puro**, no hay señal útil sobreviviendo el esquema de cuantización tal como está.

## Conclusión

**El PTQ post-entrenamiento, sin ningún ajuste, no es viable bajo las restricciones reales del acelerador.** La red nunca vio estas restricciones durante el entrenamiento y no tiene ningún margen aprendido para tolerarlas — el error de redondeo de shift por sí solo, acumulado a través de ~28 capas, es suficiente para destruir toda la señal útil.

Esto responde directamente la pregunta que originó esta sesión (ver [[project_quantization_hw_gap]]): el costo de adaptarse a las limitaciones de hardware **no es aceptable** con PTQ simple. Confirma que la Fase 2 (QAT — entrenar la red simulando estas mismas restricciones exactas, para que los pesos aprendidos compensen el redondeo de shift, el zero-point forzado, y el orden real de aplicación del bias) no es opcional, es necesaria.

## Artefactos generados

- `hw_quant_sim.py` — el simulador, reutilizable para evaluar cualquier checkpoint futuro (incluido el que salga de QAT).
- `hw_quant_sim_results/layer_quant_params.json` — tabla de shift/bias/relu6_val por capa, formato pensado para `generate_layer_table.py` (lado PS) una vez el esquema final esté cerrado — **estos valores específicos corresponden al esquema PTQ que acaba de fallar, no son los definitivos** hasta que se repita el proceso sobre el modelo que salga de QAT.
- `hw_quant_sim_results/confusion_matrix_hw_sim.csv`, `resumen_comparacion.csv`.
