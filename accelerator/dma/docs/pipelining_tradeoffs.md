# Pipelining lectura/escritura del DMA — análisis de costo/beneficio

## El gap concreto: el OFBuffer no tiene ping-pong

El IFBuffer sí es ping-pong (`inputf_buf_a`, `inputf_buf_b`), pero el OFBuffer es un único buffer (`outputf_buf`). Esto significa que, tal como está la arquitectura hoy, el acelerador no puede empezar a escribir resultados del siguiente tile hasta que el DMA haya drenado completamente el OFBuffer del tile actual — si lo hiciera, pisaría datos que el DMA todavía no ha leído.

Esto da una asimetría importante entre los dos lados del DMA:

- **Lado de lectura (prefetch)**: el hardware para traslapar ya existe, el ping-pong del IFBuffer fue pensado exactamente para esto.
- **Lado de escritura (drenado)**: para traslapar, se necesitaría agregar ping-pong al OFBuffer también, lo cual implica el uso de más BRAM y más lógica de sincronización.

## Medición real ( 2026-07-01 ) — testbenches existentes, clock 10 ns

Datos de simulación (tile 2×2, Cin=Cout=16, 1 co_group), tiempo entre `reg_start='1'` y `reg_done='1'`:

| Modo | Δt | Ciclos | max_inner | Overhead (ciclos/4px − max_inner) |
|---|---|---|---|---|
| PW1×1 | 790 ns | 79 | 16 | 3.75 |
| DW3×3 | 510 ns | 51 | 9 | 3.75 |
| Conv3×3 | 5,910 ns | 591 | 144 | 3.75 |

El overhead fijo (LATCH + POST + ciclo desperdiciado de latencia BRAM en ACCUM) es **exactamente 3.75 ciclos por (pixel, co_group)** en los tres modos, consistente con que ese costo viene de estados de la FSM que no dependen de `max_inner`. Esto valida el modelo:

`ciclos_totales ≈ pixeles × co_groups × (max_inner + 3.75)`

## Extrapolación a escala real (tile 128×8 = 1024 píxeles, Cin=Cout=64, 4 co_groups)

Usando el modelo validado arriba (no medido directamente a esta escala, pero la extrapolación es lineal y bien fundamentada porque `max_inner` y el loop de píxeles son estructuralmente iguales, solo cambia el tamaño):

| Modo | Ciclos/tile | Tiempo (10 ns) |
|---|---|---|
| PW1×1 | 1024×4×(64+3.75) = **277,504** | 2.78 ms |
| DW3×3 | 1024×4×(9+3.75) = **52,224** | 0.52 ms |

Comparando contra el estimado de transferencia DMA (~19,500 ciclos para cargar+descargar un tile completo, bus HP 64 bits):

- **PW1×1**: overhead de NO traslapar ≈ 19,500 / 277,504 ≈ **7.0%**
- **DW3×3**: overhead de NO traslapar ≈ 19,500 / 52,224 ≈ **37.3%**

La diferencia es grande: en capas PW1×1 el cómputo domina tanto que no traslapar casi no cuesta nada. En capas DW3×3 la transferencia de datos es casi tan pesada como el cómputo, así que el traslape sí importaría bastante ahí. MobileNetV2 tiene muchos bloques DW3×3 (uno por cada bottleneck invertido), así que el impacto agregado no sería despreciable.

**Nota**: el estimado de transferencia (~19,500 ciclos) sigue siendo a mano (tamaño de tile × ancho de bus HP, sin medir en simulación real del DMA). Los ciclos de cómputo, en cambio, ya están validados con datos reales extrapolados de un modelo confirmado empíricamente en los tres modos.

## Secuencia de trabajo

1. Implementar el DMA en su versión secuencial simple, aprovechando el ping-pong del IFBuffer que ya existe.
2. Dejar el ping-pong del OFBuffer como optimización futura, condicionada a que el overhead medido en DW3×3 (~37%) justifique el costo de BRAM adicional (ya en 44.29% de uso) y la complejidad de sincronización extra. Si el trabajo de grado tiene tiempo, se agrega después; si no, la versión secuencial ya es correcta y funcional.
3. Cuando el DMA esté implementado, medir en simulación el tiempo real de transferencia por tile para reemplazar el estimado de ~19,500 ciclos por un número medido.
