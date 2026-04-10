///////////////////////////////////////////////////////////////////////////////
// Module: gemm_pe.sv
// Description: Fully pipelined MAC Processing Element for GEMM Systolic Array.
//
//              Pipeline structure (2 stages, fully pipelined):
//                Stage 1: A_IN/W_IN → AND gate → FP4 Mul → [mul_out_q flop]
//                Stage 2: mul_out_q → FP16 Add → [ACC flop]
//                Both stages active every cycle — new multiply starts while
//                previous result is being accumulated.
//
//              PE enable pipeline:
//                pe_en   = H_EN_IN & V_EN_IN  (combinational, gates mul inputs)
//                pe_en_q = pe_en delayed 1cy  (gates accumulator update)
//                pe_en fires at cycle i+j for PE[i][j]
//                pe_en_q fires at cycle i+j+1 — accumulates mul_out_q ✓
//
//              Enable propagation (single stage — 1 cycle per hop):
//                H_EN_IN → [EAST flop] → H_EN_OUT
//                V_EN_IN → [SOUTH flop] → V_EN_OUT
//                1-cycle forwarding ensures h_en and v_en arrive simultaneously
//                at PE[i][j] at cycle i+j (i hops horizontal + j hops vertical)
//
//              Bias load (single cycle — LOAD_FIFO only, before compute):
//                LD_BIAS directly loads BIAS into accumulator, no pipeline needed
//                Mutually exclusive with pe_en_q (different FSM states)
//
//              Gating:
//                pe_en  gates multiplier inputs  → no switching when inactive
//                pe_en_q gates accumulator       → no corruption on inactive PEs
//                H_EN_IN gates A_OUT data        → no forwarding if row inactive
//                V_EN_IN gates W_OUT data        → no forwarding if col inactive
//
// Author: Group5
///////////////////////////////////////////////////////////////////////////////

module gemm_pe #(
    parameter ACT_WIDTH = 4,
    parameter WGT_WIDTH = 4,
    parameter ACC_WIDTH = 16
) (
    // Global
    input  logic                    clk,

    // ── Horizontal inputs (from west) ─────────────────────────────────────
    input  logic [ACT_WIDTH-1:0]    a_in,       // activation data from west
    input  logic                    h_en_in,    // horizontal enable from west

    // ── Vertical inputs (from north) ──────────────────────────────────────
    input  logic [WGT_WIDTH-1:0]    w_in,       // weight data from north
    input  logic                    v_en_in,    // vertical enable from north

    // ── Bias load (single cycle, LOAD_FIFO only) ──────────────────────────
    input  logic [ACC_WIDTH-1:0]    bias,       // FP16 bias value
    input  logic                    ld_bias,    // load bias into accumulator

    // ── Horizontal outputs (to east) ──────────────────────────────────────
    output logic [ACT_WIDTH-1:0]    a_out,      // activation data to east
    output logic                    h_en_out,   // horizontal enable to east

    // ── Vertical outputs (to south) ───────────────────────────────────────
    output logic [WGT_WIDTH-1:0]    w_out,      // weight data to south
    output logic                    v_en_out,   // vertical enable to south

    // ── Accumulator output ────────────────────────────────────────────────
    output logic [ACC_WIDTH-1:0]    acc_out
);


    ///////////////////////////////////////////////////////////////////////////
    // PE enable — combinational
    // PE[i][j] activates at cycle i+j as enables ripple through single-stage
    // pipeline registers (1 cycle per hop east/south)
    ///////////////////////////////////////////////////////////////////////////
    logic pe_en;
    assign pe_en = h_en_in & v_en_in;

    ///////////////////////////////////////////////////////////////////////////
    // Gated multiplier inputs
    // Zero when PE inactive — suppresses switching in FP4 multiplier
    ///////////////////////////////////////////////////////////////////////////
    logic [ACT_WIDTH-1:0] a_gated;
    logic [WGT_WIDTH-1:0] w_gated;

    assign a_gated = {ACT_WIDTH{pe_en}} & a_in;
    assign w_gated = {WGT_WIDTH{pe_en}} & w_in;

    ///////////////////////////////////////////////////////////////////////////
    // Stage 1: FP4 Multiplier (behavioral placeholder)
    // TODO: replace with instantiated FP4 multiplier
    //   mul_comb = fp4_mul(a_gated, w_gated)
    ///////////////////////////////////////////////////////////////////////////
    logic [15:0] mult_out;

    FloatP4x16 u_fp4_mul (
        .A   (a_gated),
        .B   (w_gated),
        .Out (mult_out)
    );

    ///////////////////////////////////////////////////////////////////////////
    // Stage 1 → Stage 2 pipeline register
    //
    // mul_out_q : registered multiplier output — valid cycle after pe_en
    // pe_en_q   : pe_en delayed 1 cycle — gates accumulator aligned with data
    //
    // No reset on mul_out_q — first valid data overwrites X before use
    // pe_en_q   no reset — pipeline flushes naturally, FSM ensures no spurious
    //           accumulation before first ld_bias initializes the accumulator
    ///////////////////////////////////////////////////////////////////////////
    logic [ACC_WIDTH-1:0] mul_out_q;
    logic                 pe_en_q;

    always_ff @(posedge clk) begin
        mul_out_q <= mult_out;
        pe_en_q   <= pe_en;
    end

    ///////////////////////////////////////////////////////////////////////////
    // Stage 2: FP16 Adder (behavioral placeholder)
    // TODO: replace with instantiated FP16 adder
    //   add_result = fp16_add(mul_out_q, acc_q)
    ///////////////////////////////////////////////////////////////////////////
    logic [ACC_WIDTH-1:0] acc_q;
    logic [ACC_WIDTH-1:0] add_result;

    fp16_adder_truncation u_fp16_add (
        .op_a   (mul_out_q),
        .op_b   (acc_q),
        .result (add_result)
    );

    ///////////////////////////////////////////////////////////////////////////
    // Accumulator register
    //
    // Priority: ld_bias > pe_en_q > hold
    //   ld_bias  : single-cycle direct load — LOAD_FIFO only, before compute
    //   pe_en_q  : accumulate pipelined result — 1cy after pe_en
    //   hold     : inactive PE never corrupts accumulator
    ///////////////////////////////////////////////////////////////////////////
    always_ff @(posedge clk) begin
        if      (ld_bias)  acc_q <= bias;
        else if (pe_en_q)  acc_q <= add_result;
    end

    assign acc_out = acc_q;

    ///////////////////////////////////////////////////////////////////////////
    // EAST pipeline register — single stage
    // h_en_out : unconditional — enable always propagates east
    // a_out    : gated by H_EN_IN — no forwarding if row inactive
    ///////////////////////////////////////////////////////////////////////////
    always_ff @(posedge clk) begin
        h_en_out <= h_en_in;
        a_out    <= h_en_in ? a_in : '0;
    end

    ///////////////////////////////////////////////////////////////////////////
    // SOUTH pipeline register — single stage
    // v_en_out : unconditional — enable always propagates south
    // w_out    : gated by V_EN_IN — no forwarding if col inactive
    ///////////////////////////////////////////////////////////////////////////
    always_ff @(posedge clk) begin
        v_en_out <= v_en_in;
        w_out    <= v_en_in ? w_in : '0;
    end

endmodule
