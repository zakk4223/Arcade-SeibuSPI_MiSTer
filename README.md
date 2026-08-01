# SlopperPI — Seibu SPI / SXX2E for MiSTer

Raiden Fighters on Seibu **SXX2E** single-board hardware (MAME set `rdfts`).

## Status

Video is functional and cross-checked against MAME frame by frame. Sound is not
implemented. See `PLAN.md` for the full design notes and the task list.

| block | state |
|---|---|
| ROM loading (hardware byte scatter) | verified byte-exact against MAME's regions |
| GFX decryption (tiles, chars, SEI252 sprites) | verified against MAME, done at fetch time |
| 386 (z386) + memory map + IRQ | running |
| Video DMA | verified exact against MAME's video RAMs |
| Tile layers (back / midl / fore / text) | verified against MAME |
| Mixer | verified against MAME |
| Sprites | drawing, not yet fully validated |
| Z80 + YMF271 sound | **not implemented — the core is silent** |

## Installing

1. Build `SeibuSPI.rbf` (see below) and put it in `/media/fat/_Arcade/cores/`.
2. Put `mra/rdfts.mra` in `/media/fat/_Arcade/`.
3. Put `rdfts.zip` in `/media/fat/games/mame/`.

Needs an SDRAM module of **32 MB or more**; the ROM set occupies 22.5 MB.

## Building

    make            # full Quartus compile -> output_files/SeibuSPI.rbf
    make map        # analysis and synthesis only, much faster
    make lint       # Verilator lint
    make test       # Verilator unit tests

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

## Credits

- z386 CPU core by nand2mario (branch `z386x`), vendored under `rtl/z386`.
- SDRAM controller by Sorgelig, via Arcade-IGSPGM_MiSTer.
- MiSTer framework by Sorgelig and contributors.
- Hardware behaviour derived from MAME's `seibu/seibuspi*.cpp`
  (Ville Linde, hap, Nicola Salmoria and others).

GPL v3 — see the headers in individual files for their original licences.
