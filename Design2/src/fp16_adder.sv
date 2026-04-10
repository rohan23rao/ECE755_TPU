
module fp16_adder (
    input  wire [15:0] op_a,
    input  wire [15:0] op_b,
    output reg  [15:0] result
);

    // Unpack op_a
    wire sa = op_a[15];
    wire [4:0]  ea = op_a[14:10];
    wire [9:0]  ma = op_a[9:0];

    // Unpack op_b
    wire sb = op_b[15];
    wire [4:0]  eb = op_b[14:10];
    wire [9:0]  mb = op_b[9:0];

    // Zero, Inf, and Nan checks
    wire a_is_zero = (ea == 5'd0)  && (ma == 10'd0);
    wire b_is_zero = (eb == 5'd0)  && (mb == 10'd0);
    wire a_is_inf  = (ea == 5'd31) && (ma == 10'd0);
    wire b_is_inf  = (eb == 5'd31) && (mb == 10'd0);
    wire a_is_nan  = (ea == 5'd31) && (ma != 10'd0);
    wire b_is_nan  = (eb == 5'd31) && (mb != 10'd0);

    // Reconstruct full significands with leading bit
    wire [10:0] sig_a = (ea == 5'd0) ? {1'b0, ma} : {1'b1, ma};
    wire [10:0] sig_b = (eb == 5'd0) ? {1'b0, mb} : {1'b1, mb};

    wire [5:0] eff_ea = (ea == 5'd0) ? 6'd1 : {1'b0, ea};
    wire [5:0] eff_eb = (eb == 5'd0) ? 6'd1 : {1'b0, eb};

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
    logic [13:0] near_lg_ext, near_sm_ext;

    assign near_lg_ext = {sig_lg, 3'b000};
    assign near_sm_ext = (exp_diff == 6'd1) ? {1'b0, sig_sm, 2'b00} : {sig_sm, 3'b000};

    logic [13:0] near_diff;

    ks_sub14 u_near_sub (
        .a    (near_lg_ext),
        .b    (near_sm_ext),
        .diff (near_diff)
    );

    // Count leading zeros in the near difference to determine normalization shift
    logic [3:0] near_lzc;
    logic       near_all_zero;

    lod_tree_14 u_near_lzc (
        .din      (near_diff),
        .lzc      (near_lzc),
        .all_zero (near_all_zero)
    );

    // Normalize near result
    logic [5:0]  near_exp;
    logic [13:0] near_shifted;
    logic [10:0] near_sig;

    always_comb begin
        near_shifted = 14'd0;
        near_exp     = 6'd0;
        near_sig     = 11'd0;

        if (!near_all_zero) begin
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

    dual_round_11 u_near_round (
        .sig      (near_pre_round),
        .do_round (near_do_round),
        .rounded  (near_rounded)
    );

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

    ks_addsub15 u_far_addsub (
        .a         ({1'b0, far_lg_ext}),
        .b         ({1'b0, far_sm_aligned}),
        .mode_sub  (eff_sub),
        .borrow_in (far_sticky_shift),
        .result    (far_sum)
    );

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

    dual_round_11 u_far_round (
        .sig      (far_pre_round),
        .do_round (far_do_round),
        .rounded  (far_rounded)
    );

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

    wire [11:0] rounded_sig = use_near ? near_rounded : far_rounded;

    // Determine special cases and pack final result
    always_comb begin
        if (a_is_nan || b_is_nan)
            result = 16'h7FFF;
        else if (a_is_inf && b_is_inf && eff_sub)
            result = 16'h7FFF;
        else if (a_is_inf && b_is_inf)
            result = {sa, 5'b11111, 10'd0};
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
