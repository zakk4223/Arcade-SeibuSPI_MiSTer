#!/usr/bin/env python3
"""Generate an MRA for every MAME set this core supports -- parents and clones.

A clone of a supported set needs nothing from the RTL if three things hold, and
all three are checked here rather than assumed:

  1. THE SAME ROM LAYOUT.  rom_loader.sv walks a fixed table indexed by part
     number and infers every destination and byte-lane rule from the INDEX, so a
     clone whose ROM_START has a different shape -- a different macro, a
     different region offset, a part more or fewer -- loads to the wrong address
     with no error anywhere.  `classify()` compares the clone's whole
     (region, macro, offset, size) sequence against its parent's and refuses
     anything that differs.  That is what excludes rdftua/rdftjb/rdftam/rdftadi:
     the SUB2/SUB4 carts carry the program as two bytes plus a word, like rdfts,
     and have no second sound ROM.  They need a table of their own.

  2. THE SAME DECRYPTION.  MAME's init_ function per set says this, and for
     every clone here it is the parent's: init_senkyua and init_batlball differ
     from init_senkyu only in which address gets a speedup hack, and all three
     call init_sei252.  Same for init_viprp1o against init_viprp1.  The sets
     whose init_ really does decrypt differently -- rdft22kc, rfjet2kc,
     init_sys386f -- are on other boards and excluded anyway.

  3. ITS OWN JOB TABLE.  The sample-flash derivation reads the updater's job
     records out of the game's own program image, and a clone's program differs,
     so the table moves: senkyu 0x00302324 against batlball 0x00302290.  That
     address is the ONE per-clone constant, it lives in the MRA (SeibuSPI.sv
     reads it at index-1 offset 16), and JOBS below is where this file gets it.

The sets on other boards are listed in UNSUPPORTED with the reason, so that
"why is there no MRA for rfjets" has an answer in the same file that would
generate it.

JOBS_BY_FAMILY is a table of constants so generating MRAs needs no ROMs.  Nothing
here trusts it: `--verify <romdir>` re-derives every address from the ROMs two
independent ways and then builds each set's flash and compares the payload to
its parent's, which must be identical byte for byte -- the region stamp is the
only thing that legitimately differs between a set and its clone.  That is also
`make check-clones`.

The six hand-written cartridge MRAs in mra/ are this generator's fixtures:
`--self-test` (always run) emits each parent and compares the part list and the
index-1 bytes against the file that is already on hardware.  A model that has
drifted fails there rather than in 42 clones.

Naming, which is MiSTer's convention and not ours:

    mra/<MAME description>.mra                                 a MAME parent
    mra/_alternatives/_<parent description>/<description>.mra   a MAME clone

so <setname> is the MAME set name and the FILE name is the descriptive one.
rdfts is a clone of rdft in MAME and lands under _alternatives with the rest.

Usage:
    tools/gen_mras.py [--out mra] [--mame ~/proj/mame] [--list] [--dry-run]
    tools/gen_mras.py --verify <romdir>       # re-derive JOBS from the ROMs
"""

import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

# ---------------------------------------------------------------------------
# The region code, which MAME's own header documents (seibuspi.cpp, "Known
# regions are:").  It is byte 0 of the sample flash, PRG offset 0x1ffffc, and
# the region digits in the blank-flash ROM's file name -- three copies that
# --verify holds against each other.  The names are MAME's, spelled the way the
# existing MRAs spell them.
# ---------------------------------------------------------------------------
REGIONS = {
    0x01: "Japan",      0x10: "USA",           0x20: "Taiwan",
    0x22: "Hong Kong",  0x24: "Korea",         0x28: "China",
    0x80: "Germany",    0x82: "Austria",       0x8c: "Great Britain",
    0x8e: "Greece",     0x90: "Holland",       0x92: "Italy",
    0x96: "Portugal",   0x9c: "Switzerland",   0x9e: "Australia",
    0xbe: "World",
}

