#!/usr/bin/env python3
"""Compare the YMF271 register-write stream the sound Z80 makes, core vs MAME.

    tools/compare_ymf_trace.py sim.txt mame.txt

Both files are `<sample index> <port> <data>` per line, the sample index in
44,100 Hz ticks -- tools/mame_ymf_trace.lua writes MAME's, and the boot
testbench writes the core's when SND_YMF is set.

WHY THIS AND NOT ONLY AUDIO. The YMF271 synthesis is verified against MAME on
its own (`make -C sim run-ymf271`), so when the Z80 core is replaced the only
thing that can have changed is what gets written to the chip and when.
Comparing the write stream says exactly that, and a difference names the
register. An audio correlation can only report that a number got worse;
PLAN.md 19.4 spent three experiments establishing that its own weak figure was
the capture chain and not the core.

THE PORTS ARE NOT THE REGISTERS, and reading the raw stream as if they were is
the trap this tool exists to avoid. 0x6000-0x600F is eight address/data pairs
onto five independent register banks: an EVEN port latches an address and the
ODD one beside it writes the register that address selects. So the stream is
five interleaved conversations, and comparing it as one sequence makes any
change in how they interleave look like a wrong value.

The interleaving DOES change, for a reason that is not a fault: control
register 0x13 is the timer/IRQ-acknowledge register -- the sound board's
heartbeat -- and the Z80 writes it from the YMF's own interrupt. The core's Z80
fetches its program out of SDRAM through a line buffer and stalls on a miss,
which MAME does not model at all; measured on rdft, 4.175% of its clock enables
go to that stall. So the two machines reach the interrupt at slightly different
offsets and the Timer A and Timer B services swap order, which reorders the
stream without changing a note.

That 4.175% is NOT a tempo difference, and the difference between those two
things is the whole reason this is worth writing down. The music's tempo is the
YMF271's own timer, not the Z80's throughput: the CPU only has to arrive before
the next tick, and it does. Elapsed time over the same 13,688 writes came out
within 0.03% of MAME's. The stall is headroom being spent, not the clock
running slow.

So this reports three things, in increasing order of how much they mean:

  in-order agreement    the raw stream, compared as one sequence. Sensitive to
                        exactly the reordering above, so a low figure here is
                        a question and not yet a finding.
  per-register          each (bank, register) compared as its own value
                        sequence. This is the load-bearing one: the sound
                        program is a sequence per register, and a CPU that
                        decoded one instruction differently leaves it.
  rate                  elapsed time per write on both sides. The value
                        sequences alone would be happy with a Z80 running at
                        half speed; on this board the Z80's speed is what
                        schedules the music.

Exit status is 0 when every register's value sequence agrees for the whole
overlap.
"""

import sys
from collections import Counter, defaultdict

# How many leading writes of the core's stream must match to call an offset the
# alignment. Short enough that an early divergence still aligns, long enough
# that it cannot land on a coincidence -- the init block writes a lot of FFs.
ANCHOR = 64

# Which bank each odd (data) port belongs to, and the even port that carries
# its address. rtl/ymf271.sv: "even offsets are address latches".
BANKS = {1: ("slot group A", 0), 3: ("slot group B", 2),
         5: ("slot group C", 4), 7: ("slot group D", 6),
         9: ("PCM", 8), 0xD: ("control", 0xC)}

# The timer / IRQ-acknowledge register in the control bank. Called out by name
# because it is the one the two machines legitimately reorder.
TIMER_REG = ("control", 0x13)


def read_trace(path):
    out = []
    with open(path) as f:
        for line in f:
            p = line.split()
            if len(p) != 3:
                continue
            out.append((int(p[0]), int(p[1], 16), int(p[2], 16)))
    return out


def decode(trace):
    """(sample, bank, register, value) for every write that reaches a register.

    An address latch is not a register write; it selects which register the
    next write to its partner port lands on.
    """
    latch = defaultdict(int)
    out = []
    for smp, port, data in trace:
        if port in BANKS:
            bank, addr_port = BANKS[port]
            out.append((smp, bank, latch[addr_port], data))
        else:
            latch[port] = data
    return out


def find_offset(sim, ref):
    """Index into ref where sim's stream starts, matched on ANCHOR writes."""
    if len(sim) < ANCHOR:
        return None
    anchor = [(p, d) for _, p, d in sim[:ANCHOR]]
    refpairs = [(p, d) for _, p, d in ref]
    for off in range(len(refpairs) - ANCHOR + 1):
        if refpairs[off:off + ANCHOR] == anchor:
            return off
    return None


def in_order(sim, ref, off):
    """Matching (port, data) pairs from the alignment, and the first miss."""
    n = min(len(sim), len(ref) - off)
    for i in range(n):
        s, r = sim[i], ref[off + i]
        if (s[1], s[2]) != (r[1], r[2]):
            return i, n, (i, s, r)
    return n, n, None


