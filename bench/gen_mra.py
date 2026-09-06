#!/usr/bin/env python3
"""Derive the benchmark MRA from the stock rfjet one, and check the result.

Everything is kept identical -- the index-1 config blob, the seventeen parts in
`rtl/rom_loader.sv`'s own table order, the NVRAM node, the buttons -- except the
four program parts, which come from bench.zip instead and carry no CRC. The MRA
`zip` attribute takes a '|' separated list, so graphics and sound still load from
the genuine set and only the 386's program is substituted.

The four are renamed `bprg*`. If they kept the stock names the loader would find
the game's own prg0.u0211 in rfjet.zip first and quietly run the game, which
looks exactly like the benchmark failing to boot.

This deliberately lives outside mra/, because tools/check_mra.py validates every
MRA there against MAME's ROM definitions and this one is designed to fail that.

    python3 bench/gen_mra.py "mra/Raiden Fighters Jet (Germany).mra" \\
        bench/out "Raiden Fighters Jet (386 Benchmark).mra" \\
        --verify ~/Downloads/roms

--verify is worth passing. rom_loader.sv's SET_RFJET table is positional: part N
is scattered by the mode and to the base the RTL has hardcoded for slot N. So
the only thing that matters about this MRA is that the ORDERED LIST OF PART
SIZES is unchanged from the stock one -- a part of the wrong length shifts every
later region and the core loads garbage with no complaint. --verify opens both
zips and checks exactly that.
"""
import argparse
import os
import re
import sys
import zipfile

# stock name -> benchmark name
RENAME = {
    "prg0.u0211": "bprg0.u0211",
    "prg1.u0212": "bprg1.u0212",
    "prg2.u0221": "bprg2.u0221",
    "prg3.u0220": "bprg3.u0220",
}

PART = re.compile(r'<part\s+name="([^"]+)"')

NOTE = """
    <!--
      386 BENCHMARK BUILD - NOT A GAME.

      The four program parts come from bench.zip, built by bench/build_rom.py
      out of bench/bench.asm, and are named bprg* so they cannot be confused
      with the game's own prg* in rfjet.zip; everything else is the genuine
      rfjet set. Put both zips in the same place.

      On boot the core runs the 386 IPC benchmark and prints its table on the
      text layer. All 37 tests fit on one screen; the bottom line reads
      COMPLETE when the last one lands, after about 90 seconds.

      Before trusting a number, in the OSD:

        Refresh Rate = Normal    both change VTOTAL, and the measurement
        CRT V-Size   = 0         window is counted in video frames

        Orientation  = Vert      the defaults. rfjet is ROT270 and the table
        Rotation     = CCW       is laid out to be read through that rotation;
                                 with Orientation = Horz it reads sideways.
    -->
"""


def part_sizes(text, romdir, extra_zip=None):
    """Ordered [(name, size)] for the index-0 ROM node, resolved against the
    zips the MRA names."""
    node = text.split('<rom index="0"', 1)[1].split("</rom>", 1)[0]
    zips = re.search(r'zip="([^"]+)"', node).group(1).split("|")

    index = {}
    for zname in zips:
        path = os.path.join(romdir, zname)
        if not os.path.exists(path) and extra_zip and os.path.basename(extra_zip) == zname:
            path = extra_zip
        if not os.path.exists(path):
            sys.exit("--verify: cannot find %s (looked in %s)" % (zname, romdir))
        with zipfile.ZipFile(path) as z:
            for info in z.infolist():
                index.setdefault(os.path.basename(info.filename), info.file_size)

    out = []
    for name in PART.findall(node):
        if name not in index:
            sys.exit("--verify: %s is in the MRA but in none of %s"
                     % (name, ", ".join(zips)))
        out.append((name, index[name]))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("source", help="the stock rfjet MRA")
    ap.add_argument("outdir")
    ap.add_argument("name")
    ap.add_argument("--verify", metavar="ROMDIR",
                    help="check the part sizes against the real zips")
    ap.add_argument("--bench-zip", default=None,
                    help="path to bench.zip, if it is not in ROMDIR")
    args = ap.parse_args()

    src = open(args.source).read()
    out = src

    out = re.sub(r"<name>[^<]*</name>",
                 "<name>Raiden Fighters Jet (386 Benchmark)</name>", out, count=1)
    out = out.replace('zip="rfjet.zip"', 'zip="rfjet.zip|bench.zip"', 1)

    n = 0
    for old, new in RENAME.items():
        pat = '<part name="%s" crc="[0-9a-f]{8}"/>' % re.escape(old)
        out, k = re.subn(pat, '<part name="%s"/>' % new, out, count=1)
        n += k
    if n != len(RENAME):
        sys.exit("replaced %d of %d program parts -- has the MRA layout changed?"
                 % (n, len(RENAME)))

    out = out.replace('    <rom index="1">', NOTE + '    <rom index="1">', 1)

    os.makedirs(args.outdir, exist_ok=True)
    path = os.path.join(args.outdir, args.name)
    with open(path, "w") as f:
        f.write(out)
    print("wrote %s" % path)

    if args.verify:
        bench_zip = args.bench_zip or os.path.join(args.outdir, "bench.zip")
        want = part_sizes(src, args.verify)
        got = part_sizes(out, args.verify, extra_zip=bench_zip)
        if len(want) != len(got):
            sys.exit("part COUNT changed: %d -> %d" % (len(want), len(got)))
        bad = [(i, a, b) for i, (a, b) in enumerate(zip(want, got))
               if a[1] != b[1]]
        for i, a, b in bad:
            print("  part %2d  %s %d  ->  %s %d   SIZE CHANGED"
                  % (i, a[0], a[1], b[0], b[1]))
        if bad:
            sys.exit("part sizes differ from the stock MRA -- the core's "
                     "positional load table would scatter every later region "
                     "to the wrong place")
        total = sum(s for _, s in got)
        print("verified %d parts, %d bytes, sizes identical to the stock MRA"
              % (len(got), total))
        for i, (name, size) in enumerate(got):
            if name in RENAME.values():
                print("  part %2d  %-24s %8d  (from bench.zip)" % (i, name, size))


if __name__ == "__main__":
    main()
