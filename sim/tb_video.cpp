//============================================================================
//  SlopperPI - render a frame and diff it against MAME's.
//
//  Loads MAME's captured tilemap and palette RAM straight into ours, points the
//  graphics fetch at the real (still encrypted) ROM image, renders a frame, and
//  compares pixel for pixel with the frame MAME drew from the same state.
//
//  That covers the whole render path in one shot: tilemap addressing and the
//  column-major scan, scroll and rowscroll, the fetch-time tile decryption, the
//  gfx bit layout, palette lookup, and the mixing order.
//
//  Inputs (see tools/mame_capture.lua and tools/build_sdram_image.py):
//    <capdir>/tilemap_ram.bin  <capdir>/palette_ram.bin
//    <capdir>/frame.bin        <capdir>/regs.txt
//    <sdram image>
//============================================================================

#include "Vtb_video_top.h"
#include "verilated.h"

#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <string>
#include <vector>
#include <map>
#include "spi_ref.h"

static const int W = 320, H = 240;

static std::vector<uint8_t> load(const std::string &p, size_t expect = 0)
{
    FILE *f = fopen(p.c_str(), "rb");
    if (!f) { printf("FAIL: cannot open %s\n", p.c_str()); exit(1); }
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    std::vector<uint8_t> v(n);
    if (fread(v.data(), 1, n, f) != (size_t)n) { printf("FAIL: short read %s\n", p.c_str()); exit(1); }
    fclose(f);
    if (expect && v.size() != expect) {
        printf("FAIL: %s is %zu bytes, expected %zu\n", p.c_str(), v.size(), expect); exit(1);
    }
    return v;
}

static std::map<std::string, std::vector<long>> load_regs(const std::string &p)
{
    FILE *f = fopen(p.c_str(), "r");
    if (!f) { printf("FAIL: cannot open %s\n", p.c_str()); exit(1); }
    std::map<std::string, std::vector<long>> m;
    char line[256];
    while (fgets(line, sizeof line, f)) {
        char key[64];
        if (sscanf(line, "%63s", key) != 1) continue;
        std::vector<long> vals; const char *q = line + strlen(key); long v; int adv;
        while (sscanf(q, "%ld%n", &v, &adv) == 1) { vals.push_back(v); q += adv; }
        m[key] = vals;
    }
    fclose(f);
    return m;
}

