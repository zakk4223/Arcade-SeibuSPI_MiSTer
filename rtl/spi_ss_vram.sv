//============================================================================
//  SeibuSPI - an ssbus slave for a video RAM, whose two ports are on two clocks
//
//  spi_dpram is a simple dual port with wr_clk = clk_cpu (the DMA fills it) and
//  rd_clk = clk_sys (the renderers read it). So a savestate reads it through
//  the port it is already on -- clk_sys, same as memory_stream, no crossing --
//  and writes it through the other one, which needs the three-cycle hold
//  spi_ss_bridge's header explains.
//
//  Both directions steal a port that something else drives. The write port is
//  the DMA's and is quiet, because the 386 is frozen and the DMA only runs when
//  it tells it to. The READ port is the renderers', and they are NOT frozen in
//  this phase -- so for the few milliseconds a transfer takes they read whatever
//  the savestate is addressing instead of what they asked for. That is a
//  visible glitch on one frame and nothing more: no state is corrupted, because
//  the renderers only read.
//
//  WORTH KNOWING, if the port stealing on these three ever costs timing: they
//  are the cheapest sections to give up. All three are filled by spi_dma out of
//  main RAM, which IS saved, so a restore that dropped them would repopulate
//  them the next time the game triggers a DMA. Measured on rdfts that is every
//  three frames or so rather than every frame, so the cost of dropping them
//  would be a few frames of stale palette and tilemap after a load -- ugly, and
//  not wrong. They are kept because 36 KB is cheap; this note is here so the
//  trade is on record rather than rediscovered.
//============================================================================

module spi_ss_vram #(
	parameter     SS_IDX = -1,
	parameter int AW     = 12,
	parameter int DW     = 32,
	parameter int ITEMS  = 1 << AW
)(
	input               clk,        // clk_sys, with memory_stream

	ssbus_if.slave      ssbus,

	// The renderers' read port, taken while a transfer is in flight.
	output              rd_own,
	output reg [AW-1:0] rd_addr,
	input      [DW-1:0] rd_data,

	// The DMA's write port, on clk_cpu.
	output reg [AW-1:0] wr_addr,
	output reg [DW-1:0] wr_data,
	output reg          wr_en
);

	localparam int SS_BYTES = (DW + 7) / 8;
	localparam int SS_CODE  = SS_BYTES > 4 ? 3 : SS_BYTES > 2 ? 2 :
	                          SS_BYTES > 1 ? 1 : 0;

	reg [2:0] ph;

	// The read port is ours only while this section is being addressed, so a
	// save glitches the picture and a load does not touch it at all.
	assign rd_own = ssbus.access(SS_IDX) && ssbus.read;

	always @(posedge clk) begin
		ssbus.setup(SS_IDX, ITEMS, SS_CODE);

		if (ssbus.access(SS_IDX)) begin
			case (ph)
			3'd0: begin
				rd_addr <= ssbus.addr[AW-1:0];
				wr_addr <= ssbus.addr[AW-1:0];
				wr_data <= ssbus.data[DW-1:0];
				wr_en   <= ssbus.write;
				ph      <= 3'd1;
			end
			// Writes hold for three cycles, so exactly one clk_cpu edge sees
			// the address already stable. Reads need only the one cycle
			// spi_dpram's registered output costs, but take the same path for
			// the sake of one state machine.
			3'd1, 3'd2: begin
				wr_en <= ssbus.write;
				ph    <= ph + 3'd1;
			end
			3'd3: begin
				wr_en <= 1'b0;
				if (ssbus.write) ssbus.write_ack(SS_IDX);
				else             ssbus.read_response(SS_IDX,
				                     {{(64-DW){1'b0}}, rd_data});
				ph <= 3'd0;
			end
			default: ph <= 3'd0;
			endcase
		end
		else begin
			ph    <= 3'd0;
			wr_en <= 1'b0;
		end
	end

endmodule
