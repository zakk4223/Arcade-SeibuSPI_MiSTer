# SlopperPI — Seibu SPI / SXX2E for MiSTer

Raiden Fighters on Seibu **SXX2E** single-board hardware (MAME set `rdfts`).

## Status

Video is functional and cross-checked against MAME frame by frame. Sound plays
on real hardware. See `PLAN.md` for the full design notes and the task list.

| block | state |
|---|---|
| ROM loading (hardware byte scatter) | verified byte-exact against MAME's regions |
| GFX decryption (tiles, chars, SEI252 sprites) | verified against MAME, done at fetch time |
| 386 (z386) + memory map + IRQ | running |
| Video DMA | verified exact against MAME's video RAMs |
| Tile layers (back / midl / fore / text) | verified against MAME |
| Mixer | verified against MAME |
| Sprites | drawing, not yet fully validated |
| Z80 + banked ROM + command FIFO + coin latch | running on hardware |
| YMF271 registers, timers, IRQ | verified in simulation, running on hardware |
| YMF271 PCM synthesis (12 voices) | verified in simulation, music plays on hardware |
| YMF271 FM (4-op, 2x2-op, 3-op, all 16 algorithms, feedback) | verified in simulation |
| YMF271 LFO (pitch and amplitude) | verified in simulation |

## Installing

1. Build `SeibuSPI.rbf` (see below) and put it in `/media/fat/_Arcade/cores/`.
2. Put `mra/rdfts.mra` in `/media/fat/_Arcade/`.
3. Put `rdfts.zip` in `/media/fat/games/mame/`.

Needs an SDRAM module of **32 MB or more**; the ROM set occupies 22.5 MB.

## Building

    make            # full Quartus compile -> output_files/SeibuSPI.rbf
    make map        # analysis and synthesis only, much faster
    make timing     # name the worst timing paths after a fit
    make lint       # Verilator lint
    make test       # Verilator unit tests

A compile that reports "successful" has not necessarily met timing — check the
Setup Summary in `output_files/SeibuSPI.sta.rpt`, or run `make timing`, which
prints the endpoints the summary leaves out.

Quartus 17.0 is expected at `~/intelFPGA_lite/17.0/quartus`; override with
`QUARTUS_DIR=`.

## Testing against MAME

The video pipeline is verified by capturing real state out of MAME and
replaying it through the RTL. See `PLAN.md` section 12 — it documents several
traps that cost real time, including that the capture must take the bitmap one
frame after the video RAM snapshot.

    tools/mame_capture.lua       capture registers, video RAMs and a frame
    tools/build_sdram_image.py   build the SDRAM image from a ROM set, by CRC32
    make -C sim run-video        render a frame and diff it against MAME's

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
