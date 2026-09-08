# Catálogo de optimizaciones de velocidad de inferencia

**Escrito 2026-09-08.** Reúne, cuantifica y ordena todas las vías conocidas
para acelerar el acelerador. Ninguna está implementada: el diseño actual es la
versión secuencial correcta, y este documento existe para que la sección de
*trabajos futuros* del documento final tenga números en vez de adjetivos, y
para que quien retome el proyecto sepa dónde está la plata.

## Punto de partida medido

| Parte | Ciclos | % del total |
|---|---|---|
| Cómputo | 5.554.432 | **79,8 %** |
| Transferencia IFM | 751.272 | 10,8 % |
| Transferencia OFM | 654.495 | 9,4 % |
| **Total** | **6.960.199** | **99,4 ms @ 70 MHz ≈ 10,1 fps** |

Modelos: cómputo `= píxeles · co_groups · (max_inner + 3,75)`, validado en
simulación en los tres modos; transferencia `= 3 · ráfagas + 2 · palabras`
(lectura) y `3 · palabras` (escritura), medido. Ver
[`../../dma/docs/pipelining_tradeoffs.md`](../../dma/docs/pipelining_tradeoffs.md).

**La lectura clave: cuatro quintas partes del tiempo son cómputo.** Cualquier
optimización que sólo ataque la transferencia tiene un techo del 20 %.

## Tabla comparativa

Ordenadas por relación beneficio/esfuerzo, no por beneficio bruto.

| # | Optimización | Tiempo | Ganancia | Esfuerzo | Riesgo |
|---|---|---|---|---|---|
| 1 | Subir el reloj atacando `addr_generator` → 100 MHz | 69,6 ms | **+30 %** | bajo-medio | bajo |
| 2 | Sobrecosto de FSM 3,75 → ~1 ciclo | 91,3 ms | **+8 %** | medio | medio |
| 3 | `axi4_write_master` a 2 ciclos/palabra | 96,4 ms | **+3 %** | bajo | bajo |
| 4 | Prefetch de IFM (ping-pong real) | 88,7 ms | **+11 %** | alto | alto |
| 5 | Ping-pong del OFBuffer (además del 4) | 79,3 ms | **+20 %** | alto | alto |
| 6 | 32 MACs en vez de 16 | 66,0 ms | **+34 %** | alto | medio |
| 7 | Halo redundante en capas con stride | ~98 ms | +1-2 % | bajo | bajo |
| 8 | Segundo puerto AXI-HP | — | ≤ +20 % | medio | medio |
| 9 | Tiles más altos (`max_y` de 3 → 4 bits) | — | +1-3 % | medio | medio |

**Combinaciones:** 1+2+3 juntas dan **61,8 ms (+38 %)** sin tocar la
arquitectura de memoria. Agregando la 6: **40,8 ms (+59 %) ≈ 24 fps**.

**Estado del timing al 2026-09-08:** `WNS = +0,268 ns` a 70 MHz — 1,9 % de
margen, el más ajustado del proyecto. Cualquier cambio nuevo en la zona de
`addr_generator`/IFBuffer necesita re-verificar timing antes de darse por
cerrado.

---

## 1. Subir el reloj — el mejor negocio de la lista

> **Revisado 2026-09-08.** La primera versión de esta entrada apuntaba a
> `ddr_addr_gen`. Estaba mal: ése era el camino crítico en la corrida del
> 2026-09-02, pero la Opción 1b lo mejoró (Vivado movió dos multiplicaciones a
> DSP48) y el crítico volvió a ser el histórico desde agosto.

**El camino crítico real** (medido 2026-09-08, bitstream generado):

```
axi_slave/r04_mode_reg[1]  →  addr_generator (addr_in)  →  IFBuffer (RAMB36 ADDR)
```

`WNS = +0,268 ns` a 70 MHz, 14 niveles lógicos, y **62,6 % del retardo es
ruteo** (8,248 ns de ruteo contra 4,933 ns de lógica). Eso dice que el
problema es congestión y *fanout*, no profundidad combinacional. Fmax
implícito ≈ 71,3 MHz; margen sobre el objetivo, 1,9 % — el más ajustado
registrado en el proyecto.

