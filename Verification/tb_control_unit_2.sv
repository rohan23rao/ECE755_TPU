///////////////////////////////////////////////////////////////////////////////
// Module: tb_gemm_control_unit.sv
// Description: Self-checking TB for gemm_control_unit.
//              Updated for Mealy LOAD_FIFO transition (no 1-cycle bubble).
//
// Timing model:
//   LOAD_FIFO (Mealy):
//     Transition fires ON the last handshake clock.
//     data_done_r / bias_done_r are sticky: set on last handshake clock edge,
//     persist until the next capture_metadata pulse.
//     After fork join both threads have consumed max(K,W) clocks — no extra
//     exit clock — and state is already GEMM_COMPUTE.
//
//   do_data_load / do_bias_load:
//     Loop for N handshakes. Last iteration: check RDY=1 and ADDR/LD_BIAS
//     BEFORE clock; clock fires (sets done_r); check RDY=0 after clock.
//     No extra cycle. Optional stall inserted BEFORE handshake stall_at.
//
//   do_gemm_compute:
//     pe_wave = 8'b00000001 on entry (set by reset or previous clr_pe_wave).
//     NO entry clock — pe_wave valid immediately.
//     Checks H/V_PE_EN and A/W_OUT_EN every cycle BEFORE clock.
//     On last cycle: optionally checks TILE_DONE and pre-asserts Y_RDY/SCALE_VLD.
//
//   do_gemm_flush:
//     Y_RDY and SCALE_VLD pre-asserted by do_gemm_compute(pre_flush=1).
//     NO entry clock — COL_ADDR=0 valid immediately.
//     Loop checks SCALE_RDY, COL_ADDR, QUANT_EN, RELU_EN_out before each clock.
//
// Tests:
//   T1  K > W  — data bottleneck; bias finishes early (sticky bias_done_r)
//   T2  K < W  — bias bottleneck; data finishes early (sticky data_done_r)
//   T3  K == W — simultaneous completion on same cycle
//   T4  BIAS_NEW=0 — data-only path, bias channel fully gated
//   T5  Data stall, no bias
//   T6  Data stall + concurrent bias (K > W, data stalls mid-load)
//   T7  Bias stall + concurrent data (W > K, bias stalls mid-load)
//   T8  Y_RDY stall during GEMM_FLUSH
//   T9  Multi-tile: 2x2x2 (no flush) → 8x8x8 (flush)
//
// Author: Group5
///////////////////////////////////////////////////////////////////////////////

import gemm_pkg::*;

