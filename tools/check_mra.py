#!/usr/bin/env python3
"""
Verify mra/rdfts.mra against MAME's driver and against the RTL loader.

Three copies of the same part list exist in this project and they have to agree
exactly, because nothing at runtime checks them:

    MAME  seibuspi.cpp ROM_START(rdfts)   the authority: names, CRCs, sizes,
                                          load macros and region offsets
    MRA   mra/rdfts.mra                   what MiSTer hands the core, IN ORDER
    RTL   rtl/rom_loader.sv               a fixed table indexed by part number,
                                          which applies the byte scatter

The MRA carries no scatter information at all -- rom_loader.sv infers everything
from the part INDEX -- so a reordered, inserted or dropped part is silently
loaded to the wrong address with no error anywhere. That is the failure this
catches.

Comparing the MRA against build_sdram_image.py would prove nothing: both are
ours and could share a mistake, which is exactly how tb_rom_loader passed for
months against a reference implementing the same wrong rule (PLAN.md 12). MAME
is the only independent source here.

Usage:
    tools/check_mra.py [--mame ~/proj/mame] [--zip rdft.zip]

With --zip, also confirms every part resolves out of that archive by CRC32,
which is how Main_MiSTer looks parts up (zip_search_by_crc, PLAN.md 11).
"""

import argparse
import binascii
import os
import re
import sys
import zipfile

SET = "rdfts"

# rtl/spi_defs.vh
BASES = {
    "prg":     0x0000000,
    "z80":     0x0200000,
    "chars":   0x0240000,
    "pcm":     0x0280000,
    "tiles":   0x0480000,
    "sprites": 0x0A80000,
}

# MAME region name -> our SDRAM region
REGION = {
    "maincpu": "prg",
    "audiocpu": "z80",
    "chars":   "chars",
    "tiles":   "tiles",
    "sprites": "sprites",
    "ymf":     "pcm",
}

# (MAME load macro, offset within region mod 4) -> the loader's scatter mode.
# ROM_LOAD24_* uses a 3-byte period, which is why MRA <interleave> cannot
# express it and the scatter lives in hardware.
def mame_mode(macro, off):
    if macro == "ROM_LOAD32_BYTE":  return {0: "M_32_B0", 1: "M_32_B1"}.get(off & 3)
    if macro == "ROM_LOAD32_WORD":  return "M_32_W23" if (off & 3) == 2 else None
    if macro == "ROM_LOAD24_WORD":  return "M_24_W01" if (off % 3) == 0 else None
    if macro == "ROM_LOAD24_BYTE":  return "M_24_B2"  if (off % 3) == 2 else None
    if macro == "ROM_LOAD":         return "M_LINEAR"
    return None


def fail(msg):
    print("FAIL: " + msg)
    sys.exit(1)


def parse_mame(path):
    """The authoritative list, in ROM_START order."""
    src = open(path, encoding="utf-8", errors="replace").read()
    m = re.search(r"ROM_START\(\s*%s\s*\)(.*?)ROM_END" % SET, src, re.S)
    if not m:
        fail("no ROM_START(%s) in %s" % (SET, path))
    body = m.group(1)

    parts, region, region_off = [], None, 0
    for line in body.splitlines():
        r = re.search(r'ROM_REGION(?:32_LE)?\(\s*(0x[0-9a-fA-F]+)\s*,\s*"(\w+)"', line)
        if r:
            region = r.group(2)
            continue
        r = re.search(r'(ROM_LOAD(?:24_WORD|24_BYTE|32_BYTE|32_WORD)?)\('
                      r'\s*"([^"]+)"\s*,\s*(0x[0-9a-fA-F]+)\s*,\s*(0x[0-9a-fA-F]+)\s*,'
                      r'\s*CRC\(([0-9a-fA-F]+)\)', line)
        if not r:
            continue
        macro, name, off, size, crc = r.groups()
        if region not in REGION:
            fail("part %s is in unmapped MAME region %r" % (name, region))
        parts.append({
            "name": name,
            "crc":  int(crc, 16),
            "size": int(size, 16),
            "off":  int(off, 16),
            "region": REGION[region],
            "mode": mame_mode(macro, int(off, 16)),
            "macro": macro,
        })
    if not parts:
        fail("parsed no ROMs out of ROM_START(%s)" % SET)
    return parts


