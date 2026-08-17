# Where this is, and what to do next

Live state as of 2026-08-17. `PLAN.md` is the design record and stays
chronological; this file is the short answer to "what was I doing". Delete the
finished parts as they go.

## The goal that is nearly done

One MRA per set, with the cartridge's sample flash either **built by the core in
0.3 s** or **programmed by the game in six minutes**, chosen on the OSD. That
replaced two MRAs per set for three of the seven sets, and no pre-flashed MRA at
all for the other four.

Five of six steps are committed and green. `PLAN.md` 20, 22, 23, 24, 25, 26.

| step | state |
|---|---|
| per-set `pcmsrc` base, so the surviving MRA shape fits 32 MB | done, on hardware |
| `spi_snd_window` extracted + swept over every dword | done |
| derivation provable from an SDRAM image alone, 7 sets | done, `make check-derive` |
| the RTL walker, 7 sets to their reference hashes | done, `make -C sim run-flash-derive` |
| integrated behind the OSD option | done, derivation verified on hardware |
| MRAs collapsed to seven, Pre-built default | done |

## THE ONE THING BLOCKING A RELEASE

**No fit meets timing.** The best is **-0.019 ns, TNS -0.019** -- ONE endpoint,
19 picoseconds, `sdram|state.STATE_RW1 -> sdram|command[1]`. That is the tree as
committed (arbitration hoist reverted, esi compare registered), and **none of the
derivation, its telemetry or the config registers appear in the worst 25**. The
failing endpoint is sdram.sv's own, every time, though which signal reaches
`command[1]` moves between fits (`ch1_rq`, `ch4_rq`, `ch5_rq`, `state.STATE_RW1`).

Read `PLAN.md` 26.4 and 28.3 before touching this. The short version:

* The endpoint is **pre-existing**. 19.16 recorded the then-shipping build at
  **+0.018 ns** on its sibling path. The design has been balanced on this
  endpoint the whole time and a fit passing it is close to a coin flip.
* It is **routing dominated, not logic dominated**. Flattening the priority
  cascade into a five-input OR was tried, was correct (the round-trip test
  passed), and made it WORSE -- -0.020 to -0.522 -- because it forces five
  signals that live near their own channel logic to converge at one gate in one
  level. That is recorded in `sdram.sv` as tried-and-rejected. Do not repeat it.
* A seed sweep was tried: 12 -> -0.256, 13 -> -0.061, 14 -> -0.239,
  15 -> -0.099. Seeds move it without resolving it. Do not repeat that either.
  (Those were measured with the 136-bit DRIV probe, before it was trimmed to 72;
  a sweep on the current tree might land differently, but 19 ps of margin is not
  worth six fits to chase and it would not be a fix.)

What has NOT been tried, in the order I would try it:

1. **Give the rq flags a registered gather per side of the die.** The problem is
   five sources converging; two levels of registered OR placed near their
   sources would cost one cycle of arbitration latency. Check sprite starvation
   after (PLAN.md's rfjet margin is 1-2 lines a frame, so this is not free).
2. **Register `command` closer to the pins**, or duplicate it per side, so the
   long routes end at a flop rather than at the shared encoder.
3. **Constrain the SDRAM interface.** 19.16 notes it is unconstrained, "exactly
   as it is in the Irem and IGS cores, so nothing checks it either way". Some of
   this may be the analyser being pessimistic about paths nobody has told it
   about.

The safety net for all of it now exists and passes -- see below.

## Also open

* **The OSD toggle itself is unverified.** `/dev/MiSTer_cmd` has no menu
  command, and Main's `.CFG` is not the raw status word (writing byte 2 bit 6 of
  a 16-byte file did nothing). Everything downstream of `derive_sel` was proved
  by forcing it high in a throwaway build. To confirm: load `rdft.mra`, switch
  **Sample Flash** to Ritual, reload, and check it runs the updater; the default
  (Pre-built) already demonstrably works.
* **One unexplained observation.** On the +0.163 collapse build, `rdft.mra` on
  defaults ran the ritual once. The telemetry build then showed the derivation
  completing correctly on the same MRA, and the flash matching the reference.
  Load a passing build several times before believing it was a one-off --
  intermittent would be worse than broken.
* **Only rdft's derivation is verified on hardware.** The other five pass in
  simulation against real images. `quartus_stp -t tools/jtag_peek.tcl derive`
  reports jobs, bytes, state and the error flags in one line.
* **`spi_romcheck` walks once**, and `check passes` is always 1. Its header
  explains why the guard must stay until the checker has a real slot in
  `spi_sdr_arb4`. PLAN.md 21.5.
* **`tb_sdram` is rdfts-only** by design (`set_id` hardcoded to 0). Fine for
  what it tests; do not waste a run feeding it another set's stream, as I did.

## Three testbenches were dead, and the fourth may be

`tb_ymf_top`, `tb_boot_top` and `tb_sdram_top` had all stopped BUILDING -- ports
their modules grew, plus `set_id` widening from 2 bits to 3. Each failure was
silent: nothing runs them, and a testbench that fails to build looks like one
that is merely slow. All three are fixed (PLAN.md 21.6, 22.3, 28).

`make lint` does not reach `SeibuSPI.sv` at all -- it lints `spi_top`, because
the top needs hps_io and the PLLs. **For anything in the top-level file,
`make map` is the first real check, not `make lint`.**

Worth doing: a `make check-tb` that merely BUILDS every testbench, so this class
of rot fails loudly the next time a port moves.

## Commands

    make verify                                  # lint + check-mra + test
    make map                                     # the real check for SeibuSPI.sv
    make && make timing                          # a compile does NOT mean timing met

    make check-derive ROMS=<romdir>              # flash derived from an image, 7 sets
    make check-snd01  ROMS=<romdir>              # the 386's sound01 window
    make -C sim run-flash-derive SDRAM=<x-upd.bin> SET=<x>
    make -C sim run-sdram SDRAM=<ref.bin> CONCAT=<stream.bin>   # rdfts only

    quartus_stp -t tools/jtag_peek.tcl derive    # the derivation, on hardware
    quartus_stp -t tools/jtag_peek.tcl sums      # NOTE: 21.7, ok bits is broken

Building the inputs:

    python3 tools/build_sdram_image.py <set>.zip out.bin --upd --set <set>
    python3 tools/build_sdram_image.py <set>.zip out.bin --concat

## Hardware

The MiSTer at 192.168.1.125 is on a **diagnostic build** (timing-failing).
Reflash something known-good before using it: `/media/fat/_Arcade/cores/` has
dated `SeibuSPI.rbf.*` backups.

Save files were renamed with the MRAs (`rdft-update.nvm` -> `rdft.nvm`). They are
unused on the default path, since Pre-built neither loads nor saves.
