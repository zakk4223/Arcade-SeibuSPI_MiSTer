#!/usr/bin/env python3
"""Pack releases/ into one zip a tester can unpack in /media/fat.

`make release` assembles releases/ in the layout MiSTer's DISTRIBUTION system
wants -- parent MRAs beside the RBF, clones under _alternatives/. That is not the
layout a MiSTer's SD CARD wants, and the difference is exactly the part a tester
gets wrong: the MRAs belong in _Arcade/, the clones in _Arcade/_alternatives/, and
the bitstream in _Arcade/cores/ under a DATED name. Hand someone the release
directory and they end up with an RBF in _Arcade/ that no MRA can find.

So this rewrites the layout on the way into the archive:

    _Arcade/<parent>.mra                        x6
    _Arcade/_alternatives/_<parent>/<clone>.mra
    _Arcade/cores/SeibuSPI.rbf

The RBF is deliberately UNDATED, so each zip overwrites the last one in place and
a tester is never running a build older than the one they just unpacked. The zip
itself carries the date; what is on the card is whatever was unzipped last.

The checks below are all failure modes that are SILENT on hardware. An MRA whose
<rbf> tag does not name this core loads a different core or none; an
_alternatives/_<name> directory with no matching parent MRA simply never appears
in the menu. Neither says anything at pack time unless something looks.

  usage: make_release_zip.py [-o dist/] [--date YYYYMMDD] [--suffix rc1]
                             [--source releases/]
"""

import argparse
import hashlib
import os
import re
import sys
import zipfile

CORE = "SeibuSPI"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def build_date():
    """YYYYMMDD from build_id.v, the same stamp the core reports on the OSD.

    build_id.v carries `define BUILD_DATE "260824" -- YYMMDD, because that is what
    fits the core's version field. The zip and the RBF name want the four-digit
    year, so widen it here rather than in the RTL.
    """
    path = os.path.join(ROOT, "build_id.v")
    try:
        with open(path) as f:
            m = re.search(r'BUILD_DATE\s+"(\d{6})"', f.read())
    except OSError:
        return None
    if not m:
        return None
    return "20" + m.group(1)


def collect(source):
    """(parent MRAs, {parent stem: [clone MRAs]}, rbf path) out of releases/."""
    parents = sorted(n for n in os.listdir(source) if n.endswith(".mra"))
    alts = {}
    altdir = os.path.join(source, "_alternatives")
    if os.path.isdir(altdir):
        for d in sorted(os.listdir(altdir)):
            full = os.path.join(altdir, d)
            if os.path.isdir(full):
                alts[d] = sorted(n for n in os.listdir(full) if n.endswith(".mra"))
    rbf = os.path.join(source, CORE + ".rbf")
    return parents, alts, (rbf if os.path.isfile(rbf) else None)


def check(source, parents, alts, rbf):
    """Everything that would ship broken and say nothing. Returns a list of errors."""
    errs = []
    if rbf is None:
        errs.append("no %s.rbf in %s -- run `make release` first" % (CORE, source))
    if not parents:
        errs.append("no parent MRAs in %s" % source)

    # An <rbf> tag naming anything else points the tester at a core that is not
    # this one. Cheap to check, invisible if wrong.
    for name in parents + [os.path.join("_alternatives", d, n)
                           for d, ns in alts.items() for n in ns]:
        with open(os.path.join(source, name), errors="replace") as f:
            tags = re.findall(r"<rbf>([^<]*)</rbf>", f.read())
        if tags != [CORE]:
            errs.append("%s: <rbf> is %s, expected [%r]" % (name, tags, CORE))

    # MiSTer shows _alternatives/_<parent>/ only under a parent MRA of that exact
    # name; an orphaned directory is simply never reachable from the menu.
    stems = {os.path.splitext(n)[0] for n in parents}
    for d, names in alts.items():
        if not d.startswith("_") or d[1:] not in stems:
            errs.append("_alternatives/%s: no parent MRA named %r" % (d, d.lstrip("_")))
        if not names:
            errs.append("_alternatives/%s: empty" % d)
    return errs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-o", "--outdir", default=os.path.join(ROOT, "dist"),
                    help="where to write the zip (default: dist/)")
    ap.add_argument("--source", default=os.path.join(ROOT, "releases"),
                    help="release directory to pack (default: releases/)")
    ap.add_argument("--date", help="override the build_id.v date stamp (YYYYMMDD)")
    ap.add_argument("--suffix", default="",
                    help="tag appended to the ZIP name, e.g. rc1 -- not to the RBF")
    args = ap.parse_args()

    date = args.date or build_date()
    if not date or not re.fullmatch(r"\d{8}", date):
        sys.exit("cannot read a YYYYMMDD build date from build_id.v; pass --date")

    if not os.path.isdir(args.source):
        sys.exit("no such release directory: %s" % args.source)
    parents, alts, rbf = collect(args.source)
    errs = check(args.source, parents, alts, rbf)
    if errs:
        for e in errs:
            print("error: " + e, file=sys.stderr)
        sys.exit(1)

    with open(rbf, "rb") as f:
        rbf_bytes = f.read()
    md5 = hashlib.md5(rbf_bytes).hexdigest()

    suffix = ("-" + args.suffix.lstrip("-")) if args.suffix else ""
    zname = "%s_%s%s.zip" % (CORE, date, suffix)
    os.makedirs(args.outdir, exist_ok=True)
    zpath = os.path.join(args.outdir, zname)

    # One fixed timestamp for every member, so the same tree packs to the same
    # bytes twice running and the zip's own md5 is worth quoting to a tester.
    stamp = (int(date[0:4]), int(date[4:6]), int(date[6:8]), 0, 0, 0)

    def add(zf, arcname, data):
        info = zipfile.ZipInfo(arcname, date_time=stamp)
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = 0o644 << 16
        zf.writestr(info, data)

    nclones = 0
    with zipfile.ZipFile(zpath, "w", zipfile.ZIP_DEFLATED) as zf:
        add(zf, "_Arcade/cores/%s.rbf" % CORE, rbf_bytes)
        for n in parents:
            with open(os.path.join(args.source, n), "rb") as f:
                add(zf, "_Arcade/" + n, f.read())
        for d in sorted(alts):
            for n in alts[d]:
                with open(os.path.join(args.source, "_alternatives", d, n), "rb") as f:
                    add(zf, "_Arcade/_alternatives/%s/%s" % (d, n), f.read())
                nclones += 1

    print("%s: %d parent MRAs, %d under _alternatives, %s.rbf %s (%.1f MB)"
          % (os.path.relpath(zpath, ROOT), len(parents), nclones, CORE,
             md5[:8], os.path.getsize(zpath) / 1e6))
    return 0


if __name__ == "__main__":
    sys.exit(main())
