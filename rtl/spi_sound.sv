//============================================================================
//  SeibuSPI - Seibu SPI / SXX2E
//
//  Sound subsystem: Z80 + banked program ROM + the 386 command FIFO + YMF271.
//  (sxx2e_soundmap, seibuspi.cpp:1171)
//
//    0000-1FFF  ROM, offset 0 of the Z80 region
//    2000-3FFF  RAM, 8 KB
//    4002,4003  nop write
//    4004       w: coin latch for the 386 (spi_coin_w)
//    4008       r: 386 -> Z80 FIFO data     w: nop
//    4009       r: FIFO status, d1 = data waiting
//    400B       nop write
//    4013       r: COIN port, active low
//    401B       w: d0-d2 ROM bank at 8000 (eight 32 KB banks over 256 KB;
//                  d3 is the watchdog and the driver always sets it)
//    6000-600F  YMF271
//    8000-FFFF  ROM, 32 KB window selected by the bank register
//
//  The board only fits ONE FIFO -- soundfifo[0], 386 to Z80. `m_soundfifo[1]`
//  is a nullptr on sxx2e, which is why both of the "other direction" status
//  bits read as zero here rather than being implemented.
//
//  The Z80 program lives in SDRAM, so an instruction fetch that misses the
//  8-byte line buffer stalls the CPU with WAIT_n until the read comes back.
//  Code is overwhelmingly sequential, so the line buffer turns 8 fetches into
//  one SDRAM read and the stall is rare.
//============================================================================

module spi_sound
	import system_consts::*;
(
	input             clk,
	// Freeze the sound board: the Z80's clock enable and the YMF271's sample
	// tick. See rtl/spi_video_timing.sv for why a savestate needs this.
	input             pause,

	// ---- the savestate's sections on this board -------------------------
	// All of it runs on clk_sys, which is the ssbus's own clock, so these are
	// plain slaves rather than going through spi_ss_bridge like the clk_cpu
	// ones do. Every RAM is reached by stealing the port its own client uses,
	// which is safe because `pause` has stopped that client.
	ssbus_if.slave    ssbus_z80,
	ssbus_if.slave    ssbus_z80ram,
	ssbus_if.slave    ssbus_fifo,
	ssbus_if.slave    ssbus_fifo2,
	ssbus_if.slave    ssbus_regs,
	// ...and the YMF271's four, passed straight through to the chip.
	ssbus_if.slave    ssbus_ymf_regs,
	ssbus_if.slave    ssbus_ymf_par,
	ssbus_if.slave    ssbus_ymf_st,
	ssbus_if.slave    ssbus_ymf_fb,          // clk_sys, 57.272727 MHz
	input             reset,

	// ---- 386 side. These cross from clk_cpu; see the CDC note below. -------
	input       [7:0] snd_din,      // 0x680 write data
	input             snd_wr,       // one clk_cpu cycle = two clk_sys cycles
	output            snd_full,     // the 386 reads ~this at 0x684 d0
	input             coin_rd,      // 0x680 read, clears the latch
	output reg  [7:0] coin_latch,   // 0x680 read data

	// ---- panel -----------------------------------------------------------
	input       [7:0] coin,         // COIN port, active low

	// ---- SDRAM ch3: Z80 program (shared with the JTAG peek) ---------------
	output reg [25:0] sdr_addr,
	input      [63:0] sdr_dout,
	output reg        sdr_req,
	input             sdr_ack,

	// ---- SDRAM ch5: YMF271 samples ----------------------------------------
	output     [25:0] pcm_addr,
	input      [63:0] pcm_dout,
	output            pcm_req,
	input             pcm_ack,

	// The sample flash: enabled only by an authentic-flash MRA, and its write
	// port goes to ch3's arbiter, because ch3 is the only channel sdram.sv
	// gives a write path (PLAN.md 17.4).
	input             flash_en,
	output     [25:0] flash_sdr_addr,
	output     [15:0] flash_sdr_din,
	output      [1:0] flash_sdr_be,
	output            flash_sdr_req,
	input             flash_sdr_ack,
	// Toggles once per store into the sample flash. spi_nvram uses it to know
	// when there is something worth saving.
	output            flash_dirty_o,
	// The FIFO watch (PLAN.md 19.14). 19.13 put 0xFF on the SDRAM bus where
	// 0xFE belonged, with the address and byte mask right, so the byte was
	// programmed rather than lost and the fault is upstream of the flash. This
	// records the chain's other two links in the SAME run: what the FIFO handed
	// the Z80 just before that write, and what the flash latched.
	//
	// `dbg_fw_pops` is the last four bytes the Z80 took from the 386 FIFO,
	// frozen at the watched write, newest in the low byte. Near this address
	// the payload runs 00, 00, FE, FF, so the freeze should read ...0000FE.
	// If it reads ...0000FF the FIFO handed over the wrong byte; if it reads
	// FE while the flash latched FF, the corruption is between them.
	//
	// `dbg_fw_empty` counts reads of 0x4008 taken while the FIFO is EMPTY.
	// Those do not pop -- `fifo_pop` is gated on !fifo_empty -- so the Z80 gets
	// `fifo_q`, a registered read that lags `fifo_rp`, and no byte is consumed.
	// What the 386 PUSHED, against what the Z80 took. 19.14 caught the FIFO
	// handing over 0xFF, which is either a byte the 386 pushed wrong or one
	// this FIFO lost in transit -- and those need different fixes.
	output reg [31:0] dbg_fw_pushes,
	output reg [31:0] dbg_fw_pops,
	output reg  [8:0] dbg_fw_fill,
	output reg [15:0] dbg_fw_empty,
	output reg  [7:0] dbg_fw_din,
	output reg        dbg_fw_frozen,

	// The watch (PLAN.md 19.11), straight out of spi_soundflash.
	output      [7:0] dbg_flash_w_progs,
	output      [1:0] dbg_flash_w_be,
	output      [7:0] dbg_flash_w_data,
	output      [7:0] dbg_flash_w_erases,
	output            dbg_flash_w_er_after,
	output     [55:0] dbg_flash_w_trace,

	output     [31:0] dbg_flash_progs,
	output     [15:0] dbg_flash_erases,
	output     [15:0] dbg_flash_drops,
	output      [1:0] dbg_flash_busy,

	output     [15:0] audio_l,
	output     [15:0] audio_r,

	// ---- telemetry --------------------------------------------------------
	output reg [15:0] dbg_z80_pc,
	output reg [15:0] dbg_fifo_rd,

	// ---- SXX2C cartridge -------------------------------------------------
	input             set_sxx2c,
	input       [7:0] jumpers,      // Z80 0x400a, update-mode select on SXX2C
	output reg  [7:0] fifo2_q,      // Z80 -> 386 FIFO head, read by 0x680
	output            fifo2_empty,
	input             fifo2_rd,     // level from clk_cpu; edge detected here
	input             z80_rst_n,    // 0 = hold the Z80 in reset (0x68C d0)
	// One past the highest Z80-region byte the 386 has downloaded. Settled
	// before the Z80 leaves reset and static after that, so it crosses from
	// clk_cpu the same way z80_rst_n does.
	input      [18:0] z80dl_end,
	// Which side of the Z80->386 FIFO is stuck, in one reading.
	output reg [15:0] dbg_f2_wr,    // pushes by the Z80 (0x4008 write)
	output reg [15:0] dbg_f2_rd,    // pops by the 386  (0x680 read)
	output reg [15:0] dbg_ymf_wr,
	// Both of these are HIGH-WATER marks, not free-running counters. Section
	// 13b and 14.9 both record the same trap: a 16-bit counter sampled over
	// JTAG wraps between reads and yields whatever rate you want. A maximum
	// can be read at any interval and still means one thing.
	output reg  [8:0] dbg_fifo_peak, // deepest the 386 -> Z80 FIFO has ever got
	output reg [15:0] dbg_full_max,  // longest unbroken FIFO-full run, /1024 clk
	output reg [15:0] dbg_wait_max,  // longest single ROM fetch wait, clk_sys
	output     [15:0] dbg_stall,
	output     [15:0] dbg_ymf_overrun,
	output     [15:0] dbg_ymf_active
);

