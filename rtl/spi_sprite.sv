//============================================================================
//  SlopperPI - Seibu SPI / SXX2E
//
//  Sprite engine (sei25x_rise1x_spr.cpp).
//
//  Format, 8 bytes per sprite, 512 of them:
//
//    +0  b15    flip Y
//        b14-12 height - 1, in 16 pixel tiles
//        b11    flip X
//        b10-8  width - 1
//        b7-6   priority
//        b5-0   colour
//    +2  tile code
//    +4  b8-0   X   (9 bit, >= 0x180 means negative: subtract 0x200)
//    +6  b8-0   Y
//
//  The sprite DMA splits each main RAM dword into two 16-bit entries, so
//  sprite n lives in dwords 2n and 2n+1 as {code, attr} and {Y, X}.
//
//  MAME walks the list BACKWARDS (last entry first), so entry 0 is drawn last
//  and ends up on top. Everything lands in one buffer tagged with its priority,
//  which means sprite-versus-sprite occlusion is decided purely by list order
//  and a high-index sprite can erase a lower-priority one. Reproduced here by
//  scanning 511 down to 0 and letting later writes win.
//
//  Tiles within a sprite are numbered down each column: for ax, for ay,
//  code++. So the tile covering column ax at vertical vcell ay is
//  code + ax*sizey + ay.
//
//  `code % elements == 0` is skipped, and since the gfx region holds exactly
//  0x10000 tiles the RISE "extra bank" bit is NOT applied on this board --
//  MAME's gfxbank callback only adds it when elements > 0x10000.
//
//  Graphics are three plane-pair chunks 4 MB apart, 64 bytes per tile, 4 bytes
//  per row. One 64-bit SDRAM read per chunk covers a row, so a 16-pixel row
//  costs three reads and two decrypt passes (8 pixels each).
//============================================================================

module spi_sprite
(
	input             clk,          // clk_sys
	input             reset,

	input       [9:0] vcnt,
	input             line_start,
	input             enable,       // layer_enable[4] inverted

	// Sprite RAM (1024 dwords), read port
	output reg  [9:0] spr_addr,
	input      [31:0] spr_data,

	// SDRAM channel 4
	output reg [24:0] sdr_addr,
	input      [63:0] sdr_dout,
	output reg        sdr_req,
	input             sdr_ack,

	// Line buffer read side
	input       [8:0] lb_x,
	input             lb_wrap,
	output     [14:0] lb_out,       // {valid, pri[1:0], colour[5:0], pixel[5:0]}

	output reg        busy,

	// Debug taps for the testbench
	output            dbg_we,
	output      [3:0] dbg_state,
	output      [8:0] dbg_index,
	output      [5:0] dbg_pix,
	output signed [10:0] dbg_emitx,

	// Telemetry: how far the engine gets. Nothing on screen could mean the scan
	// never runs, no sprite passes the y test, or pixels are all rejected as
	// transparent / off-screen -- these tell them apart.
	output reg [15:0] dbg_scanned,
	output reg [15:0] dbg_yhit,
	output reg [15:0] dbg_emitted,
	// How often a line ran out of budget with sprites still unscanned, and how
	// many tile columns were actually drawn on the last line. If the first is
	// high the engine is simply too slow and sprites are being dropped.
	output reg [15:0] dbg_starved,
	output reg [15:0] dbg_tiles,
	output     [15:0] dbg_code,
	output      [8:0] dbg_sx, dbg_sy,
	// Exposed so the golden test can decode the same tile row straight out of
	// the sprite ROM with MAME's decryptor and compare pixel for pixel.
	output     [15:0] dbg_tile_code,
	output      [3:0] dbg_ry,
	output      [3:0] dbg_px,

	// How many of the 512 list entries carry a non-zero code, sampled over one
	// scanline and latched. The y-test is gated on `code != 0`, so an empty or
	// un-DMAed list and a list whose sprites all fail the y compare look
	// identical from dbg_yhit alone -- this separates them. Counted per line
	// rather than per frame because every line walks the whole list, so the
	// per-line figure IS the list population.
	output reg [15:0] dbg_codes_nz,

	// Bitwise OR of every dword read out of sprite RAM during one scanline.
	// dbg_codes_nz == 0 has two very different causes: sprite RAM genuinely
	// holds nothing, or it holds data whose code field is not where this module
	// looks. Zero here means the RAM is empty and the fault is upstream in the
	// DMA or the CPU; non-zero means the data arrived and the decode is wrong.
	output reg [31:0] dbg_spr_or
);

