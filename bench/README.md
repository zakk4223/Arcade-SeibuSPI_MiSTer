# A 386 IPC benchmark ROM for Seibu SPI

One 2 MB rfjet program image that runs unmodified on **MAME**, on the **core in
Verilator**, on the **MiSTer core**, and on a **real SXX2C cartridge**, and puts
its results on the game's own text layer.

## What it is for

README "Future work" #1 and `PLAN.md` 16.7 ask the same question and neither
answers it: **how much faster is z386x per clock than a real 386DX-25?** Two
things about that gap are known and one is not.

* The core clocks the CPU at 28.636364 MHz where the board runs at 25.000 MHz
  (50 MHz XTAL / 2, `seibuspi.cpp:1806`) — **+14.5 %**, and the 7/8 `altclkctrl`
  gate that fixes it is decided in `PLAN.md` 16.9 but not built.
* z386 here is the **z386x** branch, with a **16 KB L1 I-cache and 16 KB L1
  D-cache** (`spi_cpu.sv:292-293`) and hardwired fast paths. The SXX2C-MAIN
  board has no cache at all — two TC551664BJ-15 SRAMs, 15 ns, straight off the
  386 at zero wait states.
* The per-clock divergence, per instruction class, has never been measured.

So this is not "is the FPGA a 386". It is a measurement of the divergence
factor, per instruction class, on a board with **no PIT and no readable raster
counter**.

## How it measures

**Time base.** There is no 8253 anywhere on SPI and `seibu_crtc_device::read()`
just returns the stored register file, so there is nothing to poll. The only
observable event is the vblank IRQ — vector 0x20, no PIC, straight into the
386's INTR. A frame is 448 x 296 pixel clocks at 7.159091 MHz = **18.5229 ms /
53.9869 Hz**, which is **463,072 CPU clocks** on the real board. MAME's own
emulated time agrees to 0.001 % (`BENCHINFO frame_period` in every run).

**A window that costs the loop nothing.** The workload is
`<init>; .loop: <prologue> <n copies> dec ebp; jnz .loop`, entered with
EBP = 0x7FFFFFFF, and nothing inside it is ever polled. The vblank ISR snapshots
EBP on the window's first and last frames, and on the last one **rewrites the
stacked return EIP** so the loop is abandoned exactly there. The window is an
exact whole number of frames and the fine quantity is the iteration count, which
runs to tens of thousands.

**Two-length differencing.** Each test is built twice, at LO and HI lengths, and
only the difference is reported:

```
cycles_per_unit = (cpu_hz / frame_hz) * window * (1/iters_hi - 1/iters_lo) / delta
```

Loop overhead, the per-iteration prologue, the ISR and the harness appear
identically in both and cancel exactly, so none of their costs ever has to be
known. This is uops.info's method (arXiv:1810.04610 3.1) rather than Abrash's
empty-loop reference subtraction, which is strictly weaker and no cheaper.

**Timed code runs from RAM.** The cartridge ROM's wait-state count is a board
parameter MAME does not model, so every block is copied into main RAM first —
and then measured again in place, deliberately, as test `ROM ADD`.

## Is the harness right? A known-answer test

MAME's i386 is a straight lookup of Intel's published counts with no bus model
(`src/devices/cpu/i386/cycles.h`, column 0). That makes it the one platform
whose answer is known in advance, so `make check` asserts the MAME column
reproduces that table:

```
$ make check ROMS=~/Downloads/roms
checked 33 values against MAME's cycles.h
PASS -- the vblank window and the two-length differencing agree with Intel's
        published counts
```

2.00 for ALU reg,reg; 4.00 for a load; 2.00 for a store; 6.00 and 7.00 for the
two read-modify-write forms; 7.00 taken and 3.00 not-taken for `Jcc`; 4.00 and
5.00 per element for `REP MOVSD` / `REP STOSD`; 42.00 for `DIV`; and −0.00 for
the null test. **Run this before believing any other column.**

A second, reference-free check: **the window length must not change the
answer**, since it is divided out. `make check-window` builds the same suite at
8 and 32 frames and compares. Every ratio comes out 1.000, which tests the ISR's
EBP snapshot, the frame accounting and the differencing against each other with
no external truth involved at all.

Two rows are expected to disagree with real silicon, and that is the point of
having them:

* `LOAD MISAL` / `STORE MISA` come out at the aligned cost, because MAME charges
  nothing for a split bus cycle.
* the `MUL M=` sweep is flat at 43, because MAME charges 41 whatever the
  multiplier is and has no early-out. A real 386 must produce a staircase:
  `max(ceil(log2 m), 3) + 6` clocks, or 9 when m is zero.

## Building

```
make -C bench            # everything
```

Produces, in `bench/out/` (8-frame windows, all 37 tests):