`include "spi_defs.vh"

	// ------------------------------------------------------------------
	// Z80 clock enable: 28.63636 / 4 = 7.1590909 MHz = clk_sys / 8, exact.
	// ------------------------------------------------------------------
	// The divider's PHASE is part of the machine's state: the Z80 steps one
	// clk_sys cycle in eight, and which one decides exactly when it consumes a
	// FIFO byte relative to the 386. Restore it wrong and a poll loop in the
	// sound driver comes out the other way.
	reg [2:0] ce_div;
	always @(posedge clk) begin
		if (reset) ce_div <= 3'd0;
		else if (ss_rg_acc && ssbus_regs.write && (ssbus_regs.addr == 32'd1))
			ce_div <= ssbus_regs.data[5:3];
		else ce_div <= ce_div + 3'd1;
	end
	// `pause` stops the sound board with the rest of it. The divider keeps
	// running so the Z80 comes back on its own phase rather than a new one.
	wire ce_z80 = (ce_div == 3'd7) && !pause;

	// ------------------------------------------------------------------
	// Z80
	// ------------------------------------------------------------------
	wire [15:0] z80_addr;
	wire  [7:0] z80_dout;
	reg   [7:0] z80_di;
	wire        z80_m1_n, z80_mreq_n, z80_iorq_n, z80_rd_n, z80_wr_n, z80_rfsh_n;
	wire        z80_wait_n;
	wire        ymf_irq;

	// The Z80's own state, discovered rather than enumerated: auto_save_adaptor2
	// walks every (device, state) pair the generated core exposes at reset and
	// records which ones answer, so nothing here has to know how many registers
	// tv80 has.
	wire        z80_ss_rd, z80_ss_wr, z80_ss_ack;
	wire [31:0] z80_ss_in, z80_ss_out;
	wire  [7:0] z80_ss_device_idx;
	wire [15:0] z80_ss_state_idx;

	auto_save_adaptor2 #(.SS_IDX(SSIDX_Z80)) z80_ss_adaptor
	(
		.clk        (clk),
		.ssbus      (ssbus_z80),
		.rd         (z80_ss_rd),
		.wr         (z80_ss_wr),
		.ack        (z80_ss_ack),
		.device_idx (z80_ss_device_idx),
		.state_idx  (z80_ss_state_idx),
		.wr_data    (z80_ss_in),
		.rd_data    (z80_ss_out)
	);

	// tv80 rather than T80, and the reason is savestates and nothing else.
	// state_module.py -- what makes a CPU's state free in Arcade-IGSPGM -- reads
	// Verilog, and rtl/t80 is VHDL. tv80 is the same core translated, so PGM's
	// already-generated tv80_auto_ss.sv drops straight in and the Z80's ~400
	// flops come along without anything being hand-instrumented. The port names
	// are the only thing that changes; `OUT0` has no equivalent and was tied off
	// here anyway.
	//
	// rtl/t80 stays in the tree. The sound path is matched against MAME over two
	// minutes of rdft2 attract (PLAN.md 14) and that measurement, not a compile,
	// is what says this swap is sound -- so the thing it replaced should still
	// be there to go back to.
	tv80s #(.Mode(0), .T2Write(1), .IOWait(1)) z80
	(
		// On SXX2C the Z80 stays in reset until the 386 has pushed its whole
		// program into RAM and released it with 0x68C d0. On SXX2E z80_rst_n is
		// tied high, because there the program is a ROM and nothing gates it.
		.reset_n (~reset & z80_rst_n),
		.clk     (clk),
		.cen     (ce_z80),
		.wait_n  (z80_wait_n),
		.int_n   (~ymf_irq),
		.nmi_n   (1'b1),
		.busrq_n (1'b1),
		.m1_n    (z80_m1_n),
		.mreq_n  (z80_mreq_n),
		.iorq_n  (z80_iorq_n),
		.rd_n    (z80_rd_n),
		.wr_n    (z80_wr_n),
		.rfsh_n  (z80_rfsh_n),
		.halt_n  (),
		.busak_n (),
		.A       (z80_addr),
		.di      (z80_di),
		.dout    (z80_dout),

		.auto_ss_rd              (z80_ss_rd),
		.auto_ss_wr              (z80_ss_wr),
		.auto_ss_data_in         (z80_ss_in),
		.auto_ss_device_idx      (z80_ss_device_idx),
		.auto_ss_state_idx       (z80_ss_state_idx),
		.auto_ss_base_device_idx (8'd0),
		.auto_ss_data_out        (z80_ss_out),
		.auto_ss_ack             (z80_ss_ack)
	);

	// ------------------------------------------------------------------
	// Bus strobes
	//
	// MREQ_n/RD_n/WR_n are asserted for whole T-states, which at clk_sys is
	// eight cycles, so anything with a side effect (popping the FIFO, latching
	// the coin byte) has to fire once per access rather than once per cycle.
	// The strobe is the FALLING edge of "an access is in progress": reads pop
	// at the end of the cycle because the Z80 latches DI there, and advancing
	// the read pointer any earlier would hand it the next byte instead.
	//
	// T80s clears MREQ_n, RD_n and WR_n on the same clock edge, so an end
	// strobe qualified on MREQ_n still being low never fires -- and the
	// address is already moving on by then. Hence the address and write data
	// are latched while the access is live and the side effects use those.
	// ------------------------------------------------------------------
	wire mem       = ~z80_mreq_n & z80_rfsh_n;   // refresh also drives MREQ_n
	wire rd_active = mem & ~z80_rd_n;
	wire wr_active = mem & ~z80_wr_n;

	reg         rd_active_d, wr_active_d;
	reg  [15:0] bus_addr;
	reg   [7:0] bus_data;
	always @(posedge clk) begin
		rd_active_d <= rd_active;
		wr_active_d <= wr_active;
		if (rd_active || wr_active) begin
			bus_addr <= z80_addr;
			bus_data <= z80_dout;
		end
	end
	wire rd_end = rd_active_d & ~rd_active;
	wire wr_end = wr_active_d & ~wr_active;

	// ------------------------------------------------------------------
	// Address decode. sel_* follow the live bus and feed the read mux and the
	// ROM fetch; b_* follow the latched address and feed the side effects.
	// ------------------------------------------------------------------
	wire sel_rom_lo = (z80_addr[15:13] == 3'b000);                 // 0000-1FFF
	wire sel_ram    = (z80_addr[15:13] == 3'b001);                 // 2000-3FFF
	wire sel_io     = (z80_addr[15:13] == 3'b010);                 // 4000-5FFF
	wire sel_ymf    = (z80_addr[15:4]  == 12'h600);                // 6000-600F
	wire sel_rom_hi = z80_addr[15];                                // 8000-FFFF
	wire sel_rom    = sel_rom_lo | sel_rom_hi;

	wire b_ram = (bus_addr[15:13] == 3'b001);
	wire b_io  = (bus_addr[15:13] == 3'b010);
	wire b_ymf = (bus_addr[15:4]  == 12'h600);

	reg [2:0] rom_bank;

	// 18-bit offset into the 256 KB Z80 region.
	wire [17:0] rom_off = sel_rom_hi ? {rom_bank, z80_addr[14:0]}
	                                 : {5'd0,     z80_addr[12:0]};

	// ------------------------------------------------------------------
	// Program ROM fetch, with an N-line (8 byte each) fully associative
	// buffer, round-robin replacement.
	//
	// The line tag covers the whole 18-bit region offset, bank bits included,
	// so a bank switch invalidates a line by itself.
	//
	// WHY MORE THAN ONE LINE. With a single line the buffer thrashes on any
	// loop that alternates opcode fetch with a data read, because both go
	// through here and evict each other. Measured on viprp1's sound-CPU
	// self-check -- a 12-instruction loop spanning four code lines plus one
	// data line -- the Z80 issued 8.0 SDRAM line fetches PER PASS for the five
	// distinct lines it touches, and paid 5.4 wait-state T-states on top of
	// the 100 the instructions themselves take. That is a 5.1% speed error
	// against a board whose Z80 reads its program with no wait states at all.
	// Holding the working set removes it: tv80's own timing is already exact
	// (measured 100.0 executed T-states a pass, matching the hand count).
	// ------------------------------------------------------------------
	localparam int LINES = 8;

	reg [63:0] line_data [LINES];
	reg [14:0] line_tag  [LINES];
	reg        line_valid[LINES];
	reg [$clog2(LINES)-1:0] line_rr;      // round-robin victim

	integer li;
	reg               line_hit_any;
	reg [63:0]        line_hit_data;
	always @* begin
		line_hit_any  = 1'b0;
		line_hit_data = 64'd0;
		for (li = 0; li < LINES; li = li + 1)
			if (line_valid[li] && (line_tag[li] == rom_off[17:3])) begin
				line_hit_any  = 1'b1;
				line_hit_data = line_data[li];
			end
	end

	wire line_hit = line_hit_any;
	wire [7:0] line_byte = line_hit_data[{rom_off[2:0], 3'b000} +: 8];

	// The region is 256 KB (MAME's :audiocpu region is 0x40000, eight 32 KB
	// bank entries) and how much of it holds a program is per set. This used to
	// read the top half back as a constant zero, on the assumption that a
	// 128 KB program in a padded region is universal. It is not: rfjet's
	// program is 240 KB and its driver spends nearly half of its bank selects
	// in bank 5, so that constant deleted the music data it reads there.
	//
	// The pad still has to read as MAME's zeros rather than as whatever SDRAM
	// held at power-on, so the bound is what was actually written -- the 386's
	// download high-water on a cartridge, and the 128 KB ROM part on SXX2E.
	// Compared per line, not per byte: a partial line at the end is data the
	// fetch brought in anyway.
	// Rounded UP to the line, so a download that does not end on an 8-byte
	// boundary keeps the valid bytes of its last line.
	reg [15:0] rom_lim;    // first line with no data behind it
	always @(posedge clk)
		rom_lim <= set_sxx2c ? (z80dl_end[18:3] + {15'd0, |z80dl_end[2:0]})
		                     : 16'h4000;   // 0x20000 >> 3

	wire beyond_prg = ({1'b0, rom_off[17:3]} >= rom_lim);

	wire [7:0] rom_byte = beyond_prg ? 8'h00 : line_byte;

	wire fetch_miss = rd_active & sel_rom & ~line_hit & ~beyond_prg;

	reg        fetching;
	reg [14:0] fetch_tag;
	reg [15:0] dbg_stall_c;
	assign dbg_stall = dbg_stall_c;

	// ch3 is the LOWEST priority channel in sdram.sv (14.7), so a fetch can sit
	// behind tiles, the 386, sprites and PCM. `dbg_stall_c` counts misses and
	// wraps; this is how long the worst ONE of them actually waited, in
	// clk_sys cycles (17.46 ns), saturating rather than wrapping. A Z80 held
	// off long enough stops draining the command FIFO, and then the 386 stalls
	// with it -- which is the gameplay hitch this is here to confirm or clear.
	reg [15:0] wait_run;
	always @(posedge clk) begin
		if (reset) begin
			wait_run     <= 16'd0;
			dbg_wait_max <= 16'd0;
		end
		else if (!fetching) wait_run <= 16'd0;
		else begin
			if (!(&wait_run)) wait_run <= wait_run + 16'd1;
			if ((wait_run + 16'd1) > dbg_wait_max) dbg_wait_max <= wait_run + 16'd1;
		end
	end

	integer lj;
	always @(posedge clk) begin
		// Held in reset the 386 is REWRITING this region through the download
		// port, so nothing cached over that boundary can be trusted. One line
		// survived it before too; with eight, more of it would.
		if (reset || !z80_rst_n) begin
			sdr_req     <= 1'b0;
			fetching    <= 1'b0;
			line_rr     <= '0;
			for (lj = 0; lj < LINES; lj = lj + 1) line_valid[lj] <= 1'b0;
			if (reset) dbg_stall_c <= 16'd0;
		end
		else if (!fetching) begin
			if (fetch_miss) begin
				sdr_addr    <= SDR_Z80_BASE + {7'd0, rom_off[17:3], 3'b000};
				fetch_tag   <= rom_off[17:3];
				sdr_req     <= ~sdr_req;
				fetching    <= 1'b1;
				dbg_stall_c <= dbg_stall_c + 16'd1;
			end
		end
		else if (sdr_ack == sdr_req) begin
			line_data [line_rr] <= sdr_dout;
			line_tag  [line_rr] <= fetch_tag;
			line_valid[line_rr] <= 1'b1;
			line_rr             <= line_rr + 1'b1;
			fetching            <= 1'b0;
		end
	end

	// Stall the CPU only while a ROM byte it is actually reading is missing.
	assign z80_wait_n = ~fetch_miss;

	// ------------------------------------------------------------------
	// Work RAM, 8 KB
	// ------------------------------------------------------------------
	reg [7:0] ram [0:8191];
	reg [7:0] ram_q;

	wire        ss_ram_acc = ssbus_z80ram.access(SSIDX_Z80_RAM);
	wire [12:0] ram_wa = ss_ram_acc ? ssbus_z80ram.addr[12:0] : bus_addr[12:0];
	wire  [7:0] ram_wd = ss_ram_acc ? ssbus_z80ram.data[7:0]  : bus_data;
	wire        ram_we = ss_ram_acc ? ssbus_z80ram.write : (wr_end && b_ram);
	wire [12:0] ram_ra = ss_ram_acc ? ssbus_z80ram.addr[12:0] : z80_addr[12:0];

	always @(posedge clk) begin
		if (ram_we) ram[ram_wa] <= ram_wd;
		ram_q <= ram[ram_ra];
	end

	// One cycle of read latency, exactly as ram_ss_adaptor handles it.
	reg ss_ram_d;
	always @(posedge clk) begin
		ssbus_z80ram.setup(SSIDX_Z80_RAM, 32'd8192, 0);
		if (ss_ram_acc) begin
			if (ssbus_z80ram.write) ssbus_z80ram.write_ack(SSIDX_Z80_RAM);
			else if (ssbus_z80ram.read) begin
				if (ss_ram_d)
					ssbus_z80ram.read_response(SSIDX_Z80_RAM, {56'd0, ram_q});
				ss_ram_d <= 1'b1;
			end
		end
		else ss_ram_d <= 1'b0;
	end

	// ------------------------------------------------------------------
	// 386 -> Z80 FIFO (IDT7201, 512 x 9; only 8 bits are wired)
	//
	// The write strobe is generated on clk_cpu, which is exactly clk_sys/2 and
	// phase aligned from the same PLL, so a one-cycle clk_cpu pulse is high for
	// exactly two clk_sys cycles and a rising-edge detector sees it once.
	// ------------------------------------------------------------------
	reg snd_wr_d, coin_rd_d;
	always @(posedge clk) begin
		snd_wr_d  <= snd_wr;
		coin_rd_d <= coin_rd;
	end
	wire snd_wr_pulse  = snd_wr  & ~snd_wr_d;
	wire coin_rd_pulse = coin_rd & ~coin_rd_d;

	reg [7:0] fifo_mem [0:511];
	reg [8:0] fifo_wp, fifo_rp;
	reg [7:0] fifo_q;

	wire fifo_empty = (fifo_wp == fifo_rp);
	wire fifo_full  = ((fifo_wp + 9'd1) == fifo_rp);
	assign snd_full = fifo_full;

	wire fifo_pop = rd_end && b_io && (bus_addr[12:0] == 13'h008) && !fifo_empty;

	always @(posedge clk) begin
		if (reset) begin
			fifo_wp     <= 9'd0;
			fifo_rp     <= 9'd0;
			dbg_fifo_rd <= 16'd0;
		end
		else if (ss_rg_acc && ssbus_regs.write && (ssbus_regs.addr == 32'd0)) begin
			fifo_rp <= ssbus_regs.data[8:0];
			fifo_wp <= ssbus_regs.data[17:9];
		end
		else begin
			if (snd_wr_pulse && !fifo_full) fifo_wp <= fifo_wp + 9'd1;
			if (fifo_pop) begin
				fifo_rp     <= fifo_rp + 9'd1;
				dbg_fifo_rd <= dbg_fifo_rd + 16'd1;
			end
		end
		// ONE write statement, with the savestate muxed into it. Two separate
		// writes to the same array -- which is how this was first written --
		// stop Quartus inferring a memory at all: it built the whole 512 bytes
		// out of flip-flops instead, and the two FIFOs between them cost 8,192
		// registers and the fit. spi_mainram.sv's header records the same trap
		// from the other direction.
		if (f1_we) fifo_mem[f1_wa] <= f1_wd;
		fifo_q <= fifo_mem[ss_f1_acc ? ssbus_fifo.addr[8:0] : fifo_rp];
	end

	wire [8:0] f1_wa = ss_f1_acc ? ssbus_fifo.addr[8:0] : fifo_wp;
	wire [7:0] f1_wd = ss_f1_acc ? ssbus_fifo.data[7:0] : snd_din;
	wire       f1_we = ss_f1_acc ? ssbus_fifo.write
	                             : (snd_wr_pulse && !fifo_full);

	wire ss_f1_acc = ssbus_fifo.access(SSIDX_SND_FIFO);
	reg  ss_f1_d;
	always @(posedge clk) begin
		ssbus_fifo.setup(SSIDX_SND_FIFO, 32'd512, 0);
		if (ss_f1_acc) begin
			if (ssbus_fifo.write) ssbus_fifo.write_ack(SSIDX_SND_FIFO);
			else if (ssbus_fifo.read) begin
				if (ss_f1_d) ssbus_fifo.read_response(SSIDX_SND_FIFO,
					{56'd0, fifo_q});
				ss_f1_d <= 1'b1;
			end
		end
		else ss_f1_d <= 1'b0;
	end

	// ------------------------------------------------------------------
	// The FIFO watch (PLAN.md 19.14).
	//
	// `fifo_q` is what a read of 0x4008 hands back, so shifting it on every
	// such read records what the Z80 actually received -- including the reads
	// that find the FIFO empty and therefore consume nothing.
	// ------------------------------------------------------------------
	wire [7:0] flash_w_din;
	wire       flash_w_hit;
	wire fifo_rd_any = rd_end && b_io && (bus_addr[12:0] == 13'h008);
	reg [31:0] fifo_hist;
	reg [31:0] push_hist;

	always @(posedge clk) begin
		if (reset) begin
			fifo_hist     <= 32'd0;
			push_hist     <= 32'd0;
			dbg_fw_pushes <= 32'd0;
			dbg_fw_pops   <= 32'd0;
			dbg_fw_fill   <= 9'd0;
			dbg_fw_empty  <= 16'd0;
			dbg_fw_din    <= 8'd0;
			dbg_fw_frozen <= 1'b0;
		end
		else begin
			if (snd_wr_pulse && !fifo_full) push_hist <= {push_hist[23:0], snd_din};
			if (fifo_rd_any) begin
				fifo_hist <= {fifo_hist[23:0], fifo_q};
				if (fifo_empty) dbg_fw_empty <= dbg_fw_empty + 16'd1;
			end
			// Freeze on the FIRST program command for the watched byte, and
			// hold it: a later pass must not overwrite the evidence.
			if (flash_w_hit && !dbg_fw_frozen) begin
				dbg_fw_pops   <= fifo_hist;
				dbg_fw_pushes <= push_hist;
				dbg_fw_fill   <= fifo_wp - fifo_rp;   // fifo_fill is declared below
				dbg_fw_din    <= flash_w_din;
				dbg_fw_frozen <= 1'b1;
			end
		end
	end

	// ------------------------------------------------------------------
	// How hard the 386 is being blocked by the sound CPU.
	//
	// `snd_full` is a real flag, so a Z80 that stops draining makes the 386
	// spin in the sound handshake -- a gameplay freeze with no video symptom
	// at all. These two say whether that is happening and for how long, which
	// is otherwise only visible as "the game hitched".
	//
	// The run length ticks every 1024 clk_sys, i.e. 17.87 us, so a full 16-bit
	// reading is 1.17 s and a quarter-second block reads about 13,974.
	// ------------------------------------------------------------------
	wire [8:0] fifo_fill = fifo_wp - fifo_rp;

	reg [9:0]  full_div;
	reg [15:0] full_run;

	always @(posedge clk) begin
		if (reset) begin
			dbg_fifo_peak <= 9'd0;
			dbg_full_max  <= 16'd0;
			full_div      <= 10'd0;
			full_run      <= 16'd0;
		end
		else begin
			if (fifo_fill > dbg_fifo_peak) dbg_fifo_peak <= fifo_fill;

			if (!fifo_full) begin
				full_div <= 10'd0;
				full_run <= 16'd0;
			end
			else begin
				full_div <= full_div + 10'd1;
				if (&full_div) begin
					full_run <= full_run + 16'd1;
					if ((full_run + 16'd1) > dbg_full_max)
						dbg_full_max <= full_run + 16'd1;
				end
			end
		end
	end

	// ------------------------------------------------------------------
	// Z80 -> 386 FIFO (m_soundfifo[1]), SXX2C only
	//
	// The Z80 writes 0x4008 -- the same address it READS the other FIFO from --
	// and the 386 reads 0x680, which on this board is the FIFO rather than the
	// coin latch. So on a cartridge the coin bits reach the 386 as a message
	// the sound program sends, not through sb_coin_r.
	//
	// SXX2E has no such device: m_soundfifo[1] is a nullptr there, which is why
	// its 0x684 d1 reads a constant 0. Pushes are gated so the SXX2E build does
	// not quietly fill a FIFO nothing drains.
	// ------------------------------------------------------------------
	reg [7:0] f2_mem [0:511];
	reg [8:0] f2_wp, f2_rp;

	assign fifo2_empty = (f2_wp == f2_rp);
	wire   f2_full     = ((f2_wp + 9'd1) == f2_rp);

	reg fifo2_rd_d;
	always @(posedge clk) fifo2_rd_d <= fifo2_rd;
	wire fifo2_rd_pulse = fifo2_rd & ~fifo2_rd_d;

	always @(posedge clk) begin
		if (reset) begin
			f2_wp <= 9'd0;
			f2_rp <= 9'd0;
			dbg_f2_wr <= 16'd0;
			dbg_f2_rd <= 16'd0;
		end
		else if (ss_rg_acc && ssbus_regs.write && (ssbus_regs.addr == 32'd1)) begin
			f2_wp <= ssbus_regs.data[20:12];
			f2_rp <= ssbus_regs.data[29:21];
		end
		else begin
			if (f2_push) begin
				f2_wp <= f2_wp + 9'd1;
				dbg_f2_wr <= dbg_f2_wr + 16'd1;
			end
			if (fifo2_rd_pulse && !fifo2_empty) begin
				f2_rp <= f2_rp + 9'd1;
				dbg_f2_rd <= dbg_f2_rd + 16'd1;
			end
		end
		if (f2_we) f2_mem[f2_wa] <= f2_wd;
		fifo2_q <= f2_mem[ss_f2_acc ? ssbus_fifo2.addr[8:0] : f2_rp];
	end

	wire       f2_push = set_sxx2c && wr_end && b_io
	                     && (bus_addr[12:0] == 13'h008) && !f2_full;
	wire [8:0] f2_wa = ss_f2_acc ? ssbus_fifo2.addr[8:0] : f2_wp;
	wire [7:0] f2_wd = ss_f2_acc ? ssbus_fifo2.data[7:0] : bus_data;
	wire       f2_we = ss_f2_acc ? ssbus_fifo2.write : f2_push;

	wire ss_f2_acc = ssbus_fifo2.access(SSIDX_SND_FIFO2);
	reg  ss_f2_d;
	always @(posedge clk) begin
		ssbus_fifo2.setup(SSIDX_SND_FIFO2, 32'd512, 0);
		if (ss_f2_acc) begin
			if (ssbus_fifo2.write) ssbus_fifo2.write_ack(SSIDX_SND_FIFO2);
			else if (ssbus_fifo2.read) begin
				if (ss_f2_d) ssbus_fifo2.read_response(SSIDX_SND_FIFO2,
					{56'd0, fifo2_q});
				ss_f2_d <= 1'b1;
			end
		end
		else ss_f2_d <= 1'b0;
	end

	// ------------------------------------------------------------------
	// Coin latch (spi_coin_w / sb_coin_r)
	//
	// The Z80 writes the coin bits and the chip latches 0xA0 | data; the 386
	// reads the byte at 0x680 and the read clears it.
	// ------------------------------------------------------------------
	always @(posedge clk) begin
		if (reset) coin_latch <= 8'h00;
		else begin
			if (wr_end && b_io && (bus_addr[12:0] == 13'h004))
				coin_latch <= (|bus_data) ? (8'hA0 | bus_data) : 8'h00;
			if (coin_rd_pulse) coin_latch <= 8'h00;
		end
	end

	// ------------------------------------------------------------------
	// ROM bank (z80_bank_w). d3 is a watchdog on the real chip; ignored.
	// ------------------------------------------------------------------
	always @(posedge clk) begin
		if (reset) rom_bank <= 3'd0;
		else if (ss_rg_acc && ssbus_regs.write && (ssbus_regs.addr == 32'd1))
			rom_bank <= ssbus_regs.data[2:0];
		else if (wr_end && b_io && (bus_addr[12:0] == 13'h01B)) rom_bank <= bus_data[2:0];
	end

	// ------------------------------------------------------------------
	// SSIDX_SND_REGS: the two FIFOs' pointers and the ROM bank. The FIFO
	// CONTENTS are their own sections; without the pointers they would say
	// nothing, because a FIFO is its pointers.
	// ------------------------------------------------------------------
	wire ss_rg_acc = ssbus_regs.access(SSIDX_SND_REGS);
	always @(posedge clk) begin
		ssbus_regs.setup(SSIDX_SND_REGS, 32'd2, 2);
		if (ss_rg_acc) begin
			if (ssbus_regs.read)
				ssbus_regs.read_response(SSIDX_SND_REGS,
					(ssbus_regs.addr == 32'd0)
						? {46'd0, fifo_wp, fifo_rp}
						: {34'd0, f2_rp, f2_wp, 6'd0, ce_div, rom_bank});
			else if (ssbus_regs.write) ssbus_regs.write_ack(SSIDX_SND_REGS);
		end
	end

	// ------------------------------------------------------------------
	// YMF271
	// ------------------------------------------------------------------
	wire [7:0] ymf_dout;
	wire       ymf_wr = wr_end & b_ymf;
	wire       ymf_rd = rd_end & b_ymf;

	// Reads need the live address, since dout is combinational; the write
	// strobe needs the latched one, and the two never overlap.
	wire [3:0] ymf_addr = ymf_wr ? bus_addr[3:0] : z80_addr[3:0];

	ymf271 ymf
	(
		.clk      (clk),
		.reset    (reset),
		.pause    (pause),
		.ssbus_regs (ssbus_ymf_regs),
		.ssbus_par  (ssbus_ymf_par),
		.ssbus_st   (ssbus_ymf_st),
		.ssbus_fb   (ssbus_ymf_fb),
		// The board, not the set: the single-board PCB sums the chip's four
		// outputs to one speaker, the cartridge splits 0 and 1 left/right.
		// That is exactly the mod byte's bit 0, which is already here.
		.stereo   (set_sxx2c),
		.addr     (ymf_addr),
		.din      (bus_data),
		.dout     (ymf_dout),
		.wr       (ymf_wr),
		.rd       (ymf_rd),
		.irq      (ymf_irq),

		.sdr_addr (pcm_addr),
		.sdr_dout (pcm_dout),
		.sdr_req  (pcm_req),
		.sdr_ack  (pcm_ack),

		.ext_wr       (ext_wr),
		.ext_wd       (ext_wd),
		.ext_a        (ext_a),
		.ext_ovr      (ext_ovr),
		.ext_ovr_data (ext_ovr_data),
		.mem_dirty    (flash_dirty),

		.audio_l     (audio_l),
		.audio_r     (audio_r),
		.dbg_overrun (dbg_ymf_overrun),
		.dbg_active  (dbg_ymf_active)
	);

	always @(posedge clk) begin
		if (reset)       dbg_ymf_wr <= 16'd0;
		else if (ymf_wr) dbg_ymf_wr <= dbg_ymf_wr + 16'd1;
	end

	// ------------------------------------------------------------------
	// The sample flash
	//
	// Only the authentic-flash MRAs have one; everywhere else the YMF271's
	// sample memory is a mask ROM or a pre-programmed image, `flash_en` is low,
	// and this is inert -- commands are ignored and reads always see the array.
	// ------------------------------------------------------------------
	wire        ext_wr;
	wire  [7:0] ext_wd;
	wire [22:0] ext_a;
	wire        ext_ovr;
	wire  [7:0] ext_ovr_data;
	wire        flash_dirty;
	assign flash_dirty_o = flash_dirty;

	/* verilator lint_off UNUSEDSIGNAL */
	wire _unused_ext = &{1'b0, ext_a[22:21]};
	/* verilator lint_on UNUSEDSIGNAL */

	spi_soundflash flash
	(
		.clk        (clk),
		.reset      (reset),
		.enable     (flash_en),

		.wr         (ext_wr),
		// The sample region is 2 MB and the chip's port is 23 bits, so the top
		// two mirror rather than reach anything -- both flash chips are inside
		// [20:0], chip 1 being just bit 20.
		.addr       (ext_a[20:0]),
		.din        (ext_wd),

		.rd_ovr     (ext_ovr),
		.rd_data    (ext_ovr_data),

		.sdr_addr   (flash_sdr_addr),
		.sdr_din    (flash_sdr_din),
		.sdr_be     (flash_sdr_be),
		.sdr_req    (flash_sdr_req),
		.sdr_ack    (flash_sdr_ack),

		.dirty      (flash_dirty),
		.dbg_w_progs    (dbg_flash_w_progs),
		.dbg_w_be       (dbg_flash_w_be),
		.dbg_w_data     (dbg_flash_w_data),
		.dbg_w_erases   (dbg_flash_w_erases),
		.dbg_w_er_after (dbg_flash_w_er_after),
		.dbg_w_trace    (dbg_flash_w_trace),
		.dbg_w_din      (flash_w_din),
		.dbg_w_hit      (flash_w_hit),
		.dbg_progs  (dbg_flash_progs),
		.dbg_erases (dbg_flash_erases),
		.dbg_drops  (dbg_flash_drops),
		.dbg_busy   (dbg_flash_busy)
	);

	// M1 with a valid opcode address is close enough to a PC sample for the
	// JTAG panel.
	always @(posedge clk) begin
		if (reset)                          dbg_z80_pc <= 16'd0;
		else if (~z80_m1_n && ~z80_mreq_n)  dbg_z80_pc <= z80_addr;
	end

	// ------------------------------------------------------------------
	// Read data multiplexer
	//
	// IM0: the interrupt acknowledge cycle (M1 + IORQ) must return 0xD7, RST
	// 10h -- that is what audio_vector_r supplies. Nothing else uses the Z80's
	// I/O space on this board.
	// ------------------------------------------------------------------
	always @* begin
		if (~z80_m1_n && ~z80_iorq_n) z80_di = 8'hD7;
		else if (sel_rom)             z80_di = rom_byte;
		else if (sel_ram)             z80_di = ram_q;
		else if (sel_ymf)             z80_di = ymf_dout;
		else if (sel_io) begin
			case (z80_addr[12:0])
				13'h008: z80_di = fifo_q;
				// d0 = _FF of the Z80->386 FIFO: 1 when there is ROOM to
				// send. The sound program polls this before every push, so
				// leaving it 0 -- correct for SXX2E, where m_soundfifo[1] is a
				// nullptr -- deadlocks the cartridge: the Z80 waits for room
				// that never appears while the 386 waits at 0x684 d1 for the
				// reply. d1 = _EF of the 386->Z80 FIFO: 1 when data is waiting.
				13'h009: z80_di = {6'd0, ~fifo_empty, set_sxx2c & ~f2_full};
				13'h00A: z80_di = jumpers;   // SXX2C only; MAME leaves it a TODO
				13'h013: z80_di = coin;
				default: z80_di = 8'hFF;
			endcase
		end
		else z80_di = 8'hFF;
	end

endmodule
