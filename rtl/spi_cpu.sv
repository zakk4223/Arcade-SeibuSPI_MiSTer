//============================================================================
//  SlopperPI - Seibu SPI / SXX2E
//
//  386 subsystem: z386 core, address decode, main RAM, PRG ROM fetch, IRQ.
//
//  Address map (sxx2e_map, seibuspi.cpp:1004,1077):
//
//    0000_0000 - 0003_FFFF   main RAM, 256 KB, on chip
//      0000_0400 - 0000_07FF   memory-mapped I/O, overlaying RAM
//    0020_0000 - 003F_FFFF   PRG ROM, 2 MB, in SDRAM
//    00A0_0000 - 00BF_FFFF   sound01, authentic flash only, pcm ROM low 1 MB
//    00E0_0000 - 00FF_FFFF   sound01, authentic flash only, pcm ROM high 1 MB
//    0120_0000 - 013F_FFFF   sound01, cartridge sets, sound1.u0222, in SDRAM
//    FFE0_0000 - FFFF_FFFF   the same ROM again, for the real-mode reset vector
//    anything else            reads as 0, writes dropped
//
//  The sound01 window (MAME maps the whole region at 00A0_0000-013F_FFFF) is
//  where the cartridge sets that have a second sound ROM keep their Z80
//  program. sound1.u0222 is loaded ROM_LOAD32_BYTE on lane 0 at region
//  0x800000, so its 512 KB occupies 2 MB of 386 space at 0120_0000-013F_FFFF
//  and the 386 reads it as 524,288 dwords with only byte 0 meaningful. That
//  whole 2 MB is decoded and the ROM is stored whole -- PACKED, one byte per
//  dword, at SDR_SND01_BASE. A 4-dword cache line is then four consecutive
//  bytes, one 64-bit SDRAM read.
//
//  Decoding the whole ROM rather than just the program is deliberate. rdft2's
//  program is at 0x60000 and rfjet's at 0x44000, and rfjet's LENGTH has never
//  been measured; carrying the region whole makes both facts irrelevant here.
//  Everything else in the sound01 window keeps falling through to S_NULL,
//  which is what MAME's ERASE00 region reads as anyway, and so do the three
//  dead lanes of every dword in this one. rdfts leaves the whole thing
//  undecoded (snd01_en low): it has no second sound ROM, it never reads the
//  window, and its SDRAM there is not written by any part.
//
//  THE PCM SOURCE WINDOW (pcmsrc_en, authentic-flash MRAs only). The rest of
//  MAME's sound01 region is the cartridge's 2 MB PCM ROM, and the game's own
//  sample-flash updater reads it from there a byte at a time to program the
//  flash (PLAN.md 17.2). It is loaded ROM_LOAD32_WORD, so it occupies TWO byte
//  lanes of every dword -- 1 MB of ROM per 2 MB of window -- and MAME's
//  ROM_CONTINUE(base + 0x400000) puts the second megabyte 2 MB further up,
//  which is the skip the 386's own fetcher walks with (`cmp esi,0x400000 /
//  test esi,0x1fffff / add esi,0x200000`). So the ROM appears as two windows
//  with a 2 MB hole between them:
//
//    00A0_0000 - 00BF_FFFF   ROM bytes 0x000000-0x0FFFFF
//    00C0_0000 - 00DF_FFFF   nothing: the ROM_CONTINUE skip
//    00E0_0000 - 00FF_FFFF   ROM bytes 0x100000-0x1FFFFF
//
//  Stored PACKED, so the byte index is the dword index doubled and a 4-dword
//  cache line is eight consecutive bytes -- one aligned 64-bit read, the same
//  arithmetic as the sound1 window with one more bit of shift.
//
//  Without this the window reads as zero and NOTHING SAYS SO: the updater runs
//  to completion, the game reports UPDATE COMPLETED, and the flash holds 2 MB
//  of silence. A pre-flashed MRA leaves it disabled because the 386 provably
//  never touches the window once the stamp matches (0 reads across 4800
//  frames, PLAN.md section 0).
//
//  The I/O registers really do live inside the RAM address space with nothing
//  to mark them uncacheable, so the z386 data cache is instantiated with its
//  uncacheable window set to 0x400-0x7FF (a 1 KB aligned window is a single
//  compare and covers every register, which all sit in 0x400-0x6FF).
//
//  Bus protocol, from l1_cache.sv / l1_icache.sv:
//    - a transfer is accepted on the edge where valid && ready are both high,
//      so `ready` must be combinational -- a registered `ready` would let a
//      write be accepted twice, since the cache does not drop `valid` until it
//      has seen `ready`
//    - `burstcount` is 4 for a cache line fill, 1 otherwise
//    - reads answer with `burstcount` single-cycle `resp_valid` pulses carrying
//      sequential dwords from `addr`
//    - writes are always burstcount 1 and produce no `resp_valid`
//  Only one request is accepted at a time.
//
//  This whole block runs on clk_cpu (28.636364 MHz), which is exactly clk_sys/2
//  and phase aligned. Main RAM's DMA port and the I/O register file's consumers
//  live on clk_sys; see rtl/pll.v for why the 386 has its own clock.
//============================================================================

