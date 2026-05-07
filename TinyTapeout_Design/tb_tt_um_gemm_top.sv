///////////////////////////////////////////////////////////////////////////////
// Module: tb_tt_um_gemm_top.sv
// Description: Interface and timing verification testbench for the
//              FP4 GEMM Tiny Tapeout 1x2 design (scale-in-LOAD, DRAIN output).
//
// Three test cases:
//   Test 1: 1x2 full LOAD  (COL_CONFIG=1, K=2, bias+scale in LOAD)
//   Test 2: 1x2 SKIP_SCALE (COL_CONFIG=1, K=2, scale reused from Test 1)
//   Test 3: 1x1 full LOAD  (COL_CONFIG=0, K=2)
//
// Common values:
//   K=2, A=W=FP4(1.0)=0x2, bias=FP16(0.0)=0x0000, scale=FP16(1.0)=0x3C00
//   Expected per column: acc = 0 + 1.0 + 1.0 = FP16(2.0) = 0x4000
//                        y   = scale * acc = FP4(2.0) = 0x4
//
// REQUIRES 1-STAGE PE (no mul_out_q flop):
//   Col 1 final accumulation completes at the END of the last STREAM cycle.
//   quant_en[1] fires at drain_cnt=0, reading sa_out[1] which is then complete.
//   With a 2-stage PE, col 1 accumulation completes one cycle later (drain_cnt=0
//   posedge), and the VU would capture an incomplete sum.
//
// Protocol summary:
//   LOAD sub-phases (1x2, COL_CONFIG=1, 4 total cycles):
//     cnt=0,1 : ld_bias[0,1] → acc_q loaded with bias
//     cnt=2,3 : scale_reg[0,1] captured from {ui_in, uio_in}
//     exit    : load_cnt == {COL_CONFIG_r, 1'b1} = 3
//   STREAM (3 cycles, stream_exit = K + COL_CONFIG - 1 = 2):
//     cnt=0: V_PE_EN=2'b01; col0 1st MAC
//     cnt=1: V_PE_EN=2'b11; col0 2nd MAC, col1 1st MAC
//     cnt=2: V_PE_EN=2'b10; col1 2nd MAC (tail); quant_en[0] fires
//   DRAIN (always 2 cycles):
//     cnt=0: uio_oe=0xFF, uio_out={4'b0,y[0]};  quant_en[1] fires, y[1] captured
//     cnt=1: uio_oe=0xFF, uio_out={y[1],y[0]};  tile_done → IDLE
//
// CFG uio_in encoding:
//   [0]   = RELU_EN
//   [1]   = SKIP_BIAS
//   [2]   = SKIP_SCALE
//   [4:3] = COL_CONFIG  (00=1x1, 01=1x2)
//   Full  1x2: uio_in=0x08  (COL_CONFIG=01, all flags=0)
//   SKIP_SCALE 1x2: uio_in=0x0C  (COL_CONFIG=01, SKIP_SCALE=1)
//   Full  1x1: uio_in=0x00  (COL_CONFIG=00, all flags=0)
//
// uo_out encoding:
//   [2:0] = FSM state (IDLE=0,CFG=1,LOAD=2,STREAM=3,DRAIN=4)
//   [3]   = busy
//   [4]   = drain_active
//   [5]   = drain_active && drain_cnt
//   [6]   = tile_done
//   → IDLE=0x00, CFG=0x09, LOAD=0x0A, STREAM=0x0B
//   → DRAIN cnt=0: 0x1C,  DRAIN cnt=1 (tile_done): 0x7C
//
// ─────────────────────────────────────────────────────────────────────────────
// Test 1 — 1x2 full LOAD (COL_CONFIG=1, K=2) cycle map
// ─────────────────────────────────────────────────────────────────────────────
//   Cycle  1  IDLE:         assert START (ui_in[0]=1)
//   Cycle  2  CFG:          K_LEN=2, COL_CONFIG=1, flags=0 captured; → LOAD
//   Cycle  3  LOAD cnt=0:   bias[0]=0x0000 → ld_bias[0]=1, acc_q[0]=0
//   Cycle  4  LOAD cnt=1:   bias[1]=0x0000 → ld_bias[1]=1, acc_q[1]=0
//   Cycle  5  LOAD cnt=2:   scale_reg[0]=0x3C00 captured
//   Cycle  6  LOAD cnt=3:   scale_reg[1]=0x3C00 captured; → STREAM
//   Cycle  7  STREAM cnt=0: V_PE_EN=01; a=1.0 → col0 (acc0=1.0 at posedge)
//   Cycle  8  STREAM cnt=1: V_PE_EN=11; col0 2nd (acc0=2.0), col1 1st (acc1=1.0)
//   Cycle  9  STREAM cnt=2: V_PE_EN=10; col1 2nd (acc1=2.0); quant_en[0]→y[0]=0x4; → DRAIN
//   Cycle 10  DRAIN cnt=0:  uio_oe=FF; uio_out=0x04 ({0,y[0]=0x4}); quant_en[1]→y[1]=0x4
//   Cycle 11  DRAIN cnt=1:  uio_oe=FF; uio_out=0x44 ({y[1]=0x4,y[0]=0x4}); tile_done → IDLE
//
// ─────────────────────────────────────────────────────────────────────────────
// Test 2 — 1x2 SKIP_SCALE (reuse scale_reg from Test 1)
// ─────────────────────────────────────────────────────────────────────────────
//   LOAD exit: cnt=={0,COL_CONFIG_r}=1 (after 2 bias cycles only)
//   scale_reg[0,1] retain 0x3C00 from Test 1; same expected outputs
//
// ─────────────────────────────────────────────────────────────────────────────
// Test 3 — 1x1 full LOAD (COL_CONFIG=0, K=2) cycle map
// ─────────────────────────────────────────────────────────────────────────────
//   LOAD: 2 cycles (cnt=0: bias[0]; cnt=1: scale[0]; exit at cnt=={00,1}=1)
//   STREAM: 2 cycles (stream_exit=K+0-1=1)
//   DRAIN: 2 cycles (drain_cnt=0: 0x04 valid; drain_cnt=1: upper nibble undefined)
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
            $display("  PASS  %-32s  got=0x%02h", lbl, got);
            pass_cnt++;
        end else begin
            $display("  FAIL  %-32s  got=0x%02h  exp=0x%02h", lbl, got, exp);
            fail_cnt++;
        end
    endtask

    //=========================================================================
    // Test stimulus
    //=========================================================================
    initial begin
        $dumpfile("tb_tt_um_gemm_top.vcd");
        $dumpvars(0, tb_tt_um_gemm_top);

        $display("=== tt_um_gemm_top: 1x2 scale-in-LOAD / DRAIN TB ===");
        $display("    K=2, A=W=FP4(1.0)=0x2, bias=0x0000, scale=FP16(1.0)=0x3C00");
        $display("    Expected per column: FP16(2.0)=0x4000 → FP4(2.0)=0x4");
        $display("    Expected DRAIN outputs: cnt=0: 0x04, cnt=1: 0x44");
        $display("");
        $display("    NOTE: Requires 1-stage PE (no mul_out_q). See header for details.");
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
        $display("--- TEST 1: 1x2 full LOAD (COL_CONFIG=1, K=2) ---");
        // ====================================================================

        //---------------------------------------------------------------------
        // IDLE → CFG: assert START
        //---------------------------------------------------------------------
        $display("-- IDLE: assert START --");
        ui_in  = 8'h01;   // START=1 → ui_in[0]
        uio_in = 8'h00;
        tick;             // posedge: state IDLE→CFG

        //---------------------------------------------------------------------
        // CFG: K_LEN=2, COL_CONFIG=1, no flags
        //   ui_in[7:0] = K_LEN = 2
        //   uio_in[4:3]=2'b01 (COL_CONFIG=1), [2]=0, [1]=0, [0]=0
        //   uio_in = 0x08 = 0b00001000
        //---------------------------------------------------------------------
        $display("-- CFG: K_LEN=2, COL_CONFIG=1 (1x2), no flags --");
        chk("T1 CFG uo_out",  uo_out, 8'h09);
        chk("T1 CFG uio_oe",  uio_oe, 8'h00);
        ui_in  = 8'h02;   // K_LEN=2
        uio_in = 8'h08;   // COL_CONFIG=01
        tick;             // posedge: config captured, state CFG→LOAD

        //---------------------------------------------------------------------
        // LOAD: 4 cycles
        //   cnt=0,1: bias sub-phase  → ld_bias[0,1]; bias_bus={ui_in,uio_in}
        //   cnt=2,3: scale sub-phase → scale_reg[0,1]={ui_in,uio_in}
        //   exit: load_cnt=={COL_CONFIG_r,1'b1}=3
        //---------------------------------------------------------------------
        $display("-- LOAD cnt=0: bias[0]=0x0000 → acc_q[0]=0 --");
        chk("T1 LOAD uo_out",  uo_out, 8'h0A);
        chk("T1 LOAD uio_oe",  uio_oe, 8'h00);
        ui_in  = 8'h00;   // bias[15:8]=0x00
        uio_in = 8'h00;   // bias[7:0]=0x00  →  FP16(+0.0)
        tick;

        $display("-- LOAD cnt=1: bias[1]=0x0000 → acc_q[1]=0 --");
        ui_in  = 8'h00;
        uio_in = 8'h00;
        tick;

        $display("-- LOAD cnt=2: scale_reg[0]=FP16(1.0)=0x3C00 --");
        ui_in  = 8'h3C;   // scale[15:8]=0x3C
        uio_in = 8'h00;   // scale[7:0]=0x00  →  FP16(1.0)
        tick;

        $display("-- LOAD cnt=3: scale_reg[1]=FP16(1.0)=0x3C00; exit→STREAM --");
        ui_in  = 8'h3C;
        uio_in = 8'h00;
        tick;             // posedge: load_cnt=3=={1'b01,1'b1}=3 → STREAM

        //---------------------------------------------------------------------
        // STREAM: 3 cycles (stream_exit = K+COL_CONFIG-1 = 2)
        //   cnt=0: V_PE_EN=2'b01; col0 1st MAC (a=1.0, w[0]=1.0)
        //   cnt=1: V_PE_EN=2'b11; col0 2nd MAC, col1 1st MAC
        //   cnt=2: V_PE_EN=2'b10; col1 2nd MAC (tail); quant_en[0] fires
        //---------------------------------------------------------------------
        $display("-- STREAM cnt=0: V_PE_EN=01; col0 1st MAC --");
        chk("T1 STREAM uo_out", uo_out, 8'h0B);
        chk("T1 STREAM uio_oe", uio_oe, 8'h00);
        ui_in  = 8'h22;   // {w_col0=0x2(1.0), a_row0=0x2(1.0)}
        uio_in = 8'h00;   // w_col1 don't care (V_PE_EN[1]=0)
        tick;

        $display("-- STREAM cnt=1: V_PE_EN=11; col0 2nd MAC, col1 1st MAC --");
        ui_in  = 8'h22;   // {w_col0=1.0, a_row0=1.0}
        uio_in = 8'h02;   // uio_in[3:0]=w_col1=0x2(1.0)
        tick;

        $display("-- STREAM cnt=2: V_PE_EN=10; col1 2nd MAC; quant_en[0]→y[0]; exit→DRAIN --");
        ui_in  = 8'h00;   // H_PE_EN=0, col0 inactive; a don't care
        uio_in = 8'h02;   // w_col1=1.0 (col1 tail cycle)
        tick;             // posedge: quant_en[0] fires → y[0] captured; state→DRAIN

        //---------------------------------------------------------------------
        // DRAIN: 2 cycles
        //   uio_oe=0xFF throughout (chip drives output)
        //   cnt=0: uio_out={4'b0, y[0]}=0x04; quant_en[1] fires → y[1] captured
        //   cnt=1: uio_out={y[1],y[0]}=0x44;  tile_done → IDLE
        //---------------------------------------------------------------------
        $display("-- DRAIN cnt=0: y[0]=0x4 on uio_out[3:0]; quant_en[1] fires --");
        chk("T1 DRAIN0 uo_out",  uo_out,  8'h1C);   // state=100,busy,drain
        chk("T1 DRAIN0 uio_oe",  uio_oe,  8'hFF);
        chk("T1 DRAIN0 uio_out", uio_out, 8'h04);   // {4'b0, y[0]=0x4}
        tick;             // posedge: drain_cnt 0→1; y[1] captured by VU

        $display("-- DRAIN cnt=1: y[1]=0x4 on uio_out[7:4]; tile_done → IDLE --");
        chk("T1 DRAIN1 uo_out",  uo_out,  8'h7C);   // tile_done=1, drain_cnt=1
        chk("T1 DRAIN1 uio_oe",  uio_oe,  8'hFF);
        chk("T1 DRAIN1 uio_out", uio_out, 8'h44);   // {y[1]=0x4, y[0]=0x4}
        tick;             // posedge: drain_cnt=1 → IDLE

        $display("-- Back to IDLE --");
        chk("T1 IDLE uo_out",    uo_out,  8'h00);
        chk("T1 IDLE uio_oe",    uio_oe,  8'h00);

        // ====================================================================
        $display("");
        $display("--- TEST 2: 1x2 SKIP_SCALE (reuse scale_reg from Test 1) ---");
        // ====================================================================
        // scale_reg[0,1] still hold 0x3C00 from Test 1.
        // LOAD runs 2 cycles (bias sub-phase only):
        //   exit: load_cnt=={0,COL_CONFIG_r}=1 (SKIP_SCALE path in FSM)
        // STREAM and DRAIN identical to Test 1; expected outputs unchanged.

        //---------------------------------------------------------------------
        // IDLE → CFG
        //---------------------------------------------------------------------
        ui_in  = 8'h01;
        uio_in = 8'h00;
        tick;             // IDLE → CFG

        //---------------------------------------------------------------------
        // CFG: COL_CONFIG=1, SKIP_SCALE=1
        //   uio_in[4:3]=01 (COL_CONFIG=1), [2]=1 (SKIP_SCALE)
        //   uio_in = 0x0C = 0b00001100
        //---------------------------------------------------------------------
        chk("T2 CFG uo_out",  uo_out, 8'h09);
        ui_in  = 8'h02;   // K_LEN=2
        uio_in = 8'h0C;   // COL_CONFIG=01, SKIP_SCALE=1
        tick;             // CFG → LOAD

        //---------------------------------------------------------------------
        // LOAD: 2 cycles (bias only)
        //   exit: load_cnt==1 (SKIP_SCALE exit condition)
        //---------------------------------------------------------------------
        $display("-- LOAD (bias only, 2 cycles) --");
        chk("T2 LOAD uo_out",  uo_out, 8'h0A);
        chk("T2 LOAD uio_oe",  uio_oe, 8'h00);
        ui_in  = 8'h00;   // bias[0]=0x0000 (cnt=0)
        uio_in = 8'h00;
        tick;

        // cnt=1 == {0,COL_CONFIG_r}=1 → SKIP_SCALE exit to STREAM
        ui_in  = 8'h00;   // bias[1]=0x0000 (cnt=1, last bias cycle)
        uio_in = 8'h00;
        tick;             // posedge: load_cnt=1==1 → STREAM

        //---------------------------------------------------------------------
        // STREAM: same as Test 1
        //---------------------------------------------------------------------
        $display("-- STREAM (3 cycles, same as Test 1) --");
        chk("T2 STREAM uo_out", uo_out, 8'h0B);
        ui_in = 8'h22; uio_in = 8'h00; tick;   // cnt=0
        ui_in = 8'h22; uio_in = 8'h02; tick;   // cnt=1
        ui_in = 8'h00; uio_in = 8'h02; tick;   // cnt=2 (stream_exit); →DRAIN

        //---------------------------------------------------------------------
        // DRAIN: same expected values
        //---------------------------------------------------------------------
        $display("-- DRAIN (2 cycles) --");
        chk("T2 DRAIN0 uo_out",  uo_out,  8'h1C);
        chk("T2 DRAIN0 uio_oe",  uio_oe,  8'hFF);
        chk("T2 DRAIN0 uio_out", uio_out, 8'h04);
        tick;

        chk("T2 DRAIN1 uo_out",  uo_out,  8'h7C);
        chk("T2 DRAIN1 uio_oe",  uio_oe,  8'hFF);
        chk("T2 DRAIN1 uio_out", uio_out, 8'h44);
        tick;             // → IDLE

        chk("T2 IDLE uo_out", uo_out, 8'h00);

        // ====================================================================
        $display("");
        $display("--- TEST 3: 1x1 full LOAD (COL_CONFIG=0, K=2) ---");
        // ====================================================================
        // LOAD: 2 cycles (cnt=0: bias[0]; cnt=1: scale[0]; exit at cnt=={00,1}=1)
        // STREAM: 2 cycles (stream_exit = K+COL_CONFIG-1 = 1)
        //   cnt=0: V_PE_EN=2'b01, col0 1st MAC; cnt=1: col0 2nd MAC; quant_en[0]
        // DRAIN: 2 cycles (drain_cnt=0: y[0] valid; drain_cnt=1: lower nibble only)

        //---------------------------------------------------------------------
        // IDLE → CFG
        //---------------------------------------------------------------------
        ui_in  = 8'h01;
        uio_in = 8'h00;
        tick;             // IDLE → CFG

        //---------------------------------------------------------------------
        // CFG: COL_CONFIG=0, no flags
        //---------------------------------------------------------------------
        chk("T3 CFG uo_out",  uo_out, 8'h09);
        ui_in  = 8'h02;   // K_LEN=2
        uio_in = 8'h00;   // COL_CONFIG=00, all flags=0
        tick;             // CFG → LOAD

        //---------------------------------------------------------------------
        // LOAD: 2 cycles (cnt=0: bias[0]; cnt=1: scale[0])
        //   exit at {COL_CONFIG_r,1'b1}={00,1}=1
        //---------------------------------------------------------------------
        $display("-- LOAD (2 cycles: bias+scale for col0 only) --");
        chk("T3 LOAD uo_out",  uo_out, 8'h0A);
        chk("T3 LOAD uio_oe",  uio_oe, 8'h00);
        ui_in  = 8'h00;   // bias[0]=0x0000 (cnt=0)
        uio_in = 8'h00;
        tick;

        // cnt=1=={00,1}=1 → exit to STREAM
        ui_in  = 8'h3C;   // scale_reg[0]=0x3C00 (cnt=1)
        uio_in = 8'h00;
        tick;             // posedge: load_cnt=1 → STREAM

        //---------------------------------------------------------------------
        // STREAM: 2 cycles (stream_exit = 2+0-1 = 1)
        //   cnt=0: pe_en_0=1 (0<2), col0 1st MAC
        //   cnt=1: pe_en_0=1 (1<2), col0 2nd MAC; quant_en[0] fires → exit
        //---------------------------------------------------------------------
        $display("-- STREAM cnt=0: col0 1st MAC --");
        chk("T3 STREAM uo_out", uo_out, 8'h0B);
        chk("T3 STREAM uio_oe", uio_oe, 8'h00);
        ui_in  = 8'h22;   // {w_col0=1.0, a_row0=1.0}
        uio_in = 8'h00;
        tick;

        $display("-- STREAM cnt=1: col0 2nd MAC; quant_en[0]→y[0]; exit→DRAIN --");
        ui_in  = 8'h22;
        uio_in = 8'h00;
        tick;             // posedge: quant_en[0] fires; state→DRAIN

        //---------------------------------------------------------------------
        // DRAIN: 2 cycles
        //   cnt=0: uio_out={4'b0, y[0]}=0x04   y[0] valid
        //   cnt=1: uio_out[3:0]=y[0] valid; uio_out[7:4]=y[1] (col1 undefined, not checked)
        //---------------------------------------------------------------------
        $display("-- DRAIN cnt=0: y[0]=0x4 valid --");
        chk("T3 DRAIN0 uo_out",      uo_out,      8'h1C);
        chk("T3 DRAIN0 uio_oe",      uio_oe,      8'hFF);
        chk("T3 DRAIN0 uio_out",     uio_out,     8'h04);
        tick;

        $display("-- DRAIN cnt=1: tile_done; uio_out[3:0]=y[0] only --");
        chk("T3 DRAIN1 uo_out",      uo_out,      8'h7C);
        chk("T3 DRAIN1 uio_oe",      uio_oe,      8'hFF);
        chk("T3 DRAIN1 uio_out[3:0]",{4'b0, uio_out[3:0]}, 8'h04); // y[0]=0x4; y[1] undefined
        tick;             // → IDLE

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

    // Watchdog: 80 cycles is more than enough for all 3 tests
    initial begin
        #(CLK_PERIOD * 80);
        $display("TIMEOUT");
        $stop;
    end

endmodule