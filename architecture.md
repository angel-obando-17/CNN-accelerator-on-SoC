# PROBLEMAS ENCONTRADOS EN LA ARQUITECTURA V1.0

Durante el proceso de implementacion de la arquitectura del acelerador CNN se llego a un punto de desicion que no se tuvo en cuenta previamente, y es que no se definio el tamaño del bus que comunica loS Buffers con el MAC Array, el problema es que si se desea realizar un paralelismo eficiente en cada etapa entonces se encontro el siguiente escenario:

## CONV $3\times3$ y PW $1\times1$
Para el caso de la Conv $3\times3$ y PW $1\times1$ se tiene un paralelismo sobre $C_{out}$ ya que los 16 MACs calculan 16 canales de salida al mismo tiempo, donde cada MAC utiliza un peso diferente por lo que para que el [ Weight Buffer ] sea capaz de mandar los 16 pesos, necesita tener un bus de 128 bits si o si, mientras que todos los 16 MACs utilizan el mismo IFM, por lo que con un bus de 8 bits es suficiente para mandar el IFM a los 16 MACs.

## DW $3\times3$
Para el caso de DW $3\times3$ se tiene un paralelismo sobre $C_{in}$ ya que los 16 MACs calculan 16 canales de entrada al mismo tiempo, cada MAC usa un weight distinto y un IFM distinto, por lo que para este caso es necesario que el     [ IFBuffer ] debe ser capaz de mandar el byte correspondiente a cada MAC, lo que nos da que necesita un bus de 128 bits.

El inconveniente es exactamente ese, que el bus del IFBuffer debe ser de 128 bits porque DW $3\times3$ lo exige de esa manera, pero para Conv $3\times3$ y para PW $1\times1$ solo se usaria 1 byte de los 16 disponibles. Para poder realizar esta implementacion se decidio utilizar una señal llamada byte_sel, la cual sera de 4 bits, esto para poder decirle al IFBuffer cual de los 16 bytes del word pasarle a los MACs en esos dos modos.

---

## BLOQUES DESCARTADOS DE LA ARQUITECTURA ORIGINAL

En el diseño inicial de la arquitectura del acelerador se habian contemplado dos bloques para manejar el acceso a los datos de entrada en los modos de convolucion $3 \times 3$: el [ Line Buffer ] y el [ Window Generator ]. Durante el proceso de implementacion del [ Address Generator ] se encontro que ambos bloques eran innecesarios, y se tomo la decision de descartarlos definitivamente. A continuacion se explica el razonamiento detras de esta decision para cada uno.

### Window Generator

El proposito original del [ Window Generator ] era recibir las filas organizadas por el [ Line Buffer ] y ensamblarlas en una ventana de $3 \times 3$ para entregarla al [ MAC Array ], de forma que cada MAC supiera exactamente con que pixel debia trabajar en cada ciclo.

Este bloque se descarto porque el [ Address Generator ] ya implementa implicitamente la logica de ventana deslizante. Su inner loop itera sobre los offsets del kernel $k_x \in \{0, 1, 2\}$ y $k_y \in \{0, 1, 2\}$, calculando en cada ciclo la direccion exacta del elemento correspondiente en el [ IFBuffer ]:

$addr\_in = (y + k_y - 1) \times TILE\_W \times G_{in} + (x + k_x - 1) \times G_{in} + \lfloor c_i / 16 \rfloor$

Esto significa que no hay ninguna ventana que "ensamblar" fisicamente. El MAC recibe un elemento a la vez y lo acumula en su acumulador. Los $3 \times 3 \times C_{in}$ elementos de la ventana llegan de forma secuencial ciclo a ciclo, sin necesidad de un bloque intermedio que los organice.

### Line Buffer

El proposito original del [ Line Buffer ] era guardar 3 filas completas del feature map en BRAM para evitar lecturas recurrentes de memoria al acceder a la vecindad espacial $3 \times 3$ de un pixel. La idea era que, dado que una convolucion $3 \times 3$ necesita las filas $y-1$, $y$ e $y+1$, era mas eficiente tenerlas pre-cargadas en un buffer intermedio antes de pasarlas al [ Window Generator ].

