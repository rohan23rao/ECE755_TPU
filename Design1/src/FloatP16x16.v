module FloatP16x16 #(
    parameter INPUT_WIDTH = 16,
    parameter OUTPUT_WIDTH = 16
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
localparam FP16_MANTISSA_LSB = INPUT_WIDTH-INPUT_SIGN_BITS-INPUT_EXPONENT_BITS-1;
localparam FP16_EFFECTIVE_MANTISSA_MSB = (INPUT_MANTISSA_BITS+1)*2-1; // 21 for 11x11 result

localparam FP16_BIAS = 15;

wire is_norm_a, is_norm_b;
wire is_zero;
//Stored Input Values
wire stored_sign_a, stored_sign_b;
wire [INPUT_EXPONENT_BITS-1:0] stored_exp_a, stored_exp_b;
wire [INPUT_MANTISSA_BITS-1:0] stored_mantissa_a, stored_mantissa_b;
//Effective Input Values
wire signed [INPUT_EXPONENT_BITS:0] effective_exp_a, effective_exp_b;  // 6 bits for negative values
wire [INPUT_MANTISSA_BITS:0] effective_mantissa_a, effective_mantissa_b; //MSB is norm LSB is mantissa
//Effective Output Values
wire signed [INPUT_EXPONENT_BITS:0] effective_exp_out;  // 6 bits for negative values
wire [FP16_EFFECTIVE_MANTISSA_MSB:0] effective_mantissa_out; // 22-bit result
//Stored Output Values
wire stored_sign_out;
wire signed [INPUT_EXPONENT_BITS:0] stored_exponent_out_temp;  // 6-bit signed
wire [INPUT_EXPONENT_BITS-1:0] stored_exponent_out;  // 5-bit final
wire [INPUT_MANTISSA_BITS-1:0] stored_mantissa_out;
//Normalization
wire [4:0] shift_factor;    //Poss Signed values (-2, -1, 0, 1)

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

//Stage 2 - Calculate Input effectives
assign effective_exp_a = (is_norm_a) ? ($signed(stored_exp_a) - FP16_BIAS) : (1-FP16_BIAS);
assign effective_exp_b = (is_norm_b) ? ($signed(stored_exp_b) - FP16_BIAS) : (1-FP16_BIAS);

assign effective_mantissa_a = {is_norm_a, stored_mantissa_a};
assign effective_mantissa_b = {is_norm_b, stored_mantissa_b};

//Stage 3 - Compute Output effectives
assign effective_exp_out = effective_exp_a + effective_exp_b + FP16_BIAS;

//Update the run_main.sh script with the right module if youre using verilator
//FixedP11x11 iFiMult(.A(effective_mantissa_a), .B(effective_mantissa_b), .Out(effective_mantissa_out));
FixedP11x11 iFiMult(.A(effective_mantissa_a), .B(effective_mantissa_b), .Out(effective_mantissa_out));

//Stage 4 - Comput Output stored
assign stored_sign_out = stored_sign_a ^ stored_sign_b;

    //Normalization
    //  shift factor is added to exponent
    //      +1 -    means that mantissa multiply resulted in 2.25 thus we right shift
    //      0 -     mantissa multiply in normal range
    //      -1/2 -  mantissa multiply less than 1, need to left shift (subtract from exp)

// For 11x11 multiplication: check bits 21 and 20 for normalization
// Result range: [0.25, 3.999...] for normalized inputs [1.0, 1.999...]
assign shift_factor =   (effective_mantissa_out[21]) ? 5'b00001 :        // Carry out, result >= 2.0
                        ((effective_mantissa_out[20]) ? 5'b00000 :       // Normal range 1.0 <= result < 2.0
                        ((effective_mantissa_out[19]) ? 5'b11111 :       // Result < 1.0, need left shift 1
                        5'b11110));                                         // Result < 0.5, need left shift 2


assign stored_exponent_out_temp = (effective_exp_out + $signed(shift_factor));
assign stored_exponent_out = (stored_exponent_out_temp <= 0) ? 5'b00000 : stored_exponent_out_temp[4:0];

// Handle subnormal mantissa adjustment
wire [4:0] subnormal_shift = (stored_exponent_out_temp <= 0) ? (1 - stored_exponent_out_temp) : 5'b00000;
wire [19:0] subnormal_mantissa = (effective_mantissa_out >> subnormal_shift);
assign stored_mantissa_out = (stored_exponent_out_temp <= 0) ? subnormal_mantissa[17:8] :
                             (shift_factor == 5'b00001) ? effective_mantissa_out[20:11] :      // Right shift 1
                             (shift_factor == 5'b11111) ? effective_mantissa_out[19:10] : // Left shift 1  
                             (shift_factor == 5'b11110) ? effective_mantissa_out[18:9] :  // Left shift 2
                             effective_mantissa_out[10:1];                            // No shift: extract bits 10-1

//Assign Output
assign Out = (is_zero) ? 0 : {stored_sign_out, stored_exponent_out, stored_mantissa_out};

endmodule
