//============================================================================
//  SeibuSPI - Seibu SPI / SXX2E
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
	// An I/O write is still in flight to another clock domain and the 386 has to
	// wait: the SXX2C Z80 program download, or a DS2404 port.
	input             io_stall,
	input             snd01_en,     // cartridge: decode sound1.u0222's window
	input             pcmsrc_en,    // authentic flash: decode the PCM source too
	// Generation A (senkyu, ejanhs, viprp1) puts a 1 MB PCM source ROM on ONE
	// byte lane where generation B puts 2 MB on two. The windows are the same
	// either way; only how much of a dword the ROM occupies changes.
	input             pcmsrc_1lane,
	// Where that ROM was loaded. PER-SET, unlike every other region base: it
	// sits directly above the set's own sprites so the SEI252 families still
	// fit a 32 MB module in their authentic-flash form. spi_top.sv picks it
	// from the same set_id that picks the sprite chunk size; the three values
	// are SDR_PCMSRC_* in spi_defs.vh.
	input      [25:0] pcmsrc_base,

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
	// Where the 386 has put its IDT, and how big it is. The savestate needs
	// this to overlay one gate; nothing else reads it.
	output     [31:0] dbg_idt_base,
	output     [19:0] dbg_idt_limit,
	output     [31:0] dbg_cs_base,
	output     [31:0] dbg_cr0,
	output     [31:0] dbg_ss_base,
	output     [19:0] dbg_ss_limit,
	output      [3:0] dbg_ss_type,
	output            dbg_ss_g,

	// ---- savestate: the 386 spills its own state ------------------------
	// PLAN: the CPU is never instrumented. A savestate asserts NMI, overlays
	// the vector-2 gate so the interrupt lands in a stub this module supplies,
	// and the stub pushes the architectural state onto the game's own stack --
	// which is main RAM, and is saved anyway. All the hardware has to keep is
	// where the stack ended up.
	input             ss_save_req,   // one clk_cpu pulse
	input             ss_restore_req,// ...and the other direction
	// What the restore stub's `pop esp` will read: the saved ESP, plus four to
	// step over the marker slot the save stub pushed, so `popad` lands on the
	// pushad frame and `iret` on the interrupt's.
	input      [31:0] ss_esp_in,
	// High from the instant the save stub's marker write retires until the
	// caller drops ss_hold_rel: the CPU is frozen and main RAM is quiet, which
	// is when the blob is streamed out.
	output reg        ss_snapshot,
	input             ss_hold_rel,
	output reg [31:0] ss_esp_out,
	// Port stealing, the pattern Arcade-IGSPGM's ram_ss_adaptor uses: while
	// the savestate owns main RAM the CPU is frozen, so the blob is read and
	// written through the port the CPU normally drives. No memory here gains
	// a second port -- spi_mainram's own header records that making it truly
	// dual-ported took the array from 2 Mbit to 4 and blew the M10K budget.
	input             ss_ram_own,
	input      [15:0] ss_ram_addr,
	input      [31:0] ss_ram_din,
	input             ss_ram_we,
	output     [31:0] ss_ram_dout,
	// Sweep every cache set after a restore has rewritten memory underneath
	// the CPU. z386's snoop port invalidates a whole set per pulse and feeds
	// both L1s, so 256 pulses retire the lot -- which is all that is needed,
	// because the data cache is write-through and neither cache holds
	// anything that is not also in RAM.
	input             ss_inval,
	input       [7:0] ss_inval_set,
	output reg        ss_in_stub,    // EIP is inside the stub window
	output reg [15:0] ss_writes,     // dword writes the stub has made
	output reg [31:0] ss_last_wa,    // physical address of the last of them
	output reg [31:0] ss_last_wd,    // and the value
	output      [2:0] ss_dbg_state,
	output            ss_dbg_nmi,
	output     [15:0] ss_dbg_gate_dw0,
	output     [15:0] ss_dbg_gate_reads,
	output            ss_dbg_hold,
	// How many dwords the stub window has served, and the last index and datum.
	// If the restore stub never reads SS_ESP_IDX, it never learned where the
	// frame is and everything after that is consequence rather than cause.
	output     [15:0] ss_dbg_stub_reads,
	output      [7:0] ss_dbg_stub_idx,
	output     [31:0] ss_dbg_stub_data,
	// The EIP at the first instruction boundary after the CPU leaves the stub.
	// Sampled in the clk_cpu domain at the exact edge, which is the only place
	// it can be read without racing the CPU.
	output     [31:0] ss_dbg_resume_eip,
	// High while the video DMA holds or wants the main RAM port. The savestate
	// must not take the port from underneath it: `ss_ram_own` overrides
	// `dma_own` in the mux below, so a transfer that started before the freeze
	// would keep advancing its address counter while reading the savestate's
	// data, and write that into the video RAMs.
	output            ss_dma_busy,
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
	// line at pcmsrc_base + 0x29F8 (PLAN.md 19.15). The set's base moved when
	// pcmsrc became per-set; the offset within the region did not, which is all
	// this watch is stated in terms of.
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
		.nmi                (ss_nmi),
		.inta               (cpu_inta),

		// The savestate's gate overlay is a READ substitution, and the gate
		// lives in main RAM, so the game's own build of the IDT has very
		// likely left that line in the data cache. Invalidating it through
		// the core's own snoop port is what makes the overlay visible.
		.snoop_addr         (ss_snoop_addr),
		.snoop_valid        (ss_snoop_valid),

		.a20_enable         (1'b1),
		.single_step        (1'b0),

		.dbg_CS             (dbg_cs),
		.dbg_EIP            (dbg_eip),
		.dbg_CS_base        (dbg_cs_base),
		.dbg_IDT_base       (dbg_idt_base),
		.dbg_IDT_limit      (dbg_idt_limit),
		.dbg_CR0            (dbg_cr0),
		.dbg_SS_base        (dbg_ss_base),
		.dbg_SS_limit       (dbg_ss_limit),
		.dbg_SS_type        (dbg_ss_type),
		.dbg_SS_G           (dbg_ss_g),
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

	// ------------------------------------------------------------------
	// Savestate: the stub window, the gate overlay, and the entry sequence
	//
	// WHY THIS SHAPE. z386 is 10,707 flops and vendored; instrumenting it
	// would cost more fabric than this core has and would fork the upstream
	// source. So the CPU is asked to write its own state out instead, exactly
	// as Arcade-IGSPGM and Arcade-TaitoF2 do with their 68000s. The difference
	// is that a 68000 takes its vector from a fixed low address and this 386
	// runs in PROTECTED MODE with the IDT wherever the boot code put it -- so
	// the gate is overlaid at `dbg_idt_base` rather than at a constant.
	//
	// Measured on rdfts: IDT base 0x00000900, limit 0x110, written once at
	// cycle 6486 and never moved; CS base 0 and CR0 = 0x11, so PE is on and
	// PAGING IS OFF. Linear equals physical, which is why the gate can carry a
	// raw physical address as its offset and why the stub needs no page tables.
	//
	// NMI rather than a maskable interrupt: it is vector 2, the games do not
	// use it, it cannot be masked by a game sitting in a cli/sti critical
	// section, and z386 takes it at an instruction boundary (`nmi_accept_
	// boundary` in z386.sv), which is the quiesce a snapshot needs anyway.
	// ------------------------------------------------------------------

	// 1 KB above main RAM, so both halves of the stub are reachable in real
	// mode after a restore reset (0x40000 is segment 0x4000, offset 0) as well
	// as in protected mode. Main RAM ends at 0x3FFFF, PRG ROM starts at
	// 0x200000, and nothing on the board decodes between them.
	localparam [31:0] SS_STUB_BASE = 32'h0004_0000;

	wire sel_ss = (byte_addr[31:10] == SS_STUB_BASE[31:10]);

	// THE TWO STUBS. Both are entered through the overlaid vector-2 gate, so
	// the CPU is already in protected mode at CPL 0 with EFLAGS, CS and EIP
	// pushed by the interrupt itself. That is the whole reason this is small:
	// a restore never has to re-enter protected mode, reload GDTR/IDTR or
	// touch CR0, because it never leaves them. Measured on rdfts, the boot
	// code writes the IDT once and never moves it, and CR0 settles at 0x11 --
	// so between any two points in one game's run those registers are already
	// identical, and main RAM (which carries the GDT and the IDT) is restored
	// wholesale anyway. A state saved BEFORE protected-mode entry is the one
	// case this cannot express, and the save side refuses it.
	//
	// SAVE, at offset 0x00:
	//
	//   60        pushad         EAX ECX EDX EBX ESP EBP ESI EDI, downwards
	//   89 E0     mov  eax, esp
	//   50        push eax       the hardware recognises THIS write by its own
	//                            signature -- the value stored is the address
	//                            stored to, plus four -- and freezes the CPU on
	//                            it. That single write pins down both ESP and
	//                            the SS base, and the freeze is the moment the
	//                            snapshot is taken.
	//   83 C4 04  add  esp, 4    ...and when the hardware lets go, the stub
	//   61        popad          unwinds and hands the game back. A save is
	//   CF        iret           therefore transparent: no reset, no reload.
	//
	// RESTORE, at offset 0x40:
	//
	//   89 E0     mov  eax, esp
	//   50        push eax       the same marker, so the same hardware freezes
	//                            on it. THE ORDER MATTERS: the blob is written
	//                            back HERE, after the interrupt has made its
	//                            own three pushes, not before. Written before,
	//                            those pushes land on top of the register frame
	//                            that was just restored and quietly wreck it --
	//                            the game's live ESP at restore time is within
	//                            a few words of where the frame sits.
	//   2E 8B 25 imm32  mov esp, cs:[SS_STUB_ESP]   a CONSTANT address, whose
	//                                      contents this module answers itself
	//   61        popad
	//   CF        iret
	//
	// HOW THE RESTORE LEARNS WHERE THE FRAME IS. Not from an immediate carrying
	// the saved ESP: that is part of the instruction stream, so it would have to
	// be right BEFORE the stub is fetched, and the saved ESP arrives from the
	// blob, which cannot be streamed in until the CPU is already frozen inside
	// the stub. Not from the stack either, which was the second attempt: `pop
	// esp` off the marker slot works, but the marker slot is at the game's live
	// ESP minus sixteen and the saved frame is a few words either side of that,
	// so patching it CORRUPTS A SAVED REGISTER. Measured: the marker landed
	// exactly on the frame's EAX slot, and the restore came back with EAX
	// holding a stack address.
	//
	// So the stub loads ESP from a fixed address in this window, which this
	// module answers combinationally out of `ss_esp_in` -- read as DATA, after
	// the blob has landed, which is what makes a constant address sufficient.
	// Nothing in the game's memory is written to make a restore work.
	//
	// THROUGH CS, and that prefix is load-bearing. The third attempt read the
	// dword through the default segment for an ESP-relative access, which is
	// SS -- and SS's LIMIT is per-game. rdfts's spans it and rdft2's does not:
	// the read fell outside the stack segment, raised #SS, and the machine went
	// off into its fault handler by way of the boot code. It looked like the
	// iret misbehaving. CS has to span this address because CS spans the code
	// doing the reading, which lives above 0x200000, and CS's base is zero.
	// A code segment must also be marked readable for this to work; every set
	// here is.
	//
	// The alternative would have been `push cs / pop ds`, which needs no
	// prefix and destroys DS -- and DS is not in the frame, because `pushad`
	// does not push segment registers.
	//
	// Everything else the restore needs -- the GDT, the IDT, the game's stack
	// and the saved register frame sitting on it -- is main RAM, streamed back
	// in while the stub is frozen on its marker.
	//
	// Padded with 0x90 so a cache-line fill never reads undefined bytes.
	localparam [7:0] SS_RESTORE_IDX = 8'h10;   // dword index of offset 0x40
	// Where the restore stub's stack points, and the dword index that answers
	// it. 0x0004_0204 is inside this window and nothing else decodes there.
	localparam [31:0] SS_STUB_ESP = SS_STUB_BASE + 32'h204;
	// ...and the dword this window answers it from. Derived, not written out
	// again: the address appears twice below as raw instruction bytes, and two
	// hand-written copies of one number is how a stub reads the wrong dword
	// after somebody moves the window.
	localparam  [7:0] SS_ESP_IDX  = SS_STUB_ESP[9:2];

	function automatic [31:0] ss_stub_rom(input [7:0] idx);
		case (idx)
			8'h00:   ss_stub_rom = 32'h50E08960;   // pushad / mov eax,esp / push eax
			8'h01:   ss_stub_rom = 32'h6104C483;   // add esp,4 / popad
			8'h02:   ss_stub_rom = 32'h909090CF;   // iret
			SS_RESTORE_IDX:
			         ss_stub_rom = 32'hBC50E089;   // mov eax,esp / push eax / mov esp,
			8'h11:   ss_stub_rom = SS_STUB_ESP;    //   ...this constant address
			8'h12:   ss_stub_rom = 32'h90CF615C;   // pop esp / popad / iret
			// The datum the stub pops. Combinational, so it is whatever the
			// caller has put there by the time the CPU reads it -- which is
			// after the blob has been streamed in, and is why this works where
			// an immediate could not.
			SS_ESP_IDX:
			         ss_stub_rom = ss_esp_in;
			default: ss_stub_rom = 32'h90909090;
		endcase
	endfunction

	// The synthetic vector-2 gate: a 32-bit interrupt gate (type 0xE, P=1,
	// DPL=0) whose selector is the CS the game is already running under -- so
	// the game's own GDT describes it and no GDT overlay is needed -- and whose
	// offset is the stub's physical address, valid as a linear address because
	// paging is off.
	wire [15:0] ss_entry_off = ss_mode_restore ? {6'd0, SS_RESTORE_IDX, 2'b00}
	                                           : 16'h0000;
	wire [31:0] ss_gate_lo = {dbg_cs, SS_STUB_BASE[15:0] | ss_entry_off};
	wire [31:0] ss_gate_hi = {SS_STUB_BASE[31:16], 8'h8E, 8'h00};

	// Where that gate sits, as a main-RAM dword index. Vector 2 is the third
	// 8-byte gate, so 16 bytes in.
	wire [15:0] ss_gate_dw0 = dbg_idt_base[17:2] + 16'd4;

	reg        ss_nmi;
	reg        ss_gate_armed;
	reg        ss_mode_restore;   // which stub the gate points at
	reg        ss_hold;           // freeze the CPU: the snapshot instant
	reg [31:0] ss_snoop_addr;
	reg        ss_snoop_valid;
	reg  [3:0] ss_arm_cnt;
	reg        ss_active;

	localparam [2:0] SS_IDLE = 3'd0, SS_INVAL = 3'd1, SS_NMI = 3'd2,
	                 SS_RUN  = 3'd3;
	reg [2:0] ss_state;

	// Does a main-RAM dword index land on the overlaid gate, and if so which
	// half? 2'd0 is "no", 2'd1 the low dword, 2'd2 the high one.
	function automatic [1:0] ss_gate_sel(input [15:0] dw);
		ss_gate_sel = !ss_gate_armed        ? 2'd0 :
		              (dw == ss_gate_dw0)   ? 2'd1 :
		              (dw == ss_gate_dw0 + 16'd1) ? 2'd2 : 2'd0;
	endfunction


	// EIP is a linear address here and the stub is identity-mapped, so this is
	// simply "is the CPU executing our code".
	wire ss_eip_in_stub = (dbg_eip[31:10] == SS_STUB_BASE[31:10]);

	assign ss_dbg_state     = ss_state;
	assign ss_dbg_hold      = ss_hold;

	reg [15:0] ss_stub_reads;
	reg  [7:0] ss_stub_idx;
	reg [31:0] ss_stub_data;
	assign ss_dbg_stub_reads = ss_stub_reads;
	assign ss_dbg_stub_idx   = ss_stub_idx;
	assign ss_dbg_stub_data  = ss_stub_data;

	reg [31:0] ss_resume_eip;
	reg  [2:0] ss_resume_hold;
	reg        ss_in_stub_d;
	assign ss_dbg_resume_eip = ss_resume_eip;

	always @(posedge clk) begin
		if (reset) begin
			ss_resume_eip  <= 32'd0;
			ss_resume_hold <= 3'd0;
			ss_in_stub_d   <= 1'b0;
		end
		else begin
			// NOT at the falling edge of ss_eip_in_stub. `dbg_eip` is EIP
			// itself, and the iret's microcode assembles it in more than one
			// step -- so the instant it first leaves the stub window it can be
			// half written. Measured: rdfts's 0x0026D7D6 was caught as
			// 0x0000D7D6, the low word in place and the high word not yet, and
			// that reads exactly like a 16-bit iret bug that is not there.
			// Waiting for it to hold still for four cycles costs nothing.
			ss_in_stub_d <= ss_eip_in_stub;
			if (ss_eip_in_stub) begin
				ss_resume_hold <= 3'd0;
			end
			else if (ss_in_stub_d || (ss_resume_hold != 3'd7)) begin
				if (dbg_eip != ss_resume_eip) begin
					ss_resume_eip  <= dbg_eip;
					ss_resume_hold <= 3'd0;
				end
				else if (ss_resume_hold != 3'd7)
					ss_resume_hold <= ss_resume_hold + 3'd1;
			end
		end
	end

	always @(posedge clk) begin
		if (reset) begin
			ss_stub_reads <= 16'd0;
			ss_stub_idx   <= 8'd0;
			ss_stub_data  <= 32'd0;
		end
		else if (state == S_SS_RD) begin
			ss_stub_reads <= ss_stub_reads + 16'd1;
			ss_stub_idx   <= cur_dw[7:0];
			ss_stub_data  <= ss_stub_rom(cur_dw[7:0]);
		end
	end
	assign ss_dbg_nmi       = ss_nmi;
	assign ss_dbg_gate_dw0  = ss_gate_dw0;

	// How many times the overlay actually answered a read. Zero here and a
	// missed stub entry means the CPU never went looking for the gate; nonzero
	// and it did, and something after that is wrong instead.
	reg [15:0] ss_gate_reads;
	assign ss_dbg_gate_reads = ss_gate_reads;

	always @(posedge clk) begin
		ss_snoop_valid <= 1'b0;
		if (ss_inval) begin
			// Set index is addr[11:4] for both L1s (16-byte lines, 256 sets).
			ss_snoop_addr  <= {20'd0, ss_inval_set, 4'd0};
			ss_snoop_valid <= 1'b1;
		end
		if (reset) ss_gate_reads <= 16'd0;
		else if (ram_rd_pipe && (ss_gsel_pipe != 2'd0))
			ss_gate_reads <= ss_gate_reads + 16'd1;

		if (reset) begin
			ss_state        <= SS_IDLE;
			ss_nmi          <= 1'b0;
			ss_gate_armed   <= 1'b0;
			ss_active       <= 1'b0;
			ss_arm_cnt      <= 4'd0;
			ss_in_stub      <= 1'b0;
			ss_writes       <= 16'd0;
			ss_last_wa      <= 32'd0;
			ss_last_wd      <= 32'd0;
			ss_mode_restore <= 1'b0;
			ss_hold         <= 1'b0;
			ss_snapshot     <= 1'b0;
			ss_esp_out      <= 32'd0;
		end
		else begin
			ss_in_stub <= ss_eip_in_stub;

			case (ss_state)
			SS_IDLE: if (ss_save_req || ss_restore_req) begin
				ss_mode_restore <= ss_restore_req && !ss_save_req;

				// Arm the overlay first, then evict the gate's cache line, and
				// only then let the NMI in: if the line were still cached the
				// CPU would read the game's own gate and vanish into whatever
				// the game does with vector 2.
				ss_gate_armed  <= 1'b1;
				ss_active      <= 1'b1;
				ss_writes      <= 16'd0;
				ss_snoop_addr  <= {14'd0, ss_gate_dw0, 2'b00};
				ss_snoop_valid <= 1'b1;
				ss_arm_cnt     <= 4'd0;
				ss_state       <= SS_INVAL;
			end

			// Give the invalidate time to retire before the NMI is offered.
			SS_INVAL: begin
				ss_arm_cnt <= ss_arm_cnt + 4'd1;
				if (ss_arm_cnt == 4'd8) begin
					ss_nmi   <= 1'b1;
					ss_state <= SS_NMI;
				end
			end

			// z386 edge-detects NMI, so the level only has to be held long
			// enough to be seen.
			SS_NMI: begin
				ss_arm_cnt <= ss_arm_cnt + 4'd1;
				if (ss_arm_cnt == 4'd15) begin
					ss_nmi   <= 1'b0;
					ss_state <= SS_RUN;
				end
			end

			// Frozen on the marker write. mem_accept is already gated by
			// ss_hold, so no further memory cycle -- and in particular no
			// write to main RAM -- can retire until the caller lets go.
			SS_RUN: if (ss_hold && ss_hold_rel) begin
				ss_hold     <= 1'b0;
				ss_snapshot <= 1'b0;
				ss_active   <= 1'b0;
				// The overlay comes down with the hold. The stub is past its
				// last fetch by now (it sits in the prefetch queue), and
				// leaving the gate substituted would silently redirect any
				// later NMI the game itself took.
				ss_gate_armed <= 1'b0;
				ss_state      <= SS_IDLE;
			end

			default: ss_state <= SS_IDLE;
			endcase

			// Snoop the stub's own writes. Everything it pushes goes to the
			// game's stack in main RAM, which the blob carries regardless; the
			// only thing the hardware has to keep is the last one, whose
			// address and value together pin down both ESP and the SS base.
			if (ss_active && ss_eip_in_stub && ram_we && !dma_own) begin
				ss_writes  <= ss_writes + 16'd1;
				ss_last_wa <= {14'd0, ram_addr, 2'b00};
				ss_last_wd <= ram_din;

				// The marker: `mov eax,esp` then `push eax` is the only write
				// whose stored VALUE is its own destination address plus four.
				// Recognising it by shape rather than by counting means the
				// stub can grow without the hardware having to be told.
				if (!ss_hold
				    && (ram_din == ({14'd0, ram_addr, 2'b00} + 32'd4))) begin
					ss_hold     <= 1'b1;
					ss_snapshot <= 1'b1;
					// Reported for BOTH directions. On a save it is the ESP to
					// remember; on a restore it is the address of the slot
					// `pop esp` is about to read, which is the one dword the
					// caller has to patch.
					ss_esp_out  <= {14'd0, ram_addr, 2'b00};
				end
			end
		end
	end

	wire sel_io  = (byte_addr[31:11] == 21'd0) && byte_addr[10];
	wire sel_ram = (byte_addr[31:18] == 14'd0) && !sel_io;
	wire sel_rom = ((byte_addr[31:22] == 10'd0) && byte_addr[21])   // 0020_0000
	            ||  (byte_addr[31:21] == 11'h7FF);                  // FFE0_0000
	// The two sound01 windows are decoded by spi_snd_window, instantiated once
	// below: `sel_dw` presents the access the CPU is asking for, `cur_dw` the
	// dword being fetched. See rtl/spi_snd_window.sv for the arithmetic.
	wire sel_s01, sel_pcm;

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
	assign ss_dma_busy = dma_own | dma_req;

	wire [15:0] ram_addr_mux = ss_ram_own ? ss_ram_addr :
	                           dma_own     ? dma_addr    : ram_addr;
	assign ss_ram_dout = ram_dout;

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
		.din  (ss_ram_own ? ss_ram_din : ram_din),
		.be   (ss_ram_own ? 4'hF       : ram_be),
		.we   (ss_ram_own ? ss_ram_we  : (ram_we && !dma_own)),
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
	localparam [2:0] S_SS_RD   = 3'd7;   // the savestate stub window

	reg  [2:0] state;
	reg  [7:0] burst_left;
	reg [29:0] cur_dw;        // running dword address
	reg [63:0] rom_data;
	// Which region this fetch is reading. Latched with the address in S_IDLE:
	// all three share S_ROM_REQ/ACK/OUT and differ only in where the 8-byte
	// group comes from and how the dword is cut out of it.
	// The source encoding lives in spi_defs.vh (SNDW_*), shared with
	// spi_snd_window and with whatever else walks these windows.
	reg  [1:0] rd_src;
	// Read delivery is two stages deep, not one: `ram_addr` is only visible to
	// the RAM the cycle AFTER it is assigned, and the RAM registers its output,
	// so data is valid two cycles after the issuing state.
	reg        ram_rd_q;
	reg        ram_rd_pipe;
	// Which half of the overlaid vector-2 gate, if either, the read now in the
	// RAM's two-cycle pipe is going to land on. Carried alongside the read
	// rather than recomputed on delivery, because by then `ram_addr` has moved
	// on to the next dword of the burst.
	reg  [1:0] ss_gsel_q, ss_gsel_pipe;

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
	// io_stall is an I/O write still in flight to clk_ram, where a second write
	// would overtake it: the SXX2C Z80 program download, which pushes 256 KB a
	// byte at a time with each byte a full SDRAM write, or a DS2404 port. The
	// CPU waits rather than risk a dropped byte. Same shape as the DMA hold
	// above, and the same justification -- the real board stops the 386 too.
	// ss_hold is the savestate freeze. Same shape as the DMA hold above and for
	// the same reason: with no memory cycle accepted, nothing the CPU is doing
	// can reach main RAM, so the blob can be streamed out of a RAM that is
	// provably still.
	wire mem_accept = cpu_valid && !cpu_inta && cpu_en && !dma_own && !dma_req
	                  && !io_stall && !ss_hold && !ss_ram_own
	                  && (state == S_IDLE);
	assign cpu_ready = cpu_inta ? inta_ready : mem_accept;

	// Guard against a zero burstcount, which would underflow the counter.
	wire [7:0] burst_n = (cpu_burstcount == 8'd0) ? 8'd1 : cpu_burstcount;

	// The sound01 and PCM-source windows, and where in SDRAM they read from.
	// `rd_src` is passed in rather than re-derived from cur_dw: a burst latches
	// its source once and then walks cur_dw, and re-deriving would change
	// source mid-burst if one ever straddled a window edge.
	wire [25:0] snd_grp_addr;
	wire  [7:0] s01_byte, pcm_byte_w;
	wire [15:0] pcm_pair;
	wire [31:0] prg_dword;
	wire        grp_last;

	spi_snd_window window
	(
		.sel_dw       (cpu_addr),
		.snd01_en     (snd01_en),
		.pcmsrc_en    (pcmsrc_en),
		.sel_s01      (sel_s01),
		.sel_pcm      (sel_pcm),

		.cur_dw       (cur_dw),
		.src          (rd_src),
		.pcmsrc_1lane (pcmsrc_1lane),
		.pcmsrc_base  (pcmsrc_base),
		.grp_data     (rom_data),

		.grp_addr     (snd_grp_addr),
		.byte_out     (s01_byte),
		.pair_out     (pcm_pair),
		.prg_out      (prg_dword),
		.grp_last     (grp_last)
	);

	// The gen-A PCM byte and the sound1 byte are the same extraction -- both
	// are one packed byte at cur_dw[2:0] -- so the module emits it once.
	assign pcm_byte_w = s01_byte;

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
		ss_gsel_q    <= 2'd0;
		ss_gsel_pipe <= ss_gsel_q;

		// Deliver the dword read from main RAM two cycles ago -- except where
		// the savestate has overlaid the vector-2 gate, which is answered from
		// here instead so the game's own IDT is never written to.
		if (ram_rd_pipe) begin
			mem_din        <= (ss_gsel_pipe == 2'd1) ? ss_gate_lo :
			                  (ss_gsel_pipe == 2'd2) ? ss_gate_hi : ram_dout;
			mem_resp_valid <= 1'b1;
		end

		if (reset) begin
			state      <= S_IDLE;
			sdr_req    <= 1'b0;
			burst_left <= 8'd0;
			ss_gsel_q    <= 2'd0;
			ss_gsel_pipe <= 2'd0;
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
					ss_gsel_q   <= ss_gate_sel(cpu_addr[17:2]);
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
					rd_src <= sel_s01 ? SNDW_S01 : sel_pcm ? SNDW_PCM : SNDW_PRG;
					state  <= S_ROM_REQ;
				end
				else if (sel_ss) begin
					state <= S_SS_RD;
				end
				else begin
					state <= S_NULL;
				end
			end

			// Remaining dwords of a RAM burst: one BRAM read per cycle.
			S_RAM_RD: begin
				ram_addr    <= cur_dw[15:0];
				ram_rd_q    <= 1'b1;
				ss_gsel_q   <= ss_gate_sel(cur_dw[15:0]);
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
				sdr_addr <= snd_grp_addr;
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
					SNDW_S01: mem_din <= {24'd0, s01_byte};
					SNDW_PCM: mem_din <= pcmsrc_1lane ? {24'd0, pcm_byte_w}
					                                  : {16'd0, pcm_pair};
					default:  mem_din <= prg_dword;
				endcase
				// The watch. Frozen on the FIRST serve of this dword: the
				// updater reads each source dword once, so a second would mean
				// something quite different is happening and is worth seeing
				// in `dbg_c_hits` rather than overwriting the evidence.
				if (rd_src == SNDW_PCM && cur_dw == WATCH_DW) begin
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

			// The savestate stub. A cache-line fill asks for four dwords, so
			// this walks the burst the same way S_NULL does.
			S_SS_RD: begin
				mem_din        <= ss_stub_rom(cur_dw[7:0]);
				mem_resp_valid <= 1'b1;
				cur_dw         <= cur_dw + 30'd1;
				burst_left     <= burst_left - 8'd1;
				if (burst_left == 8'd1) state <= S_IDLE;
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
