//============================================================================
//  SlopperPI - read SDRAM from the host over JTAG
//
//  Two In-System Sources & Probes instances:
//
//    PEEK  source = {go, addr[25:0]}   probe = {ack, data[63:0]}   (27 bits)
//          Writing an address and flipping `go` issues one 64-bit SDRAM read;
//          `ack` flips back when `data` is valid. tools/jtag_peek.tcl drives it.
//
//    SUMS  probe = {ok[3:0], sum_sprites, sum_tiles, sum_chars, sum_prg}
//          What spi_romcheck actually computed, so a checksum mismatch can be
//          told apart from a checker that is reading through a broken path.
//
//  This exists because every failure so far has been ambiguous between "the
//  hardware is wrong" and "the instrument is wrong", and reading the real SDRAM
//  contents from the host settles that directly.
//
//  Simulation-only builds never see this: it lives in SeibuSPI.sv, outside the
//  module set that sim/ lints, because altsource_probe is an Altera primitive.
//============================================================================

module spi_jtag_peek
(
	input             clk,
	input             reset,
	input             enable,        // only take the bus once the checker is done

	// SDRAM read port (shared with spi_romcheck, handed over after chk_done)
	output reg [25:0] sdr_addr,
	input      [63:0] sdr_dout,
	output reg        sdr_req,
	input             sdr_ack,

	input      [31:0] sum_prg,
	input      [31:0] sum_chars,
	input      [31:0] sum_tiles,
	input      [31:0] sum_sprites,
	input       [3:0] ok,
	input      [15:0] passes,
	input      [15:0] fails,
	input      [25:0] bytes_in,
	// What reached SDRAM. Equal to bytes_in for a straight copy, so a mismatch
	// on a set with no decoded part means the loader is losing or repeating
	// ioctl bytes; on a decoded part it is the only way to tell a decoder that
	// is working slowly from one that has stopped.
	input      [25:0] bytes_out,
	input       [4:0] part_end,

	// Live counters from the board, so the vital signs can be read over JTAG
	// instead of squinting at bars on a capture card.
	input      [15:0] c_prg,
	input      [15:0] c_iowr,
	input      [15:0] c_dma_tm,
	input      [15:0] c_dma_pal,
	input      [15:0] c_vbl,
	input       [3:0] why,
	input      [31:0] eip,
	input      [15:0] cs,
	input             irq,
	input      [15:0] lay_ovr,
	input       [1:0] lay_ovr_layer,
	input       [5:0] lay_text_col,
	input      [15:0] spr_scanned,
	input      [15:0] spr_yhit,
	input      [15:0] spr_emitted,
	input      [15:0] spr_starved,
	input      [15:0] spr_tiles,
	input      [15:0] c_dma_spr,     // sprite-list DMA triggers
	input      [15:0] spr_codes_nz,  // list entries with a non-zero code
	input      [31:0] spr_ram_or,    // OR of all sprite-RAM dwords on a line
	input      [17:2] dma_src_spr,   // source the sprite DMA actually used
	input      [15:0] cpu_wr_spr,    // CPU dword writes into 0x37000..0x37FFF
	input      [15:0] cpu_wr_tm,     // ... and into 0x38000..0x38FFF (control)
	input             frozen,        // CPU stopped (JTAG bit OR controller button)
	input             rs_en,         // rowscroll_enable as this side sees it
	input             fd13,
	input      [12:0] tm_dwords,     // 4096 = rowscroll on, 2560 = off
	input      [95:0] scrolls,       // {fy,fx,my,mx,by,bx}
	input       [4:0] lay_en,
	input      [11:0] dma_text_dw,
	input     [191:0] gdt,

	// Sound subsystem, on its own SNDV probe.
	input      [15:0] snd_pc,          // last Z80 M1 address
	input      [15:0] snd_fifo_rd,     // commands the Z80 has taken from the 386
	input      [15:0] snd_ymf_wr,      // YMF271 register writes
	input      [15:0] snd_stall,       // SDRAM fetches the Z80 had to wait for
	input      [15:0] ymf_overrun,     // samples the synth could not finish
	input      [15:0] ymf_active,      // slots sounding on the last sample
	// Z80 -> 386 FIFO, one counter per side, so a stuck handshake names its own
	// guilty half: pushes without pops means the 386 is not reading 0x680,
	// pops without pushes means the Z80 never got room to send.
	input      [15:0] snd_f2_wr,       // pushes by the Z80 (0x4008 write)
	input      [15:0] snd_f2_rd,       // pops by the 386  (0x680 read)
	// How hard the 386 is being blocked in the sound handshake. High-water
	// marks, so they can be sampled at any interval -- unlike every counter
	// above them, which wraps.
	input       [8:0] snd_fifo_peak,   // deepest the 386 -> Z80 FIFO has got
	input      [15:0] snd_full_max,    // longest FIFO-full run, 17.87 us units
	input      [15:0] spr_gap_max,     // longest sprite-DMA gap, same units
	input      [15:0] snd_wait_max,    // longest single Z80 ROM fetch wait
	// Where the 386 was the first time the frame gap passed two frames. A
	// maximum says a hitch happened; this says what was running when it did.
	input      [31:0] stall_eip,
	input      [15:0] stall_cs,

	// SDRAM occupancy, per channel, per 2^21 clk_ram window. Its own probe
	// because it is a different question from everything on SNDV.
	input      [94:0] sdr_trans,

	// Live layer masks driven from the host, so a rendering fault can be
	// isolated to a layer without a rebuild for each experiment.
	output      [7:0] ctrl,

	// EIP profiler: the window goes down, the two free-running counters come
	// back up. spi_top does the counting, on clk_cpu.
	output     [31:0] prof_lo,
	output     [31:0] prof_hi,
	input      [39:0] prof_in,
	input      [39:0] prof_total
);

	// Width of the SUMS probe, written as the sum of its fields rather than as a
	// number. It was a literal 193 while the concatenation had grown to 195 --
	// part_end went 4 bits to 5 and bytes_in 25 to 26 -- so the top two bits of
	// `fails` were truncated away and tools/jtag_peek.tcl, which slices from the
	// MSB, misread EVERY field after it. The instrument reported a part index
	// and a byte count that were simply not the ones in the hardware. Keep this
	// expression and the concatenation below in step; the Tcl prints the width
	// it actually got, so a future mismatch announces itself.
	localparam SUMS_W = 16    // fails
	                  + 16    // passes
	                  + 5     // part_end
	                  + 26    // bytes_in
	                  + 26    // bytes_out
	                  + 4     // ok
	                  + 32*4; // sum_sprites, sum_tiles, sum_chars, sum_prg

	// 27 bits, not 26: `go` sits ABOVE the address, it is not the top address
	// bit. Sharing bit 25 read every PEEK 32 MB high whenever go was 1, and
	// capped the reachable address at 32 MB -- which does not cover
	// SDR_SPRITES_BASE + 24 MB on the 64 MB module rdft2 needs.
	wire [26:0] source;
	wire        go   = source[26];
	wire [25:0] addr = source[25:0];

	reg        ack;
	reg [63:0] data;
	reg        go_d;
	reg        busy;

	altsource_probe
	#(
		.sld_auto_instance_index ("YES"),
		.sld_instance_index      (0),
		.instance_id             ("PEEK"),
		.probe_width             (65),
		.source_width            (27),
		.source_initial_value    ("0"),
		.enable_metastability    ("YES")
	)
	peek_issp
	(
		.probe      ({ack, data}),
		.source     (source),
		// enable_metastability="YES" registers the source into source_clk. With
		// no clock connected the register never advances and every write from
		// the host is silently discarded -- the source reads back as its
		// initial value forever.
		.source_clk (clk),
		.source_ena (1'b1)
	);

	altsource_probe
	#(
		.sld_auto_instance_index ("YES"),
		.sld_instance_index      (1),
		.instance_id             ("SUMS"),
		.probe_width             (SUMS_W),
		.source_width            (1),
		.source_initial_value    ("0"),
		.enable_metastability    ("NO")
	)
	sums_issp
	(
		.probe  ({fails, passes, part_end, bytes_in, bytes_out, ok, sum_sprites, sum_tiles, sum_chars, sum_prg}),
		.source ()
	);

	altsource_probe
	#(
		.sld_auto_instance_index ("YES"),
		.sld_instance_index      (2),
		.instance_id             ("VITL"),
		.probe_width             (478),
		.source_width            (1),
		.source_initial_value    ("0"),
		.enable_metastability    ("NO")
	)
	vitals_issp
	(
		// The Tcl reads this probe as a binary string MSB first, so index 0 is
		// the leftmost element here. New fields therefore go at the END (the LSB
		// side): appending leaves indices 0..253 exactly where they were, and
		// the two new words land at 254..285. Prepending would have shifted
		// every existing offset by 32 and silently corrupted every field.
		.probe  ({spr_starved, spr_tiles, dma_text_dw, lay_en, spr_emitted, spr_yhit, spr_scanned,
		          lay_text_col, lay_ovr_layer, lay_ovr, irq, cs, eip, why,
		          c_vbl, c_dma_pal, c_dma_tm, c_iowr, c_prg,
		          c_dma_spr, spr_codes_nz, spr_ram_or, dma_src_spr,
		          cpu_wr_spr, cpu_wr_tm, frozen,
		          rs_en, fd13, tm_dwords, scrolls}),
		.source ()
	);

	// A separate instance rather than more bits on VITL: altsource_probe caps
	// probe_width at 511 and VITL is already at 478.
	altsource_probe
	#(
		.sld_auto_instance_index ("YES"),
		.sld_instance_index      (5),
		.instance_id             ("SNDV"),
		.probe_width             (233),
		.source_width            (1),
		.source_initial_value    ("0"),
		.enable_metastability    ("NO")
	)
	sound_issp
	(
		// New fields go on the LSB side; see PLAN.md 14.3.
		.probe  ({snd_pc, snd_fifo_rd, snd_ymf_wr, snd_stall,
		          ymf_overrun, ymf_active, snd_f2_wr, snd_f2_rd,
		          snd_full_max, snd_fifo_peak, spr_gap_max, snd_wait_max,
		          stall_eip, stall_cs}),
		.source ()
	);

	altsource_probe
	#(
		.sld_auto_instance_index ("YES"),
		.sld_instance_index      (3),
		.instance_id             ("GDTS"),
		.probe_width             (192),
		.source_width            (1),
		.source_initial_value    ("0"),
		.enable_metastability    ("NO")
	)
	gdt_issp
	(
		.probe  (gdt),
		.source ()
	);

	// SDRAM occupancy: 5 x 19 transaction counts, ch1 in the low bits.
	// See rtl/spi_sdr_stats.sv.
	altsource_probe
	#(
		.sld_auto_instance_index ("YES"),
		.sld_instance_index      (6),
		.instance_id             ("SDRM"),
		.probe_width             (95),
		.source_width            (1),
		.source_initial_value    ("0"),
		.enable_metastability    ("NO")
	)
	sdram_issp
	(
		.probe  (sdr_trans),
		.source ()
	);

	// EIP profiler. Source is the inclusive window {hi, lo}; probe is the two
	// free-running 40-bit counters. Its own instance rather than more bits on
	// VITL because it needs a SOURCE, and VITL has none.
	//
	// source_initial_value 0 means the window is 0..0 until the host writes it,
	// so `prof_in` stays at zero rather than counting something arbitrary --
	// a reading of exactly 0 means "window never set", which is what you want
	// it to look like.
	altsource_probe
	#(
		.sld_auto_instance_index ("YES"),
		.sld_instance_index      (7),
		.instance_id             ("PROF"),
		.probe_width             (80),
		.source_width            (64),
		.source_initial_value    ("0"),
		.enable_metastability    ("YES")
	)
	prof_issp
	(
		.probe      ({prof_total, prof_in}),
		.source     ({prof_hi, prof_lo}),
		.source_clk (clk),
		.source_ena (1'b1)
	);

	altsource_probe
	#(
		.sld_auto_instance_index ("YES"),
		.sld_instance_index      (4),
		.instance_id             ("CTRL"),
		.probe_width             (8),
		.source_width            (8),
		.source_initial_value    ("0"),
		.enable_metastability    ("YES")
	)
	ctrl_issp
	(
		.probe      (ctrl),
		.source     (ctrl),
		.source_clk (clk),
		.source_ena (1'b1)
	);

	always @(posedge clk) begin
		if (reset) begin
			sdr_req <= 1'b0;
			ack     <= 1'b0;
			busy    <= 1'b0;
			go_d    <= 1'b0;
			data    <= 64'd0;
		end
		else begin
			go_d <= go;
			if (enable && !busy && (go != go_d)) begin
				sdr_addr <= {addr[25:3], 3'b000};
				sdr_req  <= ~sdr_req;
				busy     <= 1'b1;
			end
			else if (busy && (sdr_ack == sdr_req)) begin
				data <= sdr_dout;
				ack  <= go_d;
				busy <= 1'b0;
			end
		end
	end

endmodule
