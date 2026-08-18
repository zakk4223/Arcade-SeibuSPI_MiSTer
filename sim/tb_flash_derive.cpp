//============================================================================
//  spi_flash_derive against the reference image, from a real SDRAM image
//
//  The RTL walker has to reach the same sample-flash image the game's own
//  updater programs in six minutes -- and tools/check_flash_derive.py already
//  reaches it, in Python, from the same SDRAM image these runs are given. So
//  this is the acceptance test that was written before the module was:
//
//      make -C sim run-flash-derive SDRAM=<set>-upd.bin SET=<name>
//
//  and the expected sha256 is the one recorded in build_soundflash's GAMES,
//  which is itself bit-exact against the image MAME's own flash devices hold
//  after running the ritual. Three independent routes to one hash.
//
//  The SDRAM model here is deliberately unhelpful: reads and writes complete
//  after a variable delay rather than immediately, because the walker shares
//  ch3 with the Z80 and the JTAG peek and a toggle handshake that only works
//  at zero latency is not a working handshake (PLAN.md 21.3).
//============================================================================

#include "Vspi_flash_derive.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

// rtl/spi_defs.vh
static const uint32_t SDR_PCM_BASE = 0x0280000;
static const uint32_t FLASH_SIZE   = 0x200000;
static const uint32_t SPRITES_BASE = 0x1100000;

enum { GEN_A = 0, GEN_B0 = 1, GEN_B1 = 2 };

// tools/build_soundflash.py GAMES: the per-set constants the MRA will carry,
// and the reference hash each set must reach.
struct Set {
    const char *name;
    uint32_t    job_table;
    uint32_t    stamp;
    int         gen;
    bool        snd01;        // has a second sound ROM behind the 0x800000 window
    bool        one_lane;     // generation A puts 1 MB of PCM on one lane
    uint32_t    pcmsrc_base;
    const char *sha256;
};

static const uint32_t PCMSRC_SEI252 = SPRITES_BASE + 3 * 0x400000;
static const uint32_t PCMSRC_RDFT2  = SPRITES_BASE + 3 * 0x600000;
static const uint32_t PCMSRC_RFJET  = SPRITES_BASE + 3 * 0x800000;

static const Set SETS[] = {
    {"senkyu",   0x00302324, 0x003FFFFC, GEN_A,  true,  true,  PCMSRC_SEI252,
     "dd081ebad5534f72d97d815ba9ab3e9a2281c70cd017efada262a04659edd528"},
    {"batlball", 0x00302290, 0x003FFFFC, GEN_A,  true,  true,  PCMSRC_SEI252,
     "09c4b1ec253324f80d2c5763f6e037e2136c8c8f4a1fc55701edbaa80e0d3181"},
    {"ejanhs",   0x003026AC, 0x003FFFFC, GEN_A,  true,  true,  PCMSRC_SEI252,
     "7693933a13108ffc0b283a64d8f3347f76dd28b0771d71f380e140496936341f"},
    // viprp1 is the one with NO second sound ROM: its compressed tail lives in
    // the 386 program image, which is why no MRA can assemble it a pre-flashed
    // image and why deriving it is the plan's clearest win.
    {"viprp1",   0x00200760, 0x003FFFFC, GEN_A,  false, true,  PCMSRC_SEI252,
     "274495438f7acc2593c57441d7eb02d1371eb0e275e7ef3ca55e7774fa71a44e"},
    {"rdft",     0x0020174D, 0x003FFFFC, GEN_B0, true,  false, PCMSRC_SEI252,
     "659df8c6a964c109465cc6d927f1565c57beae5d9d86b88b09e5976b57befee1"},
    {"rdft2",    0x00201B55, 0x003FFFFC, GEN_B1, true,  false, PCMSRC_RDFT2,
     "c0da4614a8d07a7bce24b7712b756435f2c5fd1ef74dc44333657afdecc6c67c"},
    {"rfjet",    0x00203597, 0x003FFFFC, GEN_B1, true,  false, PCMSRC_RFJET,
     "fb02c059e7ee1b0a26c97ccb5d6eb60eaaa1c48a7e65c76c2d2628475cb4e621"},
};

