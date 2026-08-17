// Behavioural test for the YMF271 PCM engine.
//
// The Z80 core is VHDL, so nothing above ymf271 can be simulated here. This
// drives the chip's own register interface instead -- exactly the sequence a
// sound driver would write -- and checks what comes out of the mixer.
//
// The check is deliberately narrow rather than a second fixed-point model of
// the synthesis. With total level 0, all four channel attenuations at 0 dB and
// the envelope saturated, MAME's arithmetic reduces to
//
//     out = ((sample * 65536) >> 16) summed over 4 channels, then >> 2 == sample
//
// so the mixer output is the sample word, verbatim. A ramp in the sample ROM
// therefore has to come back as that same ramp, which pins down the register
// decode, the key-on path, the phase step, the address generation, the line
// cache, the 8- and 12-bit unpacking, the loop fold, the envelope reaching
// maximum and the mono sum -- each with a specific wrong answer if it is
// broken, instead of "the audio sounds odd".
//
// Only the phase pointer is modelled here, straight out of update_pcm, because
// that is the part with no independent way to observe it. Building a second
// model of the volume chain and diffing against it would only prove the two
// agree with each other; that mistake is recorded in PLAN.md section 12 under
// tb_rom_loader.

#include "Vtb_ymf_top.h"
#include "flash_replay.h"
#include "verilated.h"

// The watched byte, and it must equal spi_soundflash.sv's WATCH parameter.
// It is inside the replayed page (REPLAY_BASE 0x2900, 256 bytes), which is
// what lets the byte watch be checked against REPLAY_EXPECT rather than
// against a literal copied out of PLAN.md.
static const uint32_t WATCH_BYTE = 0x29FE;
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

static const uint32_t SDR_PCM_BASE = 0x280000;
static const uint32_t PCM_SIZE     = 0x200000;

// The same fractional accumulator ymf271.sv uses, so the testbench knows which
// cycle each 44100 Hz sample lands on without reaching into the design.
static const uint32_t CLK_HZ = 57272727;
static const uint32_t RATE   = 44100;

static Vtb_ymf_top *dut;
static std::vector<uint8_t> rom;
static int errors = 0;

static void fail(const char *what) {
    printf("FAIL: %s\n", what);
    errors++;
}

// ---------------------------------------------------------------- SDRAM ----
// One outstanding read, eight bytes, a few cycles of latency.
static bool sdr_busy = false;
static int  sdr_wait = 0;
static bool sdr_req_prev = false;

static void sdram_tick() {
    if (!sdr_busy && (dut->sdr_req != sdr_req_prev)) {
        sdr_req_prev = dut->sdr_req;
        sdr_busy = true;
        sdr_wait = 9;                       // roughly what ch5 costs in practice
    } else if (sdr_busy && --sdr_wait <= 0) {
        uint32_t a = dut->sdr_addr;
        uint64_t d = 0;
        for (int i = 0; i < 8; i++) {
            uint32_t off = a + i - SDR_PCM_BASE;
            uint8_t b = (off < PCM_SIZE) ? rom[off] : 0;
            d |= (uint64_t)b << (i * 8);
        }
        dut->sdr_dout = d;
        dut->sdr_ack  = dut->sdr_req;
        sdr_busy = false;
    }
}

// The flash's write port -- ch3's `d` in the real core. It writes the SAME
// array the read path above serves, because that is what the hardware does:
// the flash IS the YMF271's sample memory, not a copy of it. A round trip is
// deliberately slower than a read, since ch3 is bottom priority and the erase
// sweep's rate is the thing most likely to be wrong.
static bool     fl_busy = false;
static int      fl_wait = 0;
static bool     fl_req_prev = false;
static uint64_t fl_writes = 0;
// How long a flash write takes to retire. On hardware this is not a constant:
// the write is the LOWEST priority master on ch3, behind the Z80's instruction
// fetches, so it can be stalled far longer than the 14 cycles below -- which is
// the one thing this testbench did not model when the replay passed here and
// failed on hardware (PLAN.md 19.11).
static int      fl_latency = 14;
static int      fl_jitter  = 0;
static uint32_t fl_lcg     = 12345;

static void flash_tick() {
    if (!fl_busy && (dut->fl_req != fl_req_prev)) {
        fl_req_prev = dut->fl_req;
        fl_busy = true;
        fl_wait = fl_latency;
        if (fl_jitter) {
            fl_lcg = fl_lcg * 1103515245u + 12345u;
            fl_wait += (fl_lcg >> 16) % fl_jitter;
        }
    } else if (fl_busy && --fl_wait <= 0) {
        uint32_t a = dut->fl_addr - SDR_PCM_BASE;
        for (int lane = 0; lane < 2; lane++) {
            if (!(dut->fl_be & (1 << lane))) continue;
            uint32_t ba = a + lane;
            if (ba < PCM_SIZE) rom[ba] = (dut->fl_din >> (8 * lane)) & 0xFF;
        }
        fl_writes++;
        dut->fl_ack = dut->fl_req;
        fl_busy = false;
    }
}

// tick_acc has to advance on EVERY clock, not just the ones the sample loop
// looks at. Letting it drift made the testbench skip every other 44100 Hz tick
// and report the voice playing at twice the correct rate -- a convincing
// false positive, since a wrong phase step would look exactly the same.
static uint32_t tick_acc = 0;
static bool     tick_now = false;
// Sample ticks since the clock started. Driving the bus takes real time, so a
// test that writes registers between samples has to know how many it missed.
static uint64_t sample_ticks = 0;

// dbg_w_hit is a ONE-CYCLE pulse -- spi_soundflash defaults it low every clock
// -- so sampling it after the run always reads zero. Count it as it goes past.
// dbg_w_din holds, being written only on a hit, so that one can be read at the
// end.
static int dbg_w_hits = 0;

static void tick() {
    dut->clk = 0; dut->eval();
    sdram_tick();
    flash_tick();
    dut->clk = 1; dut->eval();
    if (dut->dbg_w_hit) dbg_w_hits++;

    uint32_t nxt = tick_acc + RATE;
    tick_now = (nxt >= CLK_HZ);
    tick_acc = tick_now ? (nxt - CLK_HZ) : nxt;
    if (tick_now) sample_ticks++;
}

static void run(int n) { while (n--) tick(); }

// ------------------------------------------------------------------ bus ----
static void wr(uint8_t a, uint8_t d) {
    dut->addr = a; dut->din = d; dut->wr = 1;
    tick();
    dut->wr = 0;
    run(8);                                 // the write fan-out drains in <= 4
}

// Read a bus offset. dout is combinational on addr, and the DUT advances the
// wave-memory pointer on the SAME edge the Z80 samples DI, so the value has to
// be taken before the strobe -- exactly as spi_sound presents it.
static uint8_t rd(uint8_t a) {
    dut->addr = a; dut->rd = 1;
    dut->clk = 0; dut->eval();
    uint8_t v = dut->dout;
    tick();
    dut->rd = 0;
    run(300);                               // let the refill finish from S_IDLE
    return v;
}

// Even offset latches the address, odd offset delivers the data.
static void fm_write(int bank, uint8_t sel, uint8_t reg, uint8_t data) {
    wr(bank * 2,     (uint8_t)((reg << 4) | sel));
    wr(bank * 2 + 1, data);
}
static void pcm_write(uint8_t sel, uint8_t reg, uint8_t data) {
    wr(0x8, (uint8_t)((reg << 4) | sel));
    wr(0x9, data);
}
static void timer_write(uint8_t a, uint8_t data) {
    wr(0xC, a);
    wr(0xD, data);
}

// Step to the next sample tick, then far enough past it that the pass over all
// 48 slots has finished and `audio` holds that sample.
static int16_t next_sample() {
    do { tick(); } while (!tick_now);
    run(1200);                              // a sample period is 1298 cycles
    return (int16_t)dut->audio_l;
}

// The right speaker, for the stereo test only. In mono both sides carry the
// same sample, so every other test can go on reading one of them.
static int16_t last_right() { return (int16_t)dut->audio_r; }

// ------------------------------------------------------------ phase model --
// update_pcm()'s pointer arithmetic. endaddr and loopaddr are offsets from
// startaddr: MAME compares them against stepptr>>16 and reads at
// startaddr + (stepptr>>16).
struct Phase {
    uint64_t stepptr = 0;
    uint32_t endoff, loopoff, step;
    bool looped = false;

    void wrap() {
        if ((stepptr >> 16) > endoff) {
            stepptr = stepptr - ((uint64_t)endoff << 16) + ((uint64_t)loopoff << 16);
            looped = true;
            if ((stepptr >> 16) > endoff) {
                stepptr &= 0xffff;
                stepptr |= ((uint64_t)loopoff << 16);
                if ((stepptr >> 16) > endoff) {
                    stepptr &= 0xffff;
                    stepptr |= ((uint64_t)endoff << 16);
                }
            }
        }
    }
    void advance() { stepptr += step; }
};

static int16_t expect_8bit(uint32_t start, const Phase &p) {
    return (int16_t)((uint16_t)rom[start + (uint32_t)(p.stepptr >> 16)] << 8);
}

static int16_t expect_12bit(uint32_t start, const Phase &p) {
    uint32_t base = start + (uint32_t)(p.stepptr >> 17) * 3;
    if (p.stepptr & 0x10000)
        return (int16_t)(((uint16_t)rom[base + 2] << 8) |
                         (((uint16_t)rom[base + 1] << 4) & 0xF0));
    return (int16_t)(((uint16_t)rom[base] << 8) |
                     ((uint16_t)rom[base + 1] & 0xF0));
}

