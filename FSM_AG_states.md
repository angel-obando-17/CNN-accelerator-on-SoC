# FSM Address Generator — fsm_addr_generator

Estados: `IDLE`, `ACCUM`, `PIXEL_END`, `LAYER_CHECK`

El Address Generator es el bloque que controla el traversal del tile pixel a pixel. Mantiene seis contadores: `inner_counter` ( loop interno del kernel ), `co_counter` ( grupo de canales de salida ), `x_counter`, `y_counter`, `tile_x_counter` y `tile_y_counter`. El [ addr_generator ] usa estos contadores para calcular las direcciones `addr_in`, `addr_w` y `addr_out` que se presentan a los buffers cada ciclo.

La FSM principal controla cuando el Address Generator esta activo mediante la señal `addr_en`. Sin `addr_en = 1` la FSM del AG no sale de IDLE ni de PIXEL_END.

---

## IDLE

Estado inicial y de reposo entre pixels. Los contadores se reinician aqui ( cuando `next_state = IDLE` se resetean todos en el proceso secuencial ).

**Señales generadas:**
- `counter_reset = 1` — señal de salida que indica que los contadores estan en reset
- `mac_valid = 1` ( valor por defecto del proceso )

**Señales de entrada evaluadas:**
- `addr_en` — viene de la FSM principal

**Condicion de transicion:**
- `addr_en = 1` → ACCUM
- `addr_en = 0` → IDLE

---

## ACCUM

Estado principal de acumulacion. Aqui `sig_inner_cnt` avanza ciclo a ciclo hasta completar los `max_inner + 1` elementos del inner loop del pixel actual ( todos los $C_{in}$ para PW, los $C_{in} \times 9$ para Conv3x3, los $9$ elementos del kernel para DW ).

En el primer ciclo de cada pixel ( `sig_inner_cnt = 0` ) el dato del buffer todavia no esta disponible por la latencia de 1 ciclo de la BRAM, entonces `mac_valid = 0` para evitar que el MAC acumule basura. A partir del segundo ciclo `mac_valid = 1`.

El incremento de `sig_inner_cnt` tiene una guarda para que no desborde: solo incrementa si `sig_inner_cnt < max_inner`. Sin esta guarda, en el ultimo ciclo el contador llegaria a `max_inner + 1` antes de que la transicion a PIXEL_END ocurriera.

**Señales generadas:**
- `mac_valid = 0` cuando `sig_inner_cnt = 0` ( primer ciclo del pixel, dato aun no disponible )
- `mac_valid = 1` el resto del tiempo
- `pixel_done = 1` cuando `sig_inner_cnt = max_inner` ( ultimo elemento del inner loop )

**Señales de entrada evaluadas:**
- `sig_inner_cnt` — contador interno, incrementado en el proceso secuencial
- `max_inner` — limite del inner loop, cargado por el PS antes de cada capa

**Condiciones de transicion:**
- `sig_inner_cnt = max_inner` → PIXEL_END ( pixel terminado )
- `sig_inner_cnt < max_inner` → ACCUM ( sigue acumulando )

---

## PIXEL_END

Estado de sincronizacion con la FSM principal. Aqui se calcula `sig_layer_done` comparando todos los contadores contra sus valores maximos. Ese calculo ocurre en el proceso secuencial en el ciclo en que `current_state = PIXEL_END`, entonces `sig_layer_done` estara disponible en el ciclo siguiente ( LAYER_CHECK ).

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

Decide si el tile termino o si hay mas pixels por procesar. En este ciclo tambien se actualizan los contadores externos en el proceso secuencial: si `sig_layer_done = 0` se incrementa el siguiente contador en la jerarquia ( co → x → y → tile_x → tile_y ) y `sig_inner_cnt` se resetea a cero para el proximo pixel.

El orden de los contadores es: primero todos los co_groups del pixel, luego los pixels de la fila ( x ), luego las filas del tile ( y ), luego los tiles horizontales ( tile_x ) y finalmente los tiles verticales ( tile_y ).

**Señales generadas:**
- `pixel_done = 1` — se mantiene activa un ciclo mas

**Señales de entrada evaluadas:**
- `sig_layer_done` — calculado en el ciclo anterior ( PIXEL_END )

**Condiciones de transicion:**
- `sig_layer_done = 1` → IDLE ( capa terminada, contadores se resetean )
- `sig_layer_done = 0` → ACCUM ( siguiente pixel )
