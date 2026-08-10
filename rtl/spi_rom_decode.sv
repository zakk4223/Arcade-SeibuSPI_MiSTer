//============================================================================
//  SlopperPI - ROM download decoder
//
//  Sits between ioctl and the SDRAM writer in rom_loader, so a part can be
//  DECODED on the way in rather than copied. The point is rdft2: its sample
//  flash is not a concatenation of ROMs the way rdft's is, so an MRA cannot
//  assemble it. 312,933 bytes of sound1.u0222 expand to 471,277 bytes of PCM,
//  and the expansion has to happen somewhere. Doing it here costs a few hundred
//  logic cells and two M9Ks, against the several-minute first boot, the 2 MB
//  save file and the writable sample path the authentic flash route needs.
//
//  Which codec a part uses is chosen by the MRA, not by this file -- see the
//  codec config in SeibuSPI.sv. Adding one is a new CODEC_* id in spi_defs.vh
//  and a new arm here; nothing else moves.
//
//  ---------------------------------------------------------------------------
//  CODEC_BPE_DPCM: byte pair encoding over DPCM
//  ---------------------------------------------------------------------------
//  Transcribed from the 386 routine at 0x2A1D20 in rdft2's own program ROM,
//  which is what builds the flash image on real hardware. It is Philip Gage's
//  BPE (Dr. Dobb's, 1994) with every leaf byte treated as a signed delta.
//  PLAN.md section 0 has the full derivation; the stream is:
//
//      u16 nblocks              LITTLE-endian
//      per block:
//        pair table             a count byte >= 0x80 skips (count - 127)
//                               entries; otherwise it introduces count + 1.
//                               Per entry read `left`, and only if
//                               left != index read `right`. left[i] == i is
//                               therefore the "unused" encoding.
//        u16 size               BIG-endian, input bytes in this block
//        size bytes             each expanded through the table
//
//      out[n] = out[n-1] + leaf     8-bit wrapping. The accumulator spans the
//                                   WHOLE part, not one block.
//
//  Expansion is the usual BPE stack walk: while left[c] != c, push right[c] and
//  take left[c]; pop before fetching new input. The table is rebuilt per block.
//
//  Two details that look like they could be simplified but cannot:
//
//    * the "unused" test is against the table's INITIAL content, so it compares
//      the fetched byte against the entry INDEX. That is why S_INIT exists --
//      the walk needs left[i] == i to mean "leaf" for every untouched entry.
//    * the table-full test happens on BOTH arms of the skip branch (the 386's
//      `cmp edi,edx` at 0x2A1D9A is the join point), not just after a skip.
//============================================================================

module spi_rom_decode
(
	input             clk,
	input             reset,

	// Codec for the part now being loaded, and a one-cycle pulse at its start.
	// `codec` is sampled by `start`, so it may change between parts but not
	// during one.
	input       [3:0] codec,
	input             start,

	input             in_valid,
	input       [7:0] in_data,
	output            in_ready,

	output reg        out_valid,
	output reg  [7:0] out_data,
	input             out_ready,

	// No byte held and nothing part-way through a symbol: the part can end here.
	output            idle
);

