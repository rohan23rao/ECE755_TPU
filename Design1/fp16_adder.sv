`timescale 1ns / 1ps

module fp16_adder (
    input  wire [15:0] op_a,
    input  wire [15:0] op_b,
    output reg  [15:0] result
);

    // Unpack each of the operands
    wire sa = op_a[15];
    wire [4:0]  ea = op_a[14:10];
    wire [9:0]  ma = op_a[9:0];

    wire sb = op_b[15];
    wire [4:0]  eb = op_b[14:10];
    wire [9:0]  mb = op_b[9:0];

    // Zero and Nan Checks
    wire a_is_zero = (ea == 5'd0)  && (ma == 10'd0);
    wire b_is_zero = (eb == 5'd0)  && (mb == 10'd0);
    wire a_is_inf  = (ea == 5'd31) && (ma == 10'd0);
    wire b_is_inf  = (eb == 5'd31) && (mb == 10'd0);
    wire a_is_nan  = (ea == 5'd31) && (ma != 10'd0);
    wire b_is_nan  = (eb == 5'd31) && (mb != 10'd0);

    wire [10:0] sig_a = (ea == 5'd0) ? {1'b0, ma} : {1'b1, ma};
    wire [10:0] sig_b = (eb == 5'd0) ? {1'b0, mb} : {1'b1, mb};

    wire [5:0] eff_ea = (ea == 5'd0) ? 6'd1 : {1'b0, ea};
    wire [5:0] eff_eb = (eb == 5'd0) ? 6'd1 : {1'b0, eb};

    // Compare effective exponents with leading 0/1 and then determine larger/smaller one to swap
  
    wire swap = (eff_eb > eff_ea) || ((eff_eb == eff_ea) && (sig_b > sig_a));

    wire s_lg   = swap ? sb : sa;
    wire s_sm   = swap ? sa : sb;
    wire [5:0]  e_lg   = swap ? eff_eb : eff_ea;
    wire [10:0] sig_lg = swap ? sig_b  : sig_a;
    wire [10:0] sig_sm = swap ? sig_a  : sig_b;

    wire [5:0] exp_diff = e_lg - (swap ? eff_ea : eff_eb);
    wire eff_sub  = s_lg ^ s_sm;

    // Alignment, 
    wire [13:0] sig_lg_ext = {sig_lg, 3'b000};
    wire [4:0]  shift_amt  = (exp_diff > 6'd14) ? 5'd14 : exp_diff[4:0];

    wire [24:0] sm_wide = {sig_sm, 14'd0};
    wire [24:0] sm_shifted_wide = sm_wide >> shift_amt;
    wire [13:0] sig_sm_shifted = sm_shifted_wide[24:11];
    wire sticky_shifted = (|sm_shifted_wide[10:0]) | (exp_diff > 6'd14);

    // Add and subtract
    wire [14:0] sum_raw = eff_sub ? ({1'b0, sig_lg_ext} - {1'b0, sig_sm_shifted} - {14'd0, sticky_shifted}) :
                            ({1'b0, sig_lg_ext} + {1'b0, sig_sm_shifted});

    wire sticky_raw = sum_raw[0] | sticky_shifted;

    // Count leading zeros in the raw sum to determine normalization shift
    reg [3:0] lzc;
    always @(*) begin
        casez (sum_raw[14:1])
            14'b1?????????????: lzc = 4'd0;
            14'b01????????????: lzc = 4'd1;
            14'b001???????????: lzc = 4'd2;
            14'b0001??????????: lzc = 4'd3;
            14'b00001?????????: lzc = 4'd4;
            14'b000001????????: lzc = 4'd5;
            14'b0000001???????: lzc = 4'd6;
            14'b00000001??????: lzc = 4'd7;
            14'b000000001?????: lzc = 4'd8;
            14'b0000000001????: lzc = 4'd9;
            14'b00000000001???: lzc = 4'd10;
            14'b000000000001??: lzc = 4'd11;
            14'b0000000000001?: lzc = 4'd12;
            14'b00000000000001: lzc = 4'd13;
            default:            lzc = 4'd14;
        endcase
    end

    reg [5:0]  norm_exp;
    reg [14:0] norm_shifted;
    reg        norm_sticky;
    reg [3:0]  left_shift_want, left_shift_max;

    always @(*) begin
        norm_exp = 6'd0;
        norm_shifted = 15'd0;
        norm_sticky = sticky_raw;
        left_shift_want = 4'd0;
        left_shift_max = 4'd0;

        if (sum_raw[14:1] == 14'd0) begin
            norm_exp     = 6'd0;
            norm_shifted = 15'd0;
            norm_sticky  = 1'b0;
        end
        else if (lzc == 4'd0) begin
            norm_exp     = e_lg + 6'd1;
            norm_shifted = sum_raw;
            norm_sticky  = sticky_raw | sum_raw[1];
        end
        else if (lzc == 4'd1) begin
            norm_exp = e_lg;
            norm_shifted = sum_raw;
        end
        else begin
            left_shift_want = lzc - 4'd1;

            if (e_lg <= 6'd1)
                left_shift_max = 4'd0;
            else if ({2'b0, left_shift_want} > (e_lg - 6'd1))
                left_shift_max = e_lg[3:0] - 4'd1;
            else
                left_shift_max = left_shift_want;

            norm_shifted = sum_raw << left_shift_max;

            if (left_shift_max == 4'd0)
                norm_exp = e_lg;
            else
                norm_exp = e_lg - {2'b00, left_shift_max};
        end
    end

    // Round based on IEEE 754 round to nearest, ties to even
    wire [10:0] pre_round_sig;
    wire guard_bit, round_bit, final_sticky;

    assign pre_round_sig = (lzc == 4'd0) ? sum_raw[14:4] : norm_shifted[13:3];
    assign guard_bit = (lzc == 4'd0) ? sum_raw[3] : norm_shifted[2];
    assign round_bit = (lzc == 4'd0) ? sum_raw[2] : norm_shifted[1];
    assign final_sticky = norm_sticky | ((lzc == 4'd0) ? (|sum_raw[1:0]) : norm_shifted[0]);

    wire do_round = guard_bit & (round_bit | final_sticky | pre_round_sig[0]);
    wire [11:0] rounded_sig = {1'b0, pre_round_sig} + {11'd0, do_round};

    // Nromalize again if rounding caused overflow
    wire [5:0] post_exp;
    wire [9:0] post_mant;

    assign post_exp = rounded_sig[11]   ? (norm_exp + 6'd1) :
                       (!rounded_sig[10]) ? 6'd0 :
                       (norm_exp == 6'd0) ? 6'd1 :
                       norm_exp;
    assign post_mant = rounded_sig[11] ? rounded_sig[10:1] : rounded_sig[9:0];

    // Use special cases from above and pack the final result

    always @(*) begin
        if (a_is_nan || b_is_nan)
            result = 16'h7FFF;
        else if (a_is_inf && b_is_inf) begin
            if (sa != sb) begin
                result = 16'h7FFF;
            end
            else begin
                result = {sa, 5'b11111, 10'd0};
            end
        end
        else if (a_is_inf)
            result = op_a;
        else if (b_is_inf)
            result = op_b;
        else if (a_is_zero && b_is_zero)
            result = {sa & sb, 15'd0};
        else if (a_is_zero)
            result = op_b;
        else if (b_is_zero)
            result = op_a;
        else if (post_exp >= 6'd31)
            result = {s_lg, 5'b11111, 10'd0};
        else if ((post_exp == 6'd0) && (post_mant == 10'd0) && !rounded_sig[10])
            result = 16'h0000;
        else
            result = {s_lg, post_exp[4:0], post_mant};
    end

endmodule


