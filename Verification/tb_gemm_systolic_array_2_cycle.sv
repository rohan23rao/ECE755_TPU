///////////////////////////////////////////////////////////////////////////////
// Module: tb_gemm_systolic_array.sv
// Description: Testbench for gemm_systolic_array with fully pipelined 2-stage PE.
//
//  Fully pipelined PE timing (single-stage EAST/SOUTH forwarding):
//    - 1 cycle per hop for data and enables
//    - PE[i][j] pe_en fires at cycle i+j
//    - pe_en_q fires at cycle i+j+1 → accumulator updates
//    - Next K-slice multiply begins at i+j+1 simultaneously → fully pipelined
//
//  pe_wave (normal 1-cycle shift — same as control unit):
//    - Shifts left each cycle
//    - Fills 1 for first K cycles, then 0 for drain
//    - pe_wave[i] high for K consecutive cycles starting at cycle i
//
//  COMPUTE_LIM = A + W + K - 2 + 1 = A + W + K - 1
//    (A+W+K-2 for propagation drain + 1 for multiplier pipeline stage)
//    For 8x8 K=8: 8+8+8-1 = 23 cycles
//
//  Expected accumulator (constant a/w across K cycles):
//    acc[i][j] = bias + K * a[i] * w[j]
//
//  Test 1: Full 8x8, K=8, bias=0
//    a[i]=i+1, w[j]=j+1 → acc[i][j]=(i+1)*(j+1)*8
//    total_cycles = 23
//
//  Test 2: Partial 3x4, K=5, bias=100
//    a[i]=i+2 (i<3), w[j]=j+3 (j<4) → acc[i][j]=100+(i+2)*(j+3)*5
//    total_cycles = 3+4+5-1 = 11
//
// Author: Group5
///////////////////////////////////////////////////////////////////////////////

