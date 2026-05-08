// fp16_adder_helpers.v
// Only lod_tree_14 remains — ks_sub14, ks_addsub15, and dual_round_11
// were unused (dead code) and have been removed.
// (* keep *) removed from lod_tree_14 to allow yosys inlining/optimization.

module lod_tree_14 (
    input  wire [13:0] din,
    output wire [3:0]  lzc,
    output wire        all_zero
);
    wire [15:0] x;
    assign x = {din, 2'b00};

    wire [7:0] v1, p1;
    assign v1[7] = x[15] | x[14]; assign p1[7] = ~x[15];
    assign v1[6] = x[13] | x[12]; assign p1[6] = ~x[13];
    assign v1[5] = x[11] | x[10]; assign p1[5] = ~x[11];
    assign v1[4] = x[9]  | x[8];  assign p1[4] = ~x[9];
    assign v1[3] = x[7]  | x[6];  assign p1[3] = ~x[7];
    assign v1[2] = x[5]  | x[4];  assign p1[2] = ~x[5];
    assign v1[1] = x[3]  | x[2];  assign p1[1] = ~x[3];
    assign v1[0] = x[1]  | x[0];  assign p1[0] = ~x[1];

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

    assign v4    = v3[1] | v3[0];
    assign p4[3] = ~v3[1];
    assign p4[2] = v3[1] ? p3_1[2] : p3_0[2];
    assign p4[1] = v3[1] ? p3_1[1] : p3_0[1];
    assign p4[0] = v3[1] ? p3_1[0] : p3_0[0];

    assign all_zero = ~v4;
    assign lzc      = v4 ? p4 : 4'd14;

endmodule