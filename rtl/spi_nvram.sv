//============================================================================
//  SeibuSPI - the save file: the sample flash, then the DS2404's SRAM
//
//  The SPI cartridge programs its own sample flash on first boot, and without
//  somewhere to put the result it does that on EVERY boot: six minutes of
//  "NOW UPDATING" ending on a halt screen that wants a power cycle (PLAN.md
//  18.4). This is the save file that makes it happen once.
//
//  ONE FILE, TWO DEVICES, and 516 BYTES OF IT. An MRA has a single <nvram>
//  element with a single size, so everything the board remembers is concatenated:
//
//      0x000 .. 0x003   the sample flash's REGION STAMP, and nothing else of it
//      0x004 .. 0x203   the DS2404's 512 bytes of bookkeeping SRAM
//
//  Those four bytes are the whole of what the flash needs to remember. They are
//  what the game tests to decide the flash is already programmed, so they are the
//  flag that says whether its six-minute updater runs -- and the two megabytes
//  behind them are DERIVED at every boot in a third of a second, which makes
//  storing them pointless twice over. This used to save all 2 MB, and it cost a
//  visibly unresponsive OSD every time the menu was opened, because Main reads
//  the file back whenever it polls. PLAN.md 32.
//
//  It is a fake, deliberately: the flash is not persisted, only the fact that the
//  game once filled it. What the player sees is the same either way.
//
//  The stamp comes FIRST so that the tail is what moves when a set has no flash
//  at all: on SXX2E the samples are a real ROM, so its file is 512 bytes and the
//  SRAM sits at offset 0. `has_flash` says which layout this MRA declared, and it
//  is a property of the MRA and not of the OSD -- the size in the file has to be
//  fixed before the core knows which way Sample Flash is set.
//
//  The 512-byte tail is byte-for-byte MAME's own `ds2404` nvram file.
//
//  Both directions of MiSTer's arcade `<nvram>` mechanism, on index NV_INDEX:
//
//    LOAD  Main_MiSTer sends the file as an ordinary ioctl download at that
//          index, after the ROM image. The stamp goes to flash[0..3], over the
//          blank flash the MRA just loaded; the tail goes into the DS2404.
//
//          In Pre-built mode the stamp is SKIPPED, because the derivation writes
//          the real one and a restored copy could only be the same bytes or a
//          stale set. In Cart copy mode it is APPLIED, and it is the whole
//          mechanism: a restored stamp means the ritual has been done and the
//          game skips its updater, a blank one means it runs.
//
//    SAVE  the core raises ioctl_upload_req; Main sees it the next time it
//          polls (which is when the OSD is open -- menu.cpp's
//          MENU_GENERIC_MAIN2, not a background timer) and reads the region
//          back a byte at a time. There is no way to stall that side, so the
//          bytes have to be ready when asked for; see the prefetch below.
//
//  The two directions use different SDRAM ports for a reason. The load runs
//  while the core is held in reset and takes ch3's write path, the only one
//  sdram.sv gives. The save runs while the GAME is running, so it reads
//  through ch5 -- the YMF271's own sample channel, which is idle between
//  voice fetches and cannot deadlock against a channel the sound CPU needs.
//============================================================================

