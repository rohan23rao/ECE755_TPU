///////////////////////////////////////////////////////////////////////////////
// Module: gemm_fsm.sv
// Description: Streaming FSM for the FP4 GEMM Tiny Tapeout (1x2) design.
//
//   States: IDLE → CFG → [LOAD] → STREAM → DRAIN → IDLE
//
//   SKIP_BIAS (uio_in[1] during CFG): CFG exits directly to STREAM, LOAD skipped.
//
//   LOAD (bias-only, 2 cycles for 1x2):
//     cnt=0: bias[col0] loaded by CU
//     cnt=1: bias[col1] loaded by CU
//     Exit:  load_cnt == COL_CONFIG_r  (=1 for 1x2)
//
//   STREAM: K + COL_CONFIG cycles (K+1 for 1x2, cnt 0..K).
//     pe_en_0 active cnt 0..K-1; pe_en_1 (registered) active cnt 1..K.
//
//   DRAIN: per-column 2-phase handshake, repeated for col0 then col1.
//     drain_phase=0  SCALE_LOAD  (1 cycle, unconditional advance):
//       CU asserts scale = {ui_in,uio_in}; quant_en fires; uio_oe=0x00.
//     drain_phase=1  RESULT_HOLD (stall until Y_ACK = ui_in[0]):
//       CU drives y_out on uio_out[3:0]; uio_oe=0xFF.
//       On ACK: if col0 → move to col1 SCALE_LOAD.
//                if col1 → tile_done, return to IDLE.
//
// uo_out encoding (from CU):
//   [2:0]=state, [3]=busy, [4]=drain_active, [5]=drain_phase, [6]=tile_done, [7]=drain_col
//   → IDLE=0x00, CFG=0x09, LOAD=0x0A, STREAM=0x0B,
//     scale_col0=0x1C, result_col0=0x3C,
//     scale_col1=0x9C, result_col1=0xBC, tile_done=0xFC
//
// CFG pin capture:
//   ui_in[7:0]  = K_LEN
//   uio_in[0]   = RELU_EN
//   uio_in[1]   = SKIP_BIAS
//   uio_in[4:3] = COL_CONFIG[1:0]
//
// Author: Group5
///////////////////////////////////////////////////////////////////////////////

