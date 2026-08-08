//============================================================================
//  SlopperPI - test the ROM integrity checker
//
//  spi_romcheck is going to be the thing that tells us whether the hardware's
//  ioctl download worked, so it had better be right itself. Feeds it the real
//  reference image and expects all four regions to pass, then corrupts a single
//  byte in each region in turn and expects exactly that region to fail.
//
//  usage: Vspi_romcheck <sdram.bin>
//============================================================================

#include "Vspi_romcheck.h"
#include "verilated.h"

#include <cstdio>
#include <cstdint>
#include <vector>

static const uint32_t SDR_SIZE = 0x1680000;

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);
    if (argc < 2) { printf("usage: %s <sdram.bin>\n", argv[0]); return 2; }

    std::vector<uint8_t> mem(SDR_SIZE, 0);
    FILE *f = fopen(argv[1], "rb");
    if (!f) { printf("FAIL: cannot open %s\n", argv[1]); return 2; }
    if (fread(mem.data(), 1, SDR_SIZE, f) != SDR_SIZE) { printf("FAIL: short image\n"); return 2; }
    fclose(f);

    // region -> a byte offset inside it, for the corruption cases
    const uint32_t poke[4] = { 0x000100, 0x0240100, 0x0480100, 0x0A80100 };
    const char *name[4] = { "PRG", "CHARS", "TILES", "SPRITES" };

    int failures = 0;

    for (int trial = 0; trial < 5; trial++) {
        std::vector<uint8_t> img = mem;
        int expect = 0xF;
        if (trial > 0) {
            img[poke[trial-1]] ^= 0x01;
            expect = 0xF & ~(1 << (trial-1));
        }

        Vspi_romcheck *dut = new Vspi_romcheck;
        dut->reset = 1; dut->start = 0; dut->sdr_ack = 0; dut->sdr_dout = 0;
        auto tick = [&]() { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); };
        for (int i = 0; i < 4; i++) tick();
        dut->reset = 0;
        dut->start = 1;

        uint8_t last_req = dut->sdr_req;
        uint64_t guard = 0;
        while (!dut->done) {
            if (dut->sdr_req != last_req) {
                last_req = dut->sdr_req;
                uint64_t w = 0;
                uint32_t a = dut->sdr_addr & ~7u;
                for (int b = 7; b >= 0; b--)
                    w = (w << 8) | (a + b < SDR_SIZE ? img[a + b] : 0);
                dut->sdr_dout = w;
                dut->sdr_ack = last_req;
            }
            tick();
            if (++guard > 40000000ull) { printf("FAIL: timeout\n"); return 1; }
        }

        const char *what = trial ? name[trial-1] : "clean image";
        if (dut->ok != expect) {
            printf("FAIL: %-12s -> ok=%X, expected %X\n", what, dut->ok, expect);
            failures++;
        } else {
            printf("  ok: %-12s -> ok=%X\n", what, dut->ok);
        }
        delete dut;
    }

    if (failures) { printf("\n%d case(s) failed\n", failures); return 1; }
    printf("\nPASS: the checker accepts the reference image and localises a single\n"
           "      flipped bit to the right region\n");
    return 0;
}
