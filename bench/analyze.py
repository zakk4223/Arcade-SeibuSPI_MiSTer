#!/usr/bin/env python3
"""Turn benchmark result files into cycles per unit, and compare the platforms.

Every leg emits the same line, whatever produced it:

    BENCH idx=1 name="ADD R,R" lo=956123 hi=128300 delta=100 window=8

`lo` and `hi` are iteration counts completed inside one measurement window at
the two block lengths. The window is an exact whole number of video frames, so:

    cycles_per_unit = (cpu_hz / frame_hz) * window * (1/hi - 1/lo) / delta

Nothing else has to be known. Loop overhead, the vblank ISR and the harness are
present identically in both lengths and cancel in the difference -- that is the
whole point of measuring twice (uops.info, arXiv:1810.04610 3.1).

    python3 bench/analyze.py \\
        mame=/tmp/bench_mame.txt \\
        core=/tmp/bench_core.txt:28636364 \\
        hw=/tmp/bench_hw.txt

Each argument is label=path[:cpu_hz[:frame_hz]]. cpu_hz defaults to the board's
25.000 MHz (50 MHz XTAL / 2, seibuspi.cpp:1806) and frame_hz to the SPI raster's
53.9866 Hz; pass 28636364 for the core as it stands today, or 25056818 once the
7/8 clock gate of PLAN.md 16.9 is built.
"""
import json
import os
import re
import sys

DEFAULT_CPU_HZ = 25_000_000.0
# 28.636363 MHz / 4 / (448 * 296), seibuspi.cpp:898-906
DEFAULT_FRAME_HZ = 28_636_363.0 / 4.0 / (448.0 * 296.0)

LINE = re.compile(
    r'BENCH\s+idx=(\d+)\s+name="([^"]*)"\s+lo=(\d+)\s+hi=(\d+)'
    r'\s+delta=(\d+)\s+window=(\d+)')


class Source:
    def __init__(self, spec):
        label, _, rest = spec.partition("=")
        if not rest:
            sys.exit("expected label=path[:cpu_hz[:frame_hz]], got %r" % spec)
        bits = rest.split(":")
        self.label = label
        self.path = bits[0]
        self.cpu_hz = float(bits[1]) if len(bits) > 1 and bits[1] else DEFAULT_CPU_HZ
        self.frame_hz = float(bits[2]) if len(bits) > 2 and bits[2] else DEFAULT_FRAME_HZ
        self.rows = {}
        self.load()

    def load(self):
        for line in open(self.path):
            m = LINE.search(line)
            if not m:
                continue
            idx, name, lo, hi, delta, window = m.groups()
            self.rows[int(idx)] = dict(
                name=name, lo=int(lo), hi=int(hi),
                delta=int(delta), window=int(window))

    @property
    def cpf(self):
        return self.cpu_hz / self.frame_hz

    def cycles(self, idx):
        r = self.rows.get(idx)
        if not r or r["lo"] == 0 or r["hi"] == 0 or r["delta"] == 0:
            return None
        span = self.cpf * r["window"]
        return (span / r["hi"] - span / r["lo"]) / r["delta"]


def main():
    args = sys.argv[1:]
    if not args:
        sys.exit(__doc__)
    sources = [Source(a) for a in args]

    manifest_path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                 "tests.json")
    manifest = {t["index"]: t for t in json.load(open(manifest_path))}

    print("clocks per frame:")
    for s in sources:
        print("  %-8s %10.3f MHz / %7.4f Hz = %9.1f  (%d rows)"
              % (s.label, s.cpu_hz / 1e6, s.frame_hz, s.cpf, len(s.rows)))
    print()

    head = "%-12s %7s" % ("TEST", "INTEL")
    for s in sources:
        head += " %10s" % s.label[:10]
    if len(sources) > 1:
        head += " %8s" % ("%s/%s" % (sources[-1].label[:3], sources[0].label[:3]))
    print(head)
    print("-" * len(head))

    for idx in sorted(manifest):
        t = manifest[idx]
        name = t["name"]
        exp = t["intel386"]
        row = "%-12s %7s" % (name, ("%.2f" % exp) if exp else "-")
        vals = []
        for s in sources:
            c = s.cycles(idx)
            vals.append(c)
            row += " %10s" % ("%.2f" % c if c is not None else "-")
        if len(sources) > 1:
            a, b = vals[0], vals[-1]
            row += " %8s" % ("%.3f" % (b / a) if a and b and a > 0.01 else "-")
        print(row)

    # The MUL sweep has a closed-form answer, so it is the one test that can be
    # graded rather than just compared: 386 clocks = max(ceil(log2 m), 3) + 6,
    # or 9 when m is zero. A flat sweep means the implementation does not do
    # early-out at all -- which is exactly what MAME's flat 41 will show.
    print()
    muls = [(i, t) for i, t in manifest.items() if t["name"].startswith("MUL M=")]
    if muls:
        print("MUL early-out sweep (unit is MOV+MUL, so subtract the MOV):")
        for s in sources:
            got = []
            for i, t in sorted(muls):
                c = s.cycles(i)
                got.append("%s=%s" % (t["name"][6:], "%.1f" % c if c else "-"))
            vals = [s.cycles(i) for i, _ in sorted(muls)]
            vals = [v for v in vals if v]
            spread = (max(vals) - min(vals)) if vals else 0.0
            verdict = "STAIRCASE" if spread > 3.0 else "FLAT (no early-out)"
            print("  %-8s %s   spread %.1f -> %s"
                  % (s.label, "  ".join(got), spread, verdict))


if __name__ == "__main__":
    main()
