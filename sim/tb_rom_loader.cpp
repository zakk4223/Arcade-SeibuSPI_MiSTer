//============================================================================
//  SlopperPI - testbench for rom_loader
//
//  CAUTION: this test only proves the RTL agrees with the model below. It does
//  not prove either is right -- the W24_W01 byte order was wrong in both for a
//  while, and only fell out when tools/build_sdram_image.py's output was
//  compared against MAME's own ROM regions. Keep dest_of() here in step with
//  dest_of() in that script, which is the one checked against MAME.
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

// MAME's own sprite_reorder(), copied out by tools/gen_ref_c.py. The SPR_R10
// scatter mode below is checked against it rather than against a restatement
// of it -- that is the whole point of having it here.
#include "spi_ref.h"

// ---------------------------------------------------------------------------
// SDRAM byte map (must match rtl/spi_defs.vh)
// ---------------------------------------------------------------------------
static const uint32_t PRG_BASE     = 0x0000000;
static const uint32_t Z80_BASE     = 0x0200000;
static const uint32_t CHARS_BASE   = 0x0240000;
static const uint32_t PCM_BASE     = 0x0280000;
static const uint32_t SND01_BASE   = 0x0480000;
static const uint32_t TILES_BASE   = 0x0500000;
static const uint32_t SPRITES_BASE = 0x1100000;
static const uint32_t SDR_SIZE     = 0x2900000;

enum Mode { LINEAR, W32_B0, W32_B1, W32_B2, W32_B3, W32_W01, W32_W23,
            W24_B0, W24_B1, W24_B2, W24_W01, SPR_ILV, SPR_ILV_R };

struct Part { const char *name; uint32_t base; uint32_t size; Mode mode; };

// Must match the part tables in rtl/rom_loader.sv and the <part> order in the
// MRAs. tools/check_mra.py checks those against MAME; this checks that the
// loader's SCATTER actually puts every byte where the table says.
static const Part parts_sxx2e[] = {
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
    { "gun_dogs_obj-1.u0322", SPRITES_BASE + 0,          0x400000, SPR_ILV },
    { "gun_dogs_obj-2.u0324", SPRITES_BASE + 2,          0x400000, SPR_ILV },
    { "gun_dogs_obj-3.u0323", SPRITES_BASE + 4,          0x400000, SPR_ILV },
    { "raiden-f_pcm2.u0975",  PCM_BASE,                  0x200000, LINEAR  },
};

// rdft, SPI cartridge, pre-flashed. Four byte lanes for the program and three
// for the text layer instead of SXX2E's word+byte pairs, which is what makes
// W32_B2/W32_B3/W24_B0/W24_B1 reachable at all -- before this set they were
// implemented but dead, so this is their first coverage. No Z80 part: that
// region is RAM the 386 fills through port 0x688.
static const Part parts_sxx2c[] = {
    { "raiden-fi_prg0_121196.u0211", PRG_BASE,                0x080000, W32_B0  },
    { "raiden-fi_prg1_121196.u0212", PRG_BASE,                0x080000, W32_B1  },
    { "raiden-fi_prg2_121196.u0210", PRG_BASE,                0x080000, W32_B2  },
    { "raiden-fi_prg3_121196.u029",  PRG_BASE,                0x080000, W32_B3  },
    { "seibu_5.u0423",               CHARS_BASE,              0x010000, W24_B0  },
    { "seibu_6.u0424",               CHARS_BASE,              0x010000, W24_B1  },
    { "seibu_7.u048",                CHARS_BASE,              0x010000, W24_B2  },
    { "gun_dogs_bg1-d.u0415",        TILES_BASE,              0x200000, W24_W01 },
    { "gun_dogs_bg1-p.u0410",        TILES_BASE,              0x100000, W24_B2  },
    { "gun_dogs_bg2-d.u0424",        TILES_BASE + 0x300000,   0x200000, W24_W01 },
    { "gun_dogs_bg2-p.u049",         TILES_BASE + 0x300000,   0x100000, W24_B2  },
    { "gun_dogs_obj-1.u0322",        SPRITES_BASE + 0,        0x400000, SPR_ILV },
    { "gun_dogs_obj-2.u0324",        SPRITES_BASE + 2,        0x400000, SPR_ILV },
    { "gun_dogs_obj-3.u0323",        SPRITES_BASE + 4,        0x400000, SPR_ILV },
    { "pre-programmed flash image",  PCM_BASE,                0x200000, LINEAR  },
};

