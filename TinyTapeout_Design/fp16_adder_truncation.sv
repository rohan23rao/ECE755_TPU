
module fp16_adder_truncation (
    input  wire [15:0] op_a,
    input  wire [15:0] op_b,
    output reg  [15:0] result
);

    // Unpack op_a
    wire sa = op_a[15];
    wire [4:0] ea = op_a[14:10];
    wire [9:0] ma = op_a[9:0];

    // Unpack op_b
    wire sb = op_b[15];
    wire [4:0] eb = op_b[14:10];
    wire [9:0] mb = op_b[9:0];

    // Zero, Inf, and Nan checks
    wire a_is_zero = (ea == 5'd0)  && (ma == 10'd0);
    wire b_is_zero = (eb == 5'd0)  && (mb == 10'd0);

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

    // Near path: truncate (no rounding)
    logic [5:0] near_post_exp;
    logic [9:0] near_post_mant;

    assign near_post_exp  = (!near_sig[10])    ? 6'd0   :
                            (near_exp == 6'd0)  ? 6'd1   :
                                                   near_exp;
    assign near_post_mant = near_sig[9:0];

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

    ks_addsub15 u_far_addsub (
        .a         ({1'b0, far_lg_ext}),
        .b         ({1'b0, far_sm_aligned}),
        .mode_sub  (eff_sub),
        .borrow_in (far_sticky_shift),
        .result    (far_sum)
    );

    // 1-bit normalization of the far sum
    logic [5:0]  far_norm_exp;
    logic [14:0] far_norm_sum;

    always_comb begin
        if (far_sum[14]) begin
            far_norm_exp = e_lg + 6'd1;
            far_norm_sum = far_sum;
        end else if (!far_sum[13]) begin
            if (e_lg > 6'd1) begin
                far_norm_exp = e_lg - 6'd1;
                far_norm_sum = far_sum << 1;
            end else begin
                far_norm_exp = e_lg;
                far_norm_sum = far_sum;
            end
        end else begin
            far_norm_exp = e_lg;
            far_norm_sum = far_sum;
        end
    end

    // Far path: truncate (no rounding)
    logic [10:0] far_trunc_sig;
    logic [5:0]  far_post_exp;
    logic [9:0]  far_post_mant;

    assign far_trunc_sig = far_sum[14] ? far_norm_sum[14:4] : far_norm_sum[13:3];

    assign far_post_exp  = (!far_trunc_sig[10])    ? 6'd0              :
                           (far_norm_exp == 6'd0)   ? 6'd1              :
                                                       far_norm_exp;
    assign far_post_mant = far_trunc_sig[9:0];

    // Select near or far path result
    logic [5:0] post_exp;
    logic [9:0] post_mant;

    assign post_exp  = use_near ? near_post_exp  : far_post_exp;
    assign post_mant = use_near ? near_post_mant : far_post_mant;

    logic [10:0] trunc_sig;
    assign trunc_sig = use_near ? near_sig : far_trunc_sig;

    // Output mux flat
    logic       is_both_zero, is_only_a_zero, is_only_b_zero;
    logic       is_overflow, is_underflow, is_normal;

    assign is_both_zero   = a_is_zero & b_is_zero;
    assign is_only_a_zero = a_is_zero & ~b_is_zero;
    assign is_only_b_zero = b_is_zero & ~a_is_zero;
    assign is_overflow    = ~a_is_zero & ~b_is_zero & (post_exp >= 6'd31);
    assign is_underflow   = ~a_is_zero & ~b_is_zero & (post_exp == 6'd0) & (post_mant == 10'd0) & ~trunc_sig[10];
    assign is_normal = ~is_both_zero & ~is_only_a_zero & ~is_only_b_zero & ~is_overflow & ~is_underflow;

    // Selects in parallel
    always_comb begin
        result = ({16{is_both_zero}}               & {sa & sb, 15'd0})
               | ({16{is_only_a_zero}}             & op_b)
               | ({16{is_only_b_zero}}             & op_a)
               | ({16{is_overflow}}                & {s_lg, 5'b11111, 10'd0})
               | ({16{is_underflow}}               & 16'h0000)
               | ({16{is_normal}}                  & {s_lg, post_exp[4:0], post_mant});
    end
endmodule