(* blackbox *)
module gemm_pe #(
    parameter ACT_WIDTH = 4,
    parameter WGT_WIDTH = 4,
    parameter ACC_WIDTH = 16
) (
    input  wire                    clk,
    input  wire [ACT_WIDTH-1:0]    a_in,
    input  wire                    h_en_in,
    output wire [ACT_WIDTH-1:0]    a_out,
    output wire                    h_en_out,
    input  wire [WGT_WIDTH-1:0]    w_in,
    input  wire                    v_en_in,
    output wire [WGT_WIDTH-1:0]    w_out,
    output wire                    v_en_out,
    input  wire [ACC_WIDTH-1:0]    bias,
    input  wire                    ld_bias,
    output wire [ACC_WIDTH-1:0]    acc_out
);
endmodule
