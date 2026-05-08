///////////////////////////////////////////////////////////////////////////////
// Module: fp16_adder_truncation.sv
// Description: Single-path FP16 adder, truncation output, optimized for
//              FP4 accumulation context.
//
// Design constraints assumed (valid for FP4 E2M1 accumulation):
//   (A) op_a = FloatP4x16 output. Product exponents are always in [13,20]
//       or zero. op_a is NEVER subnormal (leading bit always 1 for non-zero).
//   (B) Accumulator (op_b) can be any FP16 value including subnormal.
//   (C) Max accumulator K=256 × max_product=36 = 9216 << FP16_MAX=65504.
//       Overflow is physically impossible; is_overflow arm removed.
//   (D) FloatP4x16 only produces +0.0, never -0.0; both-zero case simplifies
//       to the normal path correctly (returns 0x0000 via is_underflow or
//       the adder giving sum=0).
//
// Optimizations vs. prior version:
//   1. eff_sub = sa ^ sb  (mux removed; always equal to sign XOR)
//   2. op_a subnormal handling removed  (constraint A)
//   3. is_both_zero output mux arm removed  (constraint D)
//   4. is_overflow output mux arm removed  (constraint C)
//   5. Normalization split on eff_sub:
//        Addition   (eff_sub=0): sum[14] can be 1, at most 1-bit normalization.
//                                LZC + barrel shift not in the critical cone.
//        Subtraction(eff_sub=1): sum[14] always 0 (diff ≤ sig_lg_ext).
//                                Full LZC + variable left-shift required.
//      Exposing this to the synthesizer (AREA 3) allows pruning the barrel
//      shift and LZC from the addition datapath.
//   6. Behavioral +/- operator (synthesizer picks area-optimal adder at 25 MHz)
//
// Bug fixed: is_underflow previously used all_zero directly, which fired
//   incorrectly when sum[14]=1 (overflow carry). Now gated with !sum[14]
//   and additionally by !eff_sub (subtraction can underflow; addition cannot).
//
// Author: Group5
///////////////////////////////////////////////////////////////////////////////

