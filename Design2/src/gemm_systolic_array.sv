///////////////////////////////////////////////////////////////////////////////
// Module: gemm_systolic_array.sv
// Description: 8x8 Systolic Array for GEMM compute. Instantiates
//              ARRAY_SIZE x ARRAY_SIZE gemm_pe cells and wires them
//              into a 2D mesh with the following dataflow:
//
//              Data flow:
//                Activations  : enter left column (col 0), flow EAST
//                Weights      : enter top row    (row 0), flow SOUTH
//                Enables      : same — H_PE_EN[i] enters PE[i][0].h_en_in
//                                       V_PE_EN[j] enters PE[0][j].v_en_in
//                               then ripple through pipeline regs diagonally
//
//              Bias:
//                BIAS [ACC_WIDTH-1:0] broadcast to all PEs
//                LD_BIAS[j] one-hot per column — loads bias into all PEs
//                in column j simultaneously (broadcast down each column)
//
//              Output:
//                SA_OUT[col][row] exposes all ACC_WIDTH accumulator outputs
//                directly. Column mux (COL_ADDR) moved to gemm_top.
//
// Connections:
//   I_COL[i]   → PE[i][0].a_in   (activation row i enters left edge)
//   W_ROW[j]   → PE[0][j].w_in   (weight col j enters top edge)
//   H_PE_EN[i] → PE[i][0].h_en_in
//   V_PE_EN[j] → PE[0][j].v_en_in
//   PE[i][j].a_out   → PE[i][j+1].a_in
//   PE[i][j].h_en_out→ PE[i][j+1].h_en_in
//   PE[i][j].w_out   → PE[i+1][j].w_in
//   PE[i][j].v_en_out→ PE[i+1][j].v_en_in
//   PE[i][j].acc_out → sa_out[j][i]
//
// Author: Group5
///////////////////////////////////////////////////////////////////////////////

module gemm_systolic_array #(
    parameter ARRAY_SIZE      = 8,
    parameter ACT_WIDTH       = 4,
    parameter WGT_WIDTH       = 4,
    parameter ACC_WIDTH       = 16
) (
    // Global
    input  logic                                        clk,

    // Activation inputs (one per row, enters left edge)
    input  logic [ARRAY_SIZE-1:0][ACT_WIDTH-1:0]  i_col,   // I_COL[row]

    // Weight inputs (one per column, enters top edge)
    input  logic [ARRAY_SIZE-1:0][WGT_WIDTH-1:0]  w_row,   // W_ROW[col]

    // PE enable vectors from Control Unit
    input  logic [ARRAY_SIZE-1:0]   h_pe_en,    // horizontal enables → left col
    input  logic [ARRAY_SIZE-1:0]   v_pe_en,    // vertical enables   → top row

    // Bias
    input  logic [ACC_WIDTH-1:0]    bias,       // broadcast to all PEs
    input  logic [ARRAY_SIZE-1:0]   ld_bias,    // one-hot per column

    // Full accumulator output mesh: sa_out[col][row]
    // col=0 is leftmost (x~105um), col=7 is rightmost (x~1135um)
    output logic [ARRAY_SIZE-1:0][ARRAY_SIZE-1:0][ACC_WIDTH-1:0] sa_out
);


    ///////////////////////////////////////////////////////////////////////////
    // Internal mesh wires
    ///////////////////////////////////////////////////////////////////////////
    logic [ARRAY_SIZE-1:0][ARRAY_SIZE:0][ACT_WIDTH-1:0]   a_mesh;
    logic [ARRAY_SIZE:0][ARRAY_SIZE-1:0][WGT_WIDTH-1:0]   w_mesh;
    logic [ARRAY_SIZE-1:0][ARRAY_SIZE:0]                   h_en_mesh;
    logic [ARRAY_SIZE:0][ARRAY_SIZE-1:0]                   v_en_mesh;
    logic [ARRAY_SIZE-1:0][ARRAY_SIZE-1:0][ACC_WIDTH-1:0]  acc_mesh;

    ///////////////////////////////////////////////////////////////////////////
    // Boundary connections
    ///////////////////////////////////////////////////////////////////////////
    genvar i, j;
    generate
        for (i = 0; i < ARRAY_SIZE; i++) begin : boundary_h
            assign a_mesh[i][0]    = i_col[i];
            assign h_en_mesh[i][0] = h_pe_en[i];
        end

        for (j = 0; j < ARRAY_SIZE; j++) begin : boundary_v
            assign w_mesh[0][j]    = w_row[j];
            assign v_en_mesh[0][j] = v_pe_en[j];
        end
    endgenerate

    // Bias demux: avoid broadcast fanout across all PEs
    logic [ARRAY_SIZE-1:0][ACC_WIDTH-1:0] bias_col;
    generate
        for (j = 0; j < ARRAY_SIZE; j++) begin : bias_demux
            assign bias_col[j] = ld_bias[j] ? bias : '0;
        end
    endgenerate

    ///////////////////////////////////////////////////////////////////////////
    // PE grid instantiation
    ///////////////////////////////////////////////////////////////////////////
    generate
        for (i = 0; i < ARRAY_SIZE; i++) begin : row_gen
            for (j = 0; j < ARRAY_SIZE; j++) begin : col_gen
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
    // Output: expose full accumulator mesh
    // sa_out[j][i] = acc_mesh[i][j]  (col-major for South pin alignment)
    // Flat bit index: sa_out[j*128 + i*16 +: 16] = col j, row i
    ///////////////////////////////////////////////////////////////////////////
    generate
        for (i = 0; i < ARRAY_SIZE; i++) begin : row_out_gen
            for (j = 0; j < ARRAY_SIZE; j++) begin : col_out_gen
                assign sa_out[j][i] = acc_mesh[i][j];
            end
        end
    endgenerate

endmodule