module tb_gemm_control_unit;

    ///////////////////////////////////////////////////////////////////////////
    // DUT Signals
    ///////////////////////////////////////////////////////////////////////////
    logic                           clk, rst_n;
    logic                           TILE_START, METADATA_VLD;
    logic [DIM_WIDTH-1:0]           A_LEN, W_LEN, K_LEN;
    logic                           BIAS_NEW, TILE_LAST, RELU_EN;
    logic                           DATA_VLD, BIAS_VLD, Y_RDY, SCALE_VLD;

    logic                           METADATA_RDY, DATA_RDY, BIAS_RDY;
    logic                           SCALE_RDY, TILE_DONE;
    logic [ARRAY_SIZE-1:0]          Y_VLD;           // 8-bit vector (A_MASK gated)
    logic [ARRAY_SIZE-1:0]          A_IN_EN,  W_IN_EN;
    logic [FIFO_ADDR_WIDTH-1:0]     WR_ADDR;
    logic [ARRAY_SIZE-1:0]          A_OUT_EN, W_OUT_EN;
    logic [ARRAY_SIZE-1:0]          H_PE_EN,  V_PE_EN;
    logic [ARRAY_SIZE-1:0]          LD_BIAS;
    logic [FIFO_ADDR_WIDTH-1:0]     COL_ADDR;
    logic [ARRAY_SIZE-1:0]          QUANT_EN;
    logic                           RELU_EN_out;
    logic                           FIFO_RD_RST;

    ///////////////////////////////////////////////////////////////////////////
    // DUT Instantiation
    ///////////////////////////////////////////////////////////////////////////
    gemm_control_unit dut (
        .clk          (clk),          .rst_n        (rst_n),
        .TILE_START   (TILE_START),   .METADATA_VLD (METADATA_VLD),
        .A_LEN        (A_LEN),        .W_LEN        (W_LEN),
        .K_LEN        (K_LEN),        .BIAS_NEW     (BIAS_NEW),
        .TILE_LAST    (TILE_LAST),    .RELU_EN      (RELU_EN),
        .DATA_VLD     (DATA_VLD),     .BIAS_VLD     (BIAS_VLD),
        .Y_RDY        (Y_RDY),        .SCALE_VLD    (SCALE_VLD),
        .METADATA_RDY (METADATA_RDY),
        .DATA_RDY     (DATA_RDY),     .BIAS_RDY     (BIAS_RDY),
        .SCALE_RDY    (SCALE_RDY),    .Y_VLD        (Y_VLD),
        .TILE_DONE    (TILE_DONE),
        .A_IN_EN      (A_IN_EN),      .W_IN_EN      (W_IN_EN),
        .WR_ADDR      (WR_ADDR),
        .A_OUT_EN     (A_OUT_EN),     .W_OUT_EN     (W_OUT_EN),
        .H_PE_EN      (H_PE_EN),      .V_PE_EN      (V_PE_EN),
        .LD_BIAS      (LD_BIAS),      .COL_ADDR     (COL_ADDR),
        .QUANT_EN     (QUANT_EN),     .RELU_EN_out  (RELU_EN_out),
        .FIFO_RD_RST  (FIFO_RD_RST)
    );

    ///////////////////////////////////////////////////////////////////////////
    // Clock
    ///////////////////////////////////////////////////////////////////////////
    initial clk = 0;
    always #5 clk = ~clk;

    ///////////////////////////////////////////////////////////////////////////
    // Test Tracking
    ///////////////////////////////////////////////////////////////////////////
    int    pass_count, fail_count;
    string current_test;

    task check(input logic got, input logic exp, input string msg);
        if (got === exp) begin
            $display("    PASS [%s] %s", current_test, msg);
            pass_count++;
        end else begin
            $display("    FAIL [%s] %s: expected %0b got %0b",
                     current_test, msg, exp, got);
            fail_count++;
        end
    endtask

    task check_vec(input logic [ARRAY_SIZE-1:0] got,
                   input logic [ARRAY_SIZE-1:0] exp,
                   input string msg);
        if (got === exp) begin
            $display("    PASS [%s] %s", current_test, msg);
            pass_count++;
        end else begin
            $display("    FAIL [%s] %s: exp 8'b%08b got 8'b%08b",
                     current_test, msg, exp, got);
            fail_count++;
        end
    endtask

    task check_addr(input logic [FIFO_ADDR_WIDTH-1:0] got,
                    input logic [FIFO_ADDR_WIDTH-1:0] exp,
                    input string msg);
        if (got === exp) begin
            $display("    PASS [%s] %s", current_test, msg);
            pass_count++;
        end else begin
            $display("    FAIL [%s] %s: expected %0d got %0d",
                     current_test, msg, exp, got);
            fail_count++;
        end
    endtask

    ///////////////////////////////////////////////////////////////////////////
    // Utility Tasks
    ///////////////////////////////////////////////////////////////////////////
    task drive_idle();
        TILE_START = 0;  METADATA_VLD = 0;
        A_LEN = 0;  W_LEN = 0;  K_LEN = 0;
        BIAS_NEW = 0;  TILE_LAST = 0;  RELU_EN = 0;
        DATA_VLD = 0;  BIAS_VLD = 0;  Y_RDY = 0;  SCALE_VLD = 0;
    endtask

    task do_reset();
        rst_n = 0;
        drive_idle();
        repeat(3) @(posedge clk); #1;
        rst_n = 1;
        @(posedge clk); #1;
    endtask

    task start_tile(
        input logic [DIM_WIDTH-1:0] a, w, k,
        input logic bias_new, tile_last, relu_en
    );
        A_LEN = a;  W_LEN = w;  K_LEN = k;
        BIAS_NEW = bias_new;  TILE_LAST = tile_last;  RELU_EN = relu_en;
        TILE_START = 1;  METADATA_VLD = 1;
        @(posedge clk); #1;
        TILE_START = 0;  METADATA_VLD = 0;
    endtask

    ///////////////////////////////////////////////////////////////////////////
    // Task: do_data_load
    //
    // Drives k_dim DATA handshakes. Mealy convention: no extra exit clock.
    //   - Checks DATA_RDY=1 and WR_ADDR=k before each clock.
    //   - Last handshake clock sets data_done_r → DATA_RDY=0 after clock.
    //   - Optional stall: DATA_VLD deasserted for stall_len cycles BEFORE
    //     handshake stall_at, verifying DATA_RDY stays 1 throughout.
    //
    // Fork-safe: shares clock events with concurrent do_bias_load.
    // After return: DATA_RDY=0, state is LOAD_FIFO or GEMM_COMPUTE
    //               depending on whether bias also completed.
    ///////////////////////////////////////////////////////////////////////////
    task do_data_load(
        input int k_dim,
        input int stall_at  = -1,
        input int stall_len = 0
    );
        DATA_VLD = 1;
        for (int k = 0; k < k_dim; k++) begin
            // Insert stall before handshake stall_at
            if (stall_at >= 0 && k == stall_at) begin
                DATA_VLD = 0;
                repeat(stall_len) begin
                    check(DATA_RDY, 1'b1,
                        $sformatf("DATA_RDY=1 during stall (before k=%0d)", k));
                    @(posedge clk); #1;
                end
                DATA_VLD = 1;
            end
            check(DATA_RDY, 1'b1, $sformatf("DATA_RDY=1 at k=%0d", k));
            check_addr(WR_ADDR, FIFO_ADDR_WIDTH'(k),
                $sformatf("WR_ADDR=%0d at k=%0d", k, k));
            @(posedge clk); #1;
            // Last iteration: clock set data_done_r; DATA_RDY now 0
        end
        DATA_VLD = 0;
        check(DATA_RDY, 1'b0, "DATA_RDY=0 after K handshakes (data_done_r set)");
    endtask

    ///////////////////////////////////////////////////////////////////////////
    // Task: do_bias_load
    //
    // Drives w_dim BIAS handshakes. Same Mealy convention as do_data_load.
    //   - Checks BIAS_RDY=1 and LD_BIAS one-hot before each clock.
    //   - Last handshake clock sets bias_done_r → BIAS_RDY=0 after clock.
    //   - Optional stall: same stall_at/stall_len mechanism as do_data_load.
    //
    // Fork-safe: shares clock events with concurrent do_data_load.
    ///////////////////////////////////////////////////////////////////////////
    task do_bias_load(
        input int w_dim,
        input int stall_at  = -1,
        input int stall_len = 0
    );
        BIAS_VLD = 1; #1;
        for (int w = 0; w < w_dim; w++) begin
            if (stall_at >= 0 && w == stall_at) begin
                BIAS_VLD = 0;
                repeat(stall_len) begin
                    check(BIAS_RDY, 1'b1,
                        $sformatf("BIAS_RDY=1 during stall (before w=%0d)", w));
                    @(posedge clk); #1;
                end
                BIAS_VLD = 1; #1;
            end
            check(BIAS_RDY, 1'b1, $sformatf("BIAS_RDY=1 at w=%0d", w));
            check_vec(LD_BIAS, ARRAY_SIZE'(1 << w),
                $sformatf("LD_BIAS one-hot [%0d] at w=%0d", w, w));
            @(posedge clk); #1;
        end
        BIAS_VLD = 0;
        check(BIAS_RDY, 1'b0, "BIAS_RDY=0 after W handshakes (bias_done_r set)");
    endtask

    ///////////////////////////////////////////////////////////////////////////
    // Task: do_gemm_compute
    //
    // pe_wave = 8'b00000001 on entry — valid immediately, no entry clock.
    // Samples H/V_PE_EN and A/W_OUT_EN before each clock.
    // Expected wave: (exp_wave << 1) | (cyc < k_dim ? 1 : 0), starting from 0.
    // On last cycle: optionally checks TILE_DONE and pre-asserts Y_RDY/SCALE_VLD
    // so QUANT_EN is valid on col 0 of GEMM_FLUSH without an extra entry clock.
    ///////////////////////////////////////////////////////////////////////////
    task do_gemm_compute(
        input int                    a_dim, w_dim, k_dim,
        input logic [ARRAY_SIZE-1:0] a_mask, w_mask,
        input logic                  check_tile_done = 1'b0,
        input logic                  pre_flush       = 1'b0
    );
        automatic int total = a_dim + w_dim + k_dim - 1;
        automatic logic [ARRAY_SIZE-1:0] exp_wave = '0;
        automatic logic [ARRAY_SIZE-1:0] exp_h, exp_v;

        $display("    Compute: A=%0d W=%0d K=%0d → %0d cycles", a_dim, w_dim, k_dim, total);

        for (int cyc = 0; cyc < total; cyc++) begin
            exp_wave = (exp_wave << 1) | (cyc < k_dim ? 1'b1 : 1'b0);
            exp_h    = exp_wave & a_mask;
            exp_v    = exp_wave & w_mask;

            check_vec(H_PE_EN,  exp_h, $sformatf("H_PE_EN  cyc %0d", cyc));
            check_vec(V_PE_EN,  exp_v, $sformatf("V_PE_EN  cyc %0d", cyc));
            check_vec(A_OUT_EN, exp_h, $sformatf("A_OUT_EN cyc %0d", cyc));
            check_vec(W_OUT_EN, exp_v, $sformatf("W_OUT_EN cyc %0d", cyc));

            if (cyc == total - 1) begin
                if (check_tile_done)
                    check(TILE_DONE, 1'b1, "TILE_DONE=1 on compute_done cycle");
                if (pre_flush) begin
                    Y_RDY     = 1;
                    SCALE_VLD = 1;
                end
            end
            @(posedge clk); #1;
        end
        check_vec(H_PE_EN, '0, "H_PE_EN=0 after compute");
        check_vec(V_PE_EN, '0, "V_PE_EN=0 after compute");
    endtask

    ///////////////////////////////////////////////////////////////////////////
	// Task: do_gemm_flush (CORRECTED)
	//
	// Flush requires W+1 handshakes:
	//   - Handshakes 0..W-1: present col_addr 0..W-1, check control signals.
	//   - Handshake W (drain): col_addr=W (out-of-range), col_out_pipe holds
	//     col W-1 — this triggers flush_done → state→IDLE.
	//
	// Y_VLD timing (with 2-stage flop fix applied):
	//   - Y_VLD fires 2 cycles after first handshake, aligned with Y_OUT.
	//   - After flush_done clock: Y_VLD=1, Y_OUT=col W-1 in IDLE for 1 cycle.
	///////////////////////////////////////////////////////////////////////////
	task do_gemm_flush(
		input int                    w_dim,
		input logic [ARRAY_SIZE-1:0] a_mask,
		input logic                  relu_en_exp
	);
		// W handshakes: check COL_ADDR, QUANT_EN, RELU_EN_out
		for (int w = 0; w < w_dim; w++) begin
			check(SCALE_RDY,  1'b1,
				$sformatf("SCALE_RDY=1 col %0d", w));
			check_addr(COL_ADDR, FIFO_ADDR_WIDTH'(w),
				$sformatf("COL_ADDR=%0d col %0d", w, w));
			check_vec(QUANT_EN, a_mask,
				$sformatf("QUANT_EN=A_MASK col %0d", w));
			check(RELU_EN_out, relu_en_exp,
				$sformatf("RELU_EN_out=%0b col %0d", relu_en_exp, w));
			@(posedge clk); #1;
		end

		// +1 drain handshake: col_out_pipe drains last column through VU.
		// flush_done fires here (main_cnt == W_DIM_r) → state→IDLE.
		// COL_ADDR=W_DIM_r (out of column range — don't check address).
		check(SCALE_RDY, 1'b1, "SCALE_RDY=1 drain cycle (flush_done)");
		check_vec(QUANT_EN, a_mask, "QUANT_EN=A_MASK drain cycle");
		@(posedge clk); #1;

		Y_RDY = 0;  SCALE_VLD = 0;
		// Now in IDLE. With 2-stage Y_VLD flop: Y_VLD=1 this cycle (col W-1 valid),
		// goes 0 next cycle.
		check_vec(Y_VLD, a_mask,  "Y_VLD=A_MASK after flush_done→IDLE");
		check(TILE_DONE,  1'b0,   "TILE_DONE=0 after flush→IDLE");
		check(SCALE_RDY,  1'b0,   "SCALE_RDY=0 in IDLE");
	endtask


    ///////////////////////////////////////////////////////////////////////////
    // MAIN TEST SEQUENCE
    ///////////////////////////////////////////////////////////////////////////
    initial begin
        pass_count = 0;  fail_count = 0;

        $display("=================================================================");
        $display(" GEMM Control Unit TB — Mealy LOAD_FIFO (no 1-cycle bubble)");
        $display("=================================================================");

        do_reset();

        ///////////////////////////////////////////////////////////////////////
        // T1: K > W  (data is bottleneck; bias finishes first)
        // A=4 W=3 K=5, BIAS_NEW=1, TILE_LAST=1, RELU_EN=1
        //
        // bias_done_r sets after cycle 2 (last BIAS handshake, w=2).
        // Transition fires on cycle 4 (last DATA handshake, k=4).
        // LOAD_FIFO = 5 cycles (K), no bubble.
        ///////////////////////////////////////////////////////////////////////
        current_test = "T1-K_GT_W";
        $display("\n[ T1 ] K > W: A=4 W=3 K=5, BIAS_NEW=1, TILE_LAST=1, RELU_EN=1");
        $display("-----------------------------------------------------------------");
        begin
            automatic logic [ARRAY_SIZE-1:0] a_mask = 8'b00001111;
            automatic logic [ARRAY_SIZE-1:0] w_mask = 8'b00000111;

            check(METADATA_RDY, 1'b1, "METADATA_RDY=1 in IDLE");
            start_tile(4'd4, 4'd3, 4'd5, 1'b1, 1'b1, 1'b1);
            check(METADATA_RDY, 1'b0, "METADATA_RDY=0 in LOAD_FIFO");

            // Verify A/W_IN_EN before first handshake
            DATA_VLD = 1; #1;
            check_vec(A_IN_EN, a_mask, "A_IN_EN=A_MASK");
            check_vec(W_IN_EN, w_mask, "W_IN_EN=W_MASK");
            DATA_VLD = 0;

            $display("    --- LOAD_FIFO: K=5 data || W=3 bias (bias done 2 cycles early) ---");
            fork
                do_data_load(5);
                do_bias_load(3);
            join
            // Cycle 2: last BIAS handshake → bias_done_r=1 next cycle
            // Cycle 4: last DATA handshake → data_done_r=1, both done → GEMM_COMPUTE

            $display("    --- GEMM_COMPUTE ---");
            do_gemm_compute(4, 3, 5, a_mask, w_mask, .pre_flush(1'b1));

            $display("    --- GEMM_FLUSH ---");
            do_gemm_flush(3, a_mask, 1'b1);

            @(posedge clk); #1;
            check(METADATA_RDY, 1'b1, "METADATA_RDY=1 back in IDLE");
        end

        do_reset();

        ///////////////////////////////////////////////////////////////////////
        // T2: K < W  (bias is bottleneck; data finishes first)
        // A=3 W=5 K=2, BIAS_NEW=1, TILE_LAST=1
        //
        // data_done_r sets after cycle 1 (last DATA handshake, k=1).
        // DATA_RDY deasserts; BIAS_RDY stays 1 while bias finishes (W=5).
        // Transition fires on cycle 4 (last BIAS handshake, w=4).
        // LOAD_FIFO = 5 cycles (W), no bubble.
        ///////////////////////////////////////////////////////////////////////
        current_test = "T2-K_LT_W";
        $display("\n[ T2 ] K < W: A=3 W=5 K=2, BIAS_NEW=1, TILE_LAST=1");
        $display("-----------------------------------------------------------------");
        begin
            automatic logic [ARRAY_SIZE-1:0] a_mask = 8'b00000111;
            automatic logic [ARRAY_SIZE-1:0] w_mask = 8'b00011111;

            start_tile(4'd3, 4'd5, 4'd2, 1'b1, 1'b1, 1'b0);

            $display("    --- LOAD_FIFO: K=2 data || W=5 bias (data done 3 cycles early) ---");
            fork
                begin
                    do_data_load(2);
                    // DATA_RDY=0 now (data_done_r=1); LOAD_FIFO still active
                    // Verify BIAS_RDY is still asserted while bias completes
                    check(BIAS_RDY, 1'b1,
                        "BIAS_RDY=1 while bias still loading after data done");
                    check(DATA_RDY, 1'b0,
                        "DATA_RDY=0 stays low after data done (no re-assertion)");
                end
                do_bias_load(5);
            join

            $display("    --- GEMM_COMPUTE ---");
            do_gemm_compute(3, 5, 2, a_mask, w_mask, .pre_flush(1'b1));

            $display("    --- GEMM_FLUSH ---");
            do_gemm_flush(5, a_mask, 1'b0);

            @(posedge clk); #1;
            check(METADATA_RDY, 1'b1, "METADATA_RDY=1 back in IDLE");
        end

        do_reset();

        ///////////////////////////////////////////////////////////////////////
        // T3: K == W  (simultaneous completion on the same clock)
        // A=4 W=4 K=4, BIAS_NEW=1, TILE_LAST=0
        //
        // Both data and bias fire their last handshake on cycle 3.
        // data_complete && bias_complete both true → single-cycle transition.
        // LOAD_FIFO = 4 cycles, TILE_LAST=0 → no flush.
        ///////////////////////////////////////////////////////////////////////
        current_test = "T3-K_EQ_W";
        $display("\n[ T3 ] K == W: A=4 W=4 K=4, BIAS_NEW=1, TILE_LAST=0");
        $display("-----------------------------------------------------------------");
        begin
            automatic logic [ARRAY_SIZE-1:0] a_mask = 8'b00001111;
            automatic logic [ARRAY_SIZE-1:0] w_mask = 8'b00001111;

            start_tile(4'd4, 4'd4, 4'd4, 1'b1, 1'b0, 1'b0);

            $display("    --- LOAD_FIFO: K=4 data || W=4 bias (simultaneous, cycle 3) ---");
            fork
                do_data_load(4);
                do_bias_load(4);
            join

            $display("    --- GEMM_COMPUTE (TILE_LAST=0 → TILE_DONE, back to IDLE) ---");
            do_gemm_compute(4, 4, 4, a_mask, w_mask, .check_tile_done(1'b1));

            check(METADATA_RDY, 1'b1, "METADATA_RDY=1 in IDLE (no flush)");
            check(TILE_DONE,    1'b0, "TILE_DONE deasserted after compute→IDLE");
        end

        do_reset();

        ///////////////////////////////////////////////////////////////////////
        // T4: BIAS_NEW=0  (data-only; bias channel fully gated)
        // A=2 W=2 K=3, TILE_LAST=0
        //
        // BIAS_RDY must stay 0 every cycle; LD_BIAS must stay 0.
        // No fork needed. Transition fires on k=2 (last DATA handshake).
        ///////////////////////////////////////////////////////////////////////
        current_test = "T4-no-bias";
        $display("\n[ T4 ] BIAS_NEW=0: A=2 W=2 K=3, data-only, TILE_LAST=0");
        $display("-----------------------------------------------------------------");
        begin
            automatic logic [ARRAY_SIZE-1:0] a_mask = 8'b00000011;
            automatic logic [ARRAY_SIZE-1:0] w_mask = 8'b00000011;

            start_tile(4'd2, 4'd2, 4'd3, 1'b0, 1'b0, 1'b0);

            $display("    --- LOAD_FIFO: K=3 data, no bias ---");
            DATA_VLD = 1;
            for (int k = 0; k < 3; k++) begin
                check(BIAS_RDY, 1'b0,
                    $sformatf("BIAS_RDY=0 (BIAS_NEW=0) k=%0d", k));
                check_vec(LD_BIAS, '0,
                    $sformatf("LD_BIAS=0  (BIAS_NEW=0) k=%0d", k));
                check(DATA_RDY, 1'b1,
                    $sformatf("DATA_RDY=1 k=%0d", k));
                check_addr(WR_ADDR, FIFO_ADDR_WIDTH'(k),
                    $sformatf("WR_ADDR=%0d", k));
                @(posedge clk); #1;
            end
            DATA_VLD = 0;
            check(DATA_RDY, 1'b0, "DATA_RDY=0 after K=3 handshakes");

            $display("    --- GEMM_COMPUTE ---");
            do_gemm_compute(2, 2, 3, a_mask, w_mask, .check_tile_done(1'b1));

            check(METADATA_RDY, 1'b1, "METADATA_RDY=1 in IDLE");
            check(|Y_VLD, 1'b0, "Y_VLD=0 — no flush occurred");
        end

        do_reset();

        ///////////////////////////////////////////////////////////////////////
        // T5: Data stall mid-load, no bias
        // A=2 W=2 K=4, TILE_LAST=1 — stall 3 cycles before k=2
        //
        // DATA_RDY must stay 1 during stall (data_done_r not yet set).
        // WR_ADDR must hold at 2 during stall (no increment while VLD=0).
        ///////////////////////////////////////////////////////////////////////
        current_test = "T5-data-stall-no-bias";
        $display("\n[ T5 ] Data stall, no bias: A=2 W=2 K=4, 3-cycle stall before k=2");
        $display("-----------------------------------------------------------------");
        begin
            automatic logic [ARRAY_SIZE-1:0] a_mask = 8'b00000011;
            automatic logic [ARRAY_SIZE-1:0] w_mask = 8'b00000011;

            start_tile(4'd2, 4'd2, 4'd4, 1'b0, 1'b1, 1'b0);

            $display("    --- LOAD_FIFO: 4 data handshakes, stall before k=2 ---");
            do_data_load(4, .stall_at(2), .stall_len(3));

            $display("    --- GEMM_COMPUTE ---");
            do_gemm_compute(2, 2, 4, a_mask, w_mask, .pre_flush(1'b1));

            $display("    --- GEMM_FLUSH ---");
            do_gemm_flush(2, a_mask, 1'b0);
        end

        do_reset();

        ///////////////////////////////////////////////////////////////////////
        // T6: Data stall + concurrent bias  (K > W; data stalls mid-load)
        // A=3 W=2 K=5, BIAS_NEW=1, TILE_LAST=1
        // Data: stall 2 cycles before k=2. Bias: runs freely, finishes at w=1.
        //
        // After bias finishes (cycle 1): bias_done_r=1, BIAS_RDY=0.
        // During data stall (cycles 2-3): neither channel makes progress.
        //   DATA_RDY=1 (data_done_r not set), BIAS_RDY=0 (bias_done_r=1).
        // Transition fires on last data handshake (k=4) after stall resolves.
        // LOAD_FIFO = K + stall_len = 7 cycles.
        ///////////////////////////////////////////////////////////////////////
        current_test = "T6-data-stall-with-bias";
        $display("\n[ T6 ] Data stall + concurrent bias: A=3 W=2 K=5, stall data before k=2");
        $display("-----------------------------------------------------------------");
        begin
            automatic logic [ARRAY_SIZE-1:0] a_mask = 8'b00000111;
            automatic logic [ARRAY_SIZE-1:0] w_mask = 8'b00000011;

            start_tile(4'd3, 4'd2, 4'd5, 1'b1, 1'b1, 1'b0);

            $display("    --- LOAD_FIFO: K=5 data (stall 2cyc at k=2) || W=2 bias ---");
            fork
                do_data_load(5, .stall_at(2), .stall_len(2));
                do_bias_load(2);
            join
            // bias_done_r=1 after cycle 1; DATA_RDY=1 during stall (data not done yet)
            // Transition on cycle 6 (k=4, last data handshake)

            $display("    --- GEMM_COMPUTE ---");
            do_gemm_compute(3, 2, 5, a_mask, w_mask, .pre_flush(1'b1));

            $display("    --- GEMM_FLUSH ---");
            do_gemm_flush(2, a_mask, 1'b0);
        end

        do_reset();

        ///////////////////////////////////////////////////////////////////////
        // T7: Bias stall + concurrent data  (W > K; bias stalls mid-load)
        // A=2 W=5 K=2, BIAS_NEW=1, TILE_LAST=1
        // Bias: stall 2 cycles before w=2. Data: runs freely, finishes at k=1.
        //
        // After data finishes (cycle 1): data_done_r=1, DATA_RDY=0.
        // BIAS_RDY=1 stays throughout (bias_done_r not set until last handshake).
        // Transition fires on last bias handshake (w=4) after stall resolves.
        // LOAD_FIFO = W + stall_len = 7 cycles.
        ///////////////////////////////////////////////////////////////////////
        current_test = "T7-bias-stall-with-data";
        $display("\n[ T7 ] Bias stall + concurrent data: A=2 W=5 K=2, stall bias before w=2");
        $display("-----------------------------------------------------------------");
        begin
            automatic logic [ARRAY_SIZE-1:0] a_mask = 8'b00000011;
            automatic logic [ARRAY_SIZE-1:0] w_mask = 8'b00011111;

            start_tile(4'd2, 4'd5, 4'd2, 1'b1, 1'b1, 1'b0);

            $display("    --- LOAD_FIFO: K=2 data || W=5 bias (stall 2cyc at w=2) ---");
            fork
                begin
                    do_data_load(2);
                    // Verify DATA_RDY stays low and BIAS_RDY stays high
                    // while bias continues loading after data is done
                    check(DATA_RDY, 1'b0,
                        "DATA_RDY=0 (data_done_r=1) while bias still loading");
                    check(BIAS_RDY, 1'b1,
                        "BIAS_RDY=1 while bias still loading after data done");
                end
                do_bias_load(5, .stall_at(2), .stall_len(2));
            join

            $display("    --- GEMM_COMPUTE ---");
            do_gemm_compute(2, 5, 2, a_mask, w_mask, .pre_flush(1'b1));

            $display("    --- GEMM_FLUSH ---");
            do_gemm_flush(5, a_mask, 1'b0);
        end

        do_reset();

        ///////////////////////////////////////////////////////////////////////
        // T8: Y_RDY stall during GEMM_FLUSH
        // A=3 W=4 K=3, BIAS_NEW=0, TILE_LAST=1, RELU_EN=1
        //
        // SCALE_RDY=Y_RDY in RTL. Stall on col 1 by deasserting both.
        // COL_ADDR must hold; QUANT_EN must gate to 0 while stalled.
        ///////////////////////////////////////////////////////////////////////
        current_test = "T8-flush-stall";
        $display("\n[ T8 ] Y_RDY stall during flush: A=3 W=4 K=3, stall on col 1");
        $display("-----------------------------------------------------------------");
        begin
            automatic logic [ARRAY_SIZE-1:0] a_mask = 8'b00000111;
            automatic logic [ARRAY_SIZE-1:0] w_mask = 8'b00001111;

            start_tile(4'd3, 4'd4, 4'd3, 1'b0, 1'b1, 1'b1);
            do_data_load(3);

            $display("    --- GEMM_COMPUTE ---");
            do_gemm_compute(3, 4, 3, a_mask, w_mask, .pre_flush(1'b1));

            $display("    --- GEMM_FLUSH with 3-cycle stall on col 1 ---");
            // Col 0 — pre-asserted Y_RDY/SCALE_VLD from pre_flush
            check(SCALE_RDY, 1'b1,    "SCALE_RDY=1 col 0");
            check_addr(COL_ADDR, 3'd0, "COL_ADDR=0  col 0");
            check_vec(QUANT_EN, a_mask,"QUANT_EN=A_MASK col 0");
            @(posedge clk); #1;

            // Stall: deassert both
            Y_RDY = 0;  SCALE_VLD = 0;  #1;
            repeat(3) begin
                check(SCALE_RDY,  1'b0, "SCALE_RDY=0 during stall");
                check_addr(COL_ADDR, 3'd1, "COL_ADDR=1 held during stall");
                check_vec(QUANT_EN, '0,   "QUANT_EN=0  during stall (Y_RDY=0)");
                @(posedge clk); #1;
            end

            // Resume col 1
            Y_RDY = 1;  SCALE_VLD = 1;  #1;
            check(SCALE_RDY,  1'b1,    "SCALE_RDY=1 on resume col 1");
            check_addr(COL_ADDR, 3'd1, "COL_ADDR=1 on resume");
            @(posedge clk); #1;

            // Col 2
			check_addr(COL_ADDR, 3'd2, "COL_ADDR=2");  @(posedge clk); #1;
			// Col 3
			check_addr(COL_ADDR, 3'd3, "COL_ADDR=3");  @(posedge clk); #1;
			// Drain: flush_done fires (main_cnt=4=W_DIM_r for W=4)
			check(SCALE_RDY, 1'b1, "SCALE_RDY=1 drain");  @(posedge clk); #1;
			Y_RDY = 0;  SCALE_VLD = 0;

            @(posedge clk); #1;
            check(METADATA_RDY, 1'b1, "METADATA_RDY=1 in IDLE after flush");
        end

        do_reset();

        ///////////////////////////////////////////////////////////////////////
        // T9: Multi-tile  (2x2x2 no-flush → 8x8x8 flush)
        //
        // Verifies: capture_metadata clears data_done_r/bias_done_r between
        // tiles; A/W masks update correctly; max-size tile (8x8x8) works.
        ///////////////////////////////////////////////////////////////////////
        current_test = "T9-multi-tile";
        $display("\n[ T9 ] Multi-tile: 2x2x2 (no flush) → 8x8x8 (flush)");
        $display("-----------------------------------------------------------------");
        begin
            // ── Tile 1: 2x2x2, BIAS_NEW=0, TILE_LAST=0 ──────────────────
            $display("    Tile 1: A=2 W=2 K=2, BIAS_NEW=0, TILE_LAST=0");
            start_tile(4'd2, 4'd2, 4'd2, 1'b0, 1'b0, 1'b0);
            do_data_load(2);
            do_gemm_compute(2, 2, 2, 8'b00000011, 8'b00000011,
                .check_tile_done(1'b1));
            check(METADATA_RDY, 1'b1, "Tile1: METADATA_RDY=1 in IDLE");

            // ── Tile 2: 8x8x8, BIAS_NEW=0, TILE_LAST=1 ──────────────────
            $display("    Tile 2: A=8 W=8 K=8, BIAS_NEW=0, TILE_LAST=1");
            start_tile(4'd8, 4'd8, 4'd8, 1'b0, 1'b1, 1'b0);

            DATA_VLD = 1; #1;
            check_vec(A_IN_EN, 8'hFF, "Tile2: A_IN_EN=FF (A=8)");
            check_vec(W_IN_EN, 8'hFF, "Tile2: W_IN_EN=FF (W=8)");
            DATA_VLD = 0;

            do_data_load(8);
            do_gemm_compute(8, 8, 8, 8'hFF, 8'hFF, .pre_flush(1'b1));
            do_gemm_flush(8, 8'hFF, 1'b0);

            @(posedge clk); #1;
            check(METADATA_RDY, 1'b1, "Tile2: METADATA_RDY=1 in IDLE");
        end

        ///////////////////////////////////////////////////////////////////////
        // Summary
        ///////////////////////////////////////////////////////////////////////
        $display("\n=================================================================");
        $display(" Results: %0d PASSED, %0d FAILED", pass_count, fail_count);
        $display("=================================================================");
        if (fail_count == 0) $display(" ALL TESTS PASSED");
        else                 $display(" FAILURES DETECTED — check above");

        $stop;
    end

    ///////////////////////////////////////////////////////////////////////////
    // Timeout watchdog
    ///////////////////////////////////////////////////////////////////////////
    initial begin
        #2_000_000;
        $display("TIMEOUT — simulation did not complete");
        $stop;
    end

endmodule