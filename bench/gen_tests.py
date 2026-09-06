#!/usr/bin/env python3
"""Generate bench/blocks.inc and bench/table.inc from one list.

Every test needs two things that must agree exactly: a pair of assembled blocks
at the LO and HI lengths, and a descriptor row naming them and saying how many
units separate them.  Keeping those in step by hand across thirty-odd tests is
the sort of thing that silently reports the wrong instruction, so both come from
the TESTS table below.

    python3 bench/gen_tests.py bench

Columns of a TESTS row:

    name      up to NAMELEN (12) characters, shown on screen as-is. rfjet's
              font covers 0x20-0x5F but tiles 0x5B and 0x5D are bars, not
              brackets, so write MEM rather than [M]
    body      body macro from tests.inc
    init      init macro, run once before the loop
    prologue  per-iteration prologue; P_ZF where the body reads flags
    lo, hi    repeat counts
    loarg,
    hiarg     the body macro's argument at each length (immediates, element
              counts); equal unless the length IS the argument
    initarg   the init macro's argument
    delta     UNITS of work separating HI from LO -- the divisor of the
              differenced cycle count.  For a k-instruction body repeated n
              more times this is k*(hi-lo); for the string moves it is the
              extra element count.
    flags     TF_FROM_ROM to run in place instead of copying into RAM
    expect    Intel's published 386 count for one unit, for the report only

`share` reuses another row's blocks instead of emitting a second copy.
"""
import json
import os
import sys

LO = 10
HI = 110
D = 100                      # (HI - LO), the usual unit delta

# name            body           init        prol     lo    hi   loarg hiarg iarg delta flags        expect  share
TESTS = [
    ("NULL",       "B_NULL",      "I_NONE",   "P_NONE", LO,   HI,  0,    0,    0,   D,    "0",          0.00, None),
    ("ADD R,R",    "B_ADD_DEP",   "I_NONE",   "P_NONE", LO,   HI,  0,    0,    0,   D,    "0",          2.00, None),
    ("ADD R,I X4", "B_ADD_IND",   "I_NONE",   "P_NONE", LO,   HI,  0,    0,    0,   4*D,  "0",          2.00, None),
    ("MOV R,R",    "B_MOV_RR",    "I_NONE",   "P_NONE", LO,   HI,  0,    0,    0,   D,    "0",          2.00, None),
    ("MOV R,IMM",  "B_MOV_RI",    "I_NONE",   "P_NONE", LO,   HI,  0,    0,    0,   D,    "0",          2.00, None),
    ("LEA",        "B_LEA",       "I_NONE",   "P_NONE", LO,   HI,  0,    0,    0,   D,    "0",          2.00, None),
    ("NOP",        "B_NOP",       "I_NONE",   "P_NONE", LO,   HI,  0,    0,    0,   D,    "0",          3.00, None),
    ("SHL R,IMM",  "B_SHL_I",     "I_SHIFT",  "P_NONE", LO,   HI,  0,    0,    0,   D,    "0",          3.00, None),
    ("SHL R,CL",   "B_SHL_CL",    "I_SHIFT",  "P_NONE", LO,   HI,  0,    0,    0,   D,    "0",          3.00, None),

    ("LOAD",       "B_LOAD",      "I_MEM",    "P_NONE", LO,   HI,  0,    0,    0,   D,    "0",          4.00, None),
    ("STORE",      "B_STORE",     "I_MEM",    "P_NONE", LO,   HI,  0,    0,    0,   D,    "0",          2.00, None),
    ("ADD R,MEM",  "B_ADD_RM",    "I_MEM",    "P_NONE", LO,   HI,  0,    0,    0,   D,    "0",          6.00, None),
    ("ADD MEM,R",  "B_ADD_MR",    "I_MEM",    "P_NONE", LO,   HI,  0,    0,    0,   D,    "0",          7.00, None),
    ("LOAD MISAL", "B_LOAD_MIS",  "I_MEM",    "P_NONE", LO,   HI,  0,    0,    0,   D,    "0",          6.00, None),
    ("STORE MISA", "B_STORE_MIS", "I_MEM",    "P_NONE", LO,   HI,  0,    0,    0,   D,    "0",          4.00, None),
    ("CHASE 4K",   "B_CHASE_SMALL","I_CHASE", "P_NONE", LO,   HI,  0,    0,    0,   D,    "0",          4.00, None),
    ("CHASE 32K",  "B_CHASE_BIG", "I_CHASE",  "P_NONE", LO,   HI,  0,    0,    0,   D,    "0",          4.00, None),

    ("PUSH+POP",   "B_PUSHPOP",   "I_NONE",   "P_NONE", LO,   HI,  0,    0,    0,   2*D,  "0",          3.00, None),
    ("PUSH+ADDSP", "B_PUSHADD",   "I_NONE",   "P_NONE", LO,   HI,  0,    0,    0,   2*D,  "0",          2.00, None),
    ("SUBSP+POP",  "B_SUBPOP",    "I_NONE",   "P_NONE", LO,   HI,  0,    0,    0,   2*D,  "0",          3.00, None),

    ("JCC TAKEN",  "B_JCC_TAKEN", "I_NONE",   "P_ZF",   LO,   HI,  0,    0,    0,   D,    "0",          7.00, None),
    ("JCC NOTTKN", "B_JCC_NOT",   "I_NONE",   "P_ZF",   LO,   HI,  0,    0,    0,   D,    "0",          3.00, None),
    ("LOOP X2",    "B_LOOP",      "I_NONE",   "P_NONE", LO,   HI,  0,    0,    0,   D,    "0",         24.00, None),
    ("DECJNZ X2",  "B_DECJNZ",    "I_NONE",   "P_NONE", LO,   HI,  0,    0,    0,   D,    "0",         16.00, None),
    ("CALL+RET",   "B_CALLRET",   "I_RETSTUB","P_NONE", LO,   HI,  0,    0,    0,   D,    "0",         17.00, None),

    # MUL early-out: clocks = max(ceil(log2 m), 3) + 6, or 9 when m = 0. The
    # unit is MOV+MUL, so the expectation carries the MOV's 2 clocks with it.
    ("MUL M=0",    "B_MUL",       "I_IMM",    "P_NONE", LO,   HI,  0,    0,          0,          D, "0", 11.00, None),
    ("MUL M=1",    "B_MUL",       "I_IMM",    "P_NONE", LO,   HI,  1,    1,          1,          D, "0", 11.00, None),
    ("MUL M=FF",   "B_MUL",       "I_IMM",    "P_NONE", LO,   HI,  0xFF, 0xFF,       0xFF,       D, "0", 16.00, None),
    ("MUL M=FFFF", "B_MUL",       "I_IMM",    "P_NONE", LO,   HI,  0xFFFF, 0xFFFF,   0xFFFF,     D, "0", 24.00, None),
    ("MUL M=7FFF", "B_MUL",       "I_IMM",    "P_NONE", LO,   HI,  0x7FFFFFFF, 0x7FFFFFFF, 0x7FFFFFFF, D, "0", 39.00, None),

    # DIV has no early-out; both of these must read the same.
    ("DIV SMALL",  "B_DIV",       "I_IMM",    "P_NONE", LO,   HI,  0x3,        0x3,        7, D, "0", 42.00, None),
    ("DIV LARGE",  "B_DIV",       "I_IMM",    "P_NONE", LO,   HI,  0x7FFFFFFF, 0x7FFFFFFF, 7, D, "0", 42.00, None),

    # Here the LENGTH is the element count, so one copy at each end.
    ("REP MOVSD",  "B_REPMOVSD",  "I_NONE",   "P_NONE", 1,    1,   16,   116,  0,   D,    "0",          4.00, None),
    ("REP STOSD",  "B_REPSTOSD",  "I_NONE",   "P_NONE", 1,    1,   16,   116,  0,   D,    "0",          5.00, None),

    # 10 KB of straight-line code against 40 KB: inside the core's 16 KB
    # I-cache, then far outside it. A real 386 has no cache and must not care.
    ("FETCH 40K",  "B_FETCH",     "I_NONE",   "P_NONE", 2048, 8192, 0,   0,    0,   6144, "0",          2.00, None),

    # The same block as ADD R,R, run in place out of the cartridge ROM instead
    # of being copied to RAM. The difference is the ROM's wait states, which is
    # the one board parameter MAME does not model at all.
    ("ROM ADD",    None,          None,       None,     LO,   HI,  0,    0,    0,   D,    "TF_FROM_ROM", 2.00, "ADD R,R"),

    ("GAME MIX",   "B_GAME",      "I_GAME",   "P_NONE", LO,   HI,  0,    0,    0,   8*D,  "0",          0.00, None),
]

