`timescale 1ns/1ps
module FixedP2x4_opt (
    input [1:0]     A,
    input [1:0]     B,
    output [3:0]    Out
);

//The logic optimiization here is that A and B will not be considered for the case 
// when either or both are 0

wire A1, A2, B1, B2;
wire O0, O1, O2, O3; 
//Only shared value
wire A1andB1;

assign A1 = A[0];
assign A2 = A[1];
assign B1 = B[0];
assign B2 = B[1];


assign A1andB1 = A1 & B1;
assign O0 = A1andB1;
assign O1 = ((A1 ^ B1) | (A2 ^ B2));
assign O2 = (~A1 & B2) | (~B1 & A2);
assign O3 = A2 & B2 & A1andB1;

assign Out = {O3,O2,O1,O0};

endmodule
