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

--upd builds the AUTHENTIC-FLASH image instead (PLAN.md section 17): MAME's own
blank flash in the sample region and the two ROMs the game's updater reads to
program it, one of them in a region a pre-flashed image never writes. That is
the image an `-update` MRA produces, and the only one with anything behind the
386's sound01 source window. 43 MB rather than 41.

Usage:
    tools/build_sdram_image.py rdft.zip out.bin [--region tiles,chars] [--sums]
    tools/build_sdram_image.py rdft.zip upd.bin --upd

--sums prints the four region checksums in the exact form rtl/spi_romcheck.sv
declares them, so the hardware checker's constants can be re-derived rather than
remembered. They go stale whenever a region's LAYOUT changes, which is not the
same as its contents changing -- see the note above print_romcheck_sums().
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
    "snd01":   0x0480000,
    "tiles":   0x0500000,
    "sprites": 0x1100000,
}
# `pcmsrc` is NOT in BASE, because it is the one region whose base depends on
# the set: it follows that set's OWN sprites rather than sitting above the
# largest set's, so an authentic-flash SEI252 game still fits a 32 MB module.
# SETS carries the value per set and it is spliced into a per-run copy of BASE.
# These three must match SDR_PCMSRC_* in rtl/spi_defs.vh.
PCMSRC_SEI252 = BASE["sprites"] + 3 * 0x400000   # 0x1D00000, 29 MB
PCMSRC_RDFT2  = BASE["sprites"] + 3 * 0x600000   # 0x2300000, 35 MB
PCMSRC_RFJET  = BASE["sprites"] + 3 * 0x800000   # 0x2900000, 41 MB

# A pre-flashed image stops at the top of the sprite region, which is the same
# 41 MB for every set -- kept flat so those images stay byte-identical to what
# every earlier run produced. An authentic-flash image ends just above its own
# pcmsrc, which is why --upd's size is computed per set rather than fixed.
SDRAM_SIZE = 0x2900000

# (region, crc32, size, mode, offset-within-region[, source-index bias[, slice]])
# Mode names match the scatter modes in rtl/rom_loader.sv. `slice` is a byte
# offset into the FILE, for the one part that takes a piece of a ROM rather than
# all of it; `size` is then the length of that piece and the CRC still covers the
# whole file, the way the MRA's crc= attribute does.
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

# rdft, the SPI cartridge's first set. Order and modes are rom_loader.sv's rdft
# table. Four byte lanes for the program and three for the text layer, where
# rdfts has word+byte pairs, and no audiocpu part at all -- that region is RAM
# the 386 fills through port 0x688.
PARTS_RDFT = [
    ("prg",     0xadcb5dbc,  0x80000, "W32_B0",  0),
    ("prg",     0x60c5b92e,  0x80000, "W32_B1",  0),
    ("prg",     0x44b86db5,  0x80000, "W32_B2",  0),
    ("prg",     0xe70727ce,  0x80000, "W32_B3",  0),
    ("chars",   0x8f8d4e14,  0x10000, "W24_B0",  0),
    ("chars",   0x6ac64968,  0x10000, "W24_B1",  0),
    ("chars",   0x4d87e1ea,  0x10000, "W24_B2",  0),
    ("tiles",   0x6a68054c, 0x200000, "W24_W01", 0),
    ("tiles",   0x3400794a, 0x100000, "W24_B2",  0),
    ("tiles",   0x61cd2991, 0x200000, "W24_W01", 0x300000),
    ("tiles",   0x502d5799, 0x100000, "W24_B2",  0x300000),
    ("sprites", 0x59d86c99, 0x400000, "SPR_ILV", 0),
    ("sprites", 0x1ceb0b6f, 0x400000, "SPR_ILV", 2),
    ("sprites", 0x36e93234, 0x400000, "SPR_ILV", 4),
    # pcm is not a part: derived, see FLASH below. rdft has no snd01 part
    # either -- its Z80 program is inside `maincpu`, not sound1.u0222 -- so the
    # only thing that ever puts seibu_8.u0216 in SDRAM is --upd.
]

