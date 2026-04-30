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
//   Systolic Array   → SA_OUT[col][row] → COL_ADDR mux → col_out[row]
//                   → Vector Unit → Y_OUT[3:0][0:7]
//
// Author: Group5
///////////////////////////////////////////////////////////////////////////////

module gemm_top #(
    parameter ARRAY_SIZE      = 8,
    parameter ACT_WIDTH       = 4,
    parameter WGT_WIDTH       = 4,
    parameter ACC_WIDTH       = 16,
    parameter OUT_WIDTH       = 4,
    parameter FIFO_DEPTH      = 8,
    parameter FIFO_ADDR_WIDTH = $clog2(FIFO_DEPTH),
    parameter DIM_WIDTH       = 4
) (
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
    output logic [ARRAY_SIZE-1:0]       Y_VLD,

    // Tile completion
    output logic                        TILE_DONE,

    // Data Inputs
    input  logic [ARRAY_SIZE-1:0][ACT_WIDTH-1:0]   A_DATA,
    input  logic [ARRAY_SIZE-1:0][WGT_WIDTH-1:0]   W_DATA,
    input  logic [ACC_WIDTH-1:0]        BIAS,
    input  logic [ACC_WIDTH-1:0]        SCALE,

    // Data Output
    output logic [ARRAY_SIZE-1:0][OUT_WIDTH-1:0]   Y_OUT
);


    ///////////////////////////////////////////////////////////////////////////
    // Internal wires — Control Unit outputs
    ///////////////////////////////////////////////////////////////////////////

    logic [ARRAY_SIZE-1:0]          a_in_en;
    logic [ARRAY_SIZE-1:0]          w_in_en;
    logic [FIFO_ADDR_WIDTH-1:0]     wr_addr;
    logic [ARRAY_SIZE-1:0]          a_out_en;
    logic [ARRAY_SIZE-1:0]          w_out_en;
    logic                           FIFO_RD_RST;

    logic [ARRAY_SIZE-1:0]          h_pe_en;
    logic [ARRAY_SIZE-1:0]          v_pe_en;
    logic [ARRAY_SIZE-1:0]          ld_bias;
    logic [FIFO_ADDR_WIDTH-1:0]     col_addr;

    logic [ARRAY_SIZE-1:0]          quant_en;
    logic                           relu_en_out;

    ///////////////////////////////////////////////////////////////////////////
    // Internal wires — datapath
    ///////////////////////////////////////////////////////////////////////////

    logic [ARRAY_SIZE-1:0][ACT_WIDTH-1:0]  i_col;
    logic [ARRAY_SIZE-1:0][WGT_WIDTH-1:0]  w_row;

    // Full SA output mesh: sa_out_full[col][row]
    logic [ARRAY_SIZE-1:0][ARRAY_SIZE-1:0][ACC_WIDTH-1:0] sa_out_full;

    // Column-selected output (mux applied in top, same semantics as before)
    logic [ARRAY_SIZE-1:0][ACC_WIDTH-1:0]  col_out;

    // Pipeline stage
    logic [ARRAY_SIZE-1:0][ACC_WIDTH-1:0]  col_out_pipe;
    logic [ARRAY_SIZE-1:0]                 quant_en_pipe;
    logic                                  relu_en_pipe;
    logic [ACC_WIDTH-1:0]                  scale_pipe;

    ///////////////////////////////////////////////////////////////////////////
    // Control Unit
    ///////////////////////////////////////////////////////////////////////////
    gemm_control_unit u_control_unit (
        .clk            (clk),
        .rst_n          (rst_n),

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

        .METADATA_RDY   (METADATA_RDY),
        .DATA_RDY       (DATA_RDY),
        .BIAS_RDY       (BIAS_RDY),
        .SCALE_RDY      (SCALE_RDY),
        .Y_VLD          (Y_VLD),
        .TILE_DONE      (TILE_DONE),

        .A_IN_EN        (a_in_en),
        .W_IN_EN        (w_in_en),
        .WR_ADDR        (wr_addr),
        .A_OUT_EN       (a_out_en),
        .W_OUT_EN       (w_out_en),
        .FIFO_RD_RST    (FIFO_RD_RST),

        .H_PE_EN        (h_pe_en),
        .V_PE_EN        (v_pe_en),
        .LD_BIAS        (ld_bias),
        .COL_ADDR       (col_addr),

        .QUANT_EN       (quant_en),
        .RELU_EN_out    (relu_en_out)
    );

    ///////////////////////////////////////////////////////////////////////////
    // Activation FIFO Array
    ///////////////////////////////////////////////////////////////////////////
    gemm_fifo_array u_act_fifo (
        .clk        (clk),
        .rst_n      (rst_n),
        .rd_ptr_rst (FIFO_RD_RST),
        .data_in    (A_DATA),
        .write_en   (a_in_en),
        .write_ptr  (wr_addr),
        .read_en    (a_out_en),
        .data_out   (i_col)
    );

    ///////////////////////////////////////////////////////////////////////////
    // Weight FIFO Array
    ///////////////////////////////////////////////////////////////////////////
    gemm_fifo_array u_wgt_fifo (
        .clk        (clk),
        .rst_n      (rst_n),
        .rd_ptr_rst (FIFO_RD_RST),
        .data_in    (W_DATA),
        .write_en   (w_in_en),
        .write_ptr  (wr_addr),
        .read_en    (w_out_en),
        .data_out   (w_row)
    );

    ///////////////////////////////////////////////////////////////////////////
    // Systolic Array (8x8)
    // col_addr mux applied here; SA exposes full acc mesh via sa_out
    ///////////////////////////////////////////////////////////////////////////
    gemm_systolic_array u_systolic_array (
        .clk        (clk),
        .i_col      (i_col),
        .w_row      (w_row),
        .h_pe_en    (h_pe_en),
        .v_pe_en    (v_pe_en),
        .bias       (BIAS),
        .ld_bias    (ld_bias),
        .sa_out     (sa_out_full)
    );

    ///////////////////////////////////////////////////////////////////////////
    // Column output mux (moved from SA)
    // col_out[i] = sa_out_full[col_addr][i]  for all rows i
    ///////////////////////////////////////////////////////////////////////////
    genvar i;
    generate
        for (i = 0; i < ARRAY_SIZE; i++) begin : col_mux
            assign col_out[i] = sa_out_full[col_addr][i];
        end
    endgenerate

    ///////////////////////////////////////////////////////////////////////////
    // Pipeline registers
    ///////////////////////////////////////////////////////////////////////////
    always_ff @(posedge clk) begin
        col_out_pipe   <= col_out;
        quant_en_pipe  <= quant_en;
        relu_en_pipe   <= relu_en_out;
        scale_pipe     <= SCALE;
    end

    ///////////////////////////////////////////////////////////////////////////
    // Vector Unit
    ///////////////////////////////////////////////////////////////////////////
    vector_unit u_vector_unit (
        .clk        (clk),
        .col_out    (col_out_pipe),
        .scale      (scale_pipe),
        .quant_en   (quant_en_pipe),
        .relu_en    (relu_en_pipe),
        .y_out      (Y_OUT)
    );

endmodule