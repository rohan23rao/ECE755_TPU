module ha
(
	input  logic [0 : 0] a,
	input  logic [0 : 0] b,
	output logic [0 : 0] s,
	output logic [0 : 0] c
);

	assign s = a ^ b;
	assign c = a & b;

endmodule