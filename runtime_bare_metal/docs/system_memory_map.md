# Mapa de memoria del sistema y partición del espacio de direcciones

**Ámbito:** este documento describe **cómo se reparte el espacio de direcciones
completo del SoC** entre los dos núcleos ARM, el acelerador en la PL y los datos
del modelo. Es el documento "de sistema".

Complementa, no reemplaza, a:

| documento | qué cubre |
|---|---|
| `ddr_memory_layout.md` | el detalle capa por capa de las 28 activaciones, pesos y bias, y las reglas con que el generador Python calcula cada dirección |
| `scheduler_flow.md` | qué escribe Core 0 en los registros y en qué orden |
| `../../accelerator/cnn_accelerator/docs/hardware_limits.md` | los límites duros del RTL (anchos de registro, alineación, tamaños máximos) |

---

## 0. Origen de cada dato de este documento

Para que sea auditable, cada cosa está marcada con su fuente:

- **[HW]** — verificado contra el hardware o contra documentación del fabricante
  de la placa. Las tres fuentes usadas, y son independientes entre sí:
  1. **Esquemático** `Puzhi PZ-StarLite Schematic.pdf` (19 hojas).
  2. **Manual de hardware** `璞致PZ-StarLite开发板之硬件用户手册.pdf`, que trae
     las tablas de asignación de MIO.
  3. **Los proyectos de ejemplo del propio fabricante** (`2_SDK.rar`), en
     particular `11_dual_core_amp` y `10_micro_sd_rw` — de ahí sale la
     configuración del PS que el fabricante sabe que arranca en esta placa,
     leída de sus `system.hwh`.
- **[BD]** — leído del block design de *este* proyecto
  (`architecture_pl/.../system_bd.hwh`).
- **[TRM]** — del manual técnico del Zynq-7000 (UG585) y de XAPP1079 (AMP
  bare-metal).
- **[DEC]** — decisión de diseño de este trabajo, tomada y justificada acá.
- **[PROP]** — propuesta todavía **no** confirmada por el autor.

---

## 1. La plataforma

**[HW]** Placa **Puzhi PZ-StarLite**, SoC **Xilinx Zynq-7000 XC7Z020-2CLG400I**:

| recurso | valor |
|---|---|
| CPU | 2 × ARM Cortex-A9 (`ps7_cortexa9_0`, `ps7_cortexa9_1`) |
| Cache L1 | 32 KiB I + 32 KiB D **por núcleo**, privadas |
| Cache L2 | 512 KiB **unificada y compartida** entre ambos núcleos |
| OCM | 256 KiB (4 bloques de 64 KiB) |
| DDR3 | **512 MiB** — **un solo** `MT41K256M16TW-107IT:P`, bus de **16 bits** |
| Flash | QSPI `W25Q128JV`, 128 Mbit (16 MiB) |
| Consola | puente USB-serie **CH340E** sobre el conector USB Type-C |
| Tarjeta | socket MicroSD vía level-shifter `TXS02612` (banco 501 a 1,8 V ↔ TF a 3,3 V) |

Del lado de *este* proyecto **[BD]**: `M_AXI_GP0` y `M_AXI_GP1` habilitados,
`S_AXI_HP0` y `S_AXI_HP1` habilitados, `IRQ_F2P` con una línea en modo `DIRECT`,
`FCLK_CLK0` a 70 MHz.

### 1.1 Mapa de MIO de la placa — verificado

**[HW]** Confirmado por las tres fuentes a la vez: el esquemático, la tabla del
manual y el `PCW_*_IO` de los proyectos del fabricante coinciden.

| periférico | MIO | detalle |
|---|---|---|
| **UART0** | **10 .. 11** | RX = MIO 10, TX = MIO 11. Puente **CH340E**. Es UART**0**, no UART1 |
| **SD0** | **40 .. 45** | CLK 40, CMD 41, DATA0-3 42-45 |
| QSPI | 1 .. 6 | flash de 16 MiB, *single slave select* |
| ENET0 | 16 .. 27 | + MDIO/MDC en 52/53 |
| USB0 | 28 .. 39 | + reset en MIO 46 |

**Voltaje de los bancos de MIO** — dato físico de la placa, fácil de pasar por
alto y que rompe la SD:

| banco | MIO | voltaje | quién lo usa |
|---|---|---|---|
| Bank 0 (500) | 0 .. 15 | **LVCMOS 3,3 V** | QSPI (1-6), UART0 (10-11) |
| Bank 1 (501) | 16 .. 53 | **LVCMOS 1,8 V** | SD0 (40-45) |

