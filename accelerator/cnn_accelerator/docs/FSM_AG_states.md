# FSM Address Generator — fsm_addr_generator

Estados: `IDLE`, `ACCUM`, `PIXEL_END`, `LAYER_CHECK`, `TILE_HOLD`

El Address Generator es el bloque que controla el traversal del tile pixel a pixel. Mantiene seis contadores: `inner_counter` ( loop interno del kernel ), `co_counter` ( grupo de canales de salida ), `x_counter`, `y_counter`, `tile_x_counter` y `tile_y_counter`. El [ addr_generator ] usa estos contadores para calcular las direcciones `addr_in`, `addr_w` y `addr_out` que se presentan a los buffers cada ciclo.

La FSM principal controla cuando el Address Generator esta activo mediante la señal `addr_en`. Sin `addr_en = 1` la FSM del AG no sale de IDLE ni de PIXEL_END.

Dos señales nuevas coordinan el traversal con el DMA cuando una capa necesita mas de un tile ( el IFBuffer no alcanza para una capa completa a resoluciones grandes ): `tile_boundary` ( salida, calculada en LAYER_CHECK ) y `tile_ready` ( entrada, viene del orquestador del DMA ). Ver el estado `TILE_HOLD` y `dma/tile_wait_protocol.md` para el protocolo completo.

---

## IDLE

Estado inicial y de reposo entre pixels. Los contadores se reinician aqui ( cuando `next_state = IDLE` se resetean todos en el proceso secuencial ).

**Señales generadas:**
- `counter_reset = 1` — señal de salida que indica que los contadores estan en reset
- `mac_valid = 0` — explicitamente cero para evitar que el MAC acumule datos rancios de la capa anterior en el ciclo de transicion IDLE → COMPUTE. Sin este override, el default `mac_valid = 1` causaba una acumulacion fantasma con los registros `act_reg` / `weight_reg` de la capa anterior.

**Señales de entrada evaluadas:**
- `addr_en` — viene de la FSM principal

**Condicion de transicion:**
- `addr_en = 1` → ACCUM
- `addr_en = 0` → IDLE

---

## ACCUM

Estado principal de acumulacion. Aqui `sig_inner_cnt` avanza ciclo a ciclo hasta completar los `max_inner + 1` elementos del inner loop del pixel actual ( todos los $C_{in}$ para PW, los $C_{in} \times 9$ para Conv3x3, los $9$ elementos del kernel para DW ).

**Señales generadas:**
- `mac_valid = 0` cuando `sig_inner_cnt = 0` **o** `sig_inner_cnt = 1` ( warm-up de 2 ciclos, ver nota abajo )
- `mac_valid = 1` el resto del tiempo
- `pixel_done = 1` cuando `sig_inner_cnt = max_inner` ( ultimo elemento del inner loop )

**Señales de entrada evaluadas:**
- `sig_inner_cnt` — contador interno, incrementado en el proceso secuencial
- `max_inner` — limite del inner loop, cargado por el PS antes de cada capa
- `addr_en` — si cae a `0` en medio de ACCUM, tiene prioridad sobre la cuenta de `max_inner`

**Condiciones de transicion ( en orden de prioridad ):**
- `addr_en = 0` → IDLE ( la FSM principal ya terminó / abortó; sin esto, al terminar la ultima capa el AG completaba un ciclo ACCUM espurio con contadores desbordados — bug corregido 2026-06-10 )
- `sig_inner_cnt = max_inner` → PIXEL_END ( pixel terminado )
- en cualquier otro caso → ACCUM ( sigue acumulando )

El incremento de `sig_inner_cnt` tiene una guarda para que no desborde: solo incrementa si `sig_inner_cnt < max_inner`.

### Por que el warm-up de `mac_valid` dura 2 ciclos y no 1 ( corregido 2026-07-12/13 )

El pipeline real de datos entre el AG y el acumulador tiene **3 ciclos de latencia total**: lectura sincrona de la BRAM ( IFBuffer / WeightBuffer ) → registro `weight_reg` / `act_reg` en `cnn_accelerator.vhd` → acumulador propio dentro de `mac.vhd`. Originalmente solo se cubria el primer ciclo ( `sig_inner_cnt = 0` ), asumiendo 1 ciclo de latencia.

Esto se manifestaba como un **bug de cabeza ( double-count )**: durante el handoff `IDLE → ACCUM` ( o `TILE_HOLD → ACCUM` ), la direccion del primer elemento del inner loop ( `ci = 0`, o `ky = kx = ci = 0` en Conv3x3 / DW3x3 ) queda mostrada 2 ciclos seguidos — uno por `counter_reset` de IDLE, uno mas por el retraso normal de un contador recien reseteado antes de incrementar. Con 2 ciclos reales de latencia de pipeline, **ambas lecturas se usan de verdad**, duplicando ese primer combo.

No se noto antes porque en Conv3x3 / DW3x3 con tiles interiores ese primer combo casi siempre cae en el halo ( dato cero, duplicar cero es inofensivo ); en PW1x1 el primer combo es dato real, asi que sumaba de mas. Se detecto con `tb_cnn_top.vhd` usando un tile 2×2 que toca los 4 bordes ( halo real en vez de dato interior ).

