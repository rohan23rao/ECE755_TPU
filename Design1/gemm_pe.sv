///////////////////////////////////////////////////////////////////////////////
// Module: gemm_pe.sv
// Description: MAC Processing Element for the GEMM Systolic Array.
//
//              Each PE performs FP4 multiply + FP16 accumulate and propagates
//              data and enables to its east and south neighbors.
//
//              Enable propagation:
//                H_EN_IN/V_EN_IN ripple through the array via unconditional
//                pipeline registers, creating the diagonal activation pattern.
//                PE_EN = H_EN_IN & V_EN_IN gates all local compute.
//
//              Data pipeline registers:
//                A_OUT gated by H_EN_IN — no forwarding if row inactive
//                W_OUT gated by V_EN_IN — no forwarding if col inactive
//
//              Accumulator:
//                LD_BIAS has priority — loads bias value into accumulator
//                PE_EN   — accumulates FP16 adder result when active
//                else    — holds current value (inactive PE, no corruption)
//
// Author: Group5
///////////////////////////////////////////////////////////////////////////////

import gemm_pkg::*;

module gemm_pe (
    // Global Inputs
    input  logic                    clk,
    input  logic                    rst_n,

    // Horizontal inputs (from west)
    input  logic [ACT_WIDTH-1:0]    a_in,       // activation data from west
    input  logic                    h_en_in,    // horizontal enable from west

    // Vertical inputs (from north)
    input  logic [WGT_WIDTH-1:0]    w_in,       // weight data from north
    input  logic                    v_en_in,    // vertical enable from north

    // Bias load
    input  logic [ACC_WIDTH-1:0]    bias,       // bias value for this column
    input  logic                    ld_bias,    // load bias into accumulator

    // Horizontal outputs (to east)
    output logic [ACT_WIDTH-1:0]    a_out,      // activation data to east
    output logic                    h_en_out,   // horizontal enable to east

    // Vertical outputs (to south)
    output logic [WGT_WIDTH-1:0]    w_out,      // weight data to south
    output logic                    v_en_out,   // vertical enable to south

    // ── Accumulator output ────────────────────────────────────────────────
    output logic [ACC_WIDTH-1:0]    acc_out     // MAC accumulator output
);

    ///////////////////////////////////////////////////////////////////////////
    // Local PE enable
    // PE is active only when both horizontal and vertical enables arrive
    // This naturally implements the diagonal activation pattern:
    //   PE[i][j] becomes active at cycle i+j as enables ripple through
    ///////////////////////////////////////////////////////////////////////////
    logic pe_en;
    assign pe_en = h_en_in & v_en_in;

    ///////////////////////////////////////////////////////////////////////////
    // Gated operands
    // Gate inputs to multiplier with pe_en to suppress switching activity
    // in inactive PEs — multiplier inputs are zero when PE not computing
    ///////////////////////////////////////////////////////////////////////////
    logic [ACT_WIDTH-1:0] a_gated;
    logic [WGT_WIDTH-1:0] w_gated;

    assign a_gated = {ACT_WIDTH{pe_en}} & a_in;
    assign w_gated = {WGT_WIDTH{pe_en}} & w_in;

    ///////////////////////////////////////////////////////////////////////////
    // Behavioral MAC (placeholder)
    // TODO: replace with instantiated FP4 multiplier + FP16 adder
    //   mac_result = fp16_add(fp4_mul(a_gated, w_gated), acc_out)
    ///////////////////////////////////////////////////////////////////////////
    logic [ACC_WIDTH-1:0] acc_q;
    logic [ACC_WIDTH-1:0] mac_result;
    logic [15:0] mult_out;

    FloatP4x16 fp4_mul (.A(a_gated), .B(w_gated), .Out(mult_out));

    fp16_adder adder (.op_a(acc_q), .op_b(mult_out), .result(mac_result));

    // assign mac_result = acc_q + (ACC_WIDTH'(a_gated) * ACC_WIDTH'(w_gated));

    ///////////////////////////////////////////////////////////////////////////
    // Accumulator register
    // Priority: rst_n > ld_bias > pe_en > hold
    //   ld_bias : loads bias independent of pe_en (column-wise, pre-compute)
    //   pe_en   : accumulates MAC result each active cycle
    //   hold    : inactive PE never corrupts accumulator
    ///////////////////////////////////////////////////////////////////////////
    always_ff @(posedge clk, negedge rst_n) begin
        if (!rst_n) begin 
			acc_q <= '0;
		end
        else if (ld_bias) begin
			acc_q <= bias;
		end
        else if (pe_en) begin
			acc_q <= mac_result;
		end
    end
    assign acc_out = acc_q;

    ///////////////////////////////////////////////////////////////////////////
    // EAST pipeline registers
    // H_EN_OUT : unconditional — enable must always propagate east
    // A_OUT    : gated by H_EN_IN — no data forwarding if row inactive
    ///////////////////////////////////////////////////////////////////////////
    always_ff @(posedge clk, negedge rst_n) begin
        if (!rst_n) begin
            h_en_out <= '0;
            a_out    <= '0;
        end
		else begin
            h_en_out <= h_en_in;                        // unconditional
            a_out    <= h_en_in ? a_in : '0;            // gated by H_EN_IN
        end
    end

    ///////////////////////////////////////////////////////////////////////////
    // SOUTH pipeline registers
    // V_EN_OUT : unconditional — enable must always propagate south
    // W_OUT    : gated by V_EN_IN — no data forwarding if col inactive
    ///////////////////////////////////////////////////////////////////////////
    always_ff @(posedge clk, negedge rst_n) begin
        if (!rst_n) begin
            v_en_out <= '0;
            w_out    <= '0;
        end
		else begin
            v_en_out <= v_en_in;                        // unconditional
            w_out    <= v_en_in ? w_in : '0;            // gated by V_EN_IN
        end
    end
endmodule