//============================================================================
//  SeibuSPI - Seibu SPI / SXX2E
//
//  Video timing generator.
//
//  The Seibu CRTC is programmable, but every SPI game writes essentially the
//  same values, and MAME hardcodes the resulting raster (seibuspi.cpp:898):
//
//    dot clock 28.63636 MHz / 4 = 7.1590909 MHz  ( = clk_sys / 8 )
//    448 x 296 total, 320 x 240 visible            => 53.99 Hz
//
//  VBSTART is 240. The CRTC register (0x408) nominally says vblank starts at
//  253, but the real board only displays 240 lines -- confirmed on hardware:
//  turning the monitor's height down does NOT reveal lines 240..252, so they are
//  blanked, not overscanned. MAME blanks at 240 for the same reason. A brief
//  experiment set this to 253 and un-blanked two overscan tile-strips the board
//  does not show, so it was reverted. VBSTART drives both the vblank output and
//  the 386's vblank IRQ; whether the real IRQ fires at 240 or 253 is still open
//  and needs an INTR-pin capture to settle -- see spi_defs.vh and memory
//  seibuspi-crtc-timing-verified.
//
//  THE RASTER NEVER STOPS. Not for a savestate, not for anything. An earlier
//  version froze the counters for the length of a savestate transfer, which
//  froze `ce_pix` and -- because sync and blanking are combinational decodes of
//  the counters -- held HSync and VSync flat for about 14 ms. MiSTer's
//  low-latency scaler is a line-locked consumer and saw one scanline stretch to
//  hundreds of times its length; the picture visibly broke on every save and
//  every load. PGM, which this core's savestate framework came from, cannot do
//  this: its pixel enable is tied to a literal 1 (`PGM.sv:130`) and its raster
//  has no pause term at all. PLAN.md 42.
//
//  What `pause` gates now is one bit: the vblank interrupt. It is DEFERRED,
//  never dropped -- if the board is frozen when the raster crosses into
//  blanking, `vbl_pend` remembers it and `vbl_rise` goes out the moment the
//  board is let go. That is exactly the semantics rtl/spi_ss.sv's header argues
//  for ("the interrupt is deferred by the length of the transfer along with
//  everything else"), obtained without stopping the display.
//
//  `line_start` deliberately keeps running, so the tile and sprite engines keep
//  refilling their line buffers from a frozen VRAM and the display shows a
//  correct still picture rather than a smear. Neither engine touches the main
//  RAM port the transfer owns; the DMA that does is started by the 386, which
//  is frozen.
//
//  ------------------------------------------------------------------------
//  VARIABLE REFRESH: the field gets shorter, the line never does.
//
//  The OSD refresh-rate option changes VTOTAL and nothing else. The pixel is
//  always exactly 8 clk_sys cycles, so HTOTAL stays 448 and the line rate stays
//  57.272727 MHz / 3584 = 15980.11 Hz in every mode. Only the count of blanked
//  lines moves; the 240 active lines are untouched, bit for bit.
//
//      mode        VTOTAL   blanked   refresh    error     vblank
//      Normal        296       56     53.9869    native    3.50 ms
//      50 Hz         320       80     49.9379    -0.124%   5.01 ms
//      57 Hz         280       40     57.0718    +0.126%   2.50 ms
//      60 Hz         266       26     60.0756    +0.126%   1.63 ms
//
//  This replaced a Bresenham that scaled the PIXEL period instead, holding the
//  frame at 448 x 296 in every mode. That kept the vblank window at 56 lines
//  and gave much finer refresh control (60 Hz landed on 59.9971), and it was
//  chosen because "SPI games run their sprite and tilemap DMA in the vblank
//  handler" and shortening VTOTAL to 266 cuts that window from 3.5 ms to
//  1.6 ms.
//
//  THAT REASONING WAS RIGHT ABOUT THE WINDOW AND WRONG ABOUT THE DEMAND ON IT,
//  and the difference was measured rather than argued. sim/tb_boot.cpp now taps
//  the DMA-busy line and the I/O-write line of every frame; across 4,712 frames
//  of rdfts, rfjet and rdft2 -- boot, attract and scripted gameplay:
//
//      worst DMA-busy line, ALL games, ALL frames ......... 240 .. 244
//      video-register writes past line 247, post-boot ..... rfjet 0, rdfts 0,
//                                                           rdft2 1 frame @290
//
//  The tilemap, palette and sprite DMA triggers on line 240 every frame and is
//  finished five lines later. VTOTAL 266 blanks 240..265 and the renderer owns
//  265, so the deadline is line 264: a twenty-line margin on the only thing
//  that writes VRAM. The frames that do run to line 290 are the handler sitting
//  in NON-video work -- 0x688 (Z80 program upload), 0x6D0/6D4/6D8 (DS2404
//  1-wire bit-banging), 0x680 (Z80 coin latch) -- which spills harmlessly into
//  active display, exactly as ordinary CPU work does. No scroll register
//  (0x600-0x60C) was ever written past line 247 in any frame of any game.
//
//  The one measured exception is rdft2 writing layer_enable (0x41C) at line 290
//  in a single frame out of 708, at what looks like a scene transition. Worst
//  case that is a one-scanline artifact on line 0 of one frame.
//
//  WHAT THE CHANGE BUYS. The pixel is a uniform integer 8 clk in every mode, so
//  the modules that resample video on a measured pixel-CE grid -- rmonic79's
//  crt_adjust / crt_vsize, as used by Raiden and Raiden II -- work at every
//  refresh rate rather than at Normal only. The old Bresenham emitted 7- and
//  8-cycle windows at 57/60 Hz, which those modules cannot follow. It also
//  removes the renderer ceiling entirely: a line is 3584 cycles in every mode,
//  so spi_layers' worst line stays where it was and there is no reclocking to
//  fit. And the 266- and 280-line fields fall below the ~285-line threshold at
//  which a consumer CRT stops treating the signal as 525/60 -- something a
//  fixed 296-line raster can never offer.
//
//  WHAT IT COSTS. Refresh precision: one line is 0.376% at 60 Hz, so 60.0756 is
//  the closest reachable and the old Bresenham's 59.9971 is gone. Raiden II is
//  +0.078% and Raiden 1 is +0.160% by the same mechanism, so this is the normal
//  standard for a VTOTAL-based core, and MiSTer's vsync_adjust tracks the core
//  rate anyway. And the game genuinely runs faster -- 60 Hz is +11.3% on the
//  vblank IRQ rate. It always did; only the arithmetic changed.
//
//  VTOTAL IS EVEN IN EVERY MODE, and spi_layers depends on it: its display-bank
//  select is vcnt[0], which only stays in step across the frame wrap if the
//  line count is even. 296, 320, 280 and 266 all are. Do not add an odd one.
//
//  SYNC POSITION IS FIXED. This module used to carry an "Analog Video H-Pos /
//  V-Pos" pair -- a two's complement -8..+7 nudge of the sync pulses, clamped
//  inside blanking, invisible over HDMI because DE never moved. CRT Adjust
//  (rtl/crt_adjust.sv, wired up in SeibuSPI.sv) does the same job properly:
//  H-Position shifts the CONTENT through a line buffer with sync left native,
//  which survives H-Size shrinking and reaches HDMI too, and V-Shift covers the
//  vertical half. Keeping both meant two controls that fought each other, so the
//  offsets were removed and the pulses are back to plain decodes.
//
//  HSync is a constant window in every mode. VSync is not: its start follows the
//  field length, so it stays a pair of registers latched at the frame wrap.
//
//  Mode and offsets are latched at the frame wrap, never mid-frame -- see the
//  raster-never-stops note above for what a mid-frame timing change does to a
//  line-locked scaler.
//============================================================================

