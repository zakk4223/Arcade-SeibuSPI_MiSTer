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
	input             clk_sys,     // 57.272727 MHz
	input             clk_ram,     // 114.545455 MHz
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

	spi_video_timing timing
	(
		.clk        (clk_sys),
		.reset      (reset),
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
	// 386 subsystem
	// ------------------------------------------------------------------
	wire        cpu_reset = reset | ~rom_ready;

	wire [10:2] io_addr;
	wire [31:0] io_wdata, io_rdata;
	wire  [3:0] io_be;
	wire        io_wr, io_rd;

	// Main RAM read port for the video DMA engines (T4).
	wire [15:0] dma_addr = 16'd0;
	wire [31:0] dma_dout;

	spi_cpu cpu
	(
		.clk       (clk_sys),
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

		.dma_addr  (dma_addr),
		.dma_dout  (dma_dout),

		.vbl_rise  (vbl_rise)
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

	spi_io io
	(
		.clk              (clk_sys),
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
	always @(posedge clk_sys) begin
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
	// TODO(T4) tilemap / sprite / palette pipelines and the mixer
	// TODO(T5) Z80 + YMF271
	// ------------------------------------------------------------------
	assign sdr_gfx_addr = 25'd0;
	assign sdr_gfx_req  = 1'b0;
	assign sdr_spr_addr = 25'd0;
	assign sdr_spr_req  = 1'b0;
	assign sdr_pcm_addr = 25'd0;
	assign sdr_pcm_req  = 1'b0;

	assign red   = 8'd0;
	assign green = 8'd0;
	assign blue  = 8'd0;

	assign audio_l = 16'd0;
	assign audio_r = 16'd0;

	// Signals not yet consumed; each disappears as its block lands.
	wire _unused = &{1'b0, clk_ram, line_start, hcnt, vcnt, dma_dout,
	                 layer_enable, rowscroll_enable, fore_layer_d13,
	                 rf2_layer_bank, scroll_bx, scroll_by, scroll_mx, scroll_my,
	                 scroll_fx, scroll_fy, dma_src, dma_len,
	                 dma_tilemap, dma_palette, dma_sprite,
	                 sndfifo_din, sndfifo_wr,
	                 sdr_gfx_dout, sdr_gfx_ack, sdr_spr_dout, sdr_spr_ack,
	                 sdr_pcm_dout, sdr_pcm_ack};

endmodule
