///////////////////////////////////////////////////////////////////////////////
// Module: fp16_adder_truncation.sv
// Description: Single-path FP16 adder, truncation output, optimized for
//              FP4 accumulation context.
//
// Design constraints (valid for FP4 E2M1 accumulation):
//   (A) op_a = FloatP4x16 output — never subnormal for non-zero input.
//   (B) op_b = accumulator — always normal at FP4 operating range.
//   (C) Overflow impossible: max acc = K*36 << FP16_MAX=65504.
//   (D) FloatP4x16 only produces +0.0, never -0.0.
//
// Optimizations:
//   1. eff_sub = sa ^ sb (mux removed).
//   2. op_a subnormal handling removed (constraint A).
//   3. is_both_zero output arm removed (constraint D).
//   4. is_overflow output arm removed (constraint C).
//   5. is_underflow output arm removed — {16{is_underflow}} & 16'h0000 is
//      always 0; is_normal already excludes the underflow case so result=0
//      when is_underflow=1.  is_underflow still gates is_normal.
//   6. add/sub paths split so synthesiser can prune LZC from add cone.
//   7. Behavioural +/- (synthesiser picks area-optimal adder at 25 MHz).
//
// Author: Group5
///////////////////////////////////////////////////////////////////////////////

module fp16_adder_truncation (
    input  wire [15:0] op_a,
    input  wire [15:0] op_b,
    output reg  [15:0] result
);

    wire        sa = op_a[15];
    wire [4:0]  ea = op_a[14:10];
    wire [9:0]  ma = op_a[9:0];

    wire        sb = op_b[15];
    wire [4:0]  eb = op_b[14:10];
    wire [9:0]  mb = op_b[9:0];

    // Zero checks (exponent-only; subnormals treated as zero per constraints)
    wire a_is_zero = (ea == 5'd0);
    wire b_is_zero = (eb == 5'd0);

    // Significands — both operands always normal (constraints A, B)
    wire [10:0] sig_a  = {1'b1, ma};
    wire [5:0]  eff_ea = {1'b0, ea};

    wire [10:0] sig_b  = {1'b1, mb};
    wire [5:0]  eff_eb = {1'b0, eb};

    // Swap so larger magnitude is "lg"
    wire swap   = (eff_eb > eff_ea) || ((eff_eb == eff_ea) && (sig_b > sig_a));

    wire        s_lg   = swap ? sb     : sa;
    wire [5:0]  e_lg   = swap ? eff_eb : eff_ea;
    wire [5:0]  e_sm   = swap ? eff_ea : eff_eb;
    wire [10:0] sig_lg = swap ? sig_b  : sig_a;
    wire [10:0] sig_sm = swap ? sig_a  : sig_b;

    wire [5:0] exp_diff = e_lg - e_sm;
    wire       eff_sub  = sa ^ sb;    // optimisation 1: mux not needed

    // Alignment
    wire [4:0]  shift_amt      = (exp_diff > 6'd14) ? 5'd14 : exp_diff[4:0];
    wire [24:0] sm_wide        = {sig_sm, 14'd0};
    wire [24:0] sm_shifted     = sm_wide >> shift_amt;
    wire [13:0] sig_sm_aligned = sm_shifted[24:11];
    wire        sticky         = (|sm_shifted[10:0]) | (exp_diff > 6'd14);

    wire [13:0] sig_lg_ext = {sig_lg, 3'b000};

    // Add/subtract (behavioural — optimisation 7)
    wire [14:0] sum = eff_sub
        ? ({1'b0, sig_lg_ext} - {1'b0, sig_sm_aligned} - {14'b0, sticky})
        : ({1'b0, sig_lg_ext} + {1'b0, sig_sm_aligned});

    // --- Addition path: at most 1-bit normalisation ---
    wire [10:0] trunc_sig_add = sum[14] ? sum[14:4] : sum[13:3];
    wire [5:0]  norm_exp_add  = sum[14] ? (e_lg + 6'd1) : e_lg;

    // --- Subtraction path: full LZC + variable left-shift ---
    wire [3:0] lzc;
    wire       all_zero;

    lod_tree_14 u_lzc (
        .din      (sum[13:0]),
        .lzc      (lzc),
        .all_zero (all_zero)
    );

    logic [3:0]  left_shift;
    logic [5:0]  norm_exp_sub;
    logic [14:0] norm_sum_sub;

    always_comb begin
        left_shift   = 4'd0;
        norm_exp_sub = e_lg;
        norm_sum_sub = sum;

        if (all_zero) begin
            norm_exp_sub = 6'd0;
            norm_sum_sub = 15'd0;
        end else if (lzc == 4'd0) begin
            norm_exp_sub = e_lg;
            norm_sum_sub = sum;
        end else begin
            if (e_lg <= 6'd1)
                left_shift = 4'd0;
            else if ({2'b0, lzc} > (e_lg - 6'd1))
                left_shift = e_lg[3:0] - 4'd1;
            else
                left_shift = lzc;

            norm_sum_sub = sum << left_shift;
            norm_exp_sub = (left_shift == 4'd0) ? e_lg : e_lg - {2'b00, left_shift};
        end
    end

    wire [10:0] trunc_sig_sub = norm_sum_sub[13:3];

    // Select path
    wire [10:0] trunc_sig = eff_sub ? trunc_sig_sub : trunc_sig_add;
    wire [5:0]  norm_exp  = eff_sub ? norm_exp_sub  : norm_exp_add;

    wire [5:0]  post_exp  = (!trunc_sig[10])  ? 6'd0   :
                            (norm_exp == 6'd0) ? 6'd1   : norm_exp;
    wire [9:0]  post_mant = trunc_sig[9:0];

    // Output mux — is_underflow arm removed (optimisation 5):
    //   {16{is_underflow}} & 16'h0000 is always 0; is_normal already gates
    //   the normal arm to 0 when is_underflow=1, so result=0 correctly.
    wire is_only_a_zero = a_is_zero & ~b_is_zero;
    wire is_only_b_zero = b_is_zero & ~a_is_zero;
    wire is_underflow   = eff_sub & ~a_is_zero & ~b_is_zero & all_zero;
    wire is_normal      = ~is_only_a_zero & ~is_only_b_zero & ~is_underflow;

    always_comb begin
        result = ({16{is_only_a_zero}} & op_b)
               | ({16{is_only_b_zero}} & op_a)
               | ({16{is_normal}}      & {s_lg, post_exp[4:0], post_mant});
    end

endmodule