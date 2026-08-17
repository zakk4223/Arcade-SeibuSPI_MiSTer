#!/usr/bin/env python3
"""
Check the 386's sound01 window decode in rtl/spi_cpu.sv against MAME's region.

The authentic-flash MRAs make the game program its own sample flash, and the
material it programs comes out of MAME's `sound01` region through the 386's
address space (PLAN.md 17.2). That region is 10 MB and sparse: two ROMs scatter
across it on different numbers of byte lanes, with a 2 MB hole in the middle
where MAME's ROM_CONTINUE skips. The core stores both ROMs PACKED and rebuilds
that view on the fly, which is a piece of address arithmetic with no natural
error signal -- an undecoded window reads as zero, the updater programs the
zeroes without complaint, and the game says UPDATE COMPLETED.

So this checks it, over the WHOLE region rather than the parts we expect to be
populated:

    for every dword in 00A0_0000-013F_FFFF
        what spi_cpu.sv's arithmetic returns, out of the packed SDRAM contents
        ==
        what MAME's region holds there

Covering the holes is the point. A decode that reads the right windows but
misses a third one still passes a spot check of the first two; here a missed
window shows up as "we answer 0 and MAME has data".

The reference is tools/build_soundflash.py's load_sound01(), which is the same
code whose flash images match MAME's own nvram bit for bit for all seven sets.

With --image it reads the two packed ROMs out of a built SDRAM image instead of
out of the zip, which extends the check by one link: the loader's PLACEMENT is
then part of what is being verified, not just the decode arithmetic. An image
built with the wrong base, or an authentic table that forgot a part, fails here
rather than on hardware.

    tools/build_sdram_image.py rdft.zip upd.bin --upd --set rdft
    tools/check_snd01_window.py rdft.zip --set rdft --image upd.bin

Usage:
    tools/check_snd01_window.py <set>.zip [--set NAME] [--image sdram.bin]
    tools/check_snd01_window.py --all <romdir>
"""

import os
import sys
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from build_soundflash import GAMES, S01_BASE, S01_SIZE, detect, load_sound01, zread

# Must match rtl/spi_defs.vh. The bases matter only for --image; without it the
# two packed ROMs come straight out of the zip and are indexed from zero.
#
# PCMSRC's base is PER-SET -- it follows that set's own sprites so the SEI252
# families still fit a 32 MB module -- so an image can only be indexed once the
# set is known. Everything else in the map is common to every set.
SPRITES_BASE = 0x1100000
PCMSRC_BASE = {
    "senkyu":   SPRITES_BASE + 3 * 0x400000,
    "batlball": SPRITES_BASE + 3 * 0x400000,
    "ejanhs":   SPRITES_BASE + 3 * 0x400000,
    "viprp1":   SPRITES_BASE + 3 * 0x400000,
    "rdft":     SPRITES_BASE + 3 * 0x400000,
    "rdft2":    SPRITES_BASE + 3 * 0x600000,
    "rfjet":    SPRITES_BASE + 3 * 0x800000,
}
PCMSRC_SIZE = 0x200000
SND01_BASE = 0x0480000
SND01_SIZE = 0x080000


def rtl_dword(addr, pcm, snd, pcmsrc_en=True, snd01_en=True, one_lane=False):
    """A literal transcription of the decode in rtl/spi_cpu.sv.

    Deliberately literal -- bit selects rather than the tidier arithmetic they
    add up to -- because the thing being checked IS the bit selects. A cleaner
    restatement here could be wrong in exactly the same way the RTL is.
    """
    byte_addr = addr
    cur_dw = addr >> 2

    sel_s01 = snd01_en and (byte_addr >> 21) == 0x009
    sel_pcm = (pcmsrc_en and (byte_addr >> 24) == 0
               and (byte_addr >> 23) & 1 and (byte_addr >> 21) & 1)

    if sel_s01:
        # s01_grp_addr = SDR_SND01_BASE + {cur_dw[18:3], 3'b000}
        # s01_byte     = rom_data[{cur_dw[2:0], 3'b000} +: 8]
        grp = ((cur_dw >> 3) & 0xFFFF) << 3
        return snd[grp + (cur_dw & 7)]

    if sel_pcm and one_lane:
        # Generation A. pcm_grp_addr = pcmsrc_base +
        #   {cur_dw[20], cur_dw[18:3], 3'b000}, byte at cur_dw[2:0]
        grp = ((((cur_dw >> 20) & 1) << 16) | ((cur_dw >> 3) & 0xFFFF)) << 3
        return pcm[grp + (cur_dw & 7)]

    if sel_pcm:
        # pcm_grp_addr = pcmsrc_base + {cur_dw[20], cur_dw[18:2], 3'b000}
        # pcm_pair     = rom_data[{cur_dw[1:0], 4'b0000} +: 16]
        grp = ((((cur_dw >> 20) & 1) << 17) | ((cur_dw >> 2) & 0x1FFFF)) << 3
        off = (cur_dw & 3) << 1
        return pcm[grp + off] | (pcm[grp + off + 1] << 8)

    # Everything else falls through to S_NULL, which answers zeroes.
    return 0


