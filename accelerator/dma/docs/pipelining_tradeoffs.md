# Pipelining lectura/escritura del DMA — análisis de costo/beneficio

> **Revisado 2026-09-08.** La versión anterior de este documento afirmaba que
> «el ping-pong del IFBuffer ya existe» y que «el hardware para traslapar ya
> está». Eso es sólo medio cierto y la mitad falsa es la que importa — ver la
> sección *Qué hay realmente implementado*. En esa revisión también se
> reemplazó el estimado a mano de ~19.500 ciclos/tile por una medición real,
> que era el pendiente que dejaba abierto este mismo documento.

## Qué hay realmente implementado (2026-09-08)

Ni el IFBuffer ni el OFBuffer traslapan hoy. La diferencia entre los dos es
**cuánto falta** para que lo hagan, y no es la que se creía:

| Buffer | Almacenamiento | Mux de lectura | Control | ¿Traslapa? |
|---|---|---|---|---|
| IFBuffer | `inputf_buf_a` + `inputf_buf_b`, los dos instanciados | sí, en `inputf_buf.vhd` | **no** | no |
| OFBuffer | un solo banco (`outputf_buf`) | — | — | no |

El detalle que la versión anterior pasaba por alto: **`inputf_buf_b` nunca se
escribe.** `buf_sel` no es un toggle por tile, es una señal derivada del estado
de `dma_fsm`: vale `'1'` en los estados de carga de IFM (`IFM_MAIN`,
`IFM_READ`, `IFM_LEFT`, `IFM_RIGHT`, `ZERO_FILL`, `IFM_NEXT`) y `'0'` en todos
los demás. Como `inputf_buf.vhd` escribe el banco A cuando `buf_sel='1'` y lo
lee cuando `buf_sel='0'`, las escrituras caen **siempre** sobre A y el banco B
queda sin escribir nunca. Se verificó en simulación: `inputf_buf_b` no recibe
ni una escritura en toda una corrida completa.

Esto **no es un bug** — el diseño secuencial es correcto sin ping-pong, tal
como razona [`tile_wait_protocol.md`](tile_wait_protocol.md): el acelerador
queda congelado en `TILE_WAIT` mientras el DMA drena y carga, así que no hay
condición de carrera posible. Es hardware provisionado para una optimización
futura, con el control todavía sin escribir.

Pero sí cambia el presupuesto de esa optimización. Prefetchear no es
«activar el ping-pong que ya está»: hace falta

1. convertir `buf_sel` en un registro que alterne por tile (hoy es
   combinacional a partir del estado), y
2. **desacoplar el orquestador**, que hoy es estrictamente secuencial
   (`WAIT_ACCEL → CHECK_OFM → OFM_WRITE → NEXT_TILE → IFM_MAIN`), para que
   arranque la carga del tile *N+1* mientras el acelerador todavía computa el
   tile *N*.

El punto (2) es el grueso del trabajo y toca la FSM más delicada del sistema.

## Costo de transferencia — MEDIDO (2026-09-08)

Reemplaza el estimado a mano de ~19.500 ciclos/tile que este documento dejaba
pendiente. Medido con `tb_meas.vhd` sobre `axi4_read_master` contra un esclavo
ideal (sin *wait states*), o sea: lo que se mide es el costo propio del
master, no el de la DDR real.

| Palabras | Ráfagas | Ciclos | Ciclos/palabra |
|---|---|---|---|
| 16 | 1 | 35 | 2,19 |
| 64 | 1 | 131 | 2,05 |
| 128 | 2 | 262 | 2,05 |
| 256 | 4 | 524 | 2,05 |
| 520 | 9 | 1.067 | 2,05 |

Ajuste **exacto** en los cinco puntos:

```
ciclos = 3 · ráfagas + 2 · palabras
```

Es decir **1 beat por ciclo**, con sólo 3 ciclos de sobrecosto por ráfaga —
prácticamente óptimo para un bus de 64 bits.

El `axi4_write_master` es más lento **por construcción**: su lazo interno es
`RD_LOCAL → W_LOW → W_HIGH`, o sea **3 ciclos por palabra de 128 bits**
(1,5 ciclos/beat) contra los 2 del lado de lectura. El ciclo de `RD_LOCAL` se
gasta esperando el dato del OFBuffer y no se solapa con nada.

Para el tile más grande (128×8 de salida, `Cin=Cout=64`) el modelo medido da
**~23.400 ciclos**, contra los ~19.500 estimados a mano. El estimado viejo era
razonable; se quedaba corto sobre todo por el costo del lado de escritura.

## Presupuesto de una inferencia completa

Cómputo con el modelo validado empíricamente en la sección siguiente,
transferencia con el modelo medido de arriba, y el *tiling* respetando los
límites duros de los registros (ancho de tile ≤ 128, alto ≤ 8, ≤ 2 tiles en X,
alto de salida ≤ 7 en capas con stride):

