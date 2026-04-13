///////////////////////////////////////////////////////////////////////////////
// Module: tb_gemm_butterfly_pe.sv
// Description: Self-checking testbench for gemm_butterfly_pe.
//
// FP4 E2M1 encoding (bias=1) used in tests:
//   4'b0010 = +1.0   (exp=1, mant=0 -> 1.0 * 2^(1-1) = 1.0)
//   4'b0100 = +2.0   (exp=2, mant=0 -> 1.0 * 2^(2-1) = 2.0)
//
// FP4 products verified against FloatP4x16 combinational logic:
//   1.0 * 1.0 = 1.0  -> FP16 0x3C00
//   2.0 * 2.0 = 4.0  -> FP16 0x4400
//   1.0 * 2.0 = 2.0  -> FP16 0x4000
//
// Timing model (isolated butterfly PE, no systolic skew):
//   PE_i  : h_en_in_i  asserted cycles [0 .. K-1]
//   PE_i1 : h_en_in_i1 asserted cycles [1 .. K]   (1-cycle wavefront offset)
//   v_en_in             asserted cycles [0 .. K]   (covers both sub-PEs)
//   Both PEs share w_in (same column in systolic array)
//
// Check window:
//   Last acc write completes at most 2K+2 cycles after last push.
//   Testbench waits 2K+4 cycles after loop end before sampling.
//
// Author: Group5
///////////////////////////////////////////////////////////////////////////////

