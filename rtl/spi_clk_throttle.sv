//============================================================================
//  SeibuSPI - Seibu SPI / SXX2E
//
//  clk_cpu throttle -- a fractional clock gate that brings the 386 domain from
//  the PLL's 28.636364 MHz down to the board's 25 MHz.
//
//  WHY A GATE AND NOT A PLL. The VCO is 1260 MHz (rtl/pll.v) and 1260/25 =
//  50.4, so no output counter on the existing PLL can produce 25 MHz. A second
//  PLL could, but it would put the 386 in a clock domain asynchronous to
//  clk_sys and clk_ram, which is a CDC rework of every crossing in spi_top for
//  a frequency this gets exactly. Removing edges from the clock we already have
//  keeps every surviving clk_cpu edge coincident with a clk_sys edge and a
//  clk_ram edge, so the domains stay in one clock group and TimeQuest goes on
//  analysing the crossings as ordinary synchronous transfers.
//
//  WHY A GATE AND NOT A CLOCK ENABLE. z386 has no CE port -- rtl/z386/z386.sv
//  declares `clk` and `reset_n` and nothing else -- and threading one through
//  means touching ~90 always_ff blocks across 16 files plus the read enables on
//  the inferred microcode ROM and the two L1 cache RAMs, in a core this project
//  re-syncs through patches/. And `cpu_en` (spi_cpu.sv:84) is NOT the throttle
//  its comment implies: it gates mem_accept only (spi_cpu.sv:1019), so with L1
//  I and D caches the core keeps executing out of cache while the bus is
//  stalled. See PLAN.md 16.9.
//
//  THE RATIO IS EXACT. clk_cpu is 1260/44 = 315/11 MHz, and
//
//      315/11 x 55/63 = 17325/693 = 25.000000 MHz
//
//  so enabling 55 of every 63 edges hits the board's rate with zero error, not
//  the +0.23% that a plain 7/8 gate leaves. The accumulator spreads the eight
//  killed edges evenly: seven live edges then a kill, once per 63 cycles, and
//  eight live edges then a kill for the other seven groups. Never two kills in
//  a row, so the longest clk_cpu period is 2x nominal (69.9 ns) and the shortest
//  is nominal -- two live edges can still be adjacent, which is exactly why the
//  SDC needs no change: the 34.9 ns constraint TimeQuest derives from the PLL is
//  still the tightest case that occurs.
//
//  WHAT THIS DOES NOT SETTLE, AND BY HOW MUCH. The clock is right now; the
//  THROUGHPUT still is not, and unlike when 16.9 was written that gap is
//  measured rather than suspected. bench/ puts z386x at 3.63 clocks on a
//  game-shaped instruction mix against Intel's 7.38 for a real 386 -- 2.03x the
//  work per clock, from the L1 caches and the hardwired fast paths. The board's
//  margin was therefore 2.03 x 28.636/25 = 2.33x, and this gate removes the
//  1.145 of it that was frequency. What is left is 2.03x, all of it IPC, and no
//  clock rate can fix that: matching throughput by frequency alone would mean
//  running the 386 at 12.3 MHz, which would be wrong in the other direction
//  everywhere the caches MISS (a 32 KB pointer chase costs 11.02 clocks here
//  against 4 on the real part). Getting closer means bus and cache timing, not
//  this file.
//
//  NUM/DEN are parameters so a measured correction is a constant, and so this
//  doubles as the OSD CPU speed control section 6 wanted -- making the ratio
//  runtime-selectable is a mux on the two constants below.
//
//  PULSE WIDTHS, for anyone auditing a crossing. Signals that leave this domain
//  as a "one clk_cpu cycle" pulse are two clk_sys cycles wide today and become
//  two OR four. Every consumer edge-detects on the clk_sys side -- sndfifo_wr
//  and coin_latch_rd in spi_sound (spi_top.sv:625), the DMA triggers in spi_dma
//  (spi_dma.sv:96, itself clk_cpu and gated with the rest) -- so wider is safe.
//  Narrower would not have been, and nothing here makes anything narrower.
//
//  And spi_cpu's savestate watchdog counts clk_cpu cycles, so its 2^23 becomes
//  ~336 ms rather than ~293 (spi_cpu.sv:849). Still eight times the worst
//  measured wait; the number in that comment is the one that goes stale.
//============================================================================

