#!/usr/bin/env python3
"""
Generate the RISE11 sprite decryption constants from MAME's seibuspi_m.cpp.

RISE11 (rfjet, and feversoc on quite different hardware) is the third of the
Seibu sprite crypts this core carries. Structurally it sits between the other
two: no key table and no per-tile fetch like SEI252, but NOT address
independent like RISE10 -- the plane210 sum takes the WORD INDEX as its addend,
which is why spi_rise11_decrypt.sv has an `i` port and spi_rise10_decrypt.sv
does not.

What has to be parsed rather than typed is the pair of 24-bit gathers: 48
hand-ordered (source word, source bit, destination bit) triples, which is
exactly the shape of thing PLAN.md section 5.4 records going silently wrong.
The strongest check available is free here and is applied below: the two
gathers together must consume all 48 source bits of b1/b2/b3 exactly once.

tools/gen_ref_c.py separately COPIES MAME's function for the testbench, so
agreement between the two validates this parser instead of being
self-consistent.

Usage:
    tools/gen_rise11_tables.py [path/to/mame] > rtl/spi_rise11_tables.vh
"""

import os
import re
import sys

DEFAULT_MAME = os.path.expanduser("~/proj/mame")


def grab_func(src):
    m = re.search(r"static void seibuspi_rise11_sprite_decrypt\(u8 \*rom, int size,"
                  r".*?\n\{(.*?)\n\}", src, re.S)
    if not m:
        raise SystemExit("could not find seibuspi_rise11_sprite_decrypt")
    return m.group(1)


def parse_gather(body, name):
    """One `u32 planeNNN = (BIT(bK,s)<<d) | ...;` block.

    Returns a list of 24 (word, source bit) pairs indexed by DESTINATION bit.
    """
    m = re.search(r"u32 %s\s*=\s*(.*?);" % name, body, re.S)
    if not m:
        raise SystemExit("could not find the %s gather" % name)
    terms = re.findall(r"BIT\(\s*(b[123])\s*,\s*(\d+)\s*\)\s*<<\s*(\d+)", m.group(1))
    if len(terms) != 24:
        raise SystemExit("expected 24 %s terms, got %d" % (name, len(terms)))

    by_dest = {}
    for word, sbit, dbit in terms:
        d = int(dbit)
        if d in by_dest:
            raise SystemExit("%s writes destination bit %d twice" % (name, d))
        if d > 23:
            raise SystemExit("%s destination bit %d is outside 24 bits" % (name, d))
        by_dest[d] = (word, int(sbit))
    if sorted(by_dest) != list(range(24)):
        raise SystemExit("%s does not cover destination bits 0..23" % name)
    return [by_dest[d] for d in range(24)]


def check_permutation(g543, g210):
    """The two gathers together must be a permutation of the 48 source bits.

    This is the check that a transcription error cannot survive: dropping,
    duplicating or mistyping any one source bit breaks it.
    """
    seen = g543 + g210
    if len(set(seen)) != 48:
        dupes = sorted({s for s in seen if seen.count(s) > 1})
        raise SystemExit("source bits used more than once: %s" % (dupes,))
    want = {(w, b) for w in ("b1", "b2", "b3") for b in range(16)}
    if set(seen) != want:
        raise SystemExit("gathers do not consume every bit of b1/b2/b3: missing %s"
                         % sorted(want - set(seen)))


def parse_keys(src, which):
    """The five constants a wrapper passes, plus the feversoc kludge flag."""
    m = re.search(r"void seibuspi_rise11_sprite_decrypt_%s\(u8 \*rom, int size\)\s*\{"
                  r"\s*seibuspi_rise11_sprite_decrypt\(rom, size,\s*"
                  r"(0x[0-9a-fA-F]+),\s*(0x[0-9a-fA-F]+),\s*(0x[0-9a-fA-F]+),\s*"
                  r"(0x[0-9a-fA-F]+),\s*(0x[0-9a-fA-F]+),\s*(\d+)\s*\)" % which,
                  src, re.S)
    if not m:
        raise SystemExit("could not parse the %s key list" % which)
    return [int(m.group(i), 16) for i in range(1, 6)] + [int(m.group(6))]


