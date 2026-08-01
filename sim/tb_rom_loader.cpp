//============================================================================
//  SlopperPI - testbench for rom_loader
//
//  Streams a synthetic concatenated ROM image (byte value = low 8 bits of its
//  offset within its own part, so every part is independently checkable) through
//  the loader and compares the resulting SDRAM image against a reference model
//  that implements MAME's ROM_LOAD24_* / ROM_LOAD32_* semantics directly.
//============================================================================

#include "Vrom_loader.h"
#include "verilated.h"

#include <cstdio>
#include <cstdint>
#include <vector>
#include <string>

// ---------------------------------------------------------------------------
// SDRAM byte map (must match rtl/spi_defs.vh)
// ---------------------------------------------------------------------------
static const uint32_t PRG_BASE     = 0x0000000;
static const uint32_t Z80_BASE     = 0x0200000;
static const uint32_t CHARS_BASE   = 0x0240000;
static const uint32_t PCM_BASE     = 0x0280000;
static const uint32_t TILES_BASE   = 0x0480000;
static const uint32_t SPRITES_BASE = 0x0A80000;
static const uint32_t SDR_SIZE     = 0x1680000;

enum Mode { LINEAR, W32_B0, W32_B1, W32_B2, W32_B3, W32_W01, W32_W23,
            W24_B0, W24_B1, W24_B2, W24_W01 };

struct Part { const char *name; uint32_t base; uint32_t size; Mode mode; };

// Must match the part table in rtl/rom_loader.sv and the <part> order in the MRA.
static const Part parts[] = {
    { "seibu_1.u0259",        PRG_BASE,                  0x080000, W32_B0  },
    { "raiden-f_prg2.u0258",  PRG_BASE,                  0x080000, W32_B1  },
    { "raiden-f_prg34.u0262", PRG_BASE,                  0x100000, W32_W23 },
    { "seibu_zprg.u1139",     Z80_BASE,                  0x020000, LINEAR  },
    { "raiden-f_fix.u0535",   CHARS_BASE,                0x020000, W24_W01 },
    { "seibu_fix2.u0528",     CHARS_BASE,                0x010000, W24_B2  },
    { "gun_dogs_bg1-d.u0526", TILES_BASE,                0x200000, W24_W01 },
    { "gun_dogs_bg1-p.u0531", TILES_BASE,                0x100000, W24_B2  },
    { "gun_dogs_bg2-d.u0534", TILES_BASE   + 0x300000,   0x200000, W24_W01 },
    { "gun_dogs_bg2-p.u0530", TILES_BASE   + 0x300000,   0x100000, W24_B2  },
    { "gun_dogs_obj-1.u0322", SPRITES_BASE + 0x000000,   0x400000, LINEAR  },
    { "gun_dogs_obj-2.u0324", SPRITES_BASE + 0x400000,   0x400000, LINEAR  },
    { "gun_dogs_obj-3.u0323", SPRITES_BASE + 0x800000,   0x400000, LINEAR  },
    { "raiden-f_pcm2.u0975",  PCM_BASE,                  0x200000, LINEAR  },
};
static const int NPARTS = sizeof(parts) / sizeof(parts[0]);

static uint32_t dest_of(const Part &p, uint32_t i)
{
    switch (p.mode) {
    case LINEAR:  return p.base + i;
    case W32_B0:  return p.base + i * 4 + 0;
    case W32_B1:  return p.base + i * 4 + 1;
    case W32_B2:  return p.base + i * 4 + 2;
    case W32_B3:  return p.base + i * 4 + 3;
    case W32_W01: return p.base + (i >> 1) * 4 + 0 + (i & 1);
    case W32_W23: return p.base + (i >> 1) * 4 + 2 + (i & 1);
    case W24_B0:  return p.base + i * 3 + 0;
    case W24_B1:  return p.base + i * 3 + 1;
    case W24_B2:  return p.base + i * 3 + 2;
    case W24_W01: return p.base + (i >> 1) * 3 + (i & 1);
    }
    return 0;
}

