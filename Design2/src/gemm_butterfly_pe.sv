///////////////////////////////////////////////////////////////////////////////
// Module: gemm_butterfly_pe.sv
// Description: Butterfly Processing Element for GEMM Systolic Array.
//
//              Pairs two adjacent row PEs (PE_i and PE_i+1) at the same
//              column j to share one 2-stage FP16 adder, halving adder count.
//
//  Pipeline structure:
//    Each sub-PE:
//      pe_en → gated A/W inputs → FP4 mul (comb) → [FIFO push]
//    Shared adder (2-stage):
//      Arbitration selects head of PE_i or PE_i+1 FIFO each cycle →
//      adder Stage 0 (comb) → [pipeline flop inside adder] →
//      adder Stage 1 (comb output = result) → accumulator write
//
//  RAW avoidance:
//    PE_i fires at cycle i+j, PE_i+1 fires at cycle i+1+j.
//    Natural 1-cycle offset → alternating FIFO pops → exactly matches
//    2-cycle adder latency. No bypass needed.
//
//  FIFO (per sub-PE):
//    4-entry circular, valid-bit per slot.
//    Push: pe_en_i  / pe_en_i1 (multiply result written to tail)
//    Pop:  arbiter grants turn AND head_valid
//    Depth 4 = K_MAX/2 — exact fit for K_MAX=8.
//
//  Arbitration (3-case combinational):
//    if   ( hv_i & ~hv_i1): pop PE_i,   arb_sel_next = 1  // force i (startup)
//    elif (~hv_i &  hv_i1): pop PE_i1,  arb_sel_next = 0  // drain PE_i+1
//    else:                   pop ~arb_sel, arb_sel_next = ~arb_sel // steady alt.
//    hv_x = head_valid of PE_x
//
//  Tag:
//    arb_sel at pop time is registered through the adder's internal pipeline
//    flop as a tag bit (tag_q). tag_q=0 → write acc_i, tag_q=1 → write acc_i1.
//
//  Weight flow (row-wise pairing, same column):
//    w_in → PE_i multiplier
//    w_in registered → PE_i+1 multiplier  (internal south register, same as
//                                           original inter-PE wire)
//    w_in registered twice → w_out (exits butterfly to south)
//    v_en_in registered twice → v_en_out (mirrors weight chain)
//
//  Bias:
//    ld_bias fans into both accumulators simultaneously — both rows of a
//    column share the same bias value and load on the same cycle.
//
//  Reset:
//    rst_n resets ONLY: FIFO valid bits, head/tail pointers, arb_sel.
//    All datapath registers (accumulators, adder pipeline, mul outputs)
//    are reset-free.
//
// Author: Group5
///////////////////////////////////////////////////////////////////////////////

