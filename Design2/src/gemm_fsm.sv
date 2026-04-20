///////////////////////////////////////////////////////////////////////////////
//	Module: gemm_fsm.sv
//	Description: Primary internal FSM for handling external inputs/outputs, and
//	generating the internal enable signals to the control unit which will 
//	form the GEMM enable vectors.
//	Author: Group5
///////////////////////////////////////////////////////////////////////////////

module gemm_fsm (
	// Global Inputs
	input logic clk,
	input logic  rst_n,
	
	// External Inputs
	input logic TILE_START,
	input logic METADATA_VLD,
	input logic BIAS_NEW,
	input logic TILE_LAST,
	input logic RELU_EN,
	input logic DATA_VLD,
	input logic BIAS_VLD,
	input logic Y_RDY,
	input logic SCALE_VLD,        // scale value valid from vector unit
	
	// Control Unit Datapath Inputs
	input logic data_load_done,
	input logic bias_load_done,
	input logic compute_done,
	input logic flush_done,
	
	// Control Unit Datapath Outputs
	output logic capture_metadata, // 1-cycle pulse on IDLE→LOAD_FIFO
	output logic clr_main_cnt,
    output logic inc_main_cnt,
    output logic clr_bias_cnt,
    output logic inc_bias_cnt,
    output logic clr_pe_wave,
    output logic shift_pe_wave,
	
	// Internal Control Outputs
	output logic FIFO_IN_EN,       // 1-bit, CU generates 8-bit vector
	output logic LD_BIAS_en,    // 1-bit, CU uses bias_cnt to index vector
	output logic PE_EN,       // 1-bit, CU generates 8-bit gated vector
    output logic FIFO_OUT_EN,      // 1-bit, CU generates 8-bit gated vector
	output logic QUANT_EN,      // 1-bit, CU generates 8-bit vector
    output logic RELU_EN_out,   // registered RELU_EN from metadata
	
	// External Outputs
	output logic DATA_RDY,
    output logic BIAS_RDY,
	output logic SCALE_RDY,       // asserted in GEMM_FLUSH — ready to accept scale
	output logic Y_VLD,         // flopped 1 cycle
	output logic TILE_DONE,
    output logic METADATA_RDY
);

	////////////////////////////////////////////////////////////////
	// FSM Internal Signals
	////////////////////////////////////////////////////////////////

	// Internal FSM State Encoding
    typedef enum logic [1:0] {
        IDLE         = 2'b00,
        LOAD_FIFO    = 2'b01,
        GEMM_COMPUTE = 2'b10,
        GEMM_FLUSH   = 2'b11
    } gemm_state_t;
	gemm_state_t state, next_state;
	
	// Metadata Holding Registers
	logic BIAS_NEW_r;
    logic TILE_LAST_r;
    logic RELU_EN_r;
	
	// Y_VLD Flop
	logic y_vld_next;
	logic y_vld_pre;
	
	// Sticky flags: set when respective last handshake is seen, cleared on LOAD_FIFO entry
	logic data_done_r, bias_done_r;
	
	

	////////////////////////////////////////////////////////////////
	// FSM State Register & Metadata Capture Registers
	////////////////////////////////////////////////////////////////
	always @(posedge clk, negedge rst_n) begin
		if (!rst_n) begin
			state <= IDLE;
		end
		else begin
			state <= next_state;
		end
	end
	
	always @(posedge clk) begin
		if (capture_metadata) begin
			BIAS_NEW_r <= BIAS_NEW;
			TILE_LAST_r <= TILE_LAST;
			RELU_EN_r <= RELU_EN;
		end
	end
	
	always @(posedge clk, negedge rst_n) begin
		if (!rst_n) begin
			y_vld_pre <= '0;
			Y_VLD     <= '0;
		end
		else begin
			y_vld_pre <= y_vld_next;  // stage 1: 1 cycle after handshake
			Y_VLD     <= y_vld_pre;   // stage 2: 2 cycles after handshake → aligns with Y_OUT
		end
	end
	
	always_ff @(posedge clk, negedge rst_n) begin
		if (!rst_n) begin
			data_done_r <= 1'b0;
			bias_done_r <= 1'b0;
		end 
		else if (capture_metadata) begin   // entering LOAD_FIFO — reset for new tile
			data_done_r <= 1'b0;
			bias_done_r <= 1'b0;
		end 
		else if (state == LOAD_FIFO) begin
			if (DATA_VLD && ~data_done_r && data_load_done) begin
				data_done_r <= 1'b1;
			end
			if (BIAS_NEW_r && BIAS_VLD && ~bias_done_r && bias_load_done) begin
				bias_done_r <= 1'b1;
			end
		end
	end
	
	
	
	////////////////////////////////////////////////////////////////
	// Output & Next State Logic
	////////////////////////////////////////////////////////////////
	always_comb begin
		// Default ALL FSM Outputs
		capture_metadata = '0;
        clr_main_cnt     = '0;
        inc_main_cnt     = '0;
        clr_bias_cnt     = '0;
        inc_bias_cnt     = '0;
        clr_pe_wave      = '0;
        shift_pe_wave    = '0;
        DATA_RDY         = '0;
        BIAS_RDY         = '0;
		SCALE_RDY        = '0;
        FIFO_IN_EN       = '0;
        LD_BIAS_en       = '0;
        PE_EN            = '0;
        FIFO_OUT_EN      = '0;
        QUANT_EN         = '0;
        RELU_EN_out      = '0;
        y_vld_next       = '0;
        METADATA_RDY     = '0;
        TILE_DONE        = '0;
        next_state       = state;
		
		// State Logic
		case (state)
			IDLE: begin
				METADATA_RDY = 1;
				
				// EXTERNAL TILE INVOCATION
				if (TILE_START && METADATA_VLD) begin
					next_state = LOAD_FIFO;
					capture_metadata = 1;
				end
			end
			
			
			LOAD_FIFO: begin
				// DATA path — deassert RDY once last transaction seen
				DATA_RDY = ~data_done_r;
				if (DATA_VLD && DATA_RDY) begin
					FIFO_IN_EN   = 1;
					inc_main_cnt = ~data_load_done;  // suppress increment on last address
				end

				// BIAS path
				BIAS_RDY = BIAS_NEW_r && ~bias_done_r;
				if (BIAS_VLD && BIAS_RDY) begin
					LD_BIAS_en   = 1;
					inc_bias_cnt = ~bias_load_done;  // suppress increment on last address
				end

				// Mealy transition: fire on the cycle both channels complete
				// data_complete: already sticky OR finishing this cycle
				// bias_complete: not required, already sticky, OR finishing this cycle
				if ((data_done_r || (DATA_VLD && DATA_RDY && data_load_done)) &&
					(~BIAS_NEW_r || bias_done_r || (BIAS_VLD && BIAS_RDY && bias_load_done))) begin
					next_state   = GEMM_COMPUTE;
					clr_main_cnt = 1;
					clr_bias_cnt = 1;
				end
			end
			
			
			GEMM_COMPUTE: begin
				// Enable Systolic Array Shifting & PE Enables
				PE_EN      = 1;
				FIFO_OUT_EN     = 1;
				shift_pe_wave = 1;
				inc_main_cnt  = 1;
				
				// k+w+a-2 Cycles
				if (compute_done) begin
					clr_main_cnt = 1;
                    clr_pe_wave  = 1;
					if (TILE_LAST_r) begin
						next_state = GEMM_FLUSH;
					end
					else begin
						next_state = IDLE;
						TILE_DONE = 1;
					end
				end
			end
			
			
			GEMM_FLUSH: begin
				SCALE_RDY = Y_RDY; // Enable Upstream only when downstream is ready
			
				// Only advance when both output consumer (Y_RDY) and scale (SCALE_VLD) ready
				if (Y_RDY && SCALE_VLD) begin
					QUANT_EN    = 1;
					RELU_EN_out = RELU_EN_r;
                    inc_main_cnt = 1;
                    y_vld_next   = 1;

					// If on final cycle, transition out
					if (flush_done) begin
						next_state = IDLE;
						TILE_DONE = 1;
						clr_main_cnt = 1;
					end
				end
				else begin
					y_vld_next = y_vld_pre;  // stall — hold Y_VLD, gate everything else
				end
			end
			
			
			default : next_state = IDLE;
		endcase
	end
endmodule