Hay tres ataques, de más a menos barato:

### 1a. Eliminar el latch de `ky_kx_reset_val` (una línea)

El reporte de timing muestra **`LDCE=1`** entre los 14 niveles del camino
crítico, y la tabla de utilización muestra **`Register as Latch: 1`** — o sea
que el único latch de todo el diseño está justo ahí. Viene de
`addr_generator.vhd`:

```vhdl
ky_kx_reset_val <= "01" when reg_mode = "10" else "00";
...
process( clk, reset )
begin
    if( reset = '1' ) then
        sig_ky <= ky_kx_reset_val;   -- carga ASÍNCRONA de un valor no constante
        sig_kx <= ky_kx_reset_val;
```

Un `FDCE`/`FDPE` sólo puede resetear a una constante. Al pedirle un reset
asíncrono con un valor que depende de `reg_mode`, Vivado infiere un latch para
sostener ese valor — y ese latch queda en el camino desde `REG_MODE` hasta la
dirección del IFBuffer.

**Candidato de arreglo:** resetear asíncronamente a `"00"` (constante) y dejar
que el valor dependiente del modo se cargue en la rama **síncrona**. Debería
ser inofensivo: la FSM arranca en `IDLE`, donde `counter_reset='1'`, así que
`sig_ky`/`sig_kx` se recargan con `ky_kx_reset_val` en el primer flanco después
del reset de todos modos.

**Sin verificar** — hay que simular (`tb_cnn_top_stride` + `tb_cnn_top_hardcore`,
que cubren los tres modos incluido PW1×1, el único donde `ky_kx_reset_val` no
es cero) y re-correr timing.

### 1b. Quitar `inputf_buf_b`

`ag_addr_in` (13 bits) alimenta **los dos bancos** del IFBuffer, o sea unos 64
RAMB36 de carga. **4 de los 6 peores caminos terminan en `buf_b`**, el banco
que hoy nunca se escribe. Eliminarlo llevaría el WNS a ~+0,335 ns (el peor
camino que quedaría, sobre `buf_a`), más lo que aporte descomprimir el ruteo al
bajar la BRAM del 75 % al ~52 %. Cuesta renunciar a la opción 4 de esta lista.
Ver [`../../dma/docs/pipelining_tradeoffs.md`](../../dma/docs/pipelining_tradeoffs.md).

### 1c. Registrar los valores constantes por capa en `addr_generator`

`tile_w`, `tile_w_pad`, `num_co` y `cin_groups` se recalculan
combinacionalmente **en cada ciclo**, pero dependen sólo de registros de
configuración (`max_x`, `max_co`, `cin`, `stride_en`) que no cambian durante
una capa. Registrarlos saca de la ruta combinacional el `+15 >> 4` de
`cin_groups` y el `shift_left`/`+2` de `tile_w_pad`.

Riesgo bajo (los valores quedan listos mucho antes de `reg_start`), pero hay
que cuidar que se actualicen antes del primer píxel.

### Lo que NO conviene: pipelinear `addr_in`

Agregar una etapa de registro sobre `addr_in` rompería el supuesto de latencia
fija de 2 ciclos entre pedir una dirección y que el dato llegue a `act_reg` —
el mismo supuesto que sostiene el estado `DRAIN` y que ya causó un bug sutil
con `Cin=24` (ver `cin_grouping_gap.md`, Parte 7). Es la opción más cara y
más riesgosa de las cuatro.

### Ganancia

A 100 MHz, 99,4 → 69,6 ms (**+30 %**). Siendo conservadores y quedándose en
90 MHz, +22 %. El punto de 75 MHz del 2026-08-04 ya cerró con `+0,232 ns`
(antes de los fixes de septiembre), así que **75 MHz parece alcanzable casi
sin trabajo** — sería +7 % por sólo re-constrañir y re-implementar.

## 2. Bajar el sobrecosto fijo de 3,75 ciclos por píxel

**Qué:** por cada (píxel, `co_group`), la FSM gasta 3,75 ciclos fuera del
cómputo útil: `DRAIN`, `LATCH`, `POST` y el ciclo perdido por la latencia de
BRAM al arrancar `ACCUM`. Es **constante**, no escala con `max_inner`, así que
duele exactamente donde el trabajo por píxel es chico:

