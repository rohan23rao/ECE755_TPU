///////////////////////////////////////////////////////////////////////////////
// Module: gemm_fsm.sv
// Description: Streaming FSM for the FP4 GEMM Tiny Tapeout (1x2) design.
//
//   States: IDLE → CFG → LOAD → STREAM → DRAIN → IDLE
//
//   LOAD sub-phases (1x2, COL_CONFIG=1):
//     cnt 0,1 : bias loading   (ld_bias[0,1])
//     cnt 2,3 : scale loading  (scale_reg[0,1] captured in CU)
//     Normal  exit: cnt == {COL_CONFIG_r, 1'b1}  (=3 for 1x2)
//     SKIP_SCALE exit: cnt == {1'b0, COL_CONFIG_r} (=1 for 1x2, after bias only)
//     SKIP_BIAS: on cnt==0, jump load_cnt to NCOLS ({1'b0,COL_CONFIG_r}+1)
//
//   DRAIN: 2 cycles (drain_cnt 0,1); tile_done on drain_cnt==1.
//     drain_cnt=0: CU outputs {4'b0, y[0]} on uio_out
//     drain_cnt=1: CU outputs {y[1], y[0]} on uio_out
//
//   NOTE: SKIP_BIAS + SKIP_SCALE simultaneously is not a supported combination.
//
// Counter ranges:
//   load_cnt   [2:0]  0..2*NCOLS-1  (max 3 for 1x2)
//   stream_cnt [8:0]  0..K+COL_CONFIG-1
//   drain_cnt  [0:0]  0..1
//
// CFG pin capture:
//   ui_in[7:0]  = K_LEN
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

    input  logic [7:0]  ui_in,
    input  logic [7:0]  uio_in,

    output logic [2:0]  state_out,

    output logic [2:0]  load_cnt,
    output logic [8:0]  stream_cnt,
    output logic [0:0]  drain_cnt,

    output logic [7:0]  K_LEN_r,
    output logic [1:0]  COL_CONFIG_r,
    output logic        RELU_EN_r,
    output logic        SKIP_BIAS_r,
    output logic        SKIP_SCALE_r,

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

    logic [2:0] load_cnt_r;
    logic [8:0] stream_cnt_r;
    logic [0:0] drain_cnt_r;

    logic [7:0] K_LEN_r_int;
    logic [1:0] COL_CONFIG_r_int;
    logic       RELU_EN_r_int;
    logic       SKIP_BIAS_r_int;
    logic       SKIP_SCALE_r_int;

    // STREAM exit: stream_cnt == K + COL_CONFIG - 1
    //   1x2 (COL_CONFIG=1): exit at K+0 = K, so STREAM runs K+1 cycles (0..K)
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
    // Config capture (CFG cycle)
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
    // Counter logic
    ///////////////////////////////////////////////////////////////////////////
    always_ff @(posedge clk, negedge rst_n) begin
        if (!rst_n) begin
            load_cnt_r   <= 3'd0;
            stream_cnt_r <= 9'd0;
            drain_cnt_r  <= 1'b0;
        end else begin
            case (state)
                CFG: begin
                    load_cnt_r   <= 3'd0;
                    stream_cnt_r <= 9'd0;
                    drain_cnt_r  <= 1'b0;
                end
                LOAD: begin
                    // SKIP_BIAS: on first LOAD cycle jump past bias sub-phase
                    if (SKIP_BIAS_r_int && load_cnt_r == 3'd0)
                        load_cnt_r <= {1'b0, COL_CONFIG_r_int} + 3'd1;
                    else
                        load_cnt_r <= load_cnt_r + 3'd1;
                end
                STREAM: stream_cnt_r <= stream_cnt_r + 9'd1;
                DRAIN:  drain_cnt_r  <= drain_cnt_r  + 1'b1;
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
            IDLE:   if (ui_in[0])
                        next_state = CFG;

            CFG:    next_state = LOAD;

            LOAD:   begin
                if (SKIP_SCALE_r_int) begin
                    // Exit after bias sub-phase: cnt == {0, COL_CONFIG_r}
                    if (load_cnt_r == {1'b0, COL_CONFIG_r_int})
                        next_state = STREAM;
                end else begin
                    // Normal exit after scale sub-phase: cnt == {COL_CONFIG_r, 1'b1}
                    if (load_cnt_r == {COL_CONFIG_r_int, 1'b1})
                        next_state = STREAM;
                end
            end

            STREAM: if (stream_cnt_r == stream_exit)
                        next_state = DRAIN;

            DRAIN:  if (drain_cnt_r == 1'b1)
                        next_state = IDLE;

            default: next_state = IDLE;
        endcase
    end

    ///////////////////////////////////////////////////////////////////////////
    // Outputs
    ///////////////////////////////////////////////////////////////////////////
    assign state_out   = state;
    assign load_cnt    = load_cnt_r;
    assign stream_cnt  = stream_cnt_r;
    assign drain_cnt   = drain_cnt_r;

    assign K_LEN_r      = K_LEN_r_int;
    assign COL_CONFIG_r = COL_CONFIG_r_int;
    assign RELU_EN_r    = RELU_EN_r_int;
    assign SKIP_BIAS_r  = SKIP_BIAS_r_int;
    assign SKIP_SCALE_r = SKIP_SCALE_r_int;

    assign load_active   = (state == LOAD);
    assign stream_active = (state == STREAM);
    assign drain_active  = (state == DRAIN);

    assign tile_done = drain_active && (drain_cnt_r == 1'b1);

endmodule