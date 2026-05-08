///////////////////////////////////////////////////////////////////////////////
// Module: gemm_fsm.sv
// Description: Streaming FSM — FP4 GEMM Tiny Tapeout, hardcoded 1x2.
//
//   States: IDLE → CFG → [LOAD] → STREAM → DRAIN → IDLE
//
//   Hardcoded 1x2 simplifications vs. prior version:
//     - COL_CONFIG removed; LOAD always 2 cycles (load_cnt 0,1).
//     - stream_exit = K_LEN_r (was K + COL_CONFIG - 1; with COL_CONFIG=1
//       this is K + 0 = K). Eliminates the 9-bit adder entirely.
//     - K_LEN_r: 8→4 bits (max K=15).
//     - stream_cnt: 9→4 bits (max 15).
//
//   SKIP_BIAS (uio_in[1] in CFG): jump CFG→STREAM, skip LOAD.
//
//   LOAD (2 cycles, bias only):
//     cnt=0: CU fires ld_bias[0].   cnt=1: CU fires ld_bias[1].
//     Exit on load_cnt == 1.
//
//   STREAM (K+1 valid cycles, 0..K):
//     pe_en_0 active on cnt 0..K-1 (K MACs for col0).
//     pe_en_1 (registered pe_en_0) active on cnt 1..K (col1 stagger).
//     Tail cycle cnt=K: pe_en_0=0, pe_en_1=1 (col1 last MAC).
//     DATA_VLD (uio_in[5]): stream_cnt and stream exit gated — stall until
//     host presents valid data; stream_exit also requires DATA_VLD so the
//     tail MAC always fires on a live cycle.
//
//   DRAIN: 2-phase per-column handshake × 2 columns.
//     phase=0 SCALE_LOAD (1 cycle unconditional).
//     phase=1 RESULT_HOLD (stall until Y_ACK = ui_in[0]).
//
// CFG captures (ui_in / uio_in):
//   ui_in[3:0]  = K_LEN   (max K=15; upper nibble ignored)
//   uio_in[0]   = RELU_EN
//   uio_in[1]   = SKIP_BIAS
//   (uio_in[4:3] was COL_CONFIG — now free)
//
// STREAM pin usage:
//   ui_in[3:0]  = a_row0    uio_in[3:0] = w_col1
//   ui_in[7:4]  = w_col0    uio_in[5]   = DATA_VLD
//
// Author: Group5
///////////////////////////////////////////////////////////////////////////////

module gemm_fsm (
    input  logic        clk,
    input  logic        rst_n,

    input  logic [7:0]  ui_in,
    input  logic [7:0]  uio_in,

    output logic [2:0]  state_out,
    output logic [0:0]  load_cnt,     // 1-bit: 0=col0 bias, 1=col1 bias
    output logic [3:0]  stream_cnt,   // 4-bit: 0..K (max 15)
    output logic        drain_col,
    output logic        drain_phase,

    output logic [3:0]  K_LEN_r,      // 4-bit captured K
    output logic        RELU_EN_r,
    output logic        SKIP_BIAS_r,

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
    logic [3:0] stream_cnt_r;
    logic       drain_col_r;
    logic       drain_phase_r;

    logic [3:0] K_LEN_r_int;
    logic       RELU_EN_r_int;
    logic       SKIP_BIAS_r_int;

    // stream_exit = K_LEN_r (hardcoded 1x2: K + 1 - 1 = K — no adder)
    wire [3:0] stream_exit = K_LEN_r_int;

    // DATA_VLD: only meaningful in STREAM; gates counter advance and exit
    wire data_vld = uio_in[5];
    wire y_ack    = ui_in[0];

    ///////////////////////////////////////////////////////////////////////////
    // State register
    ///////////////////////////////////////////////////////////////////////////
    always_ff @(posedge clk, negedge rst_n) begin
        if (!rst_n) state <= IDLE;
        else        state <= next_state;
    end

    ///////////////////////////////////////////////////////////////////////////
    // Config capture
    ///////////////////////////////////////////////////////////////////////////
    always_ff @(posedge clk) begin
        if (state == CFG) begin
            K_LEN_r_int     <= ui_in[3:0];   // 4-bit K, max 15
            RELU_EN_r_int   <= uio_in[0];
            SKIP_BIAS_r_int <= uio_in[1];
            // uio_in[4:3] (was COL_CONFIG) — now unused
        end
    end

    ///////////////////////////////////////////////////////////////////////////
    // Counters / DRAIN sub-state
    ///////////////////////////////////////////////////////////////////////////
    always_ff @(posedge clk, negedge rst_n) begin
        if (!rst_n) begin
            load_cnt_r    <= 1'b0;
            stream_cnt_r  <= 4'd0;
            drain_col_r   <= 1'b0;
            drain_phase_r <= 1'b0;
        end else begin
            case (state)
                CFG: begin
                    load_cnt_r    <= 1'b0;
                    stream_cnt_r  <= 4'd0;
                    drain_col_r   <= 1'b0;
                    drain_phase_r <= 1'b0;
                end

                LOAD: begin
                    load_cnt_r <= load_cnt_r + 1'b1;
                end

                STREAM: begin
                    if (data_vld)
                        stream_cnt_r <= stream_cnt_r + 4'd1;
                end

                DRAIN: begin
                    if (!drain_phase_r) begin
                        drain_phase_r <= 1'b1;
                    end else begin
                        if (y_ack) begin
                            if (!drain_col_r) begin
                                drain_col_r   <= 1'b1;
                                drain_phase_r <= 1'b0;
                            end
                        end
                    end
                end

                default: begin
                    load_cnt_r    <= 1'b0;
                    stream_cnt_r  <= 4'd0;
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
            IDLE:   if (ui_in[0])
                        next_state = CFG;

            CFG:    next_state = uio_in[1] ? STREAM : LOAD;

            // LOAD: 2 cycles hardcoded (load_cnt 0 then 1)
            LOAD:   if (load_cnt_r == 1'b1)
                        next_state = STREAM;

            // Exit requires data_vld: tail MAC for col1 always fires live
            STREAM: if (stream_cnt_r == stream_exit && data_vld)
                        next_state = DRAIN;

            DRAIN:  if (drain_phase_r && drain_col_r && y_ack)
                        next_state = IDLE;

            default: next_state = IDLE;
        endcase
    end

    ///////////////////////////////////////////////////////////////////////////
    // Outputs
    ///////////////////////////////////////////////////////////////////////////
    assign state_out    = state;
    assign load_cnt     = load_cnt_r;
    assign stream_cnt   = stream_cnt_r;
    assign drain_col    = drain_col_r;
    assign drain_phase  = drain_phase_r;

    assign K_LEN_r      = K_LEN_r_int;
    assign RELU_EN_r    = RELU_EN_r_int;
    assign SKIP_BIAS_r  = SKIP_BIAS_r_int;

    assign load_active   = (state == LOAD);
    assign stream_active = (state == STREAM);
    assign drain_active  = (state == DRAIN);

    assign tile_done = drain_active && drain_phase_r && drain_col_r && y_ack;

endmodule