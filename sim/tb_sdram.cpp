//============================================================================
//  SlopperPI - ROM download round-trip test
//
//  Streams the real concatenated ROM image through rom_loader into the real
//  SDRAM controller and a behavioural SDRAM chip, then reads every 64-bit word
//  back out through channel 1 and compares against the reference image built
//  by tools/build_sdram_image.py.
//
//  This is the path that runs on hardware before the 386 executes anything,
//  and until now nothing in sim/ covered it.
//
//  ---------------------------------------------------------------------------
//  BROKEN, 2026-08-17. IT DOES NOT PASS ON UNMODIFIED RTL.
//  ---------------------------------------------------------------------------
//  It had stopped BUILDING -- eighteen pins sdram.sv and rom_loader grew since
//  it was last touched, plus set_id still 2 bits against 3 (the same rot that
//  killed tb_ymf_top and tb_boot_top, PLAN.md 21.6, 22.3). Those are fixed and
//  it builds again, but it now reports 15,906,965 of 23,592,960 bytes differing
//  with every readback coming back 0xFF, on RTL nobody has changed.
//
//  What is known: the writes happen (23,396,352 write commands, exactly the
//  download) and the reads happen (2,949,120, exactly the 64-bit readback), so
//  the two sides disagree about DATA, not about whether they ran. Candidates,
//  in the order worth trying: sdram_model.sv's CAS pipeline against sdram.sv's
//  dq_reg timing; the model being ONE 32 MB chip where the design drives two
//  across 64 MB; and SDR_SIZE below.
//
//  THIS MATTERS MORE THAN IT LOOKS. It is the only test that would catch
//  sdram.sv corrupting data, which is the failure that cost PLAN.md 19.11-19.18
//  six instruments and five builds to find -- and it was a weak SDRAM module in
//  the end, not the RTL. Until this passes, changes to sdram.sv rest on
//  inspection alone, and 26.4's arbitration fix is blocked behind it.
//
//  usage: Vtb_sdram_top <sdram.bin> [<rom_concat.bin>]
//
//  Both files are required: the concatenated part image is what MiSTer streams
//  over ioctl, and the reference is what must end up in SDRAM afterwards.
//  tools/build_sdram_image.py --concat writes the former.
//============================================================================

#include "Vtb_sdram_top.h"
#include "verilated.h"

#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>

// 22.5 MB, and STALE: the map is 43 MB now (spi_defs.vh SDR_END). It is left
// alone rather than raised because sim/sdram_model.sv is a single 32 MB chip and
// the design addresses 64 MB across two, so raising this reads past the model.
// Sizing both to the real map is part of repairing this testbench -- see the
// note at the top of the file.
static const uint32_t SDR_SIZE = 0x1680000;

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);
    if (argc < 3) {
        printf("usage: %s <reference sdram.bin> <concatenated rom image>\n", argv[0]);
        return 2;
    }

    std::vector<uint8_t> ref(SDR_SIZE, 0);
    {
        FILE *f = fopen(argv[1], "rb");
        if (!f) { printf("FAIL: cannot open %s\n", argv[1]); return 2; }
        fread(ref.data(), 1, SDR_SIZE, f);
        fclose(f);
    }

    std::vector<uint8_t> src;
    {
        FILE *f = fopen(argv[2], "rb");
        if (!f) { printf("FAIL: cannot open %s\n", argv[2]); return 2; }
        fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
        src.resize(n);
        fread(src.data(), 1, n, f);
        fclose(f);
    }
    printf("reference %u bytes, source image %zu bytes\n", SDR_SIZE, src.size());

    Vtb_sdram_top *dut = new Vtb_sdram_top;

    auto tick = [&]() {
        dut->clk = 0; dut->eval();
        dut->clk = 1; dut->eval();
    };

    dut->init = 1;
    dut->ioctl_download = 0;
    dut->ioctl_wr = 0;
    dut->ioctl_dout = 0;
    dut->rd_req = 0;
    dut->rd_addr = 0;
    for (int i = 0; i < 16; i++) tick();
    dut->init = 0;

    // The controller needs its power-up sequence (about 12100 cycles) before it
    // will accept anything.
    for (int i = 0; i < 20000; i++) tick();

    // ---- download --------------------------------------------------------
    dut->ioctl_download = 1;
    size_t sent = 0;
    uint64_t cycles = 0;
    while (sent < src.size()) {
        dut->ioctl_wr = 0;
        if (!dut->ioctl_wait) {
            dut->ioctl_dout = src[sent++];
            dut->ioctl_wr = 1;
        }
        tick();
        if (++cycles > 2000ull * 1000 * 1000) { printf("FAIL: download timeout\n"); return 1; }
    }
    dut->ioctl_wr = 0;
    for (int i = 0; i < 256; i++) tick();
    dut->ioctl_download = 0;
    for (int i = 0; i < 256; i++) tick();

    if (!dut->rom_ready) { printf("FAIL: rom_ready never asserted\n"); return 1; }
    printf("download finished in %llu cycles\n", (unsigned long long)cycles);
    printf("chip saw: %u clocks, %u ACTIVE, %u READ, %u WRITE\n",
           dut->n_clk, dut->n_act, dut->n_rd, dut->n_wr);

    // ---- read everything back -------------------------------------------
    uint64_t bad = 0, checked = 0;
    uint32_t first_bad = 0;
    // Toggle handshake: flip rd_req, wait for rd_ack to match.
    uint8_t req = dut->rd_req;
    uint32_t limit = (argc > 3) ? (uint32_t)strtoul(argv[3], nullptr, 0) : SDR_SIZE;
    for (uint32_t a = 0; a < limit; a += 8) {
        dut->rd_addr = a;
        req = !req;
        dut->rd_req = req;

        uint64_t guard = 0;
        do {
            tick();
            if (++guard > 10000) {
                printf("FAIL: no ack for address 0x%X after %llu cycles\n",
                       a, (unsigned long long)guard);
                return 1;
            }
        } while (dut->rd_ack != req);

        uint64_t got = dut->rd_dout;
        for (int byte = 0; byte < 8; byte++) {
            uint8_t g = (got >> (byte * 8)) & 0xFF;
            uint8_t w = ref[a + byte];
            checked++;
            if (g != w) {
                if (!bad) first_bad = a + byte;
                if (bad < 8)
                    printf("  diff @0x%07X got %02X want %02X   (word %016llX)\n",
                           a + byte, g, w, (unsigned long long)got);
                bad++;
            }
        }
        if ((a & 0xFFFFF) == 0) { printf("  ...0x%07X\r", a); fflush(stdout); }
    }

    printf("\nchip saw after readback: %u ACTIVE, %u READ, %u WRITE\n",
           dut->n_act, dut->n_rd, dut->n_wr);
    printf("checked %llu bytes, %llu differ\n",
           (unsigned long long)checked, (unsigned long long)bad);
    if (bad) {
        printf("FAIL: first difference at 0x%X (want %02X)\n",
               first_bad, ref[first_bad]);
        return 1;
    }
    printf("PASS: the download round-trips through the real controller exactly\n");
    delete dut;
    return 0;
}
