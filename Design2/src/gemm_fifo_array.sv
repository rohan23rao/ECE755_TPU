///////////////////////////////////////////////////////////////////////////////
// Module: gemm_fifo_array.sv
// Description: Generates ARRAY_SIZE instances of gemm_fifo in parallel,
//              forming either the activation or weight FIFO bank for the
//              GEMM Core. All sizing sourced from gemm_pkg.
//
//              Each FIFO instance corresponds to one row (activation) or
//              one column (weight) of the systolic array.
//
//              Write enables : write_en[i] — from Control Unit A/W_IN_EN
//              Read enables  : read_en[i]  — from Control Unit A/W_OUT_EN
//
//              Write pointer : shared external write pointer design
//              Read pointer  : internal per-FIFO, staggered by pe_wave timing
//
// Author: Group5
///////////////////////////////////////////////////////////////////////////////

module gemm_fifo_array #(
    parameter ARRAY_SIZE      = 8,
    parameter ACT_WIDTH       = 4,
    parameter FIFO_ADDR_WIDTH = $clog2(8)
) (
    // Global
    input  logic                        clk,
    input  logic                        rst_n,

    // Write Port
    input  logic [ARRAY_SIZE-1:0][ACT_WIDTH-1:0]  data_in,
    input  logic [ARRAY_SIZE-1:0]                  write_en,   // from A/W_IN_EN
	input  logic [FIFO_ADDR_WIDTH-1:0]             write_ptr,

    // Read Port
    input  logic [ARRAY_SIZE-1:0]                  read_en,    // from A/W_OUT_EN
    output logic [ARRAY_SIZE-1:0][ACT_WIDTH-1:0]   data_out
);


    ///////////////////////////////////////////////////////////////////////////
    // Generate ARRAY_SIZE gemm_fifo instances
    ///////////////////////////////////////////////////////////////////////////
    genvar i;
    generate
        for (i = 0; i < ARRAY_SIZE; i++) begin : fifo_gen
            gemm_fifo fifo_inst (
                .clk      (clk),
                .rst_n    (rst_n),
                .data_in  (data_in[i]),
                .write_en (write_en[i]),
				.write_ptr(write_ptr),
                .read_en  (read_en[i]),
                .data_out (data_out[i])
            );
        end
    endgenerate
endmodule