// ---------------------------------------------------------- FM reference ----
// init_tables()'s waveform 0, recomputed from the trig rather than read back
// out of the generated table, so agreement means something.
static int16_t wave0(int i) {
    double m = sin(((i * 2) + 1) * M_PI / 1024.0);
    return (int16_t)(int)(m * 32767.0);
}

static const int MODULATION_LEVEL[8] = { 16, 8, 4, 2, 1, 32, 64, 128 };
static const int FEEDBACK_LEVEL[8]   = { 0, 1, 2, 4, 8, 16, 32, 64 };

// m_lut_total_level / m_lut_env_volume, from init_tables()'s formulas.
static int64_t total_level(int tl) {
    int64_t v = (int64_t)(65536.0 / pow(10.0, (0.75 * tl) / 20.0));
    return v > 65536 ? 65536 : v;
}
static int64_t env_volume(int i) {
    int64_t v = (int64_t)(65536.0 / pow(10.0, (i / (256.0 / 96.0)) / 20.0));
    return v > 65536 ? 65536 : v;
}
// ARTime[62] with keyscale 0 and keycode 1, i.e. rate 62: 0.43 ms of attack.
// calculate_clock_correction() turns that into samples and init_envelope()
// into a step.
static const int64_t ATTACK_STEP = (int64_t)((255.0 / (0.43 * 44.1)) * 65536.0);
// channel_attenuation_table -> the cents of pitch shift per pms setting
static const double PMS_CENTS[8] = { 0.0, 3.378, 5.0646, 6.7495,
                                     10.1143, 20.1699, 40.1076, 79.307 };

// ---------------------------------------------------------------- setup ----
// Slot 0 as a PCM voice at exactly one source sample per output sample, full
// volume, no decay.
static void setup_slot0(uint32_t start, uint32_t endoff, uint32_t loopoff, bool bits12) {
    timer_write(0x00, 0x03);            // group 0 sync = 3 (all four slots PCM)

    pcm_write(0, 0, start & 0xFF);
    pcm_write(0, 1, (start >> 8) & 0xFF);
    pcm_write(0, 2, (start >> 16) & 0x7F);
    pcm_write(0, 3, endoff & 0xFF);
    pcm_write(0, 4, (endoff >> 8) & 0xFF);
    pcm_write(0, 5, (endoff >> 16) & 0x7F);
    pcm_write(0, 6, loopoff & 0xFF);
    pcm_write(0, 7, (loopoff >> 8) & 0xFF);
    pcm_write(0, 8, (loopoff >> 16) & 0x7F);
    pcm_write(0, 9, bits12 ? 0x04 : 0x00);          // fs = 0, 8 or 12 bit

    fm_write(0, 0, 0x3, 0x01);          // multiple 1
    fm_write(0, 0, 0x4, 0x00);          // total level 0 = unity gain
    fm_write(0, 0, 0x5, 0x1F);          // attack rate 31, keyscale 0
    fm_write(0, 0, 0x6, 0x00);          // decay1 rate 0 -> no decay
    fm_write(0, 0, 0x7, 0x00);          // decay2 rate 0
    fm_write(0, 0, 0x8, 0x00);          // release 0, decay1 level 0
    fm_write(0, 0, 0x9, 0x00);          // fns low
    fm_write(0, 0, 0xA, 0x00);          // block 0, fns high -> step == 1.0
    fm_write(0, 0, 0xB, 0x07);          // waveform 7 = external (PCM)
    fm_write(0, 0, 0xD, 0x00);          // ch0/ch1 attenuation 0 dB
    fm_write(0, 0, 0xE, 0x00);          // ch2/ch3 attenuation 0 dB
}

static void key_on()  { fm_write(0, 0, 0x0, 0x01); }
static void key_off() { fm_write(0, 0, 0x0, 0x00); }

// One FM operator of group 0. `bank` is 0..3; sel 0 selects group 0.
// block 0 with fns 0x800 and multiple 1 gives a phase step of exactly 1.0.
static void setup_fm_op(int bank, uint8_t waveform, uint8_t tl, uint8_t feedback,
                        uint8_t alg) {
    fm_write(bank, 0, 0x3, 0x01);                       // multiple 1
    fm_write(bank, 0, 0x4, tl);
    fm_write(bank, 0, 0x5, 0x1F);                       // attack 31, keyscale 0
    fm_write(bank, 0, 0x6, 0x00);
    fm_write(bank, 0, 0x7, 0x00);
    fm_write(bank, 0, 0x8, 0x00);
    fm_write(bank, 0, 0x9, 0x00);                       // fns low
    fm_write(bank, 0, 0xA, 0x08);                       // block 0, fns = 0x800
    fm_write(bank, 0, 0xB, (uint8_t)((feedback << 4) | waveform));
    fm_write(bank, 0, 0xC, alg);
    fm_write(bank, 0, 0xD, 0x00);                       // ch0/ch1 0 dB
    fm_write(bank, 0, 0xE, 0x00);                       // ch2/ch3 0 dB
}

// Park a slot-4 PCM voice on the block of zeros in the sample ROM so it
// contributes nothing to the mix.
//
// The PCM bank addresses slots as 12*(sel>>2) + 4*(sel&3), so it reaches only
// the twelve slots that are multiples of four -- group 0, 4 or 8 -- and every
// fourth select is invalid. Slot 4 of group 0 is slot 36, which is sel 12, not
// sel 3. Using sel 3 writes nothing at all, and the untouched voice then plays
// from address 0 and buries the operator under a constant offset.
static const uint8_t PCM_SEL_G0_BANK3 = 12;

static void silence_pcm_bank3() {
    const uint8_t s = PCM_SEL_G0_BANK3;
    pcm_write(s, 0, 0x00); pcm_write(s, 1, 0x00); pcm_write(s, 2, 0x10);
    pcm_write(s, 3, 0xFF); pcm_write(s, 4, 0x0F); pcm_write(s, 5, 0x00);
    pcm_write(s, 6, 0x00); pcm_write(s, 7, 0x00); pcm_write(s, 8, 0x00);
    pcm_write(s, 9, 0x00);
}

static void reset_dut() {
    dut->reset = 1;
    dut->wr = 0; dut->rd = 0; dut->addr = 0; dut->din = 0;
    dut->sdr_ack = 0; dut->sdr_dout = 0;
    sdr_req_prev = 0; sdr_busy = false;
    dut->fl_ack = 0;
    fl_req_prev = 0; fl_busy = false;
    dbg_w_hits = 0;
    run(20);
    dut->reset = 0;
    run(20);
    tick_acc = 0;
}

// The engine picks up a key-on when its pass next reaches that slot, so which
// output sample is the note's first depends on where in the pass the write
// landed. Find that alignment once, then require exactness from there.
static int find_alignment(uint32_t start, bool bits12, int settle) {
    for (int i = 0; i < settle; i++) next_sample();
    int16_t got = next_sample();
    for (int d = 0; d <= 4; d++) {
        Phase p; p.endoff = 0x7FFFF; p.loopoff = 0; p.step = 65536;
        p.stepptr = (uint64_t)(settle - d) * 65536;
        int16_t want = bits12 ? expect_12bit(start, p) : expect_8bit(start, p);
        if (want == got) return settle - d;
    }
    return -1;
}

// ------------------------------------------------------------------ tests --

static void test_8bit_playback() {
    reset_dut();
    const uint32_t start = 0x1000;
    setup_slot0(start, 0x7FFFF, 0, false);
    key_on();

    // The envelope climbs from -60 dB; at attack rate 31 that is about a dozen
    // samples. Everything after that must be exact.
    int idx = find_alignment(start, false, 40);
    if (idx < 0) { fail("8-bit: no plausible alignment in the first samples"); return; }

    Phase p; p.endoff = 0x7FFFF; p.loopoff = 0; p.step = 65536;
    p.stepptr = (uint64_t)idx * 65536;
    p.advance();

    int bad = 0;
    for (int i = 0; i < 300; i++) {
        p.wrap();
        int16_t want = expect_8bit(start, p);
        int16_t got  = next_sample();
        if (got != want) {
            if (bad < 5) printf("FAIL: 8-bit sample %d (idx %u): want=%d got=%d\n",
                                i, (uint32_t)(p.stepptr >> 16), want, got);
            bad++;
        }
        p.advance();
    }
    errors += bad;
    printf("8-bit playback: 300 samples, %d mismatches (alignment %d)\n", bad, idx);
}

// 12 bit packs two samples into three bytes and the two halves unpack
// differently -- the classic place to get a nibble the wrong way round.
static void test_12bit_playback() {
    reset_dut();
    const uint32_t start = 0x2000;
    setup_slot0(start, 0x7FFFF, 0, true);
    key_on();

    int idx = find_alignment(start, true, 40);
    if (idx < 0) { fail("12-bit: no plausible alignment in the first samples"); return; }

    Phase p; p.endoff = 0x7FFFF; p.loopoff = 0; p.step = 65536;
    p.stepptr = (uint64_t)idx * 65536;
    p.advance();

    int bad = 0;
    for (int i = 0; i < 200; i++) {
        p.wrap();
        int16_t want = expect_12bit(start, p);
        int16_t got  = next_sample();
        if (got != want) {
            if (bad < 5) printf("FAIL: 12-bit sample %d: want=%d got=%d\n", i, want, got);
            bad++;
        }
        p.advance();
    }
    errors += bad;
    printf("12-bit playback: 200 samples, %d mismatches (alignment %d)\n", bad, idx);
}

