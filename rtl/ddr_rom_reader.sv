//============================================================================
//  SeibuSPI - Seibu SPI / SXX2E
//
//  "Fast" ROM loading: the HPS DMAs the MRA's index-0 image straight into
//  DDR3 and this module reads it back out as a byte stream, so `rom_loader`
//  sees exactly the interface it always has.
//
//  WHY AN ADAPTOR RATHER THAN A NEW LOADER. rom_loader does not copy bytes,
//  it TRANSFORMS them: a 14-part scatter with ten destination modes, the
//  BPE+DPCM decoder for rdft2's and rfjet's sample flash, and MAME's
//  sprite_reorder swizzle folded into the destination address. All of that is
//  verified byte-exact against MAME (PLAN.md section 12) and none of it wants
//  reimplementing against a different source. Replaying DDR3 as the same byte
//  stream keeps every one of those tests meaningful.
//
//  WHAT CHANGES ABOUT ioctl, which is the whole trap here:
//
//  * `ioctl_wr` NEVER FIRES. The data never crosses the FPGA's ioctl bus at
//    all -- Main_MiSTer writes it to DDR3 itself. That is how a fast download
//    is detected: `ioctl_download` went high and then low without a single
//    write. A slow download of the same index is still perfectly legal and
//    passes straight through, which is what keeps an MRA without an `address`
//    attribute working.
//
//  * `ioctl_addr` HOLDS THE LENGTH at the end. hps_io.sv latches
//    `ioctl_addr <= addr` when the HPS closes the transfer, and for a DDR3
//    download `addr` is the size the HPS reports rather than a byte counter it
//    walked. So the image is [DDR_BASE, DDR_BASE + ioctl_addr).
//
//  * `ioctl_download` FALLS LONG BEFORE THE IMAGE IS IN SDRAM. It now means
//    "the HPS has finished", not "the ROM is loaded". Everything that used to
//    key off it -- the core reset above all -- has to follow `dl_download`
//    from here instead, which stays high until the last byte has been handed
//    over. Getting that wrong releases the 386 into an empty SDRAM.
//
//  CLOCKING. This runs on clk_sys, the ioctl and DDRAM domain. rom_loader
//  runs on clk_ram, exactly 2x clk_sys and phase aligned from the same VCO,
//  and detects the RISING EDGE of a pulse that is therefore high across two of
//  its edges. So `dl_wr` must be one clk_sys cycle wide, precisely like the
//  real `ioctl_wr`: a wider strobe is counted twice and PLAN.md 10c is what
//  that looks like on hardware.
//============================================================================