module gemm_butterfly_pe #(
    parameter ACT_WIDTH  = 4,
    parameter WGT_WIDTH  = 4,
    parameter ACC_WIDTH  = 16,
    parameter FIFO_DEPTH = 4,
    parameter FIFO_AW    = $clog2(FIFO_DEPTH)   // = 2
) (
    input  logic                    clk,
    input  logic                    rst_n,

    // ── PE_i horizontal (row i) ───────────────────────────────────────────
    input  logic [ACT_WIDTH-1:0]    a_in_i,
    input  logic                    h_en_in_i,
    output logic [ACT_WIDTH-1:0]    a_out_i,
    output logic                    h_en_out_i,

    // ── PE_i+1 horizontal (row i+1) ──────────────────────────────────────
    input  logic [ACT_WIDTH-1:0]    a_in_i1,
    input  logic                    h_en_in_i1,
    output logic [ACT_WIDTH-1:0]    a_out_i1,
    output logic                    h_en_out_i1,

    // ── Vertical (shared column, enters PE_i from north) ─────────────────
    input  logic [WGT_WIDTH-1:0]    w_in,
    input  logic                    v_en_in,
    output logic [WGT_WIDTH-1:0]    w_out,
    output logic                    v_en_out,

    // ── Bias load ─────────────────────────────────────────────────────────
    input  logic [ACC_WIDTH-1:0]    bias,
    input  logic                    ld_bias,

    // ── Accumulator outputs ───────────────────────────────────────────────
    output logic [ACC_WIDTH-1:0]    acc_out_i,
    output logic [ACC_WIDTH-1:0]    acc_out_i1
);

    ///////////////////////////////////////////////////////////////////////////
    // Weight south-register chain
    //   w_q  : weight registered once  → feeds PE_i+1 multiplier
    //   w_qq : weight registered twice → exits as w_out to south
    //   Same for v_en
    ///////////////////////////////////////////////////////////////////////////
    logic [WGT_WIDTH-1:0]   w_q,    w_qq;
    logic                   v_en_q, v_en_qq;

    always_ff @(posedge clk) begin
        w_q    <= w_in;
        w_qq   <= w_q;
        v_en_q <= v_en_in;
        v_en_qq<= v_en_q;
    end

    assign w_out    = w_qq;
    assign v_en_out = v_en_qq;

    ///////////////////////////////////////////////////////////////////////////
    // PE enables
    //   pe_en_i  : gates PE_i  multiply (h_en_in_i  & v_en_in)
    //   pe_en_i1 : gates PE_i+1 multiply (h_en_in_i1 & v_en_q)
    //              v_en_q used because weight arrives 1cy later for PE_i+1
    ///////////////////////////////////////////////////////////////////////////
    logic pe_en_i, pe_en_i1;

    assign pe_en_i  = h_en_in_i  & v_en_in;
    assign pe_en_i1 = h_en_in_i1 & v_en_q;

    ///////////////////////////////////////////////////////////////////////////
    // Gated multiplier inputs
    ///////////////////////////////////////////////////////////////////////////
    logic [ACT_WIDTH-1:0] a_gated_i,  a_gated_i1;
    logic [WGT_WIDTH-1:0] w_gated_i,  w_gated_i1;

    assign a_gated_i  = {ACT_WIDTH{pe_en_i}}  & a_in_i;
    assign w_gated_i  = {WGT_WIDTH{pe_en_i}}  & w_in;
    assign a_gated_i1 = {ACT_WIDTH{pe_en_i1}} & a_in_i1;
    assign w_gated_i1 = {WGT_WIDTH{pe_en_i1}} & w_q;

    ///////////////////////////////////////////////////////////////////////////
    // FP4 Multipliers (combinational)
    ///////////////////////////////////////////////////////////////////////////
    logic [ACC_WIDTH-1:0] mul_i, mul_i1;

    FloatP4x16 u_mul_i (
        .A   (a_gated_i),
        .B   (w_gated_i),
        .Out (mul_i)
    );

    FloatP4x16 u_mul_i1 (
        .A   (a_gated_i1),
        .B   (w_gated_i1),
        .Out (mul_i1)
    );

    ///////////////////////////////////////////////////////////////////////////
    // 4-entry circular FIFOs (one per sub-PE)
    //   Push : pe_en_x asserted — mul_x result written to tail slot
    //   Pop  : arbiter grants this PE's turn AND head is valid
    //   valid bits and pointers reset to 0
    ///////////////////////////////////////////////////////////////////////////

    // PE_i FIFO
    logic [ACC_WIDTH-1:0]   fifo_i  [FIFO_DEPTH];
    logic [FIFO_AW-1:0]     head_i,  tail_i;
    logic [FIFO_DEPTH-1:0]  valid_i;

    // PE_i+1 FIFO
    logic [ACC_WIDTH-1:0]   fifo_i1 [FIFO_DEPTH];
    logic [FIFO_AW-1:0]     head_i1, tail_i1;
    logic [FIFO_DEPTH-1:0]  valid_i1;

    // Head-valid shortcuts used in arbitration
    logic hv_i, hv_i1;
    assign hv_i  = valid_i [head_i];
    assign hv_i1 = valid_i1[head_i1];

    // Arbitration pop strobes (combinational, defined in arb section below)
    logic pop_i, pop_i1;

    // ── PE_i FIFO push/pop ────────────────────────────────────────────────
    always_ff @(posedge clk) begin
        if (pe_en_i) begin
            fifo_i[tail_i] <= mul_i;
        end
    end

    always_ff @(posedge clk, negedge rst_n) begin
        if (!rst_n) begin
            tail_i  <= '0;
            head_i  <= '0;
            valid_i <= '0;
        end else begin
			if (pop_i) begin
                valid_i[head_i] <= 1'b0;
                head_i          <= head_i + 1'b1;
            end
            if (pe_en_i) begin
                valid_i[tail_i] <= 1'b1;
                tail_i          <= tail_i + 1'b1;
            end
        end
    end

    // ── PE_i+1 FIFO push/pop ─────────────────────────────────────────────
    always_ff @(posedge clk) begin
        if (pe_en_i1) begin
            fifo_i1[tail_i1] <= mul_i1;
        end
    end

    always_ff @(posedge clk, negedge rst_n) begin
        if (!rst_n) begin
            tail_i1  <= '0;
            head_i1  <= '0;
            valid_i1 <= '0;
        end else begin
			if (pop_i1) begin
                valid_i1[head_i1] <= 1'b0;
                head_i1           <= head_i1 + 1'b1;
            end
            if (pe_en_i1) begin
                valid_i1[tail_i1] <= 1'b1;
                tail_i1           <= tail_i1 + 1'b1;
            end
        end
    end



    ///////////////////////////////////////////////////////////////////////////
    // Adder inputs — mux selected FIFO head into adder op_a
    // Accumulator feedback selected by arb_sel → op_b
    //
    // adder_en : a valid pop occurred this cycle — adder result is meaningful
    ///////////////////////////////////////////////////////////////////////////
    logic                   adder_en;
    logic [ACC_WIDTH-1:0]   adder_a, adder_b;
    logic [ACC_WIDTH-1:0]   acc_i,   acc_i1;
    logic [ACC_WIDTH-1:0]   adder_result;

    assign adder_en = pop_i | pop_i1;
    assign adder_a  = pop_i ? fifo_i[head_i] : fifo_i1[head_i1];
    assign adder_b  = pop_i ? acc_i          : acc_i1;



	///////////////////////////////////////////////////////////////////////////
    // Arbitration
    //   arb_sel : 0 = PE_i's turn, 1 = PE_i+1's turn (steady-state)
    //   3-case combinational, arb_sel registered for next cycle
    //
    //   Case 1: only PE_i  has valid head → force pop PE_i,   next = 1
    //   Case 2: only PE_i1 has valid head → force pop PE_i+1, next = 0
    //   Case 3: both (or neither) valid   → follow arb_sel toggle
    //
    //   Case 3 "neither valid": pop strobes are 0, arb toggles harmlessly.
    //   Next real pop will hit Case 1 or Case 2 and self-correct.
    ///////////////////////////////////////////////////////////////////////////
    logic arb_sel;           // registered
    logic arb_sel_next;

    always_comb begin
        if      ( hv_i & ~hv_i1) begin
            pop_i       = 1'b1;
            pop_i1      = 1'b0;
            arb_sel_next= 1'b1;
        end else if (~hv_i &  hv_i1) begin
            pop_i       = 1'b0;
            pop_i1      = 1'b1;
            arb_sel_next= 1'b0;
        end else begin
			// both valid or neither valid
			pop_i        = ~arb_sel & hv_i;
			pop_i1       =  arb_sel & hv_i1;
			arb_sel_next = adder_en ? ~arb_sel : arb_sel;  // hold if nothing popped
		end
    end

    always_ff @(posedge clk, negedge rst_n) begin
        if (!rst_n) arb_sel <= 1'b0;
        else        arb_sel <= arb_sel_next;
    end



    ///////////////////////////////////////////////////////////////////////////
    // Tag: register arb_sel (= pop_i1 winning) through adder pipeline flop
    //   tag_q=0 → result routes to acc_i
    //   tag_q=1 → result routes to acc_i+1
    // adder_en_q: valid bit for accumulator write, same pipeline delay
    ///////////////////////////////////////////////////////////////////////////
    logic tag_q, adder_en_q;

    always_ff @(posedge clk) begin
        tag_q      <= pop_i1;       // 0 if PE_i won, 1 if PE_i+1 won
        adder_en_q <= adder_en;
    end

    ///////////////////////////////////////////////////////////////////////////
    // Shared 2-stage FP16 adder
    //   op_a = selected FIFO head (multiply result)
    //   op_b = selected accumulator (feedback)
    //   result available combinationally 1 cycle after inputs presented
    ///////////////////////////////////////////////////////////////////////////
    fp16_adder_truncation_pipe u_adder (
        .clk    (clk),
        .op_a   (adder_a),
        .op_b   (adder_b),
        .result (adder_result)
    );

    ///////////////////////////////////////////////////////////////////////////
    // Accumulators
    //   Priority: ld_bias > adder write > hold
    //   ld_bias is mutually exclusive with compute (different FSM states)
    //   adder_en_q & ~tag_q → write acc_i
    //   adder_en_q &  tag_q → write acc_i+1
    ///////////////////////////////////////////////////////////////////////////
    always_ff @(posedge clk) begin
        if      (ld_bias)                    acc_i <= bias;
        else if (adder_en_q & ~tag_q)        acc_i <= adder_result;
    end

    always_ff @(posedge clk) begin
        if      (ld_bias)                    acc_i1 <= bias;
        else if (adder_en_q &  tag_q)        acc_i1 <= adder_result;
    end

    assign acc_out_i  = acc_i;
    assign acc_out_i1 = acc_i1;

    ///////////////////////////////////////////////////////////////////////////
    // Horizontal east pipeline registers
    //   Gated by h_en_in to suppress forwarding when row inactive
    ///////////////////////////////////////////////////////////////////////////
    always_ff @(posedge clk) begin
        h_en_out_i  <= h_en_in_i;
        a_out_i     <= h_en_in_i  ? a_in_i  : '0;
        h_en_out_i1 <= h_en_in_i1;
        a_out_i1    <= h_en_in_i1 ? a_in_i1 : '0;
    end
endmodule