// rdft2, SPI cartridge, sample flash DECODED rather than concatenated. Read off
// MAME's ROM_START(rdft2): 12 MB of tiles in two 6 MB groups, text lanes in the
// order 1/0/2, and 18 MB of sprites as three 6 MB plane-pair chunks -- which are
// contiguous at that stride, so all six ROMs are one LINEAR part. Part 15 is the
// compressed sample tail and its size is the COMPRESSED length; part 16 is the
// Z80 program, which is the other half of the same file.
static const Part parts_rdft2[] = {
    { "prg0.tun",                    PRG_BASE,                0x080000,  W32_B0  },
    { "prg1.bin",                    PRG_BASE,                0x080000,  W32_B1  },
    { "prg2.bin",                    PRG_BASE,                0x080000,  W32_B2  },
    { "prg3.bin",                    PRG_BASE,                0x080000,  W32_B3  },
    { "fix0.u0524",                  CHARS_BASE,              0x010000,  W24_B1  },
    { "fix1.u0518",                  CHARS_BASE,              0x010000,  W24_B0  },
    { "fixp.u0514",                  CHARS_BASE,              0x010000,  W24_B2  },
    { "bg-1d.u0535",                 TILES_BASE,              0x400000,  W24_W01 },
    { "bg-1p.u0537",                 TILES_BASE,              0x200000,  W24_B2  },
    { "bg-2d.u0536",                 TILES_BASE + 0x600000,   0x400000,  W24_W01 },
    { "bg-2p.u0538",                 TILES_BASE + 0x600000,   0x200000,  W24_B2  },
    { "sprites chunk 0",             SPRITES_BASE + 0,        0x600000,  SPR_ILV_R },
    { "sprites chunk 1",             SPRITES_BASE + 2,        0x600000,  SPR_ILV_R },
    { "sprites chunk 2",             SPRITES_BASE + 4,        0x600000,  SPR_ILV_R },
    { "flash head: stamp + pcm",     PCM_BASE,                0x17C247,  LINEAR  },
    { "flash tail: sound1, packed",  PCM_BASE + 0x17C247,     0x04C665,  LINEAR  },
    // A second slice of sound1.u0222, at 0x60000: rdft2's Z80 program, which
    // the 386 reads through the sound01 window. Packed one byte per dword, so
    // the loader just copies it -- the unpacking is spi_cpu.sv's job.
    { "sound1.u0222[0x60000..]",     SND01_BASE,              0x020000,  LINEAR  },
};

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
    case W24_W01: return p.base + (i >> 1) * 3 + (1 - (i & 1));
    // Sprite interleave: tile*192 + row*12 + half*6 + byte, so the three
    // plane-pair chunks' words alternate and a 16-pixel row is contiguous.
    // SPR_ILV_R additionally folds in MAME's sprite_reorder(), which rotates
    // the word index inside each 64-byte group.
    case SPR_ILV_R: i = (i & ~0x3Fu) | ((i & 0x1Eu) << 1)
                                     | ((i & 0x20u) >> 4) | (i & 1u);
                    /* fall through */
    case SPR_ILV:   return p.base + (i >> 6) * 192 + ((i >> 2) & 15) * 12
                                  + ((i >> 1) & 1) * 6 + (i & 1);
    }
    return 0;
}

// Prove that formula IS sprite_reorder, against MAME's copy, before trusting it
// for 18 MB. Feeds a 64-byte group of distinct values through both.
static int check_spr_r10()
{
    uint8_t want[64], got[64];
    for (int i = 0; i < 64; i++) want[i] = (uint8_t)i;
    sprite_reorder(want);

    // SPR_ILV_R is sprite_reorder composed with the interleave, so undo the
    // interleave to isolate the reorder and compare that against MAME's copy.
    Part pr = { "reorder", 0, 64, SPR_ILV_R };
    Part pi = { "interleave", 0, 64, SPR_ILV };
    for (int i = 0; i < 64; i++) {
        // dest_of(SPR_ILV, j) is a bijection on a 64-byte group, so inverting
        // it turns the composed mapping back into the plain permutation.
        uint32_t d = dest_of(pr, (uint32_t)i);
        int j = 0;
        while (j < 64 && dest_of(pi, (uint32_t)j) != d) j++;
        if (j == 64) { printf("FAIL: SPR_ILV is not a bijection on a group\n"); return 1; }
        got[j] = (uint8_t)i;
    }
    for (int i = 0; i < 64; i++) {
        if (got[i] != want[i]) {
            printf("FAIL: SPR_ILV_R byte %d -> %d, MAME's sprite_reorder says %d\n",
                   i, got[i], want[i]);
            return 1;
        }
    }

    // And the interleave itself: one tile from each of three chunks must fill
    // exactly 192 contiguous bytes with no collisions, and a 16-pixel row's
    // twelve bytes must never span three 8-byte reads -- which is the entire
    // point of the layout.
    int slot[192];
    for (int i = 0; i < 192; i++) slot[i] = -1;
    for (int k = 0; k < 3; k++) {
        Part pk = { "chunk", (uint32_t)(2 * k), 64, SPR_ILV };
        for (int i = 0; i < 64; i++) {
            uint32_t d = dest_of(pk, (uint32_t)i);
            if (d >= 192 || slot[d] >= 0) {
                printf("FAIL: interleave collision at %u (chunk %d byte %d)\n", d, k, i);
                return 1;
            }
            slot[d] = k;
        }
    }
    for (int r = 0; r < 16; r++) {
        uint32_t start = (uint32_t)r * 12;
        if (((start + 11) >> 3) - (start >> 3) + 1 > 2) {
            printf("FAIL: row %d spans more than two 8-byte reads\n", r);
            return 1;
        }
    }
    printf("PASS: SPR_ILV_R is MAME's sprite_reorder, and the interleave packs\n"
           "      three chunks into 192 bytes with every row inside two reads\n");
    return 0;
}