| Parte | Ciclos | % |
|---|---|---|
| Cómputo | 5.554.432 | **79,8 %** |
| Transferencia IFM | 751.272 | **10,8 %** |
| Transferencia OFM | 654.495 | **9,4 %** |
| **Total** | **6.960.199** | **99,4 ms @ 70 MHz ≈ 10,1 fps** |

## Modelo de cómputo — medición original (2026-07-01), sigue vigente

Datos de simulación (tile 2×2, `Cin=Cout=16`, 1 `co_group`), tiempo entre
`reg_start='1'` y `reg_done='1'`:

| Modo | Δt | Ciclos | `max_inner` | Sobrecosto (ciclos/4px − `max_inner`) |
|---|---|---|---|---|
| PW1×1 | 790 ns | 79 | 16 | 3,75 |
| DW3×3 | 510 ns | 51 | 9 | 3,75 |
| Conv3×3 | 5.910 ns | 591 | 144 | 3,75 |

El sobrecosto fijo (LATCH + POST + el ciclo desperdiciado por la latencia de
BRAM en ACCUM) es **exactamente 3,75 ciclos por (píxel, `co_group`)** en los
tres modos, consistente con que viene de estados de la FSM que no dependen de
`max_inner`. Esto valida el modelo:

```
ciclos_totales ≈ píxeles · co_groups · (max_inner + 3,75)
```

## Qué se gana traslapando — corregido con los números medidos

| Optimización | Tiempo | Ganancia | Qué hace falta |
|---|---|---|---|
| Nada (hoy) | 99,4 ms | — | — |
| Prefetch de IFM | 88,7 ms | **10,8 %** | toggle de `buf_sel` + desacoplar el orquestador |
| Prefetch IFM + drenado de OFM | 79,3 ms | **20,2 %** | lo anterior **+16 bloques BRAM** para el ping-pong del OFBuffer |

Los dos números son **cotas superiores**: asumen traslape perfecto, con la
transferencia escondida por completo bajo el cómputo.

### Corrección importante sobre el análisis por capa

La versión anterior de este documento concluía que el traslape «sí importaría
bastante» en las capas DW3×3 (37 % de sobrecosto) y que, como MobileNetV2
tiene muchos bloques DW3×3, «el impacto agregado no sería despreciable».

**La primera mitad es correcta; la conclusión agregada no.** Por capa, las
DW3×3 con stride son efectivamente las peores (`irb6_dw` tiene
IFM/cómputo = 1,11; `irb4_dw` 0,87; `irb2_dw` 0,85). Pero las DW3×3 son
baratísimas en cómputo — `max_inner=9` contra 64 de una PW1×1 grande — así que
pesan poco en el total. **En agregado el prefetch de IFM vale 10,8 %, no 37 %.**

## Conclusión y decisión (2026-09-08)

**Se deja el RTL como está.** El techo de lo que compra terminar el ping-pong
del IFBuffer es 10,8 %, y el costo es reestructurar el orquestador del DMA —
la FSM más delicada del sistema y la que más verificación acumulada tiene
encima. Mantener `inputf_buf_b` instanciado cuesta BRAM ociosa (~32 de 140
bloques, estimación analítica consistente con los 105 medidos) y 128 LUTs del
mux de lectura.

> **Corrección (2026-09-08, tras generar el bitstream):** al tomar esta
> decisión se dijo que el banco B «no está en el camino crítico». **Eso
> resultó falso.** El crítico del diseño es
> `axi_slave (REG_MODE) → addr_generator (addr_in) → IFBuffer (RAMB36 ADDR)`,
> y **4 de los 6 peores caminos terminan en `buf_b`**. No es la causa —el
> origen y la lógica son idénticos para ambos bancos— pero duplica el fanout
> de `ag_addr_in` (13 bits hacia ~64 RAMB36) y aporta los peores destinos.
> Eliminarlo llevaría el WNS de +0,268 a ~+0,335 ns, más lo que aporte
> descomprimir el ruteo al bajar la BRAM del 75 % al ~52 %. Es una ganancia
> real pero modesta: **no invierte la decisión, pero sí corrige el argumento
> con que se tomó.** Ver `../../constraints/timing_analysis.md`.

Borrarlo no compra nada hoy: liberaría BRAM que ningún bloque está pidiendo.
Y si alguna vez se retoma el prefetch, tenerlo instanciado ahorra volver a
sintetizar y recerrar timing con un bloque de memoria nuevo.

**Hay alternativas con mejor relación esfuerzo/beneficio que ésta** — el
traslape no es ni la más barata ni la más rentable. Ver
[`inference_speed_roadmap.md`](../../cnn_accelerator/docs/inference_speed_roadmap.md)
para el catálogo completo y cuantificado.
