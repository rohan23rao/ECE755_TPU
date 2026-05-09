module vector_unit #(
    parameter int FP16_WIDTH = 16,
    parameter int FP4_WIDTH  = 4
) (
    input  logic                    clk,
    input  logic                    relu_en,
    input  logic                    quant_en,
    input  logic [FP16_WIDTH-1:0]   col_out,
    input  logic [FP16_WIDTH-1:0]   scale,
    output logic [FP4_WIDTH-1:0]    y_out
);

    logic [FP16_WIDTH-1:0] quant_in;
    logic [FP16_WIDTH-1:0] quant_scale;
    logic [FP4_WIDTH-1:0]  mult_out;
    logic [FP4_WIDTH-1:0]  reg_out;

    // ReLU: zero out negative inputs; gate if quant disabled
    assign quant_in    = ((relu_en && col_out[FP16_WIDTH-1]) || !quant_en) ? '0 : col_out;
    assign quant_scale = ((relu_en && col_out[FP16_WIDTH-1]) || !quant_en) ? '0 : scale;

    FloatP16x4 iFloat (.A(quant_scale), .B(quant_in), .Out(mult_out));

    always_ff @(posedge clk) begin
        if (quant_en)
            reg_out <= mult_out;
    end

    assign y_out = reg_out;

endmodule