///////////////////////////////////////////////////////////////////////////////
// Module: tt_gemm_fsm.sv
// Description: Byte-stream FSM for Tiny Tapeout 1x1 FP4 GEMM Core.
//
// Pin interface (from tt_gemm_top):
//   byte_valid  (uio[0]) — 1-cycle strobe; ui_in[7:0] holds valid byte
//   stream_done (uio[1]) — asserted simultaneously with last STREAM byte
//   data_byte   (ui_in[7:0])
//
// Packet format:
//   CFG byte:    [7:3]=unused  [2]=RELU_EN  [1]=SCALE_NEW  [0]=BIAS_NEW
//   LOAD bytes:  bias[15:8], bias[7:0]  (if BIAS_NEW)
//                scale[15:8], scale[7:0] (if SCALE_NEW)
//   STREAM byte: [7:4]=A (FP4 E2M1)  [3:0]=W (FP4 E2M1)
//
// State encoding on state_out[2:0] → uo_out[3:1]:
//   0=IDLE  1=CFG  2=LOAD  3=BLOAD  4=STREAM  5=DRAIN  6=FLUSH
//
// Accumulator init (BLOAD, 1 cycle before STREAM):
//   ld_bias always fires; if BIAS_NEW=0, bias register = 0 → clears acc to 0.
//
// Pipeline drain (DRAIN state, 1 cycle before FLUSH):
//   pe_en_q fires here, finalizing acc_q. Avoids VU sampling stale acc_out.
//
// FLUSH timing:
//   Cycle 0 (FLUSH entry):  quant_en=1, acc_out final, VU samples and registers
//   Cycle 1+ (flush_rdy=1): result_valid=1, y_out stable; held until new byte_valid
//
// Author: Group5
///////////////////////////////////////////////////////////////////////////////

