//============================================================================
//  SlopperPI - test wrapper around the video pipeline.
//
//  Video timing + tilemap RAM + palette RAM + layer renderer + mixer, with
//  preload ports so a testbench can drop in MAME's captured video RAMs and
//  compare the resulting frame against MAME's.
//============================================================================

module tb_video_top
(
	input             clk,
	input             reset,

	// CRTC state
	input       [4:0] layer_enable,
	input             rowscroll_enable,
	input             fore_layer_d13,
	input       [2:0] rf2_layer_bank,
	input      [15:0] scroll_bx, scroll_by,
	input      [15:0] scroll_mx, scroll_my,
	input      [15:0] scroll_fx, scroll_fy,

	// Preload
	input      [11:0] pre_tm_addr,
	input      [31:0] pre_tm_data,
	input             pre_tm_we,
	input      [11:0] pre_pal_addr,
	input      [29:0] pre_pal_data,
	input             pre_pal_we,

	// SDRAM graphics channel, modelled by the testbench
	output     [24:0] sdr_addr,
	input      [63:0] sdr_dout,
	output            sdr_req,
	input             sdr_ack,

	// Video out
	output            ce_pix,
	output      [7:0] red,
	output      [7:0] green,
	output      [7:0] blue,
	output            hblank,
	output            vblank,
	output      [9:0] hcnt,
	output      [9:0] vcnt,

	// Line buffer taps, so a testbench can check the layer renderer on its own
	// rather than only through the mixer.
	output      [9:0] dbg_back,
	output      [9:0] dbg_midl,
	output      [9:0] dbg_fore,
	output      [9:0] dbg_text,
	output      [1:0] dbg_layer,
	output     [14:0] dbg_tcode,
	output     [24:0] dbg_gfx_addr,
	output            dbg_emit,
	output            dbg_busy
);

	wire hsync, vsync, line_start, vbl_rise;

	spi_video_timing timing
	(
		.clk(clk), .reset(reset), .ce_pix(ce_pix),
		.hcnt(hcnt), .vcnt(vcnt),
		.hsync(hsync), .vsync(vsync), .hblank(hblank), .vblank(vblank),
		.line_start(line_start), .vbl_rise(vbl_rise)
	);

	wire [11:0] tm_ra;
	wire [31:0] tm_rd;
	wire [11:0] pal_ra;
	wire [29:0] pal_rd;

	spi_dpram #(.DW(32), .AW(12)) tilemap_ram
		(.wr_clk(clk), .rd_clk(clk),
		 .wr_addr(pre_tm_addr), .wr_data(pre_tm_data), .wr_en(pre_tm_we),
		 .rd_addr(tm_ra), .rd_data(tm_rd));

	spi_dpram #(.DW(30), .AW(12)) palette_ram
		(.wr_clk(clk), .rd_clk(clk),
		 .wr_addr(pre_pal_addr), .wr_data(pre_pal_data), .wr_en(pre_pal_we),
		 .rd_addr(pal_ra), .rd_data(pal_rd));

	// The mixer's palette sequence and composite take two pixel-times, so the
	// line buffer is read two pixels ahead. Past the end of a line that wraps
	// into the next line's buffer, which is what lb_wrap selects.
	wire [9:0] lb_nx   = hcnt + 10'd2;
	wire       lb_wrap = (lb_nx >= 10'd448);
	wire [8:0] lb_x    = lb_wrap ? 9'(lb_nx - 10'd448) : lb_nx[8:0];
	wire       lb_bank;
	wire [9:0] lb_back, lb_midl, lb_fore, lb_text;
	wire       layers_busy;

	spi_layers layers
	(
		.clk(clk), .reset(reset),
		.vcnt(vcnt), .line_start(line_start),
		.scroll_bx(scroll_bx), .scroll_by(scroll_by),
		.scroll_mx(scroll_mx), .scroll_my(scroll_my),
		.scroll_fx(scroll_fx), .scroll_fy(scroll_fy),
		.rowscroll_enable(rowscroll_enable),
		.fore_layer_d13(fore_layer_d13),
		.rf2_layer_bank(rf2_layer_bank),
		.bg_fore_pos(15'h4000),
		.tm_addr(tm_ra), .tm_data(tm_rd),
		.sdr_addr(sdr_addr), .sdr_dout(sdr_dout),
		.sdr_req(sdr_req), .sdr_ack(sdr_ack),
		.lb_x(lb_x), .lb_wrap(lb_wrap), .lb_bank(lb_bank),
		.lb_back(lb_back), .lb_midl(lb_midl),
		.lb_fore(lb_fore), .lb_text(lb_text),
		.busy(layers_busy),
		.dbg_layer(dbg_layer), .dbg_tcode(dbg_tcode),
		.dbg_gfx_addr(dbg_gfx_addr), .dbg_emit(dbg_emit), .dbg_busy(dbg_busy)
	);

	spi_mixer mixer
	(
		.clk(clk), .reset(reset), .ce_pix(ce_pix),
		.layer_enable(layer_enable),
		.lb_back(lb_back), .lb_midl(lb_midl),
		.lb_fore(lb_fore), .lb_text(lb_text),
		.lb_spr(15'd0),
		.pal_addr(pal_ra), .pal_data(pal_rd),
		.red(red), .green(green), .blue(blue)
	);

	assign dbg_back = lb_back;
	assign dbg_midl = lb_midl;
	assign dbg_fore = lb_fore;
	assign dbg_text = lb_text;

	wire _unused = &{1'b0, hsync, vsync, vbl_rise, lb_bank, layers_busy};

endmodule
