//============================================================================
//  SlopperPI - build the sample-flash image the way the game's updater does
//
//  The SXX2C cartridge ships a BLANK sample flash and the game programs it
//  itself at first boot, which takes about six minutes: 93% of that trace is
//  the 386 spinning on a Z80 round trip, one per byte, two million times
//  (PLAN.md 16.6). This does the same work from the same source material and
//  gets it wrong in none of the same ways, in well under a second, because it
//  reads SDRAM directly instead of through the 386/FIFO/Z80/wave-port chain.
//
//  It is NOT an emulation shortcut in the usual sense: every number it uses
//  comes out of the game's own program image. The job table, the source
//  addresses, the copy lengths, the fetch modes and the region stamp are all
//  read from the 386's ROM at run time, so a set this has never seen derives
//  correctly as long as the MRA says where its job table is. That is what makes
//  one MRA per set possible -- the alternative, an MRA that carries a finished
//  image, needs a new derived image and a new sha256 for every clone.
//
//  ---------------------------------------------------------------------------
//  THE JOB TABLE
//  ---------------------------------------------------------------------------
//  Twelve-byte records at `job_table`, walked until src reads 0xFFFFFFFF:
//
//      +0  u32  src      a 386 address: the program image, or the sound01
//                        window, which spi_snd_window unpacks
//      +4  u32  len      OUTPUT bytes this job contributes
//      +8  u8   mode     gen A: the fetcher's address STRIDE
//                        gen B: a lane selector, 0 = one byte per dword,
//                               1 = two, anything else = all four
//      +9  u8   verbatim gen B1 only: NONZERO copies, zero decompresses.
//                        That way round, not the other: it reads as a
//                        "decode" flag and is not one, and inverting it
//                        makes rdft2 produce the right NUMBER of bytes
//                        with the wrong contents -- a byte count that
//                        matches the reference is not a passing test.
//
//  Three generations differ only in how bytes 8 and 9 are read (PLAN.md and
//  tools/build_soundflash.py's GAMES table):
//
//      gen A   senkyu / batlball / ejanhs / viprp1   always decode, byte 8 is
//                                                    a stride, byte 9 padding
//      gen B0  rdft                                  always verbatim
//      gen B1  rdft2 / rfjet                         byte 9 picks per job
//
//  The region STAMP is four bytes read from the program image and written to
//  flash[0..3] LAST, exactly as the updater writes it -- it is what the game
//  tests to decide the flash is already good, so writing it before the payload
//  would let a reset in the middle look like a finished job.
//
//  ---------------------------------------------------------------------------
//  THE FETCHER
//  ---------------------------------------------------------------------------
//  Transcribed from the 386's own two fetchers (gen A senkyu 0x33C4B5, gen B
//  rdft2 0x2A1C34). Gen A takes the byte at esi and advances by a literal
//  stride. Gen B caches a dword and hands out some of its lanes, advancing so
//  that the lanes it skips are never seen. Both then apply the same 2 MB bank
//  skip the ROM_CONTINUE layout needs:
//
//      if (esi >= 0x400000 && (esi & 0x1FFFFF) == 0) esi += 0x200000;
//
//  and both address the 386's MAP, not a region offset, which is why a job may
//  name the program ROM instead of sound01 -- viprp1's second one does, and it
//  is the reason no MRA can assemble viprp1 a pre-flashed image at all.
//
//  ---------------------------------------------------------------------------
//  WHAT CHECKS THIS
//  ---------------------------------------------------------------------------
//  tools/check_flash_derive.py does the same walk in Python from the same SDRAM
//  image and reaches the reference sha256 on all seven sets. sim/tb_flash_derive
//  runs THIS against those images and must reach the same hashes. The decoder
//  itself is spi_rom_decode, already checked by sim/tb_rom_decode, and the
//  source window is spi_snd_window, checked over every dword by
//  sim/tb_snd_window.
//============================================================================

