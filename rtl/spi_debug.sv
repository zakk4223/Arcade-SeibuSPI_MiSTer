//============================================================================
//  SlopperPI - on-screen vital signs
//
//  Replaces the picture with eight horizontal bars, one per internal event, so
//  it is possible to tell from the hardware alone how far the core gets.
//
//  Each bar is 16 lines tall and shows TWO things:
//
//    * a moving bar growing from the left. Its length is a slice of that
//      event's counter, chosen per event so every bar sweeps at roughly the
//      same visible speed and wraps around every few seconds. MOTION MEANS THE
//      EVENT IS HAPPENING RIGHT NOW. A bar frozen at any length means the event
//      has stopped.
//    * a short dim tick near the right edge, lit once the event has happened at
//      least once. So a bar that is frozen but ticked happened and then died;
//      a bar with no tick at all never happened.
//
//  Deliberately not a saturating fill: that goes full within seconds and then
//  tells you nothing about whether the core is still alive.
//
//    0 white   ROM download finished (rom_ready)   - level, so a static full bar
//    1 red     386 fetched from program ROM        (SDRAM ch1 requests)
//    2 orange  386 wrote an I/O register           (io_wr)
//    3 yellow  tilemap DMA triggered
//    4 green   palette DMA triggered
//    5 cyan    sprite DMA triggered
//    6 blue    vertical blank interrupts raised
//    7 purple  tile layer renderer ran             (line_start)
//
//  Then four LEVEL bars, which are full while the condition holds and blank
//  otherwise. These say why the 386 is not making progress when it stops:
//
//    8 white   a program-ROM SDRAM read is outstanding. Solid means the CPU is
//              waiting for an ack that never came -- a lost SDRAM transaction.
//    9 red     the bus state machine is not idle
//   10 green   the CPU is asserting valid and the wrapper is not accepting
//   11 blue    an interrupt acknowledge cycle is stuck
//
//  Finally the ROM integrity result from spi_romcheck:
//
//   12 yellow  four 64-pixel segments, left to right: PRG, CHARS, TILES,
//              SPRITES. A lit segment means that region's checksum matched the
//              reference image. A dark segment means the ioctl download dropped
//              or misplaced bytes in it.
//   13 white   the check has finished running
//
//  Read it top to bottom: the first bar that is not moving is where the core
//  stops, and bars 8-11 say what it is stuck on.
//============================================================================

