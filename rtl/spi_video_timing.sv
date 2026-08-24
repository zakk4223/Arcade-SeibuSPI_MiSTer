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
//============================================================================

module spi_video_timing
(
	input             clk,        // clk_sys, 57.272727 MHz
	input             reset,
	// Hold the vblank interrupt, and nothing else. See the header: the raster
	// itself is not stoppable any more, by design.
	input             pause,

	output reg        ce_pix,     // 7.1590909 MHz pixel enable

	output reg  [9:0] hcnt,       // 0 .. HTOTAL-1
	output reg  [9:0] vcnt,       // 0 .. VTOTAL-1

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

	reg [2:0] div;
	// A vblank that fell while the board was frozen, owed to the 386.
	reg       vbl_pend;

	// Exactly the condition the always block below uses to set vbl_rise, one
	// cycle earlier.
	assign vbl_next = (div == 3'd7) && (hcnt == HTOTAL - 10'd1)
	                                && (vcnt == VBSTART - 10'd1);

	// Blanking and sync are simple decodes of the counters. At a 7.16 MHz pixel
	// rate on a 57 MHz fabric there is no reason to pipeline them.
	assign hblank = (hcnt >= HBSTART);
	assign vblank = (vcnt >= VBSTART);
	assign hsync  = (hcnt >= HSSTART) && (hcnt < HSEND);
	assign vsync  = (vcnt >= VSSTART) && (vcnt < VSEND);

	always @(posedge clk) begin
		if (reset) begin
			div        <= 3'd0;
			ce_pix     <= 1'b0;
			hcnt       <= 10'd0;
			vcnt       <= 10'd0;
			line_start <= 1'b0;
			vbl_rise   <= 1'b0;
			vbl_pend   <= 1'b0;
		end
		else begin
			line_start <= 1'b0;
			vbl_rise   <= 1'b0;

			div    <= div + 3'd1;
			ce_pix <= (div == 3'd7);

			if (div == 3'd7) begin
				if (hcnt == HTOTAL - 10'd1) begin
					hcnt       <= 10'd0;
					line_start <= 1'b1;

					if (vcnt == VTOTAL - 10'd1) begin
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
