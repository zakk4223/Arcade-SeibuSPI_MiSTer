//============================================================================
//  SlopperPI - testbench for spi_nvram
//
//  Both directions of the save file, against a behavioural SDRAM and a
//  behavioural DS2404: the LOAD writes an ioctl byte stream into the sample
//  region and then into the chip's SRAM, and the SAVE reads both back through
//  the same handshake hps_io uses.
//
//  The file is ONE stream covering TWO devices, because an MRA has one <nvram>
//  element -- the flash then the 512-byte tail. FLASH_BYTES is shrunk to 4096
//  here so that the crossing between them is a few thousand cycles in rather
//  than eighty million.
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
#include <cstring>
#include <vector>

static const uint32_t PCM_BASE = 0x280000;
// -GFLASH_BYTES in the Makefile. The RTL default is 0x200000.
static const uint32_t FLASH_BYTES = 4096;
static const uint32_t SRAM_BYTES  = 512;

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

// ---------------------------------------------------------------- DS2404 ----
// Only what spi_nvram can see of it: 512 bytes, a registered read, and a
// write port. spi_ds2404 has its own testbench.
static uint8_t sram[SRAM_BYTES];

static void sram_tick() {
    if (dut->sram_we) sram[dut->sram_addr % SRAM_BYTES] = dut->sram_din;
    dut->sram_dout = sram[dut->sram_addr % SRAM_BYTES];   // one cycle behind
}