module spi_debug
(
	input             clk,
	input             reset,

	input       [9:0] hcnt,
	input       [9:0] vcnt,

	input             rom_ready,
	input             ev_prg_fetch,
	input             ev_io_wr,
	input             ev_dma_tilemap,
	input             ev_dma_palette,
	input             ev_dma_sprite,
	input             ev_vbl,
	input             ev_line,
	input       [3:0] lvl_why,
	input       [3:0] chk_ok,
	input             chk_done,

	output reg  [7:0] red,
	output reg  [7:0] green,
	output reg  [7:0] blue
);

	localparam [9:0] BAR_MAX = 10'd256;   // bar wraps after this many pixels
	localparam [9:0] TICK_L  = 10'd288;   // "has ever happened" marker
	localparam [9:0] TICK_R  = 10'd304;

	reg [23:0] cnt [0:7];
	reg  [7:0] ev_d;
	reg  [7:0] seen;

	wire [7:0] ev = {ev_line, ev_vbl, ev_dma_sprite, ev_dma_palette,
	                 ev_dma_tilemap, ev_io_wr, ev_prg_fetch, rom_ready};

	integer i;
	always @(posedge clk) begin
		if (reset) begin
			for (i = 0; i < 8; i = i + 1) cnt[i] <= 24'd0;
			ev_d <= 8'd0;
			seen <= 8'd0;
		end
		else begin
			ev_d <= ev;
			for (i = 0; i < 8; i = i + 1)
				if (ev[i] && !ev_d[i]) begin
					cnt[i] <= cnt[i] + 24'd1;
					seen[i] <= 1'b1;
				end
		end
	end

	wire [3:0] bar     = vcnt[7:4];      // 16 lines per bar, 14 bars
	wire       in_bars = (vcnt < 10'd224);
	wire       is_lvl  = (bar >= 4'd8) && (bar <= 4'd11);
	wire       is_chk  = (bar == 4'd12);
	wire       is_done = (bar == 4'd13);

	// Bar 12 is four independent 64-pixel segments, one per ROM region.
	wire [1:0] seg     = hcnt[7:6];
	wire       seg_lit = (hcnt < 10'd256) && chk_ok[seg];
	wire       gap     = (vcnt[3:0] == 4'd15);

	// Per-event scaling. These are picked from the rates the boot simulation
	// measured so that every bar sweeps at roughly 100 px/s and wraps every
	// two to four seconds:
	//   ROM fetches ~6 k/s, I/O writes ~3 k/s, line_start ~14 k/s,
	//   DMAs and vblank 60/s (one per frame, so they need no divider).
	reg [4:0] shift;
	always @* begin
		case (bar)
			4'd1:    shift = 5'd6;    // ROM fetches
			4'd2:    shift = 5'd5;    // I/O writes
			4'd7:    shift = 5'd7;    // layer renders
			default: shift = 5'd0;    // per-frame events, and bar 0 is unused
		endcase
	end

	wire [23:0] c      = cnt[bar[2:0]];
	/* verilator lint_off UNUSEDSIGNAL */
	wire [23:0] scaled = c >> shift;   // only [7:0] is displayed; the rest is the wrap
	/* verilator lint_on UNUSEDSIGNAL */

	// Bar 0 and the level bars are static: full while asserted, blank otherwise.
	wire lvl = lvl_why[bar[1:0]];

	wire [9:0] len = is_lvl        ? (lvl       ? BAR_MAX : 10'd0)
	               : is_done       ? (chk_done  ? BAR_MAX : 10'd0)
	               : (bar == 4'd0) ? (rom_ready ? BAR_MAX : 10'd0)
	                               : {2'b00, scaled[7:0]};

	wire lit  = in_bars && !gap && (is_chk ? seg_lit : (hcnt < len));
	wire tick = in_bars && !gap && !is_lvl && !is_chk && !is_done && seen[bar[2:0]]
	            && (hcnt >= TICK_L) && (hcnt < TICK_R);

	reg [7:0] r, g, b;
	always @* begin
		case (bar)
			4'd0:    begin r = 8'hFF; g = 8'hFF; b = 8'hFF; end
			4'd1:    begin r = 8'hFF; g = 8'h00; b = 8'h00; end
			4'd2:    begin r = 8'hFF; g = 8'h80; b = 8'h00; end
			4'd3:    begin r = 8'hFF; g = 8'hFF; b = 8'h00; end
			4'd4:    begin r = 8'h00; g = 8'hFF; b = 8'h00; end
			4'd5:    begin r = 8'h00; g = 8'hFF; b = 8'hFF; end
			4'd6:    begin r = 8'h00; g = 8'h00; b = 8'hFF; end
			4'd7:    begin r = 8'hFF; g = 8'h00; b = 8'hFF; end
			4'd8:    begin r = 8'hFF; g = 8'hFF; b = 8'hFF; end
			4'd9:    begin r = 8'hFF; g = 8'h00; b = 8'h00; end
			4'd10:   begin r = 8'h00; g = 8'hFF; b = 8'h00; end
			4'd11:   begin r = 8'h00; g = 8'h00; b = 8'hFF; end
			4'd12:   begin r = 8'hFF; g = 8'hFF; b = 8'h00; end
			default: begin r = 8'hFF; g = 8'hFF; b = 8'hFF; end
		endcase
	end

	always @* begin
		red = 8'd0; green = 8'd0; blue = 8'd0;
		if (lit) begin
			red = r; green = g; blue = b;
		end
		else if (tick) begin
			// same hue at quarter brightness
			red = {2'b00, r[7:2]}; green = {2'b00, g[7:2]}; blue = {2'b00, b[7:2]};
		end
		else if (in_bars && gap && hcnt < TICK_R) begin
			red = 8'h20; green = 8'h20; blue = 8'h20;
		end
	end

endmodule
