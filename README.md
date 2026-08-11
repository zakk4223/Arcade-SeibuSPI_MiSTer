# SlopperPI — Seibu SPI / SXX2E for MiSTer

Raiden Fighters on Seibu **SXX2E** single-board hardware (MAME set `rdfts`),
and on the **SPI cartridge** board it shares almost everything with — `rdft`,
`rdft2` and `rfjet`, all pre-flashed so they skip the cartridge's first-boot
sample reflash.

## Status

**The rendered frame is bit-exact against MAME** — every one of 76,800 pixels,
on two independent captures with different register state, plus ten rdft2
scenes. `rdfts`, `rdft` and `rdft2` boot and run on real hardware, and
**`rdft2`'s sound has been matched against MAME** over two minutes of attract
(envelope r = 0.951, spectrum r = 0.993, zero dropouts). The hardware ROM
checker verifies all four regions on the board (`ok bits 1111`). `rfjet` is
wired end to end and passes every offline check, but has never been rendered or
run. See `PLAN.md` for the full design notes and the task list.

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
| Sound output as a whole | **matched against MAME's own audio on hardware** (`rdft2`) |

Known gaps, all in the sound chip and none of them silent-failure risks: PCM
interpolation and a handful of register fields nothing writes. `PLAN.md`
section 14.5 lists them in order of how likely they are to be heard, and says
for each one why it is deliberate rather than pending.

One known divergence with a decision behind it: **the SPI cartridge board is
stereo and this core is mono**. MAME routes YMF output 0 to the left speaker
and 1 to the right for `rdft`/`rdft2`, while SXX2E sums everything to one
speaker — so `rdfts` is right as it stands and the two cartridge sets are not.
Measured, not assumed: hardware side/mid is −73.7 dB against MAME's −14.5 dB.
The music itself matches; this is fidelity. `PLAN.md` T-K.

## Installing

1. Build `SeibuSPI.rbf` (see below) and put it in `/media/fat/_Arcade/cores/`.
2. Put the MRA you want from `mra/` in `/media/fat/_Arcade/`.
3. Put its zip in `/media/fat/games/mame/`.

| MRA | set | zip | download | state |
|---|---|---|---|---|
| `rdfts.mra` | `rdfts`, SXX2E single board | `rdfts.zip` or `rdft.zip` | 22.3 MB | runs on hardware |
| `rdft.mra`  | `rdft`, SPI cartridge, pre-flashed | `rdft.zip` | 22.2 MB | runs on hardware |
| `rdft2.mra` | `rdft2`, SPI cartridge, pre-flashed | `rdft2.zip` | 34.5 MB | runs on hardware |
| `rfjet.mra` | `rfjet`, SPI cartridge, pre-flashed | `rfjet.zip` | 37.5 MB | **built, never run** |

The three cartridge MRAs ship the YMF271 sample flash pre-programmed, so the
several-minute "techno music" reflash the real cartridge does on first boot is
skipped. rdft's image is assembled by the MRA; rdft2's and rfjet's cannot be,
because a chunk of each is compressed — the core decompresses that during the
download (`rtl/spi_rom_decode.sv`).

**rfjet has never been run.** Every per-set difference findable in MAME's driver
is selected, its part list agrees with `ROM_START(rfjet)` and its flash image
matches MAME's own bit for bit, and its RISE11 sprite crypt is checked against
MAME both in MAME's word order and in the order the fetch walks the words. But
no rfjet frame has been rendered and no board has loaded it. `PLAN.md` T-L/T-M.

**rdft2 runs on hardware** — story intro, then the title screen with sprites,
with music that matches MAME's. Its download is byte-exact: 35,752,108 bytes
in, and out exactly +158,344 more, which is the sample codec's expansion to the
byte. The 128 KB Z80 program the 386 pulls out of the `sound01` window has been
read back off the board at both ends and matches `sound1.u0222[0x60000..]`.

Two things had to land for it. The `sound01` window, which is the one thing
rdft does not need — rdft keeps its copy of the Z80 program in `maincpu`,
already loaded, while rdft2's 386 reads its own out of that window before
releasing the Z80. And an edge detector on `ioctl_wr` in `rom_loader`, which
turned out to be corrupting every set's download, rdfts included; `PLAN.md`
section 10c is the hunt for that one and is worth reading before touching the
loader.

SDRAM: **32 MB is enough for rdfts and rdft** (both reach 29 MB in the map).
**rdft2 and rfjet need 64 MB** — rdft2's sprites are 18 MB rather than 12, which
puts the top of its image at 35 MB, and rfjet's are 24 MB, which puts its top at
41 MB.

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

`capture` takes `GAME=` (default `rdfts`). rdft2 additionally needs an
already-flashed `-nvram_directory` via `NVRAM=`, or its first boot spends ~420
emulated seconds running the sample reflash; `tools/build_soundflash.py` writes
that image offline and it is byte-identical to the one MAME programs itself.
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

Both currently pass exactly: 0 of 76,800 pixels differ, on rdfts and on all ten
captured rdft2 scenes, with no starved sprite lines. `FRAME=` picks the
scene — 600 is the early attract screen, 2400 the title with the jungle
background and heavy sprite traffic. Capture more than one; a quiet scene hid
two sprite bugs and a tile-layer offset for weeks, and the rdft2 sweep is what
turned up its 17th sprite tile-code bit.

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

**JTAG, over the USB-Blaster** (`tools/jtag_peek.tcl`):

    quartus_stp -t tools/jtag_peek.tcl sums              # ROM checksums + download telemetry
    quartus_stp -t tools/jtag_peek.tcl dump <addr> <n>   # read SDRAM back, 8 bytes at a time
    quartus_stp -t tools/jtag_peek.tcl sound             # Z80 PC, FIFOs, YMF writes, voices, overruns
    quartus_stp -t tools/jtag_peek.tcl vitals            # CPU counters, CS:EIP, layer state
    quartus_stp -t tools/jtag_peek.tcl freeze / mask / sweep / trace / rate / gdt / list

`sums` reporting `ok bits 1111` means all four regions were read back on the
board and matched. Note the expected sums in `spi_romcheck.sv` are **rdfts'**,
so on `rdft`/`rdft2` the regions that genuinely differ are expected to report a
mismatch — the sums themselves are still the useful number there. Re-derive
them with `tools/build_sdram_image.py <zip> out.bin --sums` after any change to
how a region is LAID OUT; a permutation that keeps every byte still moves a sum
over 32-bit words, which is how the sprite interleave left a stale constant
reporting a failure on a perfect download for a day.

`make -C sim run-romcheck SDRAM=<image>` is the offline version of that check
and needs no hardware: it feeds the checker the reference image, expects all
four regions to pass, then flips one bit in each region in turn and expects
exactly that region to fail. It is not in `make verify` because it needs a real
ROM set.

`dump` reads any address in the 64 MB map and compares
directly against what `tools/build_sdram_image.py` produces, which is the same
image the testbenches use — that is how a "wrong" checksum was traced to a
stale constant in the checker rather than to bad data. Two caveats it earned
the hard way: the loader never writes the Z80 window (the 386 fills it at
boot, so the reference image holds `FF` there and a mismatch is expected), and
a `dump` value that looks like *neighbouring* data used to be exactly that —
`go` and the address share one ISSP source word and do not update together, so
the Tcl now writes the address first and flips `go` on a second write.

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
