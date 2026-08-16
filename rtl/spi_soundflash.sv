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
//  BOTH CHIPS ERASE AT ONCE, and nothing polls in between. This module's first
//  version assumed the opposite -- one erase engine, commands dropped while
//  busy -- and it stalled on hardware after a single block with two dropped
//  commands. The updater's actual sequence, logged out of MAME by
//  tools/mame_flash_port.lua (PLAN.md 17.14):
//
//    W 17 = 20  addr=000000     erase setup, chip 0
//    W 17 = D0  addr=000001     confirm, chip 0 starts
//    W 17 = 20  addr=100000     erase setup, chip 1, immediately after
//    W 17 = D0  addr=100001     confirm, chip 1 starts too
//    R 02 -> 00 addr=000000     then it polls chip 0
//    R 02 -> 00 addr=100000     ...and chip 1, until BOTH report ready
//
//  and the programming phase polls NOTHING: 40, datum, 40, datum, back to back
//  as fast as the Z80 can drive the port. So both chips need their own sweep,
//  and a command must never be refused. The two sweeps share the one SDRAM
//  write port by alternating, which is also what makes their busy windows the
//  same length -- the updater waits for the later of the two either way.
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
	output      [1:0] dbg_busy,

	// ---- the watch (PLAN.md 19.11) ------------------------------------
	// rdft2's flash comes out with byte 0x29FE erased where MAME holds 0xFE:
	// one byte in two megabytes, reproducibly, on two builds. Everything the
	// counters above can see says the write happened -- `dbg_progs` counts at
	// ISSUE and matches MAME's command total exactly, `dbg_drops` is zero --
	// and replaying the updater's real writes through this module reproduces
	// MAME byte for byte. So the question is no longer whether a write was
	// issued but WHAT was issued, and whether the other end got it.
	//
	// These watch one halfword. `w_progs` counts program writes issued to it,
	// `w_be`/`w_data` hold the last one's byte-enable and datum: a write that
	// lands one byte high is the SAME halfword with the other lane, so a wrong
	// `w_be` is the whole hypothesis in one field. `w_erases` and
	// `w_er_after` cover the sweep -- an erase of that halfword AFTER it was
	// programmed would put the erased value back.
	//
	// `w_trace` is the four program writes from WATCH_TRIG onwards, as
	// {addr[11:0], be} each, oldest first: if the byte was issued somewhere
	// else entirely, the neighbours say where.
	output reg  [7:0] dbg_w_progs,
	output reg  [1:0] dbg_w_be,
	output reg  [7:0] dbg_w_data,
	output reg  [7:0] dbg_w_erases,
	output reg        dbg_w_er_after,
	output reg [55:0] dbg_w_trace
);