Tres confirmaciones independientes: el esquemático trae la nota de los
*straps* de arranque `MIO[7] = 0 → MIO bank0 voltage = 3.3V` y
`MIO[8] = 1 → MIO bank1 voltage = 1.8V`; los dos proyectos del fabricante
declaran `PCW_PRESET_BANK1_VOLTAGE = LVCMOS 1.8V` con las seis señales de SD en
`LVCMOS 1.8V`; y el level-shifter `TXS02612` existe **precisamente** porque el
banco 501 está a 1,8 V y la tarjeta TF trabaja a 3,3 V. Si Vivado cree que el
banco está a 3,3 V, configura los buffers de entrada/salida con el umbral
equivocado para el VCCO real.

Dos consecuencias más que hay que respetar sí o sí:

- **No hay Card Detect.** No existe net de CD en el esquemático, la tabla del
  manual lista sólo las 6 señales de datos, y **los dos proyectos del fabricante
  que usan la SD tienen `PCW_SD0_GRP_CD_ENABLE = 0`** — incluido el demo
  dedicado de lectura/escritura de SD. En Vivado el checkbox de *Card Detect*
  va **desmarcado**.
- **Los LED y los botones están en la PL, no en MIO.** De los `.xdc` de los
  ejemplos: **LED en `R19` y `V13`**, **botones en `G14` y `J15`**, todos
  `LVCMOS33`; el reloj de la PL es `U18` y el reset `U19`. O sea que un "LED de
  latido" no sale del PS: habría que sacar un puerto desde la PL. Con UART0
  andando no hace falta.

### 1.2 El PS estaba sin configurar y con la DDR mal — RESUELTO 2026-09-10

> **Estado: corregido y verificado.** El `.xsa` re-exportado el 2026-09-10 a las
> 16:09 (`architecture_pl/system_bd_wrapper.xsa`, bitstream del mismo día
> 16:08:03) pasa **61 de 61 chequeos**: DDR completa, voltaje de bancos, las 12
> longitudes de pista, UART0 / SD0 / QSPI, y los ajustes propios del diseño
> intactos. `ps7_init.tcl` configura los 14 MIO con el IO standard correcto
> (10-11 y 1-6 en `LVCMOS 3.3V`, 40-45 en `LVCMOS 1.8V`), donde antes no
> escribía ninguno. Timing: **WNS +0,177 ns**, 0 de 22.969 endpoints fallando.
>
> Lo que sigue abajo es el diagnóstico original, que se conserva porque explica
> *por qué* cada valor es el que es.


**[BD]** El block design tiene `BOARD_PRESET = None`, `BOARD_INTERFACE = Custom`
y **los 54 MIO sin asignar**. Todo lo que hay son los valores por defecto de
Vivado; lo único propio son `FCLK_CLK0 = 70 MHz`, los puertos AXI y `IRQ_F2P`.

**Ningún periférico del PS está habilitado** (`UART0/1 = 0`, `SD0/1 = 0`,
`QSPI = 0`, `ENET = 0`, `USB = 0`). Eso significa hoy: **sin consola** (no hay
UART para `xil_printf`), **sin lector de SD** (o sea que el flujo
`SD → Core 0 → Core 1 → DDR` no es ejecutable) y **sin arranque autónomo**
(sin SD ni QSPI no hay `BOOT.BIN`; sólo JTAG).

Y hay un problema peor, que es el que impide arrancar del todo:

#### La configuración de DDR no corresponde a esta placa

| parámetro | este proyecto **[BD]** | el fabricante **[HW]** |
|---|---|---|
| Memory Part | `MT41J128M8 JP-125` | **`MT41K256M16 RE-125`** |
| Memory Type | DDR 3 | **DDR 3 (Low Voltage)** |
| **Bus width** | **32 Bit** | **16 Bit** |
| DRAM width | 8 Bits | **16 Bits** |
| Device capacity | 1024 MBits | **4096 MBits** |
| Row address count | 14 | **15** |
| Col / Bank | 10 / 3 | 10 / 3 (igual) |
| Freq, Speed bin, CL, CWL | 533,33 / DDR3_1066F / 7 / 6 | idénticos |

El que rompe es el **ancho de bus**. El esquemático muestra que del lado del
Zynq **sólo están cableados `DQ0..DQ15`, `DM0/DM1` y `DQS0/DQS1`**: los pines
`DQ16..DQ31`, `DM2/DM3` y `DQS2/DQS3` quedan al aire. Con la configuración
actual el controlador entrena cuatro *byte lanes* y dos de ellas no tienen chip:
el *write leveling*, el *read gate* y el *data eye* fallan, y **el arranque se
cuelga en el init de DDR**. Es un fallo que no tendría nada que ver con el
acelerador y que puede costar días de depuración mal dirigida.

