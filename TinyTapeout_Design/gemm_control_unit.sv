///////////////////////////////////////////////////////////////////////////////
// Module: gemm_control_unit.sv
// Description: Control Unit — FP4 GEMM Tiny Tapeout, hardcoded 1x2.
//
// Hardcoded 1x2 simplifications:
//   - COL_CONFIG removed.
//   - PE_EN[1:0] replaces H_PE_EN + V_PE_EN: pre-computed and routed
//     directly to each PE, eliminating h_en/v_en_mesh routing and the
//     redundant AND gates inside each PE.
//   - K_LEN_r: 4-bit (max K=15). stream_cnt: 4-bit.
//   - stream_exit = K_LEN_r (direct wire, no adder).
//   - data_vld gates pe_en_1 register and stream_cnt in FSM.
//
// uo_out encoding:
//   [2:0]=state, [3]=busy, [4]=drain_active, [5]=drain_phase,
//   [6]=tile_done, [7]=drain_col
//   IDLE=0x00, CFG=0x09, LOAD=0x0A, STREAM=0x0B,
//   scale_col0=0x1C, result_col0=0x3C,
//   scale_col1=0x9C, result_col1=0xBC, tile_done=0xFC
//
// Author: Group5
///////////////////////////////////////////////////////////////////////////////

module gemm_control_unit #(
    parameter ROWS      = 1,
    parameter COLS      = 2,
    parameter ACC_WIDTH = 16,
    parameter FP4_WIDTH = 4
) (
    input  logic        clk,
    input  logic        rst_n,

    input  logic [7:0]  ui_in,
    input  logic [7:0]  uio_in,

    input  logic [FP4_WIDTH-1:0]   y_out,

    // Systolic array control
    output logic [COLS-1:0]        PE_EN,       // pre-computed per-PE enable
    output logic [ACC_WIDTH-1:0]   bias_bus,
    output logic [COLS-1:0]        ld_bias,

    // Vector unit control
    output logic                   quant_en,
    output logic                   relu_en,
    output logic [ACC_WIDTH-1:0]   scale,

    // Column select for gemm_top sa_out mux
    output logic                   col_sel,

    // DATA_VLD — pipeline freeze signal to SA
    output logic                   data_vld,

    // TT pin outputs
    output logic [7:0]  uio_out,
    output logic [7:0]  uio_oe,
    output logic [7:0]  uo_out
);

    ///////////////////////////////////////////////////////////////////////////
    // FSM
    ///////////////////////////////////////////////////////////////////////////
    logic [2:0]  state;
    logic [0:0]  load_cnt;
    logic [3:0]  stream_cnt;
    logic        drain_col, drain_phase;
    logic [3:0]  K_LEN_r;
    logic        RELU_EN_r, SKIP_BIAS_r;
    logic        load_active, stream_active, drain_active;
    logic        tile_done;

    gemm_fsm u_fsm (
        .clk          (clk),
        .rst_n        (rst_n),
        .ui_in        (ui_in),
        .uio_in       (uio_in),
        .state_out    (state),
        .load_cnt     (load_cnt),
        .stream_cnt   (stream_cnt),
        .drain_col    (drain_col),
        .drain_phase  (drain_phase),
        .K_LEN_r      (K_LEN_r),
        .RELU_EN_r    (RELU_EN_r),
        .SKIP_BIAS_r  (SKIP_BIAS_r),
        .load_active  (load_active),
        .stream_active(stream_active),
        .drain_active (drain_active),
        .tile_done    (tile_done)
    );

    ///////////////////////////////////////////////////////////////////////////
    // DATA_VLD — only high in STREAM when host signals valid data
    ///////////////////////////////////////////////////////////////////////////
    assign data_vld = stream_active & uio_in[5];

    ///////////////////////////////////////////////////////////////////////////
    // PE enable chain (4-bit comparison; stream_exit = K_LEN_r, no adder)
    //   pe_en_0: active for stream_cnt 0..K-1
    //   pe_en_1: pe_en_0 delayed 1 valid cycle (col1 stagger)
    //            CE = data_vld: stall cycles don't advance the stagger
    ///////////////////////////////////////////////////////////////////////////
    logic pe_en_0, pe_en_1;
    assign pe_en_0 = stream_active && (stream_cnt < K_LEN_r);

    always_ff @(posedge clk, negedge rst_n) begin
        if (!rst_n)        pe_en_1 <= 1'b0;
        else if (data_vld) pe_en_1 <= pe_en_0;
    end

    assign PE_EN[0] = pe_en_0;
    assign PE_EN[1] = pe_en_1;   // hardcoded 1x2: always active when pe_en_1

    ///////////////////////////////////////////////////////////////////////////
    // Bias load (hardcoded 1x2: always load both cols)
    ///////////////////////////////////////////////////////////////////////////
    always_comb begin
        ld_bias  = 2'b00;
        bias_bus = '0;
        if (load_active && !SKIP_BIAS_r) begin
            bias_bus = {ui_in, uio_in};
            if (load_cnt == 1'b0) ld_bias = 2'b01;  // col0
            if (load_cnt == 1'b1) ld_bias = 2'b10;  // col1
        end
    end

    ///////////////////////////////////////////////////////////////////////////
    // Scale bypass and quant_en
    ///////////////////////////////////////////////////////////////////////////
    assign scale    = (drain_active && !drain_phase) ? {ui_in, uio_in} : 16'b0;
    assign quant_en = drain_active && !drain_phase;
    assign col_sel  = drain_col;
    assign relu_en  = RELU_EN_r;

    ///////////////////////////////////////////////////////////////////////////
    // TT pin outputs
    ///////////////////////////////////////////////////////////////////////////
    assign uio_oe  = (drain_active && drain_phase) ? 8'hFF : 8'h00;
    assign uio_out = (drain_active && drain_phase) ? {4'b0000, y_out} : 8'h00;

    assign uo_out[2:0] = state;
    assign uo_out[3]   = (state != 3'b000);
    assign uo_out[4]   = drain_active;
    assign uo_out[5]   = drain_active & drain_phase;
    assign uo_out[6]   = tile_done;
    assign uo_out[7]   = drain_active & drain_col;

endmodule