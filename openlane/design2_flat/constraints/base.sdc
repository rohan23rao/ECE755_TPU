# Timing constraints for Design2 flat flow (gemm_top)
create_clock -name clk -period $::env(CLOCK_PERIOD) [get_ports clk]
set_input_delay  [expr {$::env(CLOCK_PERIOD) * 0.1}] -clock clk [all_inputs]
set_output_delay [expr {$::env(CLOCK_PERIOD) * 0.1}] -clock clk [all_outputs]
