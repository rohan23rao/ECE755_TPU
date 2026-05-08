///////////////////////////////////////////////////////////////////////////////
// Module: tb_tt_um_gemm_top.sv
// Description: Interface and timing verification testbench for the
//              FP4 GEMM Tiny Tapeout 1x2 design (single-VU, DRAIN handshake).
//
// Three test cases:
//   Test 1: 1x2 full LOAD  (COL_CONFIG=1, K=2, bias=0, scale=1.0 per DRAIN)
//   Test 2: 1x2 SKIP_BIAS  (CFG→STREAM directly; acc retains Test 1 result)
//   Test 3: 1x1 full LOAD  (COL_CONFIG=0, K=2, bias=0, scale=1.0 per DRAIN)
//
// Common data values:
//   A = W = FP4(1.0) = 0x2
//   bias = FP16(0.0)  = 0x0000
//   scale = FP16(1.0) = 0x3C00   (driven by host during each DRAIN SCALE_LOAD)
//
// Test 1 expected:
//   acc[col0,col1] = 0 + 1.0 + 1.0 = FP16(2.0) = 0x4000
//   y = scale * acc = FP4(2.0) = 0x4 for both columns
//
// Test 2 expected (SKIP_BIAS — acc retains 2.0 from Test 1):
//   acc[col0,col1] = 2.0 + 1.0 + 1.0 = FP16(4.0) = 0x4400
//   y = FP4(4.0) = 0x6 for both columns
//
// Test 3 expected (1x1; col1 result is don't-care):
//   LOAD resets col0 bias to 0 only (ld_bias[0]; col1 unchanged from Test 2)
//   acc[col0] = 0 + 1.0 + 1.0 = FP16(2.0);  y[col0] = FP4(2.0) = 0x4
//   acc[col1] = 4.0 (leftover, not reset);    y[col1] = FP4(4.0) = 0x6 (don't check)
//
// DRAIN protocol per column (new single-VU handshake):
//   Phase 0 SCALE_LOAD (1 cycle, unconditional):
//     uo_out[4]=1, uo_out[5]=0, uio_oe=0x00
//     Host drives scale on {ui_in[7:0], uio_in[7:0]}
//     quant_en fires; VU result captured at posedge
//   Phase 1 RESULT_HOLD (variable, stalls until Y_ACK = ui_in[0]):
//     uo_out[4]=1, uo_out[5]=1, uio_oe=0xFF
//     uio_out = {4'b0, y_out}
//     Host asserts ui_in[0]=1 to ACK and advance
//
// uo_out encoding:
//   [2:0]=state, [3]=busy, [4]=drain_active, [5]=drain_phase, [6]=tile_done, [7]=drain_col
//   IDLE=0x00, CFG=0x09, LOAD=0x0A, STREAM=0x0B
//   scale_col0=0x1C, result_col0=0x3C
//   scale_col1=0x9C, result_col1=0xBC, tile_done=0xFC
//
// CFG uio_in encoding:
//   [0]   = RELU_EN
//   [1]   = SKIP_BIAS   (CFG → STREAM directly, no LOAD)
//   [4:3] = COL_CONFIG  (00=1x1, 01=1x2)
//   1x2 full : uio_in=0x08
//   1x2 SKIP_BIAS: uio_in=0x0A
//   1x1 full : uio_in=0x00
//
// Pin mapping (streaming, from gemm_top):
//   ui_in[3:0]  = A_DATA (activation row 0)
//   ui_in[7:4]  = W_DATA col 0
//   uio_in[3:0] = W_DATA col 1
//   ui_in[7:0]  = scale[15:8] during SCALE_LOAD
//   uio_in[7:0] = scale[7:0]  during SCALE_LOAD
//   uio_in[7:0] = bias[7:0]   during LOAD
//   ui_in[7:0]  = bias[15:8]  during LOAD
//   ui_in[0]    = TILE_START (IDLE) / Y_ACK (DRAIN RESULT_HOLD)
//
// Author: Group5
///////////////////////////////////////////////////////////////////////////////

