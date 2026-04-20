(* blackbox *)
module vector_unit (
    input  wire        clk,
    input  wire        relu_en,
    input  wire [7:0]  quant_en,
    input  wire [127:0] col_out,
    input  wire [15:0]  scale,
    output wire [31:0]  y_out
);
endmodule
