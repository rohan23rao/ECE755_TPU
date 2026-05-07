///////////////////////////////////////////////////////////////////////////////
// Module: gemm_top.sv
// Description: Tiny Tapeout top-level wrapper for the FP4 GEMM 1xN Core.
//
// Pin mapping:
//   ui_in[7:0]:
//     [0]    START pulse                              IDLE
//     [7:0]  K_LEN[7:0]                              CFG
//     [7:0]  bias upper byte                          LOAD
//     [3:0]  a_row0  (FP4 activation)                STREAM
//     [7:4]  w_col0  (FP4 weight, col 0)             STREAM
//     [7:0]  scale upper byte (FP16[15:8])            FLUSH even cycles
//
//   uio[7:0] bidirectional:
//     Input (uio_oe=0x00) during IDLE/CFG/LOAD/STREAM and even FLUSH cycles:
//       CFG    : [0]=RELU_EN, [1]=SKIP_BIAS, [4:3]=COL_CONFIG
//       LOAD   : [7:0] bias lower byte
//       STREAM : [3:0]=w_col1, [7:4]=w_col2
//       FLUSH even: [7:0] scale lower byte (FP16[7:0])
//     Output (uio_oe=0xFF) during odd FLUSH cycles:
//       [7:4]  y_out[3:0]  FP4 quantized result
//       [3:0]  0
//
//   uo_out[7:0] always output:
//     [2:0]  FSM state
//     [3]    busy
//     [4]    result_valid  (odd FLUSH cycle, y_out valid on uio[7:4])
//     [5]    tile_done
//     [6]    flush_cnt[0]  (0=input phase, 1=output phase)
//     [7]    0
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
    input  logic        ena,

    input  logic [7:0]  ui_in,
    output logic [7:0]  uo_out,
    input  logic [7:0]  uio_in,
    output logic [7:0]  uio_out,
    output logic [7:0]  uio_oe
);

    // Tie off ena through a real gate to satisfy antenna/XOR checks
    logic _ena_tied;
    assign _ena_tied = ena & 1'b0;

    ///////////////////////////////////////////////////////////////////////////
    // Internal wires
    ///////////////////////////////////////////////////////////////////////////
    logic [ROWS-1:0]      h_pe_en;
    logic [COLS-1:0]      v_pe_en;
    logic [ACC_WIDTH-1:0] bias_bus;
    logic [COLS-1:0]      ld_bias;

    logic                 capture_en;
    logic                 relu_en;
    logic [1:0]           col_sel;

    logic [ROWS-1:0][ACT_WIDTH-1:0] i_col;
    logic [COLS-1:0][WGT_WIDTH-1:0] w_row;
    logic [COLS-1:0][ACC_WIDTH-1:0] sa_out;

    logic [ACC_WIDTH-1:0]           col_out_sel;
    logic [FP4_WIDTH-1:0]           y_out_wire;

    ///////////////////////////////////////////////////////////////////////////
    // Input routing (harmless don't-cares when PE enables are low)
    ///////////////////////////////////////////////////////////////////////////
    assign i_col[0] = ui_in[3:0];
    assign w_row[0] = ui_in[7:4];
    assign w_row[1] = uio_in[3:0];
    assign w_row[2] = uio_in[7:4];

    ///////////////////////////////////////////////////////////////////////////
    // Column mux: select SA accumulator for shared VU
    // col_sel = flush_cnt[2:1]; max index = COL_CONFIG_r <= 2
    ///////////////////////////////////////////////////////////////////////////
    assign col_out_sel = sa_out[col_sel];

    ///////////////////////////////////////////////////////////////////////////
    // Control unit
    ///////////////////////////////////////////////////////////////////////////
    gemm_control_unit u_ctrl (
        .clk          (clk),
        .rst_n        (rst_n),
        .ui_in        (ui_in),
        .uio_in       (uio_in),
        .y_out        (y_out_wire),

        .H_PE_EN      (h_pe_en),
        .V_PE_EN      (v_pe_en),
        .bias_bus     (bias_bus),
        .ld_bias      (ld_bias),

        .capture_en   (capture_en),
        .relu_en      (relu_en),
        .col_sel      (col_sel),

        .uio_out      (uio_out),
        .uio_oe       (uio_oe),
        .uo_out       (uo_out)
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
    // Shared vector unit
    // scale_in = {ui_in, uio_in}: full 16-bit scale on even FLUSH cycles.
    // On odd cycles uio_in reflects uio_out (pad loopback) but capture_en=0
    // so y_reg does not update — the loopback has no functional effect.
    ///////////////////////////////////////////////////////////////////////////
    vector_unit u_vu (
        .clk        (clk),
        .rst_n      (rst_n),
        .capture_en (capture_en),
        .relu_en    (relu_en),
        .col_out    (col_out_sel),
        .scale_in   ({ui_in, uio_in}),
        .y_out      (y_out_wire)
    );

endmodule