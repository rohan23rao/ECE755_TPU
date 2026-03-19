`timescale 1ns/1ps
module FixedP2x4 (
    input [1:0]     A,
    input [1:0]     B,
    output [3:0]    Out
);

//THIS IS AI SLOP I DIDNT DO IT

// MUX for P[0] (The LSB)
    // If A=01 and B=01, P[0]=1. If A=11 and B=01, P[0]=1. If A=11 and B=11, P[0]=1.
    assign Out[0] = (A == 2'b01) ? B[0] : 
                  (A == 2'b11) ? B[0] : 1'b0;

    // MUX for P[1]
    assign Out[1] = (A == 2'b01) ? B[1] :
                  (A == 2'b10) ? B[0] :
                  (A == 2'b11) ? (~B[1] & B[0]) | (B[1] & ~B[0]) : 1'b0;

    // MUX for P[2]
    assign Out[2] = (A == 2'b10) ? B[1] :
                  (A == 2'b11) ? B[1] & ~B[0] : 1'b0;

    // MUX for P[3] (The MSB)
    // Only high when 1.5 * 1.5 = 2.25 (11 * 11 = 1001)
    assign Out[3] = (A == 2'b11 && B == 2'b11) ? 1'b1 : 1'b0;

endmodule
