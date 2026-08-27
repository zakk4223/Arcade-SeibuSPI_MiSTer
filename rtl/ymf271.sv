//============================================================================
//  SeibuSPI - YMF271 "OPX" register file, timers and interrupt
//
//  The Z80 sees sixteen bytes at 0x6000. Even offsets latch an address, odd
//  offsets deliver the data to one of four FM register banks, the PCM bank, or
//  the timer/control bank (ymf271_device::write, ymf271.cpp:1446).
//
//  The synthesis half lives in ymf271_pcm.sv; this file decodes writes into
//  its slot parameter RAM and hands it key on/off events.
//
//  Slot parameter RAM layout -- four 64 bit words a slot, byte addressed.
//  Every field the engine reads is stored. Detune, Acc On, Src Note and Src B
//  always were: they sit inside bytes other registers own, and it was only the
//  old synthesis core that never extracted them.
//
//    word 0: FM 3  4  5  6  7  8  9  A     (multiple/detune .. fns_hi/block)
//    word 1: FM B  D  E, PCM 0 1 2 3 4     (waveform/fb/accon, levels, start)
//    word 2: PCM 5 6 7 8 9, FM 1  2  C     (end, loop, fs/bits/src, LFO, alg)
//    word 3: FM 0                          (EN and EXT Out; KON has no storage)
//
//  Which gives the flat byte index used below:
//    FM reg 3..9 -> 0..6,  B -> 8,  D -> 9,  E -> 10
//    PCM reg r   -> 11 + r
//    FM reg 1 -> 21,  2 -> 22,  C -> 23,  0 -> 24
//
//  Byte 7 -- Block and F-Number2 -- is NOT written by FM register A. The
//  manual requires Block and F-Number2 to be written before F-Number1, and the
//  chip honours that literally: A only latches, and 9 commits both halves at
//  once. The latch is `fnum_latch` below, and a write to 9 therefore costs two
//  parameter stores per slot instead of one.
//============================================================================

module ymf271
	import system_consts::*;
