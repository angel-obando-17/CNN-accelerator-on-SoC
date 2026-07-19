# FSM Principal — fsm_cnn_accelerator

Estados: `IDLE`, `COMPUTE`, `DRAIN`, `LATCH`, `POST`, `TILE_WAIT`, `FLUSH`, `DONE`

La FSM principal controla todo el flujo de ejecucion de una capa. El PS configura los registros de capa, carga los datos en los buffers via DMA y luego escribe `reg_start = 1`. La FSM toma el control desde ahi hasta generar el `irq_out` al terminar.

---

## IDLE

Estado de reposo. Mientras este aqui los acumuladores se mantienen en cero.

**Señales generadas:**
- `acc_clear = 1` — limpia el Accumulator Bank
- `mac_clear = 1` — limpia los acumuladores de los MACs

**Condicion de transicion:**
- `reg_start = 1` → COMPUTE

**Nota importante para el scheduler del PS**: al salir de `DONE`, la FSM pasa primero por `DONE → IDLE` y luego, en una transicion **separada**, `IDLE → COMPUTE` — ambas gateadas de forma independiente por `reg_start = 1`. Esto significa que despues de que una capa termina, la FSM necesita ver `reg_start` en `1` dos veces ( dos flancos separados, no basta con mantenerlo en alto un solo pulso si el PS lo baja entre medio ) para arrancar la siguiente capa. El firmware del PS ( `dma_fsm.vhd` en el lado DMA ) ya maneja esto con un estado adicional que sostiene el pulso un ciclo extra — ver `project_cnn_accelerator` en memoria para el detalle. Fusionar `DONE → COMPUTE` en una sola transicion se evaluo y se descarto: `gap_unit.vhd` solo limpia su acumulador en `IDLE`, asi que saltarselo corromperia cualquier capa GAP que siga a otra.

---

## COMPUTE

Aqui vive el calculo propiamente dicho. El Address Generator genera las direcciones, los buffers entregan datos y los MACs acumulan. Este estado se repite una vez por pixel del tile, y dentro de cada pixel el Address Generator itera sobre todos los elementos del inner loop ( $C_{in} \times K_y \times K_x$ para Conv3x3, solo $C_{in}$ para PW, etc ).

**Señales generadas:**
- `addr_en = 1` — habilita el Address Generator
- `mac_en = mac_valid` — los MACs acumulan solo cuando el Address Generator dice que el dato es valido. Durante los primeros 2 ciclos de cada pixel `mac_valid = 0` ( ver `FSM_AG_states.md` — warm-up de 2 ciclos por la latencia real del pipeline )
- `mux_sel`: controla que byte del word de 128 bits del IFBuffer se le manda a los MACs
  - `0` para Conv3x3 ( `reg_mode = "00"` ) y DW3x3 ( `reg_mode = "01"` )
  - `1` para PW1x1 ( `reg_mode = "10"` )

**Señales de entrada evaluadas:**
- `mac_valid` — viene del Address Generator, indica si el dato del buffer ya es valido
- `reg_mode` — determina el valor de `mux_sel`
- `pixel_done` — viene del Address Generator cuando `sig_inner_cnt = max_inner`

**Condicion de transicion:**
- `pixel_done = 1` → DRAIN
- en cualquier otro caso → COMPUTE

---

## DRAIN ( nuevo — corregido 2026-07-12/13 )

Dura exactamente 1 ciclo, incondicional. Existe unicamente para dejar que el **ultimo** acumulado real de cada pixel termine de llegar al MAC antes de que `LATCH` capture y limpie.

**Señales generadas:**
- `addr_en = 1` — se mantiene activo
- `mac_en = mac_valid` — igual que en COMPUTE, todavia gateado por el AG

**Condicion de transicion:**
- Incondicional → LATCH

### Por que existe este estado ( bug de cola / tail-drop )

El pipeline de datos entre la BRAM y el acumulador del MAC tiene **3 ciclos de latencia total**: lectura sincrona de la BRAM → registro `weight_reg` / `act_reg` en `cnn_accelerator.vhd` → acumulador propio dentro de `mac.vhd`. Antes de este fix, cuando `pixel_done` pulsaba, la FSM pasaba de `COMPUTE` a `LATCH` en un solo ciclo, y `LATCH` forzaba `mac_en = 0` incondicionalmente — exactamente el ciclo en que el **ultimo** acumulado real del pixel ( todavia en transito por el pipeline ) necesitaba `mac_en = 1` para aterrizar en el acumulador. Se perdia el ultimo tap valido de cada pixel.

No se noto en los testbenches aislados originales porque `PW1x1` no lo sufre ( ver el bug de cabeza en `FSM_AG_states.md` — se compensaban ) y en Conv3x3 / DW3x3 con tiles interiores el tap perdido casi siempre coincidia con dato cero del halo. Se detecto con `tb_cnn_top.vhd`, usando un tile 2×2 que toca los 4 bordes reales.

**Fix**: nuevo estado `DRAIN` entre `COMPUTE` y `LATCH`, 1 ciclo incondicional con `mac_en <= mac_valid` antes de que `LATCH` vuelva a su forma original simple ( capturar y limpiar sin logica adicional ). Este fix va emparejado con el warm-up extendido de `mac_valid` en `fsm_addr_generator.vhd` ( ver `FSM_AG_states.md` ), que corrige el problema simetrico al inicio del pixel ( bug de cabeza ).

