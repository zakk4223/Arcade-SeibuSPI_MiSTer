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
//  VARIABLE REFRESH: the pixel window moves, the raster does not.
//
//  The OSD refresh-rate option scales how many clk_sys cycles a pixel lasts.
//  It does NOT touch HTOTAL, VTOTAL, VBSTART or anything else the software can
//  observe: the frame stays 448 x 296 with 56 blanked lines, so the vblank DMA
//  window measured in scanlines is identical in every mode and the game cannot
//  tell which one is selected. Only wall-clock time scales.
//
//  That is the whole reason this is done here rather than by adding blanking
//  lines. Reaching 60 Hz by shortening VTOTAL to 266 would cut vblank from
//  3.5 ms to 1.6 ms, and SPI games run their sprite and tilemap DMA in the
//  vblank handler.
//
//  The generator is a Bresenham accumulator: add PIX_N to a 12-bit register
//  every clk_sys cycle and take the carry out as the pixel tick. The modulus is
//  4096 by construction, so the "subtract m on overflow" is the natural wrap
//  and the whole thing is one 12-bit adder.
//
//      mode          PIX_N   avg window   windows   refresh    error
//      Normal          512     8.0000       8        53.9869    exact
//      50 Hz           474     8.6414       8,9      49.9800    -0.040%
//      57 Hz           541     7.5712       7,8      57.0447    +0.078%
//      60 Hz           569     7.1986       7,8      59.9971    -0.005%
//
//  Normal is n/m = 512/4096 = exactly 1/8, so the default path is bit-identical
//  to the fixed /8 divider this replaced -- the accumulator reaches 3584 on the
//  eighth cycle and carries on the same edge the old `div == 3'd7` fired.
//
//  A Bresenham whose average window lies between N and N+1 emits ONLY N- and
//  N+1-cycle windows, by construction.
//
//  THE CEILING IS 61.70 Hz = clk_sys/7/(448*296), and it is spi_mixer's: its
//  schedule is seven clk_sys cycles a pixel (five palette reads on one port,
//  plus the two-cycle issue-to-data latency the last is latched after), and
//  its step counter saturates rather than wrapping so anything LONGER is free.
//
//  It was very nearly the layer renderer's instead. That engine was saturated
//  at the board's own dot clock -- 3584 of 3584 cycles on the worst line -- so
//  the first attempt at 57/60 Hz broke the picture even with the mixer retimed
//  (PLAN.md 53.7). It was not short of bandwidth: it stalled on bus contention
//  only 29 cycles a line while spending 1417 on two blocking round trips per
//  tile. Overlapping those with the emit brought the worst line to 2863, and a
//  60 Hz line is 3225 (PLAN.md 53.9). If a faster mode is ever wanted, check
//  spi_layers' occupancy FIRST -- the mixer floor is not what will bite.
//
//  ANALOG SYNC POSITION. hoffset/voffset move the sync pulses only, leaving
//  hblank/vblank -- and therefore DE -- alone. So they reposition the picture
//  on an analog CRT or direct video and are deliberately invisible over HDMI,
//  where the scaler re-locks on sync. Same semantics as IremM72's "Analog Video
//  H-Pos/V-Pos". The pulse is clamped inside blanking: the measured widths (37
//  px, 8 lines) leave room at Normal, but a clamp costs a few LUTs and means no
//  combination of mode and offset can ever push sync into active video.
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

	// OSD video timing. 0 = Normal (53.99 Hz), 1 = 50 Hz. See PIX_N above.
	input       [1:0] video_mode,
	// Analog sync position, two's complement, -8 .. +7 pixels / lines.
	input       [3:0] hoffset,
	input       [3:0] voffset,

	output reg        ce_pix,     // pixel enable, 7.1590909 MHz at Normal

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

	// ------------------------------------------------------------------
	// Fractional pixel window
	// ------------------------------------------------------------------
	localparam [11:0] PIX_N_NORMAL = 12'd512;   // exactly 1/8
	localparam [11:0] PIX_N_50HZ   = 12'd474;
	localparam [11:0] PIX_N_57HZ   = 12'd541;
	localparam [11:0] PIX_N_60HZ   = 12'd569;

	function automatic [11:0] pix_n_of(input [1:0] mode);
		case (mode)
			2'd1:    pix_n_of = PIX_N_50HZ;
			2'd2:    pix_n_of = PIX_N_57HZ;
			2'd3:    pix_n_of = PIX_N_60HZ;
			default: pix_n_of = PIX_N_NORMAL;
		endcase
	endfunction

	reg  [11:0] acc;
	reg  [11:0] pix_n;

	wire [12:0] acc_nx   = {1'b0, acc} + {1'b0, pix_n};
	wire        pix_tick = acc_nx[12];

	// ------------------------------------------------------------------
	// Analog sync position
	//
	// Widths and the Normal positions come from spi_defs.vh, which holds the
	// hardware-measured values; everything here is derived from them so there
	// is still exactly one place the raster is described.
	// ------------------------------------------------------------------
	localparam [9:0] HS_WIDTH = HSEND - HSSTART;   // 37 px,   measured
	localparam [9:0] VS_WIDTH = VSEND - VSSTART;   //  8 lines, measured

	// The pulse may sit anywhere inside blanking and nowhere outside it.
	function automatic [9:0] clamp_sync(input [9:0] base, input [3:0] off,
	                                    input [9:0] lo,   input [9:0] hi);
		reg signed [11:0] want;
		begin
			want = $signed({2'b00, base}) + $signed({{8{off[3]}}, off});
			if      (want < $signed({2'b00, lo})) clamp_sync = lo;
			else if (want > $signed({2'b00, hi})) clamp_sync = hi;
			else                                  clamp_sync = want[9:0];
		end
	endfunction

	wire [9:0] hs_want = clamp_sync(HSSTART, hoffset, HBSTART, HTOTAL - HS_WIDTH);
	wire [9:0] vs_want = clamp_sync(VSSTART, voffset, VBSTART, VTOTAL - VS_WIDTH);

	reg [9:0] hs_start, hs_end, vs_start, vs_end;

	// A vblank that fell while the board was frozen, owed to the 386.
	reg       vbl_pend;

	// Exactly the condition the always block below uses to set vbl_rise, one
	// cycle earlier.
	assign vbl_next = pix_tick && (hcnt == HTOTAL - 10'd1)
	                           && (vcnt == VBSTART - 10'd1);

	// The last pixel of the last line: the one point at which a timing change
	// can be taken without deforming a line the scaler is already consuming.
	wire frame_wrap = pix_tick && (hcnt == HTOTAL - 10'd1)
	                           && (vcnt == VTOTAL - 10'd1);

	// Blanking and sync are simple decodes of the counters. At a 7.16 MHz pixel
	// rate on a 57 MHz fabric there is no reason to pipeline them. Blanking is
	// fixed; only the sync pulses move.
	assign hblank = (hcnt >= HBSTART);
	assign vblank = (vcnt >= VBSTART);
	assign hsync  = (hcnt >= hs_start) && (hcnt < hs_end);
	assign vsync  = (vcnt >= vs_start) && (vcnt < vs_end);

	always @(posedge clk) begin
		if (reset) begin
			acc        <= 12'd0;
			pix_n      <= pix_n_of(video_mode);
			ce_pix     <= 1'b0;
			hcnt       <= 10'd0;
			vcnt       <= 10'd0;
			line_start <= 1'b0;
			vbl_rise   <= 1'b0;
			vbl_pend   <= 1'b0;
			hs_start   <= HSSTART;
			hs_end     <= HSEND;
			vs_start   <= VSSTART;
			vs_end     <= VSEND;
		end
		else begin
			line_start <= 1'b0;
			vbl_rise   <= 1'b0;

			acc    <= acc_nx[11:0];
			ce_pix <= pix_tick;

			if (pix_tick) begin
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

			// Timing changes land here and only here.
			if (frame_wrap) begin
				pix_n    <= pix_n_of(video_mode);
				hs_start <= hs_want;
				hs_end   <= hs_want + HS_WIDTH;
				vs_start <= vs_want;
				vs_end   <= vs_want + VS_WIDTH;
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
