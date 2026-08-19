#!/usr/bin/env python3
"""Did the last fit actually meet timing?

`make build` runs the assembler whatever the Timing Analyzer says, so
`output_files/SeibuSPI.rbf` exists and looks perfectly ordinary after a fit that
FAILED. PLAN.md 34 measured how often that matters: of five seeds on one unchanged
tree, three failed and every one of them still wrote a bitstream. Two of those
failed on HOLD, which no amount of downclocking rescues.

So anything that publishes an RBF has to read the report rather than the exit code.
This is that read, and it is deliberately blunt: ANY negative slack on ANY clock,
or a single critical warning, and it says no.

    tools/check_timing.py [output_files/SeibuSPI.sta.rpt]

Exit 0 if the fit is shippable, 1 if it is not, 2 if there is no report to read --
which is its own failure, because "no report" and "a good report" must never look
the same to a release step.
"""

import os
import re
import sys

DEFAULT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                       "output_files", "SeibuSPI.sta.rpt")


def summary(text, title):
    """The (clock, slack, end-point TNS) rows of one summary table.

    Walked line by line rather than matched with one regex. The first attempt used
    `((?:;.*\n)+)` after the table's opening rule, which stops at the SECOND rule --
    the one under the column headings -- so it captured the heading row and no data
    at all. Every table then read as empty, no negative slack was found anywhere,
    and the check passed a report it had not looked at. A guard that cannot fail is
    worse than no guard, so this one is tested against a doctored report.
    """
    lines = text.split("\n")
    start = next((i for i, l in enumerate(lines)
                  if l.startswith("; " + title)), None)
    if start is None:
        return None
    rows = []
    for l in lines[start + 1:]:
        if l.startswith("+"):                 # a rule: opening, heading or closing
            if rows:
                break                         # the closing one, after the data
            continue
        if not l.startswith(";"):
            break
        cells = [c.strip() for c in l.split(";")]
        if len(cells) < 4 or cells[1] == "Clock":
            continue
        try:
            rows.append((cells[1], float(cells[2]), float(cells[3])))
        except ValueError:
            continue
    return rows


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT
    if not os.path.exists(path):
        print("FAIL: no timing report at %s -- nothing has been fitted, and an "
              "absent report must not read as a good one" % path)
        return 2
    text = open(path, encoding="utf-8", errors="replace").read()

    bad = []
    for title in ("Setup Summary", "Hold Summary", "Recovery Summary",
                  "Removal Summary", "Minimum Pulse Width Summary"):
        rows = summary(text, title)
        if rows is None:
            continue
        for clock, slack, tns in rows:
            if slack < 0 or tns < 0:
                bad.append((title, clock, slack, tns))
        if title in ("Setup Summary", "Hold Summary"):
            worst = min(rows, key=lambda r: r[1]) if rows else None
            if worst:
                print("  %-24s worst %+.3f on %s"
                      % (title, worst[1], worst[0].split("|")[0]))

    crit = len(re.findall(r"Critical Warning", text))
    if crit:
        print("  critical warnings: %d" % crit)

    if bad or crit:
        for title, clock, slack, tns in bad:
            print("FAIL: %s %+.3f (TNS %+.3f) on %s" % (title, slack, tns, clock))
        if crit and not bad:
            print("FAIL: timing summaries are positive but the report carries %d "
                  "critical warning(s), which every failing seed in PLAN.md 34 "
                  "had and every passing one did not" % crit)
        return 1

    print("timing met: every clock positive, TNS 0.000, no critical warnings")
    return 0


if __name__ == "__main__":
    sys.exit(main())
