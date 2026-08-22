//============================================================================
//  SeibuSPI - Seibu SPI / SXX2E
//
//  Board top: 386 + video + sound + I/O.
//
//  T3 state: the raster, the 386 subsystem and the I/O register file are in
//  place. The video pipelines (T4) and sound (T5) are still to come.
//============================================================================

module spi_top
	import system_consts::*;
(
	input             clk_sys,     // 57.272727 MHz - video, I/O, sound
	input             clk_cpu,     // 28.636364 MHz - the 386 (clk_sys / 2)
	input             clk_ram,     // 114.545455 MHz - SDRAM
	input             reset,
	input             rom_ready,

	// SXX2C cartridge board. Selected by the MRA's mod byte; see rom_loader.sv.
	input             set_sxx2c,
	// Which ROM set, for the things that differ per GAME rather than per board:
	// the sprite chunk stride and which sprite crypt to use. See spi_defs.vh.
	input       [2:0] set_id,
	// The authentic-flash variant of an SXX2C set: a blank flash plus the
	// cartridge's own sound ROMs, and the game programs it itself. See
	// PLAN.md section 17; meaningless without set_sxx2c.
	input             set_upd,
	input       [7:0] jumpers,
	// Z80 program download -> SDRAM ch3 write port
	output     [25:0] z80dl_sdr_addr,
	output     [15:0] z80dl_sdr_din,
	output      [1:0] z80dl_sdr_be,
	output            z80dl_sdr_req,
	input             z80dl_sdr_ack,

	// Sample-flash programming -> the OTHER ch3 write port. Same channel for
	// the same reason: ch3 is the only one sdram.sv can write.
	output     [25:0] flash_sdr_addr,
	output     [15:0] flash_sdr_din,
	output      [1:0] flash_sdr_be,
	output            flash_sdr_req,
	input             flash_sdr_ack,
	output            flash_dirty,

	// The DS2404's 512 bytes of bookkeeping SRAM, which are the TAIL of the save
	// file (rtl/spi_nvram.sv). The chip is board hardware so it lives in here;
	// the nvram is framework glue so it lives at the top; this is where the two
	// meet. Same clock domain as spi_nvram, deliberately -- see spi_ds2404.sv.
	input       [8:0] ds_nv_addr,
	input       [7:0] ds_nv_din,
	input             ds_nv_we,
	output      [7:0] ds_nv_dout,
	output            ds_nv_dirty,

	// PAUSE: gate the 386 while the video engines keep running, so the frozen
	// frame stays on screen and can be studied at leisure. Driven from a bound
	// controller button at the top level -- joystick bit 11, the MRA's eighth
	// button name, not an OSD switch and not button 3 (PLAN.md 33).
	//
	// It is also the only debug control left in the synthesised net: everything
	// else that used to hang off `dbg_mask` -- the per-layer force-off bits, the
	// vital signs panel, the JTAG counters -- went with the instrumentation. Their
	// modules are still in rtl/, just not instantiated. See PLAN.md 29.
	input             freeze,

	// ---- savestates -----------------------------------------------------
	// The board owns the section map and the sequencing; the top level owns
	// DDR3, the OSD and the slot. See rtl/spi_ss.sv and PLAN.md 38/39.
	input             ss_save,
	input             ss_load,
	output            ss_busy,
	output            ss_stream_write,
	output            ss_stream_read,
	input             ss_stream_busy,
	ssbus_if.slave    ssbus,

	// Probes, for sim/tb_boot_top only. Unconnected at the top level, so
	// Quartus prunes them, exactly like the dbg_* surface above.
	output            ss_in_stub,
	output            ss_snapshot,
	output     [31:0] ss_esp_out,
	output     [15:0] ss_writes,
	output     [31:0] ss_last_wa,
	output     [31:0] ss_last_wd,
	output      [2:0] ss_dbg_state,
	// spi_ss's OWN state, which is what the wedge overlay paints and what
	// the bench had no way to see. Distinct from ss_dbg_state, which is
	// spi_cpu's -- reading one as the other cost a round in PLAN.md 44.5.
	output      [4:0] ss_dbg_seq,
	output            ss_dbg_nmi,
	output     [15:0] ss_dbg_gate_dw0,
	output     [15:0] ss_dbg_gate_reads,
	output            ss_dbg_hold,
	// {io_stall, z80dl_stall, ds_stall} -- which of the two I/O holds is
	// keeping the 386 off an instruction boundary. Diagnostic only.
	output      [2:0] ss_dbg_stalls,
	// Every I/O register the 386 READS, and what it got back. Writes have been
	// visible to the testbench since the beginning; reads have not, and a poll
	// loop is made of reads.
	output            p_cpu_irq,
	// The DS2404's counter and its divider. Read-only taps; see spi_ds2404.sv.
	output     [39:0] p_ds_rtc,
	output     [31:0] p_ds_tick,
	output            p_io_rd,
	output      [8:0] p_io_raddr,
	output     [31:0] p_io_rdata,
	output     [15:0] ss_dbg_stub_reads,
	output      [7:0] ss_dbg_stub_idx,
	output     [31:0] ss_dbg_stub_data,
	output     [31:0] ss_dbg_resume_eip,
	output     [31:0] ss_dbg_esp_scratch,
	output     [31:0] ss_dbg_ss_base,
	output     [19:0] ss_dbg_ss_limit,
	output      [3:0] ss_dbg_ss_type,
	output            ss_dbg_ss_g,

	// SDRAM ch1: 386 program ROM
	output     [25:0] sdr_prg_addr,
	input      [63:0] sdr_prg_dout,
	output            sdr_prg_req,
	input             sdr_prg_ack,

	// SDRAM ch2: tile / char graphics
	output     [25:0] sdr_gfx_addr,
	input      [63:0] sdr_gfx_dout,
	output            sdr_gfx_req,
	input             sdr_gfx_ack,

	// SDRAM ch4: sprite graphics
	output     [25:0] sdr_spr_addr,
	input      [63:0] sdr_spr_dout,
	output            sdr_spr_req,
	input             sdr_spr_ack,

	// SDRAM ch3 (share): Z80 program fetch
	output     [25:0] sdr_z80_addr,
	input      [63:0] sdr_z80_dout,
	output            sdr_z80_req,
	input             sdr_z80_ack,

	// SDRAM ch5: YMF271 PCM samples
	output     [25:0] sdr_pcm_addr,
	input      [63:0] sdr_pcm_dout,
	output            sdr_pcm_req,
	input             sdr_pcm_ack,

	// Controls (active low, as the hardware presents them)
	input      [15:0] inputs,
	input       [7:0] system,
	input       [7:0] coin,

	// Video
	output            ce_pix,
	output      [7:0] red,
	output      [7:0] green,
	output      [7:0] blue,
	output            hsync,
	output            vsync,
	output            hblank,
	output            vblank,

	// Audio
	output     [15:0] audio_l,
	output     [15:0] audio_r
);

