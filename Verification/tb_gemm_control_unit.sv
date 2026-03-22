///////////////////////////////////////////////////////////////////////////////
// Module: tb_gemm_control_unit.sv
// Description: Standalone self-checking testbench for gemm_control_unit.
//
//  Timing model (sample-before-clock throughout):
//
//  do_data_load / WR_ADDR:
//    WR_ADDR = main_cnt is sampled BEFORE @(posedge clk) that increments it.
//
//  do_gemm_compute:
//    pe_wave shifts on the same clock edge that transitions to GEMM_COMPUTE,
//    so pe_wave is already valid for cyc=0 on task entry — NO entry clock.
//    Loop: sample H/V_PE_EN + A/W_OUT_EN, optionally check TILE_DONE on
//    cyc==total-1 (compute_done cycle), then clock. FSM transitions on the
//    final loop clock. COMPUTE_LIM_r = A+W+K-2, so total = A+W+K-2 cycles.
//
//  do_gemm_flush:
//    NO entry clock — COL_ADDR=main_cnt=0 valid immediately on flush entry.
//    QUANT_EN/RELU_EN_out gated by Y_RDY in RTL — caller asserts Y_RDY=1
//    BEFORE calling so these are valid on col 0.
//    Loop: sample COL_ADDR/QUANT_EN/RELU_EN_out, then clock.
//
// Author: Group5
///////////////////////////////////////////////////////////////////////////////

import gemm_pkg::*;

