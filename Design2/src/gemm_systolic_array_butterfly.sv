///////////////////////////////////////////////////////////////////////////////
// Module: gemm_systolic_array_butterfly.sv
// Description: 8x8 Systolic Array for GEMM compute. Instantiates
//              4x8 gemm_butterfly_pe cells (rows paired [0,1],[2,3],[4,5],[6,7])
//              and wires them into a 2D mesh with the following dataflow:
//
//              Data flow:
//                Activations  : enter left column (col 0), flow EAST
//                Weights      : enter top butterfly row (bp_row 0), flow SOUTH
//                               two register hops per butterfly (w_in→w_q→w_qq→w_out)
//                Enables      : H_PE_EN[i] enters bp[i/2][0].h_en_in_i or h_en_in_i1
//                               V_PE_EN[j] enters bp[0][j].v_en_in
//                               then ripple through pipeline regs diagonally
//
//              Row pairing:
//                bp[k][j] handles rows 2k and 2k+1 at column j
//                  a_in_i / h_en_in_i   ← row 2k  horizontal interface
//                  a_in_i1/ h_en_in_i1  ← row 2k+1 horizontal interface
//                  w_in / v_en_in       ← shared vertical column (from north)
//                  w_out/ v_en_out      ← exits to bp[k+1][j] (to south)
//
//              Bias:
//                BIAS [ACC_WIDTH-1:0] broadcast to all butterfly PEs
//                LD_BIAS[j] one-hot per column — loads bias into both row
//                accumulators of all butterflies in column j simultaneously
//
//              Output:
//                COL_ADDR selects which column's ACC_OUT bus is presented
//                on col_out[ARRAY_SIZE-1:0][ACC_WIDTH-1:0]
//
// Author: Group5
///////////////////////////////////////////////////////////////////////////////

