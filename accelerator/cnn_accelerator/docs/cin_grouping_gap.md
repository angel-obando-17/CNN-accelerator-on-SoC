# HALLAZGO: `cin_groups` usa `floor(Cin/16)` en vez de `ceil(Cin/16)` — rompe el direccionamiento on-chip cuando `Cin` no es múltiplo de 16

**Origen: sesión PS, 2026-09-02**, durante el Paso 3 de `generate_layer_table.py`
(dimensionar tiles/capacidad de IFBuffer por capa), al revisar de cerca la
fórmula de `cin_groups` para calcular cuántas palabras del IFBuffer ocupa
cada capa. Se documenta acá, en la zona de PL, por el mismo criterio que
`stride_support_gap.md`: es una limitación del datapath, no del software del
PS. Continúa la serie de gaps hardware↔entrenamiento iniciada en
[[project_quantization_hw_gap]] y `stride_support_gap.md`.

## El hallazgo, en una frase

**El acelerador y el DMA calculan cuántas palabras de 128 bits ocupa cada
posición espacial del IFBuffer con `floor(Cin/16)`, pero el direccionamiento
que usan (stride fijo por palabra completa) solo es correcto con
`ceil(Cin/16)` — para cualquier capa cuyo `Cin` no sea múltiplo exacto de 16,
las direcciones de columnas/filas consecutivas se pisan entre sí, y el
modelo de producción real tiene 3 de esas capas.**

## Parte 1 — La fórmula, confirmada en RTL real, en los dos lados

**`addr_generator.vhd`** (acelerador), línea 211:

```vhdl
cin_groups := resize( unsigned( cin( 6 downto 4 ) ), 3 );  -- Cin / 16
```

Usada como multiplicador de stride para `addr_in` (líneas 223-231 y 229-231):

```vhdl
term1 := resize( row * tile_w_pad * cin_groups, 13 );
term2 := resize( col * cin_groups, 13 );
```

**`ddr_addr_gen.vhd`** (DMA), línea 117 — mismo patrón exacto, mismo registro
`cin`:

```vhdl
cin_groups := resize( unsigned( cin( 6 downto 4 ) ), 16 );
```

Usado para el stride del destino on-chip (`local_addr`, dentro del IFBuffer):

```vhdl
row_words_padded := resize( ( v_tile_w + 2 ) * cin_groups, 16 );
```

**Las dos instancias son consistentes entre sí** (mismo registro `Cin`, misma
fórmula de truncamiento) — no es una discrepancia entre acelerador y DMA, es
la misma limitación replicada en los dos lados por diseño. El problema es que
`cin(6 downto 4)` es literalmente `Cin >> 4` (`floor(Cin/16)`), y ese valor
solo coincide con la cantidad real de palabras necesarias
(`ceil(Cin/16)`) cuando `Cin` es múltiplo exacto de 16.

Importante — el `cin` **crudo** (sin truncar) sí se usa correctamente en
otros lados para stride de DDR (`ddr_addr_gen.vhd`: `row_stride_in := img_w *
unsigned(cin)`, byte a byte, sin agrupar) y para direcciones del Weight
Buffer (`addr_generator.vhd`: `term3 := co_counter*cin*9`, `term7 :=
co_counter*cin`, donde `cin` escala un conteo de posiciones `ci`, no una
agrupación de 16). Esos dos usos son correctos para cualquier `Cin`, con o
sin múltiplo de 16 — **el problema está aislado exclusivamente al stride
on-chip del IFBuffer** (`cin_groups`, en los dos archivos citados arriba).

Tampoco afecta al lado de canales de **salida** (`Cout`/`co_counter`): el
número de grupos de salida (`max_co`/`REG_MAX_CO`) lo calcula el PS
directamente como `ceil(Cout/16) - 1` y lo escribe tal cual en el registro —
no se deriva por truncamiento de bits de un `Cout` crudo en ningún punto del
RTL. Ese camino ya está bien.

## Parte 2 — Por qué esto corrompe direcciones, no solo desperdicia espacio

Con `cin_groups = floor(Cin/16)` en vez de `ceil(Cin/16)`, el stride entre
columnas consecutivas del IFBuffer queda **más chico** de lo que la cantidad
real de datos por columna necesita. Dos casos concretos:

- **`Cin=3`** (el caso de `conv1`): `floor(3/16) = 0`. `cin_groups=0` hace que
  `term1`/`term2` sean **cero sin importar `row`/`col`** — todas las
  posiciones espaciales de la fila mapean a la misma dirección de palabra.
  Colapso total, no una corrupción parcial.
