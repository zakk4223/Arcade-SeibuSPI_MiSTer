#!/usr/bin/env python3
"""
Verify the MRAs against MAME's driver and against the RTL loader table.

Three copies of the same part list exist and they have to agree exactly, because
nothing at runtime checks them:

    MAME  seibuspi.cpp ROM_START(<set>)   the authority: names, CRCs, sizes,
                                          load macros and region offsets
    MRA   mra/<set>.mra                   what MiSTer hands the core, IN ORDER
    RTL   rtl/rom_loader.sv               a fixed table indexed by part number,
                                          which applies the byte scatter

The MRA carries no scatter information -- rom_loader.sv infers every destination
and byte-lane rule from the part INDEX -- so a reordered, inserted or dropped
part is loaded to the wrong address with no error anywhere. That is the failure
this catches.

Comparing the MRA against build_sdram_image.py would prove nothing: both are
ours and could share a mistake, which is how tb_rom_loader passed for months
against a reference implementing the same wrong rule (PLAN.md 12). MAME is the
only independent source here.

The loader is modelled the way the hardware works -- a byte stream split by the
table's part sizes -- so MRA <part> boundaries need not line up with loader
parts. rdft relies on that: its sample part is one 2 MB loader part assembled
from four MRA elements.

Usage:
    tools/check_mra.py [--set rdfts|rdft|all] [--mame ~/proj/mame] [--zip rdft.zip]

With --zip, also confirms every file part resolves out of that archive by CRC32,
which is how Main_MiSTer looks parts up (zip_search_by_crc, PLAN.md 11).
"""

import argparse
import os
import re
import sys
import zipfile

# rtl/spi_defs.vh
BASES = {
    "prg":     0x0000000,
    "z80":     0x0200000,
    "chars":   0x0240000,
    "pcm":     0x0280000,
    "snd01":   0x0480000,
    "tiles":   0x0500000,
    "sprites": 0x1100000,
}
# The PCM source ROM's base is PER-SET -- it follows that set's own sprites
# rather than the largest set's, so an authentic-flash SEI252 game still fits a
# 32 MB module. Three regions rather than one, named exactly as the RTL names
# them, so a set's `special` entry below picks the base by naming it and no
# per-set value has to be threaded through expected_base().
BASES["pcmsrc_sei252"] = BASES["sprites"] + 3 * 0x400000   # 0x1D00000
BASES["pcmsrc_rdft2"]  = BASES["sprites"] + 3 * 0x600000   # 0x2300000
BASES["pcmsrc_rfjet"]  = BASES["sprites"] + 3 * 0x800000   # 0x2900000

# rtl/spi_defs.vh. The MRA names one of these per part; anything else is a typo
# that would load a part as noise.
CODECS = {
    0: "CODEC_RAW",
    1: "CODEC_BPE_DPCM",
}

REGION = {
    "maincpu": "prg", "audiocpu": "z80", "chars": "chars",
    "tiles": "tiles", "sprites": "sprites", "ymf": "pcm",
}

# sound01 and soundflash1 have no single mapping: the two ROMs of one sound01
# region go to two different places, and both are stored PACKED -- the loader
# copies them and spi_cpu.sv rebuilds the 386's scattered view on the fly, so
# their scatter mode is M_LINEAR and not the ROM_LOAD32_* macro MAME uses. A set
# that carries them names each one here. See PLAN.md 17.2.
#   ROM name -> (SDRAM region, scatter mode)

