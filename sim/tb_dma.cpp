//============================================================================
//  SlopperPI - spi_dma against MAME's own video RAMs.
//
//  Feeds the captured 386 main RAM and DMA registers into our DMA engine and
//  compares what it produces with the tilemap / palette / sprite RAM MAME's
//  driver actually ended up with. That validates the destination layout --
//  including the rowscroll tables landing out of order at 0x200 / 0x600 / 0xA00
//  and the segments being skipped entirely when rowscroll is off -- against the
//  real thing rather than against my reading of the source.
//
//  Capture with tools/mame_capture.lua.
//============================================================================

#include "Vspi_dma.h"
#include "verilated.h"

#include <cstdio>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>
#include <map>

static std::vector<uint8_t> load(const std::string &path, size_t expect = 0)
{
    FILE *f = fopen(path.c_str(), "rb");
    if (!f) { printf("FAIL: cannot open %s\n", path.c_str()); exit(1); }
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    std::vector<uint8_t> v(n);
    if (fread(v.data(), 1, n, f) != (size_t)n) { printf("FAIL: short read %s\n", path.c_str()); exit(1); }
    fclose(f);
    if (expect && v.size() != expect) {
        printf("FAIL: %s is %zu bytes, expected %zu\n", path.c_str(), v.size(), expect);
        exit(1);
    }
    return v;
}