// A short loop has to fold back and raise the slot's end flag. Note the fold
// subtracts (end - loop), so the repeating run is one shorter than the region.
static void test_loop_and_end_status() {
    reset_dut();
    const uint32_t start = 0x4000, endoff = 15, loopoff = 0;
    setup_slot0(start, endoff, loopoff, false);
    key_on();

    for (int i = 0; i < 40; i++) next_sample();

    // Alignment has to be found inside the loop, so sweep the phase instead.
    int16_t first = next_sample();
    int idx = -1;
    for (int d = 0; d <= (int)endoff; d++) {
        Phase p; p.endoff = endoff; p.loopoff = loopoff; p.step = 65536;
        p.stepptr = (uint64_t)d * 65536;
        if (expect_8bit(start, p) == first) { idx = d; break; }
    }
    if (idx < 0) { fail("loop: no plausible phase matched"); return; }

    Phase p; p.endoff = endoff; p.loopoff = loopoff; p.step = 65536;
    p.stepptr = (uint64_t)idx * 65536;
    p.advance();

    int bad = 0;
    for (int i = 0; i < 100; i++) {
        p.wrap();
        int16_t want = expect_8bit(start, p);
        int16_t got  = next_sample();
        if (got != want) {
            if (bad < 5) printf("FAIL: loop sample %d (idx %u): want=%d got=%d\n",
                                i, (uint32_t)(p.stepptr >> 16), want, got);
            bad++;
        }
        p.advance();
    }
    errors += bad;
    if (!p.looped) fail("loop: the reference never wrapped, so the test proved nothing");
    printf("loop playback: 100 samples, %d mismatches\n", bad);

    // Status register 1: bits 3..6 are the low four end flags, and slot 0 is
    // bit 0 of end_status, so it shows up at bit 3.
    dut->addr = 0; dut->eval();
    if (!(dut->dout & 0x08)) fail("end status for slot 0 never set after looping");
    else printf("end status: set\n");
}

// Timer A fires every 384 * (1024 - n) master clocks, i.e. every (1024 - n)
// sample periods, and raises the IRQ. It is what makes the driver sequence.
static void test_timer_a() {
    reset_dut();
    timer_write(0x10, 0xFF);            // timerA[9:2]
    timer_write(0x11, 0x03);            // timerA[1:0] -> 1023, period 1 sample
    timer_write(0x13, 0x05);            // bit 0 = load, bit 2 = IRQ enable

    int fired = 0;
    for (int i = 0; i < 50; i++) {
        next_sample();
        if (dut->irq) {
            fired++;
            timer_write(0x13, 0x15);    // bit 4 resets timer A
            dut->eval();
            if (dut->irq) fail("timer A IRQ did not clear on reset");
            timer_write(0x13, 0x05);
        }
    }
    if (fired < 40) {
        printf("FAIL: timer A fired %d times in 50 sample periods, expected ~50\n", fired);
        errors++;
    } else {
        printf("timer A: fired %d times in 50 sample periods\n", fired);
    }
}

// Key off drops the voice into release; with a fast release rate it has to
// actually reach silence.
static void test_key_off_release() {
    reset_dut();
    setup_slot0(0x1000, 0x7FFFF, 0, false);
    fm_write(0, 0, 0x8, 0x0F);          // release rate 15 -> quick
    key_on();
    for (int i = 0; i < 40; i++) next_sample();

    bool sounding = false;
    for (int i = 0; i < 8; i++) if (next_sample() != 0) sounding = true;
    if (!sounding) fail("slot was silent before key off");

    key_off();
    for (int i = 0; i < 400; i++) next_sample();
    int16_t after = next_sample();
    if (after != 0) {
        printf("FAIL: still sounding %d after key off and 400 samples\n", after);
        errors++;
    } else {
        printf("key off: released to silence\n");
    }
}

// ------------------------------------------------------------- FM tests ---

// Algorithm 15 in 4-operator mode is four independent carriers with no
// modulation, so with three of them silenced the output is one bare waveform.
static void test_fm_carrier() {
    const int TL = 8;                   // a real attenuation, so the total
    reset_dut();                        // level path is actually exercised
    timer_write(0x00, 0x00);            // group 0 sync = 0, 4-operator FM
    setup_fm_op(0, 0, TL, 0, 0x0F);     // operator 1: sine, alg 15
    setup_fm_op(1, 7, 0x00, 0, 0x0F);   // operators 2 and 3: waveform 7 = silent
    setup_fm_op(2, 7, 0x00, 0, 0x0F);
    setup_fm_op(3, 7, 0x00, 0, 0x0F);   // operator 4 falls through to PCM
    silence_pcm_bank3();
    key_on();

    for (int i = 0; i < 40; i++) next_sample();

    // Phase advances by exactly one table entry a sample. A single sample is
    // not enough to locate it -- the sine takes most values twice a period, so
    // the first match is often the wrong one and everything after it reads as
    // a one-sample lag. Require four in a row.
    int64_t gain = (env_volume(0) * total_level(TL)) >> 16;
    int16_t seed[4];
    for (int j = 0; j < 4; j++) seed[j] = next_sample();
    int ph = -1;
    for (int p = 0; p < 1024 && ph < 0; p++) {
        bool ok = true;
        for (int j = 0; j < 4; j++)
            if ((int16_t)((wave0((p + j) & 1023) * gain) >> 16) != seed[j]) ok = false;
        if (ok) ph = p;
    }
    if (ph < 0) { fail("fm carrier: output matched no point on the waveform"); return; }
    ph += 3;
    if (gain >= 65536) fail("fm carrier: total level had no effect");

    int bad = 0;
    for (int i = 1; i <= 300; i++) {
        int16_t want = (int16_t)((wave0((ph + i) & 1023) * gain) >> 16);
        int16_t got  = next_sample();
        if (got != want) {
            if (bad < 5) printf("FAIL: fm carrier %d: want=%d got=%d\n", i, want, got);
            bad++;
        }
    }
    errors += bad;
    printf("fm carrier: 300 samples, %d mismatches (total level gain %lld/65536)\n",
           bad, (long long)gain);
}

// The heart of FM: operator 1 modulates operator 3's phase. Uses sync 1, whose
// algorithm 0 is exactly that pair with the modulator kept out of the mix.
static void test_fm_modulation() {
    const int FEEDBACK = 3;             // modulation_level[3] = 2
    reset_dut();
    timer_write(0x00, 0x01);            // group 0 sync = 1, two 2-op pairs
    setup_fm_op(0, 0, 0x00, 0, 0x00);           // pair 0 operator 1: modulator
    setup_fm_op(2, 0, 0x00, FEEDBACK, 0x00);    // pair 0 operator 3: carrier
    setup_fm_op(1, 7, 0x00, 0, 0x00);           // pair 1: silent
    setup_fm_op(3, 7, 0x00, 0, 0x00);
    key_on();

    for (int i = 0; i < 40; i++) next_sample();

    // Both operators step by exactly one entry a sample and started together,
    // so one phase offset describes the pair.
    int16_t first = next_sample();
    int ph = -1;
    for (int p = 0; p < 1024; p++) {
        int64_t mod = ((int64_t)wave0(p) << 8) * MODULATION_LEVEL[FEEDBACK];
        uint32_t sum = (uint32_t)((int64_t)p * 65536 + mod);
        if (wave0((sum >> 16) & 1023) == first) { ph = p; break; }
    }
    if (ph < 0) { fail("fm modulation: no phase matched the first sample"); return; }

    int bad = 0;
    for (int i = 1; i <= 300; i++) {
        int p = ph + i;
        int64_t mod = ((int64_t)wave0(p & 1023) << 8) * MODULATION_LEVEL[FEEDBACK];
        uint32_t sum = (uint32_t)((int64_t)p * 65536 + mod);
        int16_t want = wave0((sum >> 16) & 1023);
        int16_t got  = next_sample();
        if (got != want) {
            if (bad < 5) printf("FAIL: fm modulation %d: want=%d got=%d\n", i, want, got);
            bad++;
        }
    }
    errors += bad;
    printf("fm modulation: 300 samples, %d mismatches\n", bad);
}

// The full 4-operator chain, algorithm 0: operator 1 feeds back into itself
// and then modulates 3, which modulates 2, which modulates 4, and only 4 is
// heard. This is the only test that exercises the multi-step result chain and
// the feedback state, so it models both straight out of calculate_op() and
// set_feedback().
static void test_fm_chain_feedback() {
    const int FB1 = 5;                  // feedback_level[5] = 16
    const int M3 = 3, M2 = 4, M4 = 2;   // modulation_level 2, 1, 4
    reset_dut();
    timer_write(0x00, 0x00);            // group 0 sync = 0, 4-operator FM
    setup_fm_op(0, 0, 0x00, FB1, 0x00); // operator 1, algorithm 0
    setup_fm_op(2, 0, 0x00, M3,  0x00); // operator 3
    setup_fm_op(1, 0, 0x00, M2,  0x00); // operator 2
    setup_fm_op(3, 0, 0x00, M4,  0x00); // operator 4, the only carrier
    key_on();

    // The feedback state depends on every sample that came before it,
    // including the ones where the envelope had not finished attacking, so
    // this model has to run from the note's first sample and carry the
    // envelope too. All four operators share the same envelope settings and
    // the same phase step of exactly one entry.
    const int N = 260;
    std::vector<int16_t> model(N);
    int64_t fb0 = 0, fb1 = 0;
    int64_t vol = (int64_t)(255 - 160) << 16;

    for (int n = 0; n < N; n++) {
        vol += ATTACK_STEP;                       // update_envelope, attack
        if (vol > ((int64_t)255 << 16)) vol = (int64_t)255 << 16;
        int64_t gain = env_volume(255 - (int)(vol >> 16));   // tl 0 is unity

        auto op = [&](int64_t modin) {
            uint32_t sum = (uint32_t)((int64_t)n * 65536 + modin);
            return (wave0((sum >> 16) & 1023) * gain) >> 16;
        };

        int64_t r1 = op((fb0 + fb1) / 2);         // C division, toward zero
        fb0 = fb1;
        fb1 = ((r1 << 8) * 16) / 16;              // set_feedback, level 16
        int64_t r3 = op((r1 << 8) * MODULATION_LEVEL[M3]);
        int64_t r2 = op((r3 << 8) * MODULATION_LEVEL[M2]);
        model[n]   = (int16_t)op((r2 << 8) * MODULATION_LEVEL[M4]);
    }

    // The device needs a few samples to reach the note, so read a little more
    // than the model and slide it into place. Alignment is checked over a long
    // window, not one sample, so a coincidental match cannot pass.
    const int SLACK = 8;
    std::vector<int16_t> dev(N + SLACK);
    for (int i = 0; i < N + SLACK; i++) dev[i] = next_sample();

    int best = -1;
    for (int d = 0; d <= SLACK && best < 0; d++) {
        bool ok = true;
        for (int j = 40; j < 140 && ok; j++) if (dev[j + d] != model[j]) ok = false;
        if (ok) best = d;
    }
    if (best < 0) { fail("fm chain: could not line up with the model"); return; }

    int bad = 0;
    for (int j = 0; j < N; j++) {
        if (dev[j + best] != model[j]) {
            if (bad < 5) printf("FAIL: fm chain %d: want=%d got=%d\n",
                                j, model[j], dev[j + best]);
            bad++;
        }
    }
    errors += bad;
    if (fb1 == 0) fail("fm chain: feedback never became non-zero");
    printf("fm chain + feedback: %d samples, %d mismatches (offset %d)\n", N, bad, best);
}

