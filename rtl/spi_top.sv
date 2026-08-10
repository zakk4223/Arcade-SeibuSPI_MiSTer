//============================================================================
//  SlopperPI - Seibu SPI / SXX2E
//
//  Board top: 386 + video + sound + I/O.
//
//  T3 state: the raster, the 386 subsystem and the I/O register file are in
//  place. The video pipelines (T4) and sound (T5) are still to come.
//============================================================================

module spi_top
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
	input       [1:0] set_id,
	input       [7:0] jumpers,
	// Z80 program download -> SDRAM ch3 write port
	output     [25:0] z80dl_sdr_addr,
	output     [15:0] z80dl_sdr_din,
	output      [1:0] z80dl_sdr_be,
	output            z80dl_sdr_req,
	input             z80dl_sdr_ack,
	input             dbg_en,
	input       [3:0] chk_ok,
	input             chk_done,
	// [4:0] force a layer off (back, midl, fore, text, sprites)
	// [5]   freeze the CPU, so the picture stops changing and layers can be
	//       compared against each other without the attract mode moving on
	// [6]   force the vital signs panel on
	input       [7:0] dbg_mask,
	output     [15:0] c_prg,
	output     [15:0] c_iowr,
	output     [15:0] c_dma_tm,
	output     [15:0] c_dma_pal,
	output     [15:0] c_vbl,
	output     [15:0] c_dma_spr,
	output     [15:0] spr_codes_nz,
	output     [31:0] spr_ram_or,
	output     [17:2] dma_src_spr,
	output     [15:0] cpu_wr_spr,
	output     [15:0] cpu_wr_tm,
	output            rs_out,
	output            fd13_out,
	output     [12:0] tm_dwords_out,
	output     [95:0] scroll_out,
	output      [3:0] why,
	output     [15:0] lay_ovr,
	output      [1:0] lay_ovr_layer,
	output      [5:0] lay_text_col,
	output     [15:0] spr_scanned,
	output     [15:0] spr_yhit,
	output     [15:0] spr_emitted,
	output     [15:0] spr_starved,
	output     [15:0] spr_tiles,
	output      [4:0] lay_en_out,
	output     [11:0] dma_text_dw,
	output     [15:0] snd_pc,
	output     [15:0] snd_fifo_rd,
	output     [15:0] snd_ymf_wr,
	output     [15:0] snd_stall,
	output     [15:0] ymf_overrun,
	output     [15:0] ymf_active,
	output     [15:0] snd_f2_wr,
	output     [15:0] snd_f2_rd,
	output     [31:0] eip,
	output     [15:0] cs,
	output            irq,
	output    [191:0] gdt,

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
	// dbg_mask[5] freezes the CPU; synchronise it into clk_cpu separately.
	reg [1:0] freeze_s;
	always @(posedge clk_cpu) freeze_s <= {freeze_s[0], dbg_mask[5]};
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

	spi_cpu cpu
	(
		.z80dl_stall (z80dl_stall),
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

		.dbg_wr_spr(cpu_wr_spr),
		.dbg_wr_tm (cpu_wr_tm),
		.dma_req   (dma_req),
		.dma_gnt   (dma_gnt),
		.dma_addr  (dma_addr),
		.dma_dout  (dma_dout),

		.dbg_why   (cpu_dbg_why),
		.dbg_eip   (eip),
		.dbg_cs    (cs),
		.dbg_irq   (irq),
		.dbg_gdt0(gdt[31:0]),   .dbg_gdt1(gdt[63:32]),
		.dbg_gdt2(gdt[95:64]),  .dbg_gdt3(gdt[127:96]),
		.dbg_gdt4(gdt[159:128]),.dbg_gdt5(gdt[191:160]),

		.vbl_toggle (vbl_toggle)
	);

	// ------------------------------------------------------------------
	// I/O registers
	// ------------------------------------------------------------------
	wire  [4:0] layer_enable;
	// layer_enable is active LOW per MAME (0 = layer shown). dbg_mask[4:0] force
	// a layer off from the host over JTAG so a rendering fault can be pinned to
	// one layer without rebuilding for each experiment.
	// dbg_mask is driven by a JTAG source register in the clk_ram domain, so it
	// has to be synchronised before it is used here. Left unsynchronised it is
	// also a huge fanout into clk_sys logic (the mixer's layer enables and the
	// RGB mux), which at a non-integer clk_ram:clk_sys ratio failed timing by
	// 11 ns across hundreds of paths.
	reg [7:0] mask_s1, mask_s2;
	always @(posedge clk_sys) begin
		mask_s1 <= dbg_mask;
		mask_s2 <= mask_s1;
	end

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

	wire  [4:0] layer_en_dbg = lay_en_s2 | mask_s2[4:0];
	wire        rowscroll_enable, fore_layer_d13;
	wire  [2:0] rf2_layer_bank;
	wire [15:0] scroll_bx, scroll_by, scroll_mx, scroll_my, scroll_fx, scroll_fy;
	wire [17:0] dma_src;
	wire [15:0] dma_len;
	wire        dma_tilemap, dma_palette, dma_sprite;
	wire  [3:0] cpu_dbg_why;
	wire  [7:0] sndfifo_din;
	wire        sndfifo_wr, coin_latch_rd;

	// The I/O register file is written by the 386, so it lives in the CPU domain.
	// Its outputs are stable register values read by clk_sys logic; both clocks
	// come from the same PLL and sit in the same clock group, so TimeQuest
	// analyses those transfers normally.
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
		.z80_rst_n  (z80_rst_n),
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
		.coin_latch_rd    (coin_latch_rd)
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
	wire [15:0] snd_audio;

	spi_sound sound
	(
		.set_sxx2c  (set_sxx2c),
		.jumpers    (jumpers),
		.fifo2_q    (fifo2_q),
		.fifo2_empty(fifo2_empty),
		.fifo2_rd   (fifo2_rd),
		.z80_rst_n  (z80_rst_n),
		.dbg_f2_wr  (snd_f2_wr),
		.dbg_f2_rd  (snd_f2_rd),
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

		.audio      (snd_audio),

		.dbg_z80_pc      (snd_pc),
		.dbg_fifo_rd     (snd_fifo_rd),
		.dbg_ymf_wr      (snd_ymf_wr),
		.dbg_stall       (snd_stall),
		.dbg_ymf_overrun (ymf_overrun),
		.dbg_ymf_active  (ymf_active)
	);

	// ------------------------------------------------------------------
	// Video RAMs
	// ------------------------------------------------------------------
	wire [11:0] tm_wa;   wire [31:0] tm_wd;   wire tm_we;
	wire [11:0] pal_wa;  wire [29:0] pal_wd;  wire pal_we;
	wire  [9:0] spr_wa;  wire [31:0] spr_wd;  wire spr_we;

	wire [11:0] tm_ra;   wire [31:0] tm_rd;
	wire [11:0] pal_ra;  wire [29:0] pal_rd;

	spi_dpram #(.DW(32), .AW(12)) tilemap_ram
		(.wr_clk(clk_cpu), .rd_clk(clk_sys),
		 .wr_addr(tm_wa),  .wr_data(tm_wd),  .wr_en(tm_we),
		 .rd_addr(tm_ra),  .rd_data(tm_rd));

	spi_dpram #(.DW(30), .AW(12)) palette_ram
		(.wr_clk(clk_cpu), .rd_clk(clk_sys),
		 .wr_addr(pal_wa), .wr_data(pal_wd), .wr_en(pal_we),
		 .rd_addr(pal_ra), .rd_data(pal_rd));

	wire  [9:0] spr_ra;
	wire [31:0] spr_rd;
	spi_dpram #(.DW(32), .AW(10)) sprite_ram
		(.wr_clk(clk_cpu), .rd_clk(clk_sys),
		 .wr_addr(spr_wa), .wr_data(spr_wd), .wr_en(spr_we),
		 .rd_addr(spr_ra), .rd_data(spr_rd));

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
		.dbg_text_dwords  (dma_text_dw),
		.dbg_src_spr      (dma_src_spr),
		.dbg_tm_dwords    (tm_dwords_out)
	);

	// ------------------------------------------------------------------
	// Tile layers
	//
	// Two things here are per GAME rather than per board.
	//
	// bg_fore_pos is the fore layer's tile base and it follows the SIZE of the
	// tile region (seibuspi_v.cpp:585): 0x2000 up to 3 MB, 0x4000 up to 6 MB,
	// 0x8000 beyond. rdfts and rdft have exactly 0x600000 of tiles; rdft2 has
	// 0xC00000, which is the only case that needs the 16th code bit.
	//
	// The decryption keys are simply per game. The same triple does text and
	// background -- MAME's text_decrypt and bg_decrypt take the same three
	// constants -- so one selection covers both layers.
	// ------------------------------------------------------------------
	wire [15:0] bg_fore_pos = (set_id == SET_RDFT2) ? 16'h8000 : 16'h4000;

	wire [23:0] tkey1 = (set_id == SET_RDFT2) ? TKEY1_RDFT2 : TKEY1_SEI252;
	wire [23:0] tkey2 = (set_id == SET_RDFT2) ? TKEY2_RDFT2 : TKEY2_SEI252;
	wire [23:0] tkey3 = (set_id == SET_RDFT2) ? TKEY3_RDFT2 : TKEY3_SEI252;

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
		.layer_off        (layer_en_dbg[3:0]),
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
		.dbg_overruns     (lay_ovr),
		.dbg_ovr_layer    (lay_ovr_layer),
		.dbg_text_col     (lay_text_col)
	);

	// ------------------------------------------------------------------
	// Sprite engine. Runs on SDRAM channel 4, so it does not compete with the
	// tile layers for the line budget.
	// ------------------------------------------------------------------
	wire [14:0] lb_spr;
	wire        spr_busy;

	// rdft2 is the RISE10 set: 6 MB plane-pair chunks instead of 4, and the
	// address-independent crypt instead of SEI252's keyed one. The two always
	// change together here, but spi_sprite takes them separately because
	// rdft2us pairs RISE10 with a different board.
	wire        spr_rise10 = (set_id == SET_RDFT2);
	wire [25:0] spr_stride = spr_rise10 ? SPR_CHUNK_STRIDE_RDFT2 : SPR_CHUNK_STRIDE;

	spi_sprite sprites
	(
		.clk        (clk_sys),
		.reset      (vid_reset),
		.vcnt       (vcnt),
		.line_start (line_start),
		.enable     (~layer_en_dbg[4]),
		.spr_chunk_stride(spr_stride),
		.rise10     (spr_rise10),
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
		.dbg_scanned(spr_scanned),
		.dbg_yhit   (spr_yhit),
		.dbg_emitted(spr_emitted),
		.dbg_starved(spr_starved),
		.dbg_codes_nz(spr_codes_nz),
		.dbg_spr_or(spr_ram_or),
		.dbg_tiles  (spr_tiles),
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
		.layer_enable (layer_en_dbg),
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
	// Vital signs panel (OSD selectable)
	// ------------------------------------------------------------------
	wire [7:0] mix_r, mix_g, mix_b;
	wire [7:0] dbg_r, dbg_g, dbg_b;

	reg prg_req_d;
	always @(posedge clk_sys) prg_req_d <= sdr_prg_req;

	spi_debug dbg
	(
		.clk            (clk_sys),
		.reset          (vid_reset),
		.hcnt           (hcnt),
		.vcnt           (vcnt),
		.rom_ready      (rom_ready),
		.ev_prg_fetch   (sdr_prg_req ^ prg_req_d),
		.ev_io_wr       (io_wr),
		.ev_dma_tilemap (dma_tilemap),
		.ev_dma_palette (dma_palette),
		.ev_dma_sprite  (dma_sprite),
		.ev_vbl         (vbl_rise),
		.ev_line        (line_start),
		.lvl_why        (cpu_dbg_why),
		.chk_ok         (chk_ok),
		.chk_done       (chk_done),
		.red            (dbg_r),
		.green          (dbg_g),
		.blue           (dbg_b)
	);

	// Same events the panel counts, exported for the JTAG probe.
	reg [15:0] n_prg, n_iowr, n_tm, n_pal, n_vbl, n_spr;
	reg pq, iq, tq, lq, vq, sq;
	always @(posedge clk_sys) begin
		if (vid_reset) begin
			n_prg <= 0; n_iowr <= 0; n_tm <= 0; n_pal <= 0; n_vbl <= 0; n_spr <= 0;
			pq <= 0; iq <= 0; tq <= 0; lq <= 0; vq <= 0; sq <= 0;
		end
		else begin
			pq <= sdr_prg_req ^ prg_req_d; iq <= io_wr;
			tq <= dma_tilemap;  lq <= dma_palette; vq <= vbl_rise;
			sq <= dma_sprite;
			if ((sdr_prg_req ^ prg_req_d) && !pq) n_prg  <= n_prg  + 1'd1;
			if (io_wr        && !iq)              n_iowr <= n_iowr + 1'd1;
			if (dma_tilemap  && !tq)              n_tm   <= n_tm   + 1'd1;
			if (dma_palette  && !lq)              n_pal  <= n_pal  + 1'd1;
			if (vbl_rise     && !vq)              n_vbl  <= n_vbl  + 1'd1;
			// The sprite list only reaches sprite RAM through this DMA. If it
			// never fires, the list is stale or empty and every entry fails the
			// `code != 0` gate -- indistinguishable from a y-compare fault
			// without counting the trigger itself.
			if (dma_sprite   && !sq)              n_spr  <= n_spr  + 1'd1;
		end
	end
	assign lay_en_out = layer_enable;
	assign c_prg = n_prg; assign c_iowr = n_iowr; assign c_dma_tm = n_tm;
	assign c_dma_pal = n_pal; assign c_vbl = n_vbl; assign why = cpu_dbg_why;
	assign c_dma_spr = n_spr;
	assign rs_out    = rowscroll_enable;
	assign fd13_out  = fore_layer_d13;
	assign scroll_out = {scroll_fy, scroll_fx, scroll_my, scroll_mx, scroll_by, scroll_bx};

	wire panel = dbg_en | mask_s2[6];
	/* verilator lint_off UNUSEDSIGNAL */
	wire _unused_dbg = &{1'b0, dbg_mask[7], mask_s2[7], mask_s2[5]};   // spare
	/* verilator lint_on UNUSEDSIGNAL */
	assign red   = panel ? dbg_r : mix_r;
	assign green = panel ? dbg_g : mix_g;
	assign blue  = panel ? dbg_b : mix_b;

	// SXX2E is a mono board: the YMF271's four outputs are summed onto one
	// speaker, so both sides carry the same sample.
	assign audio_l = snd_audio;
	assign audio_r = snd_audio;

	// Signals not yet consumed; each disappears as its block lands.
	wire _unused = &{1'b0, clk_ram, dma_busy, layers_busy, spr_busy,
	                 hcnt[9], dma_src[1:0], lb_bank};

endmodule