def parse_sums(body):
    """Which sum takes which operand. Guards against the addend being read
    off the wrong one: plane543's is a constant, plane210's is the index."""
    m543 = re.search(r"plane543\s*=\s*seibu_partial_carry_sum32\(plane543,\s*"
                     r"k1,\s*k2\)\s*\^\s*k3", body)
    m210 = re.search(r"plane210\s*=\s*seibu_partial_carry_sum24\(plane210,\s*"
                     r"i,\s*k4\)\s*\^\s*k5", body)
    if not m543 or not m210:
        raise SystemExit("the two partial-carry sums are not the shape this "
                         "generator was written for -- re-read the function")


def emit_gather(o, macro, gather):
    o.append("`define %s(b1, b2, b3) { \\" % macro)
    # Verilog concatenation is MSB first, so destination 23 leads.
    parts = ["%s[%2d]" % gather[d] for d in range(23, -1, -1)]
    for i in range(0, 24, 4):
        last = (i + 4 >= 24)
        o.append("\t" + ", ".join(parts[i:i + 4]) + ("" if last else ",") +
                 (" }" if last else " \\"))


def main():
    mame = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_MAME
    path = os.path.join(mame, "src/mame/seibu/seibuspi_m.cpp")
    src = open(path).read()
    body = grab_func(src)

    parse_sums(body)
    g543 = parse_gather(body, "plane543")
    g210 = parse_gather(body, "plane210")
    check_permutation(g543, g210)

    k = parse_keys(src, "rfjet")
    if k[5] != 0:
        raise SystemExit("rfjet is not supposed to take the feversoc kludge")
    fs = parse_keys(src, "feversoc")

    # plane543's sum is MAME's 32-bit one over 24-bit operands, and the RTL uses
    # a 24-bit adder for both. That is only exact while no carry can reach bit
    # 24, i.e. while the carry mask's top bit is clear -- check it rather than
    # believe it. (With bits 24..31 of a, b and mask all zero, the sum's high
    # byte stays zero and the wrap-around carry is zero at either width.)
    if k[1] & (1 << 23):
        raise SystemExit("R11_MASK543 carries out of bit 23; the 24-bit adder "
                         "is no longer equivalent to MAME's sum32")

    o = []
    o.append("//" + "=" * 74)
    o.append("//  SlopperPI - RISE11 sprite decryption constants")
    o.append("//")
    o.append("//  GENERATED by tools/gen_rise11_tables.py from")
    o.append("//  %s" % os.path.relpath(path, mame))
    o.append("//  Do not edit.")
    o.append("//")
    o.append("//  The two gathers below are checked at generation time to consume all 48")
    o.append("//  source bits of b1/b2/b3 exactly once, which is the property a mistyped")
    o.append("//  entry cannot have.")
    o.append("//")
    o.append("//  Only rfjet's keys are emitted. feversoc shares the codec but not the")
    o.append("//  hardware -- it is an SH-2 board in a different driver -- and it also")
    o.append("//  takes an extra +1 partial sum this core has no reason to carry. Its")
    o.append("//  keys, for the record: %s." %
             " ".join("%06X" % v for v in fs[:5]))
    o.append("//" + "=" * 74)
    o.append("")
    o.append("// plane543 = partial_carry_sum(gather543, R11_ADD543, R11_MASK543)")
    o.append("//            ^ R11_XOR543")
    o.append("localparam [23:0] R11_ADD543  = 24'h%06X;" % k[0])
    o.append("localparam [23:0] R11_MASK543 = 24'h%06X;" % k[1])
    o.append("localparam [23:0] R11_XOR543  = 24'h%06X;" % k[2])
    o.append("")
    o.append("// plane210's addend is the WORD INDEX, not a constant -- this is the whole")
    o.append("// difference between RISE11 and RISE10 as far as the core is concerned.")
    o.append("localparam [23:0] R11_MASK210 = 24'h%06X;" % k[3])
    o.append("localparam [23:0] R11_XOR210  = 24'h%06X;" % k[4])
    o.append("")
    o.append("// Destination bit d of each gather takes bit [n] of the named input word.")
    o.append("// The arguments must be simple identifiers: Verilog cannot index a")
    o.append("// parenthesised expression, so no (v) here.")
    emit_gather(o, "R11_GATHER543", g543)
    o.append("")
    emit_gather(o, "R11_GATHER210", g210)
    print("\n".join(o))


if __name__ == "__main__":
    main()
