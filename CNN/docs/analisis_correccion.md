# CORRECCIÓN DE ARQUITECTURA POR LÍMITE DE CANALES DEL ACELERADOR

Este documento continúa `CNN/analisis.md` — registra un hallazgo posterior a la elección del modelo de producción (MobileNetV2 + segmentación HSV, resolución $256$ $\times$ $256$, INT8), el proceso de corrección, y el reentrenamiento resultante. Todos los archivos corregidos y sus resultados viven en `CNN/training_correction/`, separados del contenido original para no perder los resultados previos.

## EL HALLAZGO

Al iniciar el diseño del esquema de cuantización hardware-exacta (necesario porque el datapath INT8 del acelerador no soporta bias, zero-point ni escala por canal — ver más abajo), se revisó si la arquitectura de MobileNetV2 usada en el entrenamiento efectivamente respeta las restricciones de canales del acelerador.

En `inverted_residual_block`, el canal de expansión se calculaba como:

```python
exp_ch = in_ch * expand_ratio # Sin cap.
```

La constante `MAX_CH = 64` solo se aplicaba a los canales de entrada/salida de cada bloque (`min(c, MAX_CH)`), nunca al canal intermedio de expansión. En la configuración usada (`cfg` de `build_mobilenetv2`), los últimos $3$ bloques residuales parten de `in_ch=64` con `expand_ratio=2`:

$$ exp\_ch = 64 \times 2 = 128 $$

Es decir, la convolución de expansión ($1\times1$) de esos $3$ bloques generaba $128$ canales de salida, y la DepthWise $3\times3$ + convolución de proyección que siguen operaban con $128$ canales de entrada — el doble del límite de diseño del acelerador ($C_{in}, C_{out} \le 64$).

Este mismo patrón estaba presente en los tres scripts de entrenamiento (`tomatoV2.py`, `hsv_training.py`, `other_models.py`), heredado de una función `inverted_residual_block`/`mbconv_block` compartida.

### Verificación contra el RTL real

Antes de tocar el entrenamiento se confirmó, leyendo el código VHDL del acelerador, que $64$ no es una convención blanda sino un límite duro impuesto en tres puntos independientes del diseño:

1. **`co_counter`/`max_co`** (`fsm_addr_generator.vhd`): puerto de **2 bits** en la interfaz de la entidad. Con $16$ MACs en paralelo por grupo, el máximo representable es $4$ grupos $\times$ $16$ = $64$ canales de salida.
2. **`cin`** (`addr_generator.vhd`): puerto de $7$ bits que además usa un truco de bit-slice (`cin(6 downto 4)`) para extraer $C_{in}/16$ — solo correcto si $C_{in}$ es múltiplo de $16$ y $\le 64$.
3. **`weight_buf`** (`weight_buffer.vhd`): `ADDR_WIDTH=8`, exactamente $256$ palabras. La dirección de pesos en modo PointWise es `co_group × Cin + ci`; con $C_{in}=C_{out}=64$ el máximo es $3 \times 64 + 63 = 255$, que calza exacto con el buffer. Cualquier canal por encima de $64$ desborda esa dirección — sin error de síntesis, el bus de dirección simplemente se trunca y el acelerador leería pesos incorrectos.

Los tres puntos son independientes entre sí (un contador, un truco de bit-slice, un tamaño de BRAM) y los tres coinciden en $64$, confirmando que fue una decisión de diseño consistente desde el inicio del RTL, no un descuido puntual. Ampliar el límite tocaría múltiples archivos VHDL ya sintetizados y probablemente el presupuesto de BRAM (ya al $69.29\%$ de uso solo con el límite actual). Se descartó esa vía.

### Severidad

Si cualquiera de esos $3$ bloques corriera en el acelerador real tal como estaba entrenado, el direccionamiento de pesos se habría desbordado silenciosamente — lectura de pesos incorrectos, no una simple pérdida de precisión. Es un problema independiente y más grave que la brecha de cuantización descrita más abajo: aplicaría incluso si bias, zero-point y escala estuvieran perfectamente resueltos.

## LA CORRECCIÓN

Se capó el canal de expansión al mismo límite que ya se aplicaba a los demás canales:

```python
exp_ch = min( in_ch * expand_ratio, MAX_CH )
```

Aplicado en `training_correction/tomatoV2.py`, `training_correction/hsv_training.py` y `training_correction/other_models.py` (este último no se reentrenó — ver más abajo). Verificado programáticamente antes de reentrenar: ninguna capa de la arquitectura corregida excede $64$ canales.

El cambio reduce la capacidad del modelo MobileNetV2: de $84{,}937$ a $57{,}097$ parámetros ($-33\%$), concentrado en los últimos $3$ bloques residuales.

## REENTRENAMIENTO

Ejecutado en WSL (Ubuntu) con entorno conda `tf-gpu` (Python $3.11$, TensorFlow $2.17$, GPU NVIDIA RTX $3050$ detectada correctamente vía CUDA). Mismas condiciones que los entrenamientos originales: `SEED=42`, mismo split, mismos hiperparámetros (Adam, lr=$1\text{e-}3$, batch=$32$, hasta $30$ épocas con `EarlyStopping`).

Se decidió no reentrenar `other_models.py` (LeNet, EfficientNet): ya habían quedado claramente por detrás de MobileNetV2 en la comparativa original (ver `analisis.md`, sección "COMPARACIONES CON OTROS MODELOS"), no justificaba el tiempo de GPU.

