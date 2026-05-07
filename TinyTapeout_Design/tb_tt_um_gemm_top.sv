///////////////////////////////////////////////////////////////////////////////
// Module: tb_tt_um_gemm_top.sv
// Description: Interface and timing verification testbench for the
//              FP4 GEMM Tiny Tapeout 1xN design.
//
// Three test cases exercise all COL_CONFIG modes:
//   Test 1: 1x3 (COL_CONFIG=2) — primary, fully annotated
//   Test 2: 1x2 (COL_CONFIG=1) — abbreviated
//   Test 3: 1x1 (COL_CONFIG=0) — abbreviated
//
// Common test values (exact FP arithmetic, no rounding):
//   K = 2
//   A = W = FP4 1.0 (0x2) for all active inputs
//   bias  = FP16 +0.0 (0x0000)
//   scale = FP16  1.0 (0x3C00)
//
// Expected per PE:
//   acc = bias + a[0]*w[0] + a[1]*w[1] = 0 + 1.0 + 1.0 = 2.0 (FP16 0x4000)
//   y   = scale * acc = 1.0 * 2.0 = 2.0 -> FP4 0x4
//
// Pin mapping (STREAM phase):
//   ui_in[3:0]  = a_row0  (only row; constant)
//   ui_in[7:4]  = w_col0
//   uio_in[3:0] = w_col1
//   uio_in[7:4] = w_col2
//
// CFG uio_in encoding:
//   [2:0] = {SKIP_SCALE, SKIP_BIAS, RELU_EN}
//   [4:3] = COL_CONFIG  (00=1x1, 01=1x2, 10=1x3)
//   1x1: uio_in=0x00  1x2: uio_in=0x08  1x3: uio_in=0x10
//
// ────────────────────────────────────────────────────────────────────────────
// Test 1 — 1x3 (COL_CONFIG=2, K=2) cycle map
// ────────────────────────────────────────────────────────────────────────────
//   Cycle  1  IDLE:    assert START (ui_in[0]=1)
//   Cycle  2  CFG:     K_LEN=2, COL_CONFIG=2, flags=0 captured
//   Cycle  3  LOAD0:   bias[0]=0x0000 → col0 acc (load_cnt=0, ld_bias[0]=1)
//   Cycle  4  LOAD1:   bias[1]=0x0000 → col1 acc
//   Cycle  5  LOAD2:   bias[2]=0x0000 → col2 acc
//   Cycle  6  LOAD3:   scale_reg[0]=0x3C00 captured (load_cnt = NCOLS = 3)
//   Cycle  7  LOAD4:   scale_reg[1]=0x3C00 captured
//   Cycle  8  LOAD5:   scale_reg[2]=0x3C00 captured; exits LOAD → STREAM
//   Cycle  9  STREAM cnt=0: PE[0][0] 1st MAC (V_PE_EN=001)
//   Cycle 10  STREAM cnt=1: PE[0][0] 2nd, PE[0][1] 1st MAC (V_PE_EN=011)
//   Cycle 11  STREAM cnt=2: PE[0][1] 2nd, PE[0][2] 1st MAC (V_PE_EN=110)
//                            quant_en[0] fires → col0 result latches
//   Cycle 12  STREAM cnt=3: PE[0][2] 2nd MAC (V_PE_EN=100)
//                            quant_en[1] fires → col1 result latches
//                            stream_exit (cnt=K+COL_CONFIG-1=3) → DRAIN
//   Cycle 13  DRAIN  cnt=0: quant_en[2] fires → col2 result latches at end
//                            uio_out = {y[1],y[0]} = 0x44
//   Cycle 14  DRAIN  cnt=1: uio_out = {4'b0,y[2]} = 0x04; tile_done
//   Cycle 15  IDLE
//
// ────────────────────────────────────────────────────────────────────────────
// Test 2 — 1x2 (COL_CONFIG=1, K=2) cycle map
// ────────────────────────────────────────────────────────────────────────────
//   Cycle  1  IDLE → STREAM (6 cycles: 1 IDLE, 1 CFG, 4 LOAD)
//   STREAM:  3 cycles (cnt 0..2, exit at K+COL_CONFIG-1=2)
//             cnt=2: quant_en[0] fires + exit → DRAIN
//   DRAIN0:  uio_out = {4'b0,y[0]}         = 0x04
//   DRAIN1:  uio_out = {y[1],y[0]}          = 0x44; tile_done
//
// ────────────────────────────────────────────────────────────────────────────
// Test 3 — 1x1 (COL_CONFIG=0, K=2) cycle map
// ────────────────────────────────────────────────────────────────────────────
//   LOAD:   2 cycles (bias[0] then scale[0])
//   STREAM: 2 cycles (cnt 0..1, exit at K+COL_CONFIG-1=1)
//   DRAIN0: quant_en[0] fires; uio_out = 0x00 (result latches at end of cycle)
//   DRAIN1: uio_out = {4'b0,y[0]}            = 0x04; tile_done
//
// uo_out status bus:
//   IDLE   = 0x00
//   CFG    = 0x09  {busy=1, phase=001}
//   LOAD   = 0x0A  {busy=1, phase=010}
//   STREAM = 0x0B  {busy=1, phase=011}
//   DRAIN0 = 0x1C  {dvld=1, drain_cnt=0, busy=1, phase=100}
//   DRAIN1 = 0x7C  {done=1, dvld=1, drain_cnt=1, busy=1, phase=100}
//
// Author: Group5
///////////////////////////////////////////////////////////////////////////////