module spi_video_timing
(
	input             clk,        // clk_sys, 57.272727 MHz
	input             reset,
	// Hold the vblank interrupt, and nothing else. See the header: the raster
	// itself is not stoppable any more, by design.
	input             pause,

	// OSD video timing: 0 Normal, 1 = 50 Hz, 2 = 57 Hz, 3 = 60 Hz. See the
	// VTOTAL table above.
	input       [1:0] video_mode,

	output reg        ce_pix,     // pixel enable, a uniform 7.1590909 MHz

	output reg  [9:0] hcnt,       // 0 .. HTOTAL-1
	output reg  [9:0] vcnt,       // 0 .. vtotal-1

	// The LAST line index of the selected field (vtotal-1), latched at the frame
	// wrap like everything else here. spi_layers needs it to find the last
	// blanked line; nothing outside the video path may use it, because the 386
	// must not be able to observe the mode.
	//
	// The decremented form is what is published, and it is not cosmetic. Both
	// this module and spi_layers compare vcnt against it every line, and the
	// obvious `vcnt == vtotal - 1` spends a 10-bit subtractor in each of the
	// three places -- where the fixed raster it replaced compared against a
	// constant for free. At 87% ALM that showed up as a FAILING fit: -0.260 on
	// spi_flash_derive's esi datapath, in a module this change never touched,
	// purely from the placement pressure. Subtract once, into a register.
	output reg  [9:0] vlast,

	output            hsync,
	output            vsync,
	output            hblank,
	output            vblank,

	output reg        line_start, // pulse at the start of each line
	output reg        vbl_rise,   // pulse on entry to vertical blanking

	// One tick from raising vbl_rise. A savestate takes its snapshot here and
	// releases here, so the 386 comes back at the raster phase it left at --
	// see rtl/spi_ss.sv.
	output            vbl_next
);

