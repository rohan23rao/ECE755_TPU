///////////////////////////////////////////////////////////////////////////////
// Module: gemm_top.sv
// Description: Tiny Tapeout top-level wrapper for the FP4 GEMM 2x2 Core.
//
// Integrates:
//   gemm_control_unit  : FSM + all datapath control signals
//   gemm_systolic_array: 2x2 output-stationary PE mesh
//   vector_unit        : 2-lane FP16->FP4 quantizer
//
// Pin mapping:
//   ui_in[7:0]  : primary input bus
//     [3:0]  a_row0 (FP4 activation, row 0) during STREAM
//     [7:4]  a_row1 (FP4 activation, row 1) during STREAM
//     [7:0]  K_LEN[7:0]                     during CFG
//     [7:0]  bias/scale upper byte           during LOAD
//     [0]    START pulse                     during IDLE
//
//   uio[7:0] : bidirectional bus, direction set per phase
//     Input during IDLE/CFG/LOAD/STREAM:
//       [2:0]  {SKIP_SCALE, SKIP_BIAS, RELU_EN}  during CFG
//       [7:0]  bias/scale lower byte              during LOAD
//       [3:0]  w_col0 (FP4 weight, col 0)         during STREAM
//       [7:4]  w_col1 (FP4 weight, col 1)         during STREAM
//     Output during DRAIN:
//       [3:0]  y_row0 (FP4 result, row 0 of current column)
//       [7:4]  y_row1 (FP4 result, row 1 of current column)
//
//   uo_out[7:0] : status bus (always output, never carries data)
//     [2:0]  phase[2:0]   FSM state
//     [3]    busy
//     [4]    drain_valid
//     [5]    drain_col    0=col0, 1=col1
//     [6]    tile_done    1-cycle pulse
//     [7]    reserved (0)
//
// Data flow:
//   Activations : ui_in[3:0]/[7:4] -> i_col[0]/[1] -> systolic array
//   Weights     : uio_in[3:0]/[7:4] -> w_row[0]/[1] -> systolic array
//   Accumulators: sa_out[col_sel][row] -> col_out[row] -> vector unit
//   Results     : y_out[1:0] -> {uio_out[7:4], uio_out[3:0]} during DRAIN
//
// Note: No pipeline flop between systolic array and vector unit (removed
//       vs. original 8x8 design; wire distances are negligible in 2x2).
//
// Author: Group5
///////////////////////////////////////////////////////////////////////////////

module gemm_top #(
    parameter ARRAY_SIZE = 2,
    parameter ACT_WIDTH  = 4,
    parameter WGT_WIDTH  = 4,
    parameter ACC_WIDTH  = 16,
    parameter FP4_WIDTH  = 4
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
    logic [ARRAY_SIZE-1:0]  h_pe_en;
    logic [ARRAY_SIZE-1:0]  v_pe_en;
    logic [ACC_WIDTH-1:0]   bias_bus;
    logic [ARRAY_SIZE-1:0]  ld_bias;

    logic [ARRAY_SIZE-1:0]  quant_en;
    logic                   relu_en;
    logic [ACC_WIDTH-1:0]   scale;
    logic                   col_sel;

    logic [7:0]             y_out_vec;  // {y_out[1][3:0], y_out[0][3:0]}

    ///////////////////////////////////////////////////////////////////////////
    // Internal datapath signals
    ///////////////////////////////////////////////////////////////////////////

    // Systolic array inputs
    logic [ARRAY_SIZE-1:0][ACT_WIDTH-1:0] i_col;   // activations: i_col[row]
    logic [ARRAY_SIZE-1:0][WGT_WIDTH-1:0] w_row;   // weights:     w_row[col]

    // Full accumulator output mesh: sa_out[col][row][ACC_WIDTH-1:0]
    logic [ARRAY_SIZE-1:0][ARRAY_SIZE-1:0][ACC_WIDTH-1:0] sa_out;

    // Column-selected output feeding vector unit (no pipeline flop)
    logic [ARRAY_SIZE-1:0][ACC_WIDTH-1:0] col_out;

    // Vector unit FP4 results: y_out[lane][FP4_WIDTH-1:0]
    logic [ARRAY_SIZE-1:0][FP4_WIDTH-1:0] y_out;

    ///////////////////////////////////////////////////////////////////////////
    // Activation and weight routing from input pins
    //
    // During STREAM:  ui_in[3:0]=a_row0, ui_in[7:4]=a_row1
    //                 uio_in[3:0]=w_col0, uio_in[7:4]=w_col1
    // During non-STREAM phases: PE enables are 0 so data is gated; pins carry
    // config/bias/scale and these assignments are harmless don't-cares.
    ///////////////////////////////////////////////////////////////////////////
    assign i_col[0] = ui_in[3:0];
    assign i_col[1] = ui_in[7:4];
    assign w_row[0] = uio_in[3:0];
    assign w_row[1] = uio_in[7:4];

    ///////////////////////////////////////////////////////////////////////////
    // Column mux: select one column of accumulators to feed vector unit.
    // col_sel driven by control unit:
    //   0 -> col 0 (STREAM last cycle, quant_col0)
    //   1 -> col 1 (DRAIN cnt=0,       quant_col1)
    // sa_out[col][row] is col-major; direct index by col_sel.
    // No pipeline register (original gemm_top col_out_pipe removed).
    ///////////////////////////////////////////////////////////////////////////
    genvar row;
    generate
        for (row = 0; row < ARRAY_SIZE; row++) begin : col_mux_gen
            assign col_out[row] = col_sel ? sa_out[1][row] : sa_out[0][row];
        end
    endgenerate

    ///////////////////////////////////////////////////////////////////////////
    // Pack vector unit y_out for control unit result bus
    // uio_out[3:0] = row 0 result (lane 0), uio_out[7:4] = row 1 (lane 1)
    ///////////////////////////////////////////////////////////////////////////
    assign y_out_vec = {y_out[1], y_out[0]};

    ///////////////////////////////////////////////////////////////////////////
    // Control unit
    ///////////////////////////////////////////////////////////////////////////
    gemm_control_unit u_ctrl (
        .clk        (clk),
        .rst_n      (rst_n),
        .ui_in      (ui_in),
        .uio_in     (uio_in),
        .y_out_vec  (y_out_vec),

        .H_PE_EN    (h_pe_en),
        .V_PE_EN    (v_pe_en),
        .bias_bus   (bias_bus),
        .ld_bias    (ld_bias),

        .quant_en   (quant_en),
        .relu_en    (relu_en),
        .scale      (scale),
        .col_sel    (col_sel),

        .uio_out    (uio_out),
        .uio_oe     (uio_oe),
        .uo_out     (uo_out)
    );

    ///////////////////////////////////////////////////////////////////////////
    // Systolic array (2x2)
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
    // Vector unit (2 lanes, one FP16->FP4 quantizer per row)
    // col_out feeds directly from the col mux (no pipeline flop).
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