def packed_roms(zf, setname):
    """What the loader puts at the set's PCMSRC base and SDR_SND01_BASE.

    Which ROM is which comes from the same table build_soundflash.py drives the
    region from -- two byte lanes per dword is the PCM source, one is the second
    sound ROM at region 0x800000. viprp1 has no second ROM at all.

    A 2-lane PCM source is a GEN-B fact, not a cartridge fact: senkyu, ejanhs
    and viprp1 put a 1 MB PCM ROM on ONE lane instead. The two windows land in
    the same place either way -- a 1 MB ROM at one lane spans exactly what a
    2 MB ROM at two lanes does, including the ROM_CONTINUE skip -- so it is one
    more bit of mode in the decode rather than new windows. viprp1 is the first
    gen-A set with a part table, and senkyu and ejanhs are checked here too even
    though nothing loads them yet: the decode is the same either way.
    """
    pcm = bytes(PCMSRC_SIZE)
    snd = bytes(SND01_SIZE)
    for name, base, lanes in GAMES[setname]["sound01"]:
        data = zread(zf, setname, name)
        if base == 0:
            pcm = data.ljust(PCMSRC_SIZE, b"\xFF")[:PCMSRC_SIZE]
        elif base == 0x800000:
            snd = data.ljust(SND01_SIZE, b"\xFF")[:SND01_SIZE]
        else:
            raise SystemExit("%s: a sound01 ROM at %06X, which is neither "
                             "window" % (setname, base))
    return pcm, snd


def packed_from_image(path, setname):
    """The same two ROMs, read out of a built SDRAM image at their map bases."""
    img = open(path, "rb").read()
    base = PCMSRC_BASE[setname]
    need = base + PCMSRC_SIZE
    if len(img) < need:
        raise SystemExit("%s is %d bytes; %s's authentic image is %d. A "
                         "pre-flashed one has nothing at PCMSRC."
                         % (path, len(img), setname, need))
    return (img[base:base + PCMSRC_SIZE],
            img[SND01_BASE:SND01_BASE + SND01_SIZE])


def check(zf, setname, image=None):
    region = load_sound01(zf, setname, GAMES[setname]["sound01"])
    pcm, snd = (packed_from_image(image, setname) if image
                else packed_roms(zf, setname))
    one_lane = GAMES[setname]["sound01"][0][2] == 1
    # snd01_en in spi_top.sv means "this set has a second sound ROM", not "this
    # is an authentic MRA": a set without one must leave the window undecoded so
    # it reads as MAME's ERASE00 zeroes rather than as unwritten SDRAM.
    has_snd = any(base == 0x800000 for _, base, _ in GAMES[setname]["sound01"])

    bad = 0
    first_bad = None
    nonzero_seen = 0
    nonzero_ok = 0
    for off in range(0, S01_SIZE, 4):
        want = int.from_bytes(region[off:off + 4], "little")
        got = rtl_dword(S01_BASE + off, pcm, snd, snd01_en=has_snd,
                        one_lane=one_lane)
        if want:
            nonzero_seen += 1
        if got == want:
            if want:
                nonzero_ok += 1
            continue
        bad += 1
        if first_bad is None:
            first_bad = (S01_BASE + off, want, got)

    if bad:
        addr, want, got = first_bad
        print("  FAIL: %d of %d dwords differ; first at %08X: MAME %08X, core %08X"
              % (bad, S01_SIZE // 4, addr, want, got))
        return 1

    # A decode that answered zero everywhere would also "match" a region that
    # happened to be empty, so say how much of it was actually data.
    print("  PASS: %d dwords, %d of them populated and all matching"
          % (S01_SIZE // 4, nonzero_ok))
    if nonzero_seen == 0:
        print("  FAIL: the region is entirely zero, so nothing was checked")
        return 1
    return 0


def main():
    argv = sys.argv[1:]
    setname = None
    image = None
    if "--set" in argv:
        k = argv.index("--set")
        setname = argv[k + 1]
        del argv[k:k + 2]
    if "--image" in argv:
        k = argv.index("--image")
        image = argv[k + 1]
        del argv[k:k + 2]

    if "--all" in argv:
        k = argv.index("--all")
        romdir = argv[k + 1]
        rc = 0
        for name in sorted(GAMES):
            path = os.path.join(romdir, name + ".zip")
            if not os.path.exists(path):
                print("%s: SKIP, no %s" % (name, path))
                continue
            print("%s:" % name)
            rc |= check(zipfile.ZipFile(path), name)
        return rc

    args = [a for a in argv if not a.startswith("--")]
    if not args:
        raise SystemExit(__doc__)
    zf = zipfile.ZipFile(args[0])
    if setname is None:
        setname = detect(zf)
    print("%s%s:" % (setname, " (from %s)" % image if image else ""))
    return check(zf, setname, image)


if __name__ == "__main__":
    sys.exit(main())
