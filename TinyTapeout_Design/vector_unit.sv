///////////////////////////////////////////////////////////////////////////////
// Module: vector_unit.sv
// Description: Single-lane FP16→FP4 quantizer for the 1x2 GEMM core.
//
//   One shared FloatP16x4 instance. gemm_top muxes sa_out[drain_col] onto
//   col_out before the VU input, so only one column is presented per DRAIN
//   phase. quant_en fires once per SCALE_LOAD cycle.
//
//   ReLU: if relu_en is set and col_out is negative (sign bit = 1),
//   both col and scale are zeroed before the multiply — result is 0.
//
//   Pipeline: col_out → [FloatP16x4 comb] → mult_out → [FF on quant_en] → y_out
//
// Ports:
//   clk        : clock
//   relu_en    : ReLU enable (from CU, registered RELU_EN from CFG)
//   quant_en   : 1-bit capture enable (asserted during SCALE_LOAD)
//   col_out    : [15:0] FP16 accumulator value — muxed by gemm_top per drain_col
//   scale      : [15:0] FP16 scale received from host during SCALE_LOAD
//   y_out      : [3:0] FP4 E2M1 quantized output
//
// Author: Group5
///////////////////////////////////////////////////////////////////////////////

module vector_unit #(
    parameter FP16_WIDTH = 16,
    parameter FP4_WIDTH  = 4
) (
    input  logic                      clk,
    input  logic                      relu_en,
    input  logic                      quant_en,
    input  logic [FP16_WIDTH-1:0]     col_out,
    input  logic [FP16_WIDTH-1:0]     scale,
    output logic [FP4_WIDTH-1:0]      y_out
);

    logic [FP16_WIDTH-1:0] col_muxed;
    logic [FP16_WIDTH-1:0] scale_muxed;
    logic [FP4_WIDTH-1:0]  mult_out;
    logic [FP4_WIDTH-1:0]  reg_out;

    // ReLU: zero out negative activations before quantization
    assign col_muxed   = (relu_en && col_out[FP16_WIDTH-1]) ? '0 : col_out;
    assign scale_muxed = (relu_en && col_out[FP16_WIDTH-1]) ? '0 : scale;

    FloatP16x4 u_q (
        .A   (scale_muxed),
        .B   (col_muxed),
        .Out (mult_out)
    );

    always_ff @(posedge clk) begin
        if (quant_en) begin
            reg_out <= mult_out;
		end
    end

    assign y_out = reg_out;
endmodule