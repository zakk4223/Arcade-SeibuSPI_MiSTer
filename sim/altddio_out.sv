//============================================================================
//  Simulation-only stub for Altera's altddio_out. rtl/sdram.sv uses it purely
//  to forward the clock to the SDRAM chip. The real primitive emits datain_h on
//  the rising edge and datain_l on the falling one; sdram.sv wires those to
//  0 and 1, so the output is just the inverted clock.
//============================================================================
/* verilator lint_off UNUSEDPARAM */
module altddio_out
#(
	parameter extend_oe_disable = "OFF",
	parameter intended_device_family = "Cyclone V",
	parameter invert_output = "OFF",
	parameter lpm_hint = "UNUSED",
	parameter lpm_type = "altddio_out",
	parameter oe_reg = "UNREGISTERED",
	parameter power_up_high = "OFF",
	parameter width = 1
)
(
	input  [width-1:0] datain_h,
	input  [width-1:0] datain_l,
	input              outclock,
	output [width-1:0] dataout,
	input              aclr,
	input              aset,
	input              oe,
	input              outclocken,
	input              sclr,
	input              sset
);
	assign dataout = outclock ? datain_h : datain_l;
	/* verilator lint_off UNUSEDSIGNAL */
	wire _unused = &{1'b0, aclr, aset, oe, outclocken, sclr, sset};
	/* verilator lint_on UNUSEDSIGNAL */
endmodule
/* verilator lint_on UNUSEDPARAM */