`include "spi_defs.vh"

	localparam [4:0] S_RAW    = 5'd0;   // pass-through
	localparam [4:0] S_HDR0   = 5'd1;
	localparam [4:0] S_HDR1   = 5'd2;
	localparam [4:0] S_BLK    = 5'd3;
	localparam [4:0] S_INIT   = 5'd4;   // left[i] = i, right[i] = 0
	localparam [4:0] S_TCNT   = 5'd5;   // pair table: group count byte
	localparam [4:0] S_TLEFT  = 5'd6;
	localparam [4:0] S_TRIGHT = 5'd7;
	localparam [4:0] S_TNEXT  = 5'd8;
	localparam [4:0] S_SZ0    = 5'd9;
	localparam [4:0] S_SZ1    = 5'd10;
	localparam [4:0] S_EXP    = 5'd11;  // pop, fetch, or end of block
	localparam [4:0] S_FETCH  = 5'd12;
	localparam [4:0] S_POP    = 5'd13;  // stack read latency
	localparam [4:0] S_WALK   = 5'd14;  // table read latency
	localparam [4:0] S_EVAL   = 5'd15;
	localparam [4:0] S_EMIT   = 5'd16;
	localparam [4:0] S_DONE   = 5'd17;

	reg  [4:0] state;
	reg [15:0] nblk;
	reg  [8:0] ti;      // table index. 9 bits: a skip can overshoot 255
	reg  [8:0] rem;     // entries left in this group AFTER the current one
	reg  [7:0] tleft;
	reg [15:0] bsize;
	reg  [7:0] acc;     // DPCM accumulator
	reg  [7:0] sym;
	reg  [8:0] sp;

	// ------------------------------------------------------------------
	// Handshake
	// ------------------------------------------------------------------
	wire needs_byte = (state == S_HDR0)  || (state == S_HDR1)
	               || (state == S_TCNT)  || (state == S_TLEFT)
	               || (state == S_TRIGHT)|| (state == S_SZ0)
	               || (state == S_SZ1)   || (state == S_FETCH);

	// `start` takes the reset arm below, which does not consume input, so the
	// handshake has to close for that cycle or the byte is accepted and
	// dropped. That is one byte per part boundary, and it is silent.
	assign in_ready = start ? 1'b0
	                : (state == S_RAW) ? (!out_valid || out_ready) : needs_byte;
	assign idle     = !out_valid && (needs_byte || (state == S_DONE) || (state == S_RAW));

	wire take = in_valid && in_ready;

	// ------------------------------------------------------------------
	// Pair table, 256 x {right, left}. One M9K.
	// ------------------------------------------------------------------
	reg [15:0] tbl [0:255];
	reg [15:0] tbl_q;
	reg  [7:0] tbl_ra;
	reg  [7:0] tbl_wa;
	reg [15:0] tbl_wd;
	reg        tbl_we;

	always @* begin
		tbl_we = 1'b0;
		tbl_wa = ti[7:0];
		tbl_wd = {8'h00, ti[7:0]};
		if (state == S_INIT) begin
			tbl_we = 1'b1;
		end
		else if ((state == S_TRIGHT) && take && !ti[8]) begin
			tbl_we = 1'b1;
			tbl_wd = {in_data, tleft};
		end
	end

	always @* tbl_ra = sym;

	always @(posedge clk) begin
		if (tbl_we) tbl[tbl_wa] <= tbl_wd;
		tbl_q <= tbl[tbl_ra];
	end

	// ------------------------------------------------------------------
	// Expansion stack. The 386 allocates 64 bytes; 256 is one M9K either way
	// and cannot be overrun by a table whose chains are shorter than the
	// dictionary itself.
	// ------------------------------------------------------------------
	reg [7:0] stk [0:255];
	reg [7:0] stk_q;
	wire [7:0] stk_ra = sp[7:0] - 8'd1;
	wire       stk_we = (state == S_EVAL) && (tbl_q[7:0] != sym);

	always @(posedge clk) begin
		if (stk_we) stk[sp[7:0]] <= tbl_q[15:8];
		stk_q <= stk[stk_ra];
	end

	// A skip code adds (count - 127) to the index; both terms are 8-bit so the
	// sum needs 9 bits and can overshoot 255 on malformed data. ti[8] is the
	// "table full" test everywhere, so an overshoot ends the table rather than
	// running off the end of it.
	wire [8:0] ti_skip = ti + {1'b0, in_data} - 9'd127;
	wire [8:0] ti_next = in_data[7] ? ti_skip : ti;

	wire [7:0] leaf = acc + sym;

	always @(posedge clk) begin
		if (reset || start) begin
			state     <= (codec == CODEC_BPE_DPCM) ? S_HDR0 : S_RAW;
			out_valid <= 1'b0;
			acc       <= 8'd0;
			sp        <= 9'd0;
			ti        <= 9'd0;
			nblk      <= 16'd0;
			bsize     <= 16'd0;
		end
		else begin
			if (out_valid && out_ready) out_valid <= 1'b0;

			case (state)
			S_RAW: begin
				if (take) begin
					out_data  <= in_data;
					out_valid <= 1'b1;
				end
			end

			S_HDR0: if (take) begin nblk[7:0]  <= in_data; state <= S_HDR1; end
			S_HDR1: if (take) begin nblk[15:8] <= in_data; state <= S_BLK;  end

			S_BLK: begin
				if (nblk == 16'd0) state <= S_DONE;
				else begin
					nblk  <= nblk - 16'd1;
					ti    <= 9'd0;
					state <= S_INIT;
				end
			end

			// 256 cycles per block, 19,200 for rdft2's 75 blocks. Nothing.
			S_INIT: begin
				ti <= ti + 9'd1;
				if (ti == 9'd255) begin
					ti    <= 9'd0;
					state <= S_TCNT;
				end
			end

			S_TCNT: if (take) begin
				ti    <= ti_next;
				rem   <= in_data[7] ? 9'd0 : {1'b0, in_data};
				state <= ti_next[8] ? S_SZ0 : S_TLEFT;
			end

			S_TLEFT: if (take) begin
				// left[i] == i is the unused encoding and carries no right byte
				if (in_data == ti[7:0]) begin
					ti    <= ti + 9'd1;
					state <= S_TNEXT;
				end
				else begin
					tleft <= in_data;
					state <= S_TRIGHT;
				end
			end

			S_TRIGHT: if (take) begin
				ti    <= ti + 9'd1;    // the write itself is in the tbl block
				state <= S_TNEXT;
			end

			S_TNEXT: begin
				if (rem == 9'd0) state <= ti[8] ? S_SZ0 : S_TCNT;
				else begin
					rem   <= rem - 9'd1;
					state <= S_TLEFT;
				end
			end

			S_SZ0: if (take) begin bsize[15:8] <= in_data; state <= S_SZ1; end
			S_SZ1: if (take) begin bsize[7:0]  <= in_data; state <= S_EXP; end

			S_EXP: begin
				if (sp != 9'd0) begin
					sp    <= sp - 9'd1;   // stk_ra is sp-1, sampled this edge
					state <= S_POP;
				end
				else if (bsize != 16'd0) state <= S_FETCH;
				else                     state <= S_BLK;
			end

			S_FETCH: if (take) begin
				bsize <= bsize - 16'd1;
				sym   <= in_data;
				state <= S_WALK;
			end

			S_POP: begin sym <= stk_q; state <= S_WALK; end

			S_WALK: state <= S_EVAL;   // tbl_q = {right[sym], left[sym]} next cycle

			S_EVAL: begin
				if (tbl_q[7:0] == sym) begin
					acc       <= leaf;
					out_data  <= leaf;
					out_valid <= 1'b1;
					state     <= S_EMIT;
				end
				else begin
					sp    <= sp + 9'd1;      // stk write is in the stk block
					sym   <= tbl_q[7:0];
					state <= S_WALK;
				end
			end

			S_EMIT: if (out_valid && out_ready) state <= S_EXP;

			default: ;   // S_DONE parks here until the next part's `start`
			endcase
		end
	end

endmodule
