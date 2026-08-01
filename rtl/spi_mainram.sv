//============================================================================
//  SlopperPI - Seibu SPI / SXX2E
//
//  386 main RAM: 256 KB (64K x 32), single port.
//
//  It was briefly true dual port, with a second read port for the video DMA.
//  Quartus would not infer that: it duplicated all four byte lanes, taking the
//  array from 2 Mbit to 4 Mbit and blowing the M10K budget outright
//  ("device has 553 RAM locations ... design needs more than 553"). The reason
//  it fit before was that the DMA port was still tied to a constant and had
//  been optimised away entirely.
//
//  So the DMA shares this one port instead, arbitrated in spi_cpu. It only runs
//  in short bursts a few times a frame -- about 1.5% of the CPU's cycles -- and
//  real hardware steals cycles for the same transfers anyway.
//
//  No coherency logic is needed: the z386 data cache is write-through with an
//  in-order store queue, so by the time a DMA trigger write reaches the I/O
//  decoder, every data write it publishes has already landed here.
//
//  Read-during-write returns old data, which l1_cache's store queue forwarding
//  hides from the CPU.
//
//  Split into four byte lanes to get byte enables; Quartus infers M10K from
//  this shape.
//============================================================================

module spi_mainram
(
	input             clk,        // clk_cpu

	input      [15:0] addr,       // dword index
	input      [31:0] din,
	input       [3:0] be,
	input             we,
	output reg [31:0] dout
);

	(* ramstyle = "M10K" *) reg [7:0] mem0 [0:65535];
	(* ramstyle = "M10K" *) reg [7:0] mem1 [0:65535];
	(* ramstyle = "M10K" *) reg [7:0] mem2 [0:65535];
	(* ramstyle = "M10K" *) reg [7:0] mem3 [0:65535];

	always @(posedge clk) begin
		if (we && be[0]) mem0[addr] <= din[ 7: 0];
		if (we && be[1]) mem1[addr] <= din[15: 8];
		if (we && be[2]) mem2[addr] <= din[23:16];
		if (we && be[3]) mem3[addr] <= din[31:24];

		dout <= {mem3[addr], mem2[addr], mem1[addr], mem0[addr]};
	end

endmodule
