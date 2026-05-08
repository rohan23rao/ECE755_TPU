///////////////////////////////////////////////////////////////////////////////
// Module: gemm_top.sv
// Description: Tiny Tapeout top-level wrapper for the FP4 GEMM 1x2 Core.
//
// Pin mapping:
//   ui_in[7:0]:
//     [0]    TILE_START pulse                             IDLE
//     [7:0]  K_LEN[7:0]                                  CFG
//     [7:0]  bias upper byte {FP16[15:8]}                LOAD
//     [3:0]  a_row0  (FP4 activation)                    STREAM
//     [7:4]  w_col0  (FP4 weight, col 0)                 STREAM
//     [7:0]  scale upper byte {FP16[15:8]}               DRAIN SCALE_LOAD
//     [0]    Y_ACK                                       DRAIN RESULT_HOLD
//
//   uio[7:0] bidirectional:
//     Input (uio_oe=0x00) during IDLE/CFG/LOAD/STREAM/SCALE_LOAD:
//       CFG        : [0]=RELU_EN, [1]=SKIP_BIAS, [4:3]=COL_CONFIG
//       LOAD       : [7:0] bias lower byte {FP16[7:0]}
//       STREAM     : [3:0]=w_col1
//       SCALE_LOAD : [7:0] scale lower byte {FP16[7:0]}
//     Output (uio_oe=0xFF) during DRAIN RESULT_HOLD:
//       [3:0]=y_out (FP4 result for current column), [7:4]=0
//
//   uo_out[7:0] always output:
//     [2:0]  FSM state (IDLE=0, CFG=1, LOAD=2, STREAM=3, DRAIN=4)
//     [3]    busy
//     [4]    drain_active
//     [5]    drain_phase  (0=SCALE_LOAD, 1=RESULT_HOLD)
//     [6]    tile_done
//     [7]    drain_col
//     → IDLE=0x00, CFG=0x09, LOAD=0x0A, STREAM=0x0B,
//       scale_col0=0x1C, result_col0=0x3C,
//       scale_col1=0x9C, result_col1=0xBC, tile_done=0xFC
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
    logic [ROWS-1:0]       h_pe_en;
    logic [COLS-1:0]       v_pe_en;
    logic [ACC_WIDTH-1:0]  bias_bus;
    logic [COLS-1:0]       ld_bias;

    logic                  quant_en;       // 1-bit: fires once per SCALE_LOAD
    logic                  relu_en;
    logic [ACC_WIDTH-1:0]  scale;          // bypass from {ui_in, uio_in} in CU
    logic                  col_sel;        // drain_col: selects which SA column → VU

    logic [ROWS-1:0][ACT_WIDTH-1:0]   i_col;
    logic [COLS-1:0][WGT_WIDTH-1:0]   w_row;
    logic [COLS-1:0][ACC_WIDTH-1:0]   sa_out;

    logic [ACC_WIDTH-1:0]  col_out_to_vu; // single-column accumulator to VU
    logic [FP4_WIDTH-1:0]  y_out;         // single-lane FP4 result from VU

    ///////////////////////////////////////////////////////////////////////////
    // Input routing
    //   i_col[0]  : activation row 0 (same value feeds all columns — 1 row)
    //   w_row[0]  : weight for col 0
    //   w_row[1]  : weight for col 1
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
    // Column select mux
    //   Routes one column's accumulator to the single-lane VU.
    //   col_sel = drain_col; driven by CU during DRAIN.
    //   sa_out[col_sel] is valid for both columns by the time DRAIN starts.
    ///////////////////////////////////////////////////////////////////////////
    assign col_out_to_vu = sa_out[col_sel];

    ///////////////////////////////////////////////////////////////////////////
    // Vector unit (single lane)
    //   No SA-to-VU pipeline register — sa_out is directly valid at DRAIN entry.
    //   scale bypassed from {ui_in, uio_in} during SCALE_LOAD (no scale_reg).
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