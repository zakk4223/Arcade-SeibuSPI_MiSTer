//============================================================================
//  SlopperPI - Seibu SPI / SXX2E
//
//  Board top: 386 + video + sound + I/O.
//
//  Scaffold state (T1). The raster is real and final; the CPU, video pipelines
//  and sound are wired in by T3/T4/T5.
//============================================================================

module spi_top
(
	input             clk_sys,     // 57.272727 MHz
	input             clk_ram,     // 114.545455 MHz
	input             reset,
	input             rom_ready,

	// SDRAM ch1: 386 program ROM
	output     [24:0] sdr_prg_addr,
	input      [31:0] sdr_prg_dout,
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
	// TODO(T3) 386 core, main RAM, I/O decode, vblank IRQ (vector 0x20)
	// TODO(T4) tilemap / sprite / palette pipelines and the mixer
	// TODO(T5) Z80 + YMF271
	// ------------------------------------------------------------------
	assign sdr_prg_addr = 25'd0;
	assign sdr_prg_req  = 1'b0;
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

	// Keep the scaffold's unused inputs from being optimised away in a manner
	// that changes port widths; removed as each block lands.
	wire _unused = &{1'b0, rom_ready, clk_ram, line_start, vbl_rise,
	                 hcnt, vcnt, inputs, system, coin,
	                 sdr_prg_dout, sdr_prg_ack, sdr_gfx_dout, sdr_gfx_ack,
	                 sdr_spr_dout, sdr_spr_ack, sdr_pcm_dout, sdr_pcm_ack};

endmodule