`timescale 1ns/10ps

module spi_clk_throttle
#(
	// Live edges per DEN input edges. 55/63 of 28.636364 MHz is exactly 25 MHz.
	parameter NUM = 55,
	parameter DEN = 63
)
(
	input  wire clk_in,
	// Pass the clock through ungated. SXX2G ran a real AM386DX-40 at 28.63636
	// MHz (seibuspi.cpp:1908) -- which is exactly this PLL output -- so that
	// board wants no gate at all, and the 55/63 below is for the 25 MHz ones.
	// The header promised this would be "a mux on the two constants"; it turned
	// out cheaper, because full speed is just every edge surviving.
	input  wire full_speed,
	output wire clk_out
);

	localparam AW = $clog2(DEN);

	// Sized so the arithmetic below is AW+1 bits end to end. Written as casts
	// rather than as sized localparams because Quartus warns 10230 (truncated
	// 32 to 7) on the latter, and a warning that is always benign is a warning
	// nobody reads.
	localparam logic [AW:0] K_NUM = (AW+1)'(NUM);
	localparam logic [AW:0] K_DEN = (AW+1)'(DEN);

	// Bresenham: add NUM every input edge and emit an enable whenever the
	// accumulator carries past DEN. Over DEN cycles the accumulator takes in
	// NUM*DEN and gives back DEN per enable, so exactly NUM enables come out,
	// spread as evenly as an integer sequence can be.
	//
	// Clocked on clk_in, the UNGATED clock, for the obvious reason: a generator
	// clocked on its own output would stop the first time it stopped itself.
	// `ena` therefore drives nothing but the clkena block, so there is no data
	// path between the gated and ungated versions of this clock.
	reg [AW-1:0] acc = {AW{1'b0}};
	reg          ena = 1'b1;

	// Both operands are AW+1 bits wide, so neither the add nor the subtract can
	// wrap: acc tops out at DEN-1 and NUM <= DEN, so sum <= 2*DEN-1 fits.
	wire [AW:0] sum  = {1'b0, acc} + K_NUM;
	/* verilator lint_off UNUSEDSIGNAL */
	wire [AW:0] diff = sum - K_DEN;   // only the low AW bits are ever taken --
	/* verilator lint_on UNUSEDSIGNAL */  // the borrow cannot fire, sum >= K_DEN

	always @(posedge clk_in) begin
		if (sum >= K_DEN) begin
			acc <= diff[AW-1:0];
			ena <= 1'b1;
		end else begin
			acc <= sum[AW-1:0];
			ena <= 1'b0;
		end
	end

	// The Cyclone V clock control block, instantiated as the device atom rather
	// than through altclkctrl: this is what altclkctrl compiles to, and the atom
	// in cyclonev_atoms.v is the one place the port and parameter names are not
	// a guess. Same reasoning as sdram.sv's altddio_out.
	//
	// ena_register_mode = "falling edge" is what makes the gate glitch free.
	// The block latches `ena` on the FALLING edge of inclk and ANDs the held
	// value with the clock, so a decision made on rising edge N is captured
	// mid-cycle and suppresses the high phase of cycle N+1 in one piece. The
	// output never produces a runt.
	wire ena_out = ena | full_speed;

	cyclonev_clkena #(
		.clock_type            ("auto"),
		.ena_register_mode     ("falling edge"),
		.ena_register_power_up ("high"),
		.disable_mode          ("low")
	) clkena_inst (
		.inclk  (clk_in),
		.ena    (ena_out),
		.outclk (clk_out),
		.enaout ()
	);

endmodule
