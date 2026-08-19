//============================================================================
//  SeibuSPI - testbench for spi_rise10_decrypt
//
//  Drives the RTL over pseudo-random 48-bit inputs and compares against MAME's
//  own seibuspi_rise10_sprite_decrypt(), copied verbatim into spi_ref.h by
//  tools/gen_ref_c.py. The RTL's constants come from a SEPARATE path --
//  tools/gen_rise10_tables.py parses the same function -- so agreement
//  validates the parser instead of being self-consistent. That distinction is
//  the whole point; see PLAN.md section 12, where a reference implementing the
//  same wrong rule as the RTL passed for months.
//
//  Two things are checked, not one:
//    * the arithmetic, per word, as pixels;
//    * that sprite_reorder is a pure word permutation and NOT part of the
//      decrypt unit -- the test reassembles the RTL's output into a ROM image
//      and applies MAME's own reorder to it, so if the split were wrong the
//      buffers would differ.
//============================================================================

#include "Vspi_rise10_decrypt.h"
#include "verilated.h"

#include <cstdio>
#include <cstdint>
#include <vector>
#include "spi_ref.h"

// One 64-byte reorder group is 32 words per chunk; use several groups.
static const int WORDS = 32 * 64;          // 2048 words per chunk
static const int SIZE  = WORDS * 2;        // bytes per chunk

static uint32_t rnd_state = 0x13579BDFu;
static uint32_t rnd()
{
    rnd_state ^= rnd_state << 13;
    rnd_state ^= rnd_state >> 17;
    rnd_state ^= rnd_state << 5;
    return rnd_state;
}

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);
    Vspi_rise10_decrypt *dut = new Vspi_rise10_decrypt;

    // Three chunks laid out exactly as MAME expects: one contiguous buffer of
    // 3 * SIZE, chunk k starting at k * SIZE.
    std::vector<uint8_t> src(3 * SIZE);
    for (auto &b : src) b = (uint8_t)rnd();

    std::vector<uint8_t> ref = src;
    seibuspi_rise10_sprite_decrypt(ref.data(), SIZE);

    // Run the RTL word by word and rebuild the image the same way MAME does.
    std::vector<uint8_t> got(3 * SIZE);
    long bad_pix = 0;
    int  shown = 0;

    for (int i = 0; i < WORDS; i++) {
        const uint16_t y1 = src[0 * SIZE + 2 * i] | (src[0 * SIZE + 2 * i + 1] << 8);
        const uint16_t y2 = src[1 * SIZE + 2 * i] | (src[1 * SIZE + 2 * i + 1] << 8);
        const uint16_t y3 = src[2 * SIZE + 2 * i] | (src[2 * SIZE + 2 * i + 1] << 8);

        dut->y1 = y1; dut->y2 = y2; dut->y3 = y3;
        dut->eval();

        const uint8_t pix[8] = {
            (uint8_t)dut->pix0, (uint8_t)dut->pix1, (uint8_t)dut->pix2, (uint8_t)dut->pix3,
            (uint8_t)dut->pix4, (uint8_t)dut->pix5, (uint8_t)dut->pix6, (uint8_t)dut->pix7
        };

        // Reassemble the six planes. Bit p of the pen carries plane(5-p), which
        // is the convention spi_spr_decrypt already uses.
        uint8_t plane[6] = {0, 0, 0, 0, 0, 0};
        for (int j = 0; j < 8; j++)
            for (int n = 0; n < 6; n++)
                plane[n] |= (uint8_t)(((pix[j] >> (5 - n)) & 1) << j);

        got[0 * SIZE + 2 * i]     = plane[5];
        got[0 * SIZE + 2 * i + 1] = plane[4];
        got[1 * SIZE + 2 * i]     = plane[3];
        got[1 * SIZE + 2 * i + 1] = plane[2];
        got[2 * SIZE + 2 * i]     = plane[1];
        got[2 * SIZE + 2 * i + 1] = plane[0];
    }

    // sprite_reorder belongs to the FETCH, not the decrypt unit, so the test
    // applies MAME's own copy of it here. If it were really part of the
    // arithmetic this would double-apply and the compare would fail.
    for (int i = 0; i < WORDS; i += 32) {
        sprite_reorder(&got[0 * SIZE + 2 * i]);
        sprite_reorder(&got[1 * SIZE + 2 * i]);
        sprite_reorder(&got[2 * SIZE + 2 * i]);
    }

    for (size_t a = 0; a < got.size(); a++) {
        if (got[a] != ref[a]) {
            if (shown < 6) {
                printf("FAIL: byte 0x%zX (chunk %zu word %zu): got %02X want %02X\n",
                       a, a / SIZE, (a % SIZE) / 2, got[a], ref[a]);
                shown++;
            }
            bad_pix++;
        }
    }

    delete dut;
    if (bad_pix) {
        printf("FAIL: %ld of %zu bytes differ\n", bad_pix, got.size());
        return 1;
    }
    printf("PASS: %d RISE10 words (%zu bytes) match MAME, including sprite_reorder\n",
           WORDS, got.size());
    return 0;
}
