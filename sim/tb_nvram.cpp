//============================================================================
//  SlopperPI - testbench for spi_nvram
//
//  Both directions of the sample flash's save file, against a behavioural
//  SDRAM: the LOAD writes an ioctl byte stream into the region, and the SAVE
//  reads it back through the same handshake hps_io uses.
//
//  This exists because the first version went to hardware untested and came
//  back as a two-megabyte file containing byte 0 twice followed by the first
//  eight bytes repeated 262,143 times (PLAN.md 18.8). Both faults are one line
//  each and both are caught here in under a second.
//
//  The save side is modelled exactly as sys/hps_io.sv drives it, because the
//  bugs lived in that protocol and not in the data path:
//
//    FIO_FILE_TX 0xAA   ioctl_upload <= 1, ioctl_rd <= 1     (no byte yet)
//    FIO_FILE_TX_DAT    fp_dout <= ioctl_din; addr++; ioctl_rd <= 1
//
//  so every DAT word takes the byte the core is presenting and asks for the
//  next one, and there is no way to stall.
//============================================================================

#include "Vspi_nvram.h"
#include "verilated.h"

#include <cstdio>
#include <cstdint>
#include <vector>

static const uint32_t PCM_BASE = 0x280000;
static const uint32_t NV_SIZE  = 0x200000;

static Vspi_nvram *dut;
static std::vector<uint8_t> sdram;
static int errors = 0;

// ---------------------------------------------------------------- SDRAM ----
// One outstanding transaction per port, a few cycles of latency each. The read
// port is deliberately SLOWER than the write: on hardware it shares ch5 with
// the YMF271's voice fetches, and the prefetch has to cover that.
static bool wr_busy = false, rd_busy = false;
static int  wr_wait = 0,     rd_wait = 0;
static bool wr_prev = false, rd_prev = false;

static void sdram_tick() {
    if (!wr_busy && (dut->wr_req != wr_prev)) {
        wr_prev = dut->wr_req; wr_busy = true; wr_wait = 6;
    } else if (wr_busy && --wr_wait <= 0) {
        uint32_t a = dut->wr_addr;
        for (int lane = 0; lane < 2; lane++)
            if (dut->wr_be & (1 << lane)) {
                uint32_t b = a + lane;
                if (b < sdram.size()) sdram[b] = (dut->wr_din >> (8 * lane)) & 0xFF;
            }
        dut->wr_ack = dut->wr_req; wr_busy = false;
    }

    if (!rd_busy && (dut->rd_req != rd_prev)) {
        rd_prev = dut->rd_req; rd_busy = true; rd_wait = 30;
    } else if (rd_busy && --rd_wait <= 0) {
        uint32_t a = dut->rd_addr;
        uint64_t d = 0;
        for (int i = 0; i < 8; i++)
            d |= (uint64_t)(a + i < sdram.size() ? sdram[a + i] : 0) << (i * 8);
        dut->rd_dout = d;
        dut->rd_ack  = dut->rd_req;
        rd_busy = false;
    }
}

static void tick() {
    dut->clk = 0; dut->eval();
    sdram_tick();
    dut->clk = 1; dut->eval();
}
static void run(int n) { while (n--) tick(); }

// ----------------------------------------------------------------- load ----
// hps_io holds ioctl_wr for one clk_sys cycle, which is two of these, and
// honours ioctl_wait between bytes.
static void load(const std::vector<uint8_t> &img) {
    dut->ioctl_index = 2;
    dut->ioctl_download = 1;
    run(4);
    for (size_t i = 0; i < img.size(); i++) {
        int guard = 0;
        while (dut->ioctl_wait) { tick(); if (++guard > 1000) { printf("FAIL: load stalled at %zu\n", i); errors++; return; } }
        dut->ioctl_dout = img[i];
        dut->ioctl_wr = 1; tick(); tick();
        dut->ioctl_wr = 0; tick();
    }
    while (dut->ioctl_wait) tick();
    dut->ioctl_download = 0;
    run(8);
}

