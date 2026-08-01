//============================================================================
//  SlopperPI - Seibu SPI / SXX2E
//
//  ROM loader: streams the MRA's concatenated ROM image from ioctl into SDRAM,
//  performing the MAME ROM_LOAD24_* / ROM_LOAD32_* scatter in hardware.
//
//  MRA <interleave> cannot express a 3-byte period, which is exactly what the
//  Seibu "D + P" graphics ROM pairs need: two ROMs supply bytes 0 and 1 of each
//  3-byte group and a third supplies byte 2. So the MRA just concatenates the
//  raw files in a fixed order and this module places every byte.
//
//  One 16-bit masked SDRAM write per input byte. That caps the loader at about
//  14 MB/s, at or above what the HPS delivers over ioctl, so merging adjacent
//  bytes into single writes would not measurably help.
//============================================================================

module rom_loader
(
	input             clk,
	input             reset,

	// ioctl (index 0 = MRA ROM image)
	input             ioctl_download,
	input             ioctl_wr,
	input       [7:0] ioctl_index,
	input       [7:0] ioctl_dout,
	output reg        ioctl_wait,

	// SDRAM write port (channel 3, toggle handshake)
	output reg [24:0] sdr_addr,
	output reg [15:0] sdr_din,
	output reg  [1:0] sdr_be,
	output reg        sdr_req,
	output reg        sdr_rnw,
	input             sdr_ack,

	output reg        rom_ready
);

