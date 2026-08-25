# SeibuSPI — Seibu SPI / SXX2E for MiSTer

Six Seibu games on the **SPI cartridge** board — `rdft`, `rdft2`, `rfjet`,
`viprp1`, `senkyu` and `ejanhs` — and on the **SXX2E** single board they share
almost everything with (MAME set `rdfts`). **49 MRAs**: one per MAME set,
counting every clone and regional variant. The cartridge's first-boot sample
reflash is a third of a second, built by the core.

## Status

**The rendered frame is bit-exact against MAME** — every one of 76,800 pixels,
on two independent captures with different register state, plus ten rdft2
scenes and eleven rfjet ones. **All seven sets boot and run on real hardware**,
and **the sound path is matched against MAME in simulation on three sets** —
`rdfts`, `rdft` and `rdft2` — where the sound CPU writes the YMF271 the same
values in the same order MAME's does, on every register that carries a note, for
as long as the attract sequence stays in step (48 s on `rdft`). Long-term
spectrum r is 0.9996 or better on all three. `PLAN.md` 51. The hardware
ROM checker verifies all four regions on the board (`ok bits 1111` on rdfts;
its expected sums are still rdfts-only, so other sets are checked by comparing
the sums it reports against the reference image instead). See `PLAN.md` for the
full design notes and the task list.

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
| Sound output as a whole | **matched against MAME on hardware** (`rdft2`, `rfjet`) and, since the tv80 swap, **in simulation** — same YMF271 register writes, spectrum r ≥ 0.9996 (`make -C sim run-sound`) |

Known gaps, all in the sound chip and none of them silent-failure risks: PCM
interpolation and a handful of register fields nothing writes. `PLAN.md`
section 14.5 lists them in order of how likely they are to be heard, and says
for each one why it is deliberate rather than pending.

**The cartridge sets are stereo and the single board is mono, the way MAME has
them.** MAME routes YMF output 0 to the left speaker and 1 to the right for
`rdft`/`rdft2`, while SXX2E sums everything to one speaker. This used to be a
recorded divergence — the core summed the cartridge sets to mono, at −73.7 dB
side/mid against MAME's −14.5 — and it was fixed in `PLAN.md` T-K. Measured
again on the same passage rather than against a whole reference, the core reads
**−16.8 dB against MAME's −16.8** on `rdft`, with left and right within 0.5% of
MAME's levels. That also retires the 4.1 dB gap `PLAN.md` 51.8 inherited as
undiagnosed: it was two different passages being compared, not a narrower mix.

## Installing

`make release` assembles everything into `releases/`, in the layout MiSTer's
distribution system expects — parent MRAs and the RBF at the top, clones under
`_alternatives/_<parent>/`:

    releases/
      SeibuSPI.rbf
      Raiden Fighters (Germany).mra          ...and the five other parents
      _alternatives/_Raiden Fighters (Germany)/Raiden Fighters (Japan, earlier).mra
      ...43 clones in all

**`releases/` is checked in**, deliberately: MiSTer's distribution system reads the
parent MRAs, `_alternatives/` and the RBF out of the repo to copy into the master
distribution. So it is a deliverable, not a build product — after `make release`,
**commit what it changed**. `mra/` remains the source the MRAs are generated and
maintained in.

The target rebuilds `releases/` from scratch each time, so a renamed or
reclassified MRA cannot linger, and it refuses to run unless the last fit met
timing — `make build` writes an RBF whatever the analyser says (`PLAN.md` 34), and a
distribution the world pulls from is the last place that should reach.

By hand, or onto a machine already set up:

1. `SeibuSPI.rbf` goes in `/media/fat/_Arcade/cores/`.
2. The MRA you want goes in `/media/fat/_Arcade/`, keeping `_alternatives/` if you
   want the clones.
3. Its zip goes in `/media/fat/games/mame/`.

**49 MRAs, six games.** `mra/` holds one file per MAME PARENT set, named the way
MiSTer names them -- the game's descriptive name, not the set name -- and every
clone and regional variant sits under `mra/_alternatives/_<parent>/`. Copy
`_alternatives` across with the rest if you want them; MiSTer reads it in place.

| MRA in `mra/` | set | zip | download | SDRAM | variants |
|---|---|---|---|---|---|
| `Raiden Fighters (Germany).mra` | `rdft`, SPI cartridge | `rdft.zip` | 24.7 MB | 32 MB | 11 |
| `Raiden Fighters 2 - Operation Hell Dive (Germany).mra` | `rdft2`, SPI cartridge | `rdft2.zip` | 36.7 MB | 64 MB | 10 |
| `Raiden Fighters Jet (Germany).mra` | `rfjet`, SPI cartridge | `rfjet.zip` | 39.7 MB | 64 MB | 4 |
| `Viper Phase 1 (New Version, World).mra` | `viprp1`, SPI cartridge | `viprp1.zip` | 21.7 MB | 32 MB | 11 |
| `Senkyu (Japan, newer).mra` | `senkyu`, SPI cartridge | `senkyu.zip` | 20.7 MB | 32 MB | 7 |
| `E Jong High School (Japan).mra` | `ejanhs`, SPI cartridge | `ejanhs.zip` | 21.5 MB | 32 MB | 0 |

