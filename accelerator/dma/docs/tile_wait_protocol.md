# Protocolo TILE_WAIT — sincronización entre el acelerador y el DMA

## Problema Principal

En `fsm_addr_generator`, `LAYER_CHECK` calcula `sig_layer_done` comparando todos los contadores (co, x, y, tile_x, tile_y) contra su maximo en un solo chequeo plano. Eso significa que, tal como esta implementado hoy, un solo `reg_start` recorre TODOS los tiles de la capa (la cascada `co → x → y → tile_x → tile_y` esta completa dentro del mismo pulso de arranque), asumiendo que los datos de todos esos tiles ya estan disponibles en el IFBuffer.

El IFBuffer (64 KB) no alcanza para guardar una capa completa en las resoluciones grandes de MobileNetV2, entonces el DMA tiene que reemplazar el contenido del IFBuffer por el siguiente tile a mitad de una sola ejecucion del acelerador, no entre ejecuciones separadas. No existe hoy una señal que distinga "termine la grilla x,y,co de este tile" de "termine absolutamente todo" — hay que separar eso en dos niveles.

## Diseño propuesto

### 1. Nueva señal `tile_boundary` (en `fsm_addr_generator`, calculada junto a `sig_layer_done` en `LAYER_CHECK`)

Verdadera cuando `co_cnt=max_co`, `x_cnt=max_x`, `y_cnt=max_y` — sin importar `tile_x`/`tile_y`. Es un chequeo mas laxo que `layer_done`; de hecho `layer_done` implica `tile_boundary=1` tambien (terminar el ultimo tile tambien termina su grilla).

### 2. Nuevo estado en `fsm_addr_generator`: `TILE_HOLD`

Desde `LAYER_CHECK`, si `tile_boundary=1` y `sig_layer_done=0`, en vez de ir directo a `ACCUM` para el siguiente pixel, la AG entra a `TILE_HOLD` y se congela — igual que hace `IDLE` hoy con `addr_en`, pero esperando una señal nueva, `tile_ready` (viene del orquestador del DMA). Cuando `tile_ready=1`, avanza a `ACCUM` para el primer pixel del tile recien cargado (los contadores `x,y,co` ya estan en 0, `tile_x`/`tile_y` ya se incrementaron).

### 3. Nuevo estado en `fsm_cnn_acc`: `TILE_WAIT`

En `POST`, la condicion de transicion se abre en tres casos en vez de dos:

- `post_done=1`, `layer_done=1` → DONE/FLUSH (igual que hoy)
- `post_done=1`, `layer_done=0`, `tile_boundary=1` → **TILE_WAIT** (nuevo)
- `post_done=1`, `layer_done=0`, `tile_boundary=0` → COMPUTE (igual que hoy, siguiente pixel del mismo tile)

En `TILE_WAIT`, el FSM principal **mantiene `addr_en` en 1** (igual que en LATCH/POST) y levanta una señal de salida `tile_req` hacia el orquestador del DMA. Cuando `tile_ready=1` llega, transiciona a COMPUTE.

**Por qué `addr_en` se mantiene en 1 (no en 0 como se pensó originalmente):** la congelación de la AG en `TILE_HOLD` no depende de `addr_en` — ese estado solo revisa `tile_ready`, así que bajar `addr_en` no aporta nada a la sincronización. Peor aún: bajarlo apaga el `r_enable` del WeightBuffer/IFBuffer durante toda la espera, y al subirlo de nuevo justo cuando llega `tile_ready`, el primer canal (`ci=0`) del primer pixel del nuevo tile alcanza a leer el dato **viejo** que quedó congelado en la salida de la BRAM (1 ciclo de latencia de lectura sin haber tenido tiempo de refrescarse). Esto se detectó en simulación: `tile_wait.md` fue verificado con `tb_multilayer3.vhd` (PW1x1, tile 2x2, Cin=Cout=16, 2 tiles) y el primer resultado salió `0x1F` en vez de `0x20` — exactamente `1×1 + 15×2 = 31`, es decir, el canal `ci=0` acumuló con el activation viejo del tile anterior. Manteniendo `addr_en=1` durante todo `TILE_WAIT`, el puerto de lectura de las BRAM se mantiene "caliente" leyendo continuamente la dirección (ya fija) del siguiente tile, así que para cuando llega `tile_ready` el pipeline ya está al día. No hay riesgo de acumulación fantasma porque `mac_en` solo se activa en COMPUTE, independientemente de `addr_en`.

## Consecuencias del diseño

- Como el acelerador queda totalmente congelado durante `TILE_WAIT`, el DMA puede drenar el OFBuffer y cargar el siguiente IFM (y residual si aplica) sin ningun riesgo de condicion de carrera, incluso si esos buffers no fueran ping-pong. Para la version **secuencial** (la que se va a implementar primero), ni el OFBuffer ni el IFBuffer necesitan ping-pong para ser correctos.
- El ping-pong se vuelve necesario solo para la optimizacion futura de *prefetch*: empezar a cargar el siguiente tile durante COMPUTE del tile actual (antes de llegar a TILE_WAIT), para que cuando el acelerador llegue ahi, `tile_ready` ya este listo y el tiempo de espera sea cero o casi cero. Ver [[pipelining_tradeoffs]] para el analisis de cuando vale la pena.
- Los pesos NO necesitan recargarse en cada `TILE_WAIT` — son los mismos durante toda la capa, se cargan una sola vez al inicio (en `IDLE → COMPUTE`). Solo IFM y residual (si aplica) se recargan por tile.

## Señales nuevas necesarias

| Señal | Origen | Destino | Función |
|---|---|---|---|
| `tile_boundary` | `fsm_addr_generator` (LAYER_CHECK) | `fsm_cnn_acc` (POST) | Indica que la grilla x,y,co del tile actual terminó, pero quedan más tiles |
| `tile_req` | `fsm_cnn_acc` (TILE_WAIT) | Orquestador DMA | Pide al DMA que drene OFBuffer y cargue el siguiente tile |
| `tile_ready` | Orquestador DMA | `fsm_cnn_acc` (TILE_WAIT) y `fsm_addr_generator` (TILE_HOLD) | Confirma que el DMA terminó de drenar/cargar, libera ambas FSMs |

## Estado: VERIFICADO (2026-07-01)

Implementado en `fsm_addr_generator.vhd`, `addr_generator.vhd`, `fsm_cnn_acc.vhd` y `cnn_accelerator.vhd`. Probado con `tb/tb_multilayer3.vhd`: PW1x1 tile 2x2 con `max_tile_x='1'` (2 tiles), tile 0 con activaciones 0x01 (resultado 0x10) y tile 1 con activaciones 0x02 recargadas durante `TILE_WAIT` (resultado 0x20) — ambos tiles verificados correctos en las 4 posiciones del OFBuffer. El mismo testbench encadena una segunda capa PW1x1+GAP (1 solo tile, sin pasar por `TILE_WAIT`) para confirmar que el flujo normal de capas de un solo tile no se rompió con estos cambios.