SETS = {
    # table:  which rom_loader.sv part table this set walks
    # skip:   MAME regions the MRA deliberately does not carry
    # synth:  logical parts with no single MAME ROM behind them
    # mod:  the exact index-1 mod byte this set must send. bit 0 = SXX2C board,
    #       bits 3:1 = set within that board (rtl/spi_defs.vh).
    # spr_mode / spr_chunk: sprites are INTERLEAVED in SDRAM (rom_loader
    # M_SPR_ILV), so their scatter mode and destination cannot be derived from
    # MAME's plain ROM_LOAD. Chunk k lands at sprites_base + 2k.
    "rdfts": dict(mra="rdfts.mra", table="rdfts", mod=0x00, skip=(),
                  spr_mode="M_SPR_ILV", spr_chunk=0x400000),
    # ONE MRA PER SET. The pre-flashed variants are gone: they could only be
    # built for three of the seven, they needed a derived image and a fresh
    # sha256 per clone, and the core now builds the same image itself from the
    # ROMs this MRA already carries (PLAN.md 24, 26). What replaces the
    # derived-image check that used to live here is `make check-derive`, which
    # covers seven sets where this covered two.
    "rdft":  dict(mra="rdft.mra",  table="rdft",  mod=0x11,
                      skip=("audiocpu",),
                      special={"gun_dogs_pcm.u0217": ("pcmsrc_sei252", "M_LINEAR"),
                               "seibu_8.u0216":      ("snd01",  "M_LINEAR"),
                               "flash0_blank_region80.u1053": ("pcm", "M_LINEAR")},
                      spr_mode="M_SPR_ILV", spr_chunk=0x400000),
    "rdft2": dict(mra="rdft2.mra", table="rdft2", mod=0x13,
                      skip=("audiocpu", "pals"),
                      special={"pcm.u0217":    ("pcmsrc_rdft2", "M_LINEAR"),
                               "sound1.u0222": ("snd01",  "M_LINEAR"),
                               "flash0_blank_region80.u1053": ("pcm", "M_LINEAR")},
                      spr_mode="M_SPR_ILV_R", spr_chunk=0x600000),
    # viprp1 is authentic-ONLY: its flash payload's second job reads the 386's
    # interleaved program image rather than a ROM file, so no MRA can assemble
    # a pre-flashed one. It is also the first generation-A set here -- 1 MB of
    # PCM source on ONE byte lane -- and the first to use rdfts's text layout
    # on the cartridge board.
    "viprp1": dict(mra="viprp1.mra", table="viprp1", mod=0x17,
                       skip=("audiocpu",),
                       special={"v_pcm.215": ("pcmsrc_sei252", "M_LINEAR"),
                                "flash0_blank_regionbe.u1053": ("pcm", "M_LINEAR")},
                       spr_mode="M_SPR_ILV", spr_chunk=0x400000),
    # The other two generation-A cartridges. Both have a second sound ROM,
    # which viprp1 does not, and both put their program in the upper half of
    # the region behind a megabyte of zero fill.
    "senkyu": dict(mra="senkyu.mra", table="senkyu", mod=0x19,
                       skip=("audiocpu",),
                       special={"fb_pcm-1.215": ("pcmsrc_sei252", "M_LINEAR"),
                                "fb_7.216":     ("snd01",  "M_LINEAR"),
                                "flash0_blank_region01.u1053": ("pcm", "M_LINEAR")},
                       spr_mode="M_SPR_ILV", spr_chunk=0x400000),
    "ejanhs": dict(mra="ejanhs.mra", table="ejanhs", mod=0x1B,
                       skip=("audiocpu",),
                       special={"ej3_pcm1.215": ("pcmsrc_sei252", "M_LINEAR"),
                                "ejan3_7.216":  ("snd01",  "M_LINEAR"),
                                "flash0_blank_region01.u1053": ("pcm", "M_LINEAR")},
                       spr_mode="M_SPR_ILV", spr_chunk=0x400000),
    "rfjet": dict(mra="rfjet.mra", table="rfjet", mod=0x15,
                      skip=("audiocpu", "pals"),
                      special={"pcm-d.u0227":  ("pcmsrc_rfjet", "M_LINEAR"),
                               "sound1.u0222": ("snd01",  "M_LINEAR"),
                               "flash0_blank_region80.u1053": ("pcm", "M_LINEAR")},
                      spr_mode="M_SPR_ILV_R", spr_chunk=0x800000),
}


def mame_mode(macro, off):
    """MAME load macro + offset within region -> the loader's scatter mode."""
    if macro == "ROM_LOAD32_BYTE":
        return {0: "M_32_B0", 1: "M_32_B1", 2: "M_32_B2", 3: "M_32_B3"}[off & 3]
    if macro == "ROM_LOAD32_WORD":
        return {0: "M_32_W01", 2: "M_32_W23"}.get(off & 3)
    if macro == "ROM_LOAD24_WORD":
        return "M_24_W01" if (off % 3) == 0 else None
    if macro == "ROM_LOAD24_BYTE":
        return {0: "M_24_B0", 1: "M_24_B1", 2: "M_24_B2"}.get(off % 3)
    if macro == "ROM_LOAD":
        return "M_LINEAR"
    return None


