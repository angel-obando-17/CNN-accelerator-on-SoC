# CNN Accelerator FSM

IDLE -> Espera REG_START = 1 de Core0, en este punto los pesos y el tile ya estan en BRAM porque Core0 ya lanzo el DMA antes de escribir START.

Transicion: reg_start = 1 -> COMPUTE

COMPUTE -> Ejecuta la operacion segun REG_MODE. El Address Generator genera direcciones, los MACs operan, los acumuladores acumulan. Este estado internamente tiene sus propios sub-ciclos dependiendo del modo, pero hacia fuera es un solo estado. Cuando termina de procesar todos los tiles del IFM actual entonces:

Transicion: compute_done = 1 -> POST

POST -> Aplica en secuencia ReLU6 -> Quantizer INT8 -> Pool/GAP si reg_pool_en = 1. Todo sobre el Output Buffer en BRAM.

Transicion: post_done = 1 -> ADD reg_has_residual = 1, sino -> DONE

ADD -> Suma elemento a elemento el Residual Buffer con el Output Buffer. El tensor residual ya esta en BRAMporque Core0 lo cargo antes de lanzar el acelerador.

Transicion: add_done = 1 -> DONE

DONE -> Pone reg_done = 1, genera irq_out = 1 hacia el PS. Core0 recibe del IRQ, lee el Output Buffer via DMA, decide si lanzar otra capa o terminar.

Transicion: Core0 escribe reg_start = 1 para la siguiente capa -> IDLE

