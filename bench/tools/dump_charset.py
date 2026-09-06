#!/usr/bin/env python3
"""Decrypt and render rfjet's text-layer character ROM.

This is what established that the benchmark can print at all: rfjet's fix ROM
maps **tile index directly to ASCII** over 0x20-0x5F -- space, punctuation,
digits at 0x30, A-Z at 0x41 -- so bench.asm's text routines can write a
character code straight into the tilemap with no translation table. Above 0x5F
the ROM is game artwork, and there is no lowercase.

Everything here follows MAME:

  * the three ROMs interleave 3-way, fix1 -> byte 0, fix0 -> byte 1,
    fixp -> byte 2 (seibuspi.cpp:3881-3883, ROM_LOAD24_BYTE = ROM_SKIP(2))
  * each 24-bit word is decrypted as
    seibu_partial_carry_sum24(bitswap24(w), (i >> 4) + key1, key2) ^ key3
    with rfjet's keys AEA754 / FE8530 / CCB666 (seibuspi_v.cpp:41-61, :133)
  * the layout is spi_charlayout (seibuspi.cpp:1410-1420): 8x8, 5 planes at bit
    offsets 4/8/12/16/20, x order 3,2,1,0 then 27,26,25,24, 48 bytes per tile

Pen 31 is the layer's transparent pen and prints as '.'; the glyphs themselves
use pens 4, 6, 8 and 15, which is why the benchmark simply fills all 32 pens of
text colour bank 0 with white.

    python3 bench/tools/dump_charset.py rfjet.zip 0x41 8
"""
import sys
import zipfile

KEY1, KEY2, KEY3 = 0xAEA754, 0xFE8530, 0xCCB666
BITSWAP = [18, 19, 9, 5, 10, 17, 16, 20, 21, 22, 6, 11,
           15, 14, 4, 23, 0, 1, 7, 8, 13, 12, 3, 2]
PLANES = [4, 8, 12, 16, 20]
XOFF = [3, 2, 1, 0, 27, 26, 25, 24]
YOFF = [y * 48 for y in range(8)]
TRANSPARENT = 31


def partial_carry_sum24(a1, a2, mask):
    """seibu_helper.cpp: add, but only carry where the mask says so, and wrap
    the top carry back into bit 0."""
    res = carry = 0
    for i in range(24):
        bit = ((a1 >> i) & 1) + ((a2 >> i) & 1) + carry
        res += (bit & 1) << i
        carry = (bit >> 1) if ((mask >> i) & 1) else 0
    return res ^ 1 if carry else res


def bitswap24(v):
    r = 0
    for n, src in enumerate(BITSWAP):        # n = 0 is the MSB of the result
        r |= ((v >> src) & 1) << (23 - n)
    return r


def load(zip_path):
    z = zipfile.ZipFile(zip_path)
    fix1, fix0, fixp = (z.read(n) for n in
                        ("fix1.u0518", "fix0.u0524", "fixp.u0514"))
    rom = bytearray(0x30000)
    rom[0::3], rom[1::3], rom[2::3] = fix1, fix0, fixp

    for i in range(0x10000):
        w = (rom[i * 3] << 16) | (rom[i * 3 + 1] << 8) | rom[i * 3 + 2]
        w = partial_carry_sum24(bitswap24(w), (i >> 4) + KEY1, KEY2) ^ KEY3
        rom[i * 3 + 0] = (w >> 16) & 0xFF
        rom[i * 3 + 1] = (w >> 8) & 0xFF
        rom[i * 3 + 2] = w & 0xFF
    return rom


def render(rom, tile):
    base = tile * 48

    def bit(pos):
        return (rom[base + (pos >> 3)] >> (7 - (pos & 7))) & 1

    return [[sum(bit(YOFF[y] + XOFF[x] + po) << (4 - p)
                 for p, po in enumerate(PLANES))
             for x in range(8)] for y in range(8)]


def main():
    zip_path = sys.argv[1] if len(sys.argv) > 1 else "rfjet.zip"
    start = int(sys.argv[2], 0) if len(sys.argv) > 2 else 0x20
    count = int(sys.argv[3], 0) if len(sys.argv) > 3 else 64

    rom = load(zip_path)
    for base in range(start, start + count, 8):
        n = min(8, start + count - base)
        print("  ".join("%04X%s" % (base + k, " " * 4) for k in range(n)))
        grids = [render(rom, base + k) for k in range(n)]
        for y in range(8):
            print("  ".join(
                "".join("." if c == TRANSPARENT else "%X" % c if c < 16 else "#"
                        for c in g[y])
                for g in grids))
        print()


if __name__ == "__main__":
    main()
