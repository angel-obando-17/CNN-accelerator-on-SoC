# AXI4 completo vs AXI4-Lite

## AXI4-Lite

En AXI-Lite, cada transaccion mueve exactamente 1 palabra (32 bits en nuestro caso). Un handshake AW+W = una escritura. Un handshake AR+R = una lectura. No hay forma de decirle "escribe 64 palabras seguidas", habria que repetir el handshake 64 veces, con todo el overhead que eso implica.

## AXI4 completo

AXI4 resuelve esto agregando el concepto de rafaga (burst): en una sola fase de direccion, se le dice al esclavo "voy a mandarte/pedirte N palabras seguidas", y luego los datos fluyen uno por ciclo (si el slave puede seguir el ritmo) sin repetir la direccion cada vez. Esto es exactamente lo que se necesita para mover un bloque de pesos o un tile completo de la DDR al buffer interno.

Para lograr esto, los canales AW (para escritura) y AR (para lectura) ganan señales nuevas que no existen en Lite:

| Señal | Bits | Qué significa |
|---|---|---|
| `AxLEN` | 8 | Número de beats (transferencias) en la ráfaga, **menos 1**. `AxLEN=0` -> 1 beat, `AxLEN=15` -> 16 beats. AXI4 permite hasta 256 beats. |
| `AxSIZE` | 3 | Tamaño de cada beat en bytes, como potencia de 2: `000`=1 byte, `010`=4 bytes, `011`=8 bytes... hasta el ancho del bus. |
| `AxBURST` | 2 | Tipo de ráfaga: `01`=INCR (dirección incrementa en cada beat — la que se va a usar, porque los datos son secuenciales en DDR), `00`=FIXED (misma dirección siempre, raro), `10`=WRAP (vuelve al inicio al llegar a un límite, se usa en cachés — no sirve aquí). |
| `AxID` | N | Identificador de la transacción. Permite que el slave responda transacciones fuera de orden si hay varias en vuelo. Para un DMA simple, normalmente se fija `AWID`/`ARID` en un valor constante (ej. `"0000"`) y listo — no se necesitan transacciones concurrentes al inicio. |

## Los canales de datos ahora cargan varios beats

En W (escritura) y R (lectura), cada palabra individual dentro de la ráfaga es un beat. Cada canal gana una señal de "este es el último beat":

- **WLAST** (canal W): el master lo pone en `1` en el último beat de la ráfaga de escritura.
- **RLAST** (canal R): el slave lo pone en `1` en el último beat de la ráfaga de lectura.

Esto le dice al otro lado que uedes cerrar la transacción, sin esto, ninguno de los dos sabría cuándo acaba una ráfaga de longitud variable.

También aparece **WSTRB** (ya existe en Lite en realidad, pero cobra más importancia aquí): byte-enable de 4 bits (para bus de 32 bits) que indica qué bytes del beat son válidos. Útil si en algún momento se escribe menos de una palabra completa.

## Límite de 4 KB

AXI4 prohíbe que una ráfaga cruce un límite de dirección de 4 KB (0x1000). Esto es una regla de la especificación, no una sugerencia: los interconnects de Xilinx la dan por hecha y no la verifican en hardware — si se rompe, se obtiene corrupción de datos silenciosa. La FSM de DMA tendrá que trocear las transferencias grandes en ráfagas que no crucen ese límite. Con `AxLEN` máximo de 256 beats y beats de hasta 16 bytes (128 bits, el ancho del buffer), el peor caso es 256×16 = 4096 bytes = exactamente 4 KB, así que si los buffers están alineados a 4 KB, una ráfaga completa de 256 beats de 128 bits cabe justo sin cruzar el límite.

## El ancho de bus no calza

Los buffers internos (IFBuffer, Weight Buffer, OFBuffer) son de 128 bits. El puerto AXI-HP del Zynq-7020, sin embargo, es de 32 o 64 bits. Esto significa que el DMA master que hable con la DDR no puede simplemente calzar 1 beat = 1 palabra del buffer interno — va a ser necesario un conversor de ancho (128 <-> 64) en algún punto. Esto es una decisión de arquitectura que se documentará al diseñar el AXI4 Master.
