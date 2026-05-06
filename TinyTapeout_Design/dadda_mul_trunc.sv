// Truncated 11x11 unsigned multiplier – top 8 bits only.
// Instantiates the Dadda reduction tree to get the carry-save pair
// (z0, z1), then adds only bits [21:14] of each vector with a small
// 8-cell ripple-carry adder (HA + 7×FA).
// Output p[7:0] = bits [21:14] of the full 22-bit product.
// Carry-out of bit 21 is discarded (truncation error is accepted).
module dadda_mul_trunc
(
  input  logic [10:0] x,
  input  logic [10:0] y,
  output logic  [7:0] p        // p[7] = bit 21, p[0] = bit 14
);

  // --- carry-save outputs from the Dadda tree ---
  logic [21:0] z0, z1;

  dadda_reduced u_dadda (
    .x  (x),
    .y  (y),
    .z0 (z0),
    .z1 (z1)
  );

  // --- 8-bit ripple-carry adder over bits [21:14] only ---
  // No carry-in from the truncated lower bits.
  logic [8:1] carry;   // carry[8] = overflow from bit 21, discarded

  // Bit 14 (p[0]): HA – no carry-in
  ha u_ha_14 (z0[14], z1[14], p[0], carry[1]);

  // Bits 15..21 (p[1..7]): FA chain
  genvar i;
  generate
    for (i = 1; i <= 7; i++) begin : g_fa
      fa u_fa (z0[14+i], z1[14+i], carry[i], p[i], carry[i+1]);
    end
  endgenerate
  // carry[8] is the overflow from bit 21 – discarded (truncation accepted)

endmodule
