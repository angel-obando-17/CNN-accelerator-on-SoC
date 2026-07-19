# Estimado de recursos FPGA del DMA Engine

**Importante: esto es un estimado de ingenieria, no un numero medido.** El numero real solo lo da el reporte de sintesis de Vivado una vez el DMA este implementado. Este documento existe para tener un argumento razonado mientras tanto (ej. para justificar la eleccion del Zynq-7020 ante la asesora), y para comparar contra el numero real cuando exista.

## Punto de partida — acelerador solo, sin padding de IFBuffer (medido, sintetizado 2026-06-06)

14.81% LUT, 2.88% FF, 44.29% BRAM, 7.27% DSP, en XC7Z020 (53,200 LUTs, 106,400 FF aprox, 140 bloques RAMB36 ≈ 4.9 Mb, 220 DSPs).

## Acelerador con IFBuffer con padding de halo (medido, sintetizado 2026-07-01)

Tras el rediseño de `dma/ifbuffer_padding_redesign.md` (ADDR_WIDTH del IFBuffer de 12→13 bits):

| Recurso | Uso | Cambio vs. sin padding |
|---|---|---|
| Slice LUTs | 15.02% (7,993 / 53,200) | +0.21 pp — casi no se movio, el padding es aritmetica/anchos, no logica nueva |
| Slice Registers (FF) | 2.89% (3,070 / 106,400) | +0.01 pp — igual de estable |
| Block RAM Tile | **69.29% (97 / 140)** | **+25 pp** — el salto real fue mayor al estimado (~60-65%) |
| DSP | 7.27% (16 / 220) | sin cambio — el padding no toca los MACs |

El salto de BRAM (35 bloques adicionales, todos atribuibles a duplicar la profundidad del IFBuffer ping-pong) confirma que el IFBuffer es, por mucho, el mayor consumidor de BRAM del acelerador — mas grande de lo que se habia proyectado. Quedan 43 bloques de margen (30.71%) antes de llegar al limite del chip.

## Estimado del DMA completo

| Bloque | LUTs (estimado) | Comentario |
|---|---|---|
| `reg_bank` (ya construido) | ~200-400 | Comparable a `axi_lite_slave.vhd`, muy chico |
| AXI4 Master ×2 (lectura+escritura) | ~1,500-3,000 | FSM de bursts + contadores + conversor de ancho 128↔64 bits |
| FSM orquestadora + padding | ~800-1,500 | Similar orden de magnitud a `fsm_cnn_acc` + `fsm_addr_generator` juntos |
| Generador de direcciones DDR | ~500-1,000 | Aritmetica similar a `addr_generator` |
| **Total DMA** | **~3,000-6,000 LUTs** | ≈ 5.6%-11.3% del chip, adicional |

Sumado a lo ya sintetizado, el estimado total queda entre **20%-26% de LUTs** — margen amplio sobre el total del chip.

FF y DSP se mueven mucho menos: el DMA es casi todo logica de control (FSMs, contadores), no computo pesado. Estimado: bajo 5% de FF adicional, DSPs adicionales minimos o nulos (la aritmetica de direcciones es sencilla, probablemente no necesita DSP48 dedicado).

## El recurso a vigilar: BRAM (medido 2026-07-01 — mas ajustado de lo estimado)

Con el IFBuffer ya con padding, el acelerador solo consume **69.29% de BRAM**, dejando **43 bloques de margen (30.71%)** para todo lo que falta del DMA (AXI4 Master ×2, cualquier FIFO interna).

**Recomendacion (ahora con mas peso que antes)**: usar FIFOs poco profundas (32-64 entradas) en el AXI4 Master, implementadas en **distributed RAM** (LUTRAM) en vez de BRAM dedicada — cuestan LUTs (con muchisimo margen, 15.02% usado) en vez de BRAM (con margen mucho mas ajustado). El resto del DMA (banco de registros, FSM orquestadora, generador de direcciones DDR) es logica de control — no deberia tocar BRAM en absoluto si se diseña con cuidado.

## AXI4 Master — MEDIDO (sintesis aislada, 2026-07-08)

| Modulo | LUTs | FF | BRAM |
|---|---|---|---|
| `axi4_read_master.vhd` | 66 (0.12%) | 137 (0.13%) | 0 |
| `axi4_write_master.vhd` | 146 (0.27%) | 82 (0.08%) | 0 |
| **Total AXI4 Master** | **212 (0.40%)** | **219 (0.21%)** | **0** |

