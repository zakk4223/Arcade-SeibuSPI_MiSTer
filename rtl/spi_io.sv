//============================================================================
//  SeibuSPI - Seibu SPI / SXX2E
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

	// DS2404 (rtl/spi_ds2404.sv), which runs on clk_ram: the three write ports
	// go across as ONE request toggle with the port number beside it, so two
	// writes cannot be seen out of order, and `ds_stall` holds the 386 off until
	// the far side acks. 0x6DC comes back as a settled register.
	output reg        ds_req,
	output reg  [1:0] ds_port,
	output reg  [7:0] ds_data,
	input             ds_ack,
	input       [7:0] ds_dout,
	output            ds_stall,

	// Sound (T5)
	output reg  [7:0] sndfifo_din,
	output reg        sndfifo_wr,
	input             sndfifo_full,     // 386 -> Z80 FIFO full flag
	input       [7:0] coin_latch,       // latched by the Z80's coin write
	output reg        coin_latch_rd,

	// ---- SXX2C cartridge ------------------------------------------------
	input             set_sxx2c,
	// Z80 -> 386 FIFO. On the cartridge this REPLACES the coin latch at 0x680;
	// coins arrive as a FIFO message instead of through sb_coin_r.
	input       [7:0] fifo2_q,
	input             fifo2_empty,
	output reg        fifo2_rd,
	// Z80 program download. The Z80's 256 KB is RAM here, pushed a byte at a
	// time through 0x688 with an auto-incrementing pointer and released by
	// 0x68C d0, which also resets the pointer (z80_prg_transfer_w /
	// z80_enable_w). The pointer and the payload live in THIS clock domain so
	// no write can be lost crossing to the SDRAM side; the CPU is stalled
	// instead, which is also what the real board does when it steals the bus.
	output reg [17:0] z80dl_addr,
	output reg  [7:0] z80dl_data,
	output reg        z80dl_req,
	input             z80dl_ack,

	output            z80dl_stall,
	// High-water mark of the download: one past the highest region offset the
	// 386 has ever written. Everything at or above it is SDRAM nobody has
	// filled, and `spi_sound` reads it back as MAME's zero padding instead.
	output reg [18:0] z80dl_end,
	output reg        z80_rst_n,
	// ---- the savestate's view of this file, as 26 dwords ----------------
	// Presented as a little memory so it can go through spi_ss_bridge like
	// everything else, rather than growing a fourth hand-rolled crossing from
	// the ssbus's clk_sys into this file's clk_cpu. Nothing in here free-runs
	// -- there is no counter, no timer and no raster input -- so it needs no
	// pause: with the 386 frozen and the DS2404 and the Z80 held, every
	// register below is already still.
	//
	// What is NOT here, and why: the one-cycle strobes (the three DMA
	// triggers, the sound FIFO write, the coin and FIFO2 reads), which are low
	// whenever the CPU is not mid-write; the SXX2C Z80 download engine, which
	// only runs at boot; and the two crossing handshakes, which are idle at an
	// instruction boundary because `io_stall` is what holds the CPU off one.
	input       [4:0] ss_addr,
	input      [31:0] ss_din,
	input             ss_we,
	output reg [31:0] ss_dout
);

	// ------------------------------------------------------------------
	// Z80 program download state (SXX2C). 19 bits so bit 18 is the "past the
	// end of the 256 KB region" guard rather than a silent wrap.
	// ------------------------------------------------------------------
	reg [18:0] dl_pos;
	reg        dl_pend;
	reg        dl_ack_s1, dl_ack_s2;

	// The CPU is held off while a pushed byte is still in flight to SDRAM.
	// Asserted in the CPU's own clock domain on the write itself, so there is
	// no window in which a second byte could be accepted and dropped; only the
	// release crosses back, and a late release just costs cycles.
	assign z80dl_stall = dl_pend;

	// The same shape for the DS2404, and for the same reason: a byte is in
	// flight to another clock domain and a second write would overtake it. The
	// wait is one or two cycles for everything except a scratchpad copy, which
	// takes one per byte.
	reg        ds_pend;
	reg        ds_ack_s1, ds_ack_s2;
	assign ds_stall = ds_pend;

	// 0x6DC's byte comes the other way across the same crossing. It is settled
	// for thousands of cycles -- the chip only moves it two cycles after a port
	// write, and the 386 cannot issue the OUT and the IN that reads it any closer
	// together -- but registering it here rather than feeding clk_ram's own
	// register into the CPU's read mux keeps the timed path a single hop, and
	// keeps a byte that changes in another domain out of a combinational bus.
	reg  [7:0] ds_dout_r;

	// NOTE: everything this block would have driven lives in the write block
	// below instead. Quartus rejects a net driven from two always blocks --
	// "Can't resolve multiple constant drivers" -- and Verilator's -Wall does
	// NOT, which is the same trap section 11 records for spi_mixer's RGB.

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
		// The savestate wins, which costs nothing: it only ever writes while
		// the CPU is frozen, so `wr` is low.
		if (ss_we && (ss_addr < 5'd20)) crtc_ram[ss_addr] <= ss_din;
		else if (wr && crtc_sel) begin
			if (be[0]) crtc_ram[dw[6:2]][ 7: 0] <= wdata[ 7: 0];
			if (be[1]) crtc_ram[dw[6:2]][15: 8] <= wdata[15: 8];
			if (be[2]) crtc_ram[dw[6:2]][23:16] <= wdata[23:16];
			if (be[3]) crtc_ram[dw[6:2]][31:24] <= wdata[31:24];
		end
	end

	// Registered, because spi_ss_bridge expects a RAM's one-cycle read latency.
	always @(posedge clk) begin
		case (ss_addr)
			5'd20:   ss_dout <= {scroll_by, scroll_bx};
			5'd21:   ss_dout <= {scroll_my, scroll_mx};
			5'd22:   ss_dout <= {scroll_fy, scroll_fx};
			5'd23:   ss_dout <= {7'd0, rf2_layer_bank, z80_rst_n,
			                     layer_enable, layer_bank};
			5'd24:   ss_dout <= {14'd0, dma_src};
			5'd25:   ss_dout <= {16'd0, dma_len};
			default: ss_dout <= crtc_ram[ss_addr];
		endcase
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

		// Z80 download handshake back from the SDRAM side.
		dl_ack_s1 <= z80dl_ack;
		dl_ack_s2 <= dl_ack_s1;
		if (dl_pend && (dl_ack_s2 == z80dl_req)) dl_pend <= 1'b0;

		// The DS2404's, which the write block below re-raises in the same cycle
		// if it starts another access -- the last assignment wins, as it does
		// for dl_pend.
		ds_ack_s1 <= ds_ack;
		ds_ack_s2 <= ds_ack_s1;
		ds_dout_r <= ds_dout;
		if (ds_pend && (ds_ack_s2 == ds_req)) ds_pend <= 1'b0;

		if (reset) begin
			dl_pos    <= 19'd0;
			dl_pend   <= 1'b0;
			z80dl_req <= 1'b0;
			ds_pend   <= 1'b0;
			ds_req    <= 1'b0;
			ds_port   <= 2'd0;
			ds_data   <= 8'd0;
			ds_ack_s1 <= 1'b0;
			ds_ack_s2 <= 1'b0;
			ds_dout_r <= 8'd0;
			z80dl_end <= 19'd0;
			// Held in reset until the 386 releases it. On SXX2E the Z80 runs
			// from ROM and must not be gated, so this reads as 1 there.
			z80_rst_n <= ~set_sxx2c;

			layer_enable     <= 5'b00000;   // MAME video_start: 0 = all layers enabled

			rf2_layer_bank   <= 3'd0;
			{scroll_bx, scroll_by} <= 32'd0;
			{scroll_mx, scroll_my} <= 32'd0;
			{scroll_fx, scroll_fy} <= 32'd0;
			dma_src <= 18'd0;
			dma_len <= 16'd0;
			layer_bank <= 16'd0;
		end
		else if (ss_we) begin
			// rowscroll_enable and fore_layer_d13 are not written here: they
			// are derived from layer_bank one cycle later by the block above,
			// so restoring layer_bank restores them too.
			case (ss_addr)
				5'd20: {scroll_by, scroll_bx} <= ss_din;
				5'd21: {scroll_my, scroll_mx} <= ss_din;
				5'd22: {scroll_fy, scroll_fx} <= ss_din;
				5'd23: begin
					layer_bank     <= ss_din[15:0];
					layer_enable   <= ss_din[20:16];
					z80_rst_n      <= ss_din[21];
					rf2_layer_bank <= ss_din[24:22];
				end
				5'd24: dma_src <= ss_din[17:0];
				5'd25: dma_len <= ss_din[15:0];
				default: ;
			endcase
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
				11'h68C: begin
					// 0x68C z80_enable_w: d0 releases the Z80, and the write
					// resets the transfer pointer whichever way d0 goes.
					if (be[0] && set_sxx2c) begin
						z80_rst_n <= wdata[0];
						dl_pos    <= 19'd0;
					end
					if (be[2]) rf2_layer_bank <= wdata[18:16];  // 0x68E
				end


				// 0x688 z80_prg_transfer_w. MAME drops writes past the end of
				// the region and stops advancing, so do the same.
				11'h688: if (be[0] && set_sxx2c && !dl_pos[18]) begin
					z80dl_addr <= dl_pos[17:0];
					z80dl_data <= wdata[7:0];
					z80dl_req  <= ~z80dl_req;
					dl_pend    <= 1'b1;
					dl_pos     <= dl_pos + 19'd1;
					// 0x68C rewinds dl_pos, so the high-water mark has to be
					// kept separately. It is the union of every transfer,
					// which is exactly the set of bytes that hold real data.
					if ((dl_pos + 19'd1) > z80dl_end) z80dl_end <= dl_pos + 19'd1;
				end

				// ---- DS2404 ---------------------------------------------
				// Three byte ports, each its own dword. The chip is on clk_ram
				// and this is clk_cpu, so all three go through one toggle.
				11'h6D0: if (be[0]) begin           // 1-wire reset
					ds_port <= 2'd0; ds_data <= 8'd0;
					ds_req  <= ~ds_req; ds_pend <= 1'b1;
				end
				11'h6D4: if (be[0]) begin           // data
					ds_port <= 2'd1; ds_data <= wdata[7:0];
					ds_req  <= ~ds_req; ds_pend <= 1'b1;
				end
				11'h6D8: if (be[0]) begin           // clock
					ds_port <= 2'd2; ds_data <= 8'd0;
					ds_req  <= ~ds_req; ds_pend <= 1'b1;
				end

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
	// 0x6DC  DS2404 data, from the chip now and not a hardwired zero
	// 0x6DD  d0-d2 must read back clear
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
			// On SXX2C 0x680 is the Z80->386 FIFO, not the coin latch.
			11'h680: rdata = {24'd0, set_sxx2c ? fifo2_q : coin_latch};
			// d1 = _EF of the Z80->386 FIFO: 0 while it is empty. SXX2E has no
			// such FIFO (m_soundfifo[1] is a nullptr there) so it reads 0.
			11'h684: rdata = {30'd0, set_sxx2c & ~fifo2_empty, ~sndfifo_full};
			// 0x6DC is the DS2404's data byte and 0x6DD is the three bits the
			// game waits to see clear -- the same dword, so one entry covers
			// both, and MAME's spi_ds2404_unknown_r returns zero for the second.
			11'h6DC: rdata = {24'd0, ds_dout_r};
			default: rdata = 32'h0000_0000;
		endcase
	end

	// Reading 0x680 clears the coin latch (sb_coin_r).
	always @(posedge clk) begin
		if (reset) begin
			coin_latch_rd <= 1'b0;
			fifo2_rd      <= 1'b0;
		end
		else begin
			coin_latch_rd <= rd && (dw == 11'h680) && !set_sxx2c;
			fifo2_rd      <= rd && (dw == 11'h680) &&  set_sxx2c;
		end
	end

endmodule
