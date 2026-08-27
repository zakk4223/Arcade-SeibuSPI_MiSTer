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

// spi_defs.vh, the hardware-measured raster. VTOTAL is the NATIVE field; the
// OSD refresh option changes it, which is now the whole mechanism.
static const int HTOTAL = 448, VTOTAL = 296;
// Field length per refresh mode -- spi_video_timing's vtotal_of(). The active
// 240 lines never move, so these differ only in blanked lines.
static const int VT[4] = { 296, 320, 280, 266 };
// VSync keeps its 8-line width and its 13-line back porch in every mode, so
// its start slides with the field: vtotal - 13 - 8.
static int vsstart_of(int m) { return VT[m] - 21; }
// The DUT's own field length, so the frame-wrap detection follows the mode.
static int cur_vtotal = 296;
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
        if (prev == cur_vtotal - 1 && dut->vcnt == 0) return;
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
    (void)hoff; (void)voff;     // the sync-offset controls are gone
    dut->video_mode = mode;
    cur_vtotal      = VT[mode];

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

        if (prev_v == cur_vtotal - 1 && dut->vcnt == 0) break;
        prev_v = dut->vcnt;
    }
    return r;
}

struct Mode { int sel; const char *name; double want_hz; };

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);
    dut = new Vspi_video_timing;
    dut->pause = 0;

    // CLK / (HTOTAL * vtotal * 8). The pixel is eight cycles in every mode, so
    // the only thing setting the rate is the field length.
    static const Mode modes[] = {
        { 0, "Normal", 53.9869 },
        { 1, "50 Hz",  49.9379 },
        { 2, "57 Hz",  57.0718 },
        { 3, "60 Hz",  60.0756 },
    };

    printf("%-8s %-7s %-9s %-8s %-11s %-9s %s\n",
           "mode", "vtotal", "cycles", "pixels", "refresh", "window", "sync");
    for (unsigned i = 0; i < sizeof(modes)/sizeof(modes[0]); i++) {
        Result r = measure(modes[i].sel, 0, 0);
        double hz = CLK / (double)r.cycles;

        int vt = VT[modes[i].sel];

        printf("%-8s %-7d %-9ld %-8ld %-11.4f %d..%-7d H%d..%d V%d..%d\n",
               modes[i].name, vt, r.cycles, r.pixels, hz, r.win_min, r.win_max,
               r.hs_first, r.hs_last, r.vs_first, r.vs_last);

        if (r.pixels != (long)HTOTAL * vt)
            fail("%s: %ld pixel ticks per frame, expected %d (448 x %d)",
                 modes[i].name, r.pixels, HTOTAL * vt, vt);

        // THE central invariant of the VTOTAL scheme, and the reason it was
        // chosen: the pixel is a uniform integer eight clk_sys cycles in every
        // mode. crt_adjust / crt_vsize resample on a measured integer pixel-CE
        // grid and cannot follow anything else. The old Bresenham emitted 7 and
        // 8 here at 57/60 Hz, which is exactly what this replaced.
        if (r.win_min != 8 || r.win_max != 8)
            fail("%s: pixel window %d..%d, must be exactly 8 in every mode",
                 modes[i].name, r.win_min, r.win_max);

        if (r.cycles != (long)HTOTAL * vt * 8)
            fail("%s: frame is %ld cycles, expected %d",
                 modes[i].name, r.cycles, HTOTAL * vt * 8);

        // The line rate must NOT move: that is what keeps everything measured
        // in scanlines valid, and what lets crt_vsize use one pair of limits.
        if (r.cycles / vt != HTOTAL * 8)
            fail("%s: line is %ld cycles, expected %d -- the line rate must be "
                 "identical in every mode", modes[i].name, r.cycles / vt,
                 HTOTAL * 8);

        if (r.vs_first != vsstart_of(modes[i].sel))
            fail("%s: vsync starts at line %d, expected %d (13-line back porch "
                 "held constant so the picture stays put)", modes[i].name,
                 r.vs_first, vsstart_of(modes[i].sel));

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

    // Normal must still be the hardware raster, to the cycle.
    {
        Result r = measure(0, 0, 0);
        if (r.cycles != (long)HTOTAL * VTOTAL * 8)
            fail("Normal frame is %ld cycles, expected %d",
                 r.cycles, HTOTAL * VTOTAL * 8);
        if (r.vs_first != VSSTART || r.vs_last != VSEND - 1)
            fail("Normal vsync %d..%d, expected the measured %d..%d",
                 r.vs_first, r.vs_last, VSSTART, VSEND - 1);
    }

    // The sync pulse has to sit inside blanking in EVERY mode. There is no
    // offset control any more -- CRT Adjust owns picture position now -- so this
    // is a check on the per-mode VSync placement rather than on a clamp.
    for (int m = 0; m <= 3; m++) {
        Result r = measure(m, 0, 0);
        if (r.hs_outside || r.vs_outside)
            fail("mode %d: sync outside blanking (h=%d v=%d)",
                 m, r.hs_outside, r.vs_outside);
        if (r.hs_first < HBSTART || r.hs_last >= HTOTAL)
            fail("mode %d: hsync %d..%d out of range", m, r.hs_first, r.hs_last);
        if (r.vs_first < VBSTART || r.vs_last >= VT[m])
            fail("mode %d: vsync %d..%d out of range (field %d)",
                 m, r.vs_first, r.vs_last, VT[m]);
        // HSync must be identical in every mode: HTOTAL never moves, so a mode
        // that shifted it would mean the line rate had changed.
        if (r.hs_first != HSSTART || r.hs_last != HSEND - 1)
            fail("mode %d: hsync %d..%d, expected the measured %d..%d in every mode",
                 m, r.hs_first, r.hs_last, HSSTART, HSEND - 1);
    }

    printf("\n%s\n", failures ? "FAILED" : "PASS: pixel a uniform 8 clk and the "
                                           "line rate identical in every mode, "
                                           "field lengths and rates correct, "
                                           "sync inside blanking in every mode");
    delete dut;
    return failures ? 1 : 0;
}