def parse_mra(path):
    src = open(path, encoding="utf-8").read()
    # Only <part> elements carrying a crc; the MRA has none other, but be strict.
    out = []
    for m in re.finditer(r'<part\s+name="([^"]+)"\s+crc="([0-9a-fA-F]+)"\s*/>', src):
        out.append({"name": m.group(1), "crc": int(m.group(2), 16)})
    if not out:
        fail("no <part name= crc=> elements in %s" % path)
    return out


def parse_loader(path):
    """The RTL table: index -> base, size, mode, and the filename in the comment."""
    src = open(path, encoding="utf-8").read()
    out = {}
    for m in re.finditer(
            r"4'd(\d+)\s*:\s*begin\s+part_base\s*=\s*([^;]+);"
            r"\s*part_size\s*=\s*25'h([0-9a-fA-F_]+);"
            r"\s*part_mode\s*=\s*(M_\w+);\s*end\s*//\s*(\S+)", src):
        idx, base, size, mode, name = m.groups()
        out[int(idx)] = {"base": base.strip(), "size": int(size.replace("_", ""), 16),
                         "mode": mode, "name": name}
    m = re.search(r"default\s*:\s*begin\s*part_base\s*=\s*([^;]+);"
                  r"\s*part_size\s*=\s*25'h([0-9a-fA-F_]+);"
                  r"\s*part_mode\s*=\s*(M_\w+);\s*end\s*//\s*(\S+)", src)
    if m:
        base, size, mode, name = m.groups()
        out["default"] = {"base": base.strip(), "size": int(size.replace("_", ""), 16),
                          "mode": mode, "name": name}
    nparts = re.search(r"localparam \[3:0\] NPARTS\s*=\s*4'd(\d+)", src)
    if not nparts:
        fail("cannot find NPARTS in %s" % path)
    return out, int(nparts.group(1))


def resolve_base(expr, region, region_off):
    """Evaluate the RTL's part_base expression to a number."""
    e = expr.replace("SDR_PRG_BASE", hex(BASES["prg"]))
    e = e.replace("SDR_Z80_BASE", hex(BASES["z80"]))
    e = e.replace("SDR_CHARS_BASE", hex(BASES["chars"]))
    e = e.replace("SDR_PCM_BASE", hex(BASES["pcm"]))
    e = e.replace("SDR_TILES_BASE", hex(BASES["tiles"]))
    e = e.replace("SDR_SPRITES_BASE", hex(BASES["sprites"]))
    e = e.replace("SPR_CHUNK_STRIDE", hex(0x400000))
    e = re.sub(r"25'h([0-9a-fA-F_]+)", lambda m: hex(int(m.group(1).replace("_", ""), 16)), e)
    return eval(e, {"__builtins__": {}}, {})


