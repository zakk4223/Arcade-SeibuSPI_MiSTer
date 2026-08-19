//============================================================================
//  SeibuSPI - Seibu SPI / SXX2E
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
	input             clk,          // clk_cpu -- the DMA shares the 386's main
	input             reset,       // RAM port, so it lives in that domain

	// Triggers, edge detected so a held level cannot restart a transfer.
	input             trig_tilemap,
	input             trig_palette,
	input             trig_sprite,

	// Byte address in main RAM. MAME asserts DWORD_ALIGNED on this register,
	// so the low two bits are always zero and are not carried here.
	input      [17:2] dma_src,
	input      [15:0] dma_len,      // (len+1)*2 bytes
	input             rowscroll_enable,

	// Main RAM port, shared with the CPU. Request it, wait for the grant, then
	// it is ours until we drop the request. 1 cycle read latency.
	output            ram_req,
	input             ram_gnt,
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

	output            busy,

	// How many dwords the TEXT segment actually moved on the last tilemap DMA.
	// Should be 1024 (64x32 tiles, two per dword). Half that would leave tile
	// rows 16..31 stale, which is exactly source line 128 onwards.
	output reg [11:0] dbg_text_dwords,

	// The source address the sprite DMA actually used, latched at trigger time.
	output     [17:2] dbg_src_spr,

	// Total dwords moved by the last COMPLETE tilemap DMA. The segment sizes are
	// derived from rowscroll_enable and dma_len is ignored, so this is 4096 when
	// rowscroll is on and 2560 when it is off -- which makes it a direct readout
	// of whether this side agrees with the game about the source layout.
	output reg [12:0] dbg_tm_dwords
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
	// rs_tm, not the live signal: the segment layout must stay fixed for the
	// whole transfer and match what was in force when the game triggered it.
	wire [11:0] fore_off = rs_tm ? 12'h400 : 12'h200;
	wire [11:0] midl_off = rs_tm ? 12'h800 : 12'h400;
	wire [11:0] text_off = rs_tm ? 12'hC00 : 12'h600;

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

	// 12 bits, not 11: the palette transfer is 3072 dwords, which does not fit
	// in 11. It previously wrapped to 1024 and silently left two thirds of the
	// palette unwritten.
	function automatic [11:0] seg_len(input [2:0] s);
		seg_len = (s == SEG_TEXT) ? 12'd1024 : 12'd512;
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

	wire [2:0]  nseg  = seg_next(seg, rs_tm);
	wire [11:0] nbase = seg_base(nseg, fore_off, midl_off, text_off);
	wire [11:0] nlen  = seg_len(nseg);

	// ------------------------------------------------------------------
	// Engine
	//
	// One dword per cycle, pipelined: present the read address, and one cycle
	// later the data returns and is written to the destination.
	// ------------------------------------------------------------------
	localparam [1:0] M_IDLE = 2'd0, M_TILEMAP = 2'd1, M_PALETTE = 2'd2, M_SPRITE = 2'd3;

	reg [1:0]  mode;
	reg [11:0] cnt;         // dwords left in the current segment
	reg [11:0] dest;        // running destination index

	reg        rd_valid;    // a read was issued last cycle
	reg [1:0]  rd_mode;
	reg [11:0] rd_dest;

	assign busy    = (mode != M_IDLE) || rd_valid;

	// One pending slot PER MODE, and the parameters latched when the trigger
	// fires rather than when the port is granted.
	//
	// MAME performs each DMA instantaneously inside the trigger write, so it
	// always uses the video_dma_address current at that instant. Here the
	// transfer waits for the CPU to release the RAM port, and the game reloads
	// 0x494 between triggers -- sampling dma_src at grant time therefore read a
	// source address belonging to a later request.
	//
	// Worse, a single pending slot meant a trigger arriving while another
	// transfer was pending or running was dropped outright. The game fires
	// palette, tilemap and sprite DMAs back to back every frame, so the sprite
	// request -- last of the three -- was the one routinely lost, leaving sprite
	// RAM all zeros and every list entry failing the `code != 0` gate.
	reg        pend_tm, pend_pal, pend_spr;
	reg [17:2] src_tm, src_pal, src_spr;
	reg [15:0] len_pal;
	reg        rs_tm;             // rowscroll layout as it was at trigger time
	reg [12:0] tm_run;            // dwords moved by the tilemap DMA in progress
	assign ram_req = busy || pend_tm || pend_pal || pend_spr;

	// Palette: (len+1)*2 bytes => (len+1)/2 source dwords. 6144 pens = 3072
	// dwords, which needs 12 bits.
	wire [11:0] pal_dwords = 12'((len_pal + 16'd1) >> 1);

	assign dbg_src_spr = src_spr;

	always @(posedge clk) begin
		tm_we  <= 1'b0;
		pal_we <= 1'b0;
		spr_we <= 1'b0;

		if (reset) begin
			mode          <= M_IDLE;
			rd_valid      <= 1'b0;
			pend_tm       <= 1'b0;
			pend_pal      <= 1'b0;
			pend_spr      <= 1'b0;
			dbg_text_dwords <= 12'd0;
			tm_run        <= 13'd0;
			dbg_tm_dwords <= 13'd0;
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

			// ---- start stage ---------------------------------------------
			// Consume first, then latch new triggers below. A trigger landing on
			// the same cycle as its own consume therefore survives: the later
			// non-blocking assignment wins and the slot stays raised, while
			// ram_addr has already taken the OLD latched source.
			if (mode == M_IDLE && ram_gnt) begin
				dest <= 12'h000;
				if (pend_tm) begin
					pend_tm  <= 1'b0;
					mode     <= M_TILEMAP;
					ram_addr <= src_tm;
					seg      <= SEG_BACK;
					cnt      <= seg_len(SEG_BACK);
					dbg_text_dwords <= 12'd0;
					tm_run          <= 13'd0;
				end
				else if (pend_pal) begin
					pend_pal <= 1'b0;
					mode     <= M_PALETTE;
					ram_addr <= src_pal;
					cnt      <= pal_dwords;
				end
				else if (pend_spr) begin
					pend_spr <= 1'b0;
					mode     <= M_SPRITE;
					ram_addr <= src_spr;
					cnt      <= 12'd1024;
				end
			end

			// ---- trigger stage -------------------------------------------
			if (start_tm)  begin pend_tm  <= 1'b1; src_tm  <= dma_src;
			                     rs_tm    <= rowscroll_enable; end
			if (start_pal) begin pend_pal <= 1'b1; src_pal <= dma_src;
			                     len_pal  <= dma_len; end
			if (start_spr) begin pend_spr <= 1'b1; src_spr <= dma_src; end

			// ---- read stage ----------------------------------------------
			// Runs whenever a transfer is in progress. This is deliberately its
			// own `if` on mode: it used to be the `else` arm of the start stage,
			// which after the restructure would have bound to `if (start_spr)`
			// and stepped the address and count on almost every cycle.
			if (mode != M_IDLE) begin
				// The address presented last cycle returns this cycle.
				rd_valid <= 1'b1;
				rd_mode  <= mode;
				rd_dest  <= dest;

				ram_addr <= ram_addr + 16'd1;
				dest     <= dest + 12'd1;
				cnt      <= cnt - 12'd1;
				if (mode == M_TILEMAP && seg == SEG_TEXT)
					dbg_text_dwords <= dbg_text_dwords + 12'd1;
				if (mode == M_TILEMAP) tm_run <= tm_run + 13'd1;

				if (cnt == 12'd1) begin
					if (mode == M_TILEMAP && seg != SEG_TEXT) begin
						seg  <= nseg;
						dest <= nbase;
						cnt  <= nlen;
					end
					else begin
						mode <= M_IDLE;
						if (mode == M_TILEMAP) dbg_tm_dwords <= tm_run + 13'd1;
					end
				end
			end
		end
	end

endmodule
