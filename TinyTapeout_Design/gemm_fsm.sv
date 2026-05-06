///////////////////////////////////////////////////////////////////////////////
// Module: gemm_fsm.sv
// Description: Streaming FSM for the FP4 GEMM Tiny Tapeout (2x2) design.
//
//   Five states: IDLE, CFG, LOAD, STREAM, DRAIN
//
//   IDLE   : indefinite, waits for START pulse on ui_in[0]
//   CFG    : 1 cycle, captures K_LEN and control flags from input bus
//   LOAD   : 0-4 cycles (load_cnt 0..3), skipped sub-phases per SKIP_BIAS/SKIP_SCALE
//   STREAM : K_LEN_r + 2 cycles (stream_cnt 0..K+1), last cycle overlaps col0 drain
//   DRAIN  : 2 cycles (drain_cnt 0..1), outputs quantized results on bidir pins
//
// Counter ranges:
//   load_cnt   [1:0]  0-3       LOAD sub-phase index
//   stream_cnt [8:0]  0..K+1    STREAM cycle (K up to 256, max stream_cnt = 257)
//   drain_cnt  [0]    0..1      DRAIN cycle
//
// Config registers (captured in CFG, valid from LOAD onward):
//   K_LEN_r      [7:0]  inner dimension K, 1-256
//   RELU_EN_r    [0]    enable ReLU in vector unit during drain
//   SKIP_BIAS_r  [0]    skip bias load, preserve PE accumulator (chained tiles)
//   SKIP_SCALE_r [0]    skip scale load, preserve scale_reg (chained tiles)
//
// Author: Group5
///////////////////////////////////////////////////////////////////////////////

