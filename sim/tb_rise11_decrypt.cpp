//============================================================================
//  SlopperPI - testbench for spi_rise11_decrypt
//
//  Drives the RTL over pseudo-random 48-bit inputs and compares against MAME's
//  own seibuspi_rise11_sprite_decrypt_rfjet(), copied verbatim into spi_ref.h
//  by tools/gen_ref_c.py. The RTL's constants come from a SEPARATE path --
//  tools/gen_rise11_tables.py parses the same function -- so agreement
//  validates the parser instead of being self-consistent. See PLAN.md section
//  12, where a reference implementing the same wrong rule as the RTL passed for
//  months.
//
//  TWO passes, and the second is the one that earns its keep.
//
//  Pass 1, MAME's order: feed word i with index i, reassemble, apply MAME's own
//  sprite_reorder, compare. That checks the arithmetic and checks that reorder
//  is NOT part of the decrypt unit -- if it were, this would double-apply.
//
//  Pass 2, the HARDWARE's order: the loader stores the encrypted bytes already
//  reordered (M_SPR_ILV_R), so what the fetch reads at post-reorder position o
//  is the raw word from pre-reorder position j, and the index the crypt needs is
//  j, not o. Pass 2 walks o, derives j the way spi_sprite.sv does -- inside a
//  32-word group, j = {o[0], o[4:1]} -- and checks the result against MAME's
//  final image at o. Getting that inverse wrong is invisible in pass 1 and
//  silently wrong on screen, because RISE11's plane210 sum takes the index as
//  an operand. It is the specific hazard this unit adds over RISE10.
//============================================================================

#include "Vspi_rise11_decrypt.h"
#include "verilated.h"

#include <cstdio>
#include <cstdint>
#include <vector>
#include "spi_ref.h"

// One 64-byte reorder group is 32 words per chunk; use several groups.
static const int WORDS = 32 * 64;          // 2048 words per chunk
static const int SIZE  = WORDS * 2;        // bytes per chunk

static uint32_t rnd_state = 0x2468ACE0u;
static uint32_t rnd()
{
    rnd_state ^= rnd_state << 13;
    rnd_state ^= rnd_state >> 17;
    rnd_state ^= rnd_state << 5;
    return rnd_state;
}

// Reassemble the RTL's eight pens into the six plane bytes MAME writes back.
// Bit p of the pen carries plane(5-p), the convention spi_spr_decrypt uses.
static void planes_from_pix(const uint8_t pix[8], uint8_t plane[6])
{
    for (int n = 0; n < 6; n++) plane[n] = 0;
    for (int j = 0; j < 8; j++)
        for (int n = 0; n < 6; n++)
            plane[n] |= (uint8_t)(((pix[j] >> (5 - n)) & 1) << j);
}

static void run_word(Vspi_rise11_decrypt *dut, const std::vector<uint8_t> &src,
                     int pos, uint32_t index, uint8_t plane[6])
{
    dut->y1 = (uint16_t)(src[0 * SIZE + 2 * pos] | (src[0 * SIZE + 2 * pos + 1] << 8));
    dut->y2 = (uint16_t)(src[1 * SIZE + 2 * pos] | (src[1 * SIZE + 2 * pos + 1] << 8));
    dut->y3 = (uint16_t)(src[2 * SIZE + 2 * pos] | (src[2 * SIZE + 2 * pos + 1] << 8));
    dut->i  = index;
    dut->eval();

    const uint8_t pix[8] = {
        (uint8_t)dut->pix0, (uint8_t)dut->pix1, (uint8_t)dut->pix2, (uint8_t)dut->pix3,
        (uint8_t)dut->pix4, (uint8_t)dut->pix5, (uint8_t)dut->pix6, (uint8_t)dut->pix7
    };
    planes_from_pix(pix, plane);
}

static void store(std::vector<uint8_t> &dst, int pos, const uint8_t plane[6])
{
    dst[0 * SIZE + 2 * pos]     = plane[5];
    dst[0 * SIZE + 2 * pos + 1] = plane[4];
    dst[1 * SIZE + 2 * pos]     = plane[3];
    dst[1 * SIZE + 2 * pos + 1] = plane[2];
    dst[2 * SIZE + 2 * pos]     = plane[1];
    dst[2 * SIZE + 2 * pos + 1] = plane[0];
}