`include "spi_defs.vh"

	// ------------------------------------------------------------------
	// Scatter modes
	// ------------------------------------------------------------------
	localparam [3:0] M_LINEAR  = 4'd0;   // dest = base + i
	localparam [3:0] M_32_B0   = 4'd1;   // dest = base + i*4 + 0
	localparam [3:0] M_32_B1   = 4'd2;   // dest = base + i*4 + 1
	localparam [3:0] M_32_B2   = 4'd3;   // dest = base + i*4 + 2
	localparam [3:0] M_32_B3   = 4'd4;   // dest = base + i*4 + 3
	localparam [3:0] M_32_W01  = 4'd5;   // dest = base + (i>>1)*4 + 0 + (i&1)
	localparam [3:0] M_32_W23  = 4'd6;   // dest = base + (i>>1)*4 + 2 + (i&1)
	localparam [3:0] M_24_B0   = 4'd7;   // dest = base + i*3 + 0
	localparam [3:0] M_24_B1   = 4'd8;   // dest = base + i*3 + 1
	localparam [3:0] M_24_B2   = 4'd9;   // dest = base + i*3 + 2
	localparam [3:0] M_24_W01  = 4'd10;  // dest = base + (i>>1)*3 + (i&1)

	localparam [3:0] NPARTS = 4'd14;

	// ------------------------------------------------------------------
	// Part table for rdfts (SXX2E single board).
	// The order here must match the <part> order in the MRA.
	// A case statement rather than a parameter array: Quartus 17.0 handles
	// unpacked-array parameters unevenly.
	// ------------------------------------------------------------------
	reg [3:0]  part;
	reg [24:0] off;        // byte offset within the current part

	reg [24:0] part_base;
	reg [24:0] part_size;
	reg [3:0]  part_mode;

	always @* begin
		case (part)
		//                                          base   size          mode
		4'd0 : begin part_base = SDR_PRG_BASE;                       part_size = 25'h008_0000; part_mode = M_32_B0;  end // seibu_1.u0259
		4'd1 : begin part_base = SDR_PRG_BASE;                       part_size = 25'h008_0000; part_mode = M_32_B1;  end // raiden-f_prg2.u0258
		4'd2 : begin part_base = SDR_PRG_BASE;                       part_size = 25'h010_0000; part_mode = M_32_W23; end // raiden-f_prg34.u0262
		4'd3 : begin part_base = SDR_Z80_BASE;                       part_size = 25'h002_0000; part_mode = M_LINEAR; end // seibu_zprg.u1139
		4'd4 : begin part_base = SDR_CHARS_BASE;                     part_size = 25'h002_0000; part_mode = M_24_W01; end // raiden-f_fix.u0535
		4'd5 : begin part_base = SDR_CHARS_BASE;                     part_size = 25'h001_0000; part_mode = M_24_B2;  end // seibu_fix2.u0528
		4'd6 : begin part_base = SDR_TILES_BASE;                     part_size = 25'h020_0000; part_mode = M_24_W01; end // gun_dogs_bg1-d.u0526
		4'd7 : begin part_base = SDR_TILES_BASE;                     part_size = 25'h010_0000; part_mode = M_24_B2;  end // gun_dogs_bg1-p.u0531
		4'd8 : begin part_base = SDR_TILES_BASE + 25'h030_0000;      part_size = 25'h020_0000; part_mode = M_24_W01; end // gun_dogs_bg2-d.u0534
		4'd9 : begin part_base = SDR_TILES_BASE + 25'h030_0000;      part_size = 25'h010_0000; part_mode = M_24_B2;  end // gun_dogs_bg2-p.u0530
		4'd10: begin part_base = SDR_SPRITES_BASE;                   part_size = 25'h040_0000; part_mode = M_LINEAR; end // gun_dogs_obj-1.u0322
		4'd11: begin part_base = SDR_SPRITES_BASE +   SPR_CHUNK_STRIDE;  part_size = 25'h040_0000; part_mode = M_LINEAR; end // gun_dogs_obj-2.u0324
		4'd12: begin part_base = SDR_SPRITES_BASE + 2*SPR_CHUNK_STRIDE;  part_size = 25'h040_0000; part_mode = M_LINEAR; end // gun_dogs_obj-3.u0323
		default:begin part_base = SDR_PCM_BASE;                      part_size = 25'h020_0000; part_mode = M_LINEAR; end // raiden-f_pcm2.u0975
		endcase
	end

	wire last_part = (part == NPARTS - 4'd1);

	// destination offset within the part, per scatter mode
	reg [24:0] scat;
	always @* begin
		case (part_mode)
			M_LINEAR: scat =  off;
			M_32_B0 : scat = {off[22:0], 2'b00};
			M_32_B1 : scat = {off[22:0], 2'b00} + 25'd1;
			M_32_B2 : scat = {off[22:0], 2'b00} + 25'd2;
			M_32_B3 : scat = {off[22:0], 2'b00} + 25'd3;
			M_32_W01: scat = {off[23:1], 2'b00}         + {24'd0, off[0]};
			M_32_W23: scat = {off[23:1], 2'b00} + 25'd2 + {24'd0, off[0]};
			M_24_B0 : scat = {off[23:0], 1'b0} + off;
			M_24_B1 : scat = {off[23:0], 1'b0} + off + 25'd1;
			M_24_B2 : scat = {off[23:0], 1'b0} + off + 25'd2;
			M_24_W01: scat = {off[23:1], 1'b0} + {1'b0, off[24:1]} + {24'd0, off[0]};
			default : scat =  off;
		endcase
	end

	wire [24:0] dest = part_base + scat;

	// ------------------------------------------------------------------
	// Write sequencing
	// ------------------------------------------------------------------
	reg busy;
	reg seen_download;   // rom_ready must not assert before the first download

	wire download = ioctl_download && (ioctl_index == 8'd0);

	always @(posedge clk) begin
		if (reset) begin
			part          <= 4'd0;
			off           <= 25'd0;
			busy          <= 1'b0;
			ioctl_wait    <= 1'b0;
			sdr_req       <= 1'b0;
			sdr_rnw       <= 1'b1;
			rom_ready     <= 1'b0;
			seen_download <= 1'b0;
		end
		else begin
			// A write retires when ack catches up with req.
			if (busy && (sdr_ack == sdr_req)) begin
				busy       <= 1'b0;
				ioctl_wait <= 1'b0;
			end

			if (download) begin
				seen_download <= 1'b1;
				rom_ready     <= 1'b0;

				if (ioctl_wr && !busy) begin
					sdr_addr   <= {dest[24:1], 1'b0};
					sdr_din    <= {ioctl_dout, ioctl_dout};
					sdr_be     <= dest[0] ? 2'b10 : 2'b01;
					sdr_rnw    <= 1'b0;
					sdr_req    <= ~sdr_req;
					busy       <= 1'b1;
					ioctl_wait <= 1'b1;

					if (off == part_size - 25'd1) begin
						off <= 25'd0;
						if (!last_part) part <= part + 4'd1;
					end
					else begin
						off <= off + 25'd1;
					end
				end
			end
			else begin
				// Image is in place once the last write has retired.
				if (seen_download && !busy) rom_ready <= 1'b1;
				part <= 4'd0;
				off  <= 25'd0;
			end
		end
	end

endmodule
