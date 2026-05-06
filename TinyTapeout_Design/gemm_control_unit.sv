///////////////////////////////////////////////////////////////////////////////
// Module: gemm_control_unit.sv
// Description: Control Unit for the FP4 GEMM Tiny Tapeout (2x2) design.
//              Wraps gemm_tt_fsm and generates all hardware control signals.
//
// Responsibilities:
//   H_PE_EN / V_PE_EN  : stream-cycle-gated systolic enables
//   ld_bias / bias_bus  : one-hot column bias load from input bus in LOAD
//   scale_reg capture   : {ui_in, uio_in} stored on LOAD sub-phases 2 and 3
//   quant_en / col_sel  : drain sequencing (col 0 overlaps last STREAM cycle)
//   scale               : muxed from scale_reg[0] or scale_reg[1]
//   uio_oe / uio_out    : all-output during DRAIN, carries FP4 results
//   uo_out              : 8-bit status bus (always output)
//
// PE enable derivation for 2x2 array (1 cycle per hop east and south):
//   H_PE_EN[0], V_PE_EN[0]: active for stream_cnt in [0, K-1]
//   H_PE_EN[1], V_PE_EN[1]: active for stream_cnt in [1, K]
//   Results in:
//     PE[0][0] enabled cycles 0..K-1    (K MACs)
//     PE[0][1] enabled cycles 1..K      (K MACs, h_en delayed 1 cycle)
//     PE[1][0] enabled cycles 1..K      (K MACs, v_en delayed 1 cycle)
//     PE[1][1] enabled cycles 2..K+1    (K MACs, both enables delayed)
//
// Drain sequence (no SA-to-VU pipeline flop):
//   STREAM cnt=K+1   quant_en=11, col_sel=0, scale=scale_reg[0]
//                    -> reg_out latches col 0 at end of cycle
//   DRAIN  cnt=0     quant_en=11, col_sel=1, scale=scale_reg[1]
//                    -> y_out shows col 0; reg_out latches col 1 at end
//   DRAIN  cnt=1     quant_en=00
//                    -> y_out shows col 1; tile_done pulses
//
// Author: Group5
///////////////////////////////////////////////////////////////////////////////

