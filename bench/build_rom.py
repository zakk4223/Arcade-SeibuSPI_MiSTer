#!/usr/bin/env python3
"""Split the benchmark image into the four rfjet program ROMs, and zip them.

rfjet's program space is four 512 KB byte-wide devices striped little-endian
(seibuspi.cpp:3876-3879, ROM_LOAD32_BYTE at offsets 0/1/2/3):

    prg0.u0211 -> D7-0     prg1.u0212 -> D15-8
    prg2.u0221 -> D23-16   prg3.u0220 -> D31-24

The same four files feed all four targets: MAME (through mame_bench.lua, which
patches the region rather than fighting the CRC check), the Verilator model
(through build_sdram_image.py --prg), the MiSTer core (through the benchmark
MRA and this zip), and a real cartridge (four 27C040s).

    python3 build_rom.py bench.bin --out out --window 8
    python3 build_rom.py bench.bin --out out-quick --window 2 --tests 0-8,35

--window and --tests patch the 'BCFG' block the assembler puts at ROM offset 0,
so the two variants come out of one assembly rather than one #define and two
builds that can drift apart.
"""
import argparse
import os
import struct
import sys
import zipfile

ROM_SIZE = 0x200000
PART_SIZE = 0x80000
# Deliberately NOT the stock names. A benchmark MRA lists both zips, and if
# these were called prg0.u0211 the loader would find the game's own ROM in
# rfjet.zip first and quietly run the game instead. The socket numbers are
# kept so it is still obvious which EPROM goes where.
PARTS = ["bprg0.u0211", "bprg1.u0212", "bprg2.u0221", "bprg3.u0220"]
CFG_MAGIC = b"BCFG"
REGION_OFFSET = 0x1FFFFC


def parse_tests(spec):
    """"0-8,12,35" -> a 64-bit enable mask. "all" -> everything."""
    if spec is None or spec.lower() == "all":
        return (1 << 64) - 1
    mask = 0
    for piece in spec.split(","):
        piece = piece.strip()
        if not piece:
            continue
        if "-" in piece:
            a, b = piece.split("-", 1)
            for i in range(int(a), int(b) + 1):
                mask |= 1 << i
        else:
            mask |= 1 << int(piece)
    return mask


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("image", help="bench.bin from nasm")
    ap.add_argument("--out", default=".", help="output directory")
    ap.add_argument("--window", type=int, default=None,
                    help="frames per measurement window (1-64)")
    ap.add_argument("--tests", default=None,
                    help='test subset, e.g. "0-8,35" (default: all)')
    ap.add_argument("--region", type=lambda s: int(s, 0), default=None,
                    help="region byte at 0x1FFFFC (default: leave as built)")
    ap.add_argument("--zip", default="bench.zip", help="zip name, or '' to skip")
    args = ap.parse_args()

    rom = bytearray(open(args.image, "rb").read())
    if len(rom) != ROM_SIZE:
        sys.exit("%s is %d bytes, expected %d" % (args.image, len(rom), ROM_SIZE))
    if bytes(rom[0:4]) != CFG_MAGIC:
        sys.exit("no BCFG block at ROM offset 0 -- wrong image?")

    if args.window is not None:
        if not 1 <= args.window <= 64:
            # Above 64 the cycles_x100 numerator (CPF * window * 100) leaves
            # 32 bits and the on-screen figure silently wraps.
            sys.exit("--window must be 1..64")
        rom[4:8] = struct.pack("<I", args.window)
    if args.tests is not None:
        mask = parse_tests(args.tests)
        rom[8:12] = struct.pack("<I", mask & 0xFFFFFFFF)
        rom[12:16] = struct.pack("<I", (mask >> 32) & 0xFFFFFFFF)
    if args.region is not None:
        rom[REGION_OFFSET] = args.region & 0xFF

    window = struct.unpack("<I", bytes(rom[4:8]))[0]
    mask = (struct.unpack("<I", bytes(rom[8:12]))[0]
            | struct.unpack("<I", bytes(rom[12:16]))[0] << 32)

    os.makedirs(args.out, exist_ok=True)
    paths = []
    for lane, name in enumerate(PARTS):
        part = rom[lane::4]
        assert len(part) == PART_SIZE, len(part)
        path = os.path.join(args.out, name)
        with open(path, "wb") as f:
            f.write(part)
        paths.append(path)

    # Re-interleaving has to reproduce the image byte for byte, or four EPROMs
    # get burned from a split nobody checked.
    rebuilt = bytearray(ROM_SIZE)
    for lane, path in enumerate(paths):
        rebuilt[lane::4] = open(path, "rb").read()
    if rebuilt != rom:
        sys.exit("interleave check FAILED -- the split does not round-trip")

    flat = os.path.join(args.out, "bench_patched.bin")
    with open(flat, "wb") as f:
        f.write(rom)

    if args.zip:
        zpath = os.path.join(args.out, args.zip)
        with zipfile.ZipFile(zpath, "w", zipfile.ZIP_DEFLATED) as z:
            for path in paths:
                z.write(path, os.path.basename(path))
        print("zip     %s" % zpath)

    print("window  %d frames" % window)
    print("tests   0x%016X" % mask)
    print("region  0x%02X" % rom[REGION_OFFSET])
    print("parts   %s" % ", ".join(os.path.basename(p) for p in paths))
    print("flat    %s" % flat)
    print("interleave round-trips")


if __name__ == "__main__":
    main()