module gemm_fsm (
    input  logic        clk,
    input  logic        rst_n,

    input  logic [7:0]  ui_in,
    input  logic [7:0]  uio_in,

    // State / counter outputs
    output logic [2:0]  state_out,
    output logic [0:0]  load_cnt,      // 1-bit: counts bias slots 0..COL_CONFIG_r
    output logic [8:0]  stream_cnt,
    output logic        drain_col,     // 0 = col0, 1 = col1
    output logic        drain_phase,   // 0 = SCALE_LOAD, 1 = RESULT_HOLD

    // Config registers
    output logic [7:0]  K_LEN_r,
    output logic [1:0]  COL_CONFIG_r,
    output logic        RELU_EN_r,
    output logic        SKIP_BIAS_r,

    // State flags
    output logic        load_active,
    output logic        stream_active,
    output logic        drain_active,

    output logic        tile_done
);

    typedef enum logic [2:0] {
        IDLE   = 3'b000,
        CFG    = 3'b001,
        LOAD   = 3'b010,
        STREAM = 3'b011,
        DRAIN  = 3'b100
    } state_t;

    state_t state, next_state;

    logic [0:0] load_cnt_r;
    logic [8:0] stream_cnt_r;
    logic       drain_col_r;
    logic       drain_phase_r;

    logic [7:0] K_LEN_r_int;
    logic [1:0] COL_CONFIG_r_int;
    logic       RELU_EN_r_int;
    logic       SKIP_BIAS_r_int;

    // STREAM exit: stream_cnt == K + COL_CONFIG - 1
    //   1x2 (COL_CONFIG=1): exits at cnt == K; total K+1 cycles (0..K)
    logic [8:0] stream_exit;
    assign stream_exit = {1'b0, K_LEN_r_int} + {7'b0, COL_CONFIG_r_int} - 9'd1;

    logic y_ack;
    assign y_ack = ui_in[0];

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
    // Config capture — latched on the CFG cycle posedge
    ///////////////////////////////////////////////////////////////////////////
    always_ff @(posedge clk) begin
        if (state == CFG) begin
            K_LEN_r_int      <= ui_in[7:0];
            RELU_EN_r_int    <= uio_in[0];
            SKIP_BIAS_r_int  <= uio_in[1];
            COL_CONFIG_r_int <= uio_in[4:3];
        end
    end

    ///////////////////////////////////////////////////////////////////////////
    // Counter / DRAIN sub-state logic
    ///////////////////////////////////////////////////////////////////////////
    always_ff @(posedge clk, negedge rst_n) begin
        if (!rst_n) begin
            load_cnt_r    <= 1'b0;
            stream_cnt_r  <= 9'd0;
            drain_col_r   <= 1'b0;
            drain_phase_r <= 1'b0;
        end 
		else begin
            case (state)
                CFG: begin
                    load_cnt_r    <= 1'b0;
                    stream_cnt_r  <= 9'd0;
                    drain_col_r   <= 1'b0;
                    drain_phase_r <= 1'b0;
                end

                LOAD: begin
                    load_cnt_r <= load_cnt_r + 1'b1;
                end

                STREAM: begin
                    stream_cnt_r <= stream_cnt_r + 9'd1;
                end

                DRAIN: begin
                    if (!drain_phase_r) begin
                        // SCALE_LOAD: always advance to RESULT_HOLD next cycle
                        drain_phase_r <= 1'b1;
                    end
					else begin
                        // RESULT_HOLD: stall until host ACKs
                        if (y_ack) begin
                            if (!drain_col_r) begin
                                // col0 done — move to col1 SCALE_LOAD
                                drain_col_r   <= 1'b1;
                                drain_phase_r <= 1'b0;
                            end
                            // col1 ACK: tile_done, FSM → IDLE (no register update needed)
                        end
                    end
                end

                default: begin
                    load_cnt_r    <= 1'b0;
                    stream_cnt_r  <= 9'd0;
                    drain_col_r   <= 1'b0;
                    drain_phase_r <= 1'b0;
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
            // ui_in[0] doubles as TILE_START in IDLE (Y_ACK only meaningful in DRAIN)
            IDLE: begin
				if (ui_in[0]) begin
                    next_state = CFG;
				end
			end

            // Use raw uio_in[1] — SKIP_BIAS_r_int not yet updated at this posedge
            CFG: begin
				next_state = uio_in[1] ? STREAM : LOAD;
			end

            LOAD: begin
				if (load_cnt_r == {1'b0, COL_CONFIG_r_int}) begin
                    next_state = STREAM;
				end
			end

            STREAM: begin
				if (stream_cnt_r == stream_exit) begin
                    next_state = DRAIN;
				end
			end

            DRAIN: begin
				if (drain_phase_r && drain_col_r && y_ack) begin
                    next_state = IDLE;
				end
			end

            default: begin
				next_state = IDLE;
			end
        endcase
    end

    ///////////////////////////////////////////////////////////////////////////
    // Output assignments
    ///////////////////////////////////////////////////////////////////////////
    assign state_out    = state;
    assign load_cnt     = load_cnt_r;
    assign stream_cnt   = stream_cnt_r;
    assign drain_col    = drain_col_r;
    assign drain_phase  = drain_phase_r;

    assign K_LEN_r      = K_LEN_r_int;
    assign COL_CONFIG_r = COL_CONFIG_r_int;
    assign RELU_EN_r    = RELU_EN_r_int;
    assign SKIP_BIAS_r  = SKIP_BIAS_r_int;

    assign load_active   = (state == LOAD);
    assign stream_active = (state == STREAM);
    assign drain_active  = (state == DRAIN);

    // Fires on the last RESULT_HOLD cycle (col1, ACK received)
    assign tile_done = drain_active && drain_phase_r && drain_col_r && y_ack;
endmodule