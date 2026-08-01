//============================================================================
//  SlopperPI - Seibu SPI / SXX2E
//
//  Video DMA engines (seibuspi_v.cpp:238,327,351).
//
//  All video state lives in 386 main RAM and is copied into dedicated video
//  RAMs when the game writes one of three trigger registers. The source address
//  (0x494) and length (0x490) are set first; length counts (len+1)*2 bytes.
//
//  tilemap DMA (0x480) copies 0x2800 bytes, or 0x4000 with rowscroll enabled,
//  in this source order:
//      back, [back rowscroll], fore, [fore rowscroll], midl, [midl rowscroll],
//      text
//  into a 16 KB tilemap RAM at these dword offsets:
//
//      region          rowscroll off   rowscroll on
//      back tiles      0x000           0x000
//      back rowscroll  --              0x200
//      fore tiles      0x200           0x400
//      midl rowscroll  --              0x600
//      midl tiles      0x400           0x800
//      fore rowscroll  --              0xA00
//      text tiles      0x600           0xC00
//
//  Yes, the rowscroll destinations interleave oddly with the tile data. That is
//  what MAME does, and the renderer reads them back from 0x200 / 0x600 / 0xA00
//  for back / midl / fore respectively.
//
//  palette DMA (0x484) copies (len+1)*2 bytes. Each source dword holds two
//  BGR555 pens, in bits [14:0] and [30:16], and is stored to the palette RAM
//  as-is -- one entry per pen pair. Keeping the pairing means every mode moves
//  exactly one dword per cycle.
//
//  sprite DMA (0x562) copies a fixed 0x1000 bytes, 512 sprites of 8 bytes.
//============================================================================

