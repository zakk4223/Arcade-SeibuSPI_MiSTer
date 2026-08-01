//============================================================================
//  SlopperPI - Seibu SPI tile / char graphics decryption
//
//  mame/src/mame/seibu/seibuspi_v.cpp:42
//
//      decrypt_tile(val, tileno) =
//          partial_carry_sum24(bitswap24(val), tileno + KEY1, KEY2) ^ KEY3
//
//  One unit decrypts one 24-bit group, which is 4 pixels at 6 bpp. A 16-pixel
//  tile row is four groups; an 8-pixel char row is two.
//
//  The `tileno` term is what makes this cheap enough to do at fetch time rather
//  than in a boot-time pass over the whole ROM: MAME derives it from the ROM
//  address, but that collapses to the tile code.
//
//    chars: each 8x8 tile is 48 bytes = 16 groups, MAME uses group_index >> 4,
//           so tileno = char code.
//    tiles: decryption restarts every 0xC0000 bytes; within a block each 16x16
//           tile is 192 bytes = 64 groups and MAME uses group_index >> 6, so
//           tileno = tile_code & 0xFFF.
//
//  Purely combinational.
//============================================================================

module spi_tile_decrypt
(
	input      [23:0] din,      // raw 24-bit group as stored in SDRAM
	input      [11:0] tileno,
	input      [23:0] key1,
	input      [23:0] key2,
	input      [23:0] key3,
	output     [23:0] dout
);

	// MAME: bitswap<24>(val, 18,19,9,5, 10,17,16,20, 21,22,6,11,
	//                        15,14,4,23, 0,1,7,8, 13,12,3,2)
	// The first source index becomes the result's MSB.
	wire [23:0] sw = {
		din[18], din[19], din[ 9], din[ 5],
		din[10], din[17], din[16], din[20],
		din[21], din[22], din[ 6], din[11],
		din[15], din[14], din[ 4], din[23],
		din[ 0], din[ 1], din[ 7], din[ 8],
		din[13], din[12], din[ 3], din[ 2]
	};

	// tileno + key1 is an ordinary add; only the low 24 bits matter.
	wire [23:0] addend = {12'd0, tileno} + key1;

	wire [23:0] pcs;
	seibu_partial_add #(.W(24)) pa
	(
		.a          (sw),
		.b          (addend),
		.carry_mask (key2),
		.y          (pcs)
	);

	assign dout = pcs ^ key3;

endmodule
