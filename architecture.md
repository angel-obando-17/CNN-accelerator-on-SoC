# PROBLEMAS ENCONTRADOS EN LA ARQUITECTURA V1.0

Durante el proceso de implementacion de la arquitectura del acelerador CNN se llego a un punto de desicion que no se tuvo en cuenta previamente, y es que no se definio el tamaño del bus que comunica loS Buffers con el MAC Array, el problema es que si se desea realizar un paralelismo eficiente en cada etapa entonces se encontro el siguiente escenario:

## CONV $3\times3$ y PW $1\times1$
Para el caso de la Conv $3\times3$ y PW $1\times1$ se tiene un paralelismo sobre $C_{out}$ ya que los 16 MACs calculan 16 canales de salida al mismo tiempo, donde cada MAC utiliza un peso diferente por lo que para que el [ Weight Buffer ] sea capaz de mandar los 16 pesos, necesita tener un bus de 128 bits si o si, mientras que todos los 16 MACs utilizan el mismo IFM, por lo que con un bus de 8 bits es suficiente para mandar el IFM a los 16 MACs.

## DW $3\times3$
Para el caso de DW $3\times3$ se tiene un paralelismo sobre $C_{in}$ ya que los 16 MACs calculan 16 canales de entrada al mismo tiempo, cada MAC usa un weight distinto y un IFM distinto, por lo que para este caso es necesario que el     [ IFBuffer ] debe ser capaz de mandar el byte correspondiente a cada MAC, lo que nos da que necesita un bus de 128 bits.

El inconveniente es exactamente ese, que el bus del IFBuffer debe ser de 128 bits porque DW $3\times3$ lo exige de esa manera, pero para Conv $3\times3$ y para PW $1\times1$ solo se usaria 1 byte de los 16 disponibles. Para poder realizar esta implementacion se decidio utilizar una señal llamada byte_sel, la cual sera de 4 bits, esto para poder decirle al IFBuffer cual de los 16 bytes del word pasarle a los MACs en esos dos modos.

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
