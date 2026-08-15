//============================================================================
//  SlopperPI - YMF271 "OPX" synthesis engine
//
//  MAME's sound_stream_update / calculate_op / update_pcm / update_envelope /
//  calculate_slot_volume (ymf271.cpp), re-expressed as one serial pass over
//  12 groups x 4 slots per 44100 Hz sample.
//
//  The chip's 48 slots are organised as 12 groups of 4, and each group's `sync`
//  field picks what its four slots are:
//
//    sync 0   4-operator FM, one of 16 algorithms
//    sync 1   two independent 2-operator FM pairs
//    sync 2   3-operator FM, plus slot 4 as a PCM voice
//    sync 3   four PCM voices
//
//  In every mode MAME evaluates the operators in the order slot1, slot3, slot2,
//  slot4 -- banks 0, 2, 1, 3 -- which is why this walks the banks in that order
//  unconditionally and lets the algorithm table sort out the wiring.
//
//  ONE DELIBERATE DIVERGENCE FROM MAME. In sync 0 MAME evaluates slot 4 as an
//  FM operator AND then calls update_pcm() on it, advancing its phase pointer
//  twice per sample. That only avoids tripping its own fatalerror because a
//  waveform of 7 makes the operator output zero. Here slot 4 is one or the
//  other: PCM when its waveform is 7, an FM operator otherwise. The audible
//  result is the same except that the PCM voice plays at the right pitch.
//
//  Timing: clk_sys / 44100 = 1298 cycles a sample. An FM operator costs 22
//  cycles, a PCM voice 24 with a cache hit, and an idle slot 8. Only twelve
//  slots can be PCM at all (see PLAN.md 15.5), so the true worst case is
//  12 x 24 + 36 x 22 = 1080 plus a handful of cache misses. `dbg_overrun`
//  counts the samples the pass could not finish, so the budget is measured
//  rather than assumed.
//
//  Those cycle counts are mostly pipelining, not work: the first version put
//  the whole FM output chain -- feedback level, a multiply, the phase add, a
//  waveform ROM lookup and a second multiply -- between one pair of flops, and
//  missed clk_sys setup by 2.2 ns. No stage now holds more than one ROM read
//  or one multiply.
//============================================================================

