(* blackbox *)
module gemm_pe (
    input  logic        clk,
    input  logic [3:0]  a_in,
    input  logic        h_en_in,
    output logic [3:0]  a_out,
    output logic        h_en_out,
    input  logic [3:0]  w_in,
    input  logic        v_en_in,
    output logic [3:0]  w_out,
    output logic        v_en_out,
    input  logic [15:0] bias,
    input  logic        ld_bias,
    output logic [15:0] acc_out
);
endmodule
