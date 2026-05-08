///////////////////////////////////////////////////////////////////////////////
// Module: gemm_control_unit.sv
// Description: Control Unit for the FP4 GEMM Tiny Tapeout (1x2) design.
//
// Scale handling (new — single-VU):
//   Scale is NOT pre-loaded. During each DRAIN SCALE_LOAD phase the host drives
//   {ui_in[7:0], uio_in[7:0]} as the FP16 scale for the current column.
//   The CU bypasses this directly to the VU combinationally (no scale_reg).
//   quant_en fires for 1 cycle on drain_phase=0 (SCALE_LOAD).
//
// col_sel:
//   gemm_top muxes sa_out[col_sel] → VU col_out input.
//   col_sel = drain_col (from FSM).
//
// DRAIN output table:
//   SCALE_LOAD  (drain_phase=0): uio_oe=0x00 (host driving), uo_out[5]=0
//   RESULT_HOLD (drain_phase=1): uio_oe=0xFF, uio_out={4'b0, y_out}, uo_out[5]=1
//
// uo_out encoding:
//   [2:0] = state   (IDLE=0, CFG=1, LOAD=2, STREAM=3, DRAIN=4)
//   [3]   = busy    (state != IDLE)
//   [4]   = drain_active
//   [5]   = drain_phase  (0=SCALE_LOAD / 1=RESULT_HOLD)
//   [6]   = tile_done
//   [7]   = drain_col
//   → IDLE=0x00, CFG=0x09, LOAD=0x0A, STREAM=0x0B,
//     scale_col0=0x1C, result_col0=0x3C,
//     scale_col1=0x9C, result_col1=0xBC, tile_done=0xFC
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

    // FP4 result from single-lane vector unit
    input  logic [FP4_WIDTH-1:0]   y_out,

    // Systolic array control
    output logic [ROWS-1:0]        H_PE_EN,
    output logic [COLS-1:0]        V_PE_EN,
    output logic [ACC_WIDTH-1:0]   bias_bus,
    output logic [COLS-1:0]        ld_bias,

    // Vector unit control
    output logic                   quant_en,   // 1-bit: fires during SCALE_LOAD
    output logic                   relu_en,
    output logic [ACC_WIDTH-1:0]   scale,      // bypass: {ui_in,uio_in} during SCALE_LOAD

    // Column select for gemm_top sa_out mux
    output logic                   col_sel,    // = drain_col

    // TT pin outputs
    output logic [7:0]  uio_out,
    output logic [7:0]  uio_oe,
    output logic [7:0]  uo_out
);

    ///////////////////////////////////////////////////////////////////////////
    // FSM instantiation
    ///////////////////////////////////////////////////////////////////////////
    logic [2:0]  state;
    logic [0:0]  load_cnt;
    logic [8:0]  stream_cnt;
    logic        drain_col;
    logic        drain_phase;
    logic [7:0]  K_LEN_r;
    logic [1:0]  COL_CONFIG_r;
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
        .COL_CONFIG_r (COL_CONFIG_r),
        .RELU_EN_r    (RELU_EN_r),
        .SKIP_BIAS_r  (SKIP_BIAS_r),
        .load_active  (load_active),
        .stream_active(stream_active),
        .drain_active (drain_active),
        .tile_done    (tile_done)
    );

    ///////////////////////////////////////////////////////////////////////////
    // PE enable chain
    //   pe_en_0: active during stream_cnt 0..K-1
    //   pe_en_1: pe_en_0 delayed 1 cycle (col1 starts one hop later)
    ///////////////////////////////////////////////////////////////////////////
    logic [8:0] K_ext;
    assign K_ext = {1'b0, K_LEN_r};

    logic pe_en_0, pe_en_1;
    assign pe_en_0 = stream_active && (stream_cnt < K_ext);

    always_ff @(posedge clk, negedge rst_n) begin
        if (!rst_n) begin 
			pe_en_1 <= 1'b0;
		end
        else begin
			pe_en_1 <= pe_en_0;
		end
    end

    assign H_PE_EN    = pe_en_0;
    assign V_PE_EN[0] = pe_en_0;
    assign V_PE_EN[1] = pe_en_1 & (COL_CONFIG_r >= 2'd1);

    ///////////////////////////////////////////////////////////////////////////
    // Bias load
    //   LOAD cnt=0: ld_bias[0]; cnt=1: ld_bias[1] (for COL_CONFIG >= 1)
    //   bias_bus = {ui_in, uio_in} (host drives bias on the data pins)
    //   Gated by !SKIP_BIAS_r; LOAD state is skipped entirely when SKIP_BIAS.
    ///////////////////////////////////////////////////////////////////////////
    always_comb begin
        ld_bias  = 2'b00;
        bias_bus = '0;
        if (load_active && !SKIP_BIAS_r) begin
            bias_bus = {ui_in, uio_in};
            if (load_cnt == 1'b0) begin
				ld_bias = 2'b01;
			end
            if (load_cnt == 1'b1 && COL_CONFIG_r >= 2'd1) begin
				ld_bias = 2'b10;
			end
        end
    end

    ///////////////////////////////////////////////////////////////////////////
    // Scale (single-lane bypass)
    //   During DRAIN SCALE_LOAD (drain_phase=0): bypass {ui_in,uio_in} to VU.
    //   Otherwise: drive zero (quant_en deasserted, VU ignores).
    ///////////////////////////////////////////////////////////////////////////
    assign scale = (drain_active && !drain_phase) ? {ui_in, uio_in} : 16'b0;

    ///////////////////////////////////////////////////////////////////////////
    // quant_en: 1-bit, fires for exactly 1 cycle per column during SCALE_LOAD
    ///////////////////////////////////////////////////////////////////////////
    assign quant_en = drain_active && !drain_phase;

    ///////////////////////////////////////////////////////////////////////////
    // col_sel: tells gemm_top which column accumulator to route to the VU
    ///////////////////////////////////////////////////////////////////////////
    assign col_sel  = drain_col;
    assign relu_en  = RELU_EN_r;

    ///////////////////////////////////////////////////////////////////////////
    // TT pin outputs
    //
    // uio_oe:
    //   RESULT_HOLD (drain_active && drain_phase): 0xFF — device driving y_out
    //   All other states (including SCALE_LOAD): 0x00 — host driving (scale/bias)
    //
    // uio_out:
    //   RESULT_HOLD: {4'b0, y_out} — single-lane FP4 result in low nibble
    //   Otherwise  : 0x00
    ///////////////////////////////////////////////////////////////////////////
    assign uio_oe  = (drain_active && drain_phase) ? 8'hFF : 8'h00;
    assign uio_out = (drain_active && drain_phase) ? {4'b0000, y_out} : 8'h00;

    // uo_out status bus
    assign uo_out[2:0] = state;
    assign uo_out[3]   = (state != 3'b000);     // busy
    assign uo_out[4]   = drain_active;           // SCALE_RDY or Y_VLD
    assign uo_out[5]   = drain_active & drain_phase;            // 0=SCALE_LOAD, 1=RESULT_HOLD
    assign uo_out[6]   = tile_done;
    assign uo_out[7]   = drain_active & drain_col;
endmodule