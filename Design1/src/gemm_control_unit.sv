///////////////////////////////////////////////////////////////////////////////
// Module: gemm_control_unit.sv
// Description: Top-level Control Unit for GEMM Core. Instantiates the FSM
//              and implements all datapath logic:
//                - Metadata holding registers (A/W/K_DIM_r, masks, compute limit)
//                - main_cnt (5-bit) and bias_cnt (4-bit) counters
//                - Done signal generation (data_load_done, bias_load_done,
//                  compute_done, flush_done)
//                - pe_wave shift register (8-bit)
//                - 8-bit vector generation for all enable outputs
//                - WR_ADDR and COL_ADDR generation from main_cnt
//
// Dimension encoding: 4-bit inputs {1-8} representing actual dimension size
//
// Done signal conventions:
//   LOAD_FIFO:    cnt == DIM_r     (fires one cycle AFTER last handshake)
//   GEMM_COMPUTE: cnt == LIM_r     (fires ON last active cycle, no wasted cycle)
//   GEMM_FLUSH:   cnt == DIM_r-1   (fires ON last Y_RDY handshake)
//
// Author: Group5
///////////////////////////////////////////////////////////////////////////////

import gemm_pkg::*;

module gemm_control_unit (
    // Global Inputs
    input  logic                    clk,
    input  logic                    rst_n,

    // External Inputs
    input  logic                    TILE_START,
    input  logic                    METADATA_VLD,
    input  logic [DIM_WIDTH-1:0]    A_LEN,          // {1-8} actual dimension
    input  logic [DIM_WIDTH-1:0]    W_LEN,
    input  logic [DIM_WIDTH-1:0]    K_LEN,
    input  logic                    BIAS_NEW,
    input  logic                    TILE_LAST,
    input  logic                    RELU_EN,
    input  logic                    DATA_VLD,
    input  logic                    BIAS_VLD,
    input  logic                    Y_RDY,

    // External Outputs
    output logic                    METADATA_RDY,
    output logic                    DATA_RDY,
    output logic                    BIAS_RDY,
    output logic                    SCALE_RDY,      // = Y_RDY pass-through
    output logic                    Y_VLD,
    output logic                    TILE_DONE,

    // FIFO Control Outputs
    output logic [ARRAY_SIZE-1:0]   A_IN_EN,        // active activation FIFOs to write
    output logic [ARRAY_SIZE-1:0]   W_IN_EN,        // active weight FIFOs to write
    output logic [FIFO_ADDR_WIDTH-1:0] WR_ADDR,     // FIFO write address = main_cnt
    output logic [ARRAY_SIZE-1:0]   A_OUT_EN,       // pe_wave & A_MASK — read enable
    output logic [ARRAY_SIZE-1:0]   W_OUT_EN,       // pe_wave & W_MASK — read enable

    // Systolic Array Control Outputs
    output logic [ARRAY_SIZE-1:0]   H_PE_EN,        // horizontal PE enables
    output logic [ARRAY_SIZE-1:0]   V_PE_EN,        // vertical PE enables
    output logic [ARRAY_SIZE-1:0]   LD_BIAS,        // one-hot bias column load
    output logic [FIFO_ADDR_WIDTH-1:0] COL_ADDR,    // column address for flush

    // Vector Unit Control Outputs
    output logic [ARRAY_SIZE-1:0]   QUANT_EN,       // A_MASK_r when quantizing
    output logic                    RELU_EN_out     // registered RELU_EN from metadata
);



	///////////////////////////////////////////////////////////////////////////
    // Internal FSM Control Signals & FSM Instantiation
    ///////////////////////////////////////////////////////////////////////////

    // FSM → CU datapath controls
    logic        capture_metadata;
    logic        clr_main_cnt,   inc_main_cnt;
    logic        clr_bias_cnt,   inc_bias_cnt;
    logic        clr_pe_wave,    shift_pe_wave;

    // FSM 1-bit enable outputs → expanded to 8-bit vectors in CU
    logic        fsm_FIFO_IN_EN,    fsm_FIFO_OUT_EN;
    logic        fsm_LD_BIAS_en;
    logic        fsm_PE_EN;
    logic        fsm_QUANT_EN,   fsm_RELU_EN_out;

    // Done signals → FSM
    logic        data_load_done;
    logic        bias_load_done;
    logic        compute_done;
    logic        flush_done;
	
	gemm_fsm u_gemm_fsm (
        .clk              (clk),
        .rst_n            (rst_n),

        // External inputs
        .TILE_START       (TILE_START),
        .METADATA_VLD     (METADATA_VLD),
        .BIAS_NEW         (BIAS_NEW),
        .TILE_LAST        (TILE_LAST),
        .RELU_EN          (RELU_EN),
        .DATA_VLD         (DATA_VLD),
        .BIAS_VLD         (BIAS_VLD),
        .Y_RDY            (Y_RDY),

        // Done signals from CU datapath → FSM
        .data_load_done   (data_load_done),
        .bias_load_done   (bias_load_done),
        .compute_done     (compute_done),
        .flush_done       (flush_done),

        // CU datapath controls ← FSM
        .capture_metadata (capture_metadata),
        .clr_main_cnt     (clr_main_cnt),
        .inc_main_cnt     (inc_main_cnt),
        .clr_bias_cnt     (clr_bias_cnt),
        .inc_bias_cnt     (inc_bias_cnt),
        .clr_pe_wave      (clr_pe_wave),
        .shift_pe_wave    (shift_pe_wave),

        // 1-bit enables → CU vector expansion
        .FIFO_IN_EN       (fsm_FIFO_IN_EN),
        .LD_BIAS_en       (fsm_LD_BIAS_en),
        .PE_EN            (fsm_PE_EN),
        .FIFO_OUT_EN      (fsm_FIFO_OUT_EN),
        .QUANT_EN         (fsm_QUANT_EN),
        .RELU_EN_out      (fsm_RELU_EN_out),

        // External outputs — direct from FSM
        .DATA_RDY         (DATA_RDY),
        .BIAS_RDY         (BIAS_RDY),
        .Y_VLD            (Y_VLD),
        .TILE_DONE        (TILE_DONE),
        .METADATA_RDY     (METADATA_RDY)
    );



	///////////////////////////////////////////////////////////////////////////
    // Metadata Holding Registers
    // Latched on capture_metadata pulse
    // 4-bit dims {1-8} stored directly — no conversion needed
    ///////////////////////////////////////////////////////////////////////////
    logic [DIM_WIDTH-1:0]   A_DIM_r;
    logic [DIM_WIDTH-1:0]   W_DIM_r;
    logic [DIM_WIDTH-1:0]   K_DIM_r;
    logic [ARRAY_SIZE-1:0]  A_MASK_r;       // (1 << A_DIM_r) - 1 : gates active rows
    logic [ARRAY_SIZE-1:0]  W_MASK_r;       // (1 << W_DIM_r) - 1 : gates active cols
    logic [MAIN_CNT_WIDTH-1:0] COMPUTE_LIM_r;

    always_ff @(posedge clk, negedge rst_n) begin
        if (!rst_n) begin
            A_DIM_r       <= {{(DIM_WIDTH-1){1'b0}}, 1'b1};    // reset to dim=1
            W_DIM_r       <= {{(DIM_WIDTH-1){1'b0}}, 1'b1};
            K_DIM_r       <= {{(DIM_WIDTH-1){1'b0}}, 1'b1};
            A_MASK_r      <= {{(ARRAY_SIZE-1){1'b0}}, 1'b1};   // mask for dim=1
            W_MASK_r      <= {{(ARRAY_SIZE-1){1'b0}}, 1'b1};
            COMPUTE_LIM_r <= '0;
        end else if (capture_metadata) begin
            A_DIM_r       <= A_LEN;
            W_DIM_r       <= W_LEN;
            K_DIM_r       <= K_LEN;
            A_MASK_r      <= ({{(ARRAY_SIZE-1){1'b0}}, 1'b1} << A_LEN) - 1'b1;
            W_MASK_r      <= ({{(ARRAY_SIZE-1){1'b0}}, 1'b1} << W_LEN) - 1'b1;
            COMPUTE_LIM_r <= (MAIN_CNT_WIDTH'(A_LEN) +
                              MAIN_CNT_WIDTH'(W_LEN) +
                              MAIN_CNT_WIDTH'(K_LEN)) -
                              MAIN_CNT_WIDTH'(3);
        end
    end
	
	
	
	///////////////////////////////////////////////////////////////////////////
    // Counters
    // main_cnt [4:0] : shared across LOAD_FIFO, GEMM_COMPUTE, GEMM_FLUSH
    // bias_cnt [3:0] : LOAD_FIFO bias loading only
    ///////////////////////////////////////////////////////////////////////////
    logic [MAIN_CNT_WIDTH-1:0]  main_cnt;
    logic [BIAS_CNT_WIDTH-1:0]  bias_cnt;
    always_ff @(posedge clk, negedge rst_n) begin
        if (!rst_n) begin
			main_cnt <= 5'd0;
		end
        else if (clr_main_cnt) begin
			main_cnt <= 5'd0;
		end
        else if (inc_main_cnt) begin
			main_cnt <= main_cnt + 5'd1;
		end
    end
	always_ff @(posedge clk, negedge rst_n) begin
        if (!rst_n) begin
			bias_cnt <= 4'd0;
		end
        else if (clr_bias_cnt) begin
			bias_cnt <= 4'd0;
		end
        else if (inc_bias_cnt) begin
			bias_cnt <= bias_cnt + 4'd1;
		end
    end
	
	
	
	///////////////////////////////////////////////////////////////////////////
    // Done Signal Generation
    //
    // data_load_done: main_cnt == K_DIM_r
    //   fires one cycle AFTER last DATA handshake (cnt overshoots by 1)
    //   DATA_RDY = ~data_load_done naturally prevents further handshakes
    //
    // bias_load_done: bias_cnt == W_DIM_r
    //   same one-cycle-over convention for LOAD_FIFO
    //
    // compute_done: main_cnt == COMPUTE_LIM_r
    //   fires ON last active compute cycle — no wasted cycle
    //   FSM transitions and clears on same clock edge
    //
    // flush_done: main_cnt == W_DIM_r - 1
    //   fires ON last Y_RDY handshake cycle
    //   FSM transitions on same clock edge as last column output
    ///////////////////////////////////////////////////////////////////////////
    assign data_load_done = (main_cnt == MAIN_CNT_WIDTH'(K_DIM_r));
    assign bias_load_done = (bias_cnt == W_DIM_r);
    assign compute_done   = (main_cnt == COMPUTE_LIM_r);
    assign flush_done     = (main_cnt == (MAIN_CNT_WIDTH'(W_DIM_r) - 1'b1));



	///////////////////////////////////////////////////////////////////////////
    // pe_wave Shift Register (8-bit)
    //
    // In GEMM_COMPUTE, shifts left each cycle:
    //   - Shifts in 1 for first K_DIM_r cycles  (filling the wave)
    //   - Shifts in 0 for remaining drain cycles
    // pe_wave[i] high for exactly K cycles starting at cycle i
    ///////////////////////////////////////////////////////////////////////////
    logic [ARRAY_SIZE-1:0]  pe_wave;
    logic                   pe_shift_in;

    assign pe_shift_in = (main_cnt < MAIN_CNT_WIDTH'(K_DIM_r));

    always_ff @(posedge clk, negedge rst_n) begin
        if (!rst_n) begin 
			pe_wave <= '0;
		end
        else if (clr_pe_wave) begin
			pe_wave <= '0;
		end
        else if (shift_pe_wave) begin
			pe_wave <= {pe_wave[ARRAY_SIZE-2:0], pe_shift_in};
		end
    end
	
	
	
	///////////////////////////////////////////////////////////////////////////
    // 8-bit Vector Generation
    //
    // FIFO write enables (LOAD_FIFO):
    //   All active FIFOs enabled simultaneously each handshake cycle
    //   A_IN_EN = A_MASK_r  (all active activation rows written in parallel)
    //   W_IN_EN = W_MASK_r  (all active weight cols written in parallel)
    //
    // FIFO read + PE enables (GEMM_COMPUTE):
    //   pe_wave provides K-wide moving window
    //   Masked by A/W_MASK_r to gate inactive rows/cols
    //   A_OUT_EN == H_PE_EN : activation FIFO row i reads when pe_wave[i]=1
    //   W_OUT_EN == V_PE_EN : weight FIFO col j reads when pe_wave[j]=1
    //
    // QUANT_EN (GEMM_FLUSH):
    //   All active output rows quantized simultaneously = A_MASK_r
    ///////////////////////////////////////////////////////////////////////////

     // FIFO input enables — all active FIFOs write in parallel each handshake
    assign A_IN_EN  = {ARRAY_SIZE{fsm_FIFO_IN_EN}} & A_MASK_r;
    assign W_IN_EN  = {ARRAY_SIZE{fsm_FIFO_IN_EN}} & W_MASK_r;

    // FIFO output + PE enables — pe_wave moving window gated by mask
    assign A_OUT_EN = {ARRAY_SIZE{fsm_FIFO_OUT_EN}} & pe_wave & A_MASK_r;
    assign W_OUT_EN = {ARRAY_SIZE{fsm_FIFO_OUT_EN}} & pe_wave & W_MASK_r;
    assign H_PE_EN  = {ARRAY_SIZE{fsm_PE_EN}}       & pe_wave & A_MASK_r;
    assign V_PE_EN  = {ARRAY_SIZE{fsm_PE_EN}}       & pe_wave & W_MASK_r;

    // Quantization — all active output rows simultaneously
    assign QUANT_EN    = {ARRAY_SIZE{fsm_QUANT_EN}} & A_MASK_r;
    assign RELU_EN_out = fsm_RELU_EN_out;



	///////////////////////////////////////////////////////////////////////////
    // LD_BIAS One-Hot Vector
    // bias_cnt walks 0 → W_DIM_r-1, enabling one column accumulator per cycle
    // LD_BIAS[bias_cnt] = 1 each BIAS handshake
    ///////////////////////////////////////////////////////////////////////////
    assign LD_BIAS = {ARRAY_SIZE{fsm_LD_BIAS_en}} &
                     ({{(ARRAY_SIZE-1){1'b0}}, 1'b1} << bias_cnt[FIFO_ADDR_WIDTH-1:0]);



	///////////////////////////////////////////////////////////////////////////
    // SCALE_RDY — direct pass-through
    ///////////////////////////////////////////////////////////////////////////
    assign SCALE_RDY = Y_RDY;
	
	
	
	///////////////////////////////////////////////////////////////////////////
    // Address Generation
    // WR_ADDR  : FIFO write address in LOAD_FIFO  = main_cnt[2:0]
    // COL_ADDR : column flush address in GEMM_FLUSH = main_cnt[2:0]
    // Both sourced from same counter — MUX not needed, different states
    ///////////////////////////////////////////////////////////////////////////
    assign WR_ADDR  = main_cnt[FIFO_ADDR_WIDTH-1:0];
    assign COL_ADDR = main_cnt[FIFO_ADDR_WIDTH-1:0];
endmodule