Este bloque tambien se descarto porque el [ IFBuffer ] ya almacena el tile completo de $128 \times 8$ pixeles con todos sus canales. El tile por definicion contiene todas las filas necesarias para procesar cualquier pixel dentro de el, incluyendo su vecindad $3 \times 3$. Dado que el BRAM tiene una latencia de acceso de exactamente 1 ciclo a cualquier direccion, el [ Address Generator ] puede calcular directamente la direccion de cualquier elemento del vecindario y el [ IFBuffer ] lo entrega en el siguiente ciclo sin ninguna penalizacion adicional. El tile cumple exactamente el rol que el [ Line Buffer ] pretendia cumplir, sin requerir un bloque separado ni logica adicional.

---

## CALCULO DE DIRECCIONES EN EL HARDWARE

Para entender como es que el [ Address Generator ] computa cada direccion, primero hay que entender como estan organizados los datos en la BRAM. Tanto el [ IFBuffer ] como el [ Weight Buffer ] y el [ Output Buffer ] usan palabras de 128 bits ( 16 bytes ), lo que significa que en una sola lectura se obtienen 16 valores INT8 al mismo tiempo. Esto es lo que permite el paralelismo de 16 MACs, ya que en cada ciclo cada MAC recibe su propio dato sin necesidad de hacer lecturas separadas. Con eso claro, las formulas que calcula el bloque son direcciones de palabras, no de bytes.

### IFBuffer — $addr\_in$

El [ IFBuffer ] almacena los feature maps de entrada en formato $HWC$, es decir, primero la fila, luego la columna, y luego los canales. Dado que el bus es de 128 bits, los canales se agrupan de a 16, entonces una palabra del IFBuffer corresponde a los 16 canales del mismo pixel. Definiendo $G_{in} = \lfloor C_{in} / 16 \rfloor$ como el numero de grupos de canales, la posicion de una palabra en el IFBuffer queda determinada por su fila, su columna y su grupo de canales.

Para Conv $3 \times 3$ y PW $1 \times 1$, todos los 16 MACs computan canales de salida distintos pero sobre la misma activacion, entonces lo que necesitamos es un unico byte de la palabra. La fila que se accede en el tile depende de la posicion espacial $y$ mas el offset del kernel $k_y$, y lo mismo para la columna, entonces:

$addr\_in = (y + k_y - 1) \times TILE\_W \times G_{in} + (x + k_x - 1) \times G_{in} + \lfloor c_i / 16 \rfloor$

$byte\_sel = c_i \bmod 16$

Donde $y$ es el $y\_counter$, $x$ es el $x\_counter$, $k_y$ y $k_x$ son los offsets del kernel ( que van de $0$ a $2$ para convoluciones $3 \times 3$ ), y $c_i$ es el canal de entrada actual. El termino $\lfloor c_i / 16 \rfloor$ selecciona la palabra que contiene ese canal, y $byte\_sel$ le dice al IFBuffer cual de los 16 bytes de esa palabra debe pasarle a los MACs. En hardware esto es simplemente tomar $c_i[6:4]$ para la direccion y $c_i[3:0]$ para el $byte\_sel$, ya que $C_{in} \leq 64$ cabe en 7 bits.

Para DW $3 \times 3$ el caso es distinto, ya que cada MAC procesa un canal de entrada diferente, entonces los 16 MACs necesitan los 16 bytes de la misma palabra. El grupo que se accede no viene de $c_i$ sino del $co\_counter$, que indica en que grupo de 16 canales estamos en este momento:

$addr\_in = (y + k_y - 1) \times TILE\_W \times G_{in} + (x + k_x - 1) \times G_{in} + co\_counter$

En este modo $byte\_sel$ no se usa ya que todos los bytes de la palabra van directo a cada MAC.

### Weight Buffer — $addr\_w$

