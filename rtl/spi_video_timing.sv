//============================================================================
//  SeibuSPI - Seibu SPI / SXX2E
//
//  Video timing generator.
//
//  The Seibu CRTC is programmable, but every SPI game writes essentially the
//  same values, and MAME hardcodes the resulting raster (seibuspi.cpp:898):
//
//    dot clock 28.63636 MHz / 4 = 7.1590909 MHz  ( = clk_sys / 8 )
//    448 x 296 total, 320 x 240 visible          => 53.99 Hz
//
//  Vertical blanking really starts at line 253 on hardware; only 240 lines are
//  ever visible, so we blank at 240 and keep the total at 296.
//============================================================================

module spi_video_timing
(
	input             clk,        // clk_sys, 57.272727 MHz
	input             reset,
	// Stop the raster dead. Everything downstream -- the tile and sprite
	// engines, the mixer, and the vblank interrupt the 386 runs on -- is driven
	// from the counters below, so gating them here freezes the whole video side
	// without any of those modules needing to know. A savestate holds this for
	// the length of its transfer; nothing else uses it.
	input             pause,

	output reg        ce_pix,     // 7.1590909 MHz pixel enable

	output reg  [9:0] hcnt,       // 0 .. HTOTAL-1
	output reg  [9:0] vcnt,       // 0 .. VTOTAL-1

	output            hsync,
	output            vsync,
	output            hblank,
	output            vblank,

	output reg        line_start, // pulse at the start of each line
	output reg        vbl_rise    // pulse on entry to vertical blanking
);

`include "spi_defs.vh"

	reg [2:0] div;

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
		end
		else if (pause) begin
			// Not just the counters: the three pulses have to go too, or a
			// line_start latched on the way in would fire the moment the rest
			// of the board is let go.
			ce_pix     <= 1'b0;
			line_start <= 1'b0;
			vbl_rise   <= 1'b0;
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
						if (vcnt == VBSTART - 10'd1) vbl_rise <= 1'b1;
					end
				end
				else begin
					hcnt <= hcnt + 10'd1;
				end
			end
		end
	end

endmodule
