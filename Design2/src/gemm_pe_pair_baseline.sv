///////////////////////////////////////////////////////////////////////////////
// Module: gemm_pe_pair_baseline.sv
// Description: Synthesis comparison shell — two original gemm_pe instances
//              wired as adjacent rows in the same systolic array column,
//              matching the external interface of gemm_butterfly_pe exactly.
//
//              Instantiation mirrors the original gemm_systolic_array wiring:
//                PE_i  : top row    — w_in/v_en_in from north boundary
//                PE_i1 : bottom row — w_in/v_en_in from PE_i.w_out/v_en_out
//
//              Interface is pin-compatible with gemm_butterfly_pe so the two
//              modules can be dropped into the same synthesis script with no
//              port changes.  rst_n is accepted but unused (gemm_pe is
//              reset-free by design).
//
// Comparison intent:
//   gemm_pe_pair_baseline : 2× gemm_pe, each with its own fp16_adder_truncation
//   gemm_butterfly_pe     : 2× sub-PE sharing one fp16_adder_truncation_pipe
//
//   Expected delta: ~1 adder saved, critical path shortened by removing the
//   adder from the single-PE pipeline at the cost of FIFO + arbiter area.
//
// Author: Group5
///////////////////////////////////////////////////////////////////////////////

module gemm_pe_pair_baseline #(
    parameter ACT_WIDTH = 4,
    parameter WGT_WIDTH = 4,
    parameter ACC_WIDTH = 16
) (
    input  logic                    clk,
    input  logic                    rst_n,          // accepted, unused (PE is reset-free)

    // ── PE_i horizontal (row i) ───────────────────────────────────────────
    input  logic [ACT_WIDTH-1:0]    a_in_i,
    input  logic                    h_en_in_i,
    output logic [ACT_WIDTH-1:0]    a_out_i,
    output logic                    h_en_out_i,

    // ── PE_i+1 horizontal (row i+1) ──────────────────────────────────────
    input  logic [ACT_WIDTH-1:0]    a_in_i1,
    input  logic                    h_en_in_i1,
    output logic [ACT_WIDTH-1:0]    a_out_i1,
    output logic                    h_en_out_i1,

    // ── Vertical (shared column, enters PE_i from north) ─────────────────
    input  logic [WGT_WIDTH-1:0]    w_in,
    input  logic                    v_en_in,
    output logic [WGT_WIDTH-1:0]    w_out,
    output logic                    v_en_out,

    // ── Bias load ─────────────────────────────────────────────────────────
    input  logic [ACC_WIDTH-1:0]    bias,
    input  logic                    ld_bias,

    // ── Accumulator outputs ───────────────────────────────────────────────
    output logic [ACC_WIDTH-1:0]    acc_out_i,
    output logic [ACC_WIDTH-1:0]    acc_out_i1
);

    // Internal vertical wires between PE_i and PE_i+1
    logic [WGT_WIDTH-1:0] w_mid;
    logic                 v_en_mid;

    // ── PE_i (top row) ────────────────────────────────────────────────────
    gemm_pe #(
        .ACT_WIDTH (ACT_WIDTH),
        .WGT_WIDTH (WGT_WIDTH),
        .ACC_WIDTH (ACC_WIDTH)
    ) u_pe_i (
        .clk       (clk),
        .a_in      (a_in_i),
        .h_en_in   (h_en_in_i),
        .a_out     (a_out_i),
        .h_en_out  (h_en_out_i),
        .w_in      (w_in),
        .v_en_in   (v_en_in),
        .w_out     (w_mid),
        .v_en_out  (v_en_mid),
        .bias      (bias),
        .ld_bias   (ld_bias),
        .acc_out   (acc_out_i)
    );

    // ── PE_i+1 (bottom row) ───────────────────────────────────────────────
    // Receives weight and v_en from PE_i's south outputs, mirroring the
    // original systolic array inter-row wiring.
    gemm_pe #(
        .ACT_WIDTH (ACT_WIDTH),
        .WGT_WIDTH (WGT_WIDTH),
        .ACC_WIDTH (ACC_WIDTH)
    ) u_pe_i1 (
        .clk       (clk),
        .a_in      (a_in_i1),
        .h_en_in   (h_en_in_i1),
        .a_out     (a_out_i1),
        .h_en_out  (h_en_out_i1),
        .w_in      (w_mid),
        .v_en_in   (v_en_mid),
        .w_out     (w_out),
        .v_en_out  (v_en_out),
        .bias      (bias),
        .ld_bias   (ld_bias),
        .acc_out   (acc_out_i1)
    );

endmodule