module tt_gemm_fsm (
    input  logic       clk,
    input  logic       rst_n,

    // From TT pins
    input  logic       byte_valid,    // uio[0]: 1-cycle strobe
    input  logic       stream_done,   // uio[1]: asserted with last STREAM byte
    input  logic [7:0] data_byte,     // ui_in[7:0]

    // PE control
    output logic       pe_en,
    output logic       ld_bias,

    // Vector unit control
    output logic       quant_en,
    output logic       relu_en_out,

    // Byte capture enables → top-level holding registers
    output logic       bias_hi_wen,   // capture data_byte as bias[15:8]
    output logic       bias_lo_wen,   // capture data_byte as bias[7:0]
    output logic       scale_hi_wen,  // capture data_byte as scale[15:8]
    output logic       scale_lo_wen,  // capture data_byte as scale[7:0]

    // Status
    output logic       result_valid,  // uo_out[0]
    output logic [2:0] state_out      // uo_out[3:1]
);

    ///////////////////////////////////////////////////////////////////////////
    // State encoding
    ///////////////////////////////////////////////////////////////////////////
    typedef enum logic [2:0] {
        IDLE   = 3'd0,
        CFG    = 3'd1,
        LOAD   = 3'd2,
        BLOAD  = 3'd3,
        STREAM = 3'd4,
        FLUSH  = 3'd5
    } state_t;
    state_t state, next_state;

    ///////////////////////////////////////////////////////////////////////////
    // Internal registers
    ///////////////////////////////////////////////////////////////////////////
    logic BIAS_NEW_r, SCALE_NEW_r, RELU_EN_r;
    logic capture_cfg;

    logic [1:0] load_cnt;
    logic       inc_cnt, clr_cnt;

    // flush_rdy: low on first FLUSH cycle (quant_en fires), high thereafter
    logic flush_rdy;

    ///////////////////////////////////////////////////////////////////////////
    // State register
    ///////////////////////////////////////////////////////////////////////////
    always_ff @(posedge clk, negedge rst_n) begin
        if (!rst_n) state <= IDLE;
        else        state <= next_state;
    end

    ///////////////////////////////////////////////////////////////////////////
    // CFG metadata capture
    // CFG byte: [2]=RELU_EN, [1]=SCALE_NEW, [0]=BIAS_NEW
    ///////////////////////////////////////////////////////////////////////////
    always_ff @(posedge clk) begin
        if (capture_cfg) begin
            BIAS_NEW_r  <= data_byte[0];
            SCALE_NEW_r <= data_byte[1];
            RELU_EN_r   <= data_byte[2];
        end
    end

    ///////////////////////////////////////////////////////////////////////////
    // LOAD byte counter
    ///////////////////////////////////////////////////////////////////////////
    always_ff @(posedge clk, negedge rst_n) begin
        if      (!rst_n)  load_cnt <= 2'd0;
        else if (clr_cnt) load_cnt <= 2'd0;
        else if (inc_cnt) load_cnt <= load_cnt + 2'd1;
    end

    ///////////////////////////////////////////////////////////////////////////
    // FLUSH pipeline drain tracker
    // Clears on any non-FLUSH cycle so result_valid drops when leaving FLUSH
    ///////////////////////////////////////////////////////////////////////////
    always_ff @(posedge clk, negedge rst_n) begin
        if      (!rst_n)           flush_rdy <= 1'b0;
        else if (state == FLUSH)   flush_rdy <= 1'b1;
        else                       flush_rdy <= 1'b0;
    end

    ///////////////////////////////////////////////////////////////////////////
    // Combinational output and next-state logic
    ///////////////////////////////////////////////////////////////////////////
    always_comb begin
        // Defaults
        next_state   = state;
        capture_cfg  = 1'b0;
        inc_cnt      = 1'b0;
        clr_cnt      = 1'b0;
        pe_en        = 1'b0;
        ld_bias      = 1'b0;
        quant_en     = 1'b0;
        relu_en_out  = 1'b0;
        bias_hi_wen  = 1'b0;
        bias_lo_wen  = 1'b0;
        scale_hi_wen = 1'b0;
        scale_lo_wen = 1'b0;
        result_valid = 1'b0;

        case (state)

            //------------------------------------------------------------------
            // IDLE: wait for first byte → treat as CFG byte
            //------------------------------------------------------------------
            IDLE: begin
                if (byte_valid) begin
                    capture_cfg = 1'b1;
                    next_state  = CFG;
                end
            end

            //------------------------------------------------------------------
            // CFG: 1-cycle decode of newly registered metadata
            // Transition to LOAD if bias/scale needed, else straight to BLOAD
            //------------------------------------------------------------------
            CFG: begin
                clr_cnt    = 1'b1;
                next_state = (BIAS_NEW_r | SCALE_NEW_r) ? LOAD : BLOAD;
            end

            //------------------------------------------------------------------
            // LOAD: receive bias and/or scale bytes (MSB first)
            //   BIAS_NEW_r & SCALE_NEW_r: 4 bytes (bias_hi, bias_lo, scale_hi, scale_lo)
            //   BIAS_NEW_r only:          2 bytes (bias_hi, bias_lo)
            //   SCALE_NEW_r only:         2 bytes (scale_hi, scale_lo)
            //------------------------------------------------------------------
            LOAD: begin
                if (byte_valid) begin
                    if (BIAS_NEW_r) begin
                        case (load_cnt)
                            2'd0: begin
                                bias_hi_wen = 1'b1;
                                inc_cnt     = 1'b1;
                            end
                            2'd1: begin
                                bias_lo_wen = 1'b1;
                                if (SCALE_NEW_r) inc_cnt = 1'b1;
                                else begin
                                    next_state = BLOAD;
                                    clr_cnt    = 1'b1;
                                end
                            end
                            2'd2: begin
                                scale_hi_wen = 1'b1;
                                inc_cnt      = 1'b1;
                            end
                            2'd3: begin
                                scale_lo_wen = 1'b1;
                                next_state   = BLOAD;
                                clr_cnt      = 1'b1;
                            end
                            default: next_state = BLOAD;
                        endcase
                    end else begin
                        // SCALE_NEW_r only: 2 bytes
                        case (load_cnt)
                            2'd0: begin
                                scale_hi_wen = 1'b1;
                                inc_cnt      = 1'b1;
                            end
                            2'd1: begin
                                scale_lo_wen = 1'b1;
                                next_state   = BLOAD;
                                clr_cnt      = 1'b1;
                            end
                            default: next_state = BLOAD;
                        endcase
                    end
                end
            end

            //------------------------------------------------------------------
            // BLOAD: assert ld_bias for exactly one cycle before STREAM
            // bias register is stable (updated at prior clock edge)
            // If BIAS_NEW=0, bias reg = 0 (reset default) → clears acc_q to 0
            //------------------------------------------------------------------
            BLOAD: begin
                ld_bias    = 1'b1;
                next_state = STREAM;
            end

            //------------------------------------------------------------------
            // STREAM: pe_en on every valid byte; simultaneous stream_done exits
            //------------------------------------------------------------------
            STREAM: begin
                if (byte_valid) begin
                    pe_en = 1'b1;
                    if (stream_done) next_state = FLUSH;
                end
            end

            //------------------------------------------------------------------
            // FLUSH: VU fires on first cycle, result held until new byte_valid
            //   quant_en  = ~flush_rdy  (first cycle only, acc_out is final)
            //   result_valid = flush_rdy (from second cycle onwards)
            // New byte_valid treated as next CFG; transition back to CFG
            //------------------------------------------------------------------
            FLUSH: begin
                quant_en     = ~flush_rdy;
                relu_en_out  = RELU_EN_r & ~flush_rdy;
                result_valid = flush_rdy;

                if (byte_valid) begin
                    capture_cfg = 1'b1;
                    next_state  = CFG;
                end
            end

            default: next_state = IDLE;

        endcase
    end

    assign state_out = state;
endmodule