module gemm_fsm (
    input  logic        clk,
    input  logic        rst_n,

    // Input bus, sampled for START detection and config capture
    input  logic [7:0]  ui_in,
    input  logic [7:0]  uio_in,

    // Current FSM state (directly encodes phase[2:0] for status bus)
    output logic [2:0]  state_out,

    // Sub-phase counters (registered)
    output logic [1:0]  load_cnt,
    output logic [8:0]  stream_cnt,
    output logic        drain_cnt,

    // Config registers (valid from LOAD phase onward)
    output logic [7:0]  K_LEN_r,
    output logic        RELU_EN_r,
    output logic        SKIP_BIAS_r,
    output logic        SKIP_SCALE_r,

    // Phase-active flags (combinational decode of state)
    output logic        load_active,
    output logic        stream_active,
    output logic        drain_active,

    // 1-cycle pulse asserted on the last DRAIN cycle
    output logic        tile_done
);

    ///////////////////////////////////////////////////////////////////////////
    // State encoding
    ///////////////////////////////////////////////////////////////////////////
    typedef enum logic [2:0] {
        IDLE   = 3'b000,
        CFG    = 3'b001,
        LOAD   = 3'b010,
        STREAM = 3'b011,
        DRAIN  = 3'b100
    } state_t;

    state_t state, next_state;

    ///////////////////////////////////////////////////////////////////////////
    // Internal registers
    ///////////////////////////////////////////////////////////////////////////
    logic [1:0] load_cnt_r;
    logic [8:0] stream_cnt_r;
    logic       drain_cnt_r;

    logic [7:0] K_LEN_r_int;
    logic       RELU_EN_r_int;
    logic       SKIP_BIAS_r_int;
    logic       SKIP_SCALE_r_int;

    // STREAM exit threshold: K_LEN_r + 1 (stream_cnt reaches this on last cycle)
    logic [8:0] K_plus1;
    assign K_plus1 = {1'b0, K_LEN_r_int} + 9'd1;

    ///////////////////////////////////////////////////////////////////////////
    // State register
    ///////////////////////////////////////////////////////////////////////////
    always_ff @(posedge clk, negedge rst_n) begin
        if (!rst_n) begin
			state <= IDLE;
		end
        else begin 
			state <= next_state;
		end
    end

    ///////////////////////////////////////////////////////////////////////////
    // Config register capture (single cycle while state == CFG)
    // uio_in[2:0] = {SKIP_SCALE, SKIP_BIAS, RELU_EN}
    ///////////////////////////////////////////////////////////////////////////
    always_ff @(posedge clk) begin
        if (state == CFG) begin
            K_LEN_r_int      <= ui_in[7:0];
            RELU_EN_r_int    <= uio_in[0];
            SKIP_BIAS_r_int  <= uio_in[1];
            SKIP_SCALE_r_int <= uio_in[2];
        end
    end

    ///////////////////////////////////////////////////////////////////////////
    // Counter register logic
    ///////////////////////////////////////////////////////////////////////////
    always_ff @(posedge clk, negedge rst_n) begin
        if (!rst_n) begin
            load_cnt_r   <= 2'd0;
            stream_cnt_r <= 9'd0;
            drain_cnt_r  <= 1'b0;
        end
		else begin
            case (state)
                CFG: begin
                    // Reset all counters on tile start
                    load_cnt_r   <= 2'd0;
                    stream_cnt_r <= 9'd0;
                    drain_cnt_r  <= 1'b0;
                end

                LOAD: begin
                    // When SKIP_BIAS is set and counter is at 0, jump to sub-phase 2
                    // (skip bias sub-phases 0 and 1, go straight to scale loading)
                    if (load_cnt_r == 2'd0 && SKIP_BIAS_r_int) begin
                        load_cnt_r <= 2'd2;
					end
                    else begin
                        load_cnt_r <= load_cnt_r + 2'd1;
					end
                end

                STREAM: stream_cnt_r <= stream_cnt_r + 9'd1;

                DRAIN:  drain_cnt_r  <= drain_cnt_r  + 1'b1;

                default: begin
					load_cnt_r   <= 2'd0;
                    stream_cnt_r <= 9'd0;
                    drain_cnt_r  <= 1'b0;
				end
            endcase
        end
    end

    ///////////////////////////////////////////////////////////////////////////
    // Next-state logic
    ///////////////////////////////////////////////////////////////////////////
    always_comb begin
        next_state = state;
        case (state)
            IDLE: begin
                if (ui_in[0]) begin
					next_state = CFG;
				end
            end

            CFG: begin
                // Use raw input bus (not registered yet) for skip flag check.
                // Config regs capture at the SAME posedge, so this is consistent.
                if (uio_in[1] && uio_in[2]) begin
                    next_state = STREAM;   // both skipped, go directly to compute
				end
                else begin
                    next_state = LOAD;
				end
            end

            LOAD: begin
                // Exit conditions:
                //   load_cnt == 1 and SKIP_SCALE: done after bias only
                //   load_cnt == 3: all sub-phases completed
                if ((load_cnt_r == 2'd1 && SKIP_SCALE_r_int) ||
					(load_cnt_r == 2'd3)) begin
					next_state = STREAM;
				end
            end

            STREAM: begin
                if (stream_cnt_r == K_plus1) begin
					next_state = DRAIN;
				end
            end

            DRAIN: begin
                if (drain_cnt_r == 1'b1) begin
					next_state = IDLE;
				end
            end

            default: next_state = IDLE;
        endcase
    end

    ///////////////////////////////////////////////////////////////////////////
    // Output assignments
    ///////////////////////////////////////////////////////////////////////////
    assign state_out    = state;
    assign load_cnt     = load_cnt_r;
    assign stream_cnt   = stream_cnt_r;
    assign drain_cnt    = drain_cnt_r;

    assign K_LEN_r      = K_LEN_r_int;
    assign RELU_EN_r    = RELU_EN_r_int;
    assign SKIP_BIAS_r  = SKIP_BIAS_r_int;
    assign SKIP_SCALE_r = SKIP_SCALE_r_int;

    assign load_active   = (state == LOAD);
    assign stream_active = (state == STREAM);
    assign drain_active  = (state == DRAIN);

    // tile_done: 1-cycle pulse on the second (last) DRAIN cycle
    assign tile_done = drain_active && (drain_cnt_r == 1'b1);
endmodule