# ---------------------------------------------------------------------------
# Per family: everything that is a property of the GAME rather than of the set.
# `mod` is the index-1 mod byte (rtl/spi_defs.vh: bit 0 = cartridge board,
# bits 3:1 = which set, bit 4 = the authentic-flash tail of that set's table).
# `gen` is the updater generation, 0 = A, 1 = B0, 2 = B1.
# ---------------------------------------------------------------------------
FAMILY = {
    "senkyu": dict(mod=0x19, gen=0, players=2, rotation="horizontal",
                   category="Puzzle", zero_fill=True),
    "viprp1": dict(mod=0x17, gen=0, players=2, rotation="vertical (cw)",
                   category="Shooter", zero_fill=False),
    "ejanhs": dict(mod=0x1B, gen=0, players=1, rotation="horizontal",
                   category="Mahjong", zero_fill=True),
    "rdft":   dict(mod=0x11, gen=1, players=2, rotation="vertical (cw)",
                   category="Shooter", zero_fill=False),
    "rdft2":  dict(mod=0x13, gen=2, players=2, rotation="vertical (cw)",
                   category="Shooter", zero_fill=False),
    "rfjet":  dict(mod=0x15, gen=2, players=2, rotation="vertical (cw)",
                   category="Shooter", zero_fill=False),
}

# MAME regions the MRA does not carry.  audiocpu is RAM on a cartridge -- the
# 386 fills it through port 0x688 -- and pals are not ROM data.
SKIP_REGIONS = ("audiocpu", "pals")

# A gloss per MAME region, so a generated file reads like the hand-written ones.
REGION_NOTE = {
    "maincpu":     "386 program",
    "chars":       "text layer",
    "tiles":       "background tiles",
    "sprites":     "three plane-pair chunks, interleaved by the loader",
    "sound01":     "the ROMs the updater reads, carried whole",
    "soundflash1": "the sample flash, BLANK -- byte 0 is the region lock",
}

# ---------------------------------------------------------------------------
# The updater's job table, per set: a 386 address, the one constant a clone
# needs of its own.  Found two ways and cross-checked (--verify):
#
#   content   the parent's job records, searched for byte-for-byte in the
#             clone's program image.  Unambiguous wherever it hits, because a
#             job table is 28 bytes of addresses and lengths.
#   struct    every offset that reads as a whole job table -- sources inside the
#             386's program or sound01 window, sane lengths, an FFFFFFFF
#             terminator, and a payload that fills a 2 MB flash.  Used for the
#             three old-version Viper sets, whose second job reads the PROGRAM
#             image and so whose records differ from the parent's.
#
# Both then have to produce the parent's payload exactly, which every set here
# does.  rdfts is absent on purpose: the single board has real sample ROMs and
# derives nothing.
# ---------------------------------------------------------------------------
JOBS_BY_FAMILY = {
    # senkyu family (gen A)
    "senkyu": {
        "senkyu":     0x00302324,
        "senkyua":    0x0030232C,
        "batlball":   0x00302290,
        "batlballo":  0x00302290,
        "batlballu":  0x00302290,
        "batlballa":  0x00302290,
        "batlballe":  0x0030228C,
        "batlballpt": 0x00302290,
    },
    # viprp1 family (gen A)
    "viprp1": {
        "viprp1":     0x00200760,
        "viprp1k":    0x00200760,
        "viprp1u":    0x00200760,
        "viprp1ua":   0x00200760,
        "viprp1j":    0x00200760,
        "viprp1s":    0x00200760,
        "viprp1h":    0x00200760,
        "viprp1t":    0x00200760,
        "viprp1pt":   0x00200760,
        "viprp1ot":   0x00200760,   # struct
        "viprp1oj":   0x00200740,   # struct
        "viprp1hk":   0x00200760,   # struct
    },
    # ejanhs (gen A)
    "ejanhs": {
        "ejanhs":     0x003026AC,
    },
    # rdft family (gen B0)
    "rdft": {
        "rdft":       0x0020174D,
        "rdftj":      0x0020174D,
        "rdftja":     0x002017A5,
        "rdftu":      0x0020174D,
        "rdftauge":   0x002017A5,
        "rdftau":     0x0020174D,
        "rdfta":      0x00201761,
        "rdftgb":     0x00201761,
        "rdftgr":     0x00201761,
        "rdftit":     0x00201761,
        "rdftadia":   0x00201761,
    },
    # rdft2 family (gen B1)
    "rdft2": {
        "rdft2":      0x00201B55,
        "rdft2j":     0x00201B55,
        "rdft2a":     0x00201B55,
        "rdft2s":     0x00201B55,
        "rdft2ja":    0x00201B55,
        "rdft2aa":    0x00201B55,
        "rdft2it":    0x00201B55,
        "rdft2jb":    0x00201B55,
        "rdft2jc":    0x00201B55,
        "rdft2t":     0x00201B55,
        "rdft2u":     0x00201B55,
    },
    # rfjet family (gen B1)
    "rfjet": {
        "rfjet":      0x00203597,
        "rfjetu":     0x00203597,
        "rfjetj":     0x0020357F,
        "rfjeta":     0x00203597,
        "rfjett":     0x00203597,
    },
}

