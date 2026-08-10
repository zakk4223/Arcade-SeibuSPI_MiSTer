# SlopperPI — Seibu SPI / SXX2E for MiSTer

Raiden Fighters on Seibu **SXX2E** single-board hardware (MAME set `rdfts`).

## Status

**The rendered frame is bit-exact against MAME** — every one of 76,800 pixels,
on two independent captures with different register state. Sound plays on real
hardware. See `PLAN.md` for the full design notes and the task list.

| block | state |
|---|---|
| ROM loading (hardware byte scatter) | verified byte-exact against MAME's regions |
| MRA part list | verified against MAME's driver and the RTL table (`make check-mra`) |
| GFX decryption (tiles, chars, SEI252 sprites) | verified against MAME, done at fetch time |
| 386 (z386) + memory map + IRQ | running |
| Video DMA | verified exact against MAME's video RAMs |
| Tile layers (back / midl / fore / text) | verified against MAME |
| Sprites | verified against MAME, no starvation under load (SEI252 and RISE10) |
| Mixer, including the exact 127/129 alpha blend | **bit-exact against MAME** |
| Z80 + banked ROM + command FIFO + coin latch | running on hardware |
| YMF271 registers, timers, IRQ | verified in simulation, running on hardware |
| YMF271 PCM synthesis (12 voices) | verified in simulation, music plays on hardware |
| YMF271 FM (4-op, 2x2-op, 3-op, all 16 algorithms, feedback) | verified in simulation |
| YMF271 LFO (pitch and amplitude) | verified in simulation |

Known gaps, all in the sound chip and none of them silent-failure risks: the
wave-memory read port, PCM interpolation, and a handful of register fields
nothing writes. `PLAN.md` section 14.5 lists them in order of how likely they
are to be heard.

## Installing

1. Build `SeibuSPI.rbf` (see below) and put it in `/media/fat/_Arcade/cores/`.
2. Put the MRA you want from `mra/` in `/media/fat/_Arcade/`.
3. Put its zip in `/media/fat/games/mame/`.

| MRA | set | zip | download | state |
|---|---|---|---|---|
| `rdfts.mra` | `rdfts`, SXX2E single board | `rdfts.zip` or `rdft.zip` | 22.3 MB | runs on hardware |
| `rdft.mra`  | `rdft`, SPI cartridge, pre-flashed | `rdft.zip` | 22.2 MB | runs on hardware |
| `rdft2.mra` | `rdft2`, SPI cartridge, pre-flashed | `rdft2.zip` | 34.1 MB | verified in simulation, never run on hardware |

The two cartridge MRAs ship the YMF271 sample flash pre-programmed, so the
several-minute "techno music" reflash the real cartridge does on first boot is
skipped. rdft's image is assembled by the MRA; rdft2's cannot be, because half a
megabyte of it is compressed — the core decompresses that during the download
(`rtl/spi_rom_decode.sv`).

**rdft2 has never been run on hardware.** What is verified, all in simulation:
its frame is pixel-identical to MAME on ten captured scenes, and its 386 boots,
reads its Z80 program out of the `sound01` window and downloads all 128 KB of
it into the Z80's memory byte-exactly (`make -C sim run-boot GAME=rdft2`). That
window is the one thing rdft does not need — rdft keeps its copy of the program
in `maincpu`, already loaded — and it was what stood between rdft2 and booting
at all. Whether the game then plays is a hardware question: the Z80 is a stub
under Verilator, so nothing past the handover can be simulated.

SDRAM: **32 MB is enough for rdfts and rdft** (both reach 29 MB in the map).
**rdft2 needs 64 MB** — its sprites are 18 MB rather than 12, which puts the top
of the image at 35 MB.

## Building

    make            # full Quartus compile -> output_files/SeibuSPI.rbf
                    # NOTE: "successful" does not mean timing met. Always
                    # follow with `make timing` -- Quartus writes the RBF
                    # either way. As of 2026-08-10 every clock is positive
                    # (clk_ram +0.927, TNS 0.000).
    make map        # analysis and synthesis only, much faster
    make timing     # name the worst timing paths after a fit
    make lint       # Verilator lint
    make test       # Verilator unit tests
    make check-mra  # MRA vs MAME's driver vs the RTL loader table
    make verify     # all three of the above

A compile that reports "successful" has not necessarily met timing — check the
Setup Summary in `output_files/SeibuSPI.sta.rpt`, or run `make timing`, which
prints the endpoints the summary leaves out.

