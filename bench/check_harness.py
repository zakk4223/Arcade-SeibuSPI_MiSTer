#!/usr/bin/env python3
"""The harness's own known-answer test, run against MAME.

MAME's i386 is a table lookup of Intel's published 386 counts with no bus model
at all (src/devices/cpu/i386/cycles.h, x86_cycle_table[] column 0). That makes
it the one platform whose answer is known in advance -- so if the vblank window,
the ISR's EBP snapshot and the two-length differencing are all correct, the MAME
column has to reproduce that table to within rounding. Anything else means the
harness is wrong, not the CPU.

Two entries are expected to DISAGREE with real 386 silicon, and that is the
point of listing them:

  * the misaligned load and store come out at the aligned cost, because MAME
    charges nothing for a split bus cycle
  * the MUL sweep is flat at 41 + 2, because MAME has no early-out

Both are exactly the discriminators the real-hardware run exists to settle.

    python3 bench/check_harness.py /tmp/spi_bench/mame.txt
"""
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from analyze import Source                                    # noqa: E402

TOL = 0.06

# name -> what MAME's cycles.h must produce for one unit of this test
EXPECT = {
    "NULL":        0.00,
    "ADD R,R":     2.00,   # CYCLES_ALU_REG_REG
    "ADD R,I X4":  2.00,
    "MOV R,R":     2.00,   # CYCLES_MOV_REG_REG
    "MOV R,IMM":   2.00,   # CYCLES_MOV_IMM_REG
    "LEA":         2.00,   # CYCLES_LEA
    "NOP":         3.00,   # CYCLES_NOP
    "SHL R,IMM":   3.00,
    "SHL R,CL":    3.00,
    "LOAD":        4.00,   # CYCLES_MOV_MEM_REG
    "STORE":       2.00,   # CYCLES_MOV_REG_MEM
    "ADD R,MEM":   6.00,   # CYCLES_ALU_MEM_REG
    "ADD MEM,R":   7.00,   # CYCLES_ALU_REG_MEM
    "LOAD MISAL":  4.00,   # no split penalty in MAME
    "STORE MISA":  2.00,   # ditto
    "CHASE 4K":    4.00,
    "CHASE 32K":   4.00,   # no cache in MAME, so it must match CHASE 4K
    "PUSH+POP":    3.00,   # (2 + 4) / 2
    "PUSH+ADDSP":  2.00,   # (2 + 2) / 2
    "SUBSP+POP":   3.00,   # (2 + 4) / 2
    "JCC TAKEN":   7.00,   # CYCLES_JCC_DISP8
    "JCC NOTTKN":  3.00,
    "REP MOVSD":   4.00,   # 4 per element
    "REP STOSD":   5.00,   # 5 per element
    "DIV SMALL":  42.00,   # 38 + xor + mov
    "DIV LARGE":  42.00,   # DIV has no early-out: must equal DIV SMALL
    "FETCH 40K":   2.00,
    "ROM ADD":     2.00,   # MAME models no ROM wait states
}

MUL_FLAT = 42.98           # 41 + the MOV, level across the whole sweep


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/spi_bench/mame.txt"
    src = Source("mame=" + path)
    if not src.rows:
        sys.exit("no BENCH lines in %s" % path)

    by_name = {r["name"]: i for i, r in src.rows.items()}
    fails, checked, skipped = [], 0, []

    for name, want in EXPECT.items():
        if name not in by_name:
            skipped.append(name)
            continue
        got = src.cycles(by_name[name])
        checked += 1
        if got is None or abs(got - want) > TOL:
            fails.append("%-12s want %6.2f  got %s"
                         % (name, want, "%.3f" % got if got is not None else "-"))

    muls = [(n, i) for n, i in by_name.items() if n.startswith("MUL M=")]
    for name, idx in sorted(muls):
        got = src.cycles(idx)
        checked += 1
        if got is None or abs(got - MUL_FLAT) > 0.2:
            fails.append("%-12s want %6.2f  got %s  (MAME has no early-out, so "
                         "the sweep must be flat)"
                         % (name, MUL_FLAT, "%.3f" % got if got is not None else "-"))

    print("checked %d values against MAME's cycles.h" % checked)
    if skipped:
        print("skipped %d not in this run: %s" % (len(skipped), ", ".join(skipped)))
    if fails:
        print("\nFAIL")
        for f in fails:
            print("  " + f)
        sys.exit(1)
    print("PASS -- the vblank window and the two-length differencing agree with "
          "Intel's published counts")


if __name__ == "__main__":
    main()
