`timescale 1ns / 1ps

module kogge_stone_adder_8bit (
    input logic [7:0] A,
    input logic [7:0] B,
    input logic Cin,
    output logic [7:0] Sum,
    output logic Cout
);

    wire [7:0] G0 = A & B;
    wire [7:0] P0 = A ^ B;

    // Level 1: stride 1
    wire [7:0] G1, P1;

    assign G1[0] = G0[0] | (P0[0] & Cin);
    assign P1[0] = P0[0];

    assign G1[1] = G0[1] | (P0[1] & G1[0]);
    assign P1[1] = P0[1] & P0[0];

    genvar i;
    generate
        for (i = 2; i < 8; i = i + 1) begin : level1
            assign G1[i] = G0[i] | (P0[i] & G0[i-1]);
            assign P1[i] = P0[i] & P0[i-1];
        end
    endgenerate

    // Level 2: stride 2
    wire [7:0] G2, P2;

    generate
        for (i = 0; i < 8; i = i + 1) begin : level2
            if (i < 2) begin : pass
                assign G2[i] = G1[i];
                assign P2[i] = P1[i];
            end else begin : merge
                assign G2[i] = G1[i] | (P1[i] & G1[i-2]);
                assign P2[i] = P1[i] & P1[i-2];
            end
        end
    endgenerate

    // Level 3: stride 4
    wire [7:0] G3, P3;

    generate
        for (i = 0; i < 8; i = i + 1) begin : level3
            if (i < 4) begin : pass
                assign G3[i] = G2[i];
                assign P3[i] = P2[i];
            end else begin : merge
                assign G3[i] = G2[i] | (P2[i] & G2[i-4]);
                assign P3[i] = P2[i] & P2[i-4];
            end
        end
    endgenerate

    // Carry Cin into 0, G3[i-1] i > 0
    assign Sum[0] = P0[0] ^ Cin;

    generate
        for (i = 1; i < 8; i = i + 1) begin : sum
            assign Sum[i] = P0[i] ^ G3[i-1];
        end
    endgenerate

    assign Cout = G3[7];

endmodule
