//============================================================================
//  SlopperPI - does the 386 actually boot?
//
//  Loads the real SDRAM image (tools/build_sdram_image.py), releases reset, and
//  runs the board for a few million CPU cycles while watching what the 386 does.
//
//  Reports, in order of how far the core gets:
//    - whether the CPU ever fetches from the reset vector mirror at 0xFFE00000
//    - the spread of addresses it fetches (a CPU stuck in a tight loop on one
//      address is not the same as one that is running)
//    - every I/O register it writes, with the value
//    - whether the tilemap / palette / sprite DMA triggers ever fire
//
//  A black screen on hardware is consistent with several failures; this pins
//  down which one without needing the hardware.
//
//  On the SXX2C cartridge there is a second question, and for rdft2 it is the
//  important one: its Z80 program is not a loader part but something the 386
//  reads through the sound01 window and pushes into the Z80's RAM a byte at a
//  time. Both halves of that are modelled here -- sound01 answers out of the
//  SDRAM image, and the download's writes land in it -- so the run can end by
//  comparing what reached the Z80's memory against what was in the ROM. That
//  covers spi_cpu.sv's sound01 window, rom_loader's part for it and spi_io's
//  port 0x688 path in one go, with the game's own code driving all three.
//
//  What it CANNOT tell you is whether the game then runs: the Z80 is a stub
//  here (sim/T80s.sv), so after the download the 386 waits forever on a sound
//  FIFO that never answers, and a cartridge run ends on a black screen no
//  matter how healthy the core is. Judge those runs by the download check and
//  the register log, not by the picture.
//
//  usage: Vtb_boot_top <sdram.bin> [cycles] [rdfts|rdft|rdft2]
//============================================================================

#include "Vtb_boot_top.h"
#include "verilated.h"

#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <map>
#include <set>
#include <string>

// The whole map (rtl/spi_defs.vh), not just as far as rdfts reaches: rdft2's
// image tops out at 35 MB, and an authentic-flash image at 43 -- its PCM source
// region is the last 2 MB. The image is read with a plain fread of this many
// bytes, so a short constant would TRUNCATE the source window away silently and
// the 386 would read the zeroes, which is the whole failure mode section 17.2
// exists to prevent.
static const uint32_t SDR_SIZE  = 0x2B00000;
static const uint32_t Z80_BASE  = 0x0200000;
static const uint32_t Z80_SIZE  = 0x0040000;
static const uint32_t SND01_BASE = 0x0480000;
static const uint32_t SND01_SIZE = 0x0080000;   // sound1.u0222, whole

static std::vector<uint8_t> sdram;

static uint64_t rd64(uint32_t addr)
{
    addr &= ~7u;
    if (addr + 8 > sdram.size()) return 0;
    uint64_t v = 0;
    for (int i = 7; i >= 0; i--) v = (v << 8) | sdram[addr + i];
    return v;
}