# Flattened, plus the family each set belongs to.
JOBS = {s: j for fam in JOBS_BY_FAMILY for s, j in JOBS_BY_FAMILY[fam].items()}
FAMILY_OF = {s: fam for fam in JOBS_BY_FAMILY for s in JOBS_BY_FAMILY[fam]}


def family_of(setname):
    """The FAMILY key whose mod byte, table and generation this set uses."""
    return FAMILY_OF.get(setname)

# The stamp is the last dword of the 2 MB program region on every set here, and
# --verify checks that its low byte is the set's region code.
STAMP = 0x003FFFFC

# Sets on hardware this core does not implement.  Kept here, and printed by
# --list, so the absence of an MRA is documented where the MRAs are made.
UNSUPPORTED = {
    "rdftua":   "SXX2C ROM SUB2 cart: program is two bytes + one word and there "
                "is no second sound ROM -- needs its own rom_loader table",
    "rdftjb":   "as rdftua",
    "rdftam":   "as rdftua",
    "rdftadi":  "as rdftua (SUB4 cart)",
    "rdft2us":  "SXX2F single board: Z80 program ROM and real sample ROMs, not a "
                "cartridge tail -- needs its own table, like rdfts has",
    "rfjets":   "SXX2G single board, as rdft2us",
    "rfjetsa":  "SXX2G single board, as rdft2us",
    "rdft22kc": "SYS386I: dual MSM6295 instead of the YMF271, no sound flash",
    "rfjet2kc": "SYS386I, as rdft22kc",
    "ejsakura": "SYS386F: a different board entirely, not a clone of anything here",
    "ejsakura12": "SYS386F, as ejsakura",
}

# rdfts is supported and generated by hand: it is the SXX2E single board, walks
# its own part table, and has no derivation.  Named here so classify() does not
# report it as missing.
HAND_WRITTEN = {"rdfts": "mra/rdfts.mra"}


# ---------------------------------------------------------------------------
# MAME's driver, which is the authority for everything except the mod byte
# ---------------------------------------------------------------------------
def parse_driver(path):
    src = open(path, encoding="utf-8", errors="replace").read()
    sets = {}
    for m in re.finditer(r'^GAME[L]?\(\s*(\d{4}),\s*(\w+),\s*(\w+|0),\s*(\w+),'
                         r'\s*(\w+),\s*(\w+),\s*(\w+),\s*(ROT\w+),\s*"([^"]*)",'
                         r'\s*"([^"]*)"', src, re.M):
        year, name, parent, machine, inp, state, init, rot, mfr, desc = m.groups()
        sets[name] = dict(year=year, parent=None if parent == "0" else parent,
                          machine=machine, init=init, mfr=mfr, desc=desc,
                          roms=None)
    for name in sets:
        m = re.search(r"ROM_START\(\s*%s\s*\)(.*?)ROM_END" % name, src, re.S)
        if not m:
            continue
        roms, region = [], None
        for line in m.group(1).splitlines():
            r = re.search(r'ROM_REGION(?:32_LE|16_BE)?\(\s*0x[0-9a-fA-F]+\s*,'
                          r'\s*"(\w+)"', line)
            if r:
                region = r.group(1)
                continue
            # ROM_CONTINUE is the rest of the same file landing elsewhere in the
            # region.  It carries no name and no CRC, so the ROM_LOAD above it
            # understates the file by exactly this much.
            r = re.search(r'ROM_CONTINUE\(\s*0x[0-9a-fA-F]+\s*,'
                          r'\s*(0x[0-9a-fA-F]+)\s*\)', line)
            if r:
                roms[-1]["size"] += int(r.group(1), 16)
                continue
            r = re.search(r'(ROM_LOAD(?:24_WORD|24_BYTE|32_BYTE|32_WORD)?)\('
                          r'\s*"([^"]+)"\s*,\s*(0x[0-9a-fA-F]+)\s*,'
                          r'\s*(0x[0-9a-fA-F]+)\s*,\s*CRC\(([0-9a-fA-F]+)\)', line)
            if not r:
                continue
            macro, rname, off, size, crc = r.groups()
            roms.append(dict(name=rname, crc=int(crc, 16), size=int(size, 16),
                             off=int(off, 16), region=region, macro=macro))
        sets[name]["roms"] = roms
    return sets