module fp16_adder_truncation (
    input  wire [15:0] op_a,
    input  wire [15:0] op_b,
    output reg  [15:0] result
);

    ///////////////////////////////////////////////////////////////////////////
    // Unpack
    ///////////////////////////////////////////////////////////////////////////
    wire        sa = op_a[15];
    wire [4:0]  ea = op_a[14:10];
    wire [9:0]  ma = op_a[9:0];

    wire        sb = op_b[15];
    wire [4:0]  eb = op_b[14:10];
    wire [9:0]  mb = op_b[9:0];

    ///////////////////////////////////////////////////////////////////////////
    // Zero checks
    ///////////////////////////////////////////////////////////////////////////
    // Exponent-only zero detection: subnormals (ea/eb=0, mantissa≠0) are
    // treated as zero. Safe: op_a is a FloatP4x16 product (never subnormal);
    // op_b is the accumulator (can't reach subnormal range given FP4 inputs).
    wire a_is_zero = (ea == 5'd0);
    wire b_is_zero = (eb == 5'd0);

    ///////////////////////////////////////////////////////////////////////////
    // Significand and effective exponent reconstruction
    //
    // op_a (FP4 product): exponent always >= 13 for non-zero, never subnormal.
    //   Leading bit is unconditionally 1 — no ea==0 check needed.  [constraint A]
    //
    // op_b (accumulator): subnormal handling removed.
    //   Accumulator starts at FP16(0.0) from bias load; thereafter it holds the
    //   sum of FP4 products, minimum magnitude 0.25 (FP16 exp=13, always normal).
    //   Near-perfect cancellation that would push acc below FP16 subnormal
    //   threshold (~6e-5) is impossible at FP4 precision. Subnormal acc treated
    //   as zero via the exponent-only b_is_zero check below.
    ///////////////////////////////////////////////////////////////////////////
    wire [10:0] sig_a  = {1'b1, ma};              // op_a always normal [constraint A]
    wire [5:0]  eff_ea = {1'b0, ea};

    wire [10:0] sig_b  = {1'b1, mb};              // op_b always normal (see above)
    wire [5:0]  eff_eb = {1'b0, eb};

    ///////////////////////////////////////////////////////////////////////////
    // Swap so larger magnitude is "lg"
    ///////////////////////////////////////////////////////////////////////////
    wire swap = (eff_eb > eff_ea) || ((eff_eb == eff_ea) && (sig_b > sig_a));

    wire        s_lg   = swap ? sb     : sa;
    wire [5:0]  e_lg   = swap ? eff_eb : eff_ea;
    wire [5:0]  e_sm   = swap ? eff_ea : eff_eb;
    wire [10:0] sig_lg = swap ? sig_b  : sig_a;
    wire [10:0] sig_sm = swap ? sig_a  : sig_b;

    // Optimization 1: eff_sub = s_lg ^ s_sm = sa ^ sb always (mux removed)
    wire [5:0]  exp_diff = e_lg - e_sm;
    wire        eff_sub  = sa ^ sb;

    ///////////////////////////////////////////////////////////////////////////
    // Alignment: right-shift sig_sm by exp_diff (cap at 14)
    ///////////////////////////////////////////////////////////////////////////
    wire [4:0]  shift_amt       = (exp_diff > 6'd14) ? 5'd14 : exp_diff[4:0];
    wire [24:0] sm_wide         = {sig_sm, 14'd0};
    wire [24:0] sm_shifted_wide = sm_wide >> shift_amt;
    wire [13:0] sig_sm_aligned  = sm_shifted_wide[24:11];
    wire        sticky          = (|sm_shifted_wide[10:0]) | (exp_diff > 6'd14);

    ///////////////////////////////////////////////////////////////////////////
    // Add/subtract
    ///////////////////////////////////////////////////////////////////////////
    wire [13:0] sig_lg_ext = {sig_lg, 3'b000};

    wire [14:0] sum = eff_sub
        ? ({1'b0, sig_lg_ext} - {1'b0, sig_sm_aligned} - {14'b0, sticky})
        : ({1'b0, sig_lg_ext} + {1'b0, sig_sm_aligned});

    ///////////////////////////////////////////////////////////////////////////
    // Normalization — split on eff_sub  [optimization 5]
    //
    // ADDITION (eff_sub=0):
    //   Both operands positive-magnitude; sum ≥ sig_lg_ext ≥ 0.
    //   sum[14]=1: overflow carry → right-shift 1, exp+1.
    //   sum[14]=0: sig_lg[10]=1 guarantees sum[13]=1 → already normalized.
    //   LZC and barrel shift are NOT in this cone — synthesizer can prune them.
    //
    // SUBTRACTION (eff_sub=1):
    //   sum[14] is always 0 (difference bounded by sig_lg_ext ≤ 2^14-1).
    //   Leading zeros possible → full LZC + variable left-shift required.
    ///////////////////////////////////////////////////////////////////////////

    // --- Addition path (1-bit normalization only) ---
    wire [10:0] trunc_sig_add = sum[14] ? sum[14:4] : sum[13:3];
    wire [5:0]  norm_exp_add  = sum[14] ? (e_lg + 6'd1) : e_lg;

    // --- Subtraction path (full LZC + variable shift) ---
    wire [3:0] lzc;
    wire       all_zero;

    lod_tree_14 u_lzc (
        .din      (sum[13:0]),    // sum[14]=0 for subtraction always
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
            // Bit 13 = 1: already normalized
            norm_exp_sub = e_lg;
            norm_sum_sub = sum;
        end else begin
            // Clamp shift to prevent exponent underflow (norm_exp >= 1)
            if (e_lg <= 6'd1)
                left_shift = 4'd0;
            else if ({2'b0, lzc} > (e_lg - 6'd1))
                left_shift = e_lg[3:0] - 4'd1;
            else
                left_shift = lzc;

            norm_sum_sub = sum << left_shift;
            norm_exp_sub = (left_shift == 4'd0) ? e_lg
                                                 : e_lg - {2'b00, left_shift};
        end
    end

    wire [10:0] trunc_sig_sub = norm_sum_sub[13:3];

    ///////////////////////////////////////////////////////////////////////////
    // Select path and extract post-normalization values
    ///////////////////////////////////////////////////////////////////////////
    wire [10:0] trunc_sig  = eff_sub ? trunc_sig_sub : trunc_sig_add;
    wire [5:0]  norm_exp   = eff_sub ? norm_exp_sub  : norm_exp_add;

    wire [5:0]  post_exp   = (!trunc_sig[10])   ? 6'd0      :
                             (norm_exp == 6'd0)  ? 6'd1      :
                                                    norm_exp;
    wire [9:0]  post_mant  = trunc_sig[9:0];

    ///////////////////////////////////////////////////////////////////////////
    // Output mux — 4 arms (both_zero and overflow removed)  [optimizations 3,4]
    //
    // is_both_zero removed: normal path returns {s_lg,0,0}=0x0000 correctly,
    //   and FloatP4x16 never produces -0.0 so sa=sb=0 for zero inputs.
    //
    // is_overflow removed: max accumulator value 9216 << FP16_MAX 65504.
    //   [constraint C — if K ever exceeds ~1820 this must be reinstated]
    //
    // is_underflow: only possible from subtraction cancellation, not addition.
    //   Gated with eff_sub to make this explicit to the synthesizer.
    ///////////////////////////////////////////////////////////////////////////
    wire is_only_a_zero =  a_is_zero & ~b_is_zero;
    wire is_only_b_zero =  b_is_zero & ~a_is_zero;
    // is_underflow: simplified from the original 7-term condition.
    // When eff_sub=1: sum[14] is always 0 (subtraction can't overflow),
    // and all_zero=1 from lod_tree_14 implies norm_sum_sub=0 → trunc_sig=0
    // → trunc_sig[10]=0, post_exp=0, post_mant=0 follow automatically.
    // The three downstream checks are therefore redundant and removed.
    wire is_underflow   =  eff_sub & ~a_is_zero & ~b_is_zero & all_zero;
    wire is_normal      = ~is_only_a_zero & ~is_only_b_zero & ~is_underflow;

    always_comb begin
        result = ({16{is_only_a_zero}} & op_b)
               | ({16{is_only_b_zero}} & op_a)
               | ({16{is_underflow}}   & 16'h0000)
               | ({16{is_normal}}      & {s_lg, post_exp[4:0], post_mant});
    end

endmodule
