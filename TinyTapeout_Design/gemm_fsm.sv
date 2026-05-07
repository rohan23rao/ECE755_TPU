///////////////////////////////////////////////////////////////////////////////
// Module: gemm_fsm.sv
// Description: Streaming FSM for the FP4 GEMM Tiny Tapeout (1xN) design.
//
//   States: IDLE → CFG → LOAD → STREAM → FLUSH
//
//   FLUSH ping-pong protocol (2 cycles per output column):
//     Even cycles (flush_cnt[0]=0): host drives 16-bit scale on {ui_in, uio_in},
//       uio_oe=0x00 (all input). VU captures result.
//     Odd  cycles (flush_cnt[0]=1): chip drives y_out on uio_out[7:4],
//       uio_oe=0xFF (all output). Host reads result.
//     Total FLUSH cycles = 2*NCOLS  (flush_cnt 0..2*NCOLS-1)
//     Exit condition: flush_cnt == {COL_CONFIG_r, 1'b1} = 2*NCOLS-1
//
// Counter ranges:
//   load_cnt   [2:0]  0..NCOLS-1        (max 2 for 1x3)
//   stream_cnt [8:0]  0..K+COL_CONFIG-1 (K up to 256)
//   flush_cnt  [2:0]  0..2*NCOLS-1      (max 5 for 1x3)
//
// Author: Group5
///////////////////////////////////////////////////////////////////////////////

module gemm_fsm (
    input  logic        clk,
    input  logic        rst_n,

    input  logic [7:0]  ui_in,
    input  logic [7:0]  uio_in,

    output logic [2:0]  state_out,

    output logic [2:0]  load_cnt,
    output logic [8:0]  stream_cnt,
    output logic [2:0]  flush_cnt,      // widened to [2:0] for 2*NCOLS cycles

    output logic [7:0]  K_LEN_r,
    output logic [1:0]  COL_CONFIG_r,
    output logic        RELU_EN_r,
    output logic        SKIP_BIAS_r,

    output logic        load_active,
    output logic        stream_active,
    output logic        flush_active,

    output logic        tile_done
);

    typedef enum logic [2:0] {
        IDLE   = 3'b000,
        CFG    = 3'b001,
        LOAD   = 3'b010,
        STREAM = 3'b011,
        FLUSH  = 3'b100
    } state_t;

    state_t state, next_state;

    logic [2:0] load_cnt_r;
    logic [8:0] stream_cnt_r;
    logic [2:0] flush_cnt_r;

    logic [7:0] K_LEN_r_int;
    logic [1:0] COL_CONFIG_r_int;
    logic       RELU_EN_r_int;
    logic       SKIP_BIAS_r_int;

    // STREAM exit: stream_cnt == K + COL_CONFIG - 1
    logic [8:0] stream_exit;
    assign stream_exit = {1'b0, K_LEN_r_int} + {7'b0, COL_CONFIG_r_int} - 9'd1;

    // FLUSH exit: flush_cnt == 2*NCOLS-1 == {COL_CONFIG_r, 1'b1}
    //   1x1 (COL_CONFIG=0): exit at 1  (2 cycles: 0,1)
    //   1x2 (COL_CONFIG=1): exit at 3  (4 cycles: 0..3)
    //   1x3 (COL_CONFIG=2): exit at 5  (6 cycles: 0..5)
    logic [2:0] flush_exit;
    assign flush_exit = {COL_CONFIG_r_int, 1'b1};

    ///////////////////////////////////////////////////////////////////////////
    // State register
    ///////////////////////////////////////////////////////////////////////////
    always_ff @(posedge clk, negedge rst_n) begin
        if (!rst_n) state <= IDLE;
        else        state <= next_state;
    end

    ///////////////////////////////////////////////////////////////////////////
    // Config capture (CFG cycle)
    // ui_in[7:0]  = K_LEN
    // uio_in[0]   = RELU_EN
    // uio_in[1]   = SKIP_BIAS
    // uio_in[4:3] = COL_CONFIG[1:0]
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
    // Counter logic
    ///////////////////////////////////////////////////////////////////////////
    always_ff @(posedge clk, negedge rst_n) begin
        if (!rst_n) begin
            load_cnt_r   <= 3'd0;
            stream_cnt_r <= 9'd0;
            flush_cnt_r  <= 3'd0;
        end
        else begin
            case (state)
                CFG: begin
                    load_cnt_r   <= 3'd0;
                    stream_cnt_r <= 9'd0;
                    flush_cnt_r  <= 3'd0;
                end
                LOAD:   load_cnt_r   <= load_cnt_r   + 3'd1;
                STREAM: stream_cnt_r <= stream_cnt_r + 9'd1;
                FLUSH:  flush_cnt_r  <= flush_cnt_r  + 3'd1;
                default: begin
                    load_cnt_r   <= 3'd0;
                    stream_cnt_r <= 9'd0;
                    flush_cnt_r  <= 3'd0;
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

            LOAD:   if (load_cnt_r == {1'b0, COL_CONFIG_r_int})
                        next_state = STREAM;

            STREAM: if (stream_cnt_r == stream_exit)
                        next_state = FLUSH;

            FLUSH:  if (flush_cnt_r == flush_exit)
                        next_state = IDLE;

            default: next_state = IDLE;
        endcase
    end

    ///////////////////////////////////////////////////////////////////////////
    // Outputs
    ///////////////////////////////////////////////////////////////////////////
    assign state_out     = state;
    assign load_cnt      = load_cnt_r;
    assign stream_cnt    = stream_cnt_r;
    assign flush_cnt     = flush_cnt_r;

    assign K_LEN_r       = K_LEN_r_int;
    assign COL_CONFIG_r  = COL_CONFIG_r_int;
    assign RELU_EN_r     = RELU_EN_r_int;
    assign SKIP_BIAS_r   = SKIP_BIAS_r_int;

    assign load_active   = (state == LOAD);
    assign stream_active = (state == STREAM);
    assign flush_active  = (state == FLUSH);

    assign tile_done     = flush_active && (flush_cnt_r == flush_exit);

endmodule