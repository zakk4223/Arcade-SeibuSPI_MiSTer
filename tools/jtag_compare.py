#!/usr/bin/env python3
"""
Compare a JTAG SDRAM dump against the reference image.

    quartus_stp -t tools/jtag_peek.tcl dump 0x0 16 > dump.txt
    tools/jtag_compare.py sdram.bin dump.txt

Reads lines of "ADDRESS HEXWORD" as produced by jtag_peek.tcl and checks each
64-bit word against the reference. Prints the two side by side so a byte lane
swap, a bit flip and a wholly wrong address all look different.

Also usable without hardware: `--expect <addr> <count>` prints what the board
ought to return, which is what you want when eyeballing a dump by hand.
"""

import re
import sys


def words(ref, addr, count):
    for i in range(count):
        a = addr + i * 8
        w = int.from_bytes(ref[a:a + 8], "little")
        yield a, w


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)

    ref = open(sys.argv[1], "rb").read()

    if sys.argv[2] == "--expect":
        addr = int(sys.argv[3], 0)
        count = int(sys.argv[4]) if len(sys.argv) > 4 else 8
        for a, w in words(ref, addr, count):
            print("%07X %016X" % (a, w))
        return 0

    bad = 0
    total = 0
    for line in open(sys.argv[2]):
        m = re.match(r"\s*([0-9A-Fa-f]+)\s+([0-9A-Fa-f]{16})\s*$", line)
        if not m:
            continue
        a = int(m.group(1), 16)
        got = int(m.group(2), 16)
        want = int.from_bytes(ref[a:a + 8], "little")
        total += 1
        if got != want:
            bad += 1
            diff = got ^ want
            print("%07X  got %016X  want %016X  xor %016X" % (a, got, want, diff))
        else:
            print("%07X  %016X  ok" % (a, got))

    print("\n%d/%d words differ" % (bad, total))
    if total and bad == 0:
        print("SDRAM matches the reference image at every address sampled.")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