**Intentos descartados antes de llegar a este fix** ( relevante si aparece un bug similar en el futuro ):
1. Condicionar la transicion `COMPUTE → LATCH` a `pixel_done AND mac_valid = 0` — rompio todo, porque `fsm_addr_generator` corre de forma autonoma ( via `addr_en` ) y nunca vuelve a coincidir esa combinacion a tiempo.
2. Meter el drenaje dentro del propio `LATCH` ( gateado por `mac_valid`, sin estado nuevo ) — arreglo Conv3x3 / DW3x3 pero rompio PW1x1 ( sobraba 1 en el primer pixel de cada capa ), porque en PW1x1 los 16 taps validos ya se completan dentro de `COMPUTE` sin necesitar el ciclo extra. De este intento fallido se descubrio que en realidad habia **dos bugs distintos compensandose numericamente**, no uno solo — el de cola aqui, y el de cabeza en el AG.

Verificado exhaustivamente antes de comitear: los 8 casos de `tb_cnn_top.vhd` (8/8) mas los 8 testbenches aislados existentes, comparando resultado por resultado contra el RTL anterior al fix.

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
- `layer_done` — viene del Address Generator, indica que este fue el ultimo pixel de la capa completa ( todos los tiles )
- `tile_boundary` — viene del Address Generator, indica que este fue el ultimo pixel del **tile actual** ( pero quedan mas tiles en la capa )
- `reg_pool_en`, `reg_pool_type` — configuracion de pooling de la capa
- `reg_has_residual` — indica si la capa tiene conexion residual

**Condiciones de transicion:**
- `post_done = 0` → POST ( espera )
- `post_done = 1` y `layer_done = 1` y NO es GAP → DONE
- `post_done = 1` y `layer_done = 1` y es GAP ( `reg_pool_en = 1` y `reg_pool_type = 1` ) → FLUSH
- `post_done = 1` y `layer_done = 0` y `tile_boundary = 1` → TILE_WAIT ( fin del tile actual, pero hay mas tiles )
- `post_done = 1` y `layer_done = 0` y `tile_boundary = 0` → COMPUTE ( siguiente pixel, mismo tile )

---

## TILE_WAIT ( nuevo — protocolo TILE_WAIT, implementado y verificado 2026-07-01 )

Estado exclusivo para capas cuyo IFBuffer no alcanza a guardar toda la capa de una sola vez ( resoluciones grandes de MobileNetV2 ). El acelerador queda totalmente congelado aqui mientras el DMA drena el OFBuffer y carga el siguiente tile ( IFM y residual si aplica — los pesos NO se recargan, son los mismos toda la capa ).

**Señales generadas:**
- `tile_req = 1` — le pide al orquestador del DMA que drene el OFBuffer y cargue el siguiente tile
- `addr_en = 1` — se mantiene activo durante toda la espera ( ver nota abajo, decision no obvia )

**Señales de entrada evaluadas:**
- `tile_ready` — viene del orquestador del DMA ( `dma_fsm.vhd` ), confirma que el intercambio de tile termino

**Condicion de transicion:**
- `tile_ready = 1` → COMPUTE ( primer pixel del tile recien cargado )
- `tile_ready = 0` → TILE_WAIT ( espera )

### Por que `addr_en` se mantiene en 1 ( no en 0 como se penso originalmente )

La congelacion de la Address Generator en `TILE_HOLD` ( ver `FSM_AG_states.md` ) no depende de `addr_en` — ese estado solo revisa `tile_ready`, asi que bajar `addr_en` no aporta nada a la sincronizacion. Peor aun: bajarlo apaga el `r_enable` del WeightBuffer / IFBuffer durante toda la espera, y al subirlo de nuevo justo cuando llega `tile_ready`, el primer canal ( `ci = 0` ) del primer pixel del nuevo tile alcanza a leer el dato **viejo** que quedo congelado en la salida de la BRAM ( 1 ciclo de latencia de lectura sin haber tenido tiempo de refrescarse ). Esto se detecto en simulacion con `tb_multilayer3.vhd`: el primer resultado salio `0x1F` en vez de `0x20`. Manteniendo `addr_en = 1` durante todo `TILE_WAIT`, el puerto de lectura de las BRAM se mantiene "caliente" leyendo continuamente la direccion ( ya fija ) del siguiente tile, asi que para cuando llega `tile_ready` el pipeline ya esta al dia. No hay riesgo de acumulacion fantasma porque `mac_en` solo se activa en `COMPUTE`, independientemente de `addr_en`. Detalle completo en `dma/tile_wait_protocol.md`.

Como el acelerador queda totalmente congelado durante `TILE_WAIT`, ni el OFBuffer ni el IFBuffer necesitan ping-pong para la version DMA secuencial — el ping-pong solo se justifica para la optimizacion futura de *prefetch* ( empezar a cargar el siguiente tile durante `COMPUTE` del tile actual, antes de llegar a `TILE_WAIT` ). Ver `dma/pipelining_tradeoffs.md`.

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
- `reg_start = 1` → IDLE ( ver nota en `IDLE` sobre los dos pulsos necesarios para arrancar la siguiente capa )
