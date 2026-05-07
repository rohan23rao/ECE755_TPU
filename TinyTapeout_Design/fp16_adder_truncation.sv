///////////////////////////////////////////////////////////////////////////////
// Module: fp16_adder_truncation.sv
// Description: Single-path FP16 adder with truncation (no rounding).
//
// Merged from fp16_adder.sv and fp16_adder_truncation.sv:
//   - Single computation path (no near/far split; ks_sub14 no longer used)
//   - Full LZC normalization via lod_tree_14 (handles all cancellation cases)
//   - Behavioral +/- operator for add/subtract (smaller than ks_addsub15
//     at 25 MHz where timing is not a constraint; synthesizer picks area-
//     optimal adder topology with SYNTH_STRATEGY AREA 3)
//   - Truncation: sig[13:3] taken directly, no rounding logic
//   - No NaN/Inf handling (not needed for FP4 product accumulation)
//   - Flat parallel output mux (better synthesis than nested if-else)
//
// Bug fixed vs initial merge: is_underflow previously used `all_zero` from
// lod_tree_14 directly. When sum[14]=1 (overflow carry-out), sum[13:0]=0
// causing all_zero=1, which incorrectly triggered is_underflow and produced
// 0x0000 for valid sums like FP16(1.0)+FP16(1.0)=FP16(2.0).
// Fix: gate is_underflow with !sum[14] so overflow carry-out is never
// mistaken for a true zero result.
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
    // Zero checks (NaN/Inf removed — not produced by FP4 multiplier)
    ///////////////////////////////////////////////////////////////////////////
    wire a_is_zero = (ea == 5'd0) && (ma == 10'd0);
    wire b_is_zero = (eb == 5'd0) && (mb == 10'd0);

    ///////////////////////////////////////////////////////////////////////////
    // Reconstruct significands with leading bit; effective exponent
    ///////////////////////////////////////////////////////////////////////////
    wire [10:0] sig_a  = (ea == 5'd0) ? {1'b0, ma} : {1'b1, ma};
    wire [10:0] sig_b  = (eb == 5'd0) ? {1'b0, mb} : {1'b1, mb};
    wire [5:0]  eff_ea = (ea == 5'd0) ? 6'd1 : {1'b0, ea};
    wire [5:0]  eff_eb = (eb == 5'd0) ? 6'd1 : {1'b0, eb};

    ///////////////////////////////////////////////////////////////////////////
    // Swap so larger magnitude is "lg"
    ///////////////////////////////////////////////////////////////////////////
    wire swap = (eff_eb > eff_ea) || ((eff_eb == eff_ea) && (sig_b > sig_a));

    wire        s_lg   = swap ? sb     : sa;
    wire [5:0]  e_lg   = swap ? eff_eb : eff_ea;
    wire [5:0]  e_sm   = swap ? eff_ea : eff_eb;
    wire [10:0] sig_lg = swap ? sig_b  : sig_a;
    wire [10:0] sig_sm = swap ? sig_a  : sig_b;

    wire [5:0] exp_diff = e_lg - e_sm;
    wire       eff_sub  = s_lg ^ (swap ? sa : sb);

    ///////////////////////////////////////////////////////////////////////////
    // Alignment: right-shift sig_sm by exp_diff (cap at 14)
    ///////////////////////////////////////////////////////////////////////////
    wire [4:0]  shift_amt       = (exp_diff > 6'd14) ? 5'd14 : exp_diff[4:0];
    wire [24:0] sm_wide         = {sig_sm, 14'd0};
    wire [24:0] sm_shifted_wide = sm_wide >> shift_amt;
    wire [13:0] sig_sm_aligned  = sm_shifted_wide[24:11];
    wire        sticky          = (|sm_shifted_wide[10:0]) | (exp_diff > 6'd14);

    ///////////////////////////////////////////////////////////////////////////
    // Single add/subtract — behavioral operator
    //
    // eff_sub=0 (addition):   sum = sig_lg_ext + sig_sm_aligned
    // eff_sub=1 (subtraction):sum = sig_lg_ext - sig_sm_aligned - sticky
    //   The -sticky term accounts for the truncated bits of sig_sm,
    //   ensuring correct round-towards-zero behaviour on subtraction.
    //
    // Synthesizer (AREA 3) will choose a compact ripple-carry or CLA
    // adder at 25 MHz — no need for the Kogge-Stone ks_addsub15 here.
    ///////////////////////////////////////////////////////////////////////////
    wire [13:0] sig_lg_ext = {sig_lg, 3'b000};

    wire [14:0] sum = eff_sub
        ? ({1'b0, sig_lg_ext} - {1'b0, sig_sm_aligned} - {14'b0, sticky})
        : ({1'b0, sig_lg_ext} + {1'b0, sig_sm_aligned});

    ///////////////////////////////////////////////////////////////////////////
    // LZC on sum[13:0] for full normalization
    // NOTE: when sum[14]=1 (overflow carry-out), sum[13:0] is incidentally 0.
    //       all_zero=1 in that case does NOT mean the result is zero.
    //       The overflow branch is checked first; all_zero is only meaningful
    //       when sum[14]=0 (no overflow).
    ///////////////////////////////////////////////////////////////////////////
    wire [3:0] lzc;
    wire       all_zero;

    lod_tree_14 u_lzc (
        .din      (sum[13:0]),
        .lzc      (lzc),
        .all_zero (all_zero)
    );

    ///////////////////////////////////////////////////////////////////////////
    // Normalization
    //
    // sum[14]=1 (overflow carry-out): leading 1 is at bit 14.
    //   sig at [14:4], norm_exp = e_lg + 1
    //
    // lzc=0 (bit 13=1, already normalized): sig at [13:3], norm_exp = e_lg
    //
    // lzc>0 (leading zeros — cancellation from subtraction):
    //   left-shift by lzc, clamped so norm_exp >= 1 (subnormal floor)
    //
    // all_zero (sum=0): result is zero — only reachable when sum[14]=0
    ///////////////////////////////////////////////////////////////////////////
    logic [3:0]  left_shift;
    logic [5:0]  norm_exp;
    logic [14:0] norm_sum;

    always_comb begin
        left_shift = 4'd0;
        norm_exp   = e_lg;
        norm_sum   = sum;

        if (sum[14]) begin
            norm_exp = e_lg + 6'd1;
            norm_sum = sum;
        end else if (all_zero) begin
            norm_exp = 6'd0;
            norm_sum = 15'd0;
        end else begin
            // Clamped left shift
            if (e_lg <= 6'd1)
                left_shift = 4'd0;
            else if ({2'b0, lzc} > (e_lg - 6'd1))
                left_shift = e_lg[3:0] - 4'd1;
            else
                left_shift = lzc;

            norm_sum = sum << left_shift;
            norm_exp = (left_shift == 4'd0) ? e_lg
                                            : e_lg - {2'b00, left_shift};
        end
    end

    ///////////////////////////////////////////////////////////////////////////
    // Truncation: extract 11-bit significand, no rounding
    // Overflow case (sum[14]=1): take sum[14:4] (sig spans bits 14..4)
    // All other cases:           take norm_sum[13:3]
    ///////////////////////////////////////////////////////////////////////////
    wire [10:0] trunc_sig  = sum[14] ? sum[14:4] : norm_sum[13:3];
    wire [5:0]  post_exp   = (!trunc_sig[10])   ? 6'd0      :
                             (norm_exp == 6'd0)  ? 6'd1      :
                                                    norm_exp;
    wire [9:0]  post_mant  = trunc_sig[9:0];

    ///////////////////////////////////////////////////////////////////////////
    // Flat parallel output mux
    //
    // is_underflow fix: gate with !sum[14].
    //   When sum[14]=1, sum[13:0]=0 makes all_zero=1 spuriously.
    //   Without the !sum[14] guard, FP16(x)+FP16(x) — any pair with equal
    //   exponents — would incorrectly produce 0x0000.
    ///////////////////////////////////////////////////////////////////////////
    wire is_both_zero   =  a_is_zero &  b_is_zero;
    wire is_only_a_zero =  a_is_zero & ~b_is_zero;
    wire is_only_b_zero =  b_is_zero & ~a_is_zero;
    wire is_overflow    = ~a_is_zero & ~b_is_zero & (post_exp >= 6'd31);
    wire is_underflow   = ~a_is_zero & ~b_is_zero & ~sum[14]
                        & (post_exp == 6'd0) & (post_mant == 10'd0)
                        & ~trunc_sig[10];
    wire is_normal      = ~is_both_zero & ~is_only_a_zero & ~is_only_b_zero
                        & ~is_overflow  & ~is_underflow;

    always_comb begin
        result = ({16{is_both_zero}}   & {sa & sb, 15'd0})
               | ({16{is_only_a_zero}} & op_b)
               | ({16{is_only_b_zero}} & op_a)
               | ({16{is_overflow}}    & {s_lg, 5'b11111, 10'd0})
               | ({16{is_underflow}}   & 16'h0000)
               | ({16{is_normal}}      & {s_lg, post_exp[4:0], post_mant});
    end

endmodule