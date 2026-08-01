//============================================================================
//  SlopperPI - Seibu SPI / SXX2E
//
//  Layer mixer (screen_update_spi, seibuspi_v.cpp:434).
//
//  MAME composites in this exact order, and the odd bits matter:
//
//      if back disabled:  fill with pen 0
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
//  Alpha blending is a 50/50 mix applied to a hand-picked set of pens. MAME's
//  own table is an approximation (its TODO says as much); we reproduce it
//  exactly rather than inventing something different.
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
	input             visible,      // inside the 320x240 active area

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
	wire trans_back = (lb_back[5:0] == 6'd63);
	wire trans_midl = (lb_midl[5:0] == 6'd63);
	wire trans_fore = (lb_fore[5:0] == 6'd63);
	wire trans_text = (lb_text[4:0] == 5'd31);
	wire spr_valid  = lb_spr[14];
	wire [1:0] spr_pri = lb_spr[13:12];

	// ------------------------------------------------------------------
	// Palette fetch sequencer
	//
	// Six lookups per pixel (pen 0 plus the five layers) over the eight clk_sys
	// cycles a pixel lasts, using one read port.
	// ------------------------------------------------------------------
	reg [2:0] step;
	reg [14:0] rgb0, rgb_back, rgb_midl, rgb_fore, rgb_text, rgb_spr;

	reg [12:0] pen_sel;
	always @* begin
		case (step)
			3'd0: pen_sel = 13'd0;
			3'd1: pen_sel = pen_back;
			3'd2: pen_sel = pen_midl;
			3'd3: pen_sel = pen_fore;
			3'd4: pen_sel = pen_text;
			default: pen_sel = pen_spr;
		endcase
	end

	// One RAM entry holds two pens; bit 0 of the index selects the half.
	reg pen_lsb;
	wire [14:0] pal_pen = pen_lsb ? pal_data[29:15] : pal_data[14:0];

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

	// 50/50 mix, matching alpha_blend_r32(dest, pen, 0x7f). Each channel is
	// summed in 9 bits before the shift so the carry is not lost.
	/* verilator lint_off UNUSEDSIGNAL */
	function automatic [7:0] mix8(input [7:0] a, input [7:0] b);
		reg [8:0] sum;      // sum[0] is discarded by the >>1
		begin
			sum  = {1'b0, a} + {1'b0, b};
			mix8 = sum[8:1];
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
			step    <= 3'd0;
			pal_addr <= 12'd0;
			pen_lsb  <= 1'b0;
			{red, green, blue} <= 24'd0;
		end
		else begin
			// ---- fetch ------------------------------------------------
			pal_addr <= pen_sel[12:1];
			pen_lsb  <= pen_sel[0];

			// The entry requested last cycle lands now.
			case (step)
				3'd1: begin rgb0     <= pal_pen; end
				3'd2: begin rgb_back <= pal_pen; a_back <= alpha_of(pen_back); end
				3'd3: begin rgb_midl <= pal_pen; a_midl <= alpha_of(pen_midl); end
				3'd4: begin rgb_fore <= pal_pen; a_fore <= alpha_of(pen_fore); end
				3'd5: begin rgb_text <= pal_pen; a_text <= alpha_of(pen_text); end
				3'd6: begin rgb_spr  <= pal_pen; a_spr  <= alpha_of(pen_spr);  end
				default: ;
			endcase

			if (ce_pix) step <= 3'd0;
			else if (step != 3'd7) step <= step + 3'd1;
		end
	end

	// ------------------------------------------------------------------
	// The composite chain itself, evaluated once per pixel
	// ------------------------------------------------------------------
	wire [23:0] c0    = expand(rgb0);
	wire [23:0] cback = expand(rgb_back);
	wire [23:0] cmidl = expand(rgb_midl);
	wire [23:0] cfore = expand(rgb_fore);
	wire [23:0] ctext = expand(rgb_text);
	wire [23:0] cspr  = expand(rgb_spr);

	wire draw_spr0 = en_spr && spr_valid && (spr_pri == 2'd0);
	wire draw_spr1 = en_spr && spr_valid && (spr_pri == 2'd1);
	wire draw_spr2 = en_spr && spr_valid && (spr_pri == 2'd2);
	wire draw_spr3 = en_spr && spr_valid && (spr_pri == 2'd3);

	wire [23:0] m0 = en_back ? cback : c0;                              // opaque
	wire [23:0] m1 = draw_spr0                  ? blend(m0, cspr,  a_spr)  : m0;
	wire [23:0] m2 = (back_redraw && !trans_back) ? blend(m1, cback, a_back) : m1;
	wire [23:0] m3 = (en_fore && draw_spr1)     ? blend(m2, cspr,  a_spr)  : m2;
	wire [23:0] m4 = (en_midl && !trans_midl)   ? blend(m3, cmidl, a_midl) : m3;
	wire [23:0] m5 = (!en_fore && draw_spr1)    ? blend(m4, cspr,  a_spr)  : m4;
	wire [23:0] m6 = draw_spr2                  ? blend(m5, cspr,  a_spr)  : m5;
	wire [23:0] m7 = (en_fore && !trans_fore)   ? blend(m6, cfore, a_fore) : m6;
	wire [23:0] m8 = draw_spr3                  ? blend(m7, cspr,  a_spr)  : m7;
	wire [23:0] m9 = (en_text && !trans_text)   ? blend(m8, ctext, a_text) : m8;

	always @(posedge clk) begin
		if (ce_pix) {red, green, blue} <= visible ? m9 : 24'd0;
	end

endmodule
