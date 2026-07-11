# cnn_top — interconexión AXI-Lite / AXI-HP / IRQ con el PS

Decisión de arquitectura para el wrapper final `cnn_top`, que instancia `cnn_accelerator` + `dma_engine` y expone los puertos que se conectan al PS7 en el Block Design de Vivado.

## El problema: dos bancos de registros, mismos offsets

`axi_lite_slave.vhd` (acelerador) y `reg_bank.vhd` (DMA) son dos esclavos AXI-Lite independientes, cada uno con su propio mapa de direcciones empezando en `0x00`:

- Acelerador: `0x00`-`0x40` (ver tabla completa en `axi_protocol.md`)
- DMA: `0x00`-`0x48` (ver `dma/dma_registers.md`)

Si se combinan bajo un solo puerto AXI-Lite en `cnn_top`, estos rangos se pisan.

## Opciones consideradas

**A) Un solo puerto AXI-Lite en `cnn_top`, con un decodificador de direcciones interno** que reparta el rango entre los dos bloques (ej. acelerador en `0x000-0x040`, DMA corrido a `0x100-0x148`).

Descartada: no es un simple "mirar bits altos de la dirección". AXI-Lite separa el canal de dirección (AW) del canal de datos (W) y de la respuesta (B) — igual para lectura (AR/R). Para rutear correctamente W/B al esclavo que corresponde, el decodificador tiene que *recordar* qué esclavo fue seleccionado durante la fase AW hasta que termine la transacción completa (y lo mismo para AR/R). Es, en la práctica, un mini-crossbar AXI-Lite con su propio estado — exactamente el tipo de lógica de sincronización que ya nos dio un bug real (ver la carrera `DMA_START`/`DONE_LAYER` documentada en la sesión del 2026-07-10). No vale la pena escribirlo a mano.

**B) Dos puertos AXI-Lite slave independientes en `cnn_top`** — cada uno conectado 1:1 a su bloque interno, sin ningún decodificador nuevo.

## Decisión: Opción B

`cnn_top` expone **2 puertos AXI-Lite slave independientes**, cada uno pasado directo (wiring puro, sin lógica de dirección nueva) a la instancia correspondiente:

- Puerto AXI-Lite #1 → `axi_lite_slave.vhd` (acelerador), offsets `0x00`-`0x40` sin modificar
- Puerto AXI-Lite #2 → `reg_bank.vhd` (DMA), offsets `0x00`-`0x48` sin modificar

**Nota importante:** la alternativa a escribir un decodificador a mano nunca fue "ninguna" — es la IP **AXI Interconnect / SmartConnect** de Vivado, que resuelve el fan-out de 1 master a N esclavos con rangos de dirección distintos, configurable por GUI en el Address Editor del Block Design, sin una sola línea de VHDL. Es decir: la disyuntiva real nunca fue "2 puertos vs. decodificador propio" sino "2 puertos vs. lógica de crossbar que Vivado ya resuelve gratis". Con 2 puertos en `cnn_top`, ni siquiera hace falta el Interconnect: el Zynq-7020 trae **2 masters GP nativos** (`M_AXI_GP0`, `M_AXI_GP1`), así que la conexión en el Block Design es 1 a 1, directa, sin IP de interconexión de por medio.

## Mapa completo de puertos de `cnn_top` hacia el PS7

| Puerto en `cnn_top` | Conecta a (PS7) | Notas |
|---|---|---|
| AXI-Lite slave #1 (acelerador) | `M_AXI_GP0` | Control del acelerador, offsets `0x00`-`0x40` |
| AXI-Lite slave #2 (DMA) | `M_AXI_GP1` | Control del DMA, offsets `0x00`-`0x48` |
| AXI4 master (lectura: pesos + IFM) | `S_AXI_HP0` | Decidido en `dma/axi4_master_role.md` |
| AXI4 master (escritura: OFM/GAP) | `S_AXI_HP1` | Decidido en `dma/axi4_master_role.md` |
| `irq_out` | `IRQ_F2P` | Interrupción hacia el PS |

## Pendiente

Al implementar `cnn_top`, decidir si el software del PS necesita algún registro/mecanismo adicional de sincronización entre los dos bloques (ej. el PS arranca el acelerador via GP0 y el DMA via GP1 — el orden y el polling de `REG_DONE`/`DMA_DONE` los coordina el firmware, no el hardware).