def main():
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    ap = argparse.ArgumentParser()
    ap.add_argument("--mame", default=os.path.expanduser("~/proj/mame"))
    ap.add_argument("--mra", default=os.path.join(here, "mra", "rdfts.mra"))
    ap.add_argument("--rtl", default=os.path.join(here, "rtl", "rom_loader.sv"))
    ap.add_argument("--zip", default=None)
    args = ap.parse_args()

    drv = os.path.join(args.mame, "src", "mame", "seibu", "seibuspi.cpp")
    if not os.path.exists(drv):
        fail("MAME driver not found at %s (pass --mame)" % drv)

    mame = parse_mame(drv)
    mra = parse_mra(args.mra)
    rtl, nparts = parse_loader(args.rtl)

    print("MAME %s: %d ROMs" % (SET, len(mame)))
    print("MRA  %s: %d parts" % (os.path.basename(args.mra), len(mra)))
    print("RTL  NPARTS = %d" % nparts)

    if len(mra) != len(mame):
        fail("MRA has %d parts, MAME's %s has %d ROMs" % (len(mra), SET, len(mame)))
    if nparts != len(mame):
        fail("rom_loader NPARTS is %d, MAME's %s has %d ROMs" % (nparts, SET, len(mame)))

    # 1. MRA against MAME, in order.
    for i, (a, b) in enumerate(zip(mra, mame)):
        if a["crc"] != b["crc"]:
            fail("part %d: MRA crc %08x != MAME %s crc %08x" % (i, a["crc"], b["name"], b["crc"]))
        if a["name"] != b["name"]:
            fail("part %d: MRA name %r != MAME %r (crc matches, so this is a "
                 "naming slip, but fix it -- the name is the fallback lookup)"
                 % (i, a["name"], b["name"]))

    # 2. RTL table against MAME, in order: size, scatter mode and destination.
    for i, b in enumerate(mame):
        r = rtl.get(i) if i in rtl else rtl.get("default")
        if r is None:
            fail("rom_loader has no entry for part %d" % i)
        if r["name"] != b["name"]:
            fail("part %d: rom_loader comment says %r, MAME says %r -- the table "
                 "is indexed by MRA position, so this is a real mismatch"
                 % (i, r["name"], b["name"]))
        if r["size"] != b["size"]:
            fail("part %d (%s): rom_loader size 0x%X != MAME 0x%X"
                 % (i, b["name"], r["size"], b["size"]))
        if b["mode"] is None:
            fail("part %d (%s): cannot map MAME macro %s at offset 0x%X to a "
                 "scatter mode" % (i, b["name"], b["macro"], b["off"]))
        if r["mode"] != b["mode"]:
            fail("part %d (%s): rom_loader mode %s, MAME %s at region offset 0x%X"
                 % (i, b["name"], r["mode"], b["mode"], b["off"]))

        # Destination base. For the 3-byte-period modes the region offset is a
        # byte lane within a group, not a displacement, so only whole-group
        # offsets carry into the base.
        if b["mode"] in ("M_24_W01", "M_24_B2"):
            disp = (b["off"] // 3) * 3
        elif b["mode"] in ("M_32_B0", "M_32_B1", "M_32_W23"):
            disp = (b["off"] // 4) * 4
        else:
            disp = b["off"]
        want = BASES[b["region"]] + disp
        got = resolve_base(r["base"], b["region"], disp)
        if got != want:
            fail("part %d (%s): rom_loader base 0x%X != expected 0x%X "
                 "(region %s + 0x%X)" % (i, b["name"], got, want, b["region"], disp))

    total = sum(b["size"] for b in mame)
    print("all %d parts agree: order, name, CRC, size, scatter mode, destination"
          % len(mame))
    print("download total: %d bytes (%.1f MB)" % (total, total / 1048576.0))

    # 3. Optionally, do the parts actually resolve out of a real archive?
    if args.zip:
        if not os.path.exists(args.zip):
            fail("zip not found: %s" % args.zip)
        z = zipfile.ZipFile(args.zip)
        have = {}
        for info in z.infolist():
            if not info.is_dir():
                have.setdefault(info.CRC, os.path.basename(info.filename))
        missing = [b for b in mame if b["crc"] not in have]
        if missing:
            for b in missing:
                print("  MISSING crc %08x  %s" % (b["crc"], b["name"]))
            fail("%d of %d parts are not in %s" % (len(missing), len(mame), args.zip))
        renamed = [(b["name"], have[b["crc"]]) for b in mame
                   if have[b["crc"]] != b["name"]]
        print("all %d parts present in %s by CRC" % (len(mame), os.path.basename(args.zip)))
        if renamed:
            print("  (%d stored under the parent set's names, which is fine -- "
                  "MiSTer matches by CRC first)" % len(renamed))
            for want, got in renamed[:4]:
                print("    %s -> %s" % (want, got))

    print("PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
