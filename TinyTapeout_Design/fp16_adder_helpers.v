
(* keep *)
module ks_sub14 (
    input  wire [13:0] a,
    input  wire [13:0] b,
    output wire [13:0] diff
);
    wire [13:0] b_bar;
    assign b_bar = ~b;

    wire [13:0] g0, p0;
    assign g0 = a & b_bar;
    assign p0 = a ^ b_bar;

    wire [13:0] g1, p1;
    assign g1[0]    = g0[0];
    assign p1[0]    = p0[0];
    assign g1[13:1] = g0[13:1] | (p0[13:1] & g0[12:0]);
    assign p1[13:1] = p0[13:1] & p0[12:0];

    wire [13:0] g2, p2;
    assign g2[1:0]  = g1[1:0];
    assign p2[1:0]  = p1[1:0];
    assign g2[13:2] = g1[13:2] | (p1[13:2] & g1[11:0]);
    assign p2[13:2] = p1[13:2] & p1[11:0];

    wire [13:0] g3, p3;
    assign g3[3:0]  = g2[3:0];
    assign p3[3:0]  = p2[3:0];
    assign g3[13:4] = g2[13:4] | (p2[13:4] & g2[9:0]);
    assign p3[13:4] = p2[13:4] & p2[9:0];

    wire [13:0] g4, p4;
    assign g4[7:0]  = g3[7:0];
    assign p4[7:0]  = p3[7:0];
    assign g4[13:8] = g3[13:8] | (p3[13:8] & g3[5:0]);
    assign p4[13:8] = p3[13:8] & p3[5:0];

    wire [13:0] carry;
    assign carry = g4 | p4;

    assign diff[0]    = p0[0] ^ 1'b1;
    assign diff[13:1] = p0[13:1] ^ carry[12:0];

endmodule

(* keep *)
module ks_addsub15 (
    input  wire [14:0] a,
    input  wire [14:0] b,
    input  wire        mode_sub,
    input  wire        borrow_in,
    output wire [14:0] result
);
    wire [14:0] b_eff;
    assign b_eff = mode_sub ? ~b : b;

    wire cin;
    assign cin = mode_sub & ~borrow_in;

    wire [14:0] g0, p0;
    assign g0 = a & b_eff;
    assign p0 = a ^ b_eff;

    wire [14:0] g1, p1;
    assign g1[0]    = g0[0];
    assign p1[0]    = p0[0];
    assign g1[14:1] = g0[14:1] | (p0[14:1] & g0[13:0]);
    assign p1[14:1] = p0[14:1] & p0[13:0];

    wire [14:0] g2, p2;
    assign g2[1:0]  = g1[1:0];
    assign p2[1:0]  = p1[1:0];
    assign g2[14:2] = g1[14:2] | (p1[14:2] & g1[12:0]);
    assign p2[14:2] = p1[14:2] & p1[12:0];

    wire [14:0] g3, p3;
    assign g3[3:0]  = g2[3:0];
    assign p3[3:0]  = p2[3:0];
    assign g3[14:4] = g2[14:4] | (p2[14:4] & g2[10:0]);
    assign p3[14:4] = p2[14:4] & p2[10:0];

    wire [14:0] g4, p4;
    assign g4[7:0]  = g3[7:0];
    assign p4[7:0]  = p3[7:0];
    assign g4[14:8] = g3[14:8] | (p3[14:8] & g3[6:0]);
    assign p4[14:8] = p3[14:8] & p3[6:0];

    wire [14:0] carry;
    assign carry = g4 | (p4 & {15{cin}});

    assign result[0]    = p0[0] ^ cin;
    assign result[14:1] = p0[14:1] ^ carry[13:0];

endmodule


