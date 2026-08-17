#!/usr/bin/env python3
"""
Derive the sample-flash image from an SDRAM IMAGE ALONE, with no ROM set.

This is the premise the single-MRA plan rests on, and it is worth proving before
any of it is built in RTL. Today the core gets a pre-flashed image one of two
ways -- an MRA assembles it out of ROM slices, or the game spends six minutes
programming it through the 386/FIFO/Z80 -- and the plan is to have the core
derive it itself, at reset, from what the download already put in SDRAM. That is
only possible if everything the updater reads is reachable from SDRAM:

    the job table        in the 386's program image, plainly, at SDR_PRG_BASE
    a job's source       either that same program image (viprp1) or MAME's
                         sound01 region, which is NOT stored -- it is the two
                         packed ROMs at SDR_SND01_BASE and the set's pcmsrc
                         base, seen through rtl/spi_snd_window.sv's decode
    the region stamp     in the program image, written to flash[0..3] LAST

So this walks the SAME code as tools/build_soundflash.py -- build_from(), which
exists for exactly this reason -- with `prg` and `region` reconstructed from an
SDRAM image instead of from a zip, and checks the result byte for byte against
the zip-derived one. Reaching the same sha256 by two routes that share only the
walk is what says the walker has everything it needs.

It is also the ACCEPTANCE TEST for the RTL walker when that is written, and the
replacement for a check the plan deletes: check_mra.py currently rebuilds each
pre-flashed set's derived image from the MRA's own slices and compares a
sha256, and once no MRA carries a derived image there is nothing left for it to
rebuild. This is what has to take over.

The region is reconstructed through check_snd01_window.py's rtl_dword(), which
is a transcription of the RTL decode and is itself checked two ways -- against
MAME's region in that script, and against the actual RTL over all 2,621,440
dwords in sim/tb_snd_window.cpp. So "derivable" here means derivable through the
decode the hardware will really use, not through a convenient Python shortcut.

Usage:
    tools/check_flash_derive.py <set>.zip <image.bin> [--set NAME]
    tools/check_flash_derive.py --all <romdir> [--keep DIR]

--all builds each set's authentic-flash SDRAM image with build_sdram_image.py
into a temporary directory and checks every one it can build.
"""

import hashlib
import os
import subprocess
import sys
import tempfile
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from build_soundflash import GAMES, build, build_from, detect
from check_snd01_window import (PCMSRC_BASE, PCMSRC_SIZE, SND01_BASE,
                                SND01_SIZE, rtl_dword)

# rtl/spi_defs.vh, and the 386's map from build_soundflash.
PRG_BASE_SDR = 0x0000000
PRG_SIZE = 0x200000
S01_BASE = 0x00A00000
S01_SIZE = 0x00A00000


def prg_from_image(img):
    """The 386's program image: the loader already scattered it into 386 order.

    rom_loader places the four byte-lane ROMs with ROM_LOAD32_BYTE exactly as
    MAME's region does, so this is a plain slice and not a decode. That is why
    a job whose source is the PROGRAM ROM -- viprp1's second one, the case no
    MRA can assemble a pre-flashed image for -- costs nothing here.
    """
    prg = img[PRG_BASE_SDR:PRG_BASE_SDR + PRG_SIZE]
    if len(prg) != PRG_SIZE:
        raise SystemExit("image is %d bytes; the program region alone is %d"
                         % (len(img), PRG_SIZE))
    return prg


def region_from_image(img, setname):
    """MAME's 10 MB sound01 region, rebuilt through the RTL's window decode.

    Every dword of it, because a job may point anywhere in it and the whole
    point is that nothing outside the image is consulted. Addresses no window
    claims read back as 0, which is what MAME's ROMREGION_ERASE00 holds.
    """
    base = PCMSRC_BASE[setname]
    if len(img) < base + PCMSRC_SIZE:
        # A 1 MB gen-A source occupies half the window; a short image is still
        # an error, but say which region ran off the end rather than "too small".
        if len(img) < SND01_BASE + SND01_SIZE:
            raise SystemExit("image stops before the sound1 region at %#x"
                             % SND01_BASE)
    pcm = img[base:base + PCMSRC_SIZE].ljust(PCMSRC_SIZE, b"\xFF")
    snd = img[SND01_BASE:SND01_BASE + SND01_SIZE].ljust(SND01_SIZE, b"\xFF")

    g = GAMES[setname]
    one_lane = g["sound01"][0][2] == 1
    # A set with no second sound ROM must have that window SHUT, or the region
    # reads 0xFF out of SDRAM nothing wrote where MAME reads 0x00 -- viprp1's
    # bug, and the reason these two enables are separate at all.
    snd01_en = any(base_off == 0x800000 for _, base_off, _ in g["sound01"])

    region = bytearray(S01_SIZE)
    for off in range(0, S01_SIZE, 4):
        dw = rtl_dword(S01_BASE + off, pcm, snd,
                       pcmsrc_en=True, snd01_en=snd01_en, one_lane=one_lane)
        region[off:off + 4] = dw.to_bytes(4, "little")
    return bytes(region)


