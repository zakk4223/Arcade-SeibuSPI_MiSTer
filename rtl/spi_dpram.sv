//============================================================================
//  SeibuSPI - simple dual port RAM (one write port, one read port)
//
//  Separate write and read clocks: the DMA writes from the 386's domain while
//  the video reads from clk_sys. One write port and one read port is a simple
//  dual port, which Quartus infers without duplicating the array (unlike true
//  dual port -- see the note in spi_mainram.sv).
//
//  Read data appears one cycle after the address.
//============================================================================

module spi_dpram #(parameter DW = 32, parameter AW = 12)
(
	input               wr_clk,
	input               rd_clk,

	input      [AW-1:0] wr_addr,
	input      [DW-1:0] wr_data,
	input               wr_en,

	input      [AW-1:0] rd_addr,
	output reg [DW-1:0] rd_data
);

	(* ramstyle = "no_rw_check" *) reg [DW-1:0] mem [0:(1<<AW)-1];

	always @(posedge wr_clk) begin
		if (wr_en) mem[wr_addr] <= wr_data;
	end

	always @(posedge rd_clk) begin
		rd_data <= mem[rd_addr];
	end

endmodule