// ------------------------------------------------------------------ sha256 --
// Small enough to carry rather than depend on a library, and the hashes it
// produces are checked against sha256sum in the runner comment.
struct Sha256 {
    uint32_t h[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                     0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
    uint64_t len = 0;
    uint8_t  buf[64];
    size_t   n = 0;

    static uint32_t ror(uint32_t x, int c) { return (x >> c) | (x << (32 - c)); }

    void block(const uint8_t *p) {
        static const uint32_t k[64] = {
            0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,
            0x923f82a4,0xab1c5ed5,0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,
            0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,0xe49b69c1,0xefbe4786,
            0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
            0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,
            0x06ca6351,0x14292967,0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,
            0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,0xa2bfe8a1,0xa81a664b,
            0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
            0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,
            0x5b9cca4f,0x682e6ff3,0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,
            0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2};
        uint32_t w[64];
        for (int i = 0; i < 16; i++)
            w[i] = (p[i*4] << 24) | (p[i*4+1] << 16) | (p[i*4+2] << 8) | p[i*4+3];
        for (int i = 16; i < 64; i++) {
            uint32_t s0 = ror(w[i-15],7) ^ ror(w[i-15],18) ^ (w[i-15] >> 3);
            uint32_t s1 = ror(w[i-2],17) ^ ror(w[i-2],19) ^ (w[i-2] >> 10);
            w[i] = w[i-16] + s0 + w[i-7] + s1;
        }
        uint32_t a=h[0],b=h[1],c=h[2],d=h[3],e=h[4],f=h[5],g=h[6],hh=h[7];
        for (int i = 0; i < 64; i++) {
            uint32_t S1 = ror(e,6) ^ ror(e,11) ^ ror(e,25);
            uint32_t ch = (e & f) ^ (~e & g);
            uint32_t t1 = hh + S1 + ch + k[i] + w[i];
            uint32_t S0 = ror(a,2) ^ ror(a,13) ^ ror(a,22);
            uint32_t mj = (a & b) ^ (a & c) ^ (b & c);
            uint32_t t2 = S0 + mj;
            hh=g; g=f; f=e; e=d+t1; d=c; c=b; b=a; a=t1+t2;
        }
        h[0]+=a; h[1]+=b; h[2]+=c; h[3]+=d; h[4]+=e; h[5]+=f; h[6]+=g; h[7]+=hh;
    }
    void update(const uint8_t *p, size_t l) {
        len += l;
        while (l) {
            size_t take = 64 - n < l ? 64 - n : l;
            memcpy(buf + n, p, take);
            n += take; p += take; l -= take;
            if (n == 64) { block(buf); n = 0; }
        }
    }
    std::string hex() {
        uint64_t bits = len * 8;
        uint8_t pad = 0x80;
        update(&pad, 1);
        uint8_t z = 0;
        while (n != 56) update(&z, 1);
        uint8_t be[8];
        for (int i = 0; i < 8; i++) be[i] = (uint8_t)(bits >> (56 - 8*i));
        update(be, 8);
        char out[65];
        for (int i = 0; i < 8; i++) sprintf(out + i*8, "%08x", h[i]);
        return std::string(out, 64);
    }
};

// ------------------------------------------------------------------- model --
static std::vector<uint8_t> sdram;
static Vspi_flash_derive   *dut;
static uint64_t             cycles = 0;

// Deliberately not zero-latency, and not a constant either: the walker will
// share ch3 with the Z80 fetch and the peek.
static int      rd_prev = 0, wr_prev = 0;
static int      rd_wait = -1, wr_wait = -1;
static uint32_t rd_addr = 0, wr_addr = 0;
static uint16_t wr_data = 0;
static uint8_t  wr_mask = 0;
static uint64_t reads = 0, writes = 0;

static uint32_t lcg = 12345;
static int jitter(int base) { lcg = lcg * 1103515245u + 12345u; return base + (lcg >> 28); }

static void tick() {
    dut->clk = 0; dut->eval();

    // One port now, read and write, exactly as ch3 presents it.
    if (dut->sdr_req != rd_prev && rd_wait < 0 && wr_wait < 0) {
        rd_prev = dut->sdr_req;
        if (dut->sdr_rnw) { rd_addr = dut->sdr_addr; rd_wait = jitter(4); }
        else {
            wr_addr = dut->sdr_addr; wr_data = dut->sdr_din;
            wr_mask = dut->sdr_be;   wr_wait = jitter(3);
        }
    }
    if (rd_wait > 0) rd_wait--;
    else if (rd_wait == 0) {
        uint64_t g = 0;
        for (int b = 0; b < 8; b++) {
            uint32_t a = rd_addr + b;
            g |= (uint64_t)(a < sdram.size() ? sdram[a] : 0xFF) << (8 * b);
        }
        dut->sdr_dout = g;
        dut->sdr_ack  = rd_prev;
        rd_wait = -1; reads++;
    }


    if (wr_wait > 0) wr_wait--;
    else if (wr_wait == 0) {
        if (wr_mask & 1) sdram[wr_addr]     = (uint8_t)(wr_data & 0xFF);
        if (wr_mask & 2) sdram[wr_addr + 1] = (uint8_t)(wr_data >> 8);
        dut->sdr_ack = rd_prev;
        wr_wait = -1; writes++;
    }

    dut->clk = 1; dut->eval();
    cycles++;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 3) {
        printf("usage: %s <sdram.bin> <set>\n", argv[0]);
        return 2;
    }
    const char *path = argv[1], *setname = argv[2];

