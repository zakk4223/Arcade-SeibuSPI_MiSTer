//============================================================================
//  SlopperPI - Seibu SPI / SXX2E
//
//  Tile layer renderer: back, middle, fore (16x16, 6bpp) and text (8x8, 5bpp).
//
//  One scanline ahead of the raster, the four layers are rendered in turn into
//  line buffers. They share the SDRAM graphics channel and the tilemap RAM read
//  port, which is why this is one sequencer rather than four parallel ones; the
//  budget is comfortable (see the note at the bottom).
//
//  Layer geometry (seibuspi_v.cpp:591):
//
//    back/midl/fore  32x32 tiles of 16x16, TILEMAP_SCAN_COLS, 512x512 wrapping
//    text            64x32 tiles of 8x8,   TILEMAP_SCAN_ROWS, 512x256, no scroll
//
//  TILEMAP_SCAN_COLS means the tile at (col,row) is at index col*32 + row.
//  Two tiles per tilemap RAM dword, the even index in the low half.
//
//  Tile word decode (seibuspi_v.cpp:511):
//
//    back: code = w[12:0] | back_d14                  colour = w[15:13]
//    midl: code = w[12:0] | 0x2000 | midl_d14         colour = w[15:13]
//    fore: code = w[12:0] | bg_fore_pos | d13 | d14   colour = w[15:13]
//    text: code = w[11:0]                             colour = w[15:12]
//
//  GFX layout. A 16x16 tile is 192 bytes, 12 per row, four 24-bit groups of
//  four pixels. An 8x8 char is 48 bytes, 6 per row, two groups.
//
//  Within a decrypted group v (v[23] is the MSB of the first byte), MAME's
//  gfx_layout puts entry k of planeoffset[] at bit offset 4k, pixel p at a
//  further (3-p), and bit offset n reads as v[23-n].
//
//  The catch is that gfx_layout's planeoffset array is listed MOST significant
//  plane first -- decodechar uses `planebit = 1 << (planes - 1 - plane)`. So
//  planeoffset[0] is the pixel's TOP bit, not its bottom one:
//
//    16x16, planes {0,4,8,12,16,20}: pixel p = {v[20+p], v[16+p], ... v[p]}
//    8x8,   planes {4,8,12,16,20}:   pixel p = {v[16+p], v[12+p], ... v[p]}
//
//  written MSB first. Getting this backwards renders every pixel's colour
//  index bit-reversed, which looks like plausible garbage rather than an
//  obvious failure.
//============================================================================

module spi_layers
(
	input             clk,          // clk_sys
	input             reset,

	// Raster
	input       [9:0] vcnt,
	input             line_start,

	// Layer registers
	input      [15:0] scroll_bx, scroll_by,
	input      [15:0] scroll_mx, scroll_my,
	input      [15:0] scroll_fx, scroll_fy,
	input             rowscroll_enable,
	input       [3:0] layer_off,      // 1 = layer disabled, skip it entirely

	input             fore_layer_d13,
	input       [2:0] rf2_layer_bank,   // {fore d14, midl d14, back d14}
	// The fore layer's tile base, which depends on the SIZE of the tile region
	// (seibuspi_v.cpp:585): 0x2000 up to 3 MB, 0x4000 up to 6 MB, 0x8000 beyond.
	// 16 bits because of that last case -- rdft2's 12 MB of tiles is 0x10000
	// tiles and needs the whole code space, where every 6 MB set fits in 15.
	input      [15:0] bg_fore_pos,

	// Tile and text decryption keys. Per GAME, not per board, and the same
	// triple serves both layers -- MAME's text_decrypt and bg_decrypt take the
	// same three constants. spi_defs.vh has all three sets; spi_top picks.
	input      [23:0] tkey1, tkey2, tkey3,

	// Tilemap RAM read port
	output reg [11:0] tm_addr,
	input      [31:0] tm_data,

	// SDRAM graphics channel (ch2)
	output reg [25:0] sdr_addr,
	input      [63:0] sdr_dout,
	output reg        sdr_req,
	input             sdr_ack,

	// Line buffer read side (the mixer)
	input       [8:0] lb_x,
	// The mixer runs two pixels ahead, so at the very end of a line it must read
	// the NEXT line's buffer to have pixels 0 and 1 ready in time. That buffer
	// is already complete: the renderer finishes a line well before hblank ends.
	input             lb_wrap,
	output            lb_bank,        // bank currently being written; the
	                                 // mixer reads the other one
	output      [9:0] lb_back,
	output      [9:0] lb_midl,
	output      [9:0] lb_fore,
	output      [9:0] lb_text,

	output reg        busy,

	// Debug taps for the golden-reference testbench.
	output      [1:0] dbg_layer,
	output     [15:0] dbg_tcode,
	output     [25:0] dbg_gfx_addr,
	output            dbg_emit,
	output            dbg_busy,
	output     [15:0] dbg_rowscroll,
	output      [8:0] dbg_xstart,
	// Sampled at the exact cycle emit_x is latched in S_GB_WT.
	output            dbg_latch,
	output      [3:0] dbg_finex,
	output      [5:0] dbg_col,
	output signed [10:0] dbg_emitx,
	output      [5:0] dbg_pix,
	output      [3:0] dbg_emiti,

	// Overrun telemetry. A line that does not finish is abandoned at the next
	// tile boundary, and since text is rendered last it is what gets truncated.
	// These say how often that happens and how far the text layer got.
	output reg [15:0] dbg_overruns,
	output reg  [1:0] dbg_ovr_layer,
	output reg  [5:0] dbg_text_col
);

