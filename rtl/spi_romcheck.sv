//============================================================================
//  SlopperPI - verify the ROM image actually landed in SDRAM
//
//  Everything in sim/ starts from a perfect SDRAM image and fakes rom_ready, so
//  the ioctl download -- 22.3 MB pushed through rom_loader under HPS flow
//  control, which is the very first thing that happens on real hardware -- has
//  never been tested anywhere. If bytes are dropped there, the 386 executes
//  garbage and wanders off, and nothing else in the core would notice.
//
//  So after the download this walks the four regions the core actually reads
//  and sums them as 32-bit words, comparing against constants computed from the
//  reference image by tools/build_sdram_image.py. The result goes on the vital
//  signs panel.
//
//  A sum, not a CRC: the point is to catch dropped or misplaced bytes, and a
//  sum does that for a fraction of the logic. It would miss bytes that cancel
//  out, which no plausible failure mode produces.
//
//  Takes about 0.4 s at 114.5 MHz, which delays the CPU coming out of reset by
//  a barely noticeable amount.
//============================================================================

module spi_romcheck
(
	input             clk,
	input             reset,

	input             start,          // rom_ready

	// SDRAM read port
	output reg [25:0] sdr_addr,
	input      [63:0] sdr_dout,
	output reg        sdr_req,
	input             sdr_ack,

	output reg        done,
	output reg  [3:0] ok,
	// After the first pass `done` latches so the board comes out of reset, but
	// the walk keeps repeating. Later passes therefore run while the video
	// engine is hammering channel 2, which is the one condition the original
	// one-shot check could never cover: the CPU reads its ROM under exactly
	// that contention, and that is where its data goes bad.
	output reg [15:0] passes,
	output reg [15:0] fails,             // per region, 1 = matches
	output reg [31:0] sum_prg,        // what it actually computed, for JTAG
	output reg [31:0] sum_chars,
	output reg [31:0] sum_tiles,
	output reg [31:0] sum_sprites
);

`include "spi_defs.vh"

	// Computed from the reference image: `tools/build_sdram_image.py <zip> out
	// --sums` prints these four lines. Re-derive them after ANY change to how a
	// region is laid out -- SUM_SPRITES was stale from 68ccd06 until 2026-08-11
	// because the sprite interleave (21d8192) permuted the bytes within each
	// tile, which changes a sum over 32-bit words even though every byte is
	// still present. That reported a SPRITES failure on correct data for a day
	// and cost a session's worth of suspicion; see T-G.
	localparam [31:0] SUM_PRG     = 32'h741393AF;
	localparam [31:0] SUM_CHARS   = 32'h79A0EB60;
	localparam [31:0] SUM_TILES   = 32'hD3E9E887;
	localparam [31:0] SUM_SPRITES = 32'h76809831;

	reg  [1:0] region;
	reg [25:0] addr;
	reg [25:0] limit;
	reg [31:0] sum;
	reg        busy;
	reg        started;

	reg [31:0] region_sum;
	always @* begin
		case (region)
			2'd0:    region_sum = SUM_PRG;
			2'd1:    region_sum = SUM_CHARS;
			2'd2:    region_sum = SUM_TILES;
			default: region_sum = SUM_SPRITES;
		endcase
	end

	always @(posedge clk) begin
		if (reset) begin
			region  <= 2'd0;
			addr    <= 26'd0;
			limit   <= 26'd0;
			sum     <= 32'd0;
			busy    <= 1'b0;
			done    <= 1'b0;
			ok      <= 4'd0;
			started <= 1'b0;
			passes  <= 16'd0;
			fails   <= 16'd0;
			sum_prg <= 32'd0; sum_chars <= 32'd0;
			sum_tiles <= 32'd0; sum_sprites <= 32'd0;
			sdr_req <= 1'b0;
		end
		else if (!done) begin
			if (!started) begin
				if (start) begin
					started <= 1'b1;
					region  <= 2'd0;
					addr    <= SDR_PRG_BASE;
					limit   <= SDR_PRG_BASE + 26'h020_0000;
					sum     <= 32'd0;
					busy    <= 1'b0;
				end
			end
			else if (!busy) begin
				sdr_addr <= addr;
				sdr_req  <= ~sdr_req;
				busy     <= 1'b1;
			end
			else if (sdr_ack == sdr_req) begin
				busy <= 1'b0;
				sum  <= sum + sdr_dout[31:0] + sdr_dout[63:32];

				if (addr + 26'd8 >= limit) begin
					// Region finished: latch the verdict and move on.
					ok[region] <= ((sum + sdr_dout[31:0] + sdr_dout[63:32]) == region_sum);
					case (region)
						2'd0:    sum_prg     <= sum + sdr_dout[31:0] + sdr_dout[63:32];
						2'd1:    sum_chars   <= sum + sdr_dout[31:0] + sdr_dout[63:32];
						2'd2:    sum_tiles   <= sum + sdr_dout[31:0] + sdr_dout[63:32];
						default: sum_sprites <= sum + sdr_dout[31:0] + sdr_dout[63:32];
					endcase
					sum        <= 32'd0;
					if (region == 2'd3) begin
						done   <= 1'b1;
						passes <= passes + 16'd1;
						if (!(ok[2:0] == 3'b111 &&
						      ((sum + sdr_dout[31:0] + sdr_dout[63:32]) == region_sum)))
							fails <= fails + 16'd1;
						// go round again
						region <= 2'd0;
						addr   <= SDR_PRG_BASE;
						limit  <= SDR_PRG_BASE + 26'h020_0000;
					end
					else begin
						region <= region + 2'd1;
						addr   <= (region == 2'd0) ? SDR_CHARS_BASE
						        : (region == 2'd1) ? SDR_TILES_BASE
						                           : SDR_SPRITES_BASE;
						limit  <= (region == 2'd0) ? SDR_CHARS_BASE   + 26'h003_0000
						        : (region == 2'd1) ? SDR_TILES_BASE   + 26'h060_0000
						                           : SDR_SPRITES_BASE + 26'h0C0_0000;
					end
				end
				else begin
					addr <= addr + 26'd8;
				end
			end
		end
	end

endmodule
