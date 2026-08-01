//============================================================================
//  SlopperPI - Seibu SPI / SXX2E
//
//  PLL
//
//  50 MHz reference -> VCO 1260 MHz (n=5, m=126)
//    outclk_0 = 1260 / 11 = 114.545455 MHz   clk_ram  (SDRAM controller)
//    outclk_1 = 1260 / 22 =  57.272727 MHz   clk_sys  (core logic)
//
//  57.272727 MHz is exactly 2 x 28.63636 MHz, the board's master crystal, so:
//    pixel clock = clk_sys / 8 = 7.1590909 MHz  (exact, matches SPI dot clock)
//    Z80 clock   = clk_sys / 8 = 7.1590909 MHz  (exact, 28.63636 / 4)
//  and clk_ram is exactly 2 x clk_sys, phase aligned from the same PLL, so the
//  SDRAM controller's toggle handshakes are synchronous rather than a true CDC.
//============================================================================

`timescale 1ns/10ps

module pll
(
	input  wire refclk,
	input  wire rst,

	output wire outclk_0,   // 114.545455 MHz - clk_ram
	output wire outclk_1,   //  57.272727 MHz - clk_sys
	output wire locked
);

	altera_pll #(
		.fractional_vco_multiplier("false"),
		.reference_clock_frequency("50.0 MHz"),
		.operation_mode("direct"),
		.number_of_clocks(2),

		.output_clock_frequency0("114.545455 MHz"),
		.phase_shift0("0 ps"),
		.duty_cycle0(50),

		.output_clock_frequency1("57.272727 MHz"),
		.phase_shift1("0 ps"),
		.duty_cycle1(50),

		.output_clock_frequency2("0 MHz"),  .phase_shift2("0 ps"),  .duty_cycle2(50),
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
		.outclk   ({outclk_1, outclk_0}),
		.locked   (locked),
		.fboutclk ( ),
		.fbclk    (1'b0),
		.refclk   (refclk)
	);

endmodule