| file | for |
|---|---|
| `bprg0.u0211` … `bprg3.u0220` | four 512 KB images, byte-interleaved — burn these |
| `bench.zip` | the same four, for the MiSTer core |
| `bench_patched.bin` | the flat 2 MB image, for MAME and Verilator |
| `Raiden Fighters Jet (386 Benchmark).mra` | for the MiSTer core |

and in `bench/out-quick/` the same with 2-frame windows and a test subset, for
Verilator. The window and the test mask are patched into the `BCFG` block at ROM
offset 0 by `build_rom.py`, so both variants come out of one assembly rather than
two builds that can drift apart. The metric is per-frame, so a shorter window
costs precision and nothing else.

The parts are named `bprg*` on purpose: the benchmark MRA lists
`zip="rfjet.zip|bench.zip"` so graphics and sound still come from the genuine
set, and if these were called `prg0.u0211` the loader would find the game's own
ROM first and quietly run the game.

## Running

### MAME

To watch it, in a window, and page it with the arrow keys:

```
./bench/run_mame.sh -r ~/Downloads/roms
```

To just get the table:

```
./bench/run_mame.sh -r ~/Downloads/roms -t
```

or `make -C bench mame ROMS=~/Downloads/roms`, which is the same run wired into
the Makefile.

The image is written straight into the `":maincpu"` region and the machine soft
reset, which sidesteps the CRC check entirely — no doctored zip, no rebuilt
driver. rfjet's idle-loop speedup handler over 0x2894C (`seibuspi.cpp:2063`) is
harmless: it only spins when the PC is 0x0206082, which is the game's loop and
never ours. Results land in `/tmp/spi_bench/mame.txt`.

Worth doing once in a window: it exercises the same text-layer path the two
photograph-only targets depend on, so a rendering problem shows up here rather
than on a cabinet. Leave MAME's rotation alone — the default 240x320 view is
the upright one (see below).

### The core, in Verilator

```
make -C bench sim ROMS=~/Downloads/roms
```

Builds an SDRAM image with `tools/build_sdram_image.py --prg`, which substitutes
only the 2 MB program region, then runs `sim/tb_boot`. Results come out as writes
to the **0x4F0 doorbell** — an address nothing decodes, so `spi_io` drops the
write while `spi_cpu` still raises `io_wr`, which `tb_boot.cpp` already records.
No RTL change anywhere.

Budget about 4.24M `clk_ram` half-steps per video frame and roughly ten frames
per test. The `BR TARGET MISMATCH` lines in the raw log are that bench's own
branch check noticing the vblank interrupt landing on a branch: expected here,
because the ISR is what ends every measurement.

### The MiSTer core

`make -C bench dist` lays out everything the SD card needs, along with
`INSTALL.txt`:

```
bench/dist/_Arcade/Raiden Fighters Jet (386 Benchmark).mra
bench/dist/_Arcade/mame/bench.zip
bench/dist/INSTALL.txt
```

Copy those two over the matching directories on the MiSTer. The real
`rfjet.zip` and the SeibuSPI core have to already be there — the MRA lists both
zips and takes only the four program parts from `bench.zip`.

**Set Refresh Rate to Normal and CRT V-Size to 0 first.** Both change VTOTAL,
and the window is counted in frames, so a non-standard raster rescales every
number on screen.

`gen_mra.py --verify` (which `make mra` runs whenever `ROMS` has an `rfjet.zip`)
checks the one thing that can silently go wrong here: `rom_loader.sv`'s
`SET_RFJET` table is **positional**, so a substituted part of the wrong length
would shift every later region and the core would load garbage without
complaining. It confirms all 17 parts, 40,566,784 bytes, sizes identical to the
stock MRA.

### A real cartridge

```
make -C bench eproms
```

Burn `bprg0.u0211` … `bprg3.u0220` (512 KB each, 27C040-class) into u0211,
u0212, u0221 and u0220 — D7-0, D15-8, D23-16, D31-24. `build_rom.py` checks
that re-interleaving the four reproduces the 2 MB image byte for byte before it
writes them, because four EPROMs is an expensive way to find out the split was
wrong. This is the reference the whole exercise exists to obtain.

### Reporting

```
make -C bench report
```

or directly, once results from more than one platform exist:

```
python3 bench/analyze.py \
    mame=/tmp/spi_bench/mame.txt \
    core=/tmp/spi_bench/core.txt:28636364 \
    hw=/tmp/spi_bench/hw.txt
```

Each argument is `label=path[:cpu_hz[:frame_hz]]`. Use `28636364` for the core
as it stands, or `25056818` once the 7/8 gate lands. Hardware numbers can be
typed into a file by hand from a photograph — the on-screen `ITERS-HI` column is
the raw measurement and is all `analyze.py` needs, along with the `lo` value from
a second reading.

