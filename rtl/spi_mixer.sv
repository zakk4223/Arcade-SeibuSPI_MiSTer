//============================================================================
//  SlopperPI - Seibu SPI / SXX2E
//
//  Layer mixer (screen_update_spi, seibuspi_v.cpp:434).
//
//  MAME composites in this exact order, and the odd bits matter:
//
//      if back disabled:  fill with hard black (a raw fill, NOT palette pen 0)
//      else:              back layer, OPAQUE (transparent pens drawn too)
//      sprite priority 0
//      if back+fore+sprite all enabled: back layer again, TRANSPARENT
//      if fore enabled:   sprite priority 1
//      if midl enabled:   midl layer
//      if fore disabled:  sprite priority 1
//      sprite priority 2
//      if fore enabled:   fore layer
//      sprite priority 3
//      if text enabled:   text layer
//
//  layer_enable is active LOW (0 = layer on). The "back layer again" step is
//  MAME's `(m_layer_enable & 0x15) == 0`, i.e. back, fore and sprites all on.
//
//  Sprites arrive as a single pixel per column carrying its priority, because
//  that is how MAME works: every sprite is rendered into one buffer tagged with
//  its priority, so sprite-versus-sprite occlusion is decided purely by list
//  order and a high-index sprite can erase a lower-priority one. Each "sprite
//  priority N" step draws that pixel only if its tag matches.
//
//  Alpha blending is MAME's alpha_blend_r32(dest, pen, 0x7f) -- (src*127 +
//  dst*129) >> 8, not a 50/50 mix -- applied to a hand-picked set of pens.
//  MAME's own table is an approximation (its TODO says as much); we reproduce
//  it exactly rather than inventing something different.
//
//  The composite is PIPELINED across the eight clk_sys cycles a pixel lasts.
//  Ten blend steps of exact arithmetic in one combinational chain does not
//  close timing -- that is why this was a plain average for a long time -- but
//  the chain only has to produce one result per pixel, so there are seven
//  spare cycles to spread it over. See "Composite pipeline" below.
//
//  Palette entries are BGR555 packed two per RAM word:
//      bits [14:0] = even pen, [29:15] = odd pen, each R[4:0] G[9:5] B[14:10]
//============================================================================

module spi_mixer
(
	input             clk,          // clk_sys
	input             reset,
	input             ce_pix,

	input       [4:0] layer_enable, // 0 = on: {sprite, text, fore, midl, back}

	// Line buffer contents for this pixel: {colour[3:0], pixel[5:0]}.
	// The text layer is 5bpp, so lb_text[5] is always zero.
	/* verilator lint_off UNUSEDSIGNAL */
	input       [9:0] lb_back,
	input       [9:0] lb_midl,
	input       [9:0] lb_fore,
	input       [9:0] lb_text,
	/* verilator lint_on UNUSEDSIGNAL */
	// Sprite: {valid, priority[1:0], colour[5:0], pixel[5:0]}
	input      [14:0] lb_spr,

	// Palette RAM read port (two pens per entry)
	output reg [11:0] pal_addr,
	input      [29:0] pal_data,

	output reg  [7:0] red,
	output reg  [7:0] green,
	output reg  [7:0] blue
);

