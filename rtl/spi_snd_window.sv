//============================================================================
//  SeibuSPI - the 386's view of MAME's `sound01` region
//
//  MAME gives the SXX2C cartridge a 10 MB `sound01` region mapped at 386
//  address 0x00A0_0000, holding two ROMs that the loader stores PACKED in SDRAM
//  and that this decode unpacks on the fly. Extracted from spi_cpu.sv so there
//  is ONE definition: the 386 reads these windows during the sample-flash
//  ritual, and the in-core flash derivation reads exactly the same windows from
//  the same SDRAM, so a second copy of this arithmetic would be a second thing
//  to get wrong. tools/check_snd01_window.py transcribes THIS file, and
//  sim/tb_snd_window.cpp checks it against a model built from MAME's region
//  layout.
//
//  ---------------------------------------------------------------------------
//  THE SOUND1 WINDOW (snd01_en)
//  ---------------------------------------------------------------------------
//  sound1.u0222 is loaded ROM_LOAD32_BYTE on lane 0 at region offset 0x800000,
//  so its 512 KB occupies 2 MB of 386 space at 0120_0000-013F_FFFF and the 386
//  reads it as 524,288 dwords with only byte 0 meaningful. The whole ROM is
//  stored at SDR_SND01_BASE, one byte per 386 dword, so the dword index IS the
//  packed byte index and one 64-bit read covers eight consecutive dwords.
//
//  Decoding the whole ROM rather than just the Z80 program is deliberate:
//  rdft2's program is at 0x60000 and rfjet's at 0x44000, and rfjet's LENGTH has
//  never been measured. Carrying the region whole makes both facts irrelevant.
//
//  ---------------------------------------------------------------------------
//  THE PCM SOURCE WINDOW (pcmsrc_en)
//  ---------------------------------------------------------------------------
//  The rest of the region is the cartridge's PCM ROM, which the updater reads a
//  byte at a time to program the flash. Generation B loads it ROM_LOAD32_WORD,
//  so it occupies TWO byte lanes of every dword -- 1 MB of ROM per 2 MB of
//  window -- and MAME's ROM_CONTINUE(base + 0x400000) puts the second megabyte
//  2 MB further up. So the ROM appears as two windows with a hole between them:
//
//    00A0_0000 - 00BF_FFFF   ROM bytes 0x000000-0x0FFFFF
//    00C0_0000 - 00DF_FFFF   nothing: the ROM_CONTINUE skip
//    00E0_0000 - 00FF_FFFF   ROM bytes 0x100000-0x1FFFFF
//
//  The two windows differ in byte_addr[22] alone -- 0x0A00000 is 101 and
//  0x0E00000 is 111 in 2 MB units -- so that bit IS the ROM's address bit 20,
//  and the 0x0C00000 hole (110) falls out for free because byte_addr[21] is
//  what both windows share.
//
//  Generation A (senkyu, ejanhs, viprp1) puts 1 MB on ONE lane where B puts
//  2 MB on two. The windows land in the same place either way -- a 1 MB ROM at
//  one lane spans exactly what a 2 MB ROM at two lanes does, skip included --
//  so it is one more bit of mode, not a second decode. Leaving the window
//  enabled for a set with nothing behind it made the 386 read 0xFF where MAME
//  reads 0x00 on all 512 K dwords, which is why `snd01_en` and `pcmsrc_en` are
//  separate: check_snd01_window.py caught that before it reached hardware.
//
//  Purely combinational.
//============================================================================

module spi_snd_window
(
	// ---- Which window an address falls in -------------------------------
	// Driven with the address being DECODED, which for spi_cpu is the access
	// the CPU is presenting rather than the one being fetched.
	input      [29:0] sel_dw,
	input             snd01_en,
	input             pcmsrc_en,
	output            sel_s01,
	output            sel_pcm,

	// ---- Where to read, and how to pick the datum out of it -------------
	// Driven with the address being FETCHED, and with `src` stated explicitly
	// rather than re-derived from cur_dw. A burst latches its source once and
	// then walks cur_dw, so re-deriving would silently change source mid-burst
	// if a burst ever straddled a window edge. The caller owns that decision.
	/* verilator lint_off UNUSEDSIGNAL */
	input      [29:0] cur_dw,
	/* verilator lint_on UNUSEDSIGNAL */
	input       [1:0] src,           // SNDW_PRG / SNDW_S01 / SNDW_PCM
	input             pcmsrc_1lane,
	input      [25:0] pcmsrc_base,
	input      [63:0] grp_data,      // the 64-bit SDRAM group at grp_addr

	output     [25:0] grp_addr,
	output      [7:0] byte_out,      // packed byte  (sound1, and gen-A PCM)
	output     [15:0] pair_out,      // packed pair  (gen-B PCM)
	output     [31:0] prg_out,       // the plain program dword
	output            grp_last       // cur_dw is the last dword in its group
);

