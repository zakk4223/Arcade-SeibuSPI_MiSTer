# Where this is, and what to do next

Live state as of 2026-08-21. `PLAN.md` is the design record and stays
chronological; this file is the short answer to "what was I doing". Delete the
finished parts as they go.

## SAVE STATES, on branch `savestate-phase0` -- this is where the work is

Fourteen commits, none of them on `main`, nothing pushed. `PLAN.md` 38, 39 and
40 are the design record; the plan file is
`~/.claude/plans/what-would-be-involved-calm-stearns.md`.

It fits and it mostly works:

    setup +0.250   hold +0.116   TNS 0.000, SEED 3, md5 861db700 (on the board)
    -- and the tree has UNCOMMITTED changes on top of that; see 45.5/45.7
    blob in a 512 KB slot, EIGHTEEN sections (the raster is no longer one)

**IT RUNS ON HARDWARE, and the first thing that ran found a real bug.** rdft
boots and plays on the savestate bitstream; save and load were then visibly
disruptive to the low-latency scaler, because `spi_video_timing` gated its
counters with the savestate pause and sync went flat for 14 ms of an 18.5 ms
frame. Fixed the way PGM does it -- **the raster never stops now** -- and the
restore is byte-identical to the old code's on the determinism hash. PLAN.md 42.

The fit is current as of 43. 42 improved it (82 registers and 59 ALMs back,
and the thin `ascal` margin more than doubled). Worst paths are all `ascal`, the
framework's HDMI scaler, which nothing here runs on. **Do not re-roll the seed
for margin on it** -- seed 1 FAILS at -0.110 on clk_ram (41.1).

The 386 is never instrumented -- it is NMI'd into a six-instruction stub that
pushes its own registers onto the game's stack, which is main RAM and is in the
blob anyway (38). The board is paused at a chosen instant, one tick before the
raster raises vblank, which is what makes the interrupt state knowable rather
than something to carry (39.3).

**Proven in simulation, three sets:** a save is transparent (6 dwords of 65,536
differ at the same logical point, five of them the stub's own footprint on dead
stack, and it does not grow); a restore is exact in memory; the 386 resumes at
the saved CS:EIP; every one of 24,283 I/O reads matches.

**The sweep 39.8 asked for is done, and it found the bug** (`PLAN.md` 40). 86
save points, three sets, 250 k to 100 M cycles. Main RAM restores EXACT and the
386 resumes at the saved CS:EIP at every one; the DS2404's read sequence is
identical on all three sets; every register's value sequence is identical at 85
of the 86.

    set      DS2404 reads          per-register values     lockstep
    rdfts    identical 737/737     identical, all          167 k .. 399 k
    rdft2    identical 1006/1006   identical, all          284 k .. 399 k
    rfjet    identical  936/936    identical, 9 of 10      165 k .. 399 k

**"Do not save during boot" was NOT the explanation, and neither was the RTC.**
`pause` was low in S_ARM -- correct on a save, a leak on a load, where the board
ran up to a frame with the old state before the blob was written over the top.
One line. Prefix agreement at the bad points went 10 -> 201,431..211,773 and
16 -> 165,688. The cartridge sets' SXX2C Z80 download was never missing state:
rdft2 and rfjet boot-time saves now reach 399,472 and 264,590.

**Do not quote a raw prefix number.** It is dominated by the SKEW: a run in
perfect lockstep at a 40-instruction offset reads about 10 at offset zero. The
old 16 / 167,678 / 10 triple is that artefact and nothing else. Align first, then
report skew, lockstep, and PER-REGISTER value sequences -- a whole-stream diff
mistakes a one-poll phase shift for a wrong value, which it did once here.

**The three instruments that work**, and the one that does not:

    SS_TRAIL=<f>   every EIP after the operation; align two runs, the first
                   difference names the instruction. NEEDS SS_HASH_AFTER SET
                   as well -- the anchor that arms it is only assigned inside
                   the hash block.
    SS_IORD=<f>    every I/O read with its value; names the register
    SS_DSTRACE     every RTC tick during an operation, and every non-zero read
                   of the DS2404 data port WITH THE CYCLE. The cycle is the
                   part that matters: a value difference alone cannot say
                   whether the clock is wrong or the game arrived early.
    SS_HASH_AFTER  the determinism sweep -- DISTRUST IT. It read 4 of 12 at the
                   point the trail agreement had improved four orders of
                   magnitude. Never quote it without a trail number beside it.