module ddr_rom_reader #(
	// Clear of the framebuffer, which arcade_video.v puts at 0x24000000 with
	// three 8 MB buffers. The largest image here is rfjet's ~40 MB.
	parameter [31:0] DDR_BASE = 32'h3000_0000
)(
	input             clk,          // clk_sys
	input             reset,

	// ---- from hps_io ------------------------------------------------------
	input             ioctl_download,
	input       [7:0] ioctl_index,
	input      [25:0] ioctl_addr,
	input             ioctl_wr,
	input       [7:0] ioctl_dout,
	output            ioctl_wait,

	// ---- to rom_loader, byte for byte what ioctl used to look like --------
	output reg        dl_download,
	output            dl_wr,
	output      [7:0] dl_dout,
	output      [7:0] dl_index,
	input             dl_wait,      // rom_loader's ioctl_wait, on clk_ram

	// ---- DDR3 read master -------------------------------------------------
	// `ddr_active` asks for the bus; see the mux in SeibuSPI.sv for why the
	// framebuffer simply loses it for the duration.
	output reg        ddr_active,
	output reg [28:0] ddr_addr,     // 64-bit word address, i.e. byte addr >> 3
	output reg        ddr_rd,
	input      [63:0] ddr_dout,
	input             ddr_dout_ready,
	input             ddr_busy
);

	localparam [7:0] ROM_INDEX = 8'd0;

	localparam [2:0] S_IDLE  = 3'd0,
	                 S_READ  = 3'd1,
	                 S_WAIT  = 3'd2,
	                 S_EMIT  = 3'd3,
	                 S_SETTLE= 3'd4;

	reg  [2:0] state;
	reg [25:0] length;
	reg [25:0] offset;
	reg [63:0] buffer;
	reg        wr_seen;
	reg        dl_d;
	reg  [1:0] settle;
	reg        ddr_wr;
	reg  [7:0] ddr_byte;

	wire index0  = (ioctl_index == ROM_INDEX);
	wire replay  = (state != S_IDLE);

	// THE PASS-THROUGH IS COMBINATIONAL, deliberately. A slow download has to
	// behave exactly as it did when these wires ran straight from hps_io to
	// rom_loader: the loader's header records that `ioctl_wait` already has a
	// cycle of latency and only works because the HPS is slower than the SDRAM,
	// so spending another cycle here to save a few gates would be eating the
	// margin that makes the fallback path work at all.
	//
	// `dl_download` is the exception and is registered, because it must not
	// DIP. It changes only on a decision -- the download ended and was slow, or
	// the replay finished -- so at the moment `ioctl_download` falls on a fast
	// download it simply stays high. A one-cycle dip would look to rom_loader
	// like the end of the image: it would reset `part` to 0 and pulse
	// `rom_ready`, which is wired to the ROM checker's `start`, and the checker
	// would begin sweeping ch3 against an image that does not exist yet.
	assign dl_index   = replay ? ROM_INDEX : ioctl_index;
	assign dl_wr      = replay ? ddr_wr    : ioctl_wr;
	assign dl_dout    = replay ? ddr_byte  : ioctl_dout;
	assign ioctl_wait = replay ? 1'b0      : dl_wait;

	always @(posedge clk) begin
		dl_d   <= ioctl_download;
		ddr_wr <= 1'b0;

		if (index0 && ioctl_download && ioctl_wr) wr_seen <= 1'b1;

		case (state)

		// Pass-through. A slow download drives the loader through the
		// combinational assigns above and this module is a wire; only a
		// download that ended without ever writing starts a replay.
		S_IDLE: begin
			ddr_active  <= 1'b0;
			ddr_rd      <= 1'b0;
			dl_download <= ioctl_download;

			if (index0 && dl_d && !ioctl_download) begin
				wr_seen <= 1'b0;
				if (!wr_seen && |ioctl_addr) begin
					length      <= ioctl_addr;
					offset      <= 26'd0;
					dl_download <= 1'b1;   // hold the loader open, do not dip
					state       <= S_READ;
				end
			end
		end

		S_READ: begin
			ddr_active <= 1'b1;
			if (!ddr_busy) begin
				// DDRAM_ADDR is a 64-BIT WORD address, not a byte address, so
				// the base has to be shifted too: 0x30000000 is word
				// 0x06000000. Adding a byte base to a word offset here would
				// read from 0x180000000 and the fitter would not care.
				ddr_addr <= DDR_BASE[31:3] + {6'd0, offset[25:3]};
				ddr_rd   <= 1'b1;
				state    <= S_WAIT;
			end
		end

		S_WAIT: begin
			if (!ddr_busy) ddr_rd <= 1'b0;
			if (ddr_dout_ready) begin
				buffer     <= ddr_dout;
				ddr_rd     <= 1'b0;
				ddr_active <= 1'b0;
				state      <= S_EMIT;
			end
		end

		// One byte per handshake, and the handshake is the delicate part.
		// rom_loader raises its ioctl_wait on a clk_ram edge AFTER it sees the
		// strobe, so `dl_wait` cannot be trusted in the cycle right after
		// `dl_wr` -- it is still reporting the previous byte. S_SETTLE burns
		// the two clk_sys cycles that guarantee the loader has answered before
		// its answer is believed. Skipping that hands over a byte the loader
		// never took, and the image is short and every part after it is
		// misplaced.
		S_EMIT: begin
			if (offset == length) begin
				dl_download <= 1'b0;       // now the loader may drain and finish
				state       <= S_IDLE;
			end
			else if (!dl_wait) begin
				ddr_byte <= buffer[{offset[2:0], 3'b000} +: 8];
				ddr_wr   <= 1'b1;
				offset   <= offset + 26'd1;
				settle   <= 2'd2;
				state    <= S_SETTLE;
			end
		end

		S_SETTLE: begin
			if (|settle) settle <= settle - 2'd1;
			else if (!dl_wait)
				// A fresh 64-bit word is needed whenever the byte just taken
				// was the last of one -- unless the image is finished, in
				// which case reading the next word would fetch past the end of
				// the image for nothing.
				state <= (offset[2:0] == 3'd0 && offset != length) ? S_READ : S_EMIT;
		end

		default: state <= S_IDLE;
		endcase

		if (reset) begin
			state       <= S_IDLE;
			ddr_active  <= 1'b0;
			ddr_rd      <= 1'b0;
			ddr_addr    <= 29'd0;
			dl_download <= 1'b0;
			ddr_wr      <= 1'b0;
			ddr_byte    <= 8'd0;
			wr_seen     <= 1'b0;
			offset      <= 26'd0;
			length      <= 26'd0;
			settle      <= 2'd0;
		end
	end

	/* verilator lint_off UNUSEDSIGNAL */
	wire _unused = &{1'b0, DDR_BASE[2:0], 1'b0};
	/* verilator lint_on UNUSEDSIGNAL */

endmodule