def fail(msg):
    print("FAIL: " + msg)
    sys.exit(1)


def parse_mame(path, setname, skip, special):
    src = open(path, encoding="utf-8", errors="replace").read()
    m = re.search(r"ROM_START\(\s*%s\s*\)(.*?)ROM_END" % setname, src, re.S)
    if not m:
        fail("no ROM_START(%s) in %s" % (setname, path))

    parts, region = [], None
    for line in m.group(1).splitlines():
        r = re.search(r'ROM_REGION(?:32_LE|16_BE)?\(\s*0x[0-9a-fA-F]+\s*,\s*"(\w+)"', line)
        if r:
            region = r.group(1)
            continue
        # ROM_CONTINUE is the REST OF THE SAME FILE, landing somewhere else in
        # the region. It carries no name and no CRC, so the ROM_LOAD line above
        # it understates the file's size by exactly this much -- which is how
        # the authentic MRAs, the first to carry a whole sound01 ROM, found this
        # missing: the 2 MB PCM source read as 1 MB and every part after it
        # shifted. The scatter it implies (a 2 MB bank skipping 2 MB) is
        # spi_cpu.sv's business, not the loader's; here it is only a size.
        r = re.search(r'ROM_CONTINUE\(\s*(0x[0-9a-fA-F]+)\s*,\s*(0x[0-9a-fA-F]+)\s*\)', line)
        if r:
            if not parts:
                fail("ROM_CONTINUE with no ROM_LOAD before it")
            parts[-1]["size"] += int(r.group(2), 16)
            continue

        r = re.search(r'(ROM_LOAD(?:24_WORD|24_BYTE|32_BYTE|32_WORD)?)\('
                      r'\s*"([^"]+)"\s*,\s*(0x[0-9a-fA-F]+)\s*,\s*(0x[0-9a-fA-F]+)\s*,'
                      r'\s*CRC\(([0-9a-fA-F]+)\)', line)
        if not r:
            continue
        macro, name, off, size, crc = r.groups()
        entry = {"name": name, "crc": int(crc, 16), "size": int(size, 16),
                 "off": int(off, 16), "region": region, "macro": macro}
        if region in skip:
            entry["skipped"] = True
        elif name in special:
            entry["sdram"], entry["mode"] = special[name]
            entry["packed"] = True
        elif region not in REGION:
            fail("part %s is in unmapped MAME region %r" % (name, region))
        else:
            entry["sdram"] = REGION[region]
            entry["mode"] = mame_mode(macro, int(off, 16))
        parts.append(entry)
    if not parts:
        fail("parsed no ROMs out of ROM_START(%s)" % setname)
    return parts


def read_mra(path):
    """The MRA with XML comments removed.

    Not optional: these files document the config format by EXAMPLE, and an
    example <rom index="1"> inside a comment is what the parsers below would
    otherwise find first. Main_MiSTer uses a real XML parser and ignores
    comments, so a checker that reads them is checking a different file than
    the hardware does -- which it briefly was, reporting a codec on rdft that
    only ever existed in a comment.
    """
    src = open(path, encoding="utf-8").read()
    return re.sub(r"<!--.*?-->", "", src, flags=re.S)