# viprp1, the fifth set and the first generation-A one. Authentic flash ONLY --
# its pre-flashed image cannot be assembled from file slices, because the second
# of its two compressed jobs reads the 386's interleaved program image.
PARTS_VIPRP1 = [
    ("prg",     0xe5caf4ff,  0x80000, "W32_B0",  0),
    ("prg",     0x688a998e,  0x80000, "W32_B1",  0),
    ("prg",     0x990fa76a,  0x80000, "W32_B2",  0),
    ("prg",     0x13e3e343,  0x80000, "W32_B3",  0),
    ("chars",   0x5ece677c,  0x20000, "W24_W01", 0),
    ("chars",   0x44844ef8,  0x10000, "W24_B2",  0),
    ("tiles",   0x6fc96736, 0x200000, "W24_W01", 0),
    ("tiles",   0xd3c7281c, 0x100000, "W24_B2",  0),
    ("tiles",   0xd65b4318, 0x100000, "W24_W01", 0x300000),
    ("tiles",   0x24a0a23a,  0x80000, "W24_B2",  0x300000),
    ("sprites", 0x3be5b631, 0x400000, "SPR_ILV", 0),
    ("sprites", 0x924153b4, 0x400000, "SPR_ILV", 2),
    ("sprites", 0xe9fb9062, 0x400000, "SPR_ILV", 4),
]

# senkyu and ejanhs: the other two generation-A cartridges, and the only ones
# whose program sits in the UPPER half of the region behind a megabyte of zero
# fill. They are here for the flash derivation (tools/check_flash_derive.py):
# viprp1 is generation A too but has NO second sound ROM, so without these the
# gen-A-plus-sound1-window path is never exercised end to end. Authentic-flash
# only, like viprp1 -- no pre-flashed variant is built for either.
PARTS_SENKYU = [
    ("prg",     None,      0x100000, "LINEAR",  0),
    ("prg",     0x20a3e5db, 0x40000, "W32_B0",  0x100000),
    ("prg",     0x38e90619, 0x40000, "W32_B1",  0x100000),
    ("prg",     0x226f0429, 0x40000, "W32_B2",  0x100000),
    ("prg",     0xb46d66b7, 0x40000, "W32_B3",  0x100000),
    ("chars",   0xb57115c9, 0x20000, "W24_W01", 0),
    ("chars",   0x440a9ae3, 0x10000, "W24_B2",  0),
    # One bg group where every other set has two.
    ("tiles",   0xeae7a1fc, 0x200000, "W24_W01", 0),
    ("tiles",   0xb46e774e, 0x100000, "W24_B2",  0),
    ("sprites", 0x29f86f68, 0x400000, "SPR_ILV", 0),
    ("sprites", 0xc9e3130b, 0x400000, "SPR_ILV", 2),
    ("sprites", 0xf6c3bc49, 0x400000, "SPR_ILV", 4),
]

PARTS_EJANHS = [
    ("prg",     None,      0x100000, "LINEAR",  0),
    ("prg",     0xe626d3d2, 0x40000, "W32_B0",  0x100000),
    ("prg",     0x83c39da2, 0x40000, "W32_B1",  0x100000),
    ("prg",     0x46897b7d, 0x40000, "W32_B2",  0x100000),
    ("prg",     0xb3187a2b, 0x40000, "W32_B3",  0x100000),
    ("chars",   0x837e012c, 0x20000, "W24_W01", 0),
    ("chars",   0xd62db7bf, 0x10000, "W24_B2",  0),
    ("tiles",   0xbcacabe0, 0x200000, "W24_W01", 0),
    ("tiles",   0x1fd0eb5e, 0x100000, "W24_B2",  0),
    ("tiles",   0xea2acd69, 0x100000, "W24_W01", 0x300000),
    ("tiles",   0xa4a9cb0f,  0x80000, "W24_B2",  0x300000),
    ("sprites", 0x852f180e, 0x400000, "SPR_ILV", 0),
    ("sprites", 0x1116ad08, 0x400000, "SPR_ILV", 2),
    ("sprites", 0xccfe02b6, 0x400000, "SPR_ILV", 4),
]