El datasheet del `MT41K256M16` confirma el direccionamiento de la variante
**256 Meg × 16**: *row* = 32K (`A[14:0]`, **15 bits**), *bank* = 8 (`BA[2:0]`),
*column* = 1K (`A[9:0]`). Y la capacidad total cierra igual que antes:
4 Gbit sobre un bus de 16 bits = **512 MiB**, con
`PCW_DDR_RAM_HIGHADDR = 0x1FFF_FFFF` en los tres proyectos comparados. **El mapa
de memoria de este documento no se mueve.**

> **Observación pendiente, menor:** el esquemático alimenta el chip desde un net
> llamado `VDD_1V5`, pero el fabricante configura `DDR 3 (Low Voltage)` (1,35 V)
> y cerca del regulador `MP2143DJ` hay una resistencia rotulada `VDD_1V35`, o
> sea una opción de ajuste del riel. No se puede resolver desde el papel cuál
> está poblada. **Se sigue la configuración del fabricante**, que es la que
> arranca en esta placa.

#### Lo que hay que cambiar en el PS, y lo que NO

**Cambiar** — DDR según la tabla de arriba, y habilitar **UART0 (MIO 10..11)**,
**SD0 (MIO 40..45, sin Card Detect)** y, opcionalmente, **QSPI (MIO 1..6)** si se
quiere arrancar desde flash.

**No tocar** — `FCLK_CLK0 = 70 MHz`, `M_AXI_GP0`/`GP1`, `S_AXI_HP0`/`HP1` e
`IRQ_F2P`: ésos son de este diseño, no de la placa, y los ejemplos del
fabricante traen otros valores. **No aplicar un preset de placa ajena**, que
pisa la configuración de DDR y de los puertos AXI.

**No habilitar** Ethernet, USB, I²C ni watchdog: el software no los usa, comen
MIO y Ethernet arrastra lwIP.

El cambio es del lado del PS, sobre pines MIO: **no consume recursos de la PL ni
toca el camino crítico**. Pero obliga a re-sintetizar, re-implementar y
**re-exportar el `.xsa`**, y como el margen actual es de **WNS +0,177 ns**, hay
que **volver a verificar el timing** después de la corrida, no darlo por hecho.

---

## 2. Principios de la partición

1. **Asignación estática, sin reuso.** [DEC] Cada tensor tiene una dirección
   fija y única, calculada una sola vez por `scripts/generate_layer_table.py`.
   No hay `malloc`, no hay análisis de tiempo de vida de buffers, no hay
   solapamientos posibles. El costo es memoria (12,4 MiB de 512) y sobra.
2. **Toda dirección que vea el DMA está alineada a 16 B.** [límite 15 de
   `hardware_limits.md`] El bus de datos del acelerador es de 128 bits; una
   dirección desalineada no se detecta, simplemente lee mal.
3. **Toda base de región está alineada a 1 MiB.** [DEC] La MMU del Cortex-A9 en
   el BSP `standalone` mapea en **secciones de 1 MiB**, y los atributos de cache
   se cambian con esa granularidad (`Xil_SetTlbAttributes`). Si una región no
   está alineada a 1 MiB, volverla no-cacheable arrastra a la vecina.
4. **Bases "redondas" y huecos deliberados.** [DEC] Una dirección suelta vista
   en un ILA o en un `printf` se clasifica de un vistazo: `0x0100_xxxx` es un
   peso, `0x0210_xxxx` una activación. Los huecos no cuestan nada en 512 MiB.
5. **Los dos núcleos no comparten ninguna región de escritura, salvo el buzón.**
   [DEC] Cada núcleo tiene su propia región de código y datos; el único punto de
   contacto es un buzón de pocos bytes en la OCM, más el frame en DDR con
   propiedad transferida explícitamente (ver §6).

---

## 3. Vista global del espacio de direcciones

```
0x0000_0000 ┌──────────────────────────────────────────────┐
            │  DDR3 512 MiB                                │
            │  (los primeros 256 KiB los tapa la OCM)      │
0x2000_0000 ├──────────────────────────────────────────────┤
            │  sin usar                                    │
0x4000_0000 ├──────────────────────────────────────────────┤
            │  M_AXI_GP0 → registros AXI-Lite ACELERADOR   │  4 KiB útiles
0x8000_0000 ├──────────────────────────────────────────────┤
            │  M_AXI_GP1 → registros AXI-Lite DMA          │  4 KiB útiles
0xE000_0000 ├──────────────────────────────────────────────┤
            │  periféricos del PS (UART0, SD0, QSPI)       │
0xF800_0000 ├──────────────────────────────────────────────┤
            │  registros de sistema: SLCR, GIC, TTC, ...   │
0xFFFF_0000 ├──────────────────────────────────────────────┤
            │  OCM bloque alto, 64 KiB  ← buzón inter-core │
0xFFFF_FFFF └──────────────────────────────────────────────┘
```

