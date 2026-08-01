//============================================================================
//  SlopperPI - simple dual port RAM (one write port, one read port)
//
//  Single clock. Read data appears one cycle after the address. Quartus infers
//  M10K from this shape.
//============================================================================

module spi_dpram #(parameter DW = 32, parameter AW = 12)
(
	input               clk,

	input      [AW-1:0] wr_addr,
	input      [DW-1:0] wr_data,
	input               wr_en,

	input      [AW-1:0] rd_addr,
	output reg [DW-1:0] rd_data
);

	(* ramstyle = "no_rw_check" *) reg [DW-1:0] mem [0:(1<<AW)-1];

	always @(posedge clk) begin
		if (wr_en) mem[wr_addr] <= wr_data;
		rd_data <= mem[rd_addr];
	end

endmodule