`include "spi_defs.vh"

	// Both address inputs are deliberately wider than the decode reads. The
	// window tests look only at the top bits -- everything below 2 MB is inside
	// a window by construction -- and the group arithmetic uses the slices the
	// packing calls for. Stating the addresses whole and letting the unused
	// bits go is what keeps the comments above readable in MAME's own byte
	// addresses instead of in dword indices.
	/* verilator lint_off UNUSEDSIGNAL */
	wire [31:0] sel_byte_addr = {sel_dw, 2'b00};
	/* verilator lint_on UNUSEDSIGNAL */

	// 0120_0000-013F_FFFF: sound1.u0222's 2 MB of 386 space, 0x09 * 2 MB.
	assign sel_s01 = snd01_en && (sel_byte_addr[31:21] == 11'h009);

	// The PCM source's two windows, 0x05 and 0x07 * 2 MB.
	assign sel_pcm = pcmsrc_en && (sel_byte_addr[31:24] == 8'd0)
	                           && sel_byte_addr[23] && sel_byte_addr[21];

	// Both the 0x0020_0000 window and the 0xFFE0_0000 real-mode mirror map to
	// the same 2 MB image, so the low 21 bits are the offset either way. SDRAM
	// 64-bit reads are 8-byte aligned, so this is the group containing cur_dw.
	wire [25:0] prg_grp_addr = SDR_PRG_BASE + {4'd0, cur_dw[18:1], 3'b000};

	// sound1: the dword index is the packed byte index.
	wire [25:0] s01_grp_addr = SDR_SND01_BASE + {7'd0, cur_dw[18:3], 3'b000};

	// PCM source. Generation B: the packed byte index is the dword index
	// DOUBLED, with cur_dw[20] (386 address bit 22) carrying the ROM_CONTINUE
	// skip as the ROM's own address bit 20:
	//
	//   idx[20:0] = { cur_dw[20], cur_dw[18:0], 1'b0 }
	//
	// so a group is four dwords and the pair sits at idx[2:0] =
	// {cur_dw[1:0], 1'b0}, always even -- a dword's two bytes never straddle
	// two groups. Generation A is the same with the index undoubled: a group is
	// eight dwords and the byte sits at idx[2:0] = cur_dw[2:0].
	wire [25:0] pcm_grp_addr = pcmsrc_base
	                         + (pcmsrc_1lane
	                            ? {6'd0, cur_dw[20], cur_dw[18:3], 3'b000}
	                            : {5'd0, cur_dw[20], cur_dw[18:2], 3'b000});

	assign grp_addr = (src == SNDW_S01) ? s01_grp_addr
	                : (src == SNDW_PCM) ? pcm_grp_addr
	                                    : prg_grp_addr;

	assign byte_out = grp_data[{cur_dw[2:0], 3'b000} +: 8];
	assign pair_out = grp_data[{cur_dw[1:0], 4'b0000} +: 16];
	assign prg_out  = cur_dw[0] ? grp_data[63:32] : grp_data[31:0];

	// A program dword pair spans one group, eight packed sound1 bytes do, four
	// gen-B PCM dwords do (eight for gen A), so a burst crossing the end needs
	// a fresh fetch.
	assign grp_last = (src == SNDW_S01) ? (cur_dw[2:0] == 3'b111)
	                : (src == SNDW_PCM) ? (pcmsrc_1lane ? (cur_dw[2:0] == 3'b111)
	                                                    : (cur_dw[1:0] == 2'b11))
	                                    :  cur_dw[0];

endmodule