// Every algorithm of every sync mode, against a transcription of the switch
// statements in ymf271.cpp's sound_stream_update().
//
// This is the piece most like the sprite decrypt tables in PLAN.md section 5.4:
// 28 wiring diagrams read by eye into a table, where one wrong bit is a voice
// that sounds plausible but wrong. The RTL encodes them as in_mask/fb/out_mask;
// the model below follows MAME's control flow instead, so agreeing means the
// table is right rather than merely self-consistent.
struct AlgModel {
    int64_t fb0 = 0, fb1 = 0;
    int64_t vol = (int64_t)(255 - 160) << 16;
    int fbk1 = 0;                       // operator 1's feedback field
    int mod[4] = {0, 0, 0, 0};          // each operator's modulation depth field

    // One sample. `n` is the shared phase, in whole table entries.
    int64_t sample(int sync, int alg, int n) {
        vol += ATTACK_STEP;
        if (vol > ((int64_t)255 << 16)) vol = (int64_t)255 << 16;
        int64_t gain = env_volume(255 - (int)(vol >> 16));

        auto op = [&](int which, int64_t modin) -> int64_t {
            uint32_t sum = (uint32_t)((int64_t)n * 65536 + modin);
            return (wave0((sum >> 16) & 1023) * gain) >> 16;
        };
        auto pm = [&](int which, int64_t v) { return (v << 8) * MODULATION_LEVEL[mod[which]]; };
        auto feedback_in = [&]() { return (fb0 + fb1) / 2; };
        auto set_fb = [&](int64_t v) {
            fb0 = fb1;
            fb1 = ((v << 8) * FEEDBACK_LEVEL[fbk1]) / 16;
        };
        // MAME reads the average and shifts the history in the same call, so
        // the shift happens whether or not set_feedback() runs afterwards.
        auto op1_feedback = [&]() {
            int64_t in = feedback_in();
            return op(0, in);
        };

        int64_t o1 = 0, o2 = 0, o3 = 0, o4 = 0, p1, p2, p3;
        if (sync == 0) {
            p1 = op1_feedback();
            switch (alg) {
            case 0: set_fb(p1); p3=op(2,pm(2,p1)); p2=op(1,pm(1,p3)); o4=op(3,pm(3,p2)); break;
            case 1: p3=op(2,pm(2,p1)); set_fb(p3); p2=op(1,pm(1,p3)); o4=op(3,pm(3,p2)); break;
            case 2: set_fb(p1); p3=op(2,0); p2=op(1,pm(1,p1+p3)); o4=op(3,pm(3,p2)); break;
            case 3: set_fb(p1); p3=op(2,0); p2=op(1,pm(1,p3)); o4=op(3,pm(3,p1+p2)); break;
            case 4: set_fb(p1); p3=op(2,pm(2,p1)); p2=op(1,0); o4=op(3,pm(3,p3+p2)); break;
            case 5: p3=op(2,pm(2,p1)); set_fb(p3); p2=op(1,0); o4=op(3,pm(3,p3+p2)); break;
            case 6: set_fb(p1); o3=op(2,pm(2,p1)); p2=op(1,0); o4=op(3,pm(3,p2)); break;
            case 7: p3=op(2,pm(2,p1)); set_fb(p3); o3=p3; p2=op(1,0); o4=op(3,pm(3,p2)); break;
            case 8: set_fb(p1); o1=p1; p3=op(2,0); p2=op(1,pm(1,p3)); o4=op(3,pm(3,p2)); break;
            case 9: set_fb(p1); o1=p1; p3=op(2,0); p2=op(1,0); o4=op(3,pm(3,p3+p2)); break;
            case 10: set_fb(p1); o3=op(2,pm(2,p1)); o2=op(1,0); o4=op(3,0); break;
            case 11: p3=op(2,pm(2,p1)); set_fb(p3); o3=p3; o2=op(1,0); o4=op(3,0); break;
            case 12: set_fb(p1); o3=op(2,pm(2,p1)); o2=op(1,pm(1,p1)); o4=op(3,pm(3,p1)); break;
            case 13: set_fb(p1); o1=p1; p3=op(2,0); o2=op(1,pm(1,p3)); o4=op(3,0); break;
            case 14: set_fb(p1); o1=p1; o3=op(2,pm(2,p1)); p2=op(1,0); o4=op(3,pm(3,p2)); break;
            default: set_fb(p1); o1=p1; o3=op(2,0); o2=op(1,0); o4=op(3,0); break;
            }
        } else {                                   // sync 2, three operators
            p1 = op1_feedback();
            switch (alg & 7) {
            case 0: set_fb(p1); p3=op(2,pm(2,p1)); o2=op(1,pm(1,p3)); break;
            case 1: p3=op(2,pm(2,p1)); set_fb(p3); o2=op(1,pm(1,p3)); break;
            case 2: set_fb(p1); p3=op(2,0); o2=op(1,pm(1,p1+p3)); break;
            case 3: set_fb(p1); o1=p1; p3=op(2,0); o2=op(1,pm(1,p3)); break;
            case 4: set_fb(p1); o3=op(2,pm(2,p1)); o2=op(1,0); break;
            case 5: p3=op(2,pm(2,p1)); set_fb(p3); o3=p3; o2=op(1,0); break;
            case 6: set_fb(p1); o1=p1; o3=op(2,0); o2=op(1,0); break;
            default: set_fb(p1); o1=p1; o3=op(2,pm(2,p1)); o2=op(1,0); break;
            }
        }
        int64_t acc = 4 * (o1 + o2 + o3 + o4);      // four channels at 0 dB
        int64_t v = acc >> 2;
        if (v >  32767) v =  32767;
        if (v < -32768) v = -32768;
        return v;
    }
};

static void test_all_algorithms() {
    const int FBK = 4, M[4] = { 0, 3, 5, 1 };
    const int N_CMP = 120;
    int total_bad = 0, tested = 0;

    for (int sync = 0; sync <= 2; sync += 2) {
        int nalg = (sync == 0) ? 16 : 8;
        for (int alg = 0; alg < nalg; alg++) {
            reset_dut();
            timer_write(0x00, (uint8_t)sync);
            setup_fm_op(0, 0, 0x00, FBK,  (uint8_t)alg);   // operator 1
            setup_fm_op(2, 0, 0x00, M[2], (uint8_t)alg);   // operator 3
            setup_fm_op(1, 0, 0x00, M[1], (uint8_t)alg);   // operator 2
            setup_fm_op(3, 0, 0x00, M[3], (uint8_t)alg);   // operator 4
            if (sync == 2) silence_pcm_bank3();            // slot 4 is PCM here
            key_on();

            const int N = 140, SLACK = 8;
            AlgModel m;
            m.fbk1 = FBK;
            for (int k = 0; k < 4; k++) m.mod[k] = M[k];
            std::vector<int16_t> model(N);
            for (int n = 0; n < N; n++) model[n] = (int16_t)m.sample(sync, alg, n);

            std::vector<int16_t> dev(N + SLACK);
            for (int i = 0; i < N + SLACK; i++) dev[i] = next_sample();

            int best = -1;
            for (int d = 0; d <= SLACK && best < 0; d++) {
                bool ok = true;
                for (int j = 40; j < 120 && ok; j++) if (dev[j + d] != model[j]) ok = false;
                if (ok) best = d;
            }
            if (best < 0) {
                printf("FAIL: sync %d algorithm %d: no alignment with the model\n", sync, alg);
                errors++;
                continue;
            }
            // Comparison starts once the envelope has saturated in both. The
            // alignment above can only pin the PHASE, which is periodic; the
            // envelope is monotonic and there is no way to observe exactly
            // which output sample the device treated as the note's first. A
            // few samples of attack are therefore not comparable, and they are
            // the only place these ever differed -- by a couple of counts, at
            // -60 dB, while the following 120 match exactly.
            const int FROM = 20;
            int bad = 0;
            for (int j = FROM; j < N; j++) if (dev[j + best] != model[j]) {
                if (bad < 3) printf("   sync %d alg %2d: j=%3d want=%6d got=%6d\n",
                                    sync, alg, j, model[j], dev[j + best]);
                bad++;
            }
            if (bad) printf("FAIL: sync %d algorithm %d: %d/%d samples differ\n",
                            sync, alg, bad, N - FROM);
            total_bad += bad;
            tested++;
        }
    }
    errors += total_bad;
    printf("algorithms: %d networks checked (16 four-operator, 8 three-operator), "
           "%d samples each, %d mismatches\n", tested, N_CMP, total_bad);
}