// Minimal PNG writer so failures can actually be looked at.
#include <zlib.h>
static void write_png(const char *path, const std::vector<uint32_t> &px, int w, int h)
{
    std::vector<uint8_t> raw;
    raw.reserve((size_t)h * (w * 3 + 1));
    for (int y = 0; y < h; y++) {
        raw.push_back(0);
        for (int x = 0; x < w; x++) {
            uint32_t c = px[(size_t)y * w + x];
            raw.push_back((c >> 16) & 0xFF);
            raw.push_back((c >> 8) & 0xFF);
            raw.push_back(c & 0xFF);
        }
    }
    uLongf clen = compressBound(raw.size());
    std::vector<uint8_t> comp(clen);
    if (compress2(comp.data(), &clen, raw.data(), raw.size(), 9) != Z_OK) return;

    FILE *f = fopen(path, "wb");
    if (!f) return;
    auto be32 = [&](uint32_t v) {
        uint8_t b[4] = { (uint8_t)(v >> 24), (uint8_t)(v >> 16), (uint8_t)(v >> 8), (uint8_t)v };
        fwrite(b, 1, 4, f);
    };
    auto chunk = [&](const char *tag, const uint8_t *d, size_t n) {
        be32((uint32_t)n);
        uint32_t c = crc32(0, (const Bytef *)tag, 4);
        if (n) c = crc32(c, d, n);
        fwrite(tag, 1, 4, f);
        if (n) fwrite(d, 1, n, f);
        be32(c);
    };
    const uint8_t sig[8] = { 137, 'P', 'N', 'G', 13, 10, 26, 10 };
    fwrite(sig, 1, 8, f);
    uint8_t ihdr[13] = {
        (uint8_t)(w >> 24), (uint8_t)(w >> 16), (uint8_t)(w >> 8), (uint8_t)w,
        (uint8_t)(h >> 24), (uint8_t)(h >> 16), (uint8_t)(h >> 8), (uint8_t)h,
        8, 2, 0, 0, 0
    };
    chunk("IHDR", ihdr, 13);
    chunk("IDAT", comp.data(), clen);
    chunk("IEND", nullptr, 0);
    fclose(f);
}

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);
    if (argc < 3) { printf("usage: %s <capdir> <sdram.bin> [outdir]\n", argv[0]); return 1; }
    std::string cap = argv[1], sdrpath = argv[2];
    std::string outdir = (argc > 3) ? argv[3] : cap;

    auto regs   = load_regs(cap + "/regs.txt");
    auto tm     = load(cap + "/tilemap_ram.bin", 0x4000);
    auto pal    = load(cap + "/palette_ram.bin", 0x3000);
    auto ref    = load(cap + "/frame.bin", (size_t)W * H * 4);
    auto sdram  = load(sdrpath);

    Vtb_video_top *dut = new Vtb_video_top;

    dut->layer_enable     = regs["layer_enable"].at(0);
    dut->rowscroll_enable = regs["rowscroll"].at(0);
    dut->fore_layer_d13   = regs["fore_d13"].at(0);
    dut->rf2_layer_bank   = regs["rf2_bank"].at(0);
    dut->scroll_bx = regs["scroll_back"].at(0); dut->scroll_by = regs["scroll_back"].at(1);
    dut->scroll_mx = regs["scroll_midl"].at(0); dut->scroll_my = regs["scroll_midl"].at(1);
    dut->scroll_fx = regs["scroll_fore"].at(0); dut->scroll_fy = regs["scroll_fore"].at(1);

    printf("layer_enable=%02X rowscroll=%d fore_d13=%d scroll b(%d,%d) m(%d,%d) f(%d,%d)\n",
           (int)dut->layer_enable, (int)dut->rowscroll_enable, (int)dut->fore_layer_d13,
           (int)dut->scroll_bx, (int)dut->scroll_by, (int)dut->scroll_mx,
           (int)dut->scroll_my, (int)dut->scroll_fx, (int)dut->scroll_fy);

    // ---- SDRAM model: fixed latency, 64-bit aligned reads ------------------
    int      sdr_delay = -1;
    uint8_t  sdr_req_d = 0;
    uint64_t sdr_data  = 0;

    long long sdr_count = 0;
    auto tick = [&]() {
        if (dut->sdr_req != sdr_req_d) { sdr_req_d = dut->sdr_req; sdr_delay = 8; sdr_count++; }
        if (sdr_delay > 0 && --sdr_delay == 0) {
            uint64_t a = (uint64_t)dut->sdr_addr & ~7ull;
            sdr_data = 0;
            for (int i = 0; i < 8; i++)
                if (a + i < sdram.size()) sdr_data |= (uint64_t)sdram[a + i] << (8 * i);
            dut->sdr_ack = sdr_req_d;
        }
        dut->sdr_dout = sdr_data;
        dut->clk = 0; dut->eval();
        dut->clk = 1; dut->eval();
    };

    // ---- reset and preload -------------------------------------------------
    dut->reset = 1;
    dut->pre_tm_we = dut->pre_pal_we = 0;
    for (int i = 0; i < 16; i++) tick();

    for (int i = 0; i < 4096; i++) {
        dut->pre_tm_addr = i;
        dut->pre_tm_data = tm[i*4] | (tm[i*4+1] << 8) | (tm[i*4+2] << 16) | ((uint32_t)tm[i*4+3] << 24);
        dut->pre_tm_we   = 1;
        tick();
    }
    dut->pre_tm_we = 0;

    for (int i = 0; i < 3072; i++) {
        uint32_t r = pal[i*4] | (pal[i*4+1] << 8) | (pal[i*4+2] << 16) | ((uint32_t)pal[i*4+3] << 24);
        dut->pre_pal_addr = i;
        dut->pre_pal_data = (uint32_t)(((r >> 16) & 0x7FFF) << 15 | (r & 0x7FFF));
        dut->pre_pal_we   = 1;
        tick();
    }
    dut->pre_pal_we = 0;

    dut->reset = 0;
    for (int i = 0; i < 16; i++) tick();

    // ---- back layer check ---------------------------------------------------
    // Compare spi_layers' back-layer line buffer against a direct model of
    // MAME's semantics, so the renderer is validated independently of the mixer.
    auto back_line = [&](int y, int sx, int sy, int d14, std::vector<uint16_t> &out) {
        out.assign(320, 0);
        int src_y = (y + sy) & 511, row = src_y >> 4, fine_y = src_y & 15;
        for (int x = 0; x < 320; x++) {
            int src_x = (x + sx) & 511, col = src_x >> 4, fine_x = src_x & 15;
            int ti = col * 32 + row;                       // TILEMAP_SCAN_COLS
            size_t d = (size_t)(ti >> 1) * 4;
            uint32_t dw = tm[d] | (tm[d+1] << 8) | (tm[d+2] << 16) | ((uint32_t)tm[d+3] << 24);
            uint16_t w = (ti & 1) ? (dw >> 16) : (dw & 0xFFFF);
            uint32_t code = (w & 0x1FFF) | (d14 ? 0x4000 : 0);
            uint32_t color = (w >> 13) & 7;
            uint32_t off = 0x0480000 + code * 192 + fine_y * 12;
            int g = fine_x >> 2, p = fine_x & 3;
            size_t b = off + g * 3;
            uint32_t raw = ((uint32_t)sdram[b] << 16) | ((uint32_t)sdram[b+1] << 8) | sdram[b+2];
            uint32_t v = decrypt_tile(raw, code & 0xFFF, 0x5A3845, 0x77CF5B, 0x1378DF);
            uint32_t pix = 0;
            for (int k = 0; k < 6; k++) pix |= ((v >> (4 * k + p)) & 1) << k;
            out[x] = (uint16_t)((color << 6) | pix);
        }
    };

    // Generic 16x16 layer reference (back / midl / fore).
    auto tile_line = [&](int y, int tm_base_dw, int rs_base_dw, bool use_rs,
                         int sx, int sy, uint32_t code_or, std::vector<uint16_t> &out) {
        int rowscroll = 0;
        if (use_rs) {
            int idx = (y + 19) & 511;
            size_t d = (size_t)(rs_base_dw + (idx >> 1)) * 4;
            uint32_t dw = tm[d] | (tm[d+1] << 8) | (tm[d+2] << 16) | ((uint32_t)tm[d+3] << 24);
            rowscroll = (int16_t)((idx & 1) ? (dw >> 16) : (dw & 0xFFFF));
        }
        out.assign(320, 0);
        int src_y = (y + sy) & 511, row = src_y >> 4, fine_y = src_y & 15;
        for (int x = 0; x < 320; x++) {
            int src_x = (x + sx + rowscroll) & 511, col = src_x >> 4, fine_x = src_x & 15;
            int ti = col * 32 + row;
            size_t d = (size_t)(tm_base_dw + (ti >> 1)) * 4;
            uint32_t dw = tm[d] | (tm[d+1] << 8) | (tm[d+2] << 16) | ((uint32_t)tm[d+3] << 24);
            uint16_t w = (ti & 1) ? (dw >> 16) : (dw & 0xFFFF);
            uint32_t code = (w & 0x1FFF) | code_or;
            uint32_t color = (w >> 13) & 7;
            uint32_t off = 0x0480000 + code * 192 + fine_y * 12;
            int g = fine_x >> 2, p = fine_x & 3;
            size_t b = off + g * 3;
            uint32_t raw = ((uint32_t)sdram[b] << 16) | ((uint32_t)sdram[b+1] << 8) | sdram[b+2];
            uint32_t v = decrypt_tile(raw, code & 0xFFF, 0x5A3845, 0x77CF5B, 0x1378DF);
            uint32_t pix = 0;
            for (int k = 0; k < 6; k++) pix |= ((v >> (4 * k + p)) & 1) << k;
            out[x] = (uint16_t)((color << 6) | pix);
        }
    };

    // Text layer reference: 8x8, 5bpp, no scroll, TILEMAP_SCAN_ROWS 64x32.
    // planes {4,8,12,16,20} => plane k at bit offset 4k+4, pixel p at +(3-p),
    // and bit offset n is v[23-n], so plane k = v[16-4k+p].
    auto text_line = [&](int y, int tm_base_dw, std::vector<uint16_t> &out) {
        out.assign(320, 0);
        int row = (y >> 3) & 31, fine_y = y & 7;
        for (int x = 0; x < 320; x++) {
            int col = (x >> 3) & 63, fine_x = x & 7;
            int ti = row * 64 + col;
            size_t d = (size_t)(tm_base_dw + (ti >> 1)) * 4;
            uint32_t dw = tm[d] | (tm[d+1] << 8) | (tm[d+2] << 16) | ((uint32_t)tm[d+3] << 24);
            uint16_t w = (ti & 1) ? (dw >> 16) : (dw & 0xFFFF);
            uint32_t code = w & 0xFFF, color = (w >> 12) & 0xF;
            uint32_t off = 0x0240000 + code * 48 + fine_y * 6;
            int g = fine_x >> 2, p = fine_x & 3;
            size_t b = off + g * 3;
            uint32_t raw = ((uint32_t)sdram[b] << 16) | ((uint32_t)sdram[b+1] << 8) | sdram[b+2];
            uint32_t v = decrypt_tile(raw, code, 0x5A3845, 0x77CF5B, 0x1378DF);
            uint32_t pix = 0;
            for (int k = 0; k < 5; k++) pix |= ((v >> (4 * k + p)) & 1) << k;
            out[x] = (uint16_t)((color << 6) | pix);
        }
    };

    // ---- render ------------------------------------------------------------
    // The renderer builds a line one scanline ahead, so the first frame after
    // reset is incomplete; capture the second.
    std::vector<uint32_t> got((size_t)W * H, 0);
    int frame = 0;
    long long guard = 0;
    int prev_v = -1;

    const int PROBE_Y = 60;
    std::vector<uint16_t> lb_seen(512, 0xFFFF);
    std::vector<uint16_t> lb_text_seen(512, 0xFFFF);
    std::vector<uint16_t> lb_fore_seen(512, 0xFFFF);
    bool probed = false;

    while (frame < 3) {
        tick();
        if (++guard > 40000000LL) { printf("FAIL: timeout\n"); return 1; }

        // Record the back-layer line buffer across one scanline of frame 2.
        if (frame == 2 && dut->vcnt == PROBE_Y && dut->ce_pix && dut->hcnt < 512) {
            lb_seen[dut->hcnt] = dut->dbg_back;
            lb_text_seen[dut->hcnt] = dut->dbg_text;
            lb_fore_seen[dut->hcnt] = dut->dbg_fore;
            probed = true;
            if (dut->hcnt < 10)
                printf("  x=%2d  back=%03X midl=%03X fore=%03X text=%03X  out=%06X\n",
                       (int)dut->hcnt, (int)dut->dbg_back, (int)dut->dbg_midl,
                       (int)dut->dbg_fore, (int)dut->dbg_text,
                       ((uint32_t)dut->red << 16) | ((uint32_t)dut->green << 8) | dut->blue);
        }

        if (dut->ce_pix) {
            int x = dut->hcnt, y = dut->vcnt;
            if (frame == 2 && x < W && y < H)
                got[(size_t)y * W + x] = ((uint32_t)dut->red << 16) |
                                         ((uint32_t)dut->green << 8) | dut->blue;
        }
        if (dut->vcnt != prev_v) {
            if (dut->vcnt == 0 && prev_v > 0) frame++;
            prev_v = dut->vcnt;
        }
    }

    if (probed) {
        std::vector<uint16_t> want_line;
        back_line(PROBE_Y, regs["scroll_back"].at(0) & 511,
                  regs["scroll_back"].at(1) & 511,
                  (regs["rf2_bank"].at(0) & 1), want_line);
        // Print the whole profile: a repetitive scanline makes several offsets
        // tie at 100%, so a plain argmax is misleading.
        printf("back layer line %d offset profile:", PROBE_Y);
        int best_off = 0; size_t best = 0;
        for (int off = -6; off <= 6; off++) {
            size_t m = 0;
            for (int x = 0; x < 300; x++) {
                int sx = x + off;
                if (sx < 0 || sx >= 512) continue;
                if (lb_seen[sx] == want_line[x]) m++;
            }
            printf(" %d:%zu", off, m);
            if (m > best) { best = m; best_off = off; }
        }
        printf("\n  best offset %d (%zu/300)\n", best_off, best);

        {
            std::vector<uint16_t> wf;
            uint32_t code_or = 0x4000 | (regs["fore_d13"].at(0) ? 0x2000u : 0u);
            tile_line(PROBE_Y, dut->rowscroll_enable ? 0x400 : 0x200, 0xA00,
                      dut->rowscroll_enable != 0,
                      regs["scroll_fore"].at(0) & 511, regs["scroll_fore"].at(1) & 511,
                      code_or, wf);
            {   // Cross-check every captured buffer against every reference: a
                // swap or a wrong base shows up immediately.
                std::vector<uint16_t> rb, rm, rf;
                tile_line(PROBE_Y, dut->rowscroll_enable ? 0x000 : 0x000, 0x200,
                          dut->rowscroll_enable != 0,
                          regs["scroll_back"].at(0) & 511, regs["scroll_back"].at(1) & 511,
                          0, rb);
                tile_line(PROBE_Y, dut->rowscroll_enable ? 0x800 : 0x400, 0x600,
                          dut->rowscroll_enable != 0,
                          regs["scroll_midl"].at(0) & 511, regs["scroll_midl"].at(1) & 511,
                          0x2000, rm);
                tile_line(PROBE_Y, dut->rowscroll_enable ? 0x400 : 0x200, 0xA00,
                          dut->rowscroll_enable != 0,
                          regs["scroll_fore"].at(0) & 511, regs["scroll_fore"].at(1) & 511,
                          0x4000 | (regs["fore_d13"].at(0) ? 0x2000u : 0u), rf);
                const std::vector<uint16_t> *refs[3] = { &rb, &rm, &rf };
                const uint16_t *caps[3] = { lb_seen.data(), nullptr, lb_fore_seen.data() };
                const char *rn[3] = { "back", "midl", "fore" };
                for (int c = 0; c < 3; c++) {
                    if (!caps[c]) continue;
                    printf("  captured %s vs refs:", rn[c]);
                    for (int r = 0; r < 3; r++) {
                        size_t m = 0;
                        for (int x = 0; x < 300; x++) if (caps[c][x] == (*refs[r])[x]) m++;
                        printf("  %s=%zu", rn[r], m);
                    }
                    printf("\n");
                }
            }

            {   // what rowscroll does the reference see?
                int idx = (PROBE_Y + 19) & 511;
                size_t d = (size_t)(0xA00 + (idx >> 1)) * 4;
                uint32_t dw = tm[d] | (tm[d+1] << 8) | (tm[d+2] << 16) | ((uint32_t)tm[d+3] << 24);
                int rs = (int16_t)((idx & 1) ? (dw >> 16) : (dw & 0xFFFF));
                int idxb = (PROBE_Y + 19) & 511;
                size_t db = (size_t)(0x200 + (idxb >> 1)) * 4;
                uint32_t dwb = tm[db] | (tm[db+1] << 8) | (tm[db+2] << 16) | ((uint32_t)tm[db+3] << 24);
                int rsb = (int16_t)((idxb & 1) ? (dwb >> 16) : (dwb & 0xFFFF));
                printf("rowscroll line %d: fore=%d back=%d\n", PROBE_Y, rs, rsb);
            }
            {   // fore with rowscroll disabled, for comparison
                std::vector<uint16_t> w2;
                tile_line(PROBE_Y, 0x400, 0xA00, false,
                          regs["scroll_fore"].at(0) & 511, regs["scroll_fore"].at(1) & 511,
                          code_or, w2);
                size_t m = 0;
                for (int x = 0; x < 300; x++) if (lb_fore_seen[x] == w2[x]) m++;
                printf("fore (no rowscroll) at offset 0: %zu/300\n", m);
            }
            {   // hypothesis sweep for the fore layer
                struct H { const char *name; int base; int rs; int sx,sy; uint32_t cor; int dy; };
                uint32_t c0 = 0x4000 | (regs["fore_d13"].at(0) ? 0x2000u : 0u);
                H hs[] = {
                    {"as-is",        0x400, 0xA00, 0, 0, c0,      0},
                    {"y-1",          0x400, 0xA00, 0, 0, c0,     -1},
                    {"y+1",          0x400, 0xA00, 0, 0, c0,     +1},
                    {"no d13",       0x400, 0xA00, 0, 0, 0x4000,  0},
                    {"d13 only",     0x400, 0xA00, 0, 0, 0x2000,  0},
                    {"base 0x200",   0x200, 0xA00, 0, 0, c0,      0},
                    {"base 0x800",   0x800, 0xA00, 0, 0, c0,      0},
                    {"midl scroll",  0x400, 0xA00, 264, 32, c0,   0},
                    {"midl sx only", 0x400, 0xA00, 264,  0, c0,   0},
                    {"midl sy only", 0x400, 0xA00,   0, 32, c0,   0},
                };
                for (auto &h : hs) {
                    std::vector<uint16_t> w2;
                    tile_line(PROBE_Y + h.dy, h.base, h.rs, dut->rowscroll_enable != 0,
                              h.sx, h.sy, h.cor, w2);
                    size_t m = 0;
                    for (int x = 0; x < 300; x++) if (lb_fore_seen[x] == w2[x]) m++;
                    printf("  fore hyp %-12s : %zu/300\n", h.name, m);
                }
            }
            printf("fore layer profile:");
            for (int off = -2; off <= 2; off++) {
                size_t m = 0;
                for (int x = 0; x < 300; x++) { int sxx = x + off;
                    if (sxx >= 0 && sxx < 512 && lb_fore_seen[sxx] == wf[x]) m++; }
                printf(" %d:%zu", off, m);
            }
            printf("\n  rtl fore : ");
            for (int x = 0; x < 32; x++) printf("%03X ", lb_fore_seen[x]);
            printf("\n  want fore: ");
            for (int x = 0; x < 32; x++) printf("%03X ", wf[x]);
            printf("\n");
        }

        std::vector<uint16_t> want_text;
        text_line(PROBE_Y, dut->rowscroll_enable ? 0xC00 : 0x600, want_text);
        size_t tm_match = 0;
        for (int x = 0; x < 300; x++) if (lb_text_seen[x] == want_text[x]) tm_match++;
        printf("text layer line %d at offset 0: %zu/300 match\n", PROBE_Y, tm_match);
        printf("  rtl text : ");
        for (int x = 0; x < 10; x++) printf("%03X ", lb_text_seen[x]);
        printf("\n  want text: ");
        for (int x = 0; x < 10; x++) printf("%03X ", want_text[x]);
        printf("\n");
        if (best < 290) {
            printf("  rtl : ");
            for (int x = 0; x < 12; x++) printf("%03X ", lb_seen[x]);
            printf("\n  want: ");
            for (int x = 0; x < 12; x++) printf("%03X ", want_line[x]);
            printf("\n");
        }
    }

    {
        size_t nonblack = 0;
        for (auto c : got) if (c) nonblack++;
        printf("diag: sdram reads=%lld  non-black output pixels=%zu\n", sdr_count, nonblack);
    }

    // ---- compare -----------------------------------------------------------
    std::vector<uint32_t> want((size_t)W * H);
    for (size_t i = 0; i < want.size(); i++)
        want[i] = (ref[i*4] | (ref[i*4+1] << 8) | (ref[i*4+2] << 16)) & 0xFFFFFF;

    // Is the difference a pure offset? That is the signature of a pipeline
    // phase error rather than a decode bug, and it localises the fix fast.
    {
        int best_dx = 0, best_dy = 0; size_t best = 0;
        for (int dy = -4; dy <= 4; dy++)
        for (int dx = -8; dx <= 8; dx++) {
            size_t m = 0;
            for (int y = 8; y < H - 8; y++)
            for (int x = 16; x < W - 16; x++) {
                int sx = x + dx, sy = y + dy;
                if (sx < 0 || sx >= W || sy < 0 || sy >= H) continue;
                if (got[(size_t)sy * W + sx] == want[(size_t)y * W + x]) m++;
            }
            if (m > best) { best = m; best_dx = dx; best_dy = dy; }
        }
        size_t area = (size_t)(H - 16) * (W - 32);
        printf("best shift: dx=%d dy=%d  matching %zu/%zu (%.1f%%)\n",
               best_dx, best_dy, best, area, 100.0 * best / area);
    }

    size_t bad = 0;
    int first_x = -1, first_y = -1;
    for (int y = 0; y < H; y++)
        for (int x = 0; x < W; x++) {
            size_t i = (size_t)y * W + x;
            if (got[i] != want[i]) {
                if (first_x < 0) { first_x = x; first_y = y; }
                bad++;
            }
        }

    write_png((outdir + "/got.png").c_str(),  got,  W, H);
    write_png((outdir + "/want.png").c_str(), want, W, H);

    printf("pixels differing: %zu / %d  (%.2f%%)\n", bad, W * H, 100.0 * bad / (W * H));
    if (bad) {
        size_t i = (size_t)first_y * W + first_x;
        printf("first at (%d,%d): got %06X want %06X\n", first_x, first_y, got[i], want[i]);
        printf("wrote %s/got.png and %s/want.png\n", outdir.c_str(), outdir.c_str());
        return 1;
    }
    printf("PASS: frame matches MAME exactly\n");
    delete dut;
    return 0;
}
