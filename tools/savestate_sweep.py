#!/usr/bin/env python3
"""Sweep savestate save points and compare a save-only run against a restored one.

PLAN.md 40 ran this once, by hand, and the script did not survive -- which cost a
later session a round of guessing. This is that sweep, checked in.

WHAT IT COMPARES, and why it is not a whole-stream diff (PLAN.md 40.1):

    skew       the constant instruction offset between the two EIP trails, found
               by a BOUNDED search. An unbounded one finds false matches: a
               256-instruction window recurs ~62,000 times in a game loop, so the
               longest match comes from whichever iteration happens to line up.
    lockstep   how far the two streams then run identically at that skew. THIS is
               the number that means something.
    registers  for each I/O register, the SEQUENCE OF VALUES it returned. Immune
               to the interleaving shift a poll-phase offset causes, which a
               whole-stream diff mistakes for a wrong value -- it did once.

Do not quote a raw prefix-agreement number. It is dominated by the skew: two runs
in perfect lockstep at a 40-instruction offset read about 10 at offset zero.

THE OFFSET TRAP (PLAN.md 45): the restore must be asked for AFTER the save has
finished, with the board running normally in between. A save takes ~1.23 M cycles
and that grew by ~191 k at PLAN.md 42, so an offset carried over from an older
sweep silently becomes a back-to-back test instead. This script measures each
save's actual completion cycle and REFUSES the point if the restore was asked for
before it, rather than reporting a number that means something else.
"""
import argparse, os, re, struct, subprocess, sys, tempfile
from pathlib import Path

# The bench's own verdicts. `resumed at the saved EIP: NO` is keyed on a short
# trail that is usually empty and was a FALSE VERDICT throughout PLAN.md 39;
# the line below is the one to believe.
RE_RESUME   = re.compile(r"^restore\s+: (.*)$", re.M)
RE_EXACT    = re.compile(r"main RAM restored\s+: ([0-9A-F]+)\s+<- (\w+)", re.M)
RE_SAVEDONE = re.compile(r"SAVE COMPLETE at cycle (\d+)", re.M)
RE_LOADASK  = re.compile(r"load asked for at cycle (\d+)", re.M)
RE_SAVEASK  = re.compile(r"save asked for at cycle (\d+)", re.M)


def bench_cwd(bench):
    """The directory holding ucode.hex, which the bench must be run from.

    z386 $readmem's it by a relative path, and running from anywhere else fails
    an assertion several thousand lines into the core rather than saying what is
    wrong -- so find it rather than assume a fixed hop up from obj_dir/."""
    d = Path(bench).resolve().parent
    for cand in [d, *d.parents]:
        if (cand / "ucode.hex").exists():
            return str(cand)
    sys.exit("cannot find ucode.hex above %s -- the bench will not run" % bench)


def run(bench, sdram, steps, setname, env_extra, cwd):
    env = dict(os.environ)
    env.update({k: str(v) for k, v in env_extra.items()})
    p = subprocess.run([bench, sdram, str(steps), setname],
                       capture_output=True, text=True, env=env, cwd=cwd)
    # rc 1 is the bench's own download check, not a failure of the run.
    return p.stdout, p.returncode


