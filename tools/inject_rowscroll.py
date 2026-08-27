#!/usr/bin/env python3
"""Write a synthetic rowscroll table into a captured tilemap_ram.bin.

Screen flip mirrors the source row, and rowscroll is the second thing keyed off
that row (spi_layers' rs_index, alongside src_y). `make run-flip` proves the
flipped render is an exact 180 rotation -- but only for the paths the capture
actually exercises, and a capture can have rowscroll_enable=1 with a table of
all zeroes. That was true of the first one used here: the fetch ran, the data
was zero, and the test could not have caught a wrong row.

This fills the table with a pattern chosen to fail loudly on a row-index error:

  * pseudorandom, so it is NOT symmetric under y -> 239-y. A symmetric table
    would look identical whether or not the mirror was applied.
  * no period-38 collisions, so it cannot hide the +19 table bias being applied
    on the wrong side of the mirror -- (239-row)+19 versus 239-(row+19) differ
    by exactly 38 lines.
  * +-64 px, large enough that one wrong row is unmistakable in the pixels.

The data does not need to be realistic. run-flip compares the RTL against
itself, so any table works; this one just maximises sensitivity.

Layout (spi_layers.sv, rowscroll_enable=1): tables are dword bases 0x200/0x600/
0xA00, i.e. bytes 0x800/0x1800/0x2800, 512 signed 16-bit entries each, clear of
the tile data which moves to 0x000/0x400/0x800/0xC00 dwords.

Usage:  inject_rowscroll.py <capdir>/tilemap_ram.bin
"""
import struct
import sys

BASES = (("back", 0x800), ("midl", 0x1800), ("fore", 0x2800))
ENTRIES = 512


def value(i):
    x = (i * 2654435761) & 0xFFFFFFFF
    x ^= x >> 13
    return ((x >> 7) % 128) - 64


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    path = sys.argv[1]
    data = bytearray(open(path, "rb").read())
    if len(data) < 0x2C00:
        sys.exit("%s: %d bytes, expected a 16 KB tilemap RAM dump" % (path, len(data)))

    for _, base in BASES:
        for i in range(ENTRIES):
            struct.pack_into("<h", data, base + 2 * i, value(i))
    open(path, "wb").write(bytes(data))

    # Restate the two properties the pattern exists for, so a future edit that
    # breaks them is caught here rather than by a test that quietly passes.
    blind = sum(1 for y in range(240) if value(y + 19) == value((239 - y) + 19))
    collide = sum(1 for i in range(200) if value(i) == value(i + 38))
    print("injected rowscroll into %s" % path)
    print("  rows where a missing mirror would be invisible: %d/240" % blind)
    print("  period-38 collisions (would hide a +19 side error): %d/200" % collide)
    if blind > 24 or collide > 10:
        sys.exit("pattern is too degenerate to be a useful test")
    return 0


if __name__ == "__main__":
    sys.exit(main())
