///////////////////////////////////////////////////////////////////////////////
// Module: tb_tt_um_gemm_top.sv
// Description: Interface and timing verification testbench for the
//              FP4 GEMM Tiny Tapeout 1xN design (shared VU, ping-pong FLUSH).
//
// Three test cases:
//   Test 1: 1x3 (COL_CONFIG=2)
//   Test 2: 1x2 (COL_CONFIG=1)
//   Test 3: 1x1 (COL_CONFIG=0)
//
// Common test values:
//   K=2, A=W=FP4(1.0)=0x2, bias=FP16(0.0)=0x0000, scale=FP16(1.0)=0x3C00
//   Expected per column: acc = 0 + 1.0 + 1.0 = FP16(2.0)=0x4000
//                        y   = 1.0 * 2.0 = FP4(2.0) = 0x4
//   Expected uio_out[7:4] on each odd FLUSH cycle: 0x4 → uio_out = 0x40
//
// FLUSH ping-pong protocol (2 cycles per column, 2*NCOLS total):
//   Even cycles (flush_cnt[0]=0): host drives 16-bit scale on {ui_in,uio_in}
//                                  uio_oe=0x00, capture_en=1 in VU
//   Odd  cycles (flush_cnt[0]=1): chip drives y_out on uio_out[7:4]
//                                  uio_oe=0xFF, result_valid=1
//
// LOAD is bias-only (NCOLS cycles); no scale loading in LOAD phase.
//
// CFG uio_in encoding:
//   [0]   = RELU_EN
//   [1]   = SKIP_BIAS
//   [4:3] = COL_CONFIG  (00=1x1, 01=1x2, 10=1x3)
//   1x1: uio_in=0x00   1x2: uio_in=0x08   1x3: uio_in=0x10
//
// uo_out expected values:
//   IDLE            0x00
//   CFG             0x09  {busy=1, phase=001}
//   LOAD            0x0A  {busy=1, phase=010}
//   STREAM          0x0B  {busy=1, phase=011}
//   FLUSH even      0x0C  {flush_cnt[0]=0, result_valid=0, busy=1, phase=100}
//   FLUSH odd       0x5C  {flush_cnt[0]=1, result_valid=1, busy=1, phase=100}
//   FLUSH last odd  0x7C  {tile_done=1, flush_cnt[0]=1, result_valid=1, busy=1, phase=100}
//
// ─────────────────────────────────────────────────────────────────────────────
// Test 1 — 1x3 (COL_CONFIG=2, K=2) cycle map
// ─────────────────────────────────────────────────────────────────────────────
//   Cycle  1  IDLE:      assert START (ui_in[0]=1)
//   Cycle  2  CFG:       K_LEN=2, COL_CONFIG=2, flags=0 captured
//   Cycle  3  LOAD cnt=0: bias[0]=0x0000 → col0 acc (ld_bias[0]=1)
//   Cycle  4  LOAD cnt=1: bias[1]=0x0000 → col1 acc
//   Cycle  5  LOAD cnt=2: bias[2]=0x0000 → col2 acc; exit → STREAM
//   Cycle  6  STREAM cnt=0: V_PE_EN=001; col0 1st MAC
//   Cycle  7  STREAM cnt=1: V_PE_EN=011; col0 2nd, col1 1st MAC
//   Cycle  8  STREAM cnt=2: V_PE_EN=110; col1 2nd, col2 1st MAC
//   Cycle  9  STREAM cnt=3: V_PE_EN=100; col2 2nd MAC; exit → FLUSH
//   Cycle 10  FLUSH cnt=0 (even):  host drives scale[col0]=0x3C00; VU captures; uio_oe=0x00
//   Cycle 11  FLUSH cnt=1 (odd):   uio_out=0x40 (y[col0]=0x4); uio_oe=0xFF
//   Cycle 12  FLUSH cnt=2 (even):  host drives scale[col1]=0x3C00; VU captures
//   Cycle 13  FLUSH cnt=3 (odd):   uio_out=0x40 (y[col1]=0x4)
//   Cycle 14  FLUSH cnt=4 (even):  host drives scale[col2]=0x3C00; VU captures
//   Cycle 15  FLUSH cnt=5 (odd):   uio_out=0x40 (y[col2]=0x4); tile_done; → IDLE
//
// ─────────────────────────────────────────────────────────────────────────────
// Test 2 — 1x2 (COL_CONFIG=1, K=2) cycle map
// ─────────────────────────────────────────────────────────────────────────────
//   LOAD:   2 cycles (cnt=0,1; bias[0],bias[1])
//   STREAM: 3 cycles (cnt=0..2; stream_exit=K+COL_CONFIG-1=2)
//   FLUSH:  4 cycles (flush_cnt=0..3; flush_exit={1'b1,1'b1}=3)
//     cnt=0 (even):  scale[col0]; cnt=1 (odd):  y[col0]=0x4
//     cnt=2 (even):  scale[col1]; cnt=3 (odd):  y[col1]=0x4; tile_done
//
// ─────────────────────────────────────────────────────────────────────────────
// Test 3 — 1x1 (COL_CONFIG=0, K=2) cycle map
// ─────────────────────────────────────────────────────────────────────────────
//   LOAD:   1 cycle  (cnt=0; bias[0])
//   STREAM: 2 cycles (cnt=0..1; stream_exit=1)
//   FLUSH:  2 cycles (flush_cnt=0..1; flush_exit={0'b0,1'b1}=1)
//     cnt=0 (even):  scale[col0]; cnt=1 (odd): y[col0]=0x4; tile_done
//
// Author: Group5
///////////////////////////////////////////////////////////////////////////////

