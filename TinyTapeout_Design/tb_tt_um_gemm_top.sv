///////////////////////////////////////////////////////////////////////////////
// Module: tb_tt_um_gemm_top.sv
// Description: Interface and timing verification testbench for the
//              FP4 GEMM Tiny Tapeout 2x2 design.
//
// Test case (chosen for exact FP arithmetic, no rounding):
//   K = 2
//   A = W = all FP4 1.0 (0x2)
//   bias  = FP16 +0.0 (0x0000)
//   scale = FP16  1.0 (0x3C00)
//
// Expected computation per PE:
//   acc = bias + a[i][0]*w[0][j] + a[i][1]*w[1][j]
//       = 0.0  + 1.0*1.0        + 1.0*1.0
//       = 2.0  (FP16 0x4000)
//   y   = scale * acc = 1.0 * 2.0 = 2.0 -> FP4 0x4
//   All 4 outputs (2 rows x 2 cols) = 0x4
//   uio_out during drain = {y_row1, y_row0} = {0x4, 0x4} = 0x44
//
// Streaming data layout per phase:
//   stream_cnt=0: ui_in=0x02 {a_row1=0,   a_row0=1.0}, uio_in=0x02 {w_col1=0,   w_col0=1.0}
//   stream_cnt=1: ui_in=0x22 {a_row1=1.0, a_row0=1.0}, uio_in=0x22 {w_col1=1.0, w_col0=1.0}
//   stream_cnt=2: ui_in=0x20 {a_row1=1.0, a_row0=0  }, uio_in=0x20 {w_col1=1.0, w_col0=0  }
//   stream_cnt=3: ui_in=0x00 (last MAC in pipeline, col0 quant overlap)
//
// Absolute cycle map (relative to rst_n release):
//   Cycle  1  IDLE:   assert START (ui_in[0]=1)
//   Cycle  2  CFG:    K_LEN=2, flags=0 captured
//   Cycle  3  LOAD0:  bias[0]=0x0000 -> col0 PE accumulators
//   Cycle  4  LOAD1:  bias[1]=0x0000 -> col1 PE accumulators
//   Cycle  5  LOAD2:  scale_reg[0]=0x3C00 captured
//   Cycle  6  LOAD3:  scale_reg[1]=0x3C00 captured; exits to STREAM
//   Cycle  7  STREAM cnt=0
//   Cycle  8  STREAM cnt=1
//   Cycle  9  STREAM cnt=2
//   Cycle 10  STREAM cnt=3 (K+1): last MAC + col0 quant overlap
//   Cycle 11  DRAIN  cnt=0:  uio_out = col0 results (0x44)
//   Cycle 12  DRAIN  cnt=1:  uio_out = col1 results (0x44), tile_done
//   Cycle 13  IDLE
//
// uo_out status bus encoding checked at each phase:
//   IDLE   = 0x00  {rsvd=0, done=0, dcol=0, dvld=0, busy=0, phase=000}
//   CFG    = 0x09  {                                 busy=1, phase=001}
//   LOAD   = 0x0A  {                                 busy=1, phase=010}
//   STREAM = 0x0B  {                                 busy=1, phase=011}
//   DRAIN0 = 0x1C  {done=0, dcol=0, dvld=1,          busy=1, phase=100}
//   DRAIN1 = 0x7C  {done=1, dcol=1, dvld=1,          busy=1, phase=100}
//
// Author: Group5
///////////////////////////////////////////////////////////////////////////////