// LFO amplitude. With the LFO frequency at 0 the phase never moves, so a
// square wave sits at its first point and the depth is a constant this can
// predict exactly.
static void test_lfo_amplitude() {
    reset_dut();
    timer_write(0x00, 0x00);
    setup_fm_op(0, 0, 0x00, 0, 0x0F);
    setup_fm_op(1, 7, 0x00, 0, 0x0F);
    setup_fm_op(2, 7, 0x00, 0, 0x0F);
    setup_fm_op(3, 7, 0x00, 0, 0x0F);
    silence_pcm_bank3();
    fm_write(0, 0, 0x1, 0x00);          // lfoFreq 0 -> the phase stays put
    fm_write(0, 0, 0x2, 0x42);          // lfowave 2 (square), pms 0, ams 1
    key_on();

    for (int i = 0; i < 40; i++) next_sample();

    // alfo[square][0] = 65536, so lfo_volume = 65536 - ((65536*K)>>16) and the
    // gain at full modulation is 65536-K. Table 2-6-3 puts ams=1 at 5.90625 dB
    // down, so K is unity minus that gain -- not the gain itself, which is
    // what MAME uses; see the note above alfo_scaled in ymf271_synth.sv.
    int64_t ams1_k  = 65536 - (int64_t)(65536.0 / pow(10.0, 5.90625 / 20.0));
    int64_t lfo_vol = 65536 - ((65536LL * ams1_k) >> 16);
    int64_t env = (65536LL * lfo_vol) >> 16;            // ENV_VOL[0] = 65536
    int16_t seed[4];
    for (int j = 0; j < 4; j++) seed[j] = next_sample();
    int ph = -1;
    for (int p = 0; p < 1024 && ph < 0; p++) {
        bool ok = true;
        for (int j = 0; j < 4; j++)
            if ((int16_t)((wave0((p + j) & 1023) * env) >> 16) != seed[j]) ok = false;
        if (ok) ph = p;
    }
    if (ph < 0) { fail("lfo amplitude: no phase matched"); return; }
    ph += 3;

    int bad = 0;
    for (int i = 1; i <= 200; i++) {
        int16_t want = (int16_t)((wave0((ph + i) & 1023) * env) >> 16);
        int16_t got  = next_sample();
        if (got != want) {
            if (bad < 5) printf("FAIL: lfo amplitude %d: want=%d got=%d\n", i, want, got);
            bad++;
        }
    }
    errors += bad;
    if (lfo_vol >= 65536) fail("lfo amplitude: the test did not actually attenuate");
    // The point of the depth correction: full swing has to land on the
    // datasheet's dB, not somewhere 5 dB away from it.
    double depth_db = 20.0 * log10(65536.0 / (double)lfo_vol);
    if (fabs(depth_db - 5.90625) > 0.01)
        fail("lfo amplitude: ams=1 depth is not Table 2-6-3's 5.90625 dB");
    printf("lfo amplitude: 200 samples, %d mismatches (gain %lld/65536, %.3f dB)\n",
           bad, (long long)lfo_vol, depth_db);
}

// LFO pitch. Same trick: frequency 0 parks the square wave at +1, so the pitch
// shift is a fixed 2^(cents/1200) and the phase step is predictable.
static void test_lfo_pitch() {
    const int PMS = 7;                  // the deepest setting, 79.307 cents
    reset_dut();
    timer_write(0x00, 0x00);
    setup_fm_op(0, 0, 0x00, 0, 0x0F);
    setup_fm_op(1, 7, 0x00, 0, 0x0F);
    setup_fm_op(2, 7, 0x00, 0, 0x0F);
    setup_fm_op(3, 7, 0x00, 0, 0x0F);
    silence_pcm_bank3();
    fm_write(0, 0, 0x1, 0x00);
    fm_write(0, 0, 0x2, (uint8_t)(0x02 | (PMS << 3)));  // square, pms, ams 0
    key_on();

    for (int i = 0; i < 40; i++) next_sample();

    uint32_t plfo = (uint32_t)llround(65536.0 * pow(2.0, PMS_CENTS[PMS] / 1200.0));
    uint32_t step = (uint32_t)(((uint64_t)65536 * plfo) >> 16);
    if (step == 65536) fail("lfo pitch: the test did not actually shift the pitch");

    // Sweep the starting phase pointer, not just the table index: the step is
    // no longer a whole entry, so the fraction matters. Four consecutive
    // samples again, for the same reason as the carrier test.
    int16_t seed[4];
    for (int j = 0; j < 4; j++) seed[j] = next_sample();
    int64_t p0 = -1;
    for (int k = 0; k < 4096 && p0 < 0; k++) {
        bool ok = true;
        for (int j = 0; j < 4; j++) {
            uint64_t sp = (uint64_t)(k + j) * step;
            if (wave0((sp >> 16) & 1023) != seed[j]) ok = false;
        }
        if (ok) p0 = (int64_t)((uint64_t)(k + 3) * step);
    }
    if (p0 < 0) { fail("lfo pitch: no phase matched"); return; }

    int bad = 0;
    uint64_t sp = (uint64_t)p0;
    for (int i = 1; i <= 300; i++) {
        sp += step;
        int16_t want = wave0((sp >> 16) & 1023);
        int16_t got  = next_sample();
        if (got != want) {
            if (bad < 5) printf("FAIL: lfo pitch %d: want=%d got=%d\n", i, want, got);
            bad++;
        }
    }
    errors += bad;
    printf("lfo pitch: 300 samples, %d mismatches (step %u, was 65536)\n", bad, step);
}

// The wave memory read port (utility registers 0x14-0x17, data at offset 2).
// Two behaviours matter and both are easy to get backwards:
//   * the port is a read-AHEAD -- a read returns the latched byte and only
//     then advances and refetches, so the first read after setting an address
//     is a dummy and the stream starts at address+1;
//   * with the direction bit clear the port reads 0xFF, not data.
// The address is therefore set one BELOW the first byte wanted, which is the
// same convention the SPI cartridge's flash updater uses when it programs
// from 0x7FFFFF (PLAN.md section 0).
static void test_ext_memory_read() {
    const uint32_t A = 0x12345;             // first byte we want back

    // Direction bit clear: the port must not return data.
    uint32_t x = A - 1;
    timer_write(0x14, (uint8_t)(x & 0xff));
    timer_write(0x15, (uint8_t)((x >> 8) & 0xff));
    timer_write(0x16, (uint8_t)((x >> 16) & 0x7f));      // bit7 = 0 -> write dir
    uint8_t off = rd(0x2);
    if (off != 0xFF) {
        printf("FAIL: ext read with rw=0 returned %02X, want FF\n", off);
        errors++;
    }

    // Direction bit set: dummy read, then the ROM verbatim.
    timer_write(0x16, (uint8_t)(((x >> 16) & 0x7f) | 0x80));
    (void)rd(0x2);                          // the read-ahead's dummy

    int bad = 0;
    for (int i = 0; i < 32; i++) {
        uint8_t want = rom[A + i];
        uint8_t got  = rd(0x2);
        if (got != want) {
            if (bad < 5)
                printf("FAIL: ext read %d (addr %05X): want %02X got %02X\n",
                       i, A + i, want, got);
            bad++;
        }
    }
    errors += bad;
    printf("ext memory read: 32 bytes from 0x%05X, %d mismatches\n", A, bad);
}

// ----------------------------------------------------------------- flash --
// The SPI cartridge's sample flash, driven through the SAME port the sound
// program uses: utility registers 0x14-0x17 set an address and a direction and
// push bytes, and offset 2 reads them back. PLAN.md section 0 has the command
// trace this follows; the point of driving the real port is that a mistake in
// the port -- the pre-increment, the direction bit, the byte the register file
// forwards -- fails here rather than being papered over by a back door.
//
// The updater's own opening move is `address = 0x7FFFFF` so that the first
// pre-increment lands on 0, which is what open_session() does.
static void ext_seek(uint32_t a, bool read) {
    timer_write(0x14, (uint8_t)(a & 0xff));
    timer_write(0x15, (uint8_t)((a >> 8) & 0xff));
    timer_write(0x16, (uint8_t)(((a >> 16) & 0x7f) | (read ? 0x80 : 0x00)));
}

// One byte to the wave-memory port: the address pre-increments, so this lands
// at `seek + 1` counting from the last seek or write.
static void ext_put(uint8_t v) {
    timer_write(0x17, v);               // 0x17 is a TIMER-bank register, via 0xC/0xD
    run(40);                            // let the write retire into "SDRAM"
}

// Status polling as the updater does it: flip the direction bit and read. The
// address advances on every read, which is real behaviour and why the updater
// re-seeks before each session.
static uint8_t flash_status(uint32_t at) {
    ext_seek(at - 1, true);
    return rd(0x2);
}

static void wait_ready(uint32_t at, const char *what) {
    for (int i = 0; i < 200000; i++) {
        if (flash_status(at) & 0x80) return;
        run(20);
    }
    printf("FAIL: flash never went ready after %s\n", what);
    errors++;
}