def read_u32(path):
    try:
        b = Path(path).read_bytes()
    except FileNotFoundError:
        return []
    return list(struct.unpack("<%dI" % (len(b) // 4), b[:len(b) // 4 * 4]))


STUB_LO, STUB_HI = 0x40000, 0x40400


def strip_stub(t):
    """Drop the leading EIPs that are still inside the savestate stub.

    A save-only run's anchor lands with the CPU already back in game code; a
    restored run's lands with it still in the RESTORE stub, so its trail opens
    with that stub's last instructions and the iret's landing (PLAN.md 40.1).
    The two stubs are different lengths, so comparing from index 0 aligns a
    prologue against a prologue and reports zero agreement at every skew --
    which is exactly what happened the first time this script ran."""
    i = 0
    while i < len(t) and STUB_LO <= t[i] < STUB_HI:
        i += 1
    return t[i:], i


def find_skew(a, b, max_skew, window):
    """Bounded skew search: the offset that makes the two trails agree longest.

    Bounded on purpose -- see the module docstring. Returns (skew, lockstep)."""
    # Scanned from |skew| = 0 OUTWARDS, and ties go to the smaller offset. A
    # game poll loop means many skews agree for a long way -- the loop body
    # simply repeats -- so scanning from the bound inwards reports whichever
    # late iteration happens to line up, which is the false match 40.1 warns
    # about. It reported -2046 here before this was fixed, against a true 0.
    order = [0]
    for k in range(1, max_skew + 1):
        order += [-k, k]
    best = (0, -1)
    for s in order:
        ai, bi = (0, s) if s >= 0 else (-s, 0)
        n = 0
        while ai + n < len(a) and bi + n < len(b) and a[ai + n] == b[bi + n]:
            n += 1
        if n > best[1]:
            best = (s, n)
        if n >= window:          # saturated at the smallest offset that can
            break                # -- nothing further out can beat it
    return best


def per_register(pairs):
    """addr -> the sequence of values it returned."""
    seq = {}
    for i in range(0, len(pairs) - 1, 2):
        seq.setdefault(pairs[i], []).append(pairs[i + 1])
    return seq


def compare_registers(sa, sb):
    """Returns (n_registers, n_identical, [(addr, detail), ...])."""
    addrs = sorted(set(sa) | set(sb))
    bad = []
    for a in addrs:
        va, vb = sa.get(a, []), sb.get(a, [])
        n = min(len(va), len(vb))
        if va[:n] != vb[:n]:
            first = next(i for i in range(n) if va[i] != vb[i])
            bad.append((a, "value %d differs: %08X vs %08X"
                           % (first, va[first], vb[first])))
        elif not va or not vb:
            bad.append((a, "read in only one run (%d vs %d)" % (len(va), len(vb))))
    return len(addrs), len(addrs) - len(bad), bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bench", default="sim/obj_dir/Vtb_boot_top")
    ap.add_argument("--sdram", required=True)
    ap.add_argument("--set", dest="setname", required=True)
    ap.add_argument("--points", default="250000:12000000:250000",
                    help="start:stop:step, or a comma list of cycles")
    ap.add_argument("--restore-gap", type=int, default=2000000,
                    help="cycles after the save REQUEST to ask for the restore. "
                         "Must clear the save's ~1.23 M duration with room to "
                         "spare; the run is refused if it does not.")
    ap.add_argument("--trail", type=int, default=250000,
                    help="EIPs to compare after the operation. The bench's own "
                         "cap is 400,000 and is not configurable; this only "
                         "trims what is compared.")
    ap.add_argument("--max-skew", type=int, default=2048)
    ap.add_argument("--tail", type=int, default=3000000,
                    help="cycles to keep running after the restore")
    args = ap.parse_args()

    if ":" in args.points:
        a, b, c = (int(x) for x in args.points.split(":"))
        points = list(range(a, b + 1, c))
    else:
        points = [int(x) for x in args.points.split(",")]

    bench = str(Path(args.bench).resolve())
    sdram = str(Path(args.sdram).resolve())
    cwd = bench_cwd(bench)
    tmp = tempfile.mkdtemp(prefix="sssweep-")

    print("set %s, %d save points, restore +%d, trail %d EIPs"
          % (args.setname, len(points), args.restore_gap, args.trail))
    print("%-11s %-7s %-17s %-8s %-7s %s"
          % ("save@", "skew", "lock/cmp", "RAM", "resume", "registers"))

    tally = {"ok": 0, "bad": 0, "refused": 0}
    for sp in points:
        rp    = sp + args.restore_gap
        steps = (rp + args.tail) * 4          # the bench counts model steps
        ta, tb = f"{tmp}/a.trail", f"{tmp}/b.trail"
        ia, ib = f"{tmp}/a.iord",  f"{tmp}/b.iord"
        for f in (ta, tb, ia, ib):
            Path(f).unlink(missing_ok=True)

        # SS_TRAIL's anchor is only assigned inside the hash block, so
        # SS_HASH_AFTER has to be set as well or the trail comes back empty.
        common = {"SS_AT": sp, "SS_HASH_AFTER": 200000}
        out_a, rc_a = run(bench, sdram, steps, args.setname,
                          {**common, "SS_TRAIL": ta, "SS_IORD": ia}, cwd)
        out_b, rc_b = run(bench, sdram, steps, args.setname,
                          {**common, "SS_TRAIL": tb, "SS_IORD": ib,
                           "SS_RESTORE_AT": rp, "SS_RELOADS": 1}, cwd)

        # A CRASH IS NOT A DATA CONDITION. A SIGSEGV kills the run before it
        # writes SS_TRAIL, which looks exactly like an empty trail -- and 18 of
        # the first sweep's 96 points were written off that way before the
        # cause was found. Say which it is. (PLAN.md 48)
        if rc_a not in (0, 1) or rc_b not in (0, 1):
            print("%-11d  the bench CRASHED (rc %d / %d) -- point refused"
                  % (sp, rc_a, rc_b))
            tally["refused"] += 1
            continue

        # THE OFFSET TRAP. Refuse rather than report a number about a different
        # experiment than the one asked for.
        done = RE_SAVEDONE.search(out_a)
        ask  = RE_LOADASK.search(out_b)
        if not done:
            print("%-11d  the save never completed -- point refused" % sp)
            tally["refused"] += 1
            continue
        if ask and int(ask.group(1)) <= int(done.group(1)):
            print("%-11d  restore asked at %s but the save only finished at %s "
                  "-- back-to-back, point refused (raise --restore-gap)"
                  % (sp, ask.group(1), done.group(1)))
            tally["refused"] += 1
            continue

        a, na = strip_stub(read_u32(ta)[:args.trail])
        b, nb = strip_stub(read_u32(tb)[:args.trail])
        if not a or not b:
            print("%-11d  empty trail (a=%d b=%d) -- point refused"
                  % (sp, len(a), len(b)))
            tally["refused"] += 1
            continue

        cmpn = min(len(a), len(b))
        skew, lock = find_skew(a, b, args.max_skew, cmpn)
        # "agreed for N" and "agreed to the end of what was captured" are very
        # different claims. PLAN.md 40 quoted a lockstep of ~204,000 as good
        # without saying which it was.
        full = lock >= cmpn - abs(skew)
        exact  = RE_EXACT.search(out_b)
        ramok  = exact and exact.group(2) == "EXACT"
        resume = RE_RESUME.search(out_b)
        resok  = resume and "resumed at the saved CS:EIP" in resume.group(1)
        # Compare the same NUMBER OF READS from each run, not each run's whole
        # stream. The save-only run always has about twice as much post-anchor
        # time as the restored one -- the restore spends ~1.06 M cycles frozen
        # inside the same total -- so it reaches registers the other has simply
        # not got to yet. Left untruncated that shows up as "read in only one
        # run", which looks like a finding and is an artefact of the window.
        ra, rb = read_u32(ia), read_u32(ib)
        n_io = min(len(ra), len(rb)) & ~1          # whole (addr, value) pairs
        nreg, nsame, bad = compare_registers(per_register(ra[:n_io]),
                                             per_register(rb[:n_io]))
        # THE VERDICT RESTS ON THE REGISTER VALUES, not on the EIP lockstep.
        # 40.1 said so and this script did not listen: the streams re-phase
        # whenever the restored run takes one fewer turn of a poll loop, which
        # shifts every EIP after it without a single value being wrong. Measured
        # on rdft2 at 250 k: the streams part after 176,684 instructions because
        # B leaves a loop at 002A1A50 one iteration early -- and all three
        # registers, 0x600 / 0x60C / 0x6DC, return IDENTICAL value sequences
        # over 39,634 reads. That is a phase offset, not a divergence, and
        # calling it a failure buries the ones that are.
        good = ramok and resok and not bad
        note = "" if full else ("  phase-shift after %d (values all identical)"
                                % lock if not bad else "")
        tally["ok" if good else "bad"] += 1
        print("%-11d %-7d %-17s %-8s %-7s %d/%d%s"
              % (sp, skew,
                 ("%d/%d%s" % (lock, cmpn, "" if full else " phase")),
                 "EXACT" if ramok else "MISMATCH",
                 "yes" if resok else "NO",
                 nsame, nreg,
                 note if not bad
                 else "  " + "; ".join("%04X %s" % x for x in bad[:2])))

    print("\n%d clean, %d with a difference, %d refused"
          % (tally["ok"], tally["bad"], tally["refused"]))
    print("`phase` means the EIP streams re-phase on a poll loop while every "
          "register's\nvalue sequence stays identical -- informational, not a "
          "failure. See PLAN.md 40.1.")
    return 1 if tally["bad"] or tally["refused"] else 0


if __name__ == "__main__":
    sys.exit(main())