`include "spi_defs.vh"

	// ------------------------------------------------------------------
	// Palette indices for this pixel
	//
	//   back: 4096 + colour*64          midl: 4096 + (colour+16)*64
	//   fore: 4096 + (colour+8)*64      text: 5632 + colour*32
	//   sprites: colour*64 (base 0)
	// ------------------------------------------------------------------
	wire [12:0] pen_back = 13'(PAL_BASE_TILES + {4'd0, lb_back[9:6], 6'd0} + {7'd0, lb_back[5:0]});
	wire [12:0] pen_midl = 13'(PAL_BASE_TILES + 13'd1024                       // (colour+16)*64
	                     + {4'd0, lb_midl[9:6], 6'd0} + {7'd0, lb_midl[5:0]});
	wire [12:0] pen_fore = 13'(PAL_BASE_TILES + 13'd512                        // (colour+8)*64
	                     + {4'd0, lb_fore[9:6], 6'd0} + {7'd0, lb_fore[5:0]});
	wire [12:0] pen_text = PAL_BASE_TEXT  + {4'd0, lb_text[9:6], 5'd0} + {8'd0, lb_text[4:0]};
	wire [12:0] pen_spr  = {1'b0, lb_spr[11:6], 6'd0} + {7'd0, lb_spr[5:0]};

	// Transparency: pen 63 for the 6bpp layers, 31 for the 5bpp text layer.
	//
	// These are combinational on lb_*, so they follow the line buffers the
	// instant lb_x advances. The composite is sampled at step 1 of the FOLLOWING
	// pixel (see the output register below), where lb_* has already moved on --
	// so using them directly pairs pixel N's colours with pixel N+1's draw
	// decisions. They are latched below, alongside the colour each one belongs
	// to, and only the latched copies may be used in the composite.
	wire trans_back = (lb_back[5:0] == 6'd63);
	wire trans_midl = (lb_midl[5:0] == 6'd63);
	wire trans_fore = (lb_fore[5:0] == 6'd63);
	wire trans_text = (lb_text[4:0] == 5'd31);
	wire spr_valid  = lb_spr[14];
	wire [1:0] spr_pri = lb_spr[13:12];

	// Pixel-N-aligned copies, captured with the matching rgb_* below.
	reg t_back, t_midl, t_fore, t_text, v_spr;
	reg [1:0] p_spr;

	// ------------------------------------------------------------------
	// Palette fetch sequencer
	//
	// Five lookups per pixel, one per layer, over the eight clk_sys cycles a
	// pixel lasts, using one read port.
	//
	// The order is the order the composite first NEEDS each colour, not the
	// layer order: sprites are wanted by the second composite step, so they go
	// first. That is what gives the composite five cycles to run in instead of
	// one. (Sprites used to be fetched last, which is why the whole chain had
	// to be evaluated in a single cycle.)
	//
	// Two facts about the step counter, both easy to get wrong:
	//
	// * `step` lags `div` in spi_video_timing by one cycle, because ce_pix is
	//   registered there and `step <= 0` is registered here. So step 7 is the
	//   FIRST clk_sys cycle of an hcnt period and steps 0-6 follow it. lb_* is
	//   a registered line-buffer read off hcnt, so it settles one cycle after
	//   hcnt moves -- which lands it exactly on step 0. Every step from 0 to 7
	//   in sequence therefore sees the same pixel's lb_*, and any of them may
	//   be used to fetch. Steps 1-5 are used here purely to leave the tail of
	//   the composite room before the ce_pix that samples the output.
	// * A colour written by the case below at "step N" is captured on the edge
	//   ENDING step N, so it is readable from step N+1, not during step N.
	//   Reading one step early shifts the whole picture a pixel and is the
	//   first thing to check if the frame diff comes back with dx=1.
	// ------------------------------------------------------------------
	reg [2:0] step;
	reg [14:0] rgb_back, rgb_midl, rgb_fore, rgb_text, rgb_spr;

	reg [12:0] pen_sel;
	always @* begin
		case (step)
			3'd1: pen_sel = pen_spr;
			3'd2: pen_sel = pen_back;
			3'd3: pen_sel = pen_midl;
			3'd4: pen_sel = pen_fore;
			3'd5: pen_sel = pen_text;
			// Steps 0, 6 and 7 issue reads nothing latches. Holding pen_text
			// through them is a don't care that costs no extra mux input.
			default: pen_sel = pen_text;
		endcase
	end

	// One RAM entry holds two pens; bit 0 of the index selects the half. The
	// selector has to be delayed to line up with the data: pal_addr is a
	// register, so the RAM only sees it the cycle after it is assigned, and the
	// RAM registers its output on top of that -- two cycles from issue to data.
	reg pen_lsb, pen_lsb_d;
	wire [14:0] pal_pen = pen_lsb_d ? pal_data[29:15] : pal_data[14:0];

	// ------------------------------------------------------------------
	// Alpha table (seibuspi_v.cpp:603)
	//
	// Indexed by the final palette pen. MAME sets these ranges and explicitly
	// leaves the commented-out ones alone because they break specific games.
	// ------------------------------------------------------------------
	function automatic alpha_of(input [12:0] pen);
		alpha_of =
			// sprites
			   (pen >= 13'h0730 && pen < 13'h0740)
			|| (pen >= 13'h0780 && pen < 13'h07A0)
			|| (pen >= 13'h0FC0 && pen < 13'h1000)
			// fore layer
			|| (pen >= 13'h1360 && pen < 13'h1380)
			|| (pen >= 13'h13B0 && pen < 13'h13C0)
			|| (pen >= 13'h13F0 && pen < 13'h1400)
			// midl layer
			|| (pen >= 13'h15B0 && pen < 13'h15C0)
			|| (pen >= 13'h15F0 && pen < 13'h1600)
			// text layer
			|| (pen >= 13'h1770 && pen < 13'h1780)
			|| (pen >= 13'h17F0 && pen < 13'h1800);
	endfunction

	reg a_back, a_midl, a_fore, a_text, a_spr;

	// ------------------------------------------------------------------
	// Composite
	//
	// Each step either replaces the accumulator or blends 50/50 into it.
	// BGR555 is expanded to 8 bits per channel the way MAME's pal5bit does:
	// x << 3 | x >> 2.
	// ------------------------------------------------------------------
	function automatic [23:0] expand(input [14:0] c);
		expand = {{c[ 4:0], c[ 4:2]},    // R
		          {c[ 9:5], c[ 9:7]},    // G
		          {c[14:10], c[14:12]}}; // B
	endfunction

	// MAME's alpha_blend_r32(dest, pen, 0x7f), exactly:
	//
	//     out = (src*127 + dst*129) >> 8
	//
	// which is NOT a 50/50 mix -- the destination keeps 129/256. Rearranged to
	// avoid both a multiplier and a signed intermediate:
	//
	//     127*s + 129*d  ==  127*(s + d) + 2*d
	//                    ==  ((s+d) << 7) - (s+d) + (d << 1)
	//
	// Three adder levels, all unsigned, no term ever negative: (s+d)<<7 >= (s+d)
	// for every input, and the maximum 255,255 gives 65280, which is 255 after
	// the shift. Truncating, like C's >>.
	//
	// This used to be a plain average, because ten exact blends in series blew
	// clk_sys setup by 6 ns (and the average-plus-correction form by 21 ns).
	// The fix is not cheaper arithmetic, it is not doing it all in one cycle --
	// see the composite pipeline below.
	/* verilator lint_off UNUSEDSIGNAL */
	function automatic [7:0] mix8(input [7:0] d, input [7:0] s);
		reg [8:0] sum;
		reg [15:0] acc;
		begin
			sum  = {1'b0, d} + {1'b0, s};
			acc  = {sum, 7'd0} - {7'd0, sum} + {7'd0, d, 1'b0};
			mix8 = acc[15:8];
		end
	endfunction
	/* verilator lint_on UNUSEDSIGNAL */

	function automatic [23:0] blend(input [23:0] dst, input [23:0] src, input a);
		blend = a ? {mix8(dst[23:16], src[23:16]),
		             mix8(dst[15: 8], src[15: 8]),
		             mix8(dst[ 7: 0], src[ 7: 0])}
		          : src;
	endfunction

	wire en_back = ~layer_enable[0];
	wire en_midl = ~layer_enable[1];
	wire en_fore = ~layer_enable[2];
	wire en_text = ~layer_enable[3];
	wire en_spr  = ~layer_enable[4];

	// MAME: (layer_enable & 0x15) == 0  =>  back, fore and sprites all enabled
	wire back_redraw = en_back && en_fore && en_spr;

	always @(posedge clk) begin
		if (reset) begin
			step     <= 3'd0;
			pal_addr <= 12'd0;
			pen_lsb  <= 1'b0;
		end
		else begin
			// ---- fetch ------------------------------------------------
			pal_addr <= pen_sel[12:1];
			pen_lsb  <= pen_sel[0];

			pen_lsb_d <= pen_lsb;

			// Issued at step N, latched at the edge ending step N+2, so the
			// value is readable from step N+3 on.
			case (step)
				3'd3: begin rgb_spr  <= pal_pen; a_spr  <= alpha_of(pen_spr);
				            v_spr <= spr_valid; p_spr <= spr_pri; end
				3'd4: begin rgb_back <= pal_pen; a_back <= alpha_of(pen_back); t_back <= trans_back; end
				3'd5: begin rgb_midl <= pal_pen; a_midl <= alpha_of(pen_midl); t_midl <= trans_midl; end
				3'd6: begin rgb_fore <= pal_pen; a_fore <= alpha_of(pen_fore); t_fore <= trans_fore; end
				3'd7: begin rgb_text <= pal_pen; a_text <= alpha_of(pen_text); t_text <= trans_text; end
				default: ;
			endcase

			if (ce_pix) step <= 3'd0;
			else if (step != 3'd7) step <= step + 3'd1;
		end
	end

	// ------------------------------------------------------------------
	// Composite pipeline
	//
	// MAME's ten composite steps, spread over five clk_sys cycles instead of
	// crammed into one. Only one result per pixel is needed and a pixel is
	// eight cycles long, so the spare cycles are free; what they buy is the
	// exact 127/129 blend, which does not fit as a single chain.
	//
	//   step 5  q_spr0 = m0, m1, m2   back, sprite pri 0, back again
	//   step 6  q_midl = m3, m4      sprite pri 1 (fore on), midl
	//   step 7  q_spr2 = m5, m6      sprite pri 1 (fore off), sprite pri 2
	//   step 0  q_spr3 = m7, m8      fore, sprite pri 3      (next pixel's
	//   step 1  q_text = m9          text                     step numbers)
	//   step 2  published to red/green/blue
	//
	// The tail runs during the next pixel's steps 0 and 1, which is safe
	// because every source it reads is a register that the next pixel does not
	// overwrite until later: rgb_fore is rewritten at step 6, rgb_spr at
	// step 3, rgb_text at step 7. So no stage ever mixes two pixels' data --
	// the fault section 13a is about -- and the published result still lands
	// well before the ce_pix edge that samples it, leaving the output phase
	// and the callers' two-pixel lead exactly as they were.
	// ------------------------------------------------------------------
	reg [23:0] q_spr0, q_midl, q_spr2, q_spr3, q_text;

	wire [23:0] cback = expand(rgb_back);
	wire [23:0] cmidl = expand(rgb_midl);
	wire [23:0] cfore = expand(rgb_fore);
	wire [23:0] ctext = expand(rgb_text);
	wire [23:0] cspr  = expand(rgb_spr);

	wire draw_spr0 = en_spr && v_spr && (p_spr == 2'd0);
	wire draw_spr1 = en_spr && v_spr && (p_spr == 2'd1);
	wire draw_spr2 = en_spr && v_spr && (p_spr == 2'd2);
	wire draw_spr3 = en_spr && v_spr && (p_spr == 2'd3);

	// With the back layer disabled MAME does `bitmap.fill(0, cliprect)`
	// (seibuspi_v.cpp:452), which writes the raw RGB value 0 into a
	// bitmap_rgb32 -- hard black. It is NOT a draw of palette pen 0, and the
	// two are only the same when pen 0 happens to be black. In the SXX2E test
	// menu pen 0 is 0x7FFF, so reading the palette here painted the whole
	// screen white and left the (correctly rendered) text sitting on white.
	// stage 1, step 5
	wire [23:0] m0 = en_back ? cback : 24'h000000;                        // opaque
	wire [23:0] m1 = draw_spr0                ? blend(m0, cspr,  a_spr)  : m0;
	wire [23:0] m2 = (back_redraw && !t_back) ? blend(m1, cback, a_back) : m1;
	// stage 2, step 6
	wire [23:0] m3 = (en_fore && draw_spr1)   ? blend(q_spr0, cspr, a_spr) : q_spr0;
	wire [23:0] m4 = (en_midl && !t_midl)     ? blend(m3, cmidl, a_midl) : m3;
	// stage 3, step 7
	wire [23:0] m5 = (!en_fore && draw_spr1)  ? blend(q_midl, cspr, a_spr) : q_midl;
	wire [23:0] m6 = draw_spr2                ? blend(m5, cspr,  a_spr)  : m5;
	// stage 4, step 0
	wire [23:0] m7 = (en_fore && !t_fore)     ? blend(q_spr2, cfore, a_fore) : q_spr2;
	wire [23:0] m8 = draw_spr3                ? blend(m7, cspr,  a_spr)  : m7;
	// stage 5, step 1
	wire [23:0] m9 = (en_text && !t_text)     ? blend(q_spr3, ctext, a_text) : q_spr3;

	// Each stage runs in the step named above, on colours that landed earlier
	// and are still held. At most two exact blends sit in series in any of them.
	always @(posedge clk) begin
		case (step)
			3'd5: q_spr0 <= m2;
			3'd6: q_midl <= m4;
			3'd7: q_spr2 <= m6;
			3'd0: q_spr3 <= m8;
			3'd1: q_text <= m9;
			default: ;
		endcase
	end

	// q_text is complete at the end of step 1 and holds until step 1 of the
	// pixel after. Publishing at step 2 is one clk_sys cycle later than the
	// pre-pipeline mixer published, which is a fraction of a pixel: the value
	// is stable across steps 3-7 either way, so the ce_pix edge that samples it
	// sees the same colour for the same pixel. Callers still lead lb_x by two.
	//
	// No blanking here. `visible` refers to the pixel being *displayed*, but the
	// pixel being *composited* is two ahead, so gating on it blacked out the
	// first column of every line -- pixel 0 is processed during hblank. The
	// video path already blanks using HBlank/VBlank.
	always @(posedge clk) begin
		if (reset)              {red, green, blue} <= 24'd0;
		else if (step == 3'd2)  {red, green, blue} <= q_text;
	end

endmodule