| Modo | `max_inner` | Sobrecosto |
|---|---|---|
| DW3×3 | 9 | **29,4 %** del tiempo de la capa |
| PW1×1 (`Cin=16`) | 16 | 19,0 % |
| Conv3×3 (`Cin=3`, conv1) | 27 | 12,2 % |
| PW1×1 (`Cin=64`) | 64 | 5,5 % |

**Cómo:** solapar el post-procesado del píxel *N* con el cómputo del píxel
*N+1*. Parte del camino ya está hecho — `POST` mantiene `addr_en` en alto y el
Address Generator ya avanza durante ese estado. Lo que falta es que el
`mac_clear` de `LATCH` no obligue a frenar: haría falta un segundo banco de
acumuladores (o un acumulador doble) para que quant/ReLU/pool trabajen sobre
el píxel anterior mientras los MAC ya arrancaron el siguiente.

**Ganancia:** llevando 3,75 → ~1 ciclo, 99,4 → 91,3 ms (**+8 %**).

**Riesgo:** toca `fsm_cnn_acc`, que es el corazón del datapath y tiene encima
toda la verificación acumulada (`tb_cnn_top_stride`, `tb_cnn_top_hardcore`).

## 3. `axi4_write_master` a 2 ciclos por palabra

**Qué:** el lazo del master de escritura es `RD_LOCAL → W_LOW → W_HIGH`, o sea
3 ciclos por palabra de 128 bits, contra los 2 del master de lectura. El ciclo
de `RD_LOCAL` se gasta esperando el dato del OFBuffer sin hacer nada más.

**Cómo:** pedir el dato de la palabra *N+1* durante el `W_LOW`/`W_HIGH` de la
palabra *N* — el OFBuffer tiene puerto de lectura libre y una latencia de 1
ciclo, así que alcanza con adelantar `local_rd_en` y registrar el resultado.

**Ganancia:** 99,4 → 96,4 ms (**+3 %**). Modesta, pero es **la más barata de
todas**: no toca ningún buffer, ningún BRAM, ni la FSM del DMA. Sólo la FSM
interna del master de escritura, que tiene su propio testbench aislado
(`tb_axi4_write_master`, `tb_axi4_4kb`).

## 4. Prefetch de IFM — ping-pong real del IFBuffer

**Qué:** cargar el tile *N+1* mientras el acelerador computa el tile *N*.
El almacenamiento ya está instanciado (`inputf_buf_b`) pero **nunca se
escribe**: `buf_sel` no es un toggle por tile.

**Cómo:** (a) convertir `buf_sel` en un registro que alterne por tile, y
(b) desacoplar el orquestador del DMA, hoy estrictamente secuencial, para que
la carga del siguiente tile arranque durante el cómputo del actual.

**Ganancia:** 99,4 → 88,7 ms (**+11 %**), cota superior con traslape perfecto.

**Riesgo alto:** (b) es el grueso y toca la FSM más delicada del sistema. Ver
[`../../dma/docs/pipelining_tradeoffs.md`](../../dma/docs/pipelining_tradeoffs.md)
para el análisis completo y la decisión de 2026-09-08 de no hacerlo por ahora.

## 5. Ping-pong del OFBuffer

**Qué:** lo mismo pero del lado del drenado. Hoy el acelerador no puede
escribir resultados del tile siguiente hasta que el DMA vacíe el OFBuffer.

**Costo:** **+16 bloques BRAM** sobre los 105/140 (75 %) actuales → ~86 %.
Entra, pero justo. Si se elimina `inputf_buf_b` (~32 bloques) sobra espacio de
sobra — o sea que las opciones 4 y 5 compiten por la misma memoria, y hacer
sólo la 5 (liberando la 4) es una combinación coherente.

**Ganancia:** sumada a la 4, 99,4 → 79,3 ms (**+20 %**). Sola, sin la 4,
alrededor de +9 %.

## 6. Duplicar el array de MAC (16 → 32)

**Qué:** hoy `NUM_MACS = 16` (`cnn_pkg.vhd`). Los 16 MAC procesan 16 canales de
salida en paralelo (Conv3×3/PW1×1) o 16 canales de entrada (DW3×3). Con 32,
`co_groups` se parte a la mitad en todas las capas.