The `rdft` variants include `rdfts`, the SXX2E **single board** -- 22.3 MB out of
`rdfts.zip` or `rdft.zip`, and a clone of `rdft` in MAME, so it lives under
`_alternatives` with the rest: `Raiden Fighters (Taiwan, single board).mra`.

A merged MAME set works for every one of them: MRA parts resolve by CRC first,
so a clone's ROMs are found in the parent's zip whatever they are named there.

Six sets are on hardware this core does not implement -- the SUB2/SUB4 `rdft`
carts, the SXX2F/SXX2G single boards, and the two SYS386I sets. Each is listed
with the reason in `tools/gen_mras.py`; `make mras MRAFLAGS=--list` prints them.

`ejanhs` plays video and sound but **cannot be played**: it reads a mahjong
panel through MAME's `ejanhs_encode` and this core wires the standard SPI
joystick ports.

The clone MRAs are generated, not maintained -- each is its parent's part list
with its own file names, its own region lock and its own sample-flash job-table
address. `make mras` rewrites them from MAME's driver, and refuses to if it can
no longer reproduce the six hand-written parents exactly. `make check-clones
ROMS=<dir>` re-derives every job-table address from the ROMs and checks that the
flash each variant builds is its parent's payload byte for byte.

**What has actually been run:** the seven sets in the table above and `rdfts`,
on hardware. The 42 variants are checked offline only -- every part against
MAME's `ROM_START` and against `rom_loader.sv`'s table, every part resolving out
of a merged set by CRC, and every derived sample flash identical to its parent's
payload. That covers everything a variant can differ in, but it is not the same
as having booted one.

### The save file

One `<nvram>` element, because an MRA gets one, so what the board remembers is
concatenated into it — and it is **516 bytes**:

    0x000..0x003   the sample flash's REGION STAMP, and nothing else of it
    0x004..0x203   the DS2404's 512 bytes of bookkeeping SRAM

**512 for `rdfts`** — its samples are a real ROM, so there is no stamp to keep and
the tail sits at offset 0. The tail is byte-for-byte MAME's own `ds2404` nvram file.

Those four bytes are the flash's region stamp, which is the whole of what the game
tests to decide its own updater has already run. The 2 MB of samples behind them
are **derived at every boot** in a third of a second, so storing them bought
nothing and cost a visibly unresponsive OSD — Main reads the save file back every
time that menu opens. What persists is the fact of the copy, not its contents.

The DS2404 is the RTC and battery-backed SRAM the games keep their bookkeeping in
-- audit totals, and the game ID the region lock is checked against. The core
answered its ports with zeros until now, so those totals reset every boot; they
persist from here. `rtl/spi_ds2404.sv`, checked against a transliteration of
MAME's own device (`make -C sim run-ds2404`).

**Both settings derive the samples.** What **OSD → Sample Flash** picks is whether
the region stamp goes with them:

- **Pre-built** (default) — payload and stamp. The game finds a programmed flash
  and plays at once.
- **Cart copy** — payload only. The game finds a blank stamp and spends about six
  minutes programming a flash whose contents are already correct, the way the real
  cartridge does at first boot.

**Switching to Cart copy blanks the stamp and restarts the board**, because boot is
the only moment the game looks at it — so the copy can always be seen again.
Switching back does nothing: Pre-built writes the real stamp at the next boot.

### The sample flash

The SPI cartridge has no sample ROM. The YMF271 reads two flash chips the game
programs itself at first boot, and every cartridge MRA above ships them blank
along with the ROMs the game's updater reads. **OSD → Sample Flash** picks what
fills them:

The core derives the 2 MB payload either way: same job table, same sources, same
bytes as the game's own updater, read out of the 386's program image at run time,
verified byte-for-byte against the image MAME's own flash devices hold on all seven
sets. Nothing about it is per-set except two addresses the MRA carries. What the
option changes is only the region stamp, as described under **The save file**
above — and with it, whether the game runs its own six-minute copy.

**Cart copy** ends on "UPDATE COMPLETED. PLEASE TURN THE POWER BACK ON"; reset the
core then, and **open the OSD once** so the four bytes are saved — MiSTer asks the
core for its nvram only while that menu is up. Until they are saved, the copy runs
again at the next boot.

There used to be two MRAs per set for this, and for three of the seven sets
only. `viprp1` could never have a pre-flashed one at all: its payload's second
job reads the 386's own program image rather than any ROM file, which an MRA
cannot express and the core can.

