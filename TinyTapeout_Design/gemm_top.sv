module gemm_top (
    input  logic [7:0] ui_in,    // Inputs
    output logic [7:0] uo_out,   // Outputs
    input  logic [7:0] uio_in,   // Bi-directional (as input)
    output logic [7:0] uio_out,  // Bi-directional (as output)
    output logic [7:0] uio_oe,   // Bi-directional (enable)
    input  logic       ena,      // TT enable
    input  logic       clk,
    input  logic       rst_n
);
    // Internal Signals
    logic [7:0] uart_data;
    logic       uart_valid;
    logic [15:0] bias_reg, scale_reg;
    logic [15:0] acc_out;
    logic [3:0]  y_out;
    
    // FSM Control Signals
    logic pe_en, ld_bias, quant_en, relu_en, res_valid;
    logic bias_hi_wen, bias_lo_wen, scale_hi_wen, scale_lo_wen;
    logic [2:0] state_bits;

    // 1. UART Receiver
    uart_rx #(.CLK_FREQ(25_000_000), .BAUD_RATE(115_200)) u_uart (
        .clk(clk), .rst_n(rst_n),
        .rx(ui_in[0]), .data_out(uart_data), .byte_ready(uart_valid)
    );

    // 2. FSM Controller
    tt_gemm_fsm u_fsm (
        .clk(clk), .rst_n(rst_n),
        .byte_valid(uart_valid),       // UART byte triggers FSM 
        .stream_done(uio_in[1]),       // From external pin 
        .data_byte(uart_data),         // From UART
        .pe_en(pe_en), .ld_bias(ld_bias),
        .quant_en(quant_en), .relu_en_out(relu_en),
        .bias_hi_wen(bias_hi_wen), .bias_lo_wen(bias_lo_wen),
        .scale_hi_wen(scale_hi_wen), .scale_lo_wen(scale_lo_wen),
        .result_valid(res_valid), .state_out(state_bits)
    );

    // 3. Holding Registers (Bias and Scale)
    // Captured during LOAD state
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bias_reg  <= 16'h0000;
            scale_reg <= 16'h0000;
        end else begin
            if (bias_hi_wen)  bias_reg[15:8] <= uart_data;
            if (bias_lo_wen)  bias_reg[7:0]  <= uart_data;
            if (scale_hi_wen) scale_reg[15:8] <= uart_data;
            if (scale_lo_wen) scale_reg[7:0]  <= uart_data;
        end
    end

    // 4. Processing Element (MAC)
    gemm_pe u_pe (
        .clk(clk),
        .a_in(uart_data[7:4]),         // A from high nibble
        .w_in(uart_data[3:0]),         // W from low nibble
        .bias(bias_reg), .ld_bias(ld_bias),
        .pe_en(pe_en), .data_vld(uart_valid),
        .acc_out(acc_out)              // FP16 output
    );

    // 5. Vector Unit (Quantizer)
    vector_unit u_vu (
        .clk(clk), .relu_en(relu_en), .quant_en(quant_en),
        .col_out(acc_out), .scale(scale_reg), .y_out(y_out)
    );

    // Pin Assignments
    assign uo_out[3:0] = y_out;         // Result nibble
    assign uo_out[4]   = res_valid;     // Ready flag 
    assign uo_out[7:5] = state_bits;    // Debug state 

    // Set all UIO to inputs (except those you specifically want as flags)
    assign uio_oe  = 8'b0000_0000; 
    assign uio_out = 8'b0000_0000;
endmodule