module spi_flash_derive
(
	input             clk,
	input             reset,

	// One pulse to start. Everything below must already be in SDRAM.
	input             start,

	// Per-set, and from the MRA rather than a table here: a clone has its own
	// job-table address (senkyu 0x00302324, batlball 0x00302290) because its
	// program differs, so baking these in would make every clone an RTL change.
	input      [31:0] job_table,      // 386 address
	input      [31:0] stamp_addr,     // 386 address of the four stamp bytes
	input       [1:0] gen,            // GEN_A / GEN_B0 / GEN_B1

	// Passed through to spi_snd_window: which windows are live and where the
	// PCM source landed for this set.
	input             snd01_en,
	input             pcmsrc_en,
	input             pcmsrc_1lane,
	input      [25:0] pcmsrc_base,

	// SDRAM read port (toggle handshake)
	output reg [25:0] sdr_addr,
	input      [63:0] sdr_dout,
	output reg        sdr_req,
	input             sdr_ack,

	// SDRAM write port (toggle handshake), into the sample region
	output reg [25:0] wr_addr,
	output reg [15:0] wr_din,
	output reg  [1:0] wr_be,
	output reg        wr_req,
	input             wr_ack,

	output reg        done,
	// Telemetry, and the first thing to look at when a set derives wrongly.
	output reg [21:0] bytes_out,      // payload written, stamp excluded
	output reg  [7:0] jobs_done,
	output reg        err_overrun,    // a job ran past the flash region
	// A job record that cannot be real. This exists because the job-table and
	// stamp addresses come from the MRA: a wrong constant walks nonsense, and
	// without a guard the walk never terminates and the core never leaves
	// reset. Failing fast leaves the flash blank, which is the safe outcome --
	// the stamp is written last, so the game simply runs its own updater.
	output reg        err_badjob,
	// Enough to say WHERE a set that derives wrongly went wrong, without a
	// waveform: which step, which source address, and the record it is acting
	// on. The panel will want these too.
	output      [3:0] dbg_state,
	output     [31:0] dbg_esi,
	output     [31:0] dbg_src,
	output     [31:0] dbg_len,
	output      [7:0] dbg_mode,
	output      [7:0] dbg_dec
);