**Costo:** DSP de 20 a 36 de 220 — margen enorme, hoy sólo 9 % usado. El costo
real es **ancho de bus**: `weight_buf` y el IFBuffer tendrían que pasar de
palabras de 128 a 256 bits, lo que duplica su BRAM. Aquí es donde los ~32
bloques de `inputf_buf_b` encuentran un destino útil. Además hay que tocar
`input_mux`, `byte_sel` y el empaquetado de los pesos exportados.

**Ganancia:** 99,4 → 66,0 ms (**+34 %**). Es la ganancia bruta más grande de la
lista después del reloj, y ataca directamente el 79,8 % que es cómputo.

**Ojo:** con 32 MAC, `Cout=24` deja 8 carriles ociosos en vez de 8 de 16 — el
desperdicio por canales no múltiplos del ancho del array **empeora**.

## 7. Halo redundante en capas con stride

**Qué:** ya documentado en la cabecera de `tb_cnn_top_stride.vhd`. Con
`stride_en='1'` el DMA sigue trayendo el halo **simétrico** de siempre
(`tile_h + 2` filas, una arriba y una abajo), pero la fórmula
`row = 2·y_counter + sig_ky` sólo necesita halo arriba: **la última fila y la
última columna traídas nunca se leen**.

**Ganancia:** 1-2 % del total (es 1 fila de cada ~16 en las capas con stride).
Chica, pero el arreglo es local a `ddr_addr_gen.vhd`.

## 8. Segundo puerto AXI-HP

**Qué:** hoy los dos masters comparten el camino a DDR. El Zynq-7020 tiene
**cuatro** puertos HP y sólo se usa uno. Poner lectura y escritura en puertos
distintos duplica el ancho de banda disponible.

**Ganancia:** sólo sirve **combinada con las opciones 4/5** — sin traslape, las
transferencias no compiten entre sí porque nunca ocurren a la vez. Techo
conjunto ≈ el 20 % de la transferencia.

## 9. Tiles más altos

**Qué:** `max_y` es de 3 bits, así que un tile de salida no pasa de 8 filas.
`conv1` necesita **19 tiles**, y cada tile re-trae 2 filas de halo. Con tiles
más altos hay menos re-fetch de halo.

**Costo:** ensanchar `max_y` (y `DMA_TILE_H`, hoy de 4 bits, que ya limita el
alto de salida a 7 en capas con stride) y más profundidad de IFBuffer.

**Ganancia:** 1-3 %. El halo pesa ~14 % del IFM, y el IFM es 10,8 % del total.

---

## Recomendación de orden

Si en algún momento hay tiempo para optimizar, el orden razonable es
**1 → 3 → 2 → 6**, y dejar 4/5/8 para el final:

- Las opciones **1 y 3** son locales, de bajo riesgo, tienen testbenches
  aislados que las cubren, y juntas dan +33 % sin tocar la arquitectura.
- La **2** es el mejor ataque al cómputo sin cambiar la geometría del datapath.
- La **6** es la ganancia bruta más grande, pero cambia anchos de bus y obliga
  a re-exportar los pesos desde `CNN_training`.
- Las **4, 5 y 8** son las de peor relación esfuerzo/beneficio: reestructuran
  el orquestador del DMA para pelear por, como mucho, el 20 % del presupuesto.

## Lo que NO ayudaría

- **Más BRAM para tiles gigantes.** El cuello no es la memoria on-chip: el
  IFBuffer ya está dimensionado para el tile más grande que los registros
  permiten (`(128+2)·(8+2)·4 = 5.200` de 8.192 palabras).
- **Optimizar el árbol de acumulación de los MAC.** Los MAC ya hacen una
  multiplicación-acumulación por ciclo, que es el límite estructural. Lo que
  sobra no es tiempo de MAC, es tiempo *entre* MAC (opción 2).
- **Subir el reloj sin tocar el camino crítico.** A 78 MHz ya falló
  (WNS = −0,293 ns, medido en julio). El camino crítico es el techo real, no
  el reloj — hay que atacarlo primero (opción 1).
