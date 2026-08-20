//============================================================================
//  SeibuSPI - DS2404 EconoRAM Time Chip
//
//  The Dallas DS2404S on the SPI mainboard and on SXX2E: a 40-bit real-time
//  counter plus 512 bytes of battery-backed SRAM, which is where the games keep
//  their bookkeeping. Until now the core answered its four ports with zeros.
//
//  WHAT THIS IS A MODEL OF. The real DS2404 speaks 1-Wire, and the board does
//  not: the SEI600 presents it to the 386 as four byte ports, and MAME's
//  ds2404.cpp models THAT view rather than the chip's own protocol (its header
//  says so, at length). So the thing to be faithful to is MAME's device, which
//  is what the game has always been talking to:
//
//    0x6D0  w   1-wire reset: back to waiting for a ROM command
//    0x6D4  w   data: a command byte, an address byte or a scratchpad byte,
//               depending on where the state machine is
//    0x6D8  w   clock: advances the read pointer, and nothing else
//    0x6DC  r   data: the byte under the read pointer
//    0x6DD  r   three bits the game waits to see clear; always zero
//
//  Four commands exist. MAME calls anything else a fatal error; hardware cannot,
//  so an unknown byte is ignored and the machine stays where it is.
//
//    0xCC  skip ROM        the only "ROM command", and the way in
//    0x0F  write scratchpad    address low, address high, then up to 32 bytes
//    0x55  copy scratchpad     address low, address high, end offset -- and the
//                              copy happens on that third byte, not later
//    0xF0  read memory         address low, address high, then clock/read pairs
//
//  The address space behind it is the chip's, not the 386's: 0x000-0x1FF is the
//  SRAM, 0x202-0x206 the five RTC bytes low to high, and everything else reads
//  zero and swallows writes.
//
//  WHY THIS RUNS ON clk_ram. The SRAM is the last 512 bytes of the save file
//  (rtl/spi_nvram.sv), and the save side of MiSTer's nvram cannot be stalled --
//  hps_io takes ioctl_din on the same edge it advances its address. Keeping the
//  memory in the nvram's own clock domain makes that path a plain synchronous
//  read with no crossing in it. The 386 is the side that crosses, and it is the
//  side that can afford to: its accesses are single I/O instructions, tens of
//  clk_ram cycles apart, and it is held off by spi_io while one is in flight.
//
//  The RTC is NOT part of the save file, because it is not part of MAME's
//  either -- ds2404_device::nvram_write stores m_sram and nothing else. MAME
//  seeds the counter from the host clock against a 1995-01-01 reference; there
//  is no clock here, so it starts at zero and counts from power-on, the way a
//  board whose battery has gone would.
//============================================================================

