# ANALSIS DE RESULTADOS DE ENTRENAMIENTO

Para validar las restricciones impuestas en el acelerador, sobre la resolucion de imagenes y la cuantizacion a INT8, se desarrollo el modelo de CNN que tendra la tarea de indentificar enfermedades en una planta de tomate, para esto se empleo el database de PlantVillage alojado en Kaggle, link = "https://www.kaggle.com/datasets/emmarex/plantdisease/data".

## ESTRATEGIA DE VALIDACIÓN

Para hacer una analisis completo y detallado de que ocurre en distintos escenarios y asi ver que posibles resultados obtener se planteo el siguiente esquema:

* Realizar entrenamientos del modelo en $3$ resoluciones distintas, las cuales son [ $256$ $\times$ $256$, $128$ $\times$ $128$, $96$ $\times$ $96$ ].
* Para cada entrenamiento obtenido anteriormente se realizan las siguientes cuantizaciones [ "float32", "int16", "int8" ].
* En cada cuantizacion obtenida se usan como metricas el accuracy y confussion matrix.

## IMPLEMENTACION

Para poder realizar una correcta implementacion del modelo, primero se necesitaba balancear el database, ya que para cada una de las clases habia muestras muy disparejas, originalmente el database contaba con $10$ clases, las cuales eran:

* Tomato_Bacterial_Spot.
* Tomato_Early_Blight.
* Tomato_Late_Blight.
* Tomato_Leaf_Mold.
* Tomato_Septoria_Leaf_Spot.
* Tomato_Spider_Mites_Two_Spotted_Spider_Mite.
* Tomato__Target_Spot.
* Tomato__Tomato_YellowLeaf__Curl_Virus.
* Tomato__Tomato_Mosaic_Virus.
* Tomato_Healthy.

Se tomo la desicion de descartar la clase "Tomato__Tomato_Mosaic_Virus" debido a que tenia significativamente muchas menos muestras que las demas clases, y tomar esta clase como referencia para el balance provocaria una perdida enorme de informacion de las demas clases, obteniendo un entrenamiento muy pobre, por lo tanto se decidio eliminarlo definitivamente.

Despues de esto entonces se tomo como clase referencia la clase "Tomato_Leaf_Mold" la cual tenia un total de $952$ muestras, por lo que todas las demas clases debian ser recortadas hasta obtener este mismo numero de muestras, pero antes de hacer eso, se decicio con ayuda de un script en python tomar 48 muestras aleatorias de la clase "Tomato_Leaf_Mold" y aplicarle ciertas transforamciones muy poco invasivas, ya sean como hacer espejo, cambiar algunos tonos de luz o rotar un poco las imagenes, esto con el proposito de alcanzar $1000$ muestras para esta clase, de esta forma entonces, cada clase debia recortarse a $1000$ muestras.

Una vez que el dataset fue balanceado, entonces ahora si se procedio a realizar el script en python que realizaria las siguientes tareas:

* Segmentacion de las imagenes utilizando el metodo de "grabCut" de la libreria OpenCV disponible para python.
* Una vez con las imagenes segmentadas, entonces se procede a realizar el primer entrenamiento con las imagenes en su resolucion original, la cual es de $256$ $\times$ $256$. 
* Una vez que el modelo haya terminado de entrenarse, entonces se exportaron los pesos obtenidos en su formato original de "float32".
* Se procede a validar el modelo con su cunatizado original, se mide accuracy y se obtiene la confussion matrix.
* Se procede a cuantizar el modelo a "int8", se mide accuracy y se obtiene la confussion matrix.
* Se procede a cuantizar el modelo a "int16", se mide el accuracy y se obtiene la confussion matrix.
* Esto se repite para cada otra de las resoluciones, es decir para [ $128$ $\times$ $128$, $96$ $\times$ $96$ ].

