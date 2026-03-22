`timescale 1ns / 1ps

module fp16_adder (
    input  logic [15:0] op_b,

    input  logic        raw_sign,
    input  logic [4:0]  raw_exp,
    input  logic [3:0]  raw_sig,
    input  logic        raw_is_zero,

    output logic [15:0] result
);

    // Unpack op_b
    logic        sb;
    logic [4:0]  eb;
    logic [9:0]  mb;

    assign sb = op_b[15];
    assign eb = op_b[14:10];
    assign mb = op_b[9:0];

    // Zero, Inf, and Nan checks for op_b
    logic b_is_zero, b_is_inf, b_is_nan;

    assign b_is_zero = (eb == 5'd0)  && (mb == 10'd0);
    assign b_is_inf  = (eb == 5'd31) && (mb == 10'd0);
    assign b_is_nan  = (eb == 5'd31) && (mb != 10'd0);

    // Reconstruct full significand of op_b with leading bit
    logic [10:0] sig_b;
    logic [5:0]  eff_eb;

    assign sig_b  = (eb == 5'd0) ? {1'b0, mb} : {1'b1, mb};
    assign eff_eb = (eb == 5'd0) ? 6'd1 : {1'b0, eb};

    // Normalize raw product directly into FP16 to simply additional logic
    logic [10:0] sig_a;
    logic [5:0]  eff_ea;

    always_comb begin
        casez (raw_sig)
            4'b1???: begin
                sig_a  = {1'b1, raw_sig[2:0], 7'b0};
                eff_ea = {1'b0, raw_exp} + 6'd1;
            end
            4'b01??: begin
                sig_a  = {1'b1, raw_sig[1:0], 8'b0};
                eff_ea = {1'b0, raw_exp};
            end
            4'b001?: begin
                sig_a  = {1'b1, raw_sig[0], 9'b0};
                eff_ea = {1'b0, raw_exp} - 6'd1;
            end
            4'b0001: begin
                sig_a  = {1'b1, 10'b0};
                eff_ea = {1'b0, raw_exp} - 6'd2;
            end
            default: begin
                sig_a  = 11'b0;
                eff_ea = 6'd0;
            end
        endcase
    end

    logic sa;
    assign sa = raw_is_zero ? 1'b0 : raw_sign;

    // Compare effective exponents with leading 0/1 and then determine larger/smaller one to swap
    logic        swap;
    logic        s_lg,   s_sm;
    logic [5:0]  e_lg,   e_sm;
    logic [10:0] sig_lg, sig_sm;

    assign swap   = (eff_eb > eff_ea) || ((eff_eb == eff_ea) && (sig_b > sig_a));

    assign s_lg   = swap ? sb     : sa;
    assign s_sm   = swap ? sa     : sb;
    assign e_lg   = swap ? eff_eb : eff_ea;
    assign e_sm   = swap ? eff_ea : eff_eb;
    assign sig_lg = swap ? sig_b  : sig_a;
    assign sig_sm = swap ? sig_a  : sig_b;

    logic [5:0] exp_diff;
    logic       eff_sub;

    assign exp_diff = e_lg - e_sm;
    assign eff_sub  = s_lg ^ s_sm;

    // Select near path for effective subtractions with exponent difference <= 1
    // far path is used\ for all additions and larger difference subtractions (this is dual path adder)
    logic use_near;
    assign use_near = eff_sub && (exp_diff <= 6'd1);

    // Near Path

    // Alignment
    logic [13:0] near_lg_ext, near_sm_ext, near_diff;

    assign near_lg_ext = {sig_lg, 3'b000};
    assign near_sm_ext = (exp_diff == 6'd1) ? {1'b0, sig_sm, 2'b00} : {sig_sm, 3'b000};
    assign near_diff   = near_lg_ext - near_sm_ext;

    // Count leading zeros in the near difference to determine normalization shift
    logic [3:0] near_lzc;

    always_comb begin
        casez (near_diff)
            14'b1?????????????: near_lzc = 4'd0;
            14'b01????????????: near_lzc = 4'd1;
            14'b001???????????: near_lzc = 4'd2;
            14'b0001??????????: near_lzc = 4'd3;
            14'b00001?????????: near_lzc = 4'd4;
            14'b000001????????: near_lzc = 4'd5;
            14'b0000001???????: near_lzc = 4'd6;
            14'b00000001??????: near_lzc = 4'd7;
            14'b000000001?????: near_lzc = 4'd8;
            14'b0000000001????: near_lzc = 4'd9;
            14'b00000000001???: near_lzc = 4'd10;
            14'b000000000001??: near_lzc = 4'd11;
            14'b0000000000001?: near_lzc = 4'd12;
            14'b00000000000001: near_lzc = 4'd13;
            default:            near_lzc = 4'd14;
        endcase
    end

    // Normalize near result
    logic [5:0]  near_exp;
    logic [13:0] near_shifted;
    logic [10:0] near_sig;

    always_comb begin
        near_shifted = 14'd0;
        near_exp     = 6'd0;
        near_sig     = 11'd0;

        if (near_diff != 14'd0) begin
            if ({2'b0, near_lzc} >= e_lg && e_lg > 6'd0) begin
                near_shifted = near_diff << (e_lg - 6'd1);
                near_exp     = 6'd1;
            end else begin
                near_shifted = near_diff << near_lzc;
                near_exp     = e_lg - {2'b0, near_lzc};
            end
            near_sig = near_shifted[13:3];
        end
    end

    // Round based on IEEE 754 round-to-nearest, ties-to-even
    logic [10:0] near_pre_round;
    logic        near_guard, near_round_bit, near_sticky, near_do_round;
    logic [11:0] near_rounded;

    assign near_pre_round = near_sig;
    assign near_guard     = near_shifted[2];
    assign near_round_bit = near_shifted[1];
    assign near_sticky    = near_shifted[0];
    assign near_do_round  = near_guard & (near_round_bit | near_sticky | near_pre_round[0]);
    assign near_rounded   = {1'b0, near_pre_round} + {11'd0, near_do_round};

    // Normalize again if rounding caused overflow
    logic [5:0] near_post_exp;
    logic [9:0] near_post_mant;

    assign near_post_exp  = near_rounded[11]    ? (near_exp + 6'd1) :
                            (!near_rounded[10]) ? 6'd0              :
                            (near_exp == 6'd0)  ? 6'd1              :
                                                   near_exp;
    assign near_post_mant = near_rounded[11] ? near_rounded[10:1] : near_rounded[9:0];

    // Far Path

    // Alignment
    logic [13:0] far_lg_ext, far_sm_aligned;
    logic [4:0]  far_shift;
    logic [24:0] far_sm_wide, far_sm_shifted;
    logic        far_sticky_shift;

    assign far_lg_ext      = {sig_lg, 3'b000};
    assign far_shift       = (exp_diff > 6'd14) ? 5'd14 : exp_diff[4:0];
    assign far_sm_wide     = {sig_sm, 14'd0};
    assign far_sm_shifted  = far_sm_wide >> far_shift;
    assign far_sm_aligned  = far_sm_shifted[24:11];
    assign far_sticky_shift = (|far_sm_shifted[10:0]) | (exp_diff > 6'd14);

    // Add or subtract the aligned significands
    logic [14:0] far_sum;
    logic        far_sticky_raw;

    assign far_sum = eff_sub
        ? ({1'b0, far_lg_ext} - {1'b0, far_sm_aligned} - {14'd0, far_sticky_shift})
        : ({1'b0, far_lg_ext} + {1'b0, far_sm_aligned});

    assign far_sticky_raw = far_sum[0] | far_sticky_shift;

    // 1-bit normalization of the far sum
    logic [5:0]  far_norm_exp;
    logic [14:0] far_norm_sum;
    logic        far_norm_sticky;

    always_comb begin
        if (far_sum[14]) begin
            far_norm_exp    = e_lg + 6'd1;
            far_norm_sum    = far_sum;
            far_norm_sticky = far_sticky_raw | far_sum[1];
        end else if (!far_sum[13]) begin
            if (e_lg > 6'd1) begin
                far_norm_exp = e_lg - 6'd1;
                far_norm_sum = far_sum << 1;
            end else begin
                far_norm_exp = e_lg;
                far_norm_sum = far_sum;
            end
            far_norm_sticky = far_sticky_raw;
        end else begin
            far_norm_exp    = e_lg;
            far_norm_sum    = far_sum;
            far_norm_sticky = far_sticky_raw;
        end
    end

    // Round based on IEEE 754 round-to-nearest, ties-to-even
    logic [10:0] far_pre_round;
    logic        far_guard, far_round_bit, far_final_sticky, far_do_round;
    logic [11:0] far_rounded;

    assign far_pre_round    = far_sum[14] ? far_norm_sum[14:4] : far_norm_sum[13:3];
    assign far_guard        = far_sum[14] ? far_norm_sum[3]    : far_norm_sum[2];
    assign far_round_bit    = far_sum[14] ? far_norm_sum[2]    : far_norm_sum[1];
    assign far_final_sticky = far_norm_sticky
                            | (far_sum[14] ? (|far_norm_sum[1:0]) : far_norm_sum[0]);

    assign far_do_round = far_guard & (far_round_bit | far_final_sticky | far_pre_round[0]);
    assign far_rounded  = {1'b0, far_pre_round} + {11'd0, far_do_round};

    // Normalize again if rounding caused overflow
    logic [5:0] far_post_exp;
    logic [9:0] far_post_mant;

    assign far_post_exp  = far_rounded[11]        ? (far_norm_exp + 6'd1) :
                           (!far_rounded[10])      ? 6'd0                  :
                           (far_norm_exp == 6'd0)  ? 6'd1                  :
                                                      far_norm_exp;
    assign far_post_mant = far_rounded[11] ? far_rounded[10:1] : far_rounded[9:0];

    // Select near or far path result
    logic [5:0] post_exp;
    logic [9:0] post_mant;

    assign post_exp  = use_near ? near_post_exp  : far_post_exp;
    assign post_mant = use_near ? near_post_mant : far_post_mant;

    // Determine special cases and pack final result
    always_comb begin
        if (b_is_nan)
            result = 16'h7FFF;
        else if (b_is_inf)
            result = op_b;
        else if (raw_is_zero && b_is_zero)
            result = {sa & sb, 15'd0};
        else if (raw_is_zero)
            result = op_b;
        else if (b_is_zero) begin
            if (eff_ea >= 6'd31)
                result = {raw_sign, 5'b11111, 10'd0};
            else
                result = {raw_sign, eff_ea[4:0], sig_a[9:0]};
        end
        else if (post_exp >= 6'd31)
            result = {s_lg, 5'b11111, 10'd0};
        else if ((post_exp == 6'd0) && (post_mant == 10'd0))
            result = 16'h0000;
        else
            result = {s_lg, post_exp[4:0], post_mant};
    end

endmodule
