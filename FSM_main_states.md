# FSM Principal — fsm_cnn_accelerator

Estados: `IDLE`, `COMPUTE`, `LATCH`, `POST`, `FLUSH`, `DONE`

La FSM principal controla todo el flujo de ejecucion de una capa. El PS configura los registros de capa, carga los datos en los buffers via DMA y luego escribe `reg_start = 1`. La FSM toma el control desde ahi hasta generar el `irq_out` al terminar.

---

## IDLE

Estado de reposo. Mientras este aqui los acumuladores se mantienen en cero.

**Señales generadas:**
- `acc_clear = 1` — limpia el Accumulator Bank
- `mac_clear = 1` — limpia los acumuladores de los MACs

**Condicion de transicion:**
- `reg_start = 1` → COMPUTE

---

## COMPUTE

Aqui vive el calculo propiamente dicho. El Address Generator genera las direcciones, los buffers entregan datos y los MACs acumulan. Este estado se repite una vez por pixel del tile, y dentro de cada pixel el Address Generator itera sobre todos los elementos del inner loop ( $C_{in} \times K_y \times K_x$ para Conv3x3, solo $C_{in}$ para PW, etc ).

**Señales generadas:**
- `addr_en = 1` — habilita el Address Generator
- `mac_en = mac_valid` — los MACs acumulan solo cuando el Address Generator dice que el dato es valido. En el primer ciclo de cada pixel `mac_valid = 0` porque la BRAM aun no entrego el dato
- `mux_sel`: controla que byte del word de 128 bits del IFBuffer se le manda a los MACs
  - `0` para Conv3x3 ( `reg_mode = "00"` ) y DW3x3 ( `reg_mode = "01"` )
  - `1` para PW1x1 ( `reg_mode = "10"` )

**Señales de entrada evaluadas:**
- `mac_valid` — viene del Address Generator, indica si el dato del buffer ya es valido
- `reg_mode` — determina el valor de `mux_sel`
- `pixel_done` — viene del Address Generator cuando `sig_inner_cnt = max_inner`

**Condicion de transicion:**
- `pixel_done = 1` → LATCH

---

## LATCH

Dura exactamente 1 ciclo. En este ciclo el Accumulator Bank captura los valores de los 16 acumuladores del MAC Array antes de limpiarlos. Tambien se mantiene `addr_en` activo para que el Address Generator tenga la direccion de salida lista para capturar en `ofbuf_wr_addr_reg`.

**Señales generadas:**
- `acc_bank_enable = 1` — captura los acumuladores al banco de registros
- `mac_clear = 1` — limpia los MACs para el siguiente pixel
- `addr_en = 1` — necesario para que `ag_addr_out` sea valido en este ciclo y se capture en el registro de direccion del OFBuffer

**Condicion de transicion:**
- Incondicional → POST

---

## POST

Post-procesamiento del pixel actual. El bloque [ quant_relu ] toma los valores del Accumulator Bank, aplica el shift aritmetico, el clamp a INT8 y opcionalmente ReLU6. Si hay residual se suma con el [ add_unit ]. Si hay pooling el [ pool_unit ] toma el resultado. La FSM espera aqui hasta que `post_done = 1`.

**Señales generadas:**
- `relu_en = 1` — habilita la funcion de activacion ReLU6 en quant_relu
- `quant_en = 1` — habilita la cuantizacion en quant_relu
- `addr_en = 1` — mantiene el Address Generator activo para que las señales de direccion residual sean validas
- `add_en = reg_has_residual` — habilita el Add Unit si la capa tiene conexion residual
- `addr_res = reg_has_residual` — habilita la direccion al Residual Buffer si hay residual
- `pool_act = reg_pool_en` — activa el [ pool_unit ] si la capa tiene pooling
- `pool_type_sel = reg_pool_type` — le dice al pool_unit si usar MaxPool ( 0 ) o GAP ( 1 )

**Señales de entrada evaluadas:**
- `post_done` — viene de quant_relu ( `valid_out` ), indica que el pixel esta procesado
- `layer_done` — viene del Address Generator, indica que este fue el ultimo pixel del tile
- `reg_pool_en`, `reg_pool_type` — configuracion de pooling de la capa
- `reg_has_residual` — indica si la capa tiene conexion residual

**Condiciones de transicion:**
- `post_done = 0` → POST ( espera )
- `post_done = 1` y `layer_done = 0` → COMPUTE ( siguiente pixel )
- `post_done = 1` y `layer_done = 1` y NO es GAP → DONE
- `post_done = 1` y `layer_done = 1` y es GAP ( `reg_pool_en = 1` y `reg_pool_type = 1` ) → FLUSH

---

## FLUSH

Estado exclusivo para Global Average Pooling. El GAP no puede escribir su resultado hasta haber acumulado todos los pixeles del tile, entonces cuando `layer_done = 1` la FSM entra aqui y espera a que el [ gap_unit ] termine de escribir los co_groups al OFBuffer.

Para MobileNetV2 con $C_{out} = 64$ ( 4 co\_groups ), este estado dura 5 ciclos.

**Señales generadas:** ninguna ( todo a cero ).

**Señales de entrada evaluadas:**
- `gap_done` — viene del gap_unit cuando termino de escribir todos los co_groups

**Condiciones de transicion:**
- `gap_done = 0` → FLUSH ( espera )
- `gap_done = 1` → DONE

---

## DONE

La capa termino. Se genera la interrupcion hacia el PS. El PS lee el OFBuffer via DMA, decide si lanzar la siguiente capa o terminar, y cuando esta listo escribe `reg_start = 1` para volver al inicio.

**Señales generadas:**
- `reg_done = 1` — indica al PS que el acelerador termino
- `irq_out = 1` — interrupcion hacia el PS

**Señales de entrada evaluadas:**
- `reg_start` — el PS escribe 1 cuando quiere lanzar la siguiente capa

**Condicion de transicion:**
- `reg_start = 1` → IDLE
