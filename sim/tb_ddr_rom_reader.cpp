//============================================================================
//  SlopperPI - testbench for ddr_rom_reader
//
//  The ioctl download has always been the one path that could not be
//  simulated, and PLAN.md 10c is the bill for that: `ioctl_wr` was acted on
//  twice, every byte counted twice, and the first instrument to notice was a
//  MiSTer reporting 46,792,704 bytes for a 23,396,352 byte image. Fast loading
//  moves most of that path INSIDE the FPGA, where it can be tested, so it is.
//
//  Four things are checked, and each has a specific way of being wrong:
//
//  1. Fast download. ioctl_download rises and falls without a single write and
//     with ioctl_addr holding the length -- which is all the FPGA ever sees of
//     a DDR3 transfer. Every byte must come back out in order, exactly once.
//     Wrong endianness inside the 64-bit word, or an off-by-one on the last
//     partial word, both show up as a diff rather than as a count.
//
//  2. The strobe is ONE CYCLE WIDE. rom_loader runs on clk_ram at 2x this
//     clock and rising-edge detects, so a two-cycle strobe is two bytes to it.
//     That is 10c exactly, and it is checked here directly rather than
//     inferred from a byte count.
//
//  3. Slow download passes through untouched. An MRA without an `address`
//     attribute must still work, and the two existing sets' MRAs are the
//     regression that matters.
//
//  4. dl_download frames the whole replay. It has to stay high until the last
//     byte is handed over, because the core reset follows it; if it drops with
//     ioctl_download the 386 is released into an empty SDRAM.
//
//  Backpressure is irregular rather than absent, for the reason tb_rom_decode
//  gives: a source that only works against an always-ready sink is a source
//  that fails on real SDRAM.
//============================================================================

#include "Vddr_rom_reader.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

static Vddr_rom_reader *dut;
static int errors = 0;

static void fail(const char *what) {
    printf("FAIL: %s\n", what);
    errors++;
}

// ------------------------------------------------------------------ DDR3 ----
// A few cycles of latency and one 64-bit word per read, which is what the
// module asks for (burstcnt 1).
static std::vector<uint8_t> ddr;
static const uint32_t DDR_BASE = 0x30000000;

static int      ddr_delay = 0;
static bool     ddr_pending = false;
static uint32_t ddr_pending_addr = 0;

static void ddr_tick() {
    dut->ddr_dout_ready = 0;

    if (!ddr_pending && dut->ddr_rd && !dut->ddr_busy) {
        ddr_pending = true;
        ddr_pending_addr = dut->ddr_addr;
        ddr_delay = 4;
    } else if (ddr_pending && --ddr_delay <= 0) {
        uint64_t w = 0;
        // ddr_addr is a 64-bit WORD address; turn it back into bytes.
        uint64_t byte_addr = (uint64_t)ddr_pending_addr * 8;
        for (int i = 0; i < 8; i++) {
            uint64_t off = byte_addr + i - DDR_BASE;
            uint8_t b = (off < ddr.size()) ? ddr[off] : 0xAA;  // 0xAA = never valid
            w |= (uint64_t)b << (i * 8);
        }
        dut->ddr_dout = w;
        dut->ddr_dout_ready = 1;
        ddr_pending = false;
    }
}

// --------------------------------------------------------------- the sink ---
// Stands in for rom_loader: raises dl_wait when it takes a byte and holds it
// for a variable number of cycles, the way a real SDRAM write does.
static std::vector<uint8_t> got;
static int  sink_hold = 0;
static int  wr_high_run = 0;
static int  worst_wr_run = 0;
static bool check_pulse_width = true;

static void sink_tick() {
    if (dut->dl_wr) {
        got.push_back(dut->dl_dout);
        sink_hold = 1 + (int)(got.size() % 5);   // irregular, 1..5
        wr_high_run++;
        if (wr_high_run > worst_wr_run) worst_wr_run = wr_high_run;
    } else {
        wr_high_run = 0;
    }

    if (sink_hold > 0) {
        dut->dl_wait = 1;
        sink_hold--;
    } else {
        dut->dl_wait = 0;
    }
}

static uint64_t cycles = 0;

// dl_download has to be sampled DURING the low phase, not only after a full
// tick, and that is not a detail. rom_loader runs on clk_ram at 2x this clock
// and has an edge inside every clk_sys period, so it sees values a same-rate
// observer never does. Checking dl_download only between ticks made the dip
// test pass against a deliberately broken combinational version -- the dip is
// one clk_sys period wide, exactly the window a 2x consumer samples and a 1x
// testbench skips over. Watching the low phase models the consumer that
// actually exists.
static bool watch_dip = false;
static bool saw_dip   = false;

static void tick() {
    dut->clk = 0; dut->eval();
    if (watch_dip && !dut->dl_download) saw_dip = true;
    ddr_tick();
    sink_tick();
    dut->clk = 1; dut->eval();
    cycles++;
}

static void run(int n) { while (n--) tick(); }

static void reset_dut() {
    dut->reset = 1;
    dut->ioctl_download = 0;
    dut->ioctl_index = 0;
    dut->ioctl_addr = 0;
    dut->ioctl_wr = 0;
    dut->ioctl_dout = 0;
    dut->dl_wait = 0;
    dut->ddr_busy = 0;
    dut->ddr_dout = 0;
    dut->ddr_dout_ready = 0;
    ddr_pending = false;
    sink_hold = 0;
    run(8);
    dut->reset = 0;
    run(8);
    got.clear();
    worst_wr_run = 0;
    wr_high_run = 0;
}

