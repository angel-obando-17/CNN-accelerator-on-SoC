# SOPORTE DE BIAS EN HARDWARE

## Contexto: por que no estaba desde el principio

La arquitectura V1.0 del acelerador (ver `architecture.md`) no tenia forma de sumar un termino de bias a la salida de la convolucion. Un MAC solo acumula productos peso $\times$ activacion — el $Conv + BN$ que produce el modelo de entrenamiento se fusiona en un peso escalado mas un bias aditivo, y ese bias no tenia donde sumarse en el datapath original.

Se evaluo primero resolverlo por software: entrenar el modelo con Quantization-Aware Training (QAT) simulando que el hardware suma el bias **despues** del shift/clamp/ReLU6 (unico lugar donde "cabria" sin agregar un sumador real). Tres rondas de QAT llegaron a un maximo de 19.48% de accuracy hardware-exacto, muy por debajo del 94.15% objetivo — insuficiente. Se decidio entonces agregar el sumador de bias real al hardware.

## Diseno

Dos bloques nuevos, mismo patron que `residual_buf.vhd`:

- **`bias_buf.vhd`**: 1 arreglo de 16 posiciones $\times$ 128 bits. Escritura desde el DMA (`wr_addr` 4 bits, `data_in` 128 bits = 4 canales INT32 por palabra). Lectura desde el acelerador (`rd_addr` 2 bits = `co_counter`, lee 4 palabras consecutivas en el mismo ciclo para armar 16 canales INT32 = 512 bits). Convencion de layout: la palabra `wr_addr=N` trae los canales $4N..4N+3$ (canal mas bajo en los bits menos significativos, igual que `weight_buf`).
- **`bias_add.vhd`**: sumador combinacional puro, 16 canales INT32 en paralelo, sin clamp propio (el clamp lo hace `quant_relu` despues).

### Insercion en el datapath — orden critico

```
accumulator_bank (INT32) -> bias_add (+bias INT32) -> quant_relu (shift, clamp INT8, ReLU6) -> OFBuffer
```

El bias se suma **antes** del shift, no despues. Esto es lo opuesto al compromiso que forzo la Fase 2 de QAT (bias despues del shift, unico lugar disponible cuando no habia sumador real) — con el sumador real, se usa el orden matematico estandar, el mismo que produce `Conv+BN` fusionado en float. **Cualquier simulador o tabla de parametros que asuma el orden viejo (bias despues del shift) ya no representa el hardware real.**

Timing: `bias_buf.r_enable <= sig_acc_bank_en` y `rd_addr <= ag_co_counter`, sin estado nuevo en `fsm_cnn_acc.vhd` — se aprovecha que `ag_co_counter` todavia muestra el valor correcto durante `LATCH` (el incremento a `LAYER_CHECK` no es visible hasta el ciclo siguiente). Confirmado en simulacion, no solo por analisis de RTL (ver seccion de verificacion).

## Decision: bias siempre aplica, sin flag condicional

No existe un registro tipo `reg_has_bias` para desactivar el sumador por capa. Se evaluo explicitamente si hacia falta, revisando el codigo real de entrenamiento del modelo de produccion (`CNN/src/models/mobilenetv2.py`, usado por `CNN/src/training/train_hsv.py`):

- Las 9 capas de la arquitectura (`conv1`, cada `exp`/`dw`/`pw` de los 9 `inverted_residual_block`, `conv_last`) usan `use_bias=False` seguido siempre de `BatchNormalization`, sin excepcion ni rama condicional.
- El BN fusionado (`bias = beta - mean*scale`) produce un bias real para **toda** capa que corre por el acelerador — confirmado tambien del lado de cuantizacion (`CNN/src/quantization/qat/layers.py`, `HardwareOrderScaleQuant`).
- Las dos unicas capas sin bias propio no rompen el supuesto: GAP (`gap_unit.vhd`) opera sobre el dato ya cuantizado que salio de `quant_relu` (que ya incluyo el bias de la capa conv anterior), nunca pasa por `bias_add.vhd` directo; la capa `Dense` final tiene bias propio pero no corre en el acelerador (no hay unidad FC en el datapath), se resuelve en software en el PS.

Un flag no elimina el riesgo real documentado abajo (`bias_words=0`) — de cualquier forma habria que configurar el registro explicitamente por capa, con o sin flag.

## Verificacion en simulacion

