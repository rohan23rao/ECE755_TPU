///////////////////////////////////////////////////////////////////////////////
// Module: vector_unit.sv
// Description: Shared single-lane FP16->FP4 quantizer for the 1xN GEMM core.
//
//   Ping-pong FLUSH protocol:
//     Even FLUSH cycles (capture_en=1): col_out + scale_in valid from host.
//       VU computes y_comb combinatorially; y_reg captures on clock edge.
//     Odd  FLUSH cycles (capture_en=0): y_reg holds result for host readback.
//
//   No combinational path from input pins to output pins:
//     scale_in → FloatP16x4 → y_comb → [y_reg FF] → y_out
//
// Author: Group5
///////////////////////////////////////////////////////////////////////////////

module vector_unit (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        capture_en,     // even FLUSH cycles: compute and latch
    input  logic        relu_en,
    input  logic [15:0] col_out,        // FP16 accumulator from selected SA col
    input  logic [15:0] scale_in,       // full 16-bit FP16 scale from {ui_in, uio_in}
    output logic  [3:0] y_out           // FP4 E2M1 quantized result
);

    logic [15:0] col_in_muxed;
    logic [15:0] scale_muxed;
    logic  [3:0] y_comb;
    logic  [3:0] y_reg;

    assign col_in_muxed = (relu_en && col_out[15]) ? '0 : col_out;
    assign scale_muxed  = (relu_en && col_out[15]) ? '0 : scale_in;

    FloatP16x4 u_q (
        .A   (scale_muxed),
        .B   (col_in_muxed),
        .Out (y_comb)
    );

    always_ff @(posedge clk, negedge rst_n) begin
        if (capture_en) begin
            y_reg <= y_comb;
		end
    end

    assign y_out = y_reg;
endmodule