The residual is a poll-loop phase offset -- tens of instructions on rdfts,
hundreds on the cartridge sets -- landing on 0x600 and 0x60C, both hardwired
constants. No read returns a wrong value anywhere.

The bench's `resumed at the saved EIP: NO` line is keyed on a short trail that is
usually empty and was a FALSE VERDICT throughout 39. Believe the
`restore : the CPU resumed at the saved CS:EIP` line beside it.

Still open, and the list is shorter than it was:

* **THE RAPID-RELOAD LOCKUP IS NOT FIXED. This is the top of the list, and
  `PLAN.md` 45 is the handoff -- read it before touching anything.**

  Rapid repeated LOADS wedge the board. Save in ATTRACT and 10+ reloads are
  clean; save in ACTIVE GAMEPLAY and it goes in about three. TWO modes: music
  still playing with no overlay (spi_ss IDLE, restore completed, the 386 is
  executing rubbish -- a corruption) and sound stopped with the overlay up
  (spi_ss stuck in S_ASK -- a deadlock).

  **What the on-screen overlay read, wedged:** `S_ASK, is_load=1, pause=1,
  snapshot=0, in_stub=0, io_stall=0, z80dl_stall=0, ds_stall=0`. NOTHING is
  stalled, which invalidated every theory before it. Screenshot and decode it
  with `tools/savestate-debug/read_wedge.sh` (or rebuild it -- 45.2).

  **Fixed and real but partial:** SS_NMI drops the NMI whether or not the 386
  took it, and SS_RUN then waits forever for a marker write that never comes,
  parking spi_cpu so every later operation hangs. SS_RUN re-offers the NMI now.
  Measured 3 -> ~10 reloads. Not sufficient.

  **In the tree UNCOMMITTED and UNVALIDATED** (45.5): `ss_idle` from spi_cpu, and
  spi_ss waiting for it in S_ARM/S_SETTLE, with the in-stub test moved into
  clk_cpu so it cannot race the crossing. Sound reasoning, untested on hardware,
  and it did NOT change the replay's outcome.

  **NEXT ACTION, before anything else:** `SS_LOAD_FILE=<x.ss>` replays a real
  savestate off the board (new, 45.6, and the biggest hole it closes is that
  NOTHING in simulation ever exercised a real in-game save). It reproduces what
  looks like mode A -- but **the harness itself is unvalidated. Replay an
  ATTRACT-mode save first, which the hardware restores fine. If that fails too,
  the harness is broken and its result means nothing.**

  On the board: `861db700`. The last CLEAN build is `c1d99fef` (233d7fc), kept as
  `/media/fat/_Arcade/cores/SeibuSPI.rbf.20260822-0022`.

  **`output_files/SeibuSPI.rbf` is STALE** -- it is a fit that predates the
  `ss_idle` change now committed, left behind when work stopped. Refit before
  deploying anything from it. Same trap 41 opened this whole run with.
* **The 86-point sweep has not been re-run since 42**, and it cannot be re-run
  naively: the save now ends ~191 k cycles later, so any restore offset tuned to
  the old timing silently becomes a back-to-back test. Move them out first. A
  bad offset produced a false `restore: FAILED` here and cost a round.
* The sound path's MAME correlation has still not been redone since T80 was
  swapped for tv80, and for a CPU swap that is the measurement that counts.
* **The OSD and pad path is still undriven on hardware** -- slot switching,
  autoincrement, and the OSD's own save/restore entries. Audio continuity across
  a load has not been listened to either.
* Quartus keeps re-adding files to `SeibuSPI.qsf`'s stale duplicate list --
  though it did NOT across the four compiles in 41 and 42, so this may be less
  frequent than it looked.

**If a fit fails or the register count jumps**, read
`output_files/SeibuSPI.map.rpt`'s per-entity table FIRST. Two write statements to
one array stops Quartus inferring memory and builds it out of flip-flops; it
happened twice here and once got written up as "the device is full" (39.7).

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
| the DS2404, and one save file for both devices | done; rdft boots and runs on hardware |

