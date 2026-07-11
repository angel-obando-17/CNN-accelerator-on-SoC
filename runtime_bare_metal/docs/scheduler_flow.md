# Flujo del scheduler de Core0

## Decisión: el DMA orquesta la capa completa, no el PS tile por tile

`dma/rtl/dma_engine.vhd` expone un puerto `accel_start` ("To accelerator
reg_start") — el DMA dispara al acelerador directamente en hardware. Esto
significa que el scheduler de Core0, por capa, se reduce a:

1. Escribir la configuración de la capa en ambos bancos de registros
   (acelerador + DMA) — valores que vienen de la tabla generada por el
   script Python (ver `ddr_memory_layout.md`).
2. Disparar `DMA_START`.
3. Esperar `DMA_DONE`.
4. Repetir para la siguiente capa.

El PS **no** dispara `CNN_REG_START` por separado en el flujo normal — el
DMA se encarga, coordinando con el acelerador vía el protocolo TILE_WAIT
(`tile_ready`/`tile_req`) internamente en hardware, sin intervención del
software.

**Nota:** esto corrige el pseudocódigo original de `Bitacora.md` (con
`launch_accelerator()` como paso separado del PS) — ese pseudocódigo es
anterior al diseño del protocolo TILE_WAIT y quedó desactualizado en ese
punto.

## Confirmado contra `cnn_top.vhd` (2026-07-11, ya implementado)

Se leyó el RTL real de `cnn_top.vhd` para resolver lo que quedaba abierto:

- El `reg_start` que sale de `axi_lite_slave` (banco de registros del
  acelerador) está **`open`** — sin conectar a nada. Escribir
  `CNN_REG_START` por AXI-Lite no tiene ningún efecto en el sistema
  integrado.
- El `reg_start` real de `cnn_accelerator` está cableado únicamente a
  `dma_engine.accel_start` (señal interna `start_dma_to_cnn`).
- `cnn_top` expone un puerto propio `dma_done` a nivel top (además del
  registro `DMA_REG_DONE` en `reg_bank`), pensado para ir a `IRQ_F2P` del
  PS7 (ver `axi/cnn_top_interconnect.md`).

**Conclusión: `DMA_REG_DONE` (o el pin `dma_done` cuando se use IRQ) es la
única señal de completitud que el PS necesita mirar por capa.**
`CNN_REG_DONE` sigue existiendo como registro (se usa internamente para
generar el `irq_out` que consume el propio DMA durante TILE_WAIT), pero no
es algo que el firmware del PS deba leer — de hecho `CNN_REG_START` ya ni
sirve para nada desde software. `cnn_driver`/`cnn_regs.h` (cuando se
escriban) probablemente ni necesiten los campos `START`/`DONE` del banco
del acelerador para el flujo normal.

## Pendiente de confirmar

- Espera por IRQ real (`dma_done` -> `IRQ_F2P`, vía Vitis/GIC) vs. polling
  sobre `DMA_REG_DONE` — se decide cuando se aborde el subsistema de
  interrupciones.