static void test_flash_program() {
    dut->flash_en = 1;
    reset_dut();

    // A pattern that is not 0xFF anywhere, so "erased" and "written" cannot be
    // confused, and not the ramp the read tests use either.
    for (uint32_t i = 0; i < PCM_SIZE; i++) rom[i] = (uint8_t)(i * 91 + 7);

    // ---- 1. block erase, chip 0 block 1 ----------------------------------
    // 0x20 then 0xD0 at an address inside the block. Both are wave-memory
    // writes like any other, so the address pre-increments under them -- seek
    // one below, exactly as the updater does.
    const uint32_t BLK = 0x010000;
    ext_seek(BLK - 1, false);
    ext_put(0x20);
    ext_seek(BLK - 1, false);
    ext_put(0xD0);

    // The sweep is 32,768 writes; a status poll must report BUSY while it runs.
    // If it never does, the erase is finishing instantly and the updater would
    // be racing it on hardware.
    bool saw_busy = false;
    for (int i = 0; i < 40; i++) {
        if (!(flash_status(BLK) & 0x80)) { saw_busy = true; break; }
        run(5);
    }
    if (!saw_busy) { printf("FAIL: erase never reported busy\n"); errors++; }
    wait_ready(BLK, "block erase");

    int bad = 0;
    for (uint32_t i = 0; i < 0x10000; i++) if (rom[BLK + i] != 0xFF) bad++;
    if (bad) { printf("FAIL: %d bytes of the erased block are not FF\n", bad); errors++; }
    // ...and nothing outside it moved. The neighbouring blocks are what a
    // wrong block index or a sweep one bit too long would eat.
    for (uint32_t i = 0; i < 0x10000; i++) {
        if (rom[i] != (uint8_t)(i * 91 + 7)) { printf("FAIL: erase ran below its block at %06X\n", i); errors++; break; }
    }
    for (uint32_t i = 0x20000; i < 0x20100; i++) {
        if (rom[i] != (uint8_t)(i * 91 + 7)) { printf("FAIL: erase ran above its block at %06X\n", i); errors++; break; }
    }
    if (dut->dbg_erases != 1) {
        printf("FAIL: dbg_erases = %d, want 1\n", (int)dut->dbg_erases);
        errors++;
    }

    // ---- 2. byte programming ---------------------------------------------
    // 0x40 arms one byte, the next write is the datum, and the address the
    // datum lands at is the one AFTER the 0x40 -- the register pre-increments
    // under both. So a run of bytes is: seek, then 40/data pairs, with the
    // data landing at seek+2, seek+4, ... which is why the updater re-seeks.
    static const uint8_t payload[] = { 0x00, 0x12, 0x7F, 0x80, 0xF7, 0xA5 };
    for (int i = 0; i < (int)sizeof(payload); i++) {
        uint32_t at = BLK + 0x81 + i;
        ext_seek(at - 1, false);
        ext_put(0x40);
        ext_seek(at - 1, false);
        ext_put(payload[i]);
        wait_ready(at, "byte program");
    }
    for (int i = 0; i < (int)sizeof(payload); i++) {
        uint8_t got = rom[BLK + 0x81 + i];
        if (got != payload[i]) {
            printf("FAIL: programmed %02X at %06X, read back %02X\n",
                   payload[i], BLK + 0x81 + i, got);
            errors++;
        }
    }
    if (dut->dbg_progs != sizeof(payload)) {
        printf("FAIL: dbg_progs = %d, want %d\n",
               (int)dut->dbg_progs, (int)sizeof(payload));
        errors++;
    }

    // ---- 3. read array, through the chip's own port -----------------------
    // Still in status mode after the last program, so a read here must return
    // status and NOT sample memory -- that is the whole reason the override
    // exists. Then 0xFF puts the chip back and the same address reads data.
    uint8_t st = flash_status(BLK + 0x81);
    if (!(st & 0x80)) { printf("FAIL: status after programming = %02X\n", st); errors++; }

    ext_seek(BLK + 0x80, false);
    ext_put(0xFF);
    ext_seek(BLK + 0x80, true);
    (void)rd(0x2);                          // the read-ahead's dummy
    bad = 0;
    for (int i = 0; i < (int)sizeof(payload); i++) {
        uint8_t got = rd(0x2);
        if (got != payload[i]) {
            if (bad < 3)
                printf("FAIL: array read %d: want %02X got %02X\n", i, payload[i], got);
            bad++;
        }
    }
    errors += bad;

    // ---- 4. the identifier ------------------------------------------------
    // 0x90 at an even address reads the maker byte, odd the device byte. Not
    // used by the updater, but it is the cheapest proof the mode really is per
    // chip: chip 1 must still be in array mode while chip 0 is not.
    ext_seek(0x00FFFF, false);
    ext_put(0x90);
    ext_seek(0x00FFFF, true);
    (void)rd(0x2);                          // the read-ahead's dummy, as ever
    uint8_t maker = rd(0x2);                // fetched at 0x010000, so even
    if (maker != 0x89) { printf("FAIL: maker byte %02X, want 89\n", maker); errors++; }

    ext_seek(0x100000 - 1, true);           // chip 1: untouched, still array
    (void)rd(0x2);
    uint8_t other = rd(0x2);
    if (other != rom[0x100000]) {
        printf("FAIL: chip 1 answered %02X instead of array data %02X\n",
               other, rom[0x100000]);
        errors++;
    }

    // ---- 5. disabled means read-only --------------------------------------
    // A pre-flashed MRA and every SXX2E build hold flash_en low, and there the
    // same command sequence must do NOTHING -- sample memory is a mask ROM.
    dut->flash_en = 0;
    reset_dut();
    uint8_t before = rom[0x30000];
    ext_seek(0x30000 - 1, false);
    ext_put(0x40);
    ext_seek(0x30000 - 1, false);
    ext_put(0x5A);
    run(200);
    if (rom[0x30000] != before) {
        printf("FAIL: a write landed with flash_en low\n");
        errors++;
    }
    if (dut->dbg_progs != 0) { printf("FAIL: disabled flash counted a program\n"); errors++; }

    if (dut->dbg_drops != 0) {
        printf("FAIL: %d commands were dropped as busy\n", (int)dut->dbg_drops);
        errors++;
    }
    printf("sample flash: 1 block erased (%llu port writes), %d bytes programmed "
           "and read back through the array\n",
           (unsigned long long)fl_writes, (int)sizeof(payload));
}

// What the updater ACTUALLY does, logged out of MAME by
// tools/mame_flash_port.lua after the core stalled on hardware (PLAN.md 17.14):
// it erases both chips back to back without polling in between, waits for both,
// and then programs byte after byte with no status read at all. The first
// version of the flash had one erase engine and refused commands while busy, so
// on hardware it erased one block, dropped two commands and stopped -- with the
// music still playing, which is what made it look like a hang rather than a
// protocol bug.
static void test_flash_both_chips() {
    dut->flash_en = 1;
    reset_dut();
    for (uint32_t i = 0; i < PCM_SIZE; i++) rom[i] = (uint8_t)(i * 91 + 7);

    // ---- both chips erase at once ----------------------------------------
    // Exactly the trace's shape: 20 then D0 to chip 0, then 20 then D0 to
    // chip 1, with nothing in between.
    ext_seek(0x000000 - 1, false);      // wraps to 0x1FFFFF, as the updater's does
    ext_put(0x20);
    ext_put(0xD0);
    ext_seek(0x100000 - 1, false);
    ext_put(0x20);
    ext_put(0xD0);

    // Both must report busy. If the second chip is idle here it never got its
    // command -- the exact hardware failure this test exists for.
    int busy_seen = 0;
    for (int i = 0; i < 200; i++) {
        busy_seen |= dut->dbg_busy;
        if ((busy_seen & 3) == 3) break;
        run(50);
    }
    if ((busy_seen & 3) != 3) {
        printf("FAIL: chips busy mask reached only %d, want 3 (both erasing)\n", busy_seen);
        errors++;
    }

    wait_ready(0x000000, "chip 0 erase");
    wait_ready(0x100000, "chip 1 erase");

    int bad = 0;
    for (uint32_t i = 0; i < 0x10000; i++) {
        if (rom[i] != 0xFF)            bad++;
        if (rom[0x100000 + i] != 0xFF) bad++;
    }
    if (bad) { printf("FAIL: %d bytes across the two erased blocks are not FF\n", bad); errors++; }
    if (dut->dbg_erases != 2) {
        printf("FAIL: dbg_erases = %d, want 2\n", (int)dut->dbg_erases); errors++;
    }

    // ---- programming with no poll between bytes --------------------------
    // The trace goes 40, datum, 40, datum as fast as the Z80 can drive the
    // port. Nothing here waits, which is the point.
    static const uint8_t payload[] = { 0x03, 0xFC, 0xFB, 0xFB, 0x11, 0x22, 0x33, 0x44 };
    for (int i = 0; i < (int)sizeof(payload); i++) {
        uint32_t at = 0x000004 + i;
        ext_seek(at - 1, false);
        ext_put(0x40);
        ext_seek(at - 1, false);
        ext_put(payload[i]);
    }
    run(400);
    for (int i = 0; i < (int)sizeof(payload); i++) {
        if (rom[0x000004 + i] != payload[i]) {
            printf("FAIL: unpolled program %d: want %02X got %02X\n",
                   i, payload[i], rom[0x000004 + i]);
            errors++;
        }
    }
    if (dut->dbg_progs != sizeof(payload)) {
        printf("FAIL: dbg_progs = %d, want %d\n",
               (int)dut->dbg_progs, (int)sizeof(payload));
        errors++;
    }
    if (dut->dbg_drops != 0) {
        printf("FAIL: %d commands dropped -- a command must never be refused\n",
               (int)dut->dbg_drops);
        errors++;
    }
    // ---- sixteen erase pairs back to back, per chip ----------------------
    // What the updater really sends: every block of both chips, with nothing
    // waiting in between (PLAN.md 18.1). A single pending block per chip lets
    // each new pair restart the running sweep, and only the last block of each
    // survives -- so this asks for all 32 and counts them.
    for (uint32_t i = 0; i < PCM_SIZE; i++) rom[i] = (uint8_t)(i * 91 + 7);
    uint16_t erases0 = dut->dbg_erases;
    for (int blk = 0; blk < 16; blk++) {
        for (int chip = 0; chip < 2; chip++) {
            uint32_t a = ((uint32_t)chip << 20) | ((uint32_t)blk << 16);
            ext_seek(a - 1, false);
            ext_put(0x20);
            ext_put(0xD0);
        }
    }
    // Every sweep is 32,768 writes; 32 of them at ~15 cycles each is a while.
    for (int i = 0; i < 40000 && dut->dbg_busy; i++) run(500);
    if (dut->dbg_busy) { printf("FAIL: still erasing after the whole queue\n"); errors++; }
    int done = (int)dut->dbg_erases - (int)erases0;
    if (done != 32) { printf("FAIL: %d blocks erased, want 32\n", done); errors++; }
    bad = 0;
    for (uint32_t i = 0; i < PCM_SIZE; i++) if (rom[i] != 0xFF) bad++;
    if (bad) { printf("FAIL: %d bytes of the two chips are not erased\n", bad); errors++; }

    dut->flash_en = 0;
    printf("both chips: 2 blocks erased concurrently, %d bytes programmed "
           "unpolled, then all %d blocks queued back to back, %d drops\n",
           (int)sizeof(payload), done, (int)dut->dbg_drops);
}