The last row is `PLAN.md` 30 and it needed no RTL: the collapse had already
moved the one per-clone constant, the sample-flash job table, into the MRA.
Six games, 49 sets, named after the games with the clones under
`mra/_alternatives/`. Only the original seven have been BOOTED -- the 42
variants are checked offline against MAME, against `rom_loader.sv`'s table and
against their parents' flash payloads, which covers everything a variant can
differ in and is still not a boot.

## The DS2404 is in, and the save file changed shape

`PLAN.md` 31. The board's RTC and its 512 bytes of bookkeeping SRAM were answering
zeros; `rtl/spi_ds2404.sv` is a transliteration of MAME's device, which is the
right specification because the interface is the SEI600's parallel view and not
1-Wire. It runs on **clk_ram**, not clk_cpu with the rest of the I/O, because its
SRAM is part of the save file and the save side of MiSTer's nvram cannot be
stalled; the 386 crosses instead, through one request toggle, and is held off by
`io_stall` while a byte is in flight.

**The save file is 516 bytes** (`PLAN.md` 32), one stream over two devices
because an MRA gets one `<nvram>` element:

    0x000..0x003   the sample flash's REGION STAMP, and nothing else of it
    0x004..0x203   the DS2404's SRAM

**512 for rdfts**, which has an `<nvram>` element for the first time -- its samples
are a ROM, so there is no stamp to keep and the tail sits at offset 0. The tail is
byte-for-byte MAME's own `ds2404` file.

It saved all 2 MB for one day and that was enough to find two things wrong with
it: the OSD felt unresponsive on every open, because Main reads the file back
whenever it polls; and the mode was a TRAP, because one OSD visit in Pre-built
saved a stamp that said "already programmed" and the cart copy could then never be
seen again. Both are gone. What persists now is the FACT of the copy, four bytes
of it, and the 2 MB payload is derived at every boot in either mode.

**Both modes derive.** What the option picks is whether the region stamp goes with
the payload: Pre-built writes it and the game plays at once, Cart copy leaves it
blank and the game spends six minutes programming a flash that is already correct.
**Switching INTO Cart copy blanks the stamp and restarts the board** -- boot is the
only moment the game looks -- so it is always reachable. Switching back does
nothing.

**A 2,097,664-byte save from the day before is not compatible**: its first four
bytes still read as the stamp, but the 512 after them are flash payload rather than
the DS2404. Delete any that exist; there were none on the machine.

`make -C sim run-ds2404` and `run-nvram` both pass.

**On hardware (2026-08-18): rdft boots and runs with all of it in the net.** The
RBF was deployed md5-verified, `Raiden Fighters (Germany).mra` loads (CORENAME
reads `rdft`), and the attract cycle progresses -- title over live gameplay, the
runway cutscene, the RF panel, four screenshots with four different md5s. Twice
over, from two separate `load_core`s, and the ROM download never wedged Main. So
`io_stall` does not hang the 386 and the derivation still fills the flash: the
game runs its attract rather than its six-minute updater.

**Service Mode reaches its own TEST MODE menu**, which lists EXIT, GAME SETTINGS,
**INCOME**, I/O TEST, MONITOR TEST, **ADJUST TIMER** and RESET SETTING. Those two
in caps are the DS2404's: INCOME is the audit page in its SRAM and ADJUST TIMER is
the counter at 0x202-0x206, which read a hardwired zero until now.

**It took three fits.** The first FAILED on the new crossing and nothing else:
`spi_io|ds_data -> spi_ds2404|address` at -0.605 setup and -0.320 HOLD into the
scratchpad's write data, because the payload was used combinationally on the
receiving side. It is one flop deep now -- ONE, and `PLAN.md` 31.7 argues the
count, because two would carry the uncertain sample into the cycle the action
uses. The second fit then failed at -0.198 on the SAME endpoint with the crossing
gone: the decode and a 16-bit subtract in series inside one clk_ram period. Arming
a command takes its own cycle now, and the 386 cannot tell.

Both of the first two versions simulate identically -- the bench waits for the
ack, as the 386 does -- so nothing but a fit was ever going to find either.

    clk_ram  +0.187   clk_cpu  +1.647   clk_sys  +2.169   pll_hdmi +0.614
    hold     +0.161   TNS 0.000 everywhere, 0 critical warnings   SEED 3

