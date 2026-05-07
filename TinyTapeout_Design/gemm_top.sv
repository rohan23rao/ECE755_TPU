///////////////////////////////////////////////////////////////////////////////
// Module: gemm_top.sv
// Description: Tiny Tapeout top-level wrapper for the FP4 GEMM 1x2 Core.
//
// Pin mapping:
//   ui_in[7:0]:
//     [0]    START pulse                              IDLE
//     [7:0]  K_LEN[7:0]                              CFG
//     [7:0]  bias/scale upper byte {FP16[15:8]}      LOAD
//     [3:0]  a_row0  (FP4 activation)                STREAM
//     [7:4]  w_col0  (FP4 weight, col 0)             STREAM
//
//   uio[7:0] bidirectional:
//     Input (uio_oe=0x00) during IDLE/CFG/LOAD/STREAM:
//       CFG    : [0]=RELU_EN, [1]=SKIP_BIAS, [2]=SKIP_SCALE, [4:3]=COL_CONFIG
//       LOAD   : [7:0] bias/scale lower byte {FP16[7:0]}
//       STREAM : [3:0]=w_col1
//     Output (uio_oe=0xFF) during DRAIN:
//       drain_cnt=0: [3:0]=y[0], [7:4]=0
//       drain_cnt=1: [3:0]=y[0], [7:4]=y[1]
//
//   uo_out[7:0] always output:
//     [2:0]  FSM state (IDLE=0,CFG=1,LOAD=2,STREAM=3,DRAIN=4)
//     [3]    busy
//     [4]    drain_active
//     [5]    drain_active && drain_cnt
//     [6]    tile_done
//     [7]    0
//
// Author: Group5
///////////////////////////////////////////////////////////////////////////////

module gemm_top #(
    parameter ROWS      = 1,
    parameter COLS      = 2,
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

    logic [COLS-1:0]                  quant_en;
    logic                             relu_en;
    logic [ACC_WIDTH-1:0]             scale;

    logic [ROWS-1:0][ACT_WIDTH-1:0]  i_col;
    logic [COLS-1:0][WGT_WIDTH-1:0]  w_row;
    logic [COLS-1:0][ACC_WIDTH-1:0]  sa_out;

    logic [COLS-1:0][FP4_WIDTH-1:0]  y_out_vec;

    ///////////////////////////////////////////////////////////////////////////
    // Input routing
    // i_col[0]  : activation (same for all columns — 1 row)
    // w_row[0]  : weight for col 0
    // w_row[1]  : weight for col 1
    // (col 2 removed)
    ///////////////////////////////////////////////////////////////////////////
    assign i_col[0] = ui_in[3:0];
    assign w_row[0] = ui_in[7:4];
    assign w_row[1] = uio_in[3:0];

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

        .uio_out    (uio_out),
        .uio_oe     (uio_oe),
        .uo_out     (uo_out)
    );

    ///////////////////////////////////////////////////////////////////////////
    // Systolic array (1x2, ROWS=1, COLS=2)
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
    // Vector unit (2 lanes)
    // sa_out feeds directly — no SA-to-VU pipeline register.
    // scale and quant_en come from CU (CU muxes correct column's scale).
    ///////////////////////////////////////////////////////////////////////////
    vector_unit u_vu (
        .clk        (clk),
        .relu_en    (relu_en),
        .quant_en   (quant_en),
        .col_out    (sa_out),
        .scale      (scale),
        .y_out      (y_out_vec)
    );

endmodule