# batlball is senkyu with four different program ROMs and a different region
# byte in the blank flash -- nothing else changes, which is what a clone IS on
# this board. Derived from senkyu's table rather than copied, so the claim
# "only the program differs" is structural and cannot drift.
PARTS_BATLBALL = ([("prg", None, 0x100000, "LINEAR", 0)]
                  + [("prg", crc, 0x40000, mode, 0x100000) for crc, mode in
                     ((0xd4e48f89, "W32_B0"), (0x3077720b, "W32_B1"),
                      (0x520d31e1, "W32_B2"), (0x22419b78, "W32_B3"))]
                  + [p for p in PARTS_SENKYU if p[0] != "prg"])

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
    # sound1.u0222 holds rdft2's Z80 program at 0x60000, which the 386 reads
    # through the sound01 window. Carried WHOLE -- see SDR_SND01_BASE in
    # rtl/spi_defs.vh -- and packed one byte per 386 dword, so it is a plain
    # copy here and spi_cpu.sv does the unpacking.
    ("snd01",   0xb7bd3703,  0x80000, "LINEAR",  0),
]

# rfjet. Same shape as rdft2 and almost no shared numbers: 9 MB of tiles, three
# 8 MB sprite chunks of one ROM each, and MAME's sprite order is the numeric one
# here where rdft2's is reversed.
PARTS_RFJET = [
    ("prg",     0xe5a3b304,  0x80000, "W32_B0",  0),
    ("prg",     0x395e6da7,  0x80000, "W32_B1",  0),
    ("prg",     0x82f7a57e,  0x80000, "W32_B2",  0),
    ("prg",     0xcbdf100d,  0x80000, "W32_B3",  0),
    ("chars",   0x8bc080be,  0x10000, "W24_B1",  0),
    ("chars",   0xbded85e7,  0x10000, "W24_B0",  0),
    ("chars",   0x015d0748,  0x10000, "W24_B2",  0),
    ("tiles",   0xedfd96da, 0x400000, "W24_W01", 0),
    ("tiles",   0xa4cc4631, 0x200000, "W24_B2",  0),
    ("tiles",   0x731fbb59, 0x200000, "W24_W01", 0x600000),
    ("tiles",   0x03652c25, 0x100000, "W24_B2",  0x600000),
    ("sprites", 0x58a59896, 0x800000, "SPR_ILV_R", 0),
    ("sprites", 0xa121d1e3, 0x800000, "SPR_ILV_R", 2),
    ("sprites", 0xbc2c0c63, 0x800000, "SPR_ILV_R", 4),
    ("snd01",   0xd4fc3da1,  0x80000, "LINEAR",  0),
]