def derive(img, setname, quiet=True):
    """The flash image, from the SDRAM image and nothing else."""
    return build_from(prg_from_image(img), region_from_image(img, setname),
                      GAMES[setname], quiet=quiet)


def check(setname, zpath, ipath):
    img = open(ipath, "rb").read()
    got = derive(img, setname)

    with zipfile.ZipFile(zpath) as zf:
        want = build(zf, setname, quiet=True)

    h_got = hashlib.sha256(got).hexdigest()
    h_want = hashlib.sha256(want).hexdigest()
    ref = GAMES[setname].get("sha256")

    print("%s:" % setname)
    print("  from image %s" % h_got)
    print("  from zip   %s" % h_want)
    if got != want:
        n = sum(1 for a, b in zip(got, want) if a != b)
        first = next(i for i, (a, b) in enumerate(zip(got, want)) if a != b)
        print("  FAIL: %d of %d bytes differ, first at %#x (%02X vs %02X)"
              % (n, len(want), first, got[first], want[first]))
        return 1
    if ref and h_got != ref:
        print("  FAIL: matches the zip route but neither matches the recorded "
              "reference %s" % ref)
        return 1
    print("  PASS: identical%s" % (", and equals the recorded reference"
                                   if ref else ""))
    return 0


# A clone has no zip of its own in a merged set: its ROMs live in the parent's,
# under a subdirectory, which is what build_soundflash's zread() already walks.
PARENT = {"batlball": "senkyu"}


def zip_for(romdir, setname):
    for candidate in (setname, PARENT.get(setname)):
        if candidate:
            p = os.path.join(romdir, candidate + ".zip")
            if os.path.exists(p):
                return p
    return None


def build_image(tools, romdir, setname, outdir):
    """Build this set's authentic-flash SDRAM image, the way sim/ does."""
    zpath = zip_for(romdir, setname)
    if zpath is None:
        return None, "no zip for %s" % setname
    out = os.path.join(outdir, setname + "-upd.bin")
    r = subprocess.run([sys.executable,
                        os.path.join(tools, "build_sdram_image.py"),
                        zpath, out, "--upd", "--set", setname],
                       capture_output=True, text=True)
    if r.returncode:
        return None, (r.stderr or r.stdout).strip().splitlines()[-1]
    return out, None


def main():
    tools = os.path.dirname(os.path.abspath(__file__))
    if "--all" in sys.argv:
        romdir = sys.argv[sys.argv.index("--all") + 1]
        keep = (sys.argv[sys.argv.index("--keep") + 1]
                if "--keep" in sys.argv else None)
        tmp = keep or tempfile.mkdtemp(prefix="flashderive-")
        os.makedirs(tmp, exist_ok=True)
        rc = 0
        skipped = []
        for setname in sorted(GAMES):
            ipath, why = build_image(tools, romdir, setname, tmp)
            if ipath is None:
                skipped.append((setname, why))
                continue
            rc |= check(setname, zip_for(romdir, setname), ipath)
        # Say what was NOT covered. A sweep that quietly skips half the family
        # reads exactly like one that passed on all of it.
        for setname, why in skipped:
            print("%s: SKIPPED -- %s" % (setname, why))
        if skipped:
            print("\n%d of %d sets checked; the rest have no SDRAM image to "
                  "build from" % (len(GAMES) - len(skipped), len(GAMES)))
        return rc

    if len(sys.argv) < 3:
        raise SystemExit(__doc__.strip())
    zpath, ipath = sys.argv[1], sys.argv[2]
    if "--set" in sys.argv:
        setname = sys.argv[sys.argv.index("--set") + 1]
    else:
        with zipfile.ZipFile(zpath) as zf:
            setname = detect(zf)
    return check(setname, zpath, ipath)


if __name__ == "__main__":
    sys.exit(main())
