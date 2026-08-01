//============================================================================
//  SlopperPI - Seibu SPI / SXX2E
//
//  Memory-mapped I/O at 0x400-0x7FF, overlaying main RAM.
//  (sxx2e_map / base_map, seibuspi.cpp:1004,1077; seibu_crtc.cpp)
//
//  The Seibu CRTC sits at 0x400-0x43F. MAME reaches it through
//  seibu_crtc_device::write(offset, data), which then writes word `offset` of
//  the CRTC's own 16-bit space -- so a CRTC register documented at internal
//  byte address N is simply CPU byte address 0x400 + N. The registers this
//  board actually uses:
//
//    0x414  tile decrypt key   (ignored: the keys are constants, see
//                               spi_tile_decrypt.sv)
//    0x41A  reg_1a  bit15 = rowscroll enable, bit11 = fore layer d13
//    0x41C  layer enable, 0 = on, 1 = off
//             bit0 back  bit1 middle  bit2 fore  bit3 text  bit4 sprite
//    0x420  back scroll X    0x422  back scroll Y
//    0x424  midl scroll X    0x426  midl scroll Y
//    0x428  fore scroll X    0x42A  fore scroll Y
//    0x42C-0x43B  scroll base, unused by the SPI driver
//============================================================================

module spi_io
(
	input             clk,
	input             reset,

	// CPU side
	input      [10:2] addr,       // dword address (bits 1:0 are implicit)
	input      [31:0] wdata,
	input       [3:0] be,
	input             wr,
	input             rd,
	output reg [31:0] rdata,

	// Controls, active low as the hardware presents them
	input      [15:0] inputs,
	input       [7:0] system,

	// Video registers
	output reg  [4:0] layer_enable,     // 0 = on
	output reg        rowscroll_enable,
	output reg        fore_layer_d13,
	output reg  [2:0] rf2_layer_bank,   // 0x68E; not written on SXX2E
	output reg [15:0] scroll_bx, scroll_by,
	output reg [15:0] scroll_mx, scroll_my,
	output reg [15:0] scroll_fx, scroll_fy,

	// Video DMA
	output reg [17:0] dma_src,          // byte address in main RAM
	output reg [15:0] dma_len,          // raw register; bytes = (len+1)*2
	output reg        dma_tilemap,      // single cycle pulses
	output reg        dma_palette,
	output reg        dma_sprite,

	// Sound (T5)
	output reg  [7:0] sndfifo_din,
	output reg        sndfifo_wr,
	input             sndfifo_full,     // 386 -> Z80 FIFO full flag
	input       [7:0] coin_latch,       // latched by the Z80's coin write
	output reg        coin_latch_rd
);

	// ------------------------------------------------------------------
	// Writes
	// ------------------------------------------------------------------
	wire [10:0] dw = {addr, 2'b00};   // dword-aligned byte address

	// A 16-bit CRTC register at byte address A lands in the upper or lower half
	// of dword A & ~3 depending on bit 1.
	wire [15:0] w_lo = wdata[15:0];
	wire [15:0] w_hi = wdata[31:16];
	wire        be_lo = be[0] | be[1];
	wire        be_hi = be[2] | be[3];

	always @(posedge clk) begin
		dma_tilemap   <= 1'b0;
		dma_palette   <= 1'b0;
		dma_sprite    <= 1'b0;
		sndfifo_wr    <= 1'b0;

		if (reset) begin
			layer_enable     <= 5'b00000;   // MAME video_start: 0 = all layers enabled
			rowscroll_enable <= 1'b0;
			fore_layer_d13   <= 1'b0;
			rf2_layer_bank   <= 3'd0;
			{scroll_bx, scroll_by} <= 32'd0;
			{scroll_mx, scroll_my} <= 32'd0;
			{scroll_fx, scroll_fy} <= 32'd0;
			dma_src <= 18'd0;
			dma_len <= 16'd0;
		end
		else if (wr) begin
			case (dw)
				// ---- Seibu CRTC ----------------------------------------
				11'h414: ;                                   // decrypt key, ignored
				11'h418: if (be_hi) begin                    // 0x41A reg_1a
					rowscroll_enable <= w_hi[15];
					fore_layer_d13   <= w_hi[11];
				end
				11'h41C: if (be_lo) layer_enable <= w_lo[4:0];
				11'h420: begin
					if (be_lo) scroll_bx <= w_lo;
					if (be_hi) scroll_by <= w_hi;
				end
				11'h424: begin
					if (be_lo) scroll_mx <= w_lo;
					if (be_hi) scroll_my <= w_hi;
				end
				11'h428: begin
					if (be_lo) scroll_fx <= w_lo;
					if (be_hi) scroll_fy <= w_hi;
				end

				// ---- video DMA -----------------------------------------
				11'h480: dma_tilemap <= 1'b1;
				11'h484: dma_palette <= 1'b1;
				11'h490: dma_len     <= wdata[15:0];
				11'h494: dma_src     <= wdata[17:0];
				11'h498: ;                                   // dma address high, always 0

				// ---- sprite chip ---------------------------------------
				// The trigger address depends on which sprite chip is fitted:
				// SEI252 (sei252_map) uses 0x50E, RISE10/11 (rise_map) 0x562.
				// rdfts is SEI252 -- sxx2e_map calls sei252_map -- but both are
				// decoded so the RISE sets can share this file later.
				11'h50C: if (be_hi) dma_sprite <= 1'b1;      // 0x50E, SEI252
				11'h54C: ;                                   // RISE10/11 decrypt key, ignored
				11'h560: if (be_hi) dma_sprite <= 1'b1;      // 0x562, RISE10/11

				// ---- sound / misc --------------------------------------
				11'h680: if (be[0]) begin
					sndfifo_din <= wdata[7:0];
					sndfifo_wr  <= 1'b1;
				end
				11'h68C: if (be[2]) rf2_layer_bank <= wdata[18:16];  // 0x68E, SXX2F/SYS386I

				default: ;
			endcase
		end
	end

	// ------------------------------------------------------------------
	// Reads (combinational; the CPU registers the result)
	//
	// 0x600  d0 = "video/dma ready", the game spins until it is set
	// 0x604  INPUTS   0x608 EXCH (unused, all ones)   0x60C SYSTEM
	// 0x680  coin latch, cleared by reading
	// 0x684  d0 = 386->Z80 FIFO full, d1 = Z80->386 FIFO empty
	// 0x6DC  DS2404 data      0x6DD  d0-d2 must read back clear
	// ------------------------------------------------------------------
	always @* begin
		case (dw)
			11'h600: rdata = 32'h0000_0001;
			11'h604: rdata = {16'hFFFF, inputs};
			11'h608: rdata = 32'hFFFF_FFFF;
			11'h60C: rdata = {24'hFFFFFF, system};
			11'h680: rdata = {24'd0, coin_latch};
			11'h684: rdata = {30'd0, 1'b1, sndfifo_full};  // Z80->386 FIFO always empty for now
			11'h6DC: rdata = 32'h0000_0000;
			default: rdata = 32'h0000_0000;
		endcase
	end

	// Reading 0x680 clears the coin latch (sb_coin_r).
	always @(posedge clk) begin
		if (reset) coin_latch_rd <= 1'b0;
		else       coin_latch_rd <= rd && (dw == 11'h680);
	end

endmodule