module spi_cpu
(
	input             clk,          // clk_cpu, 28.636364 MHz
	input             reset,
	input             cpu_en,       // 0 = stall the CPU (pause, throttle)
	input             z80dl_stall,  // SXX2C: a Z80 download byte is in flight
	input             snd01_en,     // cartridge: decode sound1.u0222's window
	input             pcmsrc_en,    // authentic flash: decode the PCM source too
	// Generation A (senkyu, ejanhs, viprp1) puts a 1 MB PCM source ROM on ONE
	// byte lane where generation B puts 2 MB on two. The windows are the same
	// either way; only how much of a dword the ROM occupies changes.
	input             pcmsrc_1lane,

	// SDRAM channel 1 - PRG ROM
	output reg [25:0] sdr_addr,
	input      [63:0] sdr_dout,
	output reg        sdr_req,
	input             sdr_ack,

	// I/O bus (byte address; only 0x400-0x7FF is decoded here)
	output     [10:2] io_addr,
	output     [31:0] io_wdata,
	output      [3:0] io_be,
	output            io_wr,
	output            io_rd,
	input      [31:0] io_rdata,

	// Video DMA share of the main RAM port. The DMA runs in short bursts a few
	// times a frame; while it holds the port the CPU simply is not granted a
	// memory cycle, which is what the real board's DMA does too.
	input             dma_req,
	output            dma_gnt,

	// How many dwords the CPU has written into the sprite-list buffer and into
	// the tilemap buffer. The sprite DMA reads 0x37000 and finds zeros while the
	// tilemap DMA reads 0x38000 and finds valid data, so the question is whether
	// the 386 ever wrote the sprite region at all. The tilemap count is the
	// control: it must move.
	output reg [15:0] dbg_wr_spr,
	output reg [15:0] dbg_wr_tm,
	input      [15:0] dma_addr,
	output     [31:0] dma_dout,

	// Why the CPU is or is not making progress, for the on-screen panel:
	//   [0] a program-ROM read is outstanding (req toggled, ack not back yet)
	//   [1] the bus state machine is not idle
	//   [2] the CPU is asserting valid and we are not accepting it
	//   [3] an interrupt acknowledge cycle is in progress
	output      [3:0] dbg_why,
	output     [31:0] dbg_eip,
	output     [15:0] dbg_cs,
	output            dbg_irq,
	// Mirror of what the CPU writes to main RAM at 0x800, where the boot code
	// builds the GDT it then LGDTs. If protected-mode entry fails, the first
	// question is whether the GDT actually landed in RAM intact.
	output reg [31:0] dbg_gdt0,
	output reg [31:0] dbg_gdt1,
	output reg [31:0] dbg_gdt2,
	output reg [31:0] dbg_gdt3,
	output reg [31:0] dbg_gdt4,
	output reg [31:0] dbg_gdt5,

	// Vertical blanking interrupt. Crosses from clk_sys as a toggle: a one-cycle
	// clk_sys pulse would be invisible to a clock running at half the rate.
	input             vbl_toggle,

	// ---- the sel_pcm watch (PLAN.md 19.15) ----------------------------
	// 19.14 traced the wrong byte back to the 386's own read: it pushes 0xFF
	// into the sound FIFO where the source holds 0xFE, and everything below
	// the push is faithful. This watches the read that feeds it.
	//
	// One dword: the one whose PCM pair carries source byte 0x29FE. On a serve
	// it records the whole 8-byte line the pair came out of, the ADDRESS of the
	// fetch that filled it, and the pair extracted. Those three separate the
	// three ways this can go wrong -- a line fetched from the wrong place, a
	// line fetched from the right place holding the wrong bytes, or the right
	// line with the pair picked out of it wrongly.
	output reg  [7:0] dbg_c_hits,
	output reg [63:0] dbg_c_rom,
	output reg [15:0] dbg_c_pair,
	output reg [25:0] dbg_c_addr,
	output reg        dbg_c_hit
);

