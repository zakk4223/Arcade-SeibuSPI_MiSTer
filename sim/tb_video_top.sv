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
	input       [9:0] pre_spr_addr,
	input      [31:0] pre_spr_data,
	input             pre_spr_we,
	input      [11:0] pre_pal_addr,
	input      [29:0] pre_pal_data,
	input             pre_pal_we,

	// SDRAM graphics channel, modelled by the testbench
	output     [25:0] sdr_addr,
	input      [63:0] sdr_dout,
	output            sdr_req,
	input             sdr_ack,

	// SDRAM sprite channel
	output     [25:0] spr_sdr_addr,
	input      [63:0] spr_sdr_dout,
	output            spr_sdr_req,
	input             spr_sdr_ack,

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
	output            dbg_lb_bank,
	output      [9:0] dbg_back,
	output      [9:0] dbg_midl,
	output      [9:0] dbg_fore,
	output      [9:0] dbg_text,
	output      [1:0] dbg_layer,
	output     [15:0] dbg_tcode,
	output     [25:0] dbg_gfx_addr,
	output            dbg_emit,
	output            dbg_busy,
	output     [15:0] dbg_rowscroll,
	output      [8:0] dbg_xstart,
	output            dbg_latch,
	output      [3:0] dbg_finex,
	output      [5:0] dbg_col,
	output signed [10:0] dbg_emitx,
	output      [5:0] dbg_pix,
	output      [3:0] dbg_emiti,
	output            dbg_spr_we,
	output      [3:0] dbg_spr_state,
	output      [8:0] dbg_spr_index,
	output      [5:0] dbg_spr_pix,
	output signed [10:0] dbg_spr_emitx,
	output     [15:0] dbg_spr_code,
	output     [15:0] dbg_spr_tile,
	output      [3:0] dbg_spr_ry,
	output      [3:0] dbg_spr_px,
	output      [8:0] dbg_spr_sx, dbg_spr_sy,
	// Starvation: lines that ended with sprites still unscanned. This is
	// the thing the sprite-budget work is trying to drive to zero, so it
	// has to be visible here rather than only on hardware.
	output     [15:0] dbg_spr_starved,
	output     [15:0] dbg_spr_yhit_o,
	output     [15:0] dbg_spr_scanned_o
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
		.rowscroll_enable(rowscroll_enable), .layer_off(layer_enable[3:0]),
		.fore_layer_d13(fore_layer_d13),
		.rf2_layer_bank(rf2_layer_bank),
		// rdfts: 6 MB of tiles, and the SEI252 key triple.
		.bg_fore_pos(16'h4000),
		.tkey1(24'h5A3845), .tkey2(24'h77CF5B), .tkey3(24'h1378DF),
		.tm_addr(tm_ra), .tm_data(tm_rd),
		.sdr_addr(sdr_addr), .sdr_dout(sdr_dout),
		.sdr_req(sdr_req), .sdr_ack(sdr_ack),
		.lb_x(lb_x), .lb_wrap(lb_wrap), .lb_bank(lb_bank),
		.lb_back(lb_back), .lb_midl(lb_midl),
		.lb_fore(lb_fore), .lb_text(lb_text),
		.busy(layers_busy),
		.dbg_layer(dbg_layer), .dbg_tcode(dbg_tcode),
		.dbg_gfx_addr(dbg_gfx_addr), .dbg_emit(dbg_emit), .dbg_busy(dbg_busy),
		.dbg_rowscroll(dbg_rowscroll), .dbg_xstart(dbg_xstart),
		.dbg_latch(dbg_latch), .dbg_finex(dbg_finex),
		.dbg_col(dbg_col), .dbg_emitx(dbg_emitx),
		.dbg_pix(dbg_pix), .dbg_emiti(dbg_emiti),
		.dbg_overruns(), .dbg_ovr_layer(), .dbg_text_col()
	);

	wire  [9:0] spr_ra;
	wire [31:0] spr_rd;
	wire [14:0] lb_spr;
	wire        spr_busy;

	spi_dpram #(.DW(32), .AW(10)) sprite_ram
		(.wr_clk(clk), .rd_clk(clk),
		 .wr_addr(pre_spr_addr), .wr_data(pre_spr_data), .wr_en(pre_spr_we),
		 .rd_addr(spr_ra), .rd_data(spr_rd));

	spi_sprite sprites
	(
		.clk(clk), .reset(reset),
		.vcnt(vcnt), .line_start(line_start),
		.enable(~layer_enable[4]),
		// rdfts: SEI252 crypt at the 4 MB chunk stride.
		.spr_chunk_stride(26'h040_0000), .rise10(1'b0),
		.spr_addr(spr_ra), .spr_data(spr_rd),
		.sdr_addr(spr_sdr_addr), .sdr_dout(spr_sdr_dout),
		.sdr_req(spr_sdr_req), .sdr_ack(spr_sdr_ack),
		.lb_x(lb_x), .lb_wrap(lb_wrap), .lb_out(lb_spr),
		.busy(spr_busy),
		.dbg_we(dbg_spr_we), .dbg_state(dbg_spr_state), .dbg_index(dbg_spr_index),
		.dbg_pix(dbg_spr_pix), .dbg_emitx(dbg_spr_emitx), .dbg_code(dbg_spr_code),
		.dbg_sx(dbg_spr_sx), .dbg_sy(dbg_spr_sy),
		.dbg_scanned(dbg_spr_scanned_o), .dbg_yhit(dbg_spr_yhit_o), .dbg_emitted(),
		.dbg_starved(dbg_spr_starved), .dbg_tiles(),
		.dbg_codes_nz(), .dbg_spr_or(),
		.dbg_tile_code(dbg_spr_tile), .dbg_ry(dbg_spr_ry), .dbg_px(dbg_spr_px)
	);

	spi_mixer mixer
	(
		.clk(clk), .reset(reset), .ce_pix(ce_pix),
		.layer_enable(layer_enable),
		.lb_back(lb_back), .lb_midl(lb_midl),
		.lb_fore(lb_fore), .lb_text(lb_text),
		.lb_spr(lb_spr),
		.pal_addr(pal_ra), .pal_data(pal_rd),
		.red(red), .green(green), .blue(blue)
	);

	assign dbg_back = lb_back;
	assign dbg_midl = lb_midl;
	assign dbg_fore = lb_fore;
	assign dbg_text = lb_text;

	assign dbg_lb_bank = lb_bank;

	wire _unused = &{1'b0, hsync, vsync, vbl_rise, layers_busy, spr_busy};

endmodule