`timescale 1ns/1ps
import gemm_pkg::*;

module tb_gemm_systolic_array;

    ///////////////////////////////////////////////////////////////////////////
    // DUT signals
    ///////////////////////////////////////////////////////////////////////////
    logic                       clk;
    logic [ACT_WIDTH-1:0]       i_col    [0:ARRAY_SIZE-1];
    logic [WGT_WIDTH-1:0]       w_row    [0:ARRAY_SIZE-1];
    logic [ARRAY_SIZE-1:0]      h_pe_en;
    logic [ARRAY_SIZE-1:0]      v_pe_en;
    logic [ACC_WIDTH-1:0]       bias;
    logic [ARRAY_SIZE-1:0]      ld_bias;
    logic [FIFO_ADDR_WIDTH-1:0] col_addr;
    logic [ACC_WIDTH-1:0]       col_out [0:ARRAY_SIZE-1];

    ///////////////////////////////////////////////////////////////////////////
    // DUT instantiation
    ///////////////////////////////////////////////////////////////////////////
    gemm_systolic_array dut (
        .clk      (clk),
        .i_col    (i_col),
        .w_row    (w_row),
        .h_pe_en  (h_pe_en),
        .v_pe_en  (v_pe_en),
        .bias     (bias),
        .ld_bias  (ld_bias),
        .col_addr (col_addr),
        .col_out  (col_out)
    );

    ///////////////////////////////////////////////////////////////////////////
    // Clock — 10ns period
    ///////////////////////////////////////////////////////////////////////////
    initial clk = 0;
    always #5 clk = ~clk;

    ///////////////////////////////////////////////////////////////////////////
    // Test tracking
    ///////////////////////////////////////////////////////////////////////////
    int pass_count;
    int fail_count;

    ///////////////////////////////////////////////////////////////////////////
    // Reference model
    // acc[i][j] = bias + K * a[i] * w[j]
    // Pipeline only affects timing — final accumulated value unchanged
    ///////////////////////////////////////////////////////////////////////////
    function automatic logic [ACC_WIDTH-1:0] expected_acc(
        input int                   k_dim,
        input logic [ACC_WIDTH-1:0] bias_val,
        input logic [ACT_WIDTH-1:0] a_val,
        input logic [WGT_WIDTH-1:0] w_val
    );
        return bias_val + ACC_WIDTH'(k_dim) *
               (ACC_WIDTH'(a_val) * ACC_WIDTH'(w_val));
    endfunction

    ///////////////////////////////////////////////////////////////////////////
    // Task: drive all inputs idle
    ///////////////////////////////////////////////////////////////////////////
    task drive_idle();
        i_col    = '{default: '0};
        w_row    = '{default: '0};
        h_pe_en  = '0;
        v_pe_en  = '0;
        bias     = '0;
        ld_bias  = '0;
        col_addr = '0;
    endtask

    ///////////////////////////////////////////////////////////////////////////
    // Task: load bias — one-hot column walk, single cycle per column
    ///////////////////////////////////////////////////////////////////////////
    task load_bias_cols(
        input logic [ARRAY_SIZE-1:0] active_cols,
        input logic [ACC_WIDTH-1:0]  bias_val
    );
        bias = bias_val;
        for (int j = 0; j < ARRAY_SIZE; j++) begin
            if (active_cols[j]) begin
                ld_bias = ARRAY_SIZE'(1 << j);
                @(posedge clk); #1;
            end
        end
        ld_bias = '0;
        bias    = '0;
    endtask

    ///////////////////////////////////////////////////////////////////////////
    // Task: run compute
    //
    // Normal 1-cycle shift pe_wave — same as control unit
    // COMPUTE_LIM = A + W + K - 1
    //   (one extra cycle vs 1-stage PE to drain mul pipeline stage)
    //
    // After total_cycles, wait 1 extra cycle for final pe_en_q
    // to flush the last mul_out_q into the accumulator
    ///////////////////////////////////////////////////////////////////////////
    task run_compute(
        input logic [ARRAY_SIZE-1:0] h_mask,
        input logic [ARRAY_SIZE-1:0] v_mask,
        input int                    a_dim,
        input int                    w_dim,
        input int                    k_dim,
        input logic [ACT_WIDTH-1:0]  a_vals [0:ARRAY_SIZE-1],
        input logic [WGT_WIDTH-1:0]  w_vals [0:ARRAY_SIZE-1]
    );
        // COMPUTE_LIM = A + W + K - 1
        automatic int total_cycles = a_dim + w_dim + k_dim - 1;
        automatic logic [ARRAY_SIZE-1:0] pe_wave = '0;

        $display("    Running compute: A=%0d W=%0d K=%0d total_cycles=%0d",
                 a_dim, w_dim, k_dim, total_cycles);

        // Set constant data inputs
        for (int i = 0; i < ARRAY_SIZE; i++) begin
            i_col[i] = a_vals[i];
            w_row[i] = w_vals[i];
        end

        // Drive pe_wave — 1 shift per cycle, same as control unit
        for (int cyc = 0; cyc < total_cycles; cyc++) begin
            pe_wave = (pe_wave << 1) | (cyc < k_dim ? 1'b1 : 1'b0);
            h_pe_en = pe_wave & h_mask;
            v_pe_en = pe_wave & v_mask;
            @(posedge clk); #1;
        end

        // Disable enables
        h_pe_en = '0;
        v_pe_en = '0;
        i_col   = '{default: '0};
        w_row   = '{default: '0};

        // 1 extra cycle — flush final mul_out_q through accumulator
        // pe_en_q from last active cycle still needs to fire
        @(posedge clk); #1;
    endtask

    ///////////////////////////////////////////////////////////////////////////
    // Task: check one output column
    ///////////////////////////////////////////////////////////////////////////
    task check_column(
        input int                    col_idx,
        input int                    a_dim,
        input int                    k_dim,
        input logic [ACC_WIDTH-1:0]  bias_val,
        input logic [ACT_WIDTH-1:0]  a_vals [0:ARRAY_SIZE-1],
        input logic [WGT_WIDTH-1:0]  w_vals [0:ARRAY_SIZE-1],
        input string                 label
    );
        automatic logic [ACC_WIDTH-1:0] exp_val;
        col_addr = FIFO_ADDR_WIDTH'(col_idx);
        #1; // combinational settle

        for (int i = 0; i < a_dim; i++) begin
            exp_val = expected_acc(k_dim, bias_val, a_vals[i], w_vals[col_idx]);
            if (col_out[i] === exp_val) begin
                $display("    PASS [%s] col=%0d row=%0d: got %0d (0x%04h)",
                         label, col_idx, i, col_out[i], col_out[i]);
                pass_count++;
            end else begin
                $display("    FAIL [%s] col=%0d row=%0d: expected %0d (0x%04h) got %0d (0x%04h)",
                         label, col_idx, i,
                         exp_val, exp_val, col_out[i], col_out[i]);
                fail_count++;
            end
        end
    endtask

    ///////////////////////////////////////////////////////////////////////////
    // Main test sequence
    ///////////////////////////////////////////////////////////////////////////
    initial begin
        pass_count = 0;
        fail_count = 0;

        $display("=================================================================");
        $display(" GEMM Systolic Array Testbench (fully pipelined 2-stage PE)");
        $display("=================================================================");

        drive_idle();
        repeat(4) @(posedge clk); #1;

        ///////////////////////////////////////////////////////////////////
        // TEST 1 — Full 8x8, K=8, bias=0
        //
        // a[i] = i+1  (1..8), w[j] = j+1  (1..8)
        // Expected: acc[i][j] = (i+1)*(j+1)*8
        //   PE[0][0] = 1*1*8 = 8
        //   PE[3][4] = 4*5*8 = 160
        //   PE[7][7] = 8*8*8 = 512
        //
        // total_cycles = 8+8+8-1 = 23
        ///////////////////////////////////////////////////////////////////
        $display("\n[ TEST 1 ] Full 8x8, K=8, bias=0");
        $display("  total_cycles=23, expected acc[i][j]=(i+1)*(j+1)*8");
        $display("-----------------------------------------------------------------");

        begin
            automatic int A = 8, W = 8, K = 8;
            automatic logic [ARRAY_SIZE-1:0] h_mask   = 8'hFF;
            automatic logic [ARRAY_SIZE-1:0] v_mask   = 8'hFF;
            automatic logic [ACT_WIDTH-1:0]  a_vals [0:ARRAY_SIZE-1];
            automatic logic [WGT_WIDTH-1:0]  w_vals [0:ARRAY_SIZE-1];
            automatic logic [ACC_WIDTH-1:0]  bias_val = 16'd0;

            for (int i = 0; i < ARRAY_SIZE; i++) begin
                a_vals[i] = ACT_WIDTH'(i + 1);
                w_vals[i] = WGT_WIDTH'(i + 1);
            end

            $display("  Phase 1: Loading bias=0 into all 8 columns...");
            load_bias_cols(h_mask, bias_val);

            $display("  Phase 2: Running compute (23 cycles)...");
            run_compute(h_mask, v_mask, A, W, K, a_vals, w_vals);

            $display("  Phase 3: Checking all 8 columns...");
            for (int j = 0; j < W; j++)
                check_column(j, A, K, bias_val, a_vals, w_vals, "T1-8x8");
        end

        drive_idle();
        repeat(4) @(posedge clk); #1;

        ///////////////////////////////////////////////////////////////////
        // TEST 2 — Partial 3x4, K=5, bias=100
        //
        // h_mask=00000111 (rows 0-2), v_mask=00001111 (cols 0-3)
        // a[i]=i+2 for i<3: (2,3,4), w[j]=j+3 for j<4: (3,4,5,6)
        // Expected: acc[i][j] = 100 + (i+2)*(j+3)*5
        //   PE[0][0] = 100+2*3*5 = 130
        //   PE[1][2] = 100+3*5*5 = 175
        //   PE[2][3] = 100+4*6*5 = 220
        //
        // total_cycles = 3+4+5-1 = 11
        ///////////////////////////////////////////////////////////////////
        $display("\n[ TEST 2 ] Partial 3x4, K=5, bias=100");
        $display("  total_cycles=11, expected acc[i][j]=100+(i+2)*(j+3)*5");
        $display("-----------------------------------------------------------------");

        begin
            automatic int A = 3, W = 4, K = 5;
            automatic logic [ARRAY_SIZE-1:0] h_mask   = 8'b00000111;
            automatic logic [ARRAY_SIZE-1:0] v_mask   = 8'b00001111;
            automatic logic [ACT_WIDTH-1:0]  a_vals [0:ARRAY_SIZE-1];
            automatic logic [WGT_WIDTH-1:0]  w_vals [0:ARRAY_SIZE-1];
            automatic logic [ACC_WIDTH-1:0]  bias_val = 16'd100;

            for (int i = 0; i < ARRAY_SIZE; i++)
                a_vals[i] = (i < A) ? ACT_WIDTH'(i + 2) : '0;
            for (int j = 0; j < ARRAY_SIZE; j++)
                w_vals[j] = (j < W) ? WGT_WIDTH'(j + 3) : '0;

            $display("  Phase 1: Loading bias=100 into columns 0-3...");
            load_bias_cols(v_mask, bias_val);

            $display("  Phase 2: Running compute (11 cycles)...");
            run_compute(h_mask, v_mask, A, W, K, a_vals, w_vals);

            $display("  Phase 3: Checking active columns 0-3...");
            for (int j = 0; j < W; j++)
                check_column(j, A, K, bias_val, a_vals, w_vals, "T2-3x4");
        end

        ///////////////////////////////////////////////////////////////////
        // Summary
        ///////////////////////////////////////////////////////////////////
        $display("\n=================================================================");
        $display(" Results: %0d PASSED, %0d FAILED", pass_count, fail_count);
        $display("=================================================================");
        if (fail_count == 0) $display(" ALL TESTS PASSED");
        else                 $display(" FAILURES DETECTED — check waveforms");

        $stop;
    end

    ///////////////////////////////////////////////////////////////////////////
    // Timeout watchdog
    ///////////////////////////////////////////////////////////////////////////
    initial begin
        #500000;
        $display("TIMEOUT — simulation exceeded limit");
        $stop;
    end
endmodule