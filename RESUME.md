# Where this is, and what to do next

Live state as of 2026-08-18. `PLAN.md` is the design record and stays
chronological; this file is the short answer to "what was I doing". Delete the
finished parts as they go.

## The goal that is nearly done

One MRA per set, with the cartridge's sample flash either **built by the core in
0.3 s** or **programmed by the game in six minutes**, chosen on the OSD. That
replaced two MRAs per set for three of the seven sets, and no pre-flashed MRA at
all for the other four.

All of it is committed and green. `PLAN.md` 20, 22, 23, 24, 25, 26, 30.

| step | state |
|---|---|
| per-set `pcmsrc` base, so the surviving MRA shape fits 32 MB | done, on hardware |
| `spi_snd_window` extracted + swept over every dword | done |
| derivation provable from an SDRAM image alone, 7 sets | done, `make check-derive` |
| the RTL walker, 7 sets to their reference hashes | done, `make -C sim run-flash-derive` |
| integrated behind the OSD option | done, derivation verified on hardware |
| MRAs collapsed to seven, Pre-built default | done |
| every clone and regional variant, 49 MRAs | done, `make mras` + `make check-clones` |

The last row is `PLAN.md` 30 and it needed no RTL: the collapse had already
moved the one per-clone constant, the sample-flash job table, into the MRA.
Six games, 49 sets, named after the games with the clones under
`mra/_alternatives/`. Only the original seven have been BOOTED -- the 42
variants are checked offline against MAME, against `rom_loader.sv`'s table and
against their parents' flash payloads, which covers everything a variant can
differ in and is still not a boot.

## The release blocker, and what moved it

**The instrumentation is out of the net** (`PLAN.md` 29). `spi_debug`,
`spi_jtag_peek`, `spi_romcheck` and `spi_sdr_stats` are no longer instantiated,
and every per-module watch that fed them is disconnected at its instantiation.
The modules are all still in `rtl/`; nothing of theirs reaches the fabric.

    registers  37,912 -> 32,273        ALMs  86% -> 81%      LABs  99% -> 97%

**That closed the endpoint 26.4 and 28.3 were chasing.** Nineteen percent of
the registers in this design were there to watch it, and the fitter had been
placing it into 99% of the LABs. The convergence point was routing-limited
because of THAT, which is why flattening the cascade (28.3) and the seed sweep
both failed: both were rewriting logic to fix a placement problem.

**TIMING MEETS, with margin, at SEED 1.** Everything positive, TNS 0.000 on
every clock, 0 critical warnings, and the RBF in `output_files/` is that
placement (`make asm` after a refit -- a refit alone does not write it):

    setup worst  +0.254   sdram|ch2_rq -> sdram|command[1]
    clk_ram      +0.254   clk_cpu  +2.026   clk_sys  +2.275   pll_hdmi +0.394
    hold worst   +0.182

The endpoint 19.16 first flagged and 26.4/28.3 chased is the worst path still,
but at +0.254 rather than -0.019.

DO NOT re-apply 28.3's flattening on this basis. It was measured WORSE on its
own terms (-0.020 -> -0.522) and the note in `sdram.sv` stands.

**The seed still matters, and there are two marginal paths, not one.** Three
fits of this same tree:

    seed 12   clk_ram +0.466   ascal -0.261 / TNS -3.101     fails
    seed  4   clk_ram -0.003   ascal +0.433                  fails
    seed  1   clk_ram +0.254   ascal +0.394                  PASSES

`ascal` is `sys/ascal.vhd`, the framework's scaler on the HDMI clock, which
nothing here is on; 18.x already recorded it at -0.215 and closed it with a seed
change. So the design is no longer balanced on a knife edge the way 28.5
described -- but a fit is still worth CHECKING rather than assuming.

## Also open

* **The OSD toggle itself is unverified.** `/dev/MiSTer_cmd` has no menu
  command, and Main's `.CFG` is not the raw status word (writing byte 2 bit 6 of
  a 16-byte file did nothing). Everything downstream of `derive_sel` was proved
  by forcing it high in a throwaway build. To confirm: load `Raiden Fighters
  (Germany).mra`, switch **Sample Flash** to Ritual, reload, and check it runs
  the updater; the default (Pre-built) already demonstrably works.