module ymf271_synth
(
	input                clk,
	input                reset,

	// The cartridge board wires chip output 0 to the left speaker and 1 to the
	// right (MAME's spi(): add_route(0,"speaker",1.0,0) and (1,...,1)); the
	// single board sums all four into one (sxx2e(): ALL_OUTPUTS -> "mono").
	// Outputs 2 and 3 reach no speaker at all on the cartridge, and MAME's own
	// commented-out routes ask whether the hardware uses them.
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
	output reg           end_set,      // pulse: slot `end_slot` hit its loop point
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

	localparam [1:0] ENV_ATTACK  = 2'd0;
	localparam [1:0] ENV_DECAY1  = 2'd1;
	localparam [1:0] ENV_DECAY2  = 2'd2;
	localparam [1:0] ENV_RELEASE = 2'd3;

	integer i;

	// ------------------------------------------------------------------
	// Slot parameter RAM: 3 x 64 bit words per slot, byte writable.
	// The byte layout is documented in ymf271.sv, which owns the decode.
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

	genvar b;
	generate
		for (b = 0; b < 8; b = b + 1) begin : par_lane
			reg [7:0] mem [0:255];
			reg [7:0] q;
			always @(posedge clk) begin
				if (par_we && (par_byte == b[2:0])) mem[par_addr] <= par_data;
				q <= mem[par_ra];
			end
			assign par_q[b*8 +: 8] = q;
			initial for (int j = 0; j < 256; j = j + 1) mem[j] = 8'd0;
		end
	endgenerate

	// ------------------------------------------------------------------
	// Per-slot dynamic state, feedback state and sample-line cache.
	// ------------------------------------------------------------------
	// {stepptr[39:0], volume[26:0], env_state[1:0], active, lfo_phase[25:0]}
	reg [95:0] st_mem [0:47];
	reg  [5:0] st_ra, st_wa;
	reg [95:0] st_q, st_wd;
	reg        st_we;

	always @(posedge clk) begin
		if (st_we) st_mem[st_wa] <= st_wd;
		st_q <= st_mem[st_ra];
	end

	// {feedback_modulation0, feedback_modulation1}, only meaningful for the
	// slot acting as operator 1 of a network.
	reg [53:0] fb_mem [0:47];
	reg  [5:0] fb_ra, fb_wa;
	reg [53:0] fb_q, fb_wd;
	reg        fb_we;

	always @(posedge clk) begin
		if (fb_we) fb_mem[fb_wa] <= fb_wd;
		fb_q <= fb_mem[fb_ra];
	end

	// {valid, tag[19:0]} plus the eight bytes the line holds. The tags live in
	// this RAM; the VALID bits live in a plain register outside it, because a
	// flash write has to retire all 49 cached copies at once -- this line plus
	// one per slot, restored when that slot comes round again -- and a RAM
	// cannot be cleared in a cycle. See cch_vld.
	reg [20:0] cch_tv   [0:47];
	reg [63:0] cch_data [0:47];
	reg  [5:0] cch_ra, cch_wa;
	reg [20:0] cch_tv_q, cch_tv_wd;
	reg [63:0] cch_data_q, cch_data_wd;
	reg        cch_we;

	always @(posedge clk) begin
		if (cch_we) begin
			cch_tv[cch_wa]   <= cch_tv_wd;
			cch_data[cch_wa] <= cch_data_wd;
		end
		cch_tv_q   <= cch_tv[cch_ra];
		cch_data_q <= cch_data[cch_ra];
	end

	// ------------------------------------------------------------------
	// Working registers
	// ------------------------------------------------------------------
	reg [47:0] keyon_pend, keyoff_pend;
	reg        tick_pend;

	reg  [3:0] group;
	reg  [1:0] step;
	reg [63:0] w0, w1, w2;

	reg [39:0] stepptr;
	reg signed [26:0] volume;
	reg  [1:0] env_state;
	reg        active;
	reg [25:0] lfo_phase;

	reg signed [26:0] fb0, fb1;

	reg [20:0] line_tv;
	reg [63:0] line_data;

	// One valid bit per slot, outside the tag RAM so that a flash write can
	// clear all 48 in one cycle. A generation NUMBER was tried first and is
	// wrong: two writes flip a one-bit generation back to where it started and
	// bring a stale line back to life, which the cache test caught as a single
	// wrong byte out of five. Any width only makes that rarer, and an erase
	// sweep writes often enough to reach it.
	reg [47:0] cch_vld;
	reg        dirty_ack;

	// One accumulator per speaker. In mono the left one carries chip outputs
	// 0 and 2 and the right one 1 and 3, so their SUM is the four-output mix
	// the single board makes -- bit for bit what a single accumulator produced
	// before, since (g0+g2)+(g1+g3) is the same addition in a different order.
	reg signed [27:0] acc_l, acc_r;
	reg signed [15:0] sample;
	reg  [7:0] byte_lo;

	reg [31:0] step_r;
	reg [16:0] env_gain;
	reg [17:0] slot_gain;
	reg [19:0] cvsum_l, cvsum_r;
	reg [17:0] lfo_vol;

	// Pipeline registers. Everything the FM half added was originally one
	// enormous combinational chain -- feedback level, a multiply, the phase
	// add, a waveform ROM lookup and a second multiply, all between two flops.
	// That missed clk_sys setup by 2.2 ns. Each of these breaks the chain so
	// that no cycle holds more than one ROM read or one multiply.
	reg  [7:0] lfo_idx_r;
	reg signed [8:0] plfo_w_r;
	reg [16:0] alfo_r;
	reg [32:0] amul_r;
	reg [17:0] plfo_r;
	reg [16:0] num_r;
	reg [31:0] base_r;
	reg [16:0] env_raw;
	reg [16:0] tl_r;
	reg [12:0] wave_ra;
	reg [15:0] wave_q;

	always @(posedge clk) wave_q <= YMF_WAVE[wave_ra];

	reg        fetch_second;
	reg [22:0] fetch_addr;
	reg [15:0] active_cnt;

	// FM network state, live for the duration of one network
	reg signed [17:0] r1, r3, r2;
	reg signed [17:0] op_out;
	reg  [3:0] net_alg;
	reg        net_active;
	reg  [2:0] net_fbk;    // operator 1's feedback field, for set_feedback()

	wire [1:0] sync = grp_sync_flat[{group, 1'b0} +: 2];

	// Bank order is always 1, 3, 2, 4 -> 0, 2, 1, 3.
	wire [1:0] bank = (step == 2'd0) ? 2'd0 : (step == 2'd1) ? 2'd2 :
	                  (step == 2'd2) ? 2'd1 : 2'd3;
	// slot = bank * 12 + group
	wire [5:0] slot = {1'b0, bank, 3'b000} + {2'b00, bank, 2'b00} + {2'b00, group};

	// ---- parameter field views -------------------------------------------
	wire  [3:0] p_multiple   = w0[3:0];
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
	wire  [3:0] p_ch0        = w1[15:12];
	wire  [3:0] p_ch1        = w1[11:8];
	wire  [3:0] p_ch2        = w1[23:20];
	wire  [3:0] p_ch3        = w1[19:16];
	wire [22:0] p_start      = {w1[46:40], w1[39:32], w1[31:24]};
	wire [22:0] p_end        = {w2[6:0],   w1[63:56], w1[55:48]};
	wire [22:0] p_loop       = {w2[30:24], w2[23:16], w2[15:8]};
	wire  [1:0] p_fs         = w2[33:32];
	wire        p_bits12     = w2[34];
	wire  [7:0] p_lfofreq    = w2[47:40];
	wire  [1:0] p_lfowave    = w2[49:48];
	wire  [2:0] p_pms        = w2[53:51];
	wire  [1:0] p_ams        = w2[55:54];
	wire  [3:0] p_alg        = w2[59:56];

	wire p_is_pcm = (p_waveform == 3'd7);

	// ---- LFO --------------------------------------------------------------
	// update_lfo() advances the phase first, then indexes both tables with the
	// new value, so everything here uses lfo_next.
	//
	// 26 bits: an 8 bit index into the 256-entry shapes over 18 fractional
	// bits. MAME keeps only 8 fractional bits, which truncates the step to
	// zero for the 161 slowest of the 256 settings -- everything below 0.673
	// Hz, where Table 2-6-2 goes down to 0.00066 Hz. Those slots do not lose
	// their LFO quietly: a stalled phase sits at index 0, the peak of all
	// three amplitude shapes, so they get a fixed attenuation instead of a
	// sweep. Ten more fractional bits is the least that keeps setting 0 above
	// zero, and costs ten bits a slot in st_mem.
	wire [25:0] lfo_next = lfo_phase + {6'd0, YMF_LFO_STEP[p_lfofreq]};

	// m_lut_alfo: silence, falling ramp, square, triangle -- all cheap enough
	// to build from the phase rather than store.
	wire [16:0] alfo_tri = {1'b0, lfo_idx_r[6:0], 9'd0};
	wire [16:0] alfo =
		(p_lfowave == 2'd0) ? 17'd0 :
		(p_lfowave == 2'd1) ? (17'd65536 - {1'b0, lfo_idx_r, 8'd0}) :
		(p_lfowave == 2'd2) ? (lfo_idx_r[7] ? 17'd0 : 17'd65536) :
		                      (lfo_idx_r[7] ? alfo_tri : (17'd65536 - alfo_tri));

	// calculate_slot_volume()'s tremolo, with one correction: alfo peaks at
	// 65536, so the constant here is the SWING and 65536 minus it is the gain
	// at full modulation. MAME uses the gains themselves -- 65536/10^(dB/20)
	// for Table 2-6-3's 5.90625, 11.8125 and 23.625 dB -- which lands the gain
	// at 65536-K instead, giving 6.1, 2.6 and 0.6 dB: the deepest ams setting
	// comes out the shallowest. YMF_ALFO_K holds the complements.
	wire [32:0] alfo_scaled = alfo_r * YMF_ALFO_K[p_ams];
	wire [17:0] lfo_vol_c   = 18'd65536 - {2'd0, amul_r[31:16]};

	// m_lut_plfo, split into the pitch shape and the exponential so the stored
	// product is 7 x 257 entries instead of 4 x 8 x 256.
	wire signed [8:0] plfo_q  = $signed(YMF_PLFO_W[{p_lfowave, lfo_idx_r}]);
	wire        [8:0] plfo_i  = plfo_w_r + 9'sd128;
	wire        [2:0] pms_m1  = p_pms - 3'd1;
	// index = (pms - 1) * 257 + (q + 128)
	wire       [11:0] plfo_base = {1'b0, pms_m1, 8'd0} + {9'd0, pms_m1};
	wire       [11:0] plfo_addr = plfo_base + {3'd0, plfo_i};
	wire       [17:0] plfo_c  = (p_pms == 3'd0) ? 18'd65536
	                                            : YMF_PLFO[plfo_addr[10:0]];

	// ---- phase step -------------------------------------------------------
	//
	// Every factor MAME writes as a double is a power of two or a half integer,
	// so the base collapses to one multiply and a signed shift; the LFO factor
	// goes on top. pow_table is 2^(block+7) below block 8, 2^(block-9) above.
	//   PCM: st = (fns|2048) * (multiple*2) * 2^pow * plfo / 2^(3+fs)
	//   FM:  st =  fns       * (multiple*2) * 2^pow * plfo / 8
	wire [11:0] fns_ext  = p_is_pcm ? (p_fns | 12'h800) : p_fns;
	wire  [4:0] mult2    = (p_multiple == 4'd0) ? 5'd1 : {p_multiple, 1'b0};
	wire [16:0] step_num = fns_ext * mult2;      // registered into num_r

	wire signed [7:0] blk_s   = $signed({4'b0000, p_block});
	wire signed [7:0] pow_sh  = p_block[3] ? (blk_s - 8'sd9) : (blk_s + 8'sd7);
	wire signed [7:0] fs_term = p_is_pcm ? $signed({6'b000000, p_fs}) : 8'sd0;
	wire signed [7:0] step_sh = pow_sh - 8'sd3 - fs_term;
	wire signed [7:0] step_nsh = -step_sh;
	wire [31:0] step_base = (step_sh >= 0) ? ({15'd0, num_r} <<  step_sh[4:0])
	                                       : ({15'd0, num_r} >> step_nsh[4:0]);
	// plfo_c, not a registered copy: step_calc is sampled into step_r in the
	// same cycle the LFO is evaluated, so reading a register here would apply
	// the pitch shift a sample late -- and, on the first sample of a note, use
	// whatever the previously processed slot had left behind.
	// plfo is exactly 65536 when pms is 0, so the no-LFO case is bit-unchanged.
	wire [49:0] step_mul  = base_r * plfo_r;
	wire [31:0] step_calc = step_mul[47:16];

	// ---- envelope rates (init_envelope) -----------------------------------
	wire [10:0] fns_lo  = p_fns[10:0];
	wire  [1:0] n43_ext = (fns_lo < 11'h100) ? 2'd0 :
	                      (fns_lo < 11'h300) ? 2'd1 :
	                      (fns_lo < 11'h500) ? 2'd2 : 2'd3;
	wire  [1:0] n43_int = (p_fns < 12'h780) ? 2'd0 :
	                      (p_fns < 12'h900) ? 2'd1 :
	                      (p_fns < 12'hA80) ? 2'd2 : 2'd3;
	wire  [4:0] keycode = {p_block[2:0], p_is_pcm ? n43_ext : n43_int};
	wire  [4:0] rks     = YMF_RKS[{keycode, p_keyscale}];

	function [5:0] ks_rate(input [6:0] base, input [4:0] adj);
		reg [7:0] sum;
		begin
			sum = {1'b0, base} + {3'd0, adj};
			ks_rate = (sum > 8'd63) ? 6'd63 : sum[5:0];
		end
	endfunction

	wire [5:0] r_ar  = ks_rate({1'b0, p_ar,        1'b0},  rks);   // ar * 2
	wire [5:0] r_d1  = ks_rate({1'b0, p_dec1rate,  1'b0},  rks);
	wire [5:0] r_d2  = ks_rate({1'b0, p_dec2rate,  1'b0},  rks);
	wire [5:0] r_rel = ks_rate({1'b0, p_relrate,   2'b00}, rks);   // relrate * 4

	wire [23:0] attack_step  = YMF_AR_STEP[r_ar];
	wire [23:0] decay2_step  = YMF_DC_STEP[r_d2];
	wire [23:0] release_step = YMF_DC_STEP[r_rel];
	// decay1 sweeps decay1lvl*16 rather than the full 255, so it is the one
	// step that scales instead of reading straight out of a table.
	wire [31:0] d1_mul       = {4'd0, p_dec1lvl, 4'b0000} * YMF_DC_RECIP[r_d1];
	wire [23:0] decay1_step  = d1_mul[31:8];
	wire  [7:0] decay_level  = 8'd255 - {p_dec1lvl, 4'b0000};

	wire signed [27:0] v_att = {volume[26], volume} + $signed({4'd0, attack_step});
	wire signed [27:0] v_d1  = {volume[26], volume} - $signed({4'd0, decay1_step});
	wire signed [27:0] v_d2  = {volume[26], volume} - $signed({4'd0, decay2_step});
	wire signed [27:0] v_rel = {volume[26], volume} - $signed({4'd0, release_step});

	// ---- volume chain (calculate_slot_volume) -----------------------------
	wire  [7:0] vol8     = volume[26] ? 8'd0 : volume[23:16];
	wire [34:0] gain_lfo = env_raw * lfo_vol;
	wire [33:0] gain_tl  = env_gain * tl_r;
	wire [34:0] g0       = slot_gain * YMF_ATTEN[p_ch0];
	wire [34:0] g1       = slot_gain * YMF_ATTEN[p_ch1];
	wire [34:0] g2       = slot_gain * YMF_ATTEN[p_ch2];
	wire [34:0] g3       = slot_gain * YMF_ATTEN[p_ch3];

	/* verilator lint_off UNUSEDSIGNAL */
	function [17:0] chclip(input [34:0] g);
		chclip = (g[34:16] > 19'd65536) ? 18'd65536 : g[33:16];
	endfunction
	/* verilator lint_on UNUSEDSIGNAL */

	// An FM operator folds its envelope into its own output and MAME applies no
	// channel clamp there, so its mix is a plain sum of the attenuations.
	wire [19:0] fm_cvsum_l = {3'd0, YMF_ATTEN[p_ch0]}
	                       + (stereo ? 20'd0 : {3'd0, YMF_ATTEN[p_ch2]});
	wire [19:0] fm_cvsum_r = {3'd0, YMF_ATTEN[p_ch1]}
	                       + (stereo ? 20'd0 : {3'd0, YMF_ATTEN[p_ch3]});

	wire signed [36:0] mix_pcm_l = $signed(sample) * $signed({1'b0, cvsum_l});
	wire signed [36:0] mix_pcm_r = $signed(sample) * $signed({1'b0, cvsum_r});
	wire signed [38:0] mix_fm_l  = op_out * $signed({1'b0, fm_cvsum_l});
	wire signed [38:0] mix_fm_r  = op_out * $signed({1'b0, fm_cvsum_r});

	// ---- sample addressing ------------------------------------------------
	wire [23:0] addr8  = {1'b0, p_start} + stepptr[39:16];
	// 12 bit packs two samples into three bytes; base is the start of the pair.
	wire [25:0] idx3   = {2'b00, stepptr[39:17], 1'b0} + {3'b000, stepptr[39:17]};
	wire [22:0] base12 = p_start + idx3[22:0];

	wire line_hit  = line_tv[20] && (line_tv[19:0] == fetch_addr[22:3]);
	wire [7:0] line_byte = line_data[{fetch_addr[2:0], 3'b000} +: 8];

	// ------------------------------------------------------------------
	// Algorithm wiring
	//
	// Every algorithm in every sync mode is the same four operators in the same
	// order; only three things change. `in_m*` says which earlier results feed
	// each operator, as {use r1, use r3, use r2}; `fb_from_r3` picks which
	// result set_feedback() takes; `out_mask` says which operators reach the
	// mixer, bit 0 being operator 1. Read off the diagrams in ymf271.cpp.
	// ------------------------------------------------------------------
	reg  [2:0] in_m1, in_m2, in_m3;    // masks for steps 1, 2, 3
	reg        fb_from_r3;
	reg  [3:0] out_mask;

	always @* begin
		in_m1 = 3'b000; in_m2 = 3'b000; in_m3 = 3'b000;
		fb_from_r3 = 1'b0; out_mask = 4'b0000;
		case (sync)
			2'd0: case (net_alg)                    // 4-operator FM
				4'd0:  begin in_m1=3'b100; in_m2=3'b010; in_m3=3'b001; out_mask=4'b1000; end
				4'd1:  begin in_m1=3'b100; in_m2=3'b010; in_m3=3'b001; out_mask=4'b1000; fb_from_r3=1'b1; end
				4'd2:  begin in_m1=3'b000; in_m2=3'b110; in_m3=3'b001; out_mask=4'b1000; end
				4'd3:  begin in_m1=3'b000; in_m2=3'b010; in_m3=3'b101; out_mask=4'b1000; end
				4'd4:  begin in_m1=3'b100; in_m2=3'b000; in_m3=3'b011; out_mask=4'b1000; end
				4'd5:  begin in_m1=3'b100; in_m2=3'b000; in_m3=3'b011; out_mask=4'b1000; fb_from_r3=1'b1; end
				4'd6:  begin in_m1=3'b100; in_m2=3'b000; in_m3=3'b001; out_mask=4'b1010; end
				4'd7:  begin in_m1=3'b100; in_m2=3'b000; in_m3=3'b001; out_mask=4'b1010; fb_from_r3=1'b1; end
				4'd8:  begin in_m1=3'b000; in_m2=3'b010; in_m3=3'b001; out_mask=4'b1001; end
				4'd9:  begin in_m1=3'b000; in_m2=3'b000; in_m3=3'b011; out_mask=4'b1001; end
				4'd10: begin in_m1=3'b100; in_m2=3'b000; in_m3=3'b000; out_mask=4'b1110; end
				4'd11: begin in_m1=3'b100; in_m2=3'b000; in_m3=3'b000; out_mask=4'b1110; fb_from_r3=1'b1; end
				4'd12: begin in_m1=3'b100; in_m2=3'b100; in_m3=3'b100; out_mask=4'b1110; end
				4'd13: begin in_m1=3'b000; in_m2=3'b010; in_m3=3'b000; out_mask=4'b1101; end
				4'd14: begin in_m1=3'b100; in_m2=3'b000; in_m3=3'b001; out_mask=4'b1011; end
				default: begin                       // 15: all four carriers
					in_m1=3'b000; in_m2=3'b000; in_m3=3'b000; out_mask=4'b1111; end
			endcase

			2'd1: case (net_alg[1:0])               // two 2-operator pairs
				// Steps 0,1 are one pair and 2,3 the other, so one entry serves
				// both halves: in_m1 wires the pair's second operator and
				// in_m3 the same thing for the second pair.
				2'd0: begin in_m1=3'b100; in_m3=3'b100; out_mask=4'b1010; end
				2'd1: begin in_m1=3'b100; in_m3=3'b100; out_mask=4'b1010; fb_from_r3=1'b1; end
				2'd2: begin in_m1=3'b000; in_m3=3'b000; out_mask=4'b1111; end
				default: begin in_m1=3'b100; in_m3=3'b100; out_mask=4'b1111; end
			endcase

			2'd2: case (net_alg[2:0])               // 3-operator FM + PCM
				3'd0: begin in_m1=3'b100; in_m2=3'b010; out_mask=4'b0100; end
				3'd1: begin in_m1=3'b100; in_m2=3'b010; out_mask=4'b0100; fb_from_r3=1'b1; end
				3'd2: begin in_m1=3'b000; in_m2=3'b110; out_mask=4'b0100; end
				3'd3: begin in_m1=3'b000; in_m2=3'b010; out_mask=4'b0101; end
				3'd4: begin in_m1=3'b100; in_m2=3'b000; out_mask=4'b0110; end
				3'd5: begin in_m1=3'b100; in_m2=3'b000; out_mask=4'b0110; fb_from_r3=1'b1; end
				3'd6: begin in_m1=3'b000; in_m2=3'b000; out_mask=4'b0111; end
				default: begin in_m1=3'b100; in_m2=3'b000; out_mask=4'b0111; end
			endcase

			default: ;                              // sync 3: four PCM voices
		endcase
	end

	// In sync 1 the second pair restarts the network, so step 2 behaves like
	// step 0 and step 3 like step 1.
	wire net_start = (step == 2'd0) || ((sync == 2'd1) && (step == 2'd2));
	wire is_op1    = net_start;
	wire net_last  = (sync == 2'd1) ? ((step == 2'd1) || (step == 2'd3))
	                                : (step == 2'd1);

	wire [2:0] in_mask = (step == 2'd1) ? in_m1 :
	                     (step == 2'd2) ? in_m2 : in_m3;

	// PCM when the group says so, or when a slot 4 the network leaves spare
	// carries the external waveform.
	//
	// Every case is additionally gated on the slot actually carrying waveform 7.
	// Section 2-7 gives external waveforms to groups 0, 4 and 8 only -- the
	// twelve slots with PCM attribute registers -- so a sync-3 group anywhere
	// else is four one-operator FM voices, not PCM. Without the gate such a
	// group played from sample address 0, because its start/end/loop bytes are
	// never written. MAME does not handle this either: update_pcm() calls
	// fatalerror() on any waveform but 7, so it would abort where this now
	// sounds the operator. Latent in practice -- the games never do it, which
	// is why MAME can get away with the assertion.
	wire step_is_pcm = p_is_pcm
	                && ((sync == 2'd3)
	                 || ((sync == 2'd2) && (step == 2'd3))
	                 || ((sync == 2'd0) && (step == 2'd3)));

	wire mix_this_op = out_mask[step];

	// The feedback state belongs to the network's operator 1: bank 0 normally,
	// bank 1 for the second pair of a sync-1 group.
	wire [1:0] fb_bank = ((sync == 2'd1) && (step == 2'd3)) ? 2'd1 : 2'd0;
	wire [5:0] fb_slot = {1'b0, fb_bank, 3'b000} + {2'b00, fb_bank, 2'b00}
	                   + {2'b00, group};

	// ---- operator input ---------------------------------------------------
	wire signed [17:0] in_sum = (in_mask[2] ? r1 : 18'sd0)
	                          + (in_mask[1] ? r3 : 18'sd0)
	                          + (in_mask[0] ? r2 : 18'sd0);
	wire signed [33:0] mod_in = ({{8{in_sum[17]}}, in_sum, 8'd0})
	                          * $signed({1'b0, YMF_MODLVL[p_feedback]});
	// MAME divides by 2 and by 16 with C integer division, which truncates
	// TOWARD ZERO; an arithmetic shift floors instead, so negatives would come
	// out one too low. Bias before shifting.
	wire signed [27:0] fb_sum = {fb0[26], fb0} + {fb1[26], fb1};
	wire signed [27:0] fb_avg = (fb_sum + {27'd0, fb_sum[27]}) >>> 1;
	wire signed [33:0] op_input = is_op1 ? {{6{fb_avg[27]}}, fb_avg}
	                                     : ((in_mask == 3'b000) ? 34'sd0 : mod_in);

	// Phase index. Only bits 25:16 of the sum survive and carries never
	// propagate downward, so 32 bit arithmetic is exact here even though MAME
	// does it in 64.
	wire [31:0] phase_sum = stepptr[31:0] + op_input[31:0];
	wire  [9:0] phase_idx = phase_sum[25:16];
	// Waveforms 6 and 7 are the constant 32767 and silence, so the ROM only
	// holds 0..5; the address is forced in range and the constant picked after
	// the read. The read itself is registered -- an asynchronous lookup sat
	// between the two multiplies and was most of the 2.2 ns setup failure.
	wire  [2:0] wave_sel = (p_waveform >= 3'd6) ? 3'd0 : p_waveform;
	wire signed [15:0] wave_val =
		(p_waveform == 3'd7) ? 16'sd0 :
		(p_waveform == 3'd6) ? 16'sd32767 : $signed(wave_q);
	// slot_gain, not env_gain: calculate_slot_volume() folds total level in
	// before calculate_op() scales the waveform, and env_gain is only the
	// envelope-times-LFO half of it. It is valid by S_FMOP, one state later.
	wire signed [34:0] op_mul = wave_val * $signed({1'b0, slot_gain});

	// set_feedback(): ((result << 8) * feedback_level) / 16, taken from the
	// operator result that has just been latched into op_out.
	// net_fbk, not p_feedback: set_feedback() is always about operator 1, and
	// the algorithms that take their feedback from operator 3 run it a step
	// later, by which point p_feedback belongs to a different operator.
	wire signed [31:0] fb_mul = ({{6{op_out[17]}}, op_out, 8'd0})
	                          * $signed({1'b0, YMF_FBLVL[net_fbk]});
	wire signed [31:0] fb_div = fb_mul + (fb_mul[31] ? 32'sd15 : 32'sd0);
	wire signed [26:0] fb_new = fb_div[30:4];

	// ------------------------------------------------------------------
	// Sequencer
	// ------------------------------------------------------------------
	localparam [5:0] S_IDLE  = 6'd0,
	                 S_LD0   = 6'd1,  S_LD1  = 6'd2,  S_LD2  = 6'd3,  S_LD3 = 6'd4,
	                 S_KEY   = 6'd5,
	                 S_GATE  = 6'd6,
	                 S_LFO0  = 6'd7,  S_LFO1 = 6'd8,  S_LFO2 = 6'd9,
	                 S_STEP0 = 6'd10, S_STEP1 = 6'd11, S_STEP2 = 6'd12,
	                 S_LOOP  = 6'd13, S_LOOP2 = 6'd14, S_LOOP3 = 6'd15,
	                 S_ADDR  = 6'd16,
	                 S_FE0   = 6'd17, S_FE1  = 6'd18, S_FE2  = 6'd19,
	                 S_SAMP  = 6'd20,
	                 S_ENV   = 6'd21,
	                 S_VOL0  = 6'd22, S_VOL1 = 6'd23, S_VOL2 = 6'd24,
	                 S_VOL3  = 6'd25,
	                 S_MIX   = 6'd26,
	                 S_FMPH  = 6'd27, S_FMWT = 6'd28, S_FMOP = 6'd29, S_FMMIX = 6'd30,
	                 S_STORE = 6'd31,
	                 S_NEXT  = 6'd32,
	                 S_OUT   = 6'd33,
	                 S_EXT   = 6'd34;   // host wave-memory readback

	reg [5:0] state;
	reg [5:0] ext_ret;    // where S_EXT resumes: the pass must not lose its place

	// MAME normalises every one of the chip's four outputs by 32768<<2, so a
	// speaker's sample is its accumulator >> 2 whatever is routed to it.
	//
	// Mono sums the two accumulators BEFORE the shift, not after. Shifting
	// each and adding would round each half toward -inf separately and lose up
	// to one LSB against the old single-accumulator mono, which is the one
	// thing this change must not do -- rdfts' sound is already measured.
	wire signed [28:0] acc_sum = {acc_l[27], acc_l} + {acc_r[27], acc_r};

	function signed [15:0] outclip(input signed [28:0] a);
		outclip = (a >>> 2 >  29'sd32767) ?  16'sh7FFF :
		          (a >>> 2 < -29'sd32768) ? -16'sh8000 :
		          $signed(a[17:2]);
	endfunction

	wire signed [15:0] out_mono  = outclip(acc_sum);
	wire signed [15:0] out_left  = outclip({acc_l[27], acc_l});
	wire signed [15:0] out_right = outclip({acc_r[27], acc_r});

	// The slot to prefetch: next step in bank order 0, 2, 1, 3.
	wire [1:0] nstep  = step + 2'd1;
	wire [1:0] nbank  = (nstep == 2'd0) ? 2'd0 : (nstep == 2'd1) ? 2'd2 :
	                    (nstep == 2'd2) ? 2'd1 : 2'd3;
	wire [3:0] ngroup = (step == 2'd3) ? (group + 4'd1) : group;
	wire [5:0] nslot  = {1'b0, nbank, 3'b000} + {2'b00, nbank, 2'b00} + {2'b00, ngroup};

	always @(posedge clk) begin
		end_set <= 1'b0;
		st_we   <= 1'b0;
		fb_we   <= 1'b0;
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
			group      <= 4'd0;
			step       <= 2'd0;
			acc_l      <= 28'sd0;
			acc_r      <= 28'sd0;
			active_cnt <= 16'd0;
			st_ra      <= 6'd0;
			fb_ra      <= 6'd0;
			cch_ra     <= 6'd0;
			par_ra     <= 8'd0;
			state      <= S_LD0;
		end

		// All four RAMs answer two cycles after their address register is
		// loaded, and the parameter reads are pipelined one per cycle.
		S_LD0: begin par_ra <= {slot, 2'd1}; state <= S_LD1; end
		S_LD1: begin
			w0        <= par_q;
			par_ra    <= {slot, 2'd2};
			stepptr   <= st_q[95:56];
			volume    <= st_q[55:29];
			env_state <= st_q[28:27];
			active    <= st_q[26];
			lfo_phase <= st_q[25:0];
			// The tag comes out of the RAM, the valid bit out of the register
			// beside it: a flash write clears every bit of cch_vld at once, so
			// a line cached before it can never be trusted again even though
			// its tag is still sitting in the RAM.
			line_tv   <= {cch_tv_q[20] & cch_vld[slot], cch_tv_q[19:0]};
			line_data <= cch_data_q;
			state     <= S_LD2;
		end
		S_LD2: begin w1 <= par_q; state <= S_LD3; end
		S_LD3: begin
			w2 <= par_q;
			if (net_start) begin
				fb0 <= $signed(fb_q[53:27]);
				fb1 <= $signed(fb_q[26:0]);
			end
			state <= S_KEY;
		end

		// ------------------------------------------------------------
		// write_register() case 0: key on restarts the phase and the envelope
		// from -60 dB, key off drops a sounding slot into release.
		S_KEY: begin
			if (keyon_pend[slot]) begin
				stepptr   <= 40'd0;
				volume    <= 27'sd6225920;      // (255 - 160) << 16
				env_state <= ENV_ATTACK;
				active    <= 1'b1;
				lfo_phase <= 26'd0;             // init_lfo
				line_tv   <= 21'd0;             // the sample line moved too
			end
			else if (keyoff_pend[slot] && active) env_state <= ENV_RELEASE;
			state <= S_GATE;
		end

		// MAME only reaches update_lfo() and calculate_step() from inside
		// calculate_op()/update_pcm(), both of which return early on an idle
		// slot, so the gate comes first and an idle slot costs eight cycles.
		S_GATE: begin
			tl_r <= YMF_TL[p_tl];
			if (net_start) begin
				net_alg    <= p_alg;
				net_active <= active;
				net_fbk    <= p_feedback;
			end
			// A network is gated by its own operator 1; a PCM voice by itself.
			if (step_is_pcm ? active : (net_start ? active : net_active)) begin
				active_cnt <= active_cnt + 16'd1;
				state      <= S_LFO0;
			end
			else state <= S_STORE;
		end

		// update_lfo(): advance the phase, then read both shapes with it.
		S_LFO0: begin
			lfo_phase <= lfo_next;
			lfo_idx_r <= lfo_next[25:18];
			state     <= S_LFO1;
		end
		S_LFO1: begin
			plfo_w_r <= plfo_q;
			alfo_r   <= alfo;
			state    <= S_LFO2;
		end
		S_LFO2: begin
			plfo_r <= plfo_c;
			amul_r <= alfo_scaled;
			state  <= S_STEP0;
		end

		// calculate_step(), one operation a cycle: the multiply, the power of
		// two shift, then the LFO pitch factor.
		S_STEP0: begin
			lfo_vol <= lfo_vol_c;
			num_r   <= step_num;
			state   <= S_STEP1;
		end
		S_STEP1: begin base_r <= step_base; state <= S_STEP2; end
		S_STEP2: begin
			step_r <= step_calc;
			state  <= step_is_pcm ? S_LOOP : S_ENV;
		end

		// ------------------------------------------------------------
		// PCM: loop wrap, then the sample fetch. MAME retries the wrap twice
		// more, because a step long enough to clear the whole loop can still
		// land past the end after folding.
		S_LOOP: begin
			if (stepptr[39:16] > {1'b0, p_end}) begin
				stepptr  <= stepptr - {p_end, 16'd0} + {p_loop, 16'd0};
				end_set  <= 1'b1;
				end_slot <= slot;
				state    <= S_LOOP2;
			end
			else state <= S_ADDR;
		end
		S_LOOP2: begin
			if (stepptr[39:16] > {1'b0, p_end}) begin
				stepptr <= {1'b0, p_loop, stepptr[15:0]};
				state   <= S_LOOP3;
			end
			else state <= S_ADDR;
		end
		S_LOOP3: begin
			if (stepptr[39:16] > {1'b0, p_end}) stepptr <= {1'b0, p_end, stepptr[15:0]};
			state <= S_ADDR;
		end

		S_ADDR: begin
			fetch_second <= 1'b0;
			fetch_addr <= p_bits12 ? (base12 + 23'd1) : addr8[22:0];
			state      <= S_FE0;
		end

		S_FE0: begin
			if (line_hit) state <= S_SAMP;
			else begin
				sdr_addr <= SDR_PCM_BASE + {4'd0, fetch_addr[20:3], 3'b000};
				sdr_req  <= ~sdr_req;
				state    <= S_FE1;
			end
		end
		S_FE1: if (sdr_ack == sdr_req) begin
			line_data <= sdr_dout;
			line_tv   <= {1'b1, fetch_addr[22:3]};
			state     <= S_FE2;
		end
		S_FE2: state <= S_SAMP;      // let line_hit / line_byte settle

		// Host readback. Deliberately does not touch line_data / line_tv: that
		// cache belongs to whichever slot is mid-note, and evicting it here
		// would cost that slot a refetch for a transfer the synthesis path
		// never asked for.
		S_EXT: if (sdr_ack == sdr_req) begin
			ext_data <= sdr_dout[{ext_addr[2:0], 3'b000} +: 8];
			ext_ack  <= ext_req;
			state    <= ext_ret;
		end

		S_SAMP: begin
			if (!p_bits12) begin
				sample <= {line_byte, 8'h00};
				state  <= S_ENV;
			end
			else if (!fetch_second) begin
				byte_lo      <= line_byte;
				fetch_second <= 1'b1;
				fetch_addr   <= stepptr[16] ? (base12 + 23'd2) : base12;
				state        <= S_FE0;
			end
			else begin
				sample <= stepptr[16] ? {line_byte, byte_lo[3:0], 4'h0}
				                      : {line_byte, byte_lo[7:4], 4'h0};
				state  <= S_ENV;
			end
		end

		// ------------------------------------------------------------
		// Shared: envelope, then the volume chain.
		S_ENV: begin
			case (env_state)
				ENV_ATTACK:
					if (v_att >= 28'sd16711680) begin
						volume    <= 27'sd16711680;
						env_state <= ENV_DECAY1;
					end
					else volume <= v_att[26:0];

				ENV_DECAY1:
					if (v_d1 <= 28'sd0) begin
						volume <= 27'sd0;
						active <= 1'b0;
					end
					else begin
						volume <= v_d1[26:0];
						if (v_d1[26:16] <= {3'd0, decay_level}) env_state <= ENV_DECAY2;
					end

				ENV_DECAY2:
					if (v_d2 <= 28'sd0) begin
						volume <= 27'sd0;
						active <= 1'b0;
					end
					else volume <= v_d2[26:0];

				ENV_RELEASE:
					if (v_rel <= 28'sd0) begin
						volume <= 27'sd0;
						active <= 1'b0;
					end
					else volume <= v_rel[26:0];
			endcase
			state <= S_VOL0;
		end

		S_VOL0: begin env_raw  <= YMF_ENV_VOL[8'd255 - vol8]; state <= S_VOL1; end
		S_VOL1: begin env_gain <= gain_lfo[32:16];            state <= S_VOL2; end
		S_VOL2: begin
			slot_gain <= gain_tl[33:16];
			// An operator folds the envelope into its output and needs no
			// channel clamp, so it skips the rest of the PCM chain.
			state <= step_is_pcm ? S_VOL3 : S_FMPH;
		end
		S_VOL3: begin
			// Each channel is clamped at 65536 individually before it is summed
			// (update_pcm's four `if (chN_vol > 65536)`), so the clamp has to
			// stay per channel here even when two of them land in one speaker.
			cvsum_l <= {2'd0, chclip(g0)}
			         + (stereo ? 20'd0 : {2'd0, chclip(g2)});
			cvsum_r <= {2'd0, chclip(g1)}
			         + (stereo ? 20'd0 : {2'd0, chclip(g3)});
			state <= S_MIX;
		end

		S_MIX: begin
			acc_l   <= acc_l + {{7{mix_pcm_l[36]}}, mix_pcm_l[36:16]};
			acc_r   <= acc_r + {{7{mix_pcm_r[36]}}, mix_pcm_r[36:16]};
			stepptr <= stepptr + {8'd0, step_r};
			state   <= S_STORE;
		end

		// ------------------------------------------------------------
		// FM operator: phase modulation in, waveform out.
		// The phase index, the waveform lookup and the output multiply were one
		// chain; they are three cycles now.
		S_FMPH: begin wave_ra <= {wave_sel, phase_idx}; state <= S_FMWT; end
		S_FMWT: state <= S_FMOP;

		S_FMOP: begin
			op_out  <= op_mul[33:16];
			stepptr <= stepptr + {8'd0, step_r};
			if (is_op1) fb0 <= fb1;         // set_feedback's rolling average
			state   <= S_FMMIX;
		end

		S_FMMIX: begin
			case (step)
				2'd0: r1 <= op_out;
				2'd1: r3 <= op_out;
				// In sync 1 step 2 opens the second pair, so its result is
				// that pair's r1 rather than the 4-op network's r2.
				2'd2: if (sync == 2'd1) r1 <= op_out; else r2 <= op_out;
				default: ;
			endcase
			// set_feedback() runs on operator 1's own result, or on operator
			// 3's, depending on the algorithm.
			if ((is_op1 && !fb_from_r3) || (!is_op1 && net_last && fb_from_r3))
				fb1 <= fb_new;
			if (mix_this_op) begin
				acc_l <= acc_l + {{5{mix_fm_l[38]}}, mix_fm_l[38:16]};
				acc_r <= acc_r + {{5{mix_fm_r[38]}}, mix_fm_r[38:16]};
			end
			state <= S_STORE;
		end

		// ------------------------------------------------------------
		S_STORE: begin
			st_wa       <= slot;
			st_wd       <= {stepptr, volume, env_state, active, lfo_phase};
			st_we       <= 1'b1;
			cch_wa       <= slot;
			cch_tv_wd    <= line_tv;
			cch_data_wd  <= line_data;
			cch_we       <= 1'b1;
			cch_vld[slot] <= line_tv[20];
			// Feedback goes back one step after it was read, by which point
			// both set_feedback() opportunities have passed.
			if (net_last && (sync != 2'd3)) begin
				fb_wa <= fb_slot;
				fb_wd <= {fb0, fb1};
				fb_we <= 1'b1;
			end
			state <= S_NEXT;
		end

		// A slot boundary is the other safe place to serve the host: no sample
		// fetch is outstanding and the line cache is not mid-use. Servicing
		// only from S_IDLE was not enough -- under polyphony the pass occupies
		// most of a sample period, while a Z80 `in` is about 88 clk_sys cycles,
		// so back-to-back reads outran the refill and returned a stale latch.
		// Here the host gets an opening every slot, ~20-27 cycles.
		S_NEXT: begin
			keyon_pend[slot]  <= 1'b0;
			keyoff_pend[slot] <= 1'b0;
			// Sample memory changed since the last slot: flip the generation,
			// which misses every cached line at once, and drop the live one
			// with it. Safe here and nowhere cheaper -- this is the same point
			// the host read is served from, chosen for the same reason.
			if (mem_dirty != dirty_ack) begin
				dirty_ack <= mem_dirty;
				cch_vld   <= 48'd0;
				line_tv   <= 21'd0;
			end
			if ((group == 4'd11) && (step == 2'd3)) begin
				if (ext_req != ext_ack) begin
					sdr_addr <= SDR_PCM_BASE + {4'd0, ext_addr[20:3], 3'b000};
					sdr_req  <= ~sdr_req;
					ext_ret  <= S_OUT;
					state    <= S_EXT;
				end
				else state <= S_OUT;
			end
			else begin
				step   <= nstep;
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

		S_OUT: begin
			audio_l    <= stereo ? out_left  : out_mono;
			audio_r    <= stereo ? out_right : out_mono;
			dbg_active <= active_cnt;
			state      <= S_IDLE;
		end

		default: state <= S_IDLE;
		endcase

		// A key event arriving in the same cycle the pass clears the slot's
		// flag has to win, or the note is lost; hence after the case.
		if (key_on)  keyon_pend[key_slot]  <= 1'b1;
		if (key_off) keyoff_pend[key_slot] <= 1'b1;

		if (reset) begin
			state       <= S_IDLE;
			sdr_req     <= 1'b0;
			ext_ack     <= 1'b0;
			ext_data    <= 8'd0;
			tick_pend   <= 1'b0;
			audio_l     <= 16'd0;
			audio_r     <= 16'd0;
			acc_l       <= 28'sd0;
			acc_r       <= 28'sd0;
			keyon_pend  <= 48'd0;
			keyoff_pend <= 48'd0;
			dbg_overrun <= 16'd0;
			dbg_active  <= 16'd0;
			active_cnt  <= 16'd0;
			group       <= 4'd0;
			step        <= 2'd0;
			end_set     <= 1'b0;
			st_we       <= 1'b0;
			fb_we       <= 1'b0;
			cch_we      <= 1'b0;
			cch_vld     <= 48'd0;
			dirty_ack   <= 1'b0;
			line_tv     <= 21'd0;
		end
	end

	// Fields one path or the other does not use, and the low halves of products
	// the >>16 scaling deliberately discards.
	/* verilator lint_off UNUSEDSIGNAL */
	wire _unused = &{1'b0, w0, w1, w2, step_nsh, d1_mul, gain_tl, gain_lfo,
	                 mix_pcm_l, mix_pcm_r, mix_fm_l, mix_fm_r,
	                 acc_sum, addr8, idx3, step_mul, alfo_scaled,
	                 op_mul, fb_mul, fb_div, fb_sum, phase_sum, mod_in, op_input, fb_avg,
	                 plfo_q, plfo_base, plfo_addr, alfo, amul_r,
	                 // ext_addr is the chip's full 23-bit space; the sample
	                 // region is 2 MB, so [20:0] addresses all of it -- both
	                 // flash chips included, since chip 1 is just bit 20 -- and
	                 // the top two bits mirror rather than reach anything.
	                 ext_addr[22:21]};
	/* verilator lint_on UNUSEDSIGNAL */

	initial begin
		for (i = 0; i <  48; i = i + 1) begin
			st_mem[i]   = 96'd0;
			fb_mem[i]   = 54'd0;
			cch_tv[i]   = 21'd0;
			cch_data[i] = 64'd0;
		end
	end

endmodule
