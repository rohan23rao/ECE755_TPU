###############################################################################
# Created by write_sdc
###############################################################################
current_design gemm_top
###############################################################################
# Timing Constraints
###############################################################################
create_clock -name clk -period 14.0000 [get_ports {clk}]
set_propagated_clock [get_clocks {clk}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {A_DATA[0]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {A_DATA[0]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {A_DATA[10]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {A_DATA[10]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {A_DATA[11]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {A_DATA[11]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {A_DATA[12]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {A_DATA[12]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {A_DATA[13]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {A_DATA[13]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {A_DATA[14]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {A_DATA[14]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {A_DATA[15]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {A_DATA[15]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {A_DATA[16]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {A_DATA[16]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {A_DATA[17]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {A_DATA[17]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {A_DATA[18]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {A_DATA[18]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {A_DATA[19]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {A_DATA[19]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {A_DATA[1]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {A_DATA[1]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {A_DATA[20]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {A_DATA[20]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {A_DATA[21]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {A_DATA[21]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {A_DATA[22]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {A_DATA[22]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {A_DATA[23]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {A_DATA[23]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {A_DATA[24]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {A_DATA[24]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {A_DATA[25]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {A_DATA[25]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {A_DATA[26]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {A_DATA[26]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {A_DATA[27]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {A_DATA[27]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {A_DATA[28]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {A_DATA[28]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {A_DATA[29]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {A_DATA[29]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {A_DATA[2]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {A_DATA[2]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {A_DATA[30]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {A_DATA[30]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {A_DATA[31]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {A_DATA[31]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {A_DATA[3]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {A_DATA[3]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {A_DATA[4]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {A_DATA[4]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {A_DATA[5]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {A_DATA[5]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {A_DATA[6]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {A_DATA[6]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {A_DATA[7]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {A_DATA[7]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {A_DATA[8]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {A_DATA[8]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {A_DATA[9]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {A_DATA[9]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {A_LEN[0]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {A_LEN[0]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {A_LEN[1]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {A_LEN[1]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {A_LEN[2]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {A_LEN[2]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {A_LEN[3]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {A_LEN[3]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {BIAS[0]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {BIAS[0]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {BIAS[10]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {BIAS[10]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {BIAS[11]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {BIAS[11]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {BIAS[12]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {BIAS[12]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {BIAS[13]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {BIAS[13]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {BIAS[14]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {BIAS[14]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {BIAS[15]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {BIAS[15]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {BIAS[1]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {BIAS[1]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {BIAS[2]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {BIAS[2]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {BIAS[3]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {BIAS[3]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {BIAS[4]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {BIAS[4]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {BIAS[5]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {BIAS[5]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {BIAS[6]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {BIAS[6]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {BIAS[7]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {BIAS[7]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {BIAS[8]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {BIAS[8]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {BIAS[9]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {BIAS[9]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {BIAS_NEW}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {BIAS_NEW}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {BIAS_VLD}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {BIAS_VLD}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {DATA_VLD}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {DATA_VLD}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {K_LEN[0]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {K_LEN[0]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {K_LEN[1]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {K_LEN[1]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {K_LEN[2]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {K_LEN[2]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {K_LEN[3]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {K_LEN[3]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {METADATA_VLD}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {METADATA_VLD}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {RELU_EN}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {RELU_EN}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {SCALE[0]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {SCALE[0]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {SCALE[10]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {SCALE[10]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {SCALE[11]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {SCALE[11]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {SCALE[12]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {SCALE[12]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {SCALE[13]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {SCALE[13]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {SCALE[14]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {SCALE[14]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {SCALE[15]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {SCALE[15]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {SCALE[1]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {SCALE[1]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {SCALE[2]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {SCALE[2]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {SCALE[3]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {SCALE[3]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {SCALE[4]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {SCALE[4]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {SCALE[5]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {SCALE[5]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {SCALE[6]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {SCALE[6]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {SCALE[7]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {SCALE[7]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {SCALE[8]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {SCALE[8]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {SCALE[9]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {SCALE[9]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {SCALE_VLD}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {SCALE_VLD}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {TILE_LAST}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {TILE_LAST}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {TILE_START}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {TILE_START}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {W_DATA[0]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {W_DATA[0]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {W_DATA[10]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {W_DATA[10]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {W_DATA[11]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {W_DATA[11]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {W_DATA[12]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {W_DATA[12]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {W_DATA[13]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {W_DATA[13]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {W_DATA[14]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {W_DATA[14]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {W_DATA[15]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {W_DATA[15]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {W_DATA[16]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {W_DATA[16]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {W_DATA[17]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {W_DATA[17]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {W_DATA[18]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {W_DATA[18]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {W_DATA[19]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {W_DATA[19]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {W_DATA[1]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {W_DATA[1]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {W_DATA[20]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {W_DATA[20]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {W_DATA[21]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {W_DATA[21]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {W_DATA[22]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {W_DATA[22]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {W_DATA[23]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {W_DATA[23]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {W_DATA[24]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {W_DATA[24]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {W_DATA[25]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {W_DATA[25]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {W_DATA[26]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {W_DATA[26]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {W_DATA[27]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {W_DATA[27]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {W_DATA[28]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {W_DATA[28]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {W_DATA[29]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {W_DATA[29]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {W_DATA[2]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {W_DATA[2]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {W_DATA[30]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {W_DATA[30]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {W_DATA[31]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {W_DATA[31]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {W_DATA[3]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {W_DATA[3]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {W_DATA[4]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {W_DATA[4]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {W_DATA[5]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {W_DATA[5]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {W_DATA[6]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {W_DATA[6]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {W_DATA[7]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {W_DATA[7]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {W_DATA[8]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {W_DATA[8]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {W_DATA[9]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {W_DATA[9]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {W_LEN[0]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {W_LEN[0]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {W_LEN[1]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {W_LEN[1]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {W_LEN[2]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {W_LEN[2]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {W_LEN[3]}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {W_LEN[3]}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {Y_RDY}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {Y_RDY}]
set_input_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {rst_n}]
set_input_delay 2.0000 -clock [get_clocks {clk}] -max -add_delay [get_ports {rst_n}]
set_output_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {BIAS_RDY}]
set_output_delay 1.8000 -clock [get_clocks {clk}] -max -add_delay [get_ports {BIAS_RDY}]
set_output_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {DATA_RDY}]
set_output_delay 1.8000 -clock [get_clocks {clk}] -max -add_delay [get_ports {DATA_RDY}]
set_output_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {METADATA_RDY}]
set_output_delay 1.8000 -clock [get_clocks {clk}] -max -add_delay [get_ports {METADATA_RDY}]
set_output_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {SCALE_RDY}]
set_output_delay 1.8000 -clock [get_clocks {clk}] -max -add_delay [get_ports {SCALE_RDY}]
set_output_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {TILE_DONE}]
set_output_delay 1.8000 -clock [get_clocks {clk}] -max -add_delay [get_ports {TILE_DONE}]
set_output_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {Y_OUT[0]}]
set_output_delay 1.8000 -clock [get_clocks {clk}] -max -add_delay [get_ports {Y_OUT[0]}]
set_output_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {Y_OUT[10]}]
set_output_delay 1.8000 -clock [get_clocks {clk}] -max -add_delay [get_ports {Y_OUT[10]}]
set_output_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {Y_OUT[11]}]
set_output_delay 1.8000 -clock [get_clocks {clk}] -max -add_delay [get_ports {Y_OUT[11]}]
set_output_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {Y_OUT[12]}]
set_output_delay 1.8000 -clock [get_clocks {clk}] -max -add_delay [get_ports {Y_OUT[12]}]
set_output_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {Y_OUT[13]}]
set_output_delay 1.8000 -clock [get_clocks {clk}] -max -add_delay [get_ports {Y_OUT[13]}]
set_output_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {Y_OUT[14]}]
set_output_delay 1.8000 -clock [get_clocks {clk}] -max -add_delay [get_ports {Y_OUT[14]}]
set_output_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {Y_OUT[15]}]
set_output_delay 1.8000 -clock [get_clocks {clk}] -max -add_delay [get_ports {Y_OUT[15]}]
set_output_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {Y_OUT[16]}]
set_output_delay 1.8000 -clock [get_clocks {clk}] -max -add_delay [get_ports {Y_OUT[16]}]
set_output_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {Y_OUT[17]}]
set_output_delay 1.8000 -clock [get_clocks {clk}] -max -add_delay [get_ports {Y_OUT[17]}]
set_output_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {Y_OUT[18]}]
set_output_delay 1.8000 -clock [get_clocks {clk}] -max -add_delay [get_ports {Y_OUT[18]}]
set_output_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {Y_OUT[19]}]
set_output_delay 1.8000 -clock [get_clocks {clk}] -max -add_delay [get_ports {Y_OUT[19]}]
set_output_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {Y_OUT[1]}]
set_output_delay 1.8000 -clock [get_clocks {clk}] -max -add_delay [get_ports {Y_OUT[1]}]
set_output_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {Y_OUT[20]}]
set_output_delay 1.8000 -clock [get_clocks {clk}] -max -add_delay [get_ports {Y_OUT[20]}]
set_output_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {Y_OUT[21]}]
set_output_delay 1.8000 -clock [get_clocks {clk}] -max -add_delay [get_ports {Y_OUT[21]}]
set_output_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {Y_OUT[22]}]
set_output_delay 1.8000 -clock [get_clocks {clk}] -max -add_delay [get_ports {Y_OUT[22]}]
set_output_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {Y_OUT[23]}]
set_output_delay 1.8000 -clock [get_clocks {clk}] -max -add_delay [get_ports {Y_OUT[23]}]
set_output_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {Y_OUT[24]}]
set_output_delay 1.8000 -clock [get_clocks {clk}] -max -add_delay [get_ports {Y_OUT[24]}]
set_output_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {Y_OUT[25]}]
set_output_delay 1.8000 -clock [get_clocks {clk}] -max -add_delay [get_ports {Y_OUT[25]}]
set_output_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {Y_OUT[26]}]
set_output_delay 1.8000 -clock [get_clocks {clk}] -max -add_delay [get_ports {Y_OUT[26]}]
set_output_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {Y_OUT[27]}]
set_output_delay 1.8000 -clock [get_clocks {clk}] -max -add_delay [get_ports {Y_OUT[27]}]
set_output_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {Y_OUT[28]}]
set_output_delay 1.8000 -clock [get_clocks {clk}] -max -add_delay [get_ports {Y_OUT[28]}]
set_output_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {Y_OUT[29]}]
set_output_delay 1.8000 -clock [get_clocks {clk}] -max -add_delay [get_ports {Y_OUT[29]}]
set_output_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {Y_OUT[2]}]
set_output_delay 1.8000 -clock [get_clocks {clk}] -max -add_delay [get_ports {Y_OUT[2]}]
set_output_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {Y_OUT[30]}]
set_output_delay 1.8000 -clock [get_clocks {clk}] -max -add_delay [get_ports {Y_OUT[30]}]
set_output_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {Y_OUT[31]}]
set_output_delay 1.8000 -clock [get_clocks {clk}] -max -add_delay [get_ports {Y_OUT[31]}]
set_output_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {Y_OUT[3]}]
set_output_delay 1.8000 -clock [get_clocks {clk}] -max -add_delay [get_ports {Y_OUT[3]}]
set_output_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {Y_OUT[4]}]
set_output_delay 1.8000 -clock [get_clocks {clk}] -max -add_delay [get_ports {Y_OUT[4]}]
set_output_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {Y_OUT[5]}]
set_output_delay 1.8000 -clock [get_clocks {clk}] -max -add_delay [get_ports {Y_OUT[5]}]
set_output_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {Y_OUT[6]}]
set_output_delay 1.8000 -clock [get_clocks {clk}] -max -add_delay [get_ports {Y_OUT[6]}]
set_output_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {Y_OUT[7]}]
set_output_delay 1.8000 -clock [get_clocks {clk}] -max -add_delay [get_ports {Y_OUT[7]}]
set_output_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {Y_OUT[8]}]
set_output_delay 1.8000 -clock [get_clocks {clk}] -max -add_delay [get_ports {Y_OUT[8]}]
set_output_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {Y_OUT[9]}]
set_output_delay 1.8000 -clock [get_clocks {clk}] -max -add_delay [get_ports {Y_OUT[9]}]
set_output_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {Y_VLD[0]}]
set_output_delay 1.8000 -clock [get_clocks {clk}] -max -add_delay [get_ports {Y_VLD[0]}]
set_output_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {Y_VLD[1]}]
set_output_delay 1.8000 -clock [get_clocks {clk}] -max -add_delay [get_ports {Y_VLD[1]}]
set_output_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {Y_VLD[2]}]
set_output_delay 1.8000 -clock [get_clocks {clk}] -max -add_delay [get_ports {Y_VLD[2]}]
set_output_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {Y_VLD[3]}]
set_output_delay 1.8000 -clock [get_clocks {clk}] -max -add_delay [get_ports {Y_VLD[3]}]
set_output_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {Y_VLD[4]}]
set_output_delay 1.8000 -clock [get_clocks {clk}] -max -add_delay [get_ports {Y_VLD[4]}]
set_output_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {Y_VLD[5]}]
set_output_delay 1.8000 -clock [get_clocks {clk}] -max -add_delay [get_ports {Y_VLD[5]}]
set_output_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {Y_VLD[6]}]
set_output_delay 1.8000 -clock [get_clocks {clk}] -max -add_delay [get_ports {Y_VLD[6]}]
set_output_delay 0.0000 -clock [get_clocks {clk}] -min -add_delay [get_ports {Y_VLD[7]}]
set_output_delay 1.8000 -clock [get_clocks {clk}] -max -add_delay [get_ports {Y_VLD[7]}]
set_false_path -hold\
    -from [list [get_ports {A_DATA[0]}]\
           [get_ports {A_DATA[10]}]\
           [get_ports {A_DATA[11]}]\
           [get_ports {A_DATA[12]}]\
           [get_ports {A_DATA[13]}]\
           [get_ports {A_DATA[14]}]\
           [get_ports {A_DATA[15]}]\
           [get_ports {A_DATA[16]}]\
           [get_ports {A_DATA[17]}]\
           [get_ports {A_DATA[18]}]\
           [get_ports {A_DATA[19]}]\
           [get_ports {A_DATA[1]}]\
           [get_ports {A_DATA[20]}]\
           [get_ports {A_DATA[21]}]\
           [get_ports {A_DATA[22]}]\
           [get_ports {A_DATA[23]}]\
           [get_ports {A_DATA[24]}]\
           [get_ports {A_DATA[25]}]\
           [get_ports {A_DATA[26]}]\
           [get_ports {A_DATA[27]}]\
           [get_ports {A_DATA[28]}]\
           [get_ports {A_DATA[29]}]\
           [get_ports {A_DATA[2]}]\
           [get_ports {A_DATA[30]}]\
           [get_ports {A_DATA[31]}]\
           [get_ports {A_DATA[3]}]\
           [get_ports {A_DATA[4]}]\
           [get_ports {A_DATA[5]}]\
           [get_ports {A_DATA[6]}]\
           [get_ports {A_DATA[7]}]\
           [get_ports {A_DATA[8]}]\
           [get_ports {A_DATA[9]}]\
           [get_ports {A_LEN[0]}]\
           [get_ports {A_LEN[1]}]\
           [get_ports {A_LEN[2]}]\
           [get_ports {A_LEN[3]}]\
           [get_ports {BIAS[0]}]\
           [get_ports {BIAS[10]}]\
           [get_ports {BIAS[11]}]\
           [get_ports {BIAS[12]}]\
           [get_ports {BIAS[13]}]\
           [get_ports {BIAS[14]}]\
           [get_ports {BIAS[15]}]\
           [get_ports {BIAS[1]}]\
           [get_ports {BIAS[2]}]\
           [get_ports {BIAS[3]}]\
           [get_ports {BIAS[4]}]\
           [get_ports {BIAS[5]}]\
           [get_ports {BIAS[6]}]\
           [get_ports {BIAS[7]}]\
           [get_ports {BIAS[8]}]\
           [get_ports {BIAS[9]}]\
           [get_ports {BIAS_NEW}]\
           [get_ports {BIAS_RDY}]\
           [get_ports {BIAS_VLD}]\
           [get_ports {DATA_VLD}]\
           [get_ports {K_LEN[0]}]\
           [get_ports {K_LEN[1]}]\
           [get_ports {K_LEN[2]}]\
           [get_ports {K_LEN[3]}]\
           [get_ports {METADATA_VLD}]\
           [get_ports {RELU_EN}]\
           [get_ports {SCALE[0]}]\
           [get_ports {SCALE[10]}]\
           [get_ports {SCALE[11]}]\
           [get_ports {SCALE[12]}]\
           [get_ports {SCALE[13]}]\
           [get_ports {SCALE[14]}]\
           [get_ports {SCALE[15]}]\
           [get_ports {SCALE[1]}]\
           [get_ports {SCALE[2]}]\
           [get_ports {SCALE[3]}]\
           [get_ports {SCALE[4]}]\
           [get_ports {SCALE[5]}]\
           [get_ports {SCALE[6]}]\
           [get_ports {SCALE[7]}]\
           [get_ports {SCALE[8]}]\
           [get_ports {SCALE[9]}]\
           [get_ports {SCALE_RDY}]\
           [get_ports {SCALE_VLD}]\
           [get_ports {TILE_LAST}]\
           [get_ports {W_DATA[0]}]\
           [get_ports {W_DATA[10]}]\
           [get_ports {W_DATA[11]}]\
           [get_ports {W_DATA[12]}]\
           [get_ports {W_DATA[13]}]\
           [get_ports {W_DATA[14]}]\
           [get_ports {W_DATA[15]}]\
           [get_ports {W_DATA[16]}]\
           [get_ports {W_DATA[17]}]\
           [get_ports {W_DATA[18]}]\
           [get_ports {W_DATA[19]}]\
           [get_ports {W_DATA[1]}]\
           [get_ports {W_DATA[20]}]\
           [get_ports {W_DATA[21]}]\
           [get_ports {W_DATA[22]}]\
           [get_ports {W_DATA[23]}]\
           [get_ports {W_DATA[24]}]\
           [get_ports {W_DATA[25]}]\
           [get_ports {W_DATA[26]}]\
           [get_ports {W_DATA[27]}]\
           [get_ports {W_DATA[28]}]\
           [get_ports {W_DATA[29]}]\
           [get_ports {W_DATA[2]}]\
           [get_ports {W_DATA[30]}]\
           [get_ports {W_DATA[31]}]\
           [get_ports {W_DATA[3]}]\
           [get_ports {W_DATA[4]}]\
           [get_ports {W_DATA[5]}]\
           [get_ports {W_DATA[6]}]\
           [get_ports {W_DATA[7]}]\
           [get_ports {W_DATA[8]}]\
           [get_ports {W_DATA[9]}]\
           [get_ports {W_LEN[0]}]\
           [get_ports {W_LEN[1]}]\
           [get_ports {W_LEN[2]}]\
           [get_ports {W_LEN[3]}]\
           [get_ports {Y_RDY}]\
           [get_ports {rst_n}]]
###############################################################################
# Environment
###############################################################################
###############################################################################
# Design Rules
###############################################################################