(* keep = 1 *)
module lod_tree_14 (
    input  wire [13:0] din,
    output wire [3:0]  lzc,
    output wire        all_zero
);
    wire [15:0] x;
    assign x = {din, 2'b00};

    wire [7:0] v1;
    wire [7:0] p1;

    assign v1[7] = x[15] | x[14];   
    assign p1[7] = ~x[15];
    assign v1[6] = x[13] | x[12];   
    assign p1[6] = ~x[13];
    assign v1[5] = x[11] | x[10];
    assign p1[5] = ~x[11];
    assign v1[4] = x[9]  | x[8];    
    assign p1[4] = ~x[9];
    assign v1[3] = x[7]  | x[6];    
    assign p1[3] = ~x[7];
    assign v1[2] = x[5]  | x[4];    
    assign p1[2] = ~x[5];
    assign v1[1] = x[3]  | x[2];    
    assign p1[1] = ~x[3];
    assign v1[0] = x[1]  | x[0];    
    assign p1[0] = ~x[1];

    wire [3:0] v2;
    wire [1:0] p2_3, p2_2, p2_1, p2_0;

    assign v2[3]   = v1[7] | v1[6];
    assign p2_3[1] = ~v1[7];
    assign p2_3[0] = v1[7] ? p1[7] : p1[6];

    assign v2[2]   = v1[5] | v1[4];
    assign p2_2[1] = ~v1[5];
    assign p2_2[0] = v1[5] ? p1[5] : p1[4];

    assign v2[1]   = v1[3] | v1[2];
    assign p2_1[1] = ~v1[3];
    assign p2_1[0] = v1[3] ? p1[3] : p1[2];

    assign v2[0]   = v1[1] | v1[0];
    assign p2_0[1] = ~v1[1];
    assign p2_0[0] = v1[1] ? p1[1] : p1[0];

    wire [1:0] v3;
    wire [2:0] p3_1, p3_0;

    assign v3[1]   = v2[3] | v2[2];
    assign p3_1[2] = ~v2[3];
    assign p3_1[1] = v2[3] ? p2_3[1] : p2_2[1];
    assign p3_1[0] = v2[3] ? p2_3[0] : p2_2[0];

    assign v3[0]   = v2[1] | v2[0];
    assign p3_0[2] = ~v2[1];
    assign p3_0[1] = v2[1] ? p2_1[1] : p2_0[1];
    assign p3_0[0] = v2[1] ? p2_1[0] : p2_0[0];

    wire       v4;
    wire [3:0] p4;

    assign v4   = v3[1] | v3[0];
    assign p4[3] = ~v3[1];
    assign p4[2] = v3[1] ? p3_1[2] : p3_0[2];
    assign p4[1] = v3[1] ? p3_1[1] : p3_0[1];
    assign p4[0] = v3[1] ? p3_1[0] : p3_0[0];

    assign all_zero = ~v4;
    assign lzc = v4 ? p4 : 4'd14;

endmodule
// module lod_tree_14 (
//     input  wire [13:0] din,
//     output reg  [3:0]  lzc,
//     output wire        all_zero
// );

//     assign all_zero = (din == 14'd0);

//     always @(*) begin
//         casez (din)
//             14'b1?????????????: lzc = 4'd0;
//             14'b01????????????: lzc = 4'd1;
//             14'b001???????????: lzc = 4'd2;
//             14'b0001??????????: lzc = 4'd3;
//             14'b00001?????????: lzc = 4'd4;
//             14'b000001????????: lzc = 4'd5;
//             14'b0000001???????: lzc = 4'd6;
//             14'b00000001??????: lzc = 4'd7;
//             14'b000000001?????: lzc = 4'd8;
//             14'b0000000001????: lzc = 4'd9;
//             14'b00000000001???: lzc = 4'd10;
//             14'b000000000001??: lzc = 4'd11;
//             14'b0000000000001?: lzc = 4'd12;
//             14'b00000000000001: lzc = 4'd13;
//             default:            lzc = 4'd14;
//         endcase
//     end

// endmodule

// module dual_round_11 (
//     input  wire [10:0] sig,
//     input  wire        do_round,
//     output wire [11:0] rounded
// );

//     assign rounded = {1'b0, sig} + {11'd0, do_round};

// endmodule


(* keep = 1 *)
module dual_round_11 (
    input  wire [10:0] sig,
    input  wire        do_round,
    output wire [11:0] rounded
);
    wire [10:0] a0;
    assign a0 = sig;

    wire [10:0] a1;
    assign a1[0]    = a0[0];
    assign a1[10:1] = a0[10:1] & a0[9:0];

    wire [10:0] a2;
    assign a2[1:0]  = a1[1:0];
    assign a2[10:2] = a1[10:2] & a1[8:0];

    wire [10:0] a3;
    assign a3[3:0]  = a2[3:0];
    assign a3[10:4] = a2[10:4] & a2[6:0];

    wire [10:0] a4;
    assign a4[7:0]  = a3[7:0];
    assign a4[10:8] = a3[10:8] & a3[2:0];

    wire [10:0] inc;
    wire        overflow;

    assign inc[0]    = ~sig[0];
    assign inc[10:1] = sig[10:1] ^ a4[9:0];
    assign overflow  = a4[10];

    assign rounded = do_round ? {overflow, inc} : {1'b0, sig};

endmodule