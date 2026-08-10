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
#include <set>
#include <map>
#include <array>
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

// regs.txt's one non-numeric field. The capture names the set it came from so
// this bench cannot be pointed at an rdft2 capture with rdfts's keys.
static std::string load_game(const std::string &p)
{
    FILE *f = fopen(p.c_str(), "r");
    if (!f) return "";
    char line[256], name[64];
    std::string game;
    while (fgets(line, sizeof line, f))
        if (sscanf(line, "game %63s", name) == 1) game = name;
    fclose(f);
    return game;
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
    std::string game = load_game(cap + "/regs.txt");
    if (game.empty()) {
        game = "rdfts";
        printf("note: capture has no `game` line, assuming rdfts\n");
    }
    auto tm     = load(cap + "/tilemap_ram.bin", 0x4000);
    auto pal    = load(cap + "/palette_ram.bin", 0x3000);
    auto ref    = load(cap + "/frame.bin", (size_t)W * H * 4);
    auto sdram  = load(sdrpath);

    Vtb_video_top *dut = new Vtb_video_top;

    // Per-set configuration. rdft2 is the only set here that is not SEI252 at
    // 6 MB of tiles and 4 MB sprite chunks; see rtl/spi_defs.vh.
    const bool is_rdft2 = (game == "rdft2");
    dut->bg_fore_pos      = is_rdft2 ? 0x8000 : 0x4000;
    dut->tkey1            = is_rdft2 ? 0x823146 : 0x5A3845;
    dut->tkey2            = is_rdft2 ? 0x4DE2F8 : 0x77CF5B;
    dut->tkey3            = is_rdft2 ? 0x157ADC : 0x1378DF;
    dut->spr_chunk_stride = is_rdft2 ? 0x600000 : 0x400000;
    dut->rise10           = is_rdft2;
    printf("set: %s  (fore_base %04X, keys %06X/%06X/%06X, chunk %06X, %s)\n",
           game.c_str(), (unsigned)dut->bg_fore_pos, (unsigned)dut->tkey1,
           (unsigned)dut->tkey2, (unsigned)dut->tkey3,
           (unsigned)dut->spr_chunk_stride, is_rdft2 ? "RISE10" : "SEI252");

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

    // ---- SDRAM model -------------------------------------------------------
    // The graphics and sprite engines share ONE SDRAM bus in the real core:
    // sdram.sv serves a single transaction at a time from STATE_IDLE, with ch2
    // (gfx) ahead of ch4 (sprites). Modelling them as independent servers -- as
    // this testbench used to -- gives the video path unlimited bandwidth and
    // hides every contention failure. The attract scene with the yellow plane
    // renders perfectly here and badly on hardware for exactly that reason.
    //
    // A transaction occupies the bus for about 12 clk_ram cycles (ACTIVE, CAS,
    // a 4-beat burst and turnaround). clk_ram is twice clk_sys, which is the
    // clock this testbench runs at, so that is ~6 cycles here. SLOP_BUS_FREE=1
    // restores the old unlimited behaviour for comparison.
    const bool bus_free = getenv("SLOP_BUS_FREE") != nullptr;
    const int  BUS_OCC  = 6;

    uint64_t sdr_data  = 0, spr_data64 = 0;
    uint8_t  sdr_req_d = 0, spr_req_d = 0;
    bool     sdr_pend  = false, spr_pend = false;
    int      bus_busy  = 0;
    int      bus_owner = 0;          // 1 = gfx, 2 = sprite
    long long sdr_count = 0, spr_stall = 0, gfx_stall = 0;

    auto fetch64 = [&](uint32_t addr) -> uint64_t {
        uint64_t a = addr & ~7u, v = 0;
        for (int i = 0; i < 8; i++)
            if (a + i < sdram.size()) v |= (uint64_t)sdram[a + i] << (8 * i);
        return v;
    };

    auto tick = [&]() {
        // latch new requests
        if (dut->sdr_req     != sdr_req_d) { sdr_req_d = dut->sdr_req; sdr_pend = true; sdr_count++; }
        if (dut->spr_sdr_req != spr_req_d) { spr_req_d = dut->spr_sdr_req; spr_pend = true; }

        if (bus_free) {
            if (sdr_pend) { sdr_data   = fetch64(dut->sdr_addr);     dut->sdr_ack     = sdr_req_d; sdr_pend = false; }
            if (spr_pend) { spr_data64 = fetch64(dut->spr_sdr_addr); dut->spr_sdr_ack = spr_req_d; spr_pend = false; }
        }
        else {
            if (bus_busy > 0) {
                if (--bus_busy == 0) {
                    if (bus_owner == 1) { sdr_data   = fetch64(dut->sdr_addr);     dut->sdr_ack     = sdr_req_d; sdr_pend = false; }
                    else                { spr_data64 = fetch64(dut->spr_sdr_addr); dut->spr_sdr_ack = spr_req_d; spr_pend = false; }
                    bus_owner = 0;
                }
            }
            else if (sdr_pend) { bus_owner = 1; bus_busy = BUS_OCC; }
            else if (spr_pend) { bus_owner = 2; bus_busy = BUS_OCC; }
            if (sdr_pend && bus_owner != 1) gfx_stall++;
            if (spr_pend && bus_owner != 2) spr_stall++;
        }

        dut->sdr_dout     = sdr_data;
        dut->spr_sdr_dout = spr_data64;
        dut->clk = 0; dut->eval();
        dut->clk = 1; dut->eval();
    };

    // ---- reset and preload -------------------------------------------------
    dut->reset = 1;
    dut->pre_tm_we = dut->pre_pal_we = dut->pre_spr_we = 0;
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

    {
        auto spr = load(cap + "/sprite_ram.bin", 0x1000);
        for (int i = 0; i < 1024; i++) {
            dut->pre_spr_addr = i;
            dut->pre_spr_data = spr[i*4] | (spr[i*4+1] << 8) | (spr[i*4+2] << 16) | ((uint32_t)spr[i*4+3] << 24);
            dut->pre_spr_we   = 1;
            tick();
        }
        dut->pre_spr_we = 0;
    }

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

    // Overridable, because a conclusion drawn from one scanline is worth very
    // little here: a layer that happens to be uniform on the probed row ties at
    // every offset and will happily fake a one-pixel shift.
    const int PROBE_Y = getenv("SLOP_PROBE_Y") ? atoi(getenv("SLOP_PROBE_Y")) : 112;
    std::vector<uint16_t> lb_seen(512, 0xFFFF);
    std::vector<uint16_t> lb_text_seen(512, 0xFFFF);
    std::vector<uint16_t> lb_fore_seen(512, 0xFFFF);
    std::vector<uint16_t> lb_midl_seen(512, 0xFFFF);
    std::vector<std::pair<uint32_t,uint32_t>> fore_codes;
    std::vector<uint32_t> rtl_rgb(512, 0);
    std::vector<std::pair<int,int>> bank_flips;   // (vcnt, hcnt) of each render-bank flip
    std::pair<int,int> seen_rs[4] = {{-1,-1},{-1,-1},{-1,-1},{-1,-1}};
    int latch_fx[4][3] = {}, latch_col[4][3] = {}, latch_n[4] = {};
    int emit_lo[4] = {9999,9999,9999,9999}, emit_hi[4] = {-9999,-9999,-9999,-9999};
    long emit_cnt[4] = {};
    std::vector<std::array<int,4>> fore_emits;
    std::vector<std::array<int,8>> spr_emits;   // code,x,pix,sx,sy,tile,ry,px
    long line_cycles = 0, busy_cycles = 0; int max_layer = 0; bool finished = false;
    long spr_writes = 0, spr_state_hist[16] = {0}; int spr_min_index = 9999;
    bool probed = false;

    while (frame < 3) {
        tick();
        if (++guard > 40000000LL) { printf("FAIL: timeout\n"); return 1; }

        // Record the back-layer line buffer across one scanline of frame 2.
        if (frame == 2 && dut->vcnt == PROBE_Y - 1) {
            if (dut->dbg_spr_we) spr_writes++;
            if (dut->dbg_spr_state == 9 && spr_emits.size() < 2000) {   // S_EMIT
                int ex = (int)dut->dbg_spr_emitx; if (ex > 1023) ex -= 2048;
                spr_emits.push_back({(int)dut->dbg_spr_code, ex, (int)dut->dbg_spr_pix,
                                     (int)dut->dbg_spr_sx, (int)dut->dbg_spr_sy,
                                     (int)dut->dbg_spr_tile, (int)dut->dbg_spr_ry,
                                     (int)dut->dbg_spr_px});
            }
            spr_state_hist[dut->dbg_spr_state]++;
            if (dut->dbg_spr_index < spr_min_index) spr_min_index = dut->dbg_spr_index;
        }

        // How long does the renderer take per line, and does it finish?
        if (frame == 2 && dut->vcnt == PROBE_Y - 1) {
            line_cycles++;
            if (dut->dbg_busy) busy_cycles++;
            if (!dut->dbg_busy && busy_cycles) finished = true;
            if (dut->dbg_layer > max_layer) max_layer = dut->dbg_layer;
        }

        // Exact per-emit record for the fore layer: which tile, which pixel
        // index within it, and which screen x it lands on.
        if (frame == 2 && dut->vcnt == PROBE_Y - 1 && dut->dbg_emit
            && dut->dbg_layer == 2 && fore_emits.size() < 34) {
            int ex = (int)dut->dbg_emitx; if (ex > 1023) ex -= 2048;
            fore_emits.push_back({ex, (int)dut->dbg_emiti,
                                  (int)dut->dbg_tcode, (int)dut->dbg_pix});
        }

        // Range of screen x each layer actually emits to.
        if (frame == 2 && dut->vcnt == PROBE_Y - 1 && dut->dbg_emit) {
            int L = dut->dbg_layer;
            int ex = (int)dut->dbg_emitx;
            if (ex > 1023) ex -= 2048;          // sign extend 11 bits
            if (ex < emit_lo[L]) emit_lo[L] = ex;
            if (ex > emit_hi[L]) emit_hi[L] = ex;
            emit_cnt[L]++;
        }

        // Sample fine_x / col at the exact cycle emit_x is latched.
        if (frame == 2 && dut->vcnt == PROBE_Y - 1 && dut->dbg_latch) {
            int L = dut->dbg_layer;
            if (latch_n[L] < 3) {
                latch_fx[L][latch_n[L]] = dut->dbg_finex;
                latch_col[L][latch_n[L]] = dut->dbg_col;
                latch_n[L]++;
            }
        }

        // When does the render bank flip, relative to the display line?
        // spi_layers defers it to a tile boundary, so it lands at hcnt 0, 1 or
        // 2 and jitters per line. That used to decide which buffer the mixer
        // read, and was the whole left-edge error band; the read bank now comes
        // from vcnt[0] instead, so this jitter is expected and harmless. Kept
        // because it is the measurement that identified the fault.
        {
            static int prev_bank = -1;
            if (frame == 2 && prev_bank >= 0 && (int)dut->dbg_lb_bank != prev_bank
                && bank_flips.size() < 12)
                bank_flips.push_back({(int)dut->vcnt, (int)dut->hcnt});
            prev_bank = dut->dbg_lb_bank;
        }

        // What rowscroll / x_start does each layer actually use?
        if (frame == 2 && dut->vcnt == PROBE_Y - 1 && dut->dbg_emit)
            seen_rs[dut->dbg_layer] = {dut->dbg_rowscroll, dut->dbg_xstart};

        // Record the tile codes the fore layer actually fetches.
        if (frame == 2 && dut->vcnt == PROBE_Y - 1 && dut->dbg_emit && dut->dbg_layer == 2) {
            if (fore_codes.empty() || fore_codes.back().first != dut->dbg_tcode)
                fore_codes.push_back({dut->dbg_tcode, dut->dbg_gfx_addr});
        }
        if (frame == 2 && dut->vcnt == PROBE_Y && dut->ce_pix && dut->hcnt < 512) {
            lb_seen[dut->hcnt] = dut->dbg_back;
            lb_text_seen[dut->hcnt] = dut->dbg_text;
            lb_fore_seen[dut->hcnt] = dut->dbg_fore;
            lb_midl_seen[dut->hcnt] = dut->dbg_midl;
            rtl_rgb[dut->hcnt] = ((uint32_t)dut->red << 16) |
                                 ((uint32_t)dut->green << 8) | dut->blue;
            probed = true;
            if (dut->hcnt < 10) {
                uint32_t w = (ref[((size_t)PROBE_Y*W + dut->hcnt)*4]
                            | (ref[((size_t)PROBE_Y*W + dut->hcnt)*4+1] << 8)
                            | (ref[((size_t)PROBE_Y*W + dut->hcnt)*4+2] << 16)) & 0xFFFFFF;
                printf("  x=%2d  b=%03X m=%03X f=%03X t=%03X  out=%06X want=%06X %s\n",
                       (int)dut->hcnt, (int)dut->dbg_back, (int)dut->dbg_midl,
                       (int)dut->dbg_fore, (int)dut->dbg_text,
                       ((uint32_t)dut->red << 16) | ((uint32_t)dut->green << 8) | dut->blue, w,
                       ((((uint32_t)dut->red<<16)|((uint32_t)dut->green<<8)|dut->blue)==w)?"":"<<");
            }
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
                const uint16_t *caps[3] = { lb_seen.data(), lb_midl_seen.data(), lb_fore_seen.data() };
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

                // Offset profile for EVERY layer against its own reference, plus
                // a count of how much content the line actually has. A layer that
                // is uniform across the line ties at every offset, so its
                // "best offset" means nothing -- that is exactly how the fore
                // layer once faked a one-pixel bug. Only compare best offsets
                // between layers that are non-uniform here.
                for (int c = 0; c < 3; c++) {
                    if (!caps[c]) continue;
                    std::set<uint16_t> distinct;
                    for (int x = 0; x < 300; x++) distinct.insert((*refs[c])[x]);
                    printf("  %s profile (ref has %zu distinct values):", rn[c], distinct.size());
                    int bo = 0; size_t bm = 0;
                    for (int off = -3; off <= 3; off++) {
                        size_t m = 0;
                        for (int x = 0; x < 300; x++) {
                            int sx = x + off;
                            if (sx < 0 || sx >= 512) continue;
                            if (caps[c][sx] == (*refs[c])[x]) m++;
                        }
                        printf(" %d:%zu", off, m);
                        if (m > bm) { bm = m; bo = off; }
                    }
                    printf("   best %d (%zu/300)%s\n", bo, bm,
                           distinct.size() < 2 ? "  [UNIFORM - offset meaningless]" : "");
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
            for (int L = 0; L < 4; L++) {
                printf("  layer %d: rowscroll=%d x_start=%d  at emit_x latch:", L,
                       (int16_t)seen_rs[L].first, seen_rs[L].second);
                printf(" emit_x %d..%d over %ld cycles", emit_lo[L], emit_hi[L], emit_cnt[L]);
                printf("\n");
            }
            
    // ---- sprite pixel reference ------------------------------------------
    // Decode the same tile row straight out of the sprite ROM using MAME's own
    // decryptor, and compare against what the RTL emitted. This is the only
    // check that covers the sprite graphics path end to end: tb_spr_decrypt
    // proves the decrypt unit alone, and the frame diff cannot say whether a
    // wrong pixel came from the fetch, the decrypt or the plane assembly.
    //
    // MAME's spi_spritelayout: 16x16, 6bpp, RGN_FRAC(1,3) so each 4 MB chunk
    // carries two planes; planeoffset {0,8, F+0,F+8, 2F+0,2F+8} MSB first,
    // xoffset STEP8(7,-1) then STEP8(8*2+7,-1), yoffset STEP16(0,8*4),
    // 16*32 bits per tile per chunk.
    static std::vector<uint8_t> sprrom;
    const size_t SPR_CHUNK = is_rdft2 ? 0x600000 : 0x400000;
    if (sprrom.empty()) {
        // SDR_SPRITES_BASE in rtl/spi_defs.vh. This said 0x0A80000 until now,
        // which is where the sprites lived before the map was re-laid for the
        // 26-bit widening -- so this whole check has been comparing against
        // tile data for a while and reporting mismatches nobody read.
        const size_t SPR_BASE = 0x1100000;
        sprrom.assign(sdram.begin() + SPR_BASE,
                      sdram.begin() + SPR_BASE + 3 * SPR_CHUNK);
        if (is_rdft2) {
            // The SDRAM image is ALREADY sprite_reorder()ed -- rom_loader does
            // it at load time (M_SPR_R10). MAME's decryptor reorders at the
            // end, so undo ours first and let MAME's put it back; otherwise the
            // permutation is applied twice. The inverse here is the same
            // formula tb_rom_loader.cpp checks against MAME's sprite_reorder.
            std::vector<uint8_t> tmp(sprrom.size());
            for (size_t i = 0; i < sprrom.size(); i++) {
                size_t j = (i & ~(size_t)0x3F) | ((i & 0x1E) << 1)
                                               | ((i & 0x20) >> 4) | (i & 1);
                tmp[i] = sprrom[j];
            }
            sprrom.swap(tmp);
            seibuspi_rise10_sprite_decrypt(sprrom.data(), (int)SPR_CHUNK);
        } else {
            seibuspi_sprite_decrypt(sprrom.data(), (int)SPR_CHUNK);
        }
    }
    auto ref_spr_pix = [&](uint32_t tile, int row, int px) -> int {
        auto rb = [&](int chunk, uint32_t bit) -> int {
            uint32_t byteidx = (uint32_t)chunk * (uint32_t)SPR_CHUNK + (bit >> 3);
            return (sprrom[byteidx] >> (7 - (bit & 7))) & 1;
        };
        uint32_t base = tile * 512u + (uint32_t)row * 32u;
        uint32_t xoff = (px < 8) ? (uint32_t)(7 - px) : (uint32_t)(23 - (px - 8));
        int pen = 0;
        pen |= rb(0, base + xoff + 0) << 5;
        pen |= rb(0, base + xoff + 8) << 4;
        pen |= rb(1, base + xoff + 0) << 3;
        pen |= rb(1, base + xoff + 8) << 2;
        pen |= rb(2, base + xoff + 0) << 1;
        pen |= rb(2, base + xoff + 8) << 0;
        return pen;
    };
    {
        size_t good = 0, bad = 0;
        for (size_t k = 0; k < spr_emits.size(); k++) {
            const auto &e = spr_emits[k];
            int want = ref_spr_pix((uint32_t)e[5], e[6], e[7]);
            if (want == e[2]) good++;
            else {
                if (bad < 8)
                    printf("  SPR PIX MISMATCH tile=%04X row=%2d px=%2d  rtl=%02X ref=%02X\n",
                           e[5], e[6], e[7], e[2], want);
                bad++;
            }
        }
        printf("  sprite pixel check: %zu match, %zu differ (of %zu emits)\n",
               good, bad, spr_emits.size());
    }

    printf("  sprite emits (code, emit_x, pix, sx, sy):\n   ");
            for (size_t i = 0; i < spr_emits.size() && i < 24; i++) {
                printf("(%04X,%d,%02X,%d,%d) ", spr_emits[i][0], spr_emits[i][1],
                       spr_emits[i][2], spr_emits[i][3], spr_emits[i][4]);
                if ((i % 4) == 3) printf("\n   ");
            }
            printf("\n");
            printf("  sprite: %ld pixel writes, min index %d, state hist:",
                   spr_writes, spr_min_index);
            for (int i = 0; i < 13; i++) if (spr_state_hist[i]) printf(" s%d:%ld", i, spr_state_hist[i]);
            printf("\n");
            printf("  line budget: %ld cycles available, renderer busy %ld, "
                   "max layer reached %d, finished=%s\n",
                   line_cycles, busy_cycles, max_layer, finished ? "yes" : "NO");

            {   // Per-tile mapping: RTL emit vs reference pixel at that screen x
                std::vector<uint16_t> wf0;
                uint32_t cor = 0x4000 | (regs["fore_d13"].at(0) ? 0x2000u : 0u);
                tile_line(PROBE_Y, dut->rowscroll_enable ? 0x400 : 0x200, 0xA00,
                          dut->rowscroll_enable != 0,
                          regs["scroll_fore"].at(0) & 511,
                          regs["scroll_fore"].at(1) & 511, cor, wf0);
                printf("  fore per-emit (x, emit_i, code, rtl_pix | ref_pix@x ref_pix@x+1):\n   ");
                for (size_t i = 0; i < fore_emits.size() && i < 20; i++) {
                    auto &e = fore_emits[i];
                    int rx = e[0];
                    int r0 = (rx >= 0 && rx < 320) ? (wf0[rx] & 63) : -1;
                    int r1 = (rx+1 >= 0 && rx+1 < 320) ? (wf0[rx+1] & 63) : -1;
                    printf("(%d,i%d,%04X,%02X|%02X,%02X) ", e[0], e[1], e[2], e[3], r0, r1);
                    if ((i % 5) == 4) printf("\n   ");
                }
                printf("\n");
            }

            {   // What codes does the RTL fetch, versus what the reference expects?
                printf("  rtl fore codes :");
                for (size_t i = 0; i < fore_codes.size() && i < 8; i++)
                    printf(" %04X@%06X", fore_codes[i].first, fore_codes[i].second);
                printf("\n  ref fore codes :");
                uint32_t cor = 0x4000 | (regs["fore_d13"].at(0) ? 0x2000u : 0u);
                int syy = regs["scroll_fore"].at(1) & 511;
                int sxx = regs["scroll_fore"].at(0) & 511;
                int src_y = (PROBE_Y + syy) & 511, rw = src_y >> 4, fy = src_y & 15;
                for (int c = 0; c < 8; c++) {
                    int colm = ((sxx >> 4) + c) & 31;
                    int ti = colm * 32 + rw;
                    size_t d = (size_t)((dut->rowscroll_enable ? 0x400 : 0x200) + (ti >> 1)) * 4;
                    uint32_t dw = tm[d] | (tm[d+1] << 8) | (tm[d+2] << 16) | ((uint32_t)tm[d+3] << 24);
                    uint16_t w = (ti & 1) ? (dw >> 16) : (dw & 0xFFFF);
                    uint32_t code = (w & 0x1FFF) | cor;
                    printf(" %04X@%06X", code, 0x0480000 + code * 192 + fy * 12);
                }
                printf("\n");
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
                    {"sx+1",         0x400, 0xA00,   1,  0, c0,   0},
                    {"sx-1",         0x400, 0xA00, 511,  0, c0,   0},
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
        // CAUTION: the per-layer reference models below (text_line, back_line,
        // fore_line) are skewed one pixel relative to MAME's real output. Making
        // the RTL match them exactly makes the FRAME comparison worse -- text
        // goes 300/300 here but the frame goes 6.3% -> 14.5%. The frame diff
        // against MAME's captured bitmap is the ground truth; treat these layer
        // scores as a rough guide to which layer is involved, never as proof of
        // alignment.
        printf("text layer line %d at offset 0: %zu/300 match"
               " (reference is +1 skewed, see note)\n", PROBE_Y, tm_match);
        {   // Which pixel within each 8-wide character cell goes wrong? A spike
            // at one position means the emit indexing is off, not the decode.
            int bym[8] = {0};
            int shown = 0;
            for (int x = 0; x < 300; x++) {
                if (lb_text_seen[x] == want_text[x]) continue;
                bym[x & 7]++;
                if (shown < 6) {
                    printf("    text x=%3d (x%%8=%d) rtl=%03X want=%03X\n",
                           x, x & 7, lb_text_seen[x], want_text[x]);
                    shown++;
                }
            }
            printf("    text mismatches by x%%8:");
            for (int i = 0; i < 8; i++) printf(" %d:%d", i, bym[i]);
            printf("\n");
        }
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
        printf("sprite budget: %u lines ended with sprites unscanned (starved),"
           " %u scanned, %u y-hits\n",
           (unsigned)dut->dbg_spr_starved, (unsigned)dut->dbg_spr_scanned_o,
           (unsigned)dut->dbg_spr_yhit_o);
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

    if (probed) {
        // Pure mixer check: composite the RTL's own line buffers per MAME's
        // order and compare against the RTL's RGB for the same line. Inputs are
        // already verified, so any mismatch here is the mixer's alone.
        auto pen_rgb = [&](int pen) {
            size_t e = (size_t)(pen >> 1) * 4;
            uint32_t dw = pal[e] | (pal[e+1] << 8) | (pal[e+2] << 16) | ((uint32_t)pal[e+3] << 24);
            uint32_t v = (pen & 1) ? ((dw >> 16) & 0x7FFF) : (dw & 0x7FFF);
            uint32_t r = v & 31, g = (v >> 5) & 31, b = (v >> 10) & 31;
            return (uint32_t)((((r<<3)|(r>>2)) << 16) | (((g<<3)|(g>>2)) << 8) | ((b<<3)|(b>>2)));
        };
        int le = regs["layer_enable"].at(0);
        bool eb = !(le & 1), em = !(le & 2), ef = !(le & 4), et = !(le & 8);
        size_t bad = 0; int firstx = -1;
        for (int x = 2; x < 300; x++) {
            uint16_t B = lb_seen[x], M = lb_midl_seen[x], F = lb_fore_seen[x], T = lb_text_seen[x];
            uint32_t c = eb ? pen_rgb(4096 + ((B >> 6) << 6) + (B & 63)) : pen_rgb(0);
            if (em && (M & 63) != 63) c = pen_rgb(4096 + 1024 + ((M >> 6) << 6) + (M & 63));
            if (ef && (F & 63) != 63) c = pen_rgb(4096 +  512 + ((F >> 6) << 6) + (F & 63));
            if (et && (T & 31) != 31) c = pen_rgb(5632 + ((T >> 6) << 5) + (T & 31));
            if (c != rtl_rgb[x + 1]) { if (firstx < 0) firstx = x; bad++; }
        }
        printf("MIXER-ONLY check line %d: %zu/298 pixels differ", PROBE_Y, bad);
        if (bad) printf(", first at x=%d (rtl %06X want %06X)", firstx, rtl_rgb[firstx], 0u);
        printf("\n");
    }

    {   // First mismatches on the probe row, with the layer data behind them.
        printf("  first mismatches on row %d (layer values use the +1 readback offset):\n", PROBE_Y);
        int shown = 0;
        for (int x = 2; x < W && shown < 6; x++) {
            size_t i = (size_t)PROBE_Y*W + x;
            if (got[i] == want[i]) continue;
            int j = x - 1;                        // readback offset
            printf("    x=%3d got=%06X want=%06X  b=%03X m=%03X f=%03X t=%03X\n",
                   x, got[i], want[i],
                   j >= 0 ? lb_seen[j] : 0, j >= 0 ? lb_midl_seen[j] : 0,
                   j >= 0 ? lb_fore_seen[j] : 0, j >= 0 ? lb_text_seen[j] : 0);
            shown++;
        }
    }

    {   // Are the mismatches simply the sprites we do not draw yet? Sprite pens
        // are 0..4095; every tile layer pen is 4096 or above.
        // Counted over REAL mismatches only. Including the +-1 blend pixels
        // dilutes this to the point of meaninglessness -- they are four fifths
        // of the raw set and have nothing to do with sprites.
        size_t spr_like = 0, other = 0;
        for (int y = 0; y < H; y++) for (int x = 2; x < W; x++) {
            size_t i = (size_t)y*W+x;
            if (got[i] == want[i]) continue;
            int dr = int((got[i] >> 16) & 0xFF) - int((want[i] >> 16) & 0xFF);
            int dg = int((got[i] >>  8) & 0xFF) - int((want[i] >>  8) & 0xFF);
            int db = int( got[i]        & 0xFF) - int( want[i]        & 0xFF);
            if (dr >= -1 && dr <= 1 && dg >= -1 && dg <= 1 && db >= -1 && db <= 1)
                continue;
            bool found = false;
            for (int pen = 0; pen < 4096 && !found; pen++) {
                size_t e = (size_t)(pen >> 1) * 4;
                uint32_t dw = pal[e] | (pal[e+1] << 8) | (pal[e+2] << 16) | ((uint32_t)pal[e+3] << 24);
                uint32_t v = (pen & 1) ? ((dw >> 16) & 0x7FFF) : (dw & 0x7FFF);
                uint32_t r = v & 31, g = (v >> 5) & 31, b = (v >> 10) & 31;
                uint32_t c = (((r<<3)|(r>>2)) << 16) | (((g<<3)|(g>>2)) << 8) | ((b<<3)|(b>>2));
                if (c == want[i]) found = true;
            }
            if (found) spr_like++; else other++;
        }
        printf("REAL mismatches (x>=2): %zu match a sprite pen, %zu do not\n", spr_like, other);
    }

    {   // Where does the render bank flip? It should land exactly on the line
        // boundary the mixer reads across; anything later means the first
        // pixels of a line are composited from the wrong buffer.
        printf("render-bank flips at (vcnt,hcnt): ");
        for (auto &p : bank_flips) printf("(%d,%d) ", p.first, p.second);
        printf("\n");
    }

    {   // Where are the errors? Counted over REAL mismatches: a raw histogram
        // is dominated by whatever per-pixel rounding noise happens to exist
        // and hides a localised fault completely. That is how a band confined
        // to four columns sat unnoticed under the old 50/50 blend.
        auto real_bad = [&](size_t i) {
            if (got[i] == want[i]) return false;
            int dr = int((got[i] >> 16) & 0xFF) - int((want[i] >> 16) & 0xFF);
            int dg = int((got[i] >>  8) & 0xFF) - int((want[i] >>  8) & 0xFF);
            int db = int( got[i]        & 0xFF) - int( want[i]        & 0xFF);
            return !(dr >= -1 && dr <= 1 && dg >= -1 && dg <= 1 && db >= -1 && db <= 1);
        };
        int rowbad[H] = {0}, colbad[W] = {0};
        for (int y = 0; y < H; y++) for (int x = 0; x < W; x++)
            if (real_bad((size_t)y*W+x)) { rowbad[y]++; colbad[x]++; }
        printf("rows with errors (every 8th): ");
        for (int y = 0; y < H; y += 8) printf("%d:%d ", y, rowbad[y]);
        printf("\n");
        int full = 0, clean = 0;
        for (int y = 0; y < H; y++) { if (rowbad[y] >= W-4) full++; if (rowbad[y] <= 4) clean++; }
        printf("rows almost entirely wrong: %d, rows almost clean: %d\n", full, clean);
        printf("cols 0..11 errors: ");
        for (int x = 0; x < 12; x++) printf("%d ", colbad[x]);
        printf("\n");
    }

    write_png((outdir + "/got.png").c_str(),  got,  W, H);
    write_png((outdir + "/want.png").c_str(), want, W, H);

    {   // The mixer used to average where MAME does a 127/129 alpha blend,
        // which put ~26k pixels one unit out per channel and buried every real
        // fault. It does the exact blend now, so this bucket MUST read zero --
        // if it does not, the blend arithmetic has regressed, and that is a
        // different failure from the mismatches counted below.
        size_t near = 0;
        for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) {
            size_t i = (size_t)y*W+x;
            if (got[i] == want[i]) continue;
            int dr = int((got[i] >> 16) & 0xFF) - int((want[i] >> 16) & 0xFF);
            int dg = int((got[i] >>  8) & 0xFF) - int((want[i] >>  8) & 0xFF);
            int db = int( got[i]        & 0xFF) - int( want[i]        & 0xFF);
            if (dr >= -1 && dr <= 1 && dg >= -1 && dg <= 1 && db >= -1 && db <= 1)
                near++;
        }
        printf("pixels differing: %zu / %d  (%.2f%%)\n",
               bad, W * H, 100.0 * bad / (W * H));
        printf("of those, %zu are within +-1 per channel -- MUST be 0 now the"
               " blend is exact; anything here is a blend regression\n", near);
        printf("REAL mismatches: %zu / %d  (%.2f%%)\n",
               bad - near, W * H, 100.0 * (bad - near) / (W * H));
    }
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
