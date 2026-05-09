`timescale 1ns/1ps

module tb_tt_um_gemm_top;

    // --- Signals ---
    logic clk;
    logic rst_n;
    logic ena;
    logic [7:0] ui_in;
    logic [7:0] uo_out;
    logic [7:0] uio_in;
    logic [7:0] uio_out;
    logic [7:0] uio_oe;

    // UART Parameters
    localparam CLK_FREQ = 25_000_000;
    localparam BAUD_RATE = 115_200;
    localparam bit_period = 1_000_000_000 / BAUD_RATE; // in ns

    // --- Clock Generation (25MHz) ---
    initial clk = 0;
    always #20 clk = ~clk; // 20ns half-period = 25MHz

    // --- Device Under Test (DUT) ---
    gemm_top dut (
        .ui_in(ui_in),
        .uo_out(uo_out),
        .uio_in(uio_in),
        .uio_out(uio_out),
        .uio_oe(uio_oe),
        .ena(ena),
        .clk(clk),
        .rst_n(rst_n)
    );

    // --- UART Helper Task ---
    task automatic send_uart_byte(input [7:0] data);
        integer i;
        begin
            // Start Bit
            ui_in[0] = 1'b0;
            #(bit_period);
            
            // 8 Data Bits (LSB first for standard UART)
            for (i = 0; i < 8; i = i + 1) begin
                ui_in[0] = data[i];
                #(bit_period);
            end
            
            // Stop Bit
            ui_in[0] = 1'b1;
            #(bit_period);
            
            // Wait a few clocks to allow FSM to transition safely
            #500; 
        end
    endtask

    // --- Main Simulation ---
    initial begin
        // Initialize
        rst_n = 0;
        ena = 1;
        ui_in = 8'hFF;      // UART idle is high
        uio_in = 8'h00;     // stream_done (bit 1) low
        
        $display("Starting GEMM 1x1 UART Testbench...");
        #200;
        rst_n = 1;
        #200;

        // 1. Send CONFIG Byte
        // Bit 0: BIAS_NEW=1
        // Bit 1: SCALE_NEW=1
        // Bit 2: RELU_EN=1
        $display("Sending Config: New Bias, New Scale, Relu enabled (0x07)");
        send_uart_byte(8'b0000_0111); 

        // 2. Send BIAS (2 bytes for FP16 - MSB FIRST per FSM logic)
        // FP16(1.0) is 16'h3C00
        $display("Sending Bias: 16'h3C00");
        send_uart_byte(8'h3C); // High byte
        send_uart_byte(8'h00); // Low byte

        // 3. Send SCALE (2 bytes for FP16 - MSB FIRST per FSM logic)
        $display("Sending Scale: 16'h3C00");
        send_uart_byte(8'h3C); // High byte
        send_uart_byte(8'h00); // Low byte

        // 4. Send STREAM Data (Inputs and Weights)
        // Format: [7:4] Input A, [3:0] Weight W (using FP4(1.0) = 0x2)
        $display("Streaming 3 MAC operations...");
        send_uart_byte(8'h22); // MAC 1
        send_uart_byte(8'h22); // MAC 2
        
        // 5. Signal Stream Done
        // MUST be asserted *before* the final byte finishes so the FSM captures 
        // stream_done and byte_valid simultaneously!
        $display("Signaling Stream Done for the final MAC...");
        uio_in[1] = 1'b1; 
        
        send_uart_byte(8'h22); // MAC 3 (Last operation)
        
        // Safely deassert stream_done now that byte was sent
        #500;
        uio_in[1] = 1'b0;

        // 6. Monitor Result
        // Wait for uo_out[4] (result_valid)
        wait(uo_out[4] == 1'b1);
        $display("Result Received (y_out): %h", uo_out[3:0]);
        
        #100;
        $display("Test Complete.");
        $stop;
    end

    // Monitor internal state for debugging
    initial begin
        $monitor("Time: %0t | State: %b | Output y_out: %h | result_valid: %b", 
                 $time, uo_out[7:5], uo_out[3:0], uo_out[4]);
    end

endmodule