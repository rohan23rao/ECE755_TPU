# constraints.sdc
create_clock -name clk -period 14 [get_ports clk]
set_input_delay  -max 2.0 -clock clk [all_inputs]
set_input_delay  -min 0.0 -clock clk [all_inputs]
set_output_delay -max 1.8 -clock clk [all_outputs]
set_output_delay -min 0.0 -clock clk [all_outputs]
set_false_path -hold -from [get_ports {rst_n A_DATA* W_LEN* K_LEN* A_LEN* RELU_EN TILE_LAST DATA_VLD METADATA_VLD Y_RDY BIAS* SCALE* W_DATA* SCALE_VLD*}]
