//============================================================================
//  SlopperPI - testbench for spi_rom_decode
//
//  Two tests, and the difference between them matters.
//
//  1. Hand vectors. Streams written by hand from the 386 disassembly at
//     0x2A1D20, with the expected output worked out by hand as well, so they
//     check the RTL against the SPECIFICATION rather than against another
//     implementation. They cover the awkward corners: the skip code, an entry
//     whose left byte equals its index (unused, no right byte follows), the
//     little-endian block count against the big-endian block size, the stack
//     walk, and DPCM wrapping across a block boundary.
//
//  2. The real thing. rdft2's sound1.u0222 through the decoder, compared
//     against the output of tools/build_soundflash.py, which is itself verified
//     bit-for-bit against the flash image MAME's own hardware model produces.
//     That is the chain that makes this meaningful: RTL == script == MAME.
//     Needs the ROM, so it only runs when the Makefile can find one.
//
//  Backpressure is applied on the output in an irregular pattern rather than
//  never or always, because a decoder that only works when the sink is always
//  ready is a decoder that fails on real SDRAM.
//============================================================================

#include "Vspi_rom_decode.h"
#include "verilated.h"

#include <cstdio>
#include <cstdint>
#include <cstring>
#include <vector>

static const uint8_t CODEC_RAW      = 0;
static const uint8_t CODEC_BPE_DPCM = 1;

// Runs `in` through the decoder and returns what came out. `stall` seeds the
// output backpressure pattern; 0 means never stall.
static std::vector<uint8_t> run(Vspi_rom_decode *dut, uint8_t codec,
                                const std::vector<uint8_t> &in, unsigned stall,
                                uint64_t *cycles_out = nullptr,
                                size_t *consumed_out = nullptr)
{
    std::vector<uint8_t> out;
    uint64_t tick = 0, idle_run = 0;
    size_t fed = 0;
    unsigned lfsr = stall ? stall : 1;

    auto clock = [&]() {
        dut->clk = 0; dut->eval();
        dut->clk = 1; dut->eval();
        tick++;
    };

    dut->codec = codec;
    dut->reset = 1; dut->start = 0;
    dut->in_valid = 0; dut->in_data = 0; dut->out_ready = 0;
    for (int i = 0; i < 4; i++) clock();
    dut->reset = 0;
    dut->start = 1; clock();
    dut->start = 0;

    while (true) {
        // output side, with a lumpy ready pattern
        lfsr = (lfsr << 1) ^ ((lfsr >> 7) & 1 ? 0x1D : 0);
        dut->out_ready = stall ? ((lfsr & 3) != 0) : 1;

        dut->in_valid = (fed < in.size());
        dut->in_data  = dut->in_valid ? in[fed] : 0;

        // in_ready is combinational in out_ready, so settle before sampling
        // either handshake -- otherwise this reads last cycle's answer.
        dut->eval();

        bool took  = dut->in_valid && dut->in_ready;
        bool gave  = dut->out_valid && dut->out_ready;
        if (gave) out.push_back(dut->out_data);

        clock();
        if (took) fed++;

        idle_run = (took || gave) ? 0 : idle_run + 1;
        // Nothing moving for a while: the stream is spent. Note the decoder
        // stops asking for input at the END OF ITS OWN STREAM, which is not
        // the end of the file -- rdft2's codec reads 312,933 of sound1.u0222's
        // 524,288 bytes and the rest is the Z80 program. So this cannot wait
        // for `fed == in.size()`.
        if (idle_run > 1024) break;
        if (tick > 200ull * 1000 * 1000) { printf("FAIL: timeout\n"); break; }
    }

    if (cycles_out)   *cycles_out = tick;
    if (consumed_out) *consumed_out = fed;
    return out;
}

static int check(const char *what, const std::vector<uint8_t> &got,
                 const std::vector<uint8_t> &want)
{
    if (got.size() != want.size()) {
        printf("FAIL: %s produced %zu bytes, expected %zu\n", what, got.size(), want.size());
        return 1;
    }
    for (size_t i = 0; i < got.size(); i++) {
        if (got[i] != want[i]) {
            printf("FAIL: %s differs at %zu: got %02X want %02X\n",
                   what, i, got[i], want[i]);
            return 1;
        }
    }
    printf("PASS: %s, %zu bytes\n", what, got.size());
    return 0;
}