// Byte addresses within the 2 MB sample region. WATCH is the byte in question;
// the compare is on its halfword, since that is what a write addresses.
// WATCH_TRIG is two bytes below, so the trace starts one write early.
parameter [20:0] WATCH      = 21'h029FE;
parameter [20:0] WATCH_TRIG = 21'h029FC;

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

	// One erase sweep PER CHIP, because the updater runs both at once. They
	// share the single SDRAM write port by alternating, `er_turn` picking who
	// goes next; a program write jumps ahead of both.
	//
	// A QUEUE, not a single block: the updater sends all sixteen block-erase
	// pairs of a chip back to back without waiting, because MAME's intelfsh
	// erases instantly and only its STATUS is slow (a 1-second timer). One
	// pending block per chip would let each new pair restart the sweep and
	// only the last block would ever finish. Sixteen blocks, sixteen bits.
	reg [15:0] er_q     [0:1];    // blocks still to erase, bit per block
	reg  [1:0] er_run;
	reg  [3:0] er_block [0:1];
	reg [14:0] er_word  [0:1];    // 32,768 halfwords = one 64 KB block
	reg        er_turn;

	// A byte program waiting for the port. One slot per chip: the updater
	// programs back to back with no poll between bytes, so the slot has to be
	// free again within one Z80 `out` (~88 clk_sys) -- an SDRAM write retires
	// in a fraction of that. If a second byte ever arrives on a full slot it is
	// counted in dbg_drops rather than lost quietly.
	reg  [1:0] pg_pend;
	reg [18:0] pg_addr [0:1];     // halfword address within the chip
	reg        pg_lane [0:1];
	reg  [7:0] pg_data [0:1];

	// One outstanding SDRAM write, and which chip it belongs to.
	reg        wr_pend;
	reg        wr_chip;

	wire       sel = addr[20];
	// A chip is busy while its sweep is running, its program slot is full, or
	// its write is in flight. NOTHING is refused because a chip is busy -- see
	// the command port.
	assign dbg_busy = {er_run[1] | (|er_q[1]) | pg_pend[1] | (wr_pend &  wr_chip),
	                   er_run[0] | (|er_q[0]) | pg_pend[0] | (wr_pend & ~wr_chip)};

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

	// Whose turn it is, and the halfword that turn writes. Both address the
	// sample region, which is where the YMF271 reads its samples from -- this
	// IS that memory, not a copy of it.
	wire       er_pick = (er_run[0] && er_run[1]) ? er_turn : er_run[1];
	wire [20:0] er_addr = {er_pick, er_block[er_pick], er_word[er_pick], 1'b0};
	// Programs go first: a sweep has 32,768 writes to spare and the updater is
	// not waiting on it, while a program slot has to be free before the next
	// byte arrives.
	wire       pg_pick = pg_pend[0] ? 1'b0 : 1'b1;

	// The byte address a program write is about to go to, and the halfword the
	// watch compares against. Taken from the same expressions the write port
	// is built from below, so this cannot agree with a broken address.
	wire [20:0] pg_byte  = {pg_pick, pg_addr[pg_pick], 1'b0};
	wire        pg_watch = (pg_byte == {WATCH[20:1], 1'b0});
	wire        pg_trig  = (pg_byte == {WATCH_TRIG[20:1], 1'b0});
	reg   [2:0] w_tr_n;      // trace entries still to take
	reg         w_tr_armed;

	// The next queued block of each chip, lowest first. Order does not matter
	// to the updater -- it never reads back before programming -- so lowest is
	// simply the cheapest to pick.
	function [3:0] lowest;
		input [15:0] q;
		integer j;
		begin
			lowest = 4'd0;
			for (j = 15; j >= 0; j = j - 1) if (q[j]) lowest = j[3:0];
		end
	endfunction
	wire [3:0] er_next [0:1];
	assign er_next[0] = lowest(er_q[0]);
	assign er_next[1] = lowest(er_q[1]);

	integer k;
	always @(posedge clk) begin
		// ---- the SDRAM write port ------------------------------------
		if (wr_pend && (sdr_ack == sdr_req)) begin
			wr_pend <= 1'b0;
			dirty   <= ~dirty;
		end

		// ---- the port scheduler --------------------------------------
		// Guarded on "the port is free", NOT chained as an `else` off the
		// retire above -- that tested "did a write just finish", so a second
		// request went out on top of an outstanding one and the toggle
		// handshake lost writes. It cost 90% of a block erase in the
		// testbench, and on hardware it would have been a quietly incomplete
		// flash image.
		//
		// A waiting byte program goes first; otherwise the sweeps take turns,
		// so two concurrent erases finish together rather than one starving
		// the other.
		if (!wr_pend) begin
		if (|pg_pend) begin
			sdr_addr <= SDR_PCM_BASE + {5'd0, pg_pick, pg_addr[pg_pick], 1'b0};
			sdr_din  <= {pg_data[pg_pick], pg_data[pg_pick]};
			sdr_be   <= pg_lane[pg_pick] ? 2'b10 : 2'b01;
			sdr_req  <= ~sdr_req;
			wr_pend  <= 1'b1;
			wr_chip  <= pg_pick;
			pg_pend[pg_pick] <= 1'b0;
			dbg_progs <= dbg_progs + 32'd1;

			// The watch, on the values actually being sent.
			if (pg_watch) begin
				dbg_w_progs <= dbg_w_progs + 8'd1;
				dbg_w_be    <= pg_lane[pg_pick] ? 2'b10 : 2'b01;
				dbg_w_data  <= pg_data[pg_pick];
			end
			if (pg_trig) w_tr_armed <= 1'b1;
			if (pg_trig || w_tr_armed) begin
				if (|w_tr_n) begin
					dbg_w_trace <= {dbg_w_trace[41:0], pg_byte[11:0],
					                pg_lane[pg_pick] ? 2'b10 : 2'b01};
					w_tr_n <= w_tr_n - 3'd1;
				end
			end
		end
		else if (|er_run) begin
			sdr_addr <= SDR_PCM_BASE + {5'd0, er_addr};
			sdr_din  <= 16'hFFFF;
			sdr_be   <= 2'b11;
			sdr_req  <= ~sdr_req;
			wr_pend  <= 1'b1;
			wr_chip  <= er_pick;
			er_turn  <= ~er_turn;
			// A sweep over the watched halfword, and whether it came after the
			// byte was programmed -- which is the one way an erase could put
			// the erased value back without eating the rest of the block too.
			if (er_addr == {WATCH[20:1], 1'b0}) begin
				dbg_w_erases <= dbg_w_erases + 8'd1;
				if (|dbg_w_progs) dbg_w_er_after <= 1'b1;
			end
			if (&er_word[er_pick]) begin
				// Block done. Take the next one out of this chip's queue, or
				// stop if it is empty.
				dbg_erases <= dbg_erases + 16'd1;
				if (|er_q[er_pick]) begin
					er_block[er_pick] <= er_next[er_pick];
					er_q[er_pick][er_next[er_pick]] <= 1'b0;
				end
				else er_run[er_pick] <= 1'b0;
			end
			er_word[er_pick] <= er_word[er_pick] + 15'd1;
		end
		end

		// ---- the command port ----------------------------------------
		// NEVER refused. The updater erases both chips back to back and
		// programs with no poll between bytes, so a command arriving while
		// something else is busy is the normal case, not an error. Only a
		// program landing on a program slot that is still full would lose a
		// byte, and that is counted: dbg_drops must stay at zero.
		if (wr && enable) begin
			case (mode[sel])

			M_PROG: begin
				if (pg_pend[sel]) dbg_drops <= dbg_drops + 16'd1;
				pg_pend[sel] <= 1'b1;
				pg_addr[sel] <= addr[19:1];
				pg_lane[sel] <= addr[0];
				pg_data[sel] <= din;
				mode[sel]    <= M_STATUS;
				status[sel]  <= 8'h80;
			end

			M_ERASE:
				// D0 confirms; anything else is an aborted command sequence,
				// which the part reports rather than acting on.
				if (din == 8'hD0) begin
					// Idle: start on this block. Busy: queue it, because
					// restarting the running sweep would abandon it.
					if (er_run[sel]) er_q[sel][addr[19:16]] <= 1'b1;
					else begin
						er_run[sel]   <= 1'b1;
						er_block[sel] <= addr[19:16];
						er_word[sel]  <= 15'd0;
					end
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
			wr_chip    <= 1'b0;
			er_run     <= 2'd0;
			er_turn    <= 1'b0;
			er_q[0]    <= 16'd0;
			er_q[1]    <= 16'd0;
			pg_pend    <= 2'd0;
			dirty      <= 1'b0;
			dbg_progs  <= 32'd0;
			dbg_erases <= 16'd0;
			dbg_drops  <= 16'd0;
			dbg_w_progs    <= 8'd0;
			dbg_w_be       <= 2'd0;
			dbg_w_data     <= 8'd0;
			dbg_w_erases   <= 8'd0;
			dbg_w_er_after <= 1'b0;
			dbg_w_trace    <= 56'd0;
			w_tr_n         <= 3'd4;
			w_tr_armed     <= 1'b0;
			for (k = 0; k < 2; k = k + 1) begin
				mode[k]     <= M_ARRAY;
				status[k]   <= 8'h80;
				er_block[k] <= 4'd0;
				er_word[k]  <= 15'd0;
				pg_addr[k]  <= 19'd0;
				pg_lane[k]  <= 1'b0;
				pg_data[k]  <= 8'd0;
			end
		end
	end

endmodule
