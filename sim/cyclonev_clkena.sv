//============================================================================
//  Simulation-only stub for Altera's cyclonev_clkena, the Cyclone V clock
//  control block. rtl/spi_clk_throttle.sv uses it to remove clk_cpu edges.
//
//  The real block latches `ena` on the FALLING edge of inclk and ANDs the held
//  value with the clock, which is what makes the gate glitch free. This models
//  exactly that and nothing else: no clock_type, no disable_mode, no enaout.
//
//  Note that the testbenches drive clk_cpu themselves and instantiate spi_top
//  rather than the SeibuSPI.sv wrapper, so nothing in sim/ currently exercises
//  this path. It exists so `make lint-top` can elaborate the wrapper.
//============================================================================
/* verilator lint_off UNUSEDPARAM */
module cyclonev_clkena
#(
	parameter clock_type            = "auto",
	parameter ena_register_mode     = "always enabled",
	parameter lpm_type              = "cyclonev_clkena",
	parameter ena_register_power_up = "high",
	parameter disable_mode          = "low",
	parameter test_syn              = "high"
)
(
	input  wire inclk,
	input  wire ena,
	output wire enaout,
	output wire outclk
);
	reg ena_r = 1'b1;
	always @(negedge inclk) ena_r <= ena;

	assign outclk = inclk & ena_r;
	assign enaout = ena_r;
endmodule
/* verilator lint_on UNUSEDPARAM */
