//============================================================================
//  SlopperPI - how busy is the SDRAM, per channel
//
//  Every existing SDRAM instrument here is a symptom counter: starved sprite
//  lines, PCM overruns, the worst Z80 fetch wait. All of them answer "is
//  anything hurting yet", and all of them read clean right now. None of them
//  answers "how much headroom is left", which is the question that decides
//  whether a region can be moved to DDR3 or whether the priority order is
//  worth revisiting.
//
//  Measured from OUTSIDE sdram.sv, on the request/acknowledge toggles alone.
//  That is deliberate: PLAN.md 15.8 records that restructuring inside that
//  module destroyed the SDRAM input timing once, and clk_ram is the tightest
//  clock in the design. Nothing here is in a path that reaches it.
//
//  ONE number per channel: completed transactions per window. The controller
//  spends a fixed EIGHT clk_ram cycles on each one -- IDLE, WAIT, RW1, then
//  IDLE_5 down to IDLE_1 -- so occupancy is trans * 8 / WINDOW, and the five
//  together plus refresh are the whole bus.
//
//  A per-channel round-trip figure was here too and came out: it cost 110 more
//  probe bits and 220 flops, and the first build with it pushed the HDMI PLL
//  from +0.067 to -0.145. It was also redundant. Every channel that can be
//  starved already has an instrument that says so directly -- `fetch wait` for
//  ch3, `spr starved` for ch4, `pcm overruns` for ch5 -- and those measure the
//  consequence rather than a proxy for it. Occupancy was the only thing
//  actually missing.
//
//  The window is a fixed 2^21 clk_ram cycles = 18.31 ms, which is one frame at
//  53.99 Hz to within a percent. Fixed rather than vblank-derived so the
//  denominator is an exact constant on the host side and no frame pulse has to
//  cross into clk_ram. Counts are LATCHED at the end of each window, so unlike
//  every free-running counter in this project they cannot wrap between JTAG
//  samples -- 13b and 14.9 both record being lied to by one that did.
//============================================================================

module spi_sdr_stats
(
	input         clk,          // clk_ram, 114.545455 MHz

	// `ack` toggles when a transaction retires, once per access, and it is
	// already in this clock domain -- sdram.sv drives it from clk_ram. The
	// matching `req` is not needed: counting retirements counts accesses.
	input  [4:0]  ack,          // {ch5, ch4, ch3, ch2, ch1}

	// Per window, latched. ch1 in [18:0], ch2 in [37:19], and so on.
	// 19 bits because a fully saturated window is 2^21/8 = 262,144.
	output reg [94:0] trans     // 5 x 19
);

	localparam WINDOW_BITS = 21;

	reg [4:0] ack_d;
	always @(posedge clk) ack_d <= ack;

	reg [WINDOW_BITS-1:0] window;
	wire window_end = &window;
	always @(posedge clk) window <= window + 1'd1;

	reg [18:0] t_acc [0:4];

	integer i;
	initial begin
		for (i = 0; i < 5; i = i + 1) t_acc[i] = 19'd0;
		trans = 95'd0;
	end

	always @(posedge clk) begin
		for (i = 0; i < 5; i = i + 1) begin
			if (window_end) begin
				trans[i*19 +: 19] <= t_acc[i];
				// A transaction retiring on the very last cycle of a window
				// belongs to the next one, which is why this reloads rather
				// than clears.
				t_acc[i] <= (ack[i] != ack_d[i]) ? 19'd1 : 19'd0;
			end
			else if (ack[i] != ack_d[i]) t_acc[i] <= t_acc[i] + 1'd1;
		end
	end

endmodule