static void tick() {
    dut->clk = 0; dut->eval();
    sdram_tick();
    sram_tick();
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
static std::vector<uint8_t> save(size_t n, int word_cycles, int index = 2) {
    std::vector<uint8_t> out;
    dut->ioctl_index = index;
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
    sdram.assign(PCM_BASE + 0x200000, 0);

    dut->enable = 1;
    dut->has_flash = 1;                    // a cartridge set: flash then tail
    dut->flash_live = 1;                   // ...in Ritual mode
    dut->reset = 1; dut->ioctl_wr = 0; dut->ioctl_rd = 0;
    dut->ioctl_download = 0; dut->ioctl_upload = 0;
    dut->wr_ack = 0; dut->rd_ack = 0; dut->flash_dirty = 0; dut->sram_dirty = 0;
    memset(sram, 0, sizeof(sram));
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

    // ---- the whole file, both devices, one stream -------------------------
    // The crossing is the thing: the tail's bytes come from the DS2404 and not
    // from the prefetched SDRAM line, and `sram_addr` has to have wrapped to 0
    // exactly as the count reaches it.
    {
        std::vector<uint8_t> file(FLASH_BYTES + SRAM_BYTES);
        for (size_t i = 0; i < file.size(); i++) file[i] = (uint8_t)(i * 29 + 3);
        memset(sram, 0, sizeof(sram));
        load(file);
        int fbad = 0, sbad = 0;
        for (size_t i = 0; i < FLASH_BYTES; i++)
            if (sdram[PCM_BASE + i] != file[i]) fbad++;
        for (size_t i = 0; i < SRAM_BYTES; i++)
            if (sram[i] != file[FLASH_BYTES + i]) sbad++;
        if (fbad || sbad) {
            printf("FAIL: load split wrong -- %d flash bytes and %d tail bytes\n", fbad, sbad);
            errors++;
        } else printf("split: one %zu-byte stream loads the flash half and the "
                      "DS2404's 512-byte tail\n", file.size());

        std::vector<uint8_t> back = save(file.size(), 40);
        int bbad = 0;
        size_t firstbad = file.size();
        for (size_t i = 0; i < file.size(); i++)
            if (back[i] != file[i]) { if (i < firstbad) firstbad = i; bbad++; }
        if (bbad) {
            printf("FAIL: %d of %zu bytes wrong on the way back, first at %zu "
                   "(the crossing is at %u)\n", bbad, file.size(), firstbad, FLASH_BYTES);
            errors++;
        } else printf("split: and comes back byte-exact across the crossing at "
                      "%u\n", FLASH_BYTES);

        // Fast host, because the tail has a registered read of its own.
        back = save(file.size(), 12);
        bbad = 0;
        for (size_t i = 0; i < file.size(); i++) if (back[i] != file[i]) bbad++;
        if (bbad) { printf("FAIL: %d bytes wrong across the crossing with a fast host\n", bbad); errors++; }
        else      printf("split: byte-exact again with the host 3x faster than the SDRAM\n");
    }

    // ---- Pre-built: the tail loads, the flash half does not ---------------
    // The flash is about to be derived, and the derivation is writing ch3 while
    // this file arrives. So the flash half is dropped and `wr_active` -- which
    // is what claims ch3 -- must never rise, while `hold` still does: the game
    // must not read its bookkeeping before the tail has landed.
    {
        dut->flash_live = 0;
        std::vector<uint8_t> keep(FLASH_BYTES);
        for (size_t i = 0; i < FLASH_BYTES; i++) keep[i] = sdram[PCM_BASE + i];
        std::vector<uint8_t> file(FLASH_BYTES + SRAM_BYTES);
        for (size_t i = 0; i < file.size(); i++) file[i] = (uint8_t)(0xA5 ^ (i * 7));
        memset(sram, 0, sizeof(sram));

        // watch both lines for the whole transfer
        int saw_wr = 0, saw_hold = 0;
        dut->ioctl_index = 2; dut->ioctl_download = 1; run(4);
        for (size_t i = 0; i < file.size(); i++) {
            int guard = 0;
            while (dut->ioctl_wait) { tick(); if (++guard > 1000) break; }
            dut->ioctl_dout = file[i];
            dut->ioctl_wr = 1; tick(); tick();
            dut->ioctl_wr = 0; tick();
            if (dut->wr_active) saw_wr++;
            if (dut->hold)      saw_hold++;
        }
        while (dut->ioctl_wait) tick();
        dut->ioctl_download = 0; run(8);

        int touched = 0;
        for (size_t i = 0; i < FLASH_BYTES; i++)
            if (sdram[PCM_BASE + i] != keep[i]) touched++;
        int sbad = 0;
        for (size_t i = 0; i < SRAM_BYTES; i++)
            if (sram[i] != file[FLASH_BYTES + i]) sbad++;
        if (saw_wr)  { printf("FAIL: wr_active rose on %d bytes in Pre-built mode\n", saw_wr); errors++; }
        if (!saw_hold) { printf("FAIL: hold never rose, so the game could read the tail early\n"); errors++; }
        if (touched) { printf("FAIL: %d bytes of a save file reached the region that is about to be derived\n", touched); errors++; }
        if (sbad)    { printf("FAIL: %d tail bytes did not land in Pre-built mode\n", sbad); errors++; }
        if (!saw_wr && saw_hold && !touched && !sbad)
            printf("pre-built: the flash half is dropped and ch3 never claimed, "
                   "the 512-byte tail still lands, and the core stays held\n");

        // and only the DS2404 can ask for a save in this mode
        for (int i = 0; i < 5; i++) { dut->flash_dirty = !dut->flash_dirty; run(20); }
        int asked = 0;
        for (int i = 0; i < 3000; i++) { tick(); if (dut->ioctl_upload_req) asked++; }
        if (asked) { printf("FAIL: the flash asked for a save in Pre-built mode\n"); errors++; }
        dut->sram_dirty = !dut->sram_dirty;
        int waited = 0;
        while (!dut->ioctl_upload_req && waited < 4000) { tick(); waited++; }
        if (!dut->ioctl_upload_req) { printf("FAIL: a DS2404 store asked for nothing\n"); errors++; }
        else printf("pre-built: the flash cannot ask for a save, a DS2404 store can\n");
        (void)save(64, 40);
        dut->flash_live = 1;
    }

    // ---- SXX2E: no flash half at all -------------------------------------
    // The samples are a real ROM there, so the file IS the DS2404's 512 bytes
    // and the tail sits at offset 0. Same code, one input different.
    {
        dut->has_flash = 0;
        std::vector<uint8_t> file(SRAM_BYTES);
        for (size_t i = 0; i < SRAM_BYTES; i++) file[i] = (uint8_t)(i ^ 0x3C);
        memset(sram, 0, sizeof(sram));
        std::vector<uint8_t> keep(FLASH_BYTES);
        for (size_t i = 0; i < FLASH_BYTES; i++) keep[i] = sdram[PCM_BASE + i];
        load(file);
        int sbad = 0, touched = 0;
        for (size_t i = 0; i < SRAM_BYTES; i++) if (sram[i] != file[i]) sbad++;
        for (size_t i = 0; i < FLASH_BYTES; i++)
            if (sdram[PCM_BASE + i] != keep[i]) touched++;
        std::vector<uint8_t> back = save(SRAM_BYTES, 40);
        int bbad = 0;
        for (size_t i = 0; i < SRAM_BYTES; i++) if (back[i] != file[i]) bbad++;
        if (sbad || touched || bbad) {
            printf("FAIL: SXX2E layout -- %d tail bytes in, %d bytes back, "
                   "%d bytes of sample region touched\n", sbad, bbad, touched);
            errors++;
        } else printf("sxx2e: with no flash half the file is 512 bytes at offset "
                      "0, both ways, and the sample region is left alone\n");
        dut->has_flash = 1;
    }

    // ---- an upload at someone ELSE's index --------------------------------
    // hps_io's ioctl_upload is global. If this module answered every upload,
    // whatever Main was really reading would come back as sample flash.
    std::vector<uint8_t> other = save(64, 40, 3);
    int nonzero = 0;
    for (uint8_t b : other) if (b) nonzero++;
    if (nonzero) { printf("FAIL: served %d bytes to an upload at index 3\n", nonzero); errors++; }
    else         printf("index: an upload at index 3 is not answered\n");
    dut->ioctl_index = 2;

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

    // ---- enable low: the whole device is inert --------------------------
    // `enable` is "the MRA declared an <nvram> element". Every set the core runs
    // has a DS2404 to remember, so nothing drives this low today -- what varies
    // is the SHAPE of the file (has_flash) and whether the flash half is real
    // (flash_live), both checked above. It stays covered because an MRA from
    // before any of this exists, or one built with the element left out, must
    // not have a stray save file written into its sample region.
    //
    // The baseline is the region as it is NOW, not the first image loaded: the
    // tests between here and there have rewritten it, and comparing against the
    // stale copy reported 3,968 bytes of a leak that never happened.
    dut->enable = 0;
    std::vector<uint8_t> baseline(N);
    for (size_t i = 0; i < N; i++) baseline[i] = sdram[PCM_BASE + i];
    uint8_t sram_before[SRAM_BYTES];
    memcpy(sram_before, sram, SRAM_BYTES);
    std::vector<uint8_t> decoy(N + SRAM_BYTES);
    for (size_t i = 0; i < decoy.size(); i++) decoy[i] = (uint8_t)(i * 53 + 7);
    load(decoy);
    int leaked = 0;
    for (size_t i = 0; i < N; i++) if (sdram[PCM_BASE + i] != baseline[i]) leaked++;
    for (size_t i = 0; i < SRAM_BYTES; i++) if (sram[i] != sram_before[i]) leaked++;
    if (leaked) {
        printf("FAIL: %d bytes of a save file reached the board with "
               "enable low\n", leaked);
        errors++;
    }

    for (int i = 0; i < 5; i++) { dut->flash_dirty = !dut->flash_dirty; run(20); }
    dut->sram_dirty = !dut->sram_dirty; run(20);
    int asked = 0;
    for (int i = 0; i < 4000; i++) { tick(); if (dut->ioctl_upload_req) asked++; }
    if (asked) {
        printf("FAIL: a save was requested on %d cycles with enable low\n", asked);
        errors++;
    }
    if (!leaked && !asked)
        printf("disabled: no load into the region or the DS2404, and neither "
               "device can ask for a save\n");

    delete dut;
    if (errors) { printf("\n%d FAILURES\n", errors); return 1; }
    printf("\nall nvram checks passed\n");
    return 0;
}
