///////////////////////////////////////////////////////////////////////////////
// Module: gemm_systolic_array.sv
// Description: 1xN Systolic Array — hardcoded ROWS=1, COLS=2.
//
//   h_pe_en / v_pe_en replaced by pe_en[COLS]: pre-computed in CU,
//   passed directly to each PE — eliminates h_en_mesh and v_en_mesh.
//
//   Weights connect directly from w_row[j] boundary; no w_mesh needed
//   (ROWS=1: no south propagation).
//
//   data_vld broadcast to all PEs for pipeline freeze on stall.
//
// Author: Group5
///////////////////////////////////////////////////////////////////////////////

module gemm_systolic_array #(
    parameter ROWS       = 1,
    parameter COLS       = 2,
    parameter ACT_WIDTH  = 4,
    parameter WGT_WIDTH  = 4,
    parameter ACC_WIDTH  = 16
) (
    input  logic                                clk,

    // Activation input (one per row — ROWS=1)
    input  logic [ROWS-1:0][ACT_WIDTH-1:0]     i_col,

    // Weight inputs — connected directly to each PE (no mesh)
    input  logic [COLS-1:0][WGT_WIDTH-1:0]     w_row,

    // Pre-computed PE enables from CU (pe_en[j] drives PE[0][j].pe_en)
    input  logic [COLS-1:0]                     pe_en,

    // Bias
    input  logic [ACC_WIDTH-1:0]                bias,
    input  logic [COLS-1:0]                     ld_bias,

    // Pipeline freeze: 0 = stall all PE propagation and accumulation
    input  logic                                data_vld,

    // Accumulator outputs
    output logic [COLS-1:0][ACC_WIDTH-1:0]      sa_out
);

    ///////////////////////////////////////////////////////////////////////////
    // Activation mesh — horizontal propagation only (ROWS=1, COLS+1 entries)
    ///////////////////////////////////////////////////////////////////////////
    logic [ROWS-1:0][COLS:0][ACT_WIDTH-1:0]   a_mesh;
    logic [ROWS-1:0][COLS-1:0][ACC_WIDTH-1:0] acc_mesh;

    // Bias demux
    logic [COLS-1:0][ACC_WIDTH-1:0] bias_col;
    genvar j;
    generate
        for (j = 0; j < COLS; j = j + 1) begin : bias_demux
            assign bias_col[j] = ld_bias[j] ? bias : '0;
        end
    endgenerate

    // Boundary: activation row enters from the left
    genvar i;
    generate
        for (i = 0; i < ROWS; i = i + 1) begin : boundary_h
            assign a_mesh[i][0] = i_col[i];
        end
    endgenerate

    ///////////////////////////////////////////////////////////////////////////
    // PE grid
    ///////////////////////////////////////////////////////////////////////////
    generate
        for (i = 0; i < ROWS; i = i + 1) begin : row_gen
            for (j = 0; j < COLS; j = j + 1) begin : col_gen
                gemm_pe pe_inst (
                    .clk      (clk),
                    .a_in     (a_mesh[i][j]),
                    .w_in     (w_row[j]),        // direct boundary — no w_mesh
                    .bias     (bias_col[j]),
                    .ld_bias  (ld_bias[j]),
                    .pe_en    (pe_en[j]),         // pre-computed, no local AND
                    .data_vld (data_vld),
                    .a_out    (a_mesh[i][j+1]),
                    .acc_out  (acc_mesh[i][j])
                );
            end
        end
    endgenerate

    ///////////////////////////////////////////////////////////////////////////
    // Outputs
    ///////////////////////////////////////////////////////////////////////////
    generate
        for (j = 0; j < COLS; j = j + 1) begin : col_out_gen
            assign sa_out[j] = acc_mesh[0][j];
        end
    endgenerate

endmodule