Para que la lectura del [ Weight Buffer ] sea tambien de 128 bits en un solo ciclo, los pesos deben estar organizados en memoria de forma que en cada palabra queden los 16 pesos correspondientes a los 16 canales de salida del co_group actual, todos en la misma posicion del kernel $(c_i, k_y, k_x)$. Dicho de otra forma, la palabra en la direccion $addr\_w$ contiene:

$\{w[co\_counter \times 16 + 0], \, w[co\_counter \times 16 + 1], \, \ldots, \, w[co\_counter \times 16 + 15]\}$

todos evaluados en la misma posicion de kernel. Bajo esa organizacion, las formulas quedan:

Para Conv $3 \times 3$:

$addr\_w = co\_counter \times C_{in} \times 9 + c_i \times 9 + k_y \times 3 + k_x$

Para DW $3 \times 3$:

$addr\_w = co\_counter \times 9 + k_y \times 3 + k_x$

Para PW $1 \times 1$:

$addr\_w = co\_counter \times C_{in} + c_i$

Cada formula avanza primero por los co_groups, luego por los elementos del inner loop, lo que hace que al incrementar los contadores internos ( $c_i$, $k_y$, $k_x$ ) la direccion simplemente suba de uno en uno, sin saltos. Esto es importante porque significa que el [ Weight Buffer ] se lee secuencialmente dentro de cada pixel, lo que es ideal para una BRAM.

El peor caso en terminos de numero de palabras es PW $1 \times 1$ con $C_{in} = C_{out} = 64$:

$addr\_w^{max} = 3 \times 64 + 63 = 255 \text{ palabras} = 255 \times 16 \approx 4 \text{ KB}$

El bus de $addr\_w$ es de 12 bits, lo que soporta hasta $4096$ palabras, por lo que hay margen suficiente para todas las capas de MobileNetV2.

### Output Buffer — $addr\_out$

El [ Output Buffer ] tambien usa palabras de 128 bits, y almacena los feature maps de salida en formato $HWC$ agrupando de a 16 canales de salida por palabra. Definiendo $G_{out} = max\_co + 1$ como el numero de grupos de canales de salida, la direccion de escritura es:

$addr\_out = y \times TILE\_W \times G_{out} + x \times G_{out} + co\_counter$

Aqui $y$ y $x$ son los contadores espaciales del tile actual, y $co\_counter$ indica a cual de los grupos de 16 canales de salida estamos escribiendo en este momento. El resultado es que la escritura tambien es secuencial dentro de cada pixel, lo cual al igual que en el Weight Buffer es beneficioso para la BRAM.

---

## BLOQUE [ quant_relu ]

### Que hace el bloque

El [ quant_relu ] es el bloque de post-procesamiento que toma los 16 acumuladores INT32 que salen del [ Accumulator Bank ] y los convierte en 16 valores INT8 listos para ser escritos en el [ Output Buffer ]. Hace tres cosas en secuencia sobre cada uno de los 16 valores en paralelo, con una latencia de 1 ciclo de reloj.

### Por que se cuantiza primero y luego se aplica ReLU6

El orden correcto es primero cuantizar ( shift + clamp ) y luego aplicar ReLU6. Esto es porque ReLU6 trabaja sobre valores ya en escala INT8, necesitando comparar contra $0$ y contra el valor cuantizado de $6.0$. Si se aplicara ReLU6 antes del shift, se estaria comparando un valor INT32 gigante contra umbrales INT8, lo cual no tiene ningún sentido en terminos de la escala de los datos.

### Paso 1 — Shift aritmetico derecho

El acumulador INT32 contiene la suma de muchos productos INT8 $\times$ INT8. Ese valor esta "escalado", es decir, su magnitud es mucho mayor de lo que deberia ser en INT8. Formalmente, si los pesos tienen scale $S_w$ y las activaciones tienen scale $S_a$, entonces el acumulador esta en escala $S_w \times S_a$, mientras que el resultado de salida debe estar en escala $S_{out}$. Para pasar de una escala a la otra se hace un desplazamiento aritmetico a la derecha:

$resultado = acumulador \gg shift$