module gemm_control_unit #(
    parameter ARRAY_SIZE = 2,
    parameter ACC_WIDTH  = 16,
    parameter FP4_WIDTH  = 4
) (
    input  logic        clk,
    input  logic        rst_n,

    // Tiny Tapeout pin inputs
    input  logic [7:0]  ui_in,
    input  logic [7:0]  uio_in,

    // Vector unit FP4 result bus {lane1[3:0], lane0[3:0]} (from vector unit y_out)
    input  logic [7:0]  y_out_vec,

    // Systolic array control
    output logic [ARRAY_SIZE-1:0]   H_PE_EN,    // horizontal enables to left boundary
    output logic [ARRAY_SIZE-1:0]   V_PE_EN,    // vertical enables to top boundary
    output logic [ACC_WIDTH-1:0]    bias_bus,   // 16-bit bias driven to SA bias port
    output logic [ARRAY_SIZE-1:0]   ld_bias,    // one-hot column bias load pulse

    // Vector unit control
    output logic [ARRAY_SIZE-1:0]   quant_en,   // quantization enable (both lanes)
    output logic                    relu_en,    // ReLU enable from config register
    output logic [ACC_WIDTH-1:0]    scale,      // scale muxed from scale_reg[0/1]
    output logic                    col_sel,    // 0=sa_out[col0], 1=sa_out[col1]

    // Tiny Tapeout pin outputs
    output logic [7:0]  uio_out,    // bidir data (FP4 results during DRAIN)
    output logic [7:0]  uio_oe,     // bidir output enable (FF during DRAIN)
    output logic [7:0]  uo_out      // status bus (always output)
);

    ///////////////////////////////////////////////////////////////////////////
    // FSM instantiation
    ///////////////////////////////////////////////////////////////////////////
    logic [2:0] state;
    logic [1:0] load_cnt;
    logic [8:0] stream_cnt;
    logic       drain_cnt;
    logic [7:0] K_LEN_r;
    logic       RELU_EN_r, SKIP_BIAS_r, SKIP_SCALE_r;
    logic       load_active, stream_active, drain_active, tile_done;

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
        .RELU_EN_r    (RELU_EN_r),
        .SKIP_BIAS_r  (SKIP_BIAS_r),
        .SKIP_SCALE_r (SKIP_SCALE_r),
        .load_active  (load_active),
        .stream_active(stream_active),
        .drain_active (drain_active),
        .tile_done    (tile_done)
    );

    ///////////////////////////////////////////////////////////////////////////
    // Scale registers
    // Captured from {ui_in, uio_in} on LOAD sub-phases 2 and 3.
    // Preserved across tiles when SKIP_SCALE_r is set.
    ///////////////////////////////////////////////////////////////////////////
    logic [ACC_WIDTH-1:0] scale_reg [0:1];

    always_ff @(posedge clk) begin
        if (load_active && !SKIP_SCALE_r) begin
            if (load_cnt == 2'd2) begin
				scale_reg[0] <= {ui_in, uio_in};
			end
            if (load_cnt == 2'd3) begin
				scale_reg[1] <= {ui_in, uio_in};
			end
        end
    end

    ///////////////////////////////////////////////////////////////////////////
    // H_PE_EN and V_PE_EN Shared due to 2x2 Square 
    //
    // H_PE_EN[0] / V_PE_EN[0]: gate row 0 and col 0 boundary enables.
    //   Active while stream_cnt < K_LEN_r so PE[0][0] sees K enable pulses
    //   (cycles 0..K-1).
    //
    // H_PE_EN[1] / V_PE_EN[1]: 1-Cycle Delay from *_PE_EN[0]
    ///////////////////////////////////////////////////////////////////////////
    logic [8:0] K_ext;
	assign K_ext = {1'b0, K_LEN_r};

	logic pe_en_0;
	logic pe_en_1;

	assign pe_en_0 = stream_active && (stream_cnt < K_ext);

	always_ff @(posedge clk, negedge rst_n) begin
		if (!rst_n) begin
			pe_en_1 <= 1'b0;
		end
		else begin
			pe_en_1 <= pe_en_0;
		end
	end

	assign H_PE_EN[0] = pe_en_0;
	assign V_PE_EN[0] = pe_en_0;
	assign H_PE_EN[1] = pe_en_1;
	assign V_PE_EN[1] = pe_en_1;

    ///////////////////////////////////////////////////////////////////////////
    // ld_bias and bias_bus
    //
    // LOAD sub-phase 0: ld_bias[0]=1, col 0 PE accumulators load bias value.
    // LOAD sub-phase 1: ld_bias[1]=1, col 1 PE accumulators load bias value.
    // bias_bus = {ui_in[7:0], uio_in[7:0]} (16-bit input bus).
    // Skipped entirely when SKIP_BIAS_r is set (counter jumps from 0 to 2).
    ///////////////////////////////////////////////////////////////////////////
    always_comb begin
        ld_bias  = 2'b00;
        bias_bus = '0;
        if (load_active && !SKIP_BIAS_r) begin
            bias_bus = {ui_in, uio_in};
            if (load_cnt == 2'd0) begin 
				ld_bias = 2'b01;
			end
            if (load_cnt == 2'd1) begin
				ld_bias = 2'b10;
			end
        end
    end

    ///////////////////////////////////////////////////////////////////////////
    // Quantization control
    //
    // quant_col0: fires on the last STREAM cycle (stream_cnt == K+1).
    //   Reads sa_out[col 0], vector unit latches result at end of cycle.
    //   col 0 FP4 values appear on y_out in DRAIN cycle 0.
    //
    // quant_col1: fires on DRAIN cycle 0 (drain_cnt == 0).
    //   Reads sa_out[col 1], vector unit latches result at end of cycle.
    //   col 1 FP4 values appear on y_out in DRAIN cycle 1.
    //
    // col_sel: 0 when quantizing col 0, 1 when quantizing col 1.
    //   Drives the col mux in tt_um_gemm_top to select which SA column
    //   feeds the vector unit input this cycle.
    ///////////////////////////////////////////////////////////////////////////
    logic [8:0] K_plus1;
    assign K_plus1 = K_ext + 9'd1;

    logic quant_col0, quant_col1;
    assign quant_col0 = stream_active && (stream_cnt == K_plus1);
    assign quant_col1 = drain_active  && (drain_cnt  == 1'b0);

    assign quant_en = (quant_col0 || quant_col1) ? {ARRAY_SIZE{1'b1}} : '0;
    assign col_sel  = quant_col1;
    assign scale    = quant_col0 ? scale_reg[0] : scale_reg[1];
    assign relu_en  = RELU_EN_r;

    ///////////////////////////////////////////////////////////////////////////
    // Bidirectional pin control
    //
    // During DRAIN: uio_oe = FF (all output), uio_out = FP4 result nibbles.
    //   drain_cnt=0: y_out carries col 0 results (latched end of STREAM K+1)
    //   drain_cnt=1: y_out carries col 1 results (latched end of DRAIN cnt=0)
    //   uio_out[7:4] = y_out[1] = row 1 of current column
    //   uio_out[3:0] = y_out[0] = row 0 of current column
    // All other phases: uio_oe = 00 (all input, bidir used for data in).
    ///////////////////////////////////////////////////////////////////////////
    assign uio_oe  = drain_active ? 8'hFF : 8'h00;
    assign uio_out = drain_active ? y_out_vec : 8'h00;

    ///////////////////////////////////////////////////////////////////////////
    // Status bus: uo_out[7:0] (always output, never carries data)
    //
    //   [2:0] phase[2:0]  : FSM state encoding (matches state_t)
    //   [3]   busy        : 1 in any non-IDLE state
    //   [4]   drain_valid : 1 during both DRAIN cycles (uio_out is valid)
    //   [5]   drain_col   : 0 = col 0 result on uio_out, 1 = col 1
    //   [6]   tile_done   : 1-cycle pulse on last DRAIN cycle
    //   [7]   BLANK
    ///////////////////////////////////////////////////////////////////////////
    assign uo_out[2:0] = state;
    assign uo_out[3]   = (state != 3'b000);
    assign uo_out[4]   = drain_active;
    assign uo_out[5]   = drain_active && drain_cnt;
    assign uo_out[6]   = tile_done;
    assign uo_out[7]   = 1'b0;
endmodule