def shape(roms):
    """The structural fingerprint the loader table is tied to."""
    return [(r["region"], r["macro"], r["off"], r["size"]) for r in roms]


def classify(sets):
    """(supported, rejected) -- supported maps set -> parent family."""
    supported, rejected = {}, {}
    for name, s in sorted(sets.items()):
        fam = name if name in FAMILY else s["parent"]
        if fam not in FAMILY:
            continue
        if name in UNSUPPORTED or name in HAND_WRITTEN:
            continue
        if shape(s["roms"]) != shape(sets[fam]["roms"]):
            rejected[name] = "ROM layout differs from %s" % fam
            continue
        if name not in JOBS:
            rejected[name] = "no job-table address in JOBS"
            continue
        supported[name] = fam
    return supported, rejected


def region_of(s):
    """The set's region, from the blank-flash ROM's name."""
    for r in s["roms"]:
        if r["region"] == "soundflash1":
            code = int(re.search(r"region([0-9a-fA-F]{2})", r["name"]).group(1), 16)
            return code, REGIONS.get(code, "Unknown")
    return None, None


# ---------------------------------------------------------------------------
# Emission
# ---------------------------------------------------------------------------
HEADER = """<!--            FPGA compatible core for Seibu SPI / SXX2C hardware        -->
<!--                                                                     -->
<!-- This file is part of SlopperPI.                                     -->
<!--                                                                     -->
<!-- SlopperPI is free software: you can redistribute it and/or modify   -->
<!-- it under the terms of the GNU General Public License as published   -->
<!-- by the Free Software Foundation, either version 3 of the License,   -->
<!-- or (at your option) any later version.                              -->
"""


def le32(v):
    return " ".join("%02X" % ((v >> (8 * i)) & 0xFF) for i in range(4))


def index1(fam, setname):
    """The config blob: mod byte, codec pairs, derivation constants."""
    return [FAMILY[fam]["mod"]] + [0xFF] * 15 + \
        [(JOBS[setname] >> (8 * i)) & 0xFF for i in range(4)] + \
        [(STAMP >> (8 * i)) & 0xFF for i in range(4)] + \
        [FAMILY[fam]["gen"]]


def parts_of(s, fam):
    """The index-0 byte stream as (kind, ...) elements, in MAME's order.

    A leading zero fill where the program sits in the upper half of its region
    (senkyu and ejanhs load at 0x100000, and the loader's part 0 is the whole
    2 MB), and a trailing 1 MB of FF for the second E28F008SA, which has no dump
    because an erased chip has nothing to dump.
    """
    out = []
    if FAMILY[fam]["zero_fill"]:
        out.append(("fill", 0x100000, 0x00,
                    "the empty lower half of the program region"))
    last = None
    for r in s["roms"]:
        if r["region"] in SKIP_REGIONS:
            continue
        if r["region"] != last:
            out.append(("note", "%s: %s" % (r["region"],
                                            REGION_NOTE.get(r["region"], ""))))
            last = r["region"]
        out.append(("file", r["name"], r["crc"]))
    out.append(("fill", 0x100000, 0xFF,
                "the second E28F008SA, erased -- MAME has no dump for it"))
    return out