### 3.1 Registros de la PL **[BD]**

| bloque | puerto | base | rango |
|---|---|---|---|
| Acelerador CNN (`cnn_top_0/axi`) | `M_AXI_GP0` | `0x4000_0000` | `0x4000_0FFF` |
| DMA Engine (`cnn_top_0/s_axi`) | `M_AXI_GP1` | `0x8000_0000` | `0x8000_0FFF` |

Son **dos bancos de registros distintos del mismo IP**, en dos puertos GP
distintos. Los offsets están en `common/cnn_regs.h` (20 registros) y
`common/dma_regs.h` (22 registros).

### 3.2 Camino de datos PL→DDR **[BD]**

El acelerador **no** llega a la DDR por los puertos GP: ésos sólo sirven para que
el PS le escriba configuración. Los datos viajan por **`S_AXI_HP0`/`HP1`**, que
van directo al controlador de DDR **sin pasar por las caches del PS**. De ahí
sale la regla de coherencia de §7, que es la fuente de error más probable de
todo el bring-up.

### 3.3 Interrupción **[BD]**

`cnn_top_0.dma_done → processing_system7_0.IRQ_F2P[0]`, `LEVEL_HIGH`, modo
`DIRECT`. En modo directo `IRQ_F2P[0]` es la **interrupción compartida ID 61**
del GIC. La alternativa (polling sobre `DMA_DONE`, offset `0x40` del banco del
DMA) sigue siendo válida y es más simple para el primer bring-up.

---

## 4. Partición de la DDR (512 MiB)

```
             ┌──────────────────────────────────────────────────────────────┐
0x0000_0000  │ RESERVADO — no usar                                  1 MiB   │
             │ los primeros 256 KiB los tapa la OCM baja. El BSP ya lo      │
             │ excluye: PCW_DDR_RAM_BASEADDR = 0x0010_0000.                 │
0x0010_0000  ├──────────────────────────────────────────────────────────────┤
             │ CORE 0 — .text .data .bss stack heap                15 MiB   │
             │ lscript.ld: ORIGIN 0x0010_0000, LENGTH 0x00F0_0000           │
0x0100_0000  ├──────────────────────────────────────────────────────────────┤
             │ DATOS CONSTANTES DEL MODELO                          1 MiB   │
             │   0x0100_0000  pesos   cnn_weights.bin     51.520 B          │
             │   0x0101_0000  bias    cnn_bias.bin         5.696 B          │
             │   0x0102_0000  dense   cnn_dense.bin        2.340 B          │
0x0110_0000  ├──────────────────────────────────────────────────────────────┤
             │ FRAME RGB CRUDO   256x256x3 = 192 KiB                1 MiB   │
             │ productor: Core 0 (desde SD) · consumidor: Core 1            │
0x0120_0000  ├──────────────────────────────────────────────────────────────┤
             │ libre                                               14 MiB   │
0x0200_0000  ├──────────────────────────────────────────────────────────────┤
             │ FRAME HSV SEGMENTADO   256x256x16 B = 1 MiB          1 MiB   │
             │ productor: Core 1 · consumidor: el DMA (capa conv1)          │
0x0210_0000  ├──────────────────────────────────────────────────────────────┤
             │ ARENA DE ACTIVACIONES — las 28 salidas, contiguas  3,16 MiB  │
             │ termina exacto en 0x0242_803F                                │
0x0243_0000  ├──────────────────────────────────────────────────────────────┤
             │ libre                                              ~221 MiB  │
0x1000_0000  ├──────────────────────────────────────────────────────────────┤
             │ CORE 1 — .text .data .bss stack heap                 4 MiB   │
             │ ** CPU1STARTMEM = 0x1000_0000 **                             │
             │ lscript.ld: ORIGIN 0x1000_0000, LENGTH 0x0040_0000           │
0x1040_0000  ├──────────────────────────────────────────────────────────────┤
             │ LIBRE                                              ~252 MiB  │
0x1FFF_FFFF  └──────────────────────────────────────────────────────────────┘
```

### 4.1 Justificación de cada región

**`0x0000_0000 – 0x000F_FFFF` — reservado. [HW]**
La OCM está mapeada en la parte baja del espacio de direcciones y **tapa los
primeros 256 KiB de la DDR**: escribir ahí creyendo que es DDR escribe en
realidad en la OCM. No es una elección nuestra: `PCW_DDR_RAM_BASEADDR` vale
`0x0010_0000` en este proyecto **y** en los dos del fabricante. Se reserva 1 MiB
entero, no 256 KiB, como guarda contra un stack que se desborde hacia abajo.

