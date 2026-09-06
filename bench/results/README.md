# Reference runs

Result files in the `BENCH idx=... lo=... hi=... delta=... window=...` format
`analyze.py` reads. Rows are matched by **index**, not by name, so a run taken
before a test was renamed still lines up.

| file | platform | clock | notes |
|---|---|---|---|
| `mame-2026-09-03.txt` | MAME 0.289, rfjet | 25.000 MHz | 8-frame windows, all 37 tests |
| `core-2026-09-03.txt` | the core in Verilator, `sim/tb_boot` | 28.636364 MHz | 2-frame windows, assembled from two runs because the simulator is slow; two rows carry the older `ADD R,[M]` / `ADD [M],R` spelling |
| `hw-2026-09-06.md` | **the MiSTer core on hardware**, `b8f07077` | **25.000 MHz** (the 55/63 gate) | 8-frame windows, all 37 tests in one pass. Transcribed from the text layer, not `BENCH` lines -- the screen prints ITERS and CYC but not LO, so `analyze.py` cannot re-run it. Screenshots alongside. |

```
python3 bench/analyze.py \
    mame=bench/results/mame-2026-09-03.txt \
    core=bench/results/core-2026-09-03.txt:28636364
```

The hardware column landed 2026-09-06 and did double duty: it is also the proof
that the 25 MHz clock gate works. Work per frame fell to **0.872971** of the
pre-gate Verilator run against a predicted 55/63 = 0.873016, an implied
**24.99870 MHz**, and the CYC column at 25 MHz reproduces Verilator at
28.636364 MHz on 35 of 37 rows to within 0.02. See `hw-2026-09-06.md`.

Still open is the **real cartridge** run, which is a different thing again: it is
the only thing that can settle the cartridge ROM's wait states, the misalignment
penalty, and whether the `MUL` early-out staircase is really there. `ROM ADD` is
the row to watch -- it is already the one place this core and its own Verilator
model disagree.