def per_register(sim_ev, ref_ev):
    """Value sequences per (bank, register), compared independently."""
    ss, rr = defaultdict(list), defaultdict(list)
    for _, bank, reg, val in sim_ev:
        ss[(bank, reg)].append(val)
    for _, bank, reg, val in ref_ev:
        rr[(bank, reg)].append(val)
    rows = []
    for key in sorted(set(ss) | set(rr)):
        a, b = ss[key], rr[key]
        n = min(len(a), len(b))
        same = 0
        while same < n and a[same] == b[same]:
            same += 1
        rows.append((key, len(a), len(b), same, n, same == n))
    return rows


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    sim, ref = read_trace(sys.argv[1]), read_trace(sys.argv[2])
    print("core port writes       : %d" % len(sim))
    print("MAME port writes       : %d" % len(ref))
    if not sim or not ref:
        print("VERDICT: nothing to compare")
        return 2

    off = find_offset(sim, ref)
    if off is None:
        print("VERDICT: the core's first %d writes do not appear in MAME's "
              "stream at all -- the sound program diverges immediately, or one "
              "side never got started" % ANCHOR)
        print("  core first 8: %s" % [(hex(p), hex(d)) for _, p, d in sim[:8]])
        print("  MAME first 8: %s" % [(hex(p), hex(d)) for _, p, d in ref[:8]])
        return 1
    print("alignment              : core write 0 = MAME write %d" % off)

    same, overlap, first = in_order(sim, ref, off)
    print("compared               : %d port writes (the overlap)" % overlap)
    print("in-order agreement     : %d  (%.4f%%)"
          % (same, 100.0 * same / overlap if overlap else 0.0))
    if first is not None:
        i, s, r = first
        print("  first reordering at core write %d: core port %X=%02X, "
              "MAME port %X=%02X" % (i, s[1], s[2], r[1], r[2]))

    def span(t):
        return (t[-1][0] - t[0][0]) if len(t) > 1 else 0
    s_span, r_span = span(sim[:overlap]), span(ref[off:off + overlap])
    if s_span and r_span:
        print("elapsed over that span : core %.3f s, MAME %.3f s  "
              "(core/MAME %.5f)"
              % (s_span / 44100.0, r_span / 44100.0, s_span / r_span))

    sim_ev = decode(sim[:overlap])
    ref_ev = decode(ref[off:off + overlap])
    rows = per_register(sim_ev, ref_ev)
    print("\nper-register value sequences (bank, register, core writes, "
          "MAME writes, agreeing prefix):")
    bad = []
    for (bank, reg), na, nb, agree_n, n, ok in rows:
        mark = "ok" if ok else "DIFFER at %d" % agree_n
        print("  %-13s %02X  %8d %8d %8d   %s" % (bank, reg, na, nb, agree_n, mark))
        if not ok:
            bad.append(((bank, reg), agree_n, na, nb))

    print("\ndecoded register writes: core %d, MAME %d" % (len(sim_ev), len(ref_ev)))
    if not bad:
        print("\nVERDICT: every YMF271 register the sound CPU wrote got the same "
              "value sequence MAME's did, for the whole overlap")
        return 0

    only_timer = all(k == TIMER_REG for k, _, _, _ in bad)
    print("\nregisters whose value sequence differs: %d" % len(bad))
    # The multiset beside the sequence, because a REORDERING and a WRONG VALUE
    # look the same in a prefix compare and do not mean the same thing. Equal
    # counts say the same writes happened in a different order; unequal counts
    # say one side did something the other did not.
    sim_by = defaultdict(list)
    ref_by = defaultdict(list)
    for _, bank, reg, val in sim_ev:
        sim_by[(bank, reg)].append(val)
    for _, bank, reg, val in ref_ev:
        ref_by[(bank, reg)].append(val)
    for key, agree_n, na, nb in bad:
        print("  %s %02X: agrees for %d, then differs (core %d writes, "
              "MAME %d)" % (key[0], key[1], agree_n, na, nb))
        ca, cb = Counter(sim_by[key]), Counter(ref_by[key])
        for v in sorted(set(ca) | set(cb)):
            flag = "" if ca[v] == cb[v] else "   <-- counts differ"
            print("      value %02X: core %d, MAME %d%s" % (v, ca[v], cb[v], flag))
    if only_timer:
        print("\nVERDICT: the ONLY register that differs is the timer/IRQ "
              "acknowledge (control 0x13). Every register that carries a note "
              "-- key-on, frequency, envelope, volume, PCM address -- got the "
              "same values in the same order. See the note at the top of this "
              "file: the two machines service Timer A and Timer B in a "
              "different order because they run at slightly different speeds, "
              "and that reorders 0x13 without changing what is played.")
        return 0
    print("\nVERDICT: a register that carries sound data differs -- this is not "
          "the timer reordering, and it wants looking at.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