module spi_nvram
#(
	// How long the flash must be quiet before a save is asked for, as a power
	// of two clk_ram cycles: 24 is about 0.15 s. The testbench turns it down
	// rather than simulating fifty million cycles.
	parameter QUIET_BITS = 24,
	// The flash's share of the save file: its four-byte region stamp. A parameter
	// only so a testbench can widen it and check the crossing into the tail at
	// some other offset; the real layout is cheap enough to test as it stands.
	parameter int STAMP_BYTES = 4
)
(
	input             clk,          // clk_ram, with the arbiters
	input             reset,
	// The MRA declared an <nvram> element. Every set the core runs has a DS2404
	// to remember, so this is no longer the "authentic flash only" gate it was
	// -- what varies now is the SHAPE of the file, not whether there is one.
	input             enable,
	// This MRA's file carries the flash's stamp ahead of the DS2404's tail. An
	// MRA property, fixed before the OSD is reachable: on SXX2E the samples are a
	// ROM and the file is 512 bytes of SRAM and nothing else.
	input             has_flash,
	// ...and the stored stamp is the one to use, rather than the one the
	// derivation is about to write. True in Cart copy mode only.
	input             flash_live,

	// ---- ioctl, straight from hps_io (clk_sys; edge-detected here) --------
	//
	// NOT the ddr_rom_reader's `dl_*` copies. That module masks the index to 0
	// and drives the write strobe from its own DDR3 replay, so an ioctl that
	// arrives while the ROM image is still being replayed is DISCARDED -- and
	// the nvram arrives in exactly that window, because Main sends it the
	// moment its DMA of the image returns. The first attempt lost the whole
	// file that way, silently: `bytes_in` showed the image and nothing else.
	input             ioctl_download,
	input             ioctl_wr,
	input       [7:0] ioctl_index,
	input       [7:0] ioctl_dout,
	output reg        ioctl_wait,
	input             ioctl_upload,
	input             ioctl_rd,
	output      [7:0] ioctl_din,
	output reg        ioctl_upload_req,
	output      [7:0] ioctl_upload_index,

	// High while the ROM image is still landing (including the DDR3 replay,
	// which outlives the HPS's own download). The nvram must not touch ch3
	// then, so its bytes are held off with ioctl_wait until the image is done.
	input             rom_busy,

	// Toggles once per store into the sample flash, and once per store the game
	// makes into the DS2404's SRAM. Either is a reason to ask for a save.
	input             flash_dirty,
	input             sram_dirty,

	// ---- the DS2404's SRAM, the file's tail (spi_ds2404, same clock) -------
	// One address for both directions: a load and a save cannot overlap. The
	// read is registered, so `sram_dout` is a cycle behind `sram_addr` -- which
	// is thousands of times faster than the next byte the HPS asks for.
	output reg  [8:0] sram_addr,
	output reg  [7:0] sram_din,
	output reg        sram_we,
	input       [7:0] sram_dout,

	// ---- SDRAM ch3 write, while the core is in reset ----------------------
	output reg [25:0] wr_addr,
	output reg [15:0] wr_din,
	output reg  [1:0] wr_be,
	output reg        wr_req,
	input             wr_ack,
	// Holds ch3, and only while the flash half is actually being written: the
	// derivation writes the same channel, and in Pre-built mode the two would
	// otherwise overlap.
	output            wr_active,
	// Holds the CORE in reset for the WHOLE load, flash half or not, so the game
	// cannot read its bookkeeping before the save file has landed in the DS2404.
	output            hold,

	// ---- SDRAM ch5 read, while the game runs ------------------------------
	output reg [25:0] rd_addr,
	output reg        rd_req,
	input             rd_ack,
	input      [63:0] rd_dout,

	output reg [15:0] dbg_saves,
	// Beats of an upload actually served. 26 bits, not 16: a full save is
	// 2,097,152 of them, which is thirty-two exact wraps of a 16-bit counter
	// and reads back as ZERO -- identical to "the host never came", which is
	// the very thing this exists to distinguish. It said 0 beats about a
	// transfer that had just written a byte-perfect file. PLAN.md 13b's rule
	// about wrapping counters, earned again.
	output reg [25:0] dbg_beats,
	// Bytes of the save file received. Zero after a load means the file never
	// reached the core, which is a different fault from loading a wrong one.
	output     [25:0] dbg_bytes
);