`include "spi_defs.vh"

	// No PRG base constant: spi_snd_window's PRG arm masks to 2 MB itself, so
	// a program address needs no adjusting before it goes in.
	localparam [31:0] S01_386_BASE = 32'h00A0_0000;
	localparam [21:0] FLASH_SIZE   = 22'h20_0000;
	localparam [21:0] FLASH_START  = 22'd4;      // 0..3 is the stamp

	// ------------------------------------------------------------------
	// The source window. One instance serves all three sources: the program
	// image reads through the PRG arm, which masks to 2 MB exactly as the
	// 386's own two windows onto it do.
	// ------------------------------------------------------------------
	reg  [31:0] esi;
	wire [29:0] esi_dw = esi[31:2];

	wire        w_sel_s01, w_sel_pcm;
	wire [25:0] w_grp_addr;
	wire  [7:0] w_byte;
	wire [15:0] w_pair;
	wire [31:0] w_prg;

	reg  [63:0] grp_data;
	wire        in_s01 = esi >= S01_386_BASE;
	wire  [1:0] w_src  = !in_s01   ? SNDW_PRG
	                   : w_sel_s01 ? SNDW_S01
	                               : SNDW_PCM;

	spi_snd_window window
	(
		.sel_dw       (esi_dw),
		.snd01_en     (snd01_en),
		.pcmsrc_en    (pcmsrc_en),
		.sel_s01      (w_sel_s01),
		.sel_pcm      (w_sel_pcm),

		.cur_dw       (esi_dw),
		.src          (w_src),
		.pcmsrc_1lane (pcmsrc_1lane),
		.pcmsrc_base  (pcmsrc_base),
		.grp_data     (grp_data),

		.grp_addr     (w_grp_addr),
		.byte_out     (w_byte),
		.pair_out     (w_pair),
		.prg_out      (w_prg),
		.grp_last     ()
	);

	// The 386 dword at esi, formed exactly as spi_cpu forms mem_din: a window
	// that claims nothing answers 0, which is what MAME's ERASE00 region holds
	// and what the fetcher must see there.
	wire [31:0] src_dword = !in_s01                  ? w_prg
	                      : w_sel_s01                ? {24'd0, w_byte}
	                      : (w_sel_pcm & pcmsrc_1lane) ? {24'd0, w_byte}
	                      : w_sel_pcm                ? {16'd0, w_pair}
	                                                 : 32'd0;

	// ------------------------------------------------------------------
	// The decoder. Verbatim jobs go through it too, as CODEC_RAW, so there is
	// one datapath and no second write path to keep in step.
	// ------------------------------------------------------------------
	reg        dec_start;
	reg  [3:0] dec_codec;
	wire       in_ready;
	wire       out_valid;
	wire [7:0] out_data;

	// ------------------------------------------------------------------
	// Walk state
	//
	// One thread. The decoder can want many input bytes before emitting any
	// (it is reading a pair table) and can emit many from one (it is expanding
	// through it), so both sides are serviced opportunistically from S_RUN and
	// neither may be allowed to block the other. Draining output wins, because
	// that is the progress that ends the job.
	// ------------------------------------------------------------------
	localparam [3:0] S_IDLE   = 4'd0,
	                 S_J0     = 4'd1,
	                 S_JOBB   = 4'd2,
	                 S_JOBD   = 4'd3,
	                 S_BEGIN  = 4'd4,
	                 S_RUN    = 4'd5,
	                 S_NEXT   = 4'd6,
	                 S_STAMPB = 4'd7,
	                 S_RD_REQ = 4'd8,
	                 S_RD_ACK = 4'd9,
	                 S_WR_REQ = 4'd10,
	                 S_WR_ACK = 4'd11,
	                 S_DONE   = 4'd12;
	// Separate return registers for the two sub-sequences: the stamp path needs
	// a read and a write outstanding in the same step, and one shared `ret`
	// would have the write clobber the read's.
	reg  [3:0] state, ret_r, ret_w;

	reg [31:0] job;
	reg [31:0] j_src, j_len;
	reg  [7:0] j_mode, j_dec;
	reg [31:0] produced;
	reg [21:0] pos;
	reg  [7:0] wbyte;
	reg        stamping;

	reg [25:0] grp_held;
	reg        have_grp;
	reg  [7:0] fbyte;
	reg        have_byte;

	// Job records are read a BYTE at a time, not as dwords, because three of
	// the seven job tables are not dword aligned -- rdft 0x0020174D, rdft2
	// 0x00201B55, rfjet 0x00203597. The 386 reads them unaligned and so does
	// tools/build_soundflash.py; truncating to the containing dword reads the
	// table one to three bytes early, which is a garbage `len` and a job that
	// copies until it runs off the end of the flash region. That is exactly
	// what the first version of this module did.
	reg  [1:0] jw;        // which dword of the record: 0 src, 1 len, 2 mode
	reg  [1:0] jb;        // which byte within it
	reg [31:0] jacc;
	reg  [2:0] stamp_i;

	// The byte at esi. Universal across both generations and every lane mode:
	// gen A reads it explicitly, and gen B's dword cache -- load at esi%4==0,
	// shift once per byte -- hands out exactly the same byte, because the modes
	// only ever advance esi through lanes it has not yet handed out. Modelling
	// the cache would be a second thing to keep in step with the 386.
	//
	// It is also correct for an UNALIGNED address, which is what the job-record
	// reader above depends on: the window's PRG arm returns the dword holding
	// esi and this picks the byte out of it.
	wire [7:0] src_byte = src_dword[{esi[1:0], 3'b000} +: 8];

	// gen B lane advance, from the 386: take the byte, step one, then skip the
	// lanes this mode does not use. The mode-1 test is against the ALREADY
	// STEPPED address, which is why it reads as "even" here rather than "odd".
	wire [31:0] esi_p1     = esi + 32'd1;
	wire [31:0] esi_next_b = (j_mode == 8'd0)                      ? esi + 32'd4
	                       : (j_mode == 8'd1 && esi_p1[0] == 1'b0) ? esi + 32'd3
	                                                              : esi_p1;
	wire [31:0] esi_next_a = esi + {24'd0, j_mode};
	wire [31:0] esi_step   = (gen == GEN_A) ? esi_next_a : esi_next_b;
	// The 2 MB bank skip the ROM_CONTINUE layout needs, applied to whichever
	// step was taken. Both of the 386's fetchers do this and so does
	// build_soundflash's bank(), which is how the two sides agree without
	// special-casing either.
	wire [31:0] esi_next = (esi_step >= 32'h0040_0000 &&
	                        esi_step[20:0] == 21'd0) ? esi_step + 32'h0020_0000
	                                                 : esi_step;

	// This job's disposition, computed rather than latched so `dec_codec` is
	// stable in the cycle `dec_start` samples it.
	// Byte 9 is a VERBATIM flag, not a decode flag: build_soundflash's
	// `verbatim = bool(prg[job+9])`. Inverted, rfjet feeds sample data to the
	// BPE expander and hangs, and rdft2 swaps its two jobs' codecs and produces
	// exactly the right byte count out of the wrong bytes.
	wire vb = (gen == GEN_B0) ? 1'b1
	        : (gen == GEN_A)  ? 1'b0
	                          : (j_dec != 8'd0);

	// Held rather than pulsed, and combinational: a registered pulse would
	// assert a cycle after the ready that provoked it, and the byte would be
	// dropped. in_valid stays up through the write states too, which keeps the
	// decoder fed while a byte is on its way to SDRAM.
	wire       in_valid  = have_byte;
	wire [7:0] in_data   = fbyte;
	// Ready throughout S_RUN, so the cycle the decoder raises out_valid is the
	// cycle the transfer happens and S_RUN leaves to write it.
	wire       out_ready = (state == S_RUN);

	spi_rom_decode decoder
	(
		.clk       (clk),
		.reset     (reset),
		.codec     (dec_codec),
		.start     (dec_start),
		.in_valid  (in_valid),
		.in_data   (in_data),
		.in_ready  (in_ready),
		.out_valid (out_valid),
		.out_data  (out_data),
		.out_ready (out_ready),
		.idle      ()
	);

	// The source group we hold, if any. Cached by the SDRAM group ADDRESS, not
	// by a range of esi: how many 386 dwords one 64-bit group covers depends on
	// the window -- eight for sound1, four for a two-lane PCM source, two for
	// the program -- so only the address the window computed is safe to compare.
	wire cache_hit = have_grp && (grp_held == w_grp_addr);

	assign dbg_state = state;
	assign dbg_esi   = esi;
	assign dbg_src   = j_src;
	assign dbg_len   = j_len;
	assign dbg_mode  = j_mode;
	assign dbg_dec   = j_dec;

	always @(posedge clk) begin
		dec_start <= 1'b0;

		if (reset) begin
			state       <= S_IDLE;
			done        <= 1'b0;
			sdr_req     <= 1'b0;
			wr_req      <= 1'b0;
			bytes_out   <= 22'd0;
			jobs_done   <= 8'd0;
			err_overrun <= 1'b0;
			err_badjob  <= 1'b0;
			have_grp    <= 1'b0;
			have_byte   <= 1'b0;
			stamping    <= 1'b0;
		end
		else begin
			// The decoder's input handshake, independent of the walk state.
			if (in_valid && in_ready) have_byte <= 1'b0;

			case (state)

			S_IDLE: if (start) begin
				job         <= job_table;
				esi         <= job_table;
				pos         <= FLASH_START;
				bytes_out   <= 22'd0;
				jobs_done   <= 8'd0;
				err_overrun <= 1'b0;
				err_badjob  <= 1'b0;
				done        <= 1'b0;
				have_grp    <= 1'b0;
				have_byte   <= 1'b0;
				stamping    <= 1'b0;
				jw          <= 2'd0;
				jb          <= 2'd0;
				state       <= S_JOBB;
			end

			S_J0: begin
				esi   <= job;
				jw    <= 2'd0;
				jb    <= 2'd0;
				state <= S_JOBB;
			end

			// ---- one job record, twelve bytes, little endian --------------
			S_JOBB: if (cache_hit) begin
				jacc  <= {src_byte, jacc[31:8]};
				esi   <= esi + 32'd1;
				jb    <= jb + 2'd1;
				if (jb == 2'd3) state <= S_JOBD;
			end
			else begin
				ret_r <= S_JOBB;
				state <= S_RD_REQ;
			end

			S_JOBD: case (jw)
				2'd0: begin j_src <= jacc; jw <= 2'd1; state <= S_JOBB; end
				2'd1: begin j_len <= jacc; jw <= 2'd2; state <= S_JOBB; end
				default: begin
					j_mode <= jacc[7:0];
					j_dec  <= jacc[15:8];
					// 0xFFFFFFFF ends the table. The stamp is written LAST, so
					// a reset part-way through never leaves a flash that the
					// game would mistake for a finished one.
					if (j_src == 32'hFFFF_FFFF) begin
						esi      <= stamp_addr;
						stamping <= 1'b1;
						pos      <= 22'd0;
						stamp_i  <= 3'd0;
						state    <= S_STAMPB;
					end
					// A source outside the 386's program image or its sound01
					// region is not a job, and neither is a table longer than
					// any real one -- the seven known sets all have two. Both
					// mean the job-table address was wrong.
					else if (j_src < 32'h0020_0000 ||
					         j_src >= 32'h0140_0000 ||
					         jobs_done >= 8'd16) begin
						err_badjob <= 1'b1;
						state      <= S_DONE;
					end
					else state <= S_BEGIN;
				end
			endcase

			S_BEGIN: begin
				dec_codec <= vb ? CODEC_RAW : CODEC_BPE_DPCM;
				dec_start <= 1'b1;
				esi       <= j_src;
				produced  <= 32'd0;
				have_byte <= 1'b0;
				state     <= S_RUN;
			end

			// ---- the pump -------------------------------------------------
			// Draining output wins over feeding input: that is the progress
			// that ends the job. The decoder can want many bytes before
			// emitting any (reading its pair table) and emit many from one
			// (expanding through it), so neither side may block the other.
			S_RUN: begin
				if (produced == j_len)      state <= S_NEXT;
				else if (pos >= FLASH_SIZE) begin
					err_overrun <= 1'b1;
					state       <= S_DONE;
				end
				else if (out_valid) begin
					wbyte    <= out_data;
					produced <= produced + 32'd1;
					ret_w    <= S_RUN;
					state    <= S_WR_REQ;
				end
				else if (!have_byte) begin
					if (cache_hit) begin
						fbyte     <= src_byte;
						have_byte <= 1'b1;
						esi       <= esi_next;
					end
					else begin
						ret_r <= S_RUN;
						state <= S_RD_REQ;
					end
				end
			end

			S_NEXT: begin
				jobs_done <= jobs_done + 8'd1;
				job       <= job + 32'd12;
				state     <= S_J0;
			end

			// ---- the region stamp, four bytes, written last ---------------
			S_STAMPB: if (stamp_i == 3'd4) begin
				done  <= 1'b1;
				state <= S_DONE;
			end
			else if (cache_hit) begin
				wbyte   <= src_byte;
				esi     <= esi + 32'd1;
				stamp_i <= stamp_i + 3'd1;
				ret_w   <= S_STAMPB;
				state   <= S_WR_REQ;
			end
			else begin
				ret_r <= S_STAMPB;
				state <= S_RD_REQ;
			end

			// ---- shared SDRAM sub-sequences -------------------------------
			S_RD_REQ: begin
				sdr_addr <= w_grp_addr;
				grp_held <= w_grp_addr;
				sdr_req  <= ~sdr_req;
				state    <= S_RD_ACK;
			end

			S_RD_ACK: if (sdr_ack == sdr_req) begin
				grp_data <= sdr_dout;
				have_grp <= 1'b1;
				state    <= ret_r;
			end

			S_WR_REQ: begin
				wr_addr <= SDR_PCM_BASE + {4'd0, pos[21:1], 1'b0};
				wr_din  <= {wbyte, wbyte};
				wr_be   <= pos[0] ? 2'b10 : 2'b01;
				wr_req  <= ~wr_req;
				state   <= S_WR_ACK;
			end

			S_WR_ACK: if (wr_ack == wr_req) begin
				pos <= pos + 22'd1;
				if (!stamping) bytes_out <= bytes_out + 22'd1;
				state <= ret_w;
			end

			default: state <= S_DONE;

			endcase
		end
	end

endmodule