module tb_tt_um_gemm_top;

    localparam CLK_PERIOD = 10;  // 10 ns -> 100 MHz

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

    // Advance one clock edge and settle 1 ns before sampling
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

        $display("=== tt_um_gemm_top: 1xN interface/timing TB ===");
        $display("    K=2, A=W=FP4(1.0), bias=0, scale=FP16(1.0)");
        $display("    Expected all outputs: FP4 2.0 = 0x4");
        $display("");

        //---------------------------------------------------------------------
        // Reset: hold for 2 cycles
        //---------------------------------------------------------------------
        ena    = 1;
        rst_n  = 0;
        ui_in  = 8'h00;
        uio_in = 8'h00;
        repeat(2) @(posedge clk);
        rst_n = 1; #1;

        chk("RESET: IDLE uo_out",   uo_out, 8'h00);
        chk("RESET: IDLE uio_oe",   uio_oe, 8'h00);

        // ====================================================================
        $display("");
        $display("--- TEST 1: 1x3 (COL_CONFIG=2, K=2) ---");
        // ====================================================================

        //---------------------------------------------------------------------
        // IDLE: assert START
        //---------------------------------------------------------------------
        $display("--- IDLE: assert START ---");
        ui_in  = 8'h01;   // START=1
        uio_in = 8'h00;
        tick;             // IDLE -> CFG

        //---------------------------------------------------------------------
        // CFG: K_LEN=2, COL_CONFIG=2'b10, all flags=0
        //   uio_in[4:3]=2'b10 -> uio_in = 0x10
        //---------------------------------------------------------------------
        $display("--- CFG: K_LEN=2, COL_CONFIG=2 (1x3) ---");
        chk("CFG uo_out",          uo_out, 8'h09);
        chk("CFG uio_oe",          uio_oe, 8'h00);
        ui_in  = 8'h02;   // K_LEN = 2
        uio_in = 8'h10;   // COL_CONFIG=2'b10, RELU_EN=0, SKIP_BIAS=0, SKIP_SCALE=0
        tick;             // CFG -> LOAD

        //---------------------------------------------------------------------
        // LOAD cnt=0: ld_bias[0] -> col0 acc = 0x0000
        //---------------------------------------------------------------------
        $display("--- LOAD cnt=0: bias[0]=0x0000 -> col0 ---");
        chk("LOAD uo_out",         uo_out, 8'h0A);
        chk("LOAD uio_oe",         uio_oe, 8'h00);
        ui_in  = 8'h00;   // bias[15:8] = 0x00
        uio_in = 8'h00;   // bias[7:0]  = 0x00  -> FP16 +0.0
        tick;

        //---------------------------------------------------------------------
        // LOAD cnt=1: ld_bias[1] -> col1 acc = 0x0000
        //---------------------------------------------------------------------
        $display("--- LOAD cnt=1: bias[1]=0x0000 -> col1 ---");
        ui_in  = 8'h00;
        uio_in = 8'h00;
        tick;

        //---------------------------------------------------------------------
        // LOAD cnt=2: ld_bias[2] -> col2 acc = 0x0000
        //---------------------------------------------------------------------
        $display("--- LOAD cnt=2: bias[2]=0x0000 -> col2 ---");
        ui_in  = 8'h00;
        uio_in = 8'h00;
        tick;

        //---------------------------------------------------------------------
        // LOAD cnt=3: scale_reg[0]=0x3C00 captured (load_cnt = NCOLS = 3)
        //---------------------------------------------------------------------
        $display("--- LOAD cnt=3: scale_reg[0]=0x3C00 ---");
        ui_in  = 8'h3C;   // scale[15:8]
        uio_in = 8'h00;   // scale[7:0]  -> 0x3C00 = FP16 1.0
        tick;

        //---------------------------------------------------------------------
        // LOAD cnt=4: scale_reg[1]=0x3C00
        //---------------------------------------------------------------------
        $display("--- LOAD cnt=4: scale_reg[1]=0x3C00 ---");
        ui_in  = 8'h3C;
        uio_in = 8'h00;
        tick;

        //---------------------------------------------------------------------
        // LOAD cnt=5 (=2*NCOLS-1=5): scale_reg[2]=0x3C00; exits LOAD -> STREAM
        //---------------------------------------------------------------------
        $display("--- LOAD cnt=5: scale_reg[2]=0x3C00; exit -> STREAM ---");
        ui_in  = 8'h3C;
        uio_in = 8'h00;
        tick;

        //---------------------------------------------------------------------
        // STREAM cnt=0: PE[0][0] 1st MAC
        //   V_PE_EN = 001 (only col0 active)
        //   a_row0=1.0 -> PE[0][0]; w_col0=1.0; col1/col2 not yet active
        //---------------------------------------------------------------------
        $display("--- STREAM cnt=0: PE[0][0] 1st MAC ---");
        chk("STREAM uo_out",       uo_out, 8'h0B);
        chk("STREAM uio_oe",       uio_oe, 8'h00);   // bidir still input
        ui_in  = 8'h22;   // {w_col0=0x2(1.0), a_row0=0x2(1.0)}
        uio_in = 8'h00;   // w_col1/2 don't care (PEs gated off)
        tick;

        //---------------------------------------------------------------------
        // STREAM cnt=1: PE[0][0] 2nd MAC; PE[0][1] 1st MAC
        //   V_PE_EN = 011 (col0 and col1 active)
        //   w_col1=1.0 enters col1 PE; col2 still inactive
        //---------------------------------------------------------------------
        $display("--- STREAM cnt=1: PE[0][0] 2nd, PE[0][1] 1st MAC ---");
        ui_in  = 8'h22;   // {w_col0=0x2, a_row0=0x2}
        uio_in = 8'h02;   // {w_col2=0x0, w_col1=0x2(1.0)}
        tick;

        //---------------------------------------------------------------------
        // STREAM cnt=2: PE[0][1] 2nd MAC; PE[0][2] 1st MAC
        //   V_PE_EN = 110 (col1 and col2 active; col0 done)
        //   quant_en[0] fires: sa_out[0] -> VU -> col0 result latches at end
        //   a_row0 don't care (H_PE_EN=0; col1/col2 use propagated values)
        //---------------------------------------------------------------------
        $display("--- STREAM cnt=2: PE[0][1] 2nd, PE[0][2] 1st; quant_en[0] ---");
        ui_in  = 8'h00;   // a_row0/w_col0 don't care (pe_en_0=0)
        uio_in = 8'h22;   // {w_col2=0x2(1.0), w_col1=0x2(1.0)}
        tick;

        //---------------------------------------------------------------------
        // STREAM cnt=3 (=stream_exit=K+COL_CONFIG-1=3): PE[0][2] 2nd MAC
        //   V_PE_EN = 100 (only col2 active; tail drain)
        //   quant_en[1] fires: sa_out[1] -> VU -> col1 result latches at end
        //   stream_exit reached -> next_state = DRAIN
        //---------------------------------------------------------------------
        $display("--- STREAM cnt=3: PE[0][2] 2nd MAC; quant_en[1]; exit -> DRAIN ---");
        ui_in  = 8'h00;   // don't care
        uio_in = 8'h20;   // {w_col2=0x2(1.0), w_col1=0x0}
        tick;

        //---------------------------------------------------------------------
        // DRAIN cnt=0:
        //   quant_en[2] fires: sa_out[2]=2.0 -> VU -> col2 result latches at end
        //   uio_out = {y[1], y[0]} = {0x4, 0x4} = 0x44  (col0 and col1 ready)
        //   uio_oe = 0xFF
        //   uo_out: phase=100, busy=1, dvld=1, drain_cnt=0, done=0 -> 0x1C
        //---------------------------------------------------------------------
        $display("--- DRAIN cnt=0: col0+col1 output; quant_en[2] fires ---");
        chk("DRAIN0 uio_oe",       uio_oe,  8'hFF);
        chk("DRAIN0 uio_out",      uio_out, 8'h44);   // {y[1]=0x4, y[0]=0x4}
        chk("DRAIN0 uo_out",       uo_out,  8'h1C);
        tick;

        //---------------------------------------------------------------------
        // DRAIN cnt=1:
        //   uio_out = {4'b0, y[2]} = 0x04  (col2 latched at end of DRAIN0)
        //   tile_done pulses; next cycle -> IDLE
        //   uo_out: phase=100, busy=1, dvld=1, drain_cnt=1, done=1 -> 0x7C
        //---------------------------------------------------------------------
        $display("--- DRAIN cnt=1: col2 output + tile_done ---");
        chk("DRAIN1 uio_out",      uio_out, 8'h04);   // {4'b0, y[2]=0x4}
        chk("DRAIN1 uo_out",       uo_out,  8'h7C);
        tick;

        $display("--- IDLE after 1x3 tile ---");
        chk("1x3 IDLE uo_out",     uo_out,  8'h00);
        chk("1x3 IDLE uio_oe",     uio_oe,  8'h00);

        // ====================================================================
        $display("");
        $display("--- TEST 2: 1x2 (COL_CONFIG=1, K=2) ---");
        // ====================================================================
        // LOAD is 4 cycles (bias[0], bias[1], scale[0], scale[1])
        // STREAM is 3 cycles (cnt 0..2); stream_exit=K+COL_CONFIG-1=2
        //   cnt=2: quant_en[0] fires and stream exits to DRAIN same cycle
        // DRAIN0: {4'b0, y[0]} = 0x04
        // DRAIN1: {y[1], y[0]} = 0x44

        ui_in  = 8'h01; uio_in = 8'h00; tick;  // IDLE -> CFG

        chk("1x2 CFG uo_out",      uo_out,  8'h09);
        ui_in  = 8'h02;   // K_LEN=2
        uio_in = 8'h08;   // COL_CONFIG=2'b01 (uio_in[4:3]=01 -> bit3=1 -> 0x08)
        tick;             // CFG -> LOAD

        chk("1x2 LOAD uo_out",     uo_out,  8'h0A);
        // LOAD cnt=0: bias[0]
        ui_in = 8'h00; uio_in = 8'h00; tick;
        // LOAD cnt=1: bias[1]
        ui_in = 8'h00; uio_in = 8'h00; tick;
        // LOAD cnt=2: scale_reg[0] (load_cnt = COL_CONFIG+1 = 2)
        ui_in = 8'h3C; uio_in = 8'h00; tick;
        // LOAD cnt=3 (=2*NCOLS-1=3): scale_reg[1]; exit -> STREAM
        ui_in = 8'h3C; uio_in = 8'h00; tick;

        chk("1x2 STREAM uo_out",   uo_out,  8'h0B);
        // STREAM cnt=0: only col0 active
        ui_in = 8'h22; uio_in = 8'h00; tick;
        // STREAM cnt=1: col0 2nd MAC; col1 1st MAC
        ui_in = 8'h22; uio_in = 8'h02; tick;   // w_col1=1.0
        // STREAM cnt=2: col1 2nd MAC; quant_en[0] fires; exit -> DRAIN
        ui_in = 8'h00; uio_in = 8'h02; tick;   // w_col1=1.0

        $display("--- 1x2 DRAIN ---");
        chk("1x2 DRAIN0 uio_oe",   uio_oe,  8'hFF);
        chk("1x2 DRAIN0 uio_out",  uio_out, 8'h04);   // {4'b0, y[0]=0x4}
        chk("1x2 DRAIN0 uo_out",   uo_out,  8'h1C);
        tick;
        chk("1x2 DRAIN1 uio_out",  uio_out, 8'h44);   // {y[1]=0x4, y[0]=0x4}
        chk("1x2 DRAIN1 uo_out",   uo_out,  8'h7C);
        tick;
        chk("1x2 IDLE uo_out",     uo_out,  8'h00);

        // ====================================================================
        $display("");
        $display("--- TEST 3: 1x1 (COL_CONFIG=0, K=2) ---");
        // ====================================================================
        // LOAD is 2 cycles (bias[0] at cnt=0, scale[0] at cnt=1=2*NCOLS-1)
        // STREAM is 2 cycles (cnt 0..1); stream_exit=K+COL_CONFIG-1=1
        // quant_en[0] fires at drain_cnt=0 (col0 = NCOLS-1 = last col)
        // DRAIN0: result latches at end of cycle; uio_out = 0x00
        // DRAIN1: uio_out = {4'b0, y[0]} = 0x04

        ui_in  = 8'h01; uio_in = 8'h00; tick;  // IDLE -> CFG

        chk("1x1 CFG uo_out",      uo_out,  8'h09);
        ui_in  = 8'h02;   // K_LEN=2
        uio_in = 8'h00;   // COL_CONFIG=2'b00, all flags 0
        tick;             // CFG -> LOAD

        chk("1x1 LOAD uo_out",     uo_out,  8'h0A);
        // LOAD cnt=0: bias[0]
        ui_in = 8'h00; uio_in = 8'h00; tick;
        // LOAD cnt=1 (=2*NCOLS-1=1): scale_reg[0]; exit -> STREAM
        ui_in = 8'h3C; uio_in = 8'h00; tick;

        chk("1x1 STREAM uo_out",   uo_out,  8'h0B);
        // STREAM cnt=0: only col0 active; only ui_in[7:4]=w_col0 and [3:0]=a_row0 matter
        ui_in = 8'h22; uio_in = 8'h00; tick;
        // STREAM cnt=1 (=stream_exit=1): PE[0][0] 2nd MAC; exit -> DRAIN
        ui_in = 8'h22; uio_in = 8'h00; tick;

        $display("--- 1x1 DRAIN ---");
        chk("1x1 DRAIN0 uio_oe",   uio_oe,  8'hFF);
        chk("1x1 DRAIN0 uio_out",  uio_out, 8'h00);   // result latches this cycle
        chk("1x1 DRAIN0 uo_out",   uo_out,  8'h1C);
        tick;
        chk("1x1 DRAIN1 uio_out",  uio_out, 8'h04);   // {4'b0, y[0]=0x4}
        chk("1x1 DRAIN1 uo_out",   uo_out,  8'h7C);
        tick;
        chk("1x1 IDLE uo_out",     uo_out,  8'h00);

        //---------------------------------------------------------------------
        // Summary
        //---------------------------------------------------------------------
        $display("");
        $display("=== %0d passed, %0d failed ===", pass_cnt, fail_cnt);
        $display(fail_cnt == 0 ? "ALL PASS" : "FAILURES DETECTED");
        $stop;
    end

    // Watchdog
    initial begin
        #(CLK_PERIOD * 300);
        $display("TIMEOUT");
        $stop;
    end

endmodule