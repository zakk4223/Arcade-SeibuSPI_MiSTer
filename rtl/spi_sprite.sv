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
//  `code % elements == 0` is skipped. The RISE "extra bank" bit -- word 2 bit
//  12, which becomes tile code bit 16 -- is applied only when the gfx region
//  holds MORE than 0x10000 tiles, which is MAME's own gfxbank_callback rule
//  (seibuspi_v.cpp:370). The SEI252 sets have exactly 0x10000 tiles per 4 MB
//  chunk so it never fires there; rdft2's 6 MB chunks hold 0x18000 and it does.
//  That condition is read off spr_chunk_stride rather than a separate flag,
//  because elements = chunk / 64 and the two cannot disagree that way.
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

	// Per set. The stride is the sprite region divided by three, so it is the
	// chunk size: 4 MB for the SEI252 games, 6 MB for rdft2. `rise10` picks the
	// decryption with it -- the two always move together, but they are separate
	// inputs because rdft2us shares RISE10 with a different board.
	input      [25:0] spr_chunk_stride,
	input             rise10,

	// Sprite RAM (1024 dwords), read port
	output reg  [9:0] spr_addr,
	input      [31:0] spr_data,

	// SDRAM channel 4
	output reg [25:0] sdr_addr,
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
	output     [16:0] dbg_tile_code,
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
	// Not `state` alone: the golden test keys its per-pixel sprite check on
	// dbg_state == 9 (the old S_EMIT), and when the sequencer was split that
	// check quietly matched nothing and reported 0 of 0 pixels rather than
	// failing. Keep 9 meaning "emitting a pixel" whatever the encoding is.
	assign dbg_state = (state == S_DRAW && estate == E_RUN) ? 4'd9 :
	                   (state == S_DRAW)                    ? {1'b0, fstate} : state;
	assign dbg_index = sidx;
	assign dbg_pix   = pix_sel;
	assign dbg_emitx = emit_x;
	assign dbg_code  = code;
	// Emit-side, not fetch-side. The fetcher is a column ahead, so tapping its
	// tile_code/ry against the emitter's half/pcnt compares two different
	// columns -- which made the golden per-pixel check report 275 of 640
	// differing while the frame itself got BETTER.
	assign dbg_tile_code = r_tcode[eb];
	assign dbg_ry    = r_ry[eb];
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

	// Display-side bank, switching on the line boundary rather than following
	// the renderer's deferred flip -- same reasoning and same expression as
	// spi_layers, and the two must agree or the mixer takes its sprite pixel
	// from a different line than its tile pixels.
	wire disp_bank = ~vcnt[0];
	wire [9:0] lb_rd_addr = {lb_wrap ? ~disp_bank : disp_bank, lb_x};

	spi_dpram #(.DW(15), .AW(10)) lbuf
		(.wr_clk(clk), .rd_clk(clk),
		 .wr_addr(lb_wr_addr), .wr_data(lb_wr_data), .wr_en(lb_we),
		 .rd_addr(lb_rd_addr), .rd_data(lb_out));

	// ------------------------------------------------------------------
	// Sprite attributes, latched as the list is walked
	// ------------------------------------------------------------------
	reg [15:0] attr, code;
	reg        ext;                       // word 2 bit 12: the extra bank
	reg  [8:0] sx_raw, sy_raw;

	// MAME: gfxbank_callback adds 0x10000 only when elements > 0x10000, and
	// elements is the chunk size over 64 bytes per tile.
	wire ext_bank = (spr_chunk_stride > 26'h040_0000);
	wire [16:0] code_ext = {ext & ext_bank, code};

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
	// The scanner does its own y test on the streaming data (sc_yhit); this is
	// the drawer's view, from the registered copy it popped off the FIFO.
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
	wire [16:0] tile_code = code_ext + ({13'd0, ax} * {13'd0, rows_per_col})
	                                 + {14'd0, ay};

	wire signed [10:0] col_x = 11'(spr_x + $signed({4'd0, axc, 4'd0}));  // + axc*16
	// This 16-pixel column has at least one pixel on screen. Skipping an
	// off-screen column costs one cycle instead of about forty.
	wire col_visible = ((col_x + 11'sd16) > 11'sd0) && (col_x < 11'sd320);

	// ------------------------------------------------------------------
	// Graphics address: chunk k at + k*stride, tile*64 + row*4
	// ------------------------------------------------------------------
	// Written as a mux rather than chunk * stride: chunk is only ever 0, 1 or 2,
	// and a 26-bit multiplier for that would be silly.
	//
	// The row arithmetic is the same for both crypts even though RISE10 sets
	// carry MAME's sprite_reorder(), because rom_loader undoes that when it
	// places them (M_SPR_R10). Doing it here instead would put the two halves of
	// a row 32 bytes apart and cost six SDRAM reads per row instead of three.
	reg  [1:0] chunk;
	reg [25:0] chunk_base;
	always @* case (chunk)
		2'd0   : chunk_base = SDR_SPRITES_BASE;
		2'd1   : chunk_base = SDR_SPRITES_BASE + spr_chunk_stride;
		default: chunk_base = SDR_SPRITES_BASE + {spr_chunk_stride[24:0], 1'b0};
	endcase
	// Bits 1:0 are always zero: rows are 4 bytes apart. Bit 2 picks which half
	// of the 8-byte SDRAM read holds this row.
	/* verilator lint_off UNUSEDSIGNAL */
	wire [25:0] row_addr   = chunk_base + {3'd0, tile_code, 6'd0} + {19'd0, ry, 2'd0};
	/* verilator lint_on UNUSEDSIGNAL */

	// ------------------------------------------------------------------
	// Decryption inputs: three 16-bit words, one per chunk
	// ------------------------------------------------------------------
	// One 64-bit read per chunk already covers the whole 16-pixel row: the four
	// row bytes hold word i (pixels 0-7) and word i+1 (pixels 8-15). Both are
	// latched, so a row costs three reads rather than six.
	// Double buffered, so the fetcher can pull the next column's three chunks
	// while the emitter is still walking this one's sixteen pixels. Those two
	// used to be strictly sequential -- three SDRAM round trips (~21 cycles)
	// and THEN 16 emit cycles -- which is most of the per-column cost and the
	// dominant term once the list walk stopped being one. They use different
	// resources (SDRAM vs the line buffer), so they overlap for free.
	//
	// Everything the emitter needs about a column is captured with the data,
	// because by the time it runs the fetcher has moved on to another column
	// and possibly another sprite.
	reg [15:0] r_y1a[0:1], r_y1b[0:1], r_y2a[0:1], r_y2b[0:1], r_y3a[0:1], r_y3b[0:1];
	reg [16:0] r_tcode[0:1];
	reg signed [10:0] r_colx[0:1];
	reg        r_flipx[0:1];
	reg  [5:0] r_colr[0:1];
	reg  [1:0] r_pri[0:1];
	reg  [3:0] r_ry[0:1];      // only for the debug tap, but it has to match
	reg  [1:0] rv;                        // which banks hold a row ready to emit
	reg        fb, eb;                    // fetch bank, emit bank

	reg        half;                      // which 8 pixels of the row

	wire [15:0] y1 = half ? r_y1b[eb] : r_y1a[eb];
	wire [15:0] y2 = half ? r_y2b[eb] : r_y2a[eb];
	wire [15:0] y3 = half ? r_y3b[eb] : r_y3a[eb];

	// Both crypts, muxed. They present the same 48-bits-in, eight-pens-out
	// interface and the same pen bit order, so the mux is on the result and
	// nothing else in the emitter changes. RISE10 is address independent and
	// much the smaller of the two; SEI252 carries the key table.
	wire [5:0] s0, s1_, s2_, s3, s4, s5, s6, s7;
	wire [5:0] r0, r1, r2, r3, r4, r5, r6, r7;

	spi_spr_decrypt dec_sei252
	(
		.y1(y1), .y2(y2), .y3(y3),
		.addr(r_tcode[eb][14:3]),         // addr = code >> 3, for the emitting bank
		.pix0(s0), .pix1(s1_), .pix2(s2_), .pix3(s3),
		.pix4(s4), .pix5(s5),  .pix6(s6),  .pix7(s7)
	);

	spi_rise10_decrypt dec_rise10
	(
		.y1(y1), .y2(y2), .y3(y3),
		.pix0(r0), .pix1(r1), .pix2(r2), .pix3(r3),
		.pix4(r4), .pix5(r5), .pix6(r6), .pix7(r7)
	);

	wire [5:0] p0 = rise10 ? r0 : s0;
	wire [5:0] p1 = rise10 ? r1 : s1_;
	wire [5:0] p2 = rise10 ? r2 : s2_;
	wire [5:0] p3 = rise10 ? r3 : s3;
	wire [5:0] p4 = rise10 ? r4 : s4;
	wire [5:0] p5 = rise10 ? r5 : s5;
	wire [5:0] p6 = rise10 ? r6 : s6;
	wire [5:0] p7 = rise10 ? r7 : s7;

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
	wire signed [10:0] emit_x = r_colx[eb] + (r_flipx[eb] ? $signed({7'd0, 4'd15 - tile_px})
	                                                     : $signed({7'd0, tile_px}));

	// ------------------------------------------------------------------
	// Sequencer
	// ------------------------------------------------------------------
	// Line phase.
	localparam [3:0] S_IDLE  = 4'd0,
	                 S_CLR   = 4'd1,
	                 S_DRAW  = 4'd2;
	// Fetch machine, inside S_DRAW.
	localparam [2:0] F_POP  = 3'd0,   // take the next sprite the scanner queued
	                 F_COL  = 3'd1,   // is this column on screen, and is a bank free?
	                 F_REQ  = 3'd2,   // request chunk `chunk`
	                 F_WAIT = 3'd3,
	                 F_DONE = 3'd4;
	// Emit machine, inside S_DRAW, running a column behind the fetcher.
	localparam       E_IDLE = 1'b0,
	                 E_RUN  = 1'b1;

	reg [3:0]  state;
	reg [2:0]  fstate;
	reg        estate;
	reg [8:0]  clr;
	reg [11:0] budget;                 // hard per-line cap on fetch work
	reg        restart_req;

	reg [15:0] nz_cnt;    // non-zero codes seen on the line in progress
	reg [31:0] or_acc;    // OR of every sprite-RAM dword seen on that line

	// A line is 448 * 8 = 3584 cycles. The clear takes 320, and the list walk
	// now overlaps the drawing instead of preceding it, so essentially all of
	// this is available for pixel fetches.
	localparam [11:0] BUDGET = 12'd3200;

	// ------------------------------------------------------------------
	// Scanner / drawer split
	//
	// The list walk and the drawing use DIFFERENT resources -- the walk only
	// reads sprite RAM, the drawing only reads SDRAM -- but the old state
	// machine ran them one after the other, so the 512-entry walk was pure
	// dead time in front of every fetch. At 3 cycles a sprite that is 1536 of
	// the 3200-cycle budget spent before a single pixel is drawn, and on a busy
	// scene the budget ran out mid-list: measured on hardware at ~30 lines a
	// frame losing sprites, against the ~0.25% recorded for a quiet scene.
	//
	// They are two independent state machines now, with a FIFO between them.
	// The scanner streams the list at 2 cycles a sprite -- the floor for a
	// single-port RAM that needs two reads per entry -- and pushes the sprites
	// that pass the y test. The drawer pops and draws. The walk is hidden
	// behind the drawing, and what is left is bounded by fetch bandwidth, which
	// is the real limit.
	//
	// FIFO order is list order, so MAME's "later entry drawn on top" still
	// falls out of the write order exactly as before.
	// ------------------------------------------------------------------
	localparam FIFO_N = 8;
	reg [50:0] fifo [0:FIFO_N-1];         // {attr, code, ext, sx, sy}
	reg  [3:0] fifo_wp, fifo_rp;          // one spare bit for full vs empty
	wire [3:0] fifo_cnt   = fifo_wp - fifo_rp;
	wire       fifo_empty = (fifo_wp == fifo_rp);
	// Stall with room to spare: two reads are already in flight when the
	// scanner stalls, and both may still push.
	wire       fifo_full  = (fifo_cnt >= 4'd6);

	// Scanner
	reg  [8:0] sidx;                      // entry being issued
	reg        shalf;                     // which dword of it
	reg        scan_run, scan_done;
	reg [15:0] s_attr, s_code;
	// Two-cycle read pipeline: sprite RAM answers two cycles after the address
	// is registered, so track what each in-flight read belongs to.
	reg        p1_v, p2_v;
	reg        p1_h, p2_h;
	reg  [8:0] p1_i, p2_i;

	wire [8:0] sc_sy = spr_data[24:16];
	wire signed [10:0] sc_spr_y = (sc_sy >= 9'h180) ? {2'b11, sc_sy} : {2'b00, sc_sy};
	wire signed [10:0] sc_dy    = $signed({2'b00, render_line}) - sc_spr_y;
	wire sc_yhit = (sc_dy >= 0) && (sc_dy[10:4] <= {4'd0, s_attr[14:12]});

	// ... and the same test on X, which nothing used to do. The y test alone
	// queues sprites parked entirely off the sides, and every one of their
	// columns then costs three SDRAM reads and sixteen emit cycles for pixels
	// that S_EMIT throws away at the write. On a busy scene that is where the
	// budget goes. A sprite spans (sizex+1)*16 pixels from its x.
	wire [8:0] sc_sx = spr_data[8:0];
	wire signed [10:0] sc_spr_x = (sc_sx >= 9'h180) ? {2'b11, sc_sx} : {2'b00, sc_sx};
	wire signed [10:0] sc_width = 11'sd16 + $signed({4'd0, s_attr[10:8], 4'd0});
	wire sc_xhit = ((sc_spr_x + sc_width) > 11'sd0) && (sc_spr_x < 11'sd320);

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
			sidx        <= 9'd511;
			shalf       <= 1'b0;
			scan_run    <= 1'b0;
			scan_done   <= 1'b0;
			fifo_wp     <= 4'd0;
			fifo_rp     <= 4'd0;
			p1_v        <= 1'b0;
			p2_v        <= 1'b0;
			fstate      <= F_POP;
			estate      <= E_IDLE;
			rv          <= 2'b00;
			fb          <= 1'b0;
			eb          <= 1'b0;
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

			// ---- scanner, concurrent with everything below ----------------
			// Runs during the clear as well, so the first sprites are already
			// queued by the time the drawer is ready for them.
			p1_v <= 1'b0;
			p2_v <= p1_v; p2_h <= p1_h; p2_i <= p1_i;

			if (scan_run && !fifo_full && budget != 12'd0) begin
				spr_addr <= {sidx, shalf};
				p1_v  <= 1'b1;
				p1_h  <= shalf;
				p1_i  <= sidx;
				shalf <= ~shalf;
				if (shalf) begin
					if (sidx == 9'd0) scan_run <= 1'b0;
					else              sidx <= sidx - 9'd1;
				end
			end

			if (p2_v) begin
				if (!p2_h) begin
					// dword 2n: attributes and code
					s_attr <= spr_data[15:0];
					s_code <= spr_data[31:16];
					or_acc <= or_acc | spr_data;
				end
				else begin
					// dword 2n+1: position. s_attr / s_code were latched last
					// cycle, so the y test can be done here.
					or_acc      <= or_acc | spr_data;
					dbg_scanned <= dbg_scanned + 16'd1;
					if (s_code != 16'd0) nz_cnt <= nz_cnt + 16'd1;
					// MAME skips code 0 (`code % elements == 0`).
					if (sc_yhit && sc_xhit && s_code != 16'd0) begin
						dbg_yhit <= dbg_yhit + 16'd1;
						fifo[fifo_wp[2:0]] <= {s_attr, s_code, spr_data[12],
						                       spr_data[8:0], spr_data[24:16]};
						fifo_wp <= fifo_wp + 4'd1;
					end
					if (p2_i == 9'd0) scan_done <= 1'b1;
				end
			end

			// Restart only at a sprite boundary, so an SDRAM request is never
			// abandoned with its ack outstanding.
			// Safe only where no SDRAM request is outstanding: F_REQ/F_WAIT
			// have one in flight and must not be abandoned with its ack
			// pending. Interrupting the emitter mid-column is fine -- the line
			// is being abandoned anyway and S_CLR wipes the buffer.
			if (restart_req && (state == S_IDLE ||
			                    (state == S_DRAW && (fstate == F_POP ||
			                                         fstate == F_COL ||
			                                         fstate == F_DONE)))) begin
				restart_req <= 1'b0;
				render_line <= (vcnt >= VBSTART - 10'd1) ? 9'd0 : (vcnt[8:0] + 9'd1);
				render_bank <= ~render_bank;
				clr         <= 9'd0;
				budget      <= BUDGET;
				busy        <= 1'b1;
				state       <= S_CLR;
				// Both machines restart together, on the same line. Anything
				// still queued belongs to the line just finished and must go.
				sidx      <= 9'd511;
				shalf     <= 1'b0;
				scan_run  <= enable;
				scan_done <= 1'b0;
				fifo_wp   <= 4'd0;
				fifo_rp   <= 4'd0;
				p1_v      <= 1'b0;
				p2_v      <= 1'b0;
				fstate    <= F_POP;
				estate    <= E_IDLE;
				rv        <= 2'b00;
				fb        <= 1'b0;
				eb        <= 1'b0;
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
					state <= enable ? S_DRAW : S_IDLE;
					if (!enable) busy <= 1'b0;
				end
				else clr <= clr + 9'd1;
			end

			S_DRAW: begin
				// ---- fetch: runs ahead, filling whichever bank is free -------
				case (fstate)
				F_POP: begin
					if (!fifo_empty && budget != 12'd0) begin
						{attr, code, ext, sx_raw, sy_raw} <= fifo[fifo_rp[2:0]];
						fifo_rp <= fifo_rp + 4'd1;
						axc    <= 3'd0;
						fstate <= F_COL;
					end
					else if ((scan_done && fifo_empty) || budget == 12'd0)
						fstate <= F_DONE;
				end

				// Off-screen columns cost a cycle instead of forty. A bank has to
				// be free before a fetch starts, which is the only place the
				// fetcher ever waits for the emitter.
				F_COL: begin
					if (!col_visible) begin
						if (axc == sizex) fstate <= F_POP;
						else              axc <= axc + 3'd1;
					end
					else if (!rv[fb]) begin
						chunk     <= 2'd0;
						dbg_tiles <= dbg_tiles + 16'd1;
						fstate    <= F_REQ;
					end
				end

				F_REQ: begin
					sdr_addr <= {row_addr[25:3], 3'b000};
					sdr_req  <= ~sdr_req;
					fstate   <= F_WAIT;
				end

				F_WAIT: if (sdr_ack == sdr_req) begin
					// 4 bytes of the row, selected by bit 2 of the address
					case (chunk)
					2'd0: begin
						r_y1a[fb] <= row_addr[2] ? sdr_dout[47:32] : sdr_dout[15:0];
						r_y1b[fb] <= row_addr[2] ? sdr_dout[63:48] : sdr_dout[31:16];
					end
					2'd1: begin
						r_y2a[fb] <= row_addr[2] ? sdr_dout[47:32] : sdr_dout[15:0];
						r_y2b[fb] <= row_addr[2] ? sdr_dout[63:48] : sdr_dout[31:16];
					end
					default: begin
						r_y3a[fb] <= row_addr[2] ? sdr_dout[47:32] : sdr_dout[15:0];
						r_y3b[fb] <= row_addr[2] ? sdr_dout[63:48] : sdr_dout[31:16];
					end
					endcase
					if (chunk == 2'd2) begin
						// Hand the column over with everything the emitter needs.
						r_tcode[fb] <= tile_code;
						r_colx[fb]  <= col_x;
						r_flipx[fb] <= flipx;
						r_colr[fb]  <= colr;
						r_pri[fb]   <= pri;
						r_ry[fb]    <= ry;
						rv[fb]      <= 1'b1;
						fb          <= ~fb;
						if (axc == sizex) fstate <= F_POP;
						else begin
							axc    <= axc + 3'd1;
							fstate <= F_COL;
						end
					end
					else begin
						chunk  <= chunk + 2'd1;
						fstate <= F_REQ;
					end
				end

				default: ;   // F_DONE: nothing left to fetch
				endcase

				// ---- emit: drains the other bank, concurrently ---------------
				case (estate)
				E_IDLE: if (rv[eb]) begin
					pcnt   <= 3'd0;
					half   <= 1'b0;
					estate <= E_RUN;
				end

				E_RUN: begin
					if (pix_sel != 6'd63 && emit_x >= 0 && emit_x < 11'sd320) begin
						dbg_emitted <= dbg_emitted + 16'd1;
						lb_wr_addr <= {render_bank, emit_x[8:0]};
						lb_wr_data <= {1'b1, r_pri[eb], r_colr[eb], pix_sel};
						lb_we      <= 1'b1;
					end
					pcnt <= pcnt + 3'd1;
					if (pcnt == 3'd7) begin
						// Both halves were latched by one pass of three reads, so
						// the second 8 pixels need no further fetch.
						if (half) begin
							rv[eb] <= 1'b0;
							eb     <= ~eb;
							estate <= E_IDLE;
						end
						else begin
							half <= 1'b1;
							pcnt <= 3'd0;
						end
					end
				end
				endcase

				// The line is over once nothing is left to fetch and both banks
				// have drained.
				if (fstate == F_DONE && estate == E_IDLE && rv == 2'b00) begin
					if (!scan_done || !fifo_empty)
						dbg_starved <= dbg_starved + 16'd1;
					busy  <= 1'b0;
					state <= S_IDLE;
				end
			end

			default: state <= S_IDLE;
			endcase
		end
	end


endmodule