Donde $shift$ es la cantidad de bits a desplazar, calculada como:

$shift = \log_2 \left( \frac{S_w \times S_a}{S_{out}} \right)$

Es importante que el desplazamiento sea **aritmetico** ( no logico ), ya que los valores pueden ser negativos y hay que preservar el signo. El PS conoce todos los scale factors de cada capa porque los extrae del modelo cuantizado durante la calibracion offline, calcula el valor de $shift$ para cada capa, y lo escribe en el registro REG_SHIFT por AXI-Lite antes de lanzar el acelerador. El hardware no sabe nada de scales ni de floating point, solo recibe el numero entero y desplaza.

### Paso 2 — Clamp a INT8

Despues del shift el valor deberia caber en INT8, pero por efectos de saturacion puede salirse del rango $[-128, 127]$. El clamp se hace **antes de truncar los bits**, comparando el valor INT32 desplazado contra los limites:

* Si el valor $> 127$ entonces se satura a $127$.
* Si el valor $< -128$ entonces se satura a $-128$.
* Si el valor esta dentro del rango, se trunca normalmente a 8 bits.

### Paso 3 — ReLU6

ReLU6 es una variante de ReLU que ademas de poner en cero los valores negativos, los limita por arriba en $6.0$. En INT8, el valor $6.0$ no es siempre el numero $6$, ya que depende del scale factor de la capa. Por eso existe el puerto $relu6\_val$ que recibe el valor cuantizado de $6.0$ para esa capa especifico, calculado por el PS y enviado por AXI-Lite antes de lanzar el acelerador. La logica es:

* Si $clamped < 0$ entonces la salida es $0$.
* Si $clamped > relu6\_val$ entonces la salida es $relu\_in$.
* Si $0 \leq clamped \leq relu6\_val$ entonces la salida es $clamped$.

Si $relu\_en = 0$ entonces se omite este paso y el valor clampedo pasa directo como salida.

### Latencia y paralelismo

El bloque procesa los 16 canales en paralelo dentro de un unico proceso sincrono, por lo que la latencia total es de exactamente 1 ciclo de reloj. Un ciclo despues de que $quant\_en = 1$, los 16 valores INT8 estan disponibles en $data\_out$ y la señal $valid\_out = 1$, que es la que usa la FSM como $post\_done$ para saber que puede avanzar al siguiente estado.

---

## BLOQUE [ pool_unit ]

### Estructura modular

El bloque de pooling se decidio implementar de forma modular en tres archivos separados: [ max\_pool ], [ gap\_unit ] y [ pool\_unit ]. Los primeros dos implementan cada operacion por separado, y el tercero es un wrapper que instancia ambos y selecciona la salida correcta mediante multiplexores controlados por la señal $pool\_type\_sel$. Esta decision de diseño se tomo para mantener cada archivo enfocado en una sola responsabilidad, lo que facilita entender, verificar y modificar cada operacion de forma independiente.

### Decision clave: pool y residual nunca coexisten en MobileNetV2

Revisando la tabla de capas de MobileNetV2, se encontro que las capas con residual connection siempre tienen $stride = 1$ ( sin reduccion espacial ), mientras que las capas con pooling siempre tienen $stride = 2$ ( con reduccion espacial ). Esto significa que $reg\_pool\_en = 1$ y $reg\_has\_residual = 1$ nunca ocurren al mismo tiempo, lo que simplifica significativamente el multiplexor antes del [ OFBuffer ]: solo necesita dos entradas controladas por $pool\_act$.

---

## BLOQUE [ max\_pool ]

### Como funciona MaxPool $2 \times 2$

MaxPool $2 \times 2$ con stride $2$ toma una ventana de $2 \times 2$ pixeles y se queda con el maximo de cada canal, reduciendo las dimensiones espaciales a la mitad. Con el orden de traversal del [ Address Generator ] ( $co \rightarrow x \rightarrow y$ ), los pixeles llegan en el orden: todos los co\_groups de $(x=0, y=0)$, luego $(x=1, y=0)$, etc. Para hacer MaxPool $2 \times 2$ entonces se necesitan dos etapas de comparacion:

