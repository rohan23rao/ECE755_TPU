///////////////////////////////////////////////////////////////////////////////
// Module: gemm_top.sv
// Description: Tiny Tapeout wrapper — FP4 GEMM 1x2 (hardcoded).
//
// Pin mapping:
//   ui_in[7:0]:
//     [0]    TILE_START / Y_ACK (context-dependent: IDLE / DRAIN RESULT_HOLD)
//     [3:0]  K_LEN[3:0]  (CFG; max K=15; upper nibble unused during CFG)
//     [7:0]  bias[15:8]  (LOAD)
//     [3:0]  a_row0      (STREAM, FP4 activation)
//     [7:4]  w_col0      (STREAM, FP4 weight col 0)
//     [7:0]  scale[15:8] (DRAIN SCALE_LOAD)
//
//   uio[7:0] bidirectional:
//     Input (uio_oe=0x00) — IDLE/CFG/LOAD/STREAM/SCALE_LOAD:
//       CFG        : [0]=RELU_EN, [1]=SKIP_BIAS  ([4:3] freed — was COL_CONFIG)
//       LOAD       : [7:0] bias[7:0]
//       STREAM     : [3:0]=w_col1, [5]=DATA_VLD
//       SCALE_LOAD : [7:0] scale[7:0]
//     Output (uio_oe=0xFF) — DRAIN RESULT_HOLD:
//       [3:0]=y_out (FP4 result for current column), [7:4]=0
//
//   uo_out[7:0] (always output):
//     [2:0]=state  [3]=busy  [4]=drain_active  [5]=drain_phase
//     [6]=tile_done  [7]=drain_col
//     IDLE=0x00 CFG=0x09 LOAD=0x0A STREAM=0x0B
//     scale_col0=0x1C result_col0=0x3C
//     scale_col1=0x9C result_col1=0xBC tile_done=0xFC
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

    logic _ena_tied;
    assign _ena_tied = ena & 1'b0;

    ///////////////////////////////////////////////////////////////////////////
    // Internal wires
    ///////////////////////////////////////////////////////////////////////////
    logic [COLS-1:0]       pe_en;       // pre-computed per-column enables
    logic [ACC_WIDTH-1:0]  bias_bus;
    logic [COLS-1:0]       ld_bias;

    logic                  quant_en;
    logic                  relu_en;
    logic [ACC_WIDTH-1:0]  scale;
    logic                  col_sel;
    logic                  data_vld;

    logic [ROWS-1:0][ACT_WIDTH-1:0]   i_col;
    logic [COLS-1:0][WGT_WIDTH-1:0]   w_row;
    logic [COLS-1:0][ACC_WIDTH-1:0]   sa_out;

    logic [ACC_WIDTH-1:0]  col_out_to_vu;
    logic [FP4_WIDTH-1:0]  y_out;

    ///////////////////////////////////////////////////////////////////////////
    // Input routing
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
        .y_out      (y_out),

        .PE_EN      (pe_en),
        .bias_bus   (bias_bus),
        .ld_bias    (ld_bias),

        .quant_en   (quant_en),
        .relu_en    (relu_en),
        .scale      (scale),
        .col_sel    (col_sel),
        .data_vld   (data_vld),

        .uio_out    (uio_out),
        .uio_oe     (uio_oe),
        .uo_out     (uo_out)
    );

    ///////////////////////////////////////////////////////////////////////////
    // Systolic array (1x2)
    ///////////////////////////////////////////////////////////////////////////
    gemm_systolic_array u_sa (
        .clk        (clk),
        .i_col      (i_col),
        .w_row      (w_row),
        .pe_en      (pe_en),
        .bias       (bias_bus),
        .ld_bias    (ld_bias),
        .data_vld   (data_vld),
        .sa_out     (sa_out)
    );

    ///////////////////////////////////////////////////////////////////////////
    // Column select mux
    ///////////////////////////////////////////////////////////////////////////
    assign col_out_to_vu = sa_out[col_sel];

    ///////////////////////////////////////////////////////////////////////////
    // Vector unit (single lane)
    ///////////////////////////////////////////////////////////////////////////
    vector_unit u_vu (
        .clk        (clk),
        .relu_en    (relu_en),
        .quant_en   (quant_en),
        .col_out    (col_out_to_vu),
        .scale      (scale),
        .y_out      (y_out)
    );

endmodule