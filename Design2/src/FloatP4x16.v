module FloatP4x16 #(
    parameter INPUT_WIDTH = 4,
    parameter OUTPUT_WIDTH = 16
)(
    input wire [INPUT_WIDTH-1:0]    A,
    input wire [INPUT_WIDTH-1:0]    B,
    output wire [OUTPUT_WIDTH-1:0]  Out
);

//FP4
localparam INPUT_SIGN_BITS = 1;
localparam INPUT_EXPONENT_BITS = 2;
localparam INPUT_MANTISSA_BITS = 1;

localparam FP4_EXPONENT_MSB = INPUT_WIDTH-INPUT_SIGN_BITS-1;
localparam FP4_EXPONENT_LSB = INPUT_WIDTH-INPUT_SIGN_BITS-INPUT_EXPONENT_BITS;
localparam FP4_MANTISSA_MSB = INPUT_WIDTH-INPUT_SIGN_BITS-INPUT_EXPONENT_BITS-1;
localparam FP4_MANTISSA_LSB = INPUT_WIDTH-INPUT_SIGN_BITS-INPUT_EXPONENT_BITS-1;
localparam FP4_EFFECTIVE_MANTISSA_MSB = (INPUT_MANTISSA_BITS+1)*2;

//FP16
localparam OUTPUT_EXPONENT_BITS = 5;
localparam OUTPUT_MANTISSA_BITS = 10;
//FP Constants
localparam FP4_BIAS = 1;
localparam FP16_BIAS = 15;

wire is_norm_a, is_norm_b;
wire is_zero;
//Stored Input Values
wire stored_sign_a, stored_sign_b;
wire [INPUT_EXPONENT_BITS-1:0] stored_exp_a, stored_exp_b;
wire [INPUT_MANTISSA_BITS-1:0] stored_mantissa_a, stored_mantissa_b;
//Effective Input Values
wire [INPUT_EXPONENT_BITS-1:0] effective_exp_a, effective_exp_b;
wire [INPUT_MANTISSA_BITS:0] effective_mantissa_a, effective_mantissa_b; //MSB is norm LSB is mantissa
//Effective Output Values
wire [OUTPUT_EXPONENT_BITS-1:0] effective_exp_out;
wire [FP4_EFFECTIVE_MANTISSA_MSB-1:0] effective_mantissa_out;
//Stored Output Values
wire stored_sign_out;
wire [OUTPUT_EXPONENT_BITS-1:0] stored_exponent_out;
wire [OUTPUT_MANTISSA_BITS-1:0] stored_mantissa_out;
//Normalization
wire [4:0] shift_factor;    //Poss Signed values (-2, -1, 0, 1)

assign stored_sign_a = A[INPUT_WIDTH-1];
assign stored_sign_b = B[INPUT_WIDTH-1];
assign stored_exp_a = A[FP4_EXPONENT_MSB: FP4_EXPONENT_LSB];
assign stored_exp_b = B[FP4_EXPONENT_MSB: FP4_EXPONENT_LSB];
assign stored_mantissa_a = A[FP4_MANTISSA_MSB: FP4_MANTISSA_LSB];
assign stored_mantissa_b = B[FP4_MANTISSA_MSB: FP4_MANTISSA_LSB];

//Stage 1 - Check for subnormals and zero check
assign is_norm_a = (|stored_exp_a);
assign is_norm_b = (|stored_exp_b);
assign is_zero = (A[INPUT_WIDTH-2:0] == 0 || B[INPUT_WIDTH-2:0] == 0); //dont check sign -0 = 0

//Stage 2 - Calculate Input effectives (bias-free, mux selects 0 for subnormals)
wire [INPUT_EXPONENT_BITS-1:0] unbiased_exp_a, unbiased_exp_b;
assign unbiased_exp_a = (is_norm_a) ? stored_exp_a : {INPUT_EXPONENT_BITS{1'b0}};
assign unbiased_exp_b = (is_norm_b) ? stored_exp_b : {INPUT_EXPONENT_BITS{1'b0}};

assign effective_mantissa_a = {is_norm_a, stored_mantissa_a};
assign effective_mantissa_b = {is_norm_b, stored_mantissa_b};

//Stage 3 - Compute Output effectives (FP16_BIAS - 2*FP4_BIAS = 13, pre-computed constant)
localparam COMBINED_BIAS = FP16_BIAS - 2*FP4_BIAS; // = 13, resolved at compile time
assign effective_exp_out = {3'b000, unbiased_exp_a} + {3'b000, unbiased_exp_b} + COMBINED_BIAS;

//Update the run_main.sh script with the right module if youre using verilator
//FixedP2x4 iFiMult(.A(effective_mantissa_a), .B(effective_mantissa_b), .Out(effective_mantissa_out));
FixedP2x4_opt iFiMult(.A(effective_mantissa_a), .B(effective_mantissa_b), .Out(effective_mantissa_out));

//Stage 4 - Comput Output stored
assign stored_sign_out = stored_sign_a ^ stored_sign_b;

    //Normalization
    //  shift factor is added to exponent
    //      +1 -    means that mantissa multiply resulted in 2.25 thus we right shift
    //      0 -     mantissa multiply in normal range
    //      -1/2 -  mantissa multiply less than 1, need to left shift (subtract from exp)

assign shift_factor =   (effective_mantissa_out[3]) ? 5'b00001 : 
                        ((~effective_mantissa_out[3] & ~effective_mantissa_out[2] & effective_mantissa_out[1]) ? 5'b11111 :
                        (~effective_mantissa_out[3] & ~effective_mantissa_out[2] & ~effective_mantissa_out[1]) ? 5'b11110 :
                        5'b00000);

assign stored_mantissa_out = (shift_factor == 5'b00001) ? {effective_mantissa_out[2:0], 7'b0} :
                             ((shift_factor == 5'b11111) ? {effective_mantissa_out[0], 9'b0} :
                             ((shift_factor == 5'b11110) ? {10'b0} : 
                             {effective_mantissa_out[1:0],8'b0})); //default cause (shift factor is 0)


assign stored_exponent_out = (effective_exp_out + shift_factor);

//Assign Output
assign Out = (is_zero) ? 0 : {stored_sign_out, stored_exponent_out, stored_mantissa_out};

endmodule