* **Comparacion horizontal**: comparar pixel en $x$ par con pixel en $x$ impar, canal por canal, para obtener el maximo horizontal $h\_max$.
* **Comparacion vertical**: comparar $h\_max$ de la fila $y$ par con $h\_max$ de la fila $y$ impar, para obtener el maximo final de la ventana $2 \times 2$.

### Hardware interno del MaxPool

Para implementar estas dos etapas se necesitan tres elementos internos:

* **Banco de registros $x\_even\_reg$**: 4 registros de 128 bits ( uno por co\_group ) donde se guardan los pixeles en posicion $x$ par. Cuando llega el pixel $x$ impar correspondiente, se compara con el registro para obtener $h\_max$. Vivado infiere estos 4 registros como Distributed RAM ( 128 LUTs ).

* **Row buffer (BRAM)**: una BRAM de 256 palabras $\times$ 128 bits que guarda los maximos horizontales de la fila $y$ par. Cuando se procesa la fila $y$ impar, se lee el row buffer para comparar y obtener el maximo final de la ventana. La direccion de acceso al row buffer es $\lfloor x/2 \rfloor \times (max\_co + 1) + co\_counter$. Vivado infiere esto como 2 RAMB36.

* **Pipeline de 2 etapas**: dado que el BRAM tiene 1 ciclo de latencia de lectura, cuando se detecta la condicion $x$ impar, $y$ impar, se registran $h\_max$ y la direccion de salida en un ciclo ( etapa 1 ), y en el ciclo siguiente el dato del row buffer ya esta disponible para hacer la comparacion final y escribir en el [ OFBuffer ] ( etapa 2 ).

### Direccion de escritura al OFBuffer en MaxPool

La salida de MaxPool tiene dimensiones espaciales reducidas a la mitad. La direccion de escritura al [ OFBuffer ] es:

$addr\_out\_pool = \lfloor y/2 \rfloor \times (TILE\_W / 2) \times G_{out} + \lfloor x/2 \rfloor \times G_{out} + co\_counter$

En hardware esto se implementa tomando directamente los bits superiores de los contadores: $y[2:1]$ para $\lfloor y/2 \rfloor$ y $x[6:1]$ para $\lfloor x/2 \rfloor$, sin necesidad de divisiones. Esta direccion la calcula el bloque [ max\_pool ] internamente, sin modificar el [ Address Generator ].

---

## BLOQUE [ gap\_unit ]

### Como funciona Global Average Pool

El Global Average Pool ( GAP ) calcula el promedio de todos los pixeles espaciales para cada canal, produciendo una salida de $1 \times 1 \times C_{out}$. Para MobileNetV2, el GAP se aplica sobre una entrada de $16 \times 16 \times 64$, es decir, se promedian $256$ pixeles por canal.

### Hardware interno del GAP

El bloque mantiene un banco de acumuladores INT32: 4 co\_groups $\times$ 16 canales $\times$ 32 bits $= 2048$ bits en total, implementados como registros ( FFs ). Durante el procesamiento normal ( estado POST de la FSM ), el bloque va acumulando las salidas del [ quant\_relu ] en los acumuladores correspondientes al co\_group activo. Cuando se detecta $layer\_done = 1$, todos los acumuladores tienen la suma completa de todos los pixeles.

Una vez terminada la acumulacion, el bloque entra en fase de escritura: en ciclos consecutivos escribe un co\_group por ciclo al [ OFBuffer ], aplicando el shift aritmetico y clamp antes de escribir. La direccion de escritura es simplemente $co\_write\_cnt$ ( los valores $0, 1, 2, 3$ ), ya que la salida GAP es un tensor de $1 \times 1 \times C_{out}$.

### Calculo del promedio

El promedio en hardware se implementa como un desplazamiento aritmetico a la derecha por $gap\_shift$ bits, que el PS calcula como $\log_2(H \times W)$ antes de lanzar la capa. Para MobileNetV2 con entrada $16 \times 16$: $gap\_shift = \log_2(256) = 8$, lo que equivale a dividir por $256$ simplemente tomando los bits $[15:8]$ del acumulador.