// Source byte for part p at offset i. Low 8 bits of the offset plus a per-part
// salt, so a byte landing in the wrong part is caught as well as one landing at
// the wrong offset.
static uint8_t src_byte(int pi, uint32_t i)
{
    return (uint8_t)((i & 0xFF) ^ (uint8_t)(pi * 0x37 + 0x5A));
}

// ---------------------------------------------------------------------------
// A synthetic CODEC_BPE_DPCM stream for the loader test.
//
// The codec itself is checked against the real rdft2 data in tb_rom_decode.cpp;
// what needs checking HERE is the loader plumbing around it -- that the part
// ends on bytes IN while the scatter advances on bytes OUT, that the boundary
// into the next part still lands right, and that a stalled decoder does not
// drop an ioctl byte. So the stream is built to make the expected output
// obvious without a second decoder model to disagree with:
//
//   every block defines exactly one pair, left[0x80] = right[0x80] = 0x00, so
//   a data byte of 0x80 expands to two ZERO deltas -- it emits the running
//   accumulator twice and leaves it alone. Every other byte is a literal delta.
//
// Expansion therefore comes out at 1 + (fraction of 0x80 bytes), and the
// expected output is four lines of C rather than a BPE implementation.
static void make_bpe_part(uint32_t in_len, std::vector<uint8_t> &stream,
                          std::vector<uint8_t> &expect)
{
    const uint32_t NBLOCKS  = 512;
    const uint32_t OVERHEAD = 6;          // 4 table bytes + 2 size bytes
    uint32_t budget = in_len - 2 - NBLOCKS * OVERHEAD;
    uint32_t base   = budget / NBLOCKS;
    uint32_t extra  = budget % NBLOCKS;

    stream.push_back(NBLOCKS & 0xFF);          // block count is LITTLE-endian
    stream.push_back((NBLOCKS >> 8) & 0xFF);

    uint8_t  acc  = 0;
    uint32_t seed = 0x1234567;
    for (uint32_t b = 0; b < NBLOCKS; b++) {
        uint32_t n = base + (b < extra ? 1 : 0);

        stream.push_back(0xFF);   // skip 255-127 = 128 entries, then one entry
        stream.push_back(0x00);   // left[128]  = 0x00, != 128 so a right follows
        stream.push_back(0x00);   // right[128] = 0x00
        stream.push_back(0xFE);   // skip 254-127 = 127: index hits 256, done

        stream.push_back((n >> 8) & 0xFF);     // block size is BIG-endian
        stream.push_back(n & 0xFF);

        for (uint32_t k = 0; k < n; k++) {
            seed = seed * 1103515245u + 12345u;
            uint8_t d = ((seed >> 16) & 7) == 0 ? 0x80 : (uint8_t)(seed >> 8);
            stream.push_back(d);
            if (d == 0x80) { expect.push_back(acc); expect.push_back(acc); }
            else           { acc = (uint8_t)(acc + d); expect.push_back(acc); }
        }
    }
}