module tb_gemm_control_unit;

    ///////////////////////////////////////////////////////////////////////////
    // DUT signals
    ///////////////////////////////////////////////////////////////////////////
    logic                           clk, rst_n;
    logic                           TILE_START, METADATA_VLD;
    logic [DIM_WIDTH-1:0]           A_LEN, W_LEN, K_LEN;
    logic                           BIAS_NEW, TILE_LAST, RELU_EN;
    logic                           DATA_VLD, BIAS_VLD, Y_RDY, SCALE_VLD;

    logic                           METADATA_RDY, DATA_RDY, BIAS_RDY;
    logic                           SCALE_RDY, Y_VLD, TILE_DONE;
    logic [ARRAY_SIZE-1:0]          A_IN_EN, W_IN_EN;
    logic [FIFO_ADDR_WIDTH-1:0]     WR_ADDR;
    logic [ARRAY_SIZE-1:0]          A_OUT_EN, W_OUT_EN;
    logic [ARRAY_SIZE-1:0]          H_PE_EN, V_PE_EN;
    logic [ARRAY_SIZE-1:0]          LD_BIAS;
    logic [FIFO_ADDR_WIDTH-1:0]     COL_ADDR;
    logic [ARRAY_SIZE-1:0]          QUANT_EN;
    logic                           RELU_EN_out;

    ///////////////////////////////////////////////////////////////////////////
    // DUT instantiation
    ///////////////////////////////////////////////////////////////////////////
    gemm_control_unit dut (
        .clk         (clk),         .rst_n       (rst_n),
        .TILE_START  (TILE_START),  .METADATA_VLD(METADATA_VLD),
        .A_LEN       (A_LEN),       .W_LEN       (W_LEN),
        .K_LEN       (K_LEN),       .BIAS_NEW    (BIAS_NEW),
        .TILE_LAST   (TILE_LAST),   .RELU_EN     (RELU_EN),
        .DATA_VLD    (DATA_VLD),    .BIAS_VLD    (BIAS_VLD),
        .Y_RDY       (Y_RDY),       .SCALE_VLD   (SCALE_VLD),
        .METADATA_RDY(METADATA_RDY),
        .DATA_RDY    (DATA_RDY),    .BIAS_RDY    (BIAS_RDY),
        .SCALE_RDY   (SCALE_RDY),  .Y_VLD       (Y_VLD),
        .TILE_DONE   (TILE_DONE),   .A_IN_EN     (A_IN_EN),
        .W_IN_EN     (W_IN_EN),     .WR_ADDR     (WR_ADDR),
        .A_OUT_EN    (A_OUT_EN),    .W_OUT_EN    (W_OUT_EN),
        .H_PE_EN     (H_PE_EN),     .V_PE_EN     (V_PE_EN),
        .LD_BIAS     (LD_BIAS),     .COL_ADDR    (COL_ADDR),
        .QUANT_EN    (QUANT_EN),    .RELU_EN_out (RELU_EN_out)
    );

    ///////////////////////////////////////////////////////////////////////////
    // Clock
    ///////////////////////////////////////////////////////////////////////////
    initial clk = 0;
    always #5 clk = ~clk;

    ///////////////////////////////////////////////////////////////////////////
    // Test tracking
    ///////////////////////////////////////////////////////////////////////////
    int pass_count, fail_count;
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
            $display("    FAIL [%s] %s: expected 8'b%08b got 8'b%08b",
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
    // Task: idle all inputs
    ///////////////////////////////////////////////////////////////////////////
    task drive_idle();
        TILE_START = 0; METADATA_VLD = 0;
        A_LEN = 0; W_LEN = 0; K_LEN = 0;
        BIAS_NEW = 0; TILE_LAST = 0; RELU_EN = 0;
        DATA_VLD = 0; BIAS_VLD = 0; Y_RDY = 0; SCALE_VLD = 0;
    endtask

    ///////////////////////////////////////////////////////////////////////////
    // Task: reset
    ///////////////////////////////////////////////////////////////////////////
    task do_reset();
        rst_n = 0;
        drive_idle();
        repeat(3) @(posedge clk); #1;
        rst_n = 1;
        @(posedge clk); #1;
    endtask

    ///////////////////////////////////////////////////////////////////////////
    // Task: start tile
    ///////////////////////////////////////////////////////////////////////////
    task start_tile(
        input logic [DIM_WIDTH-1:0] a, w, k,
        input logic                 bias_new, tile_last, relu_en
    );
        A_LEN = a; W_LEN = w; K_LEN = k;
        BIAS_NEW = bias_new; TILE_LAST = tile_last; RELU_EN = relu_en;
        TILE_START = 1; METADATA_VLD = 1;
        @(posedge clk); #1;
        TILE_START = 0; METADATA_VLD = 0;
    endtask

    ///////////////////////////////////////////////////////////////////////////
    // Task: K data handshakes
    // FIX: WR_ADDR = main_cnt checked BEFORE clock (pre-increment value)
    ///////////////////////////////////////////////////////////////////////////
    task do_data_load(input int k_dim);
        DATA_VLD = 1;
        for (int k = 0; k < k_dim; k++) begin
            check(DATA_RDY, 1'b1,
                $sformatf("DATA_RDY=1 during load k=%0d", k));
            check_addr(WR_ADDR, FIFO_ADDR_WIDTH'(k),
                $sformatf("WR_ADDR=%0d at data cycle k=%0d", k, k));
            @(posedge clk); #1;  // increment happens here
        end
        DATA_VLD = 0;
        // One extra clock: data_load_done fires AFTER the Kth handshake
        // (main_cnt increments to K_DIM_r on the Kth posedge, so
        //  data_load_done=1 combinationally on the NEXT cycle).
        // This clock is the LOAD_FIFO exit clock: clr_pe_wave fires,
        // pe_wave loads 8'b00000001, state→GEMM_COMPUTE, main_cnt→0.
        // After this clock we are in GEMM_COMPUTE with pe_wave=00000001.
        @(posedge clk); #1;
        check(DATA_RDY, 1'b0, "DATA_RDY=0 after k_dim handshakes");
    endtask

    ///////////////////////////////////////////////////////////////////////////
    // Task: W bias handshakes
    ///////////////////////////////////////////////////////////////////////////
    task do_bias_load(input int w_dim);
        BIAS_VLD = 1;
        for (int w = 0; w < w_dim; w++) begin
            check(BIAS_RDY, 1'b1,
                $sformatf("BIAS_RDY=1 during bias load w=%0d", w));
            check_vec(LD_BIAS, ARRAY_SIZE'(1 << w),
                $sformatf("LD_BIAS one-hot [%0d] at bias cycle w=%0d", w, w));
            @(posedge clk); #1;
        end
        BIAS_VLD = 0;
        @(posedge clk); #1;
        check(BIAS_RDY, 1'b0, "BIAS_RDY=0 after w_dim handshakes");
    endtask

    ///////////////////////////////////////////////////////////////////////////
    // Task: GEMM_COMPUTE — check pe_wave vectors every cycle
    //
    // FIX 1: Clock once on entry — pe_wave shifts on first posedge of
    //        GEMM_COMPUTE, so we consume that transition cycle first.
    //        After that clock, pe_wave[0]=1 and we start sampling.
    //
    // FIX 2: TILE_DONE checked AFTER loop but BEFORE the transition clock —
    //        it is a combinational pulse on the compute_done cycle.
    ///////////////////////////////////////////////////////////////////////////
    ///////////////////////////////////////////////////////////////////////////
    // Task: GEMM_COMPUTE
    //
    // RTL: clr_pe_wave on LOAD_FIFO exit loads 8'b00000001.
    //      COMPUTE_LIM_r = A+W+K-3. Total useful cycles = A+W+K-2.
    //      LOAD_FIFO exits on the LAST handshake clock (data_load_done fires
    //      when main_cnt==K_DIM_r on the Kth handshake clock). After the
    //      do_data_load loop (no extra clock), state=GEMM_COMPUTE, pe_wave=1.
    //
    // pre_flush: assert Y_RDY=1 on cyc==total-1 before transition clock so
    //            QUANT_EN is valid on col 0 of GEMM_FLUSH immediately.
    ///////////////////////////////////////////////////////////////////////////
    task do_gemm_compute(
        input int                    a_dim, w_dim, k_dim,
        input logic [ARRAY_SIZE-1:0] a_mask, w_mask,
        input logic                  check_tile_done = 1'b0,
        input logic                  pre_flush       = 1'b0
    );
        automatic int total = a_dim + w_dim + k_dim - 2;
        automatic logic [ARRAY_SIZE-1:0] exp_wave = '0;
        automatic logic [ARRAY_SIZE-1:0] exp_h, exp_v;

        $display("    Compute: A=%0d W=%0d K=%0d cycles=%0d", a_dim, w_dim, k_dim, total);

        // NO entry clock — pe_wave=00000001 valid on cycle 0
        for (int cyc = 0; cyc < total; cyc++) begin
            exp_wave = (exp_wave << 1) | (cyc < k_dim ? 1'b1 : 1'b0);
            exp_h    = exp_wave & a_mask;
            exp_v    = exp_wave & w_mask;

            check_vec(H_PE_EN,  exp_h, $sformatf("H_PE_EN  cycle %0d", cyc));
            check_vec(V_PE_EN,  exp_v, $sformatf("V_PE_EN  cycle %0d", cyc));
            check_vec(A_OUT_EN, exp_h, $sformatf("A_OUT_EN cycle %0d", cyc));
            check_vec(W_OUT_EN, exp_v, $sformatf("W_OUT_EN cycle %0d", cyc));

            if (cyc == total-1) begin
                if (check_tile_done)
                    check(TILE_DONE, 1'b1, "TILE_DONE=1 on compute_done cycle");
                if (pre_flush) begin
                    Y_RDY     = 1;  // pre-assert both before transition clock
                    SCALE_VLD = 1;
                end
            end

            @(posedge clk); #1;
        end

        check_vec(H_PE_EN, '0, "H_PE_EN=0 after compute");
        check_vec(V_PE_EN, '0, "V_PE_EN=0 after compute");
    endtask

    ///////////////////////////////////////////////////////////////////////////
    // Task: GEMM_FLUSH with Y_RDY=1
    //
    // FIX 3: NO entry clock — COL_ADDR = main_cnt = 0 is already valid
    //        the moment we enter GEMM_FLUSH. Unlike pe_wave which needs
    //        one shift, COL_ADDR is purely combinational from main_cnt.
    //
    // Sample each column BEFORE the clock that increments main_cnt.
    ///////////////////////////////////////////////////////////////////////////
    ///////////////////////////////////////////////////////////////////////////
    // Task: GEMM_FLUSH
    // Y_RDY and SCALE_VLD pre-asserted by do_gemm_compute(pre_flush=1).
    // RTL advances only on Y_RDY && SCALE_VLD. SCALE_RDY = Y_RDY in flush.
    ///////////////////////////////////////////////////////////////////////////
    task do_gemm_flush(
        input int                    w_dim,
        input logic [ARRAY_SIZE-1:0] a_mask,
        input logic                  relu_en_exp
    );
        // Y_RDY and SCALE_VLD both pre-asserted. NO entry clock.
        for (int w = 0; w < w_dim; w++) begin
            check(SCALE_RDY,   1'b1,
                $sformatf("SCALE_RDY=1 at flush w=%0d", w));
            check_addr(COL_ADDR,   FIFO_ADDR_WIDTH'(w),
                $sformatf("COL_ADDR=%0d at flush w=%0d", w, w));
            check_vec(QUANT_EN,    a_mask,
                $sformatf("QUANT_EN=A_MASK at flush w=%0d", w));
            check(RELU_EN_out,     relu_en_exp,
                $sformatf("RELU_EN_out=%0b at flush w=%0d", relu_en_exp, w));
            @(posedge clk); #1;
        end
        Y_RDY = 0; SCALE_VLD = 0;

        // Y_VLD flopped — high 1 cycle after last flush handshake
        check(Y_VLD,     1'b1, "Y_VLD=1 after last flush");
        check(TILE_DONE, 1'b0, "TILE_DONE deasserted after flush done");
        check(SCALE_RDY, 1'b0, "SCALE_RDY=0 back in IDLE");
    endtask

    ///////////////////////////////////////////////////////////////////////////
    // Main test sequence
    ///////////////////////////////////////////////////////////////////////////
    initial begin
        pass_count = 0; fail_count = 0;

        $display("=================================================================");
        $display(" GEMM Control Unit Standalone Testbench");
        $display("=================================================================");

        do_reset();

        ///////////////////////////////////////////////////////////////////////
        // TEST 1 — Basic 4x3x5, BIAS_NEW=1, TILE_LAST=1, RELU_EN=1
        // A=4, W=3, K=5
        // A_MASK=00001111, W_MASK=00000111
        // COMPUTE cycles = 4+3+5-2 = 10
        ///////////////////////////////////////////////////////////////////////
        current_test = "T1-basic-4x3x5";
        $display("\n[ TEST 1 ] A=4 W=3 K=5, BIAS_NEW=1, TILE_LAST=1, RELU_EN=1");
        $display("-----------------------------------------------------------------");
        begin
            automatic logic [ARRAY_SIZE-1:0] a_mask = 8'b00001111;
            automatic logic [ARRAY_SIZE-1:0] w_mask = 8'b00000111;

            check(METADATA_RDY, 1'b1, "METADATA_RDY=1 in IDLE");
            start_tile(4'd4, 4'd3, 4'd5, 1'b1, 1'b1, 1'b1);
            check(METADATA_RDY, 1'b0, "METADATA_RDY=0 after tile start");

            $display("    --- LOAD_FIFO phase ---");
            // Check combinational A/W_IN_EN before first handshake
            DATA_VLD = 1; BIAS_VLD = 1; #1;
            check_vec(A_IN_EN, a_mask, "A_IN_EN=A_MASK on first data handshake");
            check_vec(W_IN_EN, w_mask, "W_IN_EN=W_MASK on first data handshake");
            DATA_VLD = 0; BIAS_VLD = 0;

            fork
                do_data_load(5);
                do_bias_load(3);
            join

            $display("    --- GEMM_COMPUTE phase ---");
            do_gemm_compute(4, 3, 5, a_mask, w_mask, .pre_flush(1'b1));

            $display("    --- GEMM_FLUSH phase ---");
            do_gemm_flush(3, a_mask, 1'b1);

            @(posedge clk); #1;
            check(METADATA_RDY, 1'b1, "METADATA_RDY=1 back in IDLE after tile");
        end

        do_reset();

        ///////////////////////////////////////////////////////////////////////
        // TEST 2 — BIAS_NEW=0, TILE_LAST=0 (no bias load, no flush)
        // A=2, W=2, K=3
        // COMPUTE cycles = 2+2+3-2 = 5
        ///////////////////////////////////////////////////////////////////////
        current_test = "T2-no-bias-no-flush";
        $display("\n[ TEST 2 ] A=2 W=2 K=3, BIAS_NEW=0, TILE_LAST=0");
        $display("-----------------------------------------------------------------");
        begin
            automatic logic [ARRAY_SIZE-1:0] a_mask = 8'b00000011;
            automatic logic [ARRAY_SIZE-1:0] w_mask = 8'b00000011;

            start_tile(4'd2, 4'd2, 4'd3, 1'b0, 1'b0, 1'b0);

            $display("    --- LOAD_FIFO phase (data only) ---");
            DATA_VLD = 1;
            repeat(3) begin
                check(BIAS_RDY, 1'b0, "BIAS_RDY=0 when BIAS_NEW=0");
                check_vec(LD_BIAS, '0, "LD_BIAS=0 when BIAS_NEW=0");
                @(posedge clk); #1;
            end
            DATA_VLD = 0;
            @(posedge clk); #1;

            $display("    --- GEMM_COMPUTE phase ---");
            // check_tile_done=1 — verify TILE_DONE fires on compute_done
            do_gemm_compute(2, 2, 3, a_mask, w_mask, .check_tile_done(1'b1));

            // Now in IDLE — TILE_DONE deasserted on transition clock
            check(METADATA_RDY, 1'b1, "METADATA_RDY=1 back in IDLE");
            check(Y_VLD,        1'b0, "Y_VLD=0 — no flush occurred");
        end

        do_reset();

        ///////////////////////////////////////////////////////////////////////
        // TEST 3 — DATA stall mid-load
        // A=2, W=2, K=4, TILE_LAST=1
        ///////////////////////////////////////////////////////////////////////
        current_test = "T3-data-stall";
        $display("\n[ TEST 3 ] DATA stall mid-load, A=2 W=2 K=4");
        $display("-----------------------------------------------------------------");
        begin
            automatic logic [ARRAY_SIZE-1:0] a_mask = 8'b00000011;
            automatic logic [ARRAY_SIZE-1:0] w_mask = 8'b00000011;

            start_tile(4'd2, 4'd2, 4'd4, 1'b0, 1'b1, 1'b0);

            // FIX: check WR_ADDR BEFORE clock (pre-increment)
            DATA_VLD = 1;
            check_addr(WR_ADDR, 3'd0, "WR_ADDR=0 at k=0");
            @(posedge clk); #1;

            check_addr(WR_ADDR, 3'd1, "WR_ADDR=1 at k=1");
            @(posedge clk); #1;

            // Stall
            DATA_VLD = 0;
            repeat(3) begin
                check(DATA_RDY,     1'b1,  "DATA_RDY=1 during stall");
                check_addr(WR_ADDR, 3'd2,  "WR_ADDR=2 held during stall");
                @(posedge clk); #1;
            end

            // Resume
            DATA_VLD = 1;
            check_addr(WR_ADDR, 3'd2, "WR_ADDR=2 at k=2 resume");
            @(posedge clk); #1;
            check_addr(WR_ADDR, 3'd3, "WR_ADDR=3 at k=3");
            @(posedge clk); #1;

            DATA_VLD = 0;
            @(posedge clk); #1; // LOAD_FIFO exit clock: pe_wave→00000001, state→GEMM_COMPUTE
            check(DATA_RDY, 1'b0, "DATA_RDY=0 after K=4 handshakes");

            $display("    --- GEMM_COMPUTE phase after stall ---");
            do_gemm_compute(2, 2, 4, a_mask, w_mask, .pre_flush(1'b1));

            $display("    --- GEMM_FLUSH phase ---");
            do_gemm_flush(2, a_mask, 1'b0);
        end

        do_reset();

        ///////////////////////////////////////////////////////////////////////
        // TEST 4 — Y_RDY stall during flush
        // A=3, W=4, K=3, TILE_LAST=1
        ///////////////////////////////////////////////////////////////////////
        current_test = "T4-flush-stall";
        $display("\n[ TEST 4 ] Y_RDY stall during flush, A=3 W=4 K=3");
        $display("-----------------------------------------------------------------");
        begin
            automatic logic [ARRAY_SIZE-1:0] a_mask = 8'b00000111;
            automatic logic [ARRAY_SIZE-1:0] w_mask = 8'b00001111;

            start_tile(4'd3, 4'd4, 4'd3, 1'b0, 1'b1, 1'b1);

            DATA_VLD = 1;
            repeat(3) @(posedge clk); #1;
            DATA_VLD = 0;
            @(posedge clk); #1;

            $display("    --- GEMM_COMPUTE phase ---");
            do_gemm_compute(3, 4, 3, a_mask, w_mask, .pre_flush(1'b1));

            $display("    --- GEMM_FLUSH with stall on col 1 ---");

            // Col 0 — Y_RDY=1 and SCALE_VLD=1 from pre_flush
            SCALE_VLD = 1;
            check(SCALE_RDY, 1'b1, "SCALE_RDY=1 col 0");
            check_addr(COL_ADDR, 3'd0, "COL_ADDR=0 flush col 0");
            check_vec(QUANT_EN, a_mask, "QUANT_EN=A_MASK col 0");
            @(posedge clk); #1;

            // Stall on col 1 — deassert Y_RDY and SCALE_VLD
            Y_RDY = 0; SCALE_VLD = 0; #1;
            repeat(3) begin
                check(SCALE_RDY,  1'b0, "SCALE_RDY=0 during stall");
                check_addr(COL_ADDR, 3'd1, "COL_ADDR=1 held during stall");
                check(Y_VLD,         1'b1, "Y_VLD=1 held during stall");
                check_vec(QUANT_EN,  '0,   "QUANT_EN=0 during stall");
                @(posedge clk); #1;
            end

            // Resume col 1 — reassert Y_RDY and SCALE_VLD
            Y_RDY = 1; SCALE_VLD = 1; #1;
            check(SCALE_RDY, 1'b1, "SCALE_RDY=1 on resume");
            check_addr(COL_ADDR, 3'd1, "COL_ADDR=1 resumes after stall");
            @(posedge clk); #1;

            // Col 2
            check_addr(COL_ADDR, 3'd2, "COL_ADDR=2 flush col 2");
            @(posedge clk); #1;

            // Col 3
            check_addr(COL_ADDR, 3'd3, "COL_ADDR=3 flush col 3");
            @(posedge clk); #1;
            Y_RDY = 0; SCALE_VLD = 0;

            @(posedge clk); #1;
            check(METADATA_RDY, 1'b1, "METADATA_RDY=1 back in IDLE after flush");
        end

        do_reset();

        ///////////////////////////////////////////////////////////////////////
        // TEST 5 — Multi-tile: 2x2x2 (no flush) then 8x8x8 (flush)
        ///////////////////////////////////////////////////////////////////////
        current_test = "T5-multi-tile";
        $display("\n[ TEST 5 ] Multi-tile: 2x2x2 then 8x8x8");
        $display("-----------------------------------------------------------------");
        begin
            // ── Tile 1: 2x2x2, TILE_LAST=0 ───────────────────────────────
            $display("    Tile 1: A=2 W=2 K=2, TILE_LAST=0");
            start_tile(4'd2, 4'd2, 4'd2, 1'b0, 1'b0, 1'b0);

            DATA_VLD = 1;
            repeat(2) @(posedge clk); #1;
            DATA_VLD = 0;
            @(posedge clk); #1;

            do_gemm_compute(2, 2, 2, 8'b00000011, 8'b00000011, .check_tile_done(1'b1));

            check(METADATA_RDY, 1'b1, "Tile1: METADATA_RDY=1 back in IDLE");

            // ── Tile 2: 8x8x8, TILE_LAST=1 ───────────────────────────────
            $display("    Tile 2: A=8 W=8 K=8, TILE_LAST=1");
            start_tile(4'd8, 4'd8, 4'd8, 1'b0, 1'b1, 1'b0);

            // Verify masks updated
            DATA_VLD = 1; #1;
            check_vec(A_IN_EN, 8'hFF, "Tile2: A_IN_EN=FF for A=8");
            check_vec(W_IN_EN, 8'hFF, "Tile2: W_IN_EN=FF for W=8");
            DATA_VLD = 0;

            DATA_VLD = 1;
            repeat(8) @(posedge clk); #1;
            DATA_VLD = 0;
            @(posedge clk); #1;

            do_gemm_compute(8, 8, 8, 8'hFF, 8'hFF, .pre_flush(1'b1));

            $display("    Tile 2 flush: W=8 columns");
            SCALE_VLD = 1; // already set by pre_flush, explicit for clarity
            for (int w = 0; w < 8; w++) begin
                check(SCALE_RDY, 1'b1, $sformatf("Tile2: SCALE_RDY=1 col %0d", w));
                check_addr(COL_ADDR, FIFO_ADDR_WIDTH'(w),
                    $sformatf("Tile2: COL_ADDR=%0d", w));
                check_vec(QUANT_EN, 8'hFF,
                    $sformatf("Tile2: QUANT_EN=FF col %0d", w));
                @(posedge clk); #1;
            end
            Y_RDY = 0; SCALE_VLD = 0;

            @(posedge clk); #1;
            check(METADATA_RDY, 1'b1, "Tile2: METADATA_RDY=1 back in IDLE");
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
        #1000000;
        $display("TIMEOUT");
        $stop;
    end
endmodule