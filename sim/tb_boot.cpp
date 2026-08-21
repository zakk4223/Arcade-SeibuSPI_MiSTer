//============================================================================
//  SeibuSPI - does the 386 actually boot?
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
    uint32_t idt_base_last = 0;
    uint64_t idt_changes = 0;
    uint32_t eip_last = 0;
    uint64_t eip_changes = 0, in_stub_cycles = 0;
    int      in_stub_d = 0, in_stub_runs = 0;

    // ---- savestates ------------------------------------------------------
    // SS_AT is a cycle count at which a save is asked for, the way the OSD
    // asks; SS_RESTORE_AT likewise for a load. 0 disables each, so every
    // existing use of this testbench behaves exactly as before.
    const char *ss_env = getenv("SS_AT");
    const uint64_t ss_at = ss_env ? strtoull(ss_env, nullptr, 0) : 0;
    const char *rst_env = getenv("SS_RESTORE_AT");
    const uint64_t ss_restore_at = rst_env ? strtoull(rst_env, nullptr, 0) : 0;
    // SS_RELOADS is how many loads to fire in total, back to back, each one
    // SS_RELOAD_GAP cycles after the previous finished. 1 (the default) is the
    // old single-restore behaviour exactly. This exists because the hardware
    // lockup is a REPEATED load -- "2-3 reloads of the same state one after
    // another" -- and a single restore never reproduced it. PLAN.md 44.
    const char *rn_env = getenv("SS_RELOADS");
    const unsigned ss_reloads = rn_env ? (unsigned)strtoul(rn_env, nullptr, 0) : 1;
    const char *rg_env = getenv("SS_RELOAD_GAP");
    const uint64_t ss_reload_gap = rg_env ? strtoull(rg_env, nullptr, 0) : 1000;
    unsigned rs_count = 0;          // loads fired so far
    uint64_t rs_next  = 0;          // cycle the next one may fire at

    const char *ha_env = getenv("SS_HASH_AFTER");
    const uint64_t ss_hash_after = ha_env ? strtoull(ha_env, nullptr, 0) : 0;

    // A flat DDR3, 512 KB of it -- one savestate slot. memory_stream drives a
    // byte address and a 64-bit port, so this is indexed by addr >> 3. Answers
    // with the one-cycle latency the real controller has at its best; there is
    // no point modelling worse, because the engine holds its request until
    // rdata_ready and the transfer is not on any critical path.
    std::vector<uint64_t> ddr(65536, 0);
    dut->ddr_rdata       = 0;
    dut->ddr_busy        = 0;
    dut->ddr_rdata_ready = 0;
    dut->ss_save = 0;
    dut->ss_load = 0;
    int      ddr_lat = -1;
    uint32_t ddr_lat_addr = 0;
    uint64_t ddr_writes = 0, ddr_reads = 0;

    bool     ss_fired = false, ss_done = false;
    bool     rs_fired = false, rs_done = false;
    uint64_t ss_snap_cyc = 0;
    uint32_t ss_saved_esp = 0;
    bool     ss_busy_d = false;
    uint64_t ds_rtc_d = 0;
    // SS_DSTRACE: every RTC tick during an operation, and every non-zero read
    // of the DS2404's data port with the cycle and the counter behind it. The
    // cycle is the part that matters -- a value difference alone cannot say
    // whether the clock is wrong or the game arrived at a different time.
    const bool ds_trace = getenv("SS_DSTRACE") != nullptr;
    uint64_t ss_resume_cyc = 0, ss_resume_vbl = 0;
    bool     ss_hashed = false;
    uint32_t ss_saved_eip = 0;
    bool     ss_eip_matched = false;
    uint64_t ss_eip_match_cyc = 0;
    bool     ss_entered = false;
    uint64_t ss_enter_cyc = 0;
    uint32_t ss_marker = 0;
    uint64_t ss_hash_at_save = 0, ss_hash_pre_load = 0, ss_hash_post_load = 0;
    uint32_t trail[24] = {0}; int trail_n = 0; bool trail_armed = false;
    const size_t IO_RD_MAX = 400000; size_t io_rd_n = 0; bool io_rd_d = false;
    const char *iort = getenv("SS_IORD");
    uint32_t *io_rd_trail = iort ? new uint32_t[IO_RD_MAX] : nullptr;
    const size_t LONG_MAX_N = 400000; size_t long_n = 0;
    const char *lt_path = getenv("SS_TRAIL");
    uint32_t *long_trail = lt_path ? new uint32_t[LONG_MAX_N] : nullptr;
    const size_t LONG_MAX = LONG_MAX_N;
    uint64_t ss_snap_vbl = 0, ss_busy_start = 0, ss_hash_anchor = 0;

    for (uint64_t t = 0; t < max_steps; t++) {
        // clk_ram toggles every step; clk_sys every 2; clk_cpu every 4
        dut->clk_ram = (t >> 0) & 1;
        dut->clk_sys = (t >> 1) & 1;
        dut->clk_cpu = (t >> 2) & 1;

        // The DDR3 the blob lives in. One clk_sys tick per two steps, which
        // is where memory_stream runs. A read answers on the next tick; a
        // write lands immediately. The engine holds its request until it sees
        // rdata_ready, so a lazier model would only make the transfer longer.
        if ((t & 3) == 0) {
            bool acq = dut->ddr_acquire;
            // SS_DDR_BUSY models a SECOND MASTER on DDR3 -- which on hardware is
            // screen_rotate, and which this bench has never had. It matters now:
            // before 42 the raster froze during a transfer so rotate was idle,
            // and now video free-runs and rotate bursts throughout. Deterministic
            // (no rand) so a failure reproduces. PLAN.md 44.
            dut->ddr_rdata_ready = 0;
            if (ddr_lat == 0) {
                dut->ddr_rdata = ddr[(ddr_lat_addr >> 3) & 0xFFFF];
                dut->ddr_rdata_ready = 1;
                ddr_lat = -1;
                ddr_reads++;
            } else if (ddr_lat > 0) {
                ddr_lat--;
            } else if (acq && dut->ddr_read) {
                ddr_lat_addr = dut->ddr_addr;
                ddr_lat = 0;
            } else if (acq && dut->ddr_write) {
                uint32_t w = (dut->ddr_addr >> 3) & 0xFFFF;
                uint64_t cur = ddr[w], nw = dut->ddr_wdata;
                for (int b = 0; b < 8; b++)
                    if (dut->ddr_byteenable & (1u << b)) {
                        uint64_t m = 0xFFULL << (8 * b);
                        cur = (cur & ~m) | (nw & m);
                    }
                ddr[w] = cur;
                ddr_writes++;
            }
        }

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
            if (dut->p_eip != eip_last) {
                eip_changes++;
                // The first few instruction boundaries after a load is
                // released: where the restore stub's iret actually landed.
                if (in_stub_d && trail_armed && trail_n < 24)
                    trail[trail_n++] = dut->p_eip;
                // The full instruction trail after the last operation finished.
                // Diffing two of these names the exact instruction at which a
                // restored machine first goes a different way, which is a fact
                // rather than a guess about which section is missing.
                if (long_trail && ss_hash_anchor && long_n < LONG_MAX)
                    long_trail[long_n++] = dut->p_eip;
                eip_last = dut->p_eip;
            }
            if (dut->p_ss_in_stub) in_stub_cycles++;
            if (dut->p_ss_in_stub != in_stub_d) {
                if (in_stub_runs++ < 16)
                    printf("  SS: in_stub %d -> %d at cycle %llu, EIP=%08X\n",
                           in_stub_d, dut->p_ss_in_stub,
                           (unsigned long long)cyc, dut->p_eip);
                // Arm the trail when the CPU leaves the stub for the second
                // time, which on a save-then-load run is the load's exit.
                if (in_stub_d && !dut->p_ss_in_stub) {
                    if (ss_done) trail_armed = true;
                }
                in_stub_d = dut->p_ss_in_stub;
            }

            // Phase 0 of the savestate work: the IDT has to be visible and
            // stable before a gate in it can be overlaid. Record when the boot
            // code's LIDT lands and whether it ever moves afterwards.
            if (dut->p_idt_base != idt_base_last) {
                idt_changes++;
                if (idt_changes <= 8)
                    printf("  IDT -> base=%08X limit=%05X at cycle %llu "
                           "(CS=%04X EIP=%08X)\n",
                           dut->p_idt_base, dut->p_idt_limit,
                           (unsigned long long)cyc, dut->p_cs, dut->p_eip);
                idt_base_last = dut->p_idt_base;
            }

            // ---- savestates, driven the way the OSD drives them --------
            // One pulse in, and the board does everything: NMI, stub, freeze,
            // the whole blob through memory_stream to DDR3, release. Phase 0's
            // testbench drove each of those steps by hand; none of that is
            // here any more, which is the point -- what runs now is the path
            // the hardware takes.
            dut->ss_save = 0;
            dut->ss_load = 0;
            if (ss_at && !ss_fired && cyc >= ss_at && !dut->p_ss_busy) {
                ss_fired = true;
                dut->ss_save = 1;
                printf("  SS: RTC at request: %llu (tick %u)\n",
                       (unsigned long long)dut->p_ds_rtc, dut->p_ds_tick);
                printf("  SS: save asked for at cycle %llu, CS=%04X EIP=%08X\n",
                       (unsigned long long)cyc, dut->p_cs, dut->p_eip);
            }
            if (ss_restore_at && ss_done && rs_count < ss_reloads
                && cyc >= (rs_count ? rs_next : ss_restore_at)
                && !dut->p_ss_busy) {
                rs_count++;
                rs_fired = true;           // the first one still gates the
                                           // existing verdicts and hashes
                rs_next  = cyc + ss_reload_gap;
                dut->ss_load = 1;
                if (ss_reloads > 1)
                    printf("  SS: --- load %u of %u ---\n", rs_count, ss_reloads);
                printf("  SS: RTC at request: %llu (tick %u)\n",
                       (unsigned long long)dut->p_ds_rtc, dut->p_ds_tick);
                printf("  SS: load asked for at cycle %llu, CS=%04X EIP=%08X\n",
                       (unsigned long long)cyc, dut->p_cs, dut->p_eip);
            }

            if (dut->p_ss_snapshot && !ss_snap_cyc) {
                ss_snap_cyc  = cyc;
                // Frozen, and the stream has not run yet on a save nor
                // finished on a load. Hashing main RAM here is layout-free:
                // the two hashes must match if the restore is exact, and
                // neither depends on knowing how memory_stream packs a section.
                uint64_t hh = 1469598103934665603ULL;
                for (uint32_t i = 0; i < 65536; i++) {
                    dut->peek_addr = (uint16_t)i;
                    dut->eval();
                    uint32_t v = dut->peek_data;
                    for (int b = 0; b < 4; b++) {
                        hh ^= (v >> (8 * b)) & 0xFF; hh *= 1099511628211ULL;
                    }
                }
                ss_snap_vbl = n_vbl;
                if (!ss_done) ss_hash_at_save = hh;
                else          ss_hash_pre_load = hh;
                if (!ss_done) ss_saved_esp = dut->p_ss_esp_out;
                else          ss_marker    = dut->p_ss_esp_out;
                printf("  SS: frozen at cycle %llu, marker slot %08X\n",
                       (unsigned long long)cyc, ss_saved_esp);
            }

            // busy falls when the whole operation is over.
            // Every RTC tick that happens while a savestate is in progress,
            // with the sequencer state it happened in. `pause` is deliberately
            // NOT asserted in S_ARM, so ticking there is correct on a SAVE --
            // the machine is live. On a load it was the leak that made three
            // write-ups blame the RTC; see rtl/spi_ss.sv.
            if (ds_trace && dut->p_ss_busy && dut->p_ds_rtc != ds_rtc_d)
                printf("    SS: RTC tick -> %llu at cycle %llu, ss_state=%u\n",
                       (unsigned long long)dut->p_ds_rtc,
                       (unsigned long long)cyc, dut->p_ss_state);
            ds_rtc_d = dut->p_ds_rtc;

            if (!ss_busy_d && dut->p_ss_busy) {
                ss_busy_start = cyc;
                printf("  SS: RTC when the operation was armed: %llu (tick %u)\n",
                       (unsigned long long)dut->p_ds_rtc, dut->p_ds_tick);
            }
            if (ss_busy_d && !dut->p_ss_busy) {
                printf("  SS: the board was paused for %llu cycles = %llu "
                       "model steps\n",
                       (unsigned long long)(cyc - ss_busy_start),
                       (unsigned long long)((cyc - ss_busy_start) * 4));
                if (!ss_done) {
                    ss_done = true;
                    printf("  SS: the CPU was frozen for %llu cycles "
                           "(%.2f ms at clk_sys) and %llu vblanks passed in "
                           "that time\n",
                           (unsigned long long)(cyc - ss_snap_cyc),
                           (double)(cyc - ss_snap_cyc) / 57272.727,
                           (unsigned long long)(n_vbl - ss_snap_vbl));
                    printf("  SS: SAVE COMPLETE at cycle %llu -- %llu DDR3 "
                           "writes, %llu reads\n",
                           (unsigned long long)cyc,
                           (unsigned long long)ddr_writes,
                           (unsigned long long)ddr_reads);
                    // What the blob says. Section GLOBAL's header is at word
                    // 1 and its one item at word 2; MAIN_RAM's header follows.
                    printf("        blob GLOBAL payload = %08X  (should be the "
                           "marker slot %08X)\n",
                           (uint32_t)(ddr[2] & 0xFFFFFFFFu), ss_saved_esp);
                    // The frame, read out of main RAM rather than out of the
                    // blob: the stub does not erase it on its way out, and the
                    // peek window is authoritative where a hand-rolled parse of
                    // memory_stream's packing is just one more thing to get
                    // wrong.
                    static const char *fn[] = {
                        "marker", "EDI", "ESI", "EBP", "ESP(pushad)", "EBX",
                        "EDX", "ECX", "EAX", "EIP", "CS", "EFLAGS" };
                    printf("        the frame on the game's stack:\n");
                    for (int i = 0; i < 12; i++) {
                        uint32_t byte = ss_saved_esp + 4u * i;
                        dut->peek_addr = (uint16_t)((byte >> 2) & 0xFFFF);
                        dut->eval();
                        if (i == 9) ss_saved_eip = dut->peek_data;
                        printf("          [%08X] = %08X   %s\n",
                               byte, dut->peek_data, fn[i]);
                    }
                } else if (!rs_done) {
                    rs_done = true;
                    printf("  SS: LOAD COMPLETE at cycle %llu\n",
                           (unsigned long long)cyc);
                    // Main RAM should now be the blob, byte for byte. The
                    // frame the CPU is about to pop is part of that, so this
                    // covers it too.
                    uint32_t diff = 0;
                    for (uint32_t i = 0; i < 65536; i++) {
                        dut->peek_addr = (uint16_t)i;
                        dut->eval();
                        uint64_t d = ddr[3 + (i >> 1)];
                        uint32_t want = (i & 1) ? (uint32_t)(d >> 32)
                                               : (uint32_t)(d & 0xFFFFFFFFu);
                        if (dut->peek_data != want) diff++;
                    }
                    printf("        main RAM vs the blob: %u of 65536 dwords "
                           "differ (layout-dependent, diagnostic only)\n", diff);
                    // The check that counts. Hashed while frozen in both cases,
                    // so nothing the CPU does after release can contaminate it.
                    uint64_t hh = 1469598103934665603ULL;
                    for (uint32_t i = 0; i < 65536; i++) {
                        dut->peek_addr = (uint16_t)i;
                        dut->eval();
                        uint32_t v = dut->peek_data;
                        for (int b = 0; b < 4; b++) {
                            hh ^= (v >> (8 * b)) & 0xFF; hh *= 1099511628211ULL;
                        }
                    }
                    ss_hash_post_load = hh;
                    printf("        main RAM at save   : %016llX\n"
                           "        main RAM before it : %016llX\n"
                           "        main RAM restored  : %016llX  %s\n",
                           (unsigned long long)ss_hash_at_save,
                           (unsigned long long)ss_hash_pre_load,
                           (unsigned long long)ss_hash_post_load,
                           ss_hash_post_load == ss_hash_at_save
                             ? "<- EXACT" : "<- MISMATCH");
                }
                ss_snap_cyc = 0;
                // The anchor for the determinism hash: the last moment the
                // savestate let go. Unambiguous, and present in both a
                // save-only run and a save-then-load one, which is what makes
                // the two comparable at all.
                if (ss_hash_after && !(ss_restore_at && !rs_done))
                    ss_hash_anchor = cyc;
                // The vblank interrupt's state at the moment the machine is
                // handed back. It is spi_cpu's, not the 386's, and it is not in
                // the blob -- so if the two runs disagree here, that is what a
                // vblank-wait loop is diverging on.
                printf("  SS: at release: irq_pending=%d, RTC=%llu (tick %u)\n",
                       dut->p_cpu_irq, (unsigned long long)dut->p_ds_rtc,
                       dut->p_ds_tick);
            }
            ss_busy_d = dut->p_ss_busy;

            // The determinism hash, taken a fixed number of cycles after the
            // savestate let go. Run it once with a save alone and once with a
            // save and then a load: if the restore is faithful the two must be
            // identical, because the CPU's evolution is a function of its
            // registers and main RAM and nothing else.
            if (ss_hash_anchor && !ss_hashed
                && cyc >= ss_hash_anchor + ss_hash_after) {
                ss_hashed = true;
                uint64_t hh = 1469598103934665603ULL;
                for (uint32_t i = 0; i < 65536; i++) {
                    dut->peek_addr = (uint16_t)i;
                    dut->eval();
                    uint32_t v = dut->peek_data;
                    for (int b = 0; b < 4; b++) {
                        hh ^= (v >> (8 * b)) & 0xFF; hh *= 1099511628211ULL;
                    }
                }
                printf("  SS: RTC %llu cycles after the operation: %llu "
                       "(tick %u)\n",
                       (unsigned long long)ss_hash_after,
                       (unsigned long long)dut->p_ds_rtc, dut->p_ds_tick);
                printf("  SS: RAM hash %llu cycles after the operation "
                       "finished: %016llX\n",
                       (unsigned long long)ss_hash_after,
                       (unsigned long long)hh);
                // ...and the memory itself, at that same instant, so two runs
                // can be diffed dword by dword. A hash only ever says
                // "different", and "different" has meant a handful of dead
                // stack words as often as it has meant a broken restore.
                if (const char *dp = getenv("SS_DUMP_AT")) {
                    FILE *f = fopen(dp, "wb");
                    if (f) {
                        for (uint32_t i = 0; i < 65536; i++) {
                            dut->peek_addr = (uint16_t)i;
                            dut->eval();
                            uint32_t v = dut->peek_data;
                            fwrite(&v, 4, 1, f);
                        }
                        fclose(f);
                    }
                }
            }

            // The determinism probe, as in phase 0: measured from the first
            // cycle after the operation finishes at which the CPU is executing
            // at the EIP that was saved.
            if (ss_saved_eip && !ss_resume_cyc
                && (ss_restore_at ? rs_done : ss_done)
                && dut->p_eip == ss_saved_eip) {
                ss_resume_cyc = cyc;
                ss_resume_vbl = n_vbl;
                ss_eip_matched = true;
                ss_eip_match_cyc = cyc;
                printf("  SS: resumed at the saved EIP %08X, cycle %llu\n",
                       ss_saved_eip, (unsigned long long)cyc);
            }
            if (ss_hash_after && ss_resume_cyc && !ss_hashed
                && cyc >= ss_resume_cyc + ss_hash_after) {
                ss_hashed = true;
                uint64_t hh = 1469598103934665603ULL;
                for (uint32_t i = 0; i < 65536; i++) {
                    dut->peek_addr = (uint16_t)i;
                    dut->eval();
                    uint32_t v = dut->peek_data;
                    for (int b = 0; b < 4; b++) {
                        hh ^= (v >> (8 * b)) & 0xFF;
                        hh *= 1099511628211ULL;
                    }
                }
                printf("  SS: RAM hash %llu cycles after resume (%llu vblanks "
                       "since): %016llX\n",
                       (unsigned long long)ss_hash_after,
                       (unsigned long long)(n_vbl - ss_resume_vbl),
                       (unsigned long long)hh);
            }

            if (ss_fired && !ss_entered && dut->p_ss_in_stub) {
                ss_entered   = true;
                ss_enter_cyc = cyc;
                printf("  SS: in the stub at cycle %llu (%llu after asking), "
                       "EIP=%08X\n",
                       (unsigned long long)cyc,
                       (unsigned long long)(cyc - ss_at), dut->p_eip);
            }

            // Every I/O read the 386 makes after the operation finishes, with
            // what it got back. Diffing two of these says what a poll loop is
            // actually looking at, which is the question four sections were
            // added without ever asking.
            // Every non-zero read of the DS2404's data port, with the cycle
            // and the RTC behind it. The value alone cannot say whether a
            // difference is the clock being wrong or the game arriving at a
            // different time; the cycle says which.
            if (ds_trace && dut->p_io_rd && !io_rd_d
                && dut->p_io_raddr * 4 == 0x6DC && dut->p_io_rdata != 0)
                printf("    DS: 0x6DC -> %02X at cycle %llu (anchor+%lld), "
                       "RTC=%llu tick=%u\n",
                       dut->p_io_rdata, (unsigned long long)cyc,
                       (long long)(cyc - (long long)ss_hash_anchor),
                       (unsigned long long)dut->p_ds_rtc, dut->p_ds_tick);

            if (io_rd_trail && ss_hash_anchor && dut->p_io_rd && !io_rd_d
                && io_rd_n + 2 < IO_RD_MAX) {
                io_rd_trail[io_rd_n++] = dut->p_io_raddr * 4;
                io_rd_trail[io_rd_n++] = dut->p_io_rdata;
            }
            io_rd_d = dut->p_io_rd;

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
            // Why is the CPU not advancing? spi_cpu's mem_accept is an AND of
            // several holds and the columns above show only some of them. These
            // are the savestate's, and a wedged load is one of them stuck on.
            printf("         ss: hold=%u snapshot=%u in_stub=%u nmi=%u state=%u"
                   "  irq=%u\n",
                   dut->p_ss_hold, dut->p_ss_snapshot, dut->p_ss_in_stub,
                   dut->p_ss_nmi, dut->p_ss_state, dut->p_cpu_irq);
            printf("         stalls: io=%u z80dl=%u ds=%u\n",
                   (dut->p_ss_stalls >> 2) & 1, (dut->p_ss_stalls >> 1) & 1,
                   dut->p_ss_stalls & 1);
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
           // Was "expected: the Verilator T80 is a stub" -- true when the
           // Z80 was VHDL and Verilator could not read it, and a lie since
           // tv80 replaced it (PLAN.md 39.5). Zero fetches is now a real
           // finding: on a cartridge set it means the 386 has not finished
           // downloading the sound program yet.
           cz80.count ? "" : "  (the Z80 has not fetched anything yet -- on a "
                             "cartridge set, the download is not done)");
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

    printf("IDT at end             : base=%08X limit=%05X (%llu changes), "
           "CS=%04X EIP=%08X\n",
           dut->p_idt_base, dut->p_idt_limit,
           (unsigned long long)idt_changes, dut->p_cs, dut->p_eip);
    printf("CS base / CR0          : %08X / %08X  (PE=%d PG=%d)\n",
           dut->p_cs_base, dut->p_cr0,
           (int)(dut->p_cr0 & 1), (int)((dut->p_cr0 >> 31) & 1));

    if (ss_at) {
        printf("\n-- savestates --\n");
        printf("save asked at cycle    : %llu\n", (unsigned long long)ss_at);
        printf("gate reads answered    : %u  (0 = the CPU never fetched the "
               "overlaid gate)\n", dut->p_ss_gate_reads);
        printf("stub entry             : %s\n",
               ss_entered ? "yes" : "NEVER -- the gate was not taken");
        printf("stub writes            : %u, last [%08X] = %08X\n",
               dut->p_ss_writes, dut->p_ss_last_wa, dut->p_ss_last_wd);
        printf("save completed         : %s\n", ss_done ? "yes" : "NO");
        printf("DDR3 traffic           : %llu writes, %llu reads\n",
               (unsigned long long)ddr_writes, (unsigned long long)ddr_reads);

        // The blob's own header, which is what Main_MiSTer reads: dword 0 is a
        // generation counter it polls, dword 1 the length in dwords, and the
        // file it writes is (length + 2) * 4 bytes.
        printf("blob header            : gen=%08X len=%u dwords -> %u bytes\n",
               (uint32_t)(ddr[0] & 0xFFFFFFFFu),
               (uint32_t)(ddr[0] >> 32),
               (uint32_t)(((ddr[0] >> 32) + 2) * 4));

        // Walk the section records the way util/dump_pgmstate.py does, so the
        // stream can be checked against what the sections claim to hold.
        printf("sections:\n");
        uint32_t w = 1;
        for (int guard = 0; guard < 32; guard++) {
            uint64_t hdr = ddr[w];
            if ((hdr >> 56) == 0xFF) { printf("    terminator at dword %u\n", w); break; }
            uint32_t cnt   = (uint32_t)(hdr & 0xFFFFFFFFu);
            uint32_t wcode = (uint32_t)((hdr >> 32) & 3);
            uint32_t idx   = (uint32_t)((hdr >> 56) & 0x1F);
            static const char *nm[] = {"GLOBAL","MAIN_RAM","TILEMAP","PALETTE",
                                       "SPRITE"};
            static const int bytes[] = {1,2,4,8};
            uint32_t payload = (cnt * bytes[wcode] + 7) / 8;
            printf("    %-9s idx=%u count=%-6u width=%d-bit  %u payload "
                   "dwords\n", idx < 5 ? nm[idx] : "?", idx, cnt,
                   bytes[wcode] * 8, payload);
            w += 1 + payload;
        }
    }

    {
        // FNV-1a over all 65,536 dwords of main RAM. Two runs that differ
        // anywhere in the 386's world differ here.
        uint64_t h = 1469598103934665603ULL;
        for (uint32_t i = 0; i < 65536; i++) {
            dut->peek_addr = (uint16_t)i;
            dut->eval();
            uint32_t v = dut->peek_data;
            for (int b = 0; b < 4; b++) {
                h ^= (v >> (8 * b)) & 0xFF;
                h *= 1099511628211ULL;
            }
        }
        printf("main RAM hash          : %016llX\n", (unsigned long long)h);
    }
    // A dump, so two runs can be diffed dword by dword rather than compared
    // through a hash that says only "different".
    if (const char *dp = getenv("SS_DUMP")) {
        FILE *f = fopen(dp, "wb");
        if (f) {
            for (uint32_t i = 0; i < 65536; i++) {
                dut->peek_addr = (uint16_t)i;
                dut->eval();
                uint32_t v = dut->peek_data;
                fwrite(&v, 4, 1, f);
            }
            fclose(f);
            printf("wrote main RAM to      : %s\n", dp);
        }
    }
    printf("EIP transitions        : %llu   (a stuck CPU shows very few)\n",
           (unsigned long long)eip_changes);
    printf("cycles with EIP in stub: %llu\n",
           (unsigned long long)in_stub_cycles);
    if (ss_restore_at) {
        printf("stub window            : %u reads, last idx=%02X data=%08X\n",
               dut->p_ss_stub_reads, dut->p_ss_stub_idx, dut->p_ss_stub_data);
        printf("esp the stub was given : %08X\n", dut->p_ss_esp_scratch);
        {   // Is the stub's scratch address inside the stack segment at all?
            uint64_t lim = dut->p_ss_limit;
            uint64_t eff = dut->p_ss_g ? ((lim << 12) | 0xFFF) : lim;
            printf("SS descriptor          : base=%08X limit=%05X G=%d type=%X"
                   "  -> spans 0..%llX  (0x40204 %s)\n",
                   dut->p_ss_base, dut->p_ss_limit, dut->p_ss_g, dut->p_ss_type,
                   (unsigned long long)eff,
                   (0x40204u <= eff) ? "INSIDE" : "OUTSIDE -- reads there fault");
        }
        // Did the CPU pass through the saved EIP on its way out of the stub?
        // Not "is it there now": the settled probe reports whatever it reached
        // after a few cycles, which is an instruction or two later.
        bool hit = false;
        for (int i = 0; i < trail_n; i++) if (trail[i] == ss_saved_eip) hit = true;
        printf("saved EIP / settled at : %08X / %08X\n",
               ss_saved_eip, dut->p_ss_resume_eip);
        printf("resumed at the saved EIP: %s\n",
               hit ? "YES" : "NO -- the iret did not land where it was saved");
        printf("first EIPs after load  :");
        for (int i = 0; i < trail_n; i++) printf(" %08X", trail[i]);
        printf("\n");
        printf("restore                : %s\n",
               ss_eip_matched
                 ? "the CPU resumed at the saved CS:EIP"
                 : "FAILED -- the CPU never reached the saved EIP");
        if (ss_eip_matched)
            printf("  resumed at cycle     : %llu\n",
                   (unsigned long long)ss_eip_match_cyc);
    }
    if (io_rd_trail) {
        FILE *f = fopen(iort, "wb");
        if (f) { fwrite(io_rd_trail, 4, io_rd_n, f); fclose(f); }
        printf("wrote %zu I/O reads after the operation to %s\n",
               io_rd_n / 2, iort);
    }
    if (long_trail) {
        FILE *f = fopen(lt_path, "wb");
        if (f) { fwrite(long_trail, 4, long_n, f); fclose(f); }
        printf("wrote %zu EIPs after the operation to %s\n", long_n, lt_path);
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