    const Set *cfg = nullptr;
    for (const Set &s : SETS) if (!strcmp(s.name, setname)) cfg = &s;
    if (!cfg) { printf("FAIL: no such set %s\n", setname); return 2; }

    FILE *f = fopen(path, "rb");
    if (!f) { printf("FAIL: cannot open %s\n", path); return 2; }
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    sdram.resize((size_t)n);
    if (fread(sdram.data(), 1, (size_t)n, f) != (size_t)n) {
        printf("FAIL: short read on %s\n", path); return 2;
    }
    fclose(f);

    // The region starts BLANK, exactly as the authentic MRA ships it. Anything
    // the walker does not write must stay 0xFF, which is what makes the hash a
    // check on coverage and not only on content.
    for (uint32_t i = 0; i < FLASH_SIZE; i++) sdram[SDR_PCM_BASE + i] = 0xFF;

    dut = new Vspi_flash_derive;
    dut->reset = 1; dut->start = 0;
    dut->stamp_en = 1;                  // Pre-built: payload and stamp
    dut->start_blank = 0;
    dut->job_table    = cfg->job_table;
    dut->stamp_addr   = cfg->stamp;
    dut->gen          = cfg->gen;
    dut->snd01_en     = cfg->snd01;
    dut->pcmsrc_en    = 1;
    dut->pcmsrc_1lane = cfg->one_lane;
    dut->pcmsrc_base  = cfg->pcmsrc_base;
    dut->sdr_ack = 0; dut->sdr_dout = 0;
    for (int i = 0; i < 8; i++) tick();
    dut->reset = 0;
    for (int i = 0; i < 8; i++) tick();

    dut->start = 1; tick(); dut->start = 0;

    const uint64_t LIMIT = 400000000ull;
    while (!dut->done && !dut->err_overrun && !dut->err_badjob &&
           cycles < LIMIT) tick();

    if (dut->err_badjob) {
        printf("FAIL: %s rejected its job table after %u jobs "
               "(src=%08X len=%u) -- wrong job_table constant?\n",
               setname, (unsigned)dut->jobs_done, (unsigned)dut->dbg_src,
               (unsigned)dut->dbg_len);
        return 1;
    }
    if (dut->err_overrun) {
        printf("FAIL: %s overran the flash region after %u bytes, %u jobs\n",
               setname, (unsigned)dut->bytes_out, (unsigned)dut->jobs_done);
        return 1;
    }
    if (!dut->done) {
        printf("FAIL: %s did not finish in %llu cycles (%u bytes, %u jobs)\n",
               setname, (unsigned long long)LIMIT,
               (unsigned)dut->bytes_out, (unsigned)dut->jobs_done);
        printf("      stuck in state %u at esi=%08X; record src=%08X len=%u "
               "mode=%u dec=%u\n", (unsigned)dut->dbg_state,
               (unsigned)dut->dbg_esi, (unsigned)dut->dbg_src,
               (unsigned)dut->dbg_len, (unsigned)dut->dbg_mode,
               (unsigned)dut->dbg_dec);
        return 1;
    }

    Sha256 sh;
    sh.update(&sdram[SDR_PCM_BASE], FLASH_SIZE);
    std::string got = sh.hex();

    printf("%-9s %u jobs, %u payload bytes, %llu reads, %llu writes, "
           "%llu cycles\n", setname, (unsigned)dut->jobs_done,
           (unsigned)dut->bytes_out, (unsigned long long)reads,
           (unsigned long long)writes, (unsigned long long)cycles);
    printf("          %s\n", got.c_str());