module spi_ds2404
#(
	// clk_ram cycles per RTC tick. MAME ticks the counter at 256 Hz, so this is
	// 114.545455 MHz / 256. The testbench turns it right down rather than
	// simulating half a million cycles per tick.
	parameter TICK_DIV = 447444
)
(
	input             clk,        // clk_ram, with spi_nvram and the arbiters
	// Stop the chip with the rest of the board while a savestate is taken. Only
	// two things in here advance without the 386 asking them to -- the RTC's
	// 256 Hz tick and the scratchpad copy loop -- so only those are gated. The
	// command machine steps on a request edge from a CPU that is frozen, so it
	// is already still, and the SRAM's ports are deliberately left live because
	// the savestate reaches the array through them.
	input             pause,
	// The state machine only. The SRAM deliberately survives reset: it is
	// battery-backed on the board, and it is loaded from the save file while the
	// rest of the core is still held down.
	input             reset,

	// ---- the 386's ports, crossed in from clk_cpu ------------------------
	// One request toggle for all three writes rather than one each, so that two
	// writes cannot be seen out of order or in the same cycle. `ack` echoes the
	// toggle back when the action is complete -- which for a scratchpad copy is
	// up to 33 cycles later -- and spi_io holds the CPU off until it does.
	//
	// `ack` is assigned the req value it OBSERVED and never toggled on its own.
	// That is what makes the two sides' resets independent: spi_io resets on
	// cpu_reset, this on the board reset, and cpu_reset is the wider of the two
	// (it also covers ~rom_ready). If spi_io clears its toggle while this side
	// keeps an old ack, the next request still matches and nothing stalls
	// forever -- which a self-toggling ack would.
	input             req,
	input       [1:0] port,       // 0 = 0x6D0 reset, 1 = 0x6D4 data, 2 = 0x6D8 clk
	input       [7:0] din,
	output reg        ack,
	// 0x6DC. A settled register read from clk_cpu, two clk_ram cycles behind
	// the pointer it follows; the 386 cannot issue an OUT and the IN that reads
	// this less than four clk_ram cycles apart.
	output reg  [7:0] dout,

	// ---- the save file's tail (spi_nvram, same clock) --------------------
	input       [8:0] nv_addr,
	input       [7:0] nv_din,
	input             nv_we,
	output reg  [7:0] nv_dout,
	// Toggles once per store the GAME makes into the SRAM, which is what tells
	// spi_nvram there is something new worth saving. Deliberately not raised by
	// nv_we: a load writing all 512 bytes must not ask for them straight back.
	output reg        nv_dirty
);

	// ------------------------------------------------------------------
	// MAME's state stack. Every command pushes the sequence of states its bytes
	// will be consumed in, and `sptr` walks it. The odd one is S_INIT, which is
	// not waited for but ACTED ON as soon as the byte before it lands, and then
	// stepped past in the same cycle -- so writing the high address byte is
	// what arms a command, not a fourth write.
	// ------------------------------------------------------------------
	localparam [3:0] S_IDLE      = 4'd1;
	localparam [3:0] S_COMMAND   = 4'd2;
	localparam [3:0] S_ADDRESS1  = 4'd3;
	localparam [3:0] S_ADDRESS2  = 4'd4;
	localparam [3:0] S_OFFSET    = 4'd5;
	localparam [3:0] S_INIT      = 4'd6;
	localparam [3:0] S_READ_MEM  = 4'd7;
	localparam [3:0] S_WRITE_PAD = 4'd8;
	// MAME has a read-scratchpad state and no command that reaches it: cmd()
	// decodes 0x0F, 0x55 and 0xF0 only. Left out for the same reason, and
	// mentioned so that the absence reads as a decision.
	localparam [3:0] S_COPY_PAD  = 4'd9;

	localparam [1:0] P_RESET = 2'd0;
	localparam [1:0] P_DATA  = 2'd1;
	localparam [1:0] P_CLK   = 2'd2;

	localparam int TICK_W = $clog2(TICK_DIV);
	localparam [TICK_W-1:0] TICK_LAST = TICK_W'(TICK_DIV - 1);

	reg  [3:0] st [0:7];
	reg  [2:0] sptr;
	reg [15:0] address;
	reg  [7:0] a1, a2, end_off;
	// Six bits, not five: MAME's m_offset walks 0..32 and the write is guarded
	// on `< 0x20`, so a 33rd scratchpad byte is DROPPED rather than wrapping
	// back over the first. A five-bit counter would overwrite pad[0].
	reg  [5:0] offset;
	reg  [7:0] pad [0:31];        // the scratchpad, 256 bits
	reg [39:0] rtc;               // five bytes, low first, as MAME orders them
	reg [TICK_W-1:0] tick_cnt;

	// ------------------------------------------------------------------
	// 512 bytes of SRAM, two read ports and one write port. The write port is
	// shared: a save file being loaded and the game copying its scratchpad
	// cannot happen at once, because the load runs while the core is held in
	// reset. Written as one array so Quartus infers block RAM -- as registers
	// this would be 4,096 of them, a seventh of the whole design, and section 29
	// did not free those to spend them here.
	// ------------------------------------------------------------------
	reg [7:0] sram [0:511];
	reg [7:0] game_q;

	wire       in_sram = (address < 16'h0200);
	wire       in_rtc  = (address >= 16'h0202) && (address <= 16'h0206);
	wire [2:0] rtc_sel = address[2:0] - 3'd2;
	wire [7:0] rtc_q   = rtc[{rtc_sel, 3'b000} +: 8];
	// readmem(): the SRAM, the five RTC bytes, or zero. `game_q` is a cycle
	// behind `address`, which is why `dout` is two.
	wire [7:0] mem_q   = in_sram ? game_q : in_rtc ? rtc_q : 8'h00;

	// ------------------------------------------------------------------
	// The copy a 0x55 does, one byte per cycle. MAME's loop runs
	// `for (i = 0; i <= end_offset; i++)` over a 32-byte scratchpad, so a game
	// asking for more than 32 reads past it there; here the index wraps, which
	// is at least defined. Nothing observed asks for more.
	// ------------------------------------------------------------------
	reg        copying;
	reg  [7:0] copy_i;
	reg [15:0] copy_addr;

	// ------------------------------------------------------------------
	// Arming a command takes its own cycle. Decoding the byte and then setting
	// the read pointer from it -- the port case, the command case, the INIT
	// decode and `{a2,a1} - 1` -- did not fit one clk_ram period: -0.198 ns on
	// `din_s1 -> address[14]`, the far end of the subtract's borrow chain. Split
	// in two, the decode runs from the incoming byte and the arithmetic runs from
	// registers, and neither is in the other's path.
	//
	// It costs one clk_ram cycle per command, which the 386 cannot observe: the
	// ack it is stalled on now comes from this cycle instead of the one before,
	// 8.7 ns later, against an I/O instruction that takes hundreds.
	// ------------------------------------------------------------------
	reg  [3:0] arm;               // the command to set up, S_IDLE = nothing to do
	wire       copy_sram = copying && (copy_addr < 16'h0200);
	wire       copy_rtc  = copying && (copy_addr >= 16'h0202) && (copy_addr <= 16'h0206);

	// ------------------------------------------------------------------
	// The request crossing: synchronise the toggle, then act on its edge.
	//
	// The PAYLOAD gets ONE flop, and the count is the argument rather than a
	// habit. `port` and `din` change on the same clk_cpu edge as `req`, and
	// spi_io then holds them until the ack, so the only sample that can be wrong
	// is one taken at the FIRST clk_ram edge after they moved -- where a flop's
	// difference in arrival decides it. Number the edges from there:
	//
	//   edge 1   req_s1 latches the new req; din_s1 MAY still see the old byte
	//   edge 2   req_s2 <= req_s1;  din_s1 re-samples din, now long settled
	//   edge 3   req_s3 <= req_s2, so req_edge (s2^s3) is true in the cycle
	//            before this one, and the action lands here reading din_s1
	//
	// So one flop is read a cycle after its uncertain sample was overwritten,
	// and there is no metastability exposure left in it. TWO flops would be
	// WORSE, not safer: din_s1 carries edge 1's uncertain sample forward into
	// exactly the cycle the action uses. For a payload that travels beside a
	// toggle, the payload must be SHALLOWER than the toggle's detection point.
	//
	// It also fixes the timing this crossing failed on. Used raw, `din` reached
	// the state machine's decode and the address subtract inside one clk_ram
	// period across a clock crossing: -0.605 ns setup, and -0.320 ns HOLD into
	// the scratchpad's write data, because clk_ram is 4x clk_cpu off the same PLL
	// and the analyser times the transfer rather than cutting it. Registered
	// here, the crossing is one flop-to-flop hop and the rest is clk_ram's own.
	// ------------------------------------------------------------------
	reg        req_s1, req_s2, req_s3;
	wire       req_edge = req_s2 ^ req_s3;
	reg  [7:0] din_s1;
	reg  [1:0] port_s1;

	integer k;
	initial begin
		for (k = 0; k < 8;   k = k + 1) st[k]   = S_IDLE;
		for (k = 0; k < 32;  k = k + 1) pad[k]  = 8'h00;
		// nvram_default(): the SRAM comes up ZEROED, not erased, so a set with
		// no save file yet sees what MAME's first boot sees.
		for (k = 0; k < 512; k = k + 1) sram[k] = 8'h00;
	end

	always @(posedge clk) begin
		// The state stack, the address bytes and the pointer as they are BEFORE
		// the edge that stores them, as variables local to this process. MAME's
		// data_w() writes m_state[] and m_a2 and then reads them back within the
		// same call, and steps the pointer twice, so all of it has to be visible
		// here rather than a cycle late -- which is what these are for, and why
		// they are the one place in this file assigned with `=`.
		automatic logic [3:0] nst [0:7];
		automatic logic [2:0] ns;
		automatic logic [7:0] na1, na2, nend;
		automatic logic [3:0] cur_st;
		automatic logic       armed;
		automatic integer     i;
		req_s1 <= req;
		req_s2 <= req_s1;
		req_s3 <= req_s2;
		din_s1  <= din;
		port_s1 <= port;

		// ---- the SRAM's ports ----------------------------------------
		// A load wins over the game, which costs nothing: the two cannot
		// overlap. nv_dout follows nv_addr for the save side, game_q follows
		// the read pointer for the 386's.
		if (nv_we)        sram[nv_addr]        <= nv_din;
		else if (copy_sram) sram[copy_addr[8:0]] <= pad[copy_i[4:0]];
		nv_dout <= sram[nv_addr];
		game_q  <= sram[address[8:0]];

		// ---- the RTC, 40 bits at 256 Hz ------------------------------
		// A tick landing on the same cycle as a copy into the counter's bytes
		// leaves the incremented value with that byte replaced, where MAME's
		// scheduler would give one or the other whole. Five cycles out of
		// 447,444 per tick, during a copy a game does once at boot if ever, and
		// arbitrating it would cost more logic than the divergence is worth.
		if (pause) begin
			// Held, not reset: the tick has to come back on its own phase or
			// the RTC gains or loses a fraction of a second on every save.
			tick_cnt <= tick_cnt;
		end
		else if (tick_cnt == TICK_LAST) begin
			tick_cnt <= '0;
			rtc      <= rtc + 40'd1;
		end
		else tick_cnt <= tick_cnt + 1'd1;

		// ---- 0x6DC ---------------------------------------------------
		// Reading it has no side effect in any reachable state: MAME advances
		// the pointer on the CLOCK write, not on the read.
		dout <= (st[sptr] == S_READ_MEM) ? mem_q : 8'h00;

		// ---- the copy loop -------------------------------------------
		if (pause) begin
			// Nothing: a copy in flight resumes where it left off.
		end
		else if (copying) begin
			if (copy_sram) nv_dirty <= ~nv_dirty;
			if (copy_rtc)  rtc[{copy_addr[2:0] - 3'd2, 3'b000} +: 8] <= pad[copy_i[4:0]];
			copy_addr <= copy_addr + 16'd1;
			copy_i    <= copy_i + 8'd1;
			if (copy_i == end_off) begin
				copying <= 1'b0;
				ack     <= req_s2;        // only now is the action complete
			end
		end

		// ---- setting up a command that was decoded last cycle --------
		else if (arm != S_IDLE) begin
			case (arm)
			S_READ_MEM:  address <= {a2, a1} - 16'd1;
			S_WRITE_PAD: begin
				address <= {a2, a1};
				offset  <= {1'b0, a1[4:0]};
			end
			S_COPY_PAD: begin
				// The copy runs from the NEXT cycle and acks when it is done.
				copying   <= 1'b1;
				copy_i    <= 8'd0;
				copy_addr <= {a2, a1};
				address   <= {a2, a1};
			end
			default: ;
			endcase
			arm <= S_IDLE;
			if (arm != S_COPY_PAD) ack <= req_s2;
		end

		// ---- a request from the 386 ----------------------------------
		else if (req_edge) begin
			for (i = 0; i < 8; i = i + 1) nst[i] = st[i];
			ns         = sptr;
			na1        = a1;
			na2        = a2;
			nend       = end_off;
			cur_st     = st[sptr];
			armed = 1'b0;

			case (port_s1)
			P_RESET: begin
				// _1w_reset_w: back to waiting for a ROM command.
				nst[0] = S_IDLE;
				ns     = 3'd0;
			end

			P_CLK: begin
				// clk_w: the read pointer, and nothing else in any state.
				if (cur_st == S_READ_MEM) address <= address + 16'd1;
			end

			P_DATA: case (cur_st)
				S_IDLE:
					// rom_cmd(): 0xCC skip ROM is the only one there is.
					if (din_s1 == 8'hCC) begin
						nst[0] = S_COMMAND;
						ns     = 3'd0;
					end
				S_COMMAND: case (din_s1)
					8'h0F: begin                      // write scratchpad
						nst[0] = S_ADDRESS1; nst[1] = S_ADDRESS2;
						nst[2] = S_INIT;     nst[3] = S_WRITE_PAD;
						ns     = 3'd0;
					end
					8'h55: begin                      // copy scratchpad
						nst[0] = S_ADDRESS1; nst[1] = S_ADDRESS2;
						nst[2] = S_OFFSET;   nst[3] = S_INIT;
						nst[4] = S_COPY_PAD;
						ns     = 3'd0;
					end
					8'hF0: begin                      // read memory
						nst[0] = S_ADDRESS1; nst[1] = S_ADDRESS2;
						nst[2] = S_INIT;     nst[3] = S_READ_MEM;
						ns     = 3'd0;
					end
					default: ;                        // MAME calls this fatal
				endcase
				S_ADDRESS1: begin na1  = din_s1; ns = sptr + 3'd1; end
				S_ADDRESS2: begin na2  = din_s1; ns = sptr + 3'd1; end
				S_OFFSET:   begin nend = din_s1; ns = sptr + 3'd1; end
				S_WRITE_PAD: if (offset < 6'd32) begin
					pad[offset[4:0]] <= din_s1;
					offset           <= offset + 6'd1;
				end
				default: ;
			endcase
			default: ;
			endcase

			// The state the byte just consumed leads to. MAME acts on it in the
			// same call; here it is NAMED now and set up next cycle, which is
			// what keeps the decode and the arithmetic out of one another's
			// path. `a1`, `a2` and `end_off` are stored at this edge, so the
			// cycle that reads them back sees the bytes this command was given.
			if (nst[ns] == S_INIT) begin
				arm        <= nst[ns + 3'd1];
				armed      = 1'b1;          // ...so this cycle does not ack
				ns = ns + 3'd1;
			end

			for (i = 0; i < 8; i = i + 1) st[i] <= nst[i];
			sptr    <= ns;
			a1      <= na1;
			a2      <= na2;
			end_off <= nend;
			// A byte that armed nothing is done with; one that armed a command
			// is acked by the cycle that sets it up, or by the copy that follows.
			if (!armed) ack <= req_s2;
		end

		if (reset) begin
			for (i = 0; i < 8; i = i + 1) st[i] <= S_IDLE;
			sptr      <= 3'd0;
			address   <= 16'd0;
			a1        <= 8'd0;
			a2        <= 8'd0;
			end_off   <= 8'd0;
			offset    <= 6'd0;
			copying   <= 1'b0;
			copy_i    <= 8'd0;
			copy_addr <= 16'd0;
			arm       <= S_IDLE;
			ack       <= 1'b0;
			dout      <= 8'd0;
			req_s1    <= 1'b0;
			req_s2    <= 1'b0;
			req_s3    <= 1'b0;
			din_s1    <= 8'd0;
			port_s1   <= 2'd0;
			// The RTC restarts at power-on; the SRAM and nv_dirty do NOT.
			rtc       <= 40'd0;
			tick_cnt  <= '0;
		end
	end

endmodule