// ---------------------------------------------------------------------------
// Hand vectors
// ---------------------------------------------------------------------------
//
// Two blocks. Worked through by hand against the disassembly:
//
//   02 00          nblocks = 2, LITTLE-endian
//   block 1 table:
//     FF           count >= 0x80: skip 255-127 = 128 entries, then 1 entry
//     01 FF        left[128] = 0x01, right[128] = 0xFF   (0x01 != 128, so a
//                                                         right byte follows)
//     FE           skip 254-127 = 127: index reaches 256, table done
//   00 03          size = 3, BIG-endian
//   80             pair: push right 0xFF, take left 0x01
//                    leaf 0x01 -> acc 0x00+0x01 = 01   OUT 01
//                    pop  0xFF -> acc 0x01+0xFF = 00   OUT 00   (wraps)
//   02             leaf     -> acc 0x00+0x02 = 02      OUT 02
//   FE             leaf     -> acc 0x02+0xFE = 00      OUT 00   (wraps)
//   block 2 table:
//     FF           skip to 128, then 1 entry
//     80           left byte == index 128: UNUSED, and no right byte follows
//     FE           skip to 256, table done
//   00 02          size = 2
//   05             leaf     -> acc 0x00+0x05 = 05      OUT 05   (acc carried
//   FB             leaf     -> acc 0x05+0xFB = 00      OUT 00    across blocks)
//
static const uint8_t vec_in[] = {
    0x02, 0x00,
    0xFF, 0x01, 0xFF, 0xFE,
    0x00, 0x03,
    0x80, 0x02, 0xFE,
    0xFF, 0x80, 0xFE,
    0x00, 0x02,
    0x05, 0xFB,
};
static const uint8_t vec_out[] = { 0x01, 0x00, 0x02, 0x00, 0x05, 0x00 };

static std::vector<uint8_t> load(const char *path)
{
    std::vector<uint8_t> v;
    FILE *f = fopen(path, "rb");
    if (!f) { printf("FAIL: cannot open %s\n", path); return v; }
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    v.resize((size_t)n);
    if (fread(v.data(), 1, v.size(), f) != v.size()) v.clear();
    fclose(f);
    return v;
}

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);
    Vspi_rom_decode *dut = new Vspi_rom_decode;
    int rc = 0;

    // --- pass-through -----------------------------------------------------
    {
        std::vector<uint8_t> in;
        for (int i = 0; i < 4096; i++) in.push_back((uint8_t)(i * 7 + (i >> 5)));
        rc |= check("CODEC_RAW is a straight copy", run(dut, CODEC_RAW, in, 0), in);
        rc |= check("CODEC_RAW under backpressure", run(dut, CODEC_RAW, in, 0x5A), in);
    }

    // --- hand vectors -----------------------------------------------------
    {
        std::vector<uint8_t> in(vec_in, vec_in + sizeof(vec_in));
        std::vector<uint8_t> want(vec_out, vec_out + sizeof(vec_out));
        rc |= check("hand vectors", run(dut, CODEC_BPE_DPCM, in, 0), want);
        rc |= check("hand vectors under backpressure",
                    run(dut, CODEC_BPE_DPCM, in, 0x93), want);
    }

    // --- the real rdft2 stream -------------------------------------------
    if (argc >= 3) {
        std::vector<uint8_t> in   = load(argv[1]);
        std::vector<uint8_t> want = load(argv[2]);
        if (in.empty() || want.empty()) { delete dut; return 1; }

        uint64_t cycles = 0;
        size_t   used   = 0;
        std::vector<uint8_t> got = run(dut, CODEC_BPE_DPCM, in, 0x27, &cycles, &used);
        rc |= check("rdft2 sound1.u0222 vs tools/build_soundflash.py", got, want);

        // The decoder must also stop in the right PLACE. Reading one byte too
        // many or too few still decodes correctly here but would misplace every
        // following part of a real download.
        const size_t RDFT2_INPUT = 312933;
        if (used != RDFT2_INPUT) {
            printf("FAIL: consumed %zu input bytes, expected %zu\n", used, RDFT2_INPUT);
            rc = 1;
        } else {
            printf("PASS: stopped after exactly %zu input bytes\n", used);
        }
        printf("      %zu in -> %zu out (%.3fx) in %llu cycles, %.2f cycles/byte out\n",
               used, got.size(), used ? (double)got.size() / (double)used : 0.0,
               (unsigned long long)cycles,
               got.empty() ? 0.0 : (double)cycles / (double)got.size());
    }
    else {
        printf("SKIP: real-ROM test (needs the decoder input and reference,"
               " see `make run-bpe ROMS=...`)\n");
    }

    delete dut;
    return rc;
}