- **`Cin=24`** (el caso de `irb3_exp`/`irb4_exp`): `floor(24/16) = 1`, pero
  24 canales necesitan 2 palabras completas (16 en la primera, 8 en la
  segunda). Con stride=1 palabra por columna, la **segunda palabra de la
  columna N** (que debería contener los canales 16-23 de esa columna) queda
  en la misma dirección que la **primera palabra de la columna N+1**
  (canales 0-15 de la columna siguiente) — se pisan.

No es un caso límite raro: es la fórmula fallando exactamente donde el
modelo real la necesita.

## Parte 3 — A quién afecta, contra la tabla de 28 capas ya armada (Paso 2)

De los 28 `Cin` de la tabla, 25 son múltiplos exactos de 16 (`16`, `32`,
`48`, `64`) y no tienen problema. **3 no lo son:**

| Capa | `Cin` | `floor(Cin/16)` (lo que calcula el RTL) | `ceil(Cin/16)` (lo que hace falta) | Efecto |
|---|---|---|---|---|
| `conv1` | **3** | `0` | `1` | Stride=0 → todas las columnas de una fila colisionan en la misma dirección |
| `irb3_exp` | **24** | `1` | `2` | La 2da palabra de cada columna pisa la 1ra palabra de la columna siguiente |
| `irb4_exp` | **24** | `1` | `2` | Mismo problema que `irb3_exp` |

Ojo con el efecto en cascada: para que estas 3 capas queden resueltas de
verdad, también hay que decidir qué pasa con las capas que las **producen**
(`irb2_pw`, `Cout=24`, alimenta a `irb3_exp`) y (`irb3_pw`, `Cout=24`,
alimenta a `irb4_exp`) — si la solución elegida implica que el `Cin` de
lectura cambie (por ejemplo, pad a múltiplo de 16), el `Cout`/dato físico
que esas dos capas productoras escriben a DDR tiene que ser consistente con
eso.

## Impacto — bloquea el Paso 3 de `generate_layer_table.py`

**Actualizado tras la Parte 4 (PL) — son 5 capas bloqueadas, no 3.** El
Paso 3 necesita calcular capacidad de IFBuffer/OFBuffer y geometría de tiles
por capa, y esa cuenta depende directamente de `cin_groups`/`cout_groups`.
Lista completa de capas donde el Paso 3 no puede calcular nada confiable:

| Capa | Motivo |
|---|---|
| `conv1` | `Cin=3`, lectura de IFBuffer rota (`cin_groups`) |
| `irb2_pw` | `Cout=24`, su propia escritura de OFM rota (`cout_groups`) |
| `irb3_exp` | `Cin=24`, lectura de IFBuffer rota (`cin_groups`) — hereda de `irb2_pw` |
| `irb3_pw` | `Cout=24`, su propia escritura de OFM rota (`cout_groups`) |
| `irb4_exp` | `Cin=24`, lectura de IFBuffer rota (`cin_groups`) — hereda de `irb3_pw` |

Las otras **23** capas de la tabla de 28 (todas con `Cin`/`Cout` múltiplo de
16) no están afectadas por ninguno de los 3 sitios del bug y se pueden
diseñar en el Paso 3 mientras se decide la solución — igual que pasó con
stride.

## Parte 4 — Ampliación (sesión PL, 2026-09-02): el mismo bug también rompe el lado `Cout` de escritura, no solo el `Cin` de lectura documentado arriba

Releyendo `ddr_addr_gen.vhd` completo (no solo la línea 117 citada por PS) para
confirmar el hallazgo antes de discutir la solución: el mismo patrón
`floor(N/16)` está **replicado una tercera vez**, en la variable
`cout_groups` (línea 118):

```vhdl
cout_groups  := resize( unsigned( cout( 6 downto 4 ) ), 16 );  -- linea 118
```

Se usa en el caso `"OFM / Residual"` (línea 207) para calcular
`row_words_out`, el stride on-chip tanto para **leer el OFBuffer al
escribir OFM a DDR** como para **escribir el Residual Buffer al leer
residual de DDR**:

```vhdl
row_words_out := resize( tile_w_out * cout_groups, 16 );  -- linea 207
```