module tb_tt_um_gemm_top;

    localparam CLK_PERIOD = 10;  // 10 ns -> 100 MHz (generous margin over 25 MHz target)

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

    // Advance one clock edge; settle 1 ns after posedge before sampling/driving
    task tick;
        @(posedge clk); #1;
    endtask

    // Check an 8-bit value and print PASS/FAIL
    task automatic chk(input string lbl, input logic [7:0] got, exp);
        if (got === exp) begin
            $display("  PASS  %-25s  got=0x%02h", lbl, got);
            pass_cnt++;
        end else begin
            $display("  FAIL  %-25s  got=0x%02h  exp=0x%02h", lbl, got, exp);
            fail_cnt++;
        end
    endtask

    //=========================================================================
    // Test stimulus
    //=========================================================================
    initial begin
        $dumpfile("tb_tt_um_gemm_top.vcd");
        $dumpvars(0, tb_tt_um_gemm_top);

        $display("=== tt_um_gemm_top: interface/timing TB ===");
        $display("    K=2, A=W=FP4(1.0), bias=0, scale=FP16(1.0)");
        $display("    Expected all outputs: FP4 2.0 = 0x4");
        $display("");

        //---------------------------------------------------------------------
        // Reset: hold for 2 cycles, then release
        //---------------------------------------------------------------------
        ena   = 1;
        rst_n = 0;
        ui_in  = 8'h00;
        uio_in = 8'h00;
        repeat(2) @(posedge clk);
        rst_n = 1; #1;

        $display("--- RESET released ---");
        chk("IDLE uo_out",      uo_out, 8'h00);   // phase=000, busy=0
        chk("IDLE uio_oe",      uio_oe, 8'h00);   // bidir all input
        chk("IDLE uio_out",     uio_out,8'h00);   // no output driven

        //---------------------------------------------------------------------
        // IDLE: assert START (ui_in[0]=1)
        // K_LEN is NOT captured here — it is captured in the next (CFG) cycle.
        //---------------------------------------------------------------------
        $display("--- IDLE: assert START ---");
        ui_in  = 8'h01;   // START=1; rest of ui_in don't care (not K_LEN yet)
        uio_in = 8'h00;
        tick;             // IDLE -> CFG

        //---------------------------------------------------------------------
        // CFG (1 cycle): K_LEN=2, RELU_EN=0, SKIP_BIAS=0, SKIP_SCALE=0
        // Chip latches ui_in[7:0] as K_LEN and uio_in[2:0] as flags at
        // the posedge of this cycle.
        //---------------------------------------------------------------------
        $display("--- CFG: K_LEN=2 ---");
        chk("CFG uo_out",       uo_out, 8'h09);   // phase=001, busy=1
        chk("CFG uio_oe",       uio_oe, 8'h00);   // bidir still input
        ui_in  = 8'h02;   // K_LEN = 2
        uio_in = 8'h00;   // {SKIP_SCALE=0, SKIP_BIAS=0, RELU_EN=0}
        tick;             // CFG -> LOAD

        //---------------------------------------------------------------------
        // LOAD cnt=0: ld_bias[0] pulses this cycle
        // {ui_in, uio_in} = bias[0] = 0x0000 loaded into col 0 accumulators
        //---------------------------------------------------------------------
        $display("--- LOAD c0: bias[0]=0x0000 ---");
        chk("LOAD uo_out",      uo_out, 8'h0A);   // phase=010, busy=1
        chk("LOAD uio_oe",      uio_oe, 8'h00);   // bidir input during LOAD
        ui_in  = 8'h00;   // bias[0][15:8] = 0x00
        uio_in = 8'h00;   // bias[0][7:0]  = 0x00  -> bias[0]=0x0000=FP16 +0.0
        tick;

        //---------------------------------------------------------------------
        // LOAD cnt=1: ld_bias[1] pulses
        // bias[1]=0x0000 loaded into col 1 accumulators
        //---------------------------------------------------------------------
        $display("--- LOAD c1: bias[1]=0x0000 ---");
        ui_in  = 8'h00;
        uio_in = 8'h00;
        tick;

        //---------------------------------------------------------------------
        // LOAD cnt=2: scale_reg[0] captured
        // scale[0] = {0x3C, 0x00} = 0x3C00 = FP16 1.0
        //---------------------------------------------------------------------
        $display("--- LOAD c2: scale[0]=0x3C00 ---");
        ui_in  = 8'h3C;   // scale[0][15:8]
        uio_in = 8'h00;   // scale[0][7:0]   -> scale[0]=0x3C00=FP16 1.0
        tick;

        //---------------------------------------------------------------------
        // LOAD cnt=3: scale_reg[1] captured; FSM exits LOAD -> STREAM
        //---------------------------------------------------------------------
        $display("--- LOAD c3: scale[1]=0x3C00 ---");
        ui_in  = 8'h3C;
        uio_in = 8'h00;
        tick;             // LOAD -> STREAM

        //---------------------------------------------------------------------
        // STREAM cnt=0: PE[0][0] first MAC
        //   H/V_PE_EN[0]=1, H/V_PE_EN[1]=0 (not yet)
        //   i_col[0]=a[0][0]=1.0, w_row[0]=w[0][0]=1.0
        //   Row1 / col1 boundary idle this cycle
        //---------------------------------------------------------------------
        $display("--- STREAM cnt=0: PE[0][0] first MAC ---");
        chk("STREAM uo_out",    uo_out, 8'h0B);   // phase=011, busy=1
        chk("STREAM uio_oe",    uio_oe, 8'h00);   // bidir still input (weights)
        ui_in  = 8'h02;   // {a_row1=0x0, a_row0=0x2 (FP4 1.0)}
        uio_in = 8'h02;   // {w_col1=0x0, w_col0=0x2 (FP4 1.0)}
        tick;

        //---------------------------------------------------------------------
        // STREAM cnt=1: PE[0][0] 2nd MAC; PE[0][1] and PE[1][0] 1st MAC
        //   H/V_PE_EN[0]=1, H/V_PE_EN[1]=1 (all enabled now)
        //   a[0][1] and a[1][0] both active; w[1][0] and w[0][1] both active
        //---------------------------------------------------------------------
        $display("--- STREAM cnt=1: all PEs active ---");
        ui_in  = 8'h22;   // {a_row1=0x2 (1.0), a_row0=0x2 (1.0)}
        uio_in = 8'h22;   // {w_col1=0x2 (1.0), w_col0=0x2 (1.0)}
        tick;

        //---------------------------------------------------------------------
        // STREAM cnt=2: PE[0][1] and PE[1][0] 2nd MAC; PE[1][1] 1st MAC
        //   H/V_PE_EN[0]=0 (boundary deasserted for row0/col0)
        //   a[1][1] on row1 boundary; w[1][1] on col1 boundary
        //---------------------------------------------------------------------
        $display("--- STREAM cnt=2: row1/col1 tail ---");
        ui_in  = 8'h20;   // {a_row1=0x2 (1.0), a_row0=0x0}
        uio_in = 8'h20;   // {w_col1=0x2 (1.0), w_col0=0x0}
        tick;

        //---------------------------------------------------------------------
        // STREAM cnt=3 (=K+1): PE[1][1] last MAC; quant_en[col0] overlap
        //   col_sel=0: sa_out[col0] -> vector unit (combinational, no flop)
        //   FP4 results for col0 latch into reg_out at end of this cycle
        //   All boundary drives are don't-care (data already in pipeline)
        //---------------------------------------------------------------------
        $display("--- STREAM cnt=3: last MAC + col0 quant ---");
        ui_in  = 8'h00;
        uio_in = 8'h00;
        tick;             // STREAM -> DRAIN

        //---------------------------------------------------------------------
        // DRAIN cnt=0:
        //   uio_out = col0 FP4 results (reg_out latched at end of STREAM cnt=3)
        //   quant_en[col1]=1 this cycle; col_sel=1; col1 results latch at end
        //   uio_oe = 0xFF (bidir flips to output)
        //   Expected: {y_row1_col0, y_row0_col0} = {0x4, 0x4} = 0x44
        //   uo_out: phase=100(4), busy=1, drain_valid=1, drain_col=0, done=0 -> 0x1C
        //---------------------------------------------------------------------
        $display("--- DRAIN cnt=0: col0 output ---");
        chk("DRAIN uio_oe",     uio_oe,  8'hFF);
        chk("DRAIN0 uio_out",   uio_out, 8'h44);   // {row1=0x4, row0=0x4}
        chk("DRAIN0 uo_out",    uo_out,  8'h1C);   // phase=100, busy, dvld, dcol=0, done=0
        tick;

        //---------------------------------------------------------------------
        // DRAIN cnt=1:
        //   uio_out = col1 FP4 results (reg_out latched at end of DRAIN cnt=0)
        //   tile_done pulses this cycle; next cycle -> IDLE
        //   Expected: {y_row1_col1, y_row0_col1} = {0x4, 0x4} = 0x44
        //   uo_out: phase=100, busy=1, drain_valid=1, drain_col=1, done=1 -> 0x7C
        //---------------------------------------------------------------------
        $display("--- DRAIN cnt=1: col1 output + tile_done ---");
        chk("DRAIN1 uio_out",   uio_out, 8'h44);   // {row1=0x4, row0=0x4}
        chk("DRAIN1 uo_out",    uo_out,  8'h7C);   // phase=100, busy, dvld, dcol=1, done=1
        tick;             // DRAIN -> IDLE

        //---------------------------------------------------------------------
        // Back to IDLE
        //---------------------------------------------------------------------
        $display("--- IDLE after tile ---");
        chk("IDLE uo_out",      uo_out,  8'h00);
        chk("IDLE uio_oe",      uio_oe,  8'h00);   // bidir back to input

        //---------------------------------------------------------------------
        // Summary
        //---------------------------------------------------------------------
        $display("");
        $display("=== %0d passed, %0d failed ===", pass_cnt, fail_cnt);
        $display(fail_cnt == 0 ? "ALL PASS" : "FAILURES DETECTED");
        $finish;
    end

    // Watchdog
    initial begin
        #(CLK_PERIOD * 200);
        $display("TIMEOUT");
        $finish;
    end

endmodule