`include "spi_defs.vh"

	// The MRA's <nvram index="..."> must match. 0 and 1 are the ROM image and
	// the config blob, 254 the DIP switches.
	localparam [7:0] NV_INDEX = 8'd2;
	// The two flash chips, then the DS2404's SRAM. `has_flash` chooses which of
	// the two shapes this MRA declared; the MRA's size= must match, and
	// tools/check_mra.py holds the two against each other.
	localparam [25:0] SRAM_BYTES = 26'h000_0200;
	wire [25:0] tail_base = has_flash ? STAMP_BYTES[25:0] : 26'd0;
	wire [25:0] nv_size   = tail_base + SRAM_BYTES;
	// The offset into the SRAM, on each side. These are SUBTRACTIONS and were
	// once the low nine bits of the counter, which worked only because both
	// tail bases used to be 512-aligned -- 0x200000 and 0. A four-byte stamp
	// ahead of the tail is not, and the shortcut silently rotated all 512 bytes
	// by four. `up_cnt + 1` because the save side reads one byte ahead.
	wire  [8:0] dl_tail = dl_off[8:0] - tail_base[8:0];
	wire  [8:0] up_tail = up_cnt[8:0] + 9'd1 - tail_base[8:0];

	assign ioctl_upload_index = NV_INDEX;

	// ------------------------------------------------------------------
	// EVERY ioctl signal crosses a clock boundary to get here, and this is where
	// that is dealt with. hps_io runs on clk_sys, this module on clk_ram, and the
	// two come off the same PLL -- so the analyser TIMES the transfer rather than
	// ignoring it, and a cold fit at the seed this design ships on failed HOLD by
	// 0.136 ns on `ioctl_upload` reaching the flop that used to sample it
	// directly. PLAN.md 37.
	//
	// THREE flops on the strobes, and the edge is detected between the second and
	// the third. Two would put the edge on s1, which is the stage that can be
	// metastable -- the whole point of the first flop is that its output is not
	// trusted. The DS2404's request crossing is built the same way for the same
	// reason (31.7), and this is the shape that was missing here.
	//
	// The edge is detected between synchronised stages rather than against the RAW
	// input, which is the bigger of the two faults in what this replaces:
	// `ioctl_wr && !ioctl_wr_d` fed a clk_sys net into clk_ram combinational logic.
	//
	// The strobes are one clk_sys cycle, which is two of these, so `s2 && !s3` is
	// true for exactly one clk_ram cycle per pulse -- the same one-rise-per-byte
	// the old form gave, two cycles later. Acting on the level would count every
	// byte twice, which is PLAN.md 10c's bug.
	//
	// LEVELS take s2, the first trustworthy stage. PAYLOADS take ONE flop,
	// deliberately shallower than the strobe's detection point, for the reason
	// 31.7 spells out: a payload synchronised as deeply as its strobe can still
	// hold the previous value when the strobe is seen, so shallower is what makes
	// it settled by then and deeper would be worse.
	// ------------------------------------------------------------------
	reg ioctl_wr_s1,     ioctl_wr_s2,     ioctl_wr_s3;
	reg ioctl_rd_s1,     ioctl_rd_s2,     ioctl_rd_s3;
	reg ioctl_upload_s1, ioctl_upload_s2, ioctl_upload_s3;
	reg ioctl_dl_s1,     ioctl_dl_s2;
	reg  [7:0] ioctl_dout_s, ioctl_index_s;

	wire ioctl_wr_rise = ioctl_wr_s2 && !ioctl_wr_s3;
	wire ioctl_rd_rise = ioctl_rd_s2 && !ioctl_rd_s3;
	wire upload_start  = ioctl_upload_s2 && !ioctl_upload_s3;
	wire upload_run    = ioctl_upload_s2;
	wire download_run  = ioctl_dl_s2;

	wire sel = enable && (ioctl_index_s == NV_INDEX);

	// ------------------------------------------------------------------
	// LOAD: one 8-bit write per byte, with ioctl_wait as backpressure.
	// ------------------------------------------------------------------
	reg [25:0] dl_off;
	reg        dl_run;
	assign hold      = dl_run;
	assign wr_active = dl_run & flash_live;
	// STICKY, and not `dl_off`: that one is cleared when the download ends, so
	// it reads zero from the moment there is anything to report. The first
	// version made exactly that mistake and reported "the save file never
	// arrived" about a load that had just worked.
	reg [25:0] dbg_got;
	assign dbg_bytes = dbg_got;

	// ------------------------------------------------------------------
	// SAVE: a byte counter and two lines of prefetch.
	//
	// hps_io samples ioctl_din on the same edge it advances its address, and
	// nothing can hold it off, so a line fetched only when the address crosses
	// into it would arrive late. Instead the NEXT line is fetched as soon as
	// the current one lands: at a crossing the answer is already here and the
	// fetch that follows has a whole line -- eight SPI byte times -- to
	// complete.
	// ------------------------------------------------------------------
	reg [25:0] up_cnt;      // byte index into the region
	reg        up_run;
	reg [63:0] cur, nxt;
	reg        nxt_valid;
	reg        fetching;
	reg        fetch_nxt;   // this fetch fills nxt rather than cur

	// The stamp comes out of the prefetched SDRAM line -- one line covers all
	// four bytes -- and the tail comes straight out of the DS2404. `sram_addr` is kept equal to up_cnt's low nine
	// bits, so `sram_dout` -- registered, one cycle behind -- is already the byte
	// the HPS will ask for next.
	wire in_tail = (up_cnt >= tail_base);
	assign ioctl_din = !up_run ? 8'd0
	                 : in_tail ? sram_dout
	                 :           cur[{up_cnt[2:0], 3'b000} +: 8];

	// ------------------------------------------------------------------
	// When to ask for a save.
	//
	// A pulse per settled burst of writes, not per write: the ritual programs
	// two million bytes and Main would otherwise be asked two million times.
	// The counter restarts on every store and asks once when the flash has
	// been quiet for about a tenth of a second at clk_ram.
	// ------------------------------------------------------------------
	reg        dirty_d, sdirty_d, dirty_seen;
	reg [QUIET_BITS-1:0] quiet;
	// `want_save` is the state; the request line is that state with a short gap
	// punched in it periodically, so hps_io gets a fresh RISING EDGE every so
	// often rather than one single edge that has to be caught. It latches on
	// the edge and clears the latch when Main polls, so an edge lost to
	// anything at all -- clock domains, a poll landing at the wrong moment --
	// would otherwise strand the save forever.
	reg        want_save;

	always @(posedge clk) begin
		ioctl_wr_s1     <= ioctl_wr;
		ioctl_wr_s2     <= ioctl_wr_s1;      ioctl_wr_s3     <= ioctl_wr_s2;
		ioctl_rd_s1     <= ioctl_rd;
		ioctl_rd_s2     <= ioctl_rd_s1;      ioctl_rd_s3     <= ioctl_rd_s2;
		ioctl_upload_s1 <= ioctl_upload;
		ioctl_upload_s2 <= ioctl_upload_s1;  ioctl_upload_s3 <= ioctl_upload_s2;
		ioctl_dl_s1     <= ioctl_download;   ioctl_dl_s2     <= ioctl_dl_s1;
		ioctl_dout_s    <= ioctl_dout;
		ioctl_index_s   <= ioctl_index;
		dirty_d        <= flash_dirty;
		sdirty_d       <= sram_dirty;
		sram_we        <= 1'b0;

		// ---- load ----------------------------------------------------
		if (wr_req == wr_ack) ioctl_wait <= 1'b0;

		if (sel && download_run) begin
			// Hold the HPS off until the ROM image has finished landing. It
			// waits mid-transfer, which is what ioctl_wait is for, and the
			// replay it is waiting on is bounded by the image size.
			if (rom_busy) ioctl_wait <= 1'b1;
			dl_run <= !rom_busy;
			if (!rom_busy && ioctl_wr_rise && (dl_off < nv_size)) begin
				if (dl_off < tail_base) begin
					// The stamp, through ch3. Dropped in Pre-built, where the
					// derivation writes the real one a moment later.
					if (flash_live) begin
						wr_addr    <= SDR_PCM_BASE + {dl_off[25:1], 1'b0};
						wr_din     <= {ioctl_dout_s, ioctl_dout_s};
						wr_be      <= dl_off[0] ? 2'b10 : 2'b01;
						wr_req     <= ~wr_req;
						ioctl_wait <= 1'b1;
					end
				end
				else begin
					sram_addr <= dl_tail;
					sram_din  <= ioctl_dout_s;
					sram_we   <= 1'b1;
				end
				dl_off     <= dl_off + 26'd1;
				dbg_got    <= dl_off + 26'd1;
			end
		end
		else begin
			dl_run <= 1'b0;
			dl_off <= 26'd0;
		end

		// ---- save ----------------------------------------------------
		// The index matters here as much as on the load side: hps_io's
		// ioctl_upload is global, so an upload Main starts for anything else
		// would otherwise be answered with sample-flash bytes. Seen as
		// `nvram save = 0 asks, 1 beats served` on ejanhs's first load -- one
		// stray beat, harmless because nothing was reading it, and wrong.
		if (upload_start && sel) begin
			up_run    <= 1'b1;
			up_cnt    <= 26'd0;
			sram_addr <= 9'd0;
			nxt_valid <= 1'b0;
			fetching  <= 1'b1;
			fetch_nxt <= 1'b0;
			rd_addr   <= SDR_PCM_BASE;
			rd_req    <= ~rd_req;
		end
		else if (!upload_run) up_run <= 1'b0;

		// EVERY re-arm toggles rd_req. Setting `fetching` without asking for
		// anything leaves ack == req, so the branch below fires again on the
		// next cycle and latches the PREVIOUS line's data as though it were the
		// next one -- which is how the first save file came back as line 0
		// repeated two million times.
		if (fetching && (rd_ack == rd_req)) begin
			fetching <= 1'b0;
			if (fetch_nxt) begin
				nxt       <= rd_dout;
				nxt_valid <= 1'b1;
			end
			else begin
				// The first line of the transfer. Chase it with the second so
				// the first crossing has something to swap in.
				cur       <= rd_dout;
				nxt_valid <= 1'b0;
				fetching  <= 1'b1;
				fetch_nxt <= 1'b1;
				rd_addr   <= SDR_PCM_BASE + {up_cnt[25:3], 3'b000} + 26'd8;
				rd_req    <= ~rd_req;
			end
		end

		// Every ioctl_rd advances the byte EXCEPT the one that arrives with the
		// 0xAA opening the transfer -- hps_io asserts ioctl_upload and that
		// first ioctl_rd on the same edge, so it is a request for byte 0 and
		// not an acknowledgement of one. Treating it as a byte sent byte 0
		// twice, which is what the first save file did. `up_run` is still low
		// in that cycle and would swallow it on its own; the explicit term is
		// there so a one-cycle skew between the two cannot resurrect the bug.
		if (up_run && ioctl_rd_rise && !upload_start) begin
			up_cnt    <= up_cnt + 26'd1;
			// Track it, so that the byte AFTER this one is already being read out
			// of the SRAM. Before the crossing it counts nonsense that nothing
			// looks at, and it reaches 0 exactly as up_cnt reaches tail_base.
			sram_addr <= up_tail;
			if (up_cnt[2:0] == 3'b111) begin
				// Crossing into the line that was prefetched.
				cur       <= nxt;
				nxt_valid <= 1'b0;
				if (!fetching) begin
					fetching  <= 1'b1;
					fetch_nxt <= 1'b1;
					rd_addr   <= SDR_PCM_BASE + {up_cnt[25:3], 3'b000} + 26'd16;
					rd_req    <= ~rd_req;
				end
			end
		end

		// ---- ask for a save ------------------------------------------
		// A LEVEL, raised when the flash settles and cleared when Main starts
		// the transfer. Not a one-cycle pulse -- this runs on clk_ram and
		// hps_io samples on clk_sys at half the rate.
		//
		// And deliberately NOT re-presented periodically. That was tried, to
		// guard against hps_io's edge latch being consumed without a transfer
		// following, and it turns one particular misconfiguration into an
		// unusable machine: an `-update` MRA with no <nvram> element (or with
		// DISABLE_NVRAM set) makes Main answer the poll, show "Saving...",
		// save nothing, and come straight back for more -- an OSD stuck in a
		// loop. A stranded request is a far better failure than that, and the
		// case it was guarding against never existed: the save that appeared
		// to be ignored was an MRA on the machine that predated the element.
		if (upload_start) want_save <= 1'b0;
		ioctl_upload_req <= want_save && !upload_start;

		if (up_run && ioctl_rd_rise) dbg_beats <= dbg_beats + 26'd1;

		if (enable) begin
			// Either device having moved is a reason to ask. The flash is only
			// worth saving when its stamp is the stored one -- in Pre-built mode
			// the derivation writes it at every boot and that is not news.
			if ((flash_live && (flash_dirty != dirty_d))
			    || (sram_dirty != sdirty_d)) begin
				dirty_seen <= 1'b1;
				quiet      <= '0;
			end
			else if (dirty_seen) begin
				if (&quiet) begin
					dirty_seen <= 1'b0;
					want_save  <= 1'b1;
					dbg_saves  <= dbg_saves + 16'd1;
				end
				else quiet <= quiet + 1'd1;
			end
		end

		if (reset) begin
			ioctl_wr_s1     <= 1'b0; ioctl_wr_s2     <= 1'b0; ioctl_wr_s3     <= 1'b0;
			ioctl_rd_s1     <= 1'b0; ioctl_rd_s2     <= 1'b0; ioctl_rd_s3     <= 1'b0;
			ioctl_upload_s1 <= 1'b0; ioctl_upload_s2 <= 1'b0; ioctl_upload_s3 <= 1'b0;
			ioctl_dl_s1     <= 1'b0; ioctl_dl_s2     <= 1'b0;
			ioctl_wait <= 1'b0;
			wr_req     <= 1'b0;
			wr_addr    <= 26'd0;
			wr_din     <= 16'd0;
			wr_be      <= 2'd0;
			dl_off     <= 26'd0;
			dbg_got    <= 26'd0;
			dl_run     <= 1'b0;
			rd_req     <= 1'b0;
			rd_addr    <= 26'd0;
			up_run     <= 1'b0;
			up_cnt     <= 26'd0;
			cur        <= 64'd0;
			nxt        <= 64'd0;
			nxt_valid  <= 1'b0;
			fetching   <= 1'b0;
			fetch_nxt  <= 1'b0;
			dirty_seen <= 1'b0;
			// dirty_d and sdirty_d are DELIBERATELY absent here, and adding them
			// back is the tidy-up to resist. They are the PREVIOUS VALUE of flags
			// their own modules keep ACROSS a reset on purpose (spi_ds2404.sv:510:
			// the 512 bytes nv_dirty tracks survive one). Forcing the copy to a
			// constant while the original holds is what manufactures an edge, and
			// it asked for one save per core load. PLAN.md 52.2. What they feed is
			// reset, which is the part that matters.
			quiet      <= '0;
			want_save  <= 1'b0;
			sram_addr  <= 9'd0;
			sram_din   <= 8'd0;
			sram_we    <= 1'b0;
			dbg_saves  <= 16'd0;
			dbg_beats  <= 26'd0;
		end
	end

	/* verilator lint_off UNUSEDSIGNAL */
	// nxt_valid is bookkeeping for the prefetch: a crossing that arrives
	// before its line has landed takes stale bytes, which the eight-byte lead
	// makes unreachable. Kept as a hook for a telemetry counter.
	wire _unused = &{1'b0, nxt_valid};
	/* verilator lint_on UNUSEDSIGNAL */

endmodule