Es exactamente el mismo bug (`floor` en vez de `ceil`), pero del lado
**Cout**, no Cin. Contra `mobilenetv2.py` (código fuente real, confirmado
directamente): `irb2_pw` y `irb3_pw` tienen `filters=24` → `Cout=24` →
`floor(24/16)=1` en vez de `2` — **estas dos capas ya estaban en la lista
de PS como "productoras" de `Cin=24`, pero por otra razón**: PS las señaló
solo porque alimentan a `irb3_exp`/`irb4_exp` con `Cin=24` malo. Lo que no
estaba documentado es que **la escritura del propio OFM de `irb2_pw` e
`irb3_pw` hacia DDR ya viene corrupta antes de eso**, por este segundo sitio
del bug — un problema independiente que da la casualidad de afectar a las
mismas dos capas.

Confirmado también que ninguna otra capa de las 28 tiene `Cout` no-múltiplo
de 16: revisando `build_mobilenetv2` capa por capa, todo `Cout` sale de
`min(algo, max_ch=64)` o de `filters` fijo en el `cfg` — los únicos
`filters` que no son múltiplos de 16 en toda la tabla `cfg` son los dos
`24` (`irb2`, `irb3`), que son justo los ya identificados. La salida final
(`Dense(num_classes)`) no corre en el acelerador — es un clasificador
minúsculo que hace el PS en software sobre el vector de 64 canales que deja
`GAP`, así que no hereda este bug.

**Conclusión para la solución:**

- **Opción 1 (fix de HW)** sigue siendo la misma en alcance real: 2
  archivos, pero **3 sitios de fórmula** a cambiar, no 2 —
  `addr_generator.vhd:211` (`cin_groups`), `ddr_addr_gen.vhd:117`
  (`cin_groups`) **y** `ddr_addr_gen.vhd:118` (`cout_groups`). Mismo cambio
  mecánico en los tres: `(unsigned(x) + 15) >> 4` en vez de `x(6 downto 4)`.
  Verificado que el ancho de bits alcanza: con el tope duro de canales ya
  confirmado en `project_channel_limit_violation` (`Cin`/`Cout` ≤ 64),
  `ceil(64/16)=4` cabe holgado en los 3 bits de `cin_groups`
  (`addr_generator.vhd`) y en los 16 bits de `cin_groups`/`cout_groups`
  (`ddr_addr_gen.vhd`) — no hace falta ensanchar ningún registro.
