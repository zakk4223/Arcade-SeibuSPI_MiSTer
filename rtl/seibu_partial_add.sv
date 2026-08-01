//============================================================================
//  SlopperPI - Seibu "partial carry sum"
//
//  The primitive under every Seibu Kaihatsu graphics encryption
//  (mame/src/mame/seibu/seibu_helper.cpp): an adder whose carry only propagates
//  from bit i to bit i+1 where carry_mask[i] is set, and whose carry out of the
//  top bit wraps around to flip bit 0.
//
//      res_i   = a_i ^ b_i ^ c_i
//      c_{i+1} = mask_i ? majority(a_i, b_i, c_i) : 0
//      if (c_W) res ^= 1
//
//  Purely combinational; a ripple of W stages. At W=32 that is the longest
//  path in the sprite decrypt pipeline, so callers register the result.
//============================================================================

module seibu_partial_add #(parameter W = 24)
(
	input  [W-1:0] a,
	input  [W-1:0] b,
	input  [W-1:0] carry_mask,
	output [W-1:0] y
);

	wire [W:0]   carry;
	wire [W-1:0] sum;

	assign carry[0] = 1'b0;

	genvar i;
	generate
		for (i = 0; i < W; i = i + 1) begin : stage
			wire [1:0] s = a[i] + b[i] + carry[i];
			assign sum[i]      = s[0];
			assign carry[i+1]  = carry_mask[i] ? s[1] : 1'b0;
		end
	endgenerate

	// Carry out of the top bit wraps around and flips bit 0.
	assign y = sum ^ {{(W-1){1'b0}}, carry[W]};

endmodule