SDRAM: **32 MB is enough for every SEI252 set, in either flash form** — rdfts,
rdft, viprp1, senkyu and ejanhs all reach 29 MB of sprites and top out at 30 or
31 MB. **rdft2 and rfjet need 64 MB** — rdft2's sprites are 18 MB rather than
12, which puts the top of its image at 37 MB, and rfjet's are 24 MB, which puts
its top at 43 MB.

The PCM source ROM is the one region whose base is per-set: it follows that
set's *own* sprites rather than sitting above the largest set's. A single 41 MB
base put all four SEI252 cartridge sets over 32 MB, which is what made the
collapse to one MRA possible at all — the surviving shape is the one that
carries these ROMs. `rtl/spi_defs.vh` `SDR_PCMSRC_*`, and
`build_sdram_image.py --upd` prints the map top it produces.

## Where this is right now

`RESUME.md` is the live state: what is finished, the one thing blocking a
release, and what to try next on it. `PLAN.md` is the design record and reads
chronologically.

## Building

    make            # full Quartus compile -> output_files/SeibuSPI.rbf
                    # NOTE: "successful" does not mean timing met. Always
                    # follow with `make timing` -- Quartus writes the RBF
                    # either way. As of 2026-08-11 every clock is positive
                    # (clk_ram +0.352, TNS 0.000; it read +0.961 one fit
                    # earlier from the same source -- see below).
    make map        # analysis and synthesis only, much faster
    make timing     # name the worst timing paths after a fit
    make lint       # Verilator lint
    make test       # Verilator unit tests
    make check-mra  # MRA vs MAME's driver vs the RTL loader table
    make verify     # all three of the above

    # These need a ROM set, so they are not in `verify`:
    make check-derive ROMS=~/Downloads/roms   # the sample flash, derived from
                                              # an SDRAM image alone, vs MAME's
    make check-snd01  ROMS=~/Downloads/roms   # the 386's sound01 window

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

`capture` takes `GAME=` (default `rdfts`). rdft2 and rfjet additionally need an
already-flashed `-nvram_directory` via `NVRAM=`, or the first boot spends ~420
emulated seconds running the sample reflash. You do not have to sit through one
to get it: `tools/build_soundflash.py` writes that image offline, it is
byte-identical to the one MAME programs itself, and MAME's nvram files are just
that image split into `soundflash1` and `soundflash2` at 1 MB. rdft2 also needs
a rompath whose zip carries three PAL placeholders; rfjet does not.
`SECONDS` must cover `FRAME` at **53.99 Hz, not 60**, or the capture silently
never happens and you get an empty directory.

There is also a whole-board run, which needs no capture — just an SDRAM image:

    make -C sim run-boot GAME=rdft2 SDRAM=/tmp/sdram_rdft2.bin STEPS=400000000

It boots the real 386 against that image and reports how far it gets: ROM
fetches, every I/O register written, the DMA triggers. On the cartridge sets it
finishes by checking the Z80 program the 386 downloaded against the ROM it came
from, which is the only test of `spi_cpu.sv`'s `sound01` window. For `rdft2` and
`rfjet` it does not assume where in `sound1.u0222` that program lives — it
searches the region for the offset that reproduces every downloaded byte and
prints the range it found. That is the only measurement of rfjet's, and it came
out at `[0x44000..0x7FFFF]`, 240 KB — neither of the two lengths that were
available to copy from the other sets. Do not judge
these runs by the picture — the Verilator Z80 is a stub, so a cartridge run
ends on a black screen with the 386 waiting on a sound FIFO that never answers.

Both currently pass exactly: 0 of 76,800 pixels differ, on rdfts, on all ten
captured rdft2 scenes and on eleven rfjet ones, with no starved sprite lines.
`FRAME=` picks the scene — 2400 is the rdfts title with the jungle background
and heavy sprite traffic. Capture more than one; a quiet scene hid two sprite
bugs and a tile-layer offset for weeks, and the rdft2 sweep is what turned up
its 17th sprite tile-code bit. Check the y-hit count in the output before
believing a pass — rfjet's frame 600 is a black screen and "passes" while
proving nothing.

If a set that used to pass suddenly does not, **rebuild the SDRAM image before
believing it**. The captures are MAME state and age fine; the images are ours
and go stale whenever the map moves. A two-day-old rdfts image reported 66% of
pixels differing, which looks exactly like a sprite regression and was not one.

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

## Verifying on the hardware

Simulation cannot see the ioctl download, the Z80 (it is VHDL) or the audio
path, so three instruments cover those. All of them have lied at some point;
`PLAN.md` 10c and 10d are the record of that, and the short version is that a
measurement you have not sanity-checked is not evidence.