static int run_set(const Part *parts, int NPARTS, int set_id, const char *label,
                   int codec_part = -1)
{
    printf("--- %s ---\n", label);
    Vrom_loader *dut = new Vrom_loader;
    dut->set_id     = set_id;
    for (int i = 0; i < 4; i++) dut->part_codec[i] = 0;   // all straight copies

    std::vector<uint8_t> cstream, cexpect;
    if (codec_part >= 0) {
        if (parts[codec_part].mode != LINEAR) {
            printf("FAIL: the codec part must be LINEAR\n");
            return 1;
        }
        make_bpe_part(parts[codec_part].size, cstream, cexpect);
        if (cstream.size() != parts[codec_part].size) {
            printf("FAIL: synthetic stream is %zu bytes, part is %u\n",
                   cstream.size(), parts[codec_part].size);
            return 1;
        }
        dut->part_codec[codec_part / 8] = 1u << ((codec_part % 8) * 4);  // CODEC_BPE_DPCM
        printf("part %d decoded: %u in -> %zu out (%.3fx)\n", codec_part,
               parts[codec_part].size, cexpect.size(),
               (double)cexpect.size() / (double)parts[codec_part].size);
    }

    std::vector<uint8_t> mem(SDR_SIZE, 0xFF);
    std::vector<uint8_t> ref(SDR_SIZE, 0xFF);
    std::vector<uint8_t> written(SDR_SIZE, 0);

    // ---- reference model -------------------------------------------------
    // `total` is bytes fed in, `total_out` bytes expected in SDRAM. They differ
    // by exactly the decoded part's expansion.
    uint64_t total = 0, total_out = 0;
    for (int pi = 0; pi < NPARTS; pi++) {
        if (pi == codec_part) {
            for (size_t j = 0; j < cexpect.size(); j++) ref[parts[pi].base + j] = cexpect[j];
            if (parts[pi].base + cexpect.size() > SDR_SIZE) {
                printf("FAIL: decoded part runs off the end of SDRAM\n");
                return 1;
            }
            total     += parts[pi].size;
            total_out += cexpect.size();
            continue;
        }
        for (uint32_t i = 0; i < parts[pi].size; i++) {
            uint32_t d = dest_of(parts[pi], i);
            if (d >= SDR_SIZE) {
                printf("FAIL: reference dest 0x%X out of range (part %s, i=%u)\n",
                       d, parts[pi].name, i);
                return 1;
            }
            ref[d] = src_byte(pi, i);
            total++;
            total_out++;
        }
    }
    printf("image: %llu bytes in, %llu bytes out, across %d parts\n",
           (unsigned long long)total, (unsigned long long)total_out, NPARTS);

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
            dut->ioctl_dout = (pi == codec_part) ? cstream[i] : src_byte(pi, i);
            dut->ioctl_wr   = 1;
            sent++;
            if (++i == parts[pi].size) { i = 0; pi++; }
        }

        clock();

        if (tick > 400ull * 1000 * 1000) { printf("FAIL: timeout\n"); return 1; }
    }

    // Drain. A decoded part is still expanding after the last byte arrives, so
    // this waits rather than counting a fixed number of cycles.
    dut->ioctl_wr = 0;
    for (int k = 0; k < 4096; k++) { if (!service_sdram()) return 1; clock(); }
    dut->ioctl_download = 0;
    for (int k = 0; k < 4096 && !dut->rom_ready; k++) {
        if (!service_sdram()) return 1;
        clock();
    }

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

    if (nwritten != total_out) {
        printf("FAIL: %llu bytes written, expected %llu\n",
               (unsigned long long)nwritten, (unsigned long long)total_out);
        return 1;
    }
    if (dut->bytes_in != (total & 0x3FFFFFF) || dut->bytes_out != (total_out & 0x3FFFFFF)) {
        printf("FAIL: telemetry says in=%u out=%u, expected in=%llu out=%llu\n",
               (unsigned)dut->bytes_in, (unsigned)dut->bytes_out,
               (unsigned long long)total, (unsigned long long)total_out);
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

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);
    if (check_spr_r10()) return 1;
    int rc = run_set(parts_sxx2e, (int)(sizeof(parts_sxx2e) / sizeof(parts_sxx2e[0])),
                     0, "rdfts (SXX2E)");
    if (rc) return rc;
    rc = run_set(parts_sxx2c, (int)(sizeof(parts_sxx2c) / sizeof(parts_sxx2c[0])),
                 1, "rdft pre-flashed (SXX2C)");
    if (rc) return rc;
    // The same set again with the sample part decoded, which is the shape
    // rdft2 needs: fourteen copied parts and one that expands.
    rc = run_set(parts_sxx2c, (int)(sizeof(parts_sxx2c) / sizeof(parts_sxx2c[0])),
                 1, "SXX2C with a CODEC_BPE_DPCM sample part", 14);
    if (rc) return rc;
    // rdft2 for real: the table the MRA drives, with part 15 decoded. The
    // stream is synthetic (tb_rom_decode.cpp is what checks the codec against
    // rdft2's actual data); what this checks is that 34 MB lands where MAME's
    // region layout says, across a 6 MB tile stride, a six-ROM sprite run and
    // a part whose output length is not its input length.
    rc = run_set(parts_rdft2, (int)(sizeof(parts_rdft2) / sizeof(parts_rdft2[0])),
                 2, "rdft2 (SXX2C, decoded sample flash)", 15);
    return rc;
}