def parse_mra(path):
    """Every <part> of index 0, in order, as a flat byte-stream description."""
    src = read_mra(path)
    m = re.search(r'<rom index="0".*?>(.*?)</rom>', src, re.S)
    if not m:
        fail('no <rom index="0"> in %s' % path)

    out = []
    for pm in re.finditer(r"<part\b([^>]*?)(?:/>|>(.*?)</part>)", m.group(1), re.S):
        attrs, text = pm.group(1), (pm.group(2) or "")
        name = re.search(r'name="([^"]+)"', attrs)
        crc = re.search(r'crc="([0-9a-fA-F]+)"', attrs)
        off = re.search(r'offset="((?:0x)?[0-9a-fA-F]+)"', attrs)
        ln = re.search(r'length="((?:0x)?[0-9a-fA-F]+)"', attrs)
        rep = re.search(r'repeat="((?:0x)?[0-9a-fA-F]+)"', attrs)
        if name:
            out.append({"kind": "file", "name": name.group(1),
                        "crc": int(crc.group(1), 16) if crc else None,
                        "offset": int(off.group(1), 16) if off else 0,
                        "length": int(ln.group(1), 16) if ln else None})
        else:
            nb = len(text.split())
            if nb == 0:
                fail("empty <part> in %s" % path)
            n = int(rep.group(1), 16) if rep else 1
            body = bytes(int(b, 16) for b in text.split())
            out.append({"kind": "fill" if rep else "inline", "size": n * nb,
                        "data": body * n})
    if not out:
        fail("no <part> elements in %s" % path)
    return out


def parse_codecs(path, nparts):
    """The MRA's index-1 config: the mod byte, then {part, codec} pairs.

    Nothing at runtime rejects a codec aimed at a part that does not exist, or
    an id the core has no decoder for -- the part simply loads as garbage. So
    check it here, where the part count is already known.
    """
    src = read_mra(path)
    m = re.search(r'<rom index="1".*?>(.*?)</rom>', src, re.S)
    if not m:
        return None, {}, []

    data = []
    for pm in re.finditer(r"<part\b[^>]*>(.*?)</part>", m.group(1), re.S):
        data += [int(b, 16) for b in pm.group(1).split()]
    if not data:
        fail("empty <rom index=\"1\"> in %s" % path)

    pairs = data[1:]
    if len(pairs) % 2:
        fail("%s: index-1 config has a dangling byte after the {part, codec} "
             "pairs (%d bytes after the mod byte)" % (path, len(pairs)))
    codecs = {}
    for i in range(0, len(pairs), 2):
        part, codec = pairs[i], pairs[i + 1]
        if part == 0xFF:            # documented terminator
            break
        if part >= nparts:
            fail("%s: index-1 assigns a codec to part %d, but the table has "
                 "only %d parts" % (path, part, nparts))
        if codec not in CODECS:
            fail("%s: part %d asks for codec %d, which rtl/spi_defs.vh does not "
                 "define (have: %s)" % (path, part, codec,
                                        ", ".join(sorted(CODECS.values()))))
        codecs[part] = CODECS[codec]
    return data[0], codecs, data


def check_derive_cfg(path, setname, data):
    """Bytes 16-24: the sample-flash derivation's per-set constants.

    A FOURTH copy of numbers that already exist in build_soundflash's GAMES and
    in the game's own program image, and the one nothing at runtime checks: a
    wrong job-table address here does not fail loudly, it walks nonsense. The
    RTL rejects an out-of-range source (spi_flash_derive's err_badjob), which
    turns it into a blank flash and a game that runs its own updater -- safe,
    but silent. So it is checked where it can still be shouted about.
    """
    from build_soundflash import GAMES
    GEN = {"A": 0, "B0": 1, "B1": 2}
    if setname not in GAMES:
        return
    if len(data) < 25:
        fail("%s: index-1 config is %d bytes; the derivation constants need 25 "
             "(job table at 16, stamp at 20, generation at 24)" % (path, len(data)))
    le = lambda o: (data[o] | (data[o+1] << 8) | (data[o+2] << 16) | (data[o+3] << 24))
    g = GAMES[setname]
    for name, got, want in (("job table", le(16), g["job_table"]),
                            ("stamp", le(20), g["stamp"]),
                            ("generation", data[24], GEN[g["gen"]])):
        if got != want:
            fail("%s: index-1 %s is %#x, but build_soundflash says %#x"
                 % (path, name, got, want))
    print("  derivation: job table %#010x, stamp %#010x, generation %s"
          % (le(16), le(20), g["gen"]))