// A crude SDRAM: fixed latency, one outstanding request per channel.
struct Chan {
    uint8_t  last_req = 0;
    int      delay    = -1;
    uint32_t addr     = 0;
    uint64_t data     = 0;
    uint64_t count    = 0;
};

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);
    if (argc < 2) { printf("usage: %s <sdram.bin> [cycles]\n", argv[0]); return 2; }

    uint64_t max_steps = (argc > 2) ? strtoull(argv[2], nullptr, 0) : 40000000ull;

    // Which board. rdfts is the default so the original invocation still means
    // what it did; the cartridge sets change the mod bits the same way the
    // MRA's mod byte does (rtl/spi_defs.vh).
    const char *setname = (argc > 3) ? argv[3] : "rdfts";
    int  set_id    = !strcmp(setname, "rfjet") ? 3 : !strcmp(setname, "rdft2") ? 2
                   : !strcmp(setname, "rdft")  ? 1 : 0;
    bool set_sxx2c = set_id != 0;
    // Sets whose Z80 program comes through the sound01 window rather than out
    // of the already-loaded Z80 region.
    bool from_snd01 = (set_id == 2) || (set_id == 3);
    if (strcmp(setname, "rdfts") && strcmp(setname, "rdft") &&
        strcmp(setname, "rdft2") && strcmp(setname, "rfjet")) {
        printf("FAIL: unknown set %s (want rdfts, rdft, rdft2 or rfjet)\n", setname);
        return 2;
    }
    printf("set: %s (set_id=%d, sxx2c=%d)\n", setname, set_id, set_sxx2c);

    FILE *f = fopen(argv[1], "rb");
    if (!f) { printf("FAIL: cannot open %s\n", argv[1]); return 2; }
    sdram.resize(SDR_SIZE, 0);
    size_t got = fread(sdram.data(), 1, SDR_SIZE, f);
    fclose(f);
    printf("sdram image: %zu bytes\n", got);
    if (got < 0x200000) { printf("FAIL: image too small to contain the program ROM\n"); return 2; }

    // Sanity: the 386 reset vector lives at the top of the 2 MB program image.
    printf("reset vector bytes at PRG+0x1FFFF0:");
    for (int i = 0; i < 16; i++) printf(" %02X", sdram[0x1FFFF0 + i]);
    printf("\n");

    // The download's own copy of the Z80 program, kept pristine for the compare
    // at the end: the writes land in `sdram` itself, and on rdfts they land on
    // top of the loader's copy.
    std::vector<uint8_t> z80_src(sdram.begin() + Z80_BASE,
                                 sdram.begin() + Z80_BASE + Z80_SIZE);

    Vtb_boot_top *dut = new Vtb_boot_top;

    // cdl is not a channel, only an owner tag: the download shares ch3 with the
    // Z80 fetch and writes rather than reads, so it retires differently.
    Chan cprg, cgfx, cspr, cz80, cdl;

    dut->reset     = 1;
    dut->rom_ready = 0;
    dut->set_id    = set_id;
    dut->set_sxx2c = set_sxx2c;
    dut->clk_sys = dut->clk_cpu = dut->clk_ram = 0;
    dut->sdr_prg_ack = dut->sdr_gfx_ack = dut->sdr_spr_ack = 0;
    dut->sdr_prg_dout = dut->sdr_gfx_dout = dut->sdr_spr_dout = 0;
    dut->sdr_z80_ack = 0;
    dut->sdr_z80_dout = 0;
    dut->z80dl_sdr_ack = 0;

    // Observations
    uint64_t rom_fetches = 0;
    std::set<uint32_t> fetch_pages;          // 4 KB granularity
    uint32_t first_fetch = 0xFFFFFFFF;
    uint64_t n_dma_tm = 0, n_dma_pal = 0, n_dma_spr = 0, n_vbl = 0;
    std::map<uint32_t, std::pair<uint64_t, uint32_t>> io_writes; // addr -> (count, last value)
    uint64_t io_wr_total = 0;
    uint64_t inta_cycles = 0;
    uint64_t stall_cycles = 0;               // valid held with no ready

    // The Z80 program download, and the sound01 reads that feed it on rdft2.
    uint64_t snd01_fetches = 0;
    uint64_t z80dl_writes  = 0;
    uint32_t z80dl_lo = 0xFFFFFFFF, z80dl_hi = 0;
    std::vector<uint8_t> z80_written(Z80_SIZE, 0);
    uint8_t  z80dl_req_d = 0;
    int      z80dl_delay = -1;
    uint64_t z80_run_cycles = 0;
    uint8_t  z80_rst_d = 0;

    uint8_t io_wr_d = 0, tm_d = 0, pal_d = 0, spr_d = 0, vbl_d = 0;

    // Frame grabber. The core emits 320x240 inside its blanking.
    const int FW = 320, FH = 240;
    std::vector<uint8_t> fb(FW * FH * 3, 0);
    int fx = 0, fy = 0;
    uint8_t hb_d = 1, vb_d = 1;
    uint64_t frames = 0;
    uint64_t nonblack = 0, nonblack_last = 0;
    // Keep the busiest frame seen, not the last one: the attract sequence has
    // long black stretches and the final frame is usually one of them.
    std::vector<uint8_t> best_fb(FW * FH * 3, 0);
    uint64_t best_nonblack = 0;
    const uint64_t dump_every =
        getenv("SLOP_DUMP_EVERY") ? strtoull(getenv("SLOP_DUMP_EVERY"), nullptr, 0) : 0;

    // The real controller has ONE bus shared by every channel, served from
    // STATE_IDLE in a fixed priority order (refresh, ch2 gfx, ch1 prg, ch4 spr,
    // ch3). Modelling each channel as an independent server -- which this
    // testbench used to do -- hides every contention and starvation bug, and
    // those are exactly the ones that only show up on hardware. So: one server,
    // same priority order, and a transaction occupies it for a whole burst.
    unsigned lat_seed = 12345;
    bool fixed_lat = getenv("SLOP_FIXED_LAT") != nullptr;
    auto burst_len = [&]() -> int {
        if (fixed_lat) return 12;
        lat_seed = lat_seed * 1103515245u + 12345u;
        return 10 + (int)((lat_seed >> 16) % 6);   // ACTIVE + CAS + burst
    };

    int      bus_busy   = 0;    // cycles left on the current transaction
    Chan    *bus_owner  = nullptr;
    uint64_t refresh_ctr = 0;

    // Latch a request when its toggle flips; nothing is served until the bus
    // frees up, so channels genuinely queue behind each other.
    auto latch = [&](Chan &c, uint8_t req, uint32_t addr) {
        if (req != c.last_req && c.delay < 0) {
            c.last_req = req;
            c.addr     = addr;
            c.delay    = 0;         // pending, not yet started
            c.count++;
        }
    };

    auto retire = [&](Chan &c, uint8_t &ack, uint64_t &dout) {
        dout = rd64(c.addr);
        ack  = c.last_req;
        c.delay = -1;
    };
    // Activity is reported per time bucket, not just as a total: a core that
    // boots and then hangs looks identical to a healthy one in the totals.
    const uint64_t BUCKET = max_steps / 20;
    uint64_t b_prg = 0, b_io = 0, b_tm = 0, b_pal = 0, b_spr = 0, b_vbl = 0;
    printf("\n%8s %8s %8s %7s %7s %7s %6s | %s\n",
           "step(M)", "prgfetch", "iowr", "dmaTM", "dmaPAL", "dmaSPR", "vbl",
           "cpu: addr vld rdy inta st own dmabsy outst");

    // clk_ram = 4x clk_cpu, clk_sys = 2x clk_cpu in this model (ratios match the PLL).
    uint64_t cyc = 0;
    for (uint64_t t = 0; t < max_steps; t++) {
        // clk_ram toggles every step; clk_sys every 2; clk_cpu every 4
        dut->clk_ram = (t >> 0) & 1;
        dut->clk_sys = (t >> 1) & 1;
        dut->clk_cpu = (t >> 2) & 1;

        dut->eval();

        // Release reset once "download" has notionally finished.
        if (t == 4000) { dut->rom_ready = 1; }
        if (t == 8000) { dut->reset = 0; cyc = 0; }

        // one clk_ram tick per two steps
        if ((t & 1) == 0) {
            latch(cprg, dut->sdr_prg_req, dut->sdr_prg_addr);
            latch(cgfx, dut->sdr_gfx_req, dut->sdr_gfx_addr);
            latch(cspr, dut->sdr_spr_req, dut->sdr_spr_addr);
            latch(cz80, dut->sdr_z80_req, dut->sdr_z80_addr);
            if (cprg.delay == 0 && cprg.addr >= SND01_BASE
                                && cprg.addr <  SND01_BASE + SND01_SIZE)
                snd01_fetches++;

            // The Z80 program download is the other master on ch3. It is a
            // 16-bit masked write, so it takes a bus slot like anything else --
            // and the 386 is stalled until it retires, which is what makes the
            // download take the time it does.
            if (dut->z80dl_sdr_req != z80dl_req_d && z80dl_delay < 0) {
                z80dl_req_d = dut->z80dl_sdr_req;
                z80dl_delay = 0;
            }

            if (bus_busy > 0) {
                if (--bus_busy == 0 && bus_owner) {
                    if      (bus_owner == &cprg) retire(cprg, dut->sdr_prg_ack, dut->sdr_prg_dout);
                    else if (bus_owner == &cgfx) retire(cgfx, dut->sdr_gfx_ack, dut->sdr_gfx_dout);
                    else if (bus_owner == &cspr) retire(cspr, dut->sdr_spr_ack, dut->sdr_spr_dout);
                    else if (bus_owner == &cz80) retire(cz80, dut->sdr_z80_ack, dut->sdr_z80_dout);
                    else {
                        // The download's masked 16-bit write, retiring.
                        uint32_t a = dut->z80dl_sdr_addr & ~1u;
                        uint16_t d = dut->z80dl_sdr_din;
                        uint8_t be = dut->z80dl_sdr_be;
                        for (int lane = 0; lane < 2; lane++) {
                            if (!(be & (1 << lane))) continue;
                            uint32_t ba = a + lane;
                            if (ba < SDR_SIZE) sdram[ba] = (d >> (8 * lane)) & 0xFF;
                            if (ba >= Z80_BASE && ba < Z80_BASE + Z80_SIZE) {
                                z80_written[ba - Z80_BASE] = 1;
                                if (ba < z80dl_lo) z80dl_lo = ba;
                                if (ba > z80dl_hi) z80dl_hi = ba;
                            }
                        }
                        z80dl_writes++;
                        z80dl_delay = -1;
                        dut->z80dl_sdr_ack = z80dl_req_d;
                    }
                    bus_owner = nullptr;
                }
            }
            else if (++refresh_ctr >= 880) {      // emergency refresh wins
                refresh_ctr = 0;
                bus_busy = 8;
                bus_owner = nullptr;
            }
            else if (cgfx.delay == 0) { bus_owner = &cgfx; bus_busy = burst_len(); }
            else if (cprg.delay == 0) { bus_owner = &cprg; bus_busy = burst_len(); }
            else if (cspr.delay == 0) { bus_owner = &cspr; bus_busy = burst_len(); }
            // ch3 last, both directions: the Z80 fetch and then the download,
            // which is the priority the real arbiter gives them.
            else if (cz80.delay == 0) { bus_owner = &cz80; bus_busy = burst_len(); }
            else if (z80dl_delay == 0) { bus_owner = &cdl;  bus_busy = burst_len(); z80dl_delay = 1; }
        }

        dut->eval();

        // Video capture on the clk_sys rising phase, gated by ce_pix.
        if (((t & 3) == 2) && !dut->reset) {
            if (dut->v_vb && !vb_d) {          // entering vblank = frame done
                frames++;
                nonblack_last = nonblack;
                if (nonblack > best_nonblack) { best_nonblack = nonblack; best_fb = fb; }
                // Dump a frame every DUMP_EVERY so the whole attract sequence can
                // be walked; the interesting failures are late (demo gameplay),
                // not on the early static screens.
                if (dump_every && (frames % dump_every) == 0) {
                    char fn[64];
                    snprintf(fn, sizeof fn, "frame_%04llu.ppm",
                             (unsigned long long)frames);
                    FILE *df = fopen(fn, "wb");
                    if (df) {
                        fprintf(df, "P6\n%d %d\n255\n", FW, FH);
                        fwrite(fb.data(), 1, fb.size(), df);
                        fclose(df);
                    }
                }
                nonblack = 0;
                fy = 0;
            }
            if (!dut->v_hb && hb_d) fx = 0;    // leaving hblank = new line
            if (dut->v_hb && !hb_d && fy < FH) fy++;
            if (dut->v_ce_pix && !dut->v_hb && !dut->v_vb) {
                if (fx < FW && fy < FH) {
                    size_t o = (size_t)(fy * FW + fx) * 3;
                    fb[o+0] = dut->v_r; fb[o+1] = dut->v_g; fb[o+2] = dut->v_b;
                    if (dut->v_r || dut->v_g || dut->v_b) nonblack++;
                }
                fx++;
            }
            hb_d = dut->v_hb; vb_d = dut->v_vb;

            cyc++;

            if (dut->p_io_wr && !io_wr_d) {
                io_wr_total++; b_io++;
                auto &e = io_writes[dut->p_io_addr];
                e.first++;
                e.second = dut->p_io_wdata;
            }
            io_wr_d = dut->p_io_wr;

            if (dut->p_dma_tilemap && !tm_d)  { n_dma_tm++;  b_tm++;  }
            if (dut->p_dma_palette && !pal_d) { n_dma_pal++; b_pal++; }
            if (dut->p_dma_sprite  && !spr_d) { n_dma_spr++; b_spr++; }
            if (dut->p_vbl_rise    && !vbl_d) { n_vbl++;     b_vbl++; }
            tm_d = dut->p_dma_tilemap; pal_d = dut->p_dma_palette;
            spr_d = dut->p_dma_sprite; vbl_d = dut->p_vbl_rise;

            if (dut->p_cpu_inta) inta_cycles++;
            if (dut->p_cpu_valid && !dut->p_cpu_ready) stall_cycles++;
            if (dut->p_z80_rst_n) z80_run_cycles++;
            if (dut->p_z80_rst_n && !z80_rst_d)
                printf("  [%.1fM] Z80 released from reset\n", t / 1e6);
            if (!dut->p_z80_rst_n && z80_rst_d)
                printf("  [%.1fM] Z80 put back into reset (last PC %04X)\n",
                       t / 1e6, dut->p_snd_pc);
            z80_rst_d = dut->p_z80_rst_n;
        }

        if (BUCKET && (t % BUCKET) == BUCKET - 1) {
            printf("%8.1f %8llu %8llu %7llu %7llu %7llu %6llu | "
                   "%08X %d %d %d %d %d %d %d\n",
                   t / 1e6,
                   (unsigned long long)(cprg.count - b_prg),
                   (unsigned long long)b_io, (unsigned long long)b_tm,
                   (unsigned long long)b_pal, (unsigned long long)b_spr,
                   (unsigned long long)b_vbl,
                   (unsigned)(dut->p_cpu_addr << 2), dut->p_cpu_valid,
                   dut->p_cpu_ready, dut->p_cpu_inta, dut->p_cpu_state,
                   dut->p_dma_own, dut->p_dma_busy, dut->p_prg_outstanding);
            printf("         frames=%llu  non-black pixels in last frame=%llu / %d\n",
                   (unsigned long long)frames,
                   (unsigned long long)nonblack_last, FW * FH);
            fflush(stdout);
            b_prg = cprg.count;
            b_io = b_tm = b_pal = b_spr = b_vbl = 0;
        }
    }

    rom_fetches = cprg.count;

    // Where did it fetch? Re-derive from the pages touched by the channel model
    // is not possible after the fact, so report what we have.
    printf("\n--- boot report after %llu clk_sys cycles ---\n", (unsigned long long)cyc);
    printf("PRG ROM 64-bit fetches : %llu\n", (unsigned long long)rom_fetches);
    printf("GFX fetches            : %llu\n", (unsigned long long)cgfx.count);
    printf("SPR fetches            : %llu\n", (unsigned long long)cspr.count);
    printf("vblank pulses          : %llu\n", (unsigned long long)n_vbl);
    printf("INTA cycles            : %llu\n", (unsigned long long)inta_cycles);
    printf("CPU stall cycles       : %llu\n", (unsigned long long)stall_cycles);
    printf("I/O writes             : %llu (%zu distinct registers)\n",
           (unsigned long long)io_wr_total, io_writes.size());
    for (auto &kv : io_writes)
        printf("    0x%03X  x%-8llu last=%08X\n", kv.first * 4,
               (unsigned long long)kv.second.first, kv.second.second);
    printf("tilemap DMA triggers   : %llu\n", (unsigned long long)n_dma_tm);
    printf("palette DMA triggers   : %llu\n", (unsigned long long)n_dma_pal);
    printf("sprite  DMA triggers   : %llu\n", (unsigned long long)n_dma_spr);
    // Always zero, and not a fault: sim/T80s.sv is a stand-in with no CPU in
    // it, because the real core is VHDL. So the Z80 fetches nothing, answers
    // nothing, and the 386 spins on the sound FIFO once it has handed the
    // program over -- which is why a cartridge run ends on a black screen here
    // even when everything works. The frame itself is verified elsewhere, by
    // replaying MAME's captured state (PLAN.md 12).
    printf("Z80 fetches (ch3)      : %llu%s\n", (unsigned long long)cz80.count,
           cz80.count ? "" : "  (expected: the Verilator T80 is a stub)");
    printf("Z80 out-of-reset cycles: %llu, last opcode fetch at %04X\n",
           (unsigned long long)z80_run_cycles, dut->p_snd_pc);
    printf("sound01 fetches        : %llu\n", (unsigned long long)snd01_fetches);
    printf("Z80 download writes    : %llu\n", (unsigned long long)z80dl_writes);

    // What actually reached the Z80's memory, and whether it is the program
    // that was in the ROM. On rdft2 that program came through the sound01
    // window, so a byte-exact match here exercises the whole path: the loader
    // part, spi_cpu's window, and port 0x688.
    int dl_rc = 0;
    if (z80dl_writes) {
        uint64_t covered = 0;
        for (uint32_t i = 0; i < Z80_SIZE; i++) covered += z80_written[i] ? 1 : 0;
        printf("Z80 RAM bytes written  : %llu, 0x%X..0x%X\n",
               (unsigned long long)covered,
               z80dl_lo - Z80_BASE, z80dl_hi - Z80_BASE);

        if (from_snd01) {
            // The program came out of the sound01 window, and the loader put
            // the WHOLE of sound1.u0222 behind that window, so where inside it
            // the program starts is not something this bench is told -- it is
            // something this bench MEASURES. Find the offset that reproduces
            // every downloaded byte and report it. rdft2's is known to be
            // 0x60000; rfjet's has never been measured any other way, and the
            // point of searching rather than asserting is that a wrong guess
            // would show up here as "no offset" instead of as a silent pass on
            // a hardcoded constant that happens to match.
            //
            // Anchor on the first written bytes, then verify each candidate in
            // full -- a run over all 512 KB offsets is otherwise 128 G compares.
            std::vector<uint32_t> cand;
            uint32_t lo = z80dl_lo - Z80_BASE;
            for (uint32_t k = 0; k + 16 <= SND01_SIZE; k++)
                if (!memcmp(&sdram[SND01_BASE + k], &sdram[Z80_BASE + lo], 16))
                    cand.push_back(k);

            std::vector<uint32_t> hits;
            for (uint32_t k : cand) {
                bool ok = true;
                for (uint32_t i = lo; i < Z80_SIZE && ok; i++) {
                    if (!z80_written[i]) continue;
                    uint32_t s = k + (i - lo);
                    ok = (s < SND01_SIZE) && (sdram[Z80_BASE + i] == sdram[SND01_BASE + s]);
                }
                if (ok) hits.push_back(k);
            }

            if (hits.empty()) {
                printf("Z80 program MISMATCH   : no offset in sound1.u0222 "
                       "reproduces the %llu downloaded bytes (%zu anchor "
                       "candidates tried)\n",
                       (unsigned long long)covered, cand.size());
                dl_rc = 1;
            }
            else {
                printf("Z80 program matches sound1.u0222[0x%X..0x%X] byte for "
                       "byte -- %llu bytes%s\n",
                       hits[0], hits[0] + (uint32_t)covered - 1,
                       (unsigned long long)covered,
                       hits.size() > 1 ? " (offset not unique; the program "
                                         "repeats in the ROM)" : "");
            }
        }
        else {
            // rdfts/rdft download a copy of what is already in the Z80 region,
            // so compare against the pristine copy taken before the run.
            uint64_t bad = 0;
            uint32_t first_bad = 0;
            for (uint32_t i = 0; i < Z80_SIZE; i++) {
                if (!z80_written[i]) continue;
                if (sdram[Z80_BASE + i] != z80_src[i]) {
                    if (!bad) first_bad = i;
                    bad++;
                }
            }
            if (bad) {
                printf("Z80 program MISMATCH   : %llu of %llu bytes, first at "
                       "0x%X (got %02X want %02X)\n",
                       (unsigned long long)bad, (unsigned long long)covered,
                       first_bad, sdram[Z80_BASE + first_bad], z80_src[first_bad]);
                dl_rc = 1;
            }
            else {
                printf("Z80 program matches the ROM byte for byte over that range\n");
            }
        }
    }
    else if (set_sxx2c) {
        printf("Z80 RAM bytes written  : none -- the 386 never reached the "
               "download, so the Z80 has no program\n");
        dl_rc = 1;
    }

    (void)first_fetch; (void)fetch_pages;

    {
        FILE *pf = fopen("boot_frame.ppm", "wb");
        if (pf) {
            fprintf(pf, "P6\n%d %d\n255\n", FW, FH);
            fwrite(best_fb.data(), 1, best_fb.size(), pf);
            fclose(pf);
            printf("busiest frame had %llu non-black pixels\n",
                   (unsigned long long)best_nonblack);
            printf("\nwrote sim/boot_frame.ppm (%llu frames, %llu non-black in the last one)\n",
                   (unsigned long long)frames, (unsigned long long)nonblack_last);
        }
    }

    printf("\nverdict: ");
    if (rom_fetches == 0)
        printf("CPU never fetched from ROM -- it is not executing at all.\n");
    else if (io_wr_total == 0)
        printf("CPU fetches ROM but never writes an I/O register -- it runs but "
               "does not reach the video setup code.\n");
    else if (n_dma_pal == 0)
        printf("CPU writes I/O but never triggers the palette DMA -- palette RAM "
               "stays black, which matches the hardware symptom.\n");
    else
        printf("CPU boots and drives the video DMAs.\n");

    delete dut;
    // The download check is the only pass/fail here; everything else is a
    // report, because "how far did it get" is the question this answers.
    return dl_rc;
}
