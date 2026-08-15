//============================================================================
//  SlopperPI - the SPI cartridge's YMF271 sample flash
//
//  Two Intel E28F008SA, 1 MB each, sitting where SXX2E has a mask ROM. They ARE
//  the YMF271's sample memory: chip 0 answers 0x000000-0x0FFFFF of the chip's
//  external address space and chip 1 0x100000-0x1FFFFF, so addr[20] is the chip
//  select and the pair is one linear 2 MB space to everything else.
//
//  The game programs them itself on first boot -- the several-minute "techno
//  music" ritual -- through the YMF271's own wave-memory port: utility register
//  0x16 d7 is the direction bit, 0x17 pre-increments the address and writes a
//  byte, and reads come back at bus offset 2. The Z80 drives that port; the
//  data crosses from the 386 over the sound FIFO. PLAN.md section 0 has the
//  command trace this module is written against and section 17 the plan.
//
//  COMMANDS, from that trace plus MAME's intelfsh:
//
//    FF          Read Array          reads return sample memory
//    70          Read Status         reads return the status register
//    50          Clear Status        error bits cleared, stays in status mode
//    90          Read Identifier     0x89 / 0xA2 at even / odd addresses
//    20 then D0  Block Erase         64 KB block, addr picks it
//    40 or 10    Byte Program setup, next write is the datum
//
//  ERASE IS A SWEEP, and that is the whole timing model. A block erase writes
//  0xFFFF over 32,768 halfwords through the SDRAM port and reports BUSY in the
//  status register until the last one retires, so the updater throttles itself
//  against the memory system instead of against a delay this file would
//  otherwise have to invent. Byte programming costs one write, and like MAME's
//  intelfsh we charge no program time: the ritual then takes as long as the
//  386/FIFO/Z80 round trip makes it, which is tens of seconds rather than the
//  minutes real flash needs (PLAN.md 16.6).
//
//  WHAT IS DELIBERATELY NOT MODELLED. Programming can only clear bits on real
//  flash, so a program into an unerased byte gives the AND of the two; here it
//  is a plain store. The updater erases everything first and MAME does the same
//  thing, so nothing observable depends on it. Erase-suspend (B0/D0) is not
//  implemented either: it is for a host that wants to read one chip while the
//  other erases, and this updater polls instead.
//
//  The chip's own voices read sample memory through ymf271_synth's fetch path,
//  which does NOT come through here -- a voice reading a chip that is in status
//  mode gets array data rather than the status byte. Real hardware would return
//  status. It cannot matter: the only time a chip is out of array mode is while
//  its contents are being destroyed and rewritten.
//============================================================================

module spi_soundflash
(
	input             clk,          // clk_sys
	input             reset,
	// 0 on SXX2E and on a pre-flashed cartridge: sample memory is read-only
	// there, so commands are ignored and reads always see the array.
	input             enable,

	// The wave-memory port's write side. `wr` is one clk_sys pulse and `addr`
	// is the POST-increment address -- the register runs one behind, which is
	// why the updater opens a session at 0x7FFFFF.
	input             wr,
	input      [20:0] addr,
	input       [7:0] din,

	// Read steering, off the SAME address -- the chip has one address register
	// and a read is steered by whatever it currently holds. When the addressed
	// chip is answering with something other than its array, `rd_ovr` says so
	// and `rd_data` is the byte.
	output            rd_ovr,
	output      [7:0] rd_data,

	// SDRAM write port -- ch3, through spi_sdr_arb4's `d`.
	output reg [25:0] sdr_addr,
	output reg [15:0] sdr_din,
	output reg  [1:0] sdr_be,
	output reg        sdr_req,
	input             sdr_ack,

	// Toggles once per store that changed sample memory. ymf271_synth uses it
	// to retire its cached sample lines; a toggle rather than a pulse so the
	// consumer can act on it at a point of its own choosing.
	output reg        dirty,

	// Telemetry: bytes programmed, blocks erased, commands dropped, and which
	// chips are busy. `dbg_drops` should stay at zero -- see the command port.
	output reg [31:0] dbg_progs,
	output reg [15:0] dbg_erases,
	output reg [15:0] dbg_drops,
	output      [1:0] dbg_busy
);

