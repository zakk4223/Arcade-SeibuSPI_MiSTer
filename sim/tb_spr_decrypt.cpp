//============================================================================
//  SeibuSPI - SEI252 sprite decrypt unit vs MAME's seibuspi_sprite_decrypt()
//
//  MAME's routine transforms a whole ROM in place, so we hand it a 3 x 2 MB
//  buffer of random data. That is large enough for the word index i to reach
//  0xFFFFF, which exercises the full addr[11:0] used by the key schedule.
//
//  The RTL emits pixels rather than plane bytes, so the check reconstructs the
//  six plane bytes from the pixel outputs. That also validates the pixel
//  mapping derived in spi_spr_decrypt.sv, not just the arithmetic.
//============================================================================

#include "Vspi_spr_decrypt.h"
#include "verilated.h"
#include "spi_ref.h"

#include <cstdio>
#include <cstdlib>
#include <vector>

static const int ROM_SIZE = 0x200000;    // per plane-pair chunk

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);
    Vspi_spr_decrypt *dut = new Vspi_spr_decrypt;

    std::vector<u8> raw(3 * ROM_SIZE);
    srand(0xC0FFEE);
    for (size_t i = 0; i < raw.size(); i++) raw[i] = (u8)rand();

    std::vector<u8> dec = raw;
    seibuspi_sprite_decrypt(dec.data(), ROM_SIZE);

    unsigned long checked = 0;

    // Walk every addr value 0..0xFFF explicitly, sampling several words inside
    // each, so all 256 key_table entries and all four addr[11:8] combinations
    // are covered rather than left to a stride pattern.
    for (int a = 0; a < 4096; a++)
    for (int k = 0; k < 16; k++) {
        int i = (a << 8) + k * 17;
        if (i >= ROM_SIZE / 2) continue;

        u16 y1 = raw[2 * i + 0 * ROM_SIZE] | (raw[2 * i + 0 * ROM_SIZE + 1] << 8);
        u16 y2 = raw[2 * i + 1 * ROM_SIZE] | (raw[2 * i + 1 * ROM_SIZE + 1] << 8);
        u16 y3 = raw[2 * i + 2 * ROM_SIZE] | (raw[2 * i + 2 * ROM_SIZE + 1] << 8);

        dut->y1   = y1;
        dut->y2   = y2;
        dut->y3   = y3;
        dut->addr = (i >> 8) & 0xFFF;
        dut->eval();

        const u8 pix[8] = {
            (u8)dut->pix0, (u8)dut->pix1, (u8)dut->pix2, (u8)dut->pix3,
            (u8)dut->pix4, (u8)dut->pix5, (u8)dut->pix6, (u8)dut->pix7
        };

        // Rebuild the six plane bytes. gfx plane p of pixel j lives in byte p
        // at bit j, and the decrypt stores MAME's plane5..plane0 into
        // chunk0.b0, chunk0.b1, chunk1.b0, chunk1.b1, chunk2.b0, chunk2.b1.
        u8 got[6] = { 0, 0, 0, 0, 0, 0 };
        for (int j = 0; j < 8; j++)
            for (int p = 0; p < 6; p++)
                got[p] |= (u8)(((pix[j] >> p) & 1) << j);

        const u8 want[6] = {
            dec[2 * i + 0 * ROM_SIZE + 0],   // MAME plane5
            dec[2 * i + 0 * ROM_SIZE + 1],   // MAME plane4
            dec[2 * i + 1 * ROM_SIZE + 0],   // MAME plane3
            dec[2 * i + 1 * ROM_SIZE + 1],   // MAME plane2
            dec[2 * i + 2 * ROM_SIZE + 0],   // MAME plane1
            dec[2 * i + 2 * ROM_SIZE + 1],   // MAME plane0
        };

        for (int p = 0; p < 6; p++) {
            if (got[p] != want[p]) {
                printf("FAIL i=%d addr=%03X y=%04X,%04X,%04X plane%d: got %02X want %02X\n",
                       i, (i >> 8) & 0xFFF, y1, y2, y3, p, got[p], want[p]);
                printf("      got  planes:");
                for (int q = 0; q < 6; q++) printf(" %02X", got[q]);
                printf("\n      want planes:");
                for (int q = 0; q < 6; q++) printf(" %02X", want[q]);
                printf("\n");
                return 1;
            }
        }
        checked++;
    }

    printf("PASS: %lu sprite decrypt vectors match MAME\n", checked);
    delete dut;
    return 0;
}