`timescale 1ns/1ps

module tb_gemm_butterfly_pe;

    // ─── Parameters ────────────────────────────────────────────────────────
    localparam ACT_WIDTH  = 4;
    localparam WGT_WIDTH  = 4;
    localparam ACC_WIDTH  = 16;
    localparam FIFO_DEPTH = 4;
    localparam CLK_HALF   = 5; // 10 ns period

    // ─── FP4 input constants ───────────────────────────────────────────────
    localparam [3:0] FP4_0P0 = 4'b0000; // +0.0
    localparam [3:0] FP4_1P0 = 4'b0010; // +1.0
    localparam [3:0] FP4_2P0 = 4'b0100; // +2.0

    // ─── FP16 expected output constants ───────────────────────────────────
    localparam [15:0] FP16_0P0  = 16'h0000; // 0.0
    localparam [15:0] FP16_1P0  = 16'h3C00; // 1.0
    localparam [15:0] FP16_2P0  = 16'h4000; // 2.0
    localparam [15:0] FP16_3P0  = 16'h4200; // 3.0
    localparam [15:0] FP16_4P0  = 16'h4400; // 4.0
    localparam [15:0] FP16_8P0  = 16'h4800; // 8.0

    // ─── DUT signals ───────────────────────────────────────────────────────
    logic                  clk;
    logic                  rst_n;

    logic [ACT_WIDTH-1:0]  a_in_i,     a_in_i1;
    logic                  h_en_in_i,  h_en_in_i1;
    logic [ACT_WIDTH-1:0]  a_out_i,    a_out_i1;    // outputs, not checked in TB
    logic                  h_en_out_i, h_en_out_i1;

    logic [WGT_WIDTH-1:0]  w_in;
    logic                  v_en_in;
    logic [WGT_WIDTH-1:0]  w_out;      // not checked in TB
    logic                  v_en_out;

    logic [ACC_WIDTH-1:0]  bias;
    logic                  ld_bias;

    logic [ACC_WIDTH-1:0]  acc_out_i, acc_out_i1;

    // ─── DUT instantiation ─────────────────────────────────────────────────
    gemm_butterfly_pe #(
        .ACT_WIDTH  (ACT_WIDTH),
        .WGT_WIDTH  (WGT_WIDTH),
        .ACC_WIDTH  (ACC_WIDTH),
        .FIFO_DEPTH (FIFO_DEPTH)
    ) dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .a_in_i      (a_in_i),
        .h_en_in_i   (h_en_in_i),
        .a_out_i     (a_out_i),
        .h_en_out_i  (h_en_out_i),
        .a_in_i1     (a_in_i1),
        .h_en_in_i1  (h_en_in_i1),
        .a_out_i1    (a_out_i1),
        .h_en_out_i1 (h_en_out_i1),
        .w_in        (w_in),
        .v_en_in     (v_en_in),
        .w_out       (w_out),
        .v_en_out    (v_en_out),
        .bias        (bias),
        .ld_bias     (ld_bias),
        .acc_out_i   (acc_out_i),
        .acc_out_i1  (acc_out_i1)
    );

    // ─── Clock ─────────────────────────────────────────────────────────────
    initial clk = 0;
    always #(CLK_HALF) clk = ~clk;

    // ─── Pass/fail counters ────────────────────────────────────────────────
    int pass_cnt = 0;
    int fail_cnt = 0;

    // ─── Tasks ─────────────────────────────────────────────────────────────

    task idle_inputs;
        a_in_i     = '0;
        h_en_in_i  = 1'b0;
        a_in_i1    = '0;
        h_en_in_i1 = 1'b0;
        w_in       = '0;
        v_en_in    = 1'b0;
        bias       = '0;
        ld_bias    = 1'b0;
    endtask

    // Assert reset for 3 cycles, then release
    task do_reset;
        idle_inputs();
        rst_n = 1'b0;
        repeat(3) @(posedge clk);
        #1;
        rst_n = 1'b1;
        @(posedge clk);
        #1;
    endtask

    // Load bias_val into both accumulators for 1 cycle
    // Mutually exclusive with compute (mirrors FSM LOAD_FIFO state)
    task load_bias_val(input logic [ACC_WIDTH-1:0] bias_val);
        bias    = bias_val;
        ld_bias = 1'b1;
        @(posedge clk);
        #1;
        ld_bias = 1'b0;
        bias    = '0;
    endtask

    // Self-check accumulator outputs
    task check(
        input string       label,
        input logic [15:0] got_i,
        input logic [15:0] exp_i,
        input logic [15:0] got_i1,
        input logic [15:0] exp_i1
    );
        if (got_i === exp_i && got_i1 === exp_i1) begin
            $display("  PASS : %s | acc_i=0x%04X  acc_i1=0x%04X",
                     label, got_i, got_i1);
            pass_cnt++;
        end else begin
            $display("  FAIL : %s", label);
            if (got_i !== exp_i)
                $display("         acc_i  got=0x%04X  exp=0x%04X", got_i,  exp_i);
            if (got_i1 !== exp_i1)
                $display("         acc_i1 got=0x%04X  exp=0x%04X", got_i1, exp_i1);
            fail_cnt++;
        end
    endtask

    // Drive one tile compute and verify accumulator results.
    //
    // a_val_i  : constant FP4 activation for PE_i  (repeated K times)
    // a_val_i1 : constant FP4 activation for PE_i1 (repeated K times)
    // w_val    : shared FP4 weight (same column — both PEs see same value)
    // K        : inner-product dimension (1..8)
    //
    // Timing:
    //   Loop runs K+1 posedges.
    //   c=0     : only PE_i  active (v_en_in just asserted)
    //   c=1..K-1: both PEs  active
    //   c=K     : only PE_i1 active (last push for i1)
    //   After loop: idle all inputs, drain 2K+4 cycles, then check.
    task run_tile(
        input logic [ACT_WIDTH-1:0] a_val_i,
        input logic [ACT_WIDTH-1:0] a_val_i1,
        input logic [WGT_WIDTH-1:0] w_val,
        input int                    K,
        input logic [ACC_WIDTH-1:0]  exp_i,
        input logic [ACC_WIDTH-1:0]  exp_i1,
        input string                 label
    );
        for (int c = 0; c <= K; c++) begin
            a_in_i     = (c < K) ? a_val_i  : '0;
            h_en_in_i  = (c < K) ? 1'b1     : 1'b0;
            a_in_i1    = (c > 0) ? a_val_i1 : '0;
            h_en_in_i1 = (c > 0) ? 1'b1     : 1'b0;
            w_in       = w_val;
            v_en_in    = 1'b1;
            @(posedge clk);
            #1;
        end

        idle_inputs();
        repeat(2*K + 4) @(posedge clk);
        #1;

        check(label, acc_out_i, exp_i, acc_out_i1, exp_i1);
    endtask

    // ─── Test stimulus ─────────────────────────────────────────────────────
    initial begin
        $display("============================================================");
        $display(" Butterfly PE Testbench");
        $display("============================================================");

        // ── Test 1: K=1, both PEs 1.0*1.0, bias=0 ─────────────────────────
        // product = 1.0 per PE, acc = 0 + 1.0 = 1.0
        do_reset();
        load_bias_val(FP16_0P0);
        run_tile(FP4_1P0, FP4_1P0, FP4_1P0, 1,
                 FP16_1P0, FP16_1P0,
                 "K=1  | A=1.0 W=1.0 B=0   | exp: i=1.0   i1=1.0  ");

        // ── Test 2: K=2, both PEs 1.0*1.0, bias=0 ─────────────────────────
        // product = 1.0 per cycle, acc = 1.0+1.0 = 2.0
        do_reset();
        load_bias_val(FP16_0P0);
        run_tile(FP4_1P0, FP4_1P0, FP4_1P0, 2,
                 FP16_2P0, FP16_2P0,
                 "K=2  | A=1.0 W=1.0 B=0   | exp: i=2.0   i1=2.0  ");

        // ── Test 3: K=4, both PEs 1.0*1.0, bias=0 ─────────────────────────
        // acc = 4x1.0 = 4.0
        do_reset();
        load_bias_val(FP16_0P0);
        run_tile(FP4_1P0, FP4_1P0, FP4_1P0, 4,
                 FP16_4P0, FP16_4P0,
                 "K=4  | A=1.0 W=1.0 B=0   | exp: i=4.0   i1=4.0  ");

        // ── Test 4: K=8 (max FIFO stress), both PEs 1.0*1.0, bias=0 ───────
        // acc = 8x1.0 = 8.0, FIFO peaks at capacity 4 — no overflow expected
        do_reset();
        load_bias_val(FP16_0P0);
        run_tile(FP4_1P0, FP4_1P0, FP4_1P0, 8,
                 FP16_8P0, FP16_8P0,
                 "K=8  | A=1.0 W=1.0 B=0   | exp: i=8.0   i1=8.0  ");

        // ── Test 5: K=2, PE_i=2.0*2.0=4.0, PE_i1=1.0*2.0=2.0, bias=0 ─────
        // Different activations, shared weight=2.0
        // acc_i = 4.0+4.0 = 8.0,  acc_i1 = 2.0+2.0 = 4.0
        do_reset();
        load_bias_val(FP16_0P0);
        run_tile(FP4_2P0, FP4_1P0, FP4_2P0, 2,
                 FP16_8P0, FP16_4P0,
                 "K=2  | Ai=2.0 Ai1=1.0 W=2.0 B=0 | exp: i=8.0 i1=4.0");

        // ── Test 6: K=2, both PEs 1.0*1.0, bias=1.0 ───────────────────────
        // acc = 1.0 (bias) + 1.0 + 1.0 = 3.0
        do_reset();
        load_bias_val(FP16_1P0);
        run_tile(FP4_1P0, FP4_1P0, FP4_1P0, 2,
                 FP16_3P0, FP16_3P0,
                 "K=2  | A=1.0 W=1.0 B=1.0 | exp: i=3.0   i1=3.0  ");

        // ── Test 7: K=1, PE_i1 only (PE_i all-zero activation) ─────────────
        // pe_en_i fires with A=0.0 -> product=0 -> acc_i stays at bias=0
        // pe_en_i1 fires with A=1.0, W=1.0 -> acc_i1 = 1.0
        do_reset();
        load_bias_val(FP16_0P0);
        run_tile(FP4_0P0, FP4_1P0, FP4_1P0, 1,
                 FP16_0P0, FP16_1P0,
                 "K=1  | Ai=0.0 Ai1=1.0 W=1.0 B=0 | exp: i=0.0 i1=1.0");

        // ─── Summary ────────────────────────────────────────────────────────
        $display("============================================================");
        $display(" Results : %0d PASS  /  %0d FAIL", pass_cnt, fail_cnt);
        if (fail_cnt == 0)
            $display(" ALL TESTS PASSED");
        else
            $display(" FAILURES DETECTED");
        $display("============================================================");

        $stop;
    end

endmodule
