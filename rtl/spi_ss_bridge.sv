//============================================================================
//  SeibuSPI - an ssbus slave on clk_sys for a memory clocked by clk_cpu
//
//  WHY THIS EXISTS. Arcade-IGSPGM's `ram_ss_adaptor` assumes the savestate bus
//  and the RAM share a clock, which is true there and is not true here:
//  `memory_stream` has to run on clk_sys because that is the DDR3 domain
//  (`DDRAM_CLK = clk_sys`), while spi_mainram is clocked entirely by clk_cpu
//  and the three video RAMs take their WRITE port from it. So the transfer
//  crosses a domain, and the ssbus protocol is a streaming one -- the master
//  holds `read` asserted and expects one `ack` per cycle -- which means a slave
//  acking on clk_cpu would present `ack` high for two clk_sys cycles and be
//  counted twice.
//
//  This is not a CDC in the usual sense and deliberately has no synchroniser.
//  clk_cpu is clk_sys/2 off the same PLL and phase aligned (rtl/pll.v), so the
//  two are one clock group and the only real question is which clk_sys edges
//  coincide with a clk_cpu edge. Rather than derive that -- which would make
//  the design depend on a phase relationship no constraint states -- every
//  transaction simply holds its controls long enough that the answer cannot
//  matter:
//
//    ph 0        latch the address and, for a write, the datum
//    ph 1..3     hold them, and hold `we` for a write
//    ph 4..5     let the RAM's registered output settle
//    ph 6        answer the ssbus, one cycle of `ack`
//
//  THREE cycles of hold, not two. Two is enough to contain a clk_cpu edge, but
//  not enough to contain one that also sees the address already stable: if
//  clk_cpu happens to rise on the very edge that starts the window, it captures
//  the previous address. Three guarantees a full clk_cpu period of stability
//  inside the window. It also means a write may be captured TWICE, on two
//  clk_cpu edges, which is harmless because writing the same datum to the same
//  address twice is idempotent -- that is the property being relied on, so it is
//  worth saying out loud rather than leaving to be re-derived.
//
//  Seven cycles an item is slow by the standards of the rest of this core. It
//  is 8 ms for the 386's 256 KB, once, while the machine is frozen and nothing
//  is waiting on it. The alternative -- deriving the phase and streaming one
//  item per clk_cpu edge -- is four times faster and rests on an assumption
//  that would break silently if the PLL were ever retuned.
//============================================================================

module spi_ss_bridge #(
	parameter     SS_IDX  = -1,
	parameter int AW      = 16,
	parameter int DW      = 32,
	// How many items this section holds. Not 2**AW: the palette is 4096 x 30
	// in a 12-bit space, but a section whose count and width disagree with the
	// address space would be written short or long.
	parameter int ITEMS   = 1 << AW,
	// A write-only port, for a memory whose read side the savestate reaches
	// somewhere else. Reads answer zero rather than stalling the stream.
	parameter bit WR_ONLY = 0
)(
	input               clk,        // clk_sys, with memory_stream

	ssbus_if.slave      ssbus,

	output reg [AW-1:0] ram_addr,
	output reg [DW-1:0] ram_din,
	output reg          ram_we,
	input      [DW-1:0] ram_dout
);

	// The width CODE memory_stream packs by: 0=8, 1=16, 2=32, 3=64 bits.
	localparam int SS_BYTES = (DW + 7) / 8;
	localparam int SS_CODE  = SS_BYTES > 4 ? 3 : SS_BYTES > 2 ? 2 :
	                          SS_BYTES > 1 ? 1 : 0;

	reg [2:0] ph;

	always @(posedge clk) begin
		ssbus.setup(SS_IDX, ITEMS, SS_CODE);

		if (ssbus.access(SS_IDX)) begin
			case (ph)
			3'd0: begin
				ram_addr <= ssbus.addr[AW-1:0];
				ram_din  <= ssbus.data[DW-1:0];
				ram_we   <= ssbus.write;
				ph       <= 3'd1;
			end
			3'd1, 3'd2: begin
				ram_we <= ssbus.write;   // held across ph 1..3
				ph     <= ph + 3'd1;
			end
			3'd3: begin
				ram_we <= 1'b0;
				ph     <= ssbus.write ? 3'd6 : 3'd4;
			end
			3'd4, 3'd5: ph <= ph + 3'd1;
			3'd6: begin
				if (ssbus.write) ssbus.write_ack(SS_IDX);
				else             ssbus.read_response(SS_IDX,
				                     WR_ONLY ? 64'd0
				                             : {{(64-DW){1'b0}}, ram_dout});
				ph <= 3'd0;
			end
			default: ph <= 3'd0;
			endcase
		end
		else begin
			ph     <= 3'd0;
			ram_we <= 1'b0;
		end
	end

endmodule
