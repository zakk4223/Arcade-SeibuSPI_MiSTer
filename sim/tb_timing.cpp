//============================================================================
//  SeibuSPI - measure the video timing generator directly.
//
//  The frame-diff bench (tb_video) proves the PICTURE is right, but it renders
//  through a fixed mode and cannot see the frame RATE at all -- a refresh
//  option that silently fell back to Normal would still pass it. This bench
//  measures the raster itself: frame period in clk_sys cycles, pixel window
//  lengths, sync widths and positions, and the analog H/V offset clamp.
//
//  The two properties that matter most here are the ones the design leans on:
//
//    * Every mode emits EXACTLY 448 x 296 pixel ticks per frame. The refresh
//      option scales the pixel window and leaves the raster alone, so nothing
//      the software can observe -- blanked lines, the vblank DMA window in
//      scanlines -- may move between modes.
//
//    * No window is ever shorter than SEVEN clk_sys cycles. Seven is the floor
//      spi_mixer's schedule reaches -- five palette reads on one port, plus the
//      two-cycle issue-to-data latency the last is latched after -- and it is
//      what bounds the mode table at 61.70 Hz. The layer renderer used to be
//      the tighter limit at eight (100% of the worst line); it now finishes a
//      worst line in 2863 cycles against the 3225 a 60 Hz line has.
//      PLAN.md 53.7 and 53.9.
//============================================================================

#include "Vspi_video_timing.h"
#include "verilated.h"

#include <cstdio>
#include <cstdlib>
#include <cstdarg>
#include <cmath>

// spi_defs.vh, the hardware-measured raster.
static const int HTOTAL = 448, VTOTAL = 296;
static const int HBSTART = 320, VBSTART = 240;
static const int HSSTART = 373, HSEND = 410;
static const int VSSTART = 275, VSEND = 283;
static const double CLK = 630e6 / 11.0;   // 57.272727 MHz

static Vspi_video_timing *dut;
static int failures = 0;

static void tick(void);

// Tick until the raster wraps into line 0, returning on that very tick.
static void to_frame_start(void)
{
    int prev = dut->vcnt;
    for (;;) {
        tick();
        if (prev == VTOTAL - 1 && dut->vcnt == 0) return;
        prev = dut->vcnt;
    }
}

static void fail(const char *fmt, ...)
{
    va_list ap; va_start(ap, fmt);
    printf("FAIL: "); vprintf(fmt, ap); printf("\n");
    va_end(ap); failures++;
}

static void tick(void) { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); }

struct Result {
    long   cycles;      // clk_sys cycles in one frame
    long   pixels;      // ce_pix pulses in one frame
    int    win_min, win_max;
    int    hs_first, hs_last;   // hcnt range over which hsync is high
    int    vs_first, vs_last;   // vcnt range over which vsync is high
    int    hs_outside;          // hsync ticks seen outside horizontal blanking
    int    vs_outside;          // vsync ticks seen outside vertical blanking
};

// Run one full frame, from the wrap into line 0 to the next one, and report.
static Result measure(int mode, int hoff, int voff)
{
    dut->video_mode = mode;
    dut->hoffset    = hoff;
    dut->voffset    = voff;

    dut->reset = 1;
    for (int i = 0; i < 16; i++) tick();
    dut->reset = 0;

    // Two settling frames: the mode and the offsets are latched at the frame
    // wrap by design, so the first frame after reset still carries defaults.
    // to_frame_start leaves the DUT on the tick that wrapped vcnt to 0, so the
    // measuring loop below counts one whole frame and not one cycle less.
    to_frame_start();
    to_frame_start();

    Result r = { 0, 0, 1 << 30, 0, 1 << 30, -1, 1 << 30, -1, 0, 0 };
    long last_tick = -1;
    int prev_v = dut->vcnt;

    for (;;) {
        tick();
        r.cycles++;

        if (dut->ce_pix) {
            r.pixels++;
            if (last_tick >= 0) {
                int win = (int)(r.cycles - last_tick);
                if (win < r.win_min) r.win_min = win;
                if (win > r.win_max) r.win_max = win;
            }
            last_tick = r.cycles;

            if (dut->hsync) {
                if (dut->hcnt < r.hs_first) r.hs_first = dut->hcnt;
                if (dut->hcnt > r.hs_last)  r.hs_last  = dut->hcnt;
                if (!dut->hblank) r.hs_outside++;
            }
            if (dut->vsync) {
                if (dut->vcnt < r.vs_first) r.vs_first = dut->vcnt;
                if (dut->vcnt > r.vs_last)  r.vs_last  = dut->vcnt;
                if (!dut->vblank) r.vs_outside++;
            }
        }

        if (prev_v == VTOTAL - 1 && dut->vcnt == 0) break;
        prev_v = dut->vcnt;
    }
    return r;
}

