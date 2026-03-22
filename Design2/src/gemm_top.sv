///////////////////////////////////////////////////////////////////////////////
// Module: gemm_top.sv
// Description: Top-level GEMM Core wrapper. Integrates:
//                - gemm_control_unit : FSM + datapath control
//                - gemm_fifo_array   : Activation FIFO bank (8x FIFO)
//                - gemm_fifo_array   : Weight FIFO bank     (8x FIFO)
//                - gemm_systolic_array : 8x8 PE mesh
//                - gemm_vector_unit  : Quantization + ReLU (stub interface)
//
// Data flow:
//   A_DATA[3:0][0:7] → Activation FIFOs → I_COL[0:7] → Systolic Array
//   W_DATA[3:0][0:7] → Weight FIFOs     → W_ROW[0:7] → Systolic Array
//   Systolic Array   → COL_OUT[15:0][0:7] → Vector Unit → Y_OUT[3:0][0:7]
//
// Control flow:
//   External handshakes → Control Unit → FIFO/Array/VU enables
//
// Interface follows GEMM_TOP block diagram. Vector Unit interface stubbed
// with correct port names for teammate integration.
//
// Author: Group5
///////////////////////////////////////////////////////////////////////////////

import gemm_pkg::*;

module gemm_top (
    // Global
    input  logic                        clk,
    input  logic                        rst_n,

    // External Control Interface
    input  logic                        TILE_START,
    input  logic                        TILE_LAST,
    input  logic                        BIAS_NEW,
    input  logic                        RELU_EN,
    input  logic [DIM_WIDTH-1:0]        A_LEN,
    input  logic [DIM_WIDTH-1:0]        W_LEN,
    input  logic [DIM_WIDTH-1:0]        K_LEN,

    // Metadata handshake
    input  logic                        METADATA_VLD,
    output logic                        METADATA_RDY,

    // Data handshake (activation + weight FIFO loading)
    input  logic                        DATA_VLD,
    output logic                        DATA_RDY,

    // Bias handshake
    input  logic                        BIAS_VLD,
    output logic                        BIAS_RDY,

    // Scale handshake (vector unit)
    input  logic                        SCALE_VLD,
    output logic                        SCALE_RDY,

    // Output handshake
    input  logic                        Y_RDY,
    output logic                        Y_VLD,

    // Tile completion
    output logic                        TILE_DONE,

    // Data Inputs
    // Activation data — one 4-bit value per FIFO row, 8 rows
    input  logic [ACT_WIDTH-1:0]        A_DATA [0:ARRAY_SIZE-1],

    // Weight data — one 4-bit value per FIFO col, 8 cols
    input  logic [WGT_WIDTH-1:0]        W_DATA [0:ARRAY_SIZE-1],

    // Bias — FP16 broadcast value loaded into systolic array accumulators
    input  logic [ACC_WIDTH-1:0]        BIAS,

    // Scale — FP16 per-channel scale for vector unit quantization
    input  logic [ACC_WIDTH-1:0]        SCALE,

    // Data Output
    // Quantized output — one OUT_WIDTH value per row, 8 rows
    output logic [OUT_WIDTH-1:0]        Y_OUT [0:ARRAY_SIZE-1]
);

    ///////////////////////////////////////////////////////////////////////////
    // Internal wires — Control Unit outputs
    ///////////////////////////////////////////////////////////////////////////

    // FIFO control
    logic [ARRAY_SIZE-1:0]          a_in_en;
    logic [ARRAY_SIZE-1:0]          w_in_en;
    logic [FIFO_ADDR_WIDTH-1:0]     wr_addr;
    logic [ARRAY_SIZE-1:0]          a_out_en;
    logic [ARRAY_SIZE-1:0]          w_out_en;

    // Systolic array control
    logic [ARRAY_SIZE-1:0]          h_pe_en;
    logic [ARRAY_SIZE-1:0]          v_pe_en;
    logic [ARRAY_SIZE-1:0]          ld_bias;
    logic [FIFO_ADDR_WIDTH-1:0]     col_addr;

    // Vector unit control
    logic [ARRAY_SIZE-1:0]          quant_en;
    logic                           relu_en_out;

    ///////////////////////////////////////////////////////////////////////////
    // Internal wires — datapath
    ///////////////////////////////////////////////////////////////////////////

    // Activation FIFO → Systolic Array
    logic [ACT_WIDTH-1:0]           i_col [0:ARRAY_SIZE-1];

    // Weight FIFO → Systolic Array
    logic [WGT_WIDTH-1:0]           w_row [0:ARRAY_SIZE-1];

    // Systolic Array → Vector Unit
    logic [ACC_WIDTH-1:0]           col_out [0:ARRAY_SIZE-1];

    ///////////////////////////////////////////////////////////////////////////
    // Control Unit
    ///////////////////////////////////////////////////////////////////////////
    gemm_control_unit u_control_unit (
        .clk            (clk),
        .rst_n          (rst_n),

        // External control inputs
        .TILE_START     (TILE_START),
        .METADATA_VLD   (METADATA_VLD),
        .A_LEN          (A_LEN),
        .W_LEN          (W_LEN),
        .K_LEN          (K_LEN),
        .BIAS_NEW       (BIAS_NEW),
        .TILE_LAST      (TILE_LAST),
        .RELU_EN        (RELU_EN),
        .DATA_VLD       (DATA_VLD),
        .BIAS_VLD       (BIAS_VLD),
        .Y_RDY          (Y_RDY),
        .SCALE_VLD      (SCALE_VLD),

        // External control outputs
        .METADATA_RDY   (METADATA_RDY),
        .DATA_RDY       (DATA_RDY),
        .BIAS_RDY       (BIAS_RDY),
        .SCALE_RDY      (SCALE_RDY),
        .Y_VLD          (Y_VLD),
        .TILE_DONE      (TILE_DONE),

        // FIFO control
        .A_IN_EN        (a_in_en),
        .W_IN_EN        (w_in_en),
        .WR_ADDR        (wr_addr),
        .A_OUT_EN       (a_out_en),
        .W_OUT_EN       (w_out_en),

        // Systolic array control
        .H_PE_EN        (h_pe_en),
        .V_PE_EN        (v_pe_en),
        .LD_BIAS        (ld_bias),
        .COL_ADDR       (col_addr),

        // Vector unit control
        .QUANT_EN       (quant_en),
        .RELU_EN_out    (relu_en_out)
    );

    ///////////////////////////////////////////////////////////////////////////
    // Activation FIFO Array
    // 8x FIFOs, one per systolic array row
    // Write: A_DATA[i] written when A_IN_EN[i] asserted, at slot WR_ADDR
    // Read:  data_out[i] driven to systolic array row i when A_OUT_EN[i]
    ///////////////////////////////////////////////////////////////////////////
    gemm_fifo_array u_act_fifo (
        .clk        (clk),
        .rst_n      (rst_n),
        .data_in    (A_DATA),
        .write_en   (a_in_en),
        .write_ptr  (wr_addr),
        .read_en    (a_out_en),
        .data_out   (i_col)
    );

    ///////////////////////////////////////////////////////////////////////////
    // Weight FIFO Array
    // 8x FIFOs, one per systolic array column
    // Write: W_DATA[j] written when W_IN_EN[j] asserted, at slot WR_ADDR
    // Read:  data_out[j] driven to systolic array col j when W_OUT_EN[j]
    // Note:  WGT_WIDTH == ACT_WIDTH from gemm_pkg so same array type used
    ///////////////////////////////////////////////////////////////////////////
    gemm_fifo_array u_wgt_fifo (
        .clk        (clk),
        .rst_n      (rst_n),
        .data_in    (W_DATA),
        .write_en   (w_in_en),
        .write_ptr  (wr_addr),
        .read_en    (w_out_en),
        .data_out   (w_row)
    );

    ///////////////////////////////////////////////////////////////////////////
    // Systolic Array (8x8)
    // Receives I_COL from activation FIFOs, W_ROW from weight FIFOs
    // PE enables ripple diagonally creating correct MAC timing
    // COL_ADDR selects which column's accumulator output is presented
    ///////////////////////////////////////////////////////////////////////////
    gemm_systolic_array u_systolic_array (
        .clk        (clk),
        .i_col      (i_col),
        .w_row      (w_row),
        .h_pe_en    (h_pe_en),
        .v_pe_en    (v_pe_en),
        .bias       (BIAS),
        .ld_bias    (ld_bias),
        .col_addr   (col_addr),
        .col_out    (col_out)
    );

    ///////////////////////////////////////////////////////////////////////////
    // Vector Unit (1x8) — stub interface for teammate integration
    // Receives one column of FP16 MAC results from systolic array
    // Applies scale quantization and optional ReLU
    // Outputs OUT_WIDTH quantized values, one per active row
    //
    // TODO: replace with teammate's gemm_vector_unit instantiation
    //       Expected port interface based on GEMM_TOP diagram:
    //         .clk        (clk)
    //         .rst_n      (rst_n)
    //         .col_out    (col_out)     // [ACC_WIDTH-1:0][0:ARRAY_SIZE-1]
    //         .scale      (SCALE)       // [ACC_WIDTH-1:0]
    //         .quant_en   (quant_en)    // [ARRAY_SIZE-1:0] — FSM gates this
    //         .relu_en    (relu_en_out) // 1-bit
    //         .y_out      (Y_OUT)       // [OUT_WIDTH-1:0][0:ARRAY_SIZE-1]
    //
    // Handshake signals (SCALE_VLD, SCALE_RDY, Y_RDY, Y_VLD) are handled
    // entirely by the FSM — the vector unit receives only data and enables.
    ///////////////////////////////////////////////////////////////////////////
    gemm_vector_unit u_vector_unit (
        .clk        (clk),
        .rst_n      (rst_n),
        .col_out    (col_out),
        .scale      (SCALE),
        .quant_en   (quant_en),
        .relu_en    (relu_en_out),
        .y_out      (Y_OUT)
    );
endmodule