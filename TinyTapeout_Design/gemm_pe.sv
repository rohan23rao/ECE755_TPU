///////////////////////////////////////////////////////////////////////////////
// Module: gemm_pe.sv
// Description: MAC Processing Element — 1-stage, 1x2 hardcoded.
//
//   pe_en is pre-computed in the CU and passed directly; h_en/v_en
//   propagation registers are removed (they were redundant: PE[0][0].pe_en
//   = pe_en_0 and PE[0][1].pe_en = pe_en_1, both already computed in CU).
//   w_out and v_en_out are removed (ROWS=1, no PE below).
//
//   a_out: east activation propagation for col1 stagger.
//     CE = data_vld: freezes on stall so col1 sees the correct held
//     activation when valid resumes.
//
//   data_vld = 0: a_out holds last value; pe_en forced 0 by CU-side gating;
//                 accumulator never fires.
//
// Author: Group5
///////////////////////////////////////////////////////////////////////////////

module gemm_pe #(
    parameter ACT_WIDTH = 4,
    parameter WGT_WIDTH = 4,
    parameter ACC_WIDTH = 16
) (
    input  logic                    clk,

    input  logic [ACT_WIDTH-1:0]    a_in,
    input  logic [WGT_WIDTH-1:0]    w_in,
    input  logic [ACC_WIDTH-1:0]    bias,
    input  logic                    ld_bias,

    // Pre-computed enable from CU — no local h_en & v_en AND gate needed
    input  logic                    pe_en,

    // Pipeline freeze: when 0, a_out holds and accumulator does not fire
    input  logic                    data_vld,

    output logic [ACC_WIDTH-1:0]    acc_out
);

    ///////////////////////////////////////////////////////////////////////////
    // Gated multiplier inputs
    ///////////////////////////////////////////////////////////////////////////
    logic [ACT_WIDTH-1:0] a_gated;
    logic [WGT_WIDTH-1:0] w_gated;

    assign a_gated = {ACT_WIDTH{pe_en}} & a_in;
    assign w_gated = {WGT_WIDTH{pe_en}} & w_in;

    ///////////////////////////////////////////////////////////////////////////
    // FP4 Multiplier
    ///////////////////////////////////////////////////////////////////////////
    logic [15:0] mult_out;

    FloatP4x16 u_fp4_mul (
        .A   (a_gated),
        .B   (w_gated),
        .Out (mult_out)
    );

    ///////////////////////////////////////////////////////////////////////////
    // FP16 Adder
    ///////////////////////////////////////////////////////////////////////////
    logic [ACC_WIDTH-1:0] acc_q;
    logic [ACC_WIDTH-1:0] add_result;

    fp16_adder_truncation u_fp16_add (
        .op_a   (mult_out),
        .op_b   (acc_q),
        .result (add_result)
    );

    ///////////////////////////////////////////////////////////////////////////
    // Accumulator  (ld_bias > pe_en > hold)
    ///////////////////////////////////////////////////////////////////////////
    always_ff @(posedge clk) begin
        if      (ld_bias) acc_q <= bias;
        else if (pe_en)   acc_q <= add_result;
    end

    assign acc_out = acc_q;
endmodule