`include "spi_defs.vh"

	// ------------------------------------------------------------------
	// Raster
	// ------------------------------------------------------------------
	wire [9:0] hcnt, vcnt;
	wire       line_start, vbl_rise;

	wire sys_reset;
	spi_reset_sync rst_sys (.clk(clk_sys), .rst_in(reset), .rst_out(sys_reset));

	spi_video_timing timing
	(
		.clk        (clk_sys),
		.reset      (sys_reset),
		.pause      (ss_pause),
		.vbl_next   (vbl_next),
		.ce_pix     (ce_pix),
		.hcnt       (hcnt),
		.vcnt       (vcnt),
		.hsync      (hsync),
		.vsync      (vsync),
		.hblank     (hblank),
		.vblank     (vblank),
		.line_start (line_start),
		.vbl_rise   (vbl_rise)
	);

	// ------------------------------------------------------------------
	// Resets
	//
	// `reset` and `rom_ready` originate in other clock domains (clk_sys and the
	// loader's clk_ram), and z386 contains genuine asynchronous clears, so each
	// domain gets its own synchroniser. See rtl/spi_reset_sync.sv.
	// ------------------------------------------------------------------
	wire raw_reset = reset | ~rom_ready;

	wire cpu_reset;
	spi_reset_sync rst_cpu (.clk(clk_cpu), .rst_in(raw_reset), .rst_out(cpu_reset));

	wire vid_reset;
	spi_reset_sync rst_vid (.clk(clk_sys), .rst_in(raw_reset), .rst_out(vid_reset));

	// ------------------------------------------------------------------
	// `freeze` arrives from clk_sys; synchronise it into clk_cpu separately.
	reg [1:0] freeze_s;
	always @(posedge clk_cpu) freeze_s <= {freeze_s[0], freeze};
	wire cpu_freeze = freeze_s[1];

	// 386 subsystem
	// ------------------------------------------------------------------

	wire [10:2] io_addr;
	wire [31:0] io_wdata, io_rdata;
	wire  [3:0] io_be;
	wire        io_wr, io_rd;

	// Video DMA share of the 386's main RAM port.
	wire        dma_req, dma_gnt;
	wire [15:0] dma_addr;
	wire [31:0] dma_dout;

	// The vblank pulse is one clk_sys cycle, which a half-rate clock can miss,
	// so it crosses as a toggle.
	reg vbl_toggle;
	always @(posedge clk_sys) begin
		if (sys_reset)     vbl_toggle <= 1'b0;
		else if (vbl_rise) vbl_toggle <= ~vbl_toggle;
	end

	// ------------------------------------------------------------------
	// Z80 program download bridge (SXX2C)
	//
	// spi_io owns the pointer and the payload on clk_cpu and holds the 386 off
	// until the byte retires, so nothing is lost crossing here. This side just
	// turns the request toggle into one 16-bit masked SDRAM write. The byte
	// lane comes from bit 0 of the address, and the data is duplicated into
	// both halves so the enable alone decides which lands.
	// ------------------------------------------------------------------
	wire  [7:0] fifo2_q;
	wire        fifo2_empty, fifo2_rd;
	wire [17:0] z80dl_addr;
	wire  [7:0] z80dl_data;
	wire        z80dl_req;
	wire        z80dl_stall;
	assign ss_dbg_stalls = {z80dl_stall | ds_stall, z80dl_stall, ds_stall};
	wire [18:0] z80dl_end;
	wire        z80_rst_n;

	reg dl_req_s1, dl_req_s2, dl_req_s3;
	always @(posedge clk_ram) begin
		dl_req_s1 <= z80dl_req;
		dl_req_s2 <= dl_req_s1;
		dl_req_s3 <= dl_req_s2;
		if (reset) {dl_req_s1, dl_req_s2, dl_req_s3} <= 3'b000;
	end
	wire dl_start = (dl_req_s2 != dl_req_s3);

	reg [25:0] dl_sdr_addr;
	reg [15:0] dl_sdr_din;
	reg  [1:0] dl_sdr_be;
	reg        dl_sdr_req;
	always @(posedge clk_ram) begin
		if (reset) begin
			dl_sdr_req <= 1'b0;
		end
		else if (dl_start) begin
			dl_sdr_addr <= SDR_Z80_BASE + {7'd0, z80dl_addr[17:1], 1'b0};
			dl_sdr_din  <= {z80dl_data, z80dl_data};
			dl_sdr_be   <= z80dl_addr[0] ? 2'b10 : 2'b01;
			dl_sdr_req  <= ~dl_sdr_req;
		end
	end
	assign z80dl_sdr_addr = dl_sdr_addr;
	assign z80dl_sdr_din  = dl_sdr_din;
	assign z80dl_sdr_be   = dl_sdr_be;
	assign z80dl_sdr_req  = dl_sdr_req;

	// Back to clk_cpu: spi_io clears its pending flag when this matches.
	wire z80dl_ack = z80dl_sdr_ack;

	// Where the loader put the PCM source ROM. The only per-set region base in
	// the map: it follows the set's OWN sprites so an authentic-flash SEI252
	// set still fits a 32 MB module (spi_defs.vh). Selected by the same set_id
	// arms as spr_chunk below, and it has to stay that way -- the two are the
	// same fact about the set, and rom_loader.sv's table is the third copy.
	reg [25:0] pcmsrc_base;
	always @* case (set_id)
		SET_RDFT2: pcmsrc_base = SDR_PCMSRC_RDFT2;
		SET_RFJET: pcmsrc_base = SDR_PCMSRC_RFJET;
		default:   pcmsrc_base = SDR_PCMSRC_SEI252;
	endcase

	spi_cpu cpu
	(
		// The sel_pcm watch (PLAN.md 19.15). Left unconnected: the counters
		// behind it have no fanout now and synthesis drops them.
		.dbg_c_hits (),
		.dbg_c_rom  (),
		.dbg_c_pair (),
		.dbg_c_addr (),
		.dbg_c_hit  (),
		// Any I/O write still in flight to another clock domain: the Z80
		// program download, and now the DS2404's ports.
		.io_stall    (z80dl_stall | ds_stall),

		// Only the sets with a second sound ROM read sound1.u0222's window, and
		// only their loader tables put anything behind it -- see spi_cpu.sv's
		// map. rdft's Z80 program is inside `maincpu` instead and rdfts has a
		// real Z80 ROM, so neither one ever looks -- UNLESS the flash is being
		// programmed, which reads that ROM as source material on every
		// cartridge set including rdft's seibu_8.u0216.
		// "This set HAS a second sound ROM", which is not the same as "this is
		// an authentic MRA". rdft2 and rfjet always do -- their Z80 program
		// lives in it -- and rdft's is loaded only by its authentic MRA, as
		// updater source. viprp1 has none at all: its compressed tail is in the
		// 386 program image. Leaving the window on for it made the 386 read the
		// unwritten SDRAM there as 0xFF where MAME reads 0x00, on all 512 K
		// dwords of it -- caught by tools/check_snd01_window.py before it ever
		// reached hardware.
		.snd01_en  ((set_id == SET_RDFT2) || (set_id == SET_RFJET)
		            || (set_id == SET_SENKYU) || (set_id == SET_EJANHS)
		            || (set_upd && (set_id == SET_RDFT))),
		// The PCM source window exists only while the game is programming its
		// own flash. A pre-flashed set loads nothing behind it.
		.pcmsrc_en (set_upd),
		// Generation A puts the PCM source on one byte lane instead of two.
		.pcmsrc_1lane ((set_id == SET_VIPRP1) || (set_id == SET_SENKYU)
		               || (set_id == SET_EJANHS)),
		.pcmsrc_base (pcmsrc_base),
		.clk       (clk_cpu),
		.reset     (cpu_reset),
		.cpu_en    (~cpu_freeze),

		.sdr_addr  (sdr_prg_addr),
		.sdr_dout  (sdr_prg_dout),
		.sdr_req   (sdr_prg_req),
		.sdr_ack   (sdr_prg_ack),

		.io_addr   (io_addr),
		.io_wdata  (io_wdata),
		.io_be     (io_be),
		.io_wr     (io_wr),
		.io_rd     (io_rd),
		.io_rdata  (io_rdata),

		.dbg_wr_spr(),
		.dbg_wr_tm (),
		.dma_req   (dma_req),
		.dma_gnt   (dma_gnt),
		.dma_addr  (dma_addr),
		.dma_dout  (dma_dout),

		.dbg_why   (),
		.dbg_eip   (),
		.dbg_cs    (),
		.dbg_idt_base  (),
		.dbg_idt_limit (),
		.dbg_cs_base   (),
		.dbg_cr0       (),
		.dbg_ss_base   (ss_dbg_ss_base),
		.dbg_ss_limit  (ss_dbg_ss_limit),
		.dbg_ss_type   (ss_dbg_ss_type),
		.dbg_ss_g      (ss_dbg_ss_g),
		.dbg_irq   (p_cpu_irq),
		.dbg_gdt0(), .dbg_gdt1(),
		.dbg_gdt2(), .dbg_gdt3(),
		.dbg_gdt4(), .dbg_gdt5(),

		.ss_save_req (ss_cpu_save),
		.ss_restore_req (ss_cpu_restore),
		.ss_esp_in   (ss_esp_scratch),
		.ss_snapshot (ss_snapshot),
		.ss_hold_rel (ss_cpu_hold_rel),
		.ss_esp_out  (ss_esp_out),
		.ss_ram_own  (ss_ram_own),
		.ss_ram_addr (ss_ram_addr),
		.ss_ram_din  (ss_ram_din),
		.ss_ram_we   (ss_ram_we),
		.ss_ram_dout (ss_ram_dout),
		.ss_inval    (ss_inval),
		.ss_inval_set(ss_inval_set),

		.ss_in_stub  (ss_in_stub),
		.ss_writes   (ss_writes),
		.ss_last_wa  (ss_last_wa),
		.ss_last_wd  (ss_last_wd),
		.ss_idle           (ss_cpu_idle),
		.ss_dbg_state      (ss_dbg_state),
		.ss_dbg_nmi        (ss_dbg_nmi),
		.ss_dbg_gate_dw0   (ss_dbg_gate_dw0),
		.ss_dbg_gate_reads (ss_dbg_gate_reads),
		.ss_dbg_hold       (ss_dbg_hold),
		.ss_dbg_stub_reads (ss_dbg_stub_reads),
		.ss_dbg_stub_idx   (ss_dbg_stub_idx),
		.ss_dbg_stub_data  (ss_dbg_stub_data),
		.ss_dbg_resume_eip (ss_dbg_resume_eip),
		.ss_dma_busy       (ss_dma_busy),
		.ss_irq_din        (irq_ss_din),
		.ss_irq_we         (irq_ss_we),
		.ss_irq_dout       (irq_ss_dout),

		.vbl_toggle (vbl_toggle)
	);

	// ------------------------------------------------------------------
	// I/O registers
	// ------------------------------------------------------------------
	// layer_enable is active LOW per MAME (0 = layer shown). The host used to be
	// able to force a layer off over JTAG (dbg_mask[4:0]); that went with the
	// instrumentation, so the game's own register is the only source now.
	wire  [4:0] layer_enable;

	// spi_io runs on clk_cpu and every one of these feeds the clk_sys video
	// logic, so they all cross domains. Left raw, layer_enable reached deep into
	// the mixer's combinational blend chain and failed setup by 6.4 ns. They are
	// slow control registers -- the game rewrites them once a frame -- so a two
	// flop synchroniser is both correct and enough. Register them once here
	// rather than at each consumer.
	reg  [4:0] lay_en_s1, lay_en_s2;
	reg  [1:0] rs_en_s, fd13_s;
	reg  [2:0] bank_s1, bank_s2;
	always @(posedge clk_sys) begin
		lay_en_s1 <= layer_enable;  lay_en_s2 <= lay_en_s1;
		rs_en_s   <= {rs_en_s[0], rowscroll_enable};
		fd13_s    <= {fd13_s[0],  fore_layer_d13};
		bank_s1   <= rf2_layer_bank; bank_s2 <= bank_s1;
	end
	wire       rowscroll_en_s = rs_en_s[1];
	wire       fore_d13_s     = fd13_s[1];

	wire        rowscroll_enable, fore_layer_d13;
	wire  [2:0] rf2_layer_bank;
	wire [15:0] scroll_bx, scroll_by, scroll_mx, scroll_my, scroll_fx, scroll_fy;
	wire [17:0] dma_src;
	wire [15:0] dma_len;
	wire        dma_tilemap, dma_palette, dma_sprite;
	wire  [7:0] sndfifo_din;
	wire        sndfifo_wr, coin_latch_rd;

	// The I/O register file is written by the 386, so it lives in the CPU domain.
	// Its outputs are stable register values read by clk_sys logic; both clocks
	// come from the same PLL and sit in the same clock group, so TimeQuest
	// analyses those transfers normally.
	assign p_io_rd    = io_rd;
	assign p_io_raddr = io_addr;
	assign p_io_rdata = io_rdata;

	spi_io io
	(
		.set_sxx2c  (set_sxx2c),
		.fifo2_q    (fifo2_q),
		.fifo2_empty(fifo2_empty),
		.fifo2_rd   (fifo2_rd),
		.z80dl_addr (z80dl_addr),
		.z80dl_data (z80dl_data),
		.z80dl_req  (z80dl_req),
		.z80dl_ack  (z80dl_ack),
		.z80dl_stall(z80dl_stall),
		.z80dl_end  (z80dl_end),
		.z80_rst_n  (z80_rst_n),
		.ss_addr    (io_ss_addr),
		.ss_din     (io_ss_din),
		.ss_we      (io_ss_we),
		.ss_dout    (io_ss_dout),
		.clk              (clk_cpu),
		.reset            (cpu_reset),

		.addr             (io_addr),
		.wdata            (io_wdata),
		.be               (io_be),
		.wr               (io_wr),
		.rd               (io_rd),
		.rdata            (io_rdata),

		.inputs           (inputs),
		.system           (system),

		.layer_enable     (layer_enable),
		.rowscroll_enable (rowscroll_enable),
		.fore_layer_d13   (fore_layer_d13),
		.rf2_layer_bank   (rf2_layer_bank),
		.scroll_bx        (scroll_bx),
		.scroll_by        (scroll_by),
		.scroll_mx        (scroll_mx),
		.scroll_my        (scroll_my),
		.scroll_fx        (scroll_fx),
		.scroll_fy        (scroll_fy),

		.dma_src          (dma_src),
		.dma_len          (dma_len),
		.dma_tilemap      (dma_tilemap),
		.dma_palette      (dma_palette),
		.dma_sprite       (dma_sprite),

		.sndfifo_din      (sndfifo_din),
		.sndfifo_wr       (sndfifo_wr),
		.sndfifo_full     (sndfifo_full),
		.coin_latch       (coin_latch),
		.coin_latch_rd    (coin_latch_rd),

		.ds_req           (ds_req),
		.ds_port          (ds_port),
		.ds_data          (ds_data),
		.ds_ack           (ds_ack),
		.ds_dout          (ds_dout),
		.ds_stall         (ds_stall)
	);

	// ------------------------------------------------------------------
	// The DS2404: an RTC and 512 bytes of battery-backed SRAM, which is where
	// the games keep their bookkeeping. It answered zeros until now.
	//
	// On clk_ram rather than clk_cpu with the rest of the I/O, because its SRAM
	// is the tail of the save file and the save side of MiSTer's nvram cannot be
	// stalled. The 386 is the side that crosses, and spi_io holds it off with
	// ds_stall while a byte is in flight. See spi_ds2404.sv.
	// ------------------------------------------------------------------
	// The DS2404's freeze, registered in clk_sys before it crosses. See the
	// .pause connection below for why it is gated on the snapshot at all.
	reg        ds_pause;
	always @(posedge clk_sys) ds_pause <= ss_pause && ss_snapshot;

	wire       ds_req, ds_ack, ds_stall;
	wire [1:0] ds_port;
	wire [7:0] ds_data, ds_dout;

	spi_ds2404 ds2404
	(
		// clk_ram, so this level crosses from clk_sys into a FASTER clock --
		// which is the easy direction: a level held for a clk_sys cycle is
		// sampled twice here rather than missed.
		//
		// GATED ON THE SNAPSHOT, not on ss_pause alone, and this is load-bearing
		// (PLAN.md 43). spi_ds2404's `if (pause)` is the first branch of a chain
		// that also covers `req_edge`, so while it is asserted a request from
		// the 386 is not delayed -- it is never seen, and `ack` never comes. On
		// a LOAD, pause asserts while the 386 is STILL RUNNING (it has to run,
		// to walk to the stub), so it can issue a DS2404 access into a chip that
		// has stopped listening. spi_io then holds `ds_stall`, spi_top ORs it
		// into `io_stall`, spi_cpu's `mem_accept` is gated on `!io_stall`, and
		// the CPU can never reach the instruction boundary where it would take
		// the NMI. Measured, not deduced: the wedge reads `io=1 ds=1` with
		// ss_hold=0 and the CPU parked at 0x600 forever.
		//
		// Waiting for the snapshot is SAFE rather than merely later: `io_stall`
		// is exactly what holds the 386 off an instruction boundary while a byte
		// is in flight, so by construction nothing is in flight at the moment it
		// freezes. And the chip only has to be still while the blob is read or
		// written, which is from the snapshot onward -- 40.5's tick_cnt hold
		// still sees `pause` throughout a restore, because the writes land in
		// S_STREAMING with the CPU frozen.
		//
		// REGISTERED, and that is not tidiness. Doing the AND combinationally
		// here failed the fit at -0.077 on clk_ram: `ss_snapshot` comes from
		// spi_cpu on clk_cpu, so the gate put two domains' logic in front of a
		// crossing into the FASTER clock. 31.7 hit the same endpoint the same
		// way and answered it the same way. One flop in clk_sys, then a single
		// level crosses, exactly as bare `ss_pause` did before.
		.pause    (ds_pause),
		.dbg_rtc     (p_ds_rtc),
		.dbg_tick    (p_ds_tick),
		.ss_addr     (ds_ss_addr),
		.ss_din      (ds_ss_din),
		.ss_we       (ds_ss_we),
		.ss_dout     (ds_ss_dout),
		.ss_ram_addr (ds_ram_addr),
		.ss_ram_din  (ds_ram_din),
		.ss_ram_we   (ds_ram_we),
		.ss_ram_dout (ds_ram_dout),
		.clk      (clk_ram),
		.reset    (reset),

		.req      (ds_req),
		.port     (ds_port),
		.din      (ds_data),
		.ack      (ds_ack),
		.dout     (ds_dout),

		.nv_addr  (ds_nv_addr),
		.nv_din   (ds_nv_din),
		.nv_we    (ds_nv_we),
		.nv_dout  (ds_nv_dout),
		.nv_dirty (ds_nv_dirty)
	);

	// ------------------------------------------------------------------
	// Sound: Z80 + YMF271
	//
	// It runs on clk_sys while spi_io runs on clk_cpu, so the two signals
	// crossing into it are handled inside spi_sound: sndfifo_wr is a one-cycle
	// clk_cpu pulse (two clk_sys cycles, edge detected there) and coin_latch_rd
	// the same. coin_latch itself is a settled register read the other way.
	// ------------------------------------------------------------------
	wire [7:0]  coin_latch;
	wire        sndfifo_full;
	wire [15:0] snd_audio_l, snd_audio_r;

	spi_sound sound
	(
		.pause      (ss_pause),
		.ssbus_z80    (ssb[SSIDX_Z80]),
		.ssbus_z80ram (ssb[SSIDX_Z80_RAM]),
		.ssbus_fifo   (ssb[SSIDX_SND_FIFO]),
		.ssbus_fifo2  (ssb[SSIDX_SND_FIFO2]),
		.ssbus_regs   (ssb[SSIDX_SND_REGS]),
		.ssbus_ymf_regs (ssb[SSIDX_YMF_REGS]),
		.ssbus_ymf_par  (ssb[SSIDX_YMF_PAR]),
		.ssbus_ymf_st   (ssb[SSIDX_YMF_ST]),
		.ssbus_ymf_fb   (ssb[SSIDX_YMF_FB]),
		.set_sxx2c  (set_sxx2c),
		.jumpers    (jumpers),
		.fifo2_q    (fifo2_q),
		.fifo2_empty(fifo2_empty),
		.fifo2_rd   (fifo2_rd),
		.z80_rst_n  (z80_rst_n),
		.z80dl_end  (z80dl_end),
		.dbg_f2_wr  (),
		.dbg_f2_rd  (),
		.clk        (clk_sys),
		.reset      (vid_reset),

		.snd_din    (sndfifo_din),
		.snd_wr     (sndfifo_wr),
		.snd_full   (sndfifo_full),
		.coin_rd    (coin_latch_rd),
		.coin_latch (coin_latch),
		.coin       (coin),

		.sdr_addr   (sdr_z80_addr),
		.sdr_dout   (sdr_z80_dout),
		.sdr_req    (sdr_z80_req),
		.sdr_ack    (sdr_z80_ack),

		.pcm_addr   (sdr_pcm_addr),
		.pcm_dout   (sdr_pcm_dout),
		.pcm_req    (sdr_pcm_req),
		.pcm_ack    (sdr_pcm_ack),

		// Only an authentic-flash MRA has flash where the samples live; every
		// other configuration leaves this inert.
		.flash_en         (set_upd),
		.flash_sdr_addr   (flash_sdr_addr),
		.flash_sdr_din    (flash_sdr_din),
		.flash_sdr_be     (flash_sdr_be),
		.flash_sdr_req    (flash_sdr_req),
		.flash_sdr_ack    (flash_sdr_ack),
		.flash_dirty_o    (flash_dirty),
		// The flash and FIFO watches (PLAN.md 19.11, 19.14). Unconnected: the
		// counters have no fanout now and synthesis drops them.
		.dbg_flash_w_progs    (),
		.dbg_flash_w_be       (),
		.dbg_flash_w_data     (),
		.dbg_flash_w_erases   (),
		.dbg_flash_w_er_after (),
		.dbg_flash_w_trace    (),
		.dbg_fw_pushes (),
		.dbg_fw_pops   (),
		.dbg_fw_fill   (),
		.dbg_fw_empty  (),
		.dbg_fw_din    (),
		.dbg_fw_frozen (),
		.dbg_flash_progs  (),
		.dbg_flash_erases (),
		.dbg_flash_drops  (),
		.dbg_flash_busy   (),

		.audio_l    (snd_audio_l),
		.audio_r    (snd_audio_r),

		.dbg_z80_pc      (),
		.dbg_fifo_rd     (),
		.dbg_ymf_wr      (),
		.dbg_stall       (),
		.dbg_ymf_overrun (),
		.dbg_ymf_active  (),
		.dbg_fifo_peak   (),
		.dbg_full_max    (),
		.dbg_wait_max    ()
	);

	// ------------------------------------------------------------------
	// Savestates: the section fan-out, and the sequencer
	//
	// One ssbus_if per section, muxed onto the single bus save_state_data
	// drives. Every section this core has is inside the board, so the mux lives
	// here rather than at the top level as it does in Arcade-IGSPGM.
	// ------------------------------------------------------------------
	ssbus_if ssb[SSIDX_COUNT]();

	ssbus_mux #(.COUNT(SSIDX_COUNT)) ss_mux
	(
		.clk    (clk_sys),
		.slave  (ssbus),
		.masters(ssb)
	);

	wire        ss_cpu_save, ss_cpu_restore, ss_cpu_hold_rel;
	wire [31:0] ss_esp_scratch;
	wire        ss_dma_busy;

	// THE BOARD-WIDE PAUSE, and it is what makes a save state correct rather
	// than merely possible.
	//
	// Freezing only the 386 -- which is all `freeze` does, and all the first
	// version of this did -- is not enough. A transfer takes about 14 ms, and
	// in that time the raster, the sound board and the vblank interrupt all run
	// on, so the 386 comes back into a machine that has moved without it.
	// Measured: a save taken while rdfts drives its display loop left the run
	// with 1,567 I/O writes against a baseline 1,569 and a different main RAM
	// hash, while the same save taken at a quiet point in boot was
	// bit-identical. No vblank was lost in the window -- it is the raster phase,
	// not the interrupt count.
	//
	// This is deliberately NOT wired to `freeze`. That is the Pause button, and
	// STATUS.md documents its behaviour as stopping the 386 alone so a frozen
	// frame stays on screen to be studied -- which is the opposite of what a
	// save state wants and a useful thing to keep.
	wire        ss_pause;      // driven by spi_ss, below
	assign ss_dbg_esp_scratch = ss_esp_scratch;
	wire        ss_ram_own, ss_ram_we;
	wire [15:0] ss_ram_addr;
	wire [31:0] ss_ram_din, ss_ram_dout;
	wire        ss_inval;
	wire  [7:0] ss_inval_set;

	spi_ss ss
	(
		.clk             (clk_sys),
		.reset           (sys_reset),

		.ss_save         (ss_save),
		.ss_load         (ss_load),
		.vbl_next        (vbl_next),
		.pause           (ss_pause),
		.dbg_st          (ss_dbg_st),
		.cpu_ss_idle     (ss_cpu_idle),
		.cpu_in_stub     (ss_in_stub),

		.stream_write    (ss_stream_write),
		.stream_read     (ss_stream_read),
		.stream_busy     (ss_stream_busy),

		.ssbus_global    (ssb[SSIDX_GLOBAL]),
		.ssbus_mainram   (ssb[SSIDX_MAIN_RAM]),

		.cpu_save_req    (ss_cpu_save),
		.cpu_restore_req (ss_cpu_restore),
		.cpu_snapshot    (ss_snapshot),
		.cpu_hold_rel    (ss_cpu_hold_rel),
		.cpu_esp         (ss_esp_out),
		.cpu_dma_busy    (ss_dma_busy),
		.cpu_esp_out     (ss_esp_scratch),

		.ram_own         (ss_ram_own),
		.ram_addr        (ss_ram_addr),
		.ram_din         (ss_ram_din),
		.ram_we          (ss_ram_we),
		.ram_dout        (ss_ram_dout),

		.inval           (ss_inval),
		.inval_set       (ss_inval_set),

		.busy            (ss_busy)
	);

	// The raster used to be a section here. It is not saved at all now: a
	// transfer starts and ends at `vbl_next`, so the phase is re-acquired
	// rather than carried, and the counters are never written from outside.
	// PLAN.md 42, and rtl/system_consts.sv says the same thing where the index
	// used to be.
	wire        vbl_next;

	// SSIDX_SPI_IO, through the same bridge as main RAM: spi_io is clk_cpu and
	// the ssbus is clk_sys.
	wire  [4:0] io_ss_addr;
	wire [31:0] io_ss_din, io_ss_dout;
	wire        io_ss_we;

	spi_ss_bridge #(
		.SS_IDX (SSIDX_SPI_IO),
		.AW     (5),
		.DW     (32),
		.ITEMS  (26)
	) io_bridge (
		.clk      (clk_sys),
		.ssbus    (ssb[SSIDX_SPI_IO]),
		.ram_addr (io_ss_addr),
		.ram_din  (io_ss_din),
		.ram_we   (io_ss_we),
		.ram_dout (io_ss_dout)
	);

	// SSIDX_CPU_IRQ: one dword, and the same bridge as everything else that has
	// to reach into clk_cpu.
	wire [31:0] irq_ss_din, irq_ss_dout;
	wire        irq_ss_we;
	/* verilator lint_off PINCONNECTEMPTY */
	spi_ss_bridge #(.SS_IDX(SSIDX_CPU_IRQ), .AW(1), .DW(32), .ITEMS(1))
	irq_bridge (
		.clk      (clk_sys),
		.ssbus    (ssb[SSIDX_CPU_IRQ]),
		.ram_addr (),
		.ram_din  (irq_ss_din),
		.ram_we   (irq_ss_we),
		.ram_dout (irq_ss_dout)
	);
	/* verilator lint_on PINCONNECTEMPTY */

	// The DS2404's two sections. It is clk_ram, faster than the ssbus's
	// clk_sys, so the bridge's hold discipline is generous here rather than
	// tight -- but it is the same bridge, because a fourth hand-rolled crossing
	// is how the last one went wrong.
	wire  [3:0] ds_ss_addr;
	wire [31:0] ds_ss_din, ds_ss_dout;
	wire        ds_ss_we;
	wire  [8:0] ds_ram_addr;
	wire  [7:0] ds_ram_din, ds_ram_dout;
	wire        ds_ram_we;

	spi_ss_bridge #(.SS_IDX(SSIDX_DS2404), .AW(4), .DW(32), .ITEMS(16))
	ds_bridge (
		.clk (clk_sys), .ssbus (ssb[SSIDX_DS2404]),
		.ram_addr (ds_ss_addr), .ram_din (ds_ss_din),
		.ram_we (ds_ss_we), .ram_dout (ds_ss_dout));

	spi_ss_bridge #(.SS_IDX(SSIDX_DS2404_RAM), .AW(9), .DW(8), .ITEMS(512))
	ds_ram_bridge (
		.clk (clk_sys), .ssbus (ssb[SSIDX_DS2404_RAM]),
		.ram_addr (ds_ram_addr), .ram_din (ds_ram_din),
		.ram_we (ds_ram_we), .ram_dout (ds_ram_dout));

	// ------------------------------------------------------------------
	// Video RAMs
	//
	// Each of the three is a savestate section. The write side is clk_cpu and
	// the read side clk_sys, so the savestate reaches them through
	// spi_ss_bridge on the write side -- WR_ONLY, because the read it needs is
	// the video side's own port, taken below. Nothing here gains a port.
	// ------------------------------------------------------------------
	wire [11:0] tm_wa;   wire [31:0] tm_wd;   wire tm_we;
	wire [11:0] pal_wa;  wire [29:0] pal_wd;  wire pal_we;
	wire  [9:0] spr_wa;  wire [31:0] spr_wd;  wire spr_we;

	wire [11:0] tm_ra;   wire [31:0] tm_rd;
	wire [11:0] pal_ra;  wire [29:0] pal_rd;

	// The savestate's side of each of the three, and the muxes that let it in.
	wire [11:0] ss_tm_ra,  ss_tm_wa;   wire [31:0] ss_tm_wd;
	wire [11:0] ss_pal_ra, ss_pal_wa;  wire [29:0] ss_pal_wd;
	wire  [9:0] ss_spr_wa;             wire [31:0] ss_spr_wd;
	wire        ss_tm_rdown, ss_pal_rdown, ss_spr_rdown;
	wire        ss_tm_we, ss_pal_we, ss_spr_we;
	// The sprite RAM has no read port of its own here -- spi_sprite reads it
	// through spr_ra below -- so its savestate read address joins that mux too.
	wire  [9:0] ss_spr_ra;

	spi_ss_vram #(.SS_IDX(SSIDX_TILEMAP_RAM), .AW(12), .DW(32), .ITEMS(4096))
	ss_tilemap (
		.clk(clk_sys), .ssbus(ssb[SSIDX_TILEMAP_RAM]),
		.rd_own(ss_tm_rdown), .rd_addr(ss_tm_ra), .rd_data(tm_rd),
		.wr_addr(ss_tm_wa), .wr_data(ss_tm_wd), .wr_en(ss_tm_we));

	spi_ss_vram #(.SS_IDX(SSIDX_PALETTE_RAM), .AW(12), .DW(30), .ITEMS(4096))
	ss_palette (
		.clk(clk_sys), .ssbus(ssb[SSIDX_PALETTE_RAM]),
		.rd_own(ss_pal_rdown), .rd_addr(ss_pal_ra), .rd_data(pal_rd),
		.wr_addr(ss_pal_wa), .wr_data(ss_pal_wd), .wr_en(ss_pal_we));

	spi_ss_vram #(.SS_IDX(SSIDX_SPRITE_RAM), .AW(10), .DW(32), .ITEMS(1024))
	ss_sprite (
		.clk(clk_sys), .ssbus(ssb[SSIDX_SPRITE_RAM]),
		.rd_own(ss_spr_rdown), .rd_addr(ss_spr_ra), .rd_data(spr_rd),
		.wr_addr(ss_spr_wa), .wr_data(ss_spr_wd), .wr_en(ss_spr_we));

	spi_dpram #(.DW(32), .AW(12)) tilemap_ram
		(.wr_clk(clk_cpu), .rd_clk(clk_sys),
		 .wr_addr(ss_tm_we ? ss_tm_wa : tm_wa),
		 .wr_data(ss_tm_we ? ss_tm_wd : tm_wd),
		 .wr_en  (ss_tm_we | tm_we),
		 .rd_addr(ss_tm_rdown ? ss_tm_ra : tm_ra),
		 .rd_data(tm_rd));

	spi_dpram #(.DW(30), .AW(12)) palette_ram
		(.wr_clk(clk_cpu), .rd_clk(clk_sys),
		 .wr_addr(ss_pal_we ? ss_pal_wa : pal_wa),
		 .wr_data(ss_pal_we ? ss_pal_wd : pal_wd),
		 .wr_en  (ss_pal_we | pal_we),
		 .rd_addr(ss_pal_rdown ? ss_pal_ra : pal_ra),
		 .rd_data(pal_rd));

	wire  [9:0] spr_ra;
	wire [31:0] spr_rd;
	spi_dpram #(.DW(32), .AW(10)) sprite_ram
		(.wr_clk(clk_cpu), .rd_clk(clk_sys),
		 .wr_addr(ss_spr_we ? ss_spr_wa : spr_wa),
		 .wr_data(ss_spr_we ? ss_spr_wd : spr_wd),
		 .wr_en  (ss_spr_we | spr_we),
		 .rd_addr(ss_spr_rdown ? ss_spr_ra : spr_ra),
		 .rd_data(spr_rd));

	// ------------------------------------------------------------------
	// Video DMA
	// ------------------------------------------------------------------
	wire dma_busy;

	spi_dma dma
	(
		.clk              (clk_cpu),
		.reset            (cpu_reset),
		.trig_tilemap     (dma_tilemap),
		.trig_palette     (dma_palette),
		.trig_sprite      (dma_sprite),
		.dma_src          (dma_src[17:2]),
		.dma_len          (dma_len),
		.rowscroll_enable (rowscroll_enable),
		.ram_req          (dma_req),
		.ram_gnt          (dma_gnt),
		.ram_addr         (dma_addr),
		.ram_data         (dma_dout),
		.tm_addr          (tm_wa),  .tm_data (tm_wd),  .tm_we (tm_we),
		.pal_addr         (pal_wa), .pal_data(pal_wd), .pal_we(pal_we),
		.spr_addr         (spr_wa), .spr_data(spr_wd), .spr_we(spr_we),
		.busy             (dma_busy),
		.dbg_text_dwords  (),
		.dbg_src_spr      (),
		.dbg_tm_dwords    ()
	);

	// ------------------------------------------------------------------
	// Tile layers
	//
	// Two things here are per GAME rather than per board.
	//
	// bg_fore_pos is the fore layer's tile base and it follows the SIZE of the
	// tile region (seibuspi_v.cpp:585): 0x2000 up to 3 MB, 0x4000 up to 6 MB,
	// 0x8000 beyond. rdfts and rdft have exactly 0x600000 of tiles; rdft2 has
	// 0xC00000 and rfjet 0x900000, and both of those need the 16th code bit.
	// Note it is the REGION length that decides, not the game -- rfjet's 9 MB
	// is nothing like rdft2's 12 and lands in the same bracket.
	//
	// The decryption keys are simply per game. The same triple does text and
	// background -- MAME's text_decrypt and bg_decrypt take the same three
	// constants -- so one selection covers both layers.
	// ------------------------------------------------------------------
	wire big_tiles = (set_id == SET_RDFT2) || (set_id == SET_RFJET);
	wire [15:0] bg_fore_pos = big_tiles ? 16'h8000 : 16'h4000;

	reg [23:0] tkey1, tkey2, tkey3;
	always @* case (set_id)
		SET_RDFT2: begin tkey1 = TKEY1_RDFT2;  tkey2 = TKEY2_RDFT2;  tkey3 = TKEY3_RDFT2;  end
		SET_RFJET: begin tkey1 = TKEY1_RFJET;  tkey2 = TKEY2_RFJET;  tkey3 = TKEY3_RFJET;  end
		default:   begin tkey1 = TKEY1_SEI252; tkey2 = TKEY2_SEI252; tkey3 = TKEY3_SEI252; end
	endcase

	// Lead the line-buffer read by one pixel: the mixer's composite is only
	// stable a pixel after its palette lookups finish.
	// The mixer's palette sequence and composite take two pixel-times, so the
	// line buffer is read two pixels ahead. Past the end of a line that wraps
	// into the next line's buffer, which lb_wrap selects; that buffer is
	// already complete, since the renderer finishes well before hblank ends.
	wire [9:0] lb_nx   = hcnt + 10'd2;
	wire       lb_wrap = (lb_nx >= 10'd448);
	wire [8:0] lb_x    = lb_wrap ? 9'(lb_nx - 10'd448) : lb_nx[8:0];
	wire       lb_bank;
	wire [9:0] lb_back, lb_midl, lb_fore, lb_text;
	wire       layers_busy;

	spi_layers layers
	(
		.clk              (clk_sys),
		.reset            (vid_reset),
		.vcnt             (vcnt),
		.line_start       (line_start),

		.scroll_bx        (scroll_bx), .scroll_by(scroll_by),
		.scroll_mx        (scroll_mx), .scroll_my(scroll_my),
		.scroll_fx        (scroll_fx), .scroll_fy(scroll_fy),
		.rowscroll_enable (rowscroll_en_s),
		.layer_off        (lay_en_s2[3:0]),
		.fore_layer_d13   (fore_d13_s),
		.rf2_layer_bank   (bank_s2),
		.bg_fore_pos      (bg_fore_pos),
		.tkey1            (tkey1),
		.tkey2            (tkey2),
		.tkey3            (tkey3),

		.tm_addr          (tm_ra),
		.tm_data          (tm_rd),

		.sdr_addr         (sdr_gfx_addr),
		.sdr_dout         (sdr_gfx_dout),
		.sdr_req          (sdr_gfx_req),
		.sdr_ack          (sdr_gfx_ack),

		.lb_x             (lb_x),
		.lb_wrap          (lb_wrap),
		.lb_bank          (lb_bank),
		.lb_back          (lb_back),
		.lb_midl          (lb_midl),
		.lb_fore          (lb_fore),
		.lb_text          (lb_text),

		.busy             (layers_busy),

		// Debug taps, used only by sim/tb_video.
		.dbg_layer        (),
		.dbg_tcode        (),
		.dbg_gfx_addr     (),
		.dbg_emit         (),
		.dbg_busy         (),
		.dbg_rowscroll    (),
		.dbg_xstart       (),
		.dbg_latch        (),
		.dbg_finex        (),
		.dbg_col          (),
		.dbg_emitx        (),
		.dbg_pix          (),
		.dbg_emiti        (),
		.dbg_overruns     (),
		.dbg_ovr_layer    (),
		.dbg_text_col     ()
	);

	// ------------------------------------------------------------------
	// Sprite engine. Runs on SDRAM channel 4, so it does not compete with the
	// tile layers for the line budget.
	// ------------------------------------------------------------------
	wire [14:0] lb_spr;
	wire        spr_busy;

	// Three crypts over three chunk sizes, and the two are selected separately
	// rather than from one flag because they do not have to agree: rdft2us pairs
	// RISE10 with a different board. The chunk size is no longer an address
	// stride -- the loader interleaves the chunks -- it is what MAME's
	// extra-bank rule counts tiles with.
	//
	//   rdfts / rdft   SEI252, 4 MB chunks
	//   rdft2          RISE10, 6 MB
	//   rfjet          RISE11, 8 MB
	//
	// pcmsrc_base above is selected on exactly these arms, because the PCM
	// source is loaded immediately after the sprites -- change one and the
	// other has to move with it.
	wire        spr_rise10 = (set_id == SET_RDFT2);
	wire        spr_rise11 = (set_id == SET_RFJET);
	reg  [25:0] spr_chunk;
	always @* case (set_id)
		SET_RDFT2: spr_chunk = SPR_CHUNK_SIZE_RDFT2;
		SET_RFJET: spr_chunk = SPR_CHUNK_SIZE_RFJET;
		default:   spr_chunk = SPR_CHUNK_SIZE;
	endcase

	spi_sprite sprites
	(
		.clk        (clk_sys),
		.reset      (vid_reset),
		.vcnt       (vcnt),
		.line_start (line_start),
		.enable     (~lay_en_s2[4]),
		.spr_chunk_size(spr_chunk),
		.rise10     (spr_rise10),
		.rise11     (spr_rise11),
		.spr_addr   (spr_ra),
		.spr_data   (spr_rd),
		.sdr_addr   (sdr_spr_addr),
		.sdr_dout   (sdr_spr_dout),
		.sdr_req    (sdr_spr_req),
		.sdr_ack    (sdr_spr_ack),
		.lb_x       (lb_x),
		.lb_wrap    (lb_wrap),
		.lb_out     (lb_spr),
		.busy       (spr_busy),
		.dbg_we     (),
		.dbg_state  (),
		.dbg_index  (),
		.dbg_pix    (),
		.dbg_emitx  (),
		.dbg_tile_code(), .dbg_ry(), .dbg_px(),
		.dbg_scanned(),
		.dbg_yhit   (),
		.dbg_emitted(),
		.dbg_starved(),
		.dbg_codes_nz(),
		.dbg_spr_or(),
		.dbg_tiles  (),
		.dbg_code   (),
		.dbg_sx     (),
		.dbg_sy     ()
	);

	// ------------------------------------------------------------------
	// Mixer
	//
	// All five inputs are live: the four tile layer buffers out of spi_layers
	// and the sprite buffer out of spi_sprite above. Both modules follow the
	// same convention -- write the line being rendered at {render_bank, x},
	// serve the displayed pixel from the other bank (lb_wrap picks
	// render_bank for the tail that belongs to the next line). spi_sprite
	// once wrote the inverted bank, so it rendered into the buffer being
	// displayed, cleared it at the next line start, and the mixer never saw
	// a valid sprite pixel; see spi_sprite.sv around lb_wr_addr.
	// ------------------------------------------------------------------
	spi_mixer mixer
	(
		.clk          (clk_sys),
		.reset        (vid_reset),
		.ce_pix       (ce_pix),
		.layer_enable (lay_en_s2),
		.lb_back      (lb_back),
		.lb_midl      (lb_midl),
		.lb_fore      (lb_fore),
		.lb_text      (lb_text),
		.lb_spr       (lb_spr),
		.pal_addr     (pal_ra),
		.pal_data     (pal_rd),
		.red          (mix_r),
		.green        (mix_g),
		.blue         (mix_b)
	);

	// ------------------------------------------------------------------
	// Video out
	//
	// This used to be a mux: `panel ? dbg_r : mix_r`, with the vital signs panel
	// REPLACING the picture when its OSD option was on. The panel, the event
	// counters that fed it, the sprite-DMA gap watch and the EIP profiler were
	// all instrumentation and are gone from the net -- rtl/spi_debug.sv is still
	// in the repo, just not instantiated. PLAN.md 29.
	// ------------------------------------------------------------------
	wire [7:0] mix_r, mix_g, mix_b;

	// ------------------------------------------------------------------
	// WEDGE OVERLAY -- diagnostic, PLAN.md 45.
	//
	// The rapid-reload lockup only happens on hardware, four candidate fixes
	// have missed, and there is no probe on the board since 35 deleted the JTAG
	// modules. So the wedge reports itself: if a savestate stays busy far longer
	// than any real operation, paint its state across the top of the picture as
	// a row of blocks, white for 1. A screenshot then says exactly what is
	// stuck, which is what solved the same class of bug in simulation (43.1).
	//
	// A save is ~2.1 M clk_sys cycles and a load ~1.3 M. This trips at 2^23,
	// 8.4 M, about 146 ms -- four times the longest real operation.
	// ------------------------------------------------------------------
	wire  [4:0] ss_dbg_st;
	assign ss_dbg_seq = ss_dbg_st;
	wire        ss_cpu_idle;
	reg  [23:0] ss_stuck_cnt;
	always @(posedge clk_sys) begin
		if (sys_reset || !ss_busy) ss_stuck_cnt <= 24'd0;
		else if (!ss_stuck_cnt[23]) ss_stuck_cnt <= ss_stuck_cnt + 24'd1;
	end
	wire ss_wedged = ss_stuck_cnt[23];

	// The bits, LSB first across the screen:
	//   0..3 spi_ss state   4 is_load       5 pause
	//   6 io_stall          7 z80dl_stall   8 ds_stall
	//   9 cpu snapshot     10 cpu in stub
	wire [10:0] ss_dbg_bits = {ss_in_stub, ss_snapshot,
	                           ss_dbg_stalls[0], ss_dbg_stalls[1],
	                           ss_dbg_stalls[2], ss_pause, ss_dbg_st};

	// Rows 16..31, one 16-pixel block per bit starting at column 16. A red block
	// at column 0 says the overlay is live, so a screenshot without it means the
	// core is not wedged rather than that the probe failed.
	wire dbg_row  = ss_wedged && (vcnt >= 10'd16) && (vcnt < 10'd32);
	wire dbg_mark = dbg_row && (hcnt < 10'd16);
	wire dbg_cell = dbg_row && (hcnt >= 10'd16) && (hcnt < 10'd16 + 11*10'd16);
	/* verilator lint_off UNUSEDSIGNAL */
	wire [9:0] dbg_off = hcnt - 10'd16;   // only [7:4] selects the block
	/* verilator lint_on UNUSEDSIGNAL */
	wire [3:0] dbg_idx = dbg_off[7:4];
	wire dbg_bit  = ss_dbg_bits[dbg_idx];

	assign red   = dbg_mark ? 8'hFF : dbg_cell ? (dbg_bit ? 8'hFF : 8'h10) : mix_r;
	assign green = dbg_mark ? 8'h00 : dbg_cell ? (dbg_bit ? 8'hFF : 8'h10) : mix_g;
	assign blue  = dbg_mark ? 8'h00 : dbg_cell ? (dbg_bit ? 8'hFF : 8'h40) : mix_b;

	// SXX2E is a mono board: the YMF271's four outputs are summed onto one
	// speaker, so both sides carry the same sample.
	// Both sides come from the synth already: it hands back the same mono
	// sample on each when the board is a single PCB. Duplicating here instead
	// would have to know the board too, and then two places would.
	assign audio_l = snd_audio_l;
	assign audio_r = snd_audio_r;

	// Signals not yet consumed; each disappears as its block lands.
	wire _unused = &{1'b0, clk_ram, dma_busy, layers_busy, spr_busy,
	                 hcnt[9], dma_src[1:0], lb_bank};

endmodule
