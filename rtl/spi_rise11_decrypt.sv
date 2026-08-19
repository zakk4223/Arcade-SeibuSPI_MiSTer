//============================================================================
//  SeibuSPI - RISE11 sprite decryption (rfjet)
//
//  seibuspi_rise11_sprite_decrypt(), seibuspi_m.cpp. Like the other two units
//  it takes one 16-bit word from each of the three plane-pair chunks -- 48 bits
//  in, eight six-plane pixels out -- and it presents the same interface, so
//  spi_sprite muxes the three on the result.
//
//  THE WORD INDEX IS AN OPERAND. This is the one structural difference from
//  RISE10 and the reason the two cannot share a unit: plane210's partial carry
//  sum takes `i`, the index of the word within the chunk, as its addend rather
//  than a constant. Feed it the wrong index and every pixel of that word is
//  wrong, silently -- there is no self-check anywhere downstream.
//
//  `i` is MAME's loop variable, which is the index BEFORE sprite_reorder(). The
//  loader has already applied that reorder as an address swizzle (M_SPR_ILV_R),
//  so what the fetch holds is a POST-reorder position and it has to be turned
//  back. That inverse is a wire permutation and it lives at the fetch site,
//  where the tile code and row are; see spi_sprite.sv.
//
//  Cheap, like RISE10: two 24-bit gathers (pure wiring), two 24-bit partial
//  carry sums, two xors. No key table, no per-tile key fetch, no lookup at all.
//
//  Pen convention matches spi_spr_decrypt and spi_rise10_decrypt exactly: bit p
//  of the pen carries plane(5-p), so bit 0 is plane5 and is the pen's MSB. MAME
//  writes the planes back as
//      chunk0 = {plane5, plane4}   chunk1 = {plane3, plane2}
//      chunk2 = {plane1, plane0}
//  which is the same byte-to-plane map RISE10 uses; only the way the six planes
//  are grouped into sums differs (543 / 210 here, 54 / 3210 there).
//============================================================================

module spi_rise11_decrypt
(
	input      [15:0] y1,      // chunk 0 word (little endian, as stored)
	input      [15:0] y2,      // chunk 1 word
	input      [15:0] y3,      // chunk 2 word

	// MAME's `i`: the word's index within one plane-pair chunk, BEFORE
	// sprite_reorder. 8 MB chunks are 4M words, so 22 bits is the whole range;
	// the sum is 24 bits wide and the top two are always zero.
	input      [23:0] i,

	output      [5:0] pix0,
	output      [5:0] pix1,
	output      [5:0] pix2,
	output      [5:0] pix3,
	output      [5:0] pix4,
	output      [5:0] pix5,
	output      [5:0] pix6,
	output      [5:0] pix7
);

`include "spi_rise11_tables.vh"

	// ------------------------------------------------------------------
	// Gather. Two fixed permutations that between them consume all 48 input
	// bits exactly once -- checked in the generator, not here.
	// ------------------------------------------------------------------
	wire [23:0] plane543_in = `R11_GATHER543(y1, y2, y3);
	wire [23:0] plane210_in = `R11_GATHER210(y1, y2, y3);

	// ------------------------------------------------------------------
	// Two partial carry sums. MAME's plane543 line calls the 32-bit form,
	// but every operand is 24 bits and R11_MASK543 cannot carry out of bit
	// 23, so a 24-bit adder gives the same answer -- the generator refuses
	// to emit constants for which that is not true.
	// ------------------------------------------------------------------
	wire [23:0] s543_pcs;
	wire [23:0] s210_pcs;

	seibu_partial_add #(.W(24)) pa543
	(
		.a(plane543_in), .b(R11_ADD543), .carry_mask(R11_MASK543), .y(s543_pcs)
	);

	seibu_partial_add #(.W(24)) pa210
	(
		.a(plane210_in), .b(i), .carry_mask(R11_MASK210), .y(s210_pcs)
	);

	wire [23:0] plane543 = s543_pcs ^ R11_XOR543;
	wire [23:0] plane210 = s210_pcs ^ R11_XOR210;

	// ------------------------------------------------------------------
	// Pixels. plane543 holds planes 5, 4, 3 from the top byte down and
	// plane210 holds 2, 1, 0. Pixel j takes bit j of each plane byte.
	// ------------------------------------------------------------------
	wire [7:0] p0 = plane210[ 7: 0];
	wire [7:0] p1 = plane210[15: 8];
	wire [7:0] p2 = plane210[23:16];
	wire [7:0] p3 = plane543[ 7: 0];
	wire [7:0] p4 = plane543[15: 8];
	wire [7:0] p5 = plane543[23:16];

	assign pix0 = {p0[0], p1[0], p2[0], p3[0], p4[0], p5[0]};
	assign pix1 = {p0[1], p1[1], p2[1], p3[1], p4[1], p5[1]};
	assign pix2 = {p0[2], p1[2], p2[2], p3[2], p4[2], p5[2]};
	assign pix3 = {p0[3], p1[3], p2[3], p3[3], p4[3], p5[3]};
	assign pix4 = {p0[4], p1[4], p2[4], p3[4], p4[4], p5[4]};
	assign pix5 = {p0[5], p1[5], p2[5], p3[5], p4[5], p5[5]};
	assign pix6 = {p0[6], p1[6], p2[6], p3[6], p4[6], p5[6]};
	assign pix7 = {p0[7], p1[7], p2[7], p3[7], p4[7], p5[7]};

endmodule