### tomatoV2.py (dataset segmentado con U-Net) — resultados

| Resolución | Cuantización | Accuracy | Accuracy original (sin cap, $84{,}937$ params) | Δ |
|---|---|---|---|---|
| $256\times256$ | float32 | $0.9304$ | $0.9319$ | $-0.15$pp |
| $256\times256$ | INT8 | $0.9274$ | $0.9333$ | $-0.59$pp |
| $256\times256$ | INT16 | $0.9274$ | $0.9319$ | $-0.45$pp |
| $128\times128$ | float32 | $0.9037$ | $0.8919$ | $+1.18$pp |
| $128\times128$ | INT8 | $0.9074$ | $0.8881$ | $+1.93$pp |
| $128\times128$ | INT16 | $0.9059$ | $0.8904$ | $+1.55$pp |
| $96\times96$ | float32 | $0.8244$ | $0.8652$ | $-4.08$pp |
| $96\times96$ | INT8 | $0.8133$ | $0.8615$ | $-4.82$pp |
| $96\times96$ | INT16 | $0.8237$ | $0.8615$ | $-3.78$pp |

$256\times256$ y $128\times128$ prácticamente no se afectan por el recorte de capacidad ($128\times128$ incluso mejoró, posiblemente por menor sobreajuste). $96\times96$ sí se resiente notoriamente — con menos resolución espacial, la red parece depender más de la capacidad de canal que se recortó en los últimos $3$ bloques.

### hsv_training.py (segmentación HSV on-the-fly) — resultados

| Modelo | Resolución | Cuantización | Accuracy |
|---|---|---|---|
| MobileNetV1 | $256\times256$ | float32 | $0.8481$ |
| MobileNetV1 | $256\times256$ | INT8 | $0.8467$ |
| MobileNetV1 | $256\times256$ | INT16 | $0.8541$ |
| MobileNetV1 | $128\times128$ | float32 | $0.7681$ |
| MobileNetV1 | $128\times128$ | INT8 | $0.7711$ |
| MobileNetV1 | $128\times128$ | INT16 | $0.7726$ |
| MobileNetV1 | $96\times96$ | float32 | $0.7800$ |
| MobileNetV1 | $96\times96$ | INT8 | $0.7844$ |
| MobileNetV1 | $96\times96$ | INT16 | $0.7837$ |
| MobileNetV2 | $256\times256$ | float32 | $0.9422$ |
| MobileNetV2 | $256\times256$ | INT8 | $0.9415$ |
| MobileNetV2 | $256\times256$ | INT16 | $0.9407$ |
| MobileNetV2 | $128\times128$ | float32 | $0.8948$ |
| MobileNetV2 | $128\times128$ | INT8 | $0.9022$ |
| MobileNetV2 | $128\times128$ | INT16 | $0.8978$ |
| MobileNetV2 | $96\times96$ | float32 | $0.8874$ |
| MobileNetV2 | $96\times96$ | INT8 | $0.8881$ |
| MobileNetV2 | $96\times96$ | INT16 | $0.8926$ |

MobileNetV2 se mantiene claramente por encima de MobileNetV1 en las 3 resoluciones, confirmando la elección de arquitectura ya tomada.

### Comparación HSV vs U-Net (misma arquitectura corregida, MobileNetV2, INT8)

| Resolución | U-Net | HSV | Δ |
|---|---|---|---|
| $256\times256$ | $0.9274$ | $0.9415$ | $+1.41$pp |
| $128\times128$ | $0.9074$ | $0.9022$ | $-0.52$pp |
| $96\times96$ | $0.8133$ | $0.8881$ | $+7.48$pp |

HSV iguala o supera a U-Net en las 3 resoluciones, y es notablemente mejor a baja resolución — consistente con que HSV segmenta por color y no depende del detalle espacial que se pierde al reescalar. Comparado contra los números HSV originales (arquitectura sin capar, en `analisis.md`), el accuracy a $256\times256$ quedó prácticamente igual ($0.9422$/$0.9415$/$0.9407$ nuevo vs $0.9422$/$0.9415$/$0.9415$ viejo) — el fix de canales costó casi nada en esta variante.

## CONCLUSIÓN

La corrección de arquitectura necesaria para respetar el límite físico de canales del acelerador ($C_{in}, C_{out} \le 64$) tiene un costo de accuracy prácticamente nulo en la resolución de producción ($256\times256$), tanto para el dataset segmentado con U-Net como para el segmentado con HSV. El costo se concentra en resoluciones bajas ($96\times96$), irrelevante para la elección final.

**Modelo de producción confirmado**: MobileNetV2, segmentación HSV, resolución $256\times256$, cuantización INT8 — `training_correction/resultados_hsv/model_MobileNetV2_HSV_256x256_int8.tflite` (accuracy INT8: $94.15\%$, arquitectura ahora sí compatible con los límites de canales del acelerador real).

Este modelo (específicamente el `.keras` float32 equivalente, `model_MobileNetV2_HSV_256x256.keras`) es el punto de partida para la siguiente etapa: diseñar un esquema de cuantización hardware-exacto que simule las restricciones reales del datapath INT8 del acelerador (sin bias, sin zero-point, un solo shift por capa) en lugar del PTQ estándar de TFLite usado hasta ahora, para cuantificar qué tanto cuesta en accuracy adaptarse a esas limitaciones — ver la sección correspondiente (pendiente al momento de este documento).
