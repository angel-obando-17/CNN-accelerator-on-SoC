# Toolchain y organización del repo — runtime bare-metal

## Toolchain: Vitis classic (decidido 2026-07-11)

Se descartó escribir el bare-metal con `arm-none-eabi-gcc`. Con Vitis
se aprovecha el BSP `standalone` que genera Xilinx (driver de GIC, arranque,
manejo de MMU/caches) en vez de escribirlo todo desde cero.

## Relación repo <-> Vitis

El repo (`common/`, `core0/src/`, `core1/src/`) es la fuente.
Los Application Projects de Vitis referencian estos archivos — mismo
patrón que se usó con `dma/rtl/` en Vivado.

El Platform Project + los dos Application Projects (uno por core) que
genera Vitis viven en `runtime_bare_metal/vitis_ws/`, 
excluido por completo en `.gitignore`. A diferencia de
`architecture_pl/` (donde quedó código fuente real mezclado con lo que
genera Vivado), acá la intención es que absolutamente nada de lo que
Vitis genere quede trackeado.

## Estructura de carpetas y su propósito

| Carpeta | Propósito |
|---|---|
| `common/` | Headers compartidos entre Core0 y Core1 (mapas de registros AXI-Lite, layout de OCM, tipos). Compartir entre dos Application Projects separados requiere agregar un include path extra en cada uno — detalle a resolver dentro de Vitis, no bloquea el diseño. |
| `core0/include/` | Headers propios de Core0 (no compartidos con Core1). |
| `core0/src/` | Fuente del Application Project de Core0: scheduler (ver `scheduler_flow.md`), drivers de registros. |
| `core1/include/` | Headers propios de Core1 (no compartidos con Core0). |
| `core1/src/` | Fuente del Application Project de Core1: segmentación HSV. |
| `docs/` | Decisiones de diseño documentadas antes de implementar — mismo enfoque que `dma/*.md`. |
| `scripts/` | (a) `.tcl` que reconstruye el workspace de Vitis desde cero apuntando al repo (necesario porque `vitis_ws/` no se trackea); (b) generador Python que lee el modelo `.tflite` cuantizado y genera la tabla de configuración por capa (ver `ddr_memory_layout.md`). |

## Arranque dual-core (pendiente de detalle)

Por defecto ambos cores bootean, pero Core1 queda en espera (WFE) hasta
que Core0 lo despierta por software — mecanismo estándar de AMP bare-metal
de Xilinx. El detalle exacto (direcciones involucradas, API del BSP) no se
documenta todavía para no anotar datos sin verificar contra la versión real
de Vitis — se confirma cuando se abra el IDE por primera vez.