module tb_tt_um_gemm_top;

    localparam CLK_PERIOD = 10;  // 10 ns → 100 MHz

    //=========================================================================
    // DUT signals
    //=========================================================================
    logic        clk;
    logic        rst_n;
    logic        ena;
    logic [7:0]  ui_in;
    logic [7:0]  uo_out;
    logic [7:0]  uio_in;
    logic [7:0]  uio_out;
    logic [7:0]  uio_oe;

    gemm_top dut (
        .clk    (clk),
        .rst_n  (rst_n),
        .ena    (ena),
        .ui_in  (ui_in),
        .uo_out (uo_out),
        .uio_in (uio_in),
        .uio_out(uio_out),
        .uio_oe (uio_oe)
    );

    //=========================================================================
    // Clock
    //=========================================================================
    initial clk = 0;
    always  #(CLK_PERIOD/2) clk = ~clk;

    //=========================================================================
    // Utilities
    //=========================================================================
    int pass_cnt = 0;
    int fail_cnt = 0;

    task tick;
        @(posedge clk); #1;
    endtask

    task automatic chk(input string lbl, input logic [7:0] got, exp);
        if (got === exp) begin
            $display("  PASS  %-30s  got=0x%02h", lbl, got);
            pass_cnt++;
        end else begin
            $display("  FAIL  %-30s  got=0x%02h  exp=0x%02h", lbl, got, exp);
            fail_cnt++;
        end
    endtask

    //=========================================================================
    // Test stimulus
    //=========================================================================
    initial begin
        $dumpfile("tb_tt_um_gemm_top.vcd");
        $dumpvars(0, tb_tt_um_gemm_top);

        $display("=== tt_um_gemm_top: 1xN ping-pong FLUSH TB ===");
        $display("    K=2, A=W=FP4(1.0)=0x2, bias=0x0000, scale=FP16(1.0)=0x3C00");
        $display("    Expected all column outputs: FP4(2.0) = 0x4");
        $display("    Expected uio_out on odd FLUSH cycles: 0x40 ({y=0x4, 4'b0})");
        $display("");

        //---------------------------------------------------------------------
        // Reset
        //---------------------------------------------------------------------
        ena    = 1;
        rst_n  = 0;
        ui_in  = 8'h00;
        uio_in = 8'h00;
        repeat(2) @(posedge clk);
        rst_n = 1; #1;

        chk("RESET: uo_out=IDLE", uo_out, 8'h00);
        chk("RESET: uio_oe=0",   uio_oe, 8'h00);

        // ====================================================================
        $display("");
        $display("--- TEST 1: 1x3 (COL_CONFIG=2, K=2) ---");
        // ====================================================================

        //---------------------------------------------------------------------
        // IDLE: assert START
        //---------------------------------------------------------------------
        $display("-- IDLE: assert START --");
        ui_in  = 8'h01;   // START=1
        uio_in = 8'h00;
        tick;             // IDLE → CFG

        //---------------------------------------------------------------------
        // CFG: K_LEN=2, COL_CONFIG=2'b10 → uio_in[4:3]=2'b10=0x10
        //---------------------------------------------------------------------
        $display("-- CFG: K_LEN=2, COL_CONFIG=2 (1x3) --");
        chk("CFG uo_out",        uo_out, 8'h09);
        chk("CFG uio_oe",        uio_oe, 8'h00);
        ui_in  = 8'h02;   // K_LEN=2
        uio_in = 8'h10;   // COL_CONFIG=2'b10, RELU_EN=0, SKIP_BIAS=0
        tick;             // CFG → LOAD

        //---------------------------------------------------------------------
        // LOAD: 3 bias cycles (cnt=0,1,2); no scale loading
        // ld_bias[j] one-hot each cycle; bias_bus = {ui_in, uio_in} = 0x0000
        //---------------------------------------------------------------------
        $display("-- LOAD cnt=0: bias[0]=0x0000 → col0 --");
        chk("LOAD uo_out",       uo_out, 8'h0A);
        chk("LOAD uio_oe",       uio_oe, 8'h00);
        ui_in  = 8'h00;   // bias[15:8]
        uio_in = 8'h00;   // bias[7:0]  → FP16(+0.0)
        tick;

        $display("-- LOAD cnt=1: bias[1]=0x0000 → col1 --");
        ui_in  = 8'h00;
        uio_in = 8'h00;
        tick;

        $display("-- LOAD cnt=2: bias[2]=0x0000 → col2; exit → STREAM --");
        ui_in  = 8'h00;
        uio_in = 8'h00;
        tick;             // load_cnt_r==COL_CONFIG_r → STREAM

        //---------------------------------------------------------------------
        // STREAM: 4 cycles (cnt=0..3, stream_exit=K+COL_CONFIG-1=3)
        // V_PE_EN stagger: 001 → 011 → 110 → 100
        //---------------------------------------------------------------------
        $display("-- STREAM cnt=0: V_PE_EN=001; col0 1st MAC --");
        chk("STREAM uo_out",     uo_out, 8'h0B);
        chk("STREAM uio_oe",     uio_oe, 8'h00);
        ui_in  = 8'h22;   // {w_col0=0x2(1.0), a_row0=0x2(1.0)}
        uio_in = 8'h00;   // w_col1/col2 don't care (V_PE_EN[1:2]=0)
        tick;

        $display("-- STREAM cnt=1: V_PE_EN=011; col0 2nd, col1 1st MAC --");
        ui_in  = 8'h22;   // {w_col0=1.0, a_row0=1.0}
        uio_in = 8'h02;   // {w_col2=0x0, w_col1=0x2(1.0)}
        tick;

        $display("-- STREAM cnt=2: V_PE_EN=110; col1 2nd, col2 1st MAC --");
        ui_in  = 8'h00;   // a_row0/w_col0 don't care (H_PE_EN=0)
        uio_in = 8'h22;   // {w_col2=0x2(1.0), w_col1=0x2(1.0)}
        tick;

        $display("-- STREAM cnt=3: V_PE_EN=100; col2 2nd MAC; exit → FLUSH --");
        ui_in  = 8'h00;   // don't care
        uio_in = 8'h20;   // {w_col2=0x2(1.0), w_col1=0x0 (inactive)}
        tick;

        //---------------------------------------------------------------------
        // FLUSH: 6 cycles (flush_cnt=0..5 = 2*NCOLS)
        // Even: host drives scale, uio_oe=0x00, uo_out=0x0C
        // Odd:  chip drives y_out, uio_oe=0xFF, uio_out=0x40
        //---------------------------------------------------------------------
        $display("-- FLUSH cnt=0 (even): scale[col0]=0x3C00; uio_oe=0x00 --");
        chk("FLUSH0 uo_out",     uo_out, 8'h0C);
        chk("FLUSH0 uio_oe",     uio_oe, 8'h00);
        ui_in  = 8'h3C;   // scale[15:8] = 0x3C  (FP16(1.0)=0x3C00)
        uio_in = 8'h00;   // scale[7:0]  = 0x00
        tick;

        $display("-- FLUSH cnt=1 (odd):  y[col0] on uio_out[7:4]; uio_oe=0xFF --");
        chk("FLUSH1 uio_oe",     uio_oe, 8'hFF);
        chk("FLUSH1 uio_out",    uio_out,8'h40);  // {y[col0]=0x4, 4'b0}
        chk("FLUSH1 uo_out",     uo_out, 8'h5C);  // result_valid=1, flush_cnt[0]=1
        ui_in  = 8'h00;   // don't care (uio is output this cycle)
        uio_in = 8'h00;
        tick;

        $display("-- FLUSH cnt=2 (even): scale[col1]=0x3C00 --");
        chk("FLUSH2 uio_oe",     uio_oe, 8'h00);
        chk("FLUSH2 uo_out",     uo_out, 8'h0C);
        ui_in  = 8'h3C;
        uio_in = 8'h00;
        tick;

        $display("-- FLUSH cnt=3 (odd):  y[col1] on uio_out[7:4] --");
        chk("FLUSH3 uio_oe",     uio_oe, 8'hFF);
        chk("FLUSH3 uio_out",    uio_out,8'h40);  // {y[col1]=0x4, 4'b0}
        chk("FLUSH3 uo_out",     uo_out, 8'h5C);
        ui_in  = 8'h00;
        uio_in = 8'h00;
        tick;

        $display("-- FLUSH cnt=4 (even): scale[col2]=0x3C00 --");
        chk("FLUSH4 uio_oe",     uio_oe, 8'h00);
        chk("FLUSH4 uo_out",     uo_out, 8'h0C);
        ui_in  = 8'h3C;
        uio_in = 8'h00;
        tick;

        $display("-- FLUSH cnt=5 (odd, last): y[col2]; tile_done → IDLE --");
        chk("FLUSH5 uio_oe",     uio_oe, 8'hFF);
        chk("FLUSH5 uio_out",    uio_out,8'h40);  // {y[col2]=0x4, 4'b0}
        chk("FLUSH5 uo_out",     uo_out, 8'h7C);  // tile_done=1, result_valid=1
        ui_in  = 8'h00;
        uio_in = 8'h00;
        tick;

        $display("-- Back to IDLE --");
        chk("1x3 IDLE uo_out",   uo_out, 8'h00);
        chk("1x3 IDLE uio_oe",   uio_oe, 8'h00);

        // ====================================================================
        $display("");
        $display("--- TEST 2: 1x2 (COL_CONFIG=1, K=2) ---");
        // ====================================================================
        // LOAD:   2 cycles (cnt=0,1)
        // STREAM: 3 cycles (cnt=0..2, stream_exit=K+COL_CONFIG-1=2)
        //   cnt=0: V_PE_EN=001  cnt=1: V_PE_EN=011  cnt=2: V_PE_EN=010 (tail)
        // FLUSH:  4 cycles (flush_cnt=0..3, flush_exit={1'b01,1'b1}=3)

        ui_in  = 8'h01; uio_in = 8'h00; tick;  // IDLE → CFG

        chk("1x2 CFG uo_out",    uo_out, 8'h09);
        ui_in  = 8'h02;   // K_LEN=2
        uio_in = 8'h08;   // COL_CONFIG=2'b01 (uio_in[4:3]=01 → bit3=1)
        tick;             // CFG → LOAD

        chk("1x2 LOAD uo_out",   uo_out, 8'h0A);
        // LOAD cnt=0: bias[0]
        ui_in = 8'h00; uio_in = 8'h00; tick;
        // LOAD cnt=1 (=COL_CONFIG_r=1): bias[1]; exit → STREAM
        ui_in = 8'h00; uio_in = 8'h00; tick;

        chk("1x2 STREAM uo_out", uo_out, 8'h0B);
        // cnt=0: col0 only active
        ui_in = 8'h22; uio_in = 8'h00; tick;
        // cnt=1: col0 2nd, col1 1st MAC
        ui_in = 8'h22; uio_in = 8'h02; tick;   // w_col1=1.0
        // cnt=2 (stream_exit): col1 2nd MAC (tail); exit → FLUSH
        ui_in = 8'h00; uio_in = 8'h02; tick;   // w_col1=1.0

        $display("-- 1x2 FLUSH (4 cycles) --");
        // flush_cnt=0 (even): scale[col0]
        chk("1x2 FLUSH0 uio_oe",  uio_oe, 8'h00);
        chk("1x2 FLUSH0 uo_out",  uo_out, 8'h0C);
        ui_in = 8'h3C; uio_in = 8'h00; tick;

        // flush_cnt=1 (odd): y[col0]
        chk("1x2 FLUSH1 uio_oe",  uio_oe, 8'hFF);
        chk("1x2 FLUSH1 uio_out", uio_out,8'h40);
        chk("1x2 FLUSH1 uo_out",  uo_out, 8'h5C);
        ui_in = 8'h00; uio_in = 8'h00; tick;

        // flush_cnt=2 (even): scale[col1]
        chk("1x2 FLUSH2 uio_oe",  uio_oe, 8'h00);
        chk("1x2 FLUSH2 uo_out",  uo_out, 8'h0C);
        ui_in = 8'h3C; uio_in = 8'h00; tick;

        // flush_cnt=3 (odd, last): y[col1]; tile_done
        chk("1x2 FLUSH3 uio_oe",  uio_oe, 8'hFF);
        chk("1x2 FLUSH3 uio_out", uio_out,8'h40);
        chk("1x2 FLUSH3 uo_out",  uo_out, 8'h7C);
        ui_in = 8'h00; uio_in = 8'h00; tick;

        chk("1x2 IDLE uo_out",    uo_out, 8'h00);

        // ====================================================================
        $display("");
        $display("--- TEST 3: 1x1 (COL_CONFIG=0, K=2) ---");
        // ====================================================================
        // LOAD:   1 cycle  (cnt=0; bias[0]; exit when cnt==COL_CONFIG_r=0)
        // STREAM: 2 cycles (cnt=0..1; stream_exit=K+COL_CONFIG-1=1)
        // FLUSH:  2 cycles (flush_cnt=0..1; flush_exit={2'b00,1'b1}=1)

        ui_in  = 8'h01; uio_in = 8'h00; tick;  // IDLE → CFG

        chk("1x1 CFG uo_out",    uo_out, 8'h09);
        ui_in  = 8'h02;   // K_LEN=2
        uio_in = 8'h00;   // COL_CONFIG=2'b00, all flags 0
        tick;             // CFG → LOAD

        chk("1x1 LOAD uo_out",   uo_out, 8'h0A);
        // LOAD cnt=0 (=COL_CONFIG_r=0): bias[0]; exit → STREAM
        ui_in = 8'h00; uio_in = 8'h00; tick;

        chk("1x1 STREAM uo_out", uo_out, 8'h0B);
        // cnt=0: col0 active (pe_en_0=1, 0<2)
        ui_in = 8'h22; uio_in = 8'h00; tick;
        // cnt=1 (stream_exit=1): col0 2nd MAC; pe_en_0=1 (1<2); exit → FLUSH
        ui_in = 8'h22; uio_in = 8'h00; tick;

        $display("-- 1x1 FLUSH (2 cycles) --");
        // flush_cnt=0 (even): scale[col0]
        chk("1x1 FLUSH0 uio_oe",  uio_oe, 8'h00);
        chk("1x1 FLUSH0 uo_out",  uo_out, 8'h0C);
        ui_in = 8'h3C; uio_in = 8'h00; tick;

        // flush_cnt=1 (odd, last): y[col0]; tile_done
        chk("1x1 FLUSH1 uio_oe",  uio_oe, 8'hFF);
        chk("1x1 FLUSH1 uio_out", uio_out,8'h40);
        chk("1x1 FLUSH1 uo_out",  uo_out, 8'h7C);
        ui_in = 8'h00; uio_in = 8'h00; tick;

        chk("1x1 IDLE uo_out",    uo_out, 8'h00);

        //---------------------------------------------------------------------
        // Summary
        //---------------------------------------------------------------------
        $display("");
        $display("=== %0d passed, %0d failed ===", pass_cnt, fail_cnt);
        $display(fail_cnt == 0 ? "ALL PASS" : "FAILURES DETECTED");
        $stop;
    end

    // Watchdog: 100 cycles is more than enough for all 3 tests
    initial begin
        #(CLK_PERIOD * 100);
        $display("TIMEOUT");
        $stop;
    end

endmodule