`include "spi_defs.vh"

	// Command modes, per chip.
	localparam [2:0] M_ARRAY  = 3'd0;   // reads return sample memory
	localparam [2:0] M_STATUS = 3'd1;   // reads return the status register
	localparam [2:0] M_ID     = 3'd2;   // reads return the identifier bytes
	localparam [2:0] M_PROG   = 3'd3;   // the next write is the datum
	localparam [2:0] M_ERASE  = 3'd4;   // the next write must be the D0 confirm

	reg [2:0] mode [0:1];
	// Status register. Only WSMS (bit 7, 1 = ready) is ever driven by anything
	// here; the error bits exist because the updater clears them with 50 and
	// would notice their absence if a read of the register came back 0x00.
	reg [7:0] status [0:1];

	// The erase sweep. One at a time: two chips erasing at once would need two
	// write ports, and the updater walks them in lockstep anyway -- it erases a
	// block, polls it, and only then moves on.
	reg        er_run;
	reg        er_chip;
	reg  [3:0] er_block;
	reg [14:0] er_word;      // 32,768 halfwords = one 64 KB block

	// One outstanding SDRAM write, from either source.
	reg        wr_pend;

	wire       sel      = addr[20];
	wire       busy     = er_run || wr_pend;
	// A chip is busy only while ITS own operation is outstanding.
	assign dbg_busy = {(er_run &&  er_chip) || (wr_pend &&  sel),
	                   (er_run && ~er_chip) || (wr_pend && ~sel)};

	// The identifier: manufacturer 0x89 (Intel), device 0xA2 (28F008SA). Bit 0
	// of the address picks between them, which is what a x8 part does.
	wire [7:0] id_byte = addr[0] ? 8'hA2 : 8'h89;

	// Reads. In array mode the wave-memory path fetches from SDRAM as usual;
	// anything else is answered here. The busy bit is computed live rather than
	// stored, so a poll during an erase sweep sees it clear the moment the
	// sweep's last write retires.
	wire [7:0] status_live = {~(dbg_busy[sel]), status[sel][6:0]};
	assign rd_ovr  = enable && (mode[sel] != M_ARRAY);
	assign rd_data = (mode[sel] == M_ID) ? id_byte : status_live;

	// The sweep's current halfword, and the byte being programmed. Both address
	// the sample region, which is where the YMF271 reads its samples from --
	// this IS that memory, not a copy of it.
	wire [20:0] er_addr = {er_chip, er_block, er_word, 1'b0};

	integer k;
	always @(posedge clk) begin
		// ---- the SDRAM write port ------------------------------------
		if (wr_pend && (sdr_ack == sdr_req)) begin
			wr_pend <= 1'b0;
			dirty   <= ~dirty;
		end

		// ---- the erase sweep -----------------------------------------
		// Runs whenever the port is free. It cannot collide with a program
		// write: the updater is blocked polling status until the sweep ends,
		// and a command arriving mid-sweep is handled below by letting the
		// sweep finish first.
		if (er_run && !wr_pend) begin
			sdr_addr <= SDR_PCM_BASE + {5'd0, er_addr};
			sdr_din  <= 16'hFFFF;
			sdr_be   <= 2'b11;
			sdr_req  <= ~sdr_req;
			wr_pend  <= 1'b1;
			if (&er_word) begin
				er_run          <= 1'b0;
				status[er_chip] <= 8'h80;
				dbg_erases      <= dbg_erases + 16'd1;
			end
			er_word <= er_word + 15'd1;
		end

		// ---- the command port ----------------------------------------
		// A write while the port is busy is dropped rather than queued, and
		// COUNTED, because a dropped byte is a silently wrong flash image. The
		// updater should never produce one: it polls WSMS before every command,
		// which is the protocol the part documents and the trace shows it
		// following, and a byte program retires in a fraction of the ~88 cycles
		// a Z80 `out` takes. If dbg_drops is ever non-zero on hardware, that
		// assumption is wrong and this needs a real handshake.
		if (wr && enable && busy) dbg_drops <= dbg_drops + 16'd1;

		if (wr && enable && !busy) begin
			case (mode[sel])

			M_PROG: begin
				sdr_addr <= SDR_PCM_BASE + {5'd0, addr[20:1], 1'b0};
				sdr_din  <= {din, din};
				sdr_be   <= addr[0] ? 2'b10 : 2'b01;
				sdr_req  <= ~sdr_req;
				wr_pend  <= 1'b1;
				mode[sel]   <= M_STATUS;
				status[sel] <= 8'h80;
				dbg_progs   <= dbg_progs + 32'd1;
			end

			M_ERASE:
				// D0 confirms; anything else is an aborted command sequence,
				// which the part reports rather than acting on.
				if (din == 8'hD0) begin
					er_run   <= 1'b1;
					er_chip  <= sel;
					er_block <= addr[19:16];
					er_word  <= 15'd0;
					mode[sel]   <= M_STATUS;
					status[sel] <= 8'h80;
				end
				else begin
					mode[sel]   <= M_STATUS;
					status[sel] <= 8'h90;   // command sequence error
				end

			default:
				case (din)
					8'hFF, 8'h00: mode[sel] <= M_ARRAY;
					8'h70:        mode[sel] <= M_STATUS;
					8'h90:        mode[sel] <= M_ID;
					8'h10, 8'h40: mode[sel] <= M_PROG;
					8'h20:        mode[sel] <= M_ERASE;
					8'h50: begin
						mode[sel]   <= M_STATUS;
						status[sel] <= 8'h80;
					end
					default: mode[sel] <= M_STATUS;
				endcase

			endcase
		end

		if (reset) begin
			sdr_req    <= 1'b0;
			sdr_addr   <= 26'd0;
			sdr_din    <= 16'd0;
			sdr_be     <= 2'd0;
			wr_pend    <= 1'b0;
			er_run     <= 1'b0;
			er_chip    <= 1'b0;
			er_block   <= 4'd0;
			er_word    <= 15'd0;
			dirty      <= 1'b0;
			dbg_progs  <= 32'd0;
			dbg_erases <= 16'd0;
			dbg_drops  <= 16'd0;
			for (k = 0; k < 2; k = k + 1) begin
				mode[k]   <= M_ARRAY;
				status[k] <= 8'h80;
			end
		end
	end

endmodule
