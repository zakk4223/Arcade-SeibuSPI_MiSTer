//============================================================================
//  SeibuSPI - YMF271 "OPX" synthesis engine
//
//  MAME's sound_stream_update / op / eg_tick / pcm_sample / env_mul / pan
//  (ymf271.cpp, the OPX rewrite 03761e46766), re-expressed as one serial pass
//  over 48 slots per 44100 Hz sample.
//
//  This replaced a port of MAME's OLD core, which worked in linear gains: a
//  6 x 1024 signed waveform ROM multiplied by an envelope volume. The chip is
//  OPM-shaped and the new core models it that way -- everything is an
//  attenuation in 1/256ths of a decade, the operator is a log-sin lookup
//  summed with the envelope and resolved through one exponential, and the
//  envelope counts UPWARD in attenuation units at fs/2. Detune, Acc On,
//  EN/EXT Out, PCM interpolation and the external-waveform key code all
//  arrived with it; PLAN.md 14.5 listed every one of them as unimplementable
//  because MAME did not implement them either.
//
//  The chip's 48 slots are organised as 12 groups of 4, and each group's
//  `sync` field picks what its four slots are:
//
//    sync 0   4-operator FM, one of 16 algorithms
//    sync 1   two independent 2-operator FM pairs
//    sync 2   3-operator FM, plus slot 4 as a PCM voice
//    sync 3   four PCM voices
//
//  EVALUATION ORDER IS FLAT AND BANK-MAJOR, WHICH IS THE WHOLE TRAP.
//
//  Slot n = 12*bank + group, and the chip evaluates n = 0..47 in order: all
//  twelve S1 slots, then all S2, then S3, then S4. The old core walked one
//  group at a time in bank order 0,2,1,3, so a 4-op network resolved
//  S1->S3->S2->S4 inside one group and every modulator was same-frame. It is
//  not: in sync 0 the chain is S1->S3->S2->S4 but S2 (n = g+12) is reached
//  BEFORE its modulator S3 (n = g+24), so S2 reads S3's output from the
//  PREVIOUS sample. MAME's comment says so outright -- "modulators with a
//  lower slot number are taken from the current frame, higher-numbered ones
//  from the previous". That one-sample delay is part of the model.
//
//  So there is no live r1/r3/r2 network here any more. Every slot's output
//  persists in `out_mem*`, and a slot reads whichever of its own group's four
//  outputs the algorithm says modulate it -- some written this pass, some
//  last. The algorithm itself is latched per group off the head slot as the
//  pass walks bank 0 (and bank 1, for the second pair of a sync-1 group),
//  which is always before any slot that needs it.
//
//  Timing: clk_sys / 44100 = 1298 cycles a sample. An FM operator and a PCM
//  voice both cost 23 cycles -- the PCM path's fetch and interpolation come to
//  the same as the operator's five stages -- and a slot in EG_OFF costs 11. So
//  a chip with all 48 slots sounding is 1104 cycles plus cache misses.
//
//  That is measured, not argued: tb_ymf271's polyphony test configures the
//  documented worst case -- groups 0, 4 and 8 in sync 3 for twelve PCM voices,
//  the other nine in sync 0 for 36 FM operators, every one keyed and playing
//  its way through the sample ROM -- and requires `dbg_overrun` to stay at zero
//  across 400 samples with `dbg_active` reading 48.
//
//  No pipeline stage holds more than one ROM read or one multiply. That rule
//  is not style: the first version of the old FM path put a feedback multiply,
//  a phase add, a ROM lookup and a second multiply between one pair of flops
//  and missed clk_sys setup by 2.2 ns. The operator now needs TWO dependent
//  ROM reads -- log-sin then exp -- so it is three states, not one.
//
//  The fixed-point widths below are not guesses. tools/check_ymf271_math.py
//  sweeps phase_inc, pcm_step and the envelope increment against MAME's
//  unbounded integers, 2.5 M combinations, and fails if any of them is a bit
//  short. Change a width here and change it there.
//============================================================================

module ymf271_synth
	import system_consts::*;
(
	input                clk,
	input                reset,

	// ---- the savestate's three sections on this engine ------------------
	// Every one of them steals the port its own client uses, which is safe
	// because `pause` stops new sample ticks rather than freezing mid-pass, so
	// the engine has drained to S_IDLE long before the stream reaches these.
	ssbus_if.slave       ssbus_par,
	ssbus_if.slave       ssbus_st,
	ssbus_if.slave       ssbus_fb,

	// The cartridge board wires chip output 0 to the left speaker and 1 to the
	// right (MAME's spi(): add_route(0,"speaker",1.0,0) and (1,...,1)); the
	// single board sums ALL of them into one (sxx2e(): ALL_OUTPUTS -> "mono").
	//
	// ALL_OUTPUTS now spans EIGHT outputs, not four: the rewrite exposes the
	// EXT1/EXT2 pins as channels 4-7. So the mono sum here follows it and adds
	// all eight. Nothing ships on that path -- every MRA in mra/ sets the mod
	// byte's bit 0, so `stereo` is high on all six -- and on real hardware
	// EXT1/EXT2 are external pins whose return wiring is not established. This
	// matches MAME; it is not independently confirmed.
	input                stereo,

	// ---- slot parameter writes (from the register file) -------------------
	input                par_we,
	input          [7:0] par_addr,     // {slot[5:0], word[1:0]}
	input          [2:0] par_byte,
	input          [7:0] par_data,

	// group sync modes, two bits per group, group 0 in the low pair
	input         [23:0] grp_sync_flat,

	// ---- key on / off events ----------------------------------------------
	input                key_on,
	input                key_off,
	input          [5:0] key_slot,

	// ---- end-of-sample status ---------------------------------------------
	// One pulse per key-on, the first time the read pointer passes the end
	// address -- NOT once per loop. Drivers play one-shot samples as a short
	// silent loop and free the channel from a copy of the status register, so
	// re-raising End on every pass of that loop kills a note re-triggered on
	// the same slot between the copy and the free pass.
	output reg           end_set,      // pulse: slot `end_slot` reached its end
	output reg     [5:0] end_slot,

	// ---- 44100 Hz sample tick ---------------------------------------------
	input                sample_tick,

	// ---- SDRAM ch5: sample ROM --------------------------------------------
	output reg    [25:0] sdr_addr,
	input         [63:0] sdr_dout,
	output reg           sdr_req,
	input                sdr_ack,

	// ---- wave memory read port (utility registers 0x14-0x17) --------------
	// The host reads sample memory back through the chip. Served at slot
	// boundaries (S_NEXT) and when idle, never mid-slot, so it costs the
	// synthesis pass one SDRAM round trip and never corrupts a fetch in
	// flight. S_IDLE alone was NOT enough: under polyphony the pass fills most
	// of a sample period while a Z80 `in` is ~88 clk_sys cycles, so
	// back-to-back reads outran the refill and returned a stale latch -- 8 of
	// 32 bytes wrong in tb_ymf271.
	input         [22:0] ext_addr,
	input                ext_req,      // toggle: a byte is wanted
	output reg           ext_ack,      // toggle: mirrors ext_req when data is up
	output reg     [7:0] ext_data,

	output reg    [15:0] audio_l,
	output reg    [15:0] audio_r,
	// Toggles when the sample memory has been written -- the SPI cartridge's
	// sample flash programming itself. Folded in at a slot boundary, where no
	// fetch is outstanding; see cch_gen.
	input                mem_dirty,

	output reg    [15:0] dbg_overrun,
	output reg    [15:0] dbg_active   // slots processed, PCM voices + FM ops
);

