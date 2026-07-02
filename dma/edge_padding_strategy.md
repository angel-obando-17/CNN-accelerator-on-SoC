# Zero-padding en bordes reales de imagen — estrategia sin tocar addr_generator

## El problema

`addr_generator.vhd` calcula, para la ventana 3x3 (Conv3x3/DW3x3):

```vhdl
row := resize( unsigned( y_counter ), 4 ) + resize( sig_ky, 4 ) - 1;
col := resize( unsigned( x_counter ), 8 ) + resize( sig_kx, 8 ) - 1;
```

Cuando `y_counter=0` y `sig_ky=0` (fila de arriba del kernel, borde superior del tile), la resta sin signo hace que `row` de la vuelta a **15** (maximo representable en 4 bits). Cuando `x_counter=0` y `sig_kx=0`, `col` da la vuelta a **255** (maximo en 8 bits). Estos valores son **constantes fijas**, no dependen de `TILE_W`/`TILE_H`/`Cin` — son propiedad del ancho de esas señales internas, no de la configuracion de la capa.

Esto aterriza en una direccion de IFBuffer lejana (no adyacente al tile), que en las pruebas actuales "funciona" solo porque los testbenches precargan esa direccion con el mismo valor uniforme del resto del tile (dato de prueba todo-unos). Con un feature map real, esa direccion tendria basura de otra parte del buffer en vez de zero-padding real.

**Importante**: el wraparound aplica a **toda una franja**, no a un solo pixel. `row=15` ocurre para todas las columnas de esa fila (banda completa), y `col=255` ocurre para todas las filas de esa columna (banda completa) — no solo la esquina.

## Asimetria: borde superior/izquierdo vs inferior/derecho

- **Borde superior** (`row=-1`) y **borde izquierdo** (`col=-1`): dan la vuelta (wraparound) a 15 y 255 respectivamente. Direccion lejana, no adyacente.
- **Borde inferior** (`row=TILE_H`) y **borde derecho** (`col=TILE_W`): estos valores caben normales dentro de los bits disponibles (no hay overflow), asi que **no** dan la vuelta — es una direccion normal, justo despues del rango propio del tile.

## La solucion: el DMA rellena, no el addr_generator

No se modifica `addr_generator.vhd` (ya verificado). La FSM orquestadora del DMA, al cargar cada tile, revisa si ese tile toca un borde **real** de la imagen (no solo un borde de tile) comparando `tile_x`/`tile_y` contra `DMA_NUM_TILE_X`/`DMA_NUM_TILE_Y` (registros ya definidos en `dma_registers.md`):

- `tile_y = 0` (borde superior real) → el DMA escribe cero en toda la banda `row=15` del IFBuffer, vía `dma_if_wr_en` (puerto que ya existe en `cnn_accelerator`), antes de escribir los datos reales del tile.
- `tile_x = 0` (borde izquierdo real) → cero en toda la banda `col=255`.
- `tile_y = DMA_NUM_TILE_Y - 1` (borde inferior real) → cero en la fila extra normal, `row = TILE_H` (direccion normal, no wraparound).
- `tile_x = DMA_NUM_TILE_X - 1` (borde derecho real) → cero en la columna extra normal, `col = TILE_W`.

Para tiles interiores (que no tocan ningun borde real), esas mismas posiciones de halo se cargan con datos reales de DDR (overlap con el tile vecino), no con ceros.

Cero lineas de RTL tocadas en el acelerador — el fix vive completo en la logica del DMA (Componente 3, FSM orquestadora), usando puertos que ya existen.

## Pendiente

- Confirmar el rango exacto de direcciones de cada banda (depende de `TILE_W`, `cin_groups`) cuando se diseñe en detalle el generador de direcciones DDR.
- Decidir si el DMA hace esto como un paso explicito antes de cada tile con borde, o si se integra en el mismo burst de carga (ej. escribiendo ceros primero y luego los datos reales encima donde aplique).