En cuanto al modelo CNN implementado, como ya se menciono anteriormente, se utilizo el modelo de MobileNetV1, pero personalizado para que utilice las capas soportadas por el acelerador que se desea implementar, por lo que solo consiste en capas de convolucion normal $3$ $\times$ $3$, DepthWise $3$ $\times$ $3$, PointWise $1$ $\times$ $1$, MaxPool $2$ $\times$ $2$ y Global Average Pool, tambien se limitaron los strides a [ $1$, $2$ ].

Tambien se implemento un sistema que midiera el tiempo que se tardo en cada etapa del proceso, desde que se cargaron las imagenes, segmentado las imagenes, entrenando el modelo, realizando las pruebas de validacion y tambien calculando el tiempo que le tomo cuantizar los parametros del modelo.

## PRIMEROS RESULTADOS

### Primer entrenamiento

#### RESOLUCION 256

Para la primer etapa de entrenamiento donde se uso las imagenes con su resolucion original, es decir $256$ $\times$ $256$, los resultados obtenidos fueron los siguientes:

* Indexado de archivos:  $0.434$ s.
* Total de $9000$ imagenes | $9$ clases.
* [ Train $=$ $6300$,  Val $=$ $1350$,  Test $=$ $1350$ ].
* Entrenamiento: $8254.509$ s.
![ Accuracy vs Loss in Training ]( resultados_experimentos/training_256x256.png )
* Accuracy: $0.8319$.
* Confussion Matrix:
![ Confussion Matrix $256$ $\times$ $256$ (float32) ]( resultados_experimentos/cm_256x256_float32.png )

Despues de esto se cuantizo a INT8, donde se obtuvieron los siguientes resultados:

* Conversion de parametros a INT8: $48.953$ s.
* Tamaño del modelo en INT8: $120.8$ KB.
* Accuracy int8: $0.8259$.
* Confussion Matrix:
![ Confussion Matrix $256$ $\times$ $256$ (int8) ]( resultados_experimentos/cm_256x256_int8.png )

Para finalizar tenemos el modelo cuantizado en INT16, donde los resultados fueron los siguientes:

* Conversion de parametros a INT16: $95.270$ s.
* Tamaño del modelo en INT8: $141.9$ KB.
* Accuracy int16: $0.8274$.
* Confussion Matrix:
![ Confussion Matrix $256$ $\times$ $256$ (int16) ]( resultados_experimentos/cm_256x256_int16.png )

#### RESOLUCION 128

Para la segunda etapa de entrenamiento donde se uso las imagenes con un reescalado a $128$ $\times$ $128$, los resultados obtenidos fueron los siguientes:

* Entrenamiento: $8052.963$ s.
![ Accuracy vs Loss in Training ]( resultados_experimentos/training_128x128.png)
* Accuracy: $0.6763$.
* Tiempo de evaluacion: $75.031$ s.
* Confussion Matrix:
![ Confussion Matrix $128$ $\times$ $128$ (float32) ]( resultados_experimentos/cm_128x128_float32.png )

Despues de esto se cuantizo a INT8, donde se obtuvieron los siguientes resultados:

* Conversion de parametros a INT8: $42.980$ s.
* Tamaño del modelo en INT8: $120.8$ KB.
* Accuracy int8: $0.6800$.
* Confussion Matrix:
![ Confussion Matrix $128$ $\times$ $128$ (int8) ]( resultados_experimentos/cm_128x128_int8.png )

Para finalizar tenemos el modelo cuantizado en INT16, donde los resultados fueron los siguientes:

