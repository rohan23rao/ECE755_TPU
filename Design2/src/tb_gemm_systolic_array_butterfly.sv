///////////////////////////////////////////////////////////////////////////////
// Module: tb_gemm_systolic_array_butterfly.sv
// Description: Self-checking testbench for gemm_systolic_array_butterfly.
//
// Instantiates a 2×2 array (ARRAY_SIZE=2) and drives it directly — no FIFO
// or control unit.  Inputs are sequenced to replicate exactly what the
// FIFO-readout + pe_wave logic would produce during GEMM_COMPUTE.
//
// pe_wave mechanics (same as gemm_control_unit):
//   - Starts at 2'b01 (reset value).
//   - Shifts left every cycle: new[1] = old[0], new[0] = shift_in.
//   - shift_in = (cycle_count < K - 1).
//   - When pe_wave[r]=1: row r FIFO presents its next k-value on i_col[r].
//   - When pe_wave[c]=1: col c FIFO presents its next k-value on w_row[c].
//
// This creates the diagonal wavefront that is the systolic array's core
// behavior under test.
//
// FP4 E2M1 encoding (bias=1) used:
//   4'b0000 = +0.0
//   4'b0010 = +1.0
//   4'b0100 = +2.0
//
// FP4 products used in tests (verified against FloatP4x16):
//   1.0 * 1.0 = 1.0 → FP16 0x3C00
//   2.0 * 1.0 = 2.0 → FP16 0x4000
//   2.0 * 2.0 = 4.0 → FP16 0x4400
//   1.0 * 2.0 = 2.0 → FP16 0x4000
//
// Test matrix:
//   T1  K=1  A=[[1.0],[2.0]]          W=[[1.0,1.0]]       bias=0
//           C=[[1.0,1.0],[2.0,2.0]]
//   T2  K=2  A=[[1.0,2.0],[1.0,1.0]]  W=[[1.0,1.0],[1.0,2.0]]  bias=0
//           C=[[3.0,5.0],[2.0,3.0]]
//   T3  K=1  Same A,W as T1            bias=1.0
//           C=[[2.0,2.0],[3.0,3.0]]
//
// Drain margin: 25 idle cycles after last enable — covers worst-case
// FIFO drain (2*K pops) + 2-stage adder pipeline + arbiter latency.
//
// Author: Group5
///////////////////////////////////////////////////////////////////////////////