def emit(setname, s, fam, sets):
    code, region = region_of(s)
    is_clone = (setname != fam)
    zips = ("%s.zip|%s.zip" % (setname, fam)) if is_clone else ("%s.zip" % fam)
    cfg = index1(fam, setname)
    parts = parts_of(s, fam)
    width = max(len(p[1]) for p in parts if p[0] == "file")

    L = [HEADER.rstrip("\n"), "",
         "<misterromdescription>",
         "    <name>%s</name>" % s["desc"],
         "    <setname>%s</setname>" % setname,
         "    <rbf>SeibuSPI</rbf>",
         "    <mameversion>0277</mameversion>",
         "    <year>%s</year>" % s["year"],
         "    <manufacturer>%s</manufacturer>" % s["mfr"],
         "    <players>%d</players>" % FAMILY[fam]["players"],
         "    <joystick>8</joystick>",
         "    <rotation>%s</rotation>" % FAMILY[fam]["rotation"],
         "    <region>%s</region>" % region,
         "    <category>%s</category>" % FAMILY[fam]["category"],
         ""]

    L += ["    <!--",
          "      GENERATED by tools/gen_mras.py from MAME's ROM_START(%s)." % setname,
          "      Edit the generator, not this file.",
          ""]
    if is_clone:
        L += ["      A clone of %s, part for part: the same ROM layout, the same" % fam,
              "      decryption (MAME's %s against the parent's %s), and a" % (s["init"], sets[fam]["init"]),
              "      program of its own -- which is why the job table below is not the",
              "      parent's address.",
              "",
              "      make check-mra holds every part here against MAME's ROM_START and",
              "      against rom_loader.sv's table.  make check-clones re-derives the job",
              "      table from the ROMs and checks that the flash it builds is %s's" % fam,
              "      payload byte for byte.",
              ""]
    L += ["      Region %#04x = %s.  The same byte is in the program image at" % (code, region),
          "      0x1ffffc and in the blank flash's byte 0; the mainboard refuses a",
          "      cartridge from another region.",
          ""]
    L += ["      Part order is significant: rom_loader.sv walks this list with a fixed",
          "      table selected by the mod byte, and infers each part's destination and",
          "      byte scatter from its INDEX, not from anything in this file.",
          "    -->", ""]

    L += ['    <!--',
          '      Index 1, the core\'s config blob, and it MUST precede the index-0 image:',
          '      Main_MiSTer sends <rom> elements in file order and the loader has to know',
          '      its table before the bytes start.',
          '',
          '        byte 0     mod byte %#04x -- cartridge board, set %d, authentic-flash tail'
          % (FAMILY[fam]["mod"], (FAMILY[fam]["mod"] >> 1) & 7),
          '        1..15      {part, codec} pairs; FF terminates, nothing here is decoded',
          '        16..19     job table  %#010x' % JOBS[setname],
          '        20..23     stamp      %#010x' % STAMP,
          '        24         generation %d' % FAMILY[fam]["gen"],
          '',
          '      The sample flash is an OSD option, "Sample Flash".  Both settings have',
          '      the core derive the 2 MB payload out of SDRAM in about a third of a',
          '      second; what the option picks is whether the region STAMP goes with it.',
          '      Pre-built writes it and the game plays at once.  Cart copy leaves it',
          '      blank, so the game spends about six minutes programming a flash that is',
          '      already correct -- and SWITCHING to Cart copy blanks the stamp and',
          '      restarts the board, because boot is the only moment the game looks.',
          '    -->',
          '    <rom index="1">',
          '      <part>%02X</part>' % cfg[0],
          '      <part>%s</part>' % " ".join("%02X" % b for b in cfg[1:16]),
          '      <part>%s</part>' % le32(JOBS[setname]),
          '      <part>%s</part>' % le32(STAMP),
          '      <part>%02X</part>' % FAMILY[fam]["gen"],
          '    </rom>', '']

    if is_clone:
        L += ['    <!--',
              '      Parts resolve by CRC first (Main_MiSTer\'s zip_search_by_crc), so a',
              '      merged set works even though most of these files are stored under the',
              '      parent\'s directory or name.  The CRCs are load-bearing.',
              '    -->']
    L.append('    <rom index="0" address="0x30000000" zip="%s" md5="none">' % zips)
    for p in parts:
        if p[0] == "note":
            L.append("        <!-- %s -->" % p[1])
        elif p[0] == "fill":
            L.append('        <!-- %s -->' % p[3])
            L.append('        <part repeat="%#x">%02X</part>' % (p[1], p[2]))
        else:
            L.append('        <part name="%s"%s crc="%08x"/>'
                     % (p[1], " " * (width - len(p[1])), p[2]))
    L.append('    </rom>')

    L += ['',
          '    <!--',
          '      The save file, in /media/fat/config/nvram/.  ONE element, because an MRA',
          '      gets one, so what the board remembers is concatenated into it -- and it',
          '      is 516 bytes, not two megabytes:',
          '',
          '        0x000..0x003   the sample flash\'s REGION STAMP, and nothing else of it',
          '        0x004..0x203   the DS2404\'s 512 bytes of bookkeeping SRAM',
          '',
          '      Those four bytes are what the game tests to decide the flash is already',
          '      programmed, so they are the whole flag that says whether its six-minute',
          '      updater runs.  The two megabytes behind them are DERIVED at every boot in',
          '      a third of a second, so storing them bought nothing and cost a visibly',
          '      unresponsive OSD -- Main reads the file back every time it polls.',
          '',
          '      The tail is byte-for-byte MAME\'s own `ds2404` file.',
          '',
          '      It must stay below the <rom> element: Main_MiSTer sends it after the',
          '      index-0 image, which is what lets it land on the blank flash.',
          '    -->',
          '    <nvram index="2" size="516"/>',
          '',
          '    <!--',
          '      The names map to joystick bits 4 UPWARDS IN ORDER and SeibuSPI.sv decodes',
          '      them at exactly those positions, so this list and that decode change',
          '      together.  Pause is the eighth, bit 11, and is not a board input at all --',
          '      it gates the 386 while the video engines keep running.  It is not on',
          '      button 3 because four of the seven sets are MAME\'s spi_3button and use',
          '      that as a game button.',
          '    -->',
          '    <buttons names="Shot,Bomb,Button 3,Start,Coin,Service Coin,Test,Pause"',
          '             default="A,B,X,Start,Select,R,L,Y" count="3"/>',
          '',
          '    <switches default="00" base="0">',
          '        <dip name="Flip Screen"  bits="0" ids="Off,On"/>',
          '        <dip name="Service Mode" bits="1" ids="Off,On"/>',
          '    </switches>',
          '</misterromdescription>']
    return "\n".join(L) + "\n"


