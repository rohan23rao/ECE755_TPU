module gemm_vector_unit #(
    parameter int FP16_WIDTH = 16, // FP16 scale factor
    parameter int FP4_WIDTH = 4,   // FP4 quantization width
    parameter int LANES = 8        // Number of parallel lanes
) (
    input logic clk,
    input logic relu_en,
    input logic  [LANES-1:0] quant_en,  // Per-lane quantization enable signals
    input logic  [FP16_WIDTH- 1:0] col_out [0:LANES-1], // 8 FP16 input data
    input logic  [FP16_WIDTH - 1:0] scale,        // 1 FP16 data for one cycle, quantize column by column

    output logic [FP4_WIDTH - 1:0] y_out[0:LANES-1]           // 8 FP4 quantized output data
);

logic  [FP16_WIDTH-1:0] quant_in   [LANES - 1:0];      // Muxed input for quantization
logic  [FP16_WIDTH-1:0] quant_scale[LANES - 1:0];      // Muxed scale for quantization
logic  [FP4_WIDTH-1:0]  reg_out    [LANES - 1:0];      // Register to hold quantized output after RELU
logic  [FP4_WIDTH-1:0]  mult_out   [LANES - 1:0];      // Output of the FP16 multiplication before quantization

genvar i;
generate 
    for (i=0; i<LANES; i=i+1) begin : gen_scale_data_reg

       // Mux logic: If RELU is enabled and data is negative, or if quantization is disabled, set quantization input and scale to 0; otherwise, use the original data and scale
       assign quant_in[i]      = ((relu_en && col_out[i][FP16_WIDTH - 1]) || (!quant_en[i])) ? '0 : col_out[i]; 
       assign quant_scale[i]   = ((relu_en && col_out[i][FP16_WIDTH - 1]) || (!quant_en[i])) ? '0 : scale;

       FloatP16x4 iFloat (.A(quant_scale[i]), .B(quant_in[i]), .Out(mult_out[i])); // FP16 multiplier instance for quantization scaling

       // RELU clamping & Quantization logic
       always_ff @(posedge clk) begin
         if (quant_en[i])
                reg_out[i] <= mult_out[i]; // take sign bit, MSB of mantissa, and 2 MSBs of exponent for FP4 E2M1
        end
    
        assign y_out[i] = reg_out[i]; // For debugging: output the quantized value of each lane directly to data_out bits
    end
endgenerate
endmodule