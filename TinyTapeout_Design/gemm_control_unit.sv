///////////////////////////////////////////////////////////////////////////////
// Module: gemm_control_unit.sv
// Description: Control Unit for the FP4 GEMM Tiny Tapeout (1xN) design.
//              Wraps gemm_fsm and generates all hardware control signals.
//
// Responsibilities:
//   H_PE_EN / V_PE_EN  : stream-cycle-gated systolic enables
//   ld_bias / bias_bus  : one-hot column bias load from input bus in LOAD
//   scale_reg capture   : {ui_in, uio_in} stored on LOAD sub-phases NCOLS..2*NCOLS-1
//   quant_en            : per-column staggered drain sequencing (no col_sel)
//   scale               : muxed from scale_reg per active quant column
//   uio_oe / uio_out    : all-output during DRAIN, carries FP4 results
//   uo_out              : 8-bit status bus (always output)
//
// PE enable derivation for 1xN array (ROWS=1, 1 cycle per hop east):
//   H_PE_EN[0] = pe_en_0: active for stream_cnt in [0, K-1]  (scalar, ROWS=1)
//   V_PE_EN[0] = pe_en_0: col 0 active same window
//   V_PE_EN[1] = pe_en_1: col 1 delayed 1 cycle (if COL_CONFIG >= 1)
//   V_PE_EN[2] = pe_en_2: col 2 delayed 2 cycles (if COL_CONFIG == 2)
//
// Quant stagger (no SA-to-VU pipeline flop):
//   Col j < NCOLS-1: quant_en[j] fires at stream_cnt == K + j  (during STREAM)
//   Col NCOLS-1    : quant_en[NCOLS-1] fires at drain_cnt == 0 (during DRAIN)
//
// Drain output table (uio_out):
//   drain_cnt=0: 1x1 → 8'h00            1x2 → {0,y[0]}      1x3 → {y[1],y[0]}
//   drain_cnt=1: 1x1 → {4'b0,y[0]}      1x2 → {y[1],y[0]}   1x3 → {4'b0,y[2]}
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

    // Tiny Tapeout pin inputs
    input  logic [7:0]  ui_in,
    input  logic [7:0]  uio_in,

    // Vector unit FP4 result bus: y_out_vec[col][3:0]
    input  logic [COLS-1:0][FP4_WIDTH-1:0]  y_out_vec,

    // Systolic array control
    output logic [ROWS-1:0]     H_PE_EN,    // 1-bit for ROWS=1
    output logic [COLS-1:0]     V_PE_EN,    // one per column
    output logic [ACC_WIDTH-1:0] bias_bus,  // 16-bit bias to SA bias port
    output logic [COLS-1:0]     ld_bias,    // one-hot column bias load pulse

    // Vector unit control
    output logic [COLS-1:0]     quant_en,   // per-column quantization enable
    output logic                relu_en,    // ReLU enable from config register
    output logic [ACC_WIDTH-1:0] scale,     // scale muxed per active quant column

    // Tiny Tapeout pin outputs
    output logic [7:0]  uio_out,    // bidir data (FP4 results during DRAIN)
    output logic [7:0]  uio_oe,     // bidir output enable (FF during DRAIN)
    output logic [7:0]  uo_out      // status bus (always output)
);

    ///////////////////////////////////////////////////////////////////////////
    // FSM instantiation
    ///////////////////////////////////////////////////////////////////////////
    logic [2:0]  state;
    logic [2:0]  load_cnt;      // widened to [2:0] for 1xN
    logic [8:0]  stream_cnt;
    logic        drain_cnt;
    logic [7:0]  K_LEN_r;
    logic [1:0]  COL_CONFIG_r;  // 00=1x1, 01=1x2, 10=1x3
    logic        RELU_EN_r, SKIP_BIAS_r, SKIP_SCALE_r;
    logic        load_active, stream_active, drain_active, tile_done;

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
    //
    // pe_en_0: base enable, high while stream_cnt < K_LEN_r
    // pe_en_1: 1-cycle flop delay of pe_en_0 (col 1 stagger)
    // pe_en_2: 1-cycle flop delay of pe_en_1 (col 2 stagger)
    //
    // H_PE_EN: scalar (ROWS=1), always pe_en_0
    // V_PE_EN[j]: gated by COL_CONFIG_r to suppress non-existent columns
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

    assign H_PE_EN    = pe_en_0;                                  // scalar (ROWS=1)
    assign V_PE_EN[0] = pe_en_0;
    assign V_PE_EN[1] = pe_en_1 & (COL_CONFIG_r >= 2'd1);
    assign V_PE_EN[2] = pe_en_2 & (COL_CONFIG_r == 2'd2);

    ///////////////////////////////////////////////////////////////////////////
    // ld_bias and bias_bus
    //
    // LOAD sub-phases 0..NCOLS-1: one-hot ld_bias[j] per cycle.
    // bias_bus = {ui_in, uio_in}.
    // Skipped entirely when SKIP_BIAS_r is set (load_cnt jumps to NCOLS).
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
    // Scale registers
    //
    // NCOLS = COL_CONFIG_r + 1
    // scale_reg[j] captured at load_cnt == NCOLS + j = COL_CONFIG_r + 1 + j
    //   1x1: scale_reg[0] at load_cnt=1
    //   1x2: scale_reg[0] at load_cnt=2, scale_reg[1] at load_cnt=3
    //   1x3: scale_reg[0] at load_cnt=3, scale_reg[1] at load_cnt=4, [2] at 5
    //
    // Preserved across tiles when SKIP_SCALE_r is set.
    ///////////////////////////////////////////////////////////////////////////
    logic [ACC_WIDTH-1:0] scale_reg [0:COLS-1];

    always_ff @(posedge clk) begin
        if (load_active && !SKIP_SCALE_r) begin
            if (load_cnt == ({1'b0, COL_CONFIG_r} + 3'd1)) scale_reg[0] <= {ui_in, uio_in};
            if (load_cnt == ({1'b0, COL_CONFIG_r} + 3'd2)) scale_reg[1] <= {ui_in, uio_in};
            if (load_cnt == ({1'b0, COL_CONFIG_r} + 3'd3)) scale_reg[2] <= {ui_in, uio_in};
        end
    end

    ///////////////////////////////////////////////////////////////////////////
    // Quantization control
    //
    // Col j < NCOLS-1: quant_en[j] fires during STREAM at stream_cnt == K + j
    // Col NCOLS-1    : quant_en[NCOLS-1] fires during DRAIN at drain_cnt == 0
    //
    // Encoding by COL_CONFIG_r:
    //   1x1 (COL_CONFIG=0): only col 0, fires at drain_cnt==0
    //   1x2 (COL_CONFIG=1): col 0 fires at stream_cnt==K; col 1 at drain_cnt==0
    //   1x3 (COL_CONFIG=2): col 0 at K; col 1 at K+1; col 2 at drain_cnt==0
    //
    // scale: driven from scale_reg[j] matching the active quant column
    ///////////////////////////////////////////////////////////////////////////
    assign quant_en[0] = (COL_CONFIG_r == 2'd0) ? (drain_active  && drain_cnt == 1'b0)
                                                 : (stream_active && stream_cnt == K_ext);

    assign quant_en[1] = (COL_CONFIG_r == 2'd1) ? (drain_active  && drain_cnt == 1'b0)      :
                         (COL_CONFIG_r == 2'd2) ? (stream_active && stream_cnt == K_ext + 9'd1)
                                                : 1'b0;  // col 1 absent in 1x1

    assign quant_en[2] = (COL_CONFIG_r == 2'd2) && drain_active && (drain_cnt == 1'b0);

    // Scale: priority-mux on active quant column (only one fires per cycle)
    assign scale = quant_en[0] ? scale_reg[0] :
                   quant_en[1] ? scale_reg[1] :
                                 scale_reg[2];

    assign relu_en = RELU_EN_r;

    ///////////////////////////////////////////////////////////////////////////
    // Bidirectional pin control
    //
    // uio_oe: all-output during DRAIN, all-input otherwise
    // uio_out: drain output table (see module header)
    //   drain_cnt=0: 1x1→00  1x2→{0,y[0]}  1x3→{y[1],y[0]}
    //   drain_cnt=1: 1x1→{0,y[0]}  1x2→{y[1],y[0]}  1x3→{0,y[2]}
    ///////////////////////////////////////////////////////////////////////////
    assign uio_oe = drain_active ? 8'hFF : 8'h00;

    always_comb begin
        uio_out = 8'h00;
        if (drain_active) begin
            case (COL_CONFIG_r)
                2'd0: // 1x1
                    uio_out = drain_cnt ? {4'b0, y_out_vec[0]} : 8'h00;
                2'd1: // 1x2
                    uio_out = drain_cnt ? {y_out_vec[1], y_out_vec[0]}
                                       : {4'b0, y_out_vec[0]};
                default: // 1x3
                    uio_out = drain_cnt ? {4'b0, y_out_vec[2]}
                                       : {y_out_vec[1], y_out_vec[0]};
            endcase
        end
    end

    ///////////////////////////////////////////////////////////////////////////
    // Status bus: uo_out[7:0] (always output)
    //
    //   [2:0]  phase     : FSM state encoding
    //   [3]    busy      : 1 in any non-IDLE state
    //   [4]    drain_valid: 1 during both DRAIN cycles
    //   [5]    drain_cnt : 0=first drain cycle, 1=second
    //   [6]    tile_done : 1-cycle pulse on last DRAIN cycle
    //   [7]    BLANK
    ///////////////////////////////////////////////////////////////////////////
    assign uo_out[2:0] = state;
    assign uo_out[3]   = (state != 3'b000);
    assign uo_out[4]   = drain_active;
    assign uo_out[5]   = drain_active && drain_cnt;
    assign uo_out[6]   = tile_done;
    assign uo_out[7]   = 1'b0;

endmodule