* Conversion de parametros a INT16: $82.207$ s.
* Tamaño del modelo en INT8: $141.9$ KB.
* Accuracy int16: $0.6763$.
* Confussion Matrix:
![ Confussion Matrix $128$ $\times$ $128$ (int16 ]( resultados_experimentos/cm_128x128_int16.png )

#### RESOLUCION 96

Para la tercer etapa y ultima etapa de entrenamiento donde se uso las imagenes con un reescalado a $96$ $\times$ $96$, los resultados obtenidos fueron los siguientes:

* Entrenamiento: $8052.963$ s.
![ Accuracy vs Loss in Training ]( resultados_experimentos/training_96x96.png    )
* Accuracy: $0.7259$.
* Tiempo de evaluacion: $72.404$ s.
* Confussion Matrix:
![ Confussion Matrix $96$ $\times$ $96$ (float32) ]( resultados_experimentos/cm_96x96_float32.png )

Despues de esto se cuantizo a INT8, donde se obtuvieron los siguientes resultados:

* Conversion de parametros a INT8: $41.845$ s.
* Tamaño del modelo en INT8: $120.7$ KB.
* Accuracy int8: $0.7230$.
* Confussion Matrix:
![ Confussion Matrix $96$ $\times$ $96$ (int8) ]( resultados_experimentos/cm_96x96_int8.png )

Para finalizar tenemos el modelo cuantizado en INT16, donde los resultados fueron los siguientes:

* Conversion de parametros a INT16: $81.680$ s.
* Tamaño del modelo en INT8: $141.8$ KB.
* Accuracy int16: $0.7267$.
* Confussion Matrix:
![ Confussion Matrix $96$ $\times$ $96$ (int16) ]( resultados_experimentos/cm_96x96_int16.png )

| Resolucion | Tiempo de Entrenamiento ( s ) | Cuantizacion | Accuracy | Inferencia ( ms / img ) | Tamaño del modelo ( kB ) | Tiempo de conversion ( s ) |
|---|---|---|---|---|---|---|
| $256$ $\times$ $256$ | $8254.509$ | float32 | $0.831852$ | $7.5678$ | $1112.441$ | No aplica |
| $256$ $\times$ $256$ | $8254.509$ | INT8 | $0.825926$ | $207.1756$ | $120.773$ | $48.9533$ |
| $256$ $\times$ $256$ | $8254.509$ | INT16 | $0.827407$ | $264.2121$ | $141.882$ | $95.2697$ |
| $128$ $\times$ $128$ | $8052.963$ | float32 | $0.676296$ | $3.3505$ | $1112.293$ | No aplica |
| $128$ $\times$ $128$ | $8052.963$ | INT8 | $0.680000$ | $214.8316$ | $120.773$ | $42.9797$ |
| $128$ $\times$ $128$ | $8052.963$ | INT16 | $0.676296$ | $218.2872$ | $141.882$ | $82.2065$ |
| $96$ $\times$ $96$ | $7811.027$ | float32 | $0.725926$ | $3.7295$ | $1112.286$ | No aplica |
| $96$ $\times$ $96$ | $7811.027$ | INT8 | $0.722963$ | $201.9591$ | $120.656$ | $41.8454$ |
| $96$ $\times$ $96$ | $7811.027$ | INT16 | $0.726667$ | $213.9610$ | $141.7656$ | $81.6804$ |

## CORRECIONES REALIZADAS

Despues de haber entrenado el modelo por primera vez, se observo que el mejor accuracy obtenido fue cuando se entreno el modelo con las dimensiones originales de las imagenes y cuantizando a float32, el accuracy que se obtuvo fue de $0.8318$, lo cual fue un buen punto de partida, a partir de aqui se tomaron desiciones respecto a como mejorar este accuracy obtenido, y buscar subirlo lo mayor posible.

Para el primer entrenamiento realizado, se escogio como modelo de segmentacion el metodo grabCut de openCV, este metodo aunque muy rapido, cometio muchos errores a la hora de segmentar algunas imagenes, ya que o les recortaba parte de la hoja, por lo tanto las dejaba incompletas o sino, les agreagaba sombra como si fueran parte de la hoja, haciendo que el modelo aprendiera patrones que no eran correctos debido a la forma en la cual estaban siendo segmentadas.

![ Segmentacion realizada con grabCut ]( resultados_experimentos/imagenes_segmentadas/00_mosaic_overview.png )

Para poder resolver este problema se tomo la desicion de tomar una muestra aleatoria de cada clase, y realizar el proceso de segmentacion de manera manual, para esto se uso la herramienta open-source labelme, con la cual se realizaron las mascaras de una muestra por clase, por lo que se obtuvieron 9 mascaras.

![ Segmentacion realizada con grabCut ]( resultados_experimentos/segmentacion/mascaras_manuales.png )

Con las 9 mascaras ya obtenidas se procedio a entrenar un modelo de CNN pequeño llamado U-Net el cual esta desarrollado para la segmentacion de imagenes. La red se basa en una red neuronal completamente convolucional cuya arquitectura se modificó y amplió para funcionar con menos imágenes de entrenamiento y lograr una segmentación más precisa.

El script utilizado para este paso fue el llamado "u_net_segmentation.py", despues de entrenarla con las 9 mascaras obtenidas de forma manual, se utilizo para segmentar todas las imagenes del dataset, por lo que se obtuvieron 9000 imagenes segmentadas de manera mas precisa que usando el metodo de grabCut, a continuacion se muestran unas muestras de esta segmentacion realizada por la red neuronal.

![ Segmentacion realizada con grabCut ]( resultados_experimentos/segmentacion/segmentacion_muestras.png )

Como se puede ver, los resultados que se obtienen son mucho mejores que los que nos devuelve el metodo de grabCut, ahora con este nuevo dataset de imagenes mejor segmentadas, se procedio a realizar un nuevo entrenamiento de la CNN, repitiendo los mismos pasos que en el primer entrenamiento, pero usando este nuevo dataset, los resultados que se obtuvieron fueron los siguientes:

### Segundo Entrenamiento


#### RESOLUCION 256

Para la primer etapa de este segundo entrenamiento, se siguio el mismo esquema que para el primer entrenamiento, donde la primer fase del entrenamiento fue con las imagenes en su resolucion original de $256$ $\times$ $256$, donde se obtuvieron los siguientes resultados:

* Indexado de archivos:  $0.124$ s.
* Total de $9000$ imagenes | $9$ clases.
* [ Train $=$ $6300$,  Val $=$ $1350$,  Test $=$ $1350$ ].
* Entrenamiento: $869.452$ s.
![ Accuracy vs Loss in Training ]( resultados_experimentos_2/training_256x256.png )
* Accuracy: $0.8859$.
* Confussion Matrix:
![ Confussion Matrix $256$ $\times$ $256$ (float32) ]( resultados_experimentos_2/cm_256x256_float32.png )

Despues de esto se cuantizo a INT8, donde se obtuvieron los siguientes resultados:

* Conversion de parametros a INT8: $35.354$ s.
* Tamaño del modelo en INT8: $120.8$ KB.
* Accuracy int8: $0.8837$.
* Confussion Matrix:
![ Confussion Matrix $256$ $\times$ $256$ (int8) ]( resultados_experimentos_2/cm_256x256_int8.png )

Para finalizar tenemos el modelo cuantizado en INT16, donde los resultados fueron los siguientes:

* Conversion de parametros a INT16: $67.825$ s.
* Tamaño del modelo en INT8: $141.9$ KB.
* Accuracy int16: $0.8867$.
* Confussion Matrix:
![ Confussion Matrix $256$ $\times$ $256$ (int16) ]( resultados_experimentos_2/cm_256x256_int16.png )

#### RESOLUCION 128

Para la segunda etapa de entrenamiento donde se uso las imagenes con un reescalado a $128$ $\times$ $128$, los resultados obtenidos fueron los siguientes:

* Entrenamiento: $531.974$ s.
![ Accuracy vs Loss in Training ]( resultados_experimentos_2/training_128x128.png )
* Accuracy: $0.7030$.
* Tiempo de evaluacion: $26.070$ s.
* Confussion Matrix:
![ Confussion Matrix $128$ $\times$ $128$ (float32) ]( resultados_experimentos_2/cm_128x128_float32.png )

Despues de esto se cuantizo a INT8, donde se obtuvieron los siguientes resultados:

* Conversion de parametros a INT8: $31.813$ s.
* Tamaño del modelo en INT8: $120.8$ KB.
* Accuracy int8: $0.7104$.
* Confussion Matrix:
![ Confussion Matrix $128$ $\times$ $128$ (int8) ]( resultados_experimentos_2/cm_128x128_int8.png )

Para finalizar tenemos el modelo cuantizado en INT16, donde los resultados fueron los siguientes:

* Conversion de parametros a INT16: $58.952$ s.
* Tamaño del modelo en INT8: $141.9$ KB.
* Accuracy int16: $0.7015$.
* Confussion Matrix:
![ Confussion Matrix $128$ $\times$ $128$ (int16 ]( resultados_experimentos_2/cm_128x128_int16.png )

#### RESOLUCION 96

Para la tercer etapa y ultima etapa de entrenamiento donde se uso las imagenes con un reescalado a $96$ $\times$ $96$, los resultados obtenidos fueron los siguientes:

* Entrenamiento: $534.569$ s.
![ Accuracy vs Loss in Training ]( resultados_experimentos_2/training_96x96.png    )
* Accuracy: $0.7622$.
* Tiempo de evaluacion: $26.955$ s.
* Confussion Matrix:
![ Confussion Matrix $96$ $\times$ $96$ (float32) ]( resultados_experimentos_2/cm_96x96_float32.png )

Despues de esto se cuantizo a INT8, donde se obtuvieron los siguientes resultados:

* Conversion de parametros a INT8: $30.056$ s.
* Tamaño del modelo en INT8: $120.7$ KB.
* Accuracy int8: $0.7689$.
* Confussion Matrix:
![ Confussion Matrix $96$ $\times$ $96$ (int8) ]( resultados_experimentos_2/cm_96x96_int8.png )

Para finalizar tenemos el modelo cuantizado en INT16, donde los resultados fueron los siguientes:

* Conversion de parametros a INT16: $59.788$ s.
* Tamaño del modelo en INT8: $141.8$ KB.
* Accuracy int16: $0.7667$.
* Confussion Matrix:
![ Confussion Matrix $96$ $\times$ $96$ (int16) ]( resultados_experimentos_2/cm_96x96_int16.png )

| Resolucion | Tiempo de Entrenamiento ( s ) | Cuantizacion | Accuracy | Inferencia ( ms / img ) | Tamaño del modelo ( kB ) | Tiempo de conversion ( s ) |
|---|---|---|---|---|---|---|
| $256$ $\times$ $256$ | $869.451$ | float32 | $0.885926$ | $8.6652$ | $1112.440$ | No aplica |
| $256$ $\times$ $256$ | $869.451$ | INT8 | $0.883704$ | $11.2185$ | $120.773$ | $35.3539$ |
| $256$ $\times$ $256$ | $869.451$ | INT16 | $0.886667$ | $68.8505$ | $141.882$ | $67.8251$ |
| $128$ $\times$ $128$ | $531.974$ | float32 | $0.702963$ | $2.8907$ | $1112.294$ | No aplica |
| $128$ $\times$ $128$ | $531.974$ | INT8 | $0.710370$ | $6.7732$ | $120.773$ | $31.8126$ |
| $128$ $\times$ $128$ | $531.974$ | INT16 | $0.701481$ | $23.7306$ | $141.882$ | $58.9521$ |
| $96$ $\times$ $96$ | $534.568$ | float32 | $0.762222$ | $3.9877$ | $1112.286$ | No aplica |
| $96$ $\times$ $96$ | $534.568$ | INT8 | $0.768889$ | $6.8182$ | $120.656$ | $30.0562$ |
| $96$ $\times$ $96$ | $534.568$ | INT16 | $0.766667$ | $16.0752$ | $141.765$ | $59.7883$ |