**`0x0010_0000` Core 0, y `0x1000_0000` Core 1. [DEC]**
Core 0 arranca donde lo pone el BSP por defecto. Para Core 1 se adopta
**`0x1000_0000`**, que es exactamente el `CPU1_START_ADDR` del ejemplo
`11_dual_core_amp` del fabricante: es un valor que ya se sabe que funciona en
esta placa, y queda a 220 MiB de distancia de la arena de activaciones, así que
ningún desborde de un lado alcanza al otro.

> **Trampa a evitar:** XAPP1079, el ejemplo canónico de Xilinx, usa
> `0x0200_0000` como base de la app de CPU1 — **eso chocaría de frente con el
> frame HSV**. Es un error fácil de cometer copiando código de ejemplo de
> internet en vez del ejemplo de la placa.

**Los `LENGTH` de los linker scripts hay que acotarlos a mano.** Vitis crea los
dos apps con el mismo `lscript.ld` (`ORIGIN 0x0010_0000`), así que **el segundo
pisa al primero** si no se editan. Y hay un segundo motivo, más sutil: el
ejemplo del fabricante deja `LENGTH = 0x3FF00000` en Core 0, o sea 1023 MiB
—más que la memoria física y **pisando todas nuestras regiones de datos**. Con
un `LENGTH` acotado a `0x00F0_0000`, el linker no puede colocar heap ni stack
dentro de los pesos: el error se convierte en un fallo de enlace, ruidoso, en
lugar de una corrupción silenciosa en ejecución.

**`0x0100_0000` datos constantes del modelo. [DEC]**
Las tres regiones caben juntas en una sola sección de MMU de 1 MiB, así que se
les puede cambiar el atributo de cache de un solo golpe. Los offsets internos
están verificados **al byte** contra `weights_manifest.json`, producido por
`export_weights.py` por un camino independiente.

**`0x0110_0000` frame RGB crudo. [PROP]**
Región que faltaba en el mapa: la imagen cruda que Core 0 lee de la SD y que
Core 1 consume como entrada del HSV. Son 256·256·3 = 196.608 B; se le da 1 MiB
por la regla de alineación 3.

**`0x0200_0000` frame HSV segmentado. [DEC, 2026-09-09]**
Estaba planificado en la OCM y se movió a DDR. El empaquetado que exige el RTL
es de `ceil(Cin/16)·16` bytes por píxel, y `conv1` tiene `Cin = 3`, que redondea
a **16 B por píxel**:

```
256 × 256 × 16 B = 1 MiB     contra     256 KiB de OCM
```

No entra por un factor de 4, y no hay forma de esquivarlo: el DMA lee palabras
de 128 bits con ese empaquetado. De los 16 B por píxel, **3 son datos (H, S, V)
y 13 son relleno** que el hardware ignora porque sólo direcciona `Cin` canales.

*(Esto corrige la línea 143 de `Bitacora.md`, que todavía dice
`256x256x3 = 192 KB, cabe en los 256 KB disponibles`.)*

**Impacto en rendimiento de mover el frame a DDR: cero.** 27 de las 28 capas ya
leían y escribían DDR; lo único que se mudó es la entrada de `conv1`, que se lee
una vez por imagen. Esa lectura son 165.996 ciclos = 2,37 ms = **2,4 %** del
total, y ese costo es idéntico contra cualquier esclavo AXI. El cuello de
botella está en la PL, no en la memoria: el `axi4_read_master` pide 553 MB/s a
70 MHz, y **la DDR de 16 bits a 533 MHz da ~2,1 GB/s de pico**, casi cuatro
veces más de lo que el puerto puede pedir. (Ese número era ~4,2 GB/s cuando se
creía que el bus era de 32 bits; la conclusión no cambia.)

**`0x0210_0000` arena de activaciones. [DEC]**
3,16 MiB, 28 tensores contiguos, sin reuso. La activación más grande es la de
`conv1` (512 KiB). Termina clavada en `0x0242_803F`.

### 4.2 Presupuesto total

| región | tamaño |
|---|---|
| Core 0 (región reservada; uso real ≪) | 15,0 MiB |
| Core 1 (región reservada; uso real ≪) | 4,0 MiB |
| pesos + bias + dense | 59,6 KiB |
| frame RGB crudo | 192 KiB |
| frame HSV empaquetado | 1,00 MiB |
| 28 activaciones intermedias | 3,16 MiB |
| **total comprometido** | **≈ 23,4 MiB de 512 MiB (4,6 %)** |

El margen es tan amplio que **la memoria no es una restricción de diseño en este
proyecto**. Eso es lo que justifica la decisión más importante del mapa: la
asignación estática sin reuso, que compra simplicidad y verificabilidad a cambio
de un recurso que sobra.

