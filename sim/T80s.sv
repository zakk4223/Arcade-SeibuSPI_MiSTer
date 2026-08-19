//============================================================================
//  SeibuSPI - T80s stand-in for Verilator
//
//  The Z80 core is the VHDL T80 under rtl/t80, which Verilator cannot read.
//  Lint and the C++ testbenches need SOMETHING with that entity's ports or the
//  elaboration of spi_sound fails, so this is it: correct interface, no CPU.
//  It is never listed in files.qip -- Quartus always gets the real core.
//============================================================================

/* verilator lint_off UNUSEDPARAM */
module T80s
#(
	parameter Mode    = 0,
	parameter T2Write = 1,
	parameter IOWait  = 1
)
/* verilator lint_on UNUSEDPARAM */
(
	input         RESET_n,
	input         CLK,
	input         CEN,
	input         WAIT_n,
	input         INT_n,
	input         NMI_n,
	input         BUSRQ_n,
	output        M1_n,
	output        MREQ_n,
	output        IORQ_n,
	output        RD_n,
	output        WR_n,
	output        RFSH_n,
	output        HALT_n,
	output        BUSAK_n,
	input         OUT0,
	output [15:0] A,
	input   [7:0] DI,
	output  [7:0] DO
);

	assign {M1_n, MREQ_n, IORQ_n, RD_n, WR_n, RFSH_n, HALT_n, BUSAK_n} = 8'hFF;
	assign A  = 16'd0;
	assign DO = 8'd0;

	/* verilator lint_off UNUSEDSIGNAL */
	wire _unused = &{1'b0, RESET_n, CLK, CEN, WAIT_n, INT_n, NMI_n, BUSRQ_n, OUT0, DI};
	/* verilator lint_on UNUSEDSIGNAL */

endmodule
