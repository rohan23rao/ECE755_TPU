///////////////////////////////////////////////////////////////////////////////
// Module: gemm_top.sv
// Description: Tiny Tapeout top-level wrapper for the FP4 GEMM 1xN Core.
//
// Integrates:
//   gemm_control_unit  : FSM + all datapath control signals
//   gemm_systolic_array: 1xN output-stationary PE mesh (ROWS=1, COLS=3)
//   vector_unit        : 3-lane FP16->FP4 quantizer
//
// Pin mapping:
//   ui_in[7:0]  : primary input bus
//     [3:0]  a_row0   (FP4 activation, single row)    during STREAM
//     [7:4]  w_col0   (FP4 weight, col 0)             during STREAM
//     [7:0]  K_LEN[7:0]                               during CFG
//     [7:0]  bias/scale upper byte                    during LOAD
//     [0]    START pulse                               during IDLE
//
//   uio[7:0] : bidirectional bus, direction set per phase
//     Input during IDLE/CFG/LOAD/STREAM:
//       [0]    RELU_EN                                 during CFG
//       [1]    SKIP_BIAS                               during CFG
//       [2]    SKIP_SCALE                              during CFG
//       [4:3]  COL_CONFIG[1:0]  (00=1x1,01=1x2,10=1x3) during CFG
//       [7:0]  bias/scale lower byte                  during LOAD
//       [3:0]  w_col1 (FP4 weight, col 1)             during STREAM
//       [7:4]  w_col2 (FP4 weight, col 2)             during STREAM
//     Output during DRAIN:
//       drain_cnt=0: 1x1→8'h00          1x2→{0,y[0]}      1x3→{y[1],y[0]}
//       drain_cnt=1: 1x1→{4'b0,y[0]}   1x2→{y[1],y[0]}   1x3→{4'b0,y[2]}
//
//   uo_out[7:0] : status bus (always output, never carries data)
//     [2:0]  phase[2:0]    FSM state
//     [3]    busy
//     [4]    drain_valid
//     [5]    drain_cnt     0=first drain cycle, 1=second
//     [6]    tile_done     1-cycle pulse
//     [7]    reserved (0)
//
// Data flow:
//   Activations : ui_in[3:0]             -> i_col[0]    -> systolic array row 0
//   Weights     : ui_in[7:4]/uio_in[3:0]/uio_in[7:4]
//                                        -> w_row[0/1/2] -> systolic array top
//   Accumulators: sa_out[j] (1D, ROWS=1) -> col_out[j]  -> vector unit lane j
//   Results     : y_out[2:0]             -> uio_out per drain table
//
// Note: No pipeline flop between systolic array and vector unit.
//       col_sel mux removed; sa_out is 1D (one acc per column, ROWS=1).
//
// Author: Group5
///////////////////////////////////////////////////////////////////////////////