static long compare(const char *what, const std::vector<uint8_t> &got,
                    const std::vector<uint8_t> &ref)
{
    long bad = 0;
    int shown = 0;
    for (size_t a = 0; a < got.size(); a++) {
        if (got[a] != ref[a]) {
            if (shown < 6) {
                printf("FAIL (%s): byte 0x%zX (chunk %zu word %zu): got %02X want %02X\n",
                       what, a, a / SIZE, (a % SIZE) / 2, got[a], ref[a]);
                shown++;
            }
            bad++;
        }
    }
    return bad;
}

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);
    Vspi_rise11_decrypt *dut = new Vspi_rise11_decrypt;

    // Three chunks laid out exactly as MAME expects: one contiguous buffer of
    // 3 * SIZE, chunk k starting at k * SIZE.
    std::vector<uint8_t> src(3 * SIZE);
    for (auto &b : src) b = (uint8_t)rnd();

    std::vector<uint8_t> ref = src;
    seibuspi_rise11_sprite_decrypt_rfjet(ref.data(), SIZE);

    // ---- pass 1: MAME's order ------------------------------------------
    std::vector<uint8_t> got(3 * SIZE);
    for (int i = 0; i < WORDS; i++) {
        uint8_t plane[6];
        run_word(dut, src, i, (uint32_t)i, plane);
        store(got, i, plane);
    }
    for (int i = 0; i < WORDS; i += 32) {
        sprite_reorder(&got[0 * SIZE + 2 * i]);
        sprite_reorder(&got[1 * SIZE + 2 * i]);
        sprite_reorder(&got[2 * SIZE + 2 * i]);
    }
    long bad1 = compare("MAME order", got, ref);

    // ---- pass 2: the hardware's order ----------------------------------
    // What the loader puts in SDRAM: the ENCRYPTED bytes, reordered.
    std::vector<uint8_t> sdram = src;
    for (int i = 0; i < WORDS; i += 32) {
        sprite_reorder(&sdram[0 * SIZE + 2 * i]);
        sprite_reorder(&sdram[1 * SIZE + 2 * i]);
        sprite_reorder(&sdram[2 * SIZE + 2 * i]);
    }

    std::vector<uint8_t> got2(3 * SIZE);
    for (int o = 0; o < WORDS; o++) {
        // Inverse of sprite_reorder inside the group, as a bit permutation:
        // reorder sends input word j to output {j[3:0], j[4]}, so the input
        // that landed at o is j = {o[0], o[4:1]}.
        const int base = o & ~31;
        const int og   = o & 31;
        const int j    = base + (((og & 1) << 4) | (og >> 1));
        uint8_t plane[6];
        run_word(dut, sdram, o, (uint32_t)j, plane);
        store(got2, o, plane);
    }
    long bad2 = compare("fetch order", got2, ref);

    // The two passes only differ because the index matters. If a bug made the
    // unit ignore `i`, pass 2 would agree with pass 1 for the wrong reason --
    // so check that the index really is load-bearing.
    uint8_t p_a[6], p_b[6];
    run_word(dut, src, 0, 0x000000, p_a);
    run_word(dut, src, 0, 0x000001, p_b);
    bool index_matters = false;
    for (int n = 0; n < 6; n++) if (p_a[n] != p_b[n]) index_matters = true;

    delete dut;

    if (bad1 || bad2 || !index_matters) {
        if (bad1) printf("FAIL: pass 1 (MAME order): %ld of %zu bytes differ\n",
                         bad1, got.size());
        if (bad2) printf("FAIL: pass 2 (fetch order): %ld of %zu bytes differ\n",
                         bad2, got2.size());
        if (!index_matters)
            printf("FAIL: the word index changed and the output did not -- "
                   "the `i` port is not connected to the plane210 sum\n");
        return 1;
    }
    printf("PASS: %d RISE11 words (%zu bytes) match MAME in MAME's order, and "
           "again in the fetch's order through the reorder inverse\n",
           WORDS, got.size());
    return 0;
}