### Cambio en la FSM principal: estado FLUSH

Dado que el GAP solo puede escribir sus resultados despues de procesar todos los pixeles ( cuando $layer\_done = 1$ ), la FSM principal no puede ir directamente a DONE como en los demas casos. Se agrego el estado **FLUSH** a la FSM, al cual se entra cuando $post\_done = 1$, $layer\_done = 1$ y la capa es de tipo GAP ( $reg\_pool\_en = 1$ y $reg\_pool\_type = 1$ ). En FLUSH la FSM espera hasta que $gap\_done = 1$, señal que genera el [ gap\_unit ] cuando termina de escribir todos los co\_groups al [ OFBuffer ]. Despues de eso, la FSM avanza a DONE y genera el IRQ hacia el PS.

Para MobileNetV2 con $C_{out} = 64$ ( 4 co\_groups ), el estado FLUSH dura exactamente 5 ciclos de reloj antes de avanzar a DONE.

---

## BUGS DE TIMING ENCONTRADOS Y CORREGIDOS EN V1.0

Durante la verificacion en simulacion de la arquitectura V1.0 se encontraron cinco problemas de timing que causaban resultados incorrectos. Todos se manifestaban como valores erroneos en el OFBuffer al finalizar el calculo. A continuacion se documenta cada uno: cual era el problema, por que ocurria y como se corrigio.

### Bug 1 — Los MACs acumulaban el dato del ciclo anterior

**Problema**: los resultados del MAC array eran incorrectos porque cada MAC estaba acumulando los datos de activacion y peso del ciclo previo, no del ciclo actual.

**Por que ocurria**: el [ IFBuffer ] y el [ Weight Buffer ] son BRAMs con 1 ciclo de latencia de lectura. El [ Address Generator ] presenta las direcciones en el ciclo en que `addr_en = 1`, pero el dato no esta disponible hasta el ciclo siguiente. La FSM activaba `mac_en` exactamente 1 ciclo despues de `addr_en`, pensando que el dato ya estaba listo. El problema es que `weight_arr` y `mux_act_out` son señales combinacionales que reflejan el dato del ciclo de BRAM anterior, no el actual.

**Solucion**: se agregaron dos registros de pipeline en `cnn_accelerator.vhd`, `weight_reg` y `act_reg`, que capturan los datos cuando `sig_addr_en = 1`. El MAC array se conecta a estos registros en lugar de a las señales combinacionales directas. De esta manera, cuando `mac_en = 1` en el ciclo siguiente, los registros contienen exactamente el dato que la BRAM entrego en ese ciclo.

### Bug 2 — Escrituras multiples al OFBuffer por cada pixel

**Problema**: se escribia el mismo resultado mas de una vez en la misma direccion del OFBuffer, lo que no era un problema de correccion en este caso (el dato era el mismo), pero en capas con residual o pool podia generar escrituras incorrectas y causaba confusion en simulacion.

**Por que ocurria**: la señal `ofbuf_wr_en` estaba conectada directamente a `quant_valid`. El bloque [ quant\_relu ] mantiene `quant_valid = 1` durante todo el estado POST de la FSM, que dura varios ciclos. Esto generaba multiples flancos de escritura a la misma direccion mientras la FSM permanecia en POST.

**Solucion**: se agrego la señal `quant_valid_prev` que registra el valor anterior de `quant_valid`. La señal de escritura se convirtio en `quant_valid AND (NOT quant_valid_prev)`, lo que genera un pulso de exactamente 1 ciclo en el flanco de subida de `quant_valid`. Solo hay una escritura por resultado.

### Bug 3 — La direccion de escritura al OFBuffer ya habia avanzado

**Problema**: los datos se escribian en la direccion incorrecta del OFBuffer. Los pixeles terminaban en posiciones desplazadas.