## Reading the screen

```
SPI 386 BENCH   W=  8
TEST            ITERS     CYC
NULL           411526    0.00
ADD R,R         16173    2.00
ADD R,I X4       4167    2.00
...
GAME MIX          570    7.37
COMPLETE
```

`ITERS` is what was actually observed: iterations of the HI block completed
inside one window. `CYC` is derived **assuming the board's 25.000 MHz**, so on
the core as it stands today it reads about 12.5 % low across the board;
`analyze.py` redoes it with the right clock. A blank line is a test that has not
run yet.

### Why the layout is transposed

rfjet is **ROT270** (`seibuspi.cpp:4353`), which MAME defines as
`ORIENTATION_SWAP_XY | ORIENTATION_FLIP_Y`: a framebuffer pixel (x, y) is shown
at (y, 319 − x). In 8×8 tiles,

```
screen_column = fb_row          screen_line = 39 - fb_col
```

so a framebuffer **row** appears on screen as a **vertical strip**. The first
version of this ROM wrote its table along framebuffer rows and produced a
perfectly correct table laid out sideways — and its own text-buffer dump, which
read the buffer the same wrong way, agreed with it. Text has to run *down* a
framebuffer column instead, with successive lines advancing leftwards along X.

The glyphs need no such help: the fix ROM stores them already rotated, which is
why the game's own "XTF PROJECT" reads upright in MAME's default view.

That leaves a **30-character by 40-line** screen, and 2 header lines + 37 tests
+ 1 footer is exactly 40 — so everything fits on one screen and the paging code
never fires.

Two more things the font imposes. It is **shaded**: over tiles 0x20–0x5F it uses
exactly seven pens — 0, 2, 4, 6, 8, 15 and the transparent 31 — with 15 as a
black outline and 0–8 a bright-to-dark grey ramp, and the letter shape lives in
the shading rather than the silhouette. Filling the colour bank with white, the
other thing this ROM did first, turns every glyph into an unreadable blob; the
palette is now copied from the values the real game leaves in its own buffer.
And tiles 0x5B and 0x5D are bars, not brackets, so test names say `ADD R,MEM`
rather than `ADD R,[M]`.

## The video bring-up, and why it is a replay

The benchmark has to bring the video hardware up on a real PCB, and neither
emulator can say how. MAME hardcodes rfjet's tile-decryption keys and its
`tile_decrypt_key_w` only logs (`seibuspi_v.cpp:140`); the core hardcodes
`TKEY*_RFJET` in `spi_defs.vh`. The game meanwhile writes six 16-bit words to
0x414 that both throw away.

So rather than reverse-engineer the RISE chip, `tools/mame_vidinit_trace.lua`
captures **every** write the real game makes to 0x400-0x6FF between reset and its
first tilemap DMA — 104 of them, inside 0.18 ms — and `tools/gen_vidinit.py`
turns that into a table the ROM replays verbatim and in order
(`vidinit_trace.txt` → `vidinit.inc`, both checked in). The game's own state at
that moment is already what the benchmark wants: layer-enable 0x17, which is
text only, and layer-bank 0x8028, which is rowscroll on and no flip.

## Files

| file | |
|---|---|
| `bench.asm` | the ROM: real-mode bring-up, flat protected mode, the harness, the vblank ISR, text output |
| `spi.inc` | hardware constants, cross-checked against MAME's map and `spi_cpu.sv`'s |
| `tests.inc` | the block emitter, the body macros, and the rules a body must obey |
| `gen_tests.py` | one TESTS list → `blocks.inc`, `table.inc`, `tests.json` |
| `build_rom.py` | split, patch the config block, zip, and verify the interleave round-trips |
| `gen_mra.py` | derive the benchmark MRA from the stock rfjet one |
| `mame_bench.lua` | patch, soft reset, poll the results block |
| `analyze.py` | iterations → cycles, and the platform comparison |
| `check_harness.py` | the known-answer test against MAME's `cycles.h` |
| `tools/dump_charset.py` | decrypt and render rfjet's fix ROM (tile index == ASCII over 0x20-0x5F) |
| `tools/mame_vidinit_trace.lua`, `tools/gen_vidinit.py` | capture and replay the game's video init |

## What the ROM assumes

* Protected mode, flat 4 GB, paging off, CPL 0, GDT and IDT both in ROM.
* EBP is the iteration counter and is reserved; blocks are memcpy'd into RAM and
  so must be position independent.
* Main RAM 0x00000-0x3FFFF, with 0x400-0x7FF the I/O overlay. 0x28000-0x2FFFF is
  left unused because MAME installs a read handler over 0x2894C.
* No watchdog is kicked. If a real SXX2C turns out to have one that the Z80
  services, the benchmark will need to start the sound board too.
