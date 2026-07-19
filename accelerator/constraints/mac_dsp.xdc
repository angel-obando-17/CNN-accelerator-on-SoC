# =============================================================================
# Synthesis constraints: Force MAC accumulators to map to DSP48 primitives
# Project : CNN Accelerator on SoC
# File    : mac_dsp.xdc
#
# Used In: Synthesis ONLY (uncheck Simulation and Implementation)
# =============================================================================

set_property use_dsp yes \
    [get_cells -hierarchical -filter \
        {NAME =~ "*inst_mac_array/gen_macs[*].mac_inst/accumulator_reg[*]"}]