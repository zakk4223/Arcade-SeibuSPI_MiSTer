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
	// The sample flash programming itself, on an authentic-flash MRA. `drops`
	// is the one to read first: it must be zero, and if it is not then bytes
	// went missing and the image is wrong in a way nothing else reports.
	input      [31:0] flash_progs,
	input      [15:0] flash_erases,
	input      [15:0] flash_drops,
	input       [1:0] flash_busy,
	// Bytes of the save file the core received. 0 after a load means the file
	// never arrived, which is a different fault from arriving wrong.
	input      [25:0] nv_bytes,
	// Did the core ASK for a save, and did the host ever answer? Zero beats
	// against non-zero asks is Main not coming; zero asks is the core's fault.
	input      [15:0] nv_saves,
	input      [25:0] nv_beats,

	// The watch (PLAN.md 19.11): one halfword of the sample flash, seen from
	// BOTH ends of the clk_sys -> clk_ram handoff. `fw_*` is what
	// spi_soundflash issued, `aw_*` is what spi_sdr_arb4 latched. They differ
	// only if the handoff is where the byte is being lost.
	input       [7:0] fw_progs,
	input       [1:0] fw_be,
	input       [7:0] fw_data,
	input       [7:0] fw_erases,
	input             fw_er_after,
	input      [55:0] fw_trace,
	input       [7:0] aw_n,
	input       [1:0] aw_be,
	input       [7:0] aw_data,
	input      [25:0] aw_total,

	// The sdram side of the same watch (PLAN.md 19.12), on its own instance
	// because SNDV is at 494 of the 511 bits altsource_probe allows.
	input       [7:0] sw_takes,
	input       [7:0] sw_writes,
	input       [7:0] sw_same,
	input       [1:0] sw_wbank,
	input             sw_wchip,
	input      [15:0] sw_e0_dq,
	input       [1:0] sw_e0_dqm,
	input       [3:0] sw_e0_gap,
	input       [1:0] sw_e0_ab,
	input             sw_e0_ac,
	input      [14:0] sw_e0_after,
	input      [15:0] sw_e1_dq,
	input       [1:0] sw_e1_dqm,
	input       [3:0] sw_e1_gap,
	input       [1:0] sw_e1_ab,
	input             sw_e1_ac,
	input      [14:0] sw_e1_after,

	// The FIFO watch (PLAN.md 19.14). On SDRW rather than SNDV only because
	// SNDV is full; these are clk_sys signals like the rest of the sound side.
	// The sel_pcm watch (PLAN.md 19.15). Its own instance: spi_cpu is on
	// clk_cpu, a third domain, and one instance per domain keeps a reading
	// from being half from each.
	input       [7:0] cw_hits,
	input      [63:0] cw_rom,
	input      [15:0] cw_pair,
	input      [25:0] cw_addr,
	input             cw_hit,

	input      [31:0] fw_pushes,
	input      [31:0] fw_pops,
	input       [8:0] fw_fill,
	input      [15:0] fw_empty,
	input       [7:0] fw_din,
	input             fw_frozen,

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
	input      [39:0] prof_total,

	// The sample-flash derivation (PLAN.md 24-26). Its own probe rather than
	// fields bolted onto SUMS: every offset in that one is hand-written in
	// tools/jtag_peek.tcl and widening it has silently shifted every field
	// after the change twice already (10d, 21.1). A new instance moves nothing.
	// 72 bits, trimmed from 136. The stamp and the live source address came out
	// again: the stamp is already held against build_soundflash by
	// `make check-mra`, and the source only mattered while the walk itself was
	// unproven. What is left is what says whether it RAN and how far it got.
	// The 136-bit version tipped sdram.sv's `ch1_rq -> command[1]` over on
	// clk_ram -- a path with none of this logic in it, which is what routing
	// pressure on a clock at 87% RAM utilisation looks like.
	input      [31:0] drv_cfg_job,
	input       [1:0] drv_cfg_gen,
	input             drv_en,
	input             drv_done,
	input             drv_overrun,
	input             drv_badjob,
	input       [7:0] drv_jobs,
	input      [21:0] drv_bytes,
	input       [3:0] drv_state
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
		.probe_width             (494),
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
		          stall_eip, stall_cs,
		          flash_progs, flash_erases, flash_drops, flash_busy,
		          nv_bytes, nv_saves, nv_beats,
		          fw_progs, fw_be, fw_data, fw_erases, fw_er_after, fw_trace,
		          aw_n, aw_be, aw_data, aw_total}),
		.source ()
	);

	// The sdram-side watch. A separate instance for room, and separate from
	// SNDV for a second reason: it is the only probe whose signals come from
	// clk_ram, and mixing two clocks into one instance would make a reading
	// that is half from each.
	altsource_probe
	#(
		.sld_auto_instance_index ("YES"),
		.sld_instance_index      (8),
		.instance_id             ("SDRW"),
		// 101, counted field by field. It was 71 first time out, which does
		// not fail or warn usefully -- the concatenation is simply truncated
		// and every field reads as part of its neighbour, which looked like
		// 255 writes to a halfword that gets three.
		.probe_width             (205),
		.source_width            (1),
		.source_initial_value    ("0"),
		.enable_metastability    ("NO")
	)
	sdrw_issp
	(
		.probe  ({sw_takes, sw_writes, sw_same, sw_wbank, sw_wchip,
		          sw_e0_dq, sw_e0_dqm, sw_e0_gap, sw_e0_ab, sw_e0_ac, sw_e0_after,
		          sw_e1_dq, sw_e1_dqm, sw_e1_gap, sw_e1_ab, sw_e1_ac, sw_e1_after,
		          fw_pushes, fw_pops, fw_fill, fw_empty, fw_din, fw_frozen}),
		.source ()
	);

	altsource_probe
	#(
		.sld_auto_instance_index ("YES"),
		.sld_instance_index      (9),
		.instance_id             ("CPUW"),
		.probe_width             (115),
		.source_width            (1),
		.source_initial_value    ("0"),
		.enable_metastability    ("NO")
	)
	cpuw_issp
	(
		.probe  ({cw_hits, cw_rom, cw_pair, cw_addr, cw_hit}),
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

	// 72 bits: cfg_job(32) cfg_gen(2) en done overrun badjob(4) jobs(8)
	// bytes(22) state(4).
	altsource_probe
	#(
		.sld_auto_instance_index ("YES"),
		.sld_instance_index      (3),
		.instance_id             ("DRIV"),
		.probe_width             (72),
		.source_width            (1),
		.source_initial_value    ("0"),
		.enable_metastability    ("NO")
	)
	drive_issp
	(
		.probe  ({drv_cfg_job, drv_cfg_gen,
		          drv_en, drv_done, drv_overrun, drv_badjob,
		          drv_jobs, drv_bytes, drv_state}),
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
