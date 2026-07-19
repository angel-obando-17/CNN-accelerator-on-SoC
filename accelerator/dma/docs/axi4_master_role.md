# El DMA como AXI4 Master

## Quién dirige quién en cada canal

En AXI-Lite, el bloque del acelerador era slave y por tanto recibía VALID y generaba READY. Como maestro, todo se invierte. Aquí está la tabla completa de quién conduce qué, desde la perspectiva del bloque DMA (el master):

| Canal | Señal | Dirección desde el DMA (master) | Notas |
|---|---|---|---|
| AW | `AWADDR`, `AWLEN`, `AWSIZE`, `AWBURST`, `AWID`, `AWVALID` | **Salida** (el DMA las genera) | El DMA decide cuándo pedir escribir |
| AW | `AWREADY` | **Entrada** | El puerto AXI-HP del PS dice si puede aceptar |
| W | `WDATA`, `WSTRB`, `WLAST`, `WVALID` | **Salida** | El DMA empuja los datos, uno por beat |
| W | `WREADY` | **Entrada** | El PS dice si puede recibir el beat actual |
| B | `BRESP`, `BID`, `BVALID` | **Entrada** | El PS confirma que la ráfaga de escritura se completó |
| B | `BREADY` | **Salida** | El DMA dice si puede procesar la respuesta |
| AR | `ARADDR`, `ARLEN`, `ARSIZE`, `ARBURST`, `ARID`, `ARVALID` | **Salida** | El DMA pide leer |
| AR | `ARREADY` | **Entrada** | El PS acepta la petición de lectura |
| R | `RDATA`, `RRESP`, `RID`, `RLAST`, `RVALID` | **Entrada** | El PS entrega los datos leídos, beat por beat |
| R | `RREADY` | **Salida** | El DMA dice si puede recibir el beat actual |

Es exactamente la tabla inversa de lo implementado en `axi_lite_slave.vhd` — mismo protocolo de handshake (VALID+READY simultáneos = transferencia), pero ahora la FSM del DMA es la que inicia en lugar de esperar.

## El puerto AXI-HP del Zynq — el "slave" del otro lado

En el Block Design de Vivado, el bloque PS7 expone puertos llamados `S_AXI_HP0`, `S_AXI_HP1`, `S_AXI_HP2`, `S_AXI_HP3` — cuatro en total. Se llaman **S** (slave) porque desde la perspectiva del PS7, él es el esclavo: la lógica en la PL (el DMA) es quien manda, el PS solo abre la puerta hacia el controlador de memoria DDR.

Cosas importantes de estos puertos:

- **Ancho configurable**: 32 o 64 bits. Para mover datos del proyecto (pesos, feature maps) conviene 64 bits — más ancho de banda por beat.
- **FIFOs internos configurables**: cada HP port tiene FIFOs de lectura y escritura independientes (profundidad configurable en el IP, ej. 32/64/128 entradas) que amortiguan las ráfagas antes de que compitan por el árbitro de memoria DDR compartido con el resto del sistema. Una FIFO más profunda tolera ráfagas más largas sin que el master tenga que esperar tanto.
- **Cada puerto tiene canales de lectura y escritura independientes** — full duplex. Esto abre una decisión de diseño: ¿usar un solo HP port para todo (pesos + IFM entran, OFM sale, todo por el mismo puerto), o repartir el tráfico en 2 puertos (ej. HP0 para lecturas de pesos+activaciones, HP1 para escritura de resultados) para tener más ancho de banda total en paralelo?

## Decisión: 2 puertos HP (uno de lectura, uno de escritura)

Se decidió usar 2 puertos HP separados — uno dedicado a lecturas (pesos + IFM) y otro dedicado a escrituras (OFM) — para maximizar el ancho de banda disponible.

### Qué tan complicado es esto en realidad

Es importante separar dos niveles distintos del diseño, porque la dificultad que agrega 2 puertos **no es uniforme** entre ellos:

**A nivel de señales AXI4 / lógica del master** En AXI4, los canales de lectura (AR+R) y de escritura (AW+W+B) ya son completamente independientes entre sí, incluso dentro de un solo puerto. Esto significa que el master necesita lógica separada para generar ráfagas de lectura y ráfagas de escritura de todas formas, sin importar si van al mismo puerto físico o a dos distintos. Usar 2 puertos en vez de 1 no duplica la complejidad de la FSM de bursts, simplemente conecta el lado de lectura del master a un puerto y el lado de escritura al otro.

**A nivel de la FSM orquestadora del DMA** Tener 2 puertos separados solo da beneficio de rendimiento si efectivamente se usan en paralelo: es decir, si mientras se escribe el resultado de una capa (o tile) ya se está leyendo por adelantado los pesos/IFM de la siguiente. Eso es *pipelining*, y requiere:

- Doble buffering (ping-pong) explícito entre lo que el acelerador está consumiendo/produciendo ahora mismo y lo que el DMA está cargando/descargando por adelantado.
- Señales de sincronización adicionales para evitar que el DMA sobreescriba un buffer que el acelerador todavía está usando.
- Más estados en la FSM orquestadora para coordinar ambos flujos sin condiciones de carrera.

Si se agregan 2 puertos pero el uso sigue siendo secuencial (leer, esperar, escribir, esperar, siguiente capa — sin traslape), se paga toda la complejidad de cableado sin ganar nada de rendimiento, porque nunca hay una lectura y una escritura ocurriendo al mismo tiempo.
