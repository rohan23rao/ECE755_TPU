///////////////////////////////////////////////////////////////////////////////
// Module: gemm_systolic_array.sv
// Description: 1xN Systolic Array for GEMM compute (Tiny Tapeout).
//              ROWS is hardcoded to 1 at synthesis; COLS=2 for 1x2 design.
//
//              Data flow:
//                Activations  : single row enters left edge (col 0), flow EAST
//                Weights      : enter top row (row 0), flow SOUTH (1 hop only)
//                Enables      : H_PE_EN[0] enters PE[0][0].h_en_in
//                               V_PE_EN[j] enters PE[0][j].v_en_in
//                               ripple east (h) / south (v) through pipeline regs
//
//              Bias:
//                BIAS[ACC_WIDTH-1:0] broadcast; LD_BIAS[j] one-hot per column
//
//              Output:
//                sa_out[COLS-1:0][ACC_WIDTH-1:0] — 1D, one acc per column
//
// Connections:
//   i_col[0]      → PE[0][0].a_in
//   w_row[j]      → PE[0][j].w_in
//   H_PE_EN[0]    → PE[0][0].h_en_in
//   V_PE_EN[j]    → PE[0][j].v_en_in
//   PE[0][j].a_out    → PE[0][j+1].a_in
//   PE[0][j].h_en_out → PE[0][j+1].h_en_in
//   PE[0][j].w_out    → (unused; ROWS=1, no row below)
//   PE[0][j].v_en_out → (unused; ROWS=1)
//   PE[0][j].acc_out  → sa_out[j]
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
    // Global
    input  logic                                clk,

    // Activation inputs (one per row — ROWS=1)
    input  logic [ROWS-1:0][ACT_WIDTH-1:0]     i_col,

    // Weight inputs (one per column)
    input  logic [COLS-1:0][WGT_WIDTH-1:0]     w_row,

    // PE enable vectors
    input  logic [ROWS-1:0]                     h_pe_en,   // 1-bit for ROWS=1
    input  logic [COLS-1:0]                     v_pe_en,

    // Bias
    input  logic [ACC_WIDTH-1:0]                bias,
    input  logic [COLS-1:0]                     ld_bias,   // one-hot per column

    // Accumulator outputs: one per column (1D since ROWS=1)
    output logic [COLS-1:0][ACC_WIDTH-1:0]      sa_out
);

    ///////////////////////////////////////////////////////////////////////////
    // Internal mesh wires
    ///////////////////////////////////////////////////////////////////////////
    logic [ROWS-1:0][COLS:0][ACT_WIDTH-1:0]    a_mesh;
    logic [ROWS:0][COLS-1:0][WGT_WIDTH-1:0]    w_mesh;
    logic [ROWS-1:0][COLS:0]                    h_en_mesh;
    logic [ROWS:0][COLS-1:0]                    v_en_mesh;
    logic [ROWS-1:0][COLS-1:0][ACC_WIDTH-1:0]  acc_mesh;

    ///////////////////////////////////////////////////////////////////////////
    // Boundary connections
    ///////////////////////////////////////////////////////////////////////////
    genvar i, j;
    generate
        for (i = 0; i < ROWS; i = i + 1) begin : boundary_h
            assign a_mesh[i][0]    = i_col[i];
            assign h_en_mesh[i][0] = h_pe_en[i];
        end

        for (j = 0; j < COLS; j = j + 1) begin : boundary_v
            assign w_mesh[0][j]    = w_row[j];
            assign v_en_mesh[0][j] = v_pe_en[j];
        end
    endgenerate

    // Bias demux — one entry per column
    logic [COLS-1:0][ACC_WIDTH-1:0] bias_col;
    generate
        for (j = 0; j < COLS; j = j + 1) begin : bias_demux
            assign bias_col[j] = ld_bias[j] ? bias : '0;
        end
    endgenerate

    ///////////////////////////////////////////////////////////////////////////
    // PE grid — ROWS x COLS (1x2 for Tiny Tapeout)
    ///////////////////////////////////////////////////////////////////////////
    generate
        for (i = 0; i < ROWS; i = i + 1) begin : row_gen
            for (j = 0; j < COLS; j = j + 1) begin : col_gen
                gemm_pe pe_inst (
                    .clk      (clk),

                    .a_in     (a_mesh[i][j]),
                    .h_en_in  (h_en_mesh[i][j]),
                    .a_out    (a_mesh[i][j+1]),
                    .h_en_out (h_en_mesh[i][j+1]),

                    .w_in     (w_mesh[i][j]),
                    .v_en_in  (v_en_mesh[i][j]),
                    .w_out    (w_mesh[i+1][j]),
                    .v_en_out (v_en_mesh[i+1][j]),

                    .bias     (bias_col[j]),
                    .ld_bias  (ld_bias[j]),

                    .acc_out  (acc_mesh[i][j])
                );
            end
        end
    endgenerate

    ///////////////////////////////////////////////////////////////////////////
    // Output: sa_out[j] = acc_mesh[0][j]
    ///////////////////////////////////////////////////////////////////////////
    generate
        for (j = 0; j < COLS; j = j + 1) begin : col_out_gen
            assign sa_out[j] = acc_mesh[0][j];
        end
    endgenerate

endmodule