// A flash write has to retire the sample-line cache, and this is the only test
// that can tell. Everything above reads the flash through the wave-memory port,
// which goes straight to memory; a PLAYING voice reads through a cached 64-bit
// line plus a per-slot copy of it, 49 copies in all, and a byte programmed into
// the line a voice is currently inside is exactly the case a valid bit cannot
// catch on its own (rtl/ymf271_synth.sv, cch_gen).
static void test_flash_write_invalidates_cache() {
    dut->flash_en = 1;
    reset_dut();
    // `rom` is left as main() built it -- rewriting it here would wipe the
    // block of silence at 0x100000 that every FM test below parks its leftover
    // PCM voice in, and they would then fail for reasons nothing to do with
    // this. Running before test_flash_program is what makes that safe.

    const uint32_t start = 0x40000;
    setup_slot0(start, 0x7FFFF, 0, false);
    key_on();
    int idx = find_alignment(start, false, 40);
    if (idx < 0) { fail("cache: no plausible alignment"); return; }

    Phase p; p.endoff = 0x7FFFF; p.loopoff = 0; p.step = 65536;
    p.stepptr = (uint64_t)idx * 65536;
    p.advance();

    // Walk to a line boundary and take that sample, which is what puts the
    // line in the cache with seven more bytes of it still to come.
    for (int guard = 0; guard < 16; guard++) {
        p.wrap();
        uint32_t i = (uint32_t)(p.stepptr >> 16);
        int16_t want = expect_8bit(start, p);
        if (next_sample() != want) { fail("cache: playback wrong before the write"); return; }
        p.advance();
        if (((start + i) & 7) == 0) break;
    }
    p.wrap();
    uint32_t at_line = (uint32_t)(p.stepptr >> 16);
    uint32_t line0 = (start + at_line) & ~7u;

    // Rewrite three bytes near the END of that line, so the voice cannot have
    // walked past them while the port was being driven -- ~340 clk_sys per
    // byte against 1299 for a sample.
    uint64_t t0 = sample_ticks;
    for (int k = 4; k <= 6; k++) {
        uint32_t a = line0 + k;
        ext_seek(a - 1, false);
        ext_put(0x40);
        ext_seek(a - 1, false);
        ext_put((uint8_t)(0xC0 + k));       // nothing the ramp would produce
        wait_ready(a, "cache-test program");
    }
    uint64_t missed = sample_ticks - t0;
    for (uint64_t i = 0; i < missed; i++) p.advance();

    p.wrap();
    uint32_t resume = (start + (uint32_t)(p.stepptr >> 16)) - line0;
    if (resume > 4) { fail("cache: the voice outran the write; test proves nothing"); return; }

    int bad = 0, checked = 0, rewritten = 0;
    while (((start + (uint32_t)(p.stepptr >> 16)) & ~7u) == line0) {
        p.wrap();
        uint32_t off = (start + (uint32_t)(p.stepptr >> 16)) - line0;
        int16_t want = expect_8bit(start, p);   // rom[] already holds the NEW byte
        int16_t got  = next_sample();
        if (got != want) {
            if (bad < 4)
                printf("FAIL: cache: line+%u: want=%d got=%d (stale line)\n", off, want, got);
            bad++;
        }
        checked++;
        if (off >= 4) rewritten++;
        p.advance();
    }
    errors += bad;
    dut->flash_en = 0;                      // leave the machine as it was found
    if (!rewritten) { fail("cache: no rewritten byte was reached"); return; }
    printf("flash write vs sample cache: %d bytes replayed from the live line, "
           "%d of them rewritten under it, %d stale\n", checked, rewritten, bad);
}

// ---------------------------------------------------------------- stereo --
// The cartridge board wires chip output 0 to the left speaker and output 1 to
// the right; the single board sums all four outputs into one. Every test above
// runs mono, so this is the only place the split is exercised.
//
// The arithmetic stays exact. With total level 0 and the envelope saturated a
// channel at 0 dB contributes (sample * 65536) >> 16 == sample and one at
// level 15 contributes (sample * 1) >> 16 == 0, so with ch0 loud and ch1
// silent the left speaker is sample >> 2 and the right is 0.
static void test_stereo_split() {
    dut->stereo = 1;
    reset_dut();
    const uint32_t start = 0x3000;
    setup_slot0(start, 0x7FFFF, 0, false);
    // ch0 0 dB, ch1 fully attenuated. ch2 and ch3 are left at 0 dB ON PURPOSE:
    // they reach no speaker on this board, so a wrong wiring that folds them
    // back in shows up here as three times the level rather than as silence.
    fm_write(0, 0, 0xD, 0x0F);
    key_on();

    int idx = -1;
    for (int i = 0; i < 40; i++) next_sample();
    int16_t got = next_sample();
    for (int d = 0; d <= 4; d++) {
        Phase p; p.endoff = 0x7FFFF; p.loopoff = 0; p.step = 65536;
        p.stepptr = (uint64_t)(40 - d) * 65536;
        if ((int16_t)(expect_8bit(start, p) >> 2) == got) { idx = 40 - d; break; }
    }
    if (idx < 0) { fail("stereo: no plausible alignment in the first samples"); return; }

    Phase p; p.endoff = 0x7FFFF; p.loopoff = 0; p.step = 65536;
    p.stepptr = (uint64_t)idx * 65536;
    p.advance();

    int bad_l = 0, bad_r = 0;
    for (int i = 0; i < 200; i++) {
        p.wrap();
        int16_t want = (int16_t)(expect_8bit(start, p) >> 2);
        int16_t l = next_sample();
        int16_t r = last_right();
        if (l != want) {
            if (bad_l < 5) printf("FAIL: stereo L sample %d: want=%d got=%d\n", i, want, l);
            bad_l++;
        }
        // "Off" is attenuation level 15, and channel_attenuation_table's last
        // entry is 1/65536, not 0. A negative sample therefore lands on -1
        // rather than 0 once the >>16 and the >>2 have both rounded toward
        // -inf. One LSB is the correct answer here, not a tolerance for slop.
        if (r < -1 || r > 0) {
            if (bad_r < 5) printf("FAIL: stereo R sample %d: want 0 or -1, got=%d\n", i, r);
            bad_r++;
        }
        p.advance();
    }
    errors += bad_l + bad_r;
    printf("stereo split: 200 samples, %d left / %d right mismatches\n", bad_l, bad_r);

    // The same registers on the single board. ch0, ch2 and ch3 are all at 0 dB
    // and ch1 is silent, so mono is three times what the left speaker just
    // carried -- and both sides must show it. If `stereo` did nothing, the
    // block above would have passed against a mono core too; this is what
    // makes that check mean something.
    dut->stereo = 0;
    reset_dut();
    setup_slot0(start, 0x7FFFF, 0, false);
    fm_write(0, 0, 0xD, 0x0F);
    key_on();

    idx = -1;
    for (int i = 0; i < 40; i++) next_sample();
    got = next_sample();
    for (int d = 0; d <= 4; d++) {
        Phase q; q.endoff = 0x7FFFF; q.loopoff = 0; q.step = 65536;
        q.stepptr = (uint64_t)(40 - d) * 65536;
        int16_t w = (int16_t)((3 * (int32_t)expect_8bit(start, q)) >> 2);
        if (got == w || got == (int16_t)(w - 1)) { idx = 40 - d; break; }
    }
    if (idx < 0) { fail("stereo: no plausible mono alignment"); return; }

    Phase q; q.endoff = 0x7FFFF; q.loopoff = 0; q.step = 65536;
    q.stepptr = (uint64_t)idx * 65536;
    q.advance();

    int bad_m = 0, bad_eq = 0;
    for (int i = 0; i < 200; i++) {
        q.wrap();
        int16_t want = (int16_t)((3 * (int32_t)expect_8bit(start, q)) >> 2);
        int16_t l = next_sample();
        int16_t r = last_right();
        // Same one-LSB residue as above: ch1 is level 15, so it adds -1 to the
        // sum on a negative sample instead of nothing.
        if (l != want && l != (int16_t)(want - 1)) {
            if (bad_m < 5) printf("FAIL: mono sample %d: want=%d got=%d\n", i, want, l);
            bad_m++;
        }
        if (r != l) bad_eq++;
        q.advance();
    }
    errors += bad_m + bad_eq;
    printf("mono sum:     200 samples, %d mismatches, %d L!=R\n", bad_m, bad_eq);
}