Dos testbenches nuevos en `tb/` (locales, gitignored — ver `accelerator/tb/` para copia versionada si aplica), acelerador + DMA reales contra DDR falsa bidireccional, corridos en ModelSim (`vcom`/`vsim`):

- **`tb_cnn_top_bias.vhd`** — 5 casos: indexado de `bias_buf` por grupo de canales, orden bias-antes-del-shift en Conv3x3/DW3x3, bias antes del residual, recarga de bias entre capas (`LOAD_BIAS` no arrastra el bias de la capa anterior). **0 fallos.**
- **`tb_cnn_top_hardcore.vhd`** — 6 casos (F-K/L): bias por grupo combinado con MaxPool y GAP reales, bias compartido entre tiles (`TILE_WAIT`), saturacion con bias muy negativo (ReLU6 a 0, sin wrap-around), cadena completa de saturacion (clamp INT8 + tope ReLU6 + GAP), cadena real de 3 capas con datos propagados, saturacion propia de `add_unit.vhd` (independiente de la de `quant_relu.vhd`). **0 fallos.**

Ambos re-verificados corriendo la simulacion desde cero (no solo releyendo el codigo) el 2026-08-04, resultado identico.

### Bug real encontrado y corregido durante esta verificacion (no relacionado con bias)

`max_pool.vhd`/`gap_unit.vhd` indexaban su estado interno (`x_even_reg`/`gap_acc`) con `co_counter` **en vivo**, que ya habia avanzado al grupo siguiente cuando el dato del grupo actual todavia estaba llegando — intercambiaba resultados entre grupos de canales cuando `Cout > 16` (2+ grupos). Invisible en toda la historia del proyecto porque ningun testbench anterior combino pooling con `Cout > 16`. Fix: nueva señal `co_counter_reg` en `cnn_accelerator.vhd`, capturada en el mismo ciclo que `ofbuf_wr_addr_reg`, alimentando `pool_unit.co_counter` en vez del valor en vivo. Segundo bug relacionado: `max_pool.vhd` no tenia limpieza entre capas (a diferencia de `gap_unit.vhd`, que ya limpia via `acc_clear`) — se agrego el mismo puerto `acc_clear` a `max_pool.vhd`.

## Hallazgo pendiente, sin corregir: `bias_words=0` desborda a una rafaga de 256 beats

Si una capa no configura `DMA_BIAS_WORDS`/`DMA_ADDR_BIAS` (offsets `0x4C`/`0x50`) antes de `DMA_START`, `axi4_read_master.vhd` calcula `ARLEN` como `resize(shift_left(sig_words_left,1)-1, 8)` — con `sig_words_left=0` esto desborda un `unsigned` a `255` (256 beats) en vez de comportarse como transferencia de longitud cero. El DMA termina leyendo una rafaga completa de lo que sea que haya en `DDR` desde la direccion `0x00000000`, corrompiendo el bias de la capa. Dado que la decision de arriba es "bias siempre aplica", el firmware del PS esta obligado a configurar estos registros en **toda** capa sin excepcion, o el hardware corrompe el bias silenciosamente. Mejora de robustez pendiente (no bloqueante, no se ha dado el caso en la practica): manejar `burst_words=0` como caso especial en `axi4_read_master.vhd`.

## Pendiente

1. Copiar los archivos tocados (`cnn_accelerator.vhd`, `cnn_top.vhd`, `max_pool.vhd`, `pool_unit.vhd`, `bias_buf.vhd`, `bias_add.vhd`, y los 4 archivos de `dma/rtl/`) al espejo git-tracked `accelerator/` — ver convencion de organizacion del repo.
2. Re-verificar timing closure (era 70MHz, WNS=+0.187ns con la arquitectura pre-bias) — el datapath POST cambio, invalida esos numeros hasta re-confirmarlos.
3. Avisar a la sesion PS: offsets nuevos `0x4C` (`DMA_BIAS_WORDS`)/`0x50` (`DMA_ADDR_BIAS`) en `dma_regs.h`, y que el firmware que arma la tabla de bias debe respetar el layout de `bias_buf` (palabra `wr_addr=N` = canales $4N..4N+3$) y calcular `bias_words = ceil(Cout/4)`.
4. Avisar a la sesion CNN_training: `hw_quant_sim.py` simula el orden viejo (bias despues del shift) en `apply_quant_relu` — ya no representa el hardware real. Hace falta actualizar el orden (bias antes del shift, sumado al acumulador crudo) y volver a correr la simulacion hardware-exacta completa contra el modelo de produccion para saber la accuracy real esperada con el hardware corregido.
