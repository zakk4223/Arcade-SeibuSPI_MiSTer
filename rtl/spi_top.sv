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

	// SDRAM ch1: 386 program ROM
	output     [24:0] sdr_prg_addr,
	input      [63:0] sdr_prg_dout,
	output            sdr_prg_req,
	input             sdr_prg_ack,

	// SDRAM ch2: tile / char graphics
	output     [24:0] sdr_gfx_addr,
	input      [63:0] sdr_gfx_dout,
	output            sdr_gfx_req,
	input             sdr_gfx_ack,

	// SDRAM ch4: sprite graphics
	output     [24:0] sdr_spr_addr,
	input      [63:0] sdr_spr_dout,
	output            sdr_spr_req,
	input             sdr_spr_ack,

	// SDRAM ch5: YMF271 PCM samples
	output     [24:0] sdr_pcm_addr,
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

	spi_cpu cpu
	(
		.clk       (clk_cpu),
		.reset     (cpu_reset),
		.cpu_en    (1'b1),

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

		.dma_req   (dma_req),
		.dma_gnt   (dma_gnt),
		.dma_addr  (dma_addr),
		.dma_dout  (dma_dout),

		.vbl_toggle (vbl_toggle)
	);

	// ------------------------------------------------------------------
	// I/O registers
	// ------------------------------------------------------------------
	wire  [4:0] layer_enable;
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
	spi_io io
	(
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
		.sndfifo_full     (1'b0),
		.coin_latch       (coin_sr),
		.coin_latch_rd    (coin_latch_rd)
	);

	// The Z80 latches coin inputs and the 386 reads them back at 0x680. Until
	// the sound CPU lands (T5), latch them here so coins still register.
	reg [7:0] coin_sr;
	reg [7:0] coin_prev;
	always @(posedge clk_cpu) begin
		if (cpu_reset) begin
			coin_sr   <= 8'd0;
			coin_prev <= 8'hFF;
		end
		else begin
			coin_prev <= coin;
			// inputs are active low, so a press is a falling edge
			coin_sr <= (coin_sr | (coin_prev & ~coin));
			if (coin_latch_rd) coin_sr <= (coin_prev & ~coin);
		end
	end

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

	// Sprite RAM: written by the DMA, read by the sprite engine (T4b).
	wire [9:0]  spr_ra = 10'd0;
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
		.busy             (dma_busy)
	);

	// ------------------------------------------------------------------
	// Tile layers
	//
	// bg_fore_pos is 0x4000 for a 6 MB tile region (seibuspi_v.cpp:580); rdfts
	// has exactly 0x600000 of tiles.
	// ------------------------------------------------------------------
	wire [8:0] lb_x = hcnt[8:0];
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
		.rowscroll_enable (rowscroll_enable),
		.fore_layer_d13   (fore_layer_d13),
		.rf2_layer_bank   (rf2_layer_bank),
		.bg_fore_pos      (15'h4000),

		.tm_addr          (tm_ra),
		.tm_data          (tm_rd),

		.sdr_addr         (sdr_gfx_addr),
		.sdr_dout         (sdr_gfx_dout),
		.sdr_req          (sdr_gfx_req),
		.sdr_ack          (sdr_gfx_ack),

		.lb_x             (lb_x),
		.lb_bank          (lb_bank),
		.lb_back          (lb_back),
		.lb_midl          (lb_midl),
		.lb_fore          (lb_fore),
		.lb_text          (lb_text),

		.busy             (layers_busy)
	);

	// ------------------------------------------------------------------
	// Mixer
	//
	// TODO(T4b): the sprite engine. Until it lands the sprite input is marked
	// invalid, so the mixer composites the four tile layers alone.
	// ------------------------------------------------------------------
	wire visible = ~hblank & ~vblank;

	spi_mixer mixer
	(
		.clk          (clk_sys),
		.reset        (vid_reset),
		.ce_pix       (ce_pix),
		.layer_enable (layer_enable),
		.visible      (visible),
		.lb_back      (lb_back),
		.lb_midl      (lb_midl),
		.lb_fore      (lb_fore),
		.lb_text      (lb_text),
		.lb_spr       (15'd0),
		.pal_addr     (pal_ra),
		.pal_data     (pal_rd),
		.red          (red),
		.green        (green),
		.blue         (blue)
	);

	// ------------------------------------------------------------------
	// TODO(T5) Z80 + YMF271
	// ------------------------------------------------------------------
	assign sdr_spr_addr = 25'd0;
	assign sdr_spr_req  = 1'b0;
	assign sdr_pcm_addr = 25'd0;
	assign sdr_pcm_req  = 1'b0;

	assign audio_l = 16'd0;
	assign audio_r = 16'd0;

	// Signals not yet consumed; each disappears as its block lands.
	wire _unused = &{1'b0, clk_ram, dma_busy, layers_busy, spr_rd,
	                 hcnt[9], dma_src[1:0], lb_bank,
	                 sndfifo_din, sndfifo_wr,
	                 sdr_spr_dout, sdr_spr_ack, sdr_pcm_dout, sdr_pcm_ack};

endmodule