    if (got != cfg->sha256) {
        printf("FAIL: %s does not match the reference\n          %s\n",
               setname, cfg->sha256);
        // With a reference image, say WHERE it went wrong rather than only
        // that it did: which job's output the first bad byte falls in is
        // usually the whole diagnosis.
        if (argc > 3) {
            FILE *rf = fopen(argv[3], "rb");
            if (rf) {
                std::vector<uint8_t> ref(FLASH_SIZE, 0xFF);
                size_t rn = fread(ref.data(), 1, FLASH_SIZE, rf);
                fclose(rf);
                size_t bad = 0, first = 0;
                for (size_t i = 0; i < rn; i++)
                    if (sdram[SDR_PCM_BASE + i] != ref[i]) {
                        if (!bad) first = i;
                        bad++;
                    }
                printf("      %zu of %zu bytes differ, first at %#zx "
                       "(got %02X want %02X)\n", bad, rn, first,
                       sdram[SDR_PCM_BASE + first], ref[first]);
            }
        }
        return 1;
    }
    printf("PASS: %s matches the image MAME's own flash devices hold\n", setname);

    // ---- Cart copy: the same payload, and no stamp ------------------------
    // The mode the OSD's Sample Flash option selects. The game has to find a
    // flash it must program itself, so the four stamp bytes must be left exactly
    // as the MRA loaded them -- here the 0xFF the region was filled with.
    {
        std::vector<uint8_t> prebuilt(sdram.begin() + SDR_PCM_BASE,
                                      sdram.begin() + SDR_PCM_BASE + FLASH_SIZE);
        for (uint32_t i = 0; i < FLASH_SIZE; i++) sdram[SDR_PCM_BASE + i] = 0xFF;
        dut->reset = 1; for (int i = 0; i < 8; i++) tick();
        dut->reset = 0; for (int i = 0; i < 8; i++) tick();
        dut->stamp_en = 0;
        dut->start = 1; tick(); dut->start = 0;
        while (!dut->done && !dut->err_overrun && !dut->err_badjob &&
               cycles < LIMIT * 2) tick();
        if (!dut->done) { printf("FAIL: the stamp_en=0 walk did not finish\n"); return 1; }
        int stamped = 0, payload_bad = 0;
        for (int i = 0; i < 4; i++) if (sdram[SDR_PCM_BASE + i] != 0xFF) stamped++;
        for (uint32_t i = 4; i < FLASH_SIZE; i++)
            if (sdram[SDR_PCM_BASE + i] != prebuilt[i]) payload_bad++;
        if (stamped || payload_bad) {
            printf("FAIL: stamp_en=0 wrote %d of the 4 stamp bytes and got %d "
                   "payload bytes wrong\n", stamped, payload_bad);
            return 1;
        }
        printf("PASS: %s with stamp_en low -- the same %u payload bytes and the "
               "stamp left erased, which is what makes the game run its own "
               "updater\n", setname, FLASH_SIZE - 4);
    }

    // ---- the blank write the OSD toggle uses ------------------------------
    // Byte 0 keeps the region code, because an erased one is the mainboard's
    // "hardware error 81"; bytes 1..3 are erased, which is what a blank
    // cartridge flash is dumped as.
    {
        uint8_t region = sdram[cfg->stamp - 0x00200000];
        // Start from a PROGRAMMED stamp, since that is the state the toggle has
        // to undo -- Pre-built wrote one a moment ago.
        for (int i = 0; i < 4; i++)
            sdram[SDR_PCM_BASE + i] = sdram[cfg->stamp - 0x00200000 + i];
        uint64_t before = writes;
        dut->reset = 1; for (int i = 0; i < 8; i++) tick();
        dut->reset = 0; for (int i = 0; i < 8; i++) tick();
        dut->start_blank = 1; tick(); dut->start_blank = 0;
        uint64_t guard = cycles + 100000;
        while (!dut->done && cycles < guard) tick();
        if (!dut->done) { printf("FAIL: start_blank did not finish\n"); return 1; }
        uint8_t *f = &sdram[SDR_PCM_BASE];
        if (f[0] != region || f[1] != 0xFF || f[2] != 0xFF || f[3] != 0xFF) {
            printf("FAIL: blank stamp is %02X %02X %02X %02X, want %02X FF FF FF\n",
                   f[0], f[1], f[2], f[3], region);
            return 1;
        }
        printf("PASS: start_blank leaves %02X FF FF FF in %llu writes -- the "
               "region kept, the build ID erased\n", region,
               (unsigned long long)(writes - before));
    }
    return 0;
}