**Por que ocurria**: la direccion `ofbuf_wr_addr` estaba conectada directamente a `ag_addr_out`. En el momento en que `quant_valid` se activa (estado POST), el [ Address Generator ] ya calculo las direcciones del siguiente pixel y `ag_addr_out` apunta a una direccion distinta a la del pixel que acaba de terminar de computarse.

**Solucion**: se agrego el registro `ofbuf_wr_addr_reg` que captura `ag_addr_out` cuando `sig_acc_bank_en = 1` (estado LATCH), que es el ciclo exacto en que el pixel termina de acumularse. Esa direccion capturada es la que se usa para la escritura posterior en POST.

### Bug 4 — El contador interno del Address Generator desbordaba

**Problema**: en algunos casos el [ Address Generator ] generaba mas iteraciones de las debidas para un pixel, produciendo accesos fuera de rango en los buffers.

**Por que ocurria**: el contador `sig_inner_cnt` se incrementaba incondicionalmente en cada ciclo del estado ACCUM, sin verificar si ya habia alcanzado `max_inner`. En el caso limite, cuando `sig_inner_cnt = max_inner`, el contador incrementaba una vez mas antes de que la transicion a PIXEL\_END ocurriera, causando que en la ultima iteracion se accediera a una direccion mas alla del final del kernel.

**Solucion**: se agrego una guarda `if sig_inner_cnt < max_inner` alrededor del incremento, de forma que el contador satura al llegar al maximo y no puede desbordarse.

### Bug 5 — pixel\_done no se levantaba en el ciclo de transicion a PIXEL\_END

**Problema**: la señal `pixel_done` del [ Address Generator ] llegaba tarde a la FSM principal, causando que esta procesara un ciclo extra antes de avanzar al siguiente estado.

**Por que ocurria**: `pixel_done` se asignaba en el estado PIXEL\_END, pero la transicion `next_state <= PIXEL_END` y la asignacion de `pixel_done` ocurrian en el mismo ciclo. Como `pixel_done` era una salida combinacional que depende del `current_state`, no estaba activa en el ciclo en que se evaluaba la condicion `sig_inner_cnt = max_inner`, sino en el ciclo siguiente, cuando ya se habia entrado a PIXEL\_END.

**Solucion**: se agrego `pixel_done <= '1'` directamente en el bloque de la condicion `if sig_inner_cnt = max_inner`, antes de asignar `next_state <= PIXEL_END`. Asi la señal se activa en el mismo ciclo que se toma la decision de transicion.

---

## CORRECCIONES EN LA FSM PRINCIPAL ( fsm\_cnn\_acc )

Ademas de los bugs en el datapath, se identificaron tres problemas en las señales de control de la FSM principal que causaban comportamiento incorrecto al inicio de cada capa y en la transicion entre estados.

### mac\_clear faltante en IDLE

En el estado IDLE la FSM levantaba `acc_clear` para limpiar el [ Accumulator Bank ], pero no levantaba `mac_clear`, lo que significa que los acumuladores individuales de los MACs podian conservar valores residuales de una capa anterior. Se agrego `mac_clear <= '1'` tambien en IDLE.

### addr\_en faltante en LATCH

En el estado LATCH la FSM levantaba `acc_bank_enable` y `mac_clear`, pero no activaba `addr_en`. Esto significaba que durante el ciclo de LATCH el [ Address Generator ] no estaba generando la direccion de salida necesaria para que `ofbuf_wr_addr_reg` pudiera capturarla correctamente. Se agrego `addr_en <= '1'` en LATCH para que el address generator produzca la direccion en ese ciclo.

### addr\_en faltante en POST

Durante el estado POST ( ReLU + cuantizacion + add residual ), el [ Address Generator ] necesita tener `addr_en` activo para que las señales de control derivadas de el ( como `ag_addr_out` ) sean validas. Sin esto, las señales de residual y add no apuntaban a las posiciones correctas. Se agrego `addr_en <= '1'` en POST.

---

## MAC ARRAY — PIPELINE DEL DSP48

### Separacion de multiplicacion y acumulacion