**Fix**: el warm-up de `mac_valid = 0` se extendio para cubrir `sig_inner_cnt = 0 OR sig_inner_cnt = 1`. Este fix va emparejado con el nuevo estado `DRAIN` en `fsm_cnn_acc` ( ver `FSM_main_states.md` ), que corrige el problema simetrico en el otro extremo del pixel ( bug de cola ).

---

## PIXEL_END

Estado de sincronizacion con la FSM principal. Aqui se calcula `sig_layer_done` y `sig_tile_boundary` comparando los contadores contra sus valores maximos. Ese calculo ocurre en el proceso secuencial en el ciclo en que `current_state = PIXEL_END`, entonces ambas señales estaran disponibles en el ciclo siguiente ( LAYER_CHECK ).

La FSM espera aqui hasta que `addr_en = 1` para avanzar. Esto la sincroniza con la FSM principal, que baja `addr_en` durante LATCH y lo vuelve a subir en POST.

**Señales generadas:**
- `pixel_done = 1` — se mantiene activa mientras la FSM principal procesa el pixel

**Señales de entrada evaluadas:**
- `addr_en` — espera que la FSM principal la habilite para continuar

**Condicion de transicion:**
- `addr_en = 1` → LAYER_CHECK
- `addr_en = 0` → PIXEL_END ( espera )

---

## LAYER_CHECK

Decide si el tile termino, si la capa completa termino, o si hay mas pixels por procesar. En este ciclo tambien se actualizan los contadores externos en el proceso secuencial: si `sig_layer_done = 0` se incrementa el siguiente contador en la jerarquia ( co → x → y → tile_x → tile_y ) y `sig_inner_cnt` se resetea a cero para el proximo pixel.

El orden de los contadores es: primero todos los co_groups del pixel, luego los pixels de la fila ( x ), luego las filas del tile ( y ), luego los tiles horizontales ( tile_x ) y finalmente los tiles verticales ( tile_y ).

**Señales generadas:**
- `pixel_done = 1` — se mantiene activa un ciclo mas
- `mac_valid = 0` — explicitamente cero para evitar que el MAC acumule datos del pixel anterior en el ciclo de transicion POST → COMPUTE ( misma razon que en IDLE )

**Señales de entrada evaluadas:**
- `sig_layer_done` — calculado en el ciclo anterior ( PIXEL_END ): `co_cnt=max_co AND x_cnt=max_x AND y_cnt=max_y AND tile_x_cnt=max_tile_x AND tile_y_cnt=max_tile_y`
- `sig_tile_boundary` — calculado en el ciclo anterior ( PIXEL_END ): `co_cnt=max_co AND x_cnt=max_x AND y_cnt=max_y`, sin importar `tile_x`/`tile_y`. Es un chequeo mas laxo que `layer_done` — de hecho `layer_done` implica `tile_boundary = 1` tambien.

**Condiciones de transicion:**
- `sig_layer_done = 1` → IDLE ( capa terminada, contadores se resetean )
- `sig_layer_done = 0 AND sig_tile_boundary = 1` → TILE_HOLD ( grilla x,y,co del tile actual terminada, pero quedan mas tiles )
- `sig_layer_done = 0 AND sig_tile_boundary = 0` → ACCUM ( siguiente pixel, mismo tile )

---

## TILE_HOLD ( nuevo — protocolo TILE_WAIT, implementado y verificado 2026-07-01 )

Estado exclusivo para capas cuyo IFBuffer no alcanza a guardar toda la capa de una sola vez ( resoluciones grandes de MobileNetV2 ). Aqui la AG se congela esperando que el DMA termine de drenar el OFBuffer y cargar el siguiente tile, exactamente igual que IDLE se congela esperando `addr_en` — pero esperando `tile_ready` en su lugar.

**Señales generadas:**
- `pixel_done = 1` — se mantiene activa
- `mac_valid = 0` — evita acumulacion fantasma cuando se reanude

**Señales de entrada evaluadas:**
- `tile_ready` — viene del orquestador del DMA ( `dma_fsm.vhd` ), confirma que el intercambio de tile termino

**Condicion de transicion:**
- `tile_ready = 1` → ACCUM ( primer pixel del tile recien cargado; `x`, `y`, `co` ya estan en 0, `tile_x`/`tile_y` ya se incrementaron en LAYER_CHECK )
- `tile_ready = 0` → TILE_HOLD ( espera )

**Por que `addr_en` se mantiene en 1 durante todo el intercambio** ( decidido en `fsm_cnn_acc`, no aqui, pero afecta directamente a este estado ): la congelacion de la AG en TILE_HOLD no depende de `addr_en` — este estado solo revisa `tile_ready`. Bajar `addr_en` apagaria el `r_enable` de los buffers durante toda la espera, y al subirlo justo cuando llega `tile_ready`, el primer canal del primer pixel del nuevo tile alcanzaria a leer el dato viejo congelado en la salida de la BRAM ( 1 ciclo de latencia sin tiempo de refrescarse ). Detalle completo, con el caso de test que expuso el bug ( `0x1F` en vez de `0x20` ), en `dma/tile_wait_protocol.md`.

Los pesos NO se recargan en cada intercambio de tile — son los mismos durante toda la capa. Solo IFM y residual ( si aplica ) se recargan por tile.
