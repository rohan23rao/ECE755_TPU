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
//                COL_ADDR selects which column's ACC_OUT bus is presented
//                on COL_OUT[ACC_WIDTH-1:0][ARRAY_SIZE-1:0]
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
//   PE[i][j].acc_out → COL_OUT mux input [j][i]
//
// Author: Group5
///////////////////////////////////////////////////////////////////////////////

module gemm_systolic_array #(
    localparam int ARRAY_SIZE      = 8,              // 8x8 systolic array
    localparam int ACT_WIDTH       = 4,              // activation input bitwidth
    localparam int WGT_WIDTH       = 4,              // weight input bitwidth
    localparam int ACC_WIDTH       = 16,             // accumulator / MAC output bitwidth
    localparam int FIFO_DEPTH      = 8,              // entries per FIFO
    localparam int FIFO_ADDR_WIDTH = $clog2(FIFO_DEPTH) // 3-bit address
) (
    // Global
    input  logic                                        clk,
    input  logic                                        rst_n,

    // Activation inputs (one per row, enters left edge)
    // Converted from unpacked: logic [ACT_WIDTH-1:0] i_col [0:ARRAY_SIZE-1]
    input  logic [ARRAY_SIZE-1:0][ACT_WIDTH-1:0]   i_col,   // I_COL[row]

    // Weight inputs (one per column, enters top edge)
    // Converted from unpacked: logic [WGT_WIDTH-1:0] w_row [0:ARRAY_SIZE-1]
    input  logic [ARRAY_SIZE-1:0][WGT_WIDTH-1:0]   w_row,   // W_ROW[col]

    // PE enable vectors from Control Unit
    input  logic [ARRAY_SIZE-1:0]                   h_pe_en,    // horizontal enables → left col
    input  logic [ARRAY_SIZE-1:0]                   v_pe_en,    // vertical enables   → top row

    // Bias
    input  logic [ACC_WIDTH-1:0]                    bias,       // broadcast to all PEs
    input  logic [ARRAY_SIZE-1:0]                   ld_bias,    // one-hot per column

    // Column select & output
    input  logic [FIFO_ADDR_WIDTH-1:0]              col_addr,   // selects output col
    // Converted from unpacked: logic [ACC_WIDTH-1:0] col_out [0:ARRAY_SIZE-1]
    output logic [ARRAY_SIZE-1:0][ACC_WIDTH-1:0]   col_out     // selected col ACC_OUT
);

    ///////////////////////////////////////////////////////////////////////////
    // Internal mesh wires
    // a_mesh[i][j]     : activation flowing into PE[i][j] from west
    // w_mesh[i][j]     : weight flowing into PE[i][j] from north
    // h_en_mesh[i][j]  : horizontal enable into PE[i][j]
    // v_en_mesh[i][j]  : vertical enable into PE[i][j]
    // acc_mesh[i][j]   : accumulator output of PE[i][j]
    //
    // Converted from 2D unpacked to packed. Note asymmetric column/row
    // extents (+1) to hold the east/south boundary wires:
    //   a_mesh   [0:ARRAY_SIZE-1][0:ARRAY_SIZE]   → [ARRAY_SIZE-1:0][ARRAY_SIZE:0]
    //   w_mesh   [0:ARRAY_SIZE  ][0:ARRAY_SIZE-1] → [ARRAY_SIZE:0][ARRAY_SIZE-1:0]
    //   h_en_mesh[0:ARRAY_SIZE-1][0:ARRAY_SIZE]   → [ARRAY_SIZE-1:0][ARRAY_SIZE:0]
    //   v_en_mesh[0:ARRAY_SIZE  ][0:ARRAY_SIZE-1] → [ARRAY_SIZE:0][ARRAY_SIZE-1:0]
    //   acc_mesh [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1] → [ARRAY_SIZE-1:0][ARRAY_SIZE-1:0]
    ///////////////////////////////////////////////////////////////////////////
    logic [ARRAY_SIZE-1:0][ARRAY_SIZE:0][ACT_WIDTH-1:0]   a_mesh;
    logic [ARRAY_SIZE:0][ARRAY_SIZE-1:0][WGT_WIDTH-1:0]   w_mesh;
    logic [ARRAY_SIZE-1:0][ARRAY_SIZE:0]                   h_en_mesh;
    logic [ARRAY_SIZE:0][ARRAY_SIZE-1:0]                   v_en_mesh;
    logic [ARRAY_SIZE-1:0][ARRAY_SIZE-1:0][ACC_WIDTH-1:0]  acc_mesh;

    ///////////////////////////////////////////////////////////////////////////
    // Boundary connections — left column and top row inputs
    ///////////////////////////////////////////////////////////////////////////
    genvar i, j;
    generate
        for (i = 0; i < ARRAY_SIZE; i++) begin : boundary_h
            // Activation row i enters left edge of PE[i][0]
            assign a_mesh[i][0]    = i_col[i];
            // Horizontal enable for row i enters left edge
            assign h_en_mesh[i][0] = h_pe_en[i];
        end

        for (j = 0; j < ARRAY_SIZE; j++) begin : boundary_v
            // Weight col j enters top edge of PE[0][j]
            assign w_mesh[0][j]    = w_row[j];
            // Vertical enable for col j enters top edge
            assign v_en_mesh[0][j] = v_pe_en[j];
        end
    endgenerate

    ///////////////////////////////////////////////////////////////////////////
    // PE grid instantiation
    // PE[i][j] : row i (0=top), col j (0=left)
    //   a_in    ← a_mesh[i][j]       (from west or left boundary)
    //   a_out   → a_mesh[i][j+1]     (to east)
    //   h_en_in ← h_en_mesh[i][j]
    //   h_en_out→ h_en_mesh[i][j+1]
    //   w_in    ← w_mesh[i][j]       (from north or top boundary)
    //   w_out   → w_mesh[i+1][j]     (to south)
    //   v_en_in ← v_en_mesh[i][j]
    //   v_en_out→ v_en_mesh[i+1][j]
    //   bias    ← bias (broadcast)
    //   ld_bias ← ld_bias[j] (column j loads bias into all its rows)
    //   acc_out → acc_mesh[i][j]
    ///////////////////////////////////////////////////////////////////////////
    generate
        for (i = 0; i < ARRAY_SIZE; i++) begin : row_gen
            for (j = 0; j < ARRAY_SIZE; j++) begin : col_gen
                gemm_pe pe_inst (
                    .clk      (clk),
                    .rst_n      (rst_n),

                    // Horizontal
                    .a_in     (a_mesh[i][j]),
                    .h_en_in  (h_en_mesh[i][j]),
                    .a_out    (a_mesh[i][j+1]),
                    .h_en_out (h_en_mesh[i][j+1]),

                    // Vertical
                    .w_in     (w_mesh[i][j]),
                    .v_en_in  (v_en_mesh[i][j]),
                    .w_out    (w_mesh[i+1][j]),
                    .v_en_out (v_en_mesh[i+1][j]),

                    // Bias — broadcast value, one-hot column select
                    .bias     (bias),
                    .ld_bias  (ld_bias[j]),

                    // Accumulator output
                    .acc_out  (acc_mesh[i][j])
                );
            end
        end
    endgenerate

    ///////////////////////////////////////////////////////////////////////////
    // Column output mux
    // COL_ADDR selects which column's accumulator bus is driven onto col_out
    // col_out[i] = acc_mesh[i][col_addr]  for all rows i
    // This is an 8-wide mux across ARRAY_SIZE columns of ACC_WIDTH-bit values
    ///////////////////////////////////////////////////////////////////////////
    generate
        for (i = 0; i < ARRAY_SIZE; i++) begin : col_out_gen
            assign col_out[i] = acc_mesh[i][col_addr];
        end
    endgenerate
endmodule