// ---------------------------------------------------------------------------
// One real page of the updater, replayed off MAME's Z80.
//
// Everything above drives the flash the way the DATASHEET says to. This drives
// it the way rdft2 actually does, which is not the same thing: the updater
// leaves the address register one behind, writes the 0x40 command THROUGH the
// same auto-incrementing port as the data, and then fixes only the LOW address
// byte before each datum. Three writes per byte, and the address arithmetic
// only works because of where the increments land.
//
// Hardware got one byte of this page wrong -- 0x29FE came back erased, twice,
// on two different builds, with the accepted-program count matching MAME's
// issued-command count exactly (PLAN.md 19.11). If that is a fault in the
// address arithmetic rather than in the SDRAM path underneath it, replaying the
// captured writes reproduces it here with everything visible.
static void test_flash_replay() {
    dut->flash_en = 1;
    reset_dut();

    // Erased, as the updater leaves it: a lost write and a written 0xFF are
    // then the same byte, which is exactly the ambiguity hardware presented.
    for (uint32_t i = REPLAY_BASE; i < REPLAY_BASE + 0x200; i++) rom[i] = 0xFF;

    // The capture starts mid-byte: the 0x40 for the page's first byte has
    // already gone in, at REPLAY_BASE, and the address register sits there.
    ext_seek(REPLAY_BASE - 1, false);
    ext_put(0x40);

    for (size_t i = 0; i < sizeof(REPLAY) / sizeof(REPLAY[0]); i++) {
        timer_write(REPLAY[i].reg, REPLAY[i].val);
        // A Z80 `out` is ~11 of its cycles and clk_sys is eight times its
        // clock, so consecutive port writes are ~88 apart. Close enough that a
        // write which needs the previous one to have retired still gets it.
        run(88);
    }
    run(400);

    int bad = 0;
    uint32_t first = 0;
    for (uint32_t i = 0; i < 256; i++) {
        if (rom[REPLAY_BASE + i] == REPLAY_EXPECT[i]) continue;
        if (!bad) first = i;
        bad++;
    }
    if (bad) {
        printf("FAIL: %d of 256 replayed bytes differ; first at %04X: "
               "want %02X got %02X\n", bad, REPLAY_BASE + first,
               REPLAY_EXPECT[first], rom[REPLAY_BASE + first]);
        errors++;
    } else {
        printf("replay: 256 bytes of rdft2's page 0x2900 match MAME byte for byte\n");
    }

    // ---- the instrument itself -------------------------------------------
    // The watch is what hardware will be asked to believe, so check it here
    // where the answer is already known. This page programs the watched
    // halfword twice: 0x29FE on the low lane, then 0x29FF on the high one.
    if (dut->dbg_w_progs != 2 || dut->dbg_w_be != 0x2 || dut->dbg_w_data != 0xFF) {
        printf("FAIL: watch saw %u writes, last be=%X data=%02X; want 2, be=2, FF\n",
               dut->dbg_w_progs, dut->dbg_w_be, dut->dbg_w_data);
        errors++;
    } else if (dut->dbg_w_erases || dut->dbg_w_er_after) {
        printf("FAIL: watch saw %u erases of a halfword nothing erased\n",
               dut->dbg_w_erases);
        errors++;
    } else {
        // Oldest first: 0x29FC low, 0x29FC high, 0x29FE low, 0x29FE high --
        // the two halfwords either side of the byte, both lanes each.
        static const uint32_t want[4] = {0x9FC << 2 | 1, 0x9FC << 2 | 2,
                                         0x9FE << 2 | 1, 0x9FE << 2 | 2};
        uint64_t tr = dut->dbg_w_trace;
        int trbad = 0;
        for (int i = 3; i >= 0; i--) {
            if ((uint32_t)(tr & 0x3FFF) != want[i]) trbad++;
            tr >>= 14;
        }
        if (trbad) {
            printf("FAIL: watch trace %014llX does not walk 29FC,29FC,29FE,29FE\n",
                   (unsigned long long)dut->dbg_w_trace);
            errors++;
        } else if (dbg_w_hits != 1 ||
                   dut->dbg_w_din != REPLAY_EXPECT[WATCH_BYTE - REPLAY_BASE]) {
            // The byte-level watch, which is the half that answers 19.14's
            // question: was this module HANDED the wrong datum, or did it make
            // one? It must fire exactly once for 0x29FE -- the halfword is
            // programmed twice, one lane each, and only the low one is this
            // byte -- carrying what MAME holds there, 0xFE. If this check ever
            // fails while the replay above passes, the instrument is lying and
            // nothing it reported on hardware means anything.
            printf("FAIL: byte watch fired %d times with din=%02X; "
                   "want 1 and %02X\n", dbg_w_hits, dut->dbg_w_din,
                   REPLAY_EXPECT[WATCH_BYTE - REPLAY_BASE]);
            errors++;
        } else {
            printf("watch: 2 writes to the watched halfword, last be=2 data=FF, "
                   "0 erases, trace walks its neighbours; byte watch fired once "
                   "with din=%02X\n", dut->dbg_w_din);
        }
    }

    // Nothing may land ABOVE the page either. A datum that misses its address
    // by a carry goes 256 bytes up, where the updater's next page would later
    // overwrite it -- which is precisely why hardware showed only ONE wrong
    // byte instead of two.
    int stray = 0;
    for (uint32_t i = REPLAY_BASE + 256; i < REPLAY_BASE + 0x200; i++)
        if (rom[i] != 0xFF) stray++;
    if (stray) {
        printf("FAIL: %d bytes written above the page\n", stray);
        errors++;
    }

    // The same page again with the SDRAM write port behaving as it does on
    // hardware: slow and irregular, because ch3 serves the Z80 first and the
    // flash last. A byte program arriving on a slot still waiting for the
    // previous write is counted in dbg_drops -- but a byte lost some OTHER way
    // is not, and that is the case worth catching.
    // Back to a known mode first. The capture ends mid-byte, with the chip
    // still expecting a datum, so the 0x40 that opens the next pass would be
    // PROGRAMMED rather than obeyed.
    reset_dut();
    uint32_t drops0 = dut->dbg_drops;
    fl_latency = 150;
    fl_jitter  = 120;
    for (uint32_t i = REPLAY_BASE; i < REPLAY_BASE + 0x200; i++) rom[i] = 0xFF;
    ext_seek(REPLAY_BASE - 1, false);
    ext_put(0x40);
    for (size_t i = 0; i < sizeof(REPLAY) / sizeof(REPLAY[0]); i++) {
        timer_write(REPLAY[i].reg, REPLAY[i].val);
        run(88);
    }
    run(4000);
    fl_latency = 14;
    fl_jitter  = 0;

    bad = 0; first = 0;
    for (uint32_t i = 0; i < 256; i++) {
        if (rom[REPLAY_BASE + i] == REPLAY_EXPECT[i]) continue;
        if (!bad) first = i;
        bad++;
    }
    uint32_t drops = dut->dbg_drops - drops0;
    if (bad) {
        printf("FAIL: contended replay: %d of 256 bytes differ; first at %04X: "
               "want %02X got %02X (%u drops)\n", bad, REPLAY_BASE + first,
               REPLAY_EXPECT[first], rom[REPLAY_BASE + first], drops);
        errors++;
    } else {
        printf("replay: byte for byte again with the write port stalled "
               "150-270 cycles (%u drops)\n", drops);
    }
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vtb_ymf_top;
    dut->stereo = 0;                        // every test but the first is mono
    dut->flash_en = 0;                      // ...and every test but the last has
                                            // a mask ROM where the samples live

    // A ramp with a stride coprime with 8, so a line-cache bug cannot hide
    // behind repeating values inside one fetched line.
    rom.resize(PCM_SIZE);
    for (uint32_t i = 0; i < PCM_SIZE; i++) rom[i] = (uint8_t)(i * 37 + 11);
    // A block of silence for parking PCM voices the FM tests cannot switch off.
    for (uint32_t i = 0x100000; i < 0x101000; i++) rom[i] = 0;

    // FIRST, on a machine nothing has played on yet. reset_dut() clears the
    // state machine but NOT the per-slot RAM, so voices an earlier test left
    // active keep sounding into the mix -- which is what silence_pcm_bank3()
    // exists to work around further down. Run last, this test saw a constant
    // 1408 in the right channel that had nothing to do with the routing.
    test_stereo_split();

    test_8bit_playback();
    // Straight after it, and for the same reason test_stereo_split runs first:
    // this one plays a PCM voice, and every FM test below leaves operators
    // configured in the banks a later key-on would restart.
    test_flash_write_invalidates_cache();
    test_12bit_playback();
    test_loop_and_end_status();
    test_timer_a();
    test_key_off_release();
    test_fm_carrier();
    test_fm_modulation();
    test_fm_chain_feedback();
    test_all_algorithms();
    test_lfo_amplitude();
    test_lfo_pitch();
    test_ext_memory_read();
    // Last: these rewrite `rom` and drive flash_en themselves.
    test_flash_program();
    test_flash_both_chips();
    test_flash_replay();

    delete dut;
    if (errors) {
        printf("\n%d FAILURES\n", errors);
        return 1;
    }
    printf("\nall ymf271 checks passed\n");
    return 0;
}