`clk_ram` is the clock that fails, and at 87% RAM blocks several of its paths sit
within a tenth of a nanosecond of each other — so **the failing endpoint moves
between fits**, and a change that only shuffles the placement can make things
worse. Judge a fix by whether it took real logic out of a clk_ram path, not by
whether the next fit happened to close. Three did the work here: `rom_loader`'s
part table, its destination adder, and `sdram.sv`'s refresh compare, all
registered (`PLAN.md` 10a(2)). Reseeding via `SEED` in `SeibuSPI.qsf` — then
`make fit && make sta && make asm`, which skips synthesis — is the last resort.
Do not "optimise" `dq_reg` to chase these, which corrupts SDRAM reads
(`PLAN.md` section 10).

Quartus 17.0 is expected at `~/intelFPGA_lite/17.0/quartus`; override with
`QUARTUS_DIR=`.

## Testing against MAME

The video pipeline is verified by capturing real state out of MAME and
replaying it through the RTL. See `PLAN.md` section 12 — it documents several
traps that cost real time, including that the capture must take the bitmap one
frame after the video RAM snapshot.

    make -C sim capture ROMS=~/Downloads   # grab a frame, build the SDRAM image
    make -C sim run-video                  # render it and diff against MAME
    make -C sim run-dma                    # DMA output vs MAME's video RAMs

There is also a whole-board run, which needs no capture — just an SDRAM image:

    make -C sim run-boot GAME=rdft2 SDRAM=/tmp/sdram_rdft2.bin STEPS=400000000

It boots the real 386 against that image and reports how far it gets: ROM
fetches, every I/O register written, the DMA triggers. On the cartridge sets it
finishes by checking the Z80 program the 386 downloaded against the ROM it came
from, which is the only test of `spi_cpu.sv`'s `sound01` window. Do not judge
these runs by the picture — the Verilator Z80 is a stub, so a cartridge run
ends on a black screen with the 386 waiting on a sound FIFO that never answers.

Both currently pass exactly: 0 of 76,800 pixels differ. `FRAME=` picks the
scene — 600 is the early attract screen, 2400 the title with the jungle
background and heavy sprite traffic. Capture more than one; a quiet scene hid
two sprite bugs and a tile-layer offset for weeks.

Underneath, `tools/mame_capture.lua` takes the registers, video RAMs and bitmap,
and `tools/build_sdram_image.py` assembles the SDRAM image from a ROM set by
CRC32 (matching by name fails on merged sets).

The sound chip is checked differently, because there is no equivalent capture.
`make -C sim run-ymf271` drives the YMF271's register interface the way a sound
driver would and predicts the exact output from MAME's own formulas: PCM
playback has to reproduce the sample ROM verbatim, an FM carrier has to
reproduce a sine recomputed from `sin()`, and a 4-operator chain with feedback
has to match sample for sample from the note's first sample onwards.
`make -C sim run-ymf271-math` checks the phase step against MAME's
floating-point arithmetic over every possible register combination. Nothing
above the sound chip is simulated at all — the Z80 core is VHDL.

## Controls

| joystick bit | function | default |
|---|---|---|
| 4 | Shot | A |
| 5 | Bomb | B |
| 6 | Button 3 | X |
| 7 | Start | Start |
| 8 | Coin | Select |
| 9 | Service Coin | R |
| 10 | Test (held, not latched) | L |

Keyboard: `1`/`2` start, `5`/`6` coin, `9` service coin, `F2` test.

## Debugging aids

Two independent OSD options, both off by default:

- **Freeze Button (Btn 3)** — Button 3 toggles a CPU freeze. The video engines
  keep running, so the frame stays on screen and can be studied or captured at
  leisure. This is the one to use for a rendering fault.
- **Vital Signs Panel** — replaces the picture with a telemetry screen. It
  *replaces* it, so do not expect to see the game with this on.

They used to be the same option, which made the freeze useless for looking at
the picture: enabling the button also hid the frame behind the panel.

Flip Screen (SW1:1) and Service Mode are on the OSD's DIP page. The bit order
above is defined by the `<buttons names=...>` list in `mra/rdfts.mra`; the MRA
and `SeibuSPI.sv` have to be changed together.

## Credits

- z386 CPU core by nand2mario (branch `z386x`), vendored under `rtl/z386`.
- SDRAM controller by Sorgelig, via Arcade-IGSPGM_MiSTer.
- MiSTer framework by Sorgelig and contributors.
- Hardware behaviour derived from MAME's `seibu/seibuspi*.cpp`
  (Ville Linde, hap, Nicola Salmoria and others).

GPL v3 — see the headers in individual files for their original licences.