---

## 5. Partición de la OCM (256 KiB)

**[TRM]** La OCM son 4 bloques de 64 KiB. Tras el reset el BootROM la deja así:

| dirección | tamaño | uso en este proyecto |
|---|---|---|
| `0x0000_0000 – 0x0002_FFFF` | 192 KiB | **no se usa** — su único efecto es tapar la DDR baja (§4.1) |
| `0xFFFF_0000 – 0xFFFF_FFFF` | 64 KiB | **buzón inter-core** |

### 5.1 Por qué el buzón va en la OCM y no en la DDR

La OCM es SRAM dentro del propio chip: **latencia de unos pocos ciclos, sin
abrir filas de DRAM y sin competir con el tráfico del DMA por el controlador de
memoria**. Es la memoria correcta para un dato que se consulta en un handshake.
Y ahora que el frame se fue a DDR, la OCM queda libre justo para eso.

Es además lo que hace el ejemplo del fabricante: `SHARE_BASE = 0xFFFF_0000`.

### 5.2 Reparto del bloque alto

```
0xFFFF_0000  ┌───────────────────────────────────────────┐
             │ BUZÓN INTER-CORE                    64 B  │  <- no cacheable
0xFFFF_0040  ├───────────────────────────────────────────┤
             │ libre (~65 KiB)                           │
0xFFFF_FF00  ├───────────────────────────────────────────┤
             │ RESERVADO BootROM / FSBL           256 B  │
             │   0xFFFF_FFF0 = dirección de arranque de  │
             │                 CPU1 (§6.2). NO TOCAR.    │
0xFFFF_FFFF  └───────────────────────────────────────────┘
```

**[PROP]** Contenido tentativo del buzón — se cierra al escribir
`common/intercore.h`:

| offset | campo | escribe | lee |
|---|---|---|---|
| `+0x00` | `frame_ready` — hay un frame crudo listo | Core 0 | Core 1 |
| `+0x04` | `seg_done` — segmentación terminada | Core 1 | Core 0 |
| `+0x08` | `frame_id` — contador de secuencia | Core 0 | Core 1 |
| `+0x0C` | `status` — código de error de Core 1 | Core 1 | Core 0 |
| `+0x10..` | reservado | | |

**Regla de propiedad: un único escritor por campo.** Ningún campo lo escriben
los dos núcleos. Eso elimina de raíz la necesidad de operaciones atómicas
(`LDREX`/`STREX`) y de cualquier exclusión mutua: no hay sección crítica que
proteger, sólo publicación de un valor.

---

## 6. Arranque AMP y protocolo de handshake

### 6.1 Modelo de ejecución: AMP, no SMP **[DEC]**

Cada núcleo corre **su propio binario bare-metal independiente**, con su propio
BSP `standalone`. No hay sistema operativo ni planificador compartido. El BSP de
**Core 1 se compila con `-DUSE_AMP=1`**, lo que evita que reinicialice la SCU,
la L2 y las tablas de MMU compartidas; sin esa bandera, el arranque de Core 1
tumba a Core 0.

**[HW]** Confirmado en el ejemplo del fabricante: el `system.mss` del BSP de
CPU1 lleva
`extra_compiler_flags = -mcpu=cortex-a9 -mfpu=vfpv3 -mfloat-abi=hard
-nostartfiles -g -Wall -Wextra -DUSE_AMP=1`.
También se ve ahí que **los dos núcleos usan `ps7_uart_0` como `stdin`/`stdout`**
—comparten la misma consola, con la salvedad de que la salida se entremezcla.

Reparto de responsabilidades:

| | Core 0 | Core 1 |
|---|---|---|
| rol | maestro / scheduler | esclavo / preprocesamiento |
| tareas | leer la imagen de la SD, despertar a Core 1, configurar los dos bancos de registros por capa, disparar `DMA_START`, esperar `DMA_DONE`, iterar las 28 capas, clasificar con la capa densa | segmentación HSV, empaquetado a 16 B/píxel, escritura del frame |
| ¿toca la PL? | sí (AXI-Lite) | no |

### 6.2 Despertar de Core 1 — ocurre una sola vez **[TRM + HW]**

No lo inventamos nosotros: lo impone el BootROM del Zynq.

1. Al salir de reset, CPU1 **no** ejecuta el programa de usuario. Entra en un
   lazo `WFE` dentro del BootROM, vigilando la palabra de `0xFFFF_FFF0`.
2. Core 0 escribe en `0xFFFF_FFF0` la **dirección de arranque del ELF de
   Core 1** (`0x1000_0000`, §4).