`include "spi_defs.vh"

	assign dbg_layer = layer;

	// ------------------------------------------------------------------
	// Which line is being rendered, and into which buffer
	// ------------------------------------------------------------------
	reg [8:0] render_line;
	reg       render_bank;

	// The line the next restart will pick up. Named here rather than inlined at
	// the restart because render_bank is derived from it: the two have to agree
	// by construction, not by both being edited the same way later.
	wire [8:0] next_line = (vcnt >= VBSTART - 10'd1) ? 9'd0 : (vcnt[8:0] + 9'd1);

	// ------------------------------------------------------------------
	// Per-layer parameters, selected by the phase
	// ------------------------------------------------------------------
	localparam [1:0] L_BACK = 2'd0, L_MIDL = 2'd1, L_FORE = 2'd2, L_TEXT = 2'd3;

	// The mixer ignores a disabled layer, so fetching and emitting it is pure
	// waste -- and with the SDRAM bus at ~90% of a line there is none to spare.
	// S_LSTART skips one in a single cycle instead of ~800.

	reg [1:0] layer;

	// Tilemap RAM dword base for each layer's tile data.
	wire [11:0] tm_base_back = 12'h000;
	wire [11:0] tm_base_fore = rowscroll_enable ? 12'h400 : 12'h200;
	wire [11:0] tm_base_midl = rowscroll_enable ? 12'h800 : 12'h400;
	wire [11:0] tm_base_text = rowscroll_enable ? 12'hC00 : 12'h600;

	// Rowscroll tables, when enabled (seibuspi_v.cpp:437).
	wire [11:0] rs_base_back = 12'h200;
	wire [11:0] rs_base_midl = 12'h600;
	wire [11:0] rs_base_fore = 12'hA00;

	/* verilator lint_off UNUSEDSIGNAL */
	reg [15:0] sx, sy;          // only [8:0] used: the layers wrap at 512
	/* verilator lint_on UNUSEDSIGNAL */
	reg [11:0] tm_base, rs_base;
	always @* begin
		case (layer)
			L_BACK: begin sx = scroll_bx; sy = scroll_by; tm_base = tm_base_back; rs_base = rs_base_back; end
			L_MIDL: begin sx = scroll_mx; sy = scroll_my; tm_base = tm_base_midl; rs_base = rs_base_midl; end
			L_FORE: begin sx = scroll_fx; sy = scroll_fy; tm_base = tm_base_fore; rs_base = rs_base_fore; end
			default:begin sx = 16'd0;     sy = 16'd0;     tm_base = tm_base_text; rs_base = 12'h000;      end
		endcase
	end

	wire is_text = (layer == L_TEXT);

	// ------------------------------------------------------------------
	// Row scroll
	//
	// MAME indexes the table with (y + 19) & 511; the adder is presumably a CRTC
	// value rather than a true constant, but every SPI game uses the same one.
	// Entries are 16-bit signed, two per tilemap RAM dword.
	// ------------------------------------------------------------------
	wire [8:0] rs_index = render_line + 9'd19;
	/* verilator lint_off UNUSEDSIGNAL */
	reg [15:0] rowscroll;       // only [8:0] used, as above
	/* verilator lint_on UNUSEDSIGNAL */

	// ------------------------------------------------------------------
	// Line geometry for the current layer
	// ------------------------------------------------------------------
	// The layers wrap at 512, so the adds are taken modulo 512 by truncation.
	wire [8:0] src_y = is_text ? render_line : 9'(render_line + sy[8:0]);

	wire [4:0] tile_row = is_text ? src_y[7:3] : src_y[8:4];
	wire [3:0] fine_y   = is_text ? {1'b0, src_y[2:0]} : src_y[3:0];

	wire [8:0] x_start = is_text ? 9'd0
	                             : 9'(sx[8:0] + (rowscroll_enable ? rowscroll[8:0] : 9'd0));
	wire [3:0] fine_x  = is_text ? {1'b0, x_start[2:0]} : x_start[3:0];

	// Columns needed to cover 320 visible pixels: 21 at 16 px, 41 at 8 px.
	wire [5:0] col_count = is_text ? 6'd41 : 6'd21;

	reg [5:0] col;          // column being fetched

	wire [5:0] cur_col = is_text ? 6'(x_start[8:3] + col)
	                             : {1'b0, 5'(x_start[8:4] + col[4:0])};

	// TILEMAP_SCAN_COLS for the 16x16 layers, SCAN_ROWS for text.
	wire [10:0] tile_index = is_text ? ({tile_row, 6'd0} + {5'd0, cur_col})            // row*64 + col
	                                 : ({1'b0, cur_col[4:0], 5'd0} + {6'd0, tile_row}); // col*32 + row

	// ------------------------------------------------------------------
	// Tile word -> code / colour
	// ------------------------------------------------------------------
	reg [15:0] tword;
	reg  [3:0] tcolor;
	reg [15:0] tcode;

	// rf2_layer_bank supplies bit 14 of the code (0x4000) per layer; it is only
	// written on SXX2F / SYS386I, so it stays 0 here.
	always @* begin
		case (layer)
			L_BACK: begin
				tcode  = {1'b0, rf2_layer_bank[0], 1'b0, tword[12:0]};
				tcolor = {1'b0, tword[15:13]};
			end
			L_MIDL: begin
				tcode  = {1'b0, rf2_layer_bank[1], 1'b1, tword[12:0]};    // | 0x2000
				tcolor = {1'b0, tword[15:13]};
			end
			L_FORE: begin
				tcode  = {1'b0, rf2_layer_bank[2], fore_layer_d13, tword[12:0]} | bg_fore_pos;
				tcolor = {1'b0, tword[15:13]};
			end
			default: begin
				tcode  = {4'd0, tword[11:0]};
				tcolor = tword[15:12];
			end
		endcase
	end

	// ------------------------------------------------------------------
	// GFX byte address
	//   16x16: code * 192 + fine_y * 12
	//   8x8:   code * 48  + fine_y * 6
	// ------------------------------------------------------------------
	// code*48  = code*32 + code*16     fine_y*6  = fine_y*4 + fine_y*2
	// code*192 = code*128 + code*64    fine_y*12 = fine_y*8 + fine_y*4
	wire [25:0] char_off = {8'd0, tcode[11:0], 5'd0} + {9'd0, tcode[11:0], 4'd0}
	                     + {19'd0, fine_y, 2'd0}     + {20'd0, fine_y, 1'b0};
	wire [25:0] tile_off = {3'd0, tcode, 7'd0} + {4'd0, tcode, 6'd0}
	                     + {18'd0, fine_y, 3'd0}     + {19'd0, fine_y, 2'd0};

	wire [25:0] gfx_base = is_text ? (SDR_CHARS_BASE + char_off)
	                               : (SDR_TILES_BASE + tile_off);

	// ------------------------------------------------------------------
	// Fetch sequencer
	// ------------------------------------------------------------------
	localparam [3:0] S_IDLE   = 4'd0,
	                 S_LSTART = 4'd13,  // decide whether this layer is drawn
	                 S_RS_REQ = 4'd1,   // rowscroll table read
	                 S_RS_WT  = 4'd2,
	                 S_RS_LAT = 4'd12,
	                 S_TM_REQ = 4'd3,   // tilemap word read
	                 S_TM_WT  = 4'd4,
	                 S_TM_LAT = 4'd5,
	                 S_GA_REQ = 4'd6,   // gfx low 64 bits
	                 S_GA_WT  = 4'd7,
	                 S_GB_REQ = 4'd8,   // gfx high 64 bits
	                 S_GB_WT  = 4'd9,
	                 S_EMIT   = 4'd10,
	                 S_NEXT   = 4'd11;

	reg [3:0] state;

	// line_start was originally only honoured in S_IDLE. If a line's rendering
	// overruns -- and with 3 x 21 + 41 = 104 tiles at ~30 cycles each against
	// 448 * 8 = 3584 cycles a line, it can -- the sequencer simply carried on,
	// so render_line and render_bank drifted steadily out of step with the
	// display. The layers stayed individually correct, which made it look like
	// a decode bug rather than a timing one.
	//
	// Restarting is deferred to a tile boundary rather than taken immediately:
	// abandoning a request mid-flight would leave sdr_req toggled with an ack
	// still outstanding, and the next request would pair with the wrong reply.
	reg restart_req;
	reg [63:0] gfx_a, gfx_b;
	reg [25:0] gfx_addr_r;

	wire [127:0] win = {gfx_b, gfx_a};

	// The 12 (or 6) bytes we want start at gfx_base[2:0] inside that window.
	// For 16x16 the offset is 0 or 4; for 8x8 it is 0, 2, 4 or 6.
	reg [95:0] row_bytes;
	always @* begin
		case (gfx_addr_r[2:0])
			3'd0:    row_bytes = win[95:0];
			3'd2:    row_bytes = win[111:16];
			3'd4:    row_bytes = win[127:32];
			default: row_bytes = win[127:32] >> 16;   // offset 6
		endcase
	end

	// Four (or two) 24-bit groups. MAME reads a group as
	// w = (b0 << 16) | (b1 << 8) | b2, so the first byte becomes the MSB.
	function automatic [23:0] group(input [95:0] r, input [1:0] g);
		case (g)
			2'd0: group = {r[ 7: 0], r[15: 8], r[23:16]};
			2'd1: group = {r[31:24], r[39:32], r[47:40]};
			2'd2: group = {r[55:48], r[63:56], r[71:64]};
			default: group = {r[79:72], r[87:80], r[95:88]};
		endcase
	endfunction

	// Decrypt. tileno is the tile code within its 0xC0000 block for the 16x16
	// layers (4096 tiles per block) and the char code for text.
	wire [11:0] dec_tileno = tcode[11:0];

	wire [23:0] dec_in  [0:3];
	wire [23:0] dec_out [0:3];

	genvar gi;
	generate
		for (gi = 0; gi < 4; gi = gi + 1) begin : dec
			assign dec_in[gi] = group(row_bytes, gi[1:0]);
			spi_tile_decrypt u
			(
				.din    (dec_in[gi]),
				.tileno (dec_tileno),
				.key1   (tkey1),
				.key2   (tkey2),
				.key3   (tkey3),
				.dout   (dec_out[gi])
			);
		end
	endgenerate

	// Pixel extraction, MSB = highest plane.
	function automatic [5:0] pix16(input [23:0] v, input [1:0] p);
		case (p)
			2'd0:    pix16 = {v[20], v[16], v[12], v[ 8], v[ 4], v[ 0]};
			2'd1:    pix16 = {v[21], v[17], v[13], v[ 9], v[ 5], v[ 1]};
			2'd2:    pix16 = {v[22], v[18], v[14], v[10], v[ 6], v[ 2]};
			default: pix16 = {v[23], v[19], v[15], v[11], v[ 7], v[ 3]};
		endcase
	endfunction

	// The char layer is 5bpp, so v[23:20] (plane offset 0) is unused by design.
	/* verilator lint_off UNUSEDSIGNAL */
	function automatic [5:0] pix8(input [23:0] v, input [1:0] p);
		case (p)
			2'd0:    pix8 = {1'b0, v[16], v[12], v[ 8], v[ 4], v[ 0]};
			2'd1:    pix8 = {1'b0, v[17], v[13], v[ 9], v[ 5], v[ 1]};
			2'd2:    pix8 = {1'b0, v[18], v[14], v[10], v[ 6], v[ 2]};
			default: pix8 = {1'b0, v[19], v[15], v[11], v[ 7], v[ 3]};
		endcase
	endfunction
	/* verilator lint_on UNUSEDSIGNAL */

	// ------------------------------------------------------------------
	// Line buffers: 2 banks x 320 entries of {colour[3:0], pixel[5:0]}
	// ------------------------------------------------------------------
	reg  [9:0] lb_wr_addr;
	reg  [9:0] lb_wr_data;
	reg  [3:0] lb_we;      // one bit per layer

	assign lb_bank = render_bank;

	// The bank the MIXER reads. It has to switch exactly on the display's line
	// boundary, and render_bank cannot do that: the renderer defers its flip to
	// a tile boundary (deliberately -- see the restart path above; abandoning an
	// SDRAM fetch with its ack outstanding is worse), so the flip lands at hcnt
	// 0, 1 or 2 and jitters from line to line. Until it happened the display was
	// still reading the PREVIOUS line's buffer, which is the error band in
	// source columns 2-5 that section 13c of PLAN.md measures.
	//
	// vcnt[0] switches on exactly the right edge, costs nothing, and cannot
	// drift out of step: VTOTAL is 296, so the parity toggles every line
	// including across the frame wrap. render_bank still owns the WRITE side,
	// unchanged, so the renderer keeps its safe tile-boundary restart.
	wire disp_bank = ~vcnt[0];
	wire [9:0] lb_rd_addr = {lb_wrap ? ~disp_bank : disp_bank, lb_x};

	spi_dpram #(.DW(10), .AW(10)) lbuf_back
		(.wr_clk(clk), .rd_clk(clk), .wr_addr(lb_wr_addr), .wr_data(lb_wr_data), .wr_en(lb_we[0]),
		 .rd_addr(lb_rd_addr), .rd_data(lb_back));
	spi_dpram #(.DW(10), .AW(10)) lbuf_midl
		(.wr_clk(clk), .rd_clk(clk), .wr_addr(lb_wr_addr), .wr_data(lb_wr_data), .wr_en(lb_we[1]),
		 .rd_addr(lb_rd_addr), .rd_data(lb_midl));
	spi_dpram #(.DW(10), .AW(10)) lbuf_fore
		(.wr_clk(clk), .rd_clk(clk), .wr_addr(lb_wr_addr), .wr_data(lb_wr_data), .wr_en(lb_we[2]),
		 .rd_addr(lb_rd_addr), .rd_data(lb_fore));
	spi_dpram #(.DW(10), .AW(10)) lbuf_text
		(.wr_clk(clk), .rd_clk(clk), .wr_addr(lb_wr_addr), .wr_data(lb_wr_data), .wr_en(lb_we[3]),
		 .rd_addr(lb_rd_addr), .rd_data(lb_text));

	// Screen x of the pixel currently being emitted.
	reg signed [10:0] emit_x;
	reg        [3:0]  emit_i;     // 0..15 for tiles, 0..7 for text

	wire [1:0] emit_grp = emit_i[3:2];
	wire [1:0] emit_sub = emit_i[1:0];
	wire [5:0] emit_pix = is_text ? pix8 (dec_out[{1'b0, emit_grp[0]}], emit_sub)
	                              : pix16(dec_out[emit_grp],           emit_sub);

	wire emit_last = is_text ? (emit_i == 4'd7) : (emit_i == 4'd15);

	assign dbg_tcode    = tcode;
	assign dbg_gfx_addr = gfx_base;
	assign dbg_emit     = (state == S_EMIT);
	assign dbg_busy     = busy;
	assign dbg_rowscroll = rowscroll;
	assign dbg_xstart    = x_start;
	assign dbg_latch     = (state == S_GB_WT) && (sdr_ack == sdr_req);
	assign dbg_finex     = fine_x;
	assign dbg_col       = col;
	assign dbg_emitx     = emit_x;
	assign dbg_pix       = emit_pix;
	assign dbg_emiti     = emit_i;

	// ------------------------------------------------------------------
	// Sequencer
	// ------------------------------------------------------------------
	always @(posedge clk) begin
		lb_we <= 4'b0000;

		if (reset) begin
			state       <= S_IDLE;
			busy        <= 1'b0;
			sdr_req     <= 1'b0;
			restart_req <= 1'b0;
			dbg_overruns  <= 16'd0;
			dbg_ovr_layer <= 2'd0;
			dbg_text_col  <= 6'd0;
		end
		else begin
			if (line_start) begin
				restart_req <= 1'b1;
				// Still rendering when the next line began: this line is about
				// to be cut short.
				if (busy) begin
					dbg_overruns  <= dbg_overruns + 16'd1;
					dbg_ovr_layer <= layer;
					if (layer == L_TEXT) dbg_text_col <= col;
					else                 dbg_text_col <= 6'd0;
				end
			end

			// A tile boundary is the safe place to abandon the rest of a line.
			if (restart_req && (state == S_IDLE || state == S_NEXT)) begin
				restart_req <= 1'b0;
				render_line <= next_line;
				// Derived from the line being rendered, NOT toggled. The mixer
				// reads line L from ~L[0] (disp_bank above), so the only correct
				// write bank is ~next_line[0]. A free-running `~render_bank`
				// satisfies that too -- but only if its phase happens to line up
				// with vcnt, and nothing established that phase: render_bank has
				// no reset value and its parity is whatever the first restart
				// after reset made it. Half of all resets came up inverted, and
				// then the renderer wrote line N+1 into the bank being displayed
				// for line N, so the display showed the stale line N-1 ahead of
				// the write sweep and N+1 behind it, with the crossover jittering
				// frame to frame. That is a one-line displacement in whichever
				// layer is opaque -- invisible on flat background, which is why
				// it read as "a band of interference" only where the fore layer
				// had contrasty content, and why a plain reset often "fixed" it.
				// Deriving the bank makes the invariant structural.
				render_bank <= ~next_line[0];
				layer       <= L_BACK;
				col         <= 6'd0;
				busy        <= 1'b1;
				rowscroll   <= 16'd0;
				state       <= S_LSTART;
			end
			else case (state)

			// Nothing to do here: starting a line is handled by the restart
			// path above, which also covers the overrun case. Having a second
			// line_start branch here fired the restart twice, one cycle apart,
			// and the extra render_bank toggle put the mixer on the wrong buffer.
			S_IDLE: ;

			S_LSTART: begin
				if (layer_off[layer]) begin
					if (layer == L_TEXT) begin
						busy  <= 1'b0;
						state <= S_IDLE;
					end
					else layer <= layer + 2'd1;   // stay here and re-test
				end
				else begin
					col   <= 6'd0;
					// TEXT is the layer with no rowscroll table; back, midl and
					// fore all have one (rs_base 0x200 / 0x600 / 0xA00). The old
					// code read `layer != L_FORE` but tested it BEFORE the
					// non-blocking layer increment landed, so it was really
					// asking about the layer just finished -- same result, but
					// testing the new layer here needs L_TEXT.
					state <= (rowscroll_enable && layer != L_TEXT) ? S_RS_REQ
					                                               : S_TM_REQ;
				end
			end

			// -------- rowscroll table --------------------------------
			S_RS_REQ: begin
				tm_addr <= rs_base + {3'd0, rs_index[8:1]};
				state   <= S_RS_WT;
			end
			// Two cycles, not one: tm_addr is a register, so the RAM only sees
			// it the cycle after S_RS_REQ, and the RAM registers its output on
			// top of that. Latching in S_RS_WT reads the previous entry.
			S_RS_WT: state <= S_RS_LAT;
			S_RS_LAT: begin
				rowscroll <= rs_index[0] ? tm_data[31:16] : tm_data[15:0];
				state     <= S_TM_REQ;
			end

			// -------- tile word --------------------------------------
			S_TM_REQ: begin
				tm_addr <= tm_base + {2'd0, tile_index[10:1]};
				state   <= S_TM_WT;
			end
			S_TM_WT: state <= S_TM_LAT;      // tilemap RAM has 1 cycle latency
			S_TM_LAT: begin
				tword <= tile_index[0] ? tm_data[31:16] : tm_data[15:0];
				state <= S_GA_REQ;
			end

			// -------- graphics ---------------------------------------
			S_GA_REQ: begin
				gfx_addr_r <= gfx_base;
				sdr_addr   <= {gfx_base[25:3], 3'b000};
				sdr_req    <= ~sdr_req;
				state      <= S_GA_WT;
			end
			S_GA_WT: if (sdr_ack == sdr_req) begin
				gfx_a <= sdr_dout;
				// An 8x8 char row is only 6 bytes. At byte offset 0 or 2 those
				// six sit inside the first aligned 8-byte word, so the second
				// read fetches nothing that gets used. char_off = code*48 +
				// fine_y*6 makes the offset cycle 0,6,4,2 -- half the rows -- and
				// skipping the read there removes about a fifth of the text
				// layer's SDRAM traffic. With the bus at ~96% of a line that is
				// worth having. The 16x16 layers need 12 bytes and always
				// straddle, so they still take both reads.
				if (is_text && gfx_base[2:0] <= 3'd2) begin
					emit_i <= 4'd0;
					emit_x <= ($signed({5'd0, col}) * 11'sd8)
					          - $signed({7'd0, fine_x});
					state  <= S_EMIT;
				end
				else state <= S_GB_REQ;
			end

			S_GB_REQ: begin
				sdr_addr <= {gfx_addr_r[25:3], 3'b000} + 26'd8;
				sdr_req  <= ~sdr_req;
				state    <= S_GB_WT;
			end
			S_GB_WT: if (sdr_ack == sdr_req) begin
				gfx_b  <= sdr_dout;
				emit_i <= 4'd0;
				emit_x <= is_text ? ($signed({5'd0, col}) * 11'sd8)  - $signed({7'd0, fine_x})
				                  : ($signed({5'd0, col}) * 11'sd16) - $signed({7'd0, fine_x});
				state  <= S_EMIT;
			end

			// -------- emit pixels ------------------------------------
			S_EMIT: begin
				if (emit_x >= 0 && emit_x < 11'sd320) begin
					lb_wr_addr <= {render_bank, emit_x[8:0]};
					lb_wr_data <= {tcolor, emit_pix};
					lb_we      <= (4'b0001 << layer);
				end
				emit_x <= emit_x + 11'sd1;
				emit_i <= emit_i + 4'd1;
				if (emit_last) state <= S_NEXT;
			end

			S_NEXT: begin
				if (col == col_count - 6'd1) begin
					col <= 6'd0;
					if (layer == L_TEXT) begin
						busy  <= 1'b0;
						state <= S_IDLE;
					end
					else begin
						layer <= layer + 2'd1;
						// Only the 16x16 layers have rowscroll tables.
						state <= S_LSTART;
						if (layer == L_FORE) rowscroll <= 16'd0;
					end
				end
				else begin
					col   <= col + 6'd1;
					state <= S_TM_REQ;
				end
			end

			default: state <= S_IDLE;
			endcase
		end
	end

	// ------------------------------------------------------------------
	// Budget
	//
	// Per line: 3 x 21 + 41 = 104 tiles, each costing 2 SDRAM reads and 16 (or
	// 8) emit cycles. SDRAM reads are ~8 clk_ram = 4 clk_sys each, so roughly
	// 104 * (8 + 16) = 2500 clk_sys, against 448 * 8 = 3584 available. Tight
	// enough to be worth measuring once sprites are sharing the line.
	// ------------------------------------------------------------------

endmodule
