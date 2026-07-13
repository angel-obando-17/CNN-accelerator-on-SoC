# =============================================================================
# Timing constraints: Reloj principal de cnn_top
# Project : CNN Accelerator on SoC
# File    : cnn_top_clock.xdc
#
# Used In: Synthesis + Implementation (para el analisis de timing, ver
#          constraints/timing_analysis.md).
#
# 70 MHz (periodo 14.286 ns) -- frecuencia final elegida para FCLK_CLK0 del PS7.
# STA real (post-ruteo, 2026-07-13), iterado con 3 puntos: 100MHz falla feo
# (WNS=-2.724ns), 78MHz falla apenas (WNS=-0.293ns), 70MHz PASA con margen
# positivo (WNS=+0.288ns, "All user specified timing constraints are met").
# Fmax real ~75-76 MHz. Camino critico en ddr_addr_gen.vhd (calculo de
# direccion DDR 100% combinacional, 2xDSP48E1+11xCARRY4). Ver
# constraints/timing_analysis.md para el detalle completo y la tabla de
# corridas.
# =============================================================================

create_clock -period 14.286 -name clk -waveform {0.000 7.143} [get_ports clk]