**The screenshot first, always.** The MiSTer takes its own, at the core's
native resolution with no capture card or scaler involved:

    sshpass -p 1 ssh root@<mister> 'echo "screenshot s.png" > /dev/MiSTer_cmd'

File size alone distinguishes a black frame from a drawn one, and the menu core
is a control. Three JTAG counters once said healthy while one screenshot named
the bug.

**JTAG, over the USB-Blaster** (`tools/jtag_peek.tcl`) — **not in the current
build.** The probes it talks to, the ROM checksum walker, the SDRAM bus meter
and the on-screen panel were all instrumentation, and they are out of the
synthesised net so a release does not carry them (PLAN.md 29). `rtl/` still has
every module and `tools/` still has the Tcl; putting them back means
recovering `spi_jtag_peek.sv` from git (`PLAN.md` 35), re-instantiating it
(plus whichever watch it is to read) and
re-adding the file to `files.qip`. Expect the timing endpoint in `sdram.sv` to
move when you do -- that is most of what these cost.

    quartus_stp -t tools/jtag_peek.tcl sums              # ROM checksums + download telemetry
    quartus_stp -t tools/jtag_peek.tcl dump <addr> <n>   # read SDRAM back, 8 bytes at a time
    quartus_stp -t tools/jtag_peek.tcl sound             # Z80 PC, FIFOs, YMF writes, voices, overruns
    quartus_stp -t tools/jtag_peek.tcl vitals            # CPU counters, CS:EIP, layer state
    quartus_stp -t tools/jtag_peek.tcl freeze / mask / sweep / trace / rate / gdt / list

The offline half of all this needs no hardware and still works:
`make -C sim run-romcheck SDRAM=<image>` feeds the checker the reference image,
expects all four regions to pass, then flips one bit in each region in turn and
expects exactly that region to fail. `tools/build_sdram_image.py <zip> out.bin
--sums` re-derives the expected sums after any change to how a region is LAID
OUT -- a permutation that keeps every byte still moves a sum over 32-bit words,
which is how a stale constant reported a failure on a perfect download for a
day.

**Audio, through the capture card.** The MiSTer's HDMI audio arrives on the
Elgato's *digital* input, and the default profile is the analog one, which
records perfect silence from a perfectly healthy core:

    v4l2-ctl --list-devices          # never assume a node
    pactl set-card-profile alsa_card.usb-Elgato_..._4K_X...-02 input:iec958-stereo
    pw-record --target alsa_input.usb-Elgato_..._4K_X...-02.iec958-stereo \
              --rate 48000 --channels 2 --format s16 hw.wav

Then compare against MAME playing the same attract:

    mame rdft2 -rompath <roms> -nvram_directory <flashed> -video none \
         -seconds_to_run 200 -nothrottle -wavwrite mame.wav

Align the two by cross-correlating their 20 ms RMS envelopes and compare
spectra on the aligned region. The envelope correlation is what says the sound
*program* is right — the same notes starting and stopping at the same times —
and the spectral correlation is what says the *synthesis* is. Telemetry cannot
tell you either: it will happily report a healthy engine playing the wrong
thing.

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
| 11 | **Pause** | Y |

Keyboard: `1`/`2` start, `5`/`6` coin, `9` service coin, `F2` test.

**Pause** is bit 11 and not button 3, because four of the seven sets are MAME's
`spi_3button` and use button 3 as a game input. It toggles: press to freeze, press
again to resume. Only the 386 stops — the video engines keep running, so the frozen
frame stays on screen and can be studied or captured at leisure, which also makes
it the tool to reach for on a rendering fault. The music carries on, since the Z80
and the YMF271 are not gated; what you hear is whatever loop the Z80 was in when
the 386 stopped feeding it.

## Debugging aids

None in the OSD. Two options used to be there and both are gone: the **Vital
Signs Panel**, which replaced the picture with a telemetry screen, went with the
rest of the instrumentation (`PLAN.md` 29); and the **Freeze Button** switch is
now the Pause button above (`PLAN.md` 33), which needs no menu trip and does not
double as a game input. Their status bits, O[20] and O[21], are left unassigned so
an old saved `.CFG` cannot turn something else on by accident.

Flip Screen (SW1:1) and Service Mode are on the OSD's DIP page. The bit order
above is defined by the `<buttons names=...>` list every MRA carries (they are all
the same list); the MRA and `SeibuSPI.sv` have to be changed together.

## Credits

- z386 CPU core by nand2mario (branch `z386x`), vendored under `rtl/z386`.
- SDRAM controller by Sorgelig, via Arcade-IGSPGM_MiSTer.
- MiSTer framework by Sorgelig and contributors.
- Hardware behaviour derived from MAME's `seibu/seibuspi*.cpp`
  (Ville Linde, hap, Nicola Salmoria and others).

GPL v3 — see the headers in individual files for their original licences.