* **One unexplained observation.** On the +0.163 collapse build, rdft's MRA on
  defaults ran the ritual once. The telemetry build then showed the derivation
  completing correctly on the same MRA, and the flash matching the reference.
  Load a passing build several times before believing it was a one-off --
  intermittent would be worse than broken.
* **Only rdft's derivation is verified on hardware.** The other five pass in
  simulation against real images -- and the one-line JTAG report that used to
  say so on the board (`jtag_peek.tcl derive`) is gone with the probes, so
  confirming another set now means watching it boot.
* **The ROM checker no longer runs at boot.** `spi_romcheck` was the thing
  that said "the download landed", and it is out of the net with the rest.
  `make -C sim run-romcheck SDRAM=<image>` is the offline version and still
  works. Its guard note (21.5) is moot until something instantiates it again.
* **The JTAG tools have nothing to talk to.** `tools/jtag_peek.tcl`,
  `jtag_server.tcl` and `jtag_diag.sh` are all still there, and all now find no
  instances. Putting one back means re-instantiating `spi_jtag_peek`, wiring
  whichever watch it is to read, and adding the file to `files.qip` -- and
  expecting the timing to move when you do.
* **`DEFMRA` points at a file the RBF in `output_files/` has never heard of.**
  The rename put rdfts under `_alternatives`, so `SeibuSPI.sv` now says
  `DEFMRA,/_Arcade/Raiden Fighters (Germany).mra`. It is a CONF_STR string and
  inert until the next compile; it only matters for launching the RBF directly
  rather than through an MRA. The committed bitstream is still 29.3's seed-1
  placement, and this is the one edit waiting on the next fit.
* **A variant has never been booted.** Any of the 42 would do as a first check,
  and `Raiden Fighters (Japan, earlier)` is the cheapest -- it shares rdft's job
  table address, so only the region lock and the file names are new.
* **`tb_sdram` is rdfts-only** by design (`set_id` hardcoded to 0). Fine for
  what it tests; do not waste a run feeding it another set's stream, as I did.

## Three testbenches were dead, and the fourth may be

`tb_ymf_top`, `tb_boot_top` and `tb_sdram_top` had all stopped BUILDING -- ports
their modules grew, plus `set_id` widening from 2 bits to 3. Each failure was
silent: nothing runs them, and a testbench that fails to build looks like one
that is merely slow. All three are fixed (PLAN.md 21.6, 22.3, 28).

`make lint` does not reach `SeibuSPI.sv` at all -- it lints `spi_top`, because
the top needs hps_io and the PLLs. `make -C sim lint-top` does reach it, for the
four checks that survive the framework modules being absent, and it no longer
swallows `%Error` lines the way it used to. **For anything in the top-level
file, `make map` is still the first real check.**

Worth doing: a `make check-tb` that merely BUILDS every testbench, so this class
of rot fails loudly the next time a port moves.

## Commands

    make verify                                  # lint + check-mra + test (49 MRAs)
    make mras                                    # regenerate the 42 clone MRAs
    make mras MRAFLAGS=--list                    # what is supported, and why not the rest
    make check-clones ROMS=<romdir>              # re-derive every job table from the ROMs
    make map                                     # the real check for SeibuSPI.sv
    make && make timing                          # a compile does NOT mean timing met

    make check-derive ROMS=<romdir>              # flash derived from an image, 7 sets
    make check-snd01  ROMS=<romdir>              # the 386's sound01 window
    make -C sim run-flash-derive SDRAM=<x-upd.bin> SET=<x>
    make -C sim run-sdram SDRAM=<ref.bin> CONCAT=<stream.bin>   # rdfts only

    # The jtag_peek.tcl commands need spi_jtag_peek back in the net; see above.

Building the inputs:

    python3 tools/build_sdram_image.py <set>.zip out.bin --upd --set <set>
    python3 tools/build_sdram_image.py <set>.zip out.bin --concat

## Hardware

The MiSTer at 192.168.1.125 is on a **diagnostic build** (timing-failing).
Reflash something known-good before using it: `/media/fat/_Arcade/cores/` has
dated `SeibuSPI.rbf.*` backups.

Save files were renamed with the MRAs (`rdft-update.nvm` -> `rdft.nvm`). They are
unused on the default path, since Pre-built neither loads nor saves.
