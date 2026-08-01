//============================================================================
//  SlopperPI - tile/char decrypt unit vs MAME's decrypt_tile()
//============================================================================

#include "Vspi_tile_decrypt.h"
#include "verilated.h"
#include "spi_ref.h"

#include <cstdio>
#include <cstdlib>

struct KeySet { const char *name; u32 k1, k2, k3; };

static const KeySet keysets[] = {
    { "SEI252 (rdft/rdfts/senkyu/viprp1)", 0x5A3845, 0x77CF5B, 0x1378DF },
    { "rdft2",                             0x823146, 0x4DE2F8, 0x157ADC },
    { "rfjet",                             0xAEA754, 0xFE8530, 0xCCB666 },
};

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);
    Vspi_tile_decrypt *dut = new Vspi_tile_decrypt;

    srand(0x5E1B0123);
    unsigned long checked = 0;

    for (const KeySet &ks : keysets) {
        dut->key1 = ks.k1;
        dut->key2 = ks.k2;
        dut->key3 = ks.k3;

        for (int tileno = 0; tileno < 4096; tileno++) {
            // A few random data words per tile number, plus the corner cases.
            for (int t = 0; t < 6; t++) {
                u32 val;
                switch (t) {
                case 0:  val = 0x000000; break;
                case 1:  val = 0xFFFFFF; break;
                case 2:  val = 0x800001; break;
                default: val = ((u32)rand() ^ ((u32)rand() << 11)) & 0xFFFFFF;
                }

                dut->din    = val;
                dut->tileno = tileno;
                dut->eval();

                u32 want = decrypt_tile(val, tileno, ks.k1, ks.k2, ks.k3) & 0xFFFFFF;
                u32 got  = dut->dout & 0xFFFFFF;

                if (got != want) {
                    printf("FAIL [%s] tileno=%d val=%06X: got %06X want %06X\n",
                           ks.name, tileno, val, got, want);
                    return 1;
                }
                checked++;
            }
        }
        printf("  %-36s ok\n", ks.name);
    }

    printf("PASS: %lu tile decrypt vectors match MAME\n", checked);
    delete dut;
    return 0;
}
