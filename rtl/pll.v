//============================================================================
//  SlopperPI - Seibu SPI / SXX2E
//
//  PLL
//
//  50 MHz reference -> VCO 1260 MHz (n=5, m=126)
//    outclk_0 = 1260 / 11 = 114.545455 MHz   clk_ram  (SDRAM controller)
//    outclk_1 = 1260 / 22 =  57.272727 MHz   clk_sys  (video, I/O, sound)
//    outclk_2 = 1260 / 44 =  28.636364 MHz   clk_cpu  (the 386)
//
//  clk_ram does NOT have to be a multiple of clk_sys or clk_cpu: every crossing
//  to the SDRAM controller is a toggle handshake. The real constraint is that
//  all three outputs are integer divisions of the same 1260 MHz VCO, so the
//  choices are 1260/N: 114.545 (/11), 105.0 (/12), 96.923 (/13), 90.0 (/14).
//
//  114.545 does not work on this board -- the first 16-bit word of every burst
//  read comes back as unstable garbage, verified over JTAG on a channel that the
//  ch1 width bug never touched. 57.272727 is reliable but too slow: the tile
//  engine cannot fetch a whole scanline in time and the text layer, rendered
//  last, gets truncated.
//
//  96.923077 (1260/13) was tried and FAILS TIMING, badly: sys/sys_top.sdc puts
//  every PLL output in one clock group, so Quartus analyses clk_ram <-> clk_sys
//  paths, and at a non-integer ratio the closest launch/capture edge pair is a
//  sliver. clk_sys came out at -4.7 ns with TNS -999. The 2:1 ratio is what made
//  the old builds close. So clk_ram is effectively pinned to an integer multiple
//  of clk_sys unless the two domains are declared asynchronous and the sdram.sv
//  request samplers are widened from one flop to two.
//
//  clk_cpu is exactly clk_sys / 2 and phase aligned, so every clk_cpu edge
//  coincides with a clk_sys edge and the two are in the same clock group -- the
//  crossings are analysed normally by TimeQuest rather than being a true CDC.
//
//  The 386 gets its own clock for two reasons. z386x does not close 57.27 MHz
//  here (its microcode-ROM address path misses by ~1 ns on Quartus Lite;
//  upstream's own profiles top out at 85 MHz only with Standard plus a seed
//  sweep), and 28.64 MHz is far closer to the board's real 386DX-25 than
//  57.27 MHz was.
//
//  57.272727 MHz is exactly 2 x 28.63636 MHz, the board's master crystal, so:
//    pixel clock = clk_sys / 8 = 7.1590909 MHz  (exact, matches the SPI dot clock)
//    Z80 clock   = clk_sys / 8 = 7.1590909 MHz  (exact, 28.63636 / 4)
//  and clk_ram is exactly 2 x clk_sys, phase aligned from the same PLL, so the
//  SDRAM controller's toggle handshakes are synchronous rather than a true CDC.
//
//  NOTE: the pll -> pll_inst -> altera_pll_i hierarchy is not decoration. The
//  framework's clock groups in sys/sys_top.sdc match on
//      *|pll|pll_inst|altera_pll_i|*[*].*|divclk
//  so flattening this module leaves the core clocks outside every clock group,
//  and TimeQuest then analyses them against every unrelated domain. That shows
//  up as tens of nanoseconds of phantom negative slack across the whole design.
//============================================================================

`timescale 1ns/10ps

module pll
(
	input  wire refclk,
	input  wire rst,

	output wire outclk_0,   // 114.545455 MHz - clk_ram
	output wire outclk_1,   //  57.272727 MHz - clk_sys
	output wire outclk_2,   //  28.636364 MHz - clk_cpu
	output wire locked
);

	pll_0002 pll_inst
	(
		.refclk   (refclk),
		.rst      (rst),
		.outclk_0 (outclk_0),
		.outclk_1 (outclk_1),
		.outclk_2 (outclk_2),
		.locked   (locked)
	);

endmodule


module pll_0002
(
	input  wire refclk,
	input  wire rst,

	output wire outclk_0,
	output wire outclk_1,
	output wire outclk_2,
	output wire locked
);

	altera_pll #(
		.fractional_vco_multiplier("false"),
		.reference_clock_frequency("50.0 MHz"),
		.operation_mode("direct"),
		.number_of_clocks(3),

		.output_clock_frequency0("114.545455 MHz"),
		.phase_shift0("0 ps"),
		.duty_cycle0(50),

		.output_clock_frequency1("57.272727 MHz"),
		.phase_shift1("0 ps"),
		.duty_cycle1(50),

		.output_clock_frequency2("28.636364 MHz"),
		.phase_shift2("0 ps"),
		.duty_cycle2(50),
		.output_clock_frequency3("0 MHz"),  .phase_shift3("0 ps"),  .duty_cycle3(50),
		.output_clock_frequency4("0 MHz"),  .phase_shift4("0 ps"),  .duty_cycle4(50),
		.output_clock_frequency5("0 MHz"),  .phase_shift5("0 ps"),  .duty_cycle5(50),
		.output_clock_frequency6("0 MHz"),  .phase_shift6("0 ps"),  .duty_cycle6(50),
		.output_clock_frequency7("0 MHz"),  .phase_shift7("0 ps"),  .duty_cycle7(50),
		.output_clock_frequency8("0 MHz"),  .phase_shift8("0 ps"),  .duty_cycle8(50),
		.output_clock_frequency9("0 MHz"),  .phase_shift9("0 ps"),  .duty_cycle9(50),
		.output_clock_frequency10("0 MHz"), .phase_shift10("0 ps"), .duty_cycle10(50),
		.output_clock_frequency11("0 MHz"), .phase_shift11("0 ps"), .duty_cycle11(50),
		.output_clock_frequency12("0 MHz"), .phase_shift12("0 ps"), .duty_cycle12(50),
		.output_clock_frequency13("0 MHz"), .phase_shift13("0 ps"), .duty_cycle13(50),
		.output_clock_frequency14("0 MHz"), .phase_shift14("0 ps"), .duty_cycle14(50),
		.output_clock_frequency15("0 MHz"), .phase_shift15("0 ps"), .duty_cycle15(50),
		.output_clock_frequency16("0 MHz"), .phase_shift16("0 ps"), .duty_cycle16(50),
		.output_clock_frequency17("0 MHz"), .phase_shift17("0 ps"), .duty_cycle17(50),

		.pll_type("General"),
		.pll_subtype("General")
	) altera_pll_i (
		.rst      (rst),
		.outclk   ({outclk_2, outclk_1, outclk_0}),
		.locked   (locked),
		.fboutclk ( ),
		.fbclk    (1'b0),
		.refclk   (refclk)
	);

endmodule
