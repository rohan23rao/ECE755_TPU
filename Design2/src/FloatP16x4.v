module FloatP16x4 #(
    parameter INPUT_WIDTH = 16,
    parameter OUTPUT_WIDTH = 4
)(
    input wire [INPUT_WIDTH-1:0]    A,
    input wire [INPUT_WIDTH-1:0]    B,
    output wire [OUTPUT_WIDTH-1:0]  Out
);

//FP Constants
localparam INPUT_SIGN_BITS = 1;
localparam INPUT_EXPONENT_BITS = 5;
localparam INPUT_MANTISSA_BITS = 10;

localparam FP16_EXPONENT_MSB = INPUT_WIDTH-INPUT_SIGN_BITS-1;
localparam FP16_EXPONENT_LSB = INPUT_WIDTH-INPUT_SIGN_BITS-INPUT_EXPONENT_BITS;
localparam FP16_MANTISSA_MSB = INPUT_WIDTH-INPUT_SIGN_BITS-INPUT_EXPONENT_BITS-1;
localparam FP16_MANTISSA_LSB = 0;
localparam FP16_EFFECTIVE_MANTISSA_MSB = (INPUT_MANTISSA_BITS+1)*2-1; // 21 for 11x11 result

localparam FP16_BIAS = 5'b01111;

//FP4 E2M1 Constants
localparam FP4_EXPONENT_BITS = 2;
localparam FP4_MANTISSA_BITS = 1;
localparam FP4_BIAS = 1;
// Exponent offset: FP4_stored_exp = FP16_stored_exp - (FP16_BIAS - FP4_BIAS) = FP16_stored_exp - 14
localparam FP4_EXP_OFFSET = FP16_BIAS - FP4_BIAS; // 14

wire is_norm_a, is_norm_b;
wire is_zero;
//Stored Input Values
wire stored_sign_a, stored_sign_b;
wire [INPUT_EXPONENT_BITS-1:0] stored_exp_a, stored_exp_b;
wire [INPUT_MANTISSA_BITS-1:0] stored_mantissa_a, stored_mantissa_b;
//Effective Input Values
wire signed [INPUT_EXPONENT_BITS+1:0] effective_exp_a, effective_exp_b; // 7-bit signed: range -14..15
wire [INPUT_MANTISSA_BITS:0] effective_mantissa_a, effective_mantissa_b; //MSB is norm LSB is mantissa
//Effective Output Values
wire signed [INPUT_EXPONENT_BITS+1:0] effective_exp_out;  // 7-bit signed
wire [7:0] effective_mantissa_out; // 22-bit result
//Stored Output Values
wire stored_sign_out;
wire signed [INPUT_EXPONENT_BITS+1:0] stored_exponent_out; // 7-bit signed
wire stored_mantissa_out;
//Normalization
wire signed [INPUT_EXPONENT_BITS+1:0] shift_factor; // signed: -1, 0, +1
//Saturation output
wire [1:0] fp4_exp;
wire fp4_mant_final;

assign stored_sign_a = A[INPUT_WIDTH-1];
assign stored_sign_b = B[INPUT_WIDTH-1];
assign stored_exp_a = A[FP16_EXPONENT_MSB: FP16_EXPONENT_LSB];
assign stored_exp_b = B[FP16_EXPONENT_MSB: FP16_EXPONENT_LSB];
assign stored_mantissa_a = A[FP16_MANTISSA_MSB: FP16_MANTISSA_LSB];
assign stored_mantissa_b = B[FP16_MANTISSA_MSB: FP16_MANTISSA_LSB];

//Stage 1 - Check for subnormals and zero check
assign is_norm_a = (|stored_exp_a);
assign is_norm_b = (|stored_exp_b);
assign is_zero = (A[INPUT_WIDTH-2:0] == 0 || B[INPUT_WIDTH-2:0] == 0); //dont check sign -0 = 0

//Stage 2 - Calculate Input effectives (bias-free, subnormal contributes -14)
wire signed [INPUT_EXPONENT_BITS+1:0] unbiased_exp_a, unbiased_exp_b;
localparam signed [INPUT_EXPONENT_BITS+1:0] SUBNORM_EXP = 7'sb1110010; // 1 - FP16_BIAS = -14, unchanged
assign unbiased_exp_a = (is_norm_a) ? $signed({2'b00, stored_exp_a}) : SUBNORM_EXP;
assign unbiased_exp_b = (is_norm_b) ? $signed({2'b00, stored_exp_b}) : SUBNORM_EXP;

assign effective_mantissa_a = {is_norm_a, stored_mantissa_a};
assign effective_mantissa_b = {is_norm_b, stored_mantissa_b};

//Stage 3 - Compute Output effectives (FP4_BIAS - 2*FP16_BIAS = -29, pre-computed constant)
localparam signed [INPUT_EXPONENT_BITS+1:0] COMBINED_BIAS = FP4_BIAS - 2*FP16_BIAS; // = -29
assign effective_exp_out = unbiased_exp_a + unbiased_exp_b + COMBINED_BIAS;


dadda_mul_trunc iFiMult(.x(effective_mantissa_a), .y(effective_mantissa_b), .p(effective_mantissa_out));

//Stage 4 - Comput Output stored
assign stored_sign_out = stored_sign_a ^ stored_sign_b;

// For 11x11 multiplication: check bits 21 and 20 for normalization
assign shift_factor =   ((~effective_mantissa_out[7] & ~effective_mantissa_out[6] & effective_mantissa_out[5]) ? 7'sb1111111 :
                        (effective_mantissa_out[7]) ? 7'sb0000001 : 7'sb0000000);


assign stored_exponent_out = effective_exp_out + shift_factor;

// Saturate to FP4 exponent range [0,3]
assign fp4_exp       = ($signed(stored_exponent_out) <= 0) ? 2'b00 :
                       ($signed(stored_exponent_out) >= 4) ? 2'b11 :
                        stored_exponent_out[1:0];
assign fp4_mant_final = ($signed(stored_exponent_out) <  0) ? 1'b0 :  // underflow → 0.0
                        ($signed(stored_exponent_out) == 0) ? 1'b1 :  // subnormal → 0.5
                        ($signed(stored_exponent_out) >= 4) ? 1'b1 :  // saturate  → 6.0
                         stored_mantissa_out;

assign stored_mantissa_out = ((~effective_mantissa_out[7] & ~effective_mantissa_out[6] & effective_mantissa_out[5]) ? 1'b1 :
                            ((~effective_mantissa_out[7] & effective_mantissa_out[6] & effective_mantissa_out[5]) ? 1'b1 :
                             (effective_mantissa_out[7:6] == 2'b11) ? 1'b1 : 1'b0));

//Assign Output
assign Out = (is_zero) ? 4'b0000 : {stored_sign_out, fp4_exp, fp4_mant_final};

endmodule