module tb_tt_um_gemm_top;

    localparam CLK_PERIOD = 10;

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
            $display("  PASS  %-36s  got=0x%02h", lbl, got);
            pass_cnt++;
        end else begin
            $display("  FAIL  %-36s  got=0x%02h  exp=0x%02h", lbl, got, exp);
            fail_cnt++;
        end
    endtask

    //=========================================================================
    // Test stimulus
    //=========================================================================
    initial begin
        $dumpfile("tb_tt_um_gemm_top.vcd");
        $dumpvars(0, tb_tt_um_gemm_top);

        $display("=== tt_um_gemm_top: single-VU DRAIN handshake TB ===");
        $display("    K=2, A=W=FP4(1.0)=0x2, bias=0x0000, scale=FP16(1.0)=0x3C00");
        $display("    Test1: y=FP4(2.0)=0x4 | Test2(SKIP_BIAS): y=FP4(4.0)=0x6");
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
        chk("RESET: uio_oe=0",   uio_oe,  8'h00);

        // ====================================================================
        $display("");
        $display("--- TEST 1: 1x2 full LOAD, K=2, scale=1.0 per DRAIN ---");
        // ====================================================================

        //---------------------------------------------------------------------
        // IDLE → CFG
        //---------------------------------------------------------------------
        ui_in  = 8'h01;   // TILE_START = ui_in[0]
        uio_in = 8'h00;
        tick;             // posedge: IDLE → CFG

        //---------------------------------------------------------------------
        // CFG: K_LEN=2, COL_CONFIG=1, no flags
        //   uio_in[4:3]=01 (COL_CONFIG=1); ui_in=K_LEN=2
        //---------------------------------------------------------------------
        chk("T1 CFG uo_out",  uo_out, 8'h09);
        chk("T1 CFG uio_oe",  uio_oe, 8'h00);
        ui_in  = 8'h02;   // K_LEN = 2
        uio_in = 8'h08;   // COL_CONFIG=01, SKIP_BIAS=0, RELU_EN=0
        tick;             // posedge: config captured, CFG → LOAD

        //---------------------------------------------------------------------
        // LOAD: bias-only, 2 cycles (cnt=0: bias[col0], cnt=1: bias[col1])
        //   bias = FP16(0.0) = 0x0000 → {ui_in=0x00, uio_in=0x00}
        //   exit: load_cnt == COL_CONFIG_r = 1
        //---------------------------------------------------------------------
        $display("-- LOAD cnt=0: bias[col0]=0x0000 --");
        chk("T1 LOAD uo_out",  uo_out, 8'h0A);
        chk("T1 LOAD uio_oe",  uio_oe, 8'h00);
        ui_in  = 8'h00;   // bias[15:8] = 0
        uio_in = 8'h00;   // bias[7:0]  = 0
        tick;             // posedge: ld_bias[0] fires, acc_q[col0] ← 0

        $display("-- LOAD cnt=1: bias[col1]=0x0000; exit → STREAM --");
        ui_in  = 8'h00;
        uio_in = 8'h00;
        tick;             // posedge: ld_bias[1] fires, acc_q[col1] ← 0; → STREAM

        //---------------------------------------------------------------------
        // STREAM: 3 cycles (stream_exit = K+COL_CONFIG-1 = 2)
        //   cnt=0: H_PE_EN=1, V_PE_EN=01; col0 1st MAC (acc0=1.0 at posedge)
        //   cnt=1: H_PE_EN=1, V_PE_EN=11; col0 2nd MAC (acc0=2.0), col1 1st MAC (acc1=1.0)
        //   cnt=2: H_PE_EN=0, V_PE_EN=10; col1 2nd MAC (acc1=2.0); exit → DRAIN
        // Pin map: ui_in[3:0]=A, ui_in[7:4]=W[col0], uio_in[3:0]=W[col1]
        //---------------------------------------------------------------------
        $display("-- STREAM cnt=0: V_PE_EN=01; col0 1st MAC --");
        chk("T1 STREAM uo_out", uo_out, 8'h0B);
        chk("T1 STREAM uio_oe", uio_oe, 8'h00);
        ui_in  = 8'h22;   // W[col0]=0x2(1.0) | A=0x2(1.0)
        uio_in = 8'h00;   // W[col1] don't care (V_PE_EN[1]=0)
        tick;

        $display("-- STREAM cnt=1: V_PE_EN=11; col0 2nd MAC, col1 1st MAC --");
        ui_in  = 8'h22;
        uio_in = 8'h02;   // W[col1]=0x2(1.0)
        tick;

        $display("-- STREAM cnt=2: V_PE_EN=10; col1 2nd MAC; exit → DRAIN --");
        ui_in  = 8'h00;   // H_PE_EN=0
        uio_in = 8'h02;   // W[col1]=1.0 (tail cycle)
        tick;             // posedge: acc_q[col1]=2.0 latched; state → DRAIN

        //---------------------------------------------------------------------
        // DRAIN col0:
        //   SCALE_LOAD: host drives scale=FP16(1.0)=0x3C00; quant_en fires
        //   RESULT_HOLD: device drives y[col0]=0x4; host ACKs
        //---------------------------------------------------------------------
        $display("-- DRAIN SCALE_LOAD col0: host drives scale=0x3C00 --");
        chk("T1 scale_col0 uo_out", uo_out, 8'h1C);   // drain_col=0,phase=0
        chk("T1 scale_col0 uio_oe", uio_oe, 8'h00);   // host driving
        ui_in  = 8'h3C;   // scale[15:8]=0x3C; ui_in[0]=0 (no Y_ACK)
        uio_in = 8'h00;   // scale[7:0]=0x00  → scale=0x3C00=FP16(1.0)
        tick;             // posedge: quant_en fires; y[col0]=FP4(1.0*2.0)=0x4 captured; phase → RESULT_HOLD

        $display("-- DRAIN RESULT_HOLD col0: y[col0]=0x4; wait for Y_ACK --");
        chk("T1 result_col0 uo_out",  uo_out,  8'h3C);   // drain_col=0,phase=1
        chk("T1 result_col0 uio_oe",  uio_oe,  8'hFF);
        chk("T1 result_col0 uio_out", uio_out, 8'h04);   // {4'b0, y=0x4}
        ui_in  = 8'h01;   // Y_ACK
        uio_in = 8'h00;
        tick;             // posedge: drain_col → 1, drain_phase → 0 (SCALE_LOAD col1)

        //---------------------------------------------------------------------
        // DRAIN col1:
        //---------------------------------------------------------------------
        $display("-- DRAIN SCALE_LOAD col1: host drives scale=0x3C00 --");
        chk("T1 scale_col1 uo_out", uo_out, 8'h9C);   // drain_col=1,phase=0
        chk("T1 scale_col1 uio_oe", uio_oe, 8'h00);
        ui_in  = 8'h3C;   // scale=1.0; ui_in[0]=0 (no Y_ACK)
        uio_in = 8'h00;
        tick;             // posedge: quant_en fires; y[col1]=FP4(1.0*2.0)=0x4 captured; phase → RESULT_HOLD

        $display("-- DRAIN RESULT_HOLD col1: y[col1]=0x4; ACK → tile_done --");
        chk("T1 result_col1 uo_out",  uo_out,  8'hBC);   // drain_col=1,phase=1
        chk("T1 result_col1 uio_oe",  uio_oe,  8'hFF);
        chk("T1 result_col1 uio_out", uio_out, 8'h04);   // {4'b0, y=0x4}
        ui_in  = 8'h01;   // Y_ACK
        uio_in = 8'h00;
        #1;               // settle: tile_done fires combinationally
        chk("T1 tile_done uo_out",    uo_out,  8'hFC);   // tile_done=1 visible before posedge
        tick;             // posedge: → IDLE

        $display("-- Back to IDLE --");
        chk("T1 IDLE uo_out", uo_out, 8'h00);
        chk("T1 IDLE uio_oe", uio_oe, 8'h00);

        // ====================================================================
        $display("");
        $display("--- TEST 2: 1x2 SKIP_BIAS (CFG→STREAM; acc retains Test1=2.0) ---");
        $display("    acc starts at 2.0; K=2 MACs → acc=4.0; y=FP4(4.0)=0x6");
        // ====================================================================

        //---------------------------------------------------------------------
        // IDLE → CFG
        //---------------------------------------------------------------------
        ui_in  = 8'h01;   // TILE_START
        uio_in = 8'h00;
        tick;             // IDLE → CFG

        //---------------------------------------------------------------------
        // CFG: COL_CONFIG=1, SKIP_BIAS=1 → next_state = STREAM (no LOAD)
        //   uio_in[4:3]=01 (COL_CONFIG=1), uio_in[1]=1 (SKIP_BIAS)
        //   uio_in = 0x0A = 0b00001010
        //---------------------------------------------------------------------
        chk("T2 CFG uo_out", uo_out, 8'h09);
        ui_in  = 8'h02;   // K_LEN=2
        uio_in = 8'h0A;   // COL_CONFIG=01, SKIP_BIAS=1
        tick;             // posedge: config captured, CFG → STREAM (LOAD skipped)

        //---------------------------------------------------------------------
        // STREAM: same 3 cycles; acc starts from 2.0 (no bias reset)
        //---------------------------------------------------------------------
        $display("-- STREAM (LOAD skipped; acc[col0,col1]=2.0 retained) --");
        chk("T2 STREAM uo_out", uo_out, 8'h0B);
        chk("T2 STREAM uio_oe", uio_oe, 8'h00);
        ui_in  = 8'h22; uio_in = 8'h00; tick;   // cnt=0
        ui_in  = 8'h22; uio_in = 8'h02; tick;   // cnt=1
        ui_in  = 8'h00; uio_in = 8'h02; tick;   // cnt=2 → DRAIN; acc=4.0 both cols

        //---------------------------------------------------------------------
        // DRAIN col0: y = FP4(1.0 * 4.0) = FP4(4.0) = 0x6
        //---------------------------------------------------------------------
        $display("-- DRAIN SCALE_LOAD col0 --");
        chk("T2 scale_col0 uo_out", uo_out, 8'h1C);
        chk("T2 scale_col0 uio_oe", uio_oe, 8'h00);
        ui_in  = 8'h3C; uio_in = 8'h00;
        tick;

        $display("-- DRAIN RESULT_HOLD col0: y=FP4(4.0)=0x6 --");
        chk("T2 result_col0 uo_out",  uo_out,  8'h3C);
        chk("T2 result_col0 uio_oe",  uio_oe,  8'hFF);
        chk("T2 result_col0 uio_out", uio_out, 8'h06);   // {4'b0, y=0x6}
        ui_in  = 8'h01; uio_in = 8'h00;
        tick;

        //---------------------------------------------------------------------
        // DRAIN col1: same expected output
        //---------------------------------------------------------------------
        $display("-- DRAIN SCALE_LOAD col1 --");
        chk("T2 scale_col1 uo_out", uo_out, 8'h9C);
        chk("T2 scale_col1 uio_oe", uio_oe, 8'h00);
        ui_in  = 8'h3C; uio_in = 8'h00;
        tick;

        $display("-- DRAIN RESULT_HOLD col1: y=FP4(4.0)=0x6 --");
        chk("T2 result_col1 uo_out",  uo_out,  8'hBC);
        chk("T2 result_col1 uio_oe",  uio_oe,  8'hFF);
        chk("T2 result_col1 uio_out", uio_out, 8'h06);
        ui_in  = 8'h01; uio_in = 8'h00;
        #1;
        chk("T2 tile_done uo_out",    uo_out,  8'hFC);
        tick;

        chk("T2 IDLE uo_out", uo_out, 8'h00);

        // ====================================================================
        $display("");
        $display("--- TEST 3: 1x1 full LOAD (COL_CONFIG=0, K=2) ---");
        $display("    LOAD: 1 cycle (bias[col0] only); col1 acc unchanged (4.0)");
        $display("    DRAIN: col0 expected 0x4; col1 output is don't-care (1x1)");
        // ====================================================================

        //---------------------------------------------------------------------
        // IDLE → CFG
        //---------------------------------------------------------------------
        ui_in  = 8'h01;
        uio_in = 8'h00;
        tick;

        //---------------------------------------------------------------------
        // CFG: COL_CONFIG=0, no flags
        //---------------------------------------------------------------------
        chk("T3 CFG uo_out", uo_out, 8'h09);
        ui_in  = 8'h02;   // K_LEN=2
        uio_in = 8'h00;   // COL_CONFIG=00, all flags=0
        tick;             // CFG → LOAD

        //---------------------------------------------------------------------
        // LOAD: 1 cycle only (exit: load_cnt==COL_CONFIG_r==0)
        //   cnt=0: ld_bias[0] fires; acc_q[col0] ← 0
        //---------------------------------------------------------------------
        $display("-- LOAD cnt=0: bias[col0]=0x0000; exit → STREAM (1 cycle) --");
        chk("T3 LOAD uo_out", uo_out, 8'h0A);
        chk("T3 LOAD uio_oe", uio_oe, 8'h00);
        ui_in  = 8'h00;   // bias=0x0000
        uio_in = 8'h00;
        tick;             // posedge: ld_bias[0] fires; load_cnt=0==COL_CONFIG_r=0 → STREAM

        //---------------------------------------------------------------------
        // STREAM: 2 cycles (stream_exit = K+COL_CONFIG-1 = 1)
        //   V_PE_EN[1] disabled (COL_CONFIG=0 → pe_en_1 gated off)
        //   cnt=0: col0 1st MAC; cnt=1: col0 2nd MAC; exit → DRAIN
        //---------------------------------------------------------------------
        $display("-- STREAM cnt=0: col0 1st MAC --");
        chk("T3 STREAM uo_out", uo_out, 8'h0B);
        ui_in  = 8'h22; uio_in = 8'h00; tick;

        $display("-- STREAM cnt=1: col0 2nd MAC; exit → DRAIN --");
        ui_in  = 8'h22; uio_in = 8'h00; tick;   // acc_q[col0]=2.0 at posedge; → DRAIN

        //---------------------------------------------------------------------
        // DRAIN col0: y = FP4(1.0 * 2.0) = 0x4
        //---------------------------------------------------------------------
        $display("-- DRAIN SCALE_LOAD col0 --");
        chk("T3 scale_col0 uo_out", uo_out, 8'h1C);
        chk("T3 scale_col0 uio_oe", uio_oe, 8'h00);
        ui_in  = 8'h3C; uio_in = 8'h00;
        tick;

        $display("-- DRAIN RESULT_HOLD col0: y=FP4(2.0)=0x4 --");
        chk("T3 result_col0 uo_out",  uo_out,  8'h3C);
        chk("T3 result_col0 uio_oe",  uio_oe,  8'hFF);
        chk("T3 result_col0 uio_out", uio_out, 8'h04);
        ui_in  = 8'h01; uio_in = 8'h00;
        tick;

        //---------------------------------------------------------------------
        // DRAIN col1 (1x1 design — col1 acc is leftover 4.0 from Test 2)
        // Hardware still cycles through col1; result is don't-care for 1x1.
        // SCALE_LOAD and RESULT_HOLD col1 still happen — only check uo_out/uio_oe.
        //---------------------------------------------------------------------
        $display("-- DRAIN SCALE_LOAD col1 (don't-care for 1x1) --");
        chk("T3 scale_col1 uo_out", uo_out, 8'h9C);
        chk("T3 scale_col1 uio_oe", uio_oe, 8'h00);
        ui_in  = 8'h3C; uio_in = 8'h00;
        tick;

        $display("-- DRAIN RESULT_HOLD col1: result don't-care; ACK → tile_done --");
        chk("T3 result_col1 uo_out", uo_out,  8'hBC);
        chk("T3 result_col1 uio_oe", uio_oe,  8'hFF);
        // uio_out not checked for 1x1 col1
        ui_in  = 8'h01; uio_in = 8'h00;
        #1;
        chk("T3 tile_done uo_out",   uo_out,  8'hFC);
        tick;

        chk("T3 IDLE uo_out", uo_out, 8'h00);
        chk("T3 IDLE uio_oe", uio_oe, 8'h00);

        //---------------------------------------------------------------------
        // Summary
        //---------------------------------------------------------------------
        $display("");
        $display("=== %0d passed, %0d failed ===", pass_cnt, fail_cnt);
        $display(fail_cnt == 0 ? "ALL PASS" : "FAILURES DETECTED");
        $stop;
    end

    // Watchdog: 100 cycles covers all 3 tests with margin
    initial begin
        #(CLK_PERIOD * 100);
        $display("TIMEOUT");
        $stop;
    end

endmodule