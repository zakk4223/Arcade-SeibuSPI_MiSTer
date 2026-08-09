//============================================================================
//  SlopperPI - Seibu SPI / SXX2E
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
//    401B       w: d0-d2 ROM bank at 8000
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
(
	input             clk,          // clk_sys, 57.272727 MHz
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
	output reg [24:0] sdr_addr,
	input      [63:0] sdr_dout,
	output reg        sdr_req,
	input             sdr_ack,

	// ---- SDRAM ch5: YMF271 samples ----------------------------------------
	output     [24:0] pcm_addr,
	input      [63:0] pcm_dout,
	output            pcm_req,
	input             pcm_ack,

	output     [15:0] audio,

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
	output reg [15:0] dbg_ymf_wr,
	output     [15:0] dbg_stall,
	output     [15:0] dbg_ymf_overrun,
	output     [15:0] dbg_ymf_active
);

`include "spi_defs.vh"

	// ------------------------------------------------------------------
	// Z80 clock enable: 28.63636 / 4 = 7.1590909 MHz = clk_sys / 8, exact.
	// ------------------------------------------------------------------
	reg [2:0] ce_div;
	always @(posedge clk) ce_div <= reset ? 3'd0 : ce_div + 3'd1;
	wire ce_z80 = (ce_div == 3'd7);

	// ------------------------------------------------------------------
	// Z80
	// ------------------------------------------------------------------
	wire [15:0] z80_addr;
	wire  [7:0] z80_dout;
	reg   [7:0] z80_di;
	wire        z80_m1_n, z80_mreq_n, z80_iorq_n, z80_rd_n, z80_wr_n, z80_rfsh_n;
	wire        z80_wait_n;
	wire        ymf_irq;

	T80s #(.Mode(0), .T2Write(1), .IOWait(1)) z80
	(
		// On SXX2C the Z80 stays in reset until the 386 has pushed its whole
		// program into RAM and released it with 0x68C d0. On SXX2E z80_rst_n is
		// tied high, because there the program is a ROM and nothing gates it.
		.RESET_n (~reset & z80_rst_n),
		.CLK     (clk),
		.CEN     (ce_z80),
		.WAIT_n  (z80_wait_n),
		.INT_n   (~ymf_irq),
		.NMI_n   (1'b1),
		.BUSRQ_n (1'b1),
		.M1_n    (z80_m1_n),
		.MREQ_n  (z80_mreq_n),
		.IORQ_n  (z80_iorq_n),
		.RD_n    (z80_rd_n),
		.WR_n    (z80_wr_n),
		.RFSH_n  (z80_rfsh_n),
		.HALT_n  (),
		.BUSAK_n (),
		.OUT0    (1'b0),
		.A       (z80_addr),
		.DI      (z80_di),
		.DO      (z80_dout)
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
	// Program ROM fetch, with a one-line (8 byte) buffer.
	//
	// The line tag covers the whole 18-bit region offset, bank bits included,
	// so a bank switch invalidates the line by itself.
	// ------------------------------------------------------------------
	reg [63:0] line_data;
	reg [14:0] line_tag;
	reg        line_valid;

	wire line_hit = line_valid && (line_tag == rom_off[17:3]);
	wire [7:0] line_byte = line_data[{rom_off[2:0], 3'b000} +: 8];

	// The Z80 ROM is 128 KB in a region padded to 256 KB. MAME fills the pad
	// with zeros; SDRAM would hand back whatever was there at power-on, so the
	// upper half reads as zero here too rather than as noise.
	wire [7:0] rom_byte = rom_off[17] ? 8'h00 : line_byte;

	wire fetch_miss = rd_active & sel_rom & ~line_hit & ~rom_off[17];

	reg        fetching;
	reg [14:0] fetch_tag;
	reg [15:0] dbg_stall_c;
	assign dbg_stall = dbg_stall_c;

	always @(posedge clk) begin
		if (reset) begin
			sdr_req    <= 1'b0;
			fetching   <= 1'b0;
			line_valid <= 1'b0;
			dbg_stall_c <= 16'd0;
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
			line_data  <= sdr_dout;
			line_tag   <= fetch_tag;
			line_valid <= 1'b1;
			fetching   <= 1'b0;
		end
	end

	// Stall the CPU only while a ROM byte it is actually reading is missing.
	assign z80_wait_n = ~fetch_miss;

	// ------------------------------------------------------------------
	// Work RAM, 8 KB
	// ------------------------------------------------------------------
	reg [7:0] ram [0:8191];
	reg [7:0] ram_q;
	always @(posedge clk) begin
		if (wr_end && b_ram) ram[bus_addr[12:0]] <= bus_data;
		ram_q <= ram[z80_addr[12:0]];
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
		else begin
			if (snd_wr_pulse && !fifo_full) begin
				fifo_mem[fifo_wp] <= snd_din;
				fifo_wp <= fifo_wp + 9'd1;
			end
			if (fifo_pop) begin
				fifo_rp     <= fifo_rp + 9'd1;
				dbg_fifo_rd <= dbg_fifo_rd + 16'd1;
			end
		end
		fifo_q <= fifo_mem[fifo_rp];
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
		end
		else begin
			if (set_sxx2c && wr_end && b_io && (bus_addr[12:0] == 13'h008) && !f2_full) begin
				f2_mem[f2_wp] <= bus_data;
				f2_wp <= f2_wp + 9'd1;
			end
			if (fifo2_rd_pulse && !fifo2_empty) f2_rp <= f2_rp + 9'd1;
		end
		fifo2_q <= f2_mem[f2_rp];
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
		else if (wr_end && b_io && (bus_addr[12:0] == 13'h01B)) rom_bank <= bus_data[2:0];
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

		.audio       (audio),
		.dbg_overrun (dbg_ymf_overrun),
		.dbg_active  (dbg_ymf_active)
	);

	always @(posedge clk) begin
		if (reset)       dbg_ymf_wr <= 16'd0;
		else if (ymf_wr) dbg_ymf_wr <= dbg_ymf_wr + 16'd1;
	end

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
				13'h009: z80_di = {6'd0, ~fifo_empty, 1'b0};
				13'h00A: z80_di = jumpers;   // SXX2C only; MAME leaves it a TODO
				13'h013: z80_di = coin;
				default: z80_di = 8'hFF;
			endcase
		end
		else z80_di = 8'hFF;
	end

endmodule