struct Mode { int sel; const char *name; double want_hz; int want_win_min; };

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);
    dut = new Vspi_video_timing;
    dut->pause = 0;

    static const Mode modes[] = {
        { 0, "Normal", 53.9869, 8 },
        { 1, "50 Hz",  49.9800, 8 },
        { 2, "57 Hz",  57.0447, 7 },
        { 3, "60 Hz",  59.9971, 7 },
    };

    printf("%-14s %-9s %-8s %-11s %-9s %s\n",
           "mode", "cycles", "pixels", "refresh", "window", "sync");
    for (unsigned i = 0; i < sizeof(modes)/sizeof(modes[0]); i++) {
        Result r = measure(modes[i].sel, 0, 0);
        double hz = CLK / (double)r.cycles;

        printf("%-14s %-9ld %-8ld %-11.4f %d..%-7d H%d..%d V%d..%d\n",
               modes[i].name, r.cycles, r.pixels, hz, r.win_min, r.win_max,
               r.hs_first, r.hs_last, r.vs_first, r.vs_last);

        if (r.pixels != (long)HTOTAL * VTOTAL)
            fail("%s: %ld pixel ticks per frame, expected %d -- the raster must "
                 "not change between modes", modes[i].name, r.pixels,
                 HTOTAL * VTOTAL);

        // The hard floor: spi_mixer's seven-step schedule.
        if (r.win_min < 7)
            fail("%s: window of %d cycles, under the seven spi_mixer schedules "
                 "by hand -- this drops a layer", modes[i].name, r.win_min);

        // And the per-mode shape. A Bresenham averaging between N and N+1 emits
        // only N and N+1, so the minimum is the mode's floor.
        if (r.win_min != modes[i].want_win_min)
            fail("%s: shortest window %d, expected %d", modes[i].name,
                 r.win_min, modes[i].want_win_min);

        if (fabs(hz - modes[i].want_hz) / modes[i].want_hz > 0.001)
            fail("%s: %.4f Hz, expected %.4f", modes[i].name, hz, modes[i].want_hz);

        if (r.hs_last - r.hs_first + 1 != HSEND - HSSTART)
            fail("%s: hsync %d px wide, expected %d (measured on hardware)",
                 modes[i].name, r.hs_last - r.hs_first + 1, HSEND - HSSTART);
        if (r.vs_last - r.vs_first + 1 != VSEND - VSSTART)
            fail("%s: vsync %d lines wide, expected %d (measured on hardware)",
                 modes[i].name, r.vs_last - r.vs_first + 1, VSEND - VSSTART);

        if (r.hs_outside || r.vs_outside)
            fail("%s: sync outside blanking (h=%d v=%d)",
                 modes[i].name, r.hs_outside, r.vs_outside);
    }

    // Normal must be bit-exact against the fixed /8 divider it replaced.
    {
        Result r = measure(0, 0, 0);
        if (r.win_min != 8 || r.win_max != 8)
            fail("Normal window is %d..%d, must be exactly 8 -- n/m is 512/4096 "
                 "and has to stay exact", r.win_min, r.win_max);
        if (r.cycles != (long)HTOTAL * VTOTAL * 8)
            fail("Normal frame is %ld cycles, expected %d",
                 r.cycles, HTOTAL * VTOTAL * 8);
    }

    // Analog sync position. The 4-bit field is two's complement and shifts the
    // sync pulse; the OSD label shows the negated value because moving sync
    // later moves the picture left/up.
    printf("\n%-6s %-6s %-12s %-12s %s\n", "hoff", "voff", "hsync", "vsync", "note");
    static const int offs[] = { 0, 1, 7, 8, 9, 15 };
    for (unsigned i = 0; i < sizeof(offs)/sizeof(offs[0]); i++) {
        int raw = offs[i];
        int sgn = (raw & 8) ? raw - 16 : raw;
        Result r = measure(0, raw, raw);

        printf("%-6d %-6d %d..%-8d %d..%-8d shift %+d\n",
               raw, raw, r.hs_first, r.hs_last, r.vs_first, r.vs_last, sgn);

        int want_h = HSSTART + sgn, want_v = VSSTART + sgn;
        if (want_h < HBSTART)            want_h = HBSTART;
        if (want_h > HTOTAL - (HSEND - HSSTART)) want_h = HTOTAL - (HSEND - HSSTART);
        if (want_v < VBSTART)            want_v = VBSTART;
        if (want_v > VTOTAL - (VSEND - VSSTART)) want_v = VTOTAL - (VSEND - VSSTART);

        if (r.hs_first != want_h) fail("hoffset %d: hsync starts %d, expected %d", raw, r.hs_first, want_h);
        if (r.vs_first != want_v) fail("voffset %d: vsync starts %d, expected %d", raw, r.vs_first, want_v);
        if (r.hs_outside || r.vs_outside)
            fail("offset %d pushed sync outside blanking (h=%d v=%d)",
                 raw, r.hs_outside, r.vs_outside);
        if (r.pixels != (long)HTOTAL * VTOTAL)
            fail("offset %d changed the raster (%ld pixels)", raw, r.pixels);
    }

    // The clamp has to hold at the extremes of the field in the tightest mode
    // the table offers, not just at Normal.
    for (int m = 0; m <= 3; m++)
        for (int raw = 0; raw < 16; raw++) {
            Result r = measure(m, raw, raw);
            if (r.hs_outside || r.vs_outside)
                fail("mode %d offset %d: sync escaped blanking", m, raw);
            if (r.hs_first < HBSTART || r.hs_last >= HTOTAL)
                fail("mode %d offset %d: hsync %d..%d out of range", m, raw, r.hs_first, r.hs_last);
            if (r.vs_first < VBSTART || r.vs_last >= VTOTAL)
                fail("mode %d offset %d: vsync %d..%d out of range", m, raw, r.vs_first, r.vs_last);
        }

    printf("\n%s\n", failures ? "FAILED" : "PASS: raster identical across modes, "
                                           "rates correct, sync clamped inside blanking");
    delete dut;
    return failures ? 1 : 0;
}