`timescale 1ns/1ps

module tb_gemm_systolic_array_butterfly;

    // ─── Parameters ──────────────────────────────────────────────────────────
    localparam ARRAY_SIZE      = 2;
    localparam ACT_WIDTH       = 4;
    localparam WGT_WIDTH       = 4;
    localparam ACC_WIDTH       = 16;
    localparam FIFO_DEPTH      = 8;
    localparam FIFO_ADDR_WIDTH = $clog2(FIFO_DEPTH);  // = 3
    localparam CLK_HALF        = 5;                    // 10 ns period

    // ─── FP4 E2M1 constants ───────────────────────────────────────────────────
    localparam [3:0] FP4_0P0 = 4'b0000;   // +0.0
    localparam [3:0] FP4_1P0 = 4'b0010;   // +1.0
    localparam [3:0] FP4_2P0 = 4'b0100;   // +2.0

    // ─── FP16 expected-output constants ──────────────────────────────────────
    localparam [15:0] FP16_0P0 = 16'h0000;   //  0.0
    localparam [15:0] FP16_1P0 = 16'h3C00;   //  1.0
    localparam [15:0] FP16_2P0 = 16'h4000;   //  2.0
    localparam [15:0] FP16_3P0 = 16'h4200;   //  3.0
    localparam [15:0] FP16_5P0 = 16'h4500;   //  5.0

    // ─── DUT signals ─────────────────────────────────────────────────────────
    logic                                      clk, rst_n;
    logic [ARRAY_SIZE-1:0][ACT_WIDTH-1:0]     i_col;    // [row]
    logic [ARRAY_SIZE-1:0][WGT_WIDTH-1:0]     w_row;    // [col]
    logic [ARRAY_SIZE-1:0]                     h_pe_en;
    logic [ARRAY_SIZE-1:0]                     v_pe_en;
    logic [ACC_WIDTH-1:0]                      bias;
    logic [ARRAY_SIZE-1:0]                     ld_bias;
    logic [FIFO_ADDR_WIDTH-1:0]                col_addr;
    logic [ARRAY_SIZE-1:0][ACC_WIDTH-1:0]      col_out;  // [row]

    // ─── DUT instantiation ───────────────────────────────────────────────────
    gemm_systolic_array_butterfly #(
        .ARRAY_SIZE      (ARRAY_SIZE),
        .ACT_WIDTH       (ACT_WIDTH),
        .WGT_WIDTH       (WGT_WIDTH),
        .ACC_WIDTH       (ACC_WIDTH),
        .FIFO_DEPTH      (FIFO_DEPTH)
    ) dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .i_col    (i_col),
        .w_row    (w_row),
        .h_pe_en  (h_pe_en),
        .v_pe_en  (v_pe_en),
        .bias     (bias),
        .ld_bias  (ld_bias),
        .col_addr (col_addr),
        .col_out  (col_out)
    );

    // ─── Clock ───────────────────────────────────────────────────────────────
    initial clk = 0;
    always #(CLK_HALF) clk = ~clk;

    // ─── Pass/fail counters ──────────────────────────────────────────────────
    int pass_cnt = 0;
    int fail_cnt = 0;

    // ─── Reusable test data arrays (module-level, populated per test) ─────────
    logic [ACT_WIDTH-1:0] ta0 [8];   // activation row 0, indexed by k
    logic [ACT_WIDTH-1:0] ta1 [8];   // activation row 1, indexed by k
    logic [WGT_WIDTH-1:0] tw0 [8];   // weight col 0, indexed by k
    logic [WGT_WIDTH-1:0] tw1 [8];   // weight col 1, indexed by k

    // ─── Tasks ───────────────────────────────────────────────────────────────

    task idle_inputs;
        i_col    = '0;
        w_row    = '0;
        h_pe_en  = '0;
        v_pe_en  = '0;
        bias     = '0;
        ld_bias  = '0;
        col_addr = '0;
    endtask

    task do_reset;
        idle_inputs();
        rst_n = 1'b0;
        repeat(3) @(posedge clk); #1;
        rst_n = 1'b1;
        @(posedge clk); #1;
    endtask

    // Load bias_val into both columns sequentially, one cycle per column.
    // Mirrors FSM LOAD_FIFO bias phase: LD_BIAS one-hot, steps through cols.
    task load_bias_all(input logic [ACC_WIDTH-1:0] bval);
        bias = bval;
        for (int c = 0; c < ARRAY_SIZE; c++) begin
            ld_bias = ARRAY_SIZE'(1 << c);
            @(posedge clk); #1;
        end
        ld_bias = '0;
        bias    = '0;
    endtask

    // Check one accumulator output point.
    // col_addr is set, combinational mux settles (#1), then col_out[row] sampled.
    task check_point(
        input string       label,
        input int          col_idx,
        input int          row_idx,
        input logic [15:0] expected
    );
        logic [15:0] got;
        col_addr = FIFO_ADDR_WIDTH'(col_idx);
        #1;
        got = col_out[row_idx];
        if (got === expected) begin
            $display("  PASS : %s | C[%0d][%0d]  got=0x%04X",
                     label, row_idx, col_idx, got);
            pass_cnt++;
        end else begin
            $display("  FAIL : %s | C[%0d][%0d]  got=0x%04X  exp=0x%04X",
                     label, row_idx, col_idx, got, expected);
            fail_cnt++;
        end
    endtask

    // ─── Systolic compute driver (ARRAY_SIZE=2) ───────────────────────────────
    //
    // Replicates FIFO-output + pe_wave sequencing for one tile.
    //
    // Inputs:
    //   a0/a1 : FP4 activation values for row 0 / row 1, indexed by k (max K-1)
    //   w0/w1 : FP4 weight values for col 0 / col 1, indexed by k
    //   K     : inner-product depth
    //
    // At each cycle:
    //   - h_pe_en = v_pe_en = pe_wave  (A/W masks = 2'b11 for full 2×2 tile)
    //   - For each r: i_col[r] = a_r[rptr_r] if pe_wave[r]=1, else 0
    //   - For each c: w_row[c] = w_c[rptr_c] if pe_wave[c]=1, else 0
    //   - After clock: advance affected read pointers; shift pe_wave left
    //
    // pe_wave shift: {pw[ARRAY_SIZE-2:0], shift_in}
    //   = {pw[0], shift_in} for ARRAY_SIZE=2
    //   shift_in = (cycle_count < K-1)
    //
    task automatic drive_compute_2x2(
        input logic [ACT_WIDTH-1:0] a0 [8],
        input logic [ACT_WIDTH-1:0] a1 [8],
        input logic [WGT_WIDTH-1:0] w0 [8],
        input logic [WGT_WIDTH-1:0] w1 [8],
        input int K
    );
        logic [ARRAY_SIZE-1:0] pw;
        int   ra0, ra1, rw0, rw1;
        int   compute_lim;
        logic shift_in;

        pw          = ARRAY_SIZE'(1);        // 2'b01
        ra0 = 0;  ra1 = 0;
        rw0 = 0;  rw1 = 0;
        compute_lim = 2 + 2 + 2*K - 3;      // A_LEN + W_LEN + (K<<1) - 3

        for (int cnt = 0; cnt <= compute_lim; cnt++) begin
            // Drive enables and FIFO head data
            h_pe_en  = pw;
            v_pe_en  = pw;
            i_col[0] = (pw[0] && ra0 < K) ? a0[ra0] : FP4_0P0;
            i_col[1] = (pw[1] && ra1 < K) ? a1[ra1] : FP4_0P0;
            w_row[0] = (pw[0] && rw0 < K) ? w0[rw0] : FP4_0P0;
            w_row[1] = (pw[1] && rw1 < K) ? w1[rw1] : FP4_0P0;

            @(posedge clk); #1;

            // Advance read pointers for active rows/cols
            if (pw[0]) begin ra0++; rw0++; end
            if (pw[1]) begin ra1++; rw1++; end

            // Shift pe_wave left: {pw[0], shift_in}
            shift_in = (cnt < K - 1) ? 1'b1 : 1'b0;
            pw       = {pw[ARRAY_SIZE-2:0], shift_in};
        end

        idle_inputs();
    endtask

    // ─── Stimulus ────────────────────────────────────────────────────────────
    initial begin
        $display("============================================================");
        $display(" Systolic Array Butterfly TB  (ARRAY_SIZE=%0d)", ARRAY_SIZE);
        $display(" Verifies diagonal wavefront, multi-K accumulation, bias.");
        $display("============================================================");

        // ──────────────────────────────────────────────────────────────────────
        // Test 1: K=1
        //
        //   A (2×1):  [1.0]    W (1×2):  [1.0  1.0]
        //             [2.0]
        //
        //   C = A × W:  C[0][0] = 1.0    C[0][1] = 1.0
        //               C[1][0] = 2.0    C[1][1] = 2.0
        //
        //   Wavefront trace (pw starts 2'b01, shift_in=0 since K=1):
        //     Cycle 0: pw=01  i_col=[1.0, 0]   w_row=[1.0, 0]
        //              PE[0][0] fires directly (no delay)
        //     Cycle 1: pw=10  i_col=[0, 2.0]   w_row=[0, 1.0]
        //              PE[1][0] fires (v_en skewed 1cy south inside butterfly)
        //              PE[0][1] fires (h_en skewed 1cy east through bp[0][0])
        //     Cycle 2: pw=00  all quiet
        //              PE[1][1] fires (both h and v skewed 1cy → arrives here)
        // ──────────────────────────────────────────────────────────────────────
        $display("--- Test 1: K=1, A=[[1],[2]], W=[[1,1]], bias=0 ---");
        do_reset();
        load_bias_all(FP16_0P0);

        for (int i = 0; i < 8; i++) begin
            ta0[i] = FP4_0P0; ta1[i] = FP4_0P0;
            tw0[i] = FP4_0P0; tw1[i] = FP4_0P0;
        end
        ta0[0] = FP4_1P0;   // A[0][k=0] = 1.0
        ta1[0] = FP4_2P0;   // A[1][k=0] = 2.0
        tw0[0] = FP4_1P0;   // W[k=0][col 0] = 1.0
        tw1[0] = FP4_1P0;   // W[k=0][col 1] = 1.0

        drive_compute_2x2(ta0, ta1, tw0, tw1, 1);
        repeat(25) @(posedge clk); #1;

        check_point("T1", 0, 0, FP16_1P0);   // C[0][0] = 1.0
        check_point("T1", 0, 1, FP16_2P0);   // C[1][0] = 2.0
        check_point("T1", 1, 0, FP16_1P0);   // C[0][1] = 1.0
        check_point("T1", 1, 1, FP16_2P0);   // C[1][1] = 2.0

        // ──────────────────────────────────────────────────────────────────────
        // Test 2: K=2
        //
        //   A (2×2):  [1.0  2.0]    W (2×2):  [1.0  1.0]
        //             [1.0  1.0]              [1.0  2.0]
        //
        //   C = A × W:  C[0][0] = 1*1+2*1 = 3.0   C[0][1] = 1*1+2*2 = 5.0
        //               C[1][0] = 1*1+1*1 = 2.0   C[1][1] = 1*1+1*2 = 3.0
        //
        //   Wavefront trace (shift_in=1 on cycle 0 since K=2):
        //     Cycle 0: pw=01  i_col=[1.0, 0]      w_row=[1.0, 0]
        //              PE[0][0] gets a[0][0]=1.0, w[0][0]=1.0  (k=0 push)
        //     Cycle 1: pw=11  i_col=[2.0, 1.0]    w_row=[1.0, 1.0]
        //              PE[0][0] gets a[0][1]=2.0, w[1][0]=1.0  (k=1 push)
        //              PE[1][0] gets a[1][0]=1.0, w[0][0]=1.0  (k=0 push, 1cy skew)
        //              PE[0][1] gets a[0][0]=1.0, w[0][1]=1.0  (k=0 push, 1cy skew)
        //     Cycle 2: pw=10  i_col=[0, 1.0]      w_row=[0, 2.0]
        //              PE[1][0] gets a[1][1]=1.0, w[1][0]=1.0  (k=1 push)
        //              PE[0][1] gets a[0][1]=2.0, w[1][1]=2.0  (k=1 push)
        //     Cycle 3: pw=00
        //              PE[1][1] k=0 push (both h and v arrive 1cy later)
        //     Cycle 4: PE[1][1] k=1 push
        // ──────────────────────────────────────────────────────────────────────
        $display("--- Test 2: K=2, A=[[1,2],[1,1]], W=[[1,1],[1,2]], bias=0 ---");
        do_reset();
        load_bias_all(FP16_0P0);

        for (int i = 0; i < 8; i++) begin
            ta0[i] = FP4_0P0; ta1[i] = FP4_0P0;
            tw0[i] = FP4_0P0; tw1[i] = FP4_0P0;
        end
        ta0[0] = FP4_1P0; ta0[1] = FP4_2P0;   // A[0] = [1.0, 2.0]
        ta1[0] = FP4_1P0; ta1[1] = FP4_1P0;   // A[1] = [1.0, 1.0]
        tw0[0] = FP4_1P0; tw0[1] = FP4_1P0;   // W[k][col 0] = [1.0, 1.0]
        tw1[0] = FP4_1P0; tw1[1] = FP4_2P0;   // W[k][col 1] = [1.0, 2.0]

        drive_compute_2x2(ta0, ta1, tw0, tw1, 2);
        repeat(25) @(posedge clk); #1;

        check_point("T2", 0, 0, FP16_3P0);   // C[0][0] = 3.0
        check_point("T2", 0, 1, FP16_2P0);   // C[1][0] = 2.0
        check_point("T2", 1, 0, FP16_5P0);   // C[0][1] = 5.0
        check_point("T2", 1, 1, FP16_3P0);   // C[1][1] = 3.0

        // ──────────────────────────────────────────────────────────────────────
        // Test 3: K=1, bias=1.0
        //
        //   Same A, W as T1; all four accumulators pre-loaded with 1.0.
        //   Verifies that ld_bias correctly initializes both sub-PE accumulators
        //   in each butterfly PE before compute.
        //
        //   C[0][0] = 1.0 + 1.0*1.0 = 2.0   C[0][1] = 1.0 + 1.0*1.0 = 2.0
        //   C[1][0] = 1.0 + 2.0*1.0 = 3.0   C[1][1] = 1.0 + 2.0*1.0 = 3.0
        // ──────────────────────────────────────────────────────────────────────
        $display("--- Test 3: K=1, bias=1.0, verifies bias load into both sub-PEs ---");
        do_reset();
        load_bias_all(FP16_1P0);

        for (int i = 0; i < 8; i++) begin
            ta0[i] = FP4_0P0; ta1[i] = FP4_0P0;
            tw0[i] = FP4_0P0; tw1[i] = FP4_0P0;
        end
        ta0[0] = FP4_1P0;   // A[0][k=0] = 1.0
        ta1[0] = FP4_2P0;   // A[1][k=0] = 2.0
        tw0[0] = FP4_1P0;   // W[k=0][col 0] = 1.0
        tw1[0] = FP4_1P0;   // W[k=0][col 1] = 1.0

        drive_compute_2x2(ta0, ta1, tw0, tw1, 1);
        repeat(25) @(posedge clk); #1;

        check_point("T3", 0, 0, FP16_2P0);   // C[0][0] = 1.0+1.0 = 2.0
        check_point("T3", 0, 1, FP16_3P0);   // C[1][0] = 1.0+2.0 = 3.0
        check_point("T3", 1, 0, FP16_2P0);   // C[0][1] = 1.0+1.0 = 2.0
        check_point("T3", 1, 1, FP16_3P0);   // C[1][1] = 1.0+2.0 = 3.0

        // ─── Summary ─────────────────────────────────────────────────────────
        $display("============================================================");
        $display(" Results : %0d PASS  /  %0d FAIL  (%0d checks total)",
                 pass_cnt, fail_cnt, pass_cnt + fail_cnt);
        if (fail_cnt == 0) $display(" ALL TESTS PASSED");
        else               $display(" FAILURES DETECTED");
        $display("============================================================");

        $stop;
    end

endmodule
