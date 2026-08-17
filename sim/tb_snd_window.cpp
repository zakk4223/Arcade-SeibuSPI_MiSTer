//============================================================================
//  spi_snd_window against MAME's own region layout
//
//  The 386 reads MAME's 10 MB `sound01` region as if the two ROMs in it were
//  scattered the way ROM_LOAD32_* scatters them, while the loader stores both
//  PACKED and spi_snd_window unpacks on the fly. This drives the RTL over EVERY
//  dword of that region and checks it against a region assembled the way MAME
//  assembles it.
//
//  The reference here is deliberately NOT a transcription of the RTL. It is
//  MAME's rule, from tools/build_soundflash.py's load_sound01():
//
//      group, lane = divmod(i, lanes)
//      region[base + bank(group * 4 + lane)] = rom[i]
//      bank(raw)  = raw + (raw / 0x200000) * 0x200000
//
//  and the RTL has to reproduce it from the packed copy alone. A model that
//  restated the bit selects could be wrong in exactly the same way the RTL is,
//  which is the trap tools/check_snd01_window.py's own header warns about; that
//  script compares a Python transcription against this same region rule, and
//  this file closes the loop by putting the actual RTL on the other side.
//
//  NO ROM SET NEEDED. The two ROMs are synthetic, which is what lets this run
//  in `make test`: what is being checked is an address mapping, and a pattern
//  with no repeats inside a group proves it as well as real samples would --
//  better, since a real ROM's runs of 0xFF would hide a lane swap.
//
//  Three things it is looking for, all of which have actually happened here:
//    * a lane or bank error, which shifts every byte past some boundary
//    * the gen-A / gen-B mode confusion (1 MB on one lane vs 2 MB on two)
//    * a window claiming an address that MAME's region leaves ERASE00, which is
//      how viprp1 read 0xFF where MAME reads 0x00 on 512 K dwords
//============================================================================

#include "Vspi_snd_window.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <vector>

// rtl/spi_defs.vh
static const uint32_t SDR_SND01_BASE = 0x0480000;
static const uint32_t SPRITES_BASE   = 0x1100000;
static const uint32_t PCMSRC_SEI252  = SPRITES_BASE + 3 * 0x400000;
static const uint32_t PCMSRC_RFJET   = SPRITES_BASE + 3 * 0x800000;

// The 386's map, from tools/build_soundflash.py
static const uint32_t S01_BASE = 0x00A00000;
static const uint32_t S01_SIZE = 0x00A00000;

static const uint32_t SND01_SIZE = 0x80000;      // sound1.u0222, always 512 KB

// rtl/spi_defs.vh SNDW_*
enum { SNDW_PRG = 0, SNDW_S01 = 1, SNDW_PCM = 2 };

static int errors = 0;

// A byte pattern with no short period, so a lane swap or a bank slip cannot
// coincidentally reproduce the right value.
static uint8_t pat(uint32_t i, uint8_t salt) {
    uint32_t x = i * 2654435761u + salt * 0x9E3779B9u;
    x ^= x >> 15; x *= 2246822519u; x ^= x >> 13;
    return (uint8_t)x;
}

static uint32_t bank(uint32_t raw) { return raw + (raw / 0x200000) * 0x200000; }

// ---------------------------------------------------------------------------
// One configuration: a generation, and the two ROMs behind it.
// ---------------------------------------------------------------------------
struct Cfg {
    const char *name;
    bool     one_lane;      // gen A: 1 MB of PCM on one lane
    uint32_t pcm_size;
    uint32_t pcmsrc_base;
    bool     snd01_en;      // viprp1 has no second sound ROM at all
    bool     pcmsrc_en;
};

