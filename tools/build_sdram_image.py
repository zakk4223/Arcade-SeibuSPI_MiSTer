#!/usr/bin/env python3
"""
Build the SDRAM image for an SPI set from a MAME ROM set.

Applies the same ROM_LOAD24_* / ROM_LOAD32_* scatter that rtl/rom_loader.sv does
in hardware, so the result is byte-for-byte what the FPGA has in SDRAM after a
download. The testbenches read this instead of trying to model the loader.

ROMs are matched by CRC32 rather than by name, because merged sets store shared
ROMs under the parent's filenames.

The set is detected from the archive by CRC, so the same command works for
either. rdft2 differs in three ways worth knowing: its sprites carry MAME's
sprite_reorder() (the loader folds it into the destination, mode SPR_R10), its
tile region is 12 MB with the second bg group 6 MB in, and its sample flash is
DERIVED rather than copied -- built here by the same code as
tools/build_soundflash.py, which is checked bit-for-bit against MAME.

Usage:
    tools/build_sdram_image.py rdft.zip out.bin [--region tiles,chars]
"""

import os
import sys
import zipfile
import binascii

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

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
PARTS_RDFTS = [
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
    # Interleaved: chunk k lands at +2k inside each 6-byte half, so the three
    # chunks' words alternate and a 16-pixel row is twelve contiguous bytes.
    ("sprites", 0x59d86c99, 0x400000, "SPR_ILV", 0),
    ("sprites", 0x1ceb0b6f, 0x400000, "SPR_ILV", 2),
    ("sprites", 0x36e93234, 0x400000, "SPR_ILV", 4),
    ("pcm",     0x3f8d4a48, 0x200000, "LINEAR",  0),
]

# rdft2. Order and modes are rom_loader.sv's rdft2 table, which check_mra.py
# holds against MAME's ROM_START(rdft2).
PARTS_RDFT2 = [
    ("prg",     0x3cb3fdca,  0x80000, "W32_B0",  0),
    ("prg",     0xcab55d88,  0x80000, "W32_B1",  0),
    ("prg",     0x83758b0e,  0x80000, "W32_B2",  0),
    ("prg",     0x084fb5e4,  0x80000, "W32_B3",  0),
    ("chars",   0x6fdf4cf6,  0x10000, "W24_B1",  0),
    ("chars",   0x69b7899b,  0x10000, "W24_B0",  0),
    ("chars",   0x99a5fece,  0x10000, "W24_B2",  0),
    ("tiles",   0x6143f576, 0x400000, "W24_W01", 0),
    ("tiles",   0x55e64ef7, 0x200000, "W24_B2",  0),
    ("tiles",   0xc607a444, 0x400000, "W24_W01", 0x600000),
    ("tiles",   0xf0830248, 0x200000, "W24_B2",  0x600000),
    # Three 6 MB plane-pair chunks, obj3 first. SPR_R10 is LINEAR plus
    # sprite_reorder(); every offset here is 64-byte aligned, so applying the
    # permutation per ROM is the same as applying it across the whole run.
    # Three 6 MB chunks, each a pair of ROMs. SPR_ILV_R is the interleave with
    # MAME's sprite_reorder() applied to the source index first. `off` is the
    # chunk slot (+0/+2/+4), and the second ROM of a pair continues its chunk,
    # which the `skip` field carries as a source-index bias.
    ("sprites", 0xe08f42dc, 0x400000, "SPR_ILV_R", 0, 0x000000),
    ("sprites", 0x1b6a523c, 0x200000, "SPR_ILV_R", 0, 0x400000),
    ("sprites", 0x7aeadd8e, 0x400000, "SPR_ILV_R", 2, 0x000000),
    ("sprites", 0x5d790a5d, 0x200000, "SPR_ILV_R", 2, 0x400000),
    ("sprites", 0xc2c50f02, 0x400000, "SPR_ILV_R", 4, 0x000000),
    ("sprites", 0x5259321f, 0x200000, "SPR_ILV_R", 4, 0x400000),
    # pcm is not a part: rdft2's sample flash is derived, see FLASH below.
]

# Sets, detected by the CRC of their first program ROM.
SETS = {
    "rdfts": dict(parts=PARTS_RDFTS, probe=0xe278dddd, flash=False),
    "rdft2": dict(parts=PARTS_RDFT2, probe=0x3cb3fdca, flash=True),
}


def dest_of(mode, i):
    # Sprite interleave: tile*192 + row*12 + half*6 + byte, optionally with
    # sprite_reorder() folded into the source index first. See
    # rtl/rom_loader.sv M_SPR_ILV.
    if mode in ("SPR_ILV", "SPR_ILV_R"):
        if mode == "SPR_ILV_R":
            i = (i & ~0x3F) | ((i & 0x1E) << 1) | ((i & 0x20) >> 4) | (i & 1)
        return (i >> 6) * 192 + ((i >> 2) & 15) * 12 + ((i >> 1) & 1) * 6 + (i & 1)
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
    # LINEAR with MAME's sprite_reorder() folded in: inside each 64-byte group
    # the word index rotates left by one. rom_loader.sv M_SPR_R10, and
    # sim/tb_rom_loader.cpp checks the formula against MAME's own copy.
    if mode == "SPR_R10":
        return (i & ~0x3F) | ((i & 0x1E) << 1) | ((i & 0x20) >> 4) | (i & 1)
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

    setname = next((n for n, c in SETS.items() if c["probe"] in by_crc), None)
    if setname is None:
        raise SystemExit("%s is none of %s" % (zpath, ", ".join(sorted(SETS))))
    cfg = SETS[setname]
    PARTS = cfg["parts"]
    print("set: %s" % setname)

    image = bytearray(b"\xFF" * SDRAM_SIZE)
    placed = 0

    for part in PARTS:
        region, crc, size, mode, off = part[:5]
        skip = part[5] if len(part) > 5 else 0
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
            image[base + dest_of(mode, i + skip)] = b
        placed += 1
        print("  %-8s %-28s %8d  %s" % (region, name, size, mode))

    # rdft2's sample flash is not a ROM. It is the region stamp, a verbatim
    # slice of pcm.u0217, and half a megabyte the game's own 386 decompresses --
    # the same image tools/build_soundflash.py rebuilds and checks by sha256
    # against what MAME's flash devices hold.
    if cfg["flash"] and (not want_regions or "pcm" in want_regions):
        from build_soundflash import build as build_flash
        flash = build_flash(zf, setname)
        image[BASE["pcm"]:BASE["pcm"] + len(flash)] = flash
        placed += 1
        print("  %-8s %-28s %8d  derived" % ("pcm", "sample flash", len(flash)))

    if concat:
        blob = bytearray()
        for part in PARTS:
            blob += zf.read(by_crc[part[1]])
        if cfg["flash"]:
            # Exactly what mra/rdft2.mra sends for the two sample parts: the
            # stamp and a slice of pcm, then the COMPRESSED tail. The loader
            # decodes the second one on the way in, so the concatenated stream
            # is shorter than the image it produces.
            blob += bytes(image[BASE["pcm"]:BASE["pcm"] + 4])   # region stamp
            blob += zf.read("pcm.u0217")[4:0x17C247]
            blob += zf.read("sound1.u0222")[:0x4C665]
        with open(outpath, "wb") as f:
            f.write(blob)
        print("wrote %s (concatenated stream, %d bytes)" % (outpath, len(blob)))
        return

    with open(outpath, "wb") as f:
        f.write(image)
    print("wrote %s (%d parts, %d bytes)" % (outpath, placed, len(image)))


if __name__ == "__main__":
    main()