// ------------------------------------------------------------------ tests ---

// A fast download of `n` bytes: the HPS has already filled DDR3, so all the
// FPGA sees is download high, download low, and the length in ioctl_addr.
static void test_fast(uint32_t n, const char *name) {
    reset_dut();

    ddr.assign(n, 0);
    for (uint32_t i = 0; i < n; i++) ddr[i] = (uint8_t)(i * 37 + 11);

    dut->ioctl_index = 0;
    dut->ioctl_download = 1;
    run(20);                                  // no ioctl_wr at all: that is the tell
    dut->ioctl_addr = n;
    dut->ioctl_download = 0;

    // dl_download MUST stay high until the last byte is handed over. This is
    // the property the core reset depends on, and it is checked by name rather
    // than left to show up as a short image: derive it combinationally instead
    // of registering it and it dips for one cycle exactly here, which
    // rom_loader reads as the end of the image -- it resets `part` and pulses
    // rom_ready, which starts the ROM checker on an image that is not there.
    uint64_t limit = (uint64_t)n * 40 + 20000;
    uint64_t start = cycles;
    watch_dip = true;
    saw_dip   = false;
    while (got.size() < n && (cycles - start) < limit) tick();
    watch_dip = false;
    if (saw_dip) {
        printf("FAIL: %s: dl_download went low before the last byte\n", name);
        errors++;
        return;
    }

    // And it must drop once the image is complete, or the core never leaves
    // reset.
    while (dut->dl_download && (cycles - start) < limit) tick();
    if (dut->dl_download) { fail("fast: dl_download never dropped (timed out)"); return; }

    if (got.size() != n) {
        printf("FAIL: %s: got %zu bytes, want %u\n", name, got.size(), n);
        errors++;
        return;
    }
    uint32_t bad = 0;
    for (uint32_t i = 0; i < n; i++) {
        if (got[i] != ddr[i]) {
            if (bad < 5) printf("FAIL: %s: byte %u want %02X got %02X\n",
                                name, i, ddr[i], got[i]);
            bad++;
        }
    }
    errors += bad;
    if (worst_wr_run > 1) {
        printf("FAIL: %s: dl_wr was high for %d consecutive cycles; rom_loader "
               "runs at 2x and would count that twice\n", name, worst_wr_run);
        errors++;
    }
    printf("%-22s %7u bytes, %u mismatches, strobe width %d, %llu cycles/byte\n",
           name, n, bad, worst_wr_run,
           (unsigned long long)((cycles - start) / (n ? n : 1)));
}

// Without an `address` attribute the HPS still streams bytes, and the module
// has to be a wire.
static void test_slow(uint32_t n) {
    reset_dut();

    std::vector<uint8_t> src(n);
    for (uint32_t i = 0; i < n; i++) src[i] = (uint8_t)(i * 91 + 7);

    dut->ioctl_index = 0;
    dut->ioctl_download = 1;
    run(4);

    for (uint32_t i = 0; i < n; i++) {
        while (dut->ioctl_wait) tick();       // honour the loader's back-pressure
        dut->ioctl_dout = src[i];
        dut->ioctl_wr = 1;
        tick();
        dut->ioctl_wr = 0;
        run(1);
    }
    dut->ioctl_addr = n;
    dut->ioctl_download = 0;
    run(200);

    if (got.size() != n) {
        printf("FAIL: slow: got %zu bytes, want %u\n", got.size(), n);
        errors++;
        return;
    }
    uint32_t bad = 0;
    for (uint32_t i = 0; i < n; i++) if (got[i] != src[i]) bad++;
    errors += bad;
    if (dut->dl_download) { fail("slow: dl_download still high after the download"); }
    printf("%-22s %7u bytes, %u mismatches (pass-through)\n", "slow download", n, bad);
}

// A download that writes nothing AND reports zero length must not start a
// replay -- that is what an empty or absent file looks like, and spinning on it
// would hang the core in reset forever.
static void test_empty() {
    reset_dut();
    dut->ioctl_index = 0;
    dut->ioctl_download = 1;
    run(20);
    dut->ioctl_addr = 0;
    dut->ioctl_download = 0;
    run(500);
    if (dut->dl_download) fail("empty: dl_download stuck high on a zero-length download");
    if (!got.empty())     fail("empty: bytes emitted for a zero-length download");
    printf("%-22s no replay, dl_download low\n", "zero length");
}

// Index 1 (the mod byte and codec config) is a normal byte download and must
// never be mistaken for a fast one.
static void test_other_index() {
    reset_dut();
    dut->ioctl_index = 1;
    dut->ioctl_download = 1;
    run(20);
    dut->ioctl_addr = 4;
    dut->ioctl_download = 0;
    run(500);
    if (dut->dl_download) fail("index 1: started a replay for a non-ROM index");
    if (!got.empty())     fail("index 1: emitted bytes for a non-ROM index");
    printf("%-22s ignored, as it must be\n", "index 1");
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vddr_rom_reader;

    // Sizes chosen around the 8-byte word boundary: exact multiples, one over,
    // one under, and a single byte. The last partial word is where an
    // off-by-one lives.
    test_fast(8,    "fast, one word");
    test_fast(1,    "fast, one byte");
    test_fast(7,    "fast, partial word");
    test_fast(9,    "fast, word + 1");
    test_fast(4096, "fast, 4 KB");

    test_slow(512);
    test_empty();
    test_other_index();

    delete dut;
    if (errors) { printf("\n%d FAILURES\n", errors); return 1; }
    printf("\nall ddr_rom_reader checks passed\n");
    return 0;
}
