///////////////////////////////////////////////////////////////////////////////
// Module: gemm_fsm.sv
// Description: Streaming FSM for the FP4 GEMM Tiny Tapeout (1xN) design.
//
//   Five states: IDLE, CFG, LOAD, STREAM, DRAIN
//
//   IDLE   : indefinite, waits for START pulse on ui_in[0]
//   CFG    : 1 cycle, captures K_LEN, COL_CONFIG, and control flags
//   LOAD   : 0..2*NCOLS-1 cycles; sub-phases skipped per SKIP_BIAS/SKIP_SCALE
//   STREAM : K + COL_CONFIG cycles (stream_cnt 0..K+COL_CONFIG-1)
//            last column (NCOLS-1) quant fires at drain_cnt==0 instead
//   DRAIN  : 2 cycles (drain_cnt 0..1), outputs quantized results
//
// Counter ranges:
//   load_cnt   [2:0]  0..2*NCOLS-1   (max 5 for 1x3)
//   stream_cnt [8:0]  0..K+COL_CONFIG-1  (K up to 256)
//   drain_cnt  [0]    0..1
//
// Config registers (captured in CFG, valid from LOAD onward):
//   K_LEN_r       [7:0]  inner dimension K, 1-256
//   COL_CONFIG_r  [1:0]  column count select: 00=1x1, 01=1x2, 10=1x3
//   RELU_EN_r     [0]    enable ReLU in vector unit during drain
//   SKIP_BIAS_r   [0]    skip bias load sub-phases (chained tiles)
//   SKIP_SCALE_r  [0]    skip scale load sub-phases (chained tiles)
//
// uio_in CFG mapping:
//   uio_in[0]   = RELU_EN
//   uio_in[1]   = SKIP_BIAS
//   uio_in[2]   = SKIP_SCALE
//   uio_in[4:3] = COL_CONFIG[1:0]
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
    output logic [2:0]  load_cnt,      // widened from [1:0] for 1xN
    output logic [8:0]  stream_cnt,
    output logic        drain_cnt,

    // Config registers (valid from LOAD phase onward)
    output logic [7:0]  K_LEN_r,
    output logic [1:0]  COL_CONFIG_r,  // new: runtime column count select
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
    logic [2:0] load_cnt_r;
    logic [8:0] stream_cnt_r;
    logic       drain_cnt_r;

    logic [7:0] K_LEN_r_int;
    logic [1:0] COL_CONFIG_r_int;
    logic       RELU_EN_r_int;
    logic       SKIP_BIAS_r_int;
    logic       SKIP_SCALE_r_int;

    // STREAM exit threshold: stream_cnt == K + COL_CONFIG - 1
    //   1x1 (COL_CONFIG=0): exits at K-1   → K total cycles
    //   1x2 (COL_CONFIG=1): exits at K     → K+1 total cycles
    //   1x3 (COL_CONFIG=2): exits at K+1   → K+2 total cycles
    // col j < NCOLS-1 quant fires at stream_cnt == K + j (within STREAM)
    // col NCOLS-1 quant fires at drain_cnt == 0
    logic [8:0] stream_exit;
    assign stream_exit = {1'b0, K_LEN_r_int} + {7'b0, COL_CONFIG_r_int} - 9'd1;

    ///////////////////////////////////////////////////////////////////////////
    // State register
    ///////////////////////////////////////////////////////////////////////////
    always_ff @(posedge clk, negedge rst_n) begin
        if (!rst_n) state <= IDLE;
        else        state <= next_state;
    end

    ///////////////////////////////////////////////////////////////////////////
    // Config register capture (single cycle while state == CFG)
    //
    // ui_in[7:0]  = K_LEN
    // uio_in[0]   = RELU_EN
    // uio_in[1]   = SKIP_BIAS
    // uio_in[2]   = SKIP_SCALE
    // uio_in[4:3] = COL_CONFIG
    ///////////////////////////////////////////////////////////////////////////
    always_ff @(posedge clk) begin
        if (state == CFG) begin
            K_LEN_r_int      <= ui_in[7:0];
            RELU_EN_r_int    <= uio_in[0];
            SKIP_BIAS_r_int  <= uio_in[1];
            SKIP_SCALE_r_int <= uio_in[2];
            COL_CONFIG_r_int <= uio_in[4:3];
        end
    end

    ///////////////////////////////////////////////////////////////////////////
    // Counter register logic
    //
    // load_cnt sub-phase structure (NCOLS = COL_CONFIG + 1):
    //   0 .. NCOLS-1          : bias load (one per column)
    //   NCOLS .. 2*NCOLS-1    : scale load (one per column)
    //   SKIP_BIAS jump        : load_cnt -> NCOLS (skip bias sub-phases)
    //   SKIP_SCALE exit       : exit when load_cnt == NCOLS-1 = COL_CONFIG_r
    //   Full exit             : exit when load_cnt == 2*NCOLS-1 = {COL_CONFIG_r,1'b1}
    ///////////////////////////////////////////////////////////////////////////
    always_ff @(posedge clk, negedge rst_n) begin
        if (!rst_n) begin
            load_cnt_r   <= 3'd0;
            stream_cnt_r <= 9'd0;
            drain_cnt_r  <= 1'b0;
        end
        else begin
            case (state)
                CFG: begin
                    load_cnt_r   <= 3'd0;
                    stream_cnt_r <= 9'd0;
                    drain_cnt_r  <= 1'b0;
                end

                LOAD: begin
                    // When SKIP_BIAS set and at start, jump past bias sub-phases
                    if (load_cnt_r == 3'd0 && SKIP_BIAS_r_int)
                        load_cnt_r <= {1'b0, COL_CONFIG_r_int} + 3'd1;  // = NCOLS
                    else
                        load_cnt_r <= load_cnt_r + 3'd1;
                end

                STREAM: stream_cnt_r <= stream_cnt_r + 9'd1;

                DRAIN:  drain_cnt_r  <= drain_cnt_r + 1'b1;

                default: begin
                    load_cnt_r   <= 3'd0;
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
                if (ui_in[0])
                    next_state = CFG;
            end

            CFG: begin
                // Skip LOAD entirely if both bias and scale are skipped
                if (uio_in[1] && uio_in[2])
                    next_state = STREAM;
                else
                    next_state = LOAD;
            end

            LOAD: begin
                // SKIP_SCALE path: done after bias sub-phases (load_cnt == NCOLS-1)
                // Full path:        done after scale sub-phases (load_cnt == 2*NCOLS-1)
                //   NCOLS-1     = COL_CONFIG_r      (as 3-bit)
                //   2*NCOLS-1   = {COL_CONFIG_r, 1'b1}  (= 2*COL_CONFIG + 1)
                if ((load_cnt_r == {1'b0, COL_CONFIG_r_int} && SKIP_SCALE_r_int) ||
                    (load_cnt_r == {COL_CONFIG_r_int, 1'b1}))
                    next_state = STREAM;
            end

            STREAM: begin
                if (stream_cnt_r == stream_exit)
                    next_state = DRAIN;
            end

            DRAIN: begin
                if (drain_cnt_r == 1'b1)
                    next_state = IDLE;
            end

            default: next_state = IDLE;
        endcase
    end

    ///////////////////////////////////////////////////////////////////////////
    // Output assignments
    ///////////////////////////////////////////////////////////////////////////
    assign state_out     = state;
    assign load_cnt      = load_cnt_r;
    assign stream_cnt    = stream_cnt_r;
    assign drain_cnt     = drain_cnt_r;

    assign K_LEN_r       = K_LEN_r_int;
    assign COL_CONFIG_r  = COL_CONFIG_r_int;
    assign RELU_EN_r     = RELU_EN_r_int;
    assign SKIP_BIAS_r   = SKIP_BIAS_r_int;
    assign SKIP_SCALE_r  = SKIP_SCALE_r_int;

    assign load_active   = (state == LOAD);
    assign stream_active = (state == STREAM);
    assign drain_active  = (state == DRAIN);

    // tile_done: 1-cycle pulse on the last DRAIN cycle
    assign tile_done = drain_active && (drain_cnt_r == 1'b1);
endmodule