# ---------------------------------------------------------------------------
# The hand-written parents as fixtures
# ---------------------------------------------------------------------------
def mra_stream(text):
    """(kind, name/size, crc/byte) per index-0 element, comments removed."""
    src = re.sub(r"<!--.*?-->", "", text, flags=re.S)
    m = re.search(r'<rom index="0".*?>(.*?)</rom>', src, re.S)
    out = []
    for pm in re.finditer(r"<part\b([^>]*?)(?:/>|>(.*?)</part>)", m.group(1), re.S):
        attrs, body = pm.group(1), (pm.group(2) or "")
        name = re.search(r'name="([^"]+)"', attrs)
        rep = re.search(r'repeat="((?:0x)?[0-9a-fA-F]+)"', attrs)
        if name:
            crc = re.search(r'crc="([0-9a-fA-F]+)"', attrs)
            out.append(("file", name.group(1), int(crc.group(1), 16)))
        else:
            n = int(rep.group(1), 16) if rep else 1
            b = [int(x, 16) for x in body.split()]
            out.append(("fill", n * len(b), b[0]))
    return out


def mra_nvram(text):
    """The <nvram> element's size, which the core's layout has to agree with."""
    src = re.sub(r"<!--.*?-->", "", text, flags=re.S)
    m = re.search(r'<nvram\b[^>]*index="(\d+)"[^>]*size="(\d+)"', src)
    if not m:
        m = re.search(r'<nvram\b[^>]*size="(\d+)"[^>]*index="(\d+)"', src)
        return (int(m.group(2)), int(m.group(1))) if m else (None, None)
    return int(m.group(1)), int(m.group(2))


def mra_cfg(text):
    src = re.sub(r"<!--.*?-->", "", text, flags=re.S)
    m = re.search(r'<rom index="1".*?>(.*?)</rom>', src, re.S)
    data = []
    for pm in re.finditer(r"<part\b[^>]*>(.*?)</part>", m.group(1), re.S):
        data += [int(b, 16) for b in pm.group(1).split()]
    return data


def self_test(sets, out_dir):
    """Emit each hand-written parent and compare what the core actually reads."""
    bad = 0
    for fam in sorted(FAMILY):
        path = None
        for cand in os.listdir(out_dir):
            if cand.endswith(".mra"):
                text = open(os.path.join(out_dir, cand), encoding="utf-8").read()
                if re.search(r"<setname>%s</setname>" % fam, text):
                    path = os.path.join(out_dir, cand)
                    break
        if not path:
            print("  self-test: no hand-written MRA for %s -- skipped" % fam)
            continue
        text = open(path, encoding="utf-8").read()
        mine = emit(fam, sets[fam], fam, sets)
        got, want = mra_stream(mine), mra_stream(text)
        gotc = [x for x in mra_cfg(mine)], [x for x in mra_cfg(text)]
        ok = True
        if got != want:
            ok = False
            print("  self-test FAIL %s: part stream differs" % fam)
            for i, (a, b) in enumerate(zip(got, want)):
                if a != b:
                    print("    element %d: generated %s, %s has %s"
                          % (i, a, os.path.basename(path), b))
            if len(got) != len(want):
                print("    %d elements generated, %d in the file" % (len(got), len(want)))
        if gotc[0] != gotc[1]:
            ok = False
            print("  self-test FAIL %s: index-1 config differs" % fam)
            print("    generated %s" % " ".join("%02X" % b for b in gotc[0]))
            print("    file      %s" % " ".join("%02X" % b for b in gotc[1]))
        if mra_nvram(mine) != mra_nvram(text):
            ok = False
            print("  self-test FAIL %s: <nvram> differs -- generated index %s size %s, "
                  "file index %s size %s" % ((fam,) + mra_nvram(mine) + mra_nvram(text)))
        if ok:
            print("  self-test ok   %s: %d parts and %d config bytes match %s"
                  % (fam, len(got), len(gotc[1]), os.path.basename(path)))
        else:
            bad += 1
    return bad


