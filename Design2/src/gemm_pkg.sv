///////////////////////////////////////////////////////////////////////////////
// Package: gemm_pkg.sv
// Description: Shared parameters for the GEMM Core design. Defines all
//              bitwidths, addresses, and depths used across modules.
// Author: Group5
///////////////////////////////////////////////////////////////////////////////

package gemm_pkg;

    // ── Systolic Array Dimensions ─────────────────────────────────────────
    localparam int ARRAY_SIZE       = 8;    // 8x8 systolic array

    // ── Data Bitwidths ────────────────────────────────────────────────────
    localparam int ACT_WIDTH        = 8;    // activation input bitwidth
    localparam int WGT_WIDTH        = 8;    // weight input bitwidth
    localparam int ACC_WIDTH        = 16;   // accumulator / MAC output bitwidth
    localparam int OUT_WIDTH        = 4;    // quantized output bitwidth

    // ── FIFO Parameters ───────────────────────────────────────────────────
    localparam int FIFO_DEPTH       = 8;    // entries per FIFO (one per k-slice)
    localparam int FIFO_ADDR_WIDTH  = $clog2(FIFO_DEPTH);  // 3-bit address

    // ── Dimension Encoding ────────────────────────────────────────────────
    localparam int DIM_WIDTH        = 4;    // 4-bit dimension inputs {1-8}

    // ── Control Counter Widths ────────────────────────────────────────────
    localparam int MAIN_CNT_WIDTH   = 5;    // main_cnt: covers A+W+K-3 max=21
    localparam int BIAS_CNT_WIDTH   = 4;    // bias_cnt: covers W_DIM max=8
endpackage
