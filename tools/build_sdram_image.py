#!/usr/bin/env python3
"""
Build the SDRAM image for rdfts from a MAME ROM set.

Applies the same ROM_LOAD24_* / ROM_LOAD32_* scatter that rtl/rom_loader.sv does
in hardware, so the result is byte-for-byte what the FPGA has in SDRAM after a
download. The testbenches read this instead of trying to model the loader.

ROMs are matched by CRC32 rather than by name, because merged sets store shared
ROMs under the parent's filenames.

Usage:
    tools/build_sdram_image.py rdft.zip out.bin [--region tiles,chars]
"""

import sys
import zipfile
import binascii

# SDRAM map, must match rtl/spi_defs.vh
BASE = {
    "prg":     0x0000000,
    "z80":     0x0200000,
    "chars":   0x0240000,
    "pcm":     0x0280000,
    "tiles":   0x0500000,
    "sprites": 0x1100000,
}
SDRAM_SIZE = 0x2900000

# (region, crc32, size, mode, offset-within-region)
# Mode names match the scatter modes in rtl/rom_loader.sv.
PARTS = [
    ("prg",     0xe278dddd,  0x80000, "W32_B0",  0),
    ("prg",     0x58ccb10c,  0x80000, "W32_B1",  0),
    ("prg",     0x63f01d17, 0x100000, "W32_W23", 0),
    ("z80",     0xc1fda3e8,  0x20000, "LINEAR",  0),
    ("chars",   0x2be2936b,  0x20000, "W24_W01", 0),
    ("chars",   0x4d87e1ea,  0x10000, "W24_B2",  0),
    ("tiles",   0x6a68054c, 0x200000, "W24_W01", 0),
    ("tiles",   0x3400794a, 0x100000, "W24_B2",  0),
    ("tiles",   0x61cd2991, 0x200000, "W24_W01", 0x300000),
    ("tiles",   0x502d5799, 0x100000, "W24_B2",  0x300000),
    ("sprites", 0x59d86c99, 0x400000, "LINEAR",  0x000000),
    ("sprites", 0x1ceb0b6f, 0x400000, "LINEAR",  0x400000),
    ("sprites", 0x36e93234, 0x400000, "LINEAR",  0x800000),
    ("pcm",     0x3f8d4a48, 0x200000, "LINEAR",  0),
]


def dest_of(mode, i):
    if mode == "LINEAR":  return i
    if mode == "W32_B0":  return i * 4
    if mode == "W32_B1":  return i * 4 + 1
    if mode == "W32_B2":  return i * 4 + 2
    if mode == "W32_B3":  return i * 4 + 3
    # No swap for the 32-bit modes: "maincpu" is ROM_REGION32_LE, so a
    # GROUPWORD load of a little-endian file needs no reordering. Verified by
    # byte-comparing against MAME's :maincpu region.
    if mode == "W32_W01": return (i >> 1) * 4 + (i & 1)
    if mode == "W32_W23": return (i >> 1) * 4 + 2 + (i & 1)
    if mode == "W24_B0":  return i * 3
    if mode == "W24_B1":  return i * 3 + 1
    if mode == "W24_B2":  return i * 3 + 2
    # The 24-bit modes DO swap. "chars" and "tiles" are plain ROM_REGIONs, not
    # ROM_REGION*_LE, so ROM_GROUPWORD reorders the two bytes of each source
    # word. Verified against MAME's decrypted :chars region: the naive order
    # decrypts char 0 to 713BE7, the swapped order to FFFFFF, which is what
    # MAME actually has (a blank, fully transparent char).
    if mode == "W24_W01": return (i >> 1) * 3 + (1 - (i & 1))
    raise SystemExit("unknown mode " + mode)


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    zpath, outpath = sys.argv[1], sys.argv[2]

    # --concat writes the raw concatenation of the parts in MRA order instead
    # of the scattered image: that is exactly the byte stream MiSTer pushes over
    # ioctl, and sim/tb_sdram.cpp feeds it to the real loader.
    concat = "--concat" in sys.argv

    want_regions = None
    if "--region" in sys.argv:
        want_regions = set(sys.argv[sys.argv.index("--region") + 1].split(","))

    zf = zipfile.ZipFile(zpath)
    by_crc = {}
    for info in zf.infolist():
        by_crc.setdefault(info.CRC, info.filename)

    image = bytearray(b"\xFF" * SDRAM_SIZE)
    placed = 0

    for region, crc, size, mode, off in PARTS:
        if want_regions and region not in want_regions:
            continue
        name = by_crc.get(crc)
        if name is None:
            raise SystemExit("missing ROM crc %08x for region %s" % (crc, region))
        data = zf.read(name)
        if len(data) != size:
            raise SystemExit("%s is %d bytes, expected %d" % (name, len(data), size))
        if binascii.crc32(data) & 0xFFFFFFFF != crc:
            raise SystemExit("%s failed CRC check" % name)

        base = BASE[region] + off
        for i, b in enumerate(data):
            image[base + dest_of(mode, i)] = b
        placed += 1
        print("  %-8s %-28s %8d  %s" % (region, name, size, mode))

    if concat:
        blob = bytearray()
        for region, crc, size, mode, off in PARTS:
            blob += zf.read(by_crc[crc])
        with open(outpath, "wb") as f:
            f.write(blob)
        print("wrote %s (concatenated stream, %d bytes)" % (outpath, len(blob)))
        return

    with open(outpath, "wb") as f:
        f.write(image)
    print("wrote %s (%d parts, %d bytes)" % (outpath, placed, len(image)))


if __name__ == "__main__":
    main()