3. Core 0 ejecuta una barrera (`dmb`) y luego la instrucción **`SEV`**
   (*Send Event*), que saca a CPU1 de su `WFE`.
4. CPU1 lee la palabra, salta a esa dirección y desde ahí corre nuestro código.

**Antes de eso**, Core 0 debe marcar como no cacheables tanto la base del buzón
como `0xFFFF_FFF0`. El ejemplo del fabricante usa el atributo **`0x14de2`**
(`S=1, TEX=0b100, AP=0b11, Domain=0b1111, C=0, B=0` → *non-cacheable
shareable*).

> **Trampa:** si esa región quedara cacheada, la escritura del paso 2 se queda
> atrapada en la L1 de Core 0 y CPU1 no la ve nunca. Es un colgado
> **silencioso**: el sistema arranca y Core 1 simplemente no despierta.

### 6.3 Handshake por imagen — una vez por inferencia **[DEC, siguiendo el ejemplo del fabricante]**

El aviso entre núcleos **no** se hace con banderas en espera activa, sino con
**interrupciones software del GIC (SGI)**, que es lo que hace el ejemplo
`11_dual_core_amp`: el dato viaja por la OCM y el *timbre* es una SGI.

```
   CORE 0                                   CORE 1
     |                                        |
     | despierta a Core 1 (§6.2)  ----------->|  arranca, marca OCM no-cacheable,
     |                                        |  inicializa GIC, espera SGI
     | lee imagen de SD -> 0x0110_0000        |
     | DCacheFlushRange( raw, 192 KiB )       |
     | escribe frame_id en el buzón           |
     | SGI 1 --------------------------------->  handler: pone flag
     |                                        |  lee 0x0110_0000
     | espera SGI 0                           |  HSV + empaquetado 16 B/pix
     |                                        |  escribe -> 0x0200_0000
     |                                        |  DCacheFlushRange( hsv, 1 MiB )
     |                                        |  escribe status en el buzón
     |  <-------------------------------- SGI 0
     | recorre las 28 capas con el DMA        |  vuelve a esperar
     v                                        v
```

Las SGI son los IDs **0 a 15** del GIC y se disparan con
`XScuGic_SoftwareIntr( &intc, <id>, <máscara de CPU destino> )`. Conviene fijar
la convención del ejemplo: **SGI 0 = avisar a Core 0**, **SGI 1 = avisar a
Core 1**.

**Por qué SGI y no espera activa:** el núcleo que espera queda detenido en el
handler en vez de quemando ciclos y ancho de banda de memoria leyendo una
bandera. Y sobre todo, es el mecanismo que el fabricante tiene andando en esta
placa exacta, con lo cual deja de ser código a depurar.

**Por qué alcanza con esto y no hace falta nada más elaborado:** la adquisición
de imagen es **por SD con preprocesamiento offline; no hay cámara en tiempo
real** (decisión del 2026-06-25). El handshake ocurre **una vez por imagen**, no
a 30 fps: un doble buffer o una cola de frames sería complejidad sin beneficio
medible.

Para Core 0 esperando `DMA_DONE` del acelerador, la elección entre polling e IRQ
(ID 61, §3.3) se decide en el bring-up: **polling primero por simplicidad, IRQ
después si hace falta**.

---

## 7. Coherencia de cache — las reglas obligatorias

Ésta es la sección que más errores previene, y por eso va explícita.

### 7.1 El problema

El acelerador llega a la DDR por **`S_AXI_HP`**, que entra directo al
controlador de DDR **sin pasar por la L1 ni por la L2 del PS**. Es decir: **la
PL no ve nada de lo que esté en las caches del ARM, y el ARM no se entera de
nada que la PL escriba en la DDR.** No hay coherencia automática por ese camino.

Los dos síntomas, ambos silenciosos:

- Core 1 escribe el frame, los datos quedan en su cache L1 y la DDR todavía
  tiene basura → **el acelerador procesa basura**, y la inferencia da un
  resultado absurdo sin ningún mensaje de error.
- El DMA escribe una activación en DDR, Core 0 la lee y su cache le contesta el
  valor viejo → **Core 0 lee datos rancios**.

### 7.2 Las reglas

| situación | acción obligatoria |
|---|---|
| Core 1 terminó de escribir el frame HSV, antes de avisar | `Xil_DCacheFlushRange( 0x0200_0000, 1 MiB )` |
| Core 0 cargó pesos, bias o imagen en DDR, antes del primer `DMA_START` | `Xil_DCacheFlushRange` sobre cada región cargada |
| Core 0 va a leer algo que escribió el DMA | `Xil_DCacheInvalidateRange` **antes** de leer |
| buzón de la OCM | `Xil_SetTlbAttributes( 0xFFFF_0000, 0x14de2 )` en **ambos** núcleos, y no cachearlo nunca |