// ----------------------------------------------------------------- save ----
// Returns what the HPS would write to the .nvm file.
static std::vector<uint8_t> save(size_t n, int word_cycles) {
    std::vector<uint8_t> out;
    dut->ioctl_upload = 1;
    dut->ioctl_rd = 1; tick(); tick();      // the request that comes with 0xAA
    dut->ioctl_rd = 0;
    // The 0xAA and the first data word are separate SPI transactions on the
    // HPS side -- EnableFpga/spi8/DisableFpga twice over, with CPU work in
    // between -- so the first line always has microseconds to land. Only the
    // STEADY state is the prefetch's problem, which is what word_cycles then
    // stresses.
    run(400);
    for (size_t i = 0; i < n; i++) {
        out.push_back(dut->ioctl_din);      // fp_dout <= ioctl_din
        dut->ioctl_rd = 1; tick(); tick();
        dut->ioctl_rd = 0;
        run(word_cycles);
    }
    dut->ioctl_upload = 0;
    run(4);
    return out;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vspi_nvram;
    sdram.assign(PCM_BASE + NV_SIZE, 0);

    dut->enable = 1;
    dut->reset = 1; dut->ioctl_wr = 0; dut->ioctl_rd = 0;
    dut->ioctl_download = 0; dut->ioctl_upload = 0;
    dut->wr_ack = 0; dut->rd_ack = 0; dut->flash_dirty = 0;
    run(8);
    dut->reset = 0; run(8);

    // A stride coprime with 8, so a line that is fetched twice or never
    // advanced cannot hide behind repeating values -- which is exactly how the
    // hardware bug presented.
    const size_t N = 4096;
    std::vector<uint8_t> img(N);
    for (size_t i = 0; i < N; i++) img[i] = (uint8_t)(i * 37 + 11);

    // ---- load ------------------------------------------------------------
    load(img);
    int bad = 0;
    for (size_t i = 0; i < N; i++) if (sdram[PCM_BASE + i] != img[i]) bad++;
    if (bad) { printf("FAIL: %d of %zu loaded bytes wrong\n", bad, N); errors++; }
    else     printf("load: %zu bytes into the sample region, byte-exact\n", N);

    // ---- save ------------------------------------------------------------
    // 40 clk_ram between words is about what the HPS's SPI leaves; the read
    // port above takes 30, so a fetch issued at a line crossing would NOT make
    // it in time. Only the prefetch does.
    std::vector<uint8_t> got = save(N, 40);
    bad = 0;
    size_t first = N;
    for (size_t i = 0; i < N; i++)
        if (got[i] != img[i]) { if (bad < 4) printf("FAIL: save byte %zu: want %02X got %02X\n", i, img[i], got[i]); if (i < first) first = i; bad++; }
    if (bad) { printf("FAIL: %d of %zu saved bytes wrong, first at %zu\n", bad, N, first); errors++; }
    else     printf("save: %zu bytes back through the ioctl handshake, byte-exact\n", N);

    // ---- save again, with the host as fast as it can be -------------------
    // 12 cycles a word is faster than any real SPI transfer and less than the
    // read latency, so this is the prefetch's worst case.
    got = save(N, 12);
    bad = 0;
    for (size_t i = 0; i < N; i++) if (got[i] != img[i]) bad++;
    if (bad) { printf("FAIL: %d of %zu bytes wrong with a fast host\n", bad, N); errors++; }
    else     printf("save: byte-exact again with the host 3x faster than the SDRAM\n");

    // ---- the save request -------------------------------------------------
    // One pulse per settled burst of flash writes, not one per write.
    // The real cycle, three times over: the flash is written, it settles, the
    // core asks, Main eventually takes it, and the ask clears. QUIET_BITS is 8
    // in this build, so "settled" is 256 cycles rather than 16.7 million.
    //
    // The request is a LEVEL and is checked as one. hps_io samples it on
    // clk_sys, half this module's rate, so a one-cycle pulse can fall between
    // its edges -- which is exactly how rfjet's save silently never happened
    // while rdft's did, with nothing else different between them.
    int reqs = 0, short_req = 0;
    for (int burst = 0; burst < 3; burst++) {
        for (int i = 0; i < 5; i++) { dut->flash_dirty = !dut->flash_dirty; run(20); }
        int waited = 0;
        while (!dut->ioctl_upload_req && waited < 4000) { tick(); waited++; }
        if (!dut->ioctl_upload_req) { printf("FAIL: burst %d raised no request\n", burst); errors++; break; }
        reqs++;
        // It must stay up until Main comes: a one-cycle pulse at clk_ram can
        // fall between two clk_sys edges. It must ALSO not be re-presented on
        // its own -- an -update MRA with no <nvram> element makes Main answer
        // the poll, save nothing and come back, and a self-renewing request
        // turns that into an OSD stuck in a "Saving..." loop.
        for (int i = 0; i < 2000; i++) { tick(); if (!dut->ioctl_upload_req) short_req++; }
        (void)save(64, 40);                    // Main takes it
        if (dut->ioctl_upload_req) { printf("FAIL: request still up after the upload started\n"); errors++; }
    }
    if (reqs != 3)   { printf("FAIL: %d requests for 3 bursts\n", reqs); errors++; }
    if (short_req)   { printf("FAIL: request dropped on %d cycles before it was taken\n", short_req); errors++; }
    if (reqs == 3 && !short_req)
        printf("request: one per settled burst, held until taken and not renewed\n");

    delete dut;
    if (errors) { printf("\n%d FAILURES\n", errors); return 1; }
    printf("\nall nvram checks passed\n");
    return 0;
}
