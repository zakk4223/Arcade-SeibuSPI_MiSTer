//============================================================================
//  SlopperPI - RISE10 sprite decryption (rdft2 / rdft2us / rdft22kc)
//
//  seibuspi_rise10_sprite_decrypt(), seibuspi_m.cpp. Operates on one 16-bit
//  word from each of the three plane-pair chunks at a time -- 48 bits in, 48
//  bits out, eight pixels of six planes.
//
//  MUCH cheaper than SEI252, and the reason is that it is ADDRESS INDEPENDENT.
//  SEI252 needs key_table[addr & 0xFF], a bitswap selected from that key, and a
//  per-tile key fetch. RISE10 has none of it: a fixed 32-bit permutation and
//  two partial-carry sums whose every operand is a constant. So this unit has
//  no `addr` input and no lookup tables at all.
//
//  (RISE11, for rfjet, is NOT address independent despite what PLAN.md section
//  0 used to claim -- its plane210 sum takes the word index as the addend. It
//  needs a different unit.)
//
//  The output convention matches spi_spr_decrypt exactly, so the two are
//  interchangeable at the fetch site. MAME writes both back as
//      chunk0 = {plane5, plane4}   chunk1 = {plane3, plane2}
//      chunk2 = {plane1, plane0}
//  and pixel j of plane n is bit j of that byte. The pen is assembled with bit
//  p carrying plane(5-p) -- bit 0 is plane5, the pen's MSB -- which is the
//  convention PLAN.md section 13 records after a bit-reversal cost real time.
//
//  NOT handled here: sprite_reorder(). That permutes whole words inside each
//  64-byte group and is an address swizzle, not arithmetic -- output word 2j
//  comes from input word j, output word 2j+1 from input word j+16. It lives in
//  rom_loader's M_SPR_R10 scatter mode, which folds it into the LOAD-time
//  destination. Doing it at fetch time would put the two halves of a 16-pixel
//  row 32 bytes apart and cost six SDRAM reads per row instead of three; doing
//  it in the loader costs nothing, because the loader computes a destination
//  per byte anyway. Either way it is not the decrypt unit's business, and
//  tb_rise10_decrypt checks that the split is real.
//============================================================================

module spi_rise10_decrypt
(
	input      [15:0] y1,      // chunk 0 word (little endian, as stored)
	input      [15:0] y2,      // chunk 1 word
	input      [15:0] y3,      // chunk 2 word

	output      [5:0] pix0,
	output      [5:0] pix1,
	output      [5:0] pix2,
	output      [5:0] pix3,
	output      [5:0] pix4,
	output      [5:0] pix5,
	output      [5:0] pix6,
	output      [5:0] pix7
);

`include "spi_rise10_tables.vh"

	// ------------------------------------------------------------------
	// Gather. plane54 is chunk 0 verbatim; plane3210 is chunks 2 and 1
	// concatenated -- note the order, chunk 2 supplies the LOW half:
	//     rom[2*size + 2i] + (rom[2*size + 2i + 1] << 8)
	//   + (rom[1*size + 2i] << 16) + (rom[1*size + 2i + 1] << 24)
	// then permuted by the fixed bitswap.
	// ------------------------------------------------------------------
	wire [15:0] plane54_in = y1;
	wire [31:0] raw3210    = {y2, y3};
	wire [31:0] plane3210_in = `R10_BITSWAP(raw3210);

	// ------------------------------------------------------------------
	// Two partial carry sums, constants throughout.
	// ------------------------------------------------------------------
	wire [15:0] s54_pcs;
	wire [31:0] s3210_pcs;

	seibu_partial_add #(.W(16)) pa54
	(
		.a(plane54_in), .b(R10_ADD54), .carry_mask(R10_MASK54), .y(s54_pcs)
	);

	seibu_partial_add #(.W(32)) pa3210
	(
		.a(plane3210_in), .b(R10_ADD3210), .carry_mask(R10_MASK3210), .y(s3210_pcs)
	);

	wire [15:0] plane54   = s54_pcs   ^ R10_XOR54;
	wire [31:0] plane3210 = s3210_pcs ^ R10_XOR3210;

	// ------------------------------------------------------------------
	// Pixels. plane54[15:8] is plane5 and [7:0] plane4; plane3210[31:24] is
	// plane3 down to [7:0] plane0. Pixel j takes bit j of each.
	// ------------------------------------------------------------------
	wire [7:0] p0 = plane3210[ 7: 0];
	wire [7:0] p1 = plane3210[15: 8];
	wire [7:0] p2 = plane3210[23:16];
	wire [7:0] p3 = plane3210[31:24];
	wire [7:0] p4 = plane54  [ 7: 0];
	wire [7:0] p5 = plane54  [15: 8];

	assign pix0 = {p0[0], p1[0], p2[0], p3[0], p4[0], p5[0]};
	assign pix1 = {p0[1], p1[1], p2[1], p3[1], p4[1], p5[1]};
	assign pix2 = {p0[2], p1[2], p2[2], p3[2], p4[2], p5[2]};
	assign pix3 = {p0[3], p1[3], p2[3], p3[3], p4[3], p5[3]};
	assign pix4 = {p0[4], p1[4], p2[4], p3[4], p4[4], p5[4]};
	assign pix5 = {p0[5], p1[5], p2[5], p3[5], p4[5], p5[5]};
	assign pix6 = {p0[6], p1[6], p2[6], p3[6], p4[6], p5[6]};
	assign pix7 = {p0[7], p1[7], p2[7], p3[7], p4[7], p5[7]};

endmodule