En la implementacion original, la operacion del MAC era `accumulator <= accumulator + (weight * act)` dentro de un unico proceso sincrono. Vivado sintetiza esto como un DSP48 con la multiplicacion y la acumulacion en el mismo ciclo de reloj, lo que puede causar problemas de timing a frecuencias altas porque el camino critico incluye tanto el multiplicador como el sumador del acumulador.

Se extrajo el producto como una señal combinacional separada:

```
product <= weight * act;
...
accumulator <= accumulator + resize( product, 32 );
```

Esto le da al sintetizador mas flexibilidad para inferir el pipeline interno del DSP48 correctamente, separando la etapa de multiplicacion de la etapa de acumulacion.

---

## BUG 6 — mac_valid fantasma en transiciones de estado del AG ( corregido 2026-06-25 )

### Problema

El primer pixel de cualquier capa producía un resultado incorrecto en el OFBuffer mientras que los pixeles siguientes salían bien. En el test multilayer, con Capa 3 PW1x1 all-nines y residual all-ones, `OFBuffer[0]` guardaba `0x0B` en lugar de `0x0A`.

### Por que ocurria

El proceso combinacional de `fsm_addr_generator.vhd` define `mac_valid <= '1'` como default. Esto aplica a todos los estados que no tienen un override explícito: IDLE, PIXEL_END y LAYER_CHECK.

Se identificaron dos escenarios donde este default causaba una acumulacion fantasma:

**Escenario 1 — Inicio de capa (IDLE → COMPUTE):**

Cuando la FSM principal transiciona IDLE→COMPUTE (flanco de `reg_start`), el `fsm_addr_generator` tarda exactamente 1 ciclo extra en seguirla, porque lee `addr_en = 0` (salida de IDLE) en el mismo flanco de transición y permanece en IDLE hasta el ciclo siguiente. Sin embargo, entre ese primer flanco y el siguiente, la FSM principal ya está en COMPUTE con `mac_en = mac_valid`. Como el AG sigue en IDLE y el default es `mac_valid = '1'`, el MAC acumula una vez con los registros `weight_reg` y `act_reg` rancios de la capa anterior.

En el test concreto: la capa anterior era DW3x3 con `act_reg = 0x10 = 16` y `weight_reg = 0x01`. Producto fantasma = 16. Acumulación total = 16 + 144 = 160. Cuantización: `160 >> 4 = 10 = 0x0A`. Con residual 0x01: `0x0B`. ✗

**Escenario 2 — Frontera de pixel (POST → COMPUTE entre pixeles):**

Al terminar cada pixel, la FSM principal va POST→COMPUTE mientras el AG va LAYER_CHECK→ACCUM. En el primer flanco de COMPUTE, el AG está todavía en LAYER_CHECK con `mac_valid = '1'` por default, causando otra acumulación fantasma. En el test actual el producto fantasma era 9 (datos ya correctos), el total quedaba `9 + 144 = 153`, y `153 >> 4 = 9`, que coincidía con el resultado esperado. El bug existía pero su efecto era invisible.

### Solucion

Se agregaron dos overrides explícitos en `fsm_addr_generator.vhd`:

```vhdl
when IDLE =>
    counter_reset <= '1';
    mac_valid     <= '0';   -- evita fantasma en transicion IDLE → COMPUTE
    ...

when LAYER_CHECK =>
    pixel_done <= '1';
    mac_valid  <= '0';   -- evita fantasma en transicion POST → COMPUTE
    ...
```

Con esto `mac_valid = '1'` solo cuando el AG está en ACCUM con `sig_inner_cnt > 0`, que es el único momento en que el dato del buffer es válido y debe acumularse.

---

### Atributo use\_dsp en archivo de constraints

El atributo `use_dsp` que fuerza la inferencia del DSP48 se movio de `mac.vhd` a un archivo de constraints de sintesis separado ( `.xdc` ). Esto mantiene el archivo VHDL limpio de directivas de sintesis especificas de Vivado, que no forman parte del comportamiento del circuito sino de como se implementa en el dispositivo.