static std::map<std::string, std::vector<long>> load_regs(const std::string &path)
{
    FILE *f = fopen(path.c_str(), "r");
    if (!f) { printf("FAIL: cannot open %s\n", path.c_str()); exit(1); }
    std::map<std::string, std::vector<long>> m;
    char line[256];
    while (fgets(line, sizeof line, f)) {
        char key[64];
        if (sscanf(line, "%63s", key) != 1) continue;
        std::vector<long> vals;
        const char *p = line + strlen(key);
        long v;
        int adv;
        while (sscanf(p, "%ld%n", &v, &adv) == 1) { vals.push_back(v); p += adv; }
        m[key] = vals;
    }
    fclose(f);
    return m;
}

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);
    std::string dir = (argc > 1) ? argv[1] : "cap";

    auto regs    = load_regs(dir + "/regs.txt");
    auto mainram = load(dir + "/mainram.bin", 0x40000);

    // The end-of-frame main RAM dump is NOT what the DMA read -- the game has
    // usually rewritten it by then. mame_capture.lua shadows main RAM and
    // snapshots the DMA source at trigger time; overlay those so the engine
    // sees exactly the bytes MAME's DMA saw.
    auto overlay = [&](const std::string &f, long base) {
        FILE *t = fopen((dir + "/" + f).c_str(), "rb");
        if (!t) return false;
        fclose(t);
        auto src = load(dir + "/" + f);
        for (size_t i = 0; i < src.size() && base + (long)i < 0x40000; i++)
            mainram[base + i] = src[i];
        return true;
    };
    auto ref_tm  = load(dir + "/tilemap_ram.bin", 0x4000);
    auto ref_pal = load(dir + "/palette_ram.bin", 0x3000);
    auto ref_spr = load(dir + "/sprite_ram.bin",  0x1000);

    const long rowscroll = regs["rowscroll"].at(0);
    const long tm_src    = regs["tilemap_dma"].at(0), tm_len  = regs["tilemap_dma"].at(1);
    const long pal_src   = regs["palette_dma"].at(0), pal_len = regs["palette_dma"].at(1);
    const long spr_src   = regs["sprite_dma"].at(0);

    const bool have_tm  = overlay("dma_tilemap_src.bin", tm_src);
    const bool have_pal = overlay("dma_palette_src.bin", pal_src);
    const bool have_spr = overlay("dma_sprite_src.bin",  spr_src);

    printf("rowscroll=%ld  tilemap src=%#lx len=%ld  palette src=%#lx len=%ld\n",
           rowscroll, tm_src, tm_len, pal_src, pal_len);
    if (!have_tm || !have_pal)
        printf("NOTE: missing trigger-time source capture (tm=%d pal=%d)\n", have_tm, have_pal);

    Vspi_dma *dut = new Vspi_dma;

    // Destination images produced by our DMA.
    std::vector<uint32_t> tm(4096, 0xDEADBEEF);
    std::vector<uint32_t> pal(4096, 0xDEADBEEF);   // 30-bit entries
    std::vector<uint32_t> spr(1024, 0xDEADBEEF);

    uint32_t ram_q = 0;      // main RAM read data, one cycle behind the address

    auto tick = [&]() {
        // Main RAM model: registered read, exactly like spi_mainram.
        uint32_t next_q = 0;
        size_t a = (size_t)dut->ram_addr * 4;
        if (a + 3 < mainram.size())
            next_q = mainram[a] | (mainram[a+1] << 8) | (mainram[a+2] << 16) | ((uint32_t)mainram[a+3] << 24);

        dut->ram_data = ram_q;
        dut->ram_gnt  = dut->ram_req;     // grant immediately

        dut->clk = 0; dut->eval();
        dut->clk = 1; dut->eval();

        if (dut->tm_we)  tm [dut->tm_addr ] = dut->tm_data;
        if (dut->pal_we) pal[dut->pal_addr] = dut->pal_data;
        if (dut->spr_we) spr[dut->spr_addr] = dut->spr_data;

        ram_q = next_q;
    };

    dut->reset = 1;
    dut->trig_tilemap = dut->trig_palette = dut->trig_sprite = 0;
    dut->rowscroll_enable = rowscroll;
    dut->dma_len = 0;
    dut->dma_src = 0;
    dut->ram_gnt = 0;
    for (int i = 0; i < 8; i++) tick();
    dut->reset = 0;
    for (int i = 0; i < 4; i++) tick();

    auto run_dma = [&](int which, long src, long len) {
        dut->dma_src = (src >> 2) & 0xFFFF;   // port is [17:2]
        dut->dma_len = len & 0xFFFF;
        for (int i = 0; i < 2; i++) tick();
        if (which == 0) dut->trig_tilemap = 1;
        if (which == 1) dut->trig_palette = 1;
        if (which == 2) dut->trig_sprite  = 1;
        tick();
        dut->trig_tilemap = dut->trig_palette = dut->trig_sprite = 0;
        int guard = 0;
        while (dut->busy || guard < 4) {
            tick();
            if (++guard > 200000) { printf("FAIL: DMA %d did not finish\n", which); exit(1); }
        }
        for (int i = 0; i < 4; i++) tick();
    };

    run_dma(0, tm_src,  tm_len);
    run_dma(1, pal_src, pal_len);
    if (have_spr) run_dma(2, spr_src, 0);

    // ---- compare ---------------------------------------------------------
    int fails = 0;

    auto cmp32 = [&](const char *name, const std::vector<uint32_t> &got,
                     const std::vector<uint8_t> &ref, size_t n) {
        size_t bad = 0, first = 0;
        for (size_t i = 0; i < n; i++) {
            uint32_t r = ref[i*4] | (ref[i*4+1] << 8) | (ref[i*4+2] << 16) | ((uint32_t)ref[i*4+3] << 24);
            if (got[i] != r) { if (!bad) first = i; bad++; }
        }
        printf("%-12s %zu/%zu dwords differ", name, bad, n);
        if (bad) {
            uint32_t r = ref[first*4] | (ref[first*4+1] << 8) | (ref[first*4+2] << 16) | ((uint32_t)ref[first*4+3] << 24);
            printf("  first at %#zx: got %08X want %08X", first, got[first], r);
            fails++;
        }
        printf("\n");
    };

    cmp32("tilemap", tm, ref_tm, 4096);

    // Palette: MAME keeps the raw dword, we keep the two 15-bit pens packed.
    {
        size_t bad = 0, first = 0;
        for (size_t i = 0; i < 3072; i++) {
            uint32_t r = ref_pal[i*4] | (ref_pal[i*4+1] << 8) | (ref_pal[i*4+2] << 16) | ((uint32_t)ref_pal[i*4+3] << 24);
            uint32_t want = ((r >> 16) & 0x7FFF) << 15 | (r & 0x7FFF);
            if ((pal[i] & 0x3FFFFFFF) != want) { if (!bad) first = i; bad++; }
        }
        printf("%-12s %zu/3072 entries differ", "palette", bad);
        if (bad) { printf("  first at %#zx", first); fails++; }
        printf("\n");
    }

    // The sprite DMA fires once at init on this set, so unless the capture
    // window happened to contain it there is nothing to compare against.
    if (have_spr) cmp32("sprite", spr, ref_spr, 1024);
    else          printf("%-12s skipped (no sprite DMA in the capture window)\n", "sprite");

    if (fails) { printf("FAIL\n"); return 1; }
    printf("PASS: DMA output matches MAME's video RAMs\n");
    delete dut;
    return 0;
}
