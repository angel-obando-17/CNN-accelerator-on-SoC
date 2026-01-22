# BITACORA [ TRABAJO DE GRADO ]
---

En este archivo se busca llevar un registro del proceso que se tendra para realizar el trabajo de grado de forma que todo quede evidenciado, todos los requerimientos y lo que se llevara a cabo sera anotado en esta bitacora.

---

## BOARD ESCOGIDA

La board con la cual se trabajara a lo largo de este proceso, sera la *Puzhi 7020 Starlite Kit de evaluación Xilinx Zynq-7000 SoC XC7Z020 Placa de desarrollo FPGA ZYNQ 7000*, dicha placa se escogio principalmente por su costo, teniendo en cuenta que el proposito es trabajar con pequeños y medianos agricultores, no muchos cuentan con los recursos para adquirir hardware de mas capacidad, pero tambien se escogio ya que tiene un minimo de recursos para poder llevar a cabo la tarea principal que es la inferencia de redes neuronales convolucionales.


## ESPECIFICACIONES DE LA BOARD

* SoC Zynq 7020:
    + Arm Cortex-A9 MPCore de dos núcleos.
    + L1 Cache 32KB para Instrucciones, 32KB para Datos ( Por nucleo ).
    + L2 Cache 512KB.
    + Hasta 866 MHz.
    + 85k Celdas Logicas.
    + 4,9 Mb de BRAM.
    + 220 particiones de DSP.
    + 200 pines de E/S Maximos.
    + 53,2k LUTs.
    + 106,4k Flip-Flops.
* 512 MB de RAM DDR3.
* 64Kbit EEPROM.
* JTAG Downloader.
* SD Card Slot.
* MIPI CSI connector.
* $1$ $\times$ UART.
* $2$ $\times$ $40$ Pin Connector.

La placa tiene un precio de \$432.010 mas \$102.344,36 de envio en AliExpress que fue donde se adquirio.

## MODELOS DE CNN ESCOGIDAS

Como se menciono en las especificaciones de la board escogida, esta cuenta con recursos muy limitados dada las necesidades de los agricultores, teniendo en cuenta el hardware, entonces tambien se debe limitar los modelos CNN que se pueden montar en la board para que esta realice su tarea de inferencia de forma satisfactoria, por lo cual se opto por dos modelos, el primero es usando MobileNetV1 y en segundo caso un modelo propio que sera desarrollado desde cero para realizarlo a medida de las limitaciones con las cuales cuenta el hardware.

## LIMITACIONES DEL ACELERADOR

Dado que la placa tiene recursos muy limitados se necesita que la CNNs que se monten en el acelerador cumplan una serie de requisitos para que puedan ser ejecutadas de forma satisfactoria en la placa, algunas de estas fueron escogidas como diria el profe Carlos, por el criterio de Ingeniero, otras tienen una razon de ser, dichas limitaciones seran anumeradas a continuacion.

* Limitaciones a nivel de CNN ( Capas soportadas ):
    + Conv $3$ $\times$ $3$.
    + Conv $1$ $\times$ $1$.
    + Depthwise $3$ $\times$ $3$.
    + ReLU.
    + MaxPool $2$ $\times$ $2$.
    + Global Average Pool.
* Numero maximo de canales:
    + $C_{in} \leq 64$.
    + $C_{out} \leq 64$.
* Resolucion maxima de entrada de $96$ $\times$ $96$ o $128$ $\times$ $128$ con 3 canales RGB.
* Precision numerica de INT8, para los acumuladores INT32 y pesos cuantizados offline.
* Limitaciones a nivel de PL:
    + Un solo motor de convolucion, que sera reutilizado en el tiempo, dicho motor sera configurable por registros, y tendra modos Conv $3$ $\times$ $3$, Conv $1$ $\times$ $1$ y Depthwise $3$ $\times$ $3$.
    + Paralelismo moderado usando solo 8 o 16 MACs en paralelo.
    + BRAM solo para line buffers, Ventana $3$ $\times$ $3$, ping-pong buffers pequeños.
    + DDR como almacenamiento principal usandose para activaciones grandes y pesos por capa.
    + Usar una camara MIPI para la captura de imagenes.
* Pre-procesamiento:
    + Re-size a $96$ $\times$ $96$.
    + RGB.
    + Normalizacion simple.
    + Todo en INT8.

### Justificación de las limitaciones

Cada una de las limitaciones impuestas al acelerador responde a restricciones reales del hardware seleccionado, así como a criterios de eficiencia, reutilización y escalabilidad. Estas decisiones permiten implementar una arquitectura genérica, capaz de acelerar múltiples CNNs ligeras sin depender de un modelo específico, maximizando el aprovechamiento de los recursos del SoC.

## MACRO - ARQUITECTURA

```mermaid
flowchart TB
    %% =========================
    %% Processing System
    %% =========================
    subgraph PS["Processing System (PS)"]
        PS1["ARM Cortex-A9"]
        PS2["Software CNN<br/>(Control & Scheduler)"]
        PS3["Drivers<br/>DMA / AXI"]
        PS1 --> PS2
        PS2 --> PS3
    end

    %% =========================
    %% AXI Interconnect
    %% =========================
    AXI["Interconexión AXI"]

    %% =========================
    %% Programmable Logic
    %% =========================
    subgraph PL["Programmable Logic (PL)"]
        PL1["MIPI CSI RX"]
        PL2["Preprocesamiento"]
        PL3["Acelerador CNN"]
        PL1 --> PL2 --> PL3
    end

    %% =========================
    %% DDR Memory
    %% =========================
    subgraph DDR["DDR3 (512 MB)"]
        DDR1["Frames de cámara"]
        DDR2["Feature Maps"]
        DDR3["Pesos CNN"]
    end

    %% =========================
    %% Connections
    %% =========================
    PS --> AXI
    AXI --> PL
    PL --> DDR
    PS --> DDR
```