`include "spi_defs.vh"
`include "ymf271_tables.vh"

	// EG states. EG_OFF is a real state, not "inactive": a released slot sits
	// in it with its output forced to zero and its Acc On sum cleared.
	localparam [2:0] EG_ATTACK  = 3'd0,
	                 EG_DECAY1  = 3'd1,
	                 EG_DECAY2  = 3'd2,
	                 EG_RELEASE = 3'd3,
	                 EG_OFF     = 3'd4;

	// Widths pinned by tools/check_ymf271_math.py. W_OUT is 18 rather than the
	// operator's 14 because waveform 6 is not an operator output: it is a DC
	// half-scale level plus the modulation input stretched by 64, which reaches
	// about 2.5x the range of every other waveform (MAME 783e8a2efc2).
	localparam int W_OUT = 18;

	// What device_reset() leaves every slot in: EG_OFF at full attenuation,
	// everything else zero. A zero-filled slot would instead be EG_ATTACK at
	// 0 dB -- the whole chip sounding.
	localparam [127:0] ST_INIT = {32'd0, 23'd0, 16'd0, 10'h3FF, EG_OFF,
	                              20'd0, 7'd0, 1'b0, 15'd0, 1'b0};

	integer i;

	// ------------------------------------------------------------------
	// Slot parameter RAM: 4 x 64 bit words per slot, byte writable.
	// The byte layout is documented in ymf271.sv, which owns the decode.
	// Word 3 was spare under the old core; it now carries FM register 0, the
	// key-on register, whose EN and EXT Out bits route a voice to CH4-7.
	//
	// Eight separate byte-wide arrays rather than one 64 bit array written
	// through a variable part-select. Quartus cannot turn
	//     par_mem[addr][{byte,3'b000} +: 8] <= data
	// into byte enables -- it built the whole thing out of registers instead,
	// 16k flip-flops plus a 256-to-1 mux on 64 bits, which came to 23k ALUTs
	// on its own. One array per lane is unambiguous and infers cleanly.
	// ------------------------------------------------------------------
	reg   [7:0] par_ra;
	wire [63:0] par_q;
	wire  [7:0] par_ra_mux = ss_par_acc ? ssbus_par.addr[7:0] : par_ra;

	genvar b;
	generate
		for (b = 0; b < 8; b = b + 1) begin : par_lane
			reg [7:0] mem [0:255];
			reg [7:0] q;
			// ONE write statement per lane, and the mux OUTSIDE it. Writing
			// `if (a) mem[x] <= p; else if (b) mem[y] <= q;` is still two
			// writes as far as Quartus is concerned, else-if or not: it stops
			// inferring memory and builds all 2 KB out of flip-flops. That is
			// what the sound FIFOs did, and this is the same mistake made
			// again one commit after the comment warning about it was written.
			wire [7:0] wa = ss_par_we ? ssbus_par.addr[7:0] : par_addr;
			wire [7:0] wd = ss_par_we ? ssbus_par.data[b*8 +: 8] : par_data;
			wire       we = ss_par_we | (par_we && (par_byte == b[2:0]));
			always @(posedge clk) begin
				if (we) mem[wa] <= wd;
				q <= mem[par_ra_mux];
			end
			assign par_q[b*8 +: 8] = q;
			initial for (int j = 0; j < 256; j = j + 1) mem[j] = 8'd0;
		end
	endgenerate

	// ------------------------------------------------------------------
	// Per-slot dynamic state. 128 bits, which is four savestate words, which
	// keeps the stream's index arithmetic a shift and a mask -- three words
	// needs a divide and a modulo by 3, and on a 32-bit index that is a full
	// divider in the combinational path: 36 ns of negative slack on a 17.5 ns
	// clock, measured.
	//
	//  [127:96] phase       FM phase accumulator, 2^32 = one cycle
	//  [ 95:73] pcm_pos     external-waveform read position, in source words
	//  [ 72:57] pcm_frac    its 16-bit fraction
	//  [ 56:47] eg_att      envelope ATTENUATION, 0 = loudest, 0x3FF = silent
	//  [ 46:44] eg_state
	//  [ 43:24] lfo_cnt     clock divider toward lfo_period(lfo_freq)
	//  [ 23:17] lfo_pos     one of 128 LFO steps
	//  [    16] pcm_ended   End already raised since this key-on
	//  [ 15: 1] acc         Acc On running sum, saturating at +/-8192
	//  [     0] spare
	// ------------------------------------------------------------------
	reg [127:0] st_mem [0:47];
	reg   [5:0] st_ra, st_wa;
	reg [127:0] st_q, st_wd;
	reg         st_we;

	always @(posedge clk) begin
		if (ss_st_commit)  st_mem[ss_st_slot] <= {ssbus_st.data[31:0], ss_st_stage};
		else if (st_we)    st_mem[st_wa] <= st_wd;
		st_q <= st_mem[ss_st_acc ? ss_st_slot : st_ra];
	end

	// Feedback history: a RAM the HEAD owns, plus a small hand-off register
	// file for the one case that crosses slots.
	//
	// The obvious shape -- two 48-entry flop arrays, with the feedback source
	// doing `hist1 = hist0; hist0 = out` on the head's entry -- costs 1,728
	// flip-flops, two 48-way write decoders and two 48-to-1 read muxes, and it
	// pushed the design past the device: the fitter wanted 4,212 LABs against
	// the 4,191 this part has.
	//
	// It is also unnecessary. The source only ever needs to hand the head ONE
	// word; the head can do its own shifting. At its visit the head takes
	//
	//     h0_now = fb_self ? h0 : fb_pend[...]        (this sample's newest)
	//     mod    = (h0_now + h1) >> (10 - fb)
	//
	// and writes back {out, h0_now}, so h1 next sample is h0_now this sample --
	// the older of the pair either way. That makes the head's entry a plain
	// read-at-S_LD3 / write-at-S_MIX pair on its OWN address, which a
	// single-port RAM does happily.
	//
	// The hand-off only exists when the source is NOT the head, and that is
	// only the S3-loop algorithms (sync 0 and 2, fbsrc 2) and the sync-1 tail
	// (fbsrc 1). Every one of those has its head at bank 0 or bank 1, so the
	// register file is indexed by {head_b0, group} -- 24 entries, not 48.
	// sync 3 and sync 2's fourth slot are their own source and never touch it.
	reg [2*W_OUT-1:0] fb_mem [0:47];
	reg         [5:0] fb_ra, fb_wa;
	reg [2*W_OUT-1:0] fb_q, fb_wd;
	reg               fb_we;

	always @(posedge clk) begin
		if (ss_fb_commit) fb_mem[ss_fb_slot] <= {ssbus_fb.data[3:0], ss_fb_stage};
		else if (fb_we)   fb_mem[fb_wa] <= fb_wd;
		fb_q <= fb_mem[ss_fb_acc ? ss_fb_slot : fb_ra];
	end

	reg signed [W_OUT-1:0] fb_pend [0:23];

	// ------------------------------------------------------------------
	// Slot outputs, as FLOPS rather than a RAM.
	//
	// This is the state the flat evaluation order forces. A slot needs the
	// outputs of up to three OTHER slots of its group, some written earlier in
	// this pass and some left over from the previous one, so the array has to
	// be readable at three arbitrary addresses at once. A single-port RAM
	// cannot do that; 48 x 18 flip-flops can, and the read collapses to one
	// 12-to-1 mux over the group's four entries because a slot's modulators
	// are always in its own group.
	// ------------------------------------------------------------------
	// FOUR COPIES of one single-port RAM, not 48 x 18 flops. The array needs
	// four arbitrary reads at once, which one RAM cannot serve -- but four
	// copies written together can, each holding the whole 48 and reading its
	// own group entry. That is 864 flip-flops and a 48-way write decoder traded
	// for four M10K blocks, the same trade fb_mem's comment above records
	// making when the flop version wanted more LABs than the part has.
	//
	// The read latency is free. `group` is loaded once per slot and holds for
	// the whole visit (see ngroup/nbank below), so a port clocked every cycle
	// carries the right value from the slot's second cycle on -- long before
	// in_sum is consumed. The write lands a cycle after S_MIX exactly as
	// st_mem's does, and the next reader of that entry is twelve slots away.
	//
	// Copy 0's read port is shared with the savestate stream the way fb_q's is,
	// which is safe for the same reason: the core is paused while the stream
	// runs, so no slot is consuming gout0 then.
	(* ramstyle = "M10K" *) reg signed [W_OUT-1:0] out_mem0 [0:47];
	(* ramstyle = "M10K" *) reg signed [W_OUT-1:0] out_mem1 [0:47];
	(* ramstyle = "M10K" *) reg signed [W_OUT-1:0] out_mem2 [0:47];
	(* ramstyle = "M10K" *) reg signed [W_OUT-1:0] out_mem3 [0:47];
	reg  [5:0] or_wa;
	reg signed [W_OUT-1:0] or_wd;
	reg        or_we;
	reg signed [W_OUT-1:0] gout0, gout1, gout2, gout3;

	// ------------------------------------------------------------------
	// The savestate's three sections.
	//
	// st_mem is 128 bits wide and fb_mem 36, while the stream carries 32-bit
	// items -- so a slot is four words and two respectively. A write stages the
	// earlier words and COMMITS on the last one, which is what lets each array
	// keep a single write port and stay inferred as memory.
	//
	// NOTE: every item here changed meaning with the OPX rewrite -- st_mem's
	// envelope is an attenuation now, not a volume -- and the stream carries no
	// version field, so a state written by the previous core loads as noise
	// rather than being rejected. See PLAN.md.
	// ------------------------------------------------------------------
	wire ss_par_acc = ssbus_par.access(SSIDX_YMF_PAR);
	wire ss_par_we  = ss_par_acc && ssbus_par.write;
	reg  ss_par_d;
	always @(posedge clk) begin
		ssbus_par.setup(SSIDX_YMF_PAR, 32'd256, 3);   // 64-bit items
		if (ss_par_acc) begin
			if (ssbus_par.write) ssbus_par.write_ack(SSIDX_YMF_PAR);
			else if (ssbus_par.read) begin
				if (ss_par_d) ssbus_par.read_response(SSIDX_YMF_PAR, par_q);
				ss_par_d <= 1'b1;
			end
		end
		else ss_par_d <= 1'b0;
	end

	// 48 slots x four words of state, then two words each of keyon and keyoff
	// pending. Four words is what st_mem is; it is also what keeps the index
	// arithmetic a shift and a mask.
	localparam int SS_ST_ITEMS = 48*4 + 4;
	localparam int SS_ST_KEY   = 48*4;

	wire        ss_st_acc  = ssbus_st.access(SSIDX_YMF_ST);
	wire [31:0] ss_st_idx  = ssbus_st.addr;
	wire  [5:0] ss_st_slot = ss_st_idx[7:2];
	wire  [1:0] ss_st_word = ss_st_idx[1:0];
	wire ss_key_wr = ss_st_acc && ssbus_st.write && (ss_st_idx >= SS_ST_KEY);
	wire ss_st_commit = ss_st_acc && ssbus_st.write
	                    && (ss_st_idx < SS_ST_KEY) && (ss_st_word == 2'd3);
	reg [95:0] ss_st_stage;
	reg        ss_st_d;

	always @(posedge clk) begin
		ssbus_st.setup(SSIDX_YMF_ST, SS_ST_ITEMS[31:0], 2);
		if (ss_st_acc) begin
			if (ssbus_st.write) begin
				if (ss_st_idx < SS_ST_KEY) begin
					if (ss_st_word == 2'd0) ss_st_stage[31:0]  <= ssbus_st.data[31:0];
					if (ss_st_word == 2'd1) ss_st_stage[63:32] <= ssbus_st.data[31:0];
					if (ss_st_word == 2'd2) ss_st_stage[95:64] <= ssbus_st.data[31:0];
				end
				ssbus_st.write_ack(SSIDX_YMF_ST);
			end
			else if (ssbus_st.read) begin
				if (ss_st_d)
					ssbus_st.read_response(SSIDX_YMF_ST, {32'd0,
						(ss_st_idx >= SS_ST_KEY)
						  ? (ss_st_word == 2'd0 ? keyon_pend[31:0]  :
						     ss_st_word == 2'd1 ? {16'd0, keyon_pend[47:32]} :
						     ss_st_word == 2'd2 ? keyoff_pend[31:0] :
						                          {16'd0, keyoff_pend[47:32]})
						  : (ss_st_word == 2'd0 ? st_q[31:0]  :
						     ss_st_word == 2'd1 ? st_q[63:32] :
						     ss_st_word == 2'd2 ? st_q[95:64] : st_q[127:96])});
				ss_st_d <= 1'b1;
			end
		end
		else ss_st_d <= 1'b0;
	end

	// Two words a slot: the two feedback history words and the slot's own
	// output, 54 bits in 64. fb_mem and out_mem* are RAM, read through their
	// registered ports (fb_q, gout0) with ss_fb_d giving the port its cycle;
	// fb_pend is still flops and is read straight out of the array.
	wire        ss_fb_acc  = ssbus_fb.access(SSIDX_YMF_FB);
	wire [31:0] ss_fb_idx  = ssbus_fb.addr;
	wire  [5:0] ss_fb_slot = 6'(ss_fb_idx >> 1);
	wire        ss_fb_word = ss_fb_idx[0];
	wire ss_fb_commit = ss_fb_acc && ssbus_fb.write && ss_fb_word
	                    && (ss_fb_idx < 32'd96);
	reg  [31:0] ss_fb_stage;
	reg         ss_fb_d;

	always @(posedge clk) begin
		ssbus_fb.setup(SSIDX_YMF_FB, 32'd120, 2);   // 48 x 2, then 24 hand-off
		if (ss_fb_acc) begin
			if (ssbus_fb.write) begin
				if (!ss_fb_word) ss_fb_stage <= ssbus_fb.data[31:0];
				ssbus_fb.write_ack(SSIDX_YMF_FB);
			end
			else if (ssbus_fb.read) begin
				if (ss_fb_d) ssbus_fb.read_response(SSIDX_YMF_FB, {32'd0,
					(ss_fb_idx >= 32'd96)
					  ? {14'd0, $unsigned(fb_pend[ss_fb_idx[4:0]])}
					  : ss_fb_word ? {$unsigned(gout0), 10'd0,
					                  fb_q[2*W_OUT-1:32]}
					               : fb_q[31:0]});
				ss_fb_d <= 1'b1;
			end
		end
		else ss_fb_d <= 1'b0;
	end

	// ------------------------------------------------------------------
	// Sample line cache: TWO consecutive 8-byte lines under one tag.
	//
	// Interpolation needs the word at the read position and the one after it,
	// and a packed 12-bit pair straddling an odd position spans four
	// consecutive bytes. Four bytes fit in one 8-byte line for five of the
	// eight alignments and cross into the next for the other three, so the
	// entry holds line A (the tag's own) and line B (the one above it). Any
	// four-byte span is then covered by A and B together, whatever its
	// alignment -- which is why the pair is tagged as a pair rather than
	// cached as two independent lines with two tags.
	//
	// The tags live in this RAM; the VALID bits live in plain registers
	// outside it, because a flash write has to retire all 49 cached copies at
	// once -- this pair plus one per slot, restored when that slot comes round
	// again -- and a RAM cannot be cleared in a cycle. See cch_vld_a.
	// ------------------------------------------------------------------
	reg  [19:0] cch_tag  [0:47];
	reg [127:0] cch_data [0:47];
	reg   [5:0] cch_ra, cch_wa;
	reg  [19:0] cch_tag_q, cch_tag_wd;
	reg [127:0] cch_data_q, cch_data_wd;
	reg         cch_we;

	always @(posedge clk) begin
		if (cch_we) begin
			cch_tag[cch_wa]  <= cch_tag_wd;
			cch_data[cch_wa] <= cch_data_wd;
		end
		cch_tag_q  <= cch_tag[cch_ra];
		cch_data_q <= cch_data[cch_ra];
	end

	// ------------------------------------------------------------------
	// Working registers
	// ------------------------------------------------------------------
	reg [47:0] keyon_pend, keyoff_pend;
	reg        tick_pend;

	// The pass walks banks OUTSIDE and groups inside, which is slot order
	// n = 0..47 with n = 12*bank + group. See the header: the order is the
	// model, not an implementation choice.
	reg  [1:0] bank;
	reg  [3:0] group;
	reg [63:0] w0, w1, w2, w3;

	// Per-slot state, unpacked from st_q at S_LD1.
	reg [31:0] phase;
	reg [22:0] pcm_pos;
	reg [15:0] pcm_frac;
	reg  [9:0] eg_att;
	reg  [2:0] eg_state;
	reg [19:0] lfo_cnt;
	reg  [6:0] lfo_pos;
	reg        pcm_ended;
	reg signed [14:0] acc;

	reg signed [W_OUT-1:0] fb0, fb1;   // the head's history, loaded at S_LD3

	// The group's algorithm, latched off the head slot as the pass walks bank 0
	// (and bank 1, for the second pair of a sync-1 group). Both heads are
	// reached before any slot that needs the value, so this is never stale
	// within a sample -- which is what MAME's rebuild_group() achieves by
	// rebuilding the whole group's connection cache up front.
	reg  [3:0] grp_alg  [0:11];
	reg  [3:0] grp_alg2 [0:11];

	// The live cache pair.
	reg [19:0] line_tag;
	reg        line_va, line_vb;
	reg [63:0] line_a, line_b;

	// One valid bit per slot per line, outside the tag RAM so that a flash
	// write can clear all 96 in one cycle. A generation NUMBER was tried first
	// and is wrong: two writes flip a one-bit generation back to where it
	// started and bring a stale line back to life, which the cache test caught
	// as a single wrong byte out of five. Any width only makes that rarer, and
	// an erase sweep writes often enough to reach it.
	reg [47:0] cch_vld_a, cch_vld_b;
	reg        dirty_ack;

	// Eight accumulators: CH0-3 are the DO1/DO2 pins, CH4-7 the EXT1/EXT2
	// pins. A carrier at full level is +/-8192 and the stream's full scale is
	// 32768, so these are already at output scale -- there is no final shift,
	// unlike the old core's >>2.
	reg signed [23:0] acc_ch [0:7];

	reg  [9:0] env;          // total attenuation, 0 (loudest) .. 1023
	reg [31:0] step;         // phase increment, or PCM step in q16 words
	reg signed [22:0] mod_in;
	reg signed [13:0] pcm_out;
	reg signed [W_OUT-1:0] op_out;
	reg  [4:0] rks_r;
	reg  [4:0] det_r;
	reg  [5:0] eg_rate_r;
	reg  [2:0] eg_state_pre_r;
	reg        eg_to_d1_r, eg_hold_r;
	reg  [2:0] eg_idx_r;
	reg signed [15:0] pm_mul_r;
	reg [19:0] fnum_q7;
	reg signed [32:0] inc_r;
	reg        op_neg, op_mute;
	reg  [5:0] att_hi;   // att_c[13:8]: the shift, and the 4096 cutoff

	// Table read ports. One address register each, one read a cycle: the
	// operator's two lookups are DEPENDENT (exp is addressed with the sum of
	// log-sin and the envelope) and must not share a stage.
	reg  [7:0] logsin_ra;
	reg [11:0] logsin_q;
	reg  [7:0] exp_ra;
	reg [10:0] exp_q;
	reg  [4:0] rks_q;
	reg  [4:0] det_q;
	reg [31:0] eginc_q;

	// The log-sin and exp reads are addressed from registers because their
	// addresses are computed in the operator's own stages. RKS, detune and the
	// envelope increment are addressed combinationally from parameters that
	// settled at S_LD3, so only their outputs need a flop.
	always @(posedge clk) begin
		logsin_q <= YMF_LOGSIN[logsin_ra];
		exp_q    <= YMF_EXP[exp_ra];
		rks_q    <= YMF_RKS[{kc_c, p_keyscale}];
		det_q    <= YMF_DETUNE[{kc_c, p_dt[1:0]}];
		eginc_q  <= YMF_EG_INC[eg_rate_r];
	end

	reg [22:0] fetch_base;   // first of the up-to-four bytes a sample needs
	reg [15:0] active_cnt;

	wire [1:0] sync = grp_sync_flat[{group, 1'b0} +: 2];

	// slot = 12 * bank + group, written as shifts so nothing is inferred from
	// a truncated multiply.
	wire [5:0] slot = {1'b0, bank, 3'b000} + {2'b00, bank, 2'b00} + {2'b00, group};

	// ---- parameter field views -------------------------------------------
	// Word 3 is FM register 0; the rest is unchanged from the old core's
	// packing. Detune, Acc On, Src Note and Src B were already stored -- they
	// sat in bytes nothing extracted, because MAME's old core dropped them.
	wire  [3:0] p_multiple   = w0[3:0];
	wire  [2:0] p_dt         = w0[6:4];
	wire  [6:0] p_tl         = w0[14:8];
	wire  [4:0] p_ar         = w0[20:16];
	wire  [2:0] p_keyscale   = w0[23:21];
	wire  [4:0] p_dec1rate   = w0[28:24];
	wire  [4:0] p_dec2rate   = w0[36:32];
	wire  [3:0] p_relrate    = w0[43:40];
	wire  [3:0] p_dec1lvl    = w0[47:44];
	wire [11:0] p_fns        = {w0[59:56], w0[55:48]};
	wire  [3:0] p_block      = w0[63:60];
	wire  [2:0] p_waveform   = w1[2:0];
	wire  [2:0] p_feedback   = w1[6:4];
	wire        p_accon      = w1[7];
	wire  [3:0] p_ch0        = w1[15:12];
	wire  [3:0] p_ch1        = w1[11:8];
	wire  [3:0] p_ch2        = w1[23:20];
	wire  [3:0] p_ch3        = w1[19:16];
	wire [22:0] p_start      = {w1[46:40], w1[39:32], w1[31:24]};
	wire [22:0] p_end        = {w2[6:0],   w1[63:56], w1[55:48]};
	wire [22:0] p_loop       = {w2[30:24], w2[23:16], w2[15:8]};
	wire  [1:0] p_fs         = w2[33:32];
	wire        p_bits12     = w2[34];
	wire  [1:0] p_srcnote    = w2[36:35];
	wire  [2:0] p_srcb       = w2[39:37];
	wire  [7:0] p_lfofreq    = w2[47:40];
	wire  [1:0] p_lfowave    = w2[49:48];
	wire  [2:0] p_pms        = w2[53:51];
	wire  [1:0] p_ams        = w2[55:54];
	wire  [3:0] p_alg        = w2[59:56];
	wire  [3:0] p_extout     = w3[6:3];
	wire        p_exten      = w3[7];

	// Only the twelve slots of groups 0/4/8 -- slot % 4 == 0 -- can fetch
	// external data; a wave-7 select anywhere else is silence, which is what
	// MAME does and what the old core had to special-case because its
	// update_pcm() called fatalerror() on the same input.
	wire p_pcm_ok = (slot[1:0] == 2'd0);
	wire p_is_pcm = (p_waveform == 3'd7) && p_pcm_ok;
	wire p_is_lin = (p_waveform == 3'd6);
	wire p_silent = (p_waveform == 3'd7) && !p_pcm_ok;

	// ---- key code (manual 2-9) --------------------------------------------
	// Octave from Block, N4N3 from the F-number. The external-waveform form
	// adds the sample's own base key code (4*SrcB + SrcNote) and reads the
	// F-number as 11 bits against a different threshold set; the 5-bit sum
	// wraps, which is the arithmetically right answer for negative blocks.
	// For an internal waveform MAME clamps the octave at 0 instead of letting
	// the manual's 4*Block wrap up to octave 7.
	wire signed [4:0] block_s = $signed({p_block[3], p_block});
	wire [10:0] fn11    = p_fns[10:0];
	wire  [1:0] n43_ext = (fn11 < 11'h100) ? 2'd0 :
	                      (fn11 < 11'h300) ? 2'd1 :
	                      (fn11 < 11'h500) ? 2'd2 : 2'd3;
	wire  [1:0] n43_int = (p_fns < 12'h780) ? 2'd0 :
	                      (p_fns < 12'h900) ? 2'd1 :
	                      (p_fns < 12'hA80) ? 2'd2 : 2'd3;
	wire  [4:0] kc_int  = {(block_s < 0) ? 3'd0 : p_block[2:0], n43_int};
	wire  [5:0] kc_ext  = {1'b0, p_srcb, p_srcnote} + {1'b0, p_block[2:0], n43_ext};
	wire  [4:0] kc_c    = p_is_pcm ? kc_ext[4:0] : kc_int;

	// ---- envelope state transitions ---------------------------------------
	// MAME checks these BEFORE picking the rate, and the D1L test runs on the
	// state the attack test may just have changed. Decay 1 ends at D1L * 32,
	// except D1L 15, which means 31 * 32 -- the bottom of the range, not
	// fifteen sixteenths of it.
	wire [9:0] d1l_att = (p_dec1lvl == 4'd15) ? 10'd992 : {1'b0, p_dec1lvl, 5'd0};
	wire       eg_to_d1 = (eg_state == EG_ATTACK) && (eg_att == 10'd0);
	wire [2:0] eg_state_1 = eg_to_d1 ? EG_DECAY1 : eg_state;
	wire [2:0] eg_state_pre = ((eg_state_1 == EG_DECAY1) && (eg_att >= d1l_att))
	                        ? EG_DECAY2 : eg_state_1;

	// ---- envelope rate ----------------------------------------------------
	// rate2 is 2*AR/D1R/D2R or 4*RR; rate 0 means infinite and never advances.
	// 62 + rks 31 = 93 is what the pre-clamp sum has to hold, so seven bits.
	wire [6:0] rate2 = (eg_state_pre == EG_ATTACK) ? {1'b0, p_ar,       1'b0} :
	                   (eg_state_pre == EG_DECAY1) ? {1'b0, p_dec1rate, 1'b0} :
	                   (eg_state_pre == EG_DECAY2) ? {1'b0, p_dec2rate, 1'b0} :
	                                                 {1'b0, p_relrate, 2'b00};
	wire [6:0] rate_sum = rate2 + {2'd0, rks_r};
	wire [5:0] eg_rate  = (rate2 == 7'd0) ? 6'd0 :
	                      (rate_sum > 7'd63) ? 6'd63 : rate_sum[5:0];

	// The envelope update is THREE stages, not one. Everything above is
	// downstream of eg_att -- the D1L compare picks the state, the state picks
	// the rate, the rate picks the shift -- and everything below feeds back
	// into eg_att. Run as one stage it is a compare, a mux, an add, a clamp, a
	// subtract, a 16-bit barrel shift, a wide OR and a multiply in series, and
	// it missed clk_sys setup by 2.557 ns: every failing path in the fit was
	// eg_att -> eg_att, with Quartus duplicating the register trying to save it.
	//
	// S_EGA latches the state and the rate, S_EGB the hold and the sub-step
	// index (and lets the eg_inc read land), S_EGC does the arithmetic.
	wire       eg_slow  = (eg_rate_r < 6'd48);
	wire [3:0] eg_sh    = eg_slow ? (4'd11 - eg_rate_r[5:2]) : 4'd0;
	wire [15:0] eg_mask = (16'd1 << eg_sh) - 16'd1;
	wire        eg_hold = eg_slow && |(eg_cnt & eg_mask);
	wire [15:0] eg_cnt_sh = eg_cnt >> eg_sh;
	wire  [2:0] eg_idx  = eg_slow ? eg_cnt_sh[2:0] : eg_cnt[2:0];

	// nibble idx of eg_inc[rate] is this sub-step's increment
	wire [3:0] eg_add = eginc_q[{eg_idx_r, 2'b00} +: 4];

	// ---- LFO --------------------------------------------------------------
	// Table 2-6-2 as a clock divider: one of 128 steps every K samples,
	// K = (32 - (n & 15)) << (14 - (n >> 4)) below 240 and 16 - (n & 15) above,
	// so f = fs / 128 / K spans 0.00066 .. 344.5 Hz. A counter, not a phase
	// accumulator -- the old core's init_lfo() truncated its increment to zero
	// for the 161 slowest settings, and this cannot.
	wire  [3:0] lfo_n_lo = p_lfofreq[3:0];
	wire  [3:0] lfo_n_hi = p_lfofreq[7:4];
	wire  [4:0] lfo_k_hi = 5'd16 - {1'b0, lfo_n_lo};      // n >= 240
	wire  [5:0] lfo_k_lo = 6'd32 - {2'b0, lfo_n_lo};      // n <  240
	wire [19:0] lfo_per  = (p_lfofreq >= 8'd240)
	                     ? {15'd0, lfo_k_hi}
	                     : ({14'd0, lfo_k_lo} << (4'd14 - lfo_n_hi));
	wire        lfo_wrap = (lfo_cnt + 20'd1) >= lfo_per;

	// Bipolar for PM, -128..127, every waveform starting at 0 and rising.
	wire  [6:0] lp     = lfo_pos;
	wire  [6:0] lp_s64 = lp + 7'd64;      // ((p + 64) & 127)
	wire  [6:0] lp_m32 = lp - 7'd32;      // 0..63 in the triangle's middle leg
	wire  [6:0] lp_m96 = lp - 7'd96;      // 0..31 in its last leg
	wire signed [8:0] lfo_pm_saw = $signed({1'b0, lp_s64, 1'b0}) - 9'sd128;
	wire signed [8:0] lfo_pm_tri =
		(lp < 7'd32) ? $signed({2'b00, lp[4:0], 2'b00}) :
		(lp < 7'd96) ? (9'sd128 - $signed({1'b0, lp_m32[5:0], 2'b00})) :
		               ($signed({2'b00, lp_m96[4:0], 2'b00}) - 9'sd128);
	wire signed [8:0] lfo_pm_c =
		(p_lfowave == 2'd1) ? lfo_pm_saw :
		(p_lfowave == 2'd2) ? (lp[6] ? -9'sd128 : 9'sd127) :
		(p_lfowave == 2'd3) ? lfo_pm_tri : 9'sd0;

	// Unipolar for AM, 0..127 of attenuation. Every waveform starts at FULL
	// attenuation at key-on and the saw and triangle come down from there --
	// the OPM convention, and ymfm's reading of the manual's figures.
	wire  [6:0] lfo_am_c =
		(p_lfowave == 2'd1) ? (7'd127 - lp) :
		(p_lfowave == 2'd2) ? (lp[6] ? 7'd0 : 7'd127) :
		(p_lfowave == 2'd3) ? (lp[6] ? ({lp[5:0], 1'b0} + 7'd1) : (7'd127 - {lp[5:0], 1'b0}))
		                    : 7'd0;

	wire lfo_on = (p_lfowave != 2'd0);
	// AMS depth: 63 / 126 / 252 units of 0.09375 dB.
	wire [8:0] am_term = (p_ams == 2'd1) ? {3'd0, lfo_am_c[6:1]} :
	                     (p_ams == 2'd2) ? {2'd0, lfo_am_c} :
	                     (p_ams == 2'd3) ? {1'd0, lfo_am_c, 1'b0} : 9'd0;
	wire [11:0] env_sum = {2'd0, eg_att} + {2'd0, p_tl, 3'b000}
	                    + ((p_ams != 2'd0 && lfo_on) ? {3'd0, am_term} : 12'd0);
	wire  [9:0] env_c   = (env_sum > 12'd1023) ? 10'd1023 : env_sum[9:0];

	// ------------------------------------------------------------------
	// Algorithm wiring
	//
	// The tables are MAME's alg4 / alg3 / alg2, packed. `mods` is a bitmask
	// over POSITIONS in the network; for sync 0 and sync 2 position equals
	// bank, so the mask is already a bank mask, and only sync 1 has to be
	// translated (its two pairs are banks 0,2 and banks 1,3).
	//
	// `car` says which positions reach the mixer and `fbsrc` which position's
	// output is written into the head's feedback history -- itself, or S3 for
	// the loop algorithms 1/5/7/11.
	// ------------------------------------------------------------------
	wire [3:0] alg_a = grp_alg[group];
	wire [3:0] alg_b = grp_alg2[group];

	reg [15:0] a4_mods; reg [3:0] a4_car; reg [1:0] a4_fbsrc;
	always @* begin
		a4_fbsrc = 2'd0;
		case (alg_a)
			4'd0:  begin a4_mods = 16'h2140; a4_car = 4'h8; end
			4'd1:  begin a4_mods = 16'h2140; a4_car = 4'h8; a4_fbsrc = 2'd2; end
			4'd2:  begin a4_mods = 16'h2050; a4_car = 4'h8; end
			4'd3:  begin a4_mods = 16'h3040; a4_car = 4'h8; end
			4'd4:  begin a4_mods = 16'h6100; a4_car = 4'h8; end
			4'd5:  begin a4_mods = 16'h6100; a4_car = 4'h8; a4_fbsrc = 2'd2; end
			4'd6:  begin a4_mods = 16'h2100; a4_car = 4'hC; end
			4'd7:  begin a4_mods = 16'h2100; a4_car = 4'hC; a4_fbsrc = 2'd2; end
			4'd8:  begin a4_mods = 16'h2040; a4_car = 4'h9; end
			4'd9:  begin a4_mods = 16'h6000; a4_car = 4'h9; end
			4'd10: begin a4_mods = 16'h0100; a4_car = 4'hE; end
			4'd11: begin a4_mods = 16'h0100; a4_car = 4'hE; a4_fbsrc = 2'd2; end
			4'd12: begin a4_mods = 16'h1110; a4_car = 4'hE; end
			4'd13: begin a4_mods = 16'h0040; a4_car = 4'hB; end
			4'd14: begin a4_mods = 16'h2100; a4_car = 4'hD; end
			default: begin a4_mods = 16'h0000; a4_car = 4'hF; end
		endcase
	end

	reg [11:0] a3_mods; reg [2:0] a3_car; reg [1:0] a3_fbsrc;
	always @* begin
		a3_fbsrc = 2'd0;
		case (alg_a[2:0])
			3'd0: begin a3_mods = 12'h140; a3_car = 3'h2; end
			3'd1: begin a3_mods = 12'h140; a3_car = 3'h2; a3_fbsrc = 2'd2; end
			3'd2: begin a3_mods = 12'h050; a3_car = 3'h2; end
			3'd3: begin a3_mods = 12'h040; a3_car = 3'h3; end
			3'd4: begin a3_mods = 12'h100; a3_car = 3'h6; end
			3'd5: begin a3_mods = 12'h100; a3_car = 3'h6; a3_fbsrc = 2'd2; end
			3'd6: begin a3_mods = 12'h000; a3_car = 3'h7; end
			default: begin a3_mods = 12'h100; a3_car = 3'h7; end
		endcase
	end

	// sync 1: the pair is picked by bank bit 0 and the position by bank bit 1,
	// so banks 0,2 are the first pair's head and tail and banks 1,3 the
	// second's. Each pair takes its algorithm from its own head slot.
	wire       pairB = bank[0];
	wire       pos2  = bank[1];
	wire [1:0] alg2s = pairB ? alg_b[1:0] : alg_a[1:0];
	reg  [3:0] a2_mods; reg [1:0] a2_car; reg a2_fbsrc;
	always @* begin
		a2_fbsrc = 1'b0;
		case (alg2s)
			2'd0: begin a2_mods = 4'h4; a2_car = 2'h2; end
			2'd1: begin a2_mods = 4'h4; a2_car = 2'h2; a2_fbsrc = 1'b1; end
			2'd2: begin a2_mods = 4'h0; a2_car = 2'h3; end
			default: begin a2_mods = 4'h4; a2_car = 2'h3; end
		endcase
	end
	wire [1:0] a2_m = a2_mods[{pos2, 1'b0} +: 2];

	reg  [3:0] mod_mask;     // which banks of this group modulate me
	reg        is_carrier, is_fbhead, is_fbsrc, fb_self;
	// Only which HALF the head is in matters, and only when the source is not
	// the head: those cases always have the head at bank 0 or bank 1.
	reg        head_b0;
	always @* begin
		fb_self = 1'b1;      // the head is its own feedback source
		case (sync)
			2'd0: begin
				mod_mask   = a4_mods[{bank, 2'b00} +: 4];
				is_carrier = a4_car[bank];
				is_fbhead  = (bank == 2'd0);
				is_fbsrc   = (bank == a4_fbsrc);
				head_b0    = 1'b0;
				fb_self    = (a4_fbsrc == 2'd0);
			end
			2'd1: begin
				mod_mask   = (a2_m[0] ? (pairB ? 4'b0010 : 4'b0001) : 4'b0000)
				           | (a2_m[1] ? (pairB ? 4'b1000 : 4'b0100) : 4'b0000);
				is_carrier = a2_car[pos2];
				is_fbhead  = (pos2 == 1'b0);
				is_fbsrc   = (pos2 == a2_fbsrc);
				head_b0    = pairB;
				fb_self    = (a2_fbsrc == 1'b0);
			end
			2'd2: begin
				if (bank == 2'd3) begin
					mod_mask   = 4'b0000;
					is_carrier = 1'b1;
					is_fbhead  = 1'b1;
					is_fbsrc   = 1'b1;
					head_b0    = 1'b0;
				end
				else begin
					mod_mask   = a3_mods[{bank, 2'b00} +: 4];
					is_carrier = a3_car[bank];
					is_fbhead  = (bank == 2'd0);
					is_fbsrc   = (bank == a3_fbsrc);
					head_b0    = 1'b0;
					fb_self    = (a3_fbsrc == 2'd0);
				end
			end
			default: begin                      // sync 3: four independent slots
				mod_mask   = 4'b0000;
				is_carrier = 1'b1;
				is_fbhead  = 1'b1;
				is_fbsrc   = 1'b1;
				head_b0    = 1'b0;
			end
		endcase
	end

	// The group's four outputs. A slot's modulators are always inside its own
	// group, so this is one 12-to-1 mux over four entries rather than a 48-way
	// read.
	always @(posedge clk) begin
		if (ss_fb_commit) begin
			out_mem0[ss_fb_slot] <= $signed(ssbus_fb.data[31:14]);
			out_mem1[ss_fb_slot] <= $signed(ssbus_fb.data[31:14]);
			out_mem2[ss_fb_slot] <= $signed(ssbus_fb.data[31:14]);
			out_mem3[ss_fb_slot] <= $signed(ssbus_fb.data[31:14]);
		end
		else if (or_we) begin
			out_mem0[or_wa] <= or_wd;
			out_mem1[or_wa] <= or_wd;
			out_mem2[or_wa] <= or_wd;
			out_mem3[or_wa] <= or_wd;
		end
		gout0 <= out_mem0[ss_fb_acc ? ss_fb_slot : {2'b00, group}];
		gout1 <= out_mem1[6'd12 + {2'b00, group}];
		gout2 <= out_mem2[6'd24 + {2'b00, group}];
		gout3 <= out_mem3[6'd36 + {2'b00, group}];
	end

	wire signed [W_OUT+1:0] in_sum = (mod_mask[0] ? {{2{gout0[W_OUT-1]}}, gout0} : 20'sd0)
	                               + (mod_mask[1] ? {{2{gout1[W_OUT-1]}}, gout1} : 20'sd0)
	                               + (mod_mask[2] ? {{2{gout2[W_OUT-1]}}, gout2} : 20'sd0)
	                               + (mod_mask[3] ? {{2{gout3[W_OUT-1]}}, gout3} : 20'sd0);

	// OPM's feedback law on the average of the last two outputs; the S3->S1
	// loop of algorithms 1/5/7/11 follows the same law. Level 0 is off.
	// {head_b0, group}: the hand-off entry for a source that is not the
	// head. Only banks 0 and 1 are ever a head in that case.
	wire [4:0] fb_pidx = {head_b0, group};
	wire signed [W_OUT-1:0] fb_h0 = fb_self ? fb0 : fb_pend[fb_pidx];
	wire signed [W_OUT:0] fb_sum = {fb_h0[W_OUT-1], fb_h0} + {fb1[W_OUT-1], fb1};
	wire  [3:0] fb_sh  = 4'd10 - {1'b0, p_feedback};
	wire signed [22:0] mod_fb = (p_feedback == 3'd0) ? 23'sd0
	                          : ({{4{fb_sum[W_OUT]}}, fb_sum} >>> fb_sh);
	wire signed [30:0] mod_mul = in_sum * $signed({1'b0, YMF_MODLVL[p_feedback]});
	wire signed [22:0] mod_c   = is_fbhead ? mod_fb : mod_mul[30:8];

	// ---- phase increment ---------------------------------------------------
	// f = 2 * fnum * 2^(block-7) * MUL * fs / 2^15, which is fnum << (block+11)
	// times MUL with detune added in units of fs/2^20 before the multiplier.
	// The external-waveform form is the same PG with the implicit F-number bit
	// 11, a step in source words with a 16-bit fraction, and the Fs divider.
	//
	// Every width here is swept against MAME's int64 by
	// tools/check_ymf271_math.py; the accumulator TRUNCATES to 32 bits, which
	// is how increments above fs/2 alias (the hi-hat carriers of the Seibu
	// titles are fed by such a modulator).
	wire [11:0] fnum_base = p_is_pcm ? {1'b1, p_fns[10:0]} : p_fns;

	wire signed [15:0] pm_t1 = $signed({1'b0, YMF_PMS_K[p_pms]}) * lfo_pm_c;
	wire signed [28:0] pm_t2 = $signed({1'b0, fnum_base}) * pm_mul_r;
	wire signed [18:0] pm_term = pm_t2[28:10];
	wire        [19:0] fnum_c = {fnum_base, 7'd0}
	                          + ((p_pms != 3'd0 && lfo_on) ? {{1{pm_term[18]}}, pm_term}
	                                                       : 20'd0);

	wire signed [5:0] fm_sh  = {block_s[4], block_s} + 6'sd4;     // -4 .. 11
	wire        [5:0] fm_nsh = 6'd0 - $unsigned(fm_sh);
	wire [32:0] inc_fm  = fm_sh[5] ? ({13'd0, fnum_q7} >> fm_nsh[2:0])
	                               : ({13'd0, fnum_q7} << fm_sh[3:0]);
	wire [35:0] pcm_num = {fnum_q7, 16'd0};
	wire  [4:0] pcm_sh  = 5'd18 - $unsigned(block_s[4:0]);        // 11 .. 26
	wire [35:0] pcm_shr  = pcm_num >> pcm_sh;
	wire [32:0] inc_pcm = pcm_shr[32:0];

	wire signed [32:0] inc_base = $signed(p_is_pcm ? inc_pcm : inc_fm);
	wire signed [32:0] det_term = p_is_pcm ? $signed({22'd0, det_r, 6'd0})
	                                       : $signed({16'd0, det_r, 12'd0});
	wire signed [32:0] inc_dt   = p_dt[2] ? (inc_base - det_term) : (inc_base + det_term);
	wire        [32:0] inc_cl   = inc_dt[32] ? 33'd0 : $unsigned(inc_dt);

	// MUL 0 means one half. The Fs divide happens on the full product, before
	// the 32-bit truncation, which is the order MAME uses and the order the
	// sweep checks.
	wire [32:0] inc_u    = $unsigned(inc_r);
	wire [36:0] inc_mul  = (p_multiple == 4'd0) ? {5'd0, inc_u[32:1]}
	                                            : ({4'd0, inc_u} * {33'd0, p_multiple});
	wire [36:0] inc_fsd  = p_is_pcm ? (inc_mul >> p_fs) : inc_mul;
	wire [31:0] step_c   = inc_fsd[31:0];

	// ---- operator ----------------------------------------------------------
	// 10-bit phase, folded into the quarter sine; waves 4 and 5 run at twice
	// the rate over the first half only. att = log-sin + 4*env, cut off at
	// 4096, resolved through the shared exponential.
	wire  [9:0] p10   = phase[31:22] + $unsigned(mod_in[9:0]);
	wire  [7:0] idx_n = p10[7:0] ^ {8{p10[8]}};
	wire  [7:0] idx_2 = {p10[6:0], 1'b0} ^ {8{p10[7]}};
	wire        w45   = (p_waveform == 3'd4) || (p_waveform == 3'd5);
	wire  [7:0] logsin_ra_c = w45 ? idx_2 : idx_n;
	wire        op_neg_c = ((p_waveform == 3'd0) || (p_waveform == 3'd1)) ? p10[9] :
	                       (p_waveform == 3'd4) ? p10[8] : 1'b0;
	wire        op_mute_c = ((p_waveform == 3'd3) || w45) && p10[9];

	wire [12:0] logsin_x = (p_waveform == 3'd1) ? {logsin_q, 1'b0} : {1'b0, logsin_q};
	wire [13:0] att_c    = {1'b0, logsin_x} + {2'd0, env, 2'b00};
	wire [12:0] exp_sh   = {exp_q, 2'b00};
	wire [12:0] op_mag   = exp_sh >> att_hi[3:0];
	wire signed [W_OUT-1:0] op_val =
		(op_mute || att_hi[5] || att_hi[4]) ? {W_OUT{1'b0}}
		: (op_neg ? -$signed({{(W_OUT-13){1'b0}}, op_mag})
		          :  $signed({{(W_OUT-13){1'b0}}, op_mag}));

	// ---- envelope multiply (PCM and the linear waveform) --------------------
	// (v * exp[(env & 63) << 2]) >> (11 + (env >> 6)); 64 attenuation units are
	// 6 dB, so the low six bits pick the mantissa and the top four the shift.
	wire signed [W_OUT+11:0] em_mul = env_mul_in * $signed({1'b0, exp_q});
	wire  [4:0] em_sh = 5'd11 + {1'b0, env[9:6]};
	wire signed [W_OUT+11:0] em_shr = em_mul >>> em_sh;
	wire signed [W_OUT-1:0]  em_val = em_shr[W_OUT-1:0];

	// waveform 6: no phase dependence at all. A DC level of half scale plus the
	// modulation input scaled by MUL, wrapped at 9 bits and stretched by 64 --
	// a hi-hat carrier emits its own modulator, up to 2.5x the range of every
	// other waveform. The PG keeps running underneath.
	wire signed [26:0] lin_mm = (p_multiple == 4'd0) ? {{4{mod_in[22]}}, mod_in[22:0]} >>> 1
	                                                 : mod_in * $signed({1'b0, p_multiple});
	wire signed [W_OUT-1:0] lin_c = $signed({4'd0, 14'd8192})
	                              + $signed({3'd0, lin_mm[8:0], 6'd0});

	// ---- external waveform -------------------------------------------------
	// Words are 8-bit (the upper byte of a 12-bit sample) or packed three
	// bytes to two words. Byte 0 of a pair is word0 bits 11..4, byte 1 is
	// word1 bits 3..0 in its high nibble and word0 bits 3..0 in its low, byte 2
	// is word1 bits 11..4.
	wire [23:0] pos3    = {1'b0, pcm_pos[22:1], 1'b0} + {2'b00, pcm_pos[22:1]};  // (pos>>1)*3
	wire [22:0] tri_a   = p_start + pos3[22:0];
	wire [22:0] base_c  = !p_bits12    ? (p_start + pcm_pos)
	                    : !pcm_pos[0]  ? tri_a
	                                   : (tri_a + 23'd1);
	// how far past the base the last needed byte sits
	wire  [1:0] span    = !p_bits12   ? 2'd1 : (!pcm_pos[0] ? 2'd2 : 2'd3);
	wire        need_b  = ({1'b0, fetch_base[2:0]} + {2'b00, span}) > 4'd7;

	wire [127:0] win = {line_b, line_a};
	wire  [3:0] wo   = {1'b0, fetch_base[2:0]};
	wire   [7:0] B0  = win[{wo,          3'b000} +: 8];
	wire   [7:0] B1  = win[{(wo + 4'd1), 3'b000} +: 8];
	wire   [7:0] B2  = win[{(wo + 4'd2), 3'b000} +: 8];
	wire   [7:0] B3  = win[{(wo + 4'd3), 3'b000} +: 8];

	wire [11:0] wordA_12 = pcm_pos[0] ? {B1, B0[7:4]} : {B0, B1[3:0]};
	wire [11:0] wordB_12 = pcm_pos[0] ? {B2, B3[3:0]} : {B2, B1[7:4]};
	wire signed [12:0] wordA = p_bits12 ? $signed({wordA_12[11], wordA_12})
	                                    : $signed({B0[7], B0, 4'd0});
	wire signed [12:0] wordB = p_bits12 ? $signed({wordB_12[11], wordB_12})
	                                    : $signed({B1[7], B1, 4'd0});

	wire  [8:0] frac8 = {1'b0, pcm_frac[15:8]};
	wire signed [22:0] ip_a = wordA * $signed({1'b0, 9'd256 - frac8});
	wire signed [22:0] ip_b = wordB * $signed({1'b0, frac8});
	wire signed [23:0] ip_s = {ip_a[22], ip_a} + {ip_b[22], ip_b};
	wire signed [13:0] pcm_c = ip_s[19:6];

	// ---- loop ---------------------------------------------------------------
	wire [39:0] adv      = {1'b0, pcm_pos, pcm_frac} + {8'd0, step_c};
	wire [22:0] adv_pos  = adv[38:16];
	wire        loop_ok  = (p_end > p_loop);
	wire [22:0] loop_len = p_end - p_loop;

	// ---- channel level ------------------------------------------------------
	// x * (1 or 0.75) >> (L >> 1), and L >= 13 is silence. The old core's
	// 16-entry linear attenuation table is gone with the linear gain domain.
	/* verilator lint_off UNUSEDSIGNAL */
	// t's top two bits exist only to carry the *3 before it is shifted back
	// down, so nothing ever reads them.
	function automatic signed [W_OUT-1:0] pan(input signed [W_OUT-1:0] v,
	                                          input [3:0] lvl);
		reg signed [W_OUT+1:0] t;
		begin
			// (v * 3) >> 2 is the 0.75 step; the shift is the coarse 6 dB one.
			// Two extra bits carry the *3 before it is shifted back down.
			t = (lvl[0] ? (($signed({{2{v[W_OUT-1]}}, v}) * 3) >>> 2)
			            :   $signed({{2{v[W_OUT-1]}}, v})) >>> lvl[3:1];
			pan = (lvl >= 4'd13) ? {W_OUT{1'b0}} : t[W_OUT-1:0];
		end
	endfunction
	/* verilator lint_on UNUSEDSIGNAL */

	wire signed [W_OUT-1:0] pan0 = pan(op_out, p_ch0);
	wire signed [W_OUT-1:0] pan1 = pan(op_out, p_ch1);
	wire signed [W_OUT-1:0] pan2 = pan(op_out, p_ch2);
	wire signed [W_OUT-1:0] pan3 = pan(op_out, p_ch3);

	// Attack multiplies the remaining headroom; every other phase adds.
	//
	// MAME writes this as `eg_att += ((~eg_att) * inc) >> 4` on a SIGNED
	// int32, where ~att is -(att+1) and the shift floors toward -infinity --
	// so the step is ceil((att+1) * inc / 16) subtracted, not
	// floor((1023 - att) * inc / 16) added. A ten-bit complement is a
	// different function and it stalls: at att = 0x3FF, ~att is 0, the step is
	// zero, and the envelope never leaves full attenuation.
	wire [10:0] att_p1   = {1'b0, eg_att} + 11'd1;      // 1 .. 1024
	wire [14:0] att_prod = att_p1 * {11'd0, eg_add};    // max 1024 * 8
	wire [14:0] att_ceil = att_prod + 15'd15;           // the ceiling of >> 4
	wire signed [11:0] att_atk = $signed({2'b00, eg_att})
	                           - $signed({1'b0, att_ceil[14:4]});
	wire [10:0] att_dec  = {1'b0, eg_att} + {7'd0, eg_add};

	// Key-on jumps straight to 0 dB when the attack rate is already maximal
	// (table 2-6-8: rate 63 is 0.07 ms). The attenuation otherwise continues
	// from wherever it was, which is the OPM convention.
	wire [6:0] kon_rate = {1'b0, p_ar, 1'b0} + {2'd0, rks_q};
	wire       kon_fast = (p_ar != 5'd0) && (kon_rate >= 7'd63);

	wire signed [W_OUT-1:0] env_mul_in = p_is_pcm
		? {{(W_OUT-14){pcm_out[13]}}, pcm_out}
		: lin_c;

	// Acc On: a running sum that saturates at the operator's own range, so any
	// sustained tone rails into a full-level square that flips at the
	// operator's zero crossings. Cleared at key-on and when the EG goes off.
	wire signed [W_OUT:0] acc_sum = {{(W_OUT-14){acc[14]}}, acc} + {op_out[W_OUT-1], op_out};
	wire signed [14:0] acc_sat = (acc_sum >  $signed({{(W_OUT-12){1'b0}}, 13'd8191}))
	                                ?  15'sd8191
	                           : (acc_sum < -$signed({{(W_OUT-13){1'b0}}, 14'd8192}))
	                                ? -15'sd8192 : acc_sum[14:0];

	// ------------------------------------------------------------------
	// Sequencer
	// ------------------------------------------------------------------
	localparam [5:0] S_IDLE  = 6'd0,
	                 S_LD0   = 6'd1,  S_LD1   = 6'd2,  S_LD2  = 6'd3,  S_LD3  = 6'd4,
	                 S_KEY   = 6'd5,  S_KC    = 6'd6,
	                 S_EGA   = 6'd7,  S_EGB   = 6'd8,
	                 S_GATE  = 6'd9,  S_ENV   = 6'd10,
	                 S_PM0   = 6'd11, S_PM1   = 6'd12,
	                 S_PH0   = 6'd13, S_PH1   = 6'd14,
	                 S_MOD   = 6'd15,
	                 S_OPA   = 6'd16, S_OPB   = 6'd17, S_OPC  = 6'd18,
	                 S_OPD   = 6'd19, S_OPE   = 6'd20,
	                 S_W6    = 6'd21,
	                 S_ADDR  = 6'd22, S_FEA0  = 6'd23, S_FEA1 = 6'd24,
	                 S_FEB0  = 6'd25, S_FEB1  = 6'd26,
	                 S_INTP  = 6'd27, S_EMUL  = 6'd28,
	                 S_LOOP  = 6'd29, S_LOOP2 = 6'd30, S_LOOP3 = 6'd31,
	                 S_ACC   = 6'd32, S_MIX   = 6'd33,
	                 S_NEXT  = 6'd34, S_OUT   = 6'd35,
	                 S_EXT   = 6'd36, S_CLR   = 6'd37, S_EGC = 6'd38;

	reg [5:0] state;
	reg [5:0] clr_cnt;
	reg [5:0] ext_ret;    // where S_EXT resumes: the pass must not lose its place
	reg [15:0] eg_cnt;
	reg        eg_phase, eg_clk;

	// One carrier at full level is +/-8192 against a full scale of 32768, so
	// the accumulators are already at output scale. The old core's >>2 is gone
	// with the linear gain domain.
	// Wide enough for the mono sum: eight 24-bit accumulators, not four.
	function automatic signed [15:0] outclip(input signed [26:0] a);
		outclip = (a >  27'sd32767) ?  16'sh7FFF :
		          (a < -27'sd32768) ? -16'sh8000 : a[15:0];
	endfunction

	// Mono sums every channel MAME routes, which is now all eight -- see the
	// note on `stereo` at the top. Stereo takes CH0 and CH1 and leaves the
	// EXT pins unmixed, exactly as spi() routes them.
	wire signed [26:0] acc_mono = {{3{acc_ch[0][23]}}, acc_ch[0]}
	                            + {{3{acc_ch[1][23]}}, acc_ch[1]}
	                            + {{3{acc_ch[2][23]}}, acc_ch[2]}
	                            + {{3{acc_ch[3][23]}}, acc_ch[3]}
	                            + {{3{acc_ch[4][23]}}, acc_ch[4]}
	                            + {{3{acc_ch[5][23]}}, acc_ch[5]}
	                            + {{3{acc_ch[6][23]}}, acc_ch[6]}
	                            + {{3{acc_ch[7][23]}}, acc_ch[7]};

	// The slot to prefetch: groups inside, banks outside.
	wire [3:0] ngroup = (group == 4'd11) ? 4'd0 : (group + 4'd1);
	wire [1:0] nbank  = (group == 4'd11) ? (bank + 2'd1) : bank;
	wire [5:0] nslot  = {1'b0, nbank, 3'b000} + {2'b00, nbank, 2'b00} + {2'b00, ngroup};
	wire       last_slot = (group == 4'd11) && (bank == 2'd3);

	wire [19:0] tag_c = fetch_base[22:3];
	wire        hit_a = line_va && (line_tag == tag_c);
	wire        hit_b = line_vb && (line_tag == tag_c);

	always @(posedge clk) begin
		end_set <= 1'b0;
		st_we   <= 1'b0;
		fb_we   <= 1'b0;
		or_we   <= 1'b0;
		cch_we  <= 1'b0;

		if (sample_tick) begin
			tick_pend <= 1'b1;
			if (tick_pend) dbg_overrun <= dbg_overrun + 16'd1;
		end

		case (state)

		// ------------------------------------------------------------
		// A pending sample tick always wins: the synthesis pass is what has a
		// deadline, the host's readback does not.
		S_IDLE: if (!tick_pend && (ext_req != ext_ack)) begin
			// Same masking as the sample path: the burst is 64-bit aligned and
			// the region is 2 MB, so the chip's 23-bit space mirrors inside it.
			// Real hardware has nothing above the ROM either; MAME reads 0
			// there because its region is ERASE00.
			sdr_addr <= SDR_PCM_BASE + {4'd0, ext_addr[20:3], 3'b000};
			sdr_req  <= ~sdr_req;
			ext_ret  <= S_IDLE;
			state    <= S_EXT;
		end
		else if (tick_pend) begin
			tick_pend  <= 1'b0;
			bank       <= 2'd0;
			group      <= 4'd0;
			for (i = 0; i < 8; i = i + 1) acc_ch[i] <= 24'sd0;
			active_cnt <= 16'd0;
			st_ra      <= 6'd0;
			fb_ra      <= 6'd0;
			cch_ra     <= 6'd0;
			par_ra     <= 8'd0;
			// The envelope runs at fs/2: one sample arms it, the next clocks it.
			eg_clk     <= eg_phase;
			eg_phase   <= ~eg_phase;
			if (eg_phase) eg_cnt <= eg_cnt + 16'd1;
			state      <= S_LD0;
		end

		// All four RAMs answer two cycles after their address register is
		// loaded, and the parameter reads are pipelined one per cycle.
		S_LD0: begin par_ra <= {slot, 2'd1}; state <= S_LD1; end
		S_LD1: begin
			w0        <= par_q;
			par_ra    <= {slot, 2'd2};
			phase     <= st_q[127:96];
			pcm_pos   <= st_q[95:73];
			pcm_frac  <= st_q[72:57];
			eg_att    <= st_q[56:47];
			eg_state  <= st_q[46:44];
			lfo_cnt   <= st_q[43:24];
			lfo_pos   <= st_q[23:17];
			pcm_ended <= st_q[16];
			acc       <= $signed(st_q[15:1]);
			// The tag comes out of the RAM, the valid bits out of the registers
			// beside it: a flash write clears every bit of cch_vld_a/b at once,
			// so a line cached before it can never be trusted again even though
			// its tag is still sitting in the RAM.
			line_tag  <= cch_tag_q;
			line_va   <= cch_vld_a[slot];
			line_vb   <= cch_vld_b[slot];
			line_a    <= cch_data_q[63:0];
			line_b    <= cch_data_q[127:64];
			state     <= S_LD2;
		end
		S_LD2: begin w1 <= par_q; par_ra <= {slot, 2'd3}; state <= S_LD3; end
		S_LD3: begin
			w2    <= par_q;
			fb0   <= $signed(fb_q[2*W_OUT-1:W_OUT]);
			fb1   <= $signed(fb_q[W_OUT-1:0]);
			state <= S_KEY;
		end

		// Word 3 is FM register 0. The group's algorithm is latched here off
		// its head slot -- bank 0, and bank 1 for the second pair of a sync-1
		// group -- which the pass always reaches before any slot that reads it.
		S_KEY: begin
			w3 <= par_q;
			if (bank == 2'd0) grp_alg[group]  <= p_alg;
			if (bank == 2'd1) grp_alg2[group] <= p_alg;
			state <= S_KC;
		end

		// Key on restarts the phase, the LFO and the sample pointer; key off
		// drops a sounding slot into release. Every KON=1 write retriggers,
		// edge or not -- P-47 Aces writes KON=1 onto already-keyed slots for
		// note repeats, and edge-triggering drops those notes.
		S_KC: begin
			det_r <= det_q;
			rks_r <= rks_q;
			if (keyon_pend[slot]) begin
				eg_state  <= EG_ATTACK;
				phase     <= 32'd0;
				if (kon_fast) eg_att <= 10'd0;
				lfo_cnt   <= 20'd0;
				lfo_pos   <= 7'd0;
				pcm_pos   <= 23'd0;
				pcm_frac  <= 16'd0;
				pcm_ended <= 1'b0;
				acc       <= 15'sd0;
			end
			else if (keyoff_pend[slot] && (eg_state != EG_OFF))
				eg_state <= EG_RELEASE;
			state <= S_EGA;
		end

		// Stage 1: the state transition and the rate, both downstream of eg_att.
		S_EGA: begin
			eg_state_pre_r <= eg_state_pre;
			eg_rate_r      <= eg_rate;
			eg_to_d1_r     <= eg_to_d1;
			state          <= S_EGB;
		end

		// Stage 2: the hold test and the sub-step index, both downstream of the
		// rate. The eg_inc read lands at the end of this cycle.
		S_EGB: begin
			eg_hold_r <= eg_hold;
			eg_idx_r  <= eg_idx;
			// The LFO advances every sample, whether or not the EG is clocked,
			// and whether or not the slot is sounding.
			if (lfo_on) begin
				if (lfo_wrap) begin
					lfo_cnt <= 20'd0;
					lfo_pos <= lfo_pos + 7'd1;
				end
				else lfo_cnt <= lfo_cnt + 20'd1;
			end
			state <= S_EGC;
		end

		// Stage 3: apply the increment.
		S_EGC: begin
			if (eg_clk && (eg_state != EG_OFF)) begin
				eg_state <= eg_state_pre_r;
				if (eg_to_d1_r) eg_att <= 10'd0;
				if (!eg_hold_r) begin
					if (eg_state_pre_r == EG_ATTACK) begin
						if (att_atk <= 12'sd0) begin
							eg_att   <= 10'd0;
							eg_state <= EG_DECAY1;
						end
						else eg_att <= att_atk[9:0];
					end
					else if (att_dec >= 11'd1023) begin
						eg_att <= 10'd1023;
						if (eg_state_pre_r == EG_RELEASE) eg_state <= EG_OFF;
					end
					else eg_att <= att_dec[9:0];
				end
			end
			state <= S_GATE;
		end

		S_GATE: begin
			if (eg_state == EG_OFF) begin
				op_out <= {W_OUT{1'b0}};
				acc    <= 15'sd0;
				state  <= S_MIX;      // stores zeros, mixes nothing
			end
			else begin
				active_cnt <= active_cnt + 16'd1;
				state      <= S_ENV;
			end
		end

		S_ENV: begin
			env    <= env_c;
			exp_ra <= {env_c[5:0], 2'b00};    // env_mul's mantissa
			state  <= S_PM0;
		end

		S_PM0: begin pm_mul_r <= pm_t1;  state <= S_PM1; end
		S_PM1: begin fnum_q7  <= fnum_c; state <= S_PH0; end
		S_PH0: begin inc_r    <= $signed(inc_cl); state <= S_PH1; end
		S_PH1: begin
			step  <= step_c;
			state <= p_is_pcm ? S_ADDR : S_MOD;
		end

		// ------------------------------------------------------------
		// FM operator: modulation in, waveform out. Two DEPENDENT ROM reads --
		// the exponential is addressed with the sum of the log-sin and the
		// envelope -- so they cannot share a stage.
		S_MOD: begin
			mod_in <= mod_c;
			state  <= p_silent ? S_ACC : (p_is_lin ? S_W6 : S_OPA);
			if (p_silent) op_out <= {W_OUT{1'b0}};
		end

		S_OPA: begin
			logsin_ra <= logsin_ra_c;
			op_neg    <= op_neg_c;
			op_mute   <= op_mute_c;
			phase     <= phase + step;
			state     <= S_OPB;
		end
		S_OPB: state <= S_OPC;                    // log-sin lands at the end
		S_OPC: begin
			att_hi <= att_c[13:8];
			exp_ra <= att_c[7:0];
			state  <= S_OPD;
		end
		S_OPD: state <= S_OPE;                    // exp lands at the end
		S_OPE: begin op_out <= op_val; state <= S_ACC; end

		// Waveform 6 does not read the phase at all, but the PG keeps running
		// underneath it.
		S_W6: begin
			op_out <= em_val;
			phase  <= phase + step;
			state  <= S_ACC;
		end

		// ------------------------------------------------------------
		// External waveform. Interpolation needs the word at the read position
		// and the one after it, which is up to four consecutive bytes; line A
		// is the tag's own and line B the one above, so any alignment is
		// covered by at most two fetches.
		S_ADDR: begin
			fetch_base <= base_c;
			state      <= S_FEA0;
		end

		S_FEA0: begin
			if (hit_a) state <= S_FEB0;
			else begin
				sdr_addr <= SDR_PCM_BASE + {4'd0, fetch_base[20:3], 3'b000};
				sdr_req  <= ~sdr_req;
				state    <= S_FEA1;
			end
		end
		S_FEA1: if (sdr_ack == sdr_req) begin
			line_a   <= sdr_dout;
			line_tag <= tag_c;
			line_va  <= 1'b1;
			line_vb  <= 1'b0;          // the pair moved; B is stale
			state    <= S_FEB0;
		end

		S_FEB0: begin
			if (!need_b || hit_b) state <= S_INTP;
			else begin
				sdr_addr <= SDR_PCM_BASE + {4'd0, fetch_base[20:3], 3'b000} + 26'd8;
				sdr_req  <= ~sdr_req;
				state    <= S_FEB1;
			end
		end
		S_FEB1: if (sdr_ack == sdr_req) begin
			line_b  <= sdr_dout;
			line_vb <= 1'b1;
			state   <= S_INTP;
		end

		S_INTP: begin pcm_out <= pcm_c; state <= S_EMUL; end
		S_EMUL: begin op_out  <= em_val; state <= S_LOOP; end

		// The output comes from the CURRENT position; only then does the
		// pointer advance. Positions run over [0, End): reaching End wraps back
		// by End-Loop, so a looped sample's period is exactly End-Loop words
		// and word End is only ever read as End-1's interpolation partner.
		S_LOOP: begin
			pcm_frac <= adv[15:0];
			if (adv_pos >= p_end) begin
				// End is raised once per key-on, not once per pass. Drivers play
				// one-shot samples as a short silent loop and free the channel
				// from a copy of the status register; re-raising it would kill a
				// note re-triggered between the copy and the free pass.
				if (!pcm_ended) begin
					pcm_ended <= 1'b1;
					end_set   <= 1'b1;
					end_slot  <= slot;
				end
				if (!loop_ok) begin
					pcm_pos <= p_loop;
					state   <= S_ACC;
				end
				else begin
					pcm_pos <= adv_pos - loop_len;
					state   <= S_LOOP2;
				end
			end
			else begin
				pcm_pos <= adv_pos;
				state   <= S_ACC;
			end
		end
		// A step long enough to clear the whole loop can still land past the
		// end after one fold, so the subtraction repeats; three passes is more
		// than any reachable step needs, and the last one gives up at Loop.
		S_LOOP2: begin
			if (pcm_pos >= p_end) begin
				pcm_pos <= pcm_pos - loop_len;
				state   <= S_LOOP3;
			end
			else state <= S_ACC;
		end
		S_LOOP3: begin
			if (pcm_pos >= p_end) pcm_pos <= p_loop;
			state <= S_ACC;
		end

		// ------------------------------------------------------------
		S_ACC: begin
			if (p_accon) begin
				acc    <= acc_sat;
				op_out <= {{(W_OUT-15){acc_sat[14]}}, acc_sat};
			end
			state <= S_MIX;
		end

		// Mix, publish the output, write the feedback history and store the
		// slot's state -- all independent, so one cycle.
		S_MIX: begin
			or_wa <= slot;
			or_wd <= op_out;
			or_we <= 1'b1;

			if (is_carrier) begin
				acc_ch[0] <= acc_ch[0] + {{6{pan0[W_OUT-1]}}, pan0};
				acc_ch[1] <= acc_ch[1] + {{6{pan1[W_OUT-1]}}, pan1};
				acc_ch[2] <= acc_ch[2] + {{6{pan2[W_OUT-1]}}, pan2};
				acc_ch[3] <= acc_ch[3] + {{6{pan3[W_OUT-1]}}, pan3};
				// EXT1 = CH4/5, EXT2 = CH6/7. EN enables them and EXT Out is a
				// bitmask of which they reach, at full level -- there is no
				// attenuation register on these pins.
				if (p_exten) begin
					if (p_extout[0]) acc_ch[4] <= acc_ch[4] + {{6{op_out[W_OUT-1]}}, op_out};
					if (p_extout[1]) acc_ch[5] <= acc_ch[5] + {{6{op_out[W_OUT-1]}}, op_out};
					if (p_extout[2]) acc_ch[6] <= acc_ch[6] + {{6{op_out[W_OUT-1]}}, op_out};
					if (p_extout[3]) acc_ch[7] <= acc_ch[7] + {{6{op_out[W_OUT-1]}}, op_out};
				end
			end

			// The feedback history belongs to the network's head; the slot that
			// writes it is the head itself, or S3 for the loop algorithms.
			//
			// A slot in EG_OFF writes nothing: MAME's `continue` skips the
			// history update along with the output, so a released operator
			// leaves the head's loop holding its last real samples rather than
			// pushing zeros through it.
			// The head shifts its own pair; a separate source only hands over
			// its output. A slot in EG_OFF hands over nothing: MAME's
			// `continue` skips the history update along with the output.
			if (is_fbhead && (eg_state != EG_OFF)) begin
				fb_wa <= slot;
				fb_wd <= {$unsigned(op_out), $unsigned(fb_h0)};
				fb_we <= 1'b1;
			end
			if (is_fbsrc && !is_fbhead && (eg_state != EG_OFF))
				fb_pend[fb_pidx] <= op_out;

			st_wa <= slot;
			st_wd <= {phase, pcm_pos, pcm_frac, eg_att, eg_state, lfo_cnt,
			          lfo_pos, pcm_ended, $unsigned(acc), 1'b0};
			st_we <= 1'b1;

			cch_wa      <= slot;
			cch_tag_wd  <= line_tag;
			cch_data_wd <= {line_b, line_a};
			cch_we      <= 1'b1;
			cch_vld_a[slot] <= line_va;
			cch_vld_b[slot] <= line_vb;

			state <= S_NEXT;
		end

		// A slot boundary is the other safe place to serve the host: no sample
		// fetch is outstanding and the line pair is not mid-use. Servicing only
		// from S_IDLE was not enough -- under polyphony the pass occupies most
		// of a sample period, while a Z80 `in` is about 88 clk_sys cycles, so
		// back-to-back reads outran the refill and returned a stale latch.
		// Here the host gets an opening every slot, ~24 cycles.
		S_NEXT: begin
			keyon_pend[slot]  <= 1'b0;
			keyoff_pend[slot] <= 1'b0;
			// Sample memory changed since the last slot: drop every cached line
			// at once, and the live pair with it. Safe here and nowhere cheaper
			// -- this is the same point the host read is served from, chosen for
			// the same reason.
			if (mem_dirty != dirty_ack) begin
				dirty_ack <= mem_dirty;
				cch_vld_a <= 48'd0;
				cch_vld_b <= 48'd0;
				line_va   <= 1'b0;
				line_vb   <= 1'b0;
			end
			if (last_slot) begin
				if (ext_req != ext_ack) begin
					sdr_addr <= SDR_PCM_BASE + {4'd0, ext_addr[20:3], 3'b000};
					sdr_req  <= ~sdr_req;
					ext_ret  <= S_OUT;
					state    <= S_EXT;
				end
				else state <= S_OUT;
			end
			else begin
				bank   <= nbank;
				group  <= ngroup;
				st_ra  <= nslot;
				fb_ra  <= nslot;
				cch_ra <= nslot;
				par_ra <= {nslot, 2'd0};
				if (ext_req != ext_ack) begin
					sdr_addr <= SDR_PCM_BASE + {4'd0, ext_addr[20:3], 3'b000};
					sdr_req  <= ~sdr_req;
					ext_ret  <= S_LD0;
					state    <= S_EXT;
				end
				else state <= S_LD0;
			end
		end

		// Host readback. Deliberately does not touch line_a / line_b / line_tag:
		// that pair belongs to whichever slot is mid-note, and evicting it here
		// would cost that slot a refetch for a transfer the synthesis path
		// never asked for.
		S_EXT: if (sdr_ack == sdr_req) begin
			ext_data <= sdr_dout[{ext_addr[2:0], 3'b000} +: 8];
			ext_ack  <= ext_req;
			state    <= ext_ret;
		end

		// Reset silences the chip, which means walking the slot RAM: a RAM
		// cannot be cleared in a cycle, and leaving it alone would carry every
		// sounding note across a reset. MAME's device_reset() puts all 48 slots
		// in EG_OFF, and a core that did not would come out of reset playing
		// whatever it was playing when it went in.
		S_CLR: begin
			st_wa  <= clr_cnt;
			st_wd  <= ST_INIT;
			st_we  <= 1'b1;
			or_wa  <= clr_cnt;
			or_wd  <= {W_OUT{1'b0}};
			or_we  <= 1'b1;
			fb_wa  <= clr_cnt;
			fb_wd  <= {(2*W_OUT){1'b0}};
			fb_we  <= 1'b1;
			if (clr_cnt < 6'd24) fb_pend[clr_cnt[4:0]] <= {W_OUT{1'b0}};
			if (clr_cnt == 6'd47) state <= S_IDLE;
			else clr_cnt <= clr_cnt + 6'd1;
		end

		S_OUT: begin
			audio_l    <= stereo ? outclip({{3{acc_ch[0][23]}}, acc_ch[0]})
			                     : outclip(acc_mono);
			audio_r    <= stereo ? outclip({{3{acc_ch[1][23]}}, acc_ch[1]})
			                     : outclip(acc_mono);
			dbg_active <= active_cnt;
			state      <= S_IDLE;
		end

		default: state <= S_IDLE;
		endcase

		// A key event arriving in the same cycle the pass clears the slot's
		// flag has to win, or the note is lost; hence after the case.
		// The savestate owns these outright, read and written in this file's own
		// section; the register-file side is frozen, so nothing competes.
		if (ss_key_wr) begin
			if (ss_st_word == 2'd0) keyon_pend[31:0]   <= ssbus_st.data[31:0];
			if (ss_st_word == 2'd1) keyon_pend[47:32]  <= ssbus_st.data[15:0];
			if (ss_st_word == 2'd2) keyoff_pend[31:0]  <= ssbus_st.data[31:0];
			if (ss_st_word == 2'd3) keyoff_pend[47:32] <= ssbus_st.data[15:0];
		end
		if (key_on)  keyon_pend[key_slot]  <= 1'b1;
		if (key_off) keyoff_pend[key_slot] <= 1'b1;

		// The feedback history lands in fb_mem through its own write port; the
		// slot outputs and the hand-off file are flops, so they are written
		// here. Items 96..119 of the section are the hand-off file.
		if (ss_fb_acc && ssbus_fb.write && (ss_fb_idx >= 32'd96))
			fb_pend[ss_fb_idx[4:0]] <= $signed(ssbus_fb.data[W_OUT-1:0]);

		if (reset) begin
			state       <= S_CLR;
			clr_cnt     <= 6'd0;
			sdr_req     <= 1'b0;
			ext_ack     <= 1'b0;
			ext_data    <= 8'd0;
			tick_pend   <= 1'b0;
			audio_l     <= 16'd0;
			audio_r     <= 16'd0;
			for (i = 0; i < 8; i = i + 1) acc_ch[i] <= 24'sd0;
			keyon_pend  <= 48'd0;
			keyoff_pend <= 48'd0;
			dbg_overrun <= 16'd0;
			dbg_active  <= 16'd0;
			active_cnt  <= 16'd0;
			bank        <= 2'd0;
			group       <= 4'd0;
			end_set     <= 1'b0;
			st_we       <= 1'b0;
			fb_we       <= 1'b0;
			cch_we      <= 1'b0;
			cch_vld_a   <= 48'd0;
			cch_vld_b   <= 48'd0;
			dirty_ack   <= 1'b0;
			line_va     <= 1'b0;
			line_vb     <= 1'b0;
			eg_cnt      <= 16'd0;
			eg_phase    <= 1'b0;
			eg_clk      <= 1'b0;
		end
	end

	// Fields one path or the other does not use, and the low halves of products
	// the scaling deliberately discards.
	/* verilator lint_off UNUSEDSIGNAL */
	wire _unused = &{1'b0, w0, w1, w2, w3, pm_t1, pm_t2, mod_mul, in_sum,
	                 inc_fm, inc_pcm, inc_dt, inc_mul, inc_fsd, pcm_num,
	                 em_mul, lin_mm, ip_a, ip_b, ip_s, acc_sum, att_prod,
	                 att_atk, att_dec, att_ceil, adv, pos3, fm_nsh, exp_sh, op_mag,
	                 logsin_x, att_c, kc_ext, lfo_per, eg_mask, env_sum,
	                 eg_cnt_sh, pcm_shr, em_shr, lp_m32, lp_m96, alg_b, B3,
	                 // ext_addr is the chip's full 23-bit space; the sample
	                 // region is 2 MB, so [20:0] addresses all of it -- both
	                 // flash chips included, since chip 1 is just bit 20 -- and
	                 // the top two bits mirror rather than reach anything.
	                 ext_addr[22:21]};
	/* verilator lint_on UNUSEDSIGNAL */

	initial begin
		for (i = 0; i < 48; i = i + 1) begin
			st_mem[i]   = ST_INIT;
			cch_tag[i]  = 20'd0;
			cch_data[i] = 128'd0;
			out_mem0[i] = {W_OUT{1'b0}};
			out_mem1[i] = {W_OUT{1'b0}};
			out_mem2[i] = {W_OUT{1'b0}};
			out_mem3[i] = {W_OUT{1'b0}};
			fb_mem[i]   = {(2*W_OUT){1'b0}};
		end
		for (i = 0; i < 12; i = i + 1) begin
			grp_alg[i]  = 4'd0;
			grp_alg2[i] = 4'd0;
		end
		for (i = 0; i < 24; i = i + 1) fb_pend[i] = {W_OUT{1'b0}};
	end

endmodule
