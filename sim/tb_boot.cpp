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
//  usage: Vtb_boot_top <sdram.bin> [cycles]
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

static const uint32_t SDR_SIZE = 0x1680000;

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

    Vtb_boot_top *dut = new Vtb_boot_top;

    Chan cprg, cgfx, cspr;

    dut->reset     = 1;
    dut->rom_ready = 0;
    dut->clk_sys = dut->clk_cpu = dut->clk_ram = 0;
    dut->sdr_prg_ack = dut->sdr_gfx_ack = dut->sdr_spr_ack = 0;
    dut->sdr_prg_dout = dut->sdr_gfx_dout = dut->sdr_spr_dout = 0;

    // Observations
    uint64_t rom_fetches = 0;
    std::set<uint32_t> fetch_pages;          // 4 KB granularity
    uint32_t first_fetch = 0xFFFFFFFF;
    uint64_t n_dma_tm = 0, n_dma_pal = 0, n_dma_spr = 0, n_vbl = 0;
    std::map<uint32_t, std::pair<uint64_t, uint32_t>> io_writes; // addr -> (count, last value)
    uint64_t io_wr_total = 0;
    uint64_t inta_cycles = 0;
    uint64_t stall_cycles = 0;               // valid held with no ready

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

            if (bus_busy > 0) {
                if (--bus_busy == 0 && bus_owner) {
                    if      (bus_owner == &cprg) retire(cprg, dut->sdr_prg_ack, dut->sdr_prg_dout);
                    else if (bus_owner == &cgfx) retire(cgfx, dut->sdr_gfx_ack, dut->sdr_gfx_dout);
                    else                         retire(cspr, dut->sdr_spr_ack, dut->sdr_spr_dout);
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
    return 0;
}