`include "spi_defs.vh"

	assign dbg_we    = lb_we;
	assign dbg_state = state;
	assign dbg_index = index;
	assign dbg_pix   = pix_sel;
	assign dbg_emitx = emit_x;
	assign dbg_code  = code;
	assign dbg_tile_code = tile_code;
	assign dbg_ry    = ry;
	assign dbg_px    = {half, pcnt};
	assign dbg_sx    = sx_raw;
	assign dbg_sy    = sy_raw;

	// ------------------------------------------------------------------
	// Line buffers, double buffered like the tile layers
	// ------------------------------------------------------------------
	reg        render_bank;
	reg  [8:0] render_line;

	reg  [9:0] lb_wr_addr;
	reg [14:0] lb_wr_data;
	reg        lb_we;

	wire [9:0] lb_rd_addr = {lb_wrap ? render_bank : ~render_bank, lb_x};

	spi_dpram #(.DW(15), .AW(10)) lbuf
		(.wr_clk(clk), .rd_clk(clk),
		 .wr_addr(lb_wr_addr), .wr_data(lb_wr_data), .wr_en(lb_we),
		 .rd_addr(lb_rd_addr), .rd_data(lb_out));

	// ------------------------------------------------------------------
	// Sprite attributes, latched as the list is walked
	// ------------------------------------------------------------------
	reg  [8:0] index;        // 511 .. 0
	reg [15:0] attr, code;
	reg  [8:0] sx_raw, sy_raw;

	wire        flipy = attr[15];
	wire  [2:0] sizey = attr[14:12];   // height - 1
	wire        flipx = attr[11];
	wire  [2:0] sizex = attr[10:8];    // width - 1
	wire  [1:0] pri   = attr[7:6];
	wire  [5:0] colr  = attr[5:0];

	// 9-bit wrap: >= 0x180 is negative.
	wire signed [10:0] spr_x = (sx_raw >= 9'h180) ? {2'b11, sx_raw} : {2'b00, sx_raw};
	wire signed [10:0] spr_y = (sy_raw >= 9'h180) ? {2'b11, sy_raw} : {2'b00, sy_raw};

	// Which vertical vcell of this sprite covers the line being rendered?
	// During S_START the Y position is still on spr_data; the registered copy
	// only becomes valid the cycle after, which is fine for the drawing phase.
	wire  [8:0] sy_now  = spr_data[24:16];
	wire signed [10:0] spr_y_now = (sy_now >= 9'h180) ? {2'b11, sy_now} : {2'b00, sy_now};
	wire signed [10:0] dy_now = $signed({2'b00, render_line}) - spr_y_now;
	wire        y_hit_now = (dy_now >= 0) && (dy_now[10:4] <= {4'd0, attr[14:12]});

	// Only the low 7 bits matter: a sprite is at most 8 tiles tall, and the
	// hit test above has already established the line falls inside it.
	/* verilator lint_off UNUSEDSIGNAL */
	wire signed [10:0] dy    = $signed({2'b00, render_line}) - spr_y;
	/* verilator lint_on UNUSEDSIGNAL */
	wire         [2:0] vcell = dy[6:4];
	wire         [3:0] yrow  = dy[3:0];

	wire [2:0] ay  = flipy ? (sizey - vcell) : vcell;
	wire [3:0] ry  = flipy ? (4'd15 - yrow)  : yrow;

	reg [2:0] axc;                       // column being drawn
	wire [2:0] ax  = flipx ? (sizex - axc) : axc;

	// code + ax*sizey_count + ay, where sizey_count = sizey + 1
	// sizey is 3 bits, so `sizey + 3'd1` is evaluated at 3 bits inside a
	// concatenation and WRAPS TO ZERO for a full-height sprite (sizey == 7).
	// That made every tile column reuse the same codes, which showed up as a
	// grid of repeated blocks over large sprites like the title logo. Widen it
	// first, then multiply.
	wire  [3:0] rows_per_col = {1'b0, sizey} + 4'd1;
	wire [15:0] tile_code = code + ({12'd0, ax} * {12'd0, rows_per_col}) + {13'd0, ay};

	wire signed [10:0] col_x = 11'(spr_x + $signed({4'd0, axc, 4'd0}));  // + axc*16

	// ------------------------------------------------------------------
	// Graphics address: chunk k at + k*4 MB, tile*64 + row*4
	// ------------------------------------------------------------------
	reg  [1:0] chunk;
	wire [24:0] chunk_base = SDR_SPRITES_BASE + ({23'd0, chunk} * SPR_CHUNK_STRIDE);
	// Bits 1:0 are always zero: rows are 4 bytes apart. Bit 2 picks which half
	// of the 8-byte SDRAM read holds this row.
	/* verilator lint_off UNUSEDSIGNAL */
	wire [24:0] row_addr   = chunk_base + {3'd0, tile_code, 6'd0} + {19'd0, ry, 2'd0};
	/* verilator lint_on UNUSEDSIGNAL */

	// ------------------------------------------------------------------
	// Decryption inputs: three 16-bit words, one per chunk
	// ------------------------------------------------------------------
	// One 64-bit read per chunk already covers the whole 16-pixel row: the four
	// row bytes hold word i (pixels 0-7) and word i+1 (pixels 8-15). Both are
	// latched, so a row costs three reads rather than six.
	reg [15:0] y1a, y1b, y2a, y2b, y3a, y3b;
	reg        half;                      // which 8 pixels of the row

	wire [15:0] y1 = half ? y1b : y1a;
	wire [15:0] y2 = half ? y2b : y2a;
	wire [15:0] y3 = half ? y3b : y3a;

	wire [5:0] p0, p1, p2, p3, p4, p5, p6, p7;

	spi_spr_decrypt dec
	(
		.y1(y1), .y2(y2), .y3(y3),
		.addr(tile_code[14:3]),           // addr = code >> 3
		.pix0(p0), .pix1(p1), .pix2(p2), .pix3(p3),
		.pix4(p4), .pix5(p5), .pix6(p6), .pix7(p7)
	);

	reg [2:0] pcnt;
	reg [5:0] pix_raw;
	always @* begin
		case (pcnt)
			3'd0: pix_raw = p0;  3'd1: pix_raw = p1;
			3'd2: pix_raw = p2;  3'd3: pix_raw = p3;
			3'd4: pix_raw = p4;  3'd5: pix_raw = p5;
			3'd6: pix_raw = p6;  default: pix_raw = p7;
		endcase
	end

	// spi_spr_decrypt emits the pen BIT REVERSED: its bit p is MAME's
	// plane(5-p), i.e. bit 0 carries plane5 which is the pen's MSB. That is the
	// convention tb_spr_decrypt checks, so the decrypt unit is right and the
	// reversal belongs here. Consuming it raw swapped every pen with its mirror,
	// which is invisible for palindromes like 3F (transparent) and 00 -- and
	// those are most pixels, so sprites looked almost right while solid areas
	// came out as the wrong colour entirely.
	wire [5:0] pix_sel = {pix_raw[0], pix_raw[1], pix_raw[2],
	                      pix_raw[3], pix_raw[4], pix_raw[5]};

	// Screen x of the pixel being emitted. Within a tile the pixel order is
	// reversed when flipx is set.
	wire [3:0] tile_px = {half, pcnt};
	wire signed [10:0] emit_x = col_x + (flipx ? $signed({7'd0, 4'd15 - tile_px})
	                                           : $signed({7'd0, tile_px}));

	// ------------------------------------------------------------------
	// Sequencer
	// ------------------------------------------------------------------
	localparam [3:0] S_IDLE  = 4'd0,
	                 S_CLR   = 4'd1,
	                 S_ATTR  = 4'd2,   // read dword 2n
	                 S_ATTR2 = 4'd3,
	                 S_TEST  = 4'd6,
	                 S_REQ   = 4'd7,   // fetch chunk `chunk`
	                 S_WAIT  = 4'd8,
	                 S_EMIT  = 4'd9,
	                 S_NEXTC = 4'd10,  // next column
	                 S_NEXTS = 4'd11,  // next sprite
	                 S_START = 4'd12;  // Y test, once position has settled

	reg [3:0]  state;
	reg [8:0]  clr;
	reg [11:0] budget;                 // hard per-line cap on fetch work
	reg        restart_req;
	reg [63:0] fetched;

	reg [15:0] nz_cnt;    // non-zero codes seen on the line in progress
	reg [31:0] or_acc;    // OR of every sprite-RAM dword seen on that line

	// A line is 448 * 8 = 3584 cycles. The clear takes 320 and a full scan
	// 4 * 512 = 2048, so this leaves around 1100 for actual pixel fetches.
	localparam [11:0] BUDGET = 12'd3200;

	always @(posedge clk) begin
		lb_we <= 1'b0;

		if (reset) begin
			dbg_scanned <= 16'd0;
			dbg_yhit    <= 16'd0;
			dbg_emitted <= 16'd0;
			dbg_starved <= 16'd0;
			dbg_tiles   <= 16'd0;
			nz_cnt      <= 16'd0;
			dbg_codes_nz <= 16'd0;
			or_acc      <= 32'd0;
			dbg_spr_or  <= 32'd0;
			state       <= S_IDLE;
			busy        <= 1'b0;
			sdr_req     <= 1'b0;
			restart_req <= 1'b0;
			render_bank <= 1'b0;
		end
		else begin
			if (line_start) begin
				restart_req  <= 1'b1;
				// Latch the previous line's tally and start a fresh one.
				dbg_codes_nz <= nz_cnt;
				nz_cnt       <= 16'd0;
				dbg_spr_or   <= or_acc;
				or_acc       <= 32'd0;
			end
			if (budget != 12'd0 && state != S_IDLE && state != S_CLR)
				budget <= budget - 12'd1;

			// Restart only at a sprite boundary, so an SDRAM request is never
			// abandoned with its ack outstanding.
			if (restart_req && (state == S_IDLE || state == S_NEXTS)) begin
				restart_req <= 1'b0;
				render_line <= (vcnt >= VBSTART - 10'd1) ? 9'd0 : (vcnt[8:0] + 9'd1);
				render_bank <= ~render_bank;
				clr         <= 9'd0;
				budget      <= BUDGET;
				busy        <= 1'b1;
				state       <= S_CLR;
			end
			else case (state)

			S_IDLE: ;

			// Blank the buffer we are about to draw into.
			S_CLR: begin
				// render_bank, NOT ~render_bank: spi_layers writes
				// {render_bank, x} and the mixer reads {~render_bank, x} while a
				// line is on screen. Writing the inverted bank here meant the
				// sprite engine rendered into the buffer being displayed and
				// then cleared it at the next line start, so the mixer only ever
				// saw valid=0 and no sprite reached the screen.
				lb_wr_addr <= {render_bank, clr};
				lb_wr_data <= 15'd0;          // valid = 0
				lb_we      <= 1'b1;
				if (clr == 9'd319) begin
					index <= 9'd511;
					state <= enable ? S_ATTR : S_IDLE;
					if (!enable) busy <= 1'b0;
				end
				else clr <= clr + 9'd1;
			end

			// Four cycles per sprite, not seven: the two dword reads are
			// overlapped, and the Y test uses spr_data directly rather than
			// waiting for sy_raw to settle. At seven cycles a 512-entry scan
			// consumed the entire 3584-cycle line and never reached a fetch.
			S_ATTR: begin
				spr_addr <= {index, 1'b0};
				state    <= S_ATTR2;
			end
			S_ATTR2: begin
				spr_addr <= {index, 1'b1};    // issue the second read back to back
				state    <= S_TEST;
			end
			S_TEST: begin                     // dword 2n is on spr_data now
				or_acc <= or_acc | spr_data;
				attr  <= spr_data[15:0];
				code  <= spr_data[31:16];
				state <= S_START;
			end

			S_START: begin                    // dword 2n+1 is on spr_data now
				sx_raw <= spr_data[8:0];
				sy_raw <= spr_data[24:16];
				// MAME skips code 0 (`code % elements == 0`, elements = 0x10000).
				dbg_scanned <= dbg_scanned + 16'd1;
				or_acc      <= or_acc | spr_data;
				if (code != 16'd0) nz_cnt <= nz_cnt + 16'd1;
				if (y_hit_now && code != 16'd0) begin
					dbg_yhit <= dbg_yhit + 16'd1;
					axc   <= 3'd0;
					chunk <= 2'd0;
					half  <= 1'b0;
					dbg_tiles <= dbg_tiles + 16'd1;
					state <= S_REQ;
				end
				else if (index == 9'd0 || budget == 12'd0) begin
					if (index != 9'd0) dbg_starved <= dbg_starved + 16'd1;
					busy  <= 1'b0;
					state <= S_IDLE;
				end
				else begin
					// Walking the 512-entry list dominates the line: at five
					// cycles a sprite it burned 2560 of the 3584 cycles and left
					// 96 for actual drawing, so most sprites simply never got
					// fetched. The RAM answers two cycles after an address is
					// presented, so the next sprite's first read is issued here
					// and S_ATTR/S_NEXTS drop out of the miss path -- three
					// cycles a sprite instead of five.
					index    <= index - 9'd1;
					spr_addr <= {index - 9'd1, 1'b0};
					state    <= S_ATTR2;
				end
			end

			S_NEXTC: begin
				if (axc == sizex) state <= S_NEXTS;
				else begin
					axc   <= axc + 3'd1;
					chunk <= 2'd0;
					half  <= 1'b0;
					dbg_tiles <= dbg_tiles + 16'd1;
					state <= S_REQ;
				end
			end

			S_REQ: begin
				sdr_addr <= {row_addr[24:3], 3'b000};
				sdr_req  <= ~sdr_req;
				state    <= S_WAIT;
			end

			S_WAIT: if (sdr_ack == sdr_req) begin
				// 4 bytes of the row, selected by bit 2 of the address
				fetched <= sdr_dout;
				case (chunk)
					2'd0: begin
						y1a <= row_addr[2] ? sdr_dout[47:32] : sdr_dout[15:0];
						y1b <= row_addr[2] ? sdr_dout[63:48] : sdr_dout[31:16];
					end
					2'd1: begin
						y2a <= row_addr[2] ? sdr_dout[47:32] : sdr_dout[15:0];
						y2b <= row_addr[2] ? sdr_dout[63:48] : sdr_dout[31:16];
					end
					default: begin
						y3a <= row_addr[2] ? sdr_dout[47:32] : sdr_dout[15:0];
						y3b <= row_addr[2] ? sdr_dout[63:48] : sdr_dout[31:16];
					end
				endcase
				if (chunk == 2'd2) begin
					pcnt  <= 3'd0;
					state <= S_EMIT;
				end
				else begin
					chunk <= chunk + 2'd1;
					state <= S_REQ;
				end
			end

			S_EMIT: begin
				if (pix_sel != 6'd63 && emit_x >= 0 && emit_x < 11'sd320) begin
					dbg_emitted <= dbg_emitted + 16'd1;
					lb_wr_addr <= {render_bank, emit_x[8:0]};
					lb_wr_data <= {1'b1, pri, colr, pix_sel};
					lb_we      <= 1'b1;
				end
				pcnt <= pcnt + 3'd1;
				if (pcnt == 3'd7) begin
					// Both halves are already latched, so the second 8 pixels
					// need no further fetch. `half` is cleared when a new
					// column starts, NOT here -- clearing it in S_WAIT was what
					// made the engine loop forever on one tile.
					if (half) state <= S_NEXTC;
					else begin
						half <= 1'b1;
						pcnt <= 3'd0;
					end
				end
			end

			S_NEXTS: begin
				if (index == 9'd0 || budget == 12'd0) begin
					if (index != 9'd0) dbg_starved <= dbg_starved + 16'd1;
					busy  <= 1'b0;
					state <= S_IDLE;
				end
				else begin
					index <= index - 9'd1;
					state <= S_ATTR;
				end
			end

			default: state <= S_IDLE;
			endcase
		end
	end

	wire _unused = &{1'b0, fetched};

endmodule
