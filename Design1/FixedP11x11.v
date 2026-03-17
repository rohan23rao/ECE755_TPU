`timescale 1ns/1ps
module FixedP11x11 #(
    parameter INPUT_WIDTH = 11,
    parameter OUTPUT_WIDTH = 22
)(
    input wire [INPUT_WIDTH-1:0]    A,
    input wire [INPUT_WIDTH-1:0]    B,
    output wire [OUTPUT_WIDTH-1:0]  Out
);

// 11x11 Fixed Point Multiplier
// Input format: Q1.10 (1 integer bit, 10 fractional bits)
// Output format: Q2.20 (2 integer bits, 20 fractional bits)
// Used for FP16 mantissa multiplication (including hidden bit)

// Behavioral implementation for clarity and correctness
// This is the actual working implementation
reg [OUTPUT_WIDTH-1:0] product_reg;

always @(*) begin
    product_reg = A * B;  // Simple multiplication
end

assign Out = product_reg;

endmodule
