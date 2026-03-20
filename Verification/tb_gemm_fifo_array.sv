///////////////////////////////////////////////////////////////////////////////
// Module: tb_gemm_fifo_array.sv
// Description: Testbench for gemm_fifo_array. Tests two scenarios:
//
//   Test 1 — Full 8x8: All 8 FIFOs active, K=8 write cycles then read back
//   Test 2 — Partial 4x5: Only FIFOs 0-3 active (write_en=00001111),
//             K=5 write cycles then read back, verify inactive FIFOs silent
//
// Note: data_out is combinational (assign read_en ? mem[read_ptr] : 0)
//       so output is valid same cycle read_en is asserted.
//       read_ptr increments on the following clock edge.
//
// Author: Group5
///////////////////////////////////////////////////////////////////////////////

`timescale 1ns/1ps
import gemm_pkg::*;

module tb_gemm_fifo_array;

    ///////////////////////////////////////////////////////////////////////////
    // DUT signals
    ///////////////////////////////////////////////////////////////////////////
    logic                       clk;
    logic                       rst_n;
    logic [ACT_WIDTH-1:0]       data_in  [0:ARRAY_SIZE-1];
    logic [ARRAY_SIZE-1:0]      write_en;
    logic [FIFO_ADDR_WIDTH-1:0] write_ptr;
    logic [ARRAY_SIZE-1:0]      read_en;
    logic [ACT_WIDTH-1:0]       data_out [0:ARRAY_SIZE-1];

    ///////////////////////////////////////////////////////////////////////////
    // DUT instantiation
    ///////////////////////////////////////////////////////////////////////////
    gemm_fifo_array dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .data_in   (data_in),
        .write_en  (write_en),
        .write_ptr (write_ptr),
        .read_en   (read_en),
        .data_out  (data_out)
    );

    ///////////////////////////////////////////////////////////////////////////
    // Clock — 10ns period
    ///////////////////////////////////////////////////////////////////////////
    initial clk = 0;
    always #5 clk = ~clk;

    ///////////////////////////////////////////////////////////////////////////
    // Test tracking
    ///////////////////////////////////////////////////////////////////////////
    int pass_count;
    int fail_count;

    // Expected storage — mirrors what we wrote into each FIFO
    logic [ACT_WIDTH-1:0] expected [0:ARRAY_SIZE-1][0:FIFO_DEPTH-1];

    ///////////////////////////////////////////////////////////////////////////
    // Task: reset
    ///////////////////////////////////////////////////////////////////////////
    task do_reset();
        rst_n     = 0;
        write_en  = '0;
        write_ptr = '0;
        read_en   = '0;
        data_in   = '{default: '0};
        @(posedge clk); #1;
        @(posedge clk); #1;
        rst_n = 1;
        @(posedge clk); #1;
    endtask

    ///////////////////////////////////////////////////////////////////////////
    // Task: write one k-slice across all active FIFOs
    //   active_mask : which FIFOs to write (matches write_en)
    //   k_idx       : which write_ptr slot to write into
    ///////////////////////////////////////////////////////////////////////////
    task write_slice(
        input logic [ARRAY_SIZE-1:0]      active_mask,
        input logic [FIFO_ADDR_WIDTH-1:0] k_idx,
        input logic [ACT_WIDTH-1:0]       values [0:ARRAY_SIZE-1]
    );
        write_en  = active_mask;
        write_ptr = k_idx;
        for (int i = 0; i < ARRAY_SIZE; i++) begin
            data_in[i] = values[i];
            // only save expected for active FIFOs
            if (active_mask[i])
                expected[i][k_idx] = values[i];
        end
        @(posedge clk); #1;
        write_en = '0;
    endtask

    ///////////////////////////////////////////////////////////////////////////
    // Task: read one k-slice and check outputs
    //   active_mask : which FIFOs to read
    //   k_idx       : which slot we expect to read (tracks read_ptr per FIFO)
    //   label       : test name for display
    ///////////////////////////////////////////////////////////////////////////
    task read_and_check(
        input logic [ARRAY_SIZE-1:0] active_mask,
        input logic [FIFO_ADDR_WIDTH-1:0] k_idx,
        input string label
    );
        read_en = active_mask;
        // data_out is combinational — valid same cycle read_en asserted
        #1; // small settle time
        for (int i = 0; i < ARRAY_SIZE; i++) begin
            if (active_mask[i]) begin
                if (data_out[i] === expected[i][k_idx]) begin
                    $display("  PASS [%s] FIFO[%0d] k=%0d: got 0x%02h",
                             label, i, k_idx, data_out[i]);
                    pass_count++;
                end else begin
                    $display("  FAIL [%s] FIFO[%0d] k=%0d: expected 0x%02h got 0x%02h",
                             label, i, k_idx, expected[i][k_idx], data_out[i]);
                    fail_count++;
                end
            end else begin
                // inactive FIFO — should output 0 since read_en=0
                if (data_out[i] === '0) begin
                    $display("  PASS [%s] FIFO[%0d] inactive: output=0 correct",
                             label, i);
                    pass_count++;
                end else begin
                    $display("  FAIL [%s] FIFO[%0d] inactive: expected 0 got 0x%02h",
                             label, i, data_out[i]);
                    fail_count++;
                end
            end
        end
        @(posedge clk); #1;  // read_ptr increments here
        read_en = '0;
    endtask

    ///////////////////////////////////////////////////////////////////////////
    // Main test sequence
    ///////////////////////////////////////////////////////////////////////////
    initial begin
        pass_count = 0;
        fail_count = 0;
        expected   = '{default: '{default: '0}};

        $display("============================================================");
        $display(" GEMM FIFO Array Testbench");
        $display("============================================================");

        do_reset();

        ///////////////////////////////////////////////////////////////////
        // TEST 1 — Full 8x8: all 8 FIFOs, K=8 write cycles
        ///////////////////////////////////////////////////////////////////
        $display("\n[ TEST 1 ] Full 8x8 — write_en=11111111, K=8");
        $display("------------------------------------------------------------");
        $display("  Writing 8 slices across all 8 FIFOs...");

        begin
            logic [ACT_WIDTH-1:0] vals [0:ARRAY_SIZE-1];
            // Write K=8 slices — each value encodes (fifo_idx << 4 | k_idx)
            // so FIFO[2] k=3 → 0x23, easy to spot in waveforms
            for (int k = 0; k < 8; k++) begin
                for (int i = 0; i < ARRAY_SIZE; i++)
                    vals[i] = (i << 4) | k;
                write_slice(8'hFF, k[FIFO_ADDR_WIDTH-1:0], vals);
            end
        end

        $display("  Reading back 8 slices from all 8 FIFOs...");
        for (int k = 0; k < 8; k++)
            read_and_check(8'hFF, k[FIFO_ADDR_WIDTH-1:0], "T1-8x8");

        ///////////////////////////////////////////////////////////////////
        // TEST 2 — Partial 4x5: FIFOs 0-3 active, K=5 write cycles
        ///////////////////////////////////////////////////////////////////
        $display("\n[ TEST 2 ] Partial 4x5 — write_en=00001111, K=5");
        $display("------------------------------------------------------------");

        // Reset so read_ptrs return to 0
        do_reset();

        $display("  Writing 5 slices to FIFOs 0-3 only...");
        begin
            logic [ACT_WIDTH-1:0] vals [0:ARRAY_SIZE-1];
            for (int k = 0; k < 5; k++) begin
                for (int i = 0; i < ARRAY_SIZE; i++)
                    // upper FIFOs get dummy data — write_en gates them out
                    vals[i] = (i < 4) ? ((i << 4) | (k + 8'h10)) : 8'hFF;
                write_slice(8'h0F, k[FIFO_ADDR_WIDTH-1:0], vals);
            end
        end

        $display("  Reading back 5 slices from FIFOs 0-3, checking FIFOs 4-7 silent...");
        for (int k = 0; k < 5; k++)
            read_and_check(8'h0F, k[FIFO_ADDR_WIDTH-1:0], "T2-4x5");

        ///////////////////////////////////////////////////////////////////
        // TEST 3 — Verify read_ptr independence after Test 2
        // FIFOs 0-3 have read_ptr=5, FIFOs 4-7 have read_ptr=0
        // Write one more slice to ALL 8 FIFOs at ptr=5 for 0-3, ptr=0 for 4-7
        ///////////////////////////////////////////////////////////////////
        $display("\n[ TEST 3 ] Read pointer independence check");
        $display("------------------------------------------------------------");

        begin
            logic [ACT_WIDTH-1:0] vals [0:ARRAY_SIZE-1];

            // Write to FIFOs 0-3 at slot 5 (their current write_ptr would be 5)
            $display("  Writing slice at ptr=5 to FIFOs 0-3...");
            for (int i = 0; i < ARRAY_SIZE; i++)
                vals[i] = 8'hA0 | i;
            write_slice(8'h0F, 3'd5, vals);

            // Write to FIFOs 4-7 at slot 0 (fresh, never written)
            $display("  Writing slice at ptr=0 to FIFOs 4-7...");
            for (int i = 0; i < ARRAY_SIZE; i++)
                vals[i] = 8'hB0 | i;
            write_slice(8'hF0, 3'd0, vals);

            // Read FIFOs 0-3 — their read_ptr is at 5
            $display("  Reading FIFOs 0-3 at their current read_ptr (5)...");
            read_and_check(8'h0F, 3'd5, "T3-ptr-indep-0to3");

            // Read FIFOs 4-7 — their read_ptr is still at 0
            $display("  Reading FIFOs 4-7 at their current read_ptr (0)...");
            read_and_check(8'hF0, 3'd0, "T3-ptr-indep-4to7");
        end

        ///////////////////////////////////////////////////////////////////
        // Summary
        ///////////////////////////////////////////////////////////////////
        $display("\n============================================================");
        $display(" Results: %0d PASSED, %0d FAILED", pass_count, fail_count);
        $display("============================================================");

        if (fail_count == 0)
            $display(" ALL TESTS PASSED");
        else
            $display(" FAILURES DETECTED — check above");

        $stop;
    end

    ///////////////////////////////////////////////////////////////////////////
    // Timeout watchdog — 10000 cycles max
    ///////////////////////////////////////////////////////////////////////////
    initial begin
        #100000;
        $display("TIMEOUT — simulation exceeded limit");
        $stop;
    end


endmodule