# ---------------------------------------------------------------------------
# --verify: re-derive JOBS from the ROMs, and check what it builds
# ---------------------------------------------------------------------------
def verify(sets, romdir):
    import hashlib
    import zipfile
    sys.path.insert(0, HERE)
    import build_soundflash as bs

    class Zip:
        """A merged zip stores a file shared by two clones once, under whichever
        directory the packer chose, so look ROMs up by CRC and not by path --
        which is also how Main_MiSTer resolves an MRA part."""
        def __init__(self, path):
            self.zf = zipfile.ZipFile(path)
            self.by_crc = {}
            for i in self.zf.infolist():
                self.by_crc.setdefault(i.CRC, i.filename)

        def read(self, crc):
            return self.zf.read(self.by_crc[crc])

    def prg_image(z, roms):
        p = sorted([r for r in roms if r["region"] == "maincpu"],
                   key=lambda r: r["off"])
        base = p[0]["off"] & ~3
        out = bytearray(bs.PRG_SIZE)
        for r in p:
            d = z.read(r["crc"])
            lane = r["off"] - base
            out[base + lane: base + lane + len(d) * 4: 4] = d
        return bytes(out)

    def sound01(z, roms):
        region = bytearray(bs.S01_SIZE)
        for r in roms:
            if r["region"] != "sound01":
                continue
            lanes = 2 if r["macro"] == "ROM_LOAD32_WORD" else 1
            for i, b in enumerate(z.read(r["crc"])):
                group, lane = divmod(i, lanes)
                region[r["off"] + bs.bank(group * 4 + lane)] = b
        return bytes(region)

    def walk(prg, addr):
        """The job records at addr, or None if this does not read as a table."""
        recs = []
        for n in range(33):
            o = addr - bs.PRG_BASE + n * 12
            if o < 0 or o + 12 > len(prg):
                return None
            src = int.from_bytes(prg[o:o + 4], "little")
            if src == 0xFFFFFFFF:
                return recs or None
            length = int.from_bytes(prg[o + 4:o + 8], "little")
            if not (bs.PRG_BASE <= src < bs.PRG_BASE + bs.PRG_SIZE
                    or bs.S01_BASE <= src < bs.S01_BASE + bs.S01_SIZE):
                return None
            if not (0 < length <= bs.FLASH_SIZE) or prg[o + 8] > 8:
                return None
            recs.append((src, length))
        return None

    def structural(prg):
        hits = []
        for i in range(len(prg) - 16):
            r = walk(prg, bs.PRG_BASE + i)
            if r and 0x180000 <= sum(x[1] for x in r) <= bs.FLASH_SIZE:
                hits.append(bs.PRG_BASE + i)
        return hits

    GEN = {0: "A", 1: "B0", 2: "B1"}
    supported, rejected = classify(sets)
    bad = 0
    for fam in sorted(FAMILY):
        z = Zip(os.path.join(romdir, fam + ".zip"))
        pprg = prg_image(z, sets[fam]["roms"])
        pj = JOBS[fam]
        n = len(walk(pprg, pj))
        pat = pprg[pj - bs.PRG_BASE: pj - bs.PRG_BASE + 12 * n + 4]
        ref = None
        print("--- %s (gen %s), job table %d records" % (fam, GEN[FAMILY[fam]["gen"]], n))
        for name in [fam] + sorted(k for k, v in supported.items() if v == fam and k != fam):
            s = sets[name]
            prg = pprg if name == fam else prg_image(z, s["roms"])
            # the address, two ways
            hits, i = [], 0
            while True:
                i = prg.find(pat, i)
                if i < 0:
                    break
                hits.append(bs.PRG_BASE + i)
                i += 1
            how = "content"
            if len(hits) != 1:
                hits = structural(prg)
                how = "struct"
            if len(hits) != 1:
                print("  %-11s FAIL: %d candidate job tables %s"
                      % (name, len(hits), [hex(h) for h in hits]))
                bad += 1
                continue
            if hits[0] != JOBS[name]:
                print("  %-11s FAIL: JOBS says %#010x, the ROMs say %#010x"
                      % (name, JOBS[name], hits[0]))
                bad += 1
                continue
            # the region code, three ways
            code, region = region_of(s)
            stamp = prg[STAMP - bs.PRG_BASE: STAMP - bs.PRG_BASE + 4]
            if stamp[0] != code:
                print("  %-11s FAIL: program stamp %02x, blank flash says %02x"
                      % (name, stamp[0], code))
                bad += 1
                continue
            # and what it builds
            img = bs.build_from(prg, sound01(z, s["roms"]),
                                dict(job_table=JOBS[name], stamp=STAMP,
                                     gen=GEN[FAMILY[fam]["gen"]]), quiet=True)
            if name == fam:
                ref = img[4:]
                want = bs.GAMES[fam]["sha256"]
                got = hashlib.sha256(img).hexdigest()
                if got != want:
                    print("  %-11s FAIL: flash sha256 %s != build_soundflash's %s"
                          % (name, got, want))
                    bad += 1
                    continue
                note = "flash matches the image MAME's flash devices hold"
            elif img[4:] != ref:
                print("  %-11s FAIL: payload differs from %s's" % (name, fam))
                bad += 1
                continue
            else:
                note = "payload identical to %s, stamp %02x %02x %02x %02x" % (
                    fam, stamp[0], stamp[1], stamp[2], stamp[3])
            print("  %-11s job %#010x [%-7s] region %#04x %-14s %s"
                  % (name, JOBS[name], how, code, region, note))
    return bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mame", default=os.path.expanduser("~/proj/mame"))
    ap.add_argument("--out", default=os.path.join(ROOT, "mra"))
    ap.add_argument("--list", action="store_true", help="report the inventory only")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--verify", metavar="ROMDIR",
                    help="re-derive every job table from the ROMs and check the "
                         "flash each set builds against its parent's")
    args = ap.parse_args()

    drv = os.path.join(args.mame, "src", "mame", "seibu", "seibuspi.cpp")
    if not os.path.exists(drv):
        print("no MAME driver at %s (use --mame)" % drv)
        return 1
    sets = parse_driver(drv)
    supported, rejected = classify(sets)

    if args.verify:
        return 1 if verify(sets, args.verify) else 0

    if args.list:
        print("supported: %d sets (%d MAME parents, %d clones, %d hand-written)"
              % (len(supported) + len(HAND_WRITTEN),
                 len([k for k, v in supported.items() if k == v]),
                 len([k for k, v in supported.items() if k != v]), len(HAND_WRITTEN)))
        for name, fam in sorted(supported.items(), key=lambda kv: (kv[1], kv[0])):
            code, region = region_of(sets[name])
            print("  %-11s %-9s %-14s %s" % (name, fam, region, sets[name]["desc"]))
        for name, path in sorted(HAND_WRITTEN.items()):
            print("  %-11s %-9s %-14s %s (hand-written: %s)"
                  % (name, sets[name]["parent"], "-", sets[name]["desc"], path))
        print("not supported: %d sets" % (len(UNSUPPORTED) + len(rejected)))
        for name, why in sorted(list(UNSUPPORTED.items()) + list(rejected.items())):
            if name in sets:
                print("  %-11s %s" % (name, why))
        return 0

    print("self-test against the hand-written MRAs:")
    if self_test(sets, args.out):
        print("FAIL: the generator no longer reproduces a hand-written MRA")
        return 1

    # Clones go under _alternatives/_<parent's descriptive name>/, which is where
    # Main_MiSTer looks for them.
    written = 0
    for name, fam in sorted(supported.items(), key=lambda kv: (kv[1], kv[0])):
        if name == fam:
            continue                       # the parents are hand-written
        d = os.path.join(args.out, "_alternatives", "_" + sets[fam]["desc"])
        path = os.path.join(d, sets[name]["desc"] + ".mra")
        text = emit(name, sets[name], fam, sets)
        if args.dry_run:
            print("  would write %s (%d bytes)" % (path, len(text)))
        else:
            os.makedirs(d, exist_ok=True)
            with open(path, "w", encoding="utf-8") as f:
                f.write(text)
        written += 1
    print("%s %d clone MRAs under %s/_alternatives"
          % ("would write" if args.dry_run else "wrote", written, args.out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