Muy por debajo del estimado inicial (~1,500-3,000 LUTs) — al ser FSMs de control puro con contadores en flip-flops (sin FIFOs, sin conversores de ancho complejos mas alla de ensamblar 2 beats de 64 bits), el costo real es casi nulo. **Confirma la decision de la Opcion A** (master simple, sin BRAM) y la recomendacion de cuidar BRAM en el resto del DMA — con estos dos modulos, CERO bloques BRAM adicionales sobre el 69.29% ya medido del acelerador.

Nota: sintesis en aislamiento (solo el modulo, sin el resto del sistema) — el numero final tras integrar todo el DMA con el acelerador podria variar levemente por optimizaciones cruzadas de Vivado, pero da una cota muy confiable dado lo simple del diseño.

## DMA Engine completo — MEDIDO (sintesis de dma_engine.vhd, 2026-07-08)

`dma_engine.vhd` instancia los 5 bloques del DMA juntos ( `reg_bank`, `ddr_addr_gen`, `dma_fsm`, `axi4_read_master`, `axi4_write_master` ):

| Recurso | Uso |
|---|---|
| Slice LUTs | 1,112 (2.09%) |
| Slice Registers (FF) | 492 (0.46%) |
| Block RAM Tile | **0 (0.00%)** |
| DSP | 4 (1.82%) |

**Cero BRAM confirmado en todo el DMA** — se cumplio el objetivo de diseño de principio a fin (Opcion A del AXI4 Master, banco de registros y FSM orquestadora como logica de control pura). Los 4 DSP son nuevos frente a la sintesis aislada de los masters (que dieron 0) — probablemente Vivado eligio DSP48 para alguna multiplicacion de `ddr_addr_gen` en vez de LUTs, una eleccion de la herramienta, no un problema ( 220 DSPs disponibles, margen enorme ).

## Panorama del sistema completo ( acelerador + DMA, sin cnn_top todavia )

| Recurso | Acelerador ( con padding ) | DMA Engine | **Total** | Margen |
|---|---|---|---|---|
| LUT | 15.02% | 2.09% | **~17.11%** | Amplio |
| FF | 2.89% | 0.46% | **~3.35%** | Amplio |
| BRAM | 69.29% | 0.00% | **69.29%** | 30.71% |
| DSP | 7.27% | 1.82% | **~9.09%** | Amplio |

BRAM sigue siendo el unico recurso ajustado, pero el DMA no le sumo absolutamente nada — todo el margen que quedaba (30.71%) sigue disponible. Este es un argumento solido y con datos reales (no estimados) para justificar el Zynq-7020 ante la asesora.

## cnn_top — MEDIDO (sintesis completa, 2026-07-11)

`cnn_top.vhd` instancia `cnn_accelerator` + `axi_lite_slave` + `dma_engine`, pura interconexion sin computo ni memoria propia:

| Recurso | Estimado (acelerador+DMA, sin cnn_top) | Medido (cnn_top real) | Diferencia |
|---|---|---|---|
| LUT | ~17.11% | **17.46%** (9,288 / 53,200) | +0.35pp |
| FF | ~3.35% | **3.42%** (3,643 / 106,400) | +0.07pp |
| BRAM | 69.29% | **69.29%** (97 / 140) | 0 |
| DSP | ~9.09% (16+4) | **9.09%** (20 / 220) | 0 |

Confirmado: el wrapper no agrega practicamente nada, tal como se predijo. Los 20 DSP se dividen en 16 del MAC array (forzados por `mac_dsp.xdc`, ver nota abajo) + 4 de `ddr_addr_gen` (inferidos automaticamente por Vivado).

**Nota sobre `mac_dsp.xdc`**: la constraint que fuerza `USE_DSP48` en el MAC vivia solo en una carpeta local (`Downloads`, fuera del repo) y no estaba trackeada en git — al pasar `cnn_accelerator` a ser un nivel mas profundo dentro de `cnn_top`, la ruta jerarquica fija del constraint (`inst_mac_array/gen_macs[*].mac_inst/accumulator_reg[*]`, sin comodin al inicio) dejo de matchear y los 16 DSP del MAC desaparecieron silenciosamente (solo 4 DSP en el primer intento de sintesis de `cnn_top`, subieron LUTs a 20.22% al compensar en fabric). Fix: agregar `*` al inicio del patron (`*inst_mac_array/...`) para que sea independiente de cuantos niveles de jerarquia haya encima, y mover el archivo al repo.

## Pendiente

`cnn_top` completo y sintetizado. Siguiente: Block Design de Vivado (PS7 + AXI-Lite + AXI-HP + IRQ), conectando `cnn_top` al procesador.