// Source byte for part p at offset i. Low 8 bits of the offset plus a per-part
// salt, so a byte landing in the wrong part is caught as well as one landing at
// the wrong offset.
static uint8_t src_byte(int pi, uint32_t i)
{
    return (uint8_t)((i & 0xFF) ^ (uint8_t)(pi * 0x37 + 0x5A));
}

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);
    Vrom_loader *dut = new Vrom_loader;

    std::vector<uint8_t> mem(SDR_SIZE, 0xFF);
    std::vector<uint8_t> ref(SDR_SIZE, 0xFF);
    std::vector<uint8_t> written(SDR_SIZE, 0);

    // ---- reference model -------------------------------------------------
    uint64_t total = 0;
    for (int pi = 0; pi < NPARTS; pi++) {
        for (uint32_t i = 0; i < parts[pi].size; i++) {
            uint32_t d = dest_of(parts[pi], i);
            if (d >= SDR_SIZE) {
                printf("FAIL: reference dest 0x%X out of range (part %s, i=%u)\n",
                       d, parts[pi].name, i);
                return 1;
            }
            ref[d] = src_byte(pi, i);
            total++;
        }
    }
    printf("image: %llu bytes across %d parts\n", (unsigned long long)total, NPARTS);

    // ---- drive the DUT ---------------------------------------------------
    uint64_t tick = 0;
    auto clock = [&]() {
        dut->clk = 0; dut->eval();
        dut->clk = 1; dut->eval();
        tick++;
    };

    dut->reset = 1;
    dut->ioctl_download = 0;
    dut->ioctl_wr = 0;
    dut->ioctl_index = 0;
    dut->ioctl_dout = 0;
    dut->sdr_ack = 0;
    for (int i = 0; i < 8; i++) clock();
    dut->reset = 0;
    for (int i = 0; i < 4; i++) clock();

    if (dut->rom_ready) { printf("FAIL: rom_ready asserted before any download\n"); return 1; }

    dut->ioctl_download = 1;

    int      pi   = 0;
    uint32_t i    = 0;
    uint64_t sent = 0;
    uint8_t  last_req = dut->sdr_req;
    int      ack_delay = 0;
    bool     ack_pending = false;

    // Model the SDRAM: a write retires a few cycles after req toggles.
    auto service_sdram = [&]() -> bool {
        // capture a new request
        if (dut->sdr_req != last_req && !ack_pending) {
            last_req = dut->sdr_req;
            uint32_t a = dut->sdr_addr & ~1u;
            uint16_t d = dut->sdr_din;
            uint8_t  be = dut->sdr_be;
            if (dut->sdr_rnw) { printf("FAIL: loader issued a read\n"); return false; }
            if (a + 1 >= SDR_SIZE) { printf("FAIL: write outside SDRAM map: 0x%X\n", a); return false; }
            if (be == 0 || be == 3) { printf("FAIL: unexpected byte enables %d\n", be); return false; }
            if (be & 1) { mem[a + 0] = d & 0xFF;        written[a + 0] = 1; }
            if (be & 2) { mem[a + 1] = (d >> 8) & 0xFF; written[a + 1] = 1; }
            ack_pending = true;
            ack_delay   = 8;    // matches the controller's ~8 cycle turnaround
        }

        if (ack_pending) {
            if (ack_delay-- == 0) { dut->sdr_ack = last_req; ack_pending = false; }
        }
        return true;
    };

    while (sent < total || ack_pending) {
        if (!service_sdram()) return 1;

        // feed the next byte when the loader is ready for it
        dut->ioctl_wr = 0;
        if (!dut->ioctl_wait && sent < total) {
            dut->ioctl_dout = src_byte(pi, i);
            dut->ioctl_wr   = 1;
            sent++;
            if (++i == parts[pi].size) { i = 0; pi++; }
        }

        clock();

        if (tick > 400ull * 1000 * 1000) { printf("FAIL: timeout\n"); return 1; }
    }

    // Drain: the last write may still be in flight after the final byte is fed.
    dut->ioctl_wr = 0;
    for (int k = 0; k < 64; k++) { if (!service_sdram()) return 1; clock(); }
    dut->ioctl_download = 0;
    for (int k = 0; k < 64; k++) { if (!service_sdram()) return 1; clock(); }

    if (!dut->rom_ready) { printf("FAIL: rom_ready not asserted after download\n"); return 1; }

    // ---- compare ---------------------------------------------------------
    uint64_t bad = 0, nwritten = 0;
    uint32_t first_bad = 0;
    for (uint32_t a = 0; a < SDR_SIZE; a++) {
        if (written[a]) nwritten++;
        if (mem[a] != ref[a]) { if (!bad) first_bad = a; bad++; }
    }

    printf("cycles: %llu, bytes written: %llu\n",
           (unsigned long long)tick, (unsigned long long)nwritten);

    if (nwritten != total) {
        printf("FAIL: %llu bytes written, expected %llu\n",
               (unsigned long long)nwritten, (unsigned long long)total);
        return 1;
    }
    if (bad) {
        printf("FAIL: %llu bytes differ, first at 0x%X (got %02X want %02X)\n",
               (unsigned long long)bad, first_bad, mem[first_bad], ref[first_bad]);
        return 1;
    }

    printf("PASS: SDRAM image matches the MAME region layout exactly\n");
    delete dut;
    return 0;
}