- **Opción 2 (pad por software)** no cambia de forma: el plan que PS ya
  había escrito arriba ("hacer que `irb2_pw`/`irb3_pw` escriban 32 canales
  de salida en vez de 24") **ya cubría esto sin saberlo** — el padding de
  `Cout` a múltiplo de 16 en esas dos capas arregla *ambos* bugs a la vez
  (su propia escritura de OFM y la lectura de `Cin` de la capa siguiente),
  aunque el razonamiento original de PS solo mencionaba la segunda razón.

Esto no cambia cuál opción conviene (la 1 sigue viéndose más limpia), pero
sí corrige el alcance exacto: son 3 sitios de fórmula, no 2, y el motivo por
el que `irb2_pw`/`irb3_pw` importan es doble, no simple.

## Parte 5 — Verificación del fix (sesión PL, 2026-09-03): CORRECTO pero NO SUFICIENTE — hay un segundo gap, nuevo, que afecta a las 5 capas por igual, no solo a 2

Angel implementó el fix de la Opción 1 (`(unsigned(x)+15) >> 4` en los 3
sitios). Se armó un testbench nuevo (`tb_cnn_top_stride.vhd`, Casos F/G/H,
mismo patrón que los de stride) y se corrió en ModelSim contra el RTL real.

**Resumen de los 6 escenarios verificados (ver tabla) — CUIDADO con el Caso
F: pasó, pero por una razón equivocada (dato uniforme que no puede detectar
el problema real), no porque `conv1` esté a salvo. El Caso F2 corrige eso.**

| Caso | Escenario | Resultado |
|---|---|---|
| F | Conv3x3, `Cin=3` (`conv1`), 2x2, activación UNIFORME | PASA — pero es un falso negativo, ver Caso F2 |
| **F2** | Conv3x3, `Cin=3` (`conv1`), **4 columnas**, activación que SÍ varía por columna | **FALLA** — satura a `0x7F` en las 4 posiciones (corrupción severa, no un simple corrimiento) |
| H | PW1x1, `Cout=24` (`irb2_pw`/`irb3_pw`), **2 filas**, escritura de OFM | PASA — pero solo prueba filas, no columnas, ver Caso H2 |
| **H2** | PW1x1, `Cout=24` (`irb2_pw`/`irb3_pw`), **2 columnas**, escritura de OFM | **FALLA** — la columna 1 lee el remanente de la columna 0 |
| G | PW1x1, `Cin=24` (`irb3_exp`/`irb4_exp`), **2 columnas** | **FALLA** — valores no coinciden (`0x21`/`0x40` en vez de `0x20`/`0x50`) |

**Conclusión correcta (reemplaza la de la primera pasada): las 5 capas
originales (`conv1`, `irb2_pw`, `irb3_exp`, `irb3_pw`, `irb4_exp`) siguen
bloqueadas para tiles reales de más de 1 columna — el fix de `ceil` no
alcanza para NINGUNA de las 5, ni para lectura (Cin) ni para escritura
(Cout).** La razón por la que el Caso F "pasó" es que usó el mismo peso y
la misma activación (=1) en todos los pixeles reales — con eso, aunque el
direccionamiento lea el pixel equivocado, sigue siendo OTRO pixel real con
el mismo valor, así que la cuenta da igual por pura coincidencia. El Caso F2
(activación distinta por columna, mismo truco que ya se usaba en los
testbenches de stride) lo expone sin ambigüedad.

(Los primeros intentos de los Casos G/H fallaron por mal armado del propio
testbench —a `weight_words`/`bias_words` les faltaba la segunda mitad para
`max_co=1`, dejando BRAM sin inicializar (`'X'`) — corregido y confirmado
que el ORIGEN del fallo del Caso H (con 2 FILAS) era eso, no el RTL: ya
corregido, pasa limpio. El Caso H2 (2 COLUMNAS, mismo `weight_words`/
`bias_words` ya corregidos) encontró el problema real, distinto.)

### La causa raíz (Casos F2/G/H2) — no es el mismo bug, es una limitación distinta que el fix no toca

`row_stride_in := img_w * cin` (línea 199 del archivo) usa `Cin` **crudo,
en bytes, sin redondear a múltiplo de 16** — es decir, en DDR cada pixel
ocupa exactamente `Cin` bytes, **empaquetado denso, sin relleno entre
pixeles consecutivos** de una misma fila. Pero el `axi4_read_master` fetchea
la fila COMPLETA en un solo burst lineal de `burst_words` palabras de 128
bits (16 bytes cada una), y el acelerador direcciona el resultado on-chip
asumiendo que **cada pixel ocupa un número entero de esas palabras de 16
bytes** (`cin_groups` de ellas, ahora correctamente `ceil(Cin/16)`).

Para `Cin=24` (`cin_groups=2`, 32 bytes reservados on-chip por pixel) contra
un empaquetado denso de solo 24 bytes reales por pixel en DDR: el pixel 0
ocupa DDR bytes `[0,23]`, el pixel 1 ocupa `[24,47]` — pero el burst lineal
corta en fronteras de 16 bytes (`[0,15]`, `[16,31]`, `[32,47]`, `[48,63]`),
así que la palabra on-chip nº2 (bytes `[32,47]` del burst) termina
conteniendo **bytes 8-23 del pixel 1** (no bytes 0-15 como espera la
dirección on-chip `pixel1_grupo0`) — el pixel 1 queda leído con un
corrimiento de 8 bytes respecto de lo que el direccionamiento cree que está
leyendo. Confirmado en simulación examinando `inputf_buf`/`outputf_buf`
directamente: el pixel 0 (primer pixel de la fila) siempre sale bien —
nunca se corrompe, porque nada lo desplaza — pero desde el pixel 1 en
adelante el corrimiento se acumula.

**Esto es un gap DISTINTO del `floor`-vs-`ceil` ya corregido — es una
consecuencia de combinar (a) empaquetado denso de `Cin`/`Cout` bytes/pixel
en DDR con (b) direccionamiento on-chip en palabras completas de 16
bytes/grupo. Con `Cin`/`Cout` múltiplo de 16 los dos esquemas coinciden
exactamente y el problema es invisible — por eso nunca apareció en los 23
casos ya verificados antes de este cambio.** Solo se manifiesta cuando una
capa tiene `Cin` (lectura) o `Cout` (escritura) no-múltiplo de 16 **Y** el
tile tiene más de una columna real — que es exactamente cómo se van a usar
las 5 capas afectadas en el pipeline real (tiles de varias columnas, no de
a 1 pixel).

Mismo mecanismo simétrico del lado de escritura (Caso H2, `row_stride_out
:= img_w_out * cout` con `cout` crudo): la columna 0 sale siempre bien
(nada la desplaza), pero el sobrante de sus últimos bytes (más allá de sus
`Cout` reales) se escribe físicamente encima de los primeros bytes de la
columna 1 — la columna 1 queda leyendo el remanente de la columna 0 en vez
de su propio dato. Confirmado en simulación: `CasoH2 col1 canales 0-7`
obtuvo el valor de la columna 0 (`32`) en vez del suyo propio (`80`). Con
`Cin=3` (`conv1`, Caso F2) el efecto es mucho más severo que con `Cin=24`
porque la proporción `16/Cin` es mayor — el corrimiento no es de unos
pocos bytes sino de filas/columnas enteras, y el resultado satura
directamente a `0x7F` en vez de dar un valor "cercano pero mal".

### Impacto sobre la decisión Opción 1 vs Opción 2

Esto **no invalida** el fix de `ceil` que ya se hizo — sigue siendo
necesario (confirmado por los Casos F y H en los escenarios que sí cubren)
— pero **no alcanza solo** para que ninguna de las 5 capas afectadas
(`conv1`, `irb2_pw`, `irb3_exp`, `irb3_pw`, `irb4_exp`) corra bien con
tiles reales de más de una columna, ni en lectura ni en escritura.

## Parte 6 — Prototipo de una tercera vía (sesión PL, 2026-09-04): "Opción 1b", rellenar el EMPAQUETADO en DDR sin tocar el modelo

Antes de recomendar entre Opción 1 (fix de HW) y Opción 2 (pad de canales
en el modelo), se probó una tercera variante intermedia: dejar `Cin`/`Cout`
tal cual (sin tocar el modelo ni los pesos exportados), pero hacer que
`ddr_addr_gen.vhd` calcule el stride de fila (`row_stride_in`/
`row_stride_out`) usando **`cin_groups*16`/`cout_groups*16`** (el
empaquetado ya redondeado a múltiplo de 16) en vez de `Cin`/`Cout` crudo —
es decir, reservar en DDR el mismo relleno que ya se reserva on-chip, en
vez de empaquetar denso.

**Prototipo (`ddr_addr_gen_proto.vhd`, 4 líneas cambiadas: `row_stride_in`,
`term2` del caso IFM, `row_stride_out`, `term2` del caso OFM/Residual — el
mismo `shift_left(cin_groups,4)` en vez de `unsigned(cin)`):**

| Caso prototipo | Resultado |
|---|---|
| **Proto-H2** (Cout=24, 2 columnas, escritura, dato en DDR ya con el relleno de 32 bytes/pixel) | **PASA limpio, las 6 verificaciones** — confirma que la Opción 1b arregla el problema del lado de escritura |
| **Proto-G** (Cin=24, 2 columnas, lectura, mismo relleno) | **Sigue fallando** en este intento — pero el diagnóstico post-mortem (examinar el IFBuffer al final de TODA la corrida) quedó contaminado por el reuso del buffer ping-pong entre capas posteriores; no se pudo aislar la causa exacta en el tiempo disponible. **No se puede confirmar ni descartar la Opción 1b para el lado de lectura con lo que se probó hasta ahora** — hace falta un testbench aislado (una sola capa, examinar el buffer inmediatamente después de esa capa) antes de confiar en este resultado.

**Conclusión de la Parte 6, con la salvedad de arriba:** la Opción 1b es
prometedora — el cambio queda contenido a las mismas 2 líneas ya tocadas
(`row_stride_in`/`row_stride_out` en `ddr_addr_gen.vhd`) más 2 líneas
hermanas (los `term2` de offset entre tiles), sin tocar el modelo entrenado
ni los pesos exportados — pero **el lado de lectura todavía no está
confirmado** y el lado de escritura sí. Antes de decidirse por esta vía
hay que: (1) rehacer el Proto-G con un testbench limpio de una sola capa, y
(2) confirmar cómo llega paddeado el **primer** frame de entrada real que
alimenta a `conv1`.

**Corrección importante sobre el punto (2):** no hay cámara MIPI en tiempo
real en el alcance de este trabajo — decisión ya tomada y documentada en
`notas_proyecto.md` (sección "Adquisición de imagen: SD card en lugar de
MIPI en tiempo real", 2026-06-25): las imágenes se pre-procesan offline
(Python/OpenCV, redimensionadas a 256×256) y se cargan desde SD card. El
flujo real es `SD card → Core 0 lee imagen → Core 1 hace segmentación HSV
→ escribe resultado en OCM → Core 0 lee OCM → DMA carga tile en IFBuffer`.
Esto es BUENA noticia para la Opción 1b, no un problema: el "primer
escritor" del frame que alimenta a `conv1` es **código C de Core 1**
(software bare-metal, no un bloque de hardware de captura), así que
paddear su formato de salida a múltiplo de 16 bytes/pixel (si se elige
esta vía) es un cambio de formato controlado enteramente por PS, no
requiere tocar ningún IP de captura de video.

Comparación de las tres vías con lo que se sabe hasta ahora:

- **Opción 1 (solo `ceil`, ya hecha)**: insuficiente por sí sola — confirmado.
- **Opción 1b (rellenar el empaquetado en DDR, prototipo de esta Parte)**:
  contenida (2 archivos, 4 líneas), sin tocar el modelo — el lado de
  lectura sigue sin confirmar (falta un testbench limpio), pero el "primer
  escritor" del frame de `conv1` es código de Core 1 (HSV, software), así
  que paddear su salida es un cambio de formato controlado, no un problema
  de hardware de captura (ver corrección de contexto arriba: no hay MIPI
  en tiempo real, es SD card + preprocesamiento offline).
- **Opción 2 (pad de canales en el modelo)**: resuelve todo de raíz —
  vuelve irrelevante la distinción denso-vs-relleno porque `Cin`/`Cout` ya
  son múltiplo de 16 en todos lados — pero encadena cambios en 6 capas del
  exportador de pesos de CNN_training (documentado arriba) y no toca el
  problema análogo que encontró PS en paralelo,
  [[project_weight_words_overflow_gap]] (registro de 8 bits que no alcanza
  para `Cin=Cout=64`) — ese sigue existiendo sea cual sea la opción elegida
  acá, porque es un límite de ancho de registro, no de empaquetado.

**No se decide acá** — queda para que Angel, PS y PL lo discutan con todo
esto sobre la mesa.

## Parte 7 — RESUELTO (sesión PL, 2026-09-04/05): tercer bug encontrado (no era el empaquetado), fix aplicado y verificado — la Opción 1b queda CONFIRMADA de punta a punta

Para terminar de confirmar/descartar el lado de lectura de la Opción 1b
(pendiente desde la Parte 6, Proto-G contaminado), se armó un entorno
aislado nuevo (`tb_proto1b.vhd`, scratch, no en el repo) con **una sola
capa por corrida** (sin reuso de ping-pong entre capas), chequeando el OFM
escrito a DDR inmediatamente después de esa capa — mismo método robusto
que ya usaban los Casos F/G/H, en vez del examen post-mortem del buffer
que contaminó el Proto-G original.

**Primer hallazgo, antes de llegar al fondo:** un **4to sitio** del mismo
bug `floor`-vs-`ceil` de las Partes 1/4, nunca tocado por esos fixes,
en `dma_fsm.vhd` (líneas 142/149): el conteo de palabras del zero-fill de
halo izquierdo/derecho del IFBuffer usaba `cin(6 downto 4)` (floor) en vez
de `ceil(Cin/16)`. Con `cin_groups>1` (exactamente las 5 capas afectadas),
esto dejaba **la mitad del halo sin inicializar** (BRAM en `'X'` en
simulación, comportamiento indefinido en hardware real). Arreglado con el
mismo patrón `(unsigned(cin)+15)>>4` que ya se usaba en los otros 3 sitios.

**Segundo hallazgo, el que realmente bloqueaba el lado de lectura — no es
el empaquetado, es un bug de timing en `addr_generator.vhd`:**
`fsm_addr_generator.vhd`/`fsm_cnn_acc.vhd` asumen una latencia constante de
2 ciclos entre "se pide una dirección" y "el dato llega a `act_reg`" (el
estado `DRAIN` del FSM principal existe para drenar exactamente ese último
dato). Esa latencia de 2 ciclos **solo es real cuando el último paso del
barrido de `sig_ci` cruza de palabra de 16 bytes** — con `Cin` múltiplo de
16 eso SIEMPRE coincide con el final del barrido (por eso nunca apareció en
los 23 casos ya verificados). Con `Cin=24` (`cin_groups=2`), el cruce de
palabra pasa a mitad del barrido (`ci=16`); los últimos pasos (`ci=16..23`)
quedan dentro de la MISMA palabra, la latencia real ahí es de 1 ciclo, y el
ciclo `DRAIN` termina leyendo `sig_ci=24` (inválido, byte de relleno) en
vez de `ci=23` (el último canal real). Confirmado ciclo a ciclo con
`vsim` en modo batch (examinando `sig_ci`, `act_reg`, `mac_en` y el
acumulador directamente).

**Fix aplicado** (sin tocar el timing de las FSMs, que sostiene los 23
casos ya verificados): en `addr_generator.vhd`, clamp de `sig_ci` a
`Cin-1` (variable `sig_ci_c`), aplicado únicamente en los 4 puntos donde
`sig_ci` se convierte en dirección/byte real (`term4`, `addr_in`,
`byte_sel`, `addr_w` de PW1x1) — si la FSM compartida deja pasar un ciclo
de más, ahora relee la última posición válida (inofensivo) en vez de leer
relleno.

**Validación — regresión completa, sin romper nada:**
- Testbench aislado (`tb_proto1b.vhd`, Cin=24 lectura + Cout=24 escritura,
  con el prototipo de empaquetado relleno de la Parte 6): **10/10 chequeos
  OK** — el lado de lectura queda confirmado por primera vez.
- Suite de regresión completa (`tb_cnn_top_stride.vhd`, Casos A–H2, contra
  el RTL real con empaquetado DENSO, sin el prototipo de la Opción 1b):
  Casos A, B, C, D, E, F, H — **sin ninguna regresión**. F2/G(pixel 1)/H2
  (col1) siguen fallando exactamente por el gap de empaquetado ya
  documentado (Partes 5-6) — nada nuevo, no relacionado con estos 2 fixes.
  De hecho `CasoG pixel(0,0)` que antes daba `0x21` (mal) ahora da `0x20`
  (bien) — confirma que el fix es una mejora real e independiente del
  empaquetado.

**Estado real de los archivos (2026-09-05):** ambos fixes aplicados y
verificados en las copias que Vivado usa activamente (confirmado contra el
`.xpr`):
- `architecture_pl/architecture_pl.srcs/sources_1/new/addr_generator.vhd`
  — clamp `sig_ci_c`.
- `dma/rtl/dma_fsm.vhd` — `ceil` en el zero-fill de halo.

(El espejo git-tracked `accelerator/` queda desactualizado hasta el
próximo sync manual — ver [[project_repo_organization]].)

**Conclusión — cambia el estado de la decisión:** la Opción 1b ya NO tiene
ninguna pata sin confirmar — está verificada de punta a punta (lectura Y
escritura). Sigue sin decidirse formalmente entre Opción 1 sola (insuficiente,
confirmado) / Opción 1b (ahora completamente verificada) / Opción 2 (resuelve
todo de raíz pero con más superficie de cambio en CNN_training), pero la
Opción 1b ya no depende de ningún testbench pendiente — solo de que Angel
decida.

## Opciones para resolver (sin decidir acá — ACTUALIZAR el análisis de costo con la Parte 5 antes de decidir)

1. **Fix de hardware — calcular `ceil(Cin/16)` de verdad.** Cambiar
   `cin(6 downto 4)` por `(unsigned(cin) + 15) >> 4` (un sumador chico, sin
   DSP nuevo) en los dos archivos (`addr_generator.vhd`, `ddr_addr_gen.vhd`).
   Contenido a esos 2 puntos — mismo tipo de alcance que el fix de stride.
   No requiere cambios en el modelo entrenado ni en los pesos exportados.
   **Implementado y verificado (Parte 5) — pero por sí solo NO alcanza para
   tiles de más de 1 columna, ver Parte 5.**

2. **Pad por software — forzar `Cin`/`Cout` a múltiplos de 16 en toda la
   cadena, con canales sintéticos en cero.** El PS configuraría
   `REG_CIN`/`DMA_CIN` ya redondeados hacia arriba (`conv1`: 3→16,
   `irb3_exp`/`irb4_exp`: 24→32), y el pipeline de exportación de pesos
   (CNN_training) tendría que:
   - Agregar canales de entrada extra en cero al primer tensor de entrada
     (imagen/HSV, 3→16 canales) — los pesos de `conv1` para esos canales
     sintéticos pueden ser cualquier valor, nunca contribuyen porque el dato
     de entrada es 0.
   - Hacer que `irb2_pw`/`irb3_pw` escriban 32 canales de salida en vez de
     24 (8 sintéticos con peso 0 → salida siempre 0 tras cuantizar), para
     que `irb3_exp`/`irb4_exp` lean un `Cin=32` real y consistente con lo
     que efectivamente está en DDR.
   Sin cambios de RTL, pero con más superficie de cambio (toca el
   exportador de pesos de CNN_training en 3 capas productoras + 3
   consumidoras, y más tráfico DMA/DDR por los canales sintéticos).

2b. **Rellenar el empaquetado en DDR a múltiplo de 16 (Opción 1b, prototipo
    Parte 6, CONFIRMADA de punta a punta en la Parte 7)** — variante
    intermedia entre 1 y 2: `Cin`/`Cout` del modelo quedan tal cual (sin
    tocar pesos ni reentrenar), pero `row_stride_in`/`row_stride_out`/sus
    `term2` en `ddr_addr_gen.vhd` usan `cin_groups*16`/`cout_groups*16` en
    vez de `Cin`/`Cout` crudo — el DDR reserva el mismo relleno que ya se
    reserva on-chip. **Lado de escritura confirmado desde la Parte 6
    (Proto-H2); lado de lectura confirmado en la Parte 7** (requirió
    además dos fixes de RTL — zero-fill de `dma_fsm.vhd` y clamp de
    `sig_ci` en `addr_generator.vhd` — ya aplicados y validados contra la
    suite de regresión completa). Sigue pendiente resolver cómo llega
    paddeado el primer frame de `conv1` — ya no es un problema de hardware
    de captura (no hay MIPI en tiempo real, ver corrección de contexto más
    abajo), es un cambio de formato de salida en el código de Core 1 (HSV).

3. Alguna otra reconciliación no considerada todavía.

**Impresión propia, no vinculante — ACTUALIZADA tras la Parte 7:** con las
dos patas de la Opción 1b ya confirmadas (lectura y escritura) y los 2
fixes de RTL que hacían falta ya aplicados y verificados sin regresión, la
Opción 1b es ahora la vía con MENOS trabajo pendiente de las tres: no
requiere ningún testbench más, solo (a) decidir formalmente entre las 3
opciones y (b) si se elige 1b, implementar el padding de salida en el
código de Core 1 (software, no HW). La Opción 2 sigue siendo la que
resuelve todo con más certeza estructural (vuelve irrelevante la
distinción denso-vs-relleno) a cambio de más superficie de cambio en
CNN_training (6 capas de export). La Opción 1 sola (ya hecha) es necesaria
pero, confirmado, insuficiente por sí sola para las 5 capas en uso real.
Sigue sin decidirse acá — los tres costos ya están sobre la mesa, ahora
los tres con evidencia de simulación completa detrás.

## How to apply

Cualquier sesión (PL, PS o CNN_training) que retome este tema debe partir
de que:
- El bug original (`floor` vs `ceil`, Parte 1) está **arreglado y
  verificado** en los 3 sitios de fórmula — no hay que rehacer eso.
- El gap de empaquetado denso (Partes 5-6) es real, confirmado por
  simulación tanto en lectura (Caso G, Caso F2) como en escritura (Caso H2)
  — afecta a las **5 capas** (`conv1`, `irb2_pw`, `irb3_exp`, `irb3_pw`,
  `irb4_exp`), no soltar la idea de que el Caso F "ya probó que `conv1`
  está bien" — ese resultado era un falso negativo, corregido por el
  Caso F2.
- **RESUELTO (Parte 7):** el bug adicional que bloqueaba confirmar el lado
  de lectura de la Opción 1b (4to sitio de `floor`/`ceil` en el zero-fill
  de `dma_fsm.vhd` + bug de timing en `sig_ci` de `addr_generator.vhd`,
  NO relacionado con el empaquetado) está arreglado y verificado sin
  regresión contra la suite completa (A-H2). La Opción 1b queda confirmada
  de punta a punta — no hace falta rehacer ningún testbench para ella.
- Del lado PS, `generate_layer_table.py` (Paso 3 en adelante) sigue
  bloqueado para esas 5 capas **solo hasta que Angel decida** entre Opción
  1 sola (insuficiente, descartada) / Opción 1b (ya verificada de punta a
  punta) / Opción 2 (pad de canales, resuelve todo de raíz) — no falta
  ninguna verificación técnica más, solo la decisión. Las otras **23**
  capas de la tabla de 28 no están afectadas por nada de esto y se pueden
  diseñar ya. Las 8 capas adicionales que bloqueaba
  [[project_weight_words_overflow_gap]] (registro de 8 bits) ya están
  libres también — ver ese doc, RESUELTO.
- No rederivar nada de esto — leer las Partes 4, 5, 6 y 7 para el detalle
  y la evidencia de simulación exacta.