def parse_loader(path, table, upd=False):
    """One of rom_loader.sv's part tables, plus its part count.

    `upd` picks the authentic-flash tail (mod byte bit 4): the cartridge tables
    carry both, as `5'dN: if (set_upd) begin ... end else begin ... end`, and
    the arm not chosen is folded away here before the ordinary parse runs.
    """
    src = open(path, encoding="utf-8").read()
    # Each table is delimited by its own marker comment, which is more robust
    # than matching the if/else shape -- and there are three of them now.
    bodies = dict(re.findall(r"// ---- TABLE (\w+):.*?\n(.*?)\n\t\tendcase", src, re.S))
    if table not in bodies:
        fail("cannot find the %s part table in %s (have: %s)"
             % (table, path, ", ".join(sorted(bodies)) or "none"))
    body = bodies[table]

    # Collapse the conditional entries to the arm this variant uses. Done as a
    # rewrite rather than by teaching the entry regex about both arms, so there
    # stays exactly one place that knows what a table entry looks like.
    cond = re.compile(r"(5'd\d+|default)\s*:\s*if \(set_upd\)\s*\n"
                      r"\s*(begin.*?end)[ \t]*(//[^\n]*)\n"
                      r"\s*else\s*(begin.*?end)[ \t]*(//[^\n]*)", re.S)
    body = cond.sub(lambda m: "%s: %s %s"
                    % (m.group(1), m.group(2 if upd else 4), m.group(3 if upd else 5)),
                    body)

    out = {}
    for e in re.finditer(r"5'd(\d+)\s*:\s*begin\s+part_base\s*=\s*([^;]+);"
                         r"\s*part_size\s*=\s*26'h([0-9a-fA-F_]+);"
                         r"\s*part_mode\s*=\s*(M_\w+);\s*end\s*//\s*(.+)", body):
        idx, base, size, mode, name = e.groups()
        out[int(idx)] = {"base": base.strip(), "size": int(size.replace("_", ""), 16),
                         "mode": mode, "name": name.strip()}
    e = re.search(r"default\s*:\s*begin\s*part_base\s*=\s*([^;]+);"
                  r"\s*part_size\s*=\s*26'h([0-9a-fA-F_]+);"
                  r"\s*part_mode\s*=\s*(M_\w+);\s*end\s*//\s*(.+)", body)
    if not e:
        fail("no default arm in the %s table" % table)
    base, size, mode, name = e.groups()
    out["default"] = {"base": base.strip(), "size": int(size.replace("_", ""), 16),
                      "mode": mode, "name": name.strip()}

    # `_U` is the authentic-flash part count. A set that exists ONLY in that
    # form -- viprp1, whose pre-flashed image no MRA can assemble -- has a
    # single table and a single count, so fall back to the plain name.
    sym = "NPARTS_" + table.upper() + ("_U" if upd else "")
    n = re.search(r"localparam \[4:0\] %s\s*=\s*5'd(\d+)" % sym, src)
    if not n and upd:
        sym = "NPARTS_" + table.upper()
        n = re.search(r"localparam \[4:0\] %s\s*=\s*5'd(\d+)" % sym, src)
    if not n:
        fail("cannot find %s in %s" % (sym, path))
    return out, int(n.group(1))


def resolve_base(expr):
    e = expr
    for k, v in (("SDR_PRG_BASE", BASES["prg"]), ("SDR_Z80_BASE", BASES["z80"]),
                 ("SDR_CHARS_BASE", BASES["chars"]), ("SDR_PCM_BASE", BASES["pcm"]),
                 ("SDR_SND01_BASE", BASES["snd01"]),
                 ("SDR_PCMSRC_SEI252", BASES["pcmsrc_sei252"]),
                 ("SDR_PCMSRC_RDFT2", BASES["pcmsrc_rdft2"]),
                 ("SDR_PCMSRC_RFJET", BASES["pcmsrc_rfjet"]),
                 ("SDR_TILES_BASE", BASES["tiles"]), ("SDR_SPRITES_BASE", BASES["sprites"]),
                 ("SPR_CHUNK_SIZE", 0x400000)):
        e = e.replace(k, hex(v))
    e = re.sub(r"26'h([0-9a-fA-F_]+)", lambda m: hex(int(m.group(1).replace("_", ""), 16)), e)
    e = re.sub(r"26'd(\d+)", lambda m: m.group(1), e)
    return eval(e, {"__builtins__": {}}, {})