# Sets, detected by the CRC of their first program ROM. `flash_stream` is what
# the MRA sends for the two derived sample parts, which --concat has to
# reproduce byte for byte: the verbatim slice, then the COMPRESSED tail. Both
# lengths come out of tools/build_soundflash.py's job-table walk.
#
# `upd` is the authentic-flash variant (--upd): instead of a derived image the
# sample region gets MAME's own blank flash, and the two ROMs the game's updater
# reads become parts of their own. All three sets take the SAME blank -- the
# region byte lives in it, and region80 is what every parent set carries.
# rom_loader.sv's authentic tail is these three parts in this order.
BLANK_FLASH = 0xe2adaff5        # flash0_blank_region80.u1053, 1 MB
BLANK_VIPRP1 = 0xa4c181d0       # flash0_blank_regionbe.u1053, viprp1's region
BLANK_REGION01 = 0x7ae7ab76     # flash0_blank_region01.u1053, senkyu/ejanhs
SETS = {
    "rdfts": dict(parts=PARTS_RDFTS, probe=0xe278dddd, flash=False),
    "rdft":  dict(parts=PARTS_RDFT,  probe=0xadcb5dbc, flash=True,
                  pcmsrc=PCMSRC_SEI252,
                  # rdft's image is a plain concatenation rather than a decoded
                  # one, so its stream carries a trailing FF fill the other two
                  # do not: 4 + 0x1A13B2 + 0x3828D + 0x269BD = 0x200000.
                  flash_stream=(("gun_dogs_pcm.u0217", 4, 0x1A13B6),
                                ("seibu_8.u0216", 0, 0x3828D)),
                  flash_fill=0x269BD,
                  upd=(0x31253ad7, 0xf88cb6e4)),
    "rdft2": dict(parts=PARTS_RDFT2, probe=0x3cb3fdca, flash=True,
                  pcmsrc=PCMSRC_RDFT2,
                  flash_stream=(("pcm.u0217", 4, 0x17C247),
                                ("sound1.u0222", 0, 0x4C665)),
                  upd=(0x2edc30b5, 0xb7bd3703)),
    "rfjet": dict(parts=PARTS_RFJET, probe=0xe5a3b304, flash=True,
                  pcmsrc=PCMSRC_RFJET,
                  flash_stream=(("pcm-d.u0227", 4, 0x189DD5),
                                ("sound1.u0222", 0, 0x41C08)),
                  upd=(0x8ee3ff45, 0xd4fc3da1)),
    # viprp1 has NO pre-flashed form here: `flash` is False and there is no
    # flash_stream, so a plain build leaves the sample region blank. --upd is
    # the only mode that produces a runnable image, and its PCM source is 1 MB
    # rather than 2 and has no second sound ROM behind it.
    "viprp1": dict(parts=PARTS_VIPRP1, probe=0xe5caf4ff, flash=False,
                   pcmsrc=PCMSRC_SEI252,
                   upd=(0xe3111b60, None), upd_pcm_size=0x100000,
                   upd_blank=BLANK_VIPRP1),
    # Generation A WITH a second sound ROM, which viprp1 is not. Their PCM
    # source is 1 MB on one lane, same as viprp1's, and MAME loads it 512 KB at
    # a time with a ROM_CONTINUE to 0x400000 -- the bank skip build_soundflash's
    # bank() and spi_snd_window both already handle.
    "senkyu": dict(parts=PARTS_SENKYU, probe=0x20a3e5db, flash=False,
                   pcmsrc=PCMSRC_SEI252,
                   upd=(0x1d83891c, 0x874d7b59), upd_pcm_size=0x100000,
                   upd_blank=BLANK_REGION01),
    "batlball": dict(parts=PARTS_BATLBALL, probe=0xd4e48f89, flash=False,
                     pcmsrc=PCMSRC_SEI252,
                     upd=(0x1d83891c, 0x874d7b59), upd_pcm_size=0x100000,
                     upd_blank=BLANK_FLASH),
    "ejanhs": dict(parts=PARTS_EJANHS, probe=0xe626d3d2, flash=False,
                   pcmsrc=PCMSRC_SEI252,
                   upd=(0xa92a3a82, 0xc6fc6bcf), upd_pcm_size=0x100000,
                   upd_blank=BLANK_REGION01),
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

    # --upd builds the authentic-flash image (PLAN.md section 17): a BLANK
    # sample flash plus the two ROMs the game's own updater reads to program it,
    # instead of a derived image. This is the image an `-update` MRA produces,
    # and the only one the 386's sound01 source window has anything behind.
    upd = "--upd" in sys.argv

    want_regions = None
    if "--region" in sys.argv:
        want_regions = set(sys.argv[sys.argv.index("--region") + 1].split(","))

    zf = zipfile.ZipFile(zpath)
    by_crc = {}
    for info in zf.infolist():
        by_crc.setdefault(info.CRC, info.filename)

    # A MERGED zip holds its clones' ROMs too, and rdfts is a clone of rdft, so
    # rdft.zip matches both -- the probe CRCs are all present in the one file.
    # First match wins, and SETS is ordered so that stays rdfts, which is what
    # every existing invocation means by rdft.zip. --set picks the other one.
    matches = [n for n, c in SETS.items() if c["probe"] in by_crc]
    if "--set" in sys.argv:
        setname = sys.argv[sys.argv.index("--set") + 1]
        if setname not in SETS:
            raise SystemExit("no such set %s (have: %s)"
                             % (setname, ", ".join(sorted(SETS))))
        if setname not in matches:
            raise SystemExit("%s does not contain %s's ROMs" % (zpath, setname))
    elif matches:
        setname = matches[0]
        if len(matches) > 1:
            print("note: %s also matches %s; --set picks one"
                  % (os.path.basename(zpath),
                     ", ".join(m for m in matches[1:])))
    else:
        raise SystemExit("%s is none of %s" % (zpath, ", ".join(sorted(SETS))))
    cfg = SETS[setname]
    PARTS = cfg["parts"]
    print("set: %s%s" % (setname, ", authentic flash" if upd else ""))

    if upd:
        if "upd" not in cfg:
            raise SystemExit("%s has no authentic-flash variant" % setname)
        pcm_crc, snd_crc = cfg["upd"]
        # The tail rom_loader.sv walks when set_upd is set. The blank flash is
        # only 1 MB: the second E28F008SA has no dump in MAME because it is
        # erased, and this image starts life as 0xFF, so chip 1 is already
        # right. rdft2 and rfjet already carry `snd01` as a part; it is dropped
        # and re-added in place so the order matches the loader's table for
        # every set, which is what --concat depends on. That order is MAME's own
        # region order -- sound01's two ROMs, then soundflash1's blank.
        tail = [("pcmsrc", pcm_crc, cfg.get("upd_pcm_size", 0x200000), "LINEAR", 0)]
        # viprp1 has no second sound ROM: its compressed tail lives in the 386
        # program image, which needs no part of its own.
        if snd_crc is not None:
            tail.append(("snd01", snd_crc, 0x080000, "LINEAR", 0))
        tail.append(("pcm", cfg.get("upd_blank", BLANK_FLASH), 0x100000, "LINEAR", 0))
        PARTS = [p for p in PARTS if p[0] != "snd01"] + tail

    # `pcmsrc` is the one per-set base, and only --upd writes it. Splicing it in
    # here rather than keeping it in BASE means a pre-flashed build cannot
    # accidentally resolve it at all -- there is no entry to resolve.
    base_of = dict(BASE)
    image_size = SDRAM_SIZE
    if upd:
        base_of["pcmsrc"] = cfg["pcmsrc"]
        top = cfg["pcmsrc"] + cfg.get("upd_pcm_size", 0x200000)
        # The image file keeps its historical 41 MB floor whatever the set's own
        # top is -- shrinking it would move nothing in the map and would only
        # invalidate every SDRAM= path in sim/. What the fit is actually stated
        # in terms of is `top`, so print that.
        image_size = max(image_size, top)
        print("map top: %d MB (pcmsrc at %d MB)"
              % (top >> 20, cfg["pcmsrc"] >> 20))

    image = bytearray(b"\xFF" * image_size)
    placed = 0

    for part in PARTS:
        region, crc, size, mode, off = part[:5]
        skip = part[5] if len(part) > 5 else 0
        sl = part[6] if len(part) > 6 else None
        if want_regions and region not in want_regions:
            continue
        if crc is None:
            # Not a file: a run of zeroes MAME's region has and no ROM supplies.
            # senkyu and ejanhs put their program in the UPPER half of a 2 MB
            # region, and MAME's ROM_REGION32_LE leaves the lower half 00 --
            # which an image starting life as 0xFF would otherwise get wrong,
            # and the derivation reads the whole program image.
            name, data = "zero fill", bytes(size)
        else:
            name = by_crc.get(crc)
            if name is None:
                raise SystemExit("missing ROM crc %08x for region %s"
                                 % (crc, region))
            data = zf.read(name)
            # The CRC covers the whole file whether or not this part is a slice
            # of it, so check it before cutting.
            if binascii.crc32(data) & 0xFFFFFFFF != crc:
                raise SystemExit("%s failed CRC check" % name)
        if sl is not None:
            data = data[sl:sl + size]
        if len(data) != size:
            raise SystemExit("%s is %d bytes, expected %d" % (name, len(data), size))

        base = base_of[region] + off
        for i, b in enumerate(data):
            image[base + dest_of(mode, i + skip)] = b
        placed += 1
        print("  %-8s %-28s %8d  %s" % (region, name, size, mode))

    # rdft2's sample flash is not a ROM. It is the region stamp, a verbatim
    # slice of pcm.u0217, and half a megabyte the game's own 386 decompresses --
    # the same image tools/build_soundflash.py rebuilds and checks by sha256
    # against what MAME's flash devices hold.
    if cfg["flash"] and not upd and (not want_regions or "pcm" in want_regions):
        from build_soundflash import build as build_flash
        flash = build_flash(zf, setname)
        image[BASE["pcm"]:BASE["pcm"] + len(flash)] = flash
        placed += 1
        print("  %-8s %-28s %8d  derived" % ("pcm", "sample flash", len(flash)))

    if concat:
        # This has to be the MRA's <part> order, which is the loader's table
        # order -- not the order of PARTS, whose sample-flash parts are derived
        # and so are not in it at all. The snd01 slice is table part 16 and
        # therefore follows them, even though it is listed above them here.
        def part_bytes(part):
            data = zf.read(by_crc[part[1]])
            sl = part[6] if len(part) > 6 else None
            return data if sl is None else data[sl:sl + part[2]]

        blob = bytearray()
        for part in PARTS:
            # Pre-flashed, `snd01` is table part 16 and therefore LAST, even
            # though PARTS lists it above the derived sample parts. Authentic,
            # PARTS is already in table order and nothing needs deferring.
            if upd or part[0] != "snd01":
                blob += part_bytes(part)
                # The authentic flash part is 2 MB of which MAME dumps only the
                # first chip; the MRA supplies the second as <part repeat>, so
                # the stream has to carry it too.
                if upd and part[0] == "pcm":
                    blob += b"\xFF" * 0x100000
        if cfg["flash"] and not upd:
            # Exactly what the MRA sends for the two sample parts: the stamp and
            # a slice of the pcm ROM, then the COMPRESSED tail. The loader
            # decodes the second one on the way in, so the concatenated stream
            # is shorter than the image it produces.
            blob += bytes(image[BASE["pcm"]:BASE["pcm"] + 4])   # region stamp
            for name, start, end in cfg["flash_stream"]:
                blob += zf.read(name)[start:end]
            # rdft's payload is a plain concatenation and stops short of 2 MB,
            # so its MRA pads with <part repeat>. The decoded sets have no fill:
            # their second part expands to the end on its own.
            blob += b"\xFF" * cfg.get("flash_fill", 0)
        if not upd:
            for part in PARTS:
                if part[0] == "snd01":
                    blob += part_bytes(part)
        with open(outpath, "wb") as f:
            f.write(blob)
        print("wrote %s (concatenated stream, %d bytes)" % (outpath, len(blob)))
        return

    with open(outpath, "wb") as f:
        f.write(image)
    print("wrote %s (%d parts, %d bytes)" % (outpath, placed, len(image)))

    if "--sums" in sys.argv:
        print_romcheck_sums(image)


# rtl/spi_romcheck.sv walks four regions on hardware and compares them against
# constants that live in that file. Nothing checked those constants against the
# image, so when the sprite interleave permuted the sprite bytes the SPRITES
# constant went stale and the checker reported a failure on a perfect download.
# Print them here, where they are derived, so re-deriving is one command.
def print_romcheck_sums(image):
    import struct

    regions = [
        ("SUM_PRG",     BASE["prg"],     0x200000),
        ("SUM_CHARS",   BASE["chars"],   0x030000),
        ("SUM_TILES",   BASE["tiles"],   0x600000),
        ("SUM_SPRITES", BASE["sprites"], 0xC00000),
    ]
    print("\nrtl/spi_romcheck.sv constants for this image:")
    for name, base, size in regions:
        total = 0
        for off in range(base, base + size, 8):
            lo, hi = struct.unpack_from("<II", image, off)
            total = (total + lo + hi) & 0xFFFFFFFF
        print("\tlocalparam [31:0] %-11s = 32'h%08X;" % (name, total))


if __name__ == "__main__":
    main()
