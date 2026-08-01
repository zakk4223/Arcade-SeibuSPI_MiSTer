//============================================================================
//  SlopperPI - Seibu SPI / SXX2E
//
//  386 main RAM: 256 KB (64K x 32), true dual port.
//
//  Port A is the CPU. Port B is a read-only port for the video DMA engines,
//  which copy tilemap / palette / sprite data out of main RAM when the game
//  writes one of the DMA trigger registers.
//
//  No coherency logic is needed on port B: the z386 data cache is write-through
//  with an in-order store queue, so by the time the trigger write reaches the
//  I/O decoder every data write it publishes has already landed here.
//
//  Port A read-during-write returns old data. That is fine -- l1_cache forwards
//  from its store queue, so the CPU never observes it.
//
//  Split into four byte lanes so port A gets byte enables; Quartus infers M10K
//  from this shape.
//============================================================================

module spi_mainram
(
	input             clk,

	// Port A - CPU
	input      [15:0] a_addr,     // dword index
	input      [31:0] a_din,
	input       [3:0] a_be,
	input             a_we,
	output reg [31:0] a_dout,

	// Port B - video DMA, read only
	input      [15:0] b_addr,     // dword index
	output reg [31:0] b_dout
);

	(* ramstyle = "M10K" *) reg [7:0] mem0 [0:65535];
	(* ramstyle = "M10K" *) reg [7:0] mem1 [0:65535];
	(* ramstyle = "M10K" *) reg [7:0] mem2 [0:65535];
	(* ramstyle = "M10K" *) reg [7:0] mem3 [0:65535];

	always @(posedge clk) begin
		if (a_we && a_be[0]) mem0[a_addr] <= a_din[ 7: 0];
		if (a_we && a_be[1]) mem1[a_addr] <= a_din[15: 8];
		if (a_we && a_be[2]) mem2[a_addr] <= a_din[23:16];
		if (a_we && a_be[3]) mem3[a_addr] <= a_din[31:24];

		a_dout <= {mem3[a_addr], mem2[a_addr], mem1[a_addr], mem0[a_addr]};
	end

	always @(posedge clk) begin
		b_dout <= {mem3[b_addr], mem2[b_addr], mem1[b_addr], mem0[b_addr]};
	end

endmodule
