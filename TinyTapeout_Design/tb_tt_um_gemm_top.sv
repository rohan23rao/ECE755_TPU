///////////////////////////////////////////////////////////////////////////////
// Module: tb_tt_um_gemm_top.sv
// Description: Interface and timing verification testbench for the
//              FP4 GEMM Tiny Tapeout 1x2 design (hardcoded 1x2, single-VU).
//
// Three test cases:
//   Test 1: 1x2 full LOAD  (K=2, bias=0, scale=1.0 per DRAIN)
//   Test 2: 1x2 SKIP_BIAS  (CFG→STREAM; acc retains Test 1 result)
//   Test 3: 1x2 RELU_EN    (K=2, W_col0 negative → RELU clamps col0 to 0)
//
// Common values:
//   A = FP4(1.0) = 0x2,  bias = FP16(0.0) = 0x0000
//   scale = FP16(1.0) = 0x3C00  (driven during each DRAIN SCALE_LOAD)
//
// Test 1 expected:
//   acc = 0 + 1.0 + 1.0 = FP16(2.0);  y = FP4(2.0) = 0x4 both cols
//
// Test 2 expected (SKIP_BIAS, acc retains 2.0 from Test 1):
//   acc = 2.0 + 1.0 + 1.0 = FP16(4.0);  y = FP4(4.0) = 0x6 both cols
//
// Test 3 expected (RELU_EN, fresh bias load):
//   W_col0 = FP4(-1.0) = 0xA → acc[col0] = -2.0 → RELU → 0  → y[col0]=0x0
//   W_col1 = FP4(+1.0) = 0x2 → acc[col1] = +2.0 → RELU → 2.0 → y[col1]=0x4
//
// DRAIN protocol (per column):
//   SCALE_LOAD (1 cycle unconditional):
//     uo_out[4]=1, uo_out[5]=0, uio_oe=0x00
//     Host drives scale on {ui_in[7:0], uio_in[7:0]}; quant_en fires.
//   RESULT_HOLD (stall until Y_ACK = ui_in[0]):
//     uo_out[4]=1, uo_out[5]=1, uio_oe=0xFF, uio_out={4'b0, y_out}
//
// uo_out encoding:
//   [2:0]=state  [3]=busy  [4]=drain_active  [5]=drain_phase
//   [6]=tile_done  [7]=drain_col
//   IDLE=0x00  CFG=0x09  LOAD=0x0A  STREAM=0x0B
//   scale_col0=0x1C  result_col0=0x3C
//   scale_col1=0x9C  result_col1=0xBC  tile_done=0xFC
//
// CFG uio_in encoding (COL_CONFIG removed — hardcoded 1x2):
//   [0] = RELU_EN
//   [1] = SKIP_BIAS  (CFG → STREAM directly, no LOAD)
//   [4:3] free (was COL_CONFIG)
//   No flags:   uio_in = 0x00
//   SKIP_BIAS:  uio_in = 0x02
//   RELU_EN:    uio_in = 0x01
//
// CFG ui_in: ui_in[3:0] = K_LEN (max K=15; upper nibble unused)
//
// STREAM pin mapping:
//   ui_in[3:0]  = a_row0 (FP4 activation)
//   ui_in[7:4]  = w_col0 (FP4 weight col 0)
//   uio_in[3:0] = w_col1 (FP4 weight col 1)
//   uio_in[5]   = DATA_VLD  (must be 1 for valid data cycles)
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

        $display("=== tt_um_gemm_top: 1x2 hardcoded, single-VU DRAIN handshake TB ===");
        $display("    K=2, A=W=FP4(1.0)=0x2, bias=0x0000, scale=FP16(1.0)=0x3C00");
        $display("    Test1: y=0x4 | Test2(SKIP_BIAS): y=0x6 | Test3(RELU): y=0x0/0x4");
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
        ui_in  = 8'h01;   // TILE_START
        uio_in = 8'h00;
        tick;             // posedge: IDLE → CFG

        //---------------------------------------------------------------------
        // CFG: K_LEN=2, no flags (COL_CONFIG removed — hardcoded 1x2)
        //   ui_in[3:0] = K_LEN = 2;  uio_in = 0x00 (RELU_EN=0, SKIP_BIAS=0)
        //---------------------------------------------------------------------
        chk("T1 CFG uo_out",  uo_out, 8'h09);
        chk("T1 CFG uio_oe",  uio_oe, 8'h00);
        ui_in  = 8'h02;   // K_LEN=2 in [3:0]; upper nibble unused in CFG
        uio_in = 8'h00;   // no flags
        tick;             // posedge: config captured, CFG → LOAD

        //---------------------------------------------------------------------
        // LOAD: 2 cycles (hardcoded 1x2: always bias[col0] then bias[col1])
        //---------------------------------------------------------------------
        $display("-- LOAD cnt=0: bias[col0]=0x0000 --");
        chk("T1 LOAD uo_out",  uo_out, 8'h0A);
        chk("T1 LOAD uio_oe",  uio_oe, 8'h00);
        ui_in  = 8'h00;   // bias[15:8] = 0
        uio_in = 8'h00;   // bias[7:0]  = 0
        tick;             // posedge: ld_bias[0], acc_q[col0] ← 0

        $display("-- LOAD cnt=1: bias[col1]=0x0000; exit → STREAM --");
        ui_in  = 8'h00;
        uio_in = 8'h00;
        tick;             // posedge: ld_bias[1], acc_q[col1] ← 0; → STREAM

        //---------------------------------------------------------------------
        // STREAM: 3 valid cycles (stream_exit = K_LEN_r = 2; cnt 0..2)
        //   cnt=0: pe_en[0]=1, pe_en[1]=0; col0 1st MAC  (acc0=1.0)
        //   cnt=1: pe_en[0]=1, pe_en[1]=1; col0 2nd MAC  (acc0=2.0)
        //                                   col1 1st MAC  (acc1=1.0)
        //   cnt=2: pe_en[0]=0, pe_en[1]=1; col1 2nd MAC  (acc1=2.0) — tail
        //   uio_in[5]=1 on all cycles (DATA_VLD)
        // Pin map: ui_in[3:0]=A, ui_in[7:4]=W_col0, uio_in[3:0]=W_col1
        //---------------------------------------------------------------------
        $display("-- STREAM cnt=0: pe_en[0]=1; col0 1st MAC --");
        chk("T1 STREAM uo_out", uo_out, 8'h0B);
        chk("T1 STREAM uio_oe", uio_oe, 8'h00);
        ui_in  = 8'h22;   // W_col0=0x2(1.0) | A=0x2(1.0)
        uio_in = 8'h20;   // DATA_VLD=1, W_col1 don't care (pe_en[1]=0)
        tick;

        $display("-- STREAM cnt=1: pe_en=11; col0 2nd MAC + col1 1st MAC --");
        ui_in  = 8'h22;   // W_col0=1.0, A=1.0
        uio_in = 8'h22;   // DATA_VLD=1, W_col1=1.0
        tick;

        $display("-- STREAM cnt=2: pe_en[1]=1 only; col1 2nd MAC (tail) --");
        ui_in  = 8'h00;   // pe_en[0]=0; A/W_col0 don't care
        uio_in = 8'h22;   // DATA_VLD=1, W_col1=1.0 (tail)
        tick;             // posedge: acc_q[col1]=2.0; → DRAIN

        //---------------------------------------------------------------------
        // DRAIN col0: y = FP4(scale=1.0 × acc=2.0) = FP4(2.0) = 0x4
        //---------------------------------------------------------------------
        $display("-- DRAIN SCALE_LOAD col0: host drives scale=0x3C00 --");
        chk("T1 scale_col0 uo_out", uo_out, 8'h1C);
        chk("T1 scale_col0 uio_oe", uio_oe, 8'h00);
        ui_in  = 8'h3C;   // scale[15:8]=0x3C; ui_in[0]=0 (no Y_ACK)
        uio_in = 8'h00;   // scale[7:0]=0x00 → scale=0x3C00=FP16(1.0)
        tick;             // posedge: quant_en, y[col0]=FP4(1.0×2.0)=0x4; phase→RESULT_HOLD

        $display("-- DRAIN RESULT_HOLD col0: y=0x4; Y_ACK --");
        chk("T1 result_col0 uo_out",  uo_out,  8'h3C);
        chk("T1 result_col0 uio_oe",  uio_oe,  8'hFF);
        chk("T1 result_col0 uio_out", uio_out, 8'h04);   // {4'b0, y=0x4}
        ui_in  = 8'h01;   // Y_ACK
        uio_in = 8'h00;
        tick;             // posedge: drain_col→1, drain_phase→0

        //---------------------------------------------------------------------
        // DRAIN col1: y = FP4(2.0) = 0x4
        //---------------------------------------------------------------------
        $display("-- DRAIN SCALE_LOAD col1: host drives scale=0x3C00 --");
        chk("T1 scale_col1 uo_out", uo_out, 8'h9C);
        chk("T1 scale_col1 uio_oe", uio_oe, 8'h00);
        ui_in  = 8'h3C;   // scale=1.0; ui_in[0]=0
        uio_in = 8'h00;
        tick;             // posedge: quant_en, y[col1]=0x4; phase→RESULT_HOLD

        $display("-- DRAIN RESULT_HOLD col1: y=0x4; ACK → tile_done --");
        chk("T1 result_col1 uo_out",  uo_out,  8'hBC);
        chk("T1 result_col1 uio_oe",  uio_oe,  8'hFF);
        chk("T1 result_col1 uio_out", uio_out, 8'h04);
        ui_in  = 8'h01; uio_in = 8'h00;
        #1;
        chk("T1 tile_done uo_out",    uo_out,  8'hFC);
        tick;             // posedge: → IDLE

        $display("-- Back to IDLE --");
        chk("T1 IDLE uo_out", uo_out, 8'h00);
        chk("T1 IDLE uio_oe", uio_oe, 8'h00);

        // ====================================================================
        $display("");
        $display("--- TEST 2: 1x2 SKIP_BIAS (CFG→STREAM; acc retains Test1=2.0) ---");
        $display("    acc = 2.0 + 1.0 + 1.0 = 4.0; y = FP4(4.0) = 0x6");
        // ====================================================================

        //---------------------------------------------------------------------
        // IDLE → CFG
        //---------------------------------------------------------------------
        ui_in  = 8'h01;
        uio_in = 8'h00;
        tick;

        //---------------------------------------------------------------------
        // CFG: SKIP_BIAS=1 → CFG exits directly to STREAM, LOAD skipped
        //   uio_in = 0x02 (SKIP_BIAS=1; COL_CONFIG field removed)
        //---------------------------------------------------------------------
        chk("T2 CFG uo_out", uo_out, 8'h09);
        ui_in  = 8'h02;   // K_LEN=2
        uio_in = 8'h02;   // SKIP_BIAS=1
        tick;             // posedge: CFG → STREAM (no LOAD)

        //---------------------------------------------------------------------
        // STREAM: acc starts at 2.0 (retained from Test 1, no bias reset)
        //---------------------------------------------------------------------
        $display("-- STREAM (LOAD skipped; acc retained at 2.0) --");
        chk("T2 STREAM uo_out", uo_out, 8'h0B);
        chk("T2 STREAM uio_oe", uio_oe, 8'h00);
        ui_in  = 8'h22; uio_in = 8'h20; tick;   // cnt=0: DATA_VLD, W_col1 dc
        ui_in  = 8'h22; uio_in = 8'h22; tick;   // cnt=1: DATA_VLD, W_col1=1.0
        ui_in  = 8'h00; uio_in = 8'h22; tick;   // cnt=2: tail; acc=4.0 → DRAIN

        //---------------------------------------------------------------------
        // DRAIN col0: y = FP4(1.0 × 4.0) = 0x6
        //---------------------------------------------------------------------
        $display("-- DRAIN SCALE_LOAD col0 --");
        chk("T2 scale_col0 uo_out", uo_out, 8'h1C);
        chk("T2 scale_col0 uio_oe", uio_oe, 8'h00);
        ui_in  = 8'h3C; uio_in = 8'h00;
        tick;

        $display("-- DRAIN RESULT_HOLD col0: y=FP4(4.0)=0x6 --");
        chk("T2 result_col0 uo_out",  uo_out,  8'h3C);
        chk("T2 result_col0 uio_oe",  uio_oe,  8'hFF);
        chk("T2 result_col0 uio_out", uio_out, 8'h06);
        ui_in  = 8'h01; uio_in = 8'h00;
        tick;

        //---------------------------------------------------------------------
        // DRAIN col1: y = FP4(4.0) = 0x6
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
        $display("--- TEST 3: RELU_EN (K=2, W_col0=-1.0, W_col1=+1.0) ---");
        $display("    col0: acc=-2.0 → RELU → 0   → y=0x0");
        $display("    col1: acc=+2.0 → RELU → 2.0 → y=0x4");
        // ====================================================================
        // W_col0 = FP4(-1.0) = 0xA  (sign=1, exp=01, mant=0 → -1.0×2^0 = -1.0)
        // After K=2 MACs: acc[col0] = 0 + (-1.0) + (-1.0) = -2.0
        //                 acc[col1] = 0 + (+1.0) + (+1.0) = +2.0
        // RELU: -2.0 → 0 (sign bit=1), +2.0 → pass (sign bit=0)
        // VU: col0 → scale_muxed=0, col_muxed=0 → FloatP16x4(0,0)=0x0
        //     col1 → FloatP16x4(1.0, 2.0) = FP4(2.0) = 0x4

        //---------------------------------------------------------------------
        // IDLE → CFG
        //---------------------------------------------------------------------
        ui_in  = 8'h01;
        uio_in = 8'h00;
        tick;

        //---------------------------------------------------------------------
        // CFG: RELU_EN=1, no SKIP_BIAS → goes through LOAD
        //---------------------------------------------------------------------
        chk("T3 CFG uo_out", uo_out, 8'h09);
        ui_in  = 8'h02;   // K_LEN=2
        uio_in = 8'h01;   // RELU_EN=1, SKIP_BIAS=0
        tick;             // posedge: CFG → LOAD

        //---------------------------------------------------------------------
        // LOAD: 2 cycles — bias=0 resets both accumulators
        //---------------------------------------------------------------------
        $display("-- LOAD cnt=0: bias[col0]=0 --");
        chk("T3 LOAD uo_out", uo_out, 8'h0A);
        chk("T3 LOAD uio_oe", uio_oe, 8'h00);
        ui_in  = 8'h00;
        uio_in = 8'h00;
        tick;             // posedge: acc_q[col0] ← 0

        $display("-- LOAD cnt=1: bias[col1]=0; exit → STREAM --");
        ui_in  = 8'h00;
        uio_in = 8'h00;
        tick;             // posedge: acc_q[col1] ← 0; → STREAM

        //---------------------------------------------------------------------
        // STREAM: K=2, W_col0=-1.0=0xA, W_col1=+1.0=0x2
        //   cnt=0: pe_en[0]=1; col0: A=1.0 × W_col0=-1.0 → acc_q[col0]=-1.0
        //   cnt=1: pe_en=11;   col0: -1.0+(-1.0)=-2.0; col1: 1.0×1.0=1.0
        //   cnt=2: pe_en[1]=1 (tail); col1: 1.0+1.0=2.0
        //   W_col1 feeding: cnt=1 → W_col1[0]=1.0; cnt=2 → W_col1[1]=1.0
        //---------------------------------------------------------------------
        $display("-- STREAM cnt=0: col0 1st MAC (1.0 × -1.0 = -1.0) --");
        chk("T3 STREAM uo_out", uo_out, 8'h0B);
        ui_in  = 8'hA2;   // W_col0=0xA(-1.0) | A=0x2(1.0)
        uio_in = 8'h20;   // DATA_VLD=1, W_col1 don't care
        tick;

        $display("-- STREAM cnt=1: col0 2nd MAC (-2.0); col1 1st MAC (+1.0) --");
        ui_in  = 8'hA2;   // W_col0=-1.0, A=1.0
        uio_in = 8'h22;   // DATA_VLD=1, W_col1=+1.0
        tick;

        $display("-- STREAM cnt=2: col1 2nd MAC (tail) → acc[col1]=+2.0 --");
        ui_in  = 8'h00;   // pe_en[0]=0; A/W_col0 don't care
        uio_in = 8'h22;   // DATA_VLD=1, W_col1=+1.0
        tick;             // posedge: acc[col0]=-2.0, acc[col1]=+2.0; → DRAIN

        //---------------------------------------------------------------------
        // DRAIN col0: RELU clamps negative acc to 0; y = 0x0
        //---------------------------------------------------------------------
        $display("-- DRAIN SCALE_LOAD col0: col_out=-2.0; RELU → 0 --");
        chk("T3 scale_col0 uo_out", uo_out, 8'h1C);
        chk("T3 scale_col0 uio_oe", uio_oe, 8'h00);
        ui_in  = 8'h3C;   // scale=1.0; ui_in[0]=0
        uio_in = 8'h00;
        tick;             // posedge: RELU gates col_muxed=0 → y[col0]=0x0

        $display("-- DRAIN RESULT_HOLD col0: y=0x0 (RELU clamped) --");
        chk("T3 result_col0 uo_out",  uo_out,  8'h3C);
        chk("T3 result_col0 uio_oe",  uio_oe,  8'hFF);
        chk("T3 result_col0 uio_out", uio_out, 8'h00);   // RELU → 0
        ui_in  = 8'h01; uio_in = 8'h00;
        tick;

        //---------------------------------------------------------------------
        // DRAIN col1: RELU passes positive acc; y = FP4(2.0) = 0x4
        //---------------------------------------------------------------------
        $display("-- DRAIN SCALE_LOAD col1: col_out=+2.0; RELU passes --");
        chk("T3 scale_col1 uo_out", uo_out, 8'h9C);
        chk("T3 scale_col1 uio_oe", uio_oe, 8'h00);
        ui_in  = 8'h3C;
        uio_in = 8'h00;
        tick;             // posedge: y[col1]=FP4(1.0×2.0)=0x4

        $display("-- DRAIN RESULT_HOLD col1: y=FP4(2.0)=0x4 --");
        chk("T3 result_col1 uo_out",  uo_out,  8'hBC);
        chk("T3 result_col1 uio_oe",  uio_oe,  8'hFF);
        chk("T3 result_col1 uio_out", uio_out, 8'h04);
        ui_in  = 8'h01; uio_in = 8'h00;
        #1;
        chk("T3 tile_done uo_out",    uo_out,  8'hFC);
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