module gemm_top #(
    parameter ROWS      = 1,
    parameter COLS      = 3,
    parameter ACT_WIDTH = 4,
    parameter WGT_WIDTH = 4,
    parameter ACC_WIDTH = 16,
    parameter FP4_WIDTH = 4
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        ena,        // TT enable, unused (design always active)

    // Tiny Tapeout standard pin interface
    input  logic [7:0]  ui_in,
    output logic [7:0]  uo_out,
    input  logic [7:0]  uio_in,
    output logic [7:0]  uio_out,
    output logic [7:0]  uio_oe
);

    // Suppress unused warning for TT ena pin
    logic _unused_ena;
    assign _unused_ena = ena;

    ///////////////////////////////////////////////////////////////////////////
    // Internal control signals (from gemm_control_unit)
    ///////////////////////////////////////////////////////////////////////////
    logic [ROWS-1:0]     h_pe_en;   // 1-bit scalar for ROWS=1
    logic [COLS-1:0]     v_pe_en;   // one per column
    logic [ACC_WIDTH-1:0] bias_bus;
    logic [COLS-1:0]     ld_bias;   // one-hot per column

    logic [COLS-1:0]     quant_en;  // per-column staggered enable
    logic                relu_en;
    logic [ACC_WIDTH-1:0] scale;

    ///////////////////////////////////////////////////////////////////////////
    // Internal datapath signals
    ///////////////////////////////////////////////////////////////////////////

    // Systolic array inputs
    logic [ROWS-1:0][ACT_WIDTH-1:0] i_col;   // i_col[row] — 1 row
    logic [COLS-1:0][WGT_WIDTH-1:0] w_row;   // w_row[col] — 3 columns

    // Accumulator outputs: 1D (ROWS=1, one acc per column)
    logic [COLS-1:0][ACC_WIDTH-1:0] sa_out;

    // col_out: direct wiring from sa_out (no mux; sa_out already 1D)
    logic [COLS-1:0][ACC_WIDTH-1:0] col_out;

    // Vector unit FP4 results: y_out[col][FP4_WIDTH-1:0]
    logic [COLS-1:0][FP4_WIDTH-1:0] y_out;

    ///////////////////////////////////////////////////////////////////////////
    // Activation and weight routing from input pins
    //
    // 1x3 mapping (during STREAM):
    //   ui_in[3:0]  -> a_row0 (single activation row)
    //   ui_in[7:4]  -> w_col0 (weight col 0)
    //   uio_in[3:0] -> w_col1 (weight col 1)
    //   uio_in[7:4] -> w_col2 (weight col 2)
    //
    // During non-STREAM phases: PE enables are 0, pins carry config/bias/scale.
    // These assignments are harmless don't-cares when PE enables are low.
    ///////////////////////////////////////////////////////////////////////////
    assign i_col[0] = ui_in[3:0];
    assign w_row[0] = ui_in[7:4];
    assign w_row[1] = uio_in[3:0];
    assign w_row[2] = uio_in[7:4];

    ///////////////////////////////////////////////////////////////////////////
    // col_out: direct wiring from sa_out
    // No column mux needed; sa_out[j] is the single accumulator for column j
    // (ROWS=1, no row index required).
    ///////////////////////////////////////////////////////////////////////////
    genvar j;
    generate
        for (j = 0; j < COLS; j++) begin : col_wire_gen
            assign col_out[j] = sa_out[j];
        end
    endgenerate

    ///////////////////////////////////////////////////////////////////////////
    // Control unit
    ///////////////////////////////////////////////////////////////////////////
    gemm_control_unit u_ctrl (
        .clk        (clk),
        .rst_n      (rst_n),
        .ui_in      (ui_in),
        .uio_in     (uio_in),
        .y_out_vec  (y_out),    // [COLS-1:0][FP4_WIDTH-1:0] — direct from VU

        .H_PE_EN    (h_pe_en),
        .V_PE_EN    (v_pe_en),
        .bias_bus   (bias_bus),
        .ld_bias    (ld_bias),

        .quant_en   (quant_en),
        .relu_en    (relu_en),
        .scale      (scale),
        // col_sel removed — no column mux in 1xN design

        .uio_out    (uio_out),
        .uio_oe     (uio_oe),
        .uo_out     (uo_out)
    );

    ///////////////////////////////////////////////////////////////////////////
    // Systolic array (1xN, ROWS=1, COLS=3)
    ///////////////////////////////////////////////////////////////////////////
    gemm_systolic_array u_sa (
        .clk        (clk),
        .i_col      (i_col),
        .w_row      (w_row),
        .h_pe_en    (h_pe_en),
        .v_pe_en    (v_pe_en),
        .bias       (bias_bus),
        .ld_bias    (ld_bias),
        .sa_out     (sa_out)
    );

    ///////////////////////////////////////////////////////////////////////////
    // Vector unit (COLS=3 lanes, one FP16->FP4 quantizer per column)
    // col_out feeds directly from sa_out (no pipeline flop).
    ///////////////////////////////////////////////////////////////////////////
    vector_unit u_vu (
        .clk        (clk),
        .relu_en    (relu_en),
        .quant_en   (quant_en),
        .col_out    (col_out),
        .scale      (scale),
        .y_out      (y_out)
    );

endmodule