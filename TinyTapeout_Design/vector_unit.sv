///////////////////////////////////////////////////////////////////////////////
// Module: vector_unit.sv
// Description: 2-lane FP16→FP4 quantizer for the 1x2 GEMM core.
//
//   Each lane has a dedicated FloatP16x4 instance.
//   Scale is broadcast from the CU (pre-loaded in LOAD phase, muxed per lane).
//   quant_en[i] is staggered by the CU to match when each column's
//   accumulator is valid.
//
//   ReLU: if relu_en is set and col_out[i] is negative (sign bit = 1),
//   both col and scale are zeroed before the multiply — result is 0.
//
//   Pipeline: col_out → [FloatP16x4 comb] → mult_out → [FF on quant_en] → y_out
//
// Ports:
//   clk        : clock
//   relu_en    : ReLU enable (from CU, registered RELU_EN from CFG)
//   quant_en   : [COLS-1:0] per-lane capture enable (staggered from CU)
//   col_out    : [COLS-1:0][15:0] FP16 accumulator values from SA
//   scale      : [15:0] broadcast FP16 scale (CU muxes correct column's scale)
//   y_out      : [COLS-1:0][3:0] FP4 E2M1 quantized outputs
//
// Author: Group5
///////////////////////////////////////////////////////////////////////////////

module vector_unit #(
    parameter COLS       = 2,
    parameter FP16_WIDTH = 16,
    parameter FP4_WIDTH  = 4
) (
    input  logic                              clk,
    input  logic                              relu_en,
    input  logic [COLS-1:0]                   quant_en,
    input  logic [COLS-1:0][FP16_WIDTH-1:0]   col_out,
    input  logic [FP16_WIDTH-1:0]             scale,
    output logic [COLS-1:0][FP4_WIDTH-1:0]    y_out
);

    logic [COLS-1:0][FP4_WIDTH-1:0]  mult_out;
    logic [COLS-1:0][FP4_WIDTH-1:0]  reg_out;

    genvar i;
    generate
        for (i = 0; i < COLS; i = i + 1) begin : gen_lane
            logic [FP16_WIDTH-1:0] col_muxed;
            logic [FP16_WIDTH-1:0] scale_muxed;

            // ReLU: zero out negative activations before quantization
            assign col_muxed   = (relu_en && col_out[i][FP16_WIDTH-1]) ? '0 : col_out[i];
            assign scale_muxed = (relu_en && col_out[i][FP16_WIDTH-1]) ? '0 : scale;

            FloatP16x4 u_q (
                .A   (scale_muxed),
                .B   (col_muxed),
                .Out (mult_out[i])
            );

            always_ff @(posedge clk) begin
                if (quant_en[i])
                    reg_out[i] <= mult_out[i];
            end

            assign y_out[i] = reg_out[i];
        end
    endgenerate

endmodule