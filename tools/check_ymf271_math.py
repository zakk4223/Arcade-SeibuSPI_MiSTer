#!/usr/bin/env python3
"""
Check the integer forms the YMF271 RTL uses against MAME's floating-point
arithmetic, exhaustively.

ymf271_pcm.sv rewrites calculate_step() as one multiply and a signed shift, on
the grounds that every factor MAME expresses as a double is a power of two or a
half integer. That is an algebra claim, and a wrong shift would come out as a
whole voice at the wrong pitch -- audible but very hard to attribute. This
sweeps all 2^19 combinations of (fns, block, fs, multiple) and compares.

It also re-derives the envelope step tables from ARTime/DCTime and checks that
the generated .vh agrees.

    tools/check_ymf271_math.py [path/to/mame]
"""

import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_ymf271_tables as gen   # noqa: E402

POW_TABLE = [128, 256, 512, 1024, 2048, 4096, 8192, 16384,
             0.5, 1, 2, 4, 8, 16, 32, 64]
MULTIPLE_TABLE = [0.5] + list(range(1, 16))
FS_FREQUENCY = [1.0, 1.0 / 2.0, 1.0 / 4.0, 1.0 / 8.0]


def mame_step(fns, block, fs, multiple):
    """calculate_step(), external waveform branch, verbatim."""
    st = float(2 * (fns | 2048)) * POW_TABLE[block] * FS_FREQUENCY[fs]
    st = st * MULTIPLE_TABLE[multiple]
    st = st / float(524288 // 65536)
    return int(st)          # (uint32_t) truncation


def rtl_step(fns, block, fs, multiple):
    """What ymf271_pcm.sv computes."""
    num = (fns | 0x800) * (1 if multiple == 0 else 2 * multiple)
    pow_sh = (block - 9) if (block & 8) else (block + 7)
    sh = pow_sh - 3 - fs
    return (num << sh) if sh >= 0 else (num >> -sh)


def main():
    mame_root = sys.argv[1] if len(sys.argv) > 1 else gen.DEFAULT_MAME
    src, _ = gen.read_source(mame_root)

    bad = 0
    checked = 0
    for block in range(16):
        for fs in range(4):
            for multiple in range(16):
                for fns in range(0, 4096, 7):     # 7 is coprime with every
                    a = mame_step(fns, block, fs, multiple)   # power of two
                    b = rtl_step(fns, block, fs, multiple)
                    checked += 1
                    if a != b:
                        bad += 1
                        if bad <= 10:
                            print("step mismatch fns=%4d block=%2d fs=%d mul=%2d  "
                                  "mame=%d rtl=%d" % (fns, block, fs, multiple, a, b))
    print("step: %d combinations checked, %d mismatches" % (checked, bad))

    # ---- envelope tables --------------------------------------------------
    ar_time = gen.parse_double_table(src, "static const double ARTime[64]", 64)
    dc_time = gen.parse_double_table(src, "static const double DCTime[64]", 64)
    lut_ar = [t * gen.SAMPLE_RATE / 1000.0 for t in ar_time]
    lut_dc = [t * gen.SAMPLE_RATE / 1000.0 for t in dc_time]

    vh = open(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                           "..", "rtl", "ymf271_tables.vh")).read()

    def table_from_vh(name, count):
        vals = [None] * count
        for m in re.finditer(re.escape(name) + r"\[\s*(\d+)\] = \d+'d(\d+);", vh):
            vals[int(m.group(1))] = int(m.group(2))
        if any(v is None for v in vals):
            raise SystemExit("%s is incomplete in ymf271_tables.vh" % name)
        return vals

    ar_step = table_from_vh("YMF_AR_STEP", 64)
    dc_step = table_from_vh("YMF_DC_STEP", 64)
    dc_recip = table_from_vh("YMF_DC_RECIP", 64)

    # init_envelope(): attack, decay2 and release all sweep the full 255 units.
    errs = 0
    for r in range(64):
        for lut, tab, what in ((lut_ar, ar_step, "AR"), (lut_dc, dc_step, "DC")):
            want = 0 if (r < 4 or lut[r] <= 0.0) else min(int((255.0 / lut[r]) * 65536.0),
                                                          255 << 16)
            if tab[r] != want:
                print("%s_STEP[%d] = %d, expected %d" % (what, r, tab[r], want))
                errs += 1

    # decay1 sweeps decay1lvl*16 instead, via a reciprocal, so it is the one
    # step that rounds. The bound that matters is absolute: an error of one
    # unit out of a 16.7M range is inaudible, an error of hundreds is not.
    # (The relative error peaks at 25%, but only where the exact step is 4 --
    # a decay that would take a minute and a half either way.)
    worst = 0
    for r in range(4, 64):
        if lut_dc[r] <= 0.0:
            continue
        for lvl in range(16):
            amount = lvl * 16
            want = int((amount / lut_dc[r]) * 65536.0)
            got = (amount * dc_recip[r]) >> 8
            worst = max(worst, abs(got - want))
    print("envelope tables: %d exact mismatches, decay1 worst absolute error %d"
          % (errs, worst))

    if bad or errs or worst > 1:
        sys.exit(1)


if __name__ == "__main__":
    main()
