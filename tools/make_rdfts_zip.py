#!/usr/bin/env python3
"""
Build a correct rdfts.zip for mra/rdfts.mra.

rdfts is a MAME clone of rdft. In a merged ROM set only the files unique to the
clone are stored under the clone's own names; everything else is deduplicated
into the parent under the PARENT's filenames. MiSTer's MRA loader matches parts
by filename inside the zip, with no CRC fallback, so an MRA that uses MAME's
rdfts names cannot find those files in a merged set. It loads whatever names do
happen to match, zero-fills the rest, and the core boots into an empty program
ROM.

This scans whatever zips you have, picks the 14 parts out by CRC32 (which is
name independent), and writes an rdfts.zip with the names mra/rdfts.mra expects.

  usage: make_rdfts_zip.py -o rdfts.zip <zip> [<zip> ...]
"""

import argparse
import sys
import zipfile

# (name as the MRA expects it, crc32, size) -- must match mra/rdfts.mra and the
# part table in rtl/rom_loader.sv.
PARTS = [
    ("seibu_1.u0259",        0xe278dddd,  0x080000),
    ("raiden-f_prg2.u0258",  0x58ccb10c,  0x080000),
    ("raiden-f_prg34.u0262", 0x63f01d17,  0x100000),
    ("seibu_zprg.u1139",     0xc1fda3e8,  0x020000),
    ("raiden-f_fix.u0535",   0x2be2936b,  0x020000),
    ("seibu_fix2.u0528",     0x4d87e1ea,  0x010000),
    ("gun_dogs_bg1-d.u0526", 0x6a68054c,  0x200000),
    ("gun_dogs_bg1-p.u0531", 0x3400794a,  0x100000),
    ("gun_dogs_bg2-d.u0534", 0x61cd2991,  0x200000),
    ("gun_dogs_bg2-p.u0530", 0x502d5799,  0x100000),
    ("gun_dogs_obj-1.u0322", 0x59d86c99,  0x400000),
    ("gun_dogs_obj-2.u0324", 0x1ceb0b6f,  0x400000),
    ("gun_dogs_obj-3.u0323", 0x36e93234,  0x400000),
    ("raiden-f_pcm2.u0975",  0x3f8d4a48,  0x200000),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-o", "--out", default="rdfts.zip")
    ap.add_argument("zips", nargs="+")
    args = ap.parse_args()

    # crc -> (source zip, member name)
    index = {}
    for path in args.zips:
        try:
            z = zipfile.ZipFile(path)
        except Exception as e:
            print(f"skipping {path}: {e}", file=sys.stderr)
            continue
        for info in z.infolist():
            index.setdefault(info.CRC, (path, info.filename))

    missing = []
    out = zipfile.ZipFile(args.out, "w", zipfile.ZIP_DEFLATED)
    for name, crc, size in PARTS:
        src = index.get(crc)
        if src is None:
            missing.append((name, crc))
            print(f"  MISSING  {name:24s} crc={crc:08x}")
            continue
        path, member = src
        with zipfile.ZipFile(path) as z:
            data = z.read(member)
        if len(data) != size:
            print(f"  BAD SIZE {name:24s} got {len(data)} want {size}")
            missing.append((name, crc))
            continue
        out.writestr(name, data)
        print(f"  ok       {name:24s} <- {member}")
    out.close()

    if missing:
        print(f"\n{len(missing)} part(s) missing; {args.out} is incomplete.",
              file=sys.stderr)
        return 1
    print(f"\nwrote {args.out} -- copy it to /media/fat/games/mame/ on the MiSTer")
    return 0


if __name__ == "__main__":
    sys.exit(main())