**SEED 3, and the seed matters more than 29.3 thought.** Five of them on one
unchanged tree and only TWO PASS (`PLAN.md` 34): seed 1 +0.101, seed 3 +0.187, and
2, 5 and 6 all failing -- two of those on HOLD, which is the half no downclocking
fixes. Every failing seed also threw exactly one critical warning and every passing
one threw none, which is the cheapest tell to check first. And every one of them
wrote an RBF regardless, so `make timing` is not optional.

A fit IS deterministic though: recompiling seed 3 reproduced it to the byte, same
slacks and an identical RBF md5. So the seed is a property of the design rather
than a ticket to re-draw.

## The release blocker, and what moved it

**The instrumentation is out of the net** (`PLAN.md` 29), and three of the four
modules are out of the TREE as well (`PLAN.md` 35): `spi_debug`, `spi_jtag_peek`
and `spi_sdr_stats` are deleted, recoverable from git at `02fcac4~1`.
`spi_romcheck` survives because `run-romcheck` still uses it. None is instantiated,
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
  instances, and the module they talked to is deleted now (`PLAN.md` 35) rather
  than merely unwired. Putting one back starts with
  `git show 02fcac4:rtl/spi_jtag_peek.sv`, then re-instantiating it, wiring
  whichever watch it is to read, and adding the file to `files.qip` -- and
  expecting the timing to move when you do.
* **`DEFMRA` is `Raiden Fighters (Germany).mra` now**, since the naming rule put
  rdfts under `_alternatives`. It only matters for launching the RBF directly
  rather than through an MRA, and it IS in the current bitstream -- the DS2404
  work rebuilt it. 29.3's seed-1 placement is no longer what is on disk; 31.8's
  is, and it is a better fit.
* **The DS2404 is VERIFIED on hardware**, and against MAME, which the Cart copy
  run did for free (`PLAN.md` 32.7). The 516-byte save file's 512-byte tail is
  `~/.mame/nvram/rdft/ds2404` in 505 of 512 bytes -- the game ID `00 4A 4A 36`,
  the `67 45 23 01` / `EF CD AB 89` test patterns, the 1,000,000 counter, 189
  non-zero bytes of bookkeeping the game wrote through the port sequence. The
  seven that differ sit on a six-byte stride and are consistent with RTC-derived
  fields, which start at zero here and from the host clock in MAME.
  Nothing left to do on it. What would still be nice: Service Mode -> INCOME with
  a coin inserted, to see a counter move on screen rather than in a file.
* **The Cart copy TOGGLE is the one thing left.** The mode itself ran on hardware
  end to end (`PLAN.md` 32.7): four minutes of "NOW UPDATING" with the counter
  moving 895 -> 424 -> 000, then "UPDATE COMPLETED". All three states are on
  hardware now: Pre-built plays at once, Cart copy with a blank stamp copies, and
  Cart copy with the valid `80 4A 4A 36` the game wrote **skips the copy and
  plays** -- which is what the four-byte save exists for.

  What has only ever run in simulation is the 0 -> 1 EDGE: blanking the stamp and
  the 1.1 ms self-reset. Select Cart copy in the OSD while the game is running and
  the board should restart itself within a second and come up copying. There is no
  way to do that from here -- there is no OSD command, and the `.CFG` route only
  sets the value at boot.

  The save on the machine is currently `80 4A 4A 36` + the DS2404, so that toggle
  test is set up: it has something valid to blank.
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

**`make check-tb` exists now**, and it earned its keep the same day: adding the
DS2404's SRAM port to `spi_top` stopped `tb_boot_top` building, exactly as the
three before it. It is part of `make verify`.

## Commands

    make verify                                  # lint + check-mra + check-tb + test
    make check-tb                                # BUILD every bench, run none
    make mras                                    # regenerate the 42 clone MRAs
    make mras MRAFLAGS=--list                    # what is supported, and why not the rest
    make check-clones ROMS=<romdir>              # re-derive every job table from the ROMs
    make -C sim run-ds2404                       # the DS2404 against MAME's own device
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

Save files were renamed with the MRAs twice over -- first with the collapse
(`rdft-update.nvm` -> `rdft.nvm`), then with the descriptive names -- and have now
changed SHAPE as well: 2,097,664 bytes, the flash then the DS2404's 512. Pre-built
uses only the tail of it, but it does now use one.
