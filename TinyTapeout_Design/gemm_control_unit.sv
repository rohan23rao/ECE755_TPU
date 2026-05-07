///////////////////////////////////////////////////////////////////////////////
// Module: gemm_control_unit.sv
// Description: Control Unit for the FP4 GEMM Tiny Tapeout (1xN) design.
//
// FLUSH ping-pong protocol (derived from flush_cnt[0]):
//   flush_cnt[0]=0 (even): uio_oe=0x00, host drives {ui_in,uio_in}=16-bit scale.
//     capture_en=1 → VU computes and latches y_reg this cycle.
//   flush_cnt[0]=1 (odd):  uio_oe=0xFF, chip drives y_out on uio_out[7:4].
//     result_valid=1, host reads y_out.
//
//   col_sel = flush_cnt[2:1]  (advances every 2 cycles)
//   FLUSH runs 2*NCOLS cycles total; tile_done on last odd cycle.
//
// Author: Group5
///////////////////////////////////////////////////////////////////////////////

module gemm_control_unit #(
    parameter ROWS      = 1,
    parameter COLS      = 3,
    parameter ACC_WIDTH = 16,
    parameter FP4_WIDTH = 4
) (
    input  logic        clk,
    input  logic        rst_n,

    input  logic [7:0]  ui_in,
    input  logic [7:0]  uio_in,

    // FP4 result from shared vector unit
    input  logic [FP4_WIDTH-1:0]    y_out,

    // Systolic array control
    output logic [ROWS-1:0]          H_PE_EN,
    output logic [COLS-1:0]          V_PE_EN,
    output logic [ACC_WIDTH-1:0]     bias_bus,
    output logic [COLS-1:0]          ld_bias,

    // Vector unit control
    output logic                     capture_en,  // even FLUSH cycles: latch VU result
    output logic                     relu_en,
    output logic [1:0]               col_sel,     // selects SA column to feed VU

    // TT pin outputs
    output logic [7:0]  uio_out,
    output logic [7:0]  uio_oe,
    output logic [7:0]  uo_out
);

    ///////////////////////////////////////////////////////////////////////////
    // FSM
    ///////////////////////////////////////////////////////////////////////////
    logic [2:0]  state;
    logic [2:0]  load_cnt;
    logic [8:0]  stream_cnt;
    logic [2:0]  flush_cnt;
    logic [7:0]  K_LEN_r;
    logic [1:0]  COL_CONFIG_r;
    logic        RELU_EN_r, SKIP_BIAS_r;
    logic        load_active, stream_active, flush_active;
    logic        tile_done;

    gemm_fsm u_fsm (
        .clk          (clk),
        .rst_n        (rst_n),
        .ui_in        (ui_in),
        .uio_in       (uio_in),
        .state_out    (state),
        .load_cnt     (load_cnt),
        .stream_cnt   (stream_cnt),
        .flush_cnt    (flush_cnt),
        .K_LEN_r      (K_LEN_r),
        .COL_CONFIG_r (COL_CONFIG_r),
        .RELU_EN_r    (RELU_EN_r),
        .SKIP_BIAS_r  (SKIP_BIAS_r),
        .load_active  (load_active),
        .stream_active(stream_active),
        .flush_active (flush_active),
        .tile_done    (tile_done)
    );

    ///////////////////////////////////////////////////////////////////////////
    // PE enable chain
    ///////////////////////////////////////////////////////////////////////////
    logic [8:0] K_ext;
    assign K_ext = {1'b0, K_LEN_r};

    logic pe_en_0, pe_en_1, pe_en_2;
    assign pe_en_0 = stream_active && (stream_cnt < K_ext);

    always_ff @(posedge clk, negedge rst_n) begin
        if (!rst_n) begin
            pe_en_1 <= 1'b0;
            pe_en_2 <= 1'b0;
        end else begin
            pe_en_1 <= pe_en_0;
            pe_en_2 <= pe_en_1;
        end
    end

    assign H_PE_EN    = pe_en_0;
    assign V_PE_EN[0] = pe_en_0;
    assign V_PE_EN[1] = pe_en_1 & (COL_CONFIG_r >= 2'd1);
    assign V_PE_EN[2] = pe_en_2 & (COL_CONFIG_r == 2'd2);

    ///////////////////////////////////////////////////////////////////////////
    // ld_bias and bias_bus
    ///////////////////////////////////////////////////////////////////////////
    always_comb begin
        ld_bias  = 3'b000;
        bias_bus = '0;
        if (load_active && !SKIP_BIAS_r) begin
            bias_bus = {ui_in, uio_in};
            if (load_cnt == 3'd0)                          ld_bias = 3'b001;
            if (load_cnt == 3'd1 && COL_CONFIG_r >= 2'd1) ld_bias = 3'b010;
            if (load_cnt == 3'd2 && COL_CONFIG_r == 2'd2) ld_bias = 3'b100;
        end
    end

    ///////////////////////////////////////////////////////////////////////////
    // FLUSH ping-pong control
    //
    // flush_cnt[0]=0 (even): input  phase — host drives scale, VU captures
    // flush_cnt[0]=1 (odd) : output phase — chip drives y_out, host reads
    //
    // col_sel advances every 2 cycles: flush_cnt[2:1]
    ///////////////////////////////////////////////////////////////////////////
    assign capture_en = flush_active && !flush_cnt[0];
    assign col_sel    = flush_cnt[2:1];
    assign relu_en    = RELU_EN_r;

    assign uio_oe  = (flush_active &&  flush_cnt[0]) ? 8'hFF : 8'h00;
    assign uio_out = (flush_active &&  flush_cnt[0]) ? {y_out, 4'b0000} : 8'h00;

    ///////////////////////////////////////////////////////////////////////////
    // Status bus uo_out[7:0]
    //
    //   [2:0]  phase        : FSM state
    //   [3]    busy         : non-IDLE
    //   [4]    result_valid : odd FLUSH cycle — y_out is valid on uio_out[7:4]
    //   [5]    tile_done    : 1-cycle pulse on last FLUSH cycle
    //   [6]    flush_cnt[0] : ping-pong phase indicator (0=input, 1=output)
    //   [7]    0
    ///////////////////////////////////////////////////////////////////////////
    assign uo_out[2:0] = state;
    assign uo_out[3]   = (state != 3'b000);
    assign uo_out[4]   = flush_active && flush_cnt[0];
    assign uo_out[5]   = tile_done;
    assign uo_out[6]   = flush_cnt[0];
    assign uo_out[7]   = 1'b0;

endmodule