`include "spi_defs.vh"

	// ------------------------------------------------------------------
	// Pixel window: a fixed eight clk_sys cycles, in every mode.
	//
	// 57.272727 MHz / 8 = 7.1590909 MHz, the board's own dot clock
	// (28.63636 / 4). This is the divider the Bresenham replaced and then
	// replaced again; `div == 3'd7` is the same edge the accumulator carried on
	// at PIX_N 512, so Normal is unchanged to the cycle.
	// ------------------------------------------------------------------
	reg  [2:0] div;
	wire       pix_tick = (div == 3'd7);

	localparam [9:0] VS_WIDTH = VSEND - VSSTART;   //  8 lines, measured

	// ------------------------------------------------------------------
	// Field length per mode. VBSTART and the 240 active lines never move, so
	// these differ only in how many lines are blanked.
	// ------------------------------------------------------------------
	localparam [9:0] VTOTAL_50HZ = 10'd320;   // 49.9379 Hz, 80 blanked
	localparam [9:0] VTOTAL_57HZ = 10'd280;   // 57.0718 Hz, 40 blanked
	localparam [9:0] VTOTAL_60HZ = 10'd266;   // 60.0756 Hz, 26 blanked

	function automatic [9:0] vtotal_of(input [1:0] mode);
		case (mode)
			2'd1:    vtotal_of = VTOTAL_50HZ;
			2'd2:    vtotal_of = VTOTAL_57HZ;
			2'd3:    vtotal_of = VTOTAL_60HZ;
			default: vtotal_of = VTOTAL;      // spi_defs.vh, hardware-measured
		endcase
	endfunction

	// VSync keeps its measured 8-line width and its measured 13-line BACK porch
	// -- the gap between the end of the pulse and the top of the next field is
	// what positions the picture vertically on a CRT, so holding it constant
	// keeps the image in the same place in every mode. The front porch absorbs
	// the whole change: 35 lines at Normal, 59 at 50 Hz, 19 at 57 Hz, 5 at
	// 60 Hz. At Normal this reproduces the measured VSSTART 275 exactly.
	localparam [9:0] VS_BP = VTOTAL - VSEND;             // 13
	function automatic [9:0] vsstart_of(input [1:0] mode);
		vsstart_of = vtotal_of(mode) - VS_BP - VS_WIDTH;
	endfunction

	// ------------------------------------------------------------------
	// Sync position
	//
	// Widths and positions come from spi_defs.vh, which holds the
	// hardware-measured values; everything here is derived from them so there
	// is still exactly one place the raster is described. HSync never moves;
	// VSync follows the field length and is latched at the frame wrap.
	// ------------------------------------------------------------------
	reg [9:0] vs_start, vs_end;

	// A vblank that fell while the board was frozen, owed to the 386.
	reg       vbl_pend;

	// Exactly the condition the always block below uses to set vbl_rise, one
	// cycle earlier.
	assign vbl_next = pix_tick && (hcnt == HTOTAL - 10'd1)
	                           && (vcnt == VBSTART - 10'd1);

	// The last pixel of the last line: the one point at which a timing change
	// can be taken without deforming a line the scaler is already consuming.
	wire frame_wrap = pix_tick && (hcnt == HTOTAL - 10'd1)
	                           && (vcnt == vlast);

	// Blanking and sync are simple decodes of the counters. At a 7.16 MHz pixel
	// rate on a 57 MHz fabric there is no reason to pipeline them. Blanking is
	// fixed; only the sync pulses move.
	assign hblank = (hcnt >= HBSTART);
	assign vblank = (vcnt >= VBSTART);
	assign hsync  = (hcnt >= HSSTART) && (hcnt < HSEND);
	assign vsync  = (vcnt >= vs_start) && (vcnt < vs_end);

	always @(posedge clk) begin
		if (reset) begin
			div        <= 3'd0;
			vlast      <= vtotal_of(video_mode) - 10'd1;
			ce_pix     <= 1'b0;
			hcnt       <= 10'd0;
			vcnt       <= 10'd0;
			line_start <= 1'b0;
			vbl_rise   <= 1'b0;
			vbl_pend   <= 1'b0;
			vs_start   <= vsstart_of(video_mode);
			vs_end     <= vsstart_of(video_mode) + VS_WIDTH;
		end
		else begin
			line_start <= 1'b0;
			vbl_rise   <= 1'b0;

			div    <= div + 3'd1;
			ce_pix <= pix_tick;

			if (pix_tick) begin
				if (hcnt == HTOTAL - 10'd1) begin
					hcnt       <= 10'd0;
					line_start <= 1'b1;

					if (vcnt == vlast) begin
						vcnt <= 10'd0;
					end
					else begin
						vcnt <= vcnt + 10'd1;
						// The 386's only interrupt source is vertical blanking.
						if (vcnt == VBSTART - 10'd1) begin
							if (pause) vbl_pend <= 1'b1;
							else       vbl_rise <= 1'b1;
						end
					end
				end
				else begin
					hcnt <= hcnt + 10'd1;
				end
			end

			// Timing changes land here and only here.
			if (frame_wrap) begin
				vlast    <= vtotal_of(video_mode) - 10'd1;
				vs_start <= vsstart_of(video_mode);
				vs_end   <= vsstart_of(video_mode) + VS_WIDTH;
			end

			// The deferred one, handed over the moment the board is let go.
			// Written after the block above so it wins the cycle; a natural
			// pulse and a deferred one can only coincide if `pause` drops on
			// the exact crossing, and one pulse is the right answer there.
			if (!pause && vbl_pend) begin
				vbl_rise <= 1'b1;
				vbl_pend <= 1'b0;
			end
		end
	end

endmodule
