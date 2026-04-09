///////////////////////////////////////////////////////////////////////////////
// Module: gemm_fifo.sv
// Description: Generic synchronous circular FIFO used for activation and
//              weight storage in the GEMM Core. Depth and width are sourced
//              from gemm_pkg to ensure consistency across all instances.
//
//              Read pointer: internal per-FIFO, increments on read_en.
//              Each FIFO instance tracks its own read position independently,
//              allowing staggered readout across the systolic array rows/cols.
//
// Author: Group5
///////////////////////////////////////////////////////////////////////////////

module gemm_fifo #(
    parameter ACT_WIDTH       = 4,
    parameter FIFO_DEPTH      = 8,
    parameter FIFO_ADDR_WIDTH = $clog2(FIFO_DEPTH)
) (
    // Global
    input  logic                    clk,
    input  logic                    rst_n,

    // Write Port
    input  logic [ACT_WIDTH-1:0]    data_in,    // input data (ACT or WGT width)
    input  logic                    write_en,   // write enable from Control Unit
	input  logic [FIFO_ADDR_WIDTH-1:0] 	write_ptr,

    // Read Port — address managed internally per-FIFO instance
    input  logic                    read_en,    // read enable from Control Unit
    output logic [ACT_WIDTH-1:0]    data_out    // output data to systolic array
);


    ///////////////////////////////////////////////////////////////////////////
    // FIFO Memory
    ///////////////////////////////////////////////////////////////////////////
    logic [FIFO_DEPTH-1:0][ACT_WIDTH-1:0] fifo_mem;

    ///////////////////////////////////////////////////////////////////////////
    // Internal Read Pointer (permanent)
    // Each FIFO instance independently tracks its own read position.
    // Increments on read_en — allows staggered readout across rows/cols
    // as pe_wave propagates through the systolic array.
    ///////////////////////////////////////////////////////////////////////////
    logic [FIFO_ADDR_WIDTH-1:0] read_ptr;

    always_ff @(posedge clk, negedge rst_n) begin
        if (!rst_n) begin 
			read_ptr <= '0;
		end
        else if (read_en) begin
			read_ptr <= read_ptr + 1'b1;
		end
    end

    ///////////////////////////////////////////////////////////////////////////
    // Write Operation
    ///////////////////////////////////////////////////////////////////////////
    always_ff @(posedge clk) begin
        if (write_en) begin
            fifo_mem[write_ptr] <= data_in;
		end
    end

    ///////////////////////////////////////////////////////////////////////////
    // Read Operation
    ///////////////////////////////////////////////////////////////////////////
	assign data_out = read_en ? fifo_mem[read_ptr] : '0;
endmodule
