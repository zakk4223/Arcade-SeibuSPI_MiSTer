//============================================================================
//  SlopperPI - the sample flash as a MiSTer arcade NVRAM
//
//  The SPI cartridge programs its own sample flash on first boot, and without
//  somewhere to put the result it does that on EVERY boot: six minutes of
//  "NOW UPDATING" ending on a halt screen that wants a power cycle (PLAN.md
//  18.4). This is the save file that makes it happen once.
//
//  Both directions of MiSTer's arcade `<nvram>` mechanism, on index NV_INDEX:
//
//    LOAD  Main_MiSTer sends the file as an ordinary ioctl download at that
//          index, after the ROM image. Every byte goes straight into the
//          sample region, over the blank flash the MRA just loaded.
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
	parameter QUIET_BITS = 24
)
(
	input             clk,          // clk_ram, with the arbiters
	input             reset,
	// Only an authentic-flash MRA has anything worth saving. Everywhere else
	// the sample region is a ROM image and this stays inert.
	input             enable,

	// ---- ioctl, from hps_io (clk_sys; edge-detected here) -----------------
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

	// Toggles once per store into the sample flash.
	input             flash_dirty,

	// ---- SDRAM ch3 write, while the core is in reset ----------------------
	output reg [25:0] wr_addr,
	output reg [15:0] wr_din,
	output reg  [1:0] wr_be,
	output reg        wr_req,
	input             wr_ack,
	output            wr_active,    // holds ch3 and the core's reset

	// ---- SDRAM ch5 read, while the game runs ------------------------------
	output reg [25:0] rd_addr,
	output reg        rd_req,
	input             rd_ack,
	input      [63:0] rd_dout,

	output reg [15:0] dbg_saves
);

`include "spi_defs.vh"

	// The MRA's <nvram index="..."> must match. 0 and 1 are the ROM image and
	// the config blob, 254 the DIP switches.
	localparam [7:0] NV_INDEX = 8'd2;
	localparam [25:0] NV_SIZE = 26'h020_0000;   // the two flash chips

	assign ioctl_upload_index = NV_INDEX;

	// ------------------------------------------------------------------
	// ioctl edges. Both strobes are one clk_sys cycle and this runs on
	// clk_ram, so they are two cycles wide here -- acting on the level would
	// count every byte twice, which is PLAN.md 10c's bug exactly.
	// ------------------------------------------------------------------
	reg ioctl_wr_d, ioctl_rd_d, ioctl_upload_d;
	wire ioctl_wr_rise = ioctl_wr && !ioctl_wr_d;
	wire ioctl_rd_rise = ioctl_rd && !ioctl_rd_d;
	wire upload_start  = ioctl_upload && !ioctl_upload_d;

	wire sel = enable && (ioctl_index == NV_INDEX);

	// ------------------------------------------------------------------
	// LOAD: one 8-bit write per byte, with ioctl_wait as backpressure.
	// ------------------------------------------------------------------
	reg [25:0] dl_off;
	reg        dl_run;
	assign wr_active = dl_run;

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

	assign ioctl_din = up_run ? cur[{up_cnt[2:0], 3'b000} +: 8] : 8'd0;

	// ------------------------------------------------------------------
	// When to ask for a save.
	//
	// A pulse per settled burst of writes, not per write: the ritual programs
	// two million bytes and Main would otherwise be asked two million times.
	// The counter restarts on every store and asks once when the flash has
	// been quiet for about a tenth of a second at clk_ram.
	// ------------------------------------------------------------------
	reg        dirty_d, dirty_seen;
	reg [QUIET_BITS-1:0] quiet;

	always @(posedge clk) begin
		ioctl_wr_d     <= ioctl_wr;
		ioctl_rd_d     <= ioctl_rd;
		ioctl_upload_d <= ioctl_upload;
		dirty_d        <= flash_dirty;
		ioctl_upload_req <= 1'b0;

		// ---- load ----------------------------------------------------
		if (wr_req == wr_ack) ioctl_wait <= 1'b0;

		if (sel && ioctl_download) begin
			dl_run <= 1'b1;
			if (ioctl_wr_rise && (dl_off < NV_SIZE)) begin
				wr_addr    <= SDR_PCM_BASE + {dl_off[25:1], 1'b0};
				wr_din     <= {ioctl_dout, ioctl_dout};
				wr_be      <= dl_off[0] ? 2'b10 : 2'b01;
				wr_req     <= ~wr_req;
				ioctl_wait <= 1'b1;
				dl_off     <= dl_off + 26'd1;
			end
		end
		else begin
			dl_run <= 1'b0;
			dl_off <= 26'd0;
		end

		// ---- save ----------------------------------------------------
		if (upload_start && enable) begin
			up_run    <= 1'b1;
			up_cnt    <= 26'd0;
			nxt_valid <= 1'b0;
			fetching  <= 1'b1;
			fetch_nxt <= 1'b0;
			rd_addr   <= SDR_PCM_BASE;
			rd_req    <= ~rd_req;
		end
		else if (!ioctl_upload) up_run <= 1'b0;

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
			up_cnt <= up_cnt + 26'd1;
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
		if (enable) begin
			if (flash_dirty != dirty_d) begin
				dirty_seen <= 1'b1;
				quiet      <= '0;
			end
			else if (dirty_seen) begin
				if (&quiet) begin
					dirty_seen       <= 1'b0;
					ioctl_upload_req <= 1'b1;
					dbg_saves        <= dbg_saves + 16'd1;
				end
				else quiet <= quiet + 1'd1;
			end
		end

		if (reset) begin
			ioctl_wait <= 1'b0;
			wr_req     <= 1'b0;
			wr_addr    <= 26'd0;
			wr_din     <= 16'd0;
			wr_be      <= 2'd0;
			dl_off     <= 26'd0;
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
			quiet      <= '0;
			dbg_saves  <= 16'd0;
		end
	end

	/* verilator lint_off UNUSEDSIGNAL */
	// nxt_valid is bookkeeping for the prefetch: a crossing that arrives
	// before its line has landed takes stale bytes, which the eight-byte lead
	// makes unreachable. Kept as a hook for a telemetry counter.
	wire _unused = &{1'b0, nxt_valid};
	/* verilator lint_on UNUSEDSIGNAL */

endmodule