**Por qué el buzón es no-cacheable y el frame no.** Son dos estrategias
distintas, elegidas a propósito:

- El **frame** son 1 MiB que se escriben una sola vez, de forma secuencial.
  Conviene escribirlos **con cache** (mucho más rápido, con *write-back* en
  ráfagas) y pagar un único `flush` al final. Volverlo no-cacheable haría lenta
  la escritura de cada píxel.
- El **buzón** son unos pocos bytes que se leen justo después de una SGI. Ahí la
  cache no ayuda y además **rompe**: sin coherencia se lee el valor viejo.

**Nota sobre la L2:** la L2 sí es compartida entre los dos núcleos, así que entre
Core 0 y Core 1 hay algo más de margen; pero **la PL no ve ni la L1 ni la L2**,
así que para todo lo que toque el DMA la regla del `flush` es innegociable.

---

## 8. Vitis: cómo se materializa esta partición

```
Platform Project  (desde el .xsa re-exportado)
├── dominio standalone · ps7_cortexa9_0   -> BSP de Core 0   stdout = ps7_uart_0
└── dominio standalone · ps7_cortexa9_1   -> BSP de Core 1   [ -DUSE_AMP=1 ]

System Project
├── core0_app   fuentes: core0/src/ + common/   lscript.ld -> 0x0010_0000, LEN 0x00F0_0000
└── core1_app   fuentes: core1/src/ + common/   lscript.ld -> 0x1000_0000, LEN 0x0040_0000
```

- **Un solo `.xsa`, una sola plataforma, dos dominios.** No se crean dos
  plataformas.
- Los dos Application Projects van **dentro del mismo System Project**: eso es lo
  que hace que `Build` compile ambos y que
  `Run/Debug As → Launch on Hardware (System Project Debug)` descargue el
  bitstream, el `ps7_init` y **los dos ELF**, cada uno a su núcleo.
- `common/` **no se copia**: cada app agrega un *include path* hacia
  `runtime_bare_metal/common`. El repo es la fuente de verdad y `vitis_ws/` está
  fuera de git por completo.
- Los **linker scripts hay que editarlos a mano** (§4.1), tanto el `ORIGIN` como
  el `LENGTH`.
- Con UART0 habilitado, en cada BSP hay que poner **`stdin`/`stdout` =
  `ps7_uart_0`**, si no `xil_printf` no sale por ningún lado.
- **Arranque autónomo** (`BOOT.BIN` = FSBL + `.bit` + los dos ELF): posible una
  vez habilitada la SD. Hasta entonces, sólo JTAG.

---

## 9. Riesgos abiertos y decisiones pendientes

| # | tema | estado |
|---|---|---|
| 1 | **DDR mal configurada** (bus de 32 bits contra 16 reales) | **CERRADO 2026-09-10** — `MT41K256M16 RE-125`, 16 Bit, 4096 MBits, row 15, *Low Voltage* |
| 2 | UART0 y SD0 deshabilitados | **CERRADO 2026-09-10** — UART0 en MIO 10..11 a 115200, SD0 en MIO 40..45 sin Card Detect, y QSPI en MIO 1..6 de yapa |
| 3 | Re-verificar **WNS** tras la corrida | **CERRADO 2026-09-10: +0,177 ns, 0/22.969 endpoints, WHS +0,045**. Recursos: LUT 21,23 %, BRAM 75 %, DSP 54 |
| 3b | Bank 1 de MIO a 3,3 V cuando la placa lo tiene a 1,8 V | **CERRADO 2026-09-10** — `LVCMOS 1.8V`, verificado hasta en los registros MIO de `ps7_init.tcl` |
| 3c | Longitudes de pista de DDR con los valores por defecto de Vivado | **CERRADO 2026-09-10** — las 12 iguales a las del fabricante |
| 4 | `DDR_RAW_BASE = 0x0110_0000` para la imagen cruda | propuesta, a confirmar |
| 5 | Campos exactos del buzón | se cierra al escribir `common/intercore.h` |
| 6 | Espera de `DMA_DONE`: polling vs. IRQ ID 61 | hardware listo; se decide en el bring-up |
| 7 | Riel de la DDR: el esquemático dice `VDD_1V5`, el fabricante configura *Low Voltage* | se sigue al fabricante; observación registrada en §1.2 |
| 8 | `Bitacora.md` línea 143 dice que el frame va a la OCM | desactualizada, corregir antes de la entrega |
| 9 | El modelo de costo (99,4 ms / 10,1 fps) se calibró en simulación con memoria de latencia fija | **el número a creer es el que se mida en placa con un timer** |
