# Layout de memoria DDR — política de asignación

## Decisión (2026-07-11): direcciones estáticas, sin reuso, v1

Cada tensor de salida de cada capa del MobileNetV2 recibe una dirección
DDR fija y única, calculada una sola vez por el script generador en Python (ver
`toolchain_and_repo_structure.md` / `scripts/`). Ninguna dirección se
reutiliza entre capas.

### Por qué

- El modelo completo (pesos + todas las activaciones intermedias) cabe
  cómodo en los 512 MB de DDR.
- Evita cualquier análisis de tiempo de vida de buffers.
- Resuelve el caso de residual/skip-connection sin copias: una capa con
  residual simplemente apunta `addr_res` a la dirección donde ya vive la
  salida de la capa que lo produjo (que puede estar varias capas atrás,
  no necesariamente N-1).

### Por qué NO ping-pong / prefetch de activaciones entre capas (por ahora)

El pipeline de capas es estrictamente secuencial en el scheduler de Core0:
`DMA_START` procesa una capa completa (pesos + todos los tiles vía
TILE_WAIT + escritura de resultado) antes de que Core0 dispare el
`DMA_START` de la siguiente capa (ver `scheduler_flow.md`). No hay overlap
de software entre capas, así que no hay beneficio de tener buffers dobles
en DDR por ahora.

Esto es distinto del ping-pong de IFBuffer/OFBuffer *dentro* de una capa,
a nivel de BRAM del acelerador — ese ya está resuelto en el RTL
(`dma/tile_wait_protocol.md`, `dma/pipelining_tradeoffs.md`): la versión
secuencial actual no necesita ping-pong ahí tampoco, y quedó como
optimización futura condicionada al overhead medido en DW3×3 (~37%). No
es responsabilidad del runtime, es interno al acelerador+DMA.

## Abierto para el futuro (no ahora)

Si más adelante se justifica optimizar memoria DDR, se puede migrar a una
política de reuso con análisis de tiempo de vida de cada tensor. Empezar
simple (v1) y solo complicar si el trabajo de grado tiene tiempo y hace
falta.
