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

## Pendiente

Falta implementar y medir: generador de direcciones DDR, FSM orquestadora. El estimado LUT para esas dos piezas (~1,300-2,500 LUTs combinados) sigue sin medir — se actualizara cuando esten implementadas. El numero de BRAM (69.29% acelerador + 0% AXI4 Master = 69.29% acumulado) ya es solido; lo que falta por sumar depende de si la FSM orquestadora necesita algun registro/tabla adicional (no deberia, es logica de control).
