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
	// Only the sprite-DMA triggers still need a half-word enable; the CRTC
	// registers are merged byte by byte below.
	wire        be_hi = be[2] | be[3];

	// Read/write storage behind the whole CRTC window (0x400-0x44F, 20 dwords),
	// mirroring MAME's `map(0x0000, 0x004f).ram()`. The decoded registers below
	// still drive the video logic; this exists so the game can read a register
	// back and get what it wrote.
	reg [31:0] crtc_ram [0:19];
	wire       crtc_sel = (dw[10:7] == 4'h8) && (dw[6:2] <= 5'd19);   // 0x400-0x44F

	integer ci;
	initial for (ci = 0; ci < 20; ci = ci + 1) crtc_ram[ci] = 32'd0;

	always @(posedge clk) begin
		if (wr && crtc_sel) begin
			if (be[0]) crtc_ram[dw[6:2]][ 7: 0] <= wdata[ 7: 0];
			if (be[1]) crtc_ram[dw[6:2]][15: 8] <= wdata[15: 8];
			if (be[2]) crtc_ram[dw[6:2]][23:16] <= wdata[23:16];
			if (be[3]) crtc_ram[dw[6:2]][31:24] <= wdata[31:24];
		end
	end

	// The whole 16-bit reg_1a is kept, and the two flags are derived from it, so
	// a partial write can only disturb the byte it actually addresses. MAME does
	// the same: COMBINE_DATA into m_layer_bank, then BIT(m_layer_bank, 15).
	/* verilator lint_off UNUSEDSIGNAL */
	reg [15:0] layer_bank;   // only bits 15 and 11 are decoded
	/* verilator lint_on UNUSEDSIGNAL */
	always @(posedge clk) begin
		rowscroll_enable <= layer_bank[15];
		fore_layer_d13   <= layer_bank[11];
	end

	always @(posedge clk) begin
		dma_tilemap   <= 1'b0;
		dma_palette   <= 1'b0;
		dma_sprite    <= 1'b0;
		sndfifo_wr    <= 1'b0;

		if (reset) begin
			layer_enable     <= 5'b00000;   // MAME video_start: 0 = all layers enabled

			rf2_layer_bank   <= 3'd0;
			{scroll_bx, scroll_by} <= 32'd0;
			{scroll_mx, scroll_my} <= 32'd0;
			{scroll_fx, scroll_fy} <= 32'd0;
			dma_src <= 18'd0;
			dma_len <= 16'd0;
			layer_bank <= 16'd0;
		end
		else if (wr) begin
			case (dw)
				// ---- Seibu CRTC ----------------------------------------
				11'h414: ;                                   // decrypt key, ignored
				// Every CRTC register is merged PER BYTE, which is what MAME's
				// COMBINE_DATA does: bytes outside mem_mask keep their old value.
				//
				// reg_1a is the register that made this matter. It is 16 bits at
				// 0x41A, so its low byte is 0x41A (be[2]) and its HIGH byte --
				// carrying both rowscroll_enable (bit 15) and fore_layer_d13
				// (bit 11) -- is 0x41B (be[3]). Gating both on be[2]|be[3] meant a
				// write touching only 0x41A latched bit 15 from a byte the game
				// never drove, clearing rowscroll_enable.
				//
				// That single bit decides the tilemap DMA's source layout: with
				// rowscroll on the source is
				//     back, back_rs, fore, fore_rs, midl, midl_rs, text  (4096 dw)
				// and with it off
				//     back, fore, midl, text                             (2560 dw)
				// so losing it makes the DMA misparse the whole buffer. The game's
				// FORE tiles land in the midl region and are drawn with the midl
				// palette, back gets the back rowscroll values as if they were
				// tiles, and fore and text end up empty -- which is exactly the
				// picture the board produced: one layer of content in the wrong
				// colours over a black screen.
				11'h418: begin                               // 0x41A reg_1a
					if (be[2]) layer_bank[ 7:0] <= wdata[23:16];
					if (be[3]) layer_bank[15:8] <= wdata[31:24];
				end
				// layer_enable is bits 4:0 -- the LOW byte of the 16-bit register
				// at 0x41C, so it follows be[0] alone.
				11'h41C: if (be[0]) layer_enable <= wdata[4:0];
				11'h420: begin
					if (be[0]) scroll_bx[ 7:0] <= wdata[ 7:0];
					if (be[1]) scroll_bx[15:8] <= wdata[15:8];
					if (be[2]) scroll_by[ 7:0] <= wdata[23:16];
					if (be[3]) scroll_by[15:8] <= wdata[31:24];
				end
				11'h424: begin
					if (be[0]) scroll_mx[ 7:0] <= wdata[ 7:0];
					if (be[1]) scroll_mx[15:8] <= wdata[15:8];
					if (be[2]) scroll_my[ 7:0] <= wdata[23:16];
					if (be[3]) scroll_my[15:8] <= wdata[31:24];
				end
				11'h428: begin
					if (be[0]) scroll_fx[ 7:0] <= wdata[ 7:0];
					if (be[1]) scroll_fx[15:8] <= wdata[15:8];
					if (be[2]) scroll_fy[ 7:0] <= wdata[23:16];
					if (be[3]) scroll_fy[15:8] <= wdata[31:24];
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
	// 0x684  d0 = _FF of the 386->Z80 FIFO, d1 = _EF of the Z80->386 FIFO.
	//        Both are the ACTIVE LOW pins: MAME's ff_r()/ef_r() return the
	//        negated internal flags, so d0 reads 1 when there is room to send
	//        and d1 reads 0 while nothing has come back. Getting d0 backwards
	//        makes the 386 believe the sound FIFO is permanently full and it
	//        spins here forever, a few frames into the boot.
	// 0x6DC  DS2404 data      0x6DD  d0-d2 must read back clear
	// ------------------------------------------------------------------
	always @* begin
		case (dw)
			// 0x400-0x44F is READ/WRITE. MAME backs the whole Seibu CRTC window
			// with `map(0x0000, 0x004f).ram()` and overlays the register handlers
			// on top, so a read returns whatever was last written -- reg_1a even
			// has an explicit reg_1a_r().
			//
			// Returning zero here instead breaks the game's read-modify-write of
			// reg_1a: it reads 0, ORs in the fore-layer bit and writes back, and
			// bit 15 (rowscroll enable) is destroyed in the process. On the board
			// rowscroll came up 1 and then dropped to 0 at the exact moment
			// fore_d13 went to 1, which is that sequence exactly. Losing it makes
			// the tilemap DMA parse the source with the wrong layout, so the
			// game's FORE tiles land in the midl region, are drawn with the midl
			// palette, and back/fore/text render nothing.
			11'h400, 11'h404, 11'h408, 11'h40C,
			11'h410, 11'h414, 11'h418, 11'h41C,
			11'h420, 11'h424, 11'h428, 11'h42C,
			11'h430, 11'h434, 11'h438, 11'h43C,
			11'h440, 11'h444, 11'h448, 11'h44C: rdata = crtc_ram[dw[6:2]];
			11'h600: rdata = 32'h0000_0001;
			11'h604: rdata = {16'hFFFF, inputs};
			11'h608: rdata = 32'hFFFF_FFFF;
			11'h60C: rdata = {24'hFFFFFF, system};
			11'h680: rdata = {24'd0, coin_latch};
			11'h684: rdata = {30'd0, 1'b0, ~sndfifo_full}; // d1=0: nothing from the Z80 yet
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