def expected_base(rom):
    """Where the loader must put this ROM: region base + whole-group displacement.

    For the 3- and 4-byte-period modes the region offset is a byte LANE within a
    group, not a displacement, so only whole groups carry into the base.
    """
    off = rom["off"]
    # A packed ROM is stored whole at its own base and unpacked on the fly by
    # spi_cpu.sv, so where MAME puts it inside the sound01 region says nothing
    # about where the loader puts it -- 0x800000 there is 0 here.
    if rom.get("packed"):
        return BASES[rom["sdram"]], 0
    if rom["mode"] in ("M_24_W01", "M_24_B0", "M_24_B1", "M_24_B2"):
        disp = (off // 3) * 3
    elif rom["mode"] in ("M_32_B0", "M_32_B1", "M_32_B2", "M_32_B3",
                         "M_32_W01", "M_32_W23"):
        disp = (off // 4) * 4
    else:
        disp = off
    return BASES[rom["sdram"]] + disp, disp


def element_bytes(el, byname, bycrc):
    """The actual bytes one MRA element contributes."""
    if el["kind"] != "file":
        return el["data"]
    data = bycrc.get(el["crc"]) or byname.get(el["name"])
    if data is None:
        fail("part %r (crc %08x) is not in the archive" % (el["name"], el["crc"] or 0))
    off = el["offset"]
    n = el["length"] if el["length"] is not None else len(data) - off
    if off + n > len(data):
        fail("part %r: offset 0x%X + length 0x%X runs past the %d-byte file"
             % (el["name"], off, n, len(data)))
    return data[off:off + n]


def check_flash(cfg, table, zippath):
    """Rebuild a derived sample-flash image the way the loader will, and check it."""
    import hashlib
    from build_soundflash import expand

    z = zipfile.ZipFile(zippath)
    byname, bycrc = {}, {}
    for info in z.infolist():
        if info.is_dir():
            continue
        blob = z.read(info)
        byname.setdefault(os.path.basename(info.filename), blob)
        bycrc.setdefault(info.CRC, blob)

    spec = cfg["flash"]
    img = bytearray(b"\xFF" * spec["size"])
    for idx in spec["parts"]:
        ent = table[idx]
        data = bytearray()
        for el in ent["members"]:
            data += element_bytes(el, byname, bycrc)
        if len(data) != ent["size"]:
            fail("flash part %d: MRA supplies 0x%X bytes, table wants 0x%X"
                 % (idx, len(data), ent["size"]))
        if idx == spec["decoded"]:
            pos = [0]
            def fetch():
                b = data[pos[0]]
                pos[0] += 1
                return b
            out = bytearray()
            expand(fetch, out)
            if pos[0] != len(data):
                fail("flash part %d: the codec read 0x%X of 0x%X bytes -- the "
                     "MRA's length is wrong" % (idx, pos[0], len(data)))
            data = out
        dst = resolve_base(ent["base"]) - BASES["pcm"]
        if dst + len(data) > spec["size"]:
            fail("flash part %d runs past the end of the image" % idx)
        img[dst:dst + len(data)] = data
        print("  flash part %d -> 0x%06X..0x%06X (%d bytes%s)"
              % (idx, dst, dst + len(data) - 1, len(data),
                 ", decoded" if idx == spec["decoded"] else ""))

    got = hashlib.sha256(bytes(img)).hexdigest()
    if got != spec["sha256"]:
        fail("rebuilt flash sha256 %s != %s (the image MAME writes)"
             % (got, spec["sha256"]))
    print("  rebuilt flash matches the image MAME's own flash devices hold")


def check_set(setname, cfg, args):
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    drv = os.path.join(args.mame, "src", "mame", "seibu", "seibuspi.cpp")
    mra_path = os.path.join(here, "mra", cfg["mra"])

    print("=== %s (%s table) ===" % (setname, cfg["table"]))
    # The MAME set is the SETS key unless `mame` says otherwise: the
    # authentic-flash MRAs are a second entry for the SAME ROM_START.
    mame = parse_mame(drv, cfg.get("mame", setname), cfg["skip"],
                      cfg.get("special", {}))
    if cfg.get("spr_mode"):
        for r in mame:
            if r.get("sdram") == "sprites":
                r["mode"] = cfg["spr_mode"]
                # Chunk k of three, from where MAME puts the ROM; the loader
                # writes that chunk at sprites_base + 2k.
                r["spr_base"] = BASES["sprites"] + 2 * (r["off"] // cfg["spr_chunk"])
    mra = parse_mra(mra_path)
    # bit 4 of the mod byte is the authentic-flash variant, and it selects the
    # other tail of the same table. Taken from the SETS entry rather than from
    # the MRA's own mod byte, because the two are checked against each other
    # immediately below -- reading it from the file would make that check
    # circular.
    rtl, nparts = parse_loader(os.path.join(here, "rtl", "rom_loader.sv"),
                               cfg["table"], upd=bool(cfg["mod"] & 0x10))
    mod_byte, codecs, cfg_bytes = parse_codecs(mra_path, nparts)

    if (mod_byte or 0) != cfg["mod"]:
        fail("%s: mod byte %s, but the %s table needs %#04x"
             % (cfg["mra"], "absent" if mod_byte is None else "%#04x" % mod_byte,
                cfg["table"], cfg["mod"]))
    for part, codec in sorted(codecs.items()):
        print("  part %d decoded by %s" % (part, codec))
    # Only the authentic-flash MRAs carry them: the derivation reads the source
    # ROMs only that variant loads.
    if cfg["mod"] & 0x10:
        check_derive_cfg(mra_path, cfg.get("mame", setname), cfg_bytes)

    roms = [r for r in mame if not r.get("skipped")]
    skipped = [r for r in mame if r.get("skipped")]
    print("MAME: %d ROMs carried, %d in skipped regions (%s)"
          % (len(roms), len(skipped), ", ".join(cfg["skip"]) or "none"))

    # Sizes of the MRA's byte stream, element by element. A file element with no
    # explicit length takes its size from MAME.
    by_name = {r["name"]: r for r in mame}
    stream = []
    for el in mra:
        if el["kind"] == "file":
            if el["length"] is not None:
                size = el["length"]
            else:
                if el["name"] not in by_name:
                    fail("MRA part %r is in no ROM_START(%s) entry" % (el["name"], setname))
                size = by_name[el["name"]]["size"]
            stream.append((size, el))
        else:
            stream.append((el["size"], el))

    # Split the stream by the table's part sizes -- exactly what the hardware does.
    table = [rtl.get(i, rtl["default"]) for i in range(nparts)]
    pos, si, sub = 0, 0, 0
    for idx, ent in enumerate(table):
        want = ent["size"]
        got, members = 0, []
        while got < want:
            if si >= len(stream):
                fail("part %d (%s) wants 0x%X bytes, the MRA ran out after 0x%X"
                     % (idx, ent["name"], want, got))
            avail = stream[si][0] - sub
            take = min(avail, want - got)
            members.append(stream[si][1])
            got += take
            sub += take
            if sub == stream[si][0]:
                si += 1
                sub = 0
        if got != want:
            fail("part %d (%s): MRA supplies 0x%X, table wants 0x%X"
                 % (idx, ent["name"], got, want))
        ent["members"] = members
        pos += want
    if si != len(stream) or sub != 0:
        left = sum(s for s, _ in stream[si:]) - sub
        fail("MRA has 0x%X bytes left over after the last table part" % left)

    # Each single-file part must be the MAME ROM the table names, in order.
    ri = 0
    for idx, ent in enumerate(table):
        if len(ent["members"]) == 1 and ent["members"][0]["kind"] == "file":
            el = ent["members"][0]
            if el["length"] is not None:
                continue                      # part of a synthesised image
            if ri >= len(roms):
                fail("part %d (%s) has no MAME ROM left to match" % (idx, ent["name"]))
            rom = roms[ri]; ri += 1
            if el["crc"] != rom["crc"]:
                fail("part %d: MRA crc %08x != MAME %s crc %08x"
                     % (idx, el["crc"], rom["name"], rom["crc"]))
            if el["name"] != rom["name"]:
                fail("part %d: MRA name %r != MAME %r" % (idx, el["name"], rom["name"]))
            if ent["name"] != rom["name"]:
                fail("part %d: rom_loader comment says %r, MAME says %r"
                     % (idx, ent["name"], rom["name"]))
            if ent["size"] != rom["size"]:
                fail("part %d (%s): table size 0x%X != MAME 0x%X"
                     % (idx, rom["name"], ent["size"], rom["size"]))
            if rom["mode"] is None:
                fail("part %d (%s): cannot map %s at region offset 0x%X to a mode"
                     % (idx, rom["name"], rom["macro"], rom["off"]))
            if ent["mode"] != rom["mode"]:
                fail("part %d (%s): table mode %s, MAME %s at region offset 0x%X"
                     % (idx, rom["name"], ent["mode"], rom["mode"], rom["off"]))
            if "spr_base" in rom:
                want_base, disp = rom["spr_base"], rom["off"]
            else:
                want_base, disp = expected_base(rom)
            got_base = resolve_base(ent["base"])
            if got_base != want_base:
                fail("part %d (%s): table base 0x%X != expected 0x%X (%s + 0x%X)"
                     % (idx, rom["name"], got_base, want_base, rom["sdram"], disp))
        else:
            # A part built from several MRA elements. Any member that is a whole
            # file still has to be the next MAME ROM, in order -- otherwise a
            # part like rdft2's six-ROM sprite run would be the one place a
            # wrong CRC or a swapped pair goes unnoticed. Members with an
            # explicit length are slices of a synthesised image and are skipped,
            # as are inline bytes and fills.
            for el in ent["members"]:
                if el["kind"] != "file" or el["length"] is not None:
                    continue
                if ri >= len(roms):
                    fail("part %d (%s) member %r has no MAME ROM left to match"
                         % (idx, ent["name"], el["name"]))
                rom = roms[ri]; ri += 1
                if el["name"] != rom["name"] or el["crc"] != rom["crc"]:
                    fail("part %d member %d: MRA %s/%08x != MAME %s/%08x"
                         % (idx, ri - 1, el["name"], el["crc"], rom["name"], rom["crc"]))
                if rom["mode"] != ent["mode"]:
                    fail("part %d member %s: MAME wants %s, the part is %s"
                         % (idx, el["name"], rom["mode"], ent["mode"]))
            names = [m.get("name", m["kind"]) for m in ent["members"]]
            print("  part %-2d %-38s from %d elements: %s"
                  % (idx, ent["name"], len(ent["members"]), ", ".join(names)))

    if ri != len(roms):
        fail("%d MAME ROMs never appeared as a whole part (first: %s)"
             % (len(roms) - ri, roms[ri]["name"]))

    total = sum(e["size"] for e in table)
    print("all %d parts agree: order, name, CRC, size, scatter mode, destination"
          % nparts)
    print("download total: %d bytes (%.1f MB)" % (total, total / 1048576.0))

    if args.zip:
        z = zipfile.ZipFile(args.zip)
        have = {}
        for info in z.infolist():
            if not info.is_dir():
                have.setdefault(info.CRC, os.path.basename(info.filename))
        needed = {}
        for el in mra:
            if el["kind"] == "file" and el["crc"] is not None:
                needed[el["crc"]] = el["name"]
        missing = [(c, n) for c, n in needed.items() if c not in have]
        for c, n in missing:
            print("  MISSING crc %08x  %s" % (c, n))
        if missing:
            fail("%d of %d parts are not in %s" % (len(missing), len(needed), args.zip))
        renamed = sum(1 for c, n in needed.items() if have[c] != n)
        print("all %d distinct files present in %s by CRC%s"
              % (len(needed), os.path.basename(args.zip),
                 " (%d under the parent set's names)" % renamed if renamed else ""))
        if cfg.get("flash"):
            check_flash(cfg, table, args.zip)
    print()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--set", default="all", choices=["all"] + sorted(SETS))
    ap.add_argument("--mame", default=os.path.expanduser("~/proj/mame"))
    ap.add_argument("--zip", default=None)
    args = ap.parse_args()

    drv = os.path.join(args.mame, "src", "mame", "seibu", "seibuspi.cpp")
    if not os.path.exists(drv):
        fail("MAME driver not found at %s (pass --mame)" % drv)

    for name in (sorted(SETS) if args.set == "all" else [args.set]):
        check_set(name, SETS[name], args)
    print("PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
