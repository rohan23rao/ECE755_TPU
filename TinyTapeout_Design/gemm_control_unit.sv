///////////////////////////////////////////////////////////////////////////////
// Module: gemm_control_unit.sv
// Description: Control Unit for the FP4 GEMM Tiny Tapeout (1x2) design.
//
// Scale pre-loaded in LOAD phase:
//   LOAD cnt 0,1 : bias[0,1] → ld_bias one-hot, bias_bus = {ui_in,uio_in}
//   LOAD cnt 2,3 : scale_reg[0,1] captured from {ui_in,uio_in}
//
// quant_en stagger:
//   quant_en[0] = last STREAM cycle  (stream_cnt == K)
//   quant_en[1] = first DRAIN cycle  (drain_cnt == 0)
//
// DRAIN output table (1x2):
//   drain_cnt=0: uio_out = {4'b0,    y[0]}   (y[0] valid, y[1] still computing)
//   drain_cnt=1: uio_out = {y[1],    y[0]}   (both valid)
//
// uio_oe = 0xFF during DRAIN, 0x00 otherwise.
//
// uo_out encoding:
//   [2:0] = FSM state  (IDLE=0,CFG=1,LOAD=2,STREAM=3,DRAIN=4)
//   [3]   = busy       (state != IDLE)
//   [4]   = drain_active
//   [5]   = drain_active && drain_cnt
//   [6]   = tile_done
//   [7]   = 0
//   → IDLE=0x00, CFG=0x09, LOAD=0x0A, STREAM=0x0B,
//     DRAIN_cnt0=0x1C, DRAIN_cnt1=0x7C
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

    // FP4 results from 2-lane vector unit
    input  logic [COLS-1:0][FP4_WIDTH-1:0]  y_out_vec,

    // Systolic array control
    output logic [ROWS-1:0]          H_PE_EN,
    output logic [COLS-1:0]          V_PE_EN,
    output logic [ACC_WIDTH-1:0]     bias_bus,
    output logic [COLS-1:0]          ld_bias,

    // Vector unit control
    output logic [COLS-1:0]          quant_en,
    output logic                     relu_en,
    output logic [ACC_WIDTH-1:0]     scale,

    // TT pin outputs
    output logic [7:0]  uio_out,
    output logic [7:0]  uio_oe,
    output logic [7:0]  uo_out
);

    ///////////////////////////////////////////////////////////////////////////
    // FSM instantiation
    ///////////////////////////////////////////////////////////////////////////
    logic [2:0]  state;
    logic [2:0]  load_cnt;
    logic [8:0]  stream_cnt;
    logic [0:0]  drain_cnt;
    logic [7:0]  K_LEN_r;
    logic [1:0]  COL_CONFIG_r;
    logic        RELU_EN_r, SKIP_BIAS_r, SKIP_SCALE_r;
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
        .drain_cnt    (drain_cnt),
        .K_LEN_r      (K_LEN_r),
        .COL_CONFIG_r (COL_CONFIG_r),
        .RELU_EN_r    (RELU_EN_r),
        .SKIP_BIAS_r  (SKIP_BIAS_r),
        .SKIP_SCALE_r (SKIP_SCALE_r),
        .load_active  (load_active),
        .stream_active(stream_active),
        .drain_active (drain_active),
        .tile_done    (tile_done)
    );

    ///////////////////////////////////////////////////////////////////////////
    // PE enable chain
    // pe_en_0: active for stream_cnt 0..K-1
    // pe_en_1: pe_en_0 delayed 1 cycle (col 1 starts one cycle later)
    ///////////////////////////////////////////////////////////////////////////
    logic [8:0] K_ext;
    assign K_ext = {1'b0, K_LEN_r};

    logic pe_en_0, pe_en_1;
    assign pe_en_0 = stream_active && (stream_cnt < K_ext);

    always_ff @(posedge clk, negedge rst_n) begin
        if (!rst_n) pe_en_1 <= 1'b0;
        else        pe_en_1 <= pe_en_0;
    end

    assign H_PE_EN    = pe_en_0;
    assign V_PE_EN[0] = pe_en_0;
    assign V_PE_EN[1] = pe_en_1 & (COL_CONFIG_r >= 2'd1);

    ///////////////////////////////////////////////////////////////////////////
    // Bias load: ld_bias one-hot per column, bias_bus = {ui_in, uio_in}
    // Gated by !SKIP_BIAS_r; col j enabled when load_cnt == j
    ///////////////////////////////////////////////////////////////////////////
    always_comb begin
        ld_bias  = 2'b00;
        bias_bus = '0;
        if (load_active && !SKIP_BIAS_r) begin
            bias_bus = {ui_in, uio_in};
            if (load_cnt == 3'd0)                          ld_bias = 2'b01;
            if (load_cnt == 3'd1 && COL_CONFIG_r >= 2'd1) ld_bias = 2'b10;
        end
    end

    ///////////////////////////////////////////////////////////////////////////
    // Scale register capture
    // scale_reg[j] latches {ui_in,uio_in} at LOAD cnt == NCOLS+j
    //   NCOLS = {0,COL_CONFIG_r}+1; for 1x2: j=0→cnt=2, j=1→cnt=3
    // Gated by !SKIP_SCALE_r so bias-only tiles don't corrupt scale_reg.
    ///////////////////////////////////////////////////////////////////////////
    logic [COLS-1:0][ACC_WIDTH-1:0] scale_reg;

    always_ff @(posedge clk) begin
        if (load_active && !SKIP_SCALE_r) begin
            if (load_cnt == {1'b0, COL_CONFIG_r} + 3'd1)
                scale_reg[0] <= {ui_in, uio_in};
            if (load_cnt == {1'b0, COL_CONFIG_r} + 3'd2)
                scale_reg[1] <= {ui_in, uio_in};
        end
    end

    ///////////////////////////////////////////////////////////////////////////
    // quant_en stagger
    //   quant_en[0]: last STREAM cycle — col 0 accumulation complete
    //   quant_en[1]: first DRAIN cycle — col 1 accumulation complete
    //                (col 1 finishes 1 cycle after col 0 due to V_PE_EN delay)
    ///////////////////////////////////////////////////////////////////////////
    assign quant_en[0] = stream_active && (stream_cnt == K_ext);
    assign quant_en[1] = drain_active  && (drain_cnt == 1'b0);

    ///////////////////////////////////////////////////////////////////////////
    // Scale output mux: broadcast the correct column's scale to the VU
    //   quant_en[0]: scale_reg[0] (col 0 quantizing at end of STREAM)
    //   otherwise  : scale_reg[1] (col 1 quantizing at drain_cnt=0)
    ///////////////////////////////////////////////////////////////////////////
    assign scale   = quant_en[0] ? scale_reg[0] : scale_reg[1];
    assign relu_en = RELU_EN_r;

    ///////////////////////////////////////////////////////////////////////////
    // TT pin outputs
    ///////////////////////////////////////////////////////////////////////////

    // uio_oe: all output during DRAIN (host reads y), all input otherwise
    assign uio_oe = drain_active ? 8'hFF : 8'h00;

    // uio_out: DRAIN output table
    //   drain_cnt=0: {4'b0, y[0]}       — y[0] valid from last STREAM posedge
    //   drain_cnt=1: {y[1], y[0]}        — y[1] valid from drain_cnt=0 posedge
    assign uio_out = (!drain_active)      ? 8'h00                       :
                     (drain_cnt == 1'b0)  ? {4'b0000, y_out_vec[0]}     :
                                            {y_out_vec[1], y_out_vec[0]};

    // uo_out status bus
    assign uo_out[2:0] = state;
    assign uo_out[3]   = (state != 3'b000);        // busy
    assign uo_out[4]   = drain_active;
    assign uo_out[5]   = drain_active && drain_cnt[0];
    assign uo_out[6]   = tile_done;
    assign uo_out[7]   = 1'b0;

endmodule