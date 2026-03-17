///////////////////////////////////////////////////////////////////////////////
// Module: gemm_fifo.sv
// Description: Generic synchronous circular FIFO used for activation and
//              weight storage in the GEMM Core. Depth and width are sourced
//              from gemm_pkg to ensure consistency across all instances.
//
//              Write pointer: internal, temporary — increments on write_en.
//              Will be replaced by external FSM-driven global write pointer
//              (wr_addr from main_cnt) after synthesis area comparison.
//
//              Read pointer: internal per-FIFO, increments on read_en.
//              Each FIFO instance tracks its own read position independently,
//              allowing staggered readout across the systolic array rows/cols.
//
// Author: Group5
///////////////////////////////////////////////////////////////////////////////

import gemm_pkg::*;

module gemm_fifo (
    // Global
    input  logic                    clk,
    input  logic                    rst_n,

    // Write Port — address managed internally (temporary write_ptr)
    input  logic [ACT_WIDTH-1:0]    data_in,    // input data (ACT or WGT width)
    input  logic                    write_en,   // write enable from Control Unit

    // Read Port — address managed internally per-FIFO instance
    input  logic                    read_en,    // read enable from Control Unit
    output logic [ACT_WIDTH-1:0]    data_out    // output data to systolic array
);

    ///////////////////////////////////////////////////////////////////////////
    // FIFO Memory
    ///////////////////////////////////////////////////////////////////////////
    logic [ACT_WIDTH-1:0] fifo_mem [0:FIFO_DEPTH-1];

    ///////////////////////////////////////////////////////////////////////////
    // Internal Write Pointer (temporary)
    // Each cycle write_en is asserted, write_ptr advances.
    // Will be replaced by shared external wr_addr from main_cnt after
    // synthesis area comparison — only change needed is:
    //   fifo_mem[write_ptr] → fifo_mem[wr_addr]
    //   and removal of this always block + write_ptr declaration.
    ///////////////////////////////////////////////////////////////////////////
    logic [FIFO_ADDR_WIDTH-1:0] write_ptr;

    always_ff @(posedge clk, negedge rst_n) begin
        if      (!rst_n)    write_ptr <= '0;
        else if (write_en)  write_ptr <= write_ptr + 1'b1;
    end

    ///////////////////////////////////////////////////////////////////////////
    // Internal Read Pointer (permanent)
    // Each FIFO instance independently tracks its own read position.
    // Increments on read_en — allows staggered readout across rows/cols
    // as pe_wave propagates through the systolic array.
    ///////////////////////////////////////////////////////////////////////////
    logic [FIFO_ADDR_WIDTH-1:0] read_ptr;

    always_ff @(posedge clk, negedge rst_n) begin
        if      (!rst_n)   read_ptr <= '0;
        else if (read_en)  read_ptr <= read_ptr + 1'b1;
    end

    ///////////////////////////////////////////////////////////////////////////
    // Write Operation
    ///////////////////////////////////////////////////////////////////////////
    always_ff @(posedge clk) begin
        if (write_en)
            fifo_mem[write_ptr] <= data_in;
    end

    ///////////////////////////////////////////////////////////////////////////
    // Read Operation
    // Registered output — 1 cycle read latency
    ///////////////////////////////////////////////////////////////////////////
    always_ff @(posedge clk, negedge rst_n) begin
        if      (!rst_n)   data_out <= '0;
        else if (read_en)  data_out <= fifo_mem[read_ptr];
    end

endmodule