NAMELEN = 12


def main():
    outdir = sys.argv[1] if len(sys.argv) > 1 else "."
    prefix_of = {}
    blocks = ["; Generated by bench/gen_tests.py -- do not edit.", ""]
    table = ["; Generated by bench/gen_tests.py -- do not edit.", ""]
    manifest = []

    for i, t in enumerate(TESTS):
        (name, body, init, prol, lo, hi, loarg, hiarg,
         iarg, delta, flags, expect, share) = t
        if len(name) > NAMELEN:
            sys.exit("test name %r exceeds %d characters" % (name, NAMELEN))

        if share is not None:
            if share not in prefix_of:
                sys.exit("test %r shares blocks with %r, which is not defined "
                         "above it" % (name, share))
            prefix = prefix_of[share]
        else:
            prefix = "t%d" % i
            blocks.append("; --- %s ---" % name)
            for tag, n, arg in (("lo", lo, loarg), ("hi", hi, hiarg)):
                blocks.append("%s_%s:" % (prefix, tag))
                blocks.append("    BLKBODY %d, %s, %s, %s, %s, %s"
                              % (n, body, init, _imm(arg), _imm(iarg), prol))
                blocks.append("%s_%s_e:" % (prefix, tag))
            blocks.append("")
            prefix_of[name] = prefix

        table.append("    TESTREC '%s', %s_lo, %s_lo_e, %s_hi, %s_hi_e, %d, %s"
                     % (name, prefix, prefix, prefix, prefix, delta, flags))
        manifest.append({
            "index": i,
            "name": name,
            "delta": delta,
            "flags": flags,
            "intel386": expect if expect else None,
        })

    _write(os.path.join(outdir, "blocks.inc"), blocks)
    _write(os.path.join(outdir, "table.inc"), table)
    with open(os.path.join(outdir, "tests.json"), "w") as f:
        json.dump(manifest, f, indent=2)
        f.write("\n")
    print("%d tests -> blocks.inc, table.inc, tests.json" % len(TESTS))


def _imm(v):
    return "0x%X" % v if isinstance(v, int) else str(v)


def _write(path, lines):
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
