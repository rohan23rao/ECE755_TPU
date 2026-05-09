module uart_rx #(
    parameter CLK_FREQ = 25_000_000,
    parameter BAUD_RATE = 115_200
)(
    input  logic       clk,
    input  logic       rst_n,
    input  logic       rx,
    output logic [7:0] data_out,
    output logic       byte_ready
);
    localparam int CLKS_PER_BIT = CLK_FREQ / BAUD_RATE;

    typedef enum logic [1:0] {IDLE, START, DATA, STOP} uart_state_t;
    uart_state_t state;

    logic [15:0] clk_cnt;
    logic [2:0]  bit_idx;
    logic [7:0]  shifter;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= IDLE;
            byte_ready <= 1'b0;
            clk_cnt    <= 0;
        end else begin
            byte_ready <= 1'b0;
            case (state)
                IDLE: begin
                    if (rx == 1'b0) begin // Start bit detected
                        clk_cnt <= 0;
                        state   <= START;
                    end
                end
                START: begin
                    if (clk_cnt == (CLKS_PER_BIT/2)) begin
                        clk_cnt <= 0;
                        state   <= DATA;
                        bit_idx <= 0;
                    end else clk_cnt <= clk_cnt + 1;
                end
                DATA: begin
                    if (clk_cnt == CLKS_PER_BIT-1) begin
                        clk_cnt <= 0;
                        shifter[bit_idx] <= rx;
                        if (bit_idx == 7) state <= STOP;
                        else bit_idx <= bit_idx + 1;
                    end else clk_cnt <= clk_cnt + 1;
                end
                STOP: begin
                    if (clk_cnt == CLKS_PER_BIT-1) begin
                        data_out   <= shifter;
                        byte_ready <= 1'b1;
                        state      <= IDLE;
                    end else clk_cnt <= clk_cnt + 1;
                end
            endcase
        end
    end
endmodule