module spi_dma
(
	input             clk,          // clk_sys
	input             reset,

	// Triggers. These originate on clk_cpu, where one cycle spans two clk_sys
	// cycles, so they are edge detected rather than used directly.
	input             trig_tilemap,
	input             trig_palette,
	input             trig_sprite,

	// Byte address in main RAM. MAME asserts DWORD_ALIGNED on this register,
	// so the low two bits are always zero and are not carried here.
	input      [17:2] dma_src,
	input      [15:0] dma_len,      // (len+1)*2 bytes
	input             rowscroll_enable,

	// Main RAM read port (1 cycle latency)
	output reg [15:0] ram_addr,     // dword index
	input      [31:0] ram_data,

	// Tilemap RAM write (4096 dwords)
	output reg [11:0] tm_addr,
	output reg [31:0] tm_data,
	output reg        tm_we,

	// Palette RAM write (3072 entries, two BGR555 pens each)
	output reg [11:0] pal_addr,
	output reg [29:0] pal_data,
	output reg        pal_we,

	// Sprite RAM write (1024 dwords)
	output reg  [9:0] spr_addr,
	output reg [31:0] spr_data,
	output reg        spr_we,

	output            busy
);

	// ------------------------------------------------------------------
	// Trigger edge detection
	// ------------------------------------------------------------------
	reg trig_tm_d, trig_pal_d, trig_spr_d;
	always @(posedge clk) begin
		trig_tm_d  <= trig_tilemap;
		trig_pal_d <= trig_palette;
		trig_spr_d <= trig_sprite;
	end
	wire start_tm  = trig_tilemap && !trig_tm_d;
	wire start_pal = trig_palette && !trig_pal_d;
	wire start_spr = trig_sprite  && !trig_spr_d;

	// ------------------------------------------------------------------
	// Tilemap segments
	// ------------------------------------------------------------------
	wire [11:0] fore_off = rowscroll_enable ? 12'h400 : 12'h200;
	wire [11:0] midl_off = rowscroll_enable ? 12'h800 : 12'h400;
	wire [11:0] text_off = rowscroll_enable ? 12'hC00 : 12'h600;

	localparam [2:0] SEG_BACK = 3'd0, SEG_BACK_RS = 3'd1,
	                 SEG_FORE = 3'd2, SEG_FORE_RS = 3'd3,
	                 SEG_MIDL = 3'd4, SEG_MIDL_RS = 3'd5,
	                 SEG_TEXT = 3'd6;

	reg [2:0] seg;

	// Where a segment writes, and how many dwords it moves.
	function automatic [11:0] seg_base(input [2:0] s,
	                                   input [11:0] f, input [11:0] m, input [11:0] t);
		case (s)
			SEG_BACK:    seg_base = 12'h000;
			SEG_BACK_RS: seg_base = 12'h200;
			SEG_FORE:    seg_base = f;
			SEG_FORE_RS: seg_base = 12'hA00;
			SEG_MIDL:    seg_base = m;
			SEG_MIDL_RS: seg_base = 12'h600;
			default:     seg_base = t;
		endcase
	endfunction

	function automatic [10:0] seg_len(input [2:0] s);
		seg_len = (s == SEG_TEXT) ? 11'd1024 : 11'd512;
	endfunction

	// Rowscroll segments are absent entirely when rowscroll is off -- the source
	// pointer does not advance over them either.
	function automatic [2:0] seg_next(input [2:0] s, input rs);
		case (s)
			SEG_BACK:    seg_next = rs ? SEG_BACK_RS : SEG_FORE;
			SEG_BACK_RS: seg_next = SEG_FORE;
			SEG_FORE:    seg_next = rs ? SEG_FORE_RS : SEG_MIDL;
			SEG_FORE_RS: seg_next = SEG_MIDL;
			SEG_MIDL:    seg_next = rs ? SEG_MIDL_RS : SEG_TEXT;
			default:     seg_next = SEG_TEXT;
		endcase
	endfunction

	wire [2:0]  nseg  = seg_next(seg, rowscroll_enable);
	wire [11:0] nbase = seg_base(nseg, fore_off, midl_off, text_off);
	wire [10:0] nlen  = seg_len(nseg);

	// ------------------------------------------------------------------
	// Engine
	//
	// One dword per cycle, pipelined: present the read address, and one cycle
	// later the data returns and is written to the destination.
	// ------------------------------------------------------------------
	localparam [1:0] M_IDLE = 2'd0, M_TILEMAP = 2'd1, M_PALETTE = 2'd2, M_SPRITE = 2'd3;

	reg [1:0]  mode;
	reg [10:0] cnt;         // dwords left in the current segment
	reg [11:0] dest;        // running destination index

	reg        rd_valid;    // a read was issued last cycle
	reg [1:0]  rd_mode;
	reg [11:0] rd_dest;

	assign busy = (mode != M_IDLE) || rd_valid;

	// Palette: (len+1)*2 bytes => (len+1)/2 source dwords. The palette is 6144
	// pens = 3072 dwords, so 11 bits covers every legal transfer.
	wire [10:0] pal_dwords = 11'((dma_len + 16'd1) >> 1);

	always @(posedge clk) begin
		tm_we  <= 1'b0;
		pal_we <= 1'b0;
		spr_we <= 1'b0;

		if (reset) begin
			mode     <= M_IDLE;
			rd_valid <= 1'b0;
		end
		else begin
			// ---- write stage --------------------------------------------
			rd_valid <= 1'b0;

			if (rd_valid) begin
				case (rd_mode)
					M_TILEMAP: begin
						tm_addr <= rd_dest;
						tm_data <= ram_data;
						tm_we   <= 1'b1;
					end
					M_PALETTE: begin
						pal_addr <= rd_dest;
						pal_data <= {ram_data[30:16], ram_data[14:0]};
						pal_we   <= 1'b1;
					end
					M_SPRITE: begin
						spr_addr <= rd_dest[9:0];
						spr_data <= ram_data;
						spr_we   <= 1'b1;
					end
					default: ;
				endcase
			end

			// ---- read stage ----------------------------------------------
			if (mode == M_IDLE) begin
				if (start_tm) begin
					mode     <= M_TILEMAP;
					seg      <= SEG_BACK;
					cnt      <= seg_len(SEG_BACK);
					dest     <= 12'h000;
					ram_addr <= dma_src;
				end
				else if (start_pal) begin
					mode     <= M_PALETTE;
					cnt      <= pal_dwords;
					dest     <= 12'h000;
					ram_addr <= dma_src;
				end
				else if (start_spr) begin
					mode     <= M_SPRITE;
					cnt      <= 11'd1024;
					dest     <= 12'h000;
					ram_addr <= dma_src;
				end
			end
			else begin
				// The address presented last cycle returns this cycle.
				rd_valid <= 1'b1;
				rd_mode  <= mode;
				rd_dest  <= dest;

				ram_addr <= ram_addr + 16'd1;
				dest     <= dest + 12'd1;
				cnt      <= cnt - 11'd1;

				if (cnt == 11'd1) begin
					if (mode == M_TILEMAP && seg != SEG_TEXT) begin
						seg  <= nseg;
						dest <= nbase;
						cnt  <= nlen;
					end
					else begin
						mode <= M_IDLE;
					end
				end
			end
		end
	end

endmodule
