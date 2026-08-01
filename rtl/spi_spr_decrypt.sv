//============================================================================
//  SlopperPI - SEI252 sprite graphics decryption
//
//  mame/src/mame/seibu/seibuspi_m.cpp:115 (seibuspi_sprite_decrypt).
//
//  One invocation consumes a 16-bit word from each of the three sprite ROM
//  plane-pair chunks (48 bits) and produces 8 pixels at 6 bpp. MAME writes the
//  result back as six plane bytes and lets the gfx decoder unpack them; we skip
//  the round trip and emit pixels directly. The mapping, worked through from
//  spi_spritelayout:
//
//    gfx plane p of pixel x reads byte p of the row at bit x, and the decrypt
//    stores plane5..plane0 into chunk0.b0, chunk0.b1, chunk1.b0, chunk1.b1,
//    chunk2.b0, chunk2.b1 -- so gfx plane 0 (the pixel's LSB) comes from MAME's
//    `plane5` variable, and so on inverted through to plane 5.
//
//      pixel[j] = { s2[4j], s2[4j+1], s2[4j+2], s2[4j+3], s1[2j], s1[2j+1] }
//                    bit5      bit4      bit3      bit2     bit1     bit0
//
//  The address term is constant across a whole sprite tile:
//
//    word index i = code*32 + row*2 + half,  addr = i >> 8 = code >> 3
//
//  because row*2+half <= 31 and (code & 7)*32 + 31 <= 255 never carries into
//  bit 8. So the key_table lookup happens once per tile, not once per word.
//
//  Purely combinational. The 32-bit partial-carry ripple is the critical path,
//  so callers should register `pix`.
//============================================================================

module spi_spr_decrypt
(
	input      [15:0] y1,      // chunk 0 word (little endian, as stored)
	input      [15:0] y2,      // chunk 1 word
	input      [15:0] y3,      // chunk 2 word
	input      [11:0] addr,    // = sprite tile code >> 3

	output      [5:0] pix0,
	output      [5:0] pix1,
	output      [5:0] pix2,
	output      [5:0] pix3,
	output      [5:0] pix4,
	output      [5:0] pix5,
	output      [5:0] pix6,
	output      [5:0] pix7
);

	// ------------------------------------------------------------------
	// Key lookup
	//
	//   key(t, addr) = bit(key_table[addr & 0xFF] >> 4, t)
	//                ^ bit(addr, 8 + ((t & 0xC) >> 2))
	//
	// and (t & 0xC) >> 2 == t >> 2 for the t in 0..10 that are actually used.
	// ------------------------------------------------------------------
	// key_table entries are used as: bits 0-3 select the y3 permutation, bits
	// 4-14 are the eleven key bits. Bit 15 is deliberately unused -- MAME notes
	// "Bit 15 is still unknown" and never reads it either.
	/* verilator lint_off UNUSEDSIGNAL */
	wire [15:0] kt    = key_table[addr[7:0]];
	/* verilator lint_on UNUSEDSIGNAL */
	wire  [3:0] bsidx = kt[3:0];

	wire [10:0] keyf;
	genvar t;
	generate
		for (t = 0; t < 11; t = t + 1) begin : keygen
			assign keyf[t] = kt[t + 4] ^ addr[8 + (t >> 2)];
		end
	endgenerate

	// key_table[], the y3 permutation and the four bit gathers
	// (s1_in, add1_in, s2_in, add2_in) are machine generated from MAME.
	`include "spi_spr_tables.vh"

	// ------------------------------------------------------------------
	// Partial carry sums
	//   s1 = partial_carry_sum16(s1, add1, 0x3A59)     ^ 0x843A
	//   s2 = partial_carry_sum32(s2, add2, 0x28D49CAC) ^ 0xC8E29F84
	// ------------------------------------------------------------------
	wire [15:0] s1_pcs;
	wire [31:0] s2_pcs;

	seibu_partial_add #(.W(16)) pa1
	(
		.a(s1_in), .b(add1_in), .carry_mask(16'h3A59), .y(s1_pcs)
	);

	seibu_partial_add #(.W(32)) pa2
	(
		.a(s2_in), .b(add2_in), .carry_mask(32'h28D49CAC), .y(s2_pcs)
	);

	wire [15:0] s1 = s1_pcs ^ 16'h843A;
	wire [31:0] s2 = s2_pcs ^ 32'hC8E29F84;

	// ------------------------------------------------------------------
	// Pixels
	// ------------------------------------------------------------------
	assign pix0 = {s2[ 0], s2[ 1], s2[ 2], s2[ 3], s1[ 0], s1[ 1]};
	assign pix1 = {s2[ 4], s2[ 5], s2[ 6], s2[ 7], s1[ 2], s1[ 3]};
	assign pix2 = {s2[ 8], s2[ 9], s2[10], s2[11], s1[ 4], s1[ 5]};
	assign pix3 = {s2[12], s2[13], s2[14], s2[15], s1[ 6], s1[ 7]};
	assign pix4 = {s2[16], s2[17], s2[18], s2[19], s1[ 8], s1[ 9]};
	assign pix5 = {s2[20], s2[21], s2[22], s2[23], s1[10], s1[11]};
	assign pix6 = {s2[24], s2[25], s2[26], s2[27], s1[12], s1[13]};
	assign pix7 = {s2[28], s2[29], s2[30], s2[31], s1[14], s1[15]};

endmodule