module gemm_systolic_array_butterfly #(
    parameter ARRAY_SIZE      = 8,
    parameter ACT_WIDTH       = 4,
    parameter WGT_WIDTH       = 4,
    parameter ACC_WIDTH       = 16,
    parameter FIFO_DEPTH      = 8,
    parameter FIFO_ADDR_WIDTH = $clog2(FIFO_DEPTH)
) (
    // Global
    input  logic                                        clk,
    input  logic                                        rst_n,

    // Activation inputs (one per row, enters left edge)
    input  logic [ARRAY_SIZE-1:0][ACT_WIDTH-1:0]  i_col,   // I_COL[row]

    // Weight inputs (one per column, enters top edge)
    input  logic [ARRAY_SIZE-1:0][WGT_WIDTH-1:0]  w_row,   // W_ROW[col]

    // PE enable vectors from Control Unit
    input  logic [ARRAY_SIZE-1:0]   h_pe_en,    // horizontal enables → left col
    input  logic [ARRAY_SIZE-1:0]   v_pe_en,    // vertical enables   → top row

    // Bias
    input  logic [ACC_WIDTH-1:0]    bias,       // broadcast to all butterfly PEs
    input  logic [ARRAY_SIZE-1:0]   ld_bias,    // one-hot per column

    // Column select & output
    input  logic [FIFO_ADDR_WIDTH-1:0]              col_addr,   // selects output col
    output logic [ARRAY_SIZE-1:0][ACC_WIDTH-1:0]    col_out     // selected col ACC_OUT
);

    ///////////////////////////////////////////////////////////////////////////
    // Derived parameter
    // BP_ROWS = 4 : number of butterfly row pairs (ARRAY_SIZE / 2)
    ///////////////////////////////////////////////////////////////////////////
    localparam BP_ROWS = ARRAY_SIZE / 2;

    ///////////////////////////////////////////////////////////////////////////
    // Internal mesh wires
    //
    // Horizontal (activation) mesh: one entry per physical row (0..7)
    //   a_mesh[i][j]    : activation into PE row i at column boundary j
    //   h_en_mesh[i][j] : horizontal enable, same indexing
    //   j runs 0..ARRAY_SIZE (left boundary=0, right drain=ARRAY_SIZE)
    //
    // Vertical (weight) mesh: one entry per butterfly row (0..3) + top boundary
    //   w_mesh[k][j]    : weight into butterfly row k at column j
    //   v_en_mesh[k][j] : vertical enable, same indexing
    //   k runs 0..BP_ROWS (top boundary=0, south drain=BP_ROWS)
    //
    // Accumulator mesh: full 8x8 physical grid
    //   acc_mesh[i][j]  : acc_out of physical row i, column j
    ///////////////////////////////////////////////////////////////////////////
    logic [ARRAY_SIZE-1:0][ARRAY_SIZE:0][ACT_WIDTH-1:0]   a_mesh;
    logic [BP_ROWS:0][ARRAY_SIZE-1:0][WGT_WIDTH-1:0]      w_mesh;
    logic [ARRAY_SIZE-1:0][ARRAY_SIZE:0]                   h_en_mesh;
    logic [BP_ROWS:0][ARRAY_SIZE-1:0]                      v_en_mesh;
    logic [ARRAY_SIZE-1:0][ARRAY_SIZE-1:0][ACC_WIDTH-1:0]  acc_mesh;

    ///////////////////////////////////////////////////////////////////////////
    // Boundary connections
    //   Left edge  : each physical row i gets its activation and h_en
    //   Top edge   : each column j gets its weight and v_en at butterfly row 0
    ///////////////////////////////////////////////////////////////////////////
    genvar i, j, k;
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

    ///////////////////////////////////////////////////////////////////////////
    // Bias demux — one value per column, avoid full broadcast fanout
    ///////////////////////////////////////////////////////////////////////////
    logic [ARRAY_SIZE-1:0][ACC_WIDTH-1:0] bias_col;
    generate
        for (j = 0; j < ARRAY_SIZE; j++) begin : bias_demux
            assign bias_col[j] = ld_bias[j] ? bias : '0;
        end
    endgenerate

    ///////////////////////////////////////////////////////////////////////////
    // Butterfly PE grid instantiation — 4 butterfly rows × 8 columns
    //
    // bp[k][j] covers physical rows 2k and 2k+1 at column j
    //
    // Horizontal wiring (per physical row, unchanged from original):
    //   PE row 2k  : a_mesh[2k][j..j+1],   h_en_mesh[2k][j..j+1]
    //   PE row 2k+1: a_mesh[2k+1][j..j+1], h_en_mesh[2k+1][j..j+1]
    //
    // Vertical wiring (per butterfly row, column j):
    //   w_in   ← w_mesh[k][j]      v_en_in  ← v_en_mesh[k][j]
    //   w_out  → w_mesh[k+1][j]    v_en_out → v_en_mesh[k+1][j]
    //   (butterfly internally inserts 2 south registers before w_out)
    //
    // Accumulator outputs:
    //   acc_out_i  → acc_mesh[2k][j]
    //   acc_out_i1 → acc_mesh[2k+1][j]
    ///////////////////////////////////////////////////////////////////////////
    generate
        for (k = 0; k < BP_ROWS; k++) begin : bp_row_gen
            for (j = 0; j < ARRAY_SIZE; j++) begin : bp_col_gen
                gemm_butterfly_pe bp_inst (
                    .clk          (clk),
                    .rst_n        (rst_n),

                    // ── PE_i (physical row 2k) horizontal ─────────────────
                    .a_in_i       (a_mesh    [2*k  ][j  ]),
                    .h_en_in_i    (h_en_mesh [2*k  ][j  ]),
                    .a_out_i      (a_mesh    [2*k  ][j+1]),
                    .h_en_out_i   (h_en_mesh [2*k  ][j+1]),

                    // ── PE_i+1 (physical row 2k+1) horizontal ─────────────
                    .a_in_i1      (a_mesh    [2*k+1][j  ]),
                    .h_en_in_i1   (h_en_mesh [2*k+1][j  ]),
                    .a_out_i1     (a_mesh    [2*k+1][j+1]),
                    .h_en_out_i1  (h_en_mesh [2*k+1][j+1]),

                    // ── Vertical (shared column) ───────────────────────────
                    .w_in         (w_mesh    [k  ][j]),
                    .v_en_in      (v_en_mesh [k  ][j]),
                    .w_out        (w_mesh    [k+1][j]),
                    .v_en_out     (v_en_mesh [k+1][j]),

                    // ── Bias ──────────────────────────────────────────────
                    .bias         (bias_col[j]),
                    .ld_bias      (ld_bias [j]),

                    // ── Accumulator outputs ────────────────────────────────
                    .acc_out_i    (acc_mesh[2*k  ][j]),
                    .acc_out_i1   (acc_mesh[2*k+1][j])
                );
            end
        end
    endgenerate

    ///////////////////////////////////////////////////////////////////////////
    // Column output mux
    // COL_ADDR selects which column's accumulator bus is driven onto col_out
    // col_out[i] = acc_mesh[i][col_addr]  for all rows i
    ///////////////////////////////////////////////////////////////////////////
    generate
        for (i = 0; i < ARRAY_SIZE; i++) begin : col_out_gen
            assign col_out[i] = acc_mesh[i][col_addr];
        end
    endgenerate

endmodule