static int run(const Cfg &cfg) {
    const uint32_t pcm_lanes = cfg.one_lane ? 1 : 2;

    std::vector<uint8_t> pcm(cfg.pcm_size), snd(SND01_SIZE);
    for (uint32_t i = 0; i < cfg.pcm_size; i++) pcm[i] = pat(i, 1);
    for (uint32_t i = 0; i < SND01_SIZE;   i++) snd[i] = pat(i, 2);

    // ---- the reference: MAME's region -------------------------------------
    std::vector<uint8_t> region(S01_SIZE, 0);       // ROMREGION_ERASE00
    if (cfg.pcmsrc_en)
        for (uint32_t i = 0; i < cfg.pcm_size; i++)
            region[bank((i / pcm_lanes) * 4 + (i % pcm_lanes))] = pcm[i];
    if (cfg.snd01_en)
        for (uint32_t i = 0; i < SND01_SIZE; i++)
            region[0x800000 + bank(i * 4)] = snd[i];

    // ---- the SDRAM the loader actually wrote: both ROMs, packed, whole ----
    //
    // A region the SET DOES NOT CARRY reads 0xFF, because the loader never
    // writes it and that is what SDRAM holds. Modelling that is the whole point
    // of the two "no" configurations: viprp1's bug was a window opened over a
    // region nothing had loaded, and the symptom was 0xFF where MAME reads
    // 0x00. Filling this array regardless of the enables would make the test
    // read plausible data through a window that should be shut, and it would
    // pass a decode that opens one.
    auto sdram_group = [&](uint32_t addr) -> uint64_t {
        uint64_t g = 0;
        for (int b = 0; b < 8; b++) {
            uint32_t a = addr + b;
            uint8_t v = 0xFF;                       // unwritten SDRAM
            if (cfg.snd01_en &&
                a >= SDR_SND01_BASE && a < SDR_SND01_BASE + SND01_SIZE)
                v = snd[a - SDR_SND01_BASE];
            else if (cfg.pcmsrc_en &&
                     a >= cfg.pcmsrc_base && a < cfg.pcmsrc_base + cfg.pcm_size)
                v = pcm[a - cfg.pcmsrc_base];
            g |= (uint64_t)v << (8 * b);
        }
        return g;
    };

    Vspi_snd_window *dut = new Vspi_snd_window;
    dut->snd01_en     = cfg.snd01_en;
    dut->pcmsrc_en    = cfg.pcmsrc_en;
    dut->pcmsrc_1lane = cfg.one_lane;
    dut->pcmsrc_base  = cfg.pcmsrc_base;

    uint32_t bad = 0, claimed = 0, zeroed = 0;
    uint32_t first_bad = 0, first_want = 0, first_got = 0;

    for (uint32_t off = 0; off < S01_SIZE; off += 4) {
        const uint32_t dw = (S01_BASE + off) >> 2;

        // Decode, exactly as spi_cpu latches it.
        dut->sel_dw = dw;
        dut->cur_dw = dw;
        dut->src    = SNDW_PRG;
        dut->grp_data = 0;
        dut->eval();

        const uint32_t want = (uint32_t)region[off]
                            | ((uint32_t)region[off + 1] << 8)
                            | ((uint32_t)region[off + 2] << 16)
                            | ((uint32_t)region[off + 3] << 24);

        uint32_t got;
        if (!dut->sel_s01 && !dut->sel_pcm) {
            // Unclaimed: spi_cpu answers zero, and MAME's region must agree --
            // this is the arm that catches a window opened over nothing.
            got = 0;
            zeroed++;
        } else {
            dut->src = dut->sel_s01 ? SNDW_S01 : SNDW_PCM;
            dut->eval();
            dut->grp_data = sdram_group(dut->grp_addr);
            dut->eval();
            if (dut->sel_s01)          got = dut->byte_out;            // lane 0
            else if (cfg.one_lane)     got = dut->byte_out;            // lane 0
            else                       got = dut->pair_out;            // lanes 0-1
            claimed++;
        }

        if (got != want) {
            if (!bad) { first_bad = S01_BASE + off; first_want = want; first_got = got; }
            bad++;
        }
    }

    if (bad) {
        printf("FAIL: %-22s %u of %u dwords differ; first at %07X: "
               "want %08X got %08X\n", cfg.name, bad, S01_SIZE / 4,
               first_bad, first_want, first_got);
        errors++;
    } else {
        printf("%-22s %u dwords: %u through a window, %u left ERASE00, all match\n",
               cfg.name, S01_SIZE / 4, claimed, zeroed);
    }
    delete dut;
    return bad ? 1 : 0;
}

// ---------------------------------------------------------------------------
// grp_last has to agree with the group the address arithmetic actually lands
// in, or a burst refetches at the wrong point. Derive it from grp_addr rather
// than restating the rule: the last dword of a group is the one after which
// grp_addr changes.
// ---------------------------------------------------------------------------
static void check_grp_last(const Cfg &cfg, int src) {
    Vspi_snd_window *dut = new Vspi_snd_window;
    dut->snd01_en = 1; dut->pcmsrc_en = 1;
    dut->pcmsrc_1lane = cfg.one_lane;
    dut->pcmsrc_base  = cfg.pcmsrc_base;
    dut->grp_data = 0;

    uint32_t bad = 0;
    const uint32_t base_dw = S01_BASE >> 2;
    for (uint32_t i = 0; i < 0x40000; i++) {
        dut->sel_dw = base_dw + i; dut->cur_dw = base_dw + i; dut->src = src;
        dut->eval();
        const uint32_t a0 = dut->grp_addr;
        const int      gl = dut->grp_last;

        dut->cur_dw = base_dw + i + 1;
        dut->eval();
        if (gl != (dut->grp_addr != a0)) bad++;
    }
    if (bad) {
        printf("FAIL: grp_last disagrees with grp_addr on %u of 262144 dwords "
               "(%s, src %d)\n", bad, cfg.name, src);
        errors++;
    } else {
        printf("grp_last: 262144 dwords agree with grp_addr (%s, src %d)\n",
               cfg.name, src);
    }
    delete dut;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);

    // Generation B, two lanes, 2 MB -- rdft, rdft2, rfjet.
    Cfg genb = { "gen B (2 MB, 2 lanes)", false, 0x200000, PCMSRC_RFJET, true, true };
    // Generation A, one lane, 1 MB -- senkyu, ejanhs, viprp1. Its base is the
    // SEI252 one, which is 12 MB below rfjet's: a base carried across from the
    // wrong set reads sprite data as samples and this is where that shows.
    Cfg gena = { "gen A (1 MB, 1 lane)", true, 0x100000, PCMSRC_SEI252, true, true };
    // viprp1: generation A with NO second sound ROM. The sound1 window must
    // stay shut, or the 386 reads unwritten SDRAM (0xFF) where MAME reads 0x00.
    Cfg vip  = { "gen A, no sound1", true, 0x100000, PCMSRC_SEI252, false, true };
    // Pre-flashed: the PCM source is not loaded at all, so that window must be
    // shut too even though the set is a cartridge.
    Cfg pre  = { "pre-flashed, no pcmsrc", false, 0x200000, PCMSRC_RFJET, true, false };

    run(genb);
    run(gena);
    run(vip);
    run(pre);

    check_grp_last(genb, SNDW_PCM);
    check_grp_last(gena, SNDW_PCM);
    check_grp_last(genb, SNDW_S01);
    check_grp_last(genb, SNDW_PRG);

    if (errors) {
        printf("\n%d FAILURES\n", errors);
        return 1;
    }
    printf("\nall spi_snd_window checks passed\n");
    return 0;
}