(
	input             clk,
	input             reset,
	// Hold the 44.1 kHz tick, and with it every voice, envelope and timer in
	// the chip: nothing in here advances except on a tick.
	input             pause,

	// ---- the savestate ---------------------------------------------------
	// SSIDX_YMF_REGS is this file's persistent state: the register file, the
	// two timers and their IRQ, the external-memory port and the sample tick's
	// own phase. The write fan-out sequencer is absent because it is idle
	// between register writes, and the 386 is frozen.
	ssbus_if.slave    ssbus_regs,
	// ...and the three sections inside the engine, passed straight through.
	ssbus_if.slave    ssbus_par,
	ssbus_if.slave    ssbus_st,
	ssbus_if.slave    ssbus_fb,
	input             stereo,      // cartridge board: out 0 left, out 1 right

	// ---- Z80 bus, 0x6000-0x600F ------------------------------------------
	input       [3:0] addr,
	input       [7:0] din,
	output reg  [7:0] dout,
	input             wr,          // single cycle strobes
	input             rd,
	output            irq,

	// ---- SDRAM ch5 --------------------------------------------------------
	output     [25:0] sdr_addr,
	input      [63:0] sdr_dout,
	output            sdr_req,
	input             sdr_ack,

	// ---- wave memory port, for a board whose sample memory is FLASH -------
	// `ext_wr` pulses for one cycle after a write to utility register 0x17,
	// with the byte on ext_wd. `ext_a` is the port's address register, which
	// is also what steers a read, and it is exported rather than duplicated
	// because the chip has exactly one: by the time ext_wr is seen the
	// register has already taken its post-increment, which is the address the
	// byte belongs at (rtl/spi_soundflash.sv, and PLAN.md section 0 on why the
	// updater opens a session at 0x7FFFFF).
	output reg        ext_wr,
	output reg  [7:0] ext_wd,
	output     [22:0] ext_a,
	// The read override: when the flash is answering with its status or
	// identifier instead of its array, this is the byte, and the sample
	// memory's own contents are not consulted.
	input             ext_ovr,
	input       [7:0] ext_ovr_data,
	// Toggles when sample memory has been written under us, so the synth can
	// retire its cached lines.
	input             mem_dirty,

	output     [15:0] audio_l,
	output     [15:0] audio_r,
	output     [15:0] dbg_overrun,
	output     [15:0] dbg_active
);

	// ------------------------------------------------------------------
	// 44100 Hz sample tick.
	//
	// The chip runs from its own 16.9344 MHz crystal and divides by 384, so
	// the rate is exactly 44100 and unrelated to clk_sys. A fractional
	// accumulator reproduces it exactly on average rather than approximately.
	// Timer A and B periods are whole multiples of 384 master clocks, so they
	// count these ticks instead of needing a clock of their own.
	// ------------------------------------------------------------------
	localparam [26:0] CLK_HZ = 27'd57272727;
	localparam [26:0] RATE   = 27'd44100;

	reg [26:0] tick_acc;
	reg        sample_tick;
	wire [27:0] tick_next = {1'b0, tick_acc} + {1'b0, RATE};

	always @(posedge clk) begin
		if (reset) begin
			tick_acc    <= 27'd0;
			sample_tick <= 1'b0;
		end
		else if (pause) begin
			sample_tick <= 1'b0;
		end
		else if (tick_next >= {1'b0, CLK_HZ}) begin
			tick_acc    <= tick_next[26:0] - CLK_HZ;
			sample_tick <= 1'b1;
		end
		else begin
			tick_acc    <= tick_next[26:0];
			sample_tick <= 1'b0;
		end
		// The sample tick's phase is part of the state, and it is the one item
		// of this section that is not driven by the register block below.
		if (ss_rg_wr && (ss_rg_i == 32'd8)) tick_acc <= ss_rg_d[26:0];
	end

	// ------------------------------------------------------------------
	// Address latches, groups, timers
	// ------------------------------------------------------------------
	reg  [7:0] regs_main [0:15];
	reg  [1:0] grp_sync  [0:11];

	reg  [9:0] timerA;
	reg  [7:0] timerB;
	reg  [7:0] enable;
	reg  [1:0] status;
	reg  [1:0] irqstate;
	reg [15:0] end_status;

	reg        timA_run, timB_run;
	reg [10:0] timA_cnt;
	reg [12:0] timB_cnt;

	// Wave memory port. ext_latch is a read-ahead: a read returns it and only
	// then advances the address and refetches, which is MAME's structure and
	// the reason the first read after setting an address is a dummy.
	reg [22:0] ext_addr;
	reg        ext_rw;
	reg  [7:0] ext_latch;
	reg        ext_req;
	reg        ext_pend;
	wire       ext_ack;
	wire [7:0] ext_data;

	assign ext_a = ext_addr;

	assign irq = |irqstate;

	wire [10:0] timA_period = 11'd1024 - {1'b0, timerA};
	wire [12:0] timB_period = (13'd256 - {5'd0, timerB}) << 4;

	// ------------------------------------------------------------------
	// Write fan-out sequencer
	//
	// ymf271_write_fm mirrors the "synchronised" registers across the slots
	// of a group when the group is in one of the FM sync modes, so a single
	// bus write can touch up to four slots. Z80 writes are microseconds
	// apart and this drains in at most four clk_sys cycles, so there is no
	// need for it to be able to queue.
	// ------------------------------------------------------------------
	reg  [3:0] seq_banks;      // remaining target banks, one bit each
	reg  [3:0] seq_group;
	reg  [3:0] seq_reg;
	reg  [7:0] seq_data;
	reg        seq_pcm;
	reg  [5:0] seq_pcm_slot;

	wire [1:0] seq_bank = seq_banks[0] ? 2'd0 : seq_banks[1] ? 2'd1 :
	                      seq_banks[2] ? 2'd2 : 2'd3;
	// slot = 12 * bank + group, written out as shifts so nothing has to be
	// inferred from a truncated multiply.
	wire [5:0] seq_slot = seq_pcm ? seq_pcm_slot
	                              : ({1'b0, seq_bank, 3'b000} + {2'b00, seq_bank, 2'b00}
	                                 + {2'b00, seq_group});

	// Flat parameter byte index, 31 = "not stored".
	wire [4:0] pidx = seq_pcm
	                ? ((seq_reg <= 4'd9) ? (5'd11 + {1'b0, seq_reg}) : 5'd31)
	                : ((seq_reg >= 4'h3 && seq_reg <= 4'h9) ? ({1'b0, seq_reg} - 5'd3) :
	                   (seq_reg == 4'hB) ? 5'd8 :
	                   (seq_reg == 4'hD) ? 5'd9 :
	                   (seq_reg == 4'hE) ? 5'd10 :
	                   (seq_reg == 4'h1) ? 5'd21 :
	                   (seq_reg == 4'h2) ? 5'd22 :
	                   (seq_reg == 4'hC) ? 5'd23 :
	                   (seq_reg == 4'h0) ? 5'd24 : 5'd31);

	wire seq_active = |seq_banks;
	wire seq_store  = seq_active && (pidx != 5'd31);
	// FM register 0 carries EN and EXT Out as well as KON, so it is stored --
	// but KON itself is an event, not a field. Every KON=1 write retriggers,
	// edge or not: P-47 Aces writes KON=1 onto already-keyed slots for note
	// repeats, and edge-triggering would drop those notes.
	wire seq_keyon  = seq_active && !seq_pcm && (seq_reg == 4'd0) &&  seq_data[0];
	wire seq_keyoff = seq_active && !seq_pcm && (seq_reg == 4'd0) && !seq_data[0];

	// Block / F-Number2, held until F-Number1 commits both. One byte a slot.
	reg  [7:0] fnum_latch [0:47];
	reg        seq_ph;                    // second store of a register-9 write
	wire       seq_two = seq_active && !seq_pcm && (seq_reg == 4'h9);

	// ------------------------------------------------------------------
	// Bus write decode
	// ------------------------------------------------------------------
	// The four FM banks take their address from the even register below them,
	// the PCM bank from 0x8 and the timer bank from 0xC.
	wire [7:0] fm_a   = (addr == 4'h1) ? regs_main[0] :
	                    (addr == 4'h3) ? regs_main[2] :
	                    (addr == 4'h5) ? regs_main[4] : regs_main[6];
	wire [1:0] fm_bank = addr[2:1];             // 1,3,5,7 -> 0,1,2,3
	wire [3:0] fm_sel  = fm_a[3:0];
	wire [3:0] fm_reg  = fm_a[7:4];
	// fm_tab / pcm_tab: the fourth entry of every group of four is invalid.
	wire       sel_ok  = (fm_sel[1:0] != 2'd3);
	// group = 3 * (sel >> 2) + (sel & 3)
	wire [3:0] fm_grp  = {1'b0, fm_sel[3:2], 1'b0} + {2'b00, fm_sel[3:2]}
	                   + {2'b00, fm_sel[1:0]};

	wire [7:0] pcm_a   = regs_main[8];
	wire [3:0] pcm_sel = pcm_a[3:0];
	wire [3:0] pcm_reg = pcm_a[7:4];
	wire       pcm_ok  = (pcm_sel[1:0] != 2'd3);
	// slot = 12 * (sel >> 2) + 4 * (sel & 3)
	wire [5:0] pcm_slot = {1'b0, pcm_sel[3:2], 3'b000} + {2'b00, pcm_sel[3:2], 2'b00}
	                    + {2'b00, pcm_sel[1:0], 2'b00};

	wire [7:0] tim_a   = regs_main[12];

	// A synchronised register is mirrored across the group; which slots depends
	// on the group's sync mode and which bank was addressed.
	wire       sync_reg = (fm_reg == 4'h0) || (fm_reg == 4'h9) || (fm_reg == 4'hA)
	                   || (fm_reg == 4'hC) || (fm_reg == 4'hD) || (fm_reg == 4'hE);
	wire [1:0] g_sync   = grp_sync[fm_grp[3:0] > 4'd11 ? 4'd0 : fm_grp];

	reg [3:0] fm_banks;
	always @* begin
		fm_banks = 4'b0001 << fm_bank;
		if (sync_reg) begin
			case (g_sync)
				2'd0: if (fm_bank == 2'd0) fm_banks = 4'b1111;
				2'd1: if (fm_bank[1] == 1'b0)
				          fm_banks = (fm_bank == 2'd0) ? 4'b0101 : 4'b1010;
				2'd2: if (fm_bank == 2'd0) fm_banks = 4'b0111;
				default: ;
			endcase
		end
	end

	// ------------------------------------------------------------------
	// Parameter RAM write port and key events, driven by the sequencer.
	// ------------------------------------------------------------------
	reg        par_we;
	reg  [7:0] par_addr;
	reg  [2:0] par_byte;
	reg  [7:0] par_data;
	reg        key_on, key_off;
	reg  [5:0] key_slot;

	wire       end_set;
	wire [5:0] end_slot;
	// calculate_status_end: only slots that are a multiple of four have a
	// status bit, at {group[3:2], bank[1:0]}.
	wire [1:0] es_bank  = end_slot >= 6'd36 ? 2'd3 : end_slot >= 6'd24 ? 2'd2 :
	                      end_slot >= 6'd12 ? 2'd1 : 2'd0;
	wire [5:0] es_grp6  = end_slot - ({1'b0, es_bank, 3'b000} + {2'b00, es_bank, 2'b00});
	wire       es_ok    = (es_grp6[1:0] == 2'd0);
	wire [3:0] es_bit   = {es_grp6[3:2], es_bank};

	wire [1:0] ks_bank  = key_slot >= 6'd36 ? 2'd3 : key_slot >= 6'd24 ? 2'd2 :
	                      key_slot >= 6'd12 ? 2'd1 : 2'd0;
	wire [5:0] ks_grp6  = key_slot - ({1'b0, ks_bank, 3'b000} + {2'b00, ks_bank, 2'b00});
	wire       ks_ok    = (ks_grp6[1:0] == 2'd0);
	wire [3:0] ks_bit   = {ks_grp6[3:2], ks_bank};

	integer k;

	always @(posedge clk) begin
		par_we  <= 1'b0;
		key_on  <= 1'b0;
		key_off <= 1'b0;
		ext_wr  <= 1'b0;

		// ---- sequencer step ------------------------------------------
		if (seq_active) begin
			// A write to FM register A only latches; register 9 then stores the
			// F-Number low byte and the latched Block / F-Number2 together, so
			// it takes two cycles per slot. Z80 writes are microseconds apart
			// and this drains in at most eight, so nothing has to queue.
			if (seq_two && !seq_ph) begin
				par_addr <= {seq_slot, 2'd0};
				par_byte <= 3'd6;
				par_data <= seq_data;
				par_we   <= 1'b1;
				seq_ph   <= 1'b1;
			end
			else begin
				if (seq_two) begin
					par_addr <= {seq_slot, 2'd0};
					par_byte <= 3'd7;
					par_data <= fnum_latch[seq_slot];
					par_we   <= 1'b1;
				end
				else begin
					par_addr <= {seq_slot, pidx[4:3]};
					par_byte <= pidx[2:0];
					par_data <= seq_data;
					par_we   <= seq_store;
				end
				if (!seq_pcm && (seq_reg == 4'hA)) fnum_latch[seq_slot] <= seq_data;
				seq_banks <= seq_banks & ~(4'b0001 << seq_bank);
				seq_ph    <= 1'b0;
				key_slot  <= seq_slot;
				key_on    <= seq_keyon;
				key_off   <= seq_keyoff;
				// Key on clears this slot's end flag straight away.
				if (seq_keyon && ks_ok) end_status[ks_bit] <= 1'b0;
			end
		end

		// The End flags are cleared by READING them. Brave Blade copies the
		// status registers to RAM every ~100 us and frees a PCM channel when it
		// sees that channel's End bit; a sticky flag kills the next note started
		// on that slot from the stale copy. Placed before the engine's set below
		// so an End raised in the same cycle survives the read.
		if (rd && (addr == 4'h0)) end_status[3:0]  <= 4'd0;
		if (rd && (addr == 4'h1)) end_status[11:4] <= 8'd0;

		if (end_set && es_ok) end_status[es_bit] <= 1'b1;

		// ---- timers --------------------------------------------------
		if (sample_tick) begin
			if (timA_run) begin
				if (timA_cnt == 11'd0) begin
					timA_cnt <= timA_period - 11'd1;
					status[0] <= 1'b1;
					if (enable[2]) irqstate[0] <= 1'b1;
				end
				else timA_cnt <= timA_cnt - 11'd1;
			end
			if (timB_run) begin
				if (timB_cnt == 13'd0) begin
					timB_cnt <= timB_period - 13'd1;
					status[1] <= 1'b1;
					if (enable[3]) irqstate[1] <= 1'b1;
				end
				else timB_cnt <= timB_cnt - 13'd1;
			end
		end

		// ---- wave memory read-ahead ----------------------------------
		// The Z80 samples DI at the end of its cycle, which is when `rd`
		// strobes, so the byte it takes is the pre-increment latch.
		if (rd && (addr == 4'h2) && ext_rw) begin
			ext_addr <= ext_addr + 23'd1;
			ext_req  <= ~ext_req;
			ext_pend <= 1'b1;
		end
		if (ext_pend && (ext_ack == ext_req)) begin
			// The flash's status or identifier stands in for the fetched byte
			// HERE rather than at the read mux, so the byte handed out always
			// belongs to the address it was fetched at. MAME's ymf271 read()
			// has the same shape -- ext_read() is called once per advance and
			// its result is what the next read returns -- and doing it at the
			// mux instead would answer from the address the port has moved on
			// to, which shows up as the wrong identifier byte and, at a chip
			// boundary, the wrong chip.
			ext_latch <= ext_ovr ? ext_ovr_data : ext_data;
			ext_pend  <= 1'b0;
		end

		// ---- bus write -----------------------------------------------
		if (wr) begin
			regs_main[addr] <= din;

			case (addr)
				4'h1, 4'h3, 4'h5, 4'h7: if (sel_ok) begin
					seq_banks    <= fm_banks;
					seq_group    <= fm_grp;
					seq_reg      <= fm_reg;
					seq_data     <= din;
					seq_pcm      <= 1'b0;
				end

				4'h9: if (pcm_ok) begin
					seq_banks    <= 4'b0001;
					seq_pcm_slot <= pcm_slot;
					seq_reg      <= pcm_reg;
					seq_data     <= din;
					seq_pcm      <= 1'b1;
				end

				4'hD: begin
					if (tim_a[7:4] == 4'd0) begin
						// group sync / PFM select
						if (tim_a[1:0] != 2'd3)
							grp_sync[{1'b0, tim_a[3:2], 1'b0} + {2'b00, tim_a[3:2]}
							         + {2'b00, tim_a[1:0]}] <= din[1:0];
					end
					else case (tim_a)
						// 0x10 is the HIGH 8 bits and 0x11 the low 2, which is
						// the reverse of the datasheet: section 2-6 3) calls
						// 0x10 "Timer-A1" and 0x11 "Timer-A2, the top 2 bits",
						// tA = 384 * (1024 - (A2*256 + A1)). MAME contradicts
						// it deliberately -- the split matches the other
						// Yamaha FM chips -- and the timer is this board's
						// sound heartbeat, so follow MAME. Do not "fix".
						8'h10: timerA[9:2] <= din;
						8'h11: timerA[1:0] <= din[1:0];
						8'h12: timerB      <= din;
						8'h13: begin
							// A timer only ever starts here: MAME reaches the
							// "stop" branch only when the enable bit is
							// already set, so it can never be taken.
							if (~enable[0] & din[0]) begin
								timA_run <= 1'b1;
								timA_cnt <= timA_period - 11'd1;
							end
							if (~enable[1] & din[1]) begin
								timB_run <= 1'b1;
								timB_cnt <= timB_period - 13'd1;
							end
							if (din[4]) begin irqstate[0] <= 1'b0; status[0] <= 1'b0; end
							if (din[5]) begin irqstate[1] <= 1'b0; status[1] <= 1'b0; end
							enable <= din;
						end
						// Wave memory port (manual 4-3). The address register
						// runs one BEHIND the next transfer: both 0x17 and the
						// read at offset 2 pre-increment. That is why the SPI
						// cartridge's flash updater sets 0x7FFFFF before
						// writing byte 0 (PLAN.md section 0).
						8'h14: ext_addr[7:0]   <= din;
						8'h15: ext_addr[15:8]  <= din;
						8'h16: begin
							ext_addr[22:16] <= din[6:0];
							ext_rw          <= din[7];
						end
						8'h17: begin
							// On SXX2E this goes nowhere: the sample memory is
							// a mask ROM. On SXX2C it is two flash chips and
							// this is the programming path -- the byte leaves
							// on ext_wr, one cycle later, by which time
							// ext_addr holds the post-increment value it
							// belongs at (rtl/spi_soundflash.sv).
							ext_addr <= ext_addr + 23'd1;
							ext_wr   <= 1'b1;
							ext_wd   <= din;
						end
						default: ;
					endcase
				end

				default: ;   // even offsets are address latches, already stored
			endcase
		end

		// ---- savestate restore -------------------------------------------
		// Every item of SSIDX_YMF_REGS except tick_acc, which is driven in the
		// tick block and restored there. Last in the block so it beats whatever
		// the normal logic wrote this cycle; `pause` means nothing should be
		// writing, but this does not depend on that being true.
		if (ss_rg_wr) begin
			case (ss_rg_i)
				32'd0: {regs_main[3],  regs_main[2],
				        regs_main[1],  regs_main[0]}  <= ss_rg_d;
				32'd1: {regs_main[7],  regs_main[6],
				        regs_main[5],  regs_main[4]}  <= ss_rg_d;
				32'd2: {regs_main[11], regs_main[10],
				        regs_main[9],  regs_main[8]}  <= ss_rg_d;
				32'd3: {regs_main[15], regs_main[14],
				        regs_main[13], regs_main[12]} <= ss_rg_d;
				32'd4: {grp_sync[11], grp_sync[10], grp_sync[9], grp_sync[8],
				        grp_sync[7],  grp_sync[6],  grp_sync[5], grp_sync[4],
				        grp_sync[3],  grp_sync[2],  grp_sync[1], grp_sync[0]}
				           <= ss_rg_d[23:0];
				32'd5: begin
					timerA   <= ss_rg_d[9:0];
					timerB   <= ss_rg_d[17:10];
					enable   <= ss_rg_d[25:18];
					status   <= ss_rg_d[27:26];
					irqstate <= ss_rg_d[29:28];
				end
				32'd6: begin
					end_status <= ss_rg_d[15:0];
					timA_run   <= ss_rg_d[16];
					timB_run   <= ss_rg_d[17];
				end
				32'd7: begin
					timA_cnt <= ss_rg_d[10:0];
					timB_cnt <= ss_rg_d[23:11];
				end
				32'd9: begin
					// ext_req is a toggle against the engine's ext_ack. Restoring
					// it can leave the two unequal, which costs one refetch of a
					// byte the port was going to reread anyway.
					ext_addr <= ss_rg_d[22:0];
					ext_rw   <= ss_rg_d[23];
					ext_req  <= ss_rg_d[24];
					ext_pend <= ss_rg_d[25];
				end
				32'd10: ext_latch <= ss_rg_d[7:0];
				default: ;
			endcase
			if (ss_rg_fl) begin
				fnum_latch[ss_rg_fb]        <= ss_rg_d[7:0];
				fnum_latch[ss_rg_fb + 6'd1] <= ss_rg_d[15:8];
				fnum_latch[ss_rg_fb + 6'd2] <= ss_rg_d[23:16];
				fnum_latch[ss_rg_fb + 6'd3] <= ss_rg_d[31:24];
			end
		end

		if (reset) begin
			seq_banks  <= 4'd0;
			par_we     <= 1'b0;
			key_on     <= 1'b0;
			key_off    <= 1'b0;
			timerA     <= 10'd0;
			timerB     <= 8'd0;
			enable     <= 8'd0;
			status     <= 2'd0;
			irqstate   <= 2'd0;
			end_status <= 16'd0;
			seq_ph     <= 1'b0;
			timA_run   <= 1'b0;
			timB_run   <= 1'b0;
			timA_cnt   <= 11'd0;
			timB_cnt   <= 13'd0;
			ext_addr   <= 23'd0;
			ext_rw     <= 1'b0;
			ext_latch  <= 8'd0;
			ext_req    <= 1'b0;
			ext_pend   <= 1'b0;
			ext_wr     <= 1'b0;
			ext_wd     <= 8'd0;
			for (k = 0; k < 16; k = k + 1) regs_main[k] <= 8'd0;
			for (k = 0; k < 12; k = k + 1) grp_sync[k]  <= 2'd0;
			for (k = 0; k < 48; k = k + 1) fnum_latch[k] <= 8'd0;
		end
	end

	// ------------------------------------------------------------------
	// Reads. Status 1 carries the timer flags and the low four end flags,
	// status 2 the rest; everything else on this board reads back 0xFF.
	// ------------------------------------------------------------------
	// Offset 2 is the wave memory data port. It returns the LATCHED byte and
	// only then advances, so the first read after setting an address is a dummy
	// and the data stream starts at address+1 -- MAME's read() does exactly
	// this. Reads while the direction bit says "write" return 0xFF.
	always @* begin
		case (addr)
			4'h0:    dout = {1'b0, end_status[3:0], 1'b0, status};
			4'h1:    dout = end_status[11:4];
			// The latch already carries the flash's status or identifier when
			// there is one; see the read-ahead. With the direction bit clear
			// the port reads 0xFF either way, which is what MAME does and what
			// the existing test pins down.
			4'h2:    dout = ext_rw ? ext_latch : 8'hFF;
			default: dout = 8'hFF;
		endcase
	end

	/* verilator lint_off UNUSEDSIGNAL */
	wire _unused = &{1'b0, enable[7:4], end_status[15:12], es_grp6[5:4], ks_grp6[5:4]};
	/* verilator lint_on UNUSEDSIGNAL */

	// The engine walks groups, so it needs every group's sync mode at once.
	wire [23:0] grp_sync_flat;
	generate
		genvar gi;
		for (gi = 0; gi < 12; gi = gi + 1) begin : gsync
			assign grp_sync_flat[gi*2 +: 2] = grp_sync[gi];
		end
	endgenerate

	// ------------------------------------------------------------------
	// SSIDX_YMF_REGS -- 23 dwords, laid out here and nowhere else.
	//
	//   0..3   regs_main[0..15]      the sixteen bus registers
	//   4      grp_sync[0..11]
	//   5      timerA/B, enable, status, irqstate
	//   6      end_status, timA_run, timB_run
	//   7      timA_cnt, timB_cnt
	//   8      tick_acc              (restored in the tick block, not here)
	//   9      ext_addr, ext_rw, ext_req, ext_pend
	//   10     ext_latch
	//   11..22 fnum_latch[0..47]     Block / F-Number2, four to a word
	//
	// This section used to be write-only in the wrong direction: the read path
	// was complete and the write path did nothing but ack, so a load threw the
	// whole register file away and the chip came back with whatever it happened
	// to be holding. It restores now. `pause` is asserted throughout a restore,
	// so nothing here is racing the bus, the timers or the wave-memory port --
	// but the restore is placed last in each block anyway, so it wins if it is.
	// ------------------------------------------------------------------
	wire ss_rg_acc = ssbus_regs.access(SSIDX_YMF_REGS);
	wire [31:0] ss_rg_i = ssbus_regs.addr;
	wire        ss_rg_wr = ss_rg_acc && ssbus_regs.write;
	wire [31:0] ss_rg_d  = ssbus_regs.data[31:0];
	// word 11 + k holds fnum_latch[4k .. 4k+3]
	wire        ss_rg_fl = ss_rg_wr && (ss_rg_i >= 32'd11) && (ss_rg_i < 32'd23);
	wire  [5:0] ss_rg_fb = 6'((ss_rg_i - 32'd11) << 2);

	function automatic [31:0] ymf_ss_rd(input [31:0] i);
		reg [5:0] b;
		case (i)
			32'd0: ymf_ss_rd = {regs_main[3],  regs_main[2],
			                    regs_main[1],  regs_main[0]};
			32'd1: ymf_ss_rd = {regs_main[7],  regs_main[6],
			                    regs_main[5],  regs_main[4]};
			32'd2: ymf_ss_rd = {regs_main[11], regs_main[10],
			                    regs_main[9],  regs_main[8]};
			32'd3: ymf_ss_rd = {regs_main[15], regs_main[14],
			                    regs_main[13], regs_main[12]};
			32'd4: ymf_ss_rd = {8'd0, grp_sync[11], grp_sync[10], grp_sync[9],
			                    grp_sync[8], grp_sync[7], grp_sync[6],
			                    grp_sync[5], grp_sync[4], grp_sync[3],
			                    grp_sync[2], grp_sync[1], grp_sync[0]};
			32'd5: ymf_ss_rd = {2'd0, irqstate, status, enable, timerB, timerA};
			32'd6: ymf_ss_rd = {14'd0, timB_run, timA_run, end_status};
			32'd7: ymf_ss_rd = {8'd0, timB_cnt, timA_cnt};
			32'd8: ymf_ss_rd = {5'd0, tick_acc};
			32'd9: ymf_ss_rd = {6'd0, ext_pend, ext_req, ext_rw, ext_addr};
			32'd10: ymf_ss_rd = {24'd0, ext_latch};
			default: begin
				b = 6'((i - 32'd11) << 2);
				ymf_ss_rd = ((i >= 32'd11) && (i < 32'd23))
				          ? {fnum_latch[b+3], fnum_latch[b+2],
				             fnum_latch[b+1], fnum_latch[b]}
				          : 32'd0;
			end
		endcase
	endfunction

	always @(posedge clk) begin
		ssbus_regs.setup(SSIDX_YMF_REGS, 32'd23, 2);
		if (ss_rg_acc) begin
			if (ssbus_regs.read)
				ssbus_regs.read_response(SSIDX_YMF_REGS,
					{32'd0, ymf_ss_rd(ss_rg_i)});
			else if (ssbus_regs.write) ssbus_regs.write_ack(SSIDX_YMF_REGS);
		end
	end

	ymf271_synth synth
	(
		.clk         (clk),
		.reset       (reset),
		.ssbus_par   (ssbus_par),
		.ssbus_st    (ssbus_st),
		.ssbus_fb    (ssbus_fb),
		.stereo      (stereo),
		.grp_sync_flat (grp_sync_flat),
		.par_we      (par_we),
		.par_addr    (par_addr),
		.par_byte    (par_byte),
		.par_data    (par_data),
		.key_on      (key_on),
		.key_off     (key_off),
		.key_slot    (key_slot),
		.end_set     (end_set),
		.end_slot    (end_slot),
		.sample_tick (sample_tick),
		.sdr_addr    (sdr_addr),
		.sdr_dout    (sdr_dout),
		.sdr_req     (sdr_req),
		.sdr_ack     (sdr_ack),
		.ext_addr    (ext_addr),
		.ext_req     (ext_req),
		.ext_ack     (ext_ack),
		.ext_data    (ext_data),
		.mem_dirty   (mem_dirty),
		.audio_l     (audio_l),
		.audio_r     (audio_r),
		.dbg_overrun (dbg_overrun),
		.dbg_active  (dbg_active)
	);

endmodule