`include "spi_defs.vh"

	// The 386 dword whose PCM pair carries source byte 0x29FE: 386 address
	// 0x0A053FC, which is dword 0x02814FF. Its pair sits at bytes 6-7 of the
	// line at SDR_PCMSRC_BASE + 0x29F8 (PLAN.md 19.15).
	localparam [29:0] WATCH_DW = 30'h02814FF;

	// ------------------------------------------------------------------
	// z386
	// ------------------------------------------------------------------
	wire [31:2] cpu_addr;
	wire  [3:0] cpu_be;
	wire  [7:0] cpu_burstcount;
	wire [31:0] cpu_dout;
	wire        cpu_valid, cpu_write, cpu_io;
	wire        cpu_inta;

	reg  [31:0] mem_din;
	reg         mem_resp_valid;
	reg         irq_pending;

	// INTA responses are muxed over the memory path, exactly as
	// z386_MiSTer/src/system.sv does it.
	reg         inta_ready;
	wire [31:0] cpu_din        = cpu_inta ? 32'h0000_0020 : mem_din;
	wire        cpu_resp_valid = cpu_inta ? inta_ready    : mem_resp_valid;
	wire        cpu_ready;

	z386 #(
		.PROTECT_UMA_ROM      (0),
		.DCACHE_SET_BITS      (8),
		.ICACHE_SET_BITS      (8),
		.DCACHE_UNCACHED_MASK (32'hFFFF_FC00),   // I/O window
		.DCACHE_UNCACHED_BASE (32'h0000_0400)
	) cpu
	(
		.clk                (clk),
		.reset_n            (~reset),

		.addr               (cpu_addr),
		.be                 (cpu_be),
		.burstcount         (cpu_burstcount),
		.din                (cpu_din),
		.dout               (cpu_dout),
		.valid              (cpu_valid),
		.ready              (cpu_ready),
		.write              (cpu_write),
		.io                 (cpu_io),
		.resp_valid         (cpu_resp_valid),

		.intr               (irq_pending),
		.nmi                (1'b0),
		.inta               (cpu_inta),

		.snoop_addr         (32'd0),
		.snoop_valid        (1'b0),

		.a20_enable         (1'b1),
		.single_step        (1'b0),

		.dbg_CS             (dbg_cs),
		.dbg_EIP            (dbg_eip),
		.dbg_CS_base        (),
		.dbg_pe             (),
		.dbg_vm             (),
		.triple_fault_reset ()
	);

	// ------------------------------------------------------------------
	// Interrupt
	//
	// MAME drives IRQ0 with HOLD_LINE on vblank and the acknowledge callback
	// unconditionally returns vector 0x20 -- there is no PIC on this board.
	//
	// The z386 BIU runs a two-cycle INTA sequence and holds `inta` across two
	// posedges per cycle, so this mirrors pic_inta_bridge.sv: respond once per
	// assertion, wait for `inta` to fall between the cycles, and retire the
	// request on the second. The vector is constant, so the first cycle's data
	// does not matter.
	// ------------------------------------------------------------------
	localparam [1:0] I_IDLE = 2'd0, I_CYC1 = 2'd1, I_CYC2 = 2'd2;

	reg [1:0] istate;
	reg       inta_responded;
	reg       vbl_tgl_d;

	always @(posedge clk) begin
		inta_ready <= 1'b0;

		if (reset) begin
			istate         <= I_IDLE;
			inta_responded <= 1'b0;
			irq_pending    <= 1'b0;
			vbl_tgl_d      <= vbl_toggle;
		end
		else begin
			vbl_tgl_d <= vbl_toggle;
			if (vbl_toggle != vbl_tgl_d) irq_pending <= 1'b1;

			case (istate)
				I_IDLE: if (cpu_inta && !inta_responded) begin
					inta_ready     <= 1'b1;
					inta_responded <= 1'b1;
					istate         <= I_CYC1;
				end

				I_CYC1: if (!cpu_inta) begin
					inta_responded <= 1'b0;
					istate         <= I_CYC2;
				end

				I_CYC2: if (cpu_inta && !inta_responded) begin
					inta_ready     <= 1'b1;
					inta_responded <= 1'b1;
					irq_pending    <= 1'b0;
					istate         <= I_IDLE;
				end

				default: istate <= I_IDLE;
			endcase

			if (!cpu_inta) inta_responded <= 1'b0;
		end
	end

	// ------------------------------------------------------------------
	// Address decode
	// ------------------------------------------------------------------
	// Bits 1:0 are constant zero by construction; kept so the region tests below
	// read as the byte addresses quoted in the memory map.
	/* verilator lint_off UNUSEDSIGNAL */
	assign dbg_irq = irq_pending;
	assign dbg_why = {cpu_inta,
	                  cpu_valid && !cpu_ready,
	                  state != S_IDLE,
	                  sdr_req ^ sdr_ack};

	wire [31:0] byte_addr = {cpu_addr, 2'b00};
	/* verilator lint_on UNUSEDSIGNAL */

	wire sel_io  = (byte_addr[31:11] == 21'd0) && byte_addr[10];
	wire sel_ram = (byte_addr[31:18] == 14'd0) && !sel_io;
	wire sel_rom = ((byte_addr[31:22] == 10'd0) && byte_addr[21])   // 0020_0000
	            ||  (byte_addr[31:21] == 11'h7FF);                  // FFE0_0000
	// 0120_0000-013F_FFFF: the whole of sound1.u0222 inside MAME's sound01
	// window, which is 0x09 * 2 MB. That ROM is loaded ROM_LOAD32_BYTE on lane 0
	// at region 0x800000, so 512 KB of ROM occupies 2 MB of 386 space.
	wire sel_s01 = snd01_en && (byte_addr[31:21] == 11'h009);
	// The PCM source ROM's two windows, 0x05 and 0x07 * 2 MB. They differ in
	// byte_addr[22] alone -- 0x0A00000 is 101 and 0x0E00000 is 111 in window
	// units -- so that bit IS the ROM's address bit 20, and the 0x0C00000 hole
	// (110) falls out for free because byte_addr[21] is what both windows share.
	wire sel_pcm = pcmsrc_en && (byte_addr[31:24] == 8'd0)
	                         && byte_addr[23] && byte_addr[21];

	// ------------------------------------------------------------------
	// Main RAM
	// ------------------------------------------------------------------
	reg  [15:0] ram_addr;
	reg  [31:0] ram_din;
	reg   [3:0] ram_be;
	reg         ram_we;
	wire [31:0] ram_dout;

	// The DMA is granted the port only when the CPU has nothing in flight, and
	// keeps it until it drops the request. Granting mid-access would corrupt a
	// read that has already been issued into the RAM's pipeline.
	reg dma_own;
	assign dma_gnt = dma_own;

	wire [15:0] ram_addr_mux = dma_own ? dma_addr : ram_addr;

	// dword 0xDC00..0xDFFF is byte 0x37000..0x37FFF (the sprite list),
	// dword 0xE000..0xE3FF is byte 0x38000..0x38FFF (the tilemap source).
	always @(posedge clk) begin
		if (reset) begin
			dbg_wr_spr <= 16'd0;
			dbg_wr_tm  <= 16'd0;
		end
		else if (ram_we && !dma_own) begin
			if (ram_addr[15:10] == 6'h37) dbg_wr_spr <= dbg_wr_spr + 16'd1;
			if (ram_addr[15:10] == 6'h38) dbg_wr_tm  <= dbg_wr_tm  + 16'd1;
		end
	end

	spi_mainram mainram
	(
		.clk  (clk),
		.addr (ram_addr_mux),
		.din  (ram_din),
		.be   (ram_be),
		.we   (ram_we && !dma_own),
		.dout (ram_dout)
	);

	assign dma_dout = ram_dout;

	// ------------------------------------------------------------------
	// I/O bus
	// ------------------------------------------------------------------
	reg        io_cyc_wr, io_cyc_rd;
	reg [10:2] io_addr_r;
	reg [31:0] io_wdata_r;
	reg  [3:0] io_be_r;

	assign io_addr  = io_addr_r;
	assign io_wdata = io_wdata_r;
	assign io_be    = io_be_r;
	assign io_wr    = io_cyc_wr;
	assign io_rd    = io_cyc_rd;

	// ------------------------------------------------------------------
	// Transaction engine
	// ------------------------------------------------------------------
	localparam [2:0] S_IDLE    = 3'd0;
	localparam [2:0] S_RAM_RD  = 3'd1;
	localparam [2:0] S_IO_RD   = 3'd2;
	localparam [2:0] S_ROM_REQ = 3'd3;
	localparam [2:0] S_ROM_ACK = 3'd4;
	localparam [2:0] S_ROM_OUT = 3'd5;
	localparam [2:0] S_NULL    = 3'd6;

	reg  [2:0] state;
	reg  [7:0] burst_left;
	reg [29:0] cur_dw;        // running dword address
	reg [63:0] rom_data;
	// Which region this fetch is reading. Latched with the address in S_IDLE:
	// all three share S_ROM_REQ/ACK/OUT and differ only in where the 8-byte
	// group comes from and how the dword is cut out of it.
	localparam [1:0] R_PRG = 2'd0, R_S01 = 2'd1, R_PCM = 2'd2;
	reg  [1:0] rd_src;
	// Read delivery is two stages deep, not one: `ram_addr` is only visible to
	// the RAM the cycle AFTER it is assigned, and the RAM registers its output,
	// so data is valid two cycles after the issuing state.
	reg        ram_rd_q;
	reg        ram_rd_pipe;

	// Accept combinationally: the cache samples ready in the same cycle it
	// drives valid, and holds valid until it sees ready. `valid` is also
	// asserted during INTA cycles, which the INTA state machine answers
	// instead, so they are excluded here.
	// !dma_req, not just !dma_own: the CPU must stop the moment a DMA is asked
	// for, not merely once the port has been handed over.
	//
	// MAME performs each video DMA atomically inside the trigger write, so no
	// instruction can run between the trigger and the copy. Here the transfer
	// waits for a quiescent state, which leaves a window in which the CPU can
	// keep writing the very buffer being copied -- the source is read over
	// thousands of cycles, so a write landing mid-transfer yields a list that is
	// half this frame and half the next. The real board steals the bus from the
	// 386 for these transfers, so halting it is also closer to the hardware.
	//
	// This is a correctness fix for tearing, NOT the cause of the empty sprite
	// list: MAME's capture shows the game does not clear the buffer after
	// triggering (main RAM at 0x37000 still holds the list at end of frame).
	// z80dl_stall is the SXX2C Z80 program download: the 386 pushes 256 KB a
	// byte at a time and each byte is a full SDRAM write, so the CPU waits
	// rather than risk a dropped byte. Same shape as the DMA hold above, and
	// the same justification -- the real board stops the 386 for this too.
	wire mem_accept = cpu_valid && !cpu_inta && cpu_en && !dma_own && !dma_req
	                  && !z80dl_stall && (state == S_IDLE);
	assign cpu_ready = cpu_inta ? inta_ready : mem_accept;

	// Guard against a zero burstcount, which would underflow the counter.
	wire [7:0] burst_n = (cpu_burstcount == 8'd0) ? 8'd1 : cpu_burstcount;

	// ROM offset: both the 0x0020_0000 window and the 0xFFE0_0000 mirror map to
	// the same 2 MB image, so the low 21 bits are the offset either way.
	// SDRAM 64-bit reads must be 8-byte aligned, so this is the address of the
	// aligned group containing cur_dw, i.e. (cur_dw & ~1) * 4.
	wire [25:0] rom_grp_addr = SDR_PRG_BASE + {4'd0, cur_dw[18:1], 3'b000};

	// sound01: the dword index within the window IS the packed byte index, so
	// one 64-bit read covers eight consecutive dwords. cur_dw[18:0] spans the
	// whole 512 KB; the window test above has already fixed the bits above it.
	wire [25:0] s01_grp_addr = SDR_SND01_BASE + {7'd0, cur_dw[18:3], 3'b000};
	wire  [7:0] s01_byte     = rom_data[{cur_dw[2:0], 3'b000} +: 8];

	// PCM source, generation B: two byte lanes per dword, so the packed byte
	// index is the dword index DOUBLED, with cur_dw[20] (386 address bit 22)
	// carrying the ROM_CONTINUE skip as the ROM's own address bit 20:
	//
	//   idx[20:0] = { cur_dw[20], cur_dw[18:0], 1'b0 }
	//
	// A group is therefore four dwords, and the pair sought within it sits at
	// byte offset idx[2:0] = {cur_dw[1:0], 1'b0} -- always even, so a dword's
	// two bytes never straddle two groups.
	//
	// Generation A is the same windows with ONE lane: the index is the dword
	// index undoubled, a group is eight dwords, and the byte sits at
	// idx[2:0] = cur_dw[2:0]. That is the sound1 arithmetic with the skip bit
	// on top, which is why it costs a mux and not a second decode.
	wire [25:0] pcm_grp_addr = SDR_PCMSRC_BASE
	                         + (pcmsrc_1lane
	                            ? {6'd0, cur_dw[20], cur_dw[18:3], 3'b000}
	                            : {5'd0, cur_dw[20], cur_dw[18:2], 3'b000});
	wire  [7:0] pcm_byte     = rom_data[{cur_dw[2:0], 3'b000} +: 8];
	wire [15:0] pcm_pair     = rom_data[{cur_dw[1:0], 4'b0000} +: 16];

	// Where the group ends: a program dword pair spans one group, eight packed
	// sound01 bytes do, four PCM-source dwords do, so a burst crossing the end
	// needs a fresh fetch.
	wire        grp_last     = (rd_src == R_S01) ? (cur_dw[2:0] == 3'b111)
	                         : (rd_src == R_PCM) ? (pcmsrc_1lane ? (cur_dw[2:0] == 3'b111)
	                                                             : (cur_dw[1:0] == 2'b11))
	                                             :  cur_dw[0];

	// Snoop the GDT the boot code builds at byte 0x800 (dword index 0x200).
	//
	// The copy loop is 24 16-bit STOS writes over 48 bytes; the 8 dwords watched
	// here (0x800..0x81F) take exactly 16 of them. The snoop honours the byte
	// enables rather than latching ram_din whole, and stops dead after those 16
	// writes -- if the CPU later runs away and scribbles over low memory, which
	// is the failure being investigated, anything looser shows the wreckage
	// instead of the GDT.
	reg [5:0] gdt_writes;
	wire      gdt_hit = ram_we && (ram_addr[15:3] == 13'h040) && (gdt_writes < 6'd16);

	always @(posedge clk) begin
		if (reset) begin
			gdt_writes <= 6'd0;
			dbg_gdt0 <= 32'd0; dbg_gdt1 <= 32'd0; dbg_gdt2 <= 32'd0;
			dbg_gdt3 <= 32'd0; dbg_gdt4 <= 32'd0; dbg_gdt5 <= 32'd0;
		end
		else if (gdt_hit) begin
			gdt_writes <= gdt_writes + 6'd1;
			case (ram_addr[2:0])
			3'd0: begin
				if (ram_be[0]) dbg_gdt0[ 7: 0] <= ram_din[ 7: 0];
				if (ram_be[1]) dbg_gdt0[15: 8] <= ram_din[15: 8];
				if (ram_be[2]) dbg_gdt0[23:16] <= ram_din[23:16];
				if (ram_be[3]) dbg_gdt0[31:24] <= ram_din[31:24];
			end
			3'd1: begin
				if (ram_be[0]) dbg_gdt1[ 7: 0] <= ram_din[ 7: 0];
				if (ram_be[1]) dbg_gdt1[15: 8] <= ram_din[15: 8];
				if (ram_be[2]) dbg_gdt1[23:16] <= ram_din[23:16];
				if (ram_be[3]) dbg_gdt1[31:24] <= ram_din[31:24];
			end
			3'd2: begin
				if (ram_be[0]) dbg_gdt2[ 7: 0] <= ram_din[ 7: 0];
				if (ram_be[1]) dbg_gdt2[15: 8] <= ram_din[15: 8];
				if (ram_be[2]) dbg_gdt2[23:16] <= ram_din[23:16];
				if (ram_be[3]) dbg_gdt2[31:24] <= ram_din[31:24];
			end
			3'd3: begin
				if (ram_be[0]) dbg_gdt3[ 7: 0] <= ram_din[ 7: 0];
				if (ram_be[1]) dbg_gdt3[15: 8] <= ram_din[15: 8];
				if (ram_be[2]) dbg_gdt3[23:16] <= ram_din[23:16];
				if (ram_be[3]) dbg_gdt3[31:24] <= ram_din[31:24];
			end
			3'd4: begin
				if (ram_be[0]) dbg_gdt4[ 7: 0] <= ram_din[ 7: 0];
				if (ram_be[1]) dbg_gdt4[15: 8] <= ram_din[15: 8];
				if (ram_be[2]) dbg_gdt4[23:16] <= ram_din[23:16];
				if (ram_be[3]) dbg_gdt4[31:24] <= ram_din[31:24];
			end
			default: begin
				if (ram_be[0]) dbg_gdt5[ 7: 0] <= ram_din[ 7: 0];
				if (ram_be[1]) dbg_gdt5[15: 8] <= ram_din[15: 8];
				if (ram_be[2]) dbg_gdt5[23:16] <= ram_din[23:16];
				if (ram_be[3]) dbg_gdt5[31:24] <= ram_din[31:24];
			end
			endcase
		end
	end

	always @(posedge clk) begin
		mem_resp_valid <= 1'b0;
		ram_we         <= 1'b0;
		io_cyc_wr      <= 1'b0;
		io_cyc_rd      <= 1'b0;
		ram_rd_q    <= 1'b0;
		ram_rd_pipe <= ram_rd_q;

		// Deliver the dword read from main RAM two cycles ago.
		if (ram_rd_pipe) begin
			mem_din        <= ram_dout;
			mem_resp_valid <= 1'b1;
		end

		if (reset) begin
			state      <= S_IDLE;
			sdr_req    <= 1'b0;
			burst_left <= 8'd0;
			dma_own    <= 1'b0;
			dbg_c_hits <= 8'd0;
			dbg_c_rom  <= 64'd0;
			dbg_c_pair <= 16'd0;
			dbg_c_addr <= 26'd0;
			dbg_c_hit  <= 1'b0;
		end
		else begin
			// Grant the DMA the RAM port only from a fully quiescent state.
			if (!dma_own) begin
				if (dma_req && (state == S_IDLE) && !ram_rd_q && !ram_rd_pipe)
					dma_own <= 1'b1;
			end
			else if (!dma_req) begin
				dma_own <= 1'b0;
			end

			case (state)

			S_IDLE: if (mem_accept) begin
				cur_dw     <= cpu_addr;
				burst_left <= burst_n;

				if (cpu_io) begin
					// The board decodes no I/O ports; MAME's map has none.
					// Reads answer with zeroes so the CPU cannot hang.
					state <= cpu_write ? S_IDLE : S_NULL;
				end
				else if (cpu_write) begin
					if (sel_ram) begin
						ram_addr <= cpu_addr[17:2];
						ram_din  <= cpu_dout;
						ram_be   <= cpu_be;
						ram_we   <= 1'b1;
					end
					else if (sel_io) begin
						io_addr_r  <= byte_addr[10:2];
						io_wdata_r <= cpu_dout;
						io_be_r    <= cpu_be;
						io_cyc_wr  <= 1'b1;
					end
					// ROM and unmapped writes are dropped.
					state <= S_IDLE;
				end
				else if (sel_ram) begin
					ram_addr    <= cpu_addr[17:2];
					ram_rd_q    <= 1'b1;
					cur_dw      <= cpu_addr + 30'd1;
					burst_left  <= burst_n - 8'd1;
					state       <= (burst_n > 8'd1) ? S_RAM_RD : S_IDLE;
				end
				else if (sel_io) begin
					io_addr_r <= byte_addr[10:2];
					io_be_r   <= cpu_be;
					io_cyc_rd <= 1'b1;
					state     <= S_IO_RD;
				end
				else if (sel_rom || sel_s01 || sel_pcm) begin
					rd_src <= sel_s01 ? R_S01 : sel_pcm ? R_PCM : R_PRG;
					state  <= S_ROM_REQ;
				end
				else begin
					state <= S_NULL;
				end
			end

			// Remaining dwords of a RAM burst: one BRAM read per cycle.
			S_RAM_RD: begin
				ram_addr    <= cur_dw[15:0];
				ram_rd_q    <= 1'b1;
				cur_dw      <= cur_dw + 30'd1;
				burst_left  <= burst_left - 8'd1;
				if (burst_left == 8'd1) state <= S_IDLE;
			end

			// I/O registers read combinationally.
			S_IO_RD: begin
				mem_din        <= io_rdata;
				mem_resp_valid <= 1'b1;
				state          <= S_IDLE;
			end

			S_ROM_REQ: begin
				case (rd_src)
					R_S01:   sdr_addr <= s01_grp_addr;
					R_PCM:   sdr_addr <= pcm_grp_addr;
					default: sdr_addr <= rom_grp_addr;
				endcase
				sdr_req  <= ~sdr_req;
				state    <= S_ROM_ACK;
			end

			S_ROM_ACK: if (sdr_ack == sdr_req) begin
				rom_data <= sdr_dout;
				state    <= S_ROM_OUT;
			end

			S_ROM_OUT: begin
				// sound01 answers one packed byte in lane 0 and zeroes above,
				// which is what MAME's ROM_LOAD32_BYTE region holds there; the
				// PCM source answers two, ROM_LOAD32_WORD. The dead lanes are
				// zero in MAME's region too, not don't-care -- the region is
				// ERASE00 and the updater's fetcher reads whole dwords.
				case (rd_src)
					R_S01:   mem_din <= {24'd0, s01_byte};
					R_PCM:   mem_din <= pcmsrc_1lane ? {24'd0, pcm_byte}
					                                : {16'd0, pcm_pair};
					default: mem_din <= cur_dw[0] ? rom_data[63:32]
					                              : rom_data[31:0];
				endcase
				// The watch. Frozen on the FIRST serve of this dword: the
				// updater reads each source dword once, so a second would mean
				// something quite different is happening and is worth seeing
				// in `dbg_c_hits` rather than overwriting the evidence.
				if (rd_src == R_PCM && cur_dw == WATCH_DW) begin
					dbg_c_hits <= dbg_c_hits + 8'd1;
					if (!dbg_c_hit) begin
						dbg_c_hit  <= 1'b1;
						dbg_c_rom  <= rom_data;
						dbg_c_pair <= pcm_pair;
						dbg_c_addr <= sdr_addr;
					end
				end

				mem_resp_valid <= 1'b1;
				cur_dw         <= cur_dw + 30'd1;
				burst_left     <= burst_left - 8'd1;

				if (burst_left == 8'd1)  state <= S_IDLE;
				// Crossing into the next 8-byte group needs a fresh fetch;
				// otherwise the next dword is already in rom_data.
				else if (grp_last)       state <= S_ROM_REQ;
			end

			// Unmapped read: answer with zeroes.
			S_NULL: begin
				mem_din        <= 32'd0;
				mem_resp_valid <= 1'b1;
				burst_left     <= burst_left - 8'd1;
				if (burst_left == 8'd1) state <= S_IDLE;
			end

			default: state <= S_IDLE;
			endcase
		end
	end

endmodule
