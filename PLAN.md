# SlopperPI — Seibu SPI / SXX2E MiSTer core

Working plan + hardware notes. This file is the resume point: if context is lost,
read this first, then `TASKS` at the bottom.

Status legend: `[ ]` not started `[~]` in progress `[x]` done

---

## 0. Target

**Raiden Fighters**, MAME set **`rdfts`** — *Raiden Fighters (Taiwan, single board)*,
Seibu **SXX2E Ver3.0** hardware (`sxx2e` machine in MAME).

### Why the single board and not the SPI cartridge (`rdft`)

The SPI cartridge mainboard (SXX2C) has no sound sample ROM. Its YMF271 reads from
two Intel E28F008SA 1 MB flash chips that the **game itself programs at first boot**
(the several-minute "techno music" reflash procedure). MAME persists the flash to
NVRAM after that one-time flash, and there is no dumped pre-flashed image. This
file used to say the cartridge-to-flash mapping was "a runtime software transform
we would have to reverse"; it has since been measured and is written out below.

`rdfts` is the same game on a single board that replaces all of that with:

* a plain 128 KB Z80 program ROM (no `z80_prg_transfer_w` download from the 386),
* a plain 2 MB YMF271 sample ROM (`raiden-f_pcm2.u0975`), directly on the YMF bus,
* no cartridge, no flash, no region lock dance.

CPU, video, sprite chip, GFX ROMs and encryption are **identical** between the two.
So the core is built against SXX2E and the SPI cart variants can be added later
behind an MRA config bit once flash emulation exists.

### What the SPI cartridge copies at boot, and where

Measured rather than inferred: `rdft` under MAME with an `install_write_tap` on
the Z80's 0x6000-0x600F (the same idiom as `tools/mame_probe.lua`) and a fresh
`-nvram_directory`, left running until the reflash stopped changing the flash,
then the resulting images correlated byte-for-byte against the cartridge ROMs.
Numbers below are `rdft`; the mechanism should be common to the cart games but
each has its own payload.

**Two copies happen, and only one of them is persistent.**

**1. The Z80 program, every boot, into RAM.** 256 KB copied verbatim from the
cartridge's 386 program ROM at region offset 0x1BB800 (0x003BB800 as the 386
addresses it), pushed a byte at a time to port 0x00000688
(`z80_prg_transfer_w`, auto-incrementing pointer) and released from reset by
0x0000068C. Captured all 262144 bytes and they match the program ROM exactly.
This is RAM, not flash, and it is redone on every boot — it is the first of the
three differences listed above.

**2. The PCM samples, once, into flash.** The destination is the two E28F008SA
chips, which *are* the YMF271's sample memory: 0x000000-0x0FFFFF and
0x100000-0x1FFFFF of the chip's 23-bit external address space.

The writer is the **Z80**, through the **YMF271's own external memory port** —
utility registers 0x14/0x15/0x16 set the 23-bit address (0x16 d7 = R/W) and
every write to 0x17 pre-increments the address and writes one byte. That is the
register block 14.5 lists as unimplemented. Stock Intel command set, as
observed:

```
ADDR  7FFFFF rw=0     address -1, so the pre-increment lands on 0
WRITE 000000 = FF     Read Array (reset), both chips
WRITE 000000 = 20     Block Erase Setup
WRITE 000001 = D0     Erase Confirm
   ... all 16 x 64 KB blocks of each chip, both chips in lockstep,
       R/W flipped to 1 between steps to poll the status register
WRITE 000081 = 40     Byte Program Setup
WRITE 000081 = F7     the data byte
```

The source is the cartridge's `sound01` ROMs, which live on the **386** bus at
0x00A00000-0x013FFFFF. The Z80 has no window onto that, so the bytes cross the
sound FIFO from the 386. Payload, 1,939,011 bytes:

| Flash range         | Source                                              |
|---------------------|-----------------------------------------------------|
| `0x000000-0x0FFFFF` | `gun_dogs_pcm.u0217`, first 1 MB                     |
| `0x100000-0x1A13B5` | `gun_dogs_pcm.u0217`, second 1 MB (its first 0xA13B6)|
| `0x1A13B6-0x1D9642` | `seibu_8.u0216` (its first 0x3828D bytes)            |
| `0x1D9643-0x1FFFFF` | left erased                                          |

The uncopied tail of *both* source ROMs is entirely 0xFF blank padding, so this
is a complete copy of all the real data, packed contiguously. Nothing is
selected, skipped or rearranged.

**The "transform" is just bus width.** `gun_dogs_pcm.u0217` is wired to D0-D15
of the 386's 32-bit bus and `seibu_8.u0216` to D0-D7, which is why MAME's
`sound01` region is a sparse 10 MB image with three populated windows
(`ROM_LOAD32_WORD` and `ROM_LOAD32_BYTE`). The flash payload is exactly those
populated byte lanes concatenated — verified across the whole span.

**Region lock.** Byte 0 of flash chip 0 is the region ID (0x80, Europe, for this
set). MAME ships `flash0_blank_region80.u1053` as a dumped blank flash carrying
it and re-asserts it on every `machine_reset` as an anti-brick hack; an erased
or mismatched byte is the "hardware error 81" the driver header describes.

Only the writes were tapped, so the reads themselves are not captured here; what
is measured is that the direction bit is set to read between steps — which is
enough to say the port has to work in both directions, since a write-only one
would hang the updater on its first status poll.

### Two MRAs: pre-flashed, or the reflash with the music

Both are possible, and the split is lopsided — the pre-flashed one is nearly
free and the authentic one carries all of the work.

**The flash image is fully derivable from the cartridge ROMs.** No emulated
reflash is needed to obtain it:

```
flash[0x000000-0x000003] = maincpu[0x1FFFFC-0x1FFFFF]      region + build stamp
flash[0x000004-0x1A13B5] = gun_dogs_pcm.u0217[0x4-0x1A13B5]
flash[0x1A13B6-0x1D9642] = seibu_8.u0216[0x0-0x3828C]
flash[0x1D9643-0x1FFFFF] = 0xFF
```

Built straight from the zip, that is **byte-identical** to the image the game
programs itself. Booting `rdft` on it, the flash is left untouched and the
machine runs at 2368% instead of the 565% it manages while flashing: the
updater is skipped. (Video and sound were off in that run, so what is confirmed
is that the update is skipped and the image accepted, not that attract plays
with correct audio.)

**The four header bytes are not a magic number and not a checksum.** They are a
verbatim copy of the last four bytes of the 386 program ROM — found at
`maincpu[0x1FFFFC]`, which is the location the MAME driver header already names
for the region code. Region byte plus a three-byte build ID. Simple sums over
the payload do not reproduce them. That is also the region lock in one
sentence: a cartridge from another region carries a different stamp, the stamp
in flash no longer matches, and the updater runs.

So the trigger is **content-based**, not the jumper. Real hardware uses a jumper
to select update mode (the 0x400a port MAME leaves as a TODO), but what is
observed here is: stamp matches -> play, stamp missing or wrong -> reflash.
That is exactly what makes two MRAs work off one core.

No interleaving is involved, so the pre-flashed part list is plain
concatenation:

```xml
<!-- YMF271 sample flash, pre-programmed -->
<part>80 4a 4a 36</part>
<part name="gun_dogs_pcm.u0217" offset="0x000004" length="0x1A13B2"/>
<part name="seibu_8.u0216"                        length="0x03828D"/>
<part repeat="0x0269BD">FF</part>
```

4 + 0x1A13B2 + 0x3828D + 0x269BD = 0x200000 exactly.

**What each variant costs the core:**

| Requirement                                   | Pre-flashed | Authentic |
|-----------------------------------------------|-------------|-----------|
| Z80 program download (0x688 / 0x68C)           | yes         | yes       |
| Second FIFO (Z80 -> 386)                       | yes         | yes       |
| Flash region in SDRAM                          | read-only, exactly like SXX2E's sample ROM | **writable**, and the sample line cache has to be invalidated on write |
| YMF271 ext memory port 0x14-0x17               | no          | **yes, both directions** |
| E28F008SA command state machine                | no          | **yes** — Read Array, Block Erase 20/D0, Byte Program 40/data, status polling |
| Persistence                                    | none needed | **MiSTer save file**, or it reflashes on every boot |

The pre-flashed variant needs nothing beyond what SXX2C support already
requires. The authentic one adds a small flash controller, a write path down a
channel that is read-only today, and save-file plumbing (costed against the
built core in **section 17**, which is the plan of record for it now -- three of
the six rows above turned out to be already built, and one MISSING row is not in
the table at all: the 386's `sound01` source window, without which the ritual
programs silence) — and without that last
one it is a multi-minute ritual every single boot.

Two MRAs is not the only mechanism: the loader could build either image from the
same part list behind an OSD switch. Two MRAs is the more idiomatic MiSTer split
and needs no core option plumbing. Either way the pre-flashed one is what people
want to play, and the authentic one is a strict superset that can follow later.

**Measured 2026-08-09: a pre-flashed MRA can omit `sound01` entirely.** The
window exists so the updater can read the samples out of the 386's address
space; once the flash carries them it is dead. A read tap over
0xA00000-0x13FFFFF, booted on the derived flash image, counted **0 reads across
4800 frames** (~89 s of attract, 2185% -- the updater skipped).

The control matters more than the result, because a tap reporting zero is
exactly what a broken tap reports. Same script, same run length, blank nvram:
**97,901 reads by frame 2100**, the address climbing steadily through the window
(00A00008 up to 00A5F9B8) at 570% -- which is the flashing speed section 0
already records. The tap works; the window really is untouched.

So the pre-flashed part list drops `gun_dogs_pcm.u0217` and `seibu_8.u0216` as
*sources for sound01* -- they are still needed, but only as the material the
flash image is built from, which the MRA does with `offset`/`length` on the same
files. `rdft` pre-flashed comes to about **22.2 MB**: 2 program + 0.19 chars + 6
tiles + 12 sprites + 2 flash, and no Z80 ROM at all because that region is RAM.
Within a rounding error of `rdfts`'s 22.4 MB, which is the sanity check -- it is
the same game.

### SXX2C pre-flashed: what is built, and what is not

**Built 2026-08-09. Not yet run on hardware.** The ROM side is verified in
simulation; the board side is written and lint-clean but unexercised.

ROM side:

* `mra/rdft.mra` -- the pre-flashed cartridge MRA. It assembles the 2 MB flash
  image out of the cartridge's own sound ROMs with `offset`/`length`, carries
  no `sound01` (measured untouched, above), and carries no Z80 ROM at all.
  22.2 MB against `rdfts`'s 22.3 MB.
* `rom_loader.sv` gains a second part table, selected by `set_sxx2c` from the
  MRA's index-1 mod byte, latched in `SeibuSPI.sv`. The four scatter modes the
  cartridge needs -- `M_32_B2`, `M_32_B3`, `M_24_B0`, `M_24_B1` -- already
  existed but had never been reachable; SXX2C is their first user.
* `tools/check_mra.py` now models the loader the way the hardware works, as a
  byte stream split by the table's part sizes, so MRA `<part>` boundaries need
  not line up with loader parts. That is what lets one 2 MB sample part be
  assembled from four MRA elements. Both MRAs verify against MAME; the checker
  is re-tested against a lane swap, a short pad and a truncated header stamp.
* `tb_rom_loader` runs both tables, which is the first coverage those four
  scatter modes have ever had.

The board half, built 2026-08-09 and lint-clean but NOT yet run:

* **Z80 program RAM.** `spi_io` keeps the transfer pointer and the payload in
  the 386's own clock domain and asserts `z80dl_stall`, which `spi_cpu` folds
  into `mem_accept` exactly like the video-DMA hold. So the CPU waits for each
  byte to retire into SDRAM instead of a FIFO trying to keep up -- nothing can
  be dropped, and stalling the 386 for this is what the real board does anyway.
  256 KB at roughly one SDRAM round trip each is about 27 ms of boot.
* **`spi_sdr_arb3`** replaces the two-port ch3 arbiter. The third port is a
  write, and everything is serialised in the arbiter rather than by muxing
  `sdram.sv`'s request lines: those use a toggle handshake, so switching a mux
  with a transaction outstanding would hand one master's ack to another.
* **The second FIFO**, Z80 -> 386. The Z80 writes 0x4008 -- the same address it
  READS the other FIFO from -- and the 386 reads 0x680, which on this board is
  the FIFO and not `sb_coin_r`. So on a cartridge the coin bits reach the 386
  as a message the sound program sends. 0x684 d1 becomes a real `_EF` flag
  instead of the constant 0 that SXX2E's missing device forces.
* **0x68C** gates the Z80's reset and resets the pointer; **0x68E** already
  existed as `rf2_layer_bank`; **0x400a** returns the jumpers, tied to all-ones
  because no update-mode jumper is fitted and a pre-flashed image skips the
  updater on content anyway.

Every one of those paths is gated on `set_sxx2c`, and `z80_rst_n` ties high
when it is clear, so an SXX2E build should be behaviourally identical -- that
is the first thing to check on hardware, before trying the cartridge.

**First hardware run, 2026-08-09: two bugs, both found by measurement.** Neither
was in the RTL the simulation covers.

**1. The mod byte must come BEFORE the index-0 ROM in the MRA.** Main_MiSTer
sends `<rom>` elements in file order, so an index-1 that follows the image
arrives after the loader has already walked its table -- the whole download
then runs against the SXX2E layout. The symptom was a 386 executing garbage in
real mode at 0000:0400, and the giveaway was in the SDRAM dump: program lanes 0
and 1 correct, lanes 2 and 3 wrong. Those are exactly the two the SXX2E table
happens to place identically, because its parts 0 and 1 are also M_32_B0 and
M_32_B1. `bytes_in` was no help -- it counts what arrived, not which table was
used, so it read the correct 23,265,280 either way.

**2. JP1 all-ones is UPDATE MODE, not "no jumper fitted".** MAME's `sxx2c`
port makes bits [1:0] = 0x3 "Update" -- its default -- and 0x0 "Normal", with
bits [7:2] unused and active low. Tying the port to 0xFF therefore asked for
the reflash, and the sound program sat in that path waiting for data a
pre-flashed core never sends. Both CPUs ended up in poll loops: the 386
oscillating over two instructions at 0x26D66x, the Z80 over 0x015D-0162 with
its FIFO reads frozen at 10 and no YMF writes at all. 0xFC is the right value,
and update mode is not reachable without the flash write path anyway.

**Second run, with the jumper fixed: no change.** Same deadlock, same PCs. So
JP1 was a real bug but not the one holding this up. What the second run did add
is that the Z80 program download is **byte-exact at both ends** -- SDRAM
0x200000 matches `maincpu[0x1BB800]` (`C3 67 00`, a valid `jp 0x0067`) and
0x23FFF0 matches `maincpu[0x1FB7F0]`, so the full 256 KB transfers, not just the
start. `ok bits 1110` also shows CHARS, TILES and SPRITES checksumming
identically to `rdfts`, which they should -- they are the same ROMs. Only PRG
"fails", because the checker hardcodes `rdfts`'s expected value.

**Third run: it boots.** The blocker was ONE BIT.

`0x4009` d0 is the Z80's "is there room to send?" flag -- MAME's
`z80_soundfifo_status_r` returns `soundfifo[1]->ff_r()` there. On SXX2E that
device is a nullptr so d0 reads 0, which is exactly what this core hardwired
and exactly right for that board. On SXX2C it has to be `~fifo2_full`. The
sound program polls it before every push, so it sat waiting for room in a FIFO
the core said was permanently full, while the 386 sat at 0x684 d1 waiting for
the reply. Two poll loops, one missing bit.

**Found by disassembly, not by staring at RTL**, and it is worth remembering as
a technique: both CPUs' program images are in SDRAM and both PCs are on the
probes, so the loop each one is stuck in can simply be read. The 386's, at
0x26D65A in the PRG window:

```
bt   WORD PTR ds:0x684, 0x1     ; the Z80 -> 386 FIFO empty flag
jae  back                        ; spin while clear
mov  ax, ds:0x680                ; then take the reply
```

and the Z80's, at 0x15D, hand-decoded out of `maincpu[0x1BB800]`:

```
015D: 3A 09 40   ld  a,(0x4009)   ; FIFO status
0160: E6 01      and 0x01         ; room to send?
0162: CA 5D 01   jp  z,0x015D     ; spin while clear
0168: 32 08 40   ld  (0x4008),a   ; push -- never reached
```

That took minutes and named the exact bit. A telemetry build would have taken
half an hour to say which side was stuck.

**The telemetry is there anyway** and earns its place: `fifo2 push` / `pop` on
the SNDV probe (96 -> 128 bits, appended LSB-side per 14.3). It reads 16/16 on
the working core, which is how the fix was confirmed rather than inferred from
the screen lighting up.

**Working, measured 2026-08-09:** `rdft` boots to attract with sprites and
sound. Z80 PC advancing, FIFO reads 10 -> 2791, YMF writes 0 -> 41146, 6-16
voices sounding, **0 PCM overruns**, fifo2 16/16, all layers enabled, video DMA
every frame. Timing met on every clock (clk_ram +0.735, clk_sys +1.517, TNS
0.000) at SEED 3.

**Sprite starvation, measured against y-hits (2026-08-09).** The `starved 1691`
seen after boot was a cumulative total since core load, not a rate -- the same
trap as the 17199 read on SXX2E earlier the same day. Sampled properly, with
masked 16-bit deltas at ~54 ms (fast enough that y-hit, which ticks ~400k/s,
cannot wrap twice), `rdft` is **no worse than `rdfts` and mostly better** at
matching work:

| y-hits/frame | rdfts starved/frame | rdft starved/frame |
|--------------|---------------------|--------------------|
| 3200-3599    | 0.10                | 0.25               |
| 4400-4799    | 2.00                | 0.64               |
| 4800-5199    | 1.58                | 0.00               |
| 5600-5999    | 6.24                | 0.00               |

So the ch3 write path is not costing the sprite engine anything measurable. The
question that prompted this is answered: SXX2C is fine.

**But neither board reproduces 13b's "0.0 across 4000-8799" any more**, and that
is unexplained. Both show starvation climbing above ~6000 y-hits/frame -- the
pre-`dq_reg` core reads 18.85 at 6400-6799, the current one 2.60, and the two
swap places in the buckets either side. So the `dq_reg` pipeline stage is NOT
the cause, which was the obvious suspect since it adds a cycle to every SDRAM
read; it was tested directly by reloading the previous core off its backup.

Treat this as *not yet established* rather than as a regression. Every
high-load bucket in both sweeps has n = 2 to 7, which is exactly the sample
size 13b warns about ("several with n < 5"), and the two runs disagree with
each other as much as either disagrees with 13b. What it needs is a sweep that
sits on a busy scene long enough to fill those buckets -- a frozen heavy frame,
or the demo gameplay rather than the whole attract cycle -- before anyone
concludes the engine got slower.

**What the first run proved**, before the jumper stopped it: the SXX2C part
table loads the program byte-exact (reset vector `E9 0D FF 00 ... 80 4A 4A 36`
verified in SDRAM), the 386 reaches protected mode and runs (CS 0018), video
DMA fires every frame, and **the Z80 program download works** -- the Z80 was
executing downloaded code at PC 0x15D-0x162, which it could only do if the
0x688 transfer and the 0x68C release both worked. Those are the two genuinely
new mechanisms.

Everything else the cartridge needs is already there: SEI252 sprite decryption
and the SEI252 tile keys are the same as `rdfts` (both are `init_sei252`), the
sprite DMA trigger at 0x50E is already decoded, and the DS2404 stub is shared.

### rdft2's flash payload is NOT derivable the way rdft's was (2026-08-09)

Measured before building anything, and it is the reason not to build it.
(Superseded in part: the payload turned out to be derivable after all, just not
by concatenation -- see "CRACKED: the rdft2 sound-flash codec" below. The
measurements here still stand and are what led there.)

Method, cheaper than section 0's write tap because the mechanism is already
known: fresh `-nvram_directory`, run `rdft2` until the updater finishes, then
read the two `soundflash` nvram files back. MAME persists the flash devices, so
the final image comes out directly.

The reflash completed and was verified as complete, not assumed: 575% while
flashing (the same figure `rdft` gives), then a re-run at **2727% with both
chips unchanged**, which is the updater skipping.

**The region-lock rule holds exactly.** `flash[0..3]` = `maincpu[0x1FFFFC]` =
`80 4A 4A 37` -- region 0x80 Germany, and note the build ID is 4A 4A **37**
against `rdft`'s 4A 4A 36. So section 0's stamp finding generalises.

**The payload does not.** `flash[4..0x17C246]` is `pcm.u0217` verbatim at
identity offset, 1,557,059 bytes. After that:

* the flash holds real data out to 0x1EF2FC, which is MORE than `pcm.u0217`
  itself contains (its real data ends at 0x18749E);
* `sound1.u0222` does not appear in the flash anywhere -- not at any offset,
  searched by content;
* probes taken from the flash past the break are not found in ANY file of the
  rdft2 set.

So `rdft` being a plain concatenation of two ROMs was a property of `rdft`, not
of the hardware. Something transforms or generates data here, and until that is
understood a pre-flashed rdft2 MRA cannot be built -- an MRA can only assemble
files that are in the ROM set.

**Write-tap follow-up, same day.** Tapping the Z80's writes to the YMF271
external port and the 386's reads of `sound01` together sharpened the picture
considerably, and confirms the payload is not a copy.

* **2,028,342 bytes written**, addresses 0x000000-0x1EF2F5, nothing at or above
  0x200000. Both chips are written in lockstep -- the address sequence is
  0x0, 0x100000, 0x1, 0x100001, ... -- and each datum is preceded by its 0x40
  program-setup command to the same address, which is why the tap logs 4,056,752
  writes for 2 MB. Replaying the log reproduces the nvram image, so the log is
  complete.
* **`flash[4..0x17C246]` is `pcm.u0217` verbatim at identity offset**, all
  1,557,059 bytes of it.
* **The remaining 471,215 bytes are not in the ROM set.** Not `pcm` (only
  10,596 of 471,215 bytes coincide, which is chance), not `sound1.u0222` at any
  alignment (best correlation 17 of 586 sampled bytes), not any other file.
  High entropy: all 256 byte values present, 2.7% zeros.
* The 386 read the **entire** 10 MB `sound01` window, 0xA00000-0x13FFFFC.

So the updater copies verbatim for 1.5 MB and then produces half a megabyte of
data from somewhere this analysis has not found. That is consistent with
decompression or with assembly in main RAM from a source outside the tapped
window; it is not consistent with any straight copy.

**Disassembly is now worth doing, and it has a target.** The updater changes
behaviour after writing exactly 0x17C243 bytes, so the code to read is whatever
runs at that transition -- reachable by breaking on the write of flash address
0x17C247, or by finding the 386 loop that feeds it. Both program images are
available (the Z80's is `maincpu[0x1BB800]` for rdft; rdft2's offset needs
finding), and this session already used disassembly successfully to pin the
0x4009 bit in minutes. What it should answer: whether the tail is decompressed,
and if so from where.

**Cracked, by decomposing the pipeline rather than reading code.** The path is
`sound01 reads -> [386] -> sound FIFO 0x680 -> [Z80] -> flash`, so tapping all
three says which stage transforms. The Z80 turns out to be a pure pass-through:
4,056,707 FIFO bytes against 4,056,752 flash writes, command bytes and all. So
everything happens in the 386, and the read log explains the payload completely.

rdft2's flash payload:

| flash range          | source                                                |
|----------------------|-------------------------------------------------------|
| `0x0..0x3`           | region stamp, = `maincpu[0x1FFFFC]` (`80 4A 4A 37`)   |
| `0x4..0x17C246`      | `pcm.u0217` VERBATIM, 1,557,059 bytes                 |
| `0x17C247..0x1EF2F5` | `sound1.u0222[0..0x4C664]` DECOMPRESSED               |

The last row is the thing rdft does not have: 312,933 bytes in, 471,215 out,
**1.506x**. That is why the tail appears in no ROM at any alignment -- it is
computed, not copied. The 386 reads exactly `snd1[0..0x4C664]` and emits exactly
the tail, which is what pins it.

**`sound1.u0222` also holds rdft2's Z80 program**, at 0x60000..0x7FFFF, 128 KB
beginning `C3 67 00` (`jp 0x0067`). It is the FIRST thing read. rdft takes its
Z80 program from `maincpu[0x1BB800]` instead, so that differs per game too --
and it means **the "omit sound01" trick is rdft-specific**. A pre-flashed rdft2
MRA that dropped sound01 would have no Z80 program at all.

### CRACKED: the rdft2 sound-flash codec is BPE over DPCM (2026-08-09)

Solved, and the whole 2 MB flash image is now built offline bit-for-bit by
`tools/build_soundflash.py rdft2.zip out.bin --verify`. It works from the stock
zip; the PAL placeholders are only needed to run rdft2 under MAME, not to build
the image.

**How it was found.** `SLOP_MODE=pc` (from `tools/mame_flash_probe.lua`) named
the routine in one 60-second run: 4,048,837 of 4,048,847 FIFO pushes come from
EIP `0x002A1B8F`. That is a leaf `push_byte` helper, so the useful step was
scanning the program image for `call rel32` sites targeting it -- seventeen, all
inside `0x2A1BBD..0x2A1EFD`, which is the entire flash updater. File offset =
EIP - 0x200000; `objdump -D -b binary -m i386 -M intel --adjust-vma=0x200000`.

**The codec, at `0x2A1D20`, is Philip Gage's byte pair encoding (Dr. Dobb's,
1994) layered over DPCM.** Stream layout, exactly as the 386 reads it:

    u16 nblocks                 LITTLE-endian (note: the block size below is not)
    per block:
      pair table                256 entries of (left, right). A count byte
                                >= 0x80 skips (count - 127) entries; otherwise
                                it introduces count + 1 entries. Per entry read
                                `left`; only if `left != index` read `right`.
                                left[i] == i therefore means "unused".
      u16 size                  BIG-endian, input bytes in this block
      size bytes                each expanded through the table

Expansion is the classic BPE stack walk: while `left[c] != c`, push `right[c]`
and take `left[c]`; pop before fetching new input. Every leaf byte is then a
DPCM delta:

    out[n] = out[n-1] + leaf     (8-bit wrapping; accumulator ds:0x36524,
                                  zeroed once per call, NOT per block)

That explains every earlier observation at once. The DPCM rule held perfectly on
single-output groups because those are unpaired leaves. The multi-output groups
are pairs expanding to 2..6 leaves. It looked stateful because the pair table is
state, and rebuilt per block. It is not LZ because nothing is copied from the
output -- the dictionary is explicit.

**The updater is table-driven, so none of the lengths are magic.** `0x2A1F2B`
walks an array of 12-byte jobs terminated by `src == 0xFFFFFFFF`:

    u32 src          386 address of the source (sound01 window is at 0xA00000)
    u32 len          verbatim: bytes to copy. decoded: OUTPUT bytes (progress bar)
    u8  lane_mode    -> ds:0x36518, consumed by the fetcher at 0x2A1C34
    u8  verbatim     nonzero: raw copy (0x2A1E1C). zero: decode (0x2A1D20)
    u16 pad

rdft2's table is at `0x00201B55` and holds exactly two jobs:

| src         | len       | lane | mode     | produces                    |
|-------------|-----------|------|----------|-----------------------------|
| `0x0A00008` | `0x17C243`| 1    | verbatim | `flash[0x4..0x17C246]`      |
| `0x1200000` | `0x730ED` | 0    | decode   | `flash[0x17C247..0x1EF333]` |

The updater is reached as `0x2A0FA7(ptr)` where the struct at `0x00201B91` is
`{stamp=0x003FFFFC, callback=0x00201BCB, tableA=0x00201B55, tableB=0x00201B79}`.
`stamp` is `maincpu[0x1FFFFC]` = `80 4A 4A 37`, written to `flash[0..3]` last;
table B is a single 0x1FFFFC-byte verbatim copy, a variant this path never took.

**`lane_mode` is the piece that made the payload unfindable by search.** The
fetcher at `0x2A1C34` caches a dword and hands out only some of its byte lanes:
mode 0 takes 1 byte per dword, mode 1 takes 2, otherwise 4. That is undoing
MAME's scatter of the sound01 region -- `pcm.u0217` is loaded 2 bytes per dword
at region 0, `sound1.u0222` 1 byte per dword at region `0x800000`. Two
confirmations of that map: the decode job's `src` is `0xA00000 + 0x800000`
exactly, and `sound1[0x60000]` (the Z80 program) lands at region `0x980000`,
which is precisely the boundary the probe script was already using.

**Numbers, all verified against the emulated flash:**

* verbatim `flash[0x4..0x17C246]` = `pcm.u0217` at identity offset, 1,557,059 B
* decoded `flash[0x17C247..0x1EF333]` = 471,277 B from `sound1.u0222[0..0x4C664]`
  (312,933 B, exactly the measured read count), 1.506x
* `flash[0..3]` = `maincpu[0x1FFFFC]`; everything past `0x1EF333` stays erased
* whole 2 MB image: sha256 `c0da4614a8d07a7bce24b7712b756435f2c5fd1ef74dc44333657afdecc6c67c`

The earlier "471,215 bytes" was 62 short: both previous runs ended mid-flash.
420 emulated seconds is not enough at these speeds -- use 520, then re-run and
check the image is unchanged and the speed jumps to ~3000% (it does).

**Why 4.95 bits/sample beat the delta entropy:** BPE pairs are a dictionary, so
common delta sequences cost one byte. Nothing was being predicted.

### What this changes: rdft2 pre-flashed is now possible, with one wrinkle

The image is derivable, so a pre-flashed rdft2 is back on the table -- but an
MRA can only concatenate files that are in the ROM set, and this needs a
decompressor. So one of:

* **run the decoder in the core at ROM-load time** -- DONE, see the next
  section. `rtl/spi_rom_decode.sv`.
* **ship a derived image** built by `tools/build_soundflash.py`, outside the MRA.
* **the authentic flash path below**, which needs no decoder at all.

Note the "omit sound01" trick stays rdft-specific either way: rdft2's Z80
program lives in `sound1.u0222[0x60000..0x7FFFF]` (128 KB, starts `C3 67 00`,
read first), not in `maincpu`.

rfjet is now cheap to check rather than a fresh reverse-engineering job: find its
job table the same way (PC tap -> callers -> the `0x2A1F2B` equivalent) and read
the jobs off. The codec and the fetcher are library code and will very likely be
identical.

### EVERY SXX2C cartridge's flash image is now derivable (2026-08-11)

That prediction held, and then some. All seven SXX2C sets in the ROM collection
build offline and verify **bit-for-bit against MAME's own flash nvram**:

```
tools/build_soundflash.py <set>.zip out.bin [--set NAME] --verify
```

| set        | gen | job table  | flash payload | sha256 (2 MB image) |
|------------|-----|------------|---------------|---------------------|
| `senkyu`   | A   | `0x302324` | `..0x1EEA11`  | `dd081eba…` |
| `batlball` | A   | `0x302290` | `..0x1EEA11`  | `09c4b1ec…` |
| `ejanhs`   | A   | `0x3026AC` | `..0x1FF891`  | `7693933a…` |
| `viprp1`   | A   | `0x200760` | `..0x18F1FF`  | `27449543…` |
| `rdft`     | B0  | `0x20174D` | `..0x1D9642`  | `659df8c6…` |
| `rdft2`    | B1  | `0x201B55` | `..0x1EF333`  | `c0da4614…` |
| `rfjet`    | B1  | `0x203597` | `..0x1E94C9`  | `fb02c059…` |

**Nothing here was found by running the game.** The tables were located
statically in the program images, and the emulator was used only afterwards, as
the check. That is the opposite order from the rdft2 arc and it is the reason
this took one session instead of three.

**The updater comes in three generations**, and telling them apart is the whole
job. All three walk the same 12-byte record — `u32 src, u32 len, u8 mode, u8
flag, u16 pad`, terminated by `src == 0xFFFFFFFF` — reached through the same
argument struct `{stamp, callback, tableA[, tableB]}`, and all three open the
flash session at address 4 and write the four stamp bytes LAST. What differs is
what `mode` and `flag` mean:

| gen | sets                                | `mode` is         | `flag` | jobs are |
|-----|-------------------------------------|-------------------|--------|----------|
| A   | `senkyu` `batlball` `ejanhs` `viprp1` | an address STRIDE | unused | always DECODED |
| B0  | `rdft`                              | a lane-mode enum  | unused | always COPIED |
| B1  | `rdft2` `rfjet`                     | a lane-mode enum  | used   | per job |

Gen A's fetcher (senkyu `0x33C4B5`) is three instructions — take the byte, add a
literal stride. A ROM occupying one byte in four is read with stride 4. Gen B's
(rdft2 `0x2A1C34`) caches a dword and hands out lanes: mode 0 takes 1 byte per
dword, mode 1 takes 2, otherwise 4. Different encodings of the same idea, and
both then apply the identical 2 MB bank skip (`cmp esi,0x400000 / test
esi,0x1fffff / add esi,0x200000`) that walks MAME's `ROM_CONTINUE` split.

**Gen A has no verbatim path at all and gen B0 has no decoder at all.** Those
two facts are what the byte-9 `flag` reading gets wrong if you assume the rdft2
layout is universal. rdft's records read `flag == 0` for both jobs, which under
rdft2's rules would mean "decode" — and rdft's payload is famously a plain
concatenation. The walkers settle it: rdft's (`0x26D93D`) has no `cmp BYTE PTR
[ebx+0x9],0x0` branch at all, it just calls the copier. Gen A's walker
(`0x33C8B4`) likewise reads only `[ebx+8]` and calls one routine, which takes no
length argument — a copier would need one, a self-terminating decompressor does
not. **Read the walker, not the record.**

**The codec is bit-identical across generations.** senkyu's decompressor at
`0x33C560` is the same BPE-over-DPCM as rdft2's `0x2A1D20`, instruction for
instruction in substance: LE `nblocks`, per-block 256-entry pair table with the
`>= 0x80` skip code and the `left[i] == i` unused encoding, BE block size, stack
walk, and a DPCM accumulator zeroed once per call. Gen A holds the table as 256
*words* (left low, right high) rather than two arrays; that is a storage detail,
not a format one. So one `expand()` serves all seven sets.

**In gen A the `len` field is output bytes, and it is not used to stop.** It is
summed up front only to scale the progress bar. That it nonetheless matches the
real payload extent exactly, on all seven sets, is the cheapest possible check
that a candidate table is the real one — do that before running anything.

**viprp1 is the odd one out and matters for the MRA.** It has no second sound
ROM, so its compressed tail lives in the **program ROM**: job 2 is
`src=0x00365200, mode=1`, reading the 4-way-interleaved 386 image linearly.
Every other set's decode source is one file read in file order, which an MRA
slices trivially; viprp1's needs `<interleave>` over `seibu1.211..seibu4.29` from
file offset `0x59480`. It also consumes 237,614 bytes, which is not a multiple of
4, so the part cannot end on a dword boundary — the decoder stops itself, but the
loader's "input spent" condition has to tolerate 2 unconsumed bytes or the next
part shifts. That is a real trap and it is the one thing in this section that is
not yet exercised by anything.

**Input/output sizes, which are the MRA slice lengths:**

| set        | job 1                              | job 2                                     |
|------------|------------------------------------|-------------------------------------------|
| `senkyu`   | decode `pcm-1[0..]` 1003392→1334444 | decode `fb_7[0..]` 504014→691554          |
| `batlball` | identical to `senkyu`, byte for byte | identical to `senkyu`                    |
| `ejanhs`   | decode `pcm1[0..]` 1040986→1397283  | decode `_7[0..]` 485581→697963            |
| `viprp1`   | decode `v_pcm[0..]` 977063→1291669  | decode **maincpu**`[0x165200]` 237614→343143 |
| `rdft`     | copy `pcm[4..]` 1708978             | copy `seibu_8[0..]` 230029                |
| `rdft2`    | copy `pcm[4..]` 1557059            | decode `sound1[0..]` 312933→471277        |
| `rfjet`    | copy `pcm-d[4..]` 1613265          | decode `sound1[0..]` 269320→390901        |

`batlball` being byte-identical to `senkyu` in its jobs, and differing only in
the region stamp and in where the table sits (`0x302290` vs `0x302324`), is what
a region clone looks like here. Do not assume a clone shares the parent's table
ADDRESS — it does not.

**How to do this for a set not listed.** Build the interleaved program image,
then scan it **unaligned** (the tables sit at odd addresses — rdft2's is at
`0x201B55`) for 12-byte records whose `src` lands in `0xA00000..0x13FFFFF`,
walking to a `0xFFFFFFFF` terminator. Confirm by finding the struct that follows
the tables, whose first dword is `0x003FFFFC`, and the `push imm32` of its
address feeding a `call`. Then disassemble THAT call to classify the generation.
Cross-check the summed `len` against the payload extent in MAME's nvram before
believing any of it.

### Resume point: what rfjet still needs (2026-08-11)

The flash image is done. What is left is the same list rdft2 worked through, and
most of it is already written down elsewhere in this file: the tile/text keys
(section 5.2's table -- `0xAEA754 / 0xFE8530 / 0xCCB666`), the 8 MB sprite chunk
stride (section 4), `set_id = 05` and one more arm in `rom_loader` (the rdft2
part-table section), and RISE11's shape (section "What else `seibuspi.cpp`
covers"). Four things were NOT recorded and are corrections or additions:

**1. The rfjet CARTRIDGE is not SXX2G, and none of the SXX2G clock work applies.**
MAME runs `rfjet` on the `rdft2` machine config -- `spi()` plus `rdft2_map` --
so the YMF271 stays at **16.9344 MHz** and the Z80 at 7.159 MHz. The 16.384 MHz
YMF, the `clock_correction` scaling of every envelope and LFO table, and the
fractional Z80 CE are `rfjets` / `rfjetsa` problems only. The board table above
lists rfjet under SXX2C and rfjets under SXX2G, which is correct but easy to
read the wrong way round; this is the sentence that says it outright.

`rdft2_map` also means `rise_map`, i.e. sprite DMA at 0x562 rather than 0x50E --
already handled, `spi_io.sv:234` decodes both, and rdft2 exercises it. Not a
gap, recorded here so it does not get re-investigated.

**2. RISE11's keys for rfjet**, from `seibuspi_rise11_sprite_decrypt_rfjet`:

    0xABCB64, 0x55AADD, 0xAB6A4C, 0xD6375B, 0x8BF23B, and a trailing flag 0

`feversoc` passes a different five and a flag of 1, which is what the flag
selects between; take all six as inputs the way `spi_tile_decrypt` takes its
keys. Remember RISE11 also needs the word index `i` -- unlike RISE10 it is NOT
address-independent, so the fetch has to supply it.

**3. rfjet's Z80 program is at `sound1.u0222[0x44000]`, NOT `[0x60000]`.**
rdft2's is at 0x60000 and the note above says so, so this is exactly the kind of
constant that gets copied across by mistake. Verified by signature: `C3 67 00`
(`jp 0x0067`) occurs at precisely one place in the whole rfjet set, and 0x44000
is where it is. It sits past the compressed audio, which ends at 0x41C08 (the
figure here used to read 0x41BC7 and was wrong; `build_soundflash.py` now
reports it) -- consistent, and the same "program follows the samples"
arrangement as rdft2, just at a different offset because the payload is smaller.

**MEASURED 2026-08-11, and the warning was justified: 245,760 bytes,
`sound1.u0222[0x44000..0x7FFFF]`.** That is 0x3C000, 240 KB, running to the very
end of the ROM -- neither rdft's 256 KB nor rdft2's 128 KB, so anyone who had
copied either constant across would have been wrong by 16 or 112 KB.

Not measured with a MAME tap in the end. `make -C sim run-boot GAME=rfjet` boots
the real 386 against the real SDRAM image and watches the 0x688 transfer, which
is the same event a tap would have caught, and the bench then SEARCHES
`sound1.u0222` for the offset that reproduces every downloaded byte rather than
being told where to look. 245,760 writes, 245,760 bytes matched, one offset.

**Neither number is load-bearing any more**, which is why the measurement is
confirmation rather than a dependency: the loader carries `sound1.u0222` WHOLE
and the window decodes all of it, so nothing in the core knows either one. See
the next section.

**4. rfjet is a big set** -- and it needs a **64 MB module**, which is a board
requirement rather than an RTL one (`sdram.sv` already routes addr[25]/addr[26]).
The 46.44 MB figure here counted the whole 10 MB `sound01` region; pre-flashed,
with only the 512 KB `sound1.u0222` lifted out of it, the download is
**37.5 MB** and it lands in a 41 MB map. Either way it cannot ride along on a
32 MB build.

### rfjet is wired end to end in the core, and unrun (2026-08-11)

Everything the section above lists is now built, and `make verify` passes. What
does NOT exist is a single frame of rfjet compared against MAME, or a hardware
run. Treat this the way rdft2 was treated at the same stage.

**The RISE11 unit, and the one genuinely new idea in it.** `rtl/spi_rise11_decrypt.sv`,
constants parsed out of MAME by `tools/gen_rise11_tables.py`, reference copied
out of MAME by `tools/gen_ref_c.py` -- the same two-path arrangement RISE10 uses,
so agreement validates the parser rather than being self-consistent.

RISE11's plane210 sum takes **the word index** as its addend. That is the whole
difference from RISE10 and it is not a detail: the loader has already applied
`sprite_reorder()` as an address swizzle, so the position the fetch reads from is
the POST-reorder one and the index the crypt needs is the PRE-reorder one. Inside
a 32-word group reorder sends input word j to output `{j[3:0], j[4]}`, so the
inverse is `j = {o[0], o[4:1]}`, and what the fetch holds as `o` is `{ry, half}`.
The index is therefore

    i = {r_tcode[eb], half, r_ry[eb]}

a pure wire permutation at the decrypt site. Get it wrong and every pen is wrong
with nothing downstream able to notice, so `sim/tb_rise11_decrypt.cpp` runs TWO
passes: MAME's word order (which checks the arithmetic and that reorder is not
part of the unit), and then the FETCH's order through that inverse, compared
against MAME's final image. Breaking the inverse deliberately fails the second
pass and not the first -- 1920 of 12288 bytes -- which is the check that it is
really testing something. A third assertion catches the degenerate case where the
`i` port is not connected at all.

The generator also refuses to emit constants it cannot vouch for: the two gathers
must consume all 48 source bits of b1/b2/b3 exactly once, and `R11_MASK543` must
not carry out of bit 23 (which is what makes a 24-bit adder equivalent to MAME's
`seibu_partial_carry_sum32` call on 24-bit operands).

**The per-set wiring.** `SET_RFJET` = 3, mod byte 0x05, and with it: the tile and
text keys (`TKEY*_RFJET` were already defined and already checked against MAME),
`SPR_CHUNK_SIZE_RFJET` = 8 MB, RISE11 selected in the sprite fetch, and
`bg_fore_pos` = 0x8000 -- rfjet has 9 MB of tiles, which is nothing like rdft2's
12 but lands in the same bracket of MAME's region-LENGTH rule. `set_id` is now
full at 2 bits; a fifth set has to widen it in three places, which
`rtl/spi_defs.vh` says.

**The sound01 window was generalised rather than parameterised, and that is the
part worth reading.** rdft2 keeps its Z80 program at `sound1.u0222[0x60000]` and
rfjet's is at `[0x44000]` -- exactly the sort of per-set constant the section
above warns gets copied across wrong -- and rfjet's program LENGTH had never been
measured at all. Rather than carry two offsets and a guessed length, the loader
now stores **the whole 512 KB of `sound1.u0222`** and `spi_cpu` decodes the whole
2 MB the ROM occupies in the 386's map (0x1200000-0x13FFFFF, its
`ROM_LOAD32_BYTE` lane-0 span) instead of just the top 512 KB. The window then
answers with whatever MAME's region holds at any address inside it, and where
each program starts stops being something the core knows. The fit is exact and
free: `SDR_SND01_BASE` to `SDR_TILES_BASE` is 512 KB to the byte.

This changed rdft2, which was working. `make -C sim run-boot GAME=rdft2` still
downloads all 131,072 bytes byte-exact, and it no longer asserts where they came
from -- it SEARCHES the region for the offset that reproduces them and prints it.
It reports `sound1.u0222[0x60000..0x7FFFF]`, which is rdft2's known answer
derived rather than assumed, and is what makes the same bench a measurement for
rfjet instead of a restatement of a guess.

**And rfjet's own boot run then answered the open question.** 245,760 bytes over
port 0x688, matching `sound1.u0222[0x44000..0x7FFFF]` -- 240 KB, to the end of
the ROM. The 0x44000 the `C3 67 00` signature predicted is right; the length is
neither of the two that were available to copy. The 386 also reaches attract in
that run: 147 tilemap and palette DMA triggers, 148 sprite ones, 833,227
sound01 fetches, and `0x680` last carrying 0x38, which is rfjet's region-stamp
build ID arriving on the sound FIFO. The screen stays black because the
Verilator Z80 is a stub, exactly as it does for rdft2.

**The part table and MRA**, `mra/rfjet.mra` plus a fourth arm in `rom_loader`,
seventeen parts, **39,303,645 bytes (37.5 MB)**. Four independent things agree on
that number and on the layout behind it:

* `tools/check_mra.py` against MAME's `ROM_START(rfjet)` -- order, name, CRC,
  size, scatter mode and destination, part by part;
* the same tool rebuilding the 2 MB sample flash from the MRA's OWN slices and
  matching `sha256 fb02c059…`, the image MAME's flash devices hold;
* `sim/tb_rom_loader.cpp`'s independent model, which walks 24 MB of sprites at an
  8 MB chunk size through the interleave and `sprite_reorder` and lands every
  byte where MAME's region layout says;
* `tools/build_sdram_image.py --concat`, whose stream is the same length.

**None of rfjet's numbers are rdft2's**, which is the reason to check rather than
eyeball: the flash splits at 0x189DD5 against 0x17C247, the compressed tail is
0x41C08 in / 0x5F6F5 out against 0x4C665 / 0x730ED, the second bg group is half
the size (at the same 6 MB base), and **MAME's sprite order is the numeric one
here** -- obj-1 is chunk 0 -- where rdft2's is obj3, obj2, obj1.

**`build_soundflash.py` now reports source bytes consumed as well as produced.**
That number is the MRA slice length and the loader's `part_size`, and for a
DECODED job it cannot be read off the job record at all -- that field carries the
output length. It was previously being taken from a table in this file, and this
file had it slightly wrong: the compressed input ends at 0x41C08, not the
0x41BC7 written above. The counter is validated by rdft2, where it reproduces the
0x4C665 already in the shipped MRA.

**Still missing:** a hardware run, which needs a **64 MB module** -- 37.5 MB of
download into a 41 MB map. `spi_romcheck`'s region sums are still rdfts'
constants and will report failures on any other set; that is pre-existing and
unrelated.

### rfjet renders pixel-identical to MAME, over eleven scenes (2026-08-11)

The gap the section above ends on is closed. **Eleven captured scenes, every one
0 of 76,800 pixels different**, and no line ever ended with sprites unscanned.

| y-hits | frames |
|--------|--------|
| 24,623 and 26,197 | 4200, 4800 |
| 11,263 to 13,866  | 3600, 5400, 6000 |
| 672 to 6,426      | 1200, 1800, 2400, 3000, 7200, 8400 |

Those top two are **heavier than anything rdft2 was ever tested at** -- its
densest capture is 16,572 -- and 0 starved lines at 26k y-hits says the 8 MB
chunk size and the interleave are not costing the fetch anything.

**Capturing rfjet is easier than rdft2, in the one way that matters.** No PAL
placeholders: `mame rfjet -verifyroms` reports the stock set good, so the patched
rompath rdft2 needs is not needed here. It still needs pre-flashed nvram or the
first boot spends minutes on the updater -- but that does not need an emulated
flashing run either, because `build_soundflash.py`'s image IS the nvram:

    python3 -c "img=open('rfjet_flash.bin','rb').read();
      open('nv/rfjet/soundflash1','wb').write(img[:0x100000]);
      open('nv/rfjet/soundflash2','wb').write(img[0x100000:])"

MAME's `intel_e28f008sa` nvram files are raw contents at identity offset, one per
1 MB chip. Booted on that, rfjet runs at **3083%** with both chips unchanged --
the updater skipped, which is the same signature rdft2 gives and is the game
itself accepting the derived image. That is a third independent confirmation of
`build_soundflash.py`, after the sha256 and the MRA rebuild.

**Two negative tests, because eleven passes prove nothing on their own.** Both
against frame 4800, the densest scene:

* RISE10 selected instead of RISE11: **51,151 of 76,800 pixels differ (66.6%)**.
  So the crypt is load-bearing and the frame check sees it.
* RISE11 fed the POST-reorder index `{tcode, ry, half}` instead of the
  pre-reorder `{tcode, half, ry}`: **27,264 differ (35.5%)**. This is the one
  that matters. It is the exact bug the whole index derivation exists to avoid,
  it changes nothing about the arithmetic, and `tb_rise11_decrypt`'s second pass
  and the frame compare are the only two things in the project that can see it.

**Do not capture frame 600.** It is a black screen -- 0 y-hits, 0 non-black
pixels -- and it "passes" while proving nothing at all. It is in the sweep above
only as the reminder; 7200 and 8400 replaced it.

**One trap, and it cost a false alarm.** `run-video` on rdfts against a
two-day-old `/tmp/sdram_rdfts_v.bin` reported 66.54% of pixels differing, which
looks exactly like a sprite-crypt regression from this work and is not one. The
SDRAM image predates a map change; rebuilt from the zip with the current
`build_sdram_image.py`, the same capture passes 0 of 76,800. **Rebuild the SDRAM
image before believing a regression** -- the captures are MAME state and age
fine, the images are ours and do not.

### rfjet RUNS ON HARDWARE, first try (2026-08-11)

**Attract with sprites and sound on the MiSTer at 192.168.1.125**, and nothing
had to be fixed to get there -- the first load booted. That is the first set in
this project that has done so: rdft took three runs (the jumper, then the
0x4009 bit), rdft2 took a session and a half (the sound01 window, then
`ioctl_wr`). The difference is that everything checkable offline had been
checked, and the frame compare in particular. It is worth remembering as the
cheaper order of operations.

**The build.** Every clock positive with TNS 0.000: clk_ram **+0.357**, clk_sys
+1.394, clk_cpu +2.762, hdmi +0.286, worst hold +0.245. clk_ram is where the
RISE11 unit could have shown up and it lands within 0.005 ns of the previous
deployed build's +0.352, so two 24-bit partial adders and a gather cost nothing
measurable.

**Deploy needs three files, not one, and the third is easy to forget.**
`rfjet.mra` and `rfjet.zip` obviously; but **`rdft2.mra` had to be re-copied
too**. Its part 16 changed from a 128 KB slice to the whole 512 KB ROM in this
work, so the MRA already on the machine would send 128 KB where the new loader
expects 512 KB and every subsequent part would land shifted. A core change that
alters a part table invalidates every deployed MRA that uses it.

**The download is byte-exact, and three offline models called it in advance:**

    bytes_in  39,303,645   exactly what check_mra, tb_rom_loader and
                           build_sdram_image --concat all predicted
    bytes_out 39,425,226   = bytes_in + 121,581, the codec's expansion
                           (390,901 out of 269,320 in) to the byte
    part_end  0x10         = 16, the last part of seventeen.
                           NOTE the probe prints this in HEX

**`ok bits 0000` is the checker, not the data** -- `spi_romcheck`'s expected
constants are still rdfts'. Confirmed rather than assumed, the same way T-G was:
all four sums the hardware reported were compared against the same regions of
`build_sdram_image.py`'s reference image and **all four match exactly**
(SPRITES C434328C, TILES 28380112, CHARS A5BBA908, PRG 768415A9). So 24 MB of
sprites and 9 MB of tiles are in SDRAM correct, checked independently of the
video path.

**Video**: the Seibu Kaihatsu copyright screen, the title with the jet and the
logo, the hi-score rank table, and the demo attract over the city and ocean
backgrounds -- all correct by eye, which is all a screenshot can say, but the
frame compare has already said the rest.

**Sound is running**: Z80 PC advancing, FIFO reads 6,116 -> 9,562, YMF writes
978 -> **55,442** between two samples a minute apart, 12 voices sounding,
**0 synth overruns**.

**Sprite starvation is a non-issue at 24 MB of sprites**, which was the open
question this set posed. Measured properly -- CPU frozen on a busy scene so the
counters describe ONE scene, 40 ms sampling so the 16-bit counters cannot wrap
twice (section 13b's lesson, and the 700 ms `rate` run that preceded this was
useless for exactly that reason):

    ~14,000 y-hits/frame, 1.0 to 2.0 starved lines per frame of 224, 0 overruns

rdfts starved 6.24 lines/frame at 5,600-5,999 y-hits. rfjet is starving less at
more than twice the load. **Unfreeze afterwards** -- `jtag_peek.tcl mask 0` --
the freeze mode leaves the CPU stopped and says so.

**What has NOT been done:** no coin, no start, no gameplay (the same gap T-I
records for rdft2), and the sound has not been matched against MAME the way 10d
did for rdft2 -- it plays and the voice count is plausible, which is not the
same thing.

### rfjet's music was never playing: banks 4-7 of the Z80 read as zero (2026-08-11)

Played on the board for the first time, and the report was "the sound is very
bad" plus an occasional quarter-second hitch in gameplay. The sound half is
settled and it is a one-line constant; the hitch is instrumented rather than
solved, below.

`spi_sound.sv` read the top half of the 256 KB Z80 region back as a constant
zero:

```
// The Z80 ROM is 128 KB in a region padded to 256 KB. MAME fills the pad
// with zeros; SDRAM would hand back whatever was there at power-on, so the
// upper half reads as zero here too rather than as noise.
wire [7:0] rom_byte = rom_off[17] ? 8'h00 : line_byte;
```

`rom_off[17]` is the top bit of the bank register, so that deletes **banks 4
through 7** -- and rfjet's Z80 program is 240 KB, not 128. The comment is a
description of rdfts, written when rdfts was the only set, and it is exactly
the class of per-set constant the rfjet notes above warn about twice.

**What the game does with those banks, measured rather than assumed**
(`tools/mame_z80bank.lua`, 75 s of attract):

| set     | banks the driver selects | highest banked byte fetched |
|---------|--------------------------|------------------------------|
| `rdfts` | 0, 1, 2                  | 0x1659E                      |
| `rdft`  | 0, 1                     | 0x0A257                      |
| `rdft2` | 0, 2                     | 0x14A84                      |
| `rfjet` | 0, 1, 3, **5**           | **0x2F168**                  |

rfjet spends 19,478 of its 41,657 bank selects in bank 5. So this bug is
rfjet-only in practice, which is why three sets shipped over it.

It was latent for **rdft** as well, and the fix changes its behaviour: rdft's
program is a full 256 KB, so MAME's region has real bytes in banks 4-7 where the
core returned zeros. Attract never goes past bank 1 there, which is why nothing
showed. rdfts and rdft2 are 128 KB programs and read exactly as before.

**Bank 5 is the music.** The reads start at t=1.0 s with a table of little-endian
`{pointer, bank}` records at 0x2CC9C -- 0xCCD7/05, 0xCCF2/05, 0xCD54/05 -- and
then stream sequence data from 0x2CD82, 0x2CEA9, 0x2D1BA onward for as long as
the game runs. Zeroed, the sequencer is handed a null pointer table.

**Reproduced in MAME, which is what makes this a diagnosis rather than a
theory.** `tools/mame_z80_zerotop.lua` blanks exactly the same reads inside the
emulator -- on the read side, because that region is RAM the 386 fills at boot,
so anything cleared before the machine runs is simply written over. 60 s of
attract:

| run                              | RMS    | peak  |
|----------------------------------|--------|-------|
| stock                            | 2171.5 | 22481 |
| pass-through tap (control)       | 2171.5 | 22481 |
| bank >= 4 reads blanked          | **0.0**| **0** |

The control is bit-identical to stock, so the tap is not what silences it.

**And this is why the hardware telemetry said the sound was fine.** With the
banks blanked MAME still writes the YMF at **1081 registers/s** against a
healthy **1038/s** -- the driver's per-tick refresh does not care that the
sequence data is zeros. The board reported 55,442 YMF writes and 12 voices
sounding and that was recorded as "sound is running". It was running; it was
playing nothing. Section 10d already said the telemetry "happily reports a
healthy engine playing the wrong thing" and this is the second instance.

**The fix, and why it is not just deleting the test.** The pad still has to read
as MAME's zeros rather than as whatever SDRAM held at power-on, so the bound
became what was actually written: `spi_io` keeps a high-water mark of the 386's
0x688 download (`z80dl_end`, kept separately because 0x68C rewinds the pointer),
and SXX2E uses the 128 KB ROM part's size. Compared per 8-byte line, rounded up
so an unaligned download keeps the valid bytes of its last line. The map has the
room: `SDR_Z80_BASE` is 0x200000 and `SDR_CHARS_BASE` is 0x240000, a full 256 KB
apart, so banks 4-7 were addressing dedicated space that simply never got read.

**The address arithmetic itself was checked, not assumed.**
`tools/mame_z80map.lua` requires every byte MAME's Z80 fetches to equal the byte
at the region offset the RTL's formula computes -- 65,191,658 fixed-window
fetches and 3,576 banked ones, 0 disagreements -- and confirms the region is
0x40000 with eight 32 KB banks. Worth having: the region SIZE in that module was
wrong, so the rest of it deserved more than a reading.

### rfjet's sound, measured against MAME (2026-08-11)

The fix deployed, and then measured the way 10d measured rdft2 -- because
"voices went from 12 to 30" is the same grade of evidence as "12 voices, sound
is running", which is what hid the bug in the first place.

198 s of hardware attract off the Elgato against 420 s of MAME, aligned by
envelope correlation (the capture starts mid-attract; the lock landed 135.8 s
into the reference). `tools/compare_audio.py`, which is 10d's measurement
written down instead of redone by hand.

| measurement                                     | rfjet        | rdft2 (10d) |
|-------------------------------------------------|--------------|-------------|
| envelope r vs MAME, 20 ms RMS                   | 0.9025       | 0.951       |
| long-term spectrum r                            | **0.9855**   | 0.9927      |
| per-second spectral r, median                   | **0.9844**   | 0.967       |
| per-second above 0.8                            | **96%**      | 87%         |
| silence agreement                               | 99.9%        | 99.9%       |
| windows hardware silent while MAME plays        | 9 of 9,900   | 0           |

**The envelope figure is lower than rdft2's and it is not drift.** Split into
six 30 s chunks, each aligned independently, four read 0.957-0.981 and two read
0.677 and 0.407. Uniform clock drift would have lowered all six equally, so
something is different in two passages.

What is different is the *timing*, not the sound. In the worst chunk -- envelope
r 0.407 -- the spectrum correlates at **0.9972** with 100% of its seconds above
0.8. The same instruments and samples are playing; they are playing at different
moments. That is what an attract DEMO doing different things looks like: it is
real gameplay, so a small timing difference changes which enemies die when and
therefore which effects fire. It is not proof -- proving it wants a second
capture to show the weak windows move -- but wrong synthesis cannot produce a
0.997 spectrum, and a wrong sequencer cannot produce a 0.98 median across every
other chunk.

One alignment lesson, the same one 15.4 records: chunk 1's independent search
preferred an offset 207 s away from the globally consistent one, because the
attract LOOPS and a 30 s window matches its own repetition slightly better. Its
correlation at the consistent offset is 0.9527, which is the number that means
something. Always check that per-chunk offsets are consistent before believing a
per-chunk correlation.

**T-K reconfirmed for rfjet, independently:** hardware side/mid **-82.4 dB**
(mono, and that is the capture path's own floor), MAME **-16.3 dB** (genuinely
stereo). Same divergence 10d found on rdft2 at -73.7 vs -14.5, and the same
cause -- `spi()` routes YMF output 0 left and 1 right, `sxx2e()` sums to mono.

Level: MAME is 1.35x the hardware here (rms 2324 vs 1728), against 2.58x on
rdft2. Still unexplained, still a level difference and not a shape one; every
figure above is normalised.

### Fast ROM loading: the HPS writes DDR3 and we read it back (2026-08-14)

The download was the slowest thing about using this core: every byte of a 23 to
40 MB image crossed the ioctl bus one at a time. Main_MiSTer can instead DMA the
whole file into DDR3 itself, which an MRA asks for with one attribute:

    <rom index="0" address="0x30000000" zip="rdft2.zip" md5="none">

`rtl/ddr_rom_reader.sv` then reads it back out and hands `rom_loader` the same
byte stream it has always been given. Modelled on `Arcade-IGSPGM_MiSTer`, whose
`ddr_rom_loader_adaptor` does exactly this.

**WHY AN ADAPTOR AND NOT A NEW LOADER.** `rom_loader` does not copy bytes, it
transforms them: a fourteen-part scatter with ten destination modes, the
BPE+DPCM decoder for rdft2's and rfjet's sample flash, and `sprite_reorder`
folded into the destination address. Every one of those is verified byte-exact
against MAME (section 12) and none of it wants rewriting against a different
source. Replaying DDR3 as the same stream keeps all of that verification
pointed at the thing that still runs.

**THE THREE ioctl SEMANTICS THAT CHANGE**, which is the whole trap:

* **`ioctl_wr` never fires.** The data does not cross the FPGA's ioctl bus at
  all. That is how a fast download is DETECTED: `ioctl_download` rose and fell
  without a single write. A slow download of the same index still streams and
  passes straight through, which is what keeps an MRA without the attribute
  working -- and means that if Main_MiSTer ever ignored the attribute, this
  degrades to the old path rather than breaking.
* **`ioctl_addr` holds the LENGTH at the end.** `hps_io.sv` latches
  `ioctl_addr <= addr` when the HPS closes the transfer, and for a DDR3
  download `addr` is the size the HPS reports rather than a counter it walked.
* **`ioctl_download` falls long before the image is in SDRAM.** It now means
  "the HPS is done", not "the ROM is loaded". Everything keyed off it has to
  follow `dl_download` instead -- above all `reset` in `SeibuSPI.sv`, which
  otherwise releases the 386 into an empty SDRAM, and `LED_USER`, which
  otherwise goes dark for the part that takes the time.

`hps_io.sv` is byte-identical to IGSPGM's, so none of this needed a sys change.

**TWO HAZARDS THAT COST NOTHING TO AVOID AND EVERYTHING TO MISS.**

`dl_download` must not DIP. It is registered and changes only on a decision --
the download ended and was slow, or the replay finished -- so at the moment
`ioctl_download` falls on a fast download it simply stays high. Derive it
combinationally and there is a one-cycle gap, and to `rom_loader` that gap is
the end of the image: it resets `part` to 0 and pulses `rom_ready`, which is
wired to `spi_romcheck`'s `start`, so the checker begins sweeping ch3 against an
image that does not exist yet.

The pass-through is COMBINATIONAL, deliberately. `rom_loader`'s header records
that `ioctl_wait` already has a cycle of latency and only works because the HPS
is slower than the SDRAM. Registering the pass-through would spend another cycle
of exactly that margin, on the fallback path, to save nothing.

**THE STROBE IS ONE clk_sys CYCLE WIDE, and this is 10c again.** `rom_loader`
runs on clk_ram, exactly 2x clk_sys and phase aligned, and rising-edge detects.
A two-cycle strobe is two bytes to it -- which is precisely the bug that had a
MiSTer reporting 46,792,704 bytes for a 23,396,352 byte image. The new bench
asserts the width directly rather than inferring it from a byte count, and
`tb_rom_loader` already runs every set with the pulse held for one AND two
loader clocks. The two tests meet exactly at that interface.

**DDRAM IS SHARED WITH THE FRAMEBUFFER, and the ROM reader simply wins.**
`screen_rotate` writes the rotated framebuffer to DDR3 at 0x24000000; the image
goes to 0x30000000, so they do not overlap in space. They can overlap in time,
and during a replay `screen_rotate`'s writes are DROPPED rather than queued.
That is the cheap option and it is sound here: `screen_rotate` ignores
`DDRAM_BUSY` -- it is declared and never read -- so it cannot be stalled, and
giving it back-pressure means a FIFO in front of it, which is what IGSPGM had
to build. There is nothing worth queueing: the core is held in reset for the
whole replay, so the dropped frames are blank ones. A core using DDRAM for
anything load-bearing during a load would need the FIFO.

**One bug worth recording because the fitter would never have complained.**
`DDRAM_ADDR` is a 64-BIT WORD address, not a byte address. Adding a byte base
to it reads from 0x180000000 -- eight times too high, off the end of memory,
and perfectly legal RTL. The base has to be shifted with the offset:
0x30000000 is word 0x06000000.

**Verified in simulation.** `make -C sim run-ddr_rom_reader` covers a fast
download at 1, 7, 8, 9 and 4096 bytes -- the sizes around the 8-byte word
boundary, where the last partial word lives -- with irregular back-pressure,
plus the strobe width, a slow download passing through, a zero-length download
starting no replay, and a non-zero index being ignored.

**CONFIRMED ON HARDWARE, byte-exact, and 2.76x faster (2026-08-14).** rdfts
first, deliberately: it is the smallest image and the only set whose checksums
`spi_romcheck` actually knows, so `ok bits 1111` is a verdict there rather than
the noise it is on rdft2.

    bytes_in 23396352  bytes_out 23396352   ok bits 1111   passes 1 fails 0
    part_end 13
    PRG 741393AF  CHARS 79A0EB60  TILES D3E9E887  SPRITES 76809831

Every figure identical to the same core loading the same set the slow way, and
all four checksums equal to the constants in `spi_romcheck.sv`. The attract
intro renders correctly.

Timing, with the same polling harness both ways so the overhead is common, two
runs each and reproducible to the millisecond:

    slow (byte by byte)   27404 ms, 27405 ms
    fast (DDR3)            9911 ms,  9912 ms

Both include FPGA reconfiguration and unzipping 23 MB, which are fixed costs, so
the transfer itself improved by much more than the 2.76x end to end. The
comparison is cheap to repeat because the same bitstream does both: a copy of
the MRA without the `address` attribute is a slow load, and
`/media/fat/_Arcade/rdfts_slow.mra` on the MiSTer is exactly that.

**rfjet next, and it is the interesting one: 39.3 MB, and the only set with a
DECODED part.**

    bytes_in 39303645  bytes_out 39425226   part_end 16

`bytes_in` is exactly the figure recorded for rfjet, and `bytes_out` is exactly
`+121,581` -- the BPE codec's expansion, to the byte. That is the result worth
having, because it is not a straight copy: the replay had to hold off against
the decoder's back-pressure for hundreds of cycles at a time and resume in the
right place, and an expansion that lands byte-exact says it did. Logo screen
renders, 11 voices, 0 overruns. `ok bits 0000 / fails 1` is the expected noise
-- `spi_romcheck` only carries rdfts' constants.

    slow   44894 ms, 45047 ms
    fast    9904 ms,  9901 ms, 9970 ms, 9959 ms

**4.53x on rfjet**, 35 seconds saved. Note the slow path scales with image size
almost exactly (23.4 MB -> 27.4 s and 39.3 MB -> 44.9 s, a ratio of 1.64 against
the images' 1.68) while the fast path does not move at all between the two sets.
Most of the fast figure is therefore fixed cost -- reconfiguration and
unzipping -- not transfer.

**ALL FOUR SETS, byte-exact.** `bytes_in` equals what `make check-mra` computes
for the MRA, to the byte, on every one; `bytes_out` equals it too except where a
part is decoded, and then by exactly the codec's expansion:

    set     image bytes   bytes_out         slow      fast    gain
    rdfts     23,396,352  = in            27404 ms   9911 ms  2.76x
    rdft      23,265,280  = in            27513 ms   9960 ms  2.76x
    rdft2     36,145,324  +158,344        45059 ms   9200 ms  4.90x
    rfjet     39,303,645  +121,581        44894 ms   9904 ms  4.53x

Both expansions are the figures already recorded for those sets, which is the
part that matters: the replay has to stall against the decoder for hundreds of
cycles and resume in the right place, and landing on the exact expansion says it
does. rdfts additionally gives `ok bits 1111` against `spi_romcheck`'s
constants.

**rdft checksums three of its four regions for free.** `ok bits 1110`: CHARS
`79A0EB60`, TILES `D3E9E887` and SPRITES `76809831` are byte-identical to
rdfts', which is what the same game on a different board should give since they
share the graphics ROMs. Only PRG differs. So rdft's graphics regions are
verified against MAME-derived constants too, which was not previously true of
any set but rdfts.

**And rdft's screenshot corroborates T-J.** It comes up in the board's TEST MODE
menu, not attract, exactly as T-J predicts from the MRA's saved Service Mode DIP.
Nothing about the core; the DIP is on. (It is also why rdft's frames are ~3 KB
and broke the timing harness's threshold, below.)

**One number moved and it is the MRA, not the loader.** This file records
rdft2's `bytes_in` as 35,752,108; it now reads 36,145,324, which is what
`check_mra` computes for the current MRA. The 393,216 difference is MRA changes
since that reading -- the sample flash gained a head/tail split with inline
parts. The codec expansion, +158,344, is unchanged, and that is the invariant
worth trusting.

**Two cautions about that measurement, one of which is a real hole.** The
completion test is "the framebuffer changed", polled about once a second, so it
cannot resolve the ~1 s of extra replay rfjet's larger image must cost; "both
about 9.9 s" is at the limit of the harness, not a claim that image size is
free. And the first version of the test was simply wrong: it fired on "the
framebuffer is not blank", which during a REPLAY is satisfied by the previous
game's frame, because dropping `screen_rotate`'s writes leaves the old picture
sitting in DDR3. That is a direct consequence of the arbitration choice above
and it means the display holds a stale frame rather than going black during a
fast load. Re-measuring against a pre-load baseline gave the same numbers, so
the figures stand -- but the naive test would have flattered the fast path on
any core that loads faster than it reconfigures.

### The `sums` panel was misreading the probe, and cost a false failure

The first fast-load reading looked like a broken download: `bytes_in 22626304`
against a true 23,396,352, `ok bits 0001`, and four checksums that looked like
nibble-shifted versions of the right answers. It was the INSTRUMENT.

`bytes_out` was added to the SUMS probe when it was wired up, and only
`tools/jtag_peek.tcl` was updated for it. `jtag_server.tcl`'s `show_sums` still
sliced the old 195-bit layout, so every field from `bytes_in` onward was read 27
bits early. A shifted field is still a plausible number, which is the entire
danger.

**The panel contradicted itself and that is what gave it away.** It printed
`passes 1 fails 0` with `ok bits 0001` -- the hardware's own comparison saying
PRG matched -- next to a PRG value that did not match `SUM_PRG`. Hardware and
printout disagreed about the same region in the same line. When that happens the
printout is the thing to doubt.

Two other things made it cheap to unmask. The slow path was tried on the same
bitstream and reported byte-for-byte the SAME wrong numbers, which rules out
anything the fast path touches. And `spi_jtag_peek.sv`'s own header already
describes this exact failure from the other direction, when `probe_width` was
193 while the concatenation was 195.

`show_sums` now derives its offsets from the documented layout, prints
`bytes_out` and `part_end` as well, and **checks the probe width**, refusing to
be believed if it is not 221. That guard already existed in `jtag_peek.tcl`; the
lesson is that two readers of one probe drift, and the one without the guard is
the one that lies. Third instrument failure of the day, after the stale JTAG
server's silent zeros and the free-running VITL counters.

### Stereo, which is two accumulators and a board flag (2026-08-14)

T-K. The cartridge board wires chip output 0 to the left speaker and output 1
to the right; the single board sums all four outputs into one. That is
`spi()`'s `add_route(0,"speaker",1.0,0)` / `add_route(1,...,1)` against
`sxx2e()`'s `add_route(ALL_OUTPUTS,"mono",1.0)`, and it splits the sets the way
the driver does, not the way the set list does:

    rdft   -> spi()            stereo
    rdft2  -> rdft2() -> spi() stereo
    rfjet  -> rdft2() -> spi() stereo
    rdfts  -> sxx2e()          mono

**That is exactly the mod byte's bit 0**, which `spi_sound` already receives as
`set_sxx2c` -- rdfts sends `00`, the other three send `01`, `03`, `05`. So the
select needed no new plumbing above the sound block, and nothing in any MRA
changes.

**The decomposition is free.** `ymf271_synth` carried one accumulator summing
all four channels. It now carries two: the left takes chip outputs 0 and 2, the
right 1 and 3. Their SUM is the old mono, because `(g0+g2)+(g1+g3)` is the same
addition in a different order, and in stereo the two halves are read
separately with outputs 2 and 3 dropped -- which is what the board does with
them. Cost is one extra multiply on each of the PCM and FM paths and one extra
28-bit accumulator.

Two details that would each have been a quiet off-by-one:

* **Mono sums before the shift, not after.** Each output is normalised by
  `32768<<2`, so a speaker is its accumulator `>> 2`. Shifting both halves and
  then adding rounds each toward -inf separately and loses up to an LSB against
  the old single accumulator. rdfts' sound is already measured against MAME;
  this change must not move it, and summing first is what guarantees that.
* **The per-channel clamp stays per channel.** `update_pcm` clamps each of the
  four at 65536 individually before summing, so folding ch0 and ch2 into one
  accumulator still has to clamp them separately on the way in.

**Verification.** `run-ymf271` gained `test_stereo_split`, and the two halves
prove each other. In stereo with ch0 at 0 dB, ch1 silenced and **ch2/ch3 left
at 0 dB on purpose**, the left speaker is `sample >> 2` exactly and the right
is silent -- a wiring that folded the unrouted channels back in would read
three times that. Flip `stereo` off with the same registers and the mix is
`3*sample >> 2` on both speakers, which is what makes the first half mean
something: it would have passed against a mono core too. All twelve
pre-existing tests pass bit-identical, which is the regression proof.

**A stale JTAG server reads as a wedged core, and cost a needless reboot.**
Deploying reprograms the FPGA, and 9b already says to restart the server after
every `load_core`. What is new is the failure MODE. The server left running
across a load did not throw, which is what was expected -- it went on answering
and returned all zeros: `bytes_in 0`, `vbl frames 0`, `CS:EIP 0000:00000000`.
That is indistinguishable from a core that never started, and the MiSTer was
rebooted on it. A screenshot taken at the very same moment was 32,929 bytes of
correct rdfts picture. The core had been fine the whole time.

This is the lesson of 10c's "take screenshots" arriving for the third time, and
the reboot happened in a session that had already quoted it. A silent zero is a
worse instrument failure than an exception, because nothing marks it as
broken. Any all-zero panel taken after a deploy means restart the server before
believing a word of it.

Separately, and genuinely: `echo ... > /dev/MiSTer_cmd` blocks, and a timeout on
the LOCAL ssh does not kill the remote writer -- two of them had accumulated.
`ssh ... 'timeout 20 sh -c "echo ... > /dev/MiSTer_cmd"'` returns 0 cleanly.
A blocked writer does not mean the load failed: rdft2's writer was stuck from
06:38 while the game booted, ran attract and was captured.

One trap, and it is the bench's rather than the core's: `reset_dut()` clears
the state machine but NOT the per-slot RAM, so voices an earlier test left
active go on sounding. Run last, this test read a constant 1408 in the right
channel that had nothing to do with the routing. It runs FIRST now, on a
machine nothing has played on. `silence_pcm_bank3()` exists for the same
reason and is worth remembering before writing any new case here.

**MEASURED ON HARDWARE the same day, and the control is what makes it a
proof.** Both captured off the Elgato through the same path, minutes apart, on
one bitstream:

    set     board          mid rms   side/mid    L!=R
    rdft2   cartridge        843.1   -25.3 dB   77.6%   STEREO
    rdfts   single board    1742.5   -81.7 dB    6.7%   MONO

rdft2 was -73.7 dB before this change, with L and R differing by at most 1 LSB.
The only thing separating the two rows is the MRA's mod byte -- `03` against
`00` -- so this tests the part simulation cannot reach: that the select chain
from the mod byte through `set_sxx2c` into `stereo` is wired correctly per
board. rdfts staying at -81.7 dB is the half that rules out "something changed
globally".

`compare_audio.py` already prints this figure and labels anything below -60 dB
MONO, so the check costs nothing on any future capture.

**The level prediction below is CONSISTENT but not proven.** rdfts reads mid
rms 1742.5, essentially the 1728 this file records for rfjet on the old mono
core, and rdft2 now sits at 843.1 -- a factor of 2.07, or 6.3 dB, which is what
was predicted. It is not a controlled measurement: rdft2 and rdfts are
different games with different music, and no capture of rdft2 on the old core
exists to difference against. Suggestive, and the honest way to settle it is a
before/after on ONE set.

**A prediction this makes, which the next audio capture can falsify.** Each
speaker now carries one chip output where it used to carry all four summed, so
if a game drives ch0/ch1 and leaves ch2/ch3 attenuated the per-speaker level
falls by roughly half -- about 6 dB. 10d already records MAME running 2.58x
LOUDER than the hardware on rdft2 and 1.35x on rfjet, unexplained; this widens
that gap rather than closing it. Which is itself informative: our mono was
summing MORE channels than MAME's stereo and was still the quieter of the two,
so the level discrepancy was never about channel count and this change should
not be expected to fix it. If a fresh capture shows the gap grow on rdft2 and
rfjet while rdfts stays put, the routing landed and whatever is left is common
to all three boards.

### rdft2 played through, and the bus is 68% idle at its worst (2026-08-14)

A credit played to a death on the second boss, marks cleared first. This is
T-I, the last set that had never been past attract, and it is the first live
load `spi_sdr_stats` has ever seen.

**Nothing moved.** `frame gap` 1036 -- exactly one frame, never exceeded -- the
two-frame stall latch never fired, `fifo peak` 16 of 511 and never full,
`fetch wait` 60 clk (1.0 us) unchanged from attract, 0 synth overruns.
`sprite starved` went 42 -> 48 across the whole credit: **six starved lines,
not six per frame**. rdfts starved 6.24 lines *per frame* at 5,600 y-hits/frame
(13b). The RISE10 sprite fetch holds under live load, which is the thing T-I
existed to ask and which had only ever been checked against static captures.

**Per-channel occupancy, 72 samples across attract and play:**

    channel        attract   gameplay peak
    ch2-tiles       20.49%       20.52%
    ch4-sprites      1.15%        7.89%
    ch3-z80          2.61%        2.75%
    ch1-386prg       0.02%        0.79%
    ch5-pcm          0.06%        0.33%
    TOTAL           24.34%       31.52%     (refresh ~2% on top)

ch2 is flat at 20.5% whatever is happening -- the tile fetch is a fixed cost
per frame -- and sprites are the only channel that responds to load, 7x from
attract to a boss. **The bus peaks at a third full.** So neither T-D (the
line-buffer generation tag, ~10% of the sprite line budget) nor reordering the
arbiter is a bandwidth argument, and if starvation ever returns it is a latency
and priority question. That is what `SLOP_SPR_PRIO` in `tb_video.cpp` probes.

Two cautions about these numbers. The sampler took one 18.31 ms window every
3 s, so a worse instantaneous peak could have fallen between samples; the four
marks are continuous and clean, so nothing *sustained* was missed. And the
VITL panel's `spr scanned`, `y-hit`, `emitted` and `tiles` are FREE-RUNNING
16-bit counters -- 39944, 47914, 65322, 6442, 12586 is one series, wrapping --
so a single sample of `y-hit` is not a per-frame figure and cannot be compared
against 13b's y-hits/frame table. `sprite starved` and `layer ovrun` are small
enough that their monotonic steps are real events.

**The 0.244 s frame gap read before the clear was boot, not a hitch.** The
first reading of this session, taken on marks that had never been cleared,
showed `frame gap 13648 = 0.244 s` with the stall latch fired at
`CS 0018 EIP 002A1A9A` -- a few hundred bytes below `0x2A1BBD..0x2A1EFD`, the
flash updater (see the SXX2C section). The 386 does not push sprite lists while
it is decompressing the sound image, so the mark catches it. rdft2's analogue
of the 0.387 s this file already records for rfjet. Re-measuring after a clear
produced 1036, which is what turns that from a guess into a reading -- and the
general lesson is the one 10c keeps teaching: an uncleared mark is a claim
about the whole session including boot, and reading it as a gameplay figure
invents a bug.

**Reproduced later the same day, which is what makes it a finding rather than
a story.** Deploying the stereo core reprogrammed the FPGA and rebooted rdft2
from cold, and the first uncleared reading was `frame gap 13648 = 0.244 s`
with `stall at CS 0018 EIP 002A1AA6` -- the same quarter second, to the unit,
at an address twelve bytes from the first one. Two independent boots landing
on the same gap at the same place in the flash updater is the confirmation the
single reading could not supply.

### The gameplay hitch went away with the bank fix (2026-08-11)

Played through with the fixed core and the marks cleared: **worst frame gap
1054**, one frame, and the two-frame stall latch never fired. The player
confirms it independently -- the hitching is gone.

**A correction, because the reasoning below it was wrong in a way worth
recording.** This section previously said the sound FIFO and ch3 starvation were
both "cleared" as suspects. Every one of those readings was taken on the FIXED
core. The broken core was never instrumented, so what was actually shown is that
neither mechanism is active *now* -- not that neither caused the original stall.
Ruling a cause out requires measuring it under the conditions that produced the
symptom, and by the time the instruments existed those conditions were gone.

The likely mechanism, and it is one none of the four marks watch: the
**Z80 -> 386** direction. The 386 polls 0x684 d1 for a reply from the sound
program. `fifo2 push`/`pop` run to about 16 for a whole session, so those
messages are rare and individually load-bearing. A driver working from a null
pointer table can easily fail to send one, and then the 386 waits. The marks
watch the 386 -> Z80 FIFO filling instead, which is the other direction.

Not proven. Proving it means putting the old core back and measuring the stall
while it happens, which costs a build and a deploy to confirm something already
fixed. Recorded rather than done, and T-O is left open at low priority in case
it returns.

### What the instruments say now, and what they are still worth

These were built while the hitch still looked unrelated to the bank bug, and
the reasoning was: the Z80 executes entirely out of the fixed 0x0000-0x1FFF
window -- 2,160 PC samples, 100% below 0x2000 -- so zeroed banks corrupt data
the driver reads, they do not send it off into a NOP field, and it keeps
servicing the command FIFO. True as far as it goes, and it missed the reply
direction; see the correction above.

The suspect at the time was 14.7: ch3 is the bottom of the SDRAM priority list,
and gameplay is when ch2/ch4 are busiest. A Z80 held off long enough stops
draining the 512-entry command FIFO, `snd_full` is a real flag now, and the 386
then spins in the sound handshake -- a freeze with no video symptom at all. On
the fixed core that is measured and small: worst single fetch 1.2 us, FIFO peak
14 of 511, never full. It is a live measurement of 14.7's concern rather than a
proof about the stall that has already gone.

Rather than guess, four high-water marks went into the build. **All four are
maxima, not counters**, because every existing counter here wraps between JTAG
samples and 13b and 14.9 both record being lied to by one:

* `fifo peak` -- deepest the 386 -> Z80 FIFO has ever got, of 511.
* `fifo full` -- longest unbroken FIFO-full run, in 1024-clk_sys (17.87 us)
  units. A quarter-second block reads about 13,974.
* `frame gap` -- longest gap between sprite DMA triggers, same units. The game
  loop pushes the sprite list once a frame, so one frame at 53.99 Hz is 1036
  units. This one is deliberately theory-free: it says whether the 386 stopped
  at all, whatever the cause, and the two above say whether sound is why.
* `fetch wait` -- longest single Z80 ROM fetch, in raw clk_sys cycles. This is
  the one that names ch3 starvation directly, and it is what `rom stalls` could
  never say: that counter counts misses and wraps, and does not measure how long
  any of them waited.

All four print from `tools/slop sound`, and `tools/slop clear` (CTRL bit 7)
re-arms them -- which is not optional, because boot alone puts 0.387 s into
`frame gap`. A fifth would be worth having if the hitch ever returns: nothing
here watches the 386 waiting on the Z80's REPLY at 0x684 d1, which is the
direction the correction above points at.

### The decoder is in the core, and the MRA chooses it (2026-08-09)

`rtl/spi_rom_decode.sv` sits between ioctl and the SDRAM writer in
`rom_loader`, so a part can be DECODED on the way in. It is the 386 routine at
0x2A1D20 transcribed: a 256 x 16 pair table, a 256-byte expansion stack, an
8-bit accumulator, an 18-state machine. Two M9Ks and a few hundred cells.

**The MRA picks the codec, not the RTL.** That was the point of doing it this
way: adding rfjet's codec later should not mean editing the loader. Index 1
grew from one mod byte into a config blob -- byte 0 is the mod byte as before,
and everything after it is a list of `{part index, codec id}` PAIRS:

    <rom index="1">
      <part>01</part>        mod byte: SXX2C
      <part>0E 01</part>     part 14 is CODEC_BPE_DPCM
    </rom>

Ids are in `rtl/spi_defs.vh` (0 = RAW, 1 = BPE_DPCM). Everything defaults to
RAW, so both existing MRAs are unchanged and behave identically. `make
check-mra` rejects a pair naming a part that does not exist, an id with no
decoder behind it, or a dangling byte -- nothing at runtime would.

**What actually changed in the loader.** A decoded part breaks the assumption
the whole module was built on, that one byte in is one byte out:

* `off` split into `in_off` (bytes ARRIVING -- what `part_size` means and what
  ends the part) and `out_off` (bytes EMITTED -- what the scatter addresses).
* a part ends when its input is spent AND the decoder has drained AND no write
  is in flight, not when a byte count is reached.
* emitting moved OUT of the `if (download)` arm. A decoded part is still
  expanding after the HPS drops `ioctl_download`, and those bytes are as real
  as the rest. `rom_ready` now waits for the drain too.
* a one-byte skid between ioctl and the decoder. The old loader consumed
  `ioctl_wr` in the cycle it arrived and SILENTLY DROPPED the byte if a write
  was in flight; `ioctl_wait` has a cycle of latency, so that only ever worked
  because the HPS is slower than the SDRAM. A decoded part stalls for hundreds
  of cycles.

One bug worth remembering, because it was silent and cost exactly one byte per
part boundary: the decoder's `start` pulse takes the reset arm, which does not
consume input, so `in_ready` has to close for that cycle. Otherwise the loader
hands over a byte that the decoder throws away. The symptom was 23,396,339
bytes written instead of 23,396,352 -- thirteen short, one per boundary.

**Verification.** Three levels, and the middle one is the one that matters:

* `make -C sim run-rom_decode` -- hand-written streams with hand-derived
  expected output, checking the RTL against the DISASSEMBLY rather than against
  another implementation. Covers the skip code, the unused-entry encoding
  (left byte == index, no right byte follows), LE block count vs BE block size,
  the stack walk, and DPCM wrapping across a block boundary.
* `make -C sim run-bpe ROMS=...` -- the real `sound1.u0222` through the RTL,
  compared against `tools/build_soundflash.py`, which is itself verified
  bit-for-bit against MAME's flash image. RTL == script == MAME. **312,933 in
  -> 471,277 out, exact, and it stops after exactly the right number of input
  bytes** -- reading one byte too many would misplace every following part.
  6.36 cycles per output byte, so rdft2's tail costs ~31 ms at clk_ram.
* `make -C sim run-rom_loader` -- a decoded part inside a real part table, to
  check the loader plumbing rather than the codec: 2 MB in, 2,363,022 out,
  every other part still exact, and `bytes_in`/`bytes_out` telemetry agreeing.

**What is still missing for rdft2 itself** is unchanged and is NOT this: a
third part table and MRA, `SPR_CHUNK_STRIDE` as a port, the tile-key select and
the RISE10 mux. The decoder is the piece that had no known answer; the rest is
known work.

Unrelated, found while running this: `make -C sim run-sdram` has not elaborated
since the 26-bit address widening (`ldr_addr` was still 25 bits). Widening it
lets the bench build, and it then fails its readback compare -- IDENTICALLY at
HEAD with the decoder reverted, 15,908,067 bytes differing either way, so that
is an older regression in the bench or the SDRAM model and not the loader.

### rdft2's part table and MRA (2026-08-09)

`mra/rdft2.mra` plus a third table in `rom_loader`. 34.0 MB, 35,621,036 bytes,
fourteen parts. `make check-mra` agrees with MAME's `ROM_START(rdft2)` on every
one: order, name, CRC, size, scatter mode and destination.

**Set selection grew a level.** The loader took `set_sxx2c`; it now takes
`set_id` (`SET_RDFTS` / `SET_RDFT` / `SET_RDFT2`). The mod byte keeps bit 0 as
the SXX2C board and adds bits 3:1 as the set WITHIN that board, so `rdft.mra`'s
existing `01` still means rdft and nothing shipped has to change. rdft2 sends
`03`; rfjet would be `05` and one more arm.

**What differs from rdft**, all read off the driver rather than assumed:

* 12 MB of tiles, so the second bg group sits at TILES + 6 MB, not + 3 MB
* the text lanes arrive in the order fix0(lane 1), fix1(lane 0), fixp(lane 2)
* 18 MB of sprites as three **6 MB** plane-pair chunks, and MAME's order is
  obj3, obj2, obj1 -- chunk 0 is obj3, not obj1
* the sample flash is two parts instead of one: a verbatim head, then the
  compressed tail marked `CODEC_BPE_DPCM` by the MRA

**The six sprite ROMs are one loader part.** At a 6 MB stride the three chunks
are contiguous from `SDR_SPRITES_BASE`, so one LINEAR run places all of them.
That is not an aesthetic choice: part indices and `part_end` are 4 bits, and
`part_end` is reported by bit position in `spi_jtag_peek`'s probe, which
`tools/jtag_peek.tcl` decodes. Nineteen parts would have meant widening both
and re-cutting the probe. Instead `check_mra` learned to walk a multi-element
part's members and match each against the next MAME ROM, so all six are still
checked individually -- better coverage than before, since rdft's synthesised
part was previously unexamined too.

**The MRA's own slices rebuild the verified flash image.** With `--zip`,
`check_mra` now reconstructs the 2 MB image the way the loader will -- head
part copied, tail part run through the same decoder `build_soundflash.py` uses
-- and compares its sha256 against the image MAME's flash devices hold. This is
the only thing tying `offset="0x000004"`, `length="0x17C243"` and
`length="0x04C665"` to reality; every one of them is off-by-one-able and silent.
Perturbing each by one byte, and the RTL's tail base by one, was tried: all four
are caught.

**One bug this turned up, in the checker rather than the core.** `check_mra`
read the MRA as text and its `<rom index="1">` regex was matching the EXAMPLE
inside a documentation comment, so it reported a codec on rdft that exists only
in prose. Main_MiSTer uses a real XML parser and ignores comments, so the
hardware was never affected -- but a checker reading a different file than the
hardware is worse than no checker. It strips comments first now.

**Still missing for rdft2 to actually run**, and the MRA says so at the top:
`SPR_CHUNK_STRIDE` as a port on `spi_sprite` (it fetches at the 4 MB SEI252
constant; the loader already lays rdft2 out at 6 MB), the RISE10 mux in the
sprite fetch, and the rdft2 tile keys in `spi_layers`. All three are known work
against verified units -- `spi_rise10_decrypt.sv` and the keys already exist and
are checked against MAME. The loading is done.

### The sprite stride port and the RISE10 mux (2026-08-09)

`spi_sprite` took the chunk stride from a constant and instantiated the SEI252
crypt unconditionally. It now takes `spr_chunk_stride` and `rise10` as ports,
and `spi_top` derives both from `set_id`: 6 MB and RISE10 for rdft2, 4 MB and
SEI252 for everything else. The two are separate ports rather than one flag
because rdft2us pairs RISE10 with a different board.

The chunk base is a three-way mux rather than `chunk * stride` -- chunk is only
ever 0, 1 or 2, and a 26-bit multiplier for that would be silly.

**sprite_reorder went into the LOADER, not the fetch.** This is the one real
design decision here, and it goes against the project's own rule that graphics
decryption happens at fetch time (section 5). The rule still holds, because
`sprite_reorder` is not decryption -- it is an address swizzle. Inside each
64-byte group MAME's reorder sends input word j to output word 2j and input
word j+16 to output word 2j+1, which as an index is one rotate:

    dest = base + { i[25:6], i[4:1], i[5], i[0] }        (M_SPR_R10)

Doing it in the loader is FREE: the loader already computes a destination for
every byte, so this is a wire permutation. Doing it at fetch time is not free.
It would put the two halves of a 16-pixel row 32 bytes apart instead of 2, so a
row would need six SDRAM reads instead of three -- doubling sprite bandwidth on
the set that already carries the most sprite data, and section 3.3's starvation
budget is not built for that.

The formula is checked against MAME's own `sprite_reorder()` (out of
`spi_ref.h`) over all 64 bytes of a group before the loader test trusts it for
18 MB. `check_mra` needed a per-set override for it -- MAME's macro is a plain
`ROM_LOAD`, so nothing in the driver says the mode should be `M_SPR_R10`.

**Regression evidence.** `make -C sim run-video` still reports the rdfts frame
matching MAME **exactly, 0 of 76,800 pixels differing**, with both crypt units
now instantiated and the stride arriving through a port. That is the test that
would catch a broken sprite path, and it is unchanged.

**Not verified: rdft2's sprites on screen.** There is no rdft2 golden capture,
and a frame compare would fail anyway while the tile and text layers still use
the SEI252 keys. What IS verified is every piece the fetch depends on: the
RISE10 arithmetic against MAME (2048 words), the reorder split, the 6 MB layout
the loader produces, and that muxing the units changed nothing for rdfts.

**What is left for rdft2** is now one item: the tile and text keys.
`spi_layers` hardwires the SEI252 triple; `TKEY*_RDFT2` are defined in
spi_defs.vh and all three key sets are already verified against MAME.

### The tile keys, and the fore-layer base that came with them (2026-08-10)

`spi_layers` hardwired `TKEY*_SEI252`. It now takes `tkey1/2/3` as ports and
`spi_top` picks the triple from `set_id`. One triple covers both layers: MAME's
`text_decrypt` and `bg_decrypt` take the same three constants, and
`rdft2_text_decrypt` / `rdft2_bg_decrypt` are those same functions with
0x823146 / 0x4DE2F8 / 0x157ADC. `spi_tile_decrypt` already took keys as inputs
and all three sets are already checked against MAME (73,728 vectors), so this
is a selection, not new arithmetic.

**A second per-set difference turned up while wiring it, and it is not cosmetic.**
`m_bg_fore_layer_position` (seibuspi_v.cpp:585) follows the SIZE of the tile
region, not the game: 0x2000 up to 3 MB, 0x4000 up to 6 MB, **0x8000 beyond**.
Every set until now has exactly 6 MB of tiles, so 0x4000 was hardcoded and the
tile code was 15 bits wide -- which cannot hold 0x8000 at all. rdft2 has 12 MB,
0x10000 tiles, and needs the 16th bit.

So `tcode` is 16 bits, `bg_fore_pos` is 16 bits and selected per set, and the
`tile_off = tcode * 0xC0` terms widened with it. Nothing else moved: the back
and midl d14 bits are still 0x4000 whatever the set, `dec_tileno` is still
`tcode[11:0]` (which is the code within its 0xC0000 decrypt block, and stays
right for 16 blocks as it was for 8), and `char_off` still uses twelve bits.

Left alone, rdft2's fore layer would have indexed the wrong half of a 12 MB
tile ROM, with correct keys. Worth knowing that the two are coupled.

**Regression evidence.** `make -C sim run-video` still has the rdfts frame
matching MAME exactly, 0 of 76,800 pixels, with the keys arriving through ports
and the tile code a bit wider.

**rdft2 is now wired end to end, and still unverified end to end.** Every
per-set difference findable in the driver is selected -- part table, sample
flash codec, sprite stride, sprite crypt, sprite reorder, tile and text keys,
fore base. What does not exist is an rdft2 golden capture, so nothing has
compared an rdft2 frame against MAME. That is the next thing worth doing and it
is a real piece of work, not a formality: `tools/build_sdram_image.py` needs
rdft2's layout (including M_SPR_R10 and the derived flash) before
`make capture` can produce a reference to compare against.

Unrelated rot noted while running the benches: `sim/tb_boot_top.sv` is 19 pins
behind `spi_top` -- the whole SXX2C Z80 and sound plumbing -- so `run-boot` has
not elaborated for some time. Its 25-bit address declarations are widened here
because they are the same debt as tb_sdram_top's, but reconnecting it needs
models for the Z80 SDRAM read and download ports and is its own change. It is
not in `make verify`.

### rdft2 verified against MAME frame by frame (2026-08-10)

Ten scenes, ten exact matches. `tools/build_sdram_image.py` learned rdft2's
layout, `mame_capture.lua` lost its rdfts-only assumptions, and the video bench
takes its per-set parameters from the capture instead of constants.

| scene            | sprite pens | result                                    |
|------------------|-------------|-------------------------------------------|
| 600 story        | 208         | exact                                      |
| 1800 intro       | 240         | exact **after the fix below**              |
| 2700             | 0           | exact                                      |
| 3600             | 48          | exact                                      |
| 4500 title       | 336         | exact                                      |
| 5400 demo play   | 976         | 377 px, sprite STARVATION -- see below     |
| 6300/7200/8100/9000 | 368/464/224/128 | exact                              |

**The bug it found: rdft2 needs a 17th sprite tile-code bit.** MAME's
`gfxbank_callback` (seibuspi_v.cpp:370) ORs 0x10000 into the code when the
sprite gfx has more than 0x10000 elements AND word 2 bit 12 of the sprite entry
is set. Elements is the chunk size over 64, so the SEI252 sets sit at exactly
0x10000 and it never fires -- `spi_sprite.sv` said as much in a comment and did
not implement it. rdft2's 6 MB chunks hold 0x18000, and the intro cinematic
draws from the top half of the sprite ROM: the left of the frame was perfect and
the right was confetti, 24.8% of pixels, all of them sprite pens.

`tile_code` is 17 bits now and the bank bit is `ext & (spr_chunk_stride >
4 MB)` -- MAME's own condition rather than a per-set flag, so the two cannot
disagree. rdfts is unaffected and still matches exactly.

**Frame 5400 is not a decode failure.** 976 of 976 sprite pens decode
correctly; the frame differs by 0.49% because **9 lines ended with sprites
unscanned**. Re-run with `SLOP_BUS_FREE=1`, which gives the sprite engine
unlimited SDRAM bandwidth, and it matches exactly with 0 starved. So this is
the sprite budget from section 3.3 meeting the densest scene tested yet --
12,981 y-hits against rdfts's 9,995 -- and not anything rdft2-specific. It is
also NOT the reorder: that lives in the loader, so an rdft2 row still costs
three SDRAM reads, the same as SEI252.

**A second broken thing, found by using it.** The bench's sprite-pixel check
read the sprite ROM from `0x0A80000`, where sprites lived before the map was
re-laid for the 26-bit widening. It had been comparing against tile data and
printing mismatches nobody read. Pointed at `SDR_SPRITES_BASE` it passes 640 of
640 for rdfts, and for rdft2 it un-does the loader's reorder before calling
MAME's RISE10 decryptor -- which reorders at the end, so applying it to an
already-reordered image would permute twice.

**Reproducing.** `make capture` takes `GAME` now:

    make capture GAME=rdft2 FRAME=4500 ROMS=<patched> NVRAM=<flashed> \
         CAP=/tmp/cap_rdft2 SDRAM=/tmp/sdram_rdft2.bin
    make run-video CAP=/tmp/cap_rdft2 SDRAM=/tmp/sdram_rdft2.bin

rdft2 needs a rompath whose `rdft2.zip` carries the three PAL placeholders, and
an already-flashed `-nvram_directory` or the first boot spends ~420 emulated
seconds reflashing. Two traps worth keeping: `SECONDS` must cover `FRAME` at
53.99 Hz and not 60, or the capture silently never happens and the directory is
just empty; and the capture now writes its set name into `regs.txt`, so the
bench cannot be pointed at an rdft2 capture with rdfts's keys.

### Sprite starvation: measured, then eliminated by interleaving (2026-08-10)

The one scene that did not match, rdft2 frame 5400, is down from **377 wrong
pixels to 133** (0.49% -> 0.17%). Everything else still matches exactly. The
remaining gap is real and this records what it actually is, because the first
thing this needed was numbers rather than a theory.

**What the busiest line is doing**, per line per frame, from the new per-line
accounting in `sim/tb_video.cpp`:

    L139  263 sprite reqs   705 stall cycles   165 gfx reqs   512 scanned   60 y-hits
    L144  252 sprite reqs   776 stall cycles   174 gfx reqs   512 scanned   59 y-hits  STARVED

Two things fall out of that. The scanner is NOT the limit -- all 512 entries are
walked on every one of these lines, so the FIFO split from earlier did its job.
And the bus is at about 72% utilisation ((263+165) x 6 cycles against a 3584
cycle line), with sprites losing ~750 cycles a line waiting behind the tiles.

**The arbiter is worse than the testbench models.** `sdram.sv`'s STATE_IDLE is
fixed priority: ch2 (tiles) > ch1 (the 386's own fetches) > ch4 (sprites) > ch5
(PCM) > ch3. `tb_video.cpp` models only tiles ahead of sprites, so it is
OPTIMISTIC -- on hardware sprites also queue behind the CPU. Worth knowing
before trusting any margin measured here.

**What was fixed.** A column is three SDRAM round trips and the fetcher stepped
through an `F_REQ` state before each one, so every round trip carried a dead
cycle. The next chunk's address differs only in its base, so it is available on
the ack cycle: `F_REQ` is gone and requests chain straight out of `F_WAIT`.
That is ~4 cycles a column, ~340 of a 3200-cycle budget on a dense line, and it
is what took 377 down to 133.

**What was tried and reverted, and did not turn out to be needed.** The
320-cycle clear pass at the top of every
line is 10% of the budget, and the standard way to remove it is a generation
tag: give each line-buffer entry the bank's tag, flip the tag when the bank is
re-rendered, treat a mismatch as invalid. Implemented, it lost every sprite on
both sets -- and lost them identically whether the tag was compared, bypassed,
or forced to always fail, which says the write side was wrong rather than the
compare. Rather than ship a half-debugged line buffer it is reverted. The idea
is still right and the measurement says it is worth 10%; whoever picks it up
should start by proving `bank_tag` actually toggles, which is the step this ran
out of road on.

**The structural fix, and why it was not taken.** Three round trips per column
exist because the three plane-pair chunks are megabytes apart. Interleaving them
at load time so a tile row's 12 bytes are contiguous makes it TWO reads always
-- 12 bytes from a 4-or-8 aligned start never spans three 8-byte reads -- a 33%
cut in sprite bus demand that would relieve the tile layers too. The loader can
do the permutation for free, exactly as it already does sprite_reorder. The
blocker is part indices: rdft2's sprites are one part only because they are
contiguous, and interleaving needs one part per chunk, which puts the table at
16. `part` and `part_end` are 4 bits and `part_end` is decoded by bit position
in `tools/jtag_peek.tcl`, so it is a wider change than it looks.

**Then the interleave, and starvation is gone.** All ten rdft2 scenes and rdfts
now match MAME exactly with **0 starved lines**, including a scene at 16,572
y-hits -- denser than the 12,981 one that used to fail.

The three plane-pair chunks used to sit megabytes apart, so a 16-pixel row cost
three round trips. `rom_loader` now interleaves them:

    dest = sprites_base + 2k + tile*192 + row*12 + half*6 + byte

A tile becomes 192 contiguous bytes holding c0.w0 c1.w0 c2.w0 c0.w1 c1.w1 c2.w1
per row, and twelve bytes from a 4- or 8-aligned start never span more than two
8-byte reads -- so a row costs TWO. Measured on the worst line: **263 sprite
requests down to 184 (-30%)**, stall cycles 705 down to ~535.

Three things made this cheap where it looked expensive:

* **The chunk index folds into the part BASE**, as +0/+2/+4, so no new table
  field is needed -- the three chunks' words simply alternate.
* **It composes with sprite_reorder.** Both are permutations inside one 64-byte
  group, which is one tile, so `M_SPR_ILV_R` applies the reorder to the source
  index and then the interleave. rdft2 needs both; the fetch sees neither.
* **The fetch got simpler, not harder.** No chunk base mux, no per-chunk data
  mux -- two reads joined into 96 bits and sliced six ways. `spr_chunk_stride`
  is gone; what remains is `spr_chunk_size`, kept only because MAME's
  extra-bank rule counts tiles with it.

The cost was the part index. rdft2's sprites had to become one part per chunk,
which puts its table at 16, so `part`, `part_end`, `NPARTS_*` and the codec
vector all widened -- and `spi_jtag_peek`'s probe with them. Its TCL decoder was
re-derived rather than patched, because it was ALREADY wrong twice over: it read
`bytes_in` as 25 bits after the map went to 26, and `part_end` as 4 bits. Every
field after a widened one moves, so the whole offset list is now written out
with the widths beside it.

**What is checked.** `tb_rom_loader` proves `M_SPR_ILV_R` is MAME's own
`sprite_reorder` composed with the interleave (by inverting the interleave to
isolate the permutation), that three chunks pack into 192 bytes with no
collision, and that no row spans three reads. `tb_video`'s sprite reference
de-interleaves the SDRAM image before handing it to MAME's decryptor, so a wrong
split would show up as wrong pixels rather than passing quietly.

**The clear pass is still there.** The generation-tag attempt above stays
reverted and stays worth ~10%, but nothing needs it now.

### The authentic flash path is still the general answer

The codec being cracked weakens this argument but does not kill it. rdft's
payload was a plain concatenation, rdft2's needed a BPE+DPCM decoder and a
job-table read out of its program image, and rfjet's job table has not been
looked at yet. Derivation now costs an hour per game rather than a session, but
it is still per game, and each one adds a derived artefact the MRA cannot
produce on its own.

The authentic path costs nothing per game and works for every cartridge title:

* **The write side of the wave memory port already exists.** 0x14-0x17 decode
  the address and the direction bit, and 0x17 pre-increments; writes currently
  go nowhere because SXX2E's sample memory is a mask ROM. Section 14.5.
* What is missing is the **E28F008SA command state machine** (Read Array FF,
  Block Erase 20/D0, Byte Program 40 + datum, status polling with the direction
  bit flipped between steps), a **writable ch5** with the sample line cache
  invalidated on write, and **save-file persistence** so the several-minute
  reflash happens once rather than every boot.
* The ch3 write arbiter built for the Z80 download (`spi_sdr_arb3`) is the
  pattern to copy for ch5.

Then rdft, rdft2, rfjet, senkyu, viprp1 and ejanhs all work from stock MRAs
with no derived images, and `mra/rdft.mra`'s pre-flashed trick stays as a
fast-boot option for the one game where it happens to be derivable.

### What else `seibuspi.cpp` covers, and what each would cost

Seven distinct titles across five board types. Everything below is read off the
driver, not remembered; sizes are the sum of the set's `ROM_REGION`s.

| Board  | Parent sets                                   | Sprite crypt          | Sound                        | Backup | 386      | Largest set |
|--------|-----------------------------------------------|-----------------------|------------------------------|--------|----------|-------------|
| SXX2E  | `rdfts`                                        | SEI252                | Z80 + YMF271 @16.9344        | DS2404 | 25 MHz   | 22.4 MB     |
| SXX2F  | `rdft2us`                                      | RISE10                | Z80 + YMF271 @16.9344        | 93C46  | 25 MHz   | 34.9 MB     |
| SXX2G  | `rfjets`, `rfjetsa`                            | RISE11                | Z80 + YMF271 **@16.384**     | 93C46  | 28.6 MHz | 37.9 MB     |
| SXX2C  | `senkyu`, `viprp1`, `ejanhs`, `rdft`, `rdft2`, `rfjet` | SEI252 / RISE10 / RISE11 | Z80-in-RAM + YMF271 on flash | DS2404 | 25 MHz   | 46.4 MB     |
| SYS386I| `rdft22kc`, `rfjet2kc`                         | RISE10 / RISE11       | **2x OKIM6295**, no Z80      | 93C46  | 40 MHz   | 39.2 MB     |
| SYS386F| `ejsakura`, `ejsakura12`                       | none (word reorder)   | **YMZ280B**, no Z80          | 93C46  | 25 MHz   | 34.0 MB     |

**Two costs recur, and they are independent of each other:** a new sprite
decryption per chip family, and SDRAM capacity. Only `rdfts` (22.4 MB),
`senkyu` (28.4) and `viprp1` / `ejanhs` / `rdft` (31.4 each) fit a 32 MB module.
Everything else needs 64 MB or more. `sdram.sv` already routes addr[25] (A[9]
on 1024-column parts) and addr[26] (second chip), so that is a board
requirement, not an RTL redesign — but it does mean the bigger sets cannot ride
along as an MRA config bit on a build 32 MB users can run.

**SXX2F / SXX2G are the closest siblings.** Same `base_video`, same CRTC, same
tilemaps, same Z80 + YMF271 topology, same 386 core. What actually differs:

* **RISE10 / RISE11 sprite decryption** — different algorithms, not different
  keys, and they are NOT the same difficulty. Both apply `sprite_reorder`,
  which permutes words inside 64-byte groups -- output word 2j from input word
  j, output word 2j+1 from input word j+16 -- so for on-the-fly decode that is
  an address swizzle at fetch rather than a pass over ROM.

  **RISE10 is address-independent and is DONE** (`rtl/spi_rise10_decrypt.sv`,
  2026-08-09). One fixed `bitswap<32>` and two partial-carry sums whose every
  operand is a constant: no `key_table[addr]`, no per-tile key fetch, no
  `addr` input at all. It is a drop-in for `spi_spr_decrypt` -- MAME writes
  both back as chunk0={plane5,plane4}, chunk1={plane3,plane2},
  chunk2={plane1,plane0}, so the same pen convention applies. Verified against
  MAME over 2048 words including `sprite_reorder`; constants parsed by
  `tools/gen_rise10_tables.py` while the reference is copied by
  `tools/gen_ref_c.py`, the same two-path arrangement the SEI252 tables use.

  **RISE11 is NOT address-independent.** This section used to claim both were,
  and that is wrong: `plane210 = partial_carry_sum24(plane210, i, k4) ^ k5`
  takes the word index `i` as its addend. It still needs no lookup tables --
  cheaper than SEI252 in that respect -- but the fetch has to supply `i`, so it
  is a different unit with a different interface. It is also parameterised by
  five keys and shared with `feversoc` in another driver, so take the keys as
  inputs the way `spi_tile_decrypt` does.
* **Tile and char decryption come free.** `spi_tile_decrypt` takes key1/key2/key3
  as inputs and `tb_tile_decrypt` already proves all three triples (rdft,
  rdft2, rfjet) against MAME. Wire the keys to a config bit.
* **Register moves:** sprite DMA trigger 0x50e -> 0x562 (`sei252_map` vs
  `rise_map`), and 0x68e changes from `rf2_layer_bank_w` to
  `spi_layerbanks_eeprom_w`.
* **93C46 EEPROM** replaces the DS2404 we stub at 0x6D0-0x6DD.
* **SXX2G clocks.** The YMF271 runs at **16.384 MHz**, so the sample rate is
  42666.7 Hz and every envelope and LFO table scales by 16.9344/16.384 — MAME's
  `clock_correction`, which the generator currently assumes is exactly 1.0 (see
  14.5). The Z80 drops to 4.9152 MHz, which is not an integer divisor of
  clk_sys (57.2727/4.9152 = 11.65) and needs a fractional CE. Note MAME's
  source literal says `4.9512_MHz_XTAL` while its own comment says 4.9152;
  4.9152 is the real part and the literal looks like a transposition.

**SXX2C is gated on flash, as above, plus two things.** The Z80's 256 KB is
*RAM*, written a byte at a time by the 386 through port 0x688 and released from
reset by 0x68c, so Z80 code stops being a read-only SDRAM region with a line
buffer and needs a write path. There is also a second FIFO in the Z80->386
direction (the one that is a `nullptr` on our board), a jumpers port at 0x400a,
and the DS2404 becomes real rather than stubbed. `senkyu` / `viprp1` / `ejanhs`
at least use SEI252, so the existing sprite decrypt covers them, and they fit
32 MB. `ejanhs` additionally wants mahjong inputs and disables the alpha table.

**SYS386I is our video with a sound chip we do not have.** Identical tilemap
video and region structure; the entire Z80 + YMF271 subsystem is replaced by two
OKIM6295s at 28.63636/20 = 1.432 MHz with a bank register at 0x68f. So: delete
the sound half, write an OKI6295, add the RISE decrypt and the EEPROM.

**SYS386F is effectively a different core** and is not worth folding in. No
tilemaps at all, sprites only, **8bpp instead of 6bpp** with an 8192-entry
palette, its own 57.59 Hz / 40x30 screen timing, a YMZ280B, and a different
memory map. It shares the 386 and the sprite chip family and little else.

**Nothing on this list disturbs the parts that were hardest to get right** — the
386, the CRTC, the tilemap and sprite renderers, the SDRAM arbiter, or (for
SXX2F) the sound chip. Best reach for least work is `rdft2us`: one new decrypt
unit, an EEPROM and two register moves, on the same YMF271 at the same clock —
if a 64 MB module is acceptable. To stay on 32 MB the SXX2C games are the only
option, and they cost flash emulation and the Z80 download path.

---

## 1. Hardware inventory (from `mame/src/mame/seibu/seibuspi*.cpp`)

| Block            | Part                        | Clock                          |
|------------------|-----------------------------|--------------------------------|
| Main CPU         | AMD/Intel 386DX             | 25 MHz (50 MHz XTAL / 2)       |
| Sound CPU        | Z80 (Z84C0008)              | 7.15909 MHz (28.63636 / 4)     |
| Sound            | Yamaha YMF271-F "OPX"       | 16.9344 MHz                    |
| Video CRTC       | Seibu custom (SEI0160?)     | —                              |
| Sprites          | SEI252                      | —                              |
| Pixel clock      |                             | 7.159090 MHz (28.63636 / 4)    |
| RTC              | Dallas DS2404               | 32.768 kHz                     |

### Video timing (`seibuspi.cpp:898`)

```
PIXEL_CLOCK = 28.636363 MHz / 4 = 7.1590909 MHz
HTOTAL 448   HBEND 0   HBSTART 320
VTOTAL 296   VBEND 0   VBSTART 240   (real VBSTART is 253, 240 lines visible)
=> 7159090 / (448*296) = 53.99 Hz
```

Visible 320x240, **ROT270** (vertical monitor, rotated clockwise... `ROT270`).

### Interrupts

`INTERRUPT_GEN` on vblank: `set_input_line(0, HOLD_LINE)`.
`IRQ_CALLBACK` always returns vector **0x20**. There is no PIC — the interrupt
acknowledge cycle just returns 0x20. "where is ack?" — MAME uses HOLD_LINE, so the
line is cleared by the CPU's own ack. We do the same: latch on vblank rising, clear
on INTA.

### ROM set `rdfts`

| MAME region | Size      | Contents                                                     |
|-------------|-----------|--------------------------------------------------------------|
| `maincpu`   | 0x200000  | `seibu_1.u0259` (b0), `raiden-f_prg2.u0258` (b1), `raiden-f_prg34.u0262` (32-bit word → b2,b3) |
| `audiocpu`  | 0x40000   | `seibu_zprg.u1139` 0x20000 (region padded to 256 KB for 8×32 KB banks) |
| `chars`     | 0x30000   | `raiden-f_fix.u0535` 0x20000 (LOAD24_WORD → b0,b1), `seibu_fix2.u0528` 0x10000 (LOAD24_BYTE → b2) |
| `tiles`     | 0x600000  | bg1-d 0x200000 @0 (WORD→b0,b1), bg1-p 0x100000 @2 (BYTE→b2), bg2-d @0x300000, bg2-p @0x300002 |
| `sprites`   | 0xC00000  | obj-1/2/3, 0x400000 each — **three plane-pair chunks**, not a linear region |
| `ymf`       | 0x200000  | `raiden-f_pcm2.u0975` (SOUND1 socket unpopulated)             |

`ROM_LOAD24_WORD(f, off, len)` = 16-bit ROM scattered into bytes {0,1} of each
3-byte group starting at `off`. `ROM_LOAD24_BYTE(f, off, len)` = 8-bit ROM scattered
into every 3rd byte starting at `off`. The ROM loader does this scatter in hardware
(see §4) because MRA `<interleave>` cannot express a 3-byte period.

---

## 2. 386 memory map (`sxx2e_map`, `seibuspi.cpp:1004,1077`)

```
0000_0000 - 0003_FFFF  main RAM (256 KB, 32-bit)      <- I/O below overlays it
  0000_0400 - 0000_043F  Seibu CRTC (16-bit regs)
  0000_0480              tilemap DMA start (w)
  0000_0484              palette DMA start (w)
  0000_0490              video DMA length (w)
  0000_0494              video DMA address (w)
  0000_0498              dma address high bits (w, always 0)
  0000_054C              RISE10/11 sprite decrypt key (w, ignored)
  0000_0562              sprite DMA start (w, 16-bit)
  0000_0600              spi_status_r (r) -> always 0x01
  0000_0604              INPUTS  (32-bit, active low)
  0000_0608              EXCH    (32-bit, active low, unused -> 0xFFFFFFFF)
  0000_060C              SYSTEM  (32-bit, active low)
  0000_0680              r: sb_coin_r (coin latch, read-clears)
                         w: sound FIFO (386 -> Z80) data
  0000_0684              r: sound fifo status: d0 = fifo0 full, d1 = fifo1 empty
  0000_0688 - 0000_068B  no-op
  0000_068C - 0000_068F  no-op (write)
  0000_06D0              DS2404 1-wire reset (w)
  0000_06D4              DS2404 data (w)
  0000_06D8              DS2404 clk (w)
  0000_06DC              DS2404 data (r)
  0000_06DD              spi_ds2404_unknown_r (r) -> 0x00 (game waits for clear)
0020_0000 - 003F_FFFF  PRG ROM (2 MB)
FFE0_0000 - FFFF_FFFF  PRG ROM mirror (real-mode reset vector)
```

Note the SEI252 sprite chip's decrypt-key writes at 0x524/0x528/0x530/0x534/0x53C
are `nopw` in MAME — the keys are hardwired constants in the decryption tables, so
we ignore those writes too (see §5.4).

### Seibu CRTC registers (`seibu_crtc.cpp`, 16-bit at 0x400 + reg)

```
0x14  tile decrypt key (ignored — keys are constants)
0x1a  layer_bank:  bit15 = rowscroll enable, bit11 = fore layer d13
0x1c  layer_enable: 0=on 1=off
        bit0 back  bit1 middle  bit2 fore  bit3 text  bit4 sprite
0x20  back scroll X   0x22  back scroll Y
0x24  midl scroll X   0x26  midl scroll Y
0x28  fore scroll X   0x2a  fore scroll Y
0x2c-0x3b  layer scroll base (unused by SPI driver)
```

### Z80 map (`sxx2e_soundmap`, `seibuspi.cpp:1171`)

```
0000-1FFF  ROM (bank 0 of the Z80 ROM region)
2000-3FFF  RAM (8 KB)
4002,4003  nop write
4004       coin latch write (spi_coin_w)
4008       r: FIFO (386 -> Z80) data     w: nop
4009       r: FIFO status for Z80
400B       nop write
4013       r: COIN port
401B       w: ROM bank select
6000-600F  YMF271 (r/w)
8000-FFFF  banked ROM (8 x 32 KB windows into the 256 KB region)
```

`spi_coin_w`: d0/d1 rising edge latches COIN bits into `m_sb_coin_latch`, which the
386 reads at 0x680. YMF271 IRQ -> Z80 INT, `audio_vector_r` supplies the vector.

### Inputs (`sxx2e` ports)

`INPUTS` (0x604), active low:
```
b0-3  P1 up/down/left/right    b4-6  P1 button 1/2/3    b7 unused
b8-11 P2 up/down/left/right    b12-14 P2 button 1/2/3
b15   flip screen dip (SW1:1)
```
`SYSTEM` (0x60C), active low: b0 start1, b1 start2, b2 service mode, b3 service coin.
`COIN` (Z80 0x4013), active low: b0 coin1, b1 coin2.

---

## 3. Video architecture

### 3.1 DMA engines

All video state lives in 386 main RAM and is copied to dedicated video RAMs by
three DMA triggers. `video_dma_address` (0x494) and `video_dma_length` (0x490) are
set first; length is in units of `(len+1)*2` bytes.

* **tilemap DMA** (0x480) — copies `0x2800` bytes (no rowscroll) or `0x4000` bytes
  (rowscroll) into a 16 KB tilemap RAM, in this source order:
  `back(0x800)`, `[back rowscroll(0x800)]`, `fore(0x800)`, `[fore rowscroll]`,
  `midl(0x800)`, `[midl rowscroll]`, `text(0x1000)`.

  Destination layout inside the 16 KB tilemap RAM (byte offsets):
  | region        | rowscroll off | rowscroll on |
  |---------------|---------------|--------------|
  | back tiles    | 0x0000        | 0x0000       |
  | back rowscroll| —             | 0x0800       |
  | fore tiles    | 0x0800        | 0x1000       |
  | midl rowscroll| —             | 0x1800       |
  | midl tiles    | 0x1000        | 0x2000       |
  | fore rowscroll| —             | 0x2800       |
  | text tiles    | 0x1800        | 0x3000       |

  (Yes, the rowscroll destinations are interleaved oddly — that is what
  `seibuspi_v.cpp:238` does. Rowscroll tables are read back at 0x800 / 0x1800 /
  0x2800 for back / midl / fore respectively.)

* **palette DMA** (0x484) — copies `(len+1)*2` bytes into 12 KB palette RAM.
  Each 32-bit word holds two BGR555 colours: pens `2i` = bits [14:0],
  pen `2i+1` = bits [30:16]. Channel order in the word is R[4:0] G[9:5] B[14:10]
  (`pal5bit(x>>0)` = R, `>>5` = G, `>>10` = B).

* **sprite DMA** (0x562, 16-bit write) — copies 0x1000 bytes into sprite RAM
  (512 sprites × 8 bytes).

### 3.2 Layers

| Layer | Size        | Tile   | Scan   | bpp | GFX   | Palette base            | Trans pen |
|-------|-------------|--------|--------|-----|-------|-------------------------|-----------|
| back  | 32×32 tiles | 16×16  | COLS   | 6   | tiles | 4096 + colour*64        | 63        |
| midl  | 32×32       | 16×16  | COLS   | 6   | tiles | 4096 + (colour+16)*64   | 63        |
| fore  | 32×32       | 16×16  | COLS   | 6   | tiles | 4096 + (colour+8)*64    | 63        |
| text  | 64×32       | 8×8    | ROWS   | 5   | chars | 5632 + colour*32        | 31        |

`TILEMAP_SCAN_COLS` for the 16×16 layers means tile index = `col*32 + row`
(column-major), 512×512 px wrapping. Text is row-major, 512×256.

Two tiles per 32-bit tilemap RAM word; even tile index = low half.

Tile word decode:
```
back: code = w & 0x1FFF | back_d14        colour = (w>>13)&7
midl: code = w & 0x1FFF | 0x2000 | midl_d14   colour = (w>>13)&7, +16
fore: code = w & 0x1FFF | bg_fore_position | fore_d13 | fore_d14
                                          colour = (w>>13)&7, +8
text: code = w & 0x0FFF                   colour = (w>>12)&0xF
```
where (`seibuspi_v.cpp:149`):
```
fore_d13 = (layer_bank << 2) & 0x2000            // CRTC 0x1a bit 11
back_d14 = (rf2_layer_bank << 14) & 0x4000       // 0x68E bit 0 — SXX2E: not written
midl_d14 = (rf2_layer_bank << 13) & 0x4000       // 0x68E bit 1
fore_d14 = (rf2_layer_bank << 12) & 0x4000       // 0x68E bit 2
bg_fore_position = 0x2000 if tiles<=3MB, 0x4000 if <=6MB, else 0x8000
                 = 0x4000 for rdfts (tiles region is exactly 0x600000)
```
On SXX2E `0x68E` is a no-op, so `rf2_layer_bank` stays 0 — but keep the register
so SXX2F/`rdft2` works later.

### 3.3 Sprites (SEI252, 8 bytes each, 512 entries)

```
+0  b15    flip Y
    b14-12 height-1 (tiles)
    b11    flip X
    b10-8  width-1 (tiles)
    b7-6   priority (0..3)
    b5-0   colour
+2  tile code (16 bit)
+4  b12    extra bank bit -> code |= 0x10000 when the gfx region has >0x10000 tiles
    b8-0   X position (9 bit, >=0x180 => -0x200)
+6  b8-0   Y position (same wrap)
```
`code == 0` (mod element count) is skipped. Sprites are drawn **last entry first**,
so **entry 0 is topmost**. All sprites render into one 16-bit buffer holding
`{pri[1:0], colour[5:0], pixel[5:0]}` with 0xFFFF = empty; the mixer then composites
that buffer four times, once per priority value. That means sprite-vs-sprite
occlusion is purely list order, and a low-priority sprite pixel can be *erased* by a
high-index sprite of a different priority. We reproduce this exactly.

### 3.4 Mixing order (`screen_update_spi`, `seibuspi_v.cpp:434`)

```
if back disabled: fill 0
else:             back layer, OPAQUE
sprite pri 0
if (back && fore && text all enabled...) : actually  if ((layer_enable & 0x15)==0)
                  back layer again, TRANSPARENT      // draws back over sprite pri 0
if fore enabled:  sprite pri 1
if midl enabled:  midl layer
if fore disabled: sprite pri 1
sprite pri 2
if fore enabled:  fore layer
sprite pri 3
if text enabled:  text layer
```
Note `(m_layer_enable & 0x15) == 0` means back+fore+sprite all enabled.

Alpha blending: a 8192-entry table indexed by final palette pen; where set, the
pixel is blended 50/50 with what is already in the framebuffer
(`alpha_blend_r32(dest, pen, 0x7f)`). MAME's table is a hand-tuned approximation
(`seibuspi_v.cpp:603`); we bake the same table into a small ROM:
```
sprites: [0x730,0x740) [0x780,0x7A0) [0xFC0,0x1000)
fore:    [0x1360,0x1380) [0x13B0,0x13C0) [0x13F0,0x1400)
midl:    [0x15B0,0x15C0) [0x15F0,0x1600)
text:    [0x1770,0x1780) [0x17F0,0x1800)
```

### 3.5 Row scroll

When `layer_bank` bit 15 is set, back/midl/fore each get a 0x800-byte table of
16-bit signed X offsets, indexed `(y + 19) & 511`, added to the layer's X scroll.

---

## 4. ROM loading and SDRAM map

**64 MB SDRAM module required as of 2026-08-09** (32 MB fits only the SEI252
sets). The core's addresses are 26 bits; they were 25, and the controller's are
27, which produced five WIDTHEXPAND warnings that looked cosmetic and were
actually the 32 MB ceiling -- `rdft2` pre-flashed is 34.4 MB and could not be
addressed at all. The extension to 27 is explicit at the `sdram` instantiation
now, so `make -C sim lint-top` is clean and a future width mistake will show up
instead of hiding among known warnings.

One map serves every set, sized for the worst case in the family rather than
for `rdfts`: 12 MB of tiles (rdft2) and 24 MB of sprites (rfjet). A set needing
less leaves the tail unwritten.

    0x0000000   2 MB    PRG        386 program
    0x0200000   256 KB  Z80        sound program (RAM on SXX2C)
    0x0240000   192 KB  CHARS      text tiles
    0x0280000   2.5 MB  PCM        YMF271 samples / pre-programmed flash
    0x0500000   12 MB   TILES      background tiles
    0x1100000   24 MB   SPRITES    three plane-pair chunks
    0x2900000   2 MB    PCMSRC     the updater's PCM source ROM, authentic only
    0x2B00000   ---     end (43 MB)

(`PCMSRC` is written only by the authentic-flash MRAs, which is why it is at the
top rather than anywhere tighter: a pre-flashed set leaves it unwritten and its
image is the 41 MB it always was. Section 17.2.)

`SPR_CHUNK_STRIDE` is the sprite region divided by three and is therefore PER
SET -- 4 MB for the SEI252 games, 6 MB for rdft2, 8 MB for rfjet. Only the
SEI252 value is wired; rdft2 needs it to become a port on `spi_sprite`.

The ROM loader performs the MAME
`ROM_LOAD24_*` / `ROM_LOAD32_*` scatter in hardware, so the MRA just concatenates
the raw files in a fixed order.

```
0x0000000  2 MB    PRG        (386 program, 32-bit)
0x0200000  256 KB  Z80        (sound program, byte)
0x0240000  192 KB  CHARS      (text tiles, 3-byte groups)
0x0280000  2 MB    PCM        (YMF271 samples, byte)
0x0480000  6 MB    TILES      (bg tiles, 3-byte groups)
0x0A80000  12 MB   SPRITES    (3 x 4 MB plane-pair chunks)
0x1680000  ---     end (22.5 MB)
```

MRA part order and the loader's scatter rule per part:

| # | file                    | size     | dest                                              |
|---|-------------------------|----------|---------------------------------------------------|
| 0 | seibu_1.u0259           | 0x80000  | PRG + i*4 + 0                                     |
| 1 | raiden-f_prg2.u0258     | 0x80000  | PRG + i*4 + 1                                     |
| 2 | raiden-f_prg34.u0262    | 0x100000 | PRG + (i>>1)*4 + 2 + (i&1)                        |
| 3 | seibu_zprg.u1139        | 0x20000  | Z80 + i                                           |
| 4 | raiden-f_fix.u0535      | 0x20000  | CHARS + (i>>1)*3 + (i&1)                          |
| 5 | seibu_fix2.u0528        | 0x10000  | CHARS + i*3 + 2                                   |
| 6 | gun_dogs_bg1-d.u0526    | 0x200000 | TILES + (i>>1)*3 + (i&1)                          |
| 7 | gun_dogs_bg1-p.u0531    | 0x100000 | TILES + i*3 + 2                                   |
| 8 | gun_dogs_bg2-d.u0534    | 0x200000 | TILES + 0x300000 + (i>>1)*3 + (i&1)               |
| 9 | gun_dogs_bg2-p.u0530    | 0x100000 | TILES + 0x300000 + i*3 + 2                        |
|10 | gun_dogs_obj-1.u0322    | 0x400000 | SPRITES + 0x000000 + i                            |
|11 | gun_dogs_obj-2.u0324    | 0x400000 | SPRITES + 0x400000 + i                            |
|12 | gun_dogs_obj-3.u0323    | 0x400000 | SPRITES + 0x800000 + i                            |
|13 | raiden-f_pcm2.u0975     | 0x200000 | PCM + i                                           |

SDRAM channel assignment (Sorgelig 5-channel controller):

| ch | width | user                                        |
|----|-------|---------------------------------------------|
| 1  | 32    | 386 PRG ROM fetch                           |
| 2  | 64    | tile layers (back/midl/fore) + chars        |
| 3  | rw    | ROM download; Z80 ROM fetch after download  |
| 4  | 64    | sprite gfx fetch                            |
| 5  | 64    | YMF271 PCM fetch                            |

---

## 5. GFX decryption — done **at fetch time**, not at load time

This is the key design decision. Every Seibu SPI decryption is a pure function of
(raw ROM bits, ROM address), and the address term collapses to the tile code. So
there is **no boot-time decryption pass at all** — the decrypt units sit in the
gfx fetch pipelines. This saves ~2.5 s of boot time and 0 bytes of SDRAM, and makes
adding RISE10/RISE11 for `rdft2`/`rfjet` a matter of swapping one unit.

### 5.1 Primitive: partial carry sum (`seibu_helper.cpp`)

```
res_i   = a_i ^ b_i ^ c_i
c_{i+1} = mask_i ? majority(a_i, b_i, c_i) : 0
```
plus a final wrap: if the carry out of the top bit is set, `res ^= 1`.
Ripple chain of 16/24/32 bits — pipeline in 2 stages.

### 5.2 Tile / char decryption (`seibuspi_v.cpp:42`)

```
decrypt_tile(val24, tileno) =
    partial_carry_sum24( bitswap24(val24), tileno + KEY1, KEY2 ) ^ KEY3

bitswap24 order: 18,19,9,5, 10,17,16,20, 21,22,6,11, 15,14,4,23, 0,1,7,8, 13,12,3,2
                 (MSB first)
KEY1=0x5A3845  KEY2=0x77CF5B  KEY3=0x1378DF   (rdft / rdfts / all SEI252 sets)
```
`tileno` derivation:
* **chars**: each 8×8 tile is 48 bytes = 16 three-byte groups, and MAME uses
  `tileno = group_index >> 4` → **`tileno = char code`**.
* **tiles**: decryption is applied in 0xC0000-byte blocks; within a block each 16×16
  tile is 192 bytes = 64 groups and `tileno = group_index >> 6` →
  **`tileno = tile_code & 0xFFF`** (4096 tiles per block).

A 16-pixel tile row is 4 groups (96 bits) → 4 parallel decrypt units, same `tileno`.
An 8-pixel char row is 2 groups (48 bits, 5 planes used) → 2 units.

Key sets for later:
| set family | KEY1     | KEY2     | KEY3     |
|------------|----------|----------|----------|
| rdft/senkyu/viprp1/ejanhs | 0x5A3845 | 0x77CF5B | 0x1378DF |
| rdft2      | 0x823146 | 0x4DE2F8 | 0x157ADC |
| rfjet      | 0xAEA754 | 0xFE8530 | 0xCCB666 |

### 5.3 GFX bit layout after decryption

`spi_tilelayout` (16×16, 6bpp, 192 bytes/tile, 12 bytes/row):
per 4-pixel group (24 bits, MSB-first bit numbering as MAME counts them) the six
planes are at bit offsets {0,4,8,12,16,20} and the four pixels at {3,2,1,0} within
each nibble, i.e. group byte-triple `B0 B1 B2` gives, for pixel p (0..3):
```
plane0 = bit(3-p) of nibble at offset 0    ...
```
Concretely: 24-bit value `v` (v[23] = MSB of B0). Pixel p of the group:
`{v[20+3-p], v[16+3-p], v[12+3-p], v[8+3-p], v[4+3-p], v[0+3-p]}` reading MAME's
plane list `{0,4,8,12,16,20}` as bit offsets from the MSB. The RTL encodes this as
an explicit table — see `rtl/spi_gfx_decode.sv` (to be written) — verified against
`spi_tilelayout` / `spi_charlayout`.

`spi_charlayout` (8×8, 5bpp, 48 bytes/tile, 6 bytes/row): same nibble structure,
planes {4,8,12,16,20} (plane at offset 0 unused → 5bpp, transparent pen 31).

`spi_spritelayout` (16×16, 6bpp, RGN_FRAC(1,3)): 3 chunks 4 MB apart, each chunk
holds 2 planes, 64 bytes/tile, 4 bytes (32 bits) per row:
```
chunk k, row y, dword d = data[chunk_base + code*64 + y*4]
  d[7:0]   plane(2k+0), pixels 0..7   (pixel 0 = MSB)
  d[15:8]  plane(2k+1), pixels 0..7
  d[23:16] plane(2k+0), pixels 8..15
  d[31:24] plane(2k+1), pixels 8..15
```
so one 16-pixel row needs three 32-bit reads from three widely separated addresses —
good for SDRAM bank interleaving. A 64-bit read covers rows y and y+1.

### 5.4 Sprite decryption (SEI252, `seibuspi_m.cpp:115`)

Operates on one 16-bit word from each of the three chunks at a time (48 bits in,
48 bits out = 8 pixels × 6 planes). Address term:
```
i    = word index within a chunk = code*32 + row*2 + (half ? 1 : 0)
addr = i >> 8  = code >> 3        (rows 0..15 never carry into bit 8)
```
Needs two small ROMs:
* `key_table[256]` — 16-bit, from `seibuspi_m.cpp:36`
* `spi_bitswap[16][16]` — 4-bit entries, from `seibuspi_m.cpp:87`

and:
```
key(t, addr) = bit(key_table[addr & 0xFF] >> 4, t) ^ bit(addr, 8 + ((t & 0xC) >> 2))
```
Then: permute y3 by `spi_bitswap[key_table[addr&0xFF] & 0xF]`, gather s1 (16 bit)
and s2 (32 bit) from y1/y2/y3 per the fixed bit tables, build add1 (16 bit) and
add2 (32 bit) from `key()`/`addr` bits, then
```
s1 = partial_carry_sum16(s1, add1, 0x3A59) ^ 0x843A
s2 = partial_carry_sum32(s2, add2, 0x28D49CAC) ^ 0xC8E29F84
```
and deinterleave s1 → planes 5,4 and s2 → planes 3,2,1,0.

Because `addr = code >> 3` is constant for a whole sprite tile, the key lookup and
the bitswap-select happen once per tile fetch, not per word.

**Risk:** these bit-gather tables are long and transcription errors are silent
(garbled sprites). Mitigation: generate the RTL tables with a script from the MAME
source rather than hand-typing, and cross-check with a Verilator testbench that
runs the C algorithm and the RTL over the same pseudo-random inputs.

---

## 6. Clocking

```
50 MHz ref -> PLL:  n=5, m=126  => VCO 1260 MHz
  c0 = /11  = 114.545455 MHz   clk_ram   (SDRAM)
  c1 = /22  =  57.272727 MHz   clk_sys   (video, I/O, sound) = 28.63636 * 2
  c2 = /44  =  28.636364 MHz   clk_cpu   (the 386)
  pixel clock = clk_sys / 8 = 7.1590909 MHz   (exact)
  Z80 CE      = clk_sys / 8 = 7.1590909 MHz   (exact)
```

**Why the 386 has its own clock.** With z386 on clk_sys the design missed setup
by 1.030 ns (TNS -32.487). Every failing path was internal to the CPU, from
`IND[0]` to the microcode ROM's address register — nothing to do with the glue
logic. Upstream z386_MiSTer ships PLL profiles at 50 / 65 / 85 MHz, so the core
can go faster, but it also keeps a `seed_sweep.py` in the repo, which says
something about how hard the top of that range is to hit.

Halving the CPU clock fixes it with margin and improves accuracy at the same
time: 28.64 MHz is far closer to the board's real 386DX-25 than 57.27 MHz was.
clk_cpu is exactly clk_sys/2 and phase aligned from the same PLL, so every
clk_cpu edge coincides with a clk_sys edge and both sit in the same clock group
— TimeQuest analyses the crossings normally instead of them being a true CDC.

Crossings that needed care:
* **vblank -> CPU IRQ**: a one-cycle clk_sys pulse is invisible to a half-rate
  clock, so it crosses as a toggle (`vbl_toggle`) and is edge-detected in
  `spi_cpu`.
* **main RAM**: dual-clock M10K, port A on clk_cpu, port B (video DMA) on
  clk_sys.
* **I/O registers**: written on clk_cpu, read by video on clk_sys. These are
  stable register values, not pulses.
* **DMA trigger pulses** (clk_cpu, one cycle = two clk_sys cycles) will need
  edge detection in the clk_sys DMA engine when T4 lands, or they will fire
  twice.
* **reset**: `reset` comes from clk_sys logic and `rom_ready` from the loader on
  clk_ram, while z386 contains genuine asynchronous clears
  (`dsp_mul.sv:57`, `always_ff @(posedge clk or negedge reset_n)`). Feeding that
  combination straight in produced a real recovery violation
  (`rom_loader|rom_ready` -> `dsp_mul|acc[*]`, -0.394 ns), which in hardware
  means the CPU can leave reset part-way through a cycle. Each domain now gets
  its own `spi_reset_sync`.
* **YMF271** 16.9344 MHz — unrelated to 28.636 MHz. Generate a fractional clock
  enable from clk_sys, or better, generate the 44100 Hz sample tick directly
  (16934400 / 384 = 44100) and clock the synth's internal slot pipeline from
  clk_sys with 384 slots per sample period.
* **386** nominally 25 MHz. z386x is *not* cycle-accurate to a 386 — it has L1
  caches and hardwired fast paths and is materially faster per clock. Running it at
  a 25 MHz clock enable will therefore run the game *faster* than real hardware in
  CPU-bound sections. Plan: expose a CPU speed option in the OSD, default to a
  value calibrated against MAME, and record the calibration here once measured.
  **Open item — but see section 16, which measures it.** The 386 is idle 80-85%
  of a frame in rdft attract, so 25 MHz is cosmetic: the same work is 17-24% of a
  frame there too. Exact 25.000 MHz also needs a second PLL and an asynchronous
  `clk_cpu`. What is still unmeasured is z386x's throughput against a real
  386DX-25, and section 16.3 records why MAME would not give it up.

---

## 7. z386 integration notes

Submodule was not checked out in `~/proj/z386_MiSTer`; fixed with
`git submodule update --init` (commit `516ced0`, branch `z386x`).

Interface (`src/z386/z386.sv`) is a clean ready/valid 32-bit bus:
```
addr[31:2] be[3:0] burstcount[7:0] din dout valid ready write io resp_valid
intr nmi inta  snoop_addr snoop_valid  a20_enable  single_step  triple_fault_reset
```
Parameters: `PROTECT_UMA_ROM`, `DCACHE_SET_BITS`, `ICACHE_SET_BITS`.

**Cache coherency with memory-mapped I/O.** The SPI I/O registers live at
0x400–0x6FF, *inside* the main RAM address space, with no PIC or MMU to mark them
uncacheable. Findings after reading `l1_cache.sv` / `l1_icache.sv`:

1. *The dcache is **write-through*** with a 3-entry in-order store queue
   (`l1_cache.sv`, `STOREQ_DEPTH = 3`). So the video DMA engines reading main RAM cannot see
   stale data: the DMA-trigger write to 0x480 / 0x484 / 0x562 goes through the
   same queue behind the data writes it is meant to publish. Ordering is free.
   No flush, no snoop, no dual-port coherency scheme needed.

2. *An uncacheable path already exists*, but hardcoded to the PC VGA aperture:
   ```
   wire cpu_uncacheable = !cache_enable || (cpu_addr[31:17] == 15'h5);  // A0000-BFFFF
   ```
   The patch is therefore small: parameterise it as a mask/base compare, default
   it to the existing PC window, and instantiate with mask `0xFFFFF800` / base
   `0x00000000` so 0x0–0x7FF is uncacheable. Plumb the two parameters through
   `z386.sv`. Keep the diff in `patches/`.

   **This is the pre-patch state, kept because it explains the change.** The
   line above no longer exists in `rtl/z386/l1_cache.sv`; it now reads
   `(cpu_addr & UNCACHED_MASK) == UNCACHED_BASE`, which is the patch applied.

3. *Self-modifying code works.* The icache snoops the dcache's own store stream
   (`icache_write_snoop` in `z386.sv`) and patches the cached data, so code
   copied into RAM and executed is coherent without any help from us.

4. *Cache tags only cover addr[24:0]* (`TAG_MSB = 24`, a 32 MB window). Two CPU
   addresses differing only above bit 24 share a cache line. Our PRG ROM at
   0x00200000 and its real-mode mirror at 0xFFE00000 map to tag regions
   0x0200000 and 0x1E00000 respectively, so they do not collide — but the
   address decoder must handle the mirror itself, and nothing else may be placed
   at 0x1E00000–0x1FFFFFF.

Set `PROTECT_UMA_ROM = 0` (no UMA on this board).

Vendored under `rtl/z386/` (with the fetched submodule contents) so the core builds
standalone. `ucode.mif` / `pla_entry_rom.hex` must be copied too.

---

## 8. Module breakdown

```
SeibuSPI.sv               top (emu), OSD/HPS wiring, video out, rotation
rtl/pll/                  PLL
rtl/spi_top.sv            the board: CPU + video + sound + I/O decode
rtl/spi_cpu.sv            z386 wrapper, address decode, main RAM, IRQ
rtl/spi_io.sv             I/O register file, CRTC regs, DMA triggers, inputs
rtl/spi_dma.sv            tilemap / palette / sprite DMA engines
rtl/spi_video.sv          video top: timing, layer pipelines, mixer
rtl/spi_tilemap.sv        one 16x16 layer fetch+render pipeline (x3 instances)
rtl/spi_text.sv           8x8 text layer pipeline
rtl/spi_sprite.sv         sprite list walk + line buffer render
rtl/spi_mixer.sv          priority composite + alpha blend table
rtl/spi_palette.sv        palette RAM + BGR555 -> RGB888
rtl/spi_gfx_decrypt.sv    tile/char decrypt unit (partial carry sum 24)
rtl/spi_spr_decrypt.sv    SEI252 sprite decrypt unit (+ key/bitswap ROMs)
rtl/seibu_partial_add.sv  partial carry adder primitive
rtl/spi_sound.sv          Z80 + banking + FIFO + YMF271
rtl/t80/                  T80 Z80 core (from an existing arcade core)
rtl/ymf271/               YMF271 implementation
rtl/spi_ds2404.sv         minimal DS2404 1-wire stub
rtl/rom_loader.sv         ioctl -> SDRAM with per-part address scatter
rtl/sdram.sv              Sorgelig 5-channel controller
rtl/screen_rotate.sv      ROT270 framebuffer rotation (DDR3)
mra/rdfts.mra
tools/gen_tables.py       emits key_table / bitswap / alpha tables from MAME src
sim/                      Verilator testbenches for the decrypt units
```

---

## 9. Risks / open items

1. **YMF271** is the single largest unknown: 48 slots, 4-op FM + PCM + envelope +
   LFO, 1800 lines of C in MAME, and no existing FPGA implementation anywhere
   (checked jtcores, jtframe, all local Arcade-* cores — nothing). Staged plan:
   PCM slots first (Seibu games lean heavily on PCM for both music and SFX), then
   4-op FM. **Both landed** -- see 14 and 15; music plays on hardware with 0
   overruns. What is left is the list of gaps in 14.5, none of which is
   structural.
2. **Sprite bandwidth.** 3 SDRAM reads per 16-pixel sprite row; worst case 512
   sprites. **Resolved in 13b** -- concurrent scan/draw, horizontal culling and
   fetch/emit overlap took starvation to zero across the whole measured load
   range, on hardware.
3. **SDRAM at 114.5 MHz** with CAS3 -- **largely resolved 2026-08-09 by a
   pipeline stage after `dq_reg`.** The recurring `dq_reg -> chN_dout` failures
   had no logic in them at all: one 16-bit capture register in the I/O cell
   fanning out to 5 channels x 64 bits, so the fitter could not place the net.
   `dq_reg_d` is a plain fabric copy one cycle behind, and the only thing the
   channel dout registers read; every `data_ready` tap moved one position later
   to pay for the cycle. On the SAME seed this took clk_ram from -0.690 (TNS
   -12.459) to -0.022 (TNS -0.022), and a reseed then closed the whole design at
   +0.301. Note this is NOT the section 10 mistake: `dq_reg` itself is untouched
   and still single, so the DQ input path is unchanged; only the fanout moved to
   a register with no I/O constraint. Verified on hardware -- the ROM checker
   reads all four regions back and reports `ok bits 1111`.

   Also worth correcting: this section used to nominate retiming `spi_layers`'
   address path as the first lever. That path is real -- `gfx_base` is four adds
   deep -- but it is in **clk_sys**, which passes with margin, so it could never
   have fixed a clk_ram failure. Look at the failing endpoint before picking a
   lever.

   Original note follows. **SDRAM at 114.5 MHz** with CAS3 — above the usual 100 MHz for this
   controller, and now the tightest domain in the design. Setup slack on
   `clk_ram` fell to **+0.106 ns** when the tile layers landed, from +1.415 ns
   before. The sprite engine shares that channel arbitration and will very
   likely push it negative.

   Levers, in order: retime the `spi_layers` SDRAM request path (it drives
   `sdr_addr` straight out of a wide combinational address calculation —
   `gfx_base` is four adds deep), then drop `clk_ram` to 95.45 MHz
   (28.63636 × 10/3) and re-check bandwidth. **Re-run STA after adding the
   sprite engine; do not assume it still fits.**
4. **z386 accuracy/speed** vs a real 386DX-25 (see §6 and **section 16**). The
   core runs `clk_cpu` at 28.636364 MHz — this item used to say 57.27 MHz, which
   was true before the 386 got its own domain. That is 14.5% above a 386DX-25
   before counting z386x's caches and fast paths. Gameplay speed is locked to the
   54 Hz vblank interrupt either way, but the per-frame compute budget is not:
   Raiden Fighters' slowdown under heavy fire is part of how the game plays, and
   at this speed it will not happen — **measured, section 16: the 386 is idle
   80-85% of a frame in attract**, so the headroom is real and large.
   `spi_cpu` already has a `cpu_en` input, but note it gates `mem_accept`, i.e.
   the EXTERNAL bus only; with 256-set I- and D-caches, cache-resident code is
   not throttled by it at all, so it is not a uniform speed control as it
   stands. The lever is either wait-states on the memory interface or a real
   `cpu_en` inside z386. **Unresolved**, and the missing number is how much
   faster z386x is per clock than a real 386 (16.3).
5. **Decrypt table transcription** (see §5.4) — script-generated + Verilator-checked.
6. **Alpha blending.** MAME's table of blended pens is its own approximation of
   the hardware (its TODO says so) and we reproduce that table exactly; the
   blend arithmetic itself is now bit-exact rather than a 50/50 average, so we
   are as close to MAME as it is possible to be. Any remaining inaccuracy is
   MAME's, not ours. See 13c.
7. **DS2404** — the game reads it; a stub returning 0 may or may not satisfy the
   boot checks. `spi_ds2404_unknown_r` returning 0x00 is what MAME does.
8. **Toolchain.** Quartus Prime 17.0.0 Lite at `~/intelFPGA_lite/17.0/quartus`
   (`bin/quartus_sh`), target part `5CSEBA6U23I7` confirmed present. This is the
   normal MiSTer toolchain — Lite is what the platform is built with and what
   `5CSEBA6` is supported by — so resource and timing numbers here are real, not
   provisional. Verilator 5.050 is also available for lint and decrypt-unit unit
   tests.

---

## 9b. Debug workflow: freeze the scene, then instrument it

Do not identify an attract scene by timing or by counting non-black pixels.
Both were tried and both put measurements on the wrong scene, which was then
reported as a hardware fault that did not exist. `quartus_stp` needs ~5 s just
to claim the JTAG chain, and the ROM download shifts the whole attract sequence
by seconds between runs, so a guessed delay cannot be aimed.

Instead:

1. **Freeze the hardware with any controller button.** `SeibuSPI.sv` toggles the
   CPU freeze on any button of either pad. Only `spi_cpu`'s `cpu_en` is gated,
   so the video engines keep running and the frozen frame stays on screen.
2. **Instrument it** with the persistent JTAG console, which holds the chain
   open so commands cost milliseconds:

       quartus_stp -t tools/jtag_server.tcl      # leave running in a terminal
       tools/slop vitals                          # from anywhere else

   ENTER in the console also toggles the freeze. `vitals` reports `state` from
   probe bit 366, which is the *effective* freeze, so a button-triggered freeze
   is visible too -- reading the CTRL source register alone would miss it.
3. **Pause MAME on the same scene** and dump its state:

       SLOP_OUT=/tmp/mame_state mame rdfts -autoboot_script tools/mame_probe.lua

   Press P; each pause writes `mainram/tilemap_ram/palette_ram/sprite_ram.bin`,
   `frame.bin` and a decoded `sprites.txt` into `/tmp/mame_state/NNN/`.
4. **Confirm both sides are on the same scene before concluding anything.**
   `sprites.txt`'s `codes_nonzero` and the hardware's `codes!=0` are directly
   comparable and identify a scene far more reliably than appearance does. This
   is what exposed the wrong-scene error: hardware read 5 exactly when MAME's
   frame 901 had 5, which placed the measurements ten seconds earlier in the
   attract than assumed.

Worth knowing: MAME itself has a **10.2 s stretch of the attract with zero
sprites** (frames 351-900). A screen with no sprites is not evidence of a fault.

## 10. Gotchas found the hard way

**The Seibu CRTC register window (0x400-0x44F) must be READABLE.** MAME backs
the whole window with `map(0x0000, 0x004f).ram()` and overlays the register
handlers on top, and `reg_1a` additionally has an explicit `reg_1a_r()`. Reads
therefore return whatever was last written.

Returning zero instead broke the game's read-modify-write of `reg_1a`: it read
0, ORed in the fore-layer bit and wrote the result back, destroying **bit 15,
rowscroll enable**, in the process. On the board `rowscroll` came up 1 and then
dropped to 0 at the exact instant `fore_d13` went to 1 -- that sequence is the
RMW.

The damage is out of all proportion to one bit, because it selects the tilemap
DMA's source layout:

    rowscroll on : back, back_rs, fore, fore_rs, midl, midl_rs, text  (4096 dw)
    rowscroll off: back, fore, midl, text                             (2560 dw)

Parsing a rowscroll-on buffer as rowscroll-off puts the game's FORE tiles in the
midl region, where they are drawn with the **midl palette**; back receives the
back rowscroll values as if they were tile codes; and fore and text get nothing.
The board showed exactly that: one layer of content in the wrong colours over an
all-black screen, with a black band wherever the misplaced layer had no tiles.

Related, and fixed at the same time: **every CRTC register is merged per byte**,
as MAME's `COMBINE_DATA` does. `reg_1a`'s bit 15 and bit 11 both live in its
*high* byte (0x41B, `be[3]`); gating them on `be[2]|be[3]` let a write touching
only 0x41A latch bit 15 from a byte the game never drove. `layer_enable` is the
low byte of 0x41C (`be[0]`) for the same reason.

**The three video DMAs each need their own pending slot, and their parameters
must be latched when the trigger fires.** MAME performs each DMA instantly
inside the trigger write, so it always uses the `video_dma_address` current at
that instant. Here the transfer waits for the CPU to release the shared main RAM
port, which opened two holes:

* A single `start_pending` flag meant a trigger arriving while another transfer
  was pending or running simply overwrote `pend_mode` and was **dropped**. The
  game fires all three DMAs back to back every frame, so the sprite request --
  last of the three -- was the one routinely lost. Sprite RAM then kept its
  power-on zeros, every list entry failed the `code != 0` gate, and no sprite was
  ever emitted in that scene.
* `ram_addr <= dma_src` sampled the source at *grant* time, so a late-starting
  transfer could read from an address belonging to a later request.

That these are different addresses is not hypothetical -- one captured frame has
`sprite_dma 0x37000`, `tilemap_dma 0x38000`, `palette_dma 0x3C000`.

`sim/tb_dma.cpp` originally ran one DMA at a time and waited for each to finish,
which cannot reach either bug; it now also fires two triggers a cycle apart with
the source changing in between, and fails if any destination is left untouched.

**Telemetry counters must be latched per line/frame, not left free-running.**
The 16-bit sprite counters tick at ~10^5/s, so sampling them 500 ms apart
overflows more than once and the deltas alias into nonsense -- the giveaway was
`y-hit` reading higher than `scanned`, which is impossible. Sample at 40 ms, or
latch a per-line value (`dbg_codes_nz`) and read that.

**`quartus_stp` Tcl: `[index_of \"CTRL\"]` inside a `"..."` string does not
work.** Tcl parses a bracket body as a script, where `\"CTRL\"` is a malformed
word, so the whole `elseif` branch failed to *parse* -- at runtime, only when
that branch was taken. Every `mask` call was therefore a silent no-op: the
layer-isolation sweep changed nothing and `mask 0` never released the CPU
freeze. Resolve the index into a variable first.

**Masking a layer off does not blank it.** Each layer owns its own line buffer
and `S_LSTART` skips a disabled layer entirely, so its buffer keeps stale
content. This is harmless in normal operation -- `spi_mixer` also gates on
`layer_enable`, so a disabled layer is never mixed -- but it makes
"show one layer at a time" useless as a diagnostic, because what you see
accumulates across steps. Judge layer isolation from the mixer's output, not
from non-black pixel counts.

**The Elgato drops off the bus if it is opened and closed repeatedly.** A sweep
that reopens it per step will produce a run of all-black frames that look exactly
like a dead core. Do one long capture and cut it up afterwards, and always set
`--set-fmt-video=width=1920,height=1080,pixelformat=MJPG` explicitly -- after a
replug it renegotiates to 640x480.


**The core PLL must keep the `pll -> pll_inst -> altera_pll_i` hierarchy.**
`sys/sys_top.sdc` puts the core clocks into a clock group by *name*:

```
-group [get_clocks { *|pll|pll_inst|altera_pll_i|*[*].*|divclk}]
```

A hand-written flat `module pll` instantiating `altera_pll` directly produces
`emu|pll|altera_pll_i|...`, which matches nothing. The core clocks then sit
outside every clock group and TimeQuest analyses them against every unrelated
domain — the whole design reports tens of nanoseconds of phantom negative slack
(clk_sys "Fmax 27.66 MHz", setup slack -90.878 ns) with no real critical path to
find. Keep the extra level of hierarchy. After the fix, every clock is clean:

| clock     | target      | Fmax       | setup slack | hold slack |
|-----------|-------------|------------|-------------|------------|
| `clk_ram` | 114.545 MHz | 140.15 MHz | +1.595 ns   | +0.247 ns  |
| `clk_sys` |  57.273 MHz |  79.11 MHz | +3.393 ns   | +0.246 ns  |

TNS 0.000 on every domain. That is the empty-skeleton baseline; the margin will
shrink as the CPU, video and sound land, and `clk_ram` has the least of it.

**Do not ask Quartus for a true dual port memory.** Main RAM was briefly true
dual port — CPU on one side, video DMA read on the other. Quartus refused to
infer it and **duplicated all four byte lanes**, taking the array from 2 Mbit to
4 Mbit and overflowing the device: *"device has 553 RAM locations ... design
needs more than 553"*. It had fitted before only because the DMA port was still
tied to a constant and had been optimised away entirely, so the cost appeared
the moment the port became real.

The fix was architectural and is the better design anyway: the DMA moved into
the CPU's clock domain and now shares the single main RAM port through a
request/grant handshake in `spi_cpu`. It only runs in short bursts a few times a
frame (~1.5% of CPU cycles), and the real board steals cycles for the same
transfers. Block memory went 5,316,901 -> 3,265,253 bits.

One write port plus one read port (simple dual port) *is* inferred cleanly, even
with different clocks — that is what `spi_dpram` uses for the video RAMs.

Tracing that arbitration also exposed a pre-existing off-by-one: `spi_cpu`
delivered main RAM reads one cycle too early. `ram_addr` is a register, so the
RAM only sees it the cycle *after* it is assigned, and the RAM registers its
output on top of that — delivery is two stages deep, not one. It would have
returned stale data for every RAM read the CPU made.

**Verilator lint is not a substitute for a Quartus run.** `spi_mixer` drove
`red/green/blue` from two `always @(posedge clk)` blocks — the reset in one and
the pixel output in the other. Verilator `-Wall` passed it; Quartus rejected it
outright with "Can't resolve multiple constant drivers". Run at least
`quartus_map` before believing a module is done.

**Never edit `files.qip` or the QSF while a compile is running.** Quartus notices
the change, rewrites the QSF with `sys.tcl` and a stale snapshot of `files.qip`
expanded inline, and then dies with "quartus_map ended unexpectedly". The
template's "do not add files in the Quartus IDE" warning covers this case too.
Recovery is to regenerate the QSF from `Template_MiSTer/mycore.qsf`.

- **Two sprite bugs, both found by building a pixel-level golden check.**

  1. *The 6-bit sprite pen was bit reversed.* spi_spr_decrypt emits the pen with
     bit p carrying MAME plane(5-p) -- bit 0 is plane5, the pen's MSB. That is
     the convention tb_spr_decrypt asserts, so the decrypt unit is correct and
     the reversal belongs in spi_sprite, which consumed it raw. Near invisible
     because the common values are palindromes: 3F (transparent) and 00 survive
     reversal unchanged, so most pixels looked right while solid areas took
     wildly wrong colours. Frame error against MAME went 7.21% -> 1.68%.

  2. *sizey + 3'd1 overflowed 3 bits.* tile_code = code + ax*(sizey+1) + ay, but
     `sizey + 3'd1` is evaluated at 3 bits inside a concatenation, so a
     full-height sprite (sizey == 7) wrapped the multiplier to ZERO and every
     tile column reused the same codes -- a grid of repeated blocks over large
     sprites, most obviously the title logo. Widen before multiplying. The
     golden capture has no full-height sprite, so this was invisible to the
     frame test and only showed on hardware.

  Lesson: the frame-level diff said "7.21% wrong, mostly sprite-ish colours",
  far too vague to act on -- and its "matches a sprite pen" heuristic is weak,
  since pens 0..4095 cover most colours by coincidence. What cracked it was
  decoding the same tile row straight out of the ROM with MAME's own decryptor
  and diffing pixel by pixel (the sprite pixel check in tb_video). Build the
  narrow check that names the wrong bit, not the broad one that counts wrong
  pixels.

- **The alpha blend is a 127/129 mix, not 50/50.** MAME composites with
  alpha_blend_r32(dest, pen, 0x7f) = (src*127 + dst*129) >> 8. A plain
  (a+b)>>1 differs by one unit per channel on about half of all blended pixels.
  Invisible to the eye, but it was 24,975 of the 29,815 differing pixels on the
  frame-2400 capture -- it buried every real fault under rounding noise.
  Both exact forms cost far too much timing: the literal 128*(d+s)+(d-s)>>8 blew
  clk_sys setup by 6 ns and the average-plus-correction form by 21 ns, because
  several blends sit in series in one combinational chain. The mixer keeps the
  cheap average; sim/tb_video now scores frames with a +-1 per channel tolerance
  and reports REAL mismatches separately. Only exact-form work would justify
  pipelining the mixer across its eight cycles per pixel.

- **spi_io's outputs cross clk_cpu to clk_sys unsynchronised.** layer_enable,
  rowscroll_enable, fore_layer_d13 and rf2_layer_bank are all written on clk_cpu
  and consumed by the clk_sys video logic. layer_enable in particular reaches
  deep into the mixer's blend chain, and once that chain grew it failed setup by
  6.4 ns. They are slow control registers, rewritten about once a frame, so a
  two-flop synchroniser in spi_top is both correct and sufficient.

- **tb_video's per-layer reference models are skewed one pixel.** text_line(),
  back_line() and fore_line() disagree with MAME's real output by one pixel.
  Making the RTL match them makes the FRAME worse: forcing the text layer to
  300/300 against text_line() took the frame from 6.3% to 14.5%. This cost real
  time -- it produced a confident but wrong "the back layer is shifted one pixel"
  conclusion. The frame diff against MAME's captured bitmap is the ground truth.
  Treat the layer scores as a hint about WHICH layer is involved, never as proof
  of alignment.

## 12. Golden-reference testing against MAME

MAME exposes the SPI driver's internals by name, which makes it a usable oracle
rather than just a thing to read:

* shares `:mainram`, `:tilemap_ram`, `:palette_ram`, `:sprite_ram`
* regions `:maincpu`, `:chars`, `:tiles` -- and the graphics regions are
  **decrypted in place at init**, so they are ground truth for the decryption

`tools/mame_capture.lua` drives this; `tools/build_sdram_image.py` builds the
SDRAM image from a ROM set (matching by CRC32, since merged sets store shared
ROMs under the parent's filenames). Tests: `make -C sim run-dma`, `run-video`.

Traps worth remembering:

* **Reading memory inside a MAME write tap segfaults** -- it re-enters the
  memory system. Shadow registers in the tap; read RAM in the frame notifier.
* **Lua subscriptions must be held in globals.** Held in a local, the tap and
  frame notifier are collected once the autoboot chunk ends and silently stop
  firing, which looks exactly like the game never touching the hardware.
* **The DMA reads main RAM at the instant it is triggered**, and the game has
  overwritten it by the frame notifier. Comparing against an end-of-frame dump
  showed ~20% of tilemap entries differing for no real reason. The script
  shadows main RAM for one frame and snapshots the source at trigger time.
* `screen:pixels()` returns (data, width, height); `f:write(scr:pixels())`
  appends the dimensions as text.

### What this caught that nothing else would have

1. **spi_dma's segment counter was 11 bits** but the palette moves 3072 dwords.
   It wrapped to 1024 and left two thirds of the palette unwritten. The first
   mismatch landed at exactly 0x400.
2. **ROM_LOAD24_WORD byte order was backwards.** MAME's ROM_GROUPWORD swaps the
   bytes of each source word when the destination is a plain ROM_REGION, as
   `chars` and `tiles` are; it does NOT for `maincpu`, which is
   ROM_REGION32_LE. `tb_rom_loader` had passed all along because it compared
   the RTL against my own reference implementing the same wrong rule --
   self-consistent, not correct. Now verified against MAME's actual regions:
   PRG byte-exact, chars and tiles exact after decryption.
3. **The gfx plane order was reversed.** `gfx_layout.planeoffset[]` is listed
   MOST significant plane first -- `decodechar` uses
   `planebit = 1 << (planes - 1 - plane)`. Getting this backwards bit-reverses
   every colour index, which renders as plausible garbage rather than an
   obvious failure.
4. **The rowscroll table fetch was a cycle short**, same class as the two
   earlier pipeline-depth bugs.

Of those, only the first would ever have produced an obvious symptom.

## 10a. RESUME HERE (end of 2026-08-10): all three sets run on hardware

**rdfts, rdft and rdft2 all boot and run on the MiSTer at 192.168.1.125**, each
confirmed by screenshot on the build at this commit: every clock positive
(clk_ram +1.001, TNS 0.000) and `make verify` passing. (2026-08-11: still true
on the current build, clk_ram +0.352, with rdfts now reporting `ok bits 1111`
and rdft2 verified by ear and by spectrum -- 10d.)

    rdfts   bytes_in 23,396,353  bytes_out 23,396,352   attract plays
    rdft2   bytes_in 35,752,108  bytes_out 35,910,452   title screen, sprites
            (+158,344 is the sample codec's expansion, 471,277 - 312,933)
    rdft    the board's TEST MODE menu, rendering correctly

rdft came up in Test Mode because the Service Mode DIP is set for that MRA in
the MiSTer's saved per-core config -- an OSD setting, not a core fault. Its
attract has not been seen since the `ioctl_wr` fix; turn Service Mode off on
the OSD's DIP page to check, which is the only thing still unconfirmed about
that set.

### What is NOT known yet, in the order it matters

**Four of the five items that were here on 2026-08-10 are closed; see 10d.**
rdft2 has been heard AND matched against MAME (T-H), the SPRITES checksum was a
stale constant in the checker rather than bad data (T-G), and the PEEK address
bit is fixed and confirmed on hardware along with a second instrument bug it
exposed (T-F). What remains:

1. **rdft2 has only been seen in attract.** No coin, no start, no gameplay, no
   second loop. Sprite starvation and the RISE10 path have been exercised
   against captures but not against a live game under load. This is now the
   top item (T-I).
2. **rdft's attract** (T-J), still behind the Service Mode DIP in that MRA's
   saved OSD config.
3. **Stereo** (T-K, new): the cartridge board outputs stereo and the core
   sums to mono. Measured against MAME, not guessed. Fidelity, not a fault.

### How to get back to a running board

    make && make timing                       # never trust "successful" alone
    sshpass -p 1 scp output_files/SeibuSPI.rbf root@192.168.1.125:/media/fat/_Arcade/cores/
    sshpass -p 1 ssh root@192.168.1.125 'echo "load_core /media/fat/_Arcade/rdft2.mra" > /dev/MiSTer_cmd'
    sshpass -p 1 ssh root@192.168.1.125 'echo "screenshot s.png" > /dev/MiSTer_cmd'

Take the screenshot BEFORE reading any JTAG counter. See the end of 10c for why
that is not a stylistic preference.

### What got finished in the rdft2 arc

rdft2 went from "the flash format is unknown" to running on hardware, all of it
in section 0 above and 10c below:

* the sample-flash codec cracked (BPE over DPCM) and rebuilt offline bit-exact
* an in-core decoder, with the MRA choosing which codec runs per part
* rdft2's loader table and MRA, 34.1 MB, checked part by part against MAME
* the sprite chunk stride and the RISE10 crypt selected per set
* the tile/text keys, and the fore-layer base that had to widen with them
* ten captured scenes verified pixel-identical, which found rdft2's 17th
  sprite tile-code bit
* sprite starvation eliminated by interleaving the sprite ROMs at load time
* **the sound01 window, which is what had blocked booting** -- see (1)
* **the `ioctl_wr` edge detector, which is what had blocked RUNNING** -- and it
  turned out to be corrupting every set's download, not just rdft2's. 10c.

### (1) rdft2's Z80 program: the sound01 window -- DONE

The blocking item, and it was in the CORE, not the MRA. Measured: pre-flashed,
rdft2 still issues 131,072 dword reads over 0x1380000-0x13FFFFC, which is
`sound1.u0222[0x60000..0x7FFFF]` and nothing else -- its Z80 program, which the
386 pushes through port 0x688 before releasing the Z80. `spi_cpu.sv` decoded
main RAM, I/O and PRG ROM only, so that download was 128 KB of zeros, and since
the 386 waits on the Z80 during boot the symptom would have been a HANG, not
silence.

What it needed was a fourth 386 read window at 0x1380000 backed by SDRAM, and it
was smaller than it sounds:

* only 128 KB of the 10 MB window is ever touched, so only the 512 KB of 386
  space at 0x1380000 is decoded (`byte_addr[31:19] == 13'h027`);
* the 386 reads it as dwords with only byte 0 meaningful (`sound1` is
  ROM_LOAD32_BYTE on lane 0), so it is stored PACKED and expanded to
  `{24'b0, byte}` on the way out. A 4-dword cache-line burst is then four
  consecutive bytes, one 64-bit SDRAM read, and eight dwords come out of each
  group instead of two;
* the PCM region had 512 KB spare above rdft2's 2 MB flash image, so
  `SDR_SND01_BASE` is 0x0480000 and the map did not move. The YMF271 masks its
  address to the low 2 MB of `SDR_PCM_BASE`, so the two cannot collide;
* one more loader part (a 17th for rdft2) and an MRA part carrying
  `sound1.u0222` offset 0x60000 length 0x20000 -- the same file twice, since
  the other slice is the compressed sample tail.

It shares `spi_cpu`'s program-ROM fetch states rather than adding its own; the
only differences are where the group address comes from, how the dword is cut
out of the group, and where the group ends (`cur_dw[2:0] == 7` instead of
`cur_dw[0]`). `snd01_en` gates the whole window on rdft2: rdft and rdfts never
read it and have nothing loaded behind it.

**Verified by running the game's own code.** `run-boot` was revived for this
(it was 19 pins behind `spi_top`) and now takes a set, models ch3 in both
directions, and ends by comparing what the download put in the Z80's memory
against the ROM:

    make -C sim run-boot GAME=rdft2 SDRAM=/tmp/sdram_rdft2.bin STEPS=400000000

    sound01 fetches        : 444294
    Z80 download writes    : 131072
    Z80 RAM bytes written  : 131072, 0x0..0x1FFFF
    Z80 program matches the ROM byte for byte over that range

That covers the loader part, the window and port 0x688 in one pass, with
nothing modelled by hand except the SDRAM. The 386 releases the Z80 at ~56M
steps and then spins on the sound FIFO forever -- correctly, because the
Verilator T80 is a stub with no CPU in it. So a cartridge `run-boot` always
ends on a black screen; judge it by the download check and the register log,
never by the picture.

### (2) clk_ram missed timing by 0.292 ns -- FIXED, and now +0.927

**The current build meets timing on every clock**, TNS 0.000 everywhere:

    clk_ram   (general[0])  +0.927      clk_sys (general[1])  +1.088
    clk_cpu   (general[2])  +3.085      HDMI PLL              +0.268
    worst hold                          +0.188

87% RAM blocks, 53% DSP, 62% block memory bits. The rest of this section is how
it got there, because the shape of the problem is the useful part.

`make build` succeeded -- 0 errors, RBF written -- but a successful compile does
NOT mean timing met, and that one did not:

    clk_ram (general[0], 96.9 MHz)   slack -0.292   TNS -0.448
    everything else                  positive (worst other +0.117)

TNS -0.448 over a slack of -0.292 means only a couple of failing endpoints. The
worst paths are the STATE_IDLE priority mux in `sdram.sv` feeding `SDRAM_A`:

    -0.292  sdram|ch4_rq~DUPLICATE  -> sdram|SDRAM_A[7]
    -0.169  sdram|ch2_rq            -> sdram|SDRAM_A[7]
    -0.165  sdram|state.STATE_RW1   -> sdram|SDRAM_A[7]
    -0.005  rom_loader|part[1]      -> rom_loader|sdr_addr[24]

The last one is directly mine: widening `part` to 5 bits made the part-table mux
that feeds `sdr_addr` one level deeper. The `sdram.sv` ones are not new logic --
that mux was always there -- but the design is at 80% ALMs and 87% RAM blocks
now, so the fitter has less room. `sdram.sv:52` already carries a note that this
mux "costs a level in the STATE_IDLE priority mux that feeds SDRAM_A".

#### Chased down, one fit at a time (2026-08-10)

Three fits, and the interesting part is that the failing endpoint MOVED each
time. At this occupancy the design has several paths within a tenth of a
nanosecond of each other, so fixing the worst one just promotes the next -- and
a "fix" that only shuffles the placement makes things worse. What worked was
cutting real logic out of clk_ram paths, twice:

* **`rom_loader`'s part table is registered**, and read one part ahead
  (`part_sel`) so the registered copy is valid the same cycle `part` changes.
  That is the fix predicted above, and it worked: `part[1] -> sdr_addr[24]`
  went from -0.005 to +0.083. It also has a trap -- during reset `part_size_r`
  is not loaded yet, so `part_in_full` reads true against a zero size and
  `part_done` fires spuriously, which would leave the table pointing at part 1
  on release. `part_sel` is forced to 0 while reset is held.
* **`sdram.sv`'s emergency-refresh test is registered.** With the loader fixed,
  the single remaining endpoint was `refresh_count[12] -> SDRAM_A[11]`: a live
  14-bit magnitude compare at the TOP of the STATE_IDLE priority chain, so it
  sat in front of the entire address mux. Firing one cycle later is nothing on
  an 880-cycle threshold. This one also has a startup trap: `refresh_count`
  runs UP to a wrap during STATE_STARTUP, so a stale `refresh_due` would fire
  against a freshly zeroed counter and underflow it into a burst of refreshes.
  It is cleared everywhere the counter is.
* **`rom_loader`'s destination is registered.** After the two above, every
  failing endpoint was `out_off[4] -> sdr_addr[N]` -- the scatter itself, a
  13-way mux over 26-bit shift-adds and then a 26-bit add. Registering `dest`
  is free: `out_off` only moves on `emit`, and two emits are always at least
  two cycles apart because the second waits for the first's write to retire.
  `tb_rom_loader` reports the same cycle count to the cycle afterwards, which
  is the evidence that nothing was slowed down.

The `sdram.sv` change goes nowhere near `dq_reg` or the DQ capture path, which
is the thing section 15.8 says must not be touched.

Result: -0.292 -> -0.348 (worse, and on a different endpoint) -> +0.927. The
middle fit is the lesson. Do not read one fit's worst path as "the" problem, and
do not judge a change by whether the next fit closed -- judge it by whether the
logic it removed was really in the path. Reseeding is still the last resort, and
it was not needed here.

### (2b) Where timing ended up

Each later build in this session re-fitted and stayed positive, so the three
structural changes hold rather than having been one lucky seed:

    after the registering       clk_ram +0.927
    + bytes_out on the probe    clk_ram +0.275
    + the ioctl_wr edge         clk_ram +1.001   <- the build on the MiSTer

The spread across those is the point: the same netlist plus a few flops moves
clk_ram by 0.7 ns between fits. Anything under about +0.3 should be treated as
"met by luck", not as headroom.

### Verification state, and how to re-run it

    make verify                      lint + check-mra + the unit tests
    make -C sim run-bpe ROMS=...     the rdft2 codec against real ROM data
    make -C sim run-video CAP=... SDRAM=...
    make -C sim run-boot GAME=rdft2 SDRAM=... STEPS=400000000

rdfts and all ten rdft2 captures render 0/76,800 pixels different. Regenerating
an rdft2 capture needs a rompath whose `rdft2.zip` carries three 0x117-byte PAL
placeholders and an already-flashed `-nvram_directory`; `make capture GAME=rdft2`
documents both. `SECONDS` must cover `FRAME` at 53.99 Hz, not 60.

`run-boot` needs only an SDRAM image, no capture -- 400M steps is about 80
seconds and reaches well past the Z80 download.

Known-broken and NOT from this work: `make -C sim run-sdram` fails its readback
compare. It is not in `make verify`.

## 10c. rdft2 RUNS ON HARDWARE, and what stood in the way (2026-08-10)

**rdft2 boots on the MiSTer.** Story intro, then the title screen with the
jungle background and sprites: "RAIDEN FIGHTERS 2 / OPERATION HELL DIVE",
(c)1997 Seibu Kaihatsu, INSERT COIN(S). Its download is byte-perfect --
`bytes_in` = 35,752,108 exactly, `bytes_out` = 35,910,452, which is exactly
+158,344, the sample codec's expansion (471,277 - 312,933) to the byte -- and
`part_end` = 16, the sound01 slice.

Getting there took finding a bug that had nothing to do with rdft2 and had been
breaking rdfts too. The rest of this section is that hunt, in the order it
happened, because the wrong turns are the useful part.

### The first run: the download deadlocked in part 15

Deployed and loaded. It did not boot: the ROM download stopped part-way through
part 15 and never finished, so `rom_ready` never asserted and the 386 never
started.

The symptom is not subtle once you know where to look. `MiSTer_Main` HANGS --
`echo load_core > /dev/MiSTer_cmd` blocks forever and the machine will not
switch cores, because the ARM is spinning inside `fpga_spi()` waiting for an
SSPI ack that `sys_top.v` gates on `io_wait`, which is the core's `ioctl_wait`.
So a core that never lowers `ioctl_wait` wedges the whole MiSTer, not just
itself. Recovery is a reboot over ssh.

Measured over JTAG, stable across minutes:

    part_end  = 15
    bytes_in  = 35,373,586      of 35,752,108 for the whole image
    parts 0..14 total           35,308,103
    => 65,483 bytes into part 15, of its 312,933

Part 15 is the CODEC_BPE_DPCM part. So the first set with a decoded part is the
first set whose download stops.

### Why a stalled decoder wedges everything

`rom_loader` holds one byte of skid and raises `ioctl_wait` while it is full.
`feed` needs `dec_in_ready`, and `spi_rom_decode` only asserts that in states
that want a byte. Two of its states never do and never leave on their own:

* **S_DONE**, which it parks in after the last block. If the decoder finishes
  EARLY -- fewer input bytes than the table says the part has -- `in_ready`
  goes low forever, `part_in_full` is never reached, `part_done` never fires,
  and the loader waits for a byte it will not accept while the HPS waits for
  the wait line to drop. Deadlock, both sides blaming the other.
* **S_EMIT**, if `out_ready` never comes -- which would mean an SDRAM write
  that never acked.

Both fit the evidence. Distinguishing them is what `bytes_out` is for, which is
now wired to the JTAG probe (see below).

### The instrument was lying, and had been for two sessions

`spi_jtag_peek.sv` declared `probe_width(193)` while its concatenation had
grown to 195 -- `part_end` 4 bits to 5, `bytes_in` 25 to 26. The top two bits
of `fails` were truncated, and `tools/jtag_peek.tcl`, which slices from the
MSB, therefore misread EVERY field: it reported `part_end = 0x1E` (a part that
cannot exist) and a `bytes_in` off by a factor of five. The numbers above come
from decoding the raw 193 bits by hand.

Fixed: the width is now built by adding up the field widths, the Tcl prints the
width it got and says loudly when it is not what it expects, and `bytes_out` is
wired in -- exactly as `SeibuSPI.sv`'s own comment said to do "when a decoded
set first runs on hardware, because bytes_in alone cannot tell a stalled
decoder from a working one".

### What is NOT the cause

* **Not the codec.** `make -C sim run-bpe ROMS=...` decodes the real
  `sound1.u0222` against `build_soundflash.py`'s reference, under randomised
  output backpressure, and consumes exactly 312,933 bytes. It does not stop
  early on this stream.
* **Not the MRA or the zip.** `check_mra.py --zip` against the archive on the
  MiSTer passes on all 17 parts, and rebuilds the flash image to the sha256
  MAME's own flash devices hold.
* **Not the new part 16.** The download never reaches it.
* **Not timing.** This build meets timing on every clock.

### The download is wrong for rdfts TOO, and always has been

This is the real finding, and it reframes everything above. With the probe
fixed, rdfts -- the set that has been "working" for a week -- reports:

    part_end  = 13          (correct, its last part)
    bytes_in  = 46,792,704  = EXACTLY 2 x 23,396,352
    bytes_out = 46,792,704
    ok        = 0000        all four regions MISMATCH
    fails     = 1 of 1 pass

    region    hardware    reference image
    PRG       146E86E4    741393AF
    CHARS     3CBDE728    79A0EB60
    TILES     CFE42328    D3E9E887
    SPRITES   2AD8C8C3    DCD037DA

The four constants in `spi_romcheck.sv` are NOT stale -- recomputing them from
`tools/build_sdram_image.py`'s output reproduces them exactly, all four. So the
checker is right and what is in SDRAM is not the reference image.

**It is not a regression from this session.** Reflashing the previous build
(the one taken off the MiSTer before this session's RBF went on) and reading
the raw probe by hand gives the SAME four wrong sums, to the digit, and the
same doubled `bytes_in`. This has been true for as long as the misaligned probe
has been hiding it: `ok` was being read from the wrong bit position, so
"check fails = 0" was never a statement about the hardware.

Two candidates, and `bytes_in` = exactly 2x is the clue:

1. **The ROM image is sent twice** and the second pass is harmless (same bytes,
   same addresses) -- in which case the sums must be explained some other way,
   and the checker or its read path is the thing at fault.
2. **`ioctl_wr` is sampled twice.** It is a one-`clk_sys`-cycle pulse and
   `rom_loader` samples it on `clk_ram`, which is exactly 2x `clk_sys` and
   phase aligned from the same VCO, and there is NO edge detector on it. Two
   samples per byte would double `bytes_in`, double `bytes_out`, and re-hold a
   byte that was already fed -- writing each source byte to two consecutive
   destinations, which would scramble every region exactly as observed.

(2) explains all four numbers with one mechanism and (1) explains none of them,
so (2) is where to start. The fix is an edge detector on `ioctl_wr` in
`rom_loader`, and the test is this same telemetry: `bytes_in` must land on
23,396,352 and `ok` on 1111.

What makes this worth being careful about is that rdfts nonetheless BOOTS and
plays on this hardware, which a scrambled image should not allow. So one of the
two stories is incomplete.

### SETTLED: `ioctl_wr` was being acted on twice. Screenshots decided it.

The MiSTer takes its own screenshots -- `echo "screenshot name.png" >
/dev/MiSTer_cmd`, and the file lands in `/media/fat/screenshots/`. That is a
far better instrument than anything over JTAG, and it settled the contradiction
in one shot: **rdfts renders a 320x240 all-black frame**, on this build and on
the pre-session build alike. It is not playing. The menu core screenshots at
58 KB of real content from the same mechanism, so the capture works.

So the checksums were telling the truth and the "but rdfts works" objection was
simply out of date. Which makes hypothesis (2) the answer, and it reproduces in
simulation the moment the bench models the real pulse:

    tb_rom_loader, rdfts, ioctl_wr held 2 clocks:
      FAIL: telemetry says in=46792704 out=23396367

46,792,704 is the number the hardware reported, to the byte.

The fix is an edge detector on `ioctl_wr` in `rom_loader`. The bench now runs
every set BOTH ways, one clock and two, and the two must agree -- which also
required fixing the bench's producer model: it never let `ioctl_wr` fall
between bytes, so with an edge detector only the first byte was ever seen. A
byte is now `pulse` clocks high followed by `pulse` low, which is one cycle of
the producer's clock each way.

### A SECOND instrument bug: PEEK reads 32 MB too high

The obvious next step is `tools/jtag_peek.tcl dump 0x0 8`, to read the start of
the 386 program straight out of SDRAM and compare. It returns bytes that are
not the reference image and that show a duplication pattern -- which looks like
confirmation of (2), and **is not usable as evidence**, because the peek's own
address is wrong:

    rtl/spi_jtag_peek.sv:118    wire        go   = source[25];
    rtl/spi_jtag_peek.sv:119    wire [25:0] addr = source[25:0];   // <-- includes go

`source` is 26 bits and the Tcl sends `{go, addr[24:0]}`, so bit 25 of the
address IS the go bit and is 1 for every request. Every peek therefore reads at
`addr + 0x2000000`. On a 32 MB module that bit lands on A[9], a don't-care
column bit on a 512-column part, and aliases harmlessly back -- which is why
this has never been noticed. **On the 64 MB module rdft2 needs, it does not
alias: it reads 32 MB higher, off the end of the image.** The header comment
says `source = {go, addr[25:0]}`, 27 bits, which is what the code should have
been.

So: fix the address, THEN take the dump. Three separate things were being read
through a broken instrument this session -- the probe width, the field offsets,
and this -- and each one produced a confident wrong number. Fix the instrument
first.

**Fixed 2026-08-11 by widening, not by masking.** The parenthetical above ("widen
`source` if the map ever needs the full 26") was already true when it was
written: `SDR_SPRITES_BASE` is 0x1100000 with 24 MB behind it, so the image ends
at 41 MB and `source[24:0]` would have left the top 9 MB of the sprites
unreachable -- which is precisely the region T-G asks about. `source` is 27
bits, `go` is `source[26]`, `addr` is `source[25:0]`, and the Tcl sends 26
address bits. See T-F.

### Confirmed on hardware

With the edge detector in:

    rdfts   bytes_in  23,396,353   bytes_out  23,396,352   ok 0111
            sum PRG, CHARS, TILES all match the reference EXACTLY
            screenshot: the Raiden Fighters attract plane. It plays.

    rdft2   bytes_in  35,752,108   bytes_out  35,910,452   part_end 16
            screenshot: story intro, then the title screen with sprites

So part 15 was never a bug of its own -- it was the first place a corrupted
stream could not be survived. A BPE stream with a duplicated byte reads a bogus
block count, finishes early, and parks the decoder in S_DONE with `in_ready`
low, which is the hang. Every other part just took the wrong bytes quietly.

Two loose ends, neither blocking:

* **rdfts' SPRITES sum still mismatches** (76809831 vs DCD037DA) while the
  other three regions are exact. It may be real, or it may be the checker's
  own reads: `spi_romcheck` loops forever and later passes run while the sprite
  engine is hammering ch4, which is the contention case those repeat passes
  exist to catch (13c). Read `passes` and `sum SPRITES` twice: if the sum moves
  between passes it is the read path, if it is stable the data is wrong.
* The PEEK address bit (T-F), so SDRAM can be read back on a 64 MB module --
  which is what would settle the above directly.

### Take screenshots. They are the cheapest instrument here

This session spent a long time reasoning about what the hardware might be doing
from JTAG counters, THREE of which were lying, when one screenshot would have
said "black screen" immediately and pointed straight at the ROM image. The
command is one line over ssh and needs no capture card, no JTAG and no server:

    echo "screenshot slop.png" > /dev/MiSTer_cmd     # -> /media/fat/screenshots/
    scp root@192.168.1.125:/media/fat/screenshots/slop.png .

Take one FIRST, before reading a single counter. Reading it:

* a ~1100-byte PNG at 320x240 is an all-black frame; real content is tens of KB,
  so the file SIZE alone answers "is it drawing anything";
* screenshot the menu core as a control if the mechanism itself is in doubt
  (58 KB of content, from the same path);
* when a counter and the screen disagree, suspect the counter. Every JTAG
  reading this session that contradicted the screen was the instrument's fault.

The capture card (Elgato 4K X, `/dev/video2` -- ALWAYS find it with
`v4l2-ctl --list-devices`) is for motion, for what the analog path does, and it
is the only way to get the AUDIO off the board. For audio it has two input
profiles and the default is the wrong one:

    pactl set-card-profile alsa_card.usb-Elgato_Elgato_4K_X_...-02 input:iec958-stereo
    pw-record --target alsa_input.usb-Elgato_Elgato_4K_X_...-02.iec958-stereo \
              --rate 48000 --channels 2 --format s16 out.wav

`input:analog-stereo` records perfect digital silence from a perfectly healthy
core, and PipeWire owns the device so `arecord -D hw:N,0` returns EBUSY. Grab a
frame first and look at it: a silent recording and an unplugged HDMI input are
the same measurement until you do. For
"what is the core drawing", the MiSTer's own screenshot is better: no cable, no
scaler in the way, and it is the core's native 320x240 rather than a 1080p
rescale.

## 10d. The instrument is trustworthy now, and rdft2's sound matches MAME (2026-08-11)

T-F and T-G are both closed, and neither ended where it was expected to. The
sound is verified against MAME rather than against an opinion.

### T-F: the address bit, plus a SECOND bug the fix exposed

The widening (see T-F) is confirmed on hardware: `dump` at ten sites across the
map, 16 words each, against the image `tools/build_sdram_image.py` produces.

    prg, chars, snd01, tiles, sprites at 0x1100000, 0x1FFFF00,
    0x2000000, 0x2100000, 0x22FFF00                 16/16 exact, every site

0x2000000 and above are the ones that matter: those addresses did not exist as
far as the old instrument was concerned. The Z80 window at 0x0200000 "failed"
all 16 and that is the good news -- the loader never writes it, so the
reference image holds 0xFF there, and what the hardware actually holds is
`C3 67 00 ...` = `sound1.u0222[0x60000]`, the Z80 program the 386 downloads at
boot. Both ends of that 128 KB check out (0x200000 and 0x21FF80, 16/16 each),
which is the first time rdft2's download has been confirmed on hardware rather
than in simulation.

**The second bug: `go` and the address do not update together.** With T-F fixed
the dumps were still wrong about one word in seven, and the wrong values were
always a NEIGHBOURING word. The measurements that pinned it, in order:

* the same address read 30 times -- 30 identical, correct values. So it is not
  noise, contention or the SDRAM;
* alternating two addresses -- 0x0000000 sometimes returns the data for
  0x0000008. One address bit, bit 3, carried over from the previous request;
* 120 sequential reads, one-phase: 103 correct, 17 wrong, all 17 a word within
  +-64 bytes.

`go` shares the ISSP source word with the address and the RTL does not see all
27 bits change in one cycle, so a request can fire on a half-updated address.
The read then lands on a neighbour and returns entirely plausible data. Fixed
in `tools/jtag_peek.tcl` alone: write the address with `go` HELD, then re-write
with only `go` flipped, so both writes carry identical address bits. Same 120
reads two-phase: **120/120**.

Worth keeping in mind for any future ISSP source that carries a strobe next to
data: this is a property of the primitive, not of this design. And note what it
would have done to a debugging session -- every value it returns is real data
from real SDRAM, just from the wrong place, so nothing looks broken.

### T-G: the data was right and the CHECKER's constant was stale

rdfts' SPRITES sum has mismatched since the interleave landed. It is neither
the data nor the read path:

* 48 sites x 64 bytes across the whole 12 MB sprite region, hardware against
  the reference image: **384/384 exact**;
* the sum computed over the reference image in Python is **76809831** -- which
  is exactly what the hardware reported. The two agree perfectly.

So the download is right and `spi_romcheck`'s hardcoded `SUM_SPRITES` was
wrong. `git log -S` dates it: the constant was set in 68ccd06 and the sprite
interleave landed later in 21d8192, which permutes the bytes within each tile.
Every byte is still present, so a CRC would not have moved -- but the sum is
over 32-bit WORDS, and the permutation changes those. The constant was never
re-derived.

Fixed, and **`ok bits 1111`, `fails 0` on hardware** -- the first time all four
regions have verified. `build_sdram_image.py --sums` now prints the four
constants in the form `spi_romcheck.sv` declares them, so re-deriving is one
command instead of an act of memory. A layout change is not a content change;
only the former moves these.

**There WAS a bench that would have caught this, and it was rotten in exactly
the way 10a records for tb_video's sprite check.** `sim/tb_romcheck.cpp` had
`SDR_SIZE = 0x1680000` -- the map as it stood before the 26-bit widening -- so
it loaded only the first 23 MB of a 41 MB image and the sprite region read back
as zeros. Its corruption pokes were pre-widening too: the TILES poke landed in
the `snd01` window and the SPRITES poke in the tiles, so two of the four cases
were testing nothing at all. It takes its size from the file now, refuses an
image that stops short of the sprite region, and pokes the current bases. All
five cases pass:

    clean image -> F,  PRG -> E,  CHARS -> D,  TILES -> B,  SPRITES -> 7

It is not in `make verify` (it needs a real ROM set), which is why nobody ran
it and why a stale constant survived. Worth running by hand whenever those
constants or the map move -- it is the offline half of `ok bits`.

Note the constants are **rdfts'**. On the cartridge sets the regions that
genuinely differ are expected to mismatch, and what is useful there is the
reported sum, not the ok bit.

### rdft2's sound, measured against MAME

The Elgato's DIGITAL input is the one that carries HDMI audio
(`pactl set-card-profile ... input:iec958-stereo`); the analog profile records
digital silence, which looks exactly like a dead core. Confirm the capture path
with a frame grab before trusting a silent recording -- the same lesson as the
`/dev/video0` one, in audio.

130 s of attract off the hardware against 200 s of the same attract out of MAME
(`-wavwrite`, pre-flashed nvram). MAME's own flash, incidentally, came out
sha256 `c0da4614...`, byte-identical to `tools/build_soundflash.py` -- the codec
re-confirmed for free.

| measurement                                   | result                        |
|-----------------------------------------------|-------------------------------|
| envelope alignment vs MAME (20 ms RMS)        | r = **0.951** over 130 s      |
| long-term spectrum shape                      | r = **0.9927**                |
| per-frame spectral correlation                | median **0.967**, 87% > 0.8   |
| windows where hardware is silent but MAME plays | **0**                       |
| silent-window agreement                       | 99.9%                         |
| synth overruns / voices                       | **0** / 23-27 sounding        |

The envelope correlation is the one that says the sound PROGRAM is right: the
same notes start and stop at the same times for over two minutes. The spectral
figures say the synthesis is right. Neither could have been had from the
telemetry, which happily reports a healthy engine playing the wrong thing.

**The one divergence found, and it is real: rdft2 should be STEREO.** Hardware
L and R never differ by more than 1 LSB (side/mid -73.7 dB -- that 1 LSB is the
capture path). MAME's rdft2 is genuinely stereo, side/mid -14.5 dB, 14.5% of
samples differing by more than 256. MAME's driver is explicit about why:
`spi()` routes `ymf.add_route(0, "speaker", 1.0, 0)` and `(1, ..., 1)` and the
PCB notes say "CN121 - Output connector for left/right speakers", while
`sxx2e()` is `add_route(ALL_OUTPUTS, "mono")` with the comment "Single PCBs
only output mono sound".

`spi_top.sv` hardcodes `audio_l = audio_r = snd_audio`, which is correct for
rdfts and wrong for the two cartridge sets. The ingredients are already there:
`ymf271_synth.sv` computes `g0` and `g1` per slot from `p_ch0`/`p_ch1` and then
throws the separation away at `cvsum <= chclip(g0) + chclip(g1)`. Stereo means
carrying two accumulators and selecting on `set_id`. See T-K.

Also measured, not explained: MAME's summed output is 2.58x the hardware's
level. Some of that is MiSTer's own output level and some may be the mono sum
normalisation; it is not a clean factor of two and nobody has chased it. It is
a level difference, not a shape difference -- the spectra above are normalised.

## 10b. Where the project stands (end of 2026-08-09, before the rdft2 arc)

(Superseded by 10a above, which is the current state.)

**CORRECTION, 2026-08-10.** Read the "verified on hardware" claims below with
care: the build that was actually sitting on the MiSTer at the start of the
next session rendered rdfts as an all-black frame, and its four ROM checksums
all failed, because of the `ioctl_wr` double-sample in 10c. So a download that
was silently corrupt was in place for at least part of the period this section
describes. Either the earlier verification ran on a build that behaved
differently, or "boots to attract with sprites and sound" was read off a
picture nobody re-checked afterwards -- there is no way to tell now. What IS
established is that both sets run correctly on the build at the head of this
repo. Treat every dated hardware claim in this section as unconfirmed rather
than as a baseline to reason from.

Two mainboard revisions run on hardware, both deployed to the MiSTer at
192.168.1.125 and both said to be verified in that session:

* **SXX2E** (`rdfts`) -- the original target. Frame is BIT-EXACT against MAME,
  0 of 76,800 pixels differing, on two independent captures. Sound plays with
  0 PCM overruns.
* **SXX2C** (`rdft`, pre-flashed) -- the SPI cartridge mainboard. Boots to
  attract with sprites and sound from an MRA that ships the sample flash
  pre-programmed, so no reflash ritual.
  (**Re-confirmed on the current build, 2026-08-15** -- this is the one claim in
  this section that has since been re-established rather than left unconfirmed.
  See T-J: attract screenshots across the cycle, plus 18 voices and 0 overruns.
  What had been mistaken for it in between was the board's TEST MODE menu, and
  that was the MRA's saved Service Mode DIP.)

The deployed core is SEED 3, timing met on every clock: clk_ram +0.735,
clk_sys +1.517, TNS 0.000. `make verify` passes; `make -C sim lint-top` is
clean for the first time.

**Built but not yet wired to anything:**

* `spi_rom_decode.sv` -- the ROM-download codec unit. CODEC_RAW passes bytes
  through; CODEC_BPE_DPCM is rdft2's sample-flash decompressor, verified exact
  against the real stream. Wired into `rom_loader` and into `files.qip`; the
  MRA selects it per part through the index-1 config.
* `spi_rise10_decrypt.sv` -- RISE10 sprite decryption for rdft2/rdft2us,
  verified against MAME over 2048 words including `sprite_reorder`. In
  `files.qip`, and `spi_sprite` now muxes it against SEI252 on `set_id`, with
  the chunk stride arriving as a port alongside it.
* Tile keys for all three families are defined, all three verified, and
  `spi_layers` now takes them as ports with `spi_top` selecting on `set_id` --
  along with the fore-layer tile base, which depends on the tile region size
  and needed the tile code widened to 16 bits.

**The immediate decision** is recorded in section 0: an in-core decoder that
builds the flash contents from raw ROM at load time, versus the authentic flash
controller. **The decoder path is built** -- `rtl/spi_rom_decode.sv`, chosen
per part by the MRA, verified against the real rdft2 stream (section 0). The
controller still needs a writable ch5, a save file and a long first boot, and
remains the fallback for any game whose packer is not worth cracking.

**What rdft2 still needs: the sound01 window, for its Z80 program.** (Built
since, and verified -- 10a(1). The measurement below is what it was built to,
and is why it is still worth reading.) The video path is done -- ten captured
scenes match MAME exactly, sprite starvation included (section 0). Sound is
not, and the gap is in the CORE, not the MRA.

rdft2 keeps its Z80 program in `sound1.u0222[0x60000..0x7FFFF]` and the 386
reads it through the sound01 window before releasing the Z80 from reset. rdft
does not -- its copy is in `maincpu`, already loaded -- which is exactly why
rdft can drop sound01 and rdft2 cannot. Section 0 predicted this; it is now
measured. Pre-flashed, with the updater skipped, rdft2 still issues **131,072
dword reads over 0x1380000-0x13FFFFC**, which is region 0x980000-0x9FFFFC, which
is `sound1.u0222[0x60000..0x7FFFF]` exactly and nothing else.

`spi_cpu.sv` decodes main RAM, I/O and the PRG ROM; anything else reads as zero,
so today the 386 would push 128 KB of zeros through port 0x688. What it needs is
a fourth 386 read window at 0x1380000 backed by SDRAM. Two details make it
smaller than it sounds: only 128 KB of the 10 MB window is ever touched, and the
386 reads it as dwords with only byte 0 meaningful (`sound1` is ROM_LOAD32_BYTE
on lane 0), so the core can store it PACKED and expand `{24'b0, byte}` on the
way out -- and a 4-dword cache-line burst is then four consecutive bytes, one
64-bit SDRAM read. The PCM region has 512 KB spare above rdft2's 2 MB flash
image, which is where the 128 KB can live without moving the map.

rdft2 has never been run on hardware.

## 11. TASKS

Open, in the order they block things (updated 2026-08-15). All four sets run on
hardware, so nothing below blocks a working board -- these are about knowing
whether it is RIGHT.

- [x] **T-J** rdft's attract. **Service Mode off, and it is attract: the title
      logo over a live demo, twelve screenshots across the cycle (2026-08-15).**
      The diagnosis was right -- it was the MRA's saved DIP, nothing in the core.
      Frames are 75-144 KB now against TEST MODE's 3.2 KB, which is the same
      signal the fast-load timing harness tripped over. The demo progresses
      (forest terrain, then rock, then back to forest as it loops) with all four
      layers and sprites: shot patterns, homing missiles, explosions, the text
      layer's copyright and INSERT COIN(S), and the licensee line.
      **The sound half of 10b's claim is confirmed too**, which the pictures
      cannot do. Read over steady attract after a `tools/slop clear`: Z80 PC
      moving (01EF then 1A35 -- one sample cannot tell a running CPU from a
      stuck one, two can), 18 voices, 0 synth overruns, `ymf writes` climbing
      29,544 -> 36,370, `fifo2 push/pop` 42/42 which is the SXX2C-only path this
      board takes, `fifo peak` 12 of 511 and full for 0.000 s.
      **A transient that looks exactly like T-O, and is not.** The FIRST read
      after the DIP change showed `frame gap` 21991 = 0.393 s with the two-frame
      stall latch fired at CS 0018 EIP 0026D573. Cleared and re-measured over 90
      s of attract: `frame gap` 1036, which is one frame exactly, and the latch
      never fires. So the gap was the mode transition, not a live fault -- worth
      recording because a cumulative counter read straight after a reset or a
      DIP toggle wears T-O's signature and means nothing.
- [x] **T-H** Listen to rdft2. **It plays, and it matches MAME.** Heard first,
      then measured over 130 s of attract against MAME's own `-wavwrite` of the
      same sequence: envelope r = 0.951, long-term spectrum r = 0.9927,
      per-frame spectral median 0.967, and ZERO windows where the hardware is
      silent while MAME is playing. 0 synth overruns with 23-27 voices
      sounding. Section 10d. One real divergence fell out of it -- see T-K.
- [x] **T-I** Play rdft2. **Played to a death on the second boss, and it
      passes.** Six starved sprite lines across the whole credit (42 -> 48, not
      per frame), `layer ovrun 0`, 0 synth overruns, `frame gap` 1036 = one
      frame with the stall latch never firing, `fifo peak` 16 of 511.
      Per-channel occupancy peaks at 31.52% total with sprites at 7.89% and
      tiles flat at 20.5%, so the RISE10 fetch path holds under live load and
      the bus is two thirds idle at its worst. Section "rdft2 played through"
      (2026-08-14), which also records why the VITL y-hit counters cannot be
      read as per-frame figures.
- [x] **T-F** The JTAG instrument. **Confirmed on hardware, and it exposed a
      second instrument bug on the way** (`go` and the address not updating
      atomically -- one read in seven landed on a neighbouring word; fixed in
      the Tcl, 120/120 after). Section 10d has the measurements.
      `spi_jtag_peek.sv`'s `addr` was `source[25:0]`
      where bit 25 IS the go bit, so every PEEK read 32 MB high -- harmless on a
      32 MB module, useless on the 64 MB one rdft2 needs. Section 10c.
      **Fixed by widening rather than by masking**, which is the option 10c
      leaves open and the map turns out to require: `SDR_SPRITES_BASE` is
      0x1100000 and the sprites are 24 MB, so the image runs to 41 MB and a
      25-bit address could not reach the top 9 MB of it -- exactly the region
      T-G is about. So `source` is 27 bits now, `go` is `source[26]` and `addr`
      is a full `source[25:0]`; `tools/jtag_peek.tcl` sends `dec2bin $addr 26`.
      Builds clean and every clock is still positive with TNS 0.000 (clk_ram
      +0.961, clk_sys +1.869, clk_cpu +4.293). **Not yet exercised over JTAG**
      -- the first PEEK on hardware is what confirms it, and T-G is the thing
      to point it at.
- [x] **T-G** rdfts' SPRITES checksum. **Neither the data nor the read path:
      the checker's own expected constant was stale.** The sprite interleave
      (21d8192) permuted the bytes within each tile, which changes a sum over
      32-bit words while leaving every byte present, and `SUM_SPRITES` was
      never re-derived from 68ccd06. Hardware now reports `ok bits 1111`,
      `fails 0`. Confirmed two independent ways before touching it: 384/384
      words exact across the 12 MB region against the reference image, and the
      sum computed over that image equals what the hardware reported. Section
      10d; `build_sdram_image.py --sums` stops it recurring.
- [x] **T-L** rfjet against MAME frame by frame. **Eleven scenes, every one 0 of
      76,800 pixels different, 0 starved sprite lines**, including two at 24.6k
      and 26.2k y-hits -- heavier than rdft2 has ever been tested. Two negative
      tests confirm the check can fail: RISE10 instead of RISE11 differs on
      66.6% of pixels, and the post-reorder word index instead of the
      pre-reorder one on 35.5%. No PAL placeholders needed (unlike rdft2), and
      the pre-flashed nvram is just `build_soundflash.py`'s image split in two.
- [x] **T-M** rfjet on hardware. **Boots to attract with sprites and sound,
      first try** -- the only set that has ever done that. bytes_in 39,303,645
      exactly as predicted, bytes_out +121,581 (the codec's expansion), all
      four SDRAM regions checksumming identical to the reference image, 12
      voices, 0 synth overruns, and 1-2 starved sprite lines per frame at
      ~14,000 y-hits. Timing +0.357 on clk_ram.
- [~] **T-N** Play rfjet, and listen to it against MAME. **The listening half is
      DONE and passes**: 198 s of attract against 420 s of MAME gives spectrum
      r 0.9855, per-second median 0.9844 with 96% above 0.8, silence agreement
      99.9% (`tools/compare_audio.py`). Envelope r is 0.9025 and the two weak
      30 s chunks are event timing, not synthesis -- the worst of them
      correlates 0.9972 spectrally, which is the attract demo diverging.
      Playing it is what found the bank 4-7 bug in the first place. What is
      still owed: actual play -- coin, start, a credit through -- which is also
      what T-O needs.
- [~] **T-O** The gameplay hitch -- a quarter to half a second, occasionally,
      during play. **Gone with the bank 4-7 fix**: a full play session records a
      worst frame gap of 1054 units, one frame, and the two-frame stall latch
      never fires. Left open rather than closed because it was never explained.
      Every reading that "cleared" the sound FIFO and ch3 was taken on the FIXED
      core, which shows neither is active now, not that neither caused it. The
      likely mechanism is the one none of the four marks watch: the 386 waiting
      at 0x684 d1 for a reply the sound program, working from a null pointer
      table, never sent -- `fifo2 push`/`pop` run to about 16 for a whole
      session, so those messages are rare and individually load-bearing.
      Confirming it means putting the old core back to measure a stall that is
      already fixed. If it ever returns: `tools/slop clear`, play, then
      `tools/slop sound` prints `stall at CS:EIP`.
- [x] **T-K** rdft2, rdft and rfjet should output STEREO; the core was mono.
      **Done, and MEASURED ON HARDWARE: rdft2 side/mid -25.3 dB against
      rdfts' -81.7 dB on the same bitstream**, where rdft2 read -73.7 dB
      before. The two rows differ only in the MRA's mod byte, so the per-board
      select is verified end to end, which simulation cannot do.
      `ymf271_synth` carries two accumulators -- left takes chip outputs 0 and
      2, right takes 1 and 3 -- so their sum is the old mono bit-for-bit and
      the halves read separately are the cartridge's stereo. The select is
      `set_sxx2c`, which `spi_sound` already had, because the split is
      per-BOARD: rdfts is `sxx2e()` and mono, the other three reach `spi()` and
      are stereo. `test_stereo_split` covers both directions and all twelve
      existing cases still pass bit-identical. Section "Stereo, which is two
      accumulators and a board flag" (2026-08-14), including a level prediction
      that is consistent but not yet controlled. What is still owed: -25.3 dB
      is stereo but narrower than MAME's -14.5 dB, and the two figures come
      from different passages of attract, so comparing them means capturing the
      SAME passage on both sides. Nobody has listened to it yet either.
      The original finding, kept because it is the measurement that started it:
      measuring against MAME (10d): hardware side/mid is -73.7 dB (L and R
      differ by at most 1 LSB, which is the capture path), MAME's is -14.5 dB.
      MAME's `spi()` routes YMF output 0 to the left speaker and 1 to the
      right -- the cartridge PCB has a left/right connector -- while `sxx2e()`
      is `ALL_OUTPUTS -> mono`. So this is per-BOARD, not per-set, and rdfts is
      correct as it stands. `ymf271_synth.sv` already computes `g0` and `g1`
      per slot and then discards the separation in `cvsum`; the work is a
      second accumulator and a `set_id` select in `spi_top.sv`. Nothing about
      the music is wrong -- the spectra match -- so this is fidelity, not a
      fault.
- [x] **T-A** clk_ram timing. Was -0.292; every build since is positive with
      TNS 0.000 (the deployed one is **+0.352**, and it read +0.961 one fit
      earlier from the same source -- see the warning about spread), by registering `rom_loader`'s
      part table and its destination and `sdram.sv`'s emergency-refresh
      compare. Section 10a(2), worth reading for the fit that got WORSE in the
      middle and for how much clk_ram moves between fits.
- [x] **T-B** rdft2's sound01 window, 128 KB at 386 address 0x1380000, so the
      386 can download the Z80 program. Section 10a(1). Verified by the game's
      own boot code in `run-boot`: 131,072 bytes into the Z80's memory, byte
      for byte the ROM they came from.
- [x] **T-C** rdft2 on hardware. **It boots and runs** -- story intro and the
      title screen with sprites. Its download is byte-perfect: bytes_in
      35,752,108, bytes_out exactly +158,344 (the codec's expansion), part_end
      16. What had blocked it was not rdft2 at all but `ioctl_wr` being acted
      on twice in `rom_loader`, which was corrupting every set's download.
      Section 10c.
- [ ] **T-P** The authentic boot-up flash, as a second set of MRAs: let the game
      run its own sample-flash updater instead of shipping a derived image.
      Section 17 has the whole plan. Three of section 0's six line items are
      already built (the SXX2C board, the wave-memory port's read direction, the
      2 MB region); what is left is the 386's `sound01` source window, an
      E28F008SA command FSM, a write port onto the PCM region with the sample
      cache invalidated, and nvram persistence. **Do the source window first:**
      without it the ritual completes successfully and programs 2 MB of silence,
      because the undecoded window reads as zero. Verified by dumping SDRAM and
      matching `tools/build_soundflash.py`'s sha256, which is already exact
      against MAME's own flash nvram.
- [ ] **T-D** Optional, ~10% of the sprite line budget: the line-buffer
      generation tag that replaces the 320-cycle clear. Tried and reverted --
      start by proving `bank_tag` actually toggles. Nothing needs it now that
      the sprite ROMs are interleaved.
- [ ] **T-E** Bench rot: `run-sdram` fails its readback compare (identically
      before this work) and is not in `make verify`. `run-boot` was the other
      half of this and is fixed -- it now takes a set, drives ch3 in both
      directions and checks the Z80 download. `run-romcheck` was a THIRD case,
      fixed 2026-08-11: it was sized to the pre-widening map, so it loaded 23 MB
      of a 41 MB image and failed SPRITES on a perfect one, and two of its four
      corruption pokes pointed at the wrong regions entirely. All five cases
      pass now (10d). The pattern is worth naming: every bench that is not in
      `make verify` has rotted, and each one rotted at the 26-bit widening.
      Worth re-reading `run-sdram`'s
      failure in the light of 10c: it is the ONE bench that drives the loader
      into a real `sdram.sv`, and it has been failing a readback compare the
      whole time the hardware download has been suspect. Retested after the
      `ioctl_wr` fix and it still fails, but the failure is now pinned and it
      is NOT the loader:

          chip saw: 26,345,472 ACTIVE, 2,949,120 READ, 23,396,352 WRITE
          checked 23,592,960 bytes, 22,893,589 differ, every one FF

      23,396,352 writes is EXACTLY rdfts' image, so the loader and the
      controller put the right number of bytes into the behavioural chip. The
      readback then returns 0xFF for nearly all of it. So the fault is in the
      read side -- the bench's readback loop or `sdram_model.sv`'s read path --
      and this bench has never been proving anything about writes. Fix the
      read side and it becomes the only test that drives `rom_loader` through a
      real `sdram.sv`, which is exactly the gap 10c fell into.

- [x] **T1** Repo skeleton: `sys/` from Template_MiSTer, `SeibuSPI.{qpf,qsf,sdc,sv}`,
      `files.qip`, PLL, Makefile, README.
- [x] **T2** ROM loader with per-part scatter, SDRAM controller + map, and the
      fetch-time GFX decryption units.
      - `rom_loader.sv` verified byte-exact against the MAME region layout
        (23,396,352 bytes, `sim/tb_rom_loader.cpp`).
      - `spi_tile_decrypt.sv` verified against MAME's `decrypt_tile()` for all
        three key sets (73,728 vectors).
      - `spi_spr_decrypt.sv` verified against MAME's `seibuspi_sprite_decrypt()`
        over all 4096 `addr` values (65,536 vectors), including the pixel
        mapping, not just the arithmetic.
      - Tables are generated from MAME by `tools/gen_spi_tables.py` (a parser)
        while the test reference is copied from MAME by `tools/gen_ref_c.py`
        (an extractor). Two independent paths from the same source, so agreement
        validates the parser rather than being self-consistent.
- [x] **T3** z386 integration: main RAM, PRG ROM window + mirror, I/O decode,
      vblank IRQ / vector 0x20, uncacheable-window patch.
      - `rtl/z386/` vendored at `516ced0`; the one local change is kept as
        `patches/z386-uncached-window.patch` and is backward compatible.
      - `rtl/spi_cpu.sv`, `rtl/spi_io.sv`, `rtl/spi_mainram.sv`.
      - QSF must define `Z386_QUARTUS_M10K_UCODE=1` and `Z386_ALTERA_ALU=1`,
        as upstream's own project does. Without the first, the microcode ROM
        synthesises into logic instead of M10K.
      - `files.qip` must list `z386_pkg.sv` before everything else, and the
        Verilator lint target too — a plain glob sorts it last and every type
        reference then fails.
      - Two bugs worth remembering: the bus `ready` has to be combinational
        (a registered one accepts every write twice, because `l1_cache` holds
        `valid` until it observes `ready`), and `cpu_addr` is declared `[31:2]`
        so the main RAM dword index is `cpu_addr[17:2]`, not `[15:0]`.
- [x] **T4** Video: DMA engines, palette, 4 layer pipelines, sprite engine,
      mixer, 320x240 output + ROT270.
      - [x] `spi_dma.sv` — tilemap / palette / sprite DMA, including the oddly
            interleaved rowscroll destinations and the segment skipping when
            rowscroll is off. Triggers are edge detected because they arrive
            from clk_cpu, where one cycle spans two clk_sys cycles.
      - [x] `spi_layers.sv` — back / midl / fore (16x16 6bpp) and text
            (8x8 5bpp), rendered one line ahead into double-buffered line
            buffers, sharing the SDRAM gfx channel and the tilemap RAM port.
            Fetch-time tile decryption is wired in here.
      - [x] `spi_mixer.sv` — MAME's exact composite order including the
            "draw back again" step, the alpha table, and BGR555 expansion.
      - [x] `spi_dpram.sv`, tilemap / palette / sprite RAMs.
      - [x] Golden-reference harness against MAME (see section 12). The frame
            diff went from 100% wrong to **40.1%** as four real bugs fell out.
      - [x] **All four layers verified 299/300** against reference scanlines
            (back, midl, fore, text). The one remaining pixel is the phase
            edge at x=0.
      - [x] **Mixer verified exact.** Compositing `spi_layers`' own line
            buffers per MAME's order reproduces the mixer's RGB output
            0/298 pixels differ. Composite order, transparency handling and
            palette indexing are all correct.
      - [x] Two real phase bugs fixed while proving that: the line buffer read
            has to lead by **two** pixels (the palette sequence plus the
            composite), and the mixer must not gate on `visible` -- that signal
            refers to the pixel being displayed, but the pixel being
            composited is two ahead, so it blacked out column 0 of every line.
            The video path already blanks with HBlank/VBlank.
      - [x] `spi_sprite.sv` written and wired. It also turned up a real
            address bug: **the sprite DMA trigger is at 0x50E, not 0x562**.
            `sxx2e_map` calls `sei252_map` (0x50E); 0x562 is `rise_map`, used
            by rdft2/rfjet. Both are now decoded. MAME went from reporting 1
            sprite DMA per 900 frames to 894.
      - [x] **The fore layer is correct.** Dumping the per-emit record
            (screen x, emit_i, tile code, pixel) shows the RTL matching the
            reference at every position. The apparent one-pixel offset was in
            the *probe*: line buffer readback is one ahead, and that only
            showed on fore because back/midl/text are uniform on the rows
            probed, so any shift matched them.
      - [x] **Frame 18.2% wrong, and it IS the sprites.** Proven properly this
            time: for a mismatching pixel, every palette entry producing
            MAME's colour is below pen 4096, and pens below 4096 are sprite
            pens -- no tile-layer pen in the palette yields it. The earlier
            "64% match a sprite pen" was a weak coincidence argument and the
            subsequent claim that sprites were NOT involved was wrong; both
            are superseded by this.

            **The blocker is the capture, not the engine.** Both MAME's
            `:sprite_ram` share and the trigger-time DMA source read as all
            zeros, yet MAME plainly draws sprites from that data, so the
            capture is faulty. Until it is fixed `spi_sprite` has nothing to
            draw and cannot be validated. Suspects: the sprite DMA may use a
            source register other than 0x494, or writes to 0x50E may not be
            the only trigger.

            **Resolved, and the diagnosis above was only half right.** Every
            capture from 13a onwards carries real sprite data -- tb_video's
            per-pixel sprite check and 13b's sweeps both read it -- so the
            engine finally had something to validate against. The score came
            down 18.2% -> 7.89% -> 1.78% -> 0.23% through the mixer fix (13a)
            and the concurrent scan/draw, horizontal culling and fetch/emit
            overlap (13b). The largest single piece of what "IS the sprites"
            actually was is in 13a: the mixer pairing one pixel's colours
            with the next pixel's draw decisions.
      - [x] **The alpha blend is exact** -- section 13c. The mixer does
            MAME's `(src*127 + dst*129) >> 8` rather than a 50/50 average,
            which removes the entire +-1-per-channel error class: 26,492
            pixels of the frame-2400 capture to zero, and the raw frame score
            from 34.70% to 0.24%.
      - [x] **The left-edge band is fixed** -- it was a line-buffer bank
            race, not the mixer: the display read the bank the *renderer*
            was pointing at, and that flip is deferred to a tile boundary.
            The read side now comes from `vcnt[0]` in both `spi_layers` and
            `spi_sprite`. **tb_video passes exactly, 0 of 76,800 pixels
            differing, on two independent captures.** See 13c.

      The fore layer's long-running failure turned out NOT to be a decode bug
      at all. `line_start` was only honoured in `S_IDLE`, so when a line's
      rendering overran -- 104 tiles at ~30 cycles against 3584 cycles a line
      is genuinely marginal -- the sequencer just carried on and `render_line`
      and `render_bank` drifted out of step with the display. Every layer
      stayed individually correct, which is exactly why it read as a decode
      problem. Restart is now deferred to a tile boundary, so an in-flight
      SDRAM request is never abandoned with its ack outstanding.

      **Throughput is the thing to watch.** At a realistic 4-cycle SDRAM
      latency the renderer needs 2801 of 3584 cycles per line, and the sprite
      engine has to fit in what is left. Overlapping the next tile's fetch
      with the current tile's emit is the obvious win.

      Build state with the tile layers in: 0 errors, 0 negative slack,
      67% ALMs, 77% RAM blocks, 3,265,253 block memory bits.

      **A frame-level testbench came before the sprite engine, and that was
      right.** Both bugs found while writing T4 (the RAM read off-by-one and
      the RGB multi-driver) produced silently wrong data rather than a build
      failure, and the same class of bug in the render path is invisible
      without comparing actual pixels. That harness is section 12, and every
      T4 fault since has been found through it.

      **What is left on T4:** nothing for correctness -- the frame is exact
      against MAME on two captures. Optional headroom only: `spi_layers`
      renders layers the game has disabled, and issues two 64-bit reads per
      text column for a 6-byte char row.
- [x] **T5** Sound: T80, banking, FIFOs, coin latch, YMF271 (PCM then FM).
      - [x] `rtl/t80/` — T80 vendored from Arcade-IremM72_MiSTer. VHDL, so
            Verilator cannot read it; `sim/T80s.sv` is a port-compatible stub
            that exists only so lint and the C++ testbenches elaborate.
            Quartus never sees it — it is not in `files.qip`.
      - [x] `rtl/spi_sound.sv` — Z80 at clk_sys/8 (7.1590909 MHz, exact), 8 KB
            RAM, the 386→Z80 FIFO, the coin latch, the bank register, and the
            program fetch out of SDRAM ch3 behind an 8-byte line buffer.
      - [x] `rtl/ymf271.sv` — the 0x6000 register file, the four FM banks' sync
            write fan-out, timers A and B, the status/end flags and the IRQ.
      - [x] `rtl/ymf271_pcm.sv` — 48-slot PCM synthesis at 44100 Hz.
      - [x] `rtl/spi_sdr_arb2.sv` — ch3 now has two owners after boot (the Z80
            and the JTAG peek) and needs arbitration.
      - [x] **FM and both LFOs landed** — see section 15. `ymf271_pcm.sv`
            became `ymf271_synth.sv` and now walks 12 groups x 4 slots: the
            28 algorithms collapse to one 28-entry wiring table over an
            invariant slot1/slot3/slot2/slot4 order, plus the amplitude and
            pitch LFOs. Pipelined to meet clk_sys (15.6) — no state may hold
            more than one ROM read or one multiply.
      - [x] `sim/tb_ymf271.cpp` drives the chip's own register interface and
            checks 8-bit playback, 12-bit unpacking, the loop fold and end
            status, timer A + IRQ, and key-off release — now ten checks with
            the FM ones (carrier, modulation, chain + feedback, both LFOs)
            and `test_all_algorithms`' sweep of 24 networks, 15.4 / 15.7.
            All pass.
            `tools/check_ymf271_math.py` checks the phase step against MAME's
            doubles over all 600,064 (fns, block, fs, multiple) combinations.
      - [x] **Heard on hardware, 2026-08-04** — section 14.9. Nothing above
            `ymf271` can be simulated (the Z80 is VHDL), so the Z80 bus, the
            FIFO, the coin latch and the ch3 arbiter were only ever reasoned
            about; the measurement is what cleared them. Z80 PC advancing,
            ~45 FIFO reads/s, 7-12 slots sounding and tracking the music,
            **0 PCM overruns on every reading**, L and R bit-identical as
            SXX2E requires. `tools/slop sound` reports all of it; see 14.6.
      - [x] **The two YMF271 gaps worth closing are closed.** The **wave
            memory data read register (utility 0x14-0x17 plus offset 2)** is
            implemented as the read-ahead MAME models, and is the port SXX2C
            flash needs (section 0); `tb_ymf271` reads 32 bytes back and
            requires the sample ROM verbatim. **Sync 3 no longer forces PCM**
            on a group whose slots are not waveform 7. See 14.5 -- including
            the service-point mistake the first version made, which lost
            bytes under polyphony.
      - [x] **The rest of 14.5 is a decision, not a backlog.** Each remaining
            item fails one of: it cannot be verified (MAME itself is unsure,
            or nothing reachable exercises it), it costs more than it returns
            (interpolation against a 27-cycle slot budget; a shadow byte per
            slot with RAM blocks at 86%), or it is the sound driver's
            heartbeat and not worth diverging on untestably. Reasons are
            written out at the end of 14.5.

      Build with FM, the LFOs and the pipelining in (15.8): 0 errors, TNS
      0.000 on every clock, **78% ALMs**, **86% RAM blocks**, 53% DSP. Setup
      slack clk_ram +0.641 ns, clk_sys +0.919 ns, clk_cpu +3.044 ns. RAM
      blocks are now the tightest resource. (The PCM-only build before FM was
      77% ALMs / 82% RAM / 44% DSP.)
- [x] **T6** MRA, docs, build verification.
      - [x] **`tools/check_mra.py`, wired up as `make check-mra`.** Three
            copies of the part list have to agree and nothing at runtime
            checks them: MAME's `ROM_START(rdfts)`, `mra/rdfts.mra`, and
            `rom_loader.sv`'s table. The MRA carries no scatter information
            at all -- the loader infers everything from the part INDEX -- so
            a reordered or dropped part loads to the wrong address silently.
            The checker compares order, name, CRC, size, scatter mode and
            destination address, using MAME as the authority rather than
            `build_sdram_image.py`, which is ours and could share a mistake
            (the section 12 trap). Optionally confirms every part resolves
            out of a real zip by CRC. Proven to catch a swap, a one-digit
            CRC error and a dropped part. All 14 parts currently agree.
      - [x] **`make verify`** = lint + check-mra + test, and it passes.
      - [x] **`make test` never ran the tests.** `sim/Makefile` defined
            `lint-sound` above `all`, so it was the default goal and
            `make -C sim` linted one module instead of running the suite.
            `all` is now first. This is why the ordering matters more than
            it looks: the root Makefile calls the sub-make with no target.
      - [x] **`make -C sim capture`** produces the golden capture and the
            SDRAM image, so `run-video` / `run-dma` are reproducible instead
            of depending on paths from whoever last ran them -- `CAP`
            defaulted to a scratch directory that no longer existed.
      - [x] README brought up to date: the frame is bit-exact, the MRA check
            and capture flow are documented, and the fitter-seed procedure is
            written down where someone hitting a negative `clk_ram` will find
            it.
      - [x] `releases/` refreshed to the current RBF and MRA. Note it is
            **gitignored** -- a local staging directory, not a tracked
            artifact, so "refreshed" means on disk only and no RBF is ever
            committed.
      - [x] **Clean-from-scratch build verified.** `make clean && make build`
            from an empty `db/`, `incremental_db/` and `output_files/`: 0
            errors, timing identical to the incremental build (`clk_ram`
            +0.443, `clk_sys` +1.241), and the RBF **byte-identical** to the
            one in `releases/` and running on the MiSTer. So nothing in the
            incremental database was masking a file missing from
            `files.qip`, and the build is deterministic.

Order matters: T4 is the visible payoff and depends only on T1–T3. T5 can lag.

- **MiSTer MRA parts are matched by CRC first, not by name.** Main_MiSTer's
  `FileOpenZip()` calls `zip_search_by_crc()` and only falls back to
  `mz_zip_reader_locate_file()` on the name. So an MRA carrying correct `crc=`
  attributes loads correctly even from a merged set, where a clone's files are
  stored under the parent's names (rdfts vs rdft) or behind a path prefix.
  I initially "found" a bug here by reasoning about the loader instead of reading
  it, and built a whole tool to work around a problem that did not exist.
  tools/make_rdfts_zip.py survives as a way to produce a clean non-merged
  rdfts.zip, but it is not required.
  Lesson: when the diagnosis depends on what another component does, go read that
  component. Main_MiSTer is checked out at ~/proj/Main_MiSTer.

- **Active-low FIFO flags at 0x684.** MAME's `fifo7200_device` exposes `ef_r()`
  and `ff_r()` as `!m_ef` / `!m_ff` -- they model the _EF and _FF *pins*, which
  are active low, not the internal flags. So d0 reads 1 when the 386->Z80 FIFO
  has room and d1 reads 0 while the Z80 has sent nothing back. I had both
  inverted, so the 386 believed the sound FIFO was permanently full and spun in
  the sound handshake a couple of seconds into the boot -- after it had already
  set up the CRTC and run a dozen palette DMAs, which is why the screen showed a
  few stray coloured pixels rather than nothing at all.
  Lesson: when a MAME accessor negates something, that negation is usually the
  hardware pin polarity and belongs in the RTL too. Also: a "hang" that leaves
  the free-running raster alive is a *poll loop*, not a stall -- probing the CPU
  address bus named the culprit in one run, where staring at the RTL had not.

- **Never duplicate sdram.sv's dq_reg.** It sits directly on the DQ input path
  and belongs in the I/O cell. I split it into per-channel copies with
  `preserve` to chase a reported -0.054 ns *fabric* slack, and that let the
  fitter drag copies out towards their consumers and destroyed the *input*
  timing: the first 16-bit word of every burst read came back as unstable
  garbage that changed on every read of the same address. Symptoms looked exactly
  like an SDRAM too fast for the module, and I wrongly concluded 114.545 MHz was
  unreachable on this board and halved clk_ram to 57.272727 to work around it.
  Reference cores run this register single at 120 MHz; restoring it single made
  114.545 MHz byte-perfect (all four checksums exact, zero layer overruns) with
  timing closing at +0.379 ns. The original -0.054 ns violation never came back;
  at the time USE_CH5 was 0, which had removed some load, but ch5 is enabled now
  for the YMF271's PCM reads and clk_ram still closes.
  Lessons: chasing a tiny fabric slack broke a path the SDC does not even
  constrain; and "it is too fast for the hardware" is a conclusion to reach only
  after checking what a working core does differently -- IremM92 runs 120 MHz on
  this very board, which is what finally pointed at the real cause.

- **Debugging this needs hardware access, and it is available.** The MiSTer is at
  192.168.1.125 (root/1); `echo "load_core /media/fat/_Arcade/rdfts.mra" >
  /dev/MiSTer_cmd` loads the core, so deploy-and-measure is fully scriptable. An
  an Elgato 4K X captures the output for automated frame analysis -- ALWAYS find
  it with `v4l2-ctl --list-devices`, never by assuming a node. This file said
  /dev/video0 for months; that is the built-in webcam, and the Elgato came up on
  /dev/video2. Capturing from the wrong node photographs the room and looks like
  a core rendering garbage,
  and the USB-Blaster gives In-System Sources & Probes via tools/jtag_peek.tcl
  (PEEK reads any SDRAM address, SUMS reports checksums and download telemetry,
  VITL reports CPU counters plus CS:EIP, GDTS snoops the GDT the boot code
  builds). Use them before theorising -- three wrong diagnoses in this session
  came from reasoning where a measurement was available.


## 13. Current state (end of the hardware debugging session)

The core boots into Raiden Fighters attract mode on real hardware: the 386 runs
in protected mode (CS=0018), services vblank interrupts, and drives one tilemap
and one palette DMA per frame, in lockstep with vblank. The back, midl and fore
layers are pixel correct -- masking the text layer off shows the attract artwork
rendering perfectly.

PARTLY RESOLVED: the TEXT layer used to paint a solid opaque block over the top
two thirds of the rotated screen. That was bandwidth, and the shortfall was
itself caused by the dq_reg mistake above forcing clk_ram down to 57 MHz. At
114.545 MHz the renderer reports ZERO overruns, the block is gone and the text
layer is now correctly transparent over most of the screen.

SPRITES FIXED TOO. spi_sprite wrote its line buffer at {~render_bank, x} while
spi_layers writes {render_bank, x}, and the mixer reads {lb_wrap ? render_bank :
~render_bank, x}. So the tile layers rendered into the back buffer (correct
double buffering) but the sprite engine rendered into the buffer being displayed
and then cleared it at the next line start, so the mixer only ever saw valid=0.
Sprites now render recognisably -- aircraft, bullets, shot trails, explosions.

Telemetry added to spi_sprite (dbg_scanned / dbg_yhit / dbg_emitted, on the VITL
probe) is what proved the engine itself was fine: it was scanning, passing the y
test and emitting tens of thousands of pixels into a buffer nobody read.

BOTH OF THE FAULTS BELOW WERE ONE BUG IN THE MIXER, found 2026-08-08 and fixed.
Kept because the wrong diagnoses are instructive:

  1. On hardware, a band of striped garbage over source lines 128..208 in the
     demo gameplay. Isolated properly (CPU frozen via mask bit 5, same scene,
     text on vs off): the right band reads 31 with text enabled and 7 with text
     disabled, identical to the good left band. It IS the text layer. Do not
     read too much into the 128 boundary -- rows 0..15 may simply have no text
     in that scene, so the layer could be wrong everywhere and only visible
     where the game draws.
  2. sim/tb_video (golden reference against a MAME capture) reports 7.21% of
     frame pixels differing, and 5210 of the 5537 mismatches match a SPRITE pen.
     So sprites are still substantially wrong even after the bank fix.

Fault 2 was NOT sprites. "Matches a sprite pen" only ever meant "some pen below
4096 happens to have this colour", and in a 6144-entry palette that is weak
evidence. It survived three separate sessions as a conclusion. Both faults were
the mixer pairing one pixel's colours with the next pixel's draw decisions --
see section 13a.

The bank fix is confirmed good by measurement, not assumption: old bank scores
8.03% on the golden test, fixed bank 7.21%, and only the fixed one puts sprites
on screen at all.

Ruled out for the text layer by inspection against MAME (do not redo):
pix8 plane extraction, char_off = code*48 + fine_y*6, the row_bytes window
(char offsets are only 0/2/4/6), both 64-bit gfx reads happening for text,
emit_grp = emit_i[3:2] selecting group 0 for pixels 0-3 and 1 for 4-7,
tcode/tcolor split, tile_index = row*64 + col with SCAN_ROWS, the DMA
destination offsets, and the text DMA moving the full 1024 dwords (measured on
hardware via the dma_text_dw probe).

CAPTURE YOUR OWN GOLDEN FRAMES. The original capture was a quiet scene and hid
two sprite bugs and the tile-layer offset. Making a new one takes a minute:

  cd ~/proj/mame && SLOP_OUT=<dir> SLOP_FRAME=2400 ./mame rdfts \
    -rompath "<roms>" -autoboot_script ~/proj/SlopperPI/tools/mame_capture.lua \
    -video none -sound none -seconds_to_run 45 -nothrottle

SLOP_FRAME picks the frame; 600 is the early attract screen, 2400 is the title
with the jungle background and heavy sprite traffic. Then point tb_video at it.

USE sim/tb_video AS THE ITERATION LOOP. It runs in seconds, needs no hardware,
and localises errors per layer. The rotation mapping is calibrated: source vcnt
maps directly to display X (panel bar N sits at display x ~= 555 + N*50), and
source hcnt maps to display Y inverted. Force the panel on over JTAG with
mask bit 6 to re-calibrate.

Isolate on hardware with the JTAG masks and the CPU frozen:
    quartus_stp -t tools/jtag_peek.tcl mask 32   # freeze, all layers
    quartus_stp -t tools/jtag_peek.tcl mask 47   # freeze, sprites only
    quartus_stp -t tools/jtag_peek.tcl mask 55   # freeze, text only
Note the earlier "the text layer draws garbled blocks" conclusion was NOT sound:
those captures were taken at different points in the attract cycle, so the
comparison was confounded. Always freeze the CPU (bit 5) before comparing.

Ruled out for the text garbage: the 5bpp pixel extraction. MAME's readbit is
MSB-first within a byte, so MAME bit N is w[23-N]; pixel 0's five planes land on
v[16], v[12], v[8], v[4], v[0], which is exactly what pix8() does. The
row_bytes window selection also covers every offset chars can produce
(code*48 + fine_y*6 gives offsets 0, 2, 4, 6 only). And most text tiles ARE
correctly transparent, which they could not be if the decode were broken. Look
instead at the tile codes reaching the layer and at the colour field / palette
base (pen_text = 5632 + colour*32 + pen).

The diagnosis chain for the original block, kept because the telemetry is worth
reusing:

  * Masking layers one at a time (JTAG-driven, with the CPU frozen so the
    attract mode stops moving) shows only the text layer contributes to it.
  * spi_layers renders back, midl, fore, text in that order and abandons a line
    at the next line_start if it has not finished. Telemetry says the overrun
    layer is ALWAYS 3 (text) and the text layer only reaches column 12 of 41.
  * Columns 13..40 are therefore never written, lb_text keeps its reset value of
    0, and pen 0 is not the transparent pen -- MAME uses
    set_transparent_pen(31) for the 5bpp text layer -- so it composites opaque.
  * Those unrendered columns map to the top of the rotated screen, which is
    exactly where the block appears.

The 10%-of-lines overrun rate never did square with a solid block on every
line, and that discrepancy is still unexplained -- but with overruns at zero the
block is gone, so it is moot unless it resurfaces.

On clock ratios, since it cost a lot of time: clk_ram does NOT need to be a
multiple of clk_sys for the *logic* -- every crossing is a toggle handshake.
But sys/sys_top.sdc puts all PLL outputs in one clock group, so Quartus analyses
clk_ram <-> clk_sys paths, and at a non-integer ratio the closest launch/capture
edge pair is a sliver. 96.923077 MHz (1260/13) built at clk_sys -4.7 ns, TNS
-999. Integer ratios are what make it close; IremM92 pairs 120 MHz SDRAM with a
40 MHz sys clock, exactly 3:1. To use an arbitrary rate, declare the domains
asynchronous and widen sdram.sv's request samplers from one flop to two.

Still worth doing for headroom regardless: spi_layers renders all four layers
even when the game has disabled some, and issues two 64-bit reads per text
column when an 8x8 char row is only 6 bytes.

Sprite engine throughput: the 512-entry list walk used to cost five cycles a
sprite = 2560 of the 3584 cycles in a line, leaving 96 for actual drawing. The
RAM answers two cycles after an address is presented, so the next sprite's first
read is now issued from S_START and S_ATTR/S_NEXTS drop out of the miss path --
three cycles a sprite, 1536 cycles, and roughly 2.6x the drawing time. Two
cycles a sprite is reachable with a proper pipeline if more is needed. There is
a dbg_starved counter on the VITL probe: it fires when a line ends with sprites
still unscanned. Measured at ~0.25% of lines, so starvation is NOT currently the
main cause of missing sprites.

WITHDRAWN: "the BACK tile layer is shifted one pixel horizontally" was NOT a
bug. It was the probe skew of section 11 recurring, and it fooled me the same
way it fooled the fore investigation before it.

The reasoning was: back's offset profile peaks at -1 while fore's peaks at 0,
therefore back is shifted relative to fore. The flaw is that **fore is uniform**
on the probed rows -- it is fully transparent (0x3F) across the whole line in
this scene, one distinct value -- so it ties at every offset from -1 to +3 and
its "best offset 0" is an artefact of argmax picking the first maximum. Only
layers with real content can be compared at all.

Measured properly, on five rows (40, 80, 112, 160, 200) with the per-layer
profile that now prints the reference's distinct-value count:

    back  (20-26 distinct values):  best -1, 299/300, every row
    midl  (27-32 distinct values):  best -1, 299/300, every row
    fore  (1 distinct value):       tied everywhere, meaningless

Both layers that carry content agree at -1, which is exactly what a correct
layer looks like through a readback that leads by one. There is no relative
shift and nothing to fix.

The 38.82% (40.25% on a fresh capture) was also misattributed. It is dominated
by the mixer's **deliberate** blend approximation: MAME does
`alpha_blend_r32(dest, pen, 0x7f)` = `(src*127 + dst*129) >> 8`, the mixer does
a plain 50/50 average, and rtl/spi_mixer.sv:157 records the choice and why
(both exact forms blew clk_sys setup, by 6 ns and 21 ns). That is worth at most
one unit per channel and only on blended pixels, and it accounts for 24854 of
the 30915 differing pixels. Confirmed rather than assumed: for every channel of
the sampled mismatches there are real palette-value pairs (d,s) that produce
our value under the average and MAME's under 127/129 -- e.g. d=66,s=74 gives 70
and 69.

So the frame-2400 score is **7.89% real mismatches**, not 40%, and the diff
"blanketing the jungle background" was the blend approximation blanketing the
blended background, not a shifted layer.

Two things changed in sim/tb_video.cpp so this cannot recur:
  * the offset profile now runs for every layer and prints how many distinct
    values the reference has, flagging `[UNIFORM - offset meaningless]`;
  * the raw percentage is labelled "NOT the score to quote" and REAL mismatches
    is the last line printed.
`SLOP_PROBE_Y=<row>` picks the probe row -- a conclusion from a single scanline
is worth very little here.

Lesson, and it is the third time in this project: before comparing two
measurements, check that both are capable of distinguishing the thing being
compared. A uniform reference matches everything.

NEXT THING TO CHASE: the 7.89%. The sprite-pen classification was also being
computed over the raw set, where the blend pixels outnumber it four to one; it
now runs over REAL mismatches only and reports **3933 match a sprite pen, 2086
do not**. So roughly two thirds of the genuine error is sprites, which agrees
with section 13's other reading, and there is a residual third that is not
sprite-coloured and has never been accounted for. (Superseded: the blend is
exact as of 13c and the residual turned out to be the bank race, so tb_video
now passes with every pixel identical. The paragraph is kept for the reasoning,
not the numbers.)

Fixed and verified on real hardware:
  * SDRAM read corruption -- fixed by restoring `sdram.sv`'s single `dq_reg`.
    **clk_ram is 114.545455 MHz** (pll.v c0). This bullet used to say the fix
    was halving clk_ram to 57.272727; that was the wrong diagnosis and was
    reverted -- see section 10.
  * Sound FIFO status polarity at 0x684 (_FF/_EF are active low).
  * clk_ram setup timing. **Not** by per-channel DQ capture registers: section
    10 records that splitting `dq_reg` per channel is what CAUSED the
    corruption above, and it was reverted. USE_CH5 is also 1 now, not 0 -- the
    YMF271 reads PCM through ch5.

Verified good, so not worth re-investigating:
  * ioctl download delivers all 23,396,352 bytes, all 14 parts (bytes_in probe).
  * Microcode: ucode.mif and ucode.hex agree on all 2560 entries.
  * Timing closes on every clock, no violations.
  * SDRAM contents match the reference byte for byte, including under load.
  * All 14 MRA part CRCs are present in the MiSTer's rdft.zip.

FIXED, and the game now boots and renders: SeibuSPI.sv declared

    wire [31:0] sdr_prg_dout;    // "ch1 386 program ROM (32 bit)"

for a bus that sdram.sv drives 64 bits wide and spi_top consumes 64 bits wide.
Quartus truncated the controller's output to 32 bits and zero-extended it back,
so rom_data[63:32] was permanently zero and *every odd dword the 386 fetched
from ROM read as 0x00000000* -- half the instruction stream was blank. It got
far enough to build a GDT with two corrupt entries, then died on the far jump.

Why nothing caught it: Quartus only warns on width mismatches, the testbenches
declare their own ports correctly so simulation was structurally blind, and
`make -C sim lint` lints spi_top -- never SeibuSPI.sv. The integration file was
the one source in the project that nothing checked. There is now a `lint-top`
target that lints it for WIDTHTRUNC/WIDTHEXPAND/IMPLICIT/PINMISSING; run it.

Lesson: when simulation and hardware disagree and every shared component has
been cleared, suspect the code that only exists on one side of the divide.

## 13a. The mixer bug that was three different bug reports (2026-08-08)

Two RTL faults, found by capturing the SXX2E **test menu** instead of a game
scene. The screen is worth knowing about: it sets `layer_enable = 0x17`, which
disables back, midl, fore **and** sprites, so the frame is the text layer alone
on a flat background. Every previous capture had all layers on, and that is why
this hid for so long -- there was nothing to isolate the text layer against.

Capturing it needed `tools/mame_capture.lua` to trigger on demand rather than at
a fixed frame number, which is what `SLOP_TRIGGER=<path>` now does: MAME runs
normally until that file appears, then captures the next frame. That makes any
hand-driven scene capturable -- a menu, a boss, a particular moment.

### Bug 1: disabled back layer filled with palette pen 0, not black

`screen_update_spi` (seibuspi_v.cpp:452) does:

    if (m_layer_enable & 1)
        bitmap.fill(0, cliprect);

`bitmap.fill(0)` on a `bitmap_rgb32` writes the raw RGB value 0 -- **hard
black**. It is not a draw of palette pen 0, and the two coincide only when pen 0
happens to be black. The mixer read the palette. In the test menu pen 0 is
0x7FFF, so the entire screen came out **white** with the (correctly rendered)
text sitting on it. 98.56% of pixels wrong, and it reads as "the text is
broken" because the text is the only thing on screen.

### Bug 2: colours from pixel N, draw decisions from pixel N+1

After bug 1 the frame was 2.28% wrong, in a very specific pattern: every run of
opaque text pixels sat **one pixel left** of MAME's, and the first pixel of each
run was 0x080808 instead of 0xEFEFEF. Decomposed by shifting our frame right one
pixel: 1510 mismatches -> 755, and *all* 755 survivors were that same colour
pair, every one of them at the start of an opaque run and none mid-run.

That is one bug, not two. The mixer latches each layer's colour during the
pixel (`rgb_back` at step 3, `rgb_text` at step 6 ...) but read `trans_*`,
`spr_valid` and `spr_pri` **combinationally** off `lb_*`. The composite is
sampled at step 1 of the *following* pixel, by which point `lb_x` has advanced,
so the transparency test described pixel N+1 while the colour described pixel N.
Consequences, both observed:

  * the opaque run follows pixel N+1's mask at pixel N's position -- shifted
    one pixel left;
  * at the first position of a run the latched colour is the *previous* pixel's,
    which is the transparent pen. Text transparent pen = 5632+31, whose palette
    entry is 0x080808 -- exactly the dim leading pixel.

Fix: latch `t_back/t_midl/t_fore/t_text/v_spr/p_spr` alongside the colour they
belong to, and use only the latched copies in the composite. The alpha flags
`a_*` were already latched at the right step, which is why blending never showed
this.

### What it scored

    test menu   98.56% -> 0.00%   PASS, exact match, all 76800 pixels
    attract      7.89% -> 1.78%   (REAL mismatches, blend-tolerant score)

Confirmed on real hardware 2026-08-08: built with timing met (clk_ram +0.885,
clk_sys +1.175, clk_cpu +3.827, TNS 0.000 everywhere -- all three better than
the previous build), deployed, and the test menu now renders black background
with clean white text, captured off the Elgato and matching MAME.

The attract residual is now 1369 pixels, 1210 of which "match a sprite pen" --
but that phrase means very little (see the note above), and the same statistic
pointed at sprites when the real fault was the mixer. Treat it as unexplained,
not as a sprite finding.

### The lesson, which is the same one twice

Both faults were invisible in every capture taken so far because those scenes
could not isolate anything: every layer was on, so a text fault was buried under
three other layers, and a background fault was hidden behind an opaque back
layer. **The register state is part of the test case.** When a layer is
suspect, find a scene where the hardware itself turns the others off -- the
game's own test menu did in one capture what a year of attract-mode frames
could not.

And "matches a sprite pen" is not evidence. With 4096 candidate pens, most
colours match one. It survived as a conclusion across three sessions and was
wrong every time.

## 13b. Sprite starvation, and three levers (2026-08-08)

The sprite engine dropped sprites under load, and the symptom was ugly: the
list is walked 511->0 and drawn in that order so entry 0 lands on top, which
means when the budget runs out what gets dropped is the TAIL -- the lowest
indices, the last-drawn, the topmost sprites. Not background clutter: the
player ship. On a frozen scene it showed as a slice cut out of the ship,
vertical on screen because source scanlines map to display X under the
rotation.

Three changes, in increasing order of payoff:

**1. Scan and draw concurrently.** The list walk reads sprite RAM, the drawing
reads SDRAM -- different resources, but the old FSM ran them one after the
other, so 1536 of the 3200-cycle budget was dead time before a single pixel.
Split into a scanner and a drawer with an 8-entry FIFO; the scanner streams at
2 cycles a sprite (the floor for one RAM port and two reads per entry) and the
walk hides entirely behind the drawing. FIFO order is list order, so the draw
order is unchanged. Sim: 246 starved lines -> 0, and the attract frame went
1.78% -> 0.23%, which is where most of that "unexplained" residual went.

**2. Horizontal culling.** There was none: the scanner tested only Y, and the
only X test was per-pixel at write time, AFTER the fetch. A sprite parked off
the side still cost three SDRAM reads and sixteen emit cycles per column for
pixels that were then discarded. Now culled per sprite in the scanner and per
column in the drawer (an off-screen column costs one cycle instead of ~40).
Note it is not free: entering columns via S_COL adds ~1 cycle per column, so on
a scene with nothing off-screen it is a slight net loss.

**3. Overlap the fetch with the emit.** The big one, and the same optimisation
the tile layers already had. Each column serialised three SDRAM round trips
(~21 cycles) and THEN 16 emit cycles. Those use different resources, so the row
data is now double-buffered: the fetcher fills one bank while the emitter
drains the other. Everything the emitter needs about a column (tile code, col_x,
flipx, colour, priority, ry) is captured with the data, because by then the
fetcher has moved on -- possibly to another sprite.

Measured on hardware, starvation against ACTUAL work (y-hits per frame):

    work/frame    before      after
    4000-4399        2.7        0.0
    4400-4799        7.1        0.0
    4800-5199        8.8        0.3
    5600-5999       18.6        0.0
    6000-6399       38.5        0.0
    7600-7999       36.8        0.0
    8400-8799       42.0        0.0

Gone across the whole range, including scenes twice as heavy as the one that
first showed the fault.

### Two measurement lessons, both learned the hard way here

**`codes != 0` is list population, not work.** Comparing builds against it gave
a meaningless result -- some buckets better, some worse, several with n < 5 --
and an early partial sample of it made culling look like a clean win when a
longer sweep showed nothing of the kind. Sprite counts say nothing about how
many pass the y test or how wide they are. Use `spr y-hit` or `spr tiles`.
Both sweeps must also cover the same load range: the first culling comparison
sampled to 184 sprites against 358 and I read the gap as a trend.

**The golden test can go blind without failing.** Splitting the sequencer
changed the state encoding, and `sim/tb_video`'s per-pixel sprite check keys on
`dbg_state == 9`. It reported "0 match, 0 differ (of 0 emits)" and PASSED. Then
when the tap was restored it reported 275 of 640 differing -- also wrong, because
the debug taps were fetch-side (`tile_code`, `ry`) while `half`/`pcnt` are
emit-side, and those are now different columns. `dbg_state` now reports 9
whenever the emitter is running whatever the encoding, and `dbg_tile_code` /
`dbg_ry` come from the emitting bank. A check reporting zero items is a failing
check, not a passing one.

### Restarting the JTAG server leaves jtagd wedged

Killing `jtag_server.tcl` mid-operation leaves `jtagd` in a state where
`get_insystem_source_probe_instance_info` returns "No In-System Sources and
Probes instance was found" even though `jtagconfig` enumerates the chain
happily and the core is plainly running. `pkill -f jtagd` and re-run
`jtagconfig`. Half an hour went into suspecting the build before checking the
host. Also: the server must not be started until the FPGA has finished
reconfiguring after a `load_core`, or it fails the same way.

## 13c. The exact alpha blend, and what it uncovered (2026-08-09)

The mixer now does MAME's blend exactly. The thing that had made this look
expensive was never the arithmetic -- it was doing all ten composite steps in
one cycle.

### The arithmetic

`alpha_blend_r32(dest, pen, 0x7f)` is `(src*127 + dst*129) >> 8`. Rearranged so
there is neither a multiplier nor a signed intermediate:

    127*s + 129*d  ==  127*(s+d) + 2*d  ==  ((s+d) << 7) - (s+d) + (d << 1)

Three adder levels, every term non-negative for all inputs -- `(s+d)<<7` is
always at least `s+d` -- and the maximum is 65280, so the 16-bit accumulator
never overflows and `acc[15:8]` is the truncating `>>8` C gives. Checked
exhaustively against the C expression over all 65,536 `(d,s)` pairs, zero
mismatches.

### The pipeline is the actual fix

A pixel is eight clk_sys cycles and the composite only has to produce one
result per pixel, so the chain gets five cycles instead of one, at most two
exact blends per stage. The palette fetch order changed to make that possible:
it now follows the order the composite first *needs* each colour -- sprite,
back, midl, fore, text -- rather than layer order with sprites last. The old
dead slot 0 (a fetch of pen 0, unused because a disabled back layer is hard
black) is gone.

The tail deliberately runs into the next pixel's first two cycles. That is safe
because every source it reads is a register the next pixel does not overwrite
until later, and it keeps the published output on the same phase, so the
callers' two-pixel `lb_x` lead is untouched and the picture does not move.

**Two facts about the step counter, both of which I got wrong first time:**

* `step` lags `div` in `spi_video_timing` by one cycle, so **step 7 is the
  first clk_sys cycle of an hcnt period**, not the last. `lb_*` is a registered
  line-buffer read, settling one cycle after hcnt moves -- which lands exactly
  on step 0. So all eight steps see the same pixel's `lb_*` and any of them can
  fetch. My first attempt asserted the opposite in a comment; it was wrong.
* A colour written by the fetch case "at step N" is captured on the edge
  **ending** step N and is readable from step N+1. Reading it during step N
  shifts the whole picture one pixel. That is what my first attempt actually
  did, and `best shift: dx=1` in tb_video named it immediately -- that line is
  worth reading before anything else when a change goes wrong.

### Score

    frame 2400, raw pixels differing   26,650 (34.70%)  ->  185 (0.24%)
    of those, within +-1 per channel   26,492            ->  0
    REAL mismatches                       158            ->  185

The +-1 class is gone completely, which is what the change was for. tb_video's
tolerance bucket is kept, re-labelled: it must now read zero, and anything in
it is a blend regression rather than expected noise.

### Timing: the exact blend is free, and clk_ram needed a seed

The pipelining more than pays for the arithmetic. Against the pre-change build
of 15.8, every clock improved:

| clock     | before   | after    |
|-----------|----------|----------|
| `clk_ram` | +0.641   | +0.820   |
| `clk_sys` | +0.919   | **+1.611** |
| `clk_cpu` | +3.044   | +3.999   |

TNS 0.000 on every clock, worst hold +0.221. 78% ALMs, 86% RAM blocks, 53% DSP
-- unchanged but for a fraction of a percent of logic. The blend infers no DSP,
which is the point of writing it as shifts and adds rather than `127*s`.

Getting there took a fitter seed, and the intermediate result is worth keeping
because it is a trap. The first build reported "Full Compilation was
successful" and **failed timing**: `clk_ram` at -0.556, TNS -4.953. Every one
of the worst 25 paths was `sdram|dq_reg -> sdram|chN_dout`, and not one was in
the mixer -- `clk_sys` had *gained* margin in that same build. That is exactly
the path section 10 records destroying SDRAM input timing when it is
restructured, and 15.8 already said the lever is a fitter seed rather than the
register. **SEED 17 -> 5 in the QSF**, rebuilt, and it closed at +0.820 with
nothing else changed. Two lessons, both already in this file and both worth
having relearned: read the Setup Summary rather than the exit status, and when
the failing endpoints are nowhere near the change, suspect placement.

### Confirmed on hardware, 2026-08-09

Deployed to the MiSTer at 192.168.1.125 and measured. The core boots and runs
the attract sequence correctly: Seibu Kaihatsu logo, RAIDEN FIGHTERS title with
the plane, the ACE PILOTS table, the propeller close-up, and the jungle title
with heavy sprite traffic -- which is the scene whose blended background used to
dominate the frame diff. No banding, no wrong colours, nothing out of place.

`slop vitals`: state running, CS:EIP 0018:00203F57, all layers enabled, vblank
advancing at ~54 Hz, layer overruns 0, and **sprite starvation not accumulating**
(static across samples while vblank climbed; the non-zero total is from earlier
in the session). `slop sound`: Z80 PC changing, FIFO reads and YMF writes
climbing, 12-13 voices sounding, **0 PCM overruns** -- unchanged by the re-fit.

**Screenshots are far easier than the capture card.** `echo "screenshot" >
/dev/MiSTer_cmd` writes a PNG to `/media/fat/screenshots/<core>/`, at the core's
native 320x240 and *before* rotation, so it is directly comparable with MAME's
frame and with tb_video's output. No Elgato, no format negotiation, no black
first frame, and no risk of photographing the room. Use this first; section 9b's
capture-card advice is for when actual scanout needs checking.

### What it uncovered: the left edge is a bank race

REAL went slightly UP, 158 -> 185, and that turned out to be the interesting
result. Every one of those 185 pixels is in **source columns 2-5** -- the
histogram of error locations now counts REAL mismatches instead of raw ones,
which is what made the band visible at all; under the old blend it was buried
under 26k rounding differences spread across every column.

It is not the mixer. Three different fetch schedules give 77, 114 and 127 wrong
pixels in column 2, so the error depends on *which cycle the mixer samples
`lb_*`* -- meaning `lb_*` is not stable across the pixel at the start of a
line. Measured directly, with the render bank exposed to tb_video:

    render-bank flips at (vcnt,hcnt): (0,0) (1,2) (2,2) (3,0) (4,0) (5,1) (6,2) ...

`spi_layers` defers `render_bank <= ~render_bank` to a tile boundary (correctly
-- section 11 records why abandoning a line mid-fetch is worse), so the flip
lands anywhere in the first three pixels of a line, jittering per line. Until
it happens the mixer is reading `~render_bank`, which is still the *previous*
line's buffer. That is the band, and it has been there all along.

### Fixed, and the frame is now exact

The fix is on the display side, not the renderer's. `render_bank` keeps the
write side and keeps its deferred tile-boundary flip, which is correct for the
reason the restart path already documents. The read side stops following it:

    wire disp_bank = ~vcnt[0];
    wire [9:0] lb_rd_addr = {lb_wrap ? ~disp_bank : disp_bank, lb_x};

in **both** `spi_layers` and `spi_sprite` -- they have to agree, or the mixer
takes its sprite pixel from a different line than its tile pixels. `vcnt`
changes on exactly the edge the display crosses into a new line, one cycle
earlier than a `line_start`-triggered register could manage, which matters
because the read address for hcnt=0 is presented in that very cycle. It also
cannot drift: VTOTAL is 296, so `vcnt[0]` toggles every line including across
the frame wrap.

    frame 2400   185 wrong  ->  0 / 76800   PASS, exact
    frame  600     - -      ->  0 / 76800   PASS, exact

Frame 600 is an independent capture with a different register state
(`fore_d13=1`, different scrolls), so this is not one frame being fitted. **This
is the first time tb_video has ever passed**, and with the blend exact there is
no tolerance left in the comparison -- 76,800 of 76,800 pixels identical to
MAME, twice.

The render-bank flip still jitters across hcnt 0-2; that is expected and now
harmless, and tb_video still prints it because it is the measurement that found
the fault.

Confirmed on hardware the same day: attract renders correctly with sprites,
`slop vitals` reports running with all layers on, vblank counting, **layer
overruns 0**, and `slop sound` **0 PCM overruns**. Timing met on every clock,
TNS 0.000, worst hold +0.242; `clk_ram` +0.443, `clk_sys` +1.241, `clk_cpu`
+2.568.

**The fitter seed is a lottery on this design, and it is worth budgeting for.**
`clk_ram` is marginal enough that seed choice decides whether a build closes,
and the winning seed is netlist-specific -- 17 failed the mixer-only netlist at
-0.556 and then passed the mixer+bank netlist at +0.443. This round went 5
(-0.155), 12 (-0.428), 17 (+0.443). Two things make that cheaper: a re-fit is
`make fit && make sta && make asm`, which skips `quartus_map` and is much faster
than a full compile; and the failing paths are always the same `sdram|dq_reg ->
chN_dout` and `chN_rq -> SDRAM_A`. The latter is the wide combinational address
calculation section 9.3 already nominates as the first structural lever, so if
seeds ever stop working, retiming that -- not touching `dq_reg` -- is next.

## 14. Sound (T5) — design notes and what is deliberately missing

**The single fact that shapes the whole thing:** on SXX2E the YMF271 is the
sound driver's heartbeat as well as its voice. `ymf.irq_handler()` goes to the
Z80's INT and `audio_vector_r` returns **0xD7 — RST 10h, IM0**, so with the
timers dead the driver never sequences anything. Timers A and B were therefore
implemented before a single sample was played, and both periods are whole
multiples of 384 master clocks, i.e. whole 44100 Hz sample periods, so they
count sample ticks instead of needing a clock of their own.

**Only ONE FIFO exists on this board.** `m_soundfifo[1]` is a nullptr in the
`sxx2e` machine config, which is why the Z80→386 direction is not implemented
and why both of the corresponding status bits read back as zero rather than
being wired to something.

**The 386→Z80 handshake, end to end.** 386 writes 0x680 → `spi_io` (clk_cpu)
raises a one-cycle pulse → `spi_sound` (clk_sys) edge-detects it, since a
clk_cpu cycle is exactly two clk_sys cycles from the same PLL → 512-deep FIFO →
Z80 reads 0x4008. The 386 polls `~full` at 0x684 d0. Coins go the other way:
the Z80 writes 0x4004, the chip latches `0xA0 | data`, and the 386's read of
0x680 clears it.

**Z80 code runs out of SDRAM, not block RAM.** 128 KB would have cost a quarter
of the device's memory blocks, so ch3 is shared and a miss on the 8-byte line
buffer stalls the CPU with WAIT_n. Code is overwhelmingly sequential, so one
SDRAM read serves about eight fetches. `dbg_stall` counts the misses.

### 14.1 The bus-strobe bug that would have been invisible

T80s clears MREQ_n, RD_n and WR_n **on the same clock edge**, so a strobe
written as "RD_n rose while MREQ_n is still low" never fires at all — and by
then the address register is already moving toward the next machine cycle. The
first version of `spi_sound` did exactly that, which would have meant the FIFO
never popped, the bank register never changed and no coin ever latched, with no
error anywhere to point at it. The working form latches the address and write
data while an access is live and triggers on the falling edge of "access in
progress".

Reads take effect at the END of the cycle on purpose: the Z80 samples DI there,
so popping the FIFO any earlier hands it the next byte instead of the one it
asked for.

### 14.2 YMF271 PCM engine

MAME's `update_pcm` / `update_envelope` / `calculate_slot_volume`, re-expressed
as one serial pass over 48 slots per sample. clk_sys/44100 = 1298 cycles per
sample, so the budget is ~27 cycles a slot; an active slot that hits its sample
cache costs about 20 and an idle one about 8. `dbg_overrun` counts samples the
pass could not finish, so that budget is measured rather than assumed.

Everything MAME computes in doubles collapses to integers:

* `calculate_step` — `pow_table` is a power of two, `fs_frequency` is a shift
  and `multiple_table` is a half-integer, so the whole product is one 12x5
  multiply and a signed shift.
* the envelope rates come from two generated tables (attack and decay sweeps of
  the full 255 units, pre-multiplied by 65536) plus one reciprocal table for
  decay1, which is the only step whose sweep is not 255.
* `tools/gen_ymf271_tables.py` emits all of them from `ymf271.cpp` itself, the
  same arrangement the sprite decrypt tables use.

Per-slot state (stepptr, volume, envelope state, active) lives in a 48-entry
RAM, the slot parameters in a 256x64 RAM, and each slot keeps an 8-byte line of
its sample stream so a slot stepping at roughly 1.0 hits SDRAM once every eight
samples instead of every one.

**The FM half and the LFO have since landed** and this section is about the PCM
path only; the operator network, the 28 algorithms and both LFOs are described
in the header of `ymf271_synth.sv`, and what is still missing is in 14.5.

One knowing divergence: MAME latches the four envelope rates at key-on and
keeps them for the note's life. Storing them would cost 96 bits a slot, so they
are recomputed from the LUTs every sample. It only shows if the game retunes a
slot mid-note, and then only in how fast that envelope runs.

### 14.3 Two synthesis traps this hit

**A variable part-select write does not infer a byte-enabled RAM.** The slot
parameter store was written as

    par_mem[addr][{byte, 3'b000} +: 8] <= data

which Quartus turned into **16k flip-flops plus a 256-to-1 mux on 64 bits —
23,229 ALUTs**, a third of the device, for 16 Kbit of storage. Eight separate
byte-wide arrays with their own write enables infer cleanly. Check
`Analysis & Synthesis Resource Utilization by Entity` for any new RAM; a
failure to infer looks like nothing at all until the fitter runs out of room.

**`altsource_probe` caps `probe_width` at 511.** VITL was already at 478, so
appending the six sound counters overflowed it and elaboration failed with a
VHDL assertion out of `altsource_probe_body.vhd`. They live on their own SNDV
probe instead. The "append new fields on the LSB side" rule in §9b still holds,
but it has a ceiling — VITL has 33 bits left.

### 14.4 Controls

Joystick bits 4 and up are the MRA's `<buttons names="..."/>` list **in order**,
and `SeibuSPI.sv` decodes them at exactly those positions. They had drifted
apart: the MRA named eight entries with two `-` placeholders in the middle,
putting Start on bit 9 and Coin on bit 10, while the core read bit 7 as coin and
bit 8 as start. Coin and start were mapped to buttons nobody could press. The
layout is now bit 4 Shot, 5 Bomb, 6 Button 3, 7 Start, 8 Coin, 9 Service Coin,
10 Test, and the two files have to be changed together.

**The debug freeze used to fire on ANY button of either pad**, which made the
game unplayable the moment anyone pressed shot. It now requires the Vital Signs
Panel option to be on, and only Button 3 triggers it.

**DIP polarity here is the opposite of the usual arcade MRA.** MAME's
`PORT_SPECIAL_ONOFF_DIPLOC(0x8000, 0x0000, Flip_Screen, "SW1:1")` makes Off the
bit CLEAR, and a DIPSWITCH field does not take the port's `IP_ACTIVE_LOW`
inversion the way the buttons do. So `<switches default="00">`, not the usual
`ff`, and INPUTS bit 15 passes straight through while bits 14:0 are inverted.

The DIP transfer arrives as ioctl index 254 on the same bus as the ROM
download, so the core's reset had to stop keying on `ioctl_download` alone or
changing a DIP would restart the game.

### 14.5 Divergences, from MAME and from the datasheet

The engine is a port of `ymf271.cpp`, so by default it inherits MAME's reading
of the chip. Yamaha's own documents are in `~/Downloads/OPX`: `YMF271.pdf` is
the 26-page Japanese catalog datasheet (pinout, mode-select table, bank layout,
PCM overview) and `ymf271_trans.pdf` is a translation of the 78-page
application manual, which is the one with the register bit maps and every
numeric table. The four `Ce*.jpg` files are the algorithm diagrams, which
appear in neither PDF.

The whole engine was checked against those documents. What came out clean, and
does not need rechecking: the bus and bank decode, every function- and
PCM-register bit field, the status-flag scramble, the sync-mode mirroring, both
pitch formulas against the manual's own worked examples (C4 lands on 261.60 Hz
against a quoted 261.626, and the external-waveform cent table matches to four
places), all 28 algorithms read off the diagrams, and the RKS, AR/DC, LFO
frequency, PMS, feedback/modulation, channel attenuation, waveform and keycode
tables.

**Two places where the datasheet wins and MAME is wrong.** Both are fixed here,
so the output deliberately differs from MAME:

* **AMS tremolo depth.** `alfo` peaks at 65536, so the constant in
  `lfo_volume = 65536 - ((alfo * K) >> 16)` is the swing and `65536-K` is the
  gain at full modulation. MAME passes the gains themselves — 65536/10^(dB/20)
  for Table 2-6-3's 5.90625 / 11.8125 / 23.625 dB — which lands the gain at
  `65536-K` instead and yields 6.1 / 2.6 / 0.6 dB. The ordering inverts: ams=3,
  the deepest setting in the book, comes out the shallowest by a factor of ten.
  `YMF_ALFO_K` holds the complements, and `tb_ymf271` now asserts the ams=1
  depth is 5.90625 dB rather than comparing against a constant.
* **LFO phase resolution.** `init_lfo` keeps 8 fractional bits below the 8-bit
  shape index and truncates, which makes the step zero for the 161 slowest of
  the 256 settings — everything below 0.673 Hz, where Table 2-6-2 goes down to
  0.00066 Hz. A stalled LFO is not a silent one: phase 0 is the peak of all
  three amplitude shapes, so those slots take a fixed attenuation instead of a
  sweep. `lfo_phase` is 26 bits here, 18 fractional, which is the least that
  keeps setting 0 above zero; every setting now oscillates. Cost is ten bits a
  slot in `st_mem`, which stays a 48 x 96 inferred RAM at 0 ALUTs.

**One place where MAME wins and the datasheet is wrong.** Register 0x10 is the
*high* 8 bits of the 10-bit timer A period and 0x11 the low 2, which is what
`ymf271.sv` does. Section 2-6 3) says the opposite in as many words — 10H is
"Timer-A1", 11H is "Timer-A2, the top 2 bits", and tA = 384·(1024 − (A2·256 +
A1)). MAME contradicts it on purpose, with a comment saying the split matches
the other Yamaha FM chips and not Yamaha's own book. Since the timer is the
sound driver's heartbeat on this board, follow MAME.

**Known gaps, in rough order of how likely they are to be heard:**

* ~~**The wave memory data read register is not implemented.**~~ **Done.**
  Utility registers 0x14-0x17 set the 23-bit address and direction bit, and
  offset 2 returns data. It is a read-AHEAD, exactly as MAME's `read()` is: a
  read returns the latched byte and only then pre-increments and refetches, so
  the first read after setting an address is a dummy and the stream starts at
  address+1. That is the same convention the cartridge flash updater relies on
  when it programs from 0x7FFFFF (section 0). With the direction bit clear the
  port reads 0xFF. Writes through 0x17 advance the address and go nowhere,
  which is what a mask ROM does; on SXX2C that path becomes the flash write.
  `tb_ymf271`'s `ext memory read` check reads 32 bytes and requires the sample
  ROM verbatim.

  Confirmed on hardware 2026-08-09: attract renders with heavy sprite traffic,
  Z80 executing, FIFO reads and YMF writes climbing, 17-23 slots sounding and
  **0 PCM overruns** across every sample -- which is the reading that matters,
  since serving the port at slot boundaries adds an SDRAM round trip to the
  pass. Timing met on every clock (clk_ram +0.841, clk_sys +0.882, TNS 0.000)
  at SEED 5; three of the five seeds swept closed, and the failing endpoints
  were the usual `sdram|dq_reg -> chN_dout`, none on the new address mux.

  **The service point is the interesting part.** The refill is an SDRAM read on
  ch5, which the synthesis pass owns, so it is served at slot boundaries
  (`S_NEXT`) and when idle. Serving it only when idle -- the obvious first
  choice -- lost bytes: under polyphony the pass fills most of a sample period
  while a Z80 `in` is about 88 clk_sys cycles, so back-to-back reads outran the
  refill and got a stale latch. 8 of 32 bytes wrong, and it would have been
  worse on hardware than in the testbench, since the reflash plays music while
  it reads. A slot boundary comes round every 20-27 cycles, which the host
  cannot outrun.
* **PCM samples are not interpolated.** Block description 13 says external
  waveform data is interpolated before the envelope multiply. Nearest-sample
  here, as in MAME, so samples played away from their native rate alias more
  than they should.
* **The external-waveform keycode ignores Src B and Src Note.** Section 2-9(b)
  makes the key code the sum of the sample's base key code and the played
  block/F-number; only the second term is computed, so RKS envelope key-scaling
  on a PCM voice is that of octave 0 regardless of how the sample was recorded.
  MAME has the line present but commented out with "not sure". Note the sum can
  exceed 31 and would need a clamp.
* **Register fields decoded nowhere.** Detune (3xH d6:4, Table 2-6-5), A/L
  alternate loop (PCM 2xH d7), Acc On (BxH d7), EN and EXT Out (0xH d7 and
  d6:3, which route a voice to CH4-7 and so *out* of the DO1/DO2 mix), PFM
  (utility 0xH d7, FM with an external PCM operator source), and the status
  Busy flag, which always reads 0. Every one of these is also on MAME's own
  TODO list at the top of `ymf271.cpp`.
* ~~**Sync 3 forces PCM on any group.**~~ **Closed.** `step_is_pcm` is now
  gated on the slot actually carrying waveform 7, so a sync-3 group outside
  groups 0, 4 and 8 sounds its operators instead of playing from sample
  address 0 (its start/end/loop bytes are never written). Still latent -- the
  games never do it, which is why MAME can afford to `fatalerror` on the same
  case in `update_pcm()` rather than handle it.
* **`fns` / `block` update immediately.** MAME's `write_register` case 0x9 does
  `fns = (fns_hi << 8 & 0x0f00) | data` and `block = fns_hi >> 4`, so writing
  register 0xA alone changes nothing until register 9 is written — which is the
  datasheet's rule too (2-6 AxH: write Block and F-Number2 before F-Number1).
  Here both fields are decoded straight out of the stored bytes, so a lone 0xA
  write takes effect at once. Drivers write A then 9 together, which gives the
  same result except for the one sample where a tick falls between them.
* **Timer A and B free-run once started.** Register 13H's Load bit is
  documented as start on 1, stop on 0; nothing stops them here. That is MAME's
  behaviour too: the "stop" branch in `ymf271_write_timer` case 0x13 is only
  reachable when the enable bit is already set, so it can never be taken.
* **Channel levels D, E and F are 1/65536, not silence.** The book says ∞
  attenuation, MAME uses 96.1 dB. Inaudible, listed so nobody re-derives it.

**Everything still on that list is left there on purpose, not forgotten.** The
two that were worth closing are closed; each of the rest fails at least one of
the two tests that matter here.

*It cannot be verified.* The engine is checked by predicting its output from
MAME's own formulas, so a change MAME does not make has nothing to score
against. The external-waveform keycode is the clearest case: MAME has the Src B
/ Src Note term written out and commented `not sure`, so implementing it means
guessing, and the sum can exceed 31 and would need a clamp nobody can calibrate.
Detune, A/L alternate loop, Acc On, EN / EXT Out, PFM and the Busy flag are the
same -- all on MAME's own TODO, none reachable from a driver we can run.

*It costs more than it returns.* PCM interpolation is real per the datasheet and
we do not do it, but it adds a second sample fetch and a multiply to a 27-cycle
slot budget, and it would break the one test that proves the PCM path
end-to-end -- that a ramp in the ROM comes back verbatim. `fns`/`block`
deferring until register 9 is written would need a shadow byte per slot, and RAM
blocks are the tightest resource in the design at 86%; the divergence it removes
is one sample in a race the drivers do not run.

*It is the heartbeat.* Timers A and B free-run once started because MAME's stop
branch is unreachable. The datasheet says the Load bit should stop them, and
that is probably a MAME bug -- but this chip's timer IS the sound driver's
sequencer on this board (14), and 14.5 already resolved the one other
timer-versus-datasheet conflict in MAME's favour for exactly that reason.
Diverging here on an untestable reading risks silence, and buys nothing
observable.

So the audio is finished in the sense that matters: everything reachable from
the hardware we emulate is implemented and checked, and what is left is either
MAME's uncertainty or a deliberate trade recorded above.

Also noted for later: `sxx2g` boards clock the YMF271 at 16.384 MHz rather than
16.9344, which moves the sample rate to 42666.7 Hz and scales every envelope
and LFO table by 16.9344/16.384. `rdfts` is `sxx2e` and runs at the documented
clock, so the hardcoded 44100 and MAME's `clock_correction` of 1.0 are right
for the only supported set.

### 14.6 What to check first when this is put on hardware

`tools/slop sound` (or `quartus_stp -t tools/jtag_peek.tcl sound`), in order:

1. **Z80 PC changing at all.** If it is stuck the sound CPU never started, and
   the most likely cause is the ch3 arbiter or the ROM line buffer, not the
   YMF271.
2. **fifo reads > 0.** The 386 writes commands whether or not anything listens;
   this is the first evidence the Z80 is executing the driver.
3. **ymf writes > 0**, then **pcm slots > 0**. Slots sounding but no audio
   points at the sample fetch or the volume chain; no slots points at the
   driver or the key-on path.
4. **pcm overruns.** Should be 0. If not, the 27-cycle-a-slot budget is wrong
   and the sample rate is being stretched.

New failure mode to be aware of: 0x684 d0 is now a real FIFO-full flag rather
than the constant "there is room" it used to be. A Z80 that never runs will let
the 512-entry FIFO fill and then the 386 will spin in the sound handshake --
the same symptom as the polarity bug in section 12, from a different cause.

### 14.7 The Z80 sits at the bottom of the SDRAM priority list

`sdram.sv` serves ch2 (tiles) > ch1 (386) > ch4 (sprites) > ch5 (PCM) > ch3,
and ch3 is where the Z80's program fetch now lives. It is the right order --
starving the video shows on screen, starving the Z80 only makes the sound CPU
run slower, and the YMF271 timers keep their own time regardless. But it does
mean a stalled fetch waits behind everything, so if the sound driver ever
misses its tick under heavy sprite load, this is where to look. `dbg_stall`
counts the misses; it does not measure how long each one waited.

### 14.8 What the simulation does and does not cover

`make -C sim run-ymf271` drives `ymf271` through its own register interface --
the same writes a sound driver makes -- and requires the mixer output to be the
sample ROM contents verbatim. That works because with total level 0, all four
channel attenuations at 0 dB and the envelope saturated, MAME's arithmetic
collapses to `out == sample`, so a ramp in the ROM has to come back as that same
ramp. It covers the register decode, key on and off, the phase step, address
generation, the line cache, 8- and 12-bit unpacking, the loop fold, the end
status flag, the envelope reaching maximum and releasing to silence, and timer A
with its interrupt.

Only the phase pointer is modelled in C, straight out of `update_pcm`. A second
fixed-point model of the volume chain would only prove the two agree with each
other -- the `tb_rom_loader` mistake in section 12.

**Two testbench bugs worth remembering**, because both produced confident wrong
answers about the RTL:

* The 44100 Hz accumulator was only advanced on the clocks the sample loop
  looked at, not on the ones inside `run()`. It therefore skipped every other
  tick and reported the voice playing at exactly twice the correct rate --
  indistinguishable from a phase step that is one bit off.
* `endaddr` and `loopaddr` are offsets from `startaddr`, not absolute
  addresses: MAME compares them against `stepptr>>16` and reads at
  `startaddr + (stepptr>>16)`. Setting them to absolute addresses read at twice
  the intended offset.

**Not simulated at all: everything above `ymf271`.** The Z80 is VHDL, so
`spi_sound` -- the bus strobes, the FIFO, the coin latch, the bank register, the
ROM line buffer -- and the ch3 arbiter have been built and reasoned about but
never executed. That is where to look first if the board comes up silent.

### 14.9 First hardware run — sound works

Deployed to the MiSTer at 192.168.1.125 and measured, 2026-08-04.

Telemetry over `tools/slop sound`, sampled repeatedly:

| reading | value | meaning |
|---|---|---|
| Z80 PC | changes every read (009D, 0143, 0168, 0286, 012A…) | the sound CPU is executing |
| fifo reads | climbing, ~45/s | the Z80 is taking commands from the 386 |
| ymf writes | climbing steadily | the driver is programming the chip |
| pcm slots | 7 - 12, dropping to 0 between tracks | voices sounding, tracking the music |
| **pcm overruns** | **0, every reading** | the 27-cycle-a-slot budget holds under load |

Audio captured off the HDMI through the Elgato and measured: peak 27% of full
scale, RMS ~1200, sustained over 35 seconds, strongest components at 105-250 Hz
and a zero-crossing rate that moves between seconds -- music, not a stuck tone.
**L and R are bit-identical**, which is correct: SXX2E sums all four YMF outputs
onto one speaker.

The clincher is that the audio and the telemetry agree about the *silence*. The
attract sequence has a gap between tracks; across it the per-second RMS went
`2297 2024 1527 399 1 1 1 460 575 838` while the slot count read 10, then 2,
then 0, then climbed again. The core is playing the game's music, not an
artefact of the measurement.

**`dbg_stall` cannot be read as a rate.** It is a free-running 16-bit counter
and it wraps faster than it can be sampled -- four readings 0.4 s apart gave
61278, 63214, 56093, 50728, which implies two different rates depending on which
interval is used. This is the same trap as the sprite counters in section 9b and
it was not fixed for this one. All it establishes is that the ROM fetch path is
busy. Latch it per frame if the actual number ever matters.

Also confirmed on the same run: the picture is unaffected (title screen renders
upright, so the flip-screen DIP defaults correctly), CS=0018 with EIP advancing,
all layers enabled, vblank counting.

The first capture-card frame after opening the device is black. That is the
artefact section 9b describes, not a dead core -- check the JTAG vitals before
believing a black frame.

## 15. FM and the LFO (finishing the audio)

`ymf271_pcm.sv` is now `ymf271_synth.sv`. The engine walks **12 groups x 4
slots** instead of 48 flat slots, because everything about FM is per group.

### 15.1 The structural insight that made this small

MAME writes out 16 + 4 + 8 algorithm cases as 28 blocks of straight-line code,
and they look like 28 different machines. They are not. In **every** algorithm
of **every** sync mode the operators are evaluated in the same order --
slot1, slot3, slot2, slot4, i.e. banks 0, 2, 1, 3 -- and only three things
change:

* which earlier results feed each operator (a 3-bit mask over r1, r3, r2),
* whether `set_feedback()` takes operator 1's result or operator 3's,
* which operators reach the mixer (a 4-bit mask).

So the whole thing is a 28-entry table and one sequencer, not 28 datapaths.
The bank order being invariant is what collapses it.

### 15.2 Fixed-point notes

* An FM operator's output already has its envelope folded in and MAME applies
  no channel clamp to it, so its mix is a plain sum of the four attenuations --
  one multiply, where PCM needs four clamped ones.
* `calculate_op`'s phase index is `((stepptr + slot_input) >> 16) & 1023`.
  MAME does that in 64 bits; 32 is exact here, because only bits 25:16 survive
  and carries never propagate downward.
* The waveform ROM stores only waveforms 0-5. Waveform 6 is the constant 32767
  and 7 is silence, both cheaper in logic than in memory.
* The pitch LFO would be a 4 x 8 x 256 table of doubles. Split into the shape
  (4 x 256, quantised to 128ths) and the exponential (7 x 257, since pms 0 is
  exactly unity) it is 5 M10K instead of 14, and the quantisation error is
  1/256 of the modulation depth -- 0.0003 semitones at the deepest setting.

### 15.3 Three bugs, and what caught each

**The pitch LFO was applied a sample late, using another slot's value.**
`step_calc` multiplied by the *registered* `plfo`, but `step_r <= step_calc`
happens in the same cycle as `plfo <= plfo_c`. So every note's first sample
used whatever the previously processed slot had left in that register. Caught
by the LFO pitch test, which parks the LFO at a fixed depth and predicts the
phase step exactly. The fix is to read `plfo_c` combinationally.

**FM operators ignored total level.** `op_mul` scaled the waveform by
`env_gain`, which is only the envelope-times-LFO half; `calculate_slot_volume`
folds total level in as well, and that is `slot_gain`. Every FM voice would
have played at full volume regardless of what the driver asked for. This one
was NOT caught by a test -- every test used total level 0, where the two are
equal. It was found by writing the reference model for the chain test and
noticing the model needed a term the RTL did not have. The carrier test now
uses a real attenuation so it cannot come back.

**Two roundings went the wrong way.** MAME's `/2` in the feedback average and
`/16` in `set_feedback` are C integer division, which truncates toward zero;
an arithmetic shift floors. Negatives came out one too low. Only reachable
with feedback enabled, which is exactly what the chain test turns on.

### 15.4 The testbench

`make -C sim run-ymf271` now runs ten checks. The FM ones work the same way as
the PCM ones -- predict the exact output from MAME's formulas, not from a
second copy of the RTL's arithmetic:

* **carrier** -- algorithm 15 is four independent oscillators; silence three
  and the output is one bare waveform, recomputed from `sin()` rather than read
  back out of the generated table, scaled by a real total level.
* **modulation** -- sync 1 algorithm 0 is one operator modulating another's
  phase, the heart of FM.
* **chain + feedback** -- algorithm 0 in 4-operator mode: 1 feeds back into
  itself, then modulates 3, then 2, then 4. The feedback state depends on every
  previous sample including the ones where the envelope was still attacking, so
  the model carries the envelope too and matches from the note's first sample.
* **LFO amplitude and pitch** -- with the LFO frequency at 0 the phase never
  moves, so a square wave parks at a fixed depth and both the gain and the
  phase step become constants the test can predict.

**A one-sample match is not an alignment.** The first version located the
phase by finding any table index whose value equalled the first sample. The
sine takes most values twice a period, so it frequently locked onto the wrong
one and every subsequent sample read as a one-sample lag -- which is also
exactly what a wrong phase step looks like. All the searches now require four
consecutive samples to agree.

### 15.5 PCM voices live only at slots that are multiples of four

`pcm_tab` maps the PCM bank's select to `12*(sel>>2) + 4*(sel&3)`, so it
reaches twelve slots -- 0, 4, 8, 12 ... 44 -- and every fourth select is
invalid. Since slot = bank*12 + group, that means **only groups 0, 4 and 8 can
hold PCM voices**, four each. This is not a curiosity: the hardware telemetry
had already shown the sounding-slot count peaking at exactly 12 and never
higher, which is the same fact seen from the other end.

It also cost a debugging cycle. The FM tests park a spare slot-4 PCM voice on
silence, and doing that through select 3 writes nothing at all -- `sel & 3 == 3`
is the invalid entry. The untouched voice then played from address 0 and buried
the operator under a constant offset. Slot 4 of group 0 is slot 36, which is
select 12.

### 15.6 The FM engine missed clk_sys setup by 2.2 ns, and how it was found

The first FM build produced an RBF and reported "Full Compilation successful",
but `clk_sys` was at **-2.212 ns setup, TNS -77.9**. A successful compile is not
a passing compile -- always read the Setup Summary.

The Setup Summary names the clock and the slack but not the endpoints, and the
STA report as written contains no path listing. To get one:

    quartus_sta -t paths.tcl        # project_open, create_timing_netlist,
                                    # read_sdc, update_timing_netlist, then
                                    # get_timing_paths -setup -npaths 25

Every one of the worst 25 paths was the same: `w1[4]` to `op_out[*]`. `w1[4]` is
the low bit of the operator's `feedback` field, and the chain from there was

    feedback -> MODLVL lookup -> 18x8 multiply -> add to stepptr
             -> waveform ROM lookup -> 16x19 multiply -> op_out

two multiplies with an asynchronous ROM read between them, all in one cycle.

The fix is entirely pipelining -- no logic changed, and all ten testbench
checks still pass bit for bit:

* the waveform ROM now has a registered address and a registered output, so it
  is a real M10K read rather than an asynchronous lookup buried mid-chain
  (`S_FMPH` / `S_FMWT` / `S_FMOP`);
* the LFO's three serial ROM reads -- frequency, pitch shape, exponential --
  get a cycle each (`S_LFO0` / `S_LFO1` / `S_LFO2`);
* `calculate_step`'s multiply, power-of-two shift and LFO scaling get a cycle
  each (`S_STEP0` / `S_STEP1` / `S_STEP2`);
* the volume chain's two ROM reads and two multiplies are spread over four
  cycles instead of two.

The gate that decides whether a slot is sounding also moved **before** the LFO
work, which is both faster and more faithful: MAME only reaches `update_lfo()`
and `calculate_step()` from inside `calculate_op()` / `update_pcm()`, and both
return early on an idle slot.

Rule of thumb this leaves behind: in this engine no state may contain more than
one ROM read or one multiply. Two of either, or one of each in series, does not
fit in 17.46 ns.

### 15.7 What the algorithm sweep caught, and one thing it cannot

`test_all_algorithms` sets up all four operators, walks every algorithm of
sync 0 and sync 2 -- 24 networks -- and compares against a transcription of
MAME's `switch` statements rather than against the RTL's own `in_mask` /
`out_mask` table. That is the point: the table is 28 wiring diagrams read by
eye, the same transcription risk as the sprite decrypt tables in section 5.4,
and a self-consistent check would prove nothing.

It immediately failed on **algorithms 1, 5, 7 and 11 of sync 0 and 1 and 5 of
sync 2** -- exactly the six whose `set_feedback()` takes operator 3's result
rather than operator 1's. Those run a step later, by which point `p_feedback`
holds a different operator's field, so the feedback depth was read from the
wrong operator. Operator 1's value is now latched into `net_fbk` at the start
of the network. Nothing else in the table was wrong.

**What the sweep cannot check: the first few samples of a note.** The
alignment search can only pin the phase, which is periodic; the envelope is
monotonic and there is no way to observe which output sample the device treated
as the note's first. Comparison therefore starts once the envelope has
saturated. Those early samples were the only place the two ever differed --
by a couple of counts, at -60 dB -- while the following 120 match exactly.

### 15.8 clk_ram, and a path that is not allowed to be touched

With clk_sys fixed, `clk_ram` came out at **-0.104 ns, TNS -0.154**: two paths,
both `sdram|dq_reg -> sdram|ch5_dout`. That is the SDRAM's PCM read capture,
and section 10 already records what happens if it is "optimised" --
restructuring `dq_reg` destroyed the SDRAM input timing and produced garbage on
the first word of every burst, a fault that looked exactly like a module too
slow for the clock. It is pure routing, 0.1 ns, on the channel the sound engine
made real. Rebuilding cleared it -- the netlist had changed anyway for the
`net_fbk` fix, and the fitter placed it differently -- so `dq_reg` was never
touched. If it comes back, a fitter seed is the next lever, not that register.

Final state with FM, the LFO and the pipelining: **0 errors, TNS 0.000 on every
clock**, setup slack clk_ram +0.641 ns, clk_sys +0.919 ns, clk_cpu +3.044 ns,
78% ALMs, 86% RAM blocks, 53% DSP. RAM blocks are now the tightest resource;
the waveform ROM is 13 of them and the two LFO tables 5.

`make timing` runs `tools/timing_paths.tcl`, which prints the endpoints the
Setup Summary leaves out. Worth knowing before the next timing hunt: a compile
that says "Full Compilation was successful" has NOT necessarily met timing, and
the .sta.rpt it writes contains no path listing at all.

---

## 16. The 386 is idle 60-97% of the time, so 25 MHz would be cosmetic (2026-08-15)

The question was whether to run z386 at the frequency the real board runs at.
The board is a 386DX at **25 MHz** (50 MHz XTAL / 2, section 6's table); the core
runs `clk_cpu` at 28.636364 MHz, which is 14.5% fast. Two things came out of
looking at it: the frequency cannot be reached from this PLL without making
`clk_cpu` asynchronous, and it would not matter if it could.

### 16.1 Exact 25 MHz is not available from one PLL

`clk_sys` must stay exactly 57.272727 MHz -- the pixel clock and the Z80 clock
are both `clk_sys`/8 and both have to be exact. Requiring one VCO to divide to
both 630/11 MHz and 25 MHz means

    clk_sys/clk_cpu = 126/55, so the smallest usable VCO is 55 x 630/11 = 3150 MHz

against a Cyclone V ceiling near 1600. So it cannot be done with the single PLL.

Nor is there a near miss worth taking. Every output is a division of the same
1260 MHz VCO, so all edges land on VCO ticks and the closest launch/capture pair
between `clk_cpu` and `clk_sys` is `gcd(22, N)` VCO periods:

    /44  28.636 MHz  gcd 22  ->  17.460 ns   <- current, fully aligned
    /50  25.200 MHz  gcd  2  ->   1.587 ns
    /51  24.706 MHz  gcd  1  ->   0.794 ns

Only multiples of 22 stay aligned, which is 28.636 MHz and then 19.09 MHz --
nothing near 25. `sys/sys_top.sdc` puts every core PLL output in ONE clock group,
so these are analysed against each other, and a 1.6 ns sliver is the same trap
that made 96.923 MHz `clk_ram` build at -4.7 ns (see pll.v).

Exact 25.000 is therefore a SECOND PLL (50 MHz ref, VCO 1000, /40), which makes
`clk_cpu` genuinely asynchronous and turns several crossings into real CDCs:
`spi_top.sv:399` (`sndfifo_wr` is a one-`clk_cpu` pulse that `spi_sound` edge
detects assuming it spans two `clk_sys` cycles), `spi_top.sv:341` (the whole
`spi_io` register file, already flagged in section 11 as unsynchronised), and
`spi_top.sv:784` (telemetry, commented "a synchronous sample, not a CDC"). Worth
noting the real board IS two crystals -- 50 MHz for the 386, 28.63636 for video
-- so an asynchronous CPU domain is more faithful, not less.

### 16.2 Measured on rdft: the 386 is idle 80-85% of a frame

Before doing any of that, measure. `eip` and `cs` are already in the VITL probe,
so `tools/slop vitals` is a sampling profiler with no RTL change: the JTAG round
trip is ~54 ms against an 18.52 ms frame, uncorrelated with frame phase, so the
samples are uniform in time.

rdft in attract, two independent runs:

    run 1   600 samples   79.0% in the spin, 85.2% including the call inside it
    run 2   300 samples   75.0% in the spin, 80.3% including the call inside it

The hot addresses disassemble (from MAME's own memory, via objdump) as a
wait-for-vblank spin:

    203ef9  mov  eax, ds:0x3692c            ; snapshot the frame counter
    203f00  test DWORD PTR ds:0x298d0,0x400
    203f0a  je   203f11
    203f0c  call 206339                     ; conditional, inside the wait
    203f11  cmp  eax, DWORD PTR ds:0x3692c  ; changed yet?
    203f17  je   203f00                     ; no -> spin
    203f19  ret

So the game uses 15-20% of the CPU in this scene:

    28.636364 MHz / 53.99 Hz = 530,401 clk_cpu cycles per frame
    busy 14.8-19.7%          =  78,700-111,400 cycles of actual work

**At exactly 25 MHz that same work is 17-24% of a frame, so the 386 would still
be idle 76-83%.** Dropping the clock 12.7% changes nothing a player could see.
The frequency is cosmetic; only a throttle several times deeper would restore a
real 386DX-25's behaviour.

### 16.3 The MAME comparison was against the wrong program state (corrected)

**This section originally reported that MAME's 386 waits on the SOUND handshake
while ours waits on vblank, and treated that as a real difference worth
remembering for T-O. It is withdrawn. They wait on the same thing.**

MAME was not in attract. It was running the sample-flash updater -- the
"NOW UPDATING. PLEASE WAIT A MOMENT." screen with its block counter -- because
`~/.mame/nvram/rdft/soundflash1`+`2` did not hold a valid pre-flashed image. The
updater's whole job is to hand blocks to the sound subsystem and wait for the
Z80 to acknowledge each one, which is exactly the loop it was sitting in:

    26d65a  bt   WORD PTR ds:0x684,1     ; Z80 -> 386 FIFO not empty?
    26d66c  jae  26d65a                  ; no reply yet -> spin
    26d66e  mov  ax, ds:0x680            ; take the reply

So that 93% figure measured the reflash ritual, not gameplay. Our hardware never
shows it because the MRA ships the flash pre-programmed (section 10b), which is
the same reason `fifo2 push/pop` sits at 42 for a whole session.

Installing the image the way the capture recipe already prescribes --
`tools/build_soundflash.py rdft.zip out.bin`, split at 1 MB into
`<nvram>/rdft/soundflash1` and `soundflash2` -- makes MAME boot straight to
attract, the same title-over-demo screen the hardware shows. Re-run there:

    480 of 480 fixed-phase samples at 00203F0A -- the SAME vblank spin loop

**The lesson is the one already written down for hardware and not applied here:
screenshot first.** One snapshot of MAME would have shown "NOW UPDATING" in
seconds and saved the whole detour. `Average speed` does not substitute for it:
throttled runs report 100% whether or not the updater is running, so the speed
tell in the capture recipe only works with `-nothrottle`.

### 16.4 rfjet, the heavy set: 4-36% busy, and the peak is what matters

rdft is a light set. rfjet is the one that has been pushed hardest (T-L: scenes
at 24.6k and 26.2k y-hits), so the measurement was redone on it. MAME's nvram
was built the same way -- `tools/build_soundflash.py rfjet.zip`, split at 1 MB
-- and **screenshotted first this time**: attract, no updater. The codec
expansion the builder reports, 269,320 in -> 390,901 out, is +121,581, which is
exactly the figure recorded for rfjet in the fast-load table. Good cross-check.

rfjet's wait loop is the same construct as rdft's, relocated (same library):

    206075  mov  eax, ds:0x36790            ; snapshot the frame counter
    20607c  test DWORD PTR ds:0x2894c,0x400
    206086  je   20608d
    206088  call 2094a9                     ; conditional, inside the wait
    20608d  cmp  eax, DWORD PTR ds:0x36790
    206093  je   20607c                     ; spin
    206095  ret

MAME, fixed phase: 400 of 400 samples at 00206086, the same loop -- so both
sides are in the same program state, which is the thing 16.3 got wrong.

**Hardware, 1200 uniform samples over about 12 minutes of attract.** The single
number is 16.6% busy, but reporting only that would hide the real structure:

    50-sample windows, busy fraction

      light attract screens   0.04 .. 0.12
      the demo playing        0.24 .. 0.36

(Played gameplay peaks a little higher still, 0.396 -- see 16.5.)

Two shorter runs landed at 30.3% and 11.3% busy purely because one caught the
demo and the other the hi-score screens -- a 10-sigma "disagreement" that is
just scene, and a warning against quoting a mean from a short sample here.

    overall     busy 16.6%   =  87,958 clk_cpu cycles/frame
    PEAK window busy 36.0%   = 190,944 clk_cpu cycles/frame

**At exactly 25 MHz the peak becomes 41% of a frame** (overall 19%), so even
rfjet's heaviest attract scene keeps well over half the frame spare. The
conclusion from 16.2 survives the harder set: the frequency change is cosmetic.

What the peak DOES give is the first real bound on where slowdown would start.
Saturating the CPU in this scene needs it about **2.8x slower than now, around
10 MHz** effective -- so a throttle aiming at 386DX-25 behaviour is looking for
something in that neighbourhood, not the 12.7% a clock change buys. That is a
bound from OUR side only; it still does not say what a real 386DX-25 does, which
remains 16.5.

### 16.5 Measured during actual PLAY: peak 39.6%, and the boss is not the peak

16.4's 36% was an attract number. A credit was played through on rfjet
(2026-08-15) with the profiler logging an 8-second hardware-counted window every
~18 s. 59 samples across menus, stage 1, its boss, and stage 2:

    mean over everything          16.7%
    mean excluding <8%             21.0%   (43 samples; <8% is menus, deaths,
                                            scripted lulls)
    PEAK                           39.6%   mid-stage 1

**The stage 1 boss is NOT the peak.** Its window runs 16.9 -> 26.4% and tops out
at 26.4, well under the 39.6 hit mid-stage. That is the right shape rather than a
surprise: the 386's per-frame work scales with the NUMBER of objects, not their
size, and a boss is one large sprite with a few patterns while mid-stage is many
independent enemies plus bullets. Anyone hunting worst-case CPU load should aim
at a crowded mid-stage moment, not a boss.

Two samples inside the boss window read 2.7%, the CPU almost entirely idle --
the boss intro or the defeat sequence, where the game runs a scripted animation
and little else.

So play is heavier than attract, but not by much: 39.6% against 36.0%, and the
mean play figure of 21.0% against attract's 16.6%.

    PEAK play  39.6% = 210,039 clk_cpu cycles/frame
               at exactly 25 MHz that is 45.4% of a frame

**Which settles the original question on real gameplay, not just attract: at
25 MHz the 386 still has more than half of every frame spare, even at the worst
moment of a played credit.** The clock change is cosmetic.

The saturation bound tightens from attract's estimate: reaching 100% needs the
CPU about **2.5x slower than now, ~11.3 MHz effective** (attract implied 2.8x /
10.3 MHz). That is the number a throttle aiming at 386DX-25 behaviour would have
to hit, and it is nowhere near the 12.7% a clock change buys.

Method note: driving the game from this end did NOT work. A uinput keyboard on
the MiSTer (python3 + /dev/uinput; MiSTer takes MAME-standard defaults, 5 = coin,
1 = start, so no OSD mapping is needed) successfully coined up, started, and
walked the name-entry and plane-select screens -- but the round trip per input is
several seconds, which is slower than the game's own menu timeouts, so it could
not actually play. A human played; the logger ran unattended on this side. The
uinput trick is still worth keeping for anything that only needs a few keypresses
at a screen that waits.

Also worth recording: the persistent jtag_server died after 19 minutes with an
internal Tcl error inside `read_probe_data`, taking the logger with it. The
gameplay log was taken with `jtag_peek.tcl prof` instead -- one self-contained
quartus_stp per sample, ~8 s of measurement per ~18 s of wall clock. Slower, but
nothing long-lived to die mid-session. Prefer it for unattended logging.

### 16.6 The sample-flash updater is NOT a CPU benchmark

Asked whether the "NOW UPDATING" ritual could serve as a rough 386 benchmark.
It cannot, for three separate reasons, and the first one is fatal on its own.

**Our core cannot run it.** The pre-flashed variant is what was built (the table
in section 0): the flash region in SDRAM is read-only, there is no E28F008SA
command state machine and no YMF271 ext-memory port in the write direction. Only
MAME can run the ritual, so it could never be a comparative measurement.

**The 386 is not the bottleneck -- it is blocked on a Z80 round trip.** Traced
per frame through rfjet's update, 140 of 140 samples land in a three-instruction
wait, and it is the same library routine as rdft's 0x26D65A, relocated:

    2c5315  bt   WORD PTR ds:0x684,1    ; Z80 -> 386 FIFO not empty?   48%
    2c531e  mov  WORD PTR ds:0x600,1    ; watchdog kick                31%
    2c5327  jae  2c5315                 ; no reply yet -> spin         14%
    2c5329  mov  ax, ds:0x680           ; take the reply

That is 93% of the trace in the spin itself. It fits what section 0 already
measured from the other end: the Z80 is a pure pass-through, 4,056,707 FIFO bytes
against 4,056,752 flash writes, so every unit of work is a 386 command and a Z80
reply with the 386 waiting in between. The pace is set by the Z80's loop and, on
real hardware, by flash programming time -- neither of which is the 386.

**MAME's flash costs nothing, so its duration is not the hardware's.** MAME's
`intelfsh` does not charge byte-program time, and the whole ritual finishes in
about 7 emulated seconds -- it was on "UPDATE COMPLETED. PLEASE TURN THE POWER
BACK ON." by frame 400. Real hardware has to actually program ~2 MB a byte at a
time and takes minutes. So the MAME figure measures the 386/FIFO/Z80 pipeline
with the flash removed, and the hardware figure is dominated by the part MAME
omits. Neither is a CPU number.

Worth keeping from the exercise: **MAME's own programming run reproduces
`build_soundflash.py` byte for byte** (sha256 of both 1 MB halves identical), which
re-confirms the offline builder end to end, from a completely different direction
than the original derivation.

One trap this cost time on: after the update the game HALTS on "please turn the
power back on" and never reaches the vblank spin loop, so a completion detector
that waits for the spin window waits forever. Detect the update by the halt
screen, or by the flash contents settling.

### 16.7 What is still not established


How much faster z386x is per clock than a real 386DX-25 is still open. MAME's
fraction cannot be pinned down with the hooks it exposes:

* **No periodic Lua hook** -- only frame notifiers, so every PC sample is at one
  fixed phase of the frame. 480/480 in the spin says MAME has substantial
  headroom too, consistent with our 80-85%, but a single phase cannot be turned
  into a fraction.
* **Memory read taps are bypassed for normal RAM reads.** A tap on the frame
  counter 0x3692c fires exactly 0.998 times per frame, which looks like a
  measurement -- but sampling EIP inside the tap shows it is ALWAYS 0x26b188,
  the vblank ISR's own read-modify-write. The game's loop reads never reach it.
  Check WHICH access a tap is catching before believing a per-frame count.
* **A tap on the device port 0x684 crashes MAME** (core dump).

### 16.8 The EIP profiler (built)

The instrument is now on our side. `spi_top` counts, on clk_cpu, the cycles with
`eip` inside a programmable inclusive window, against a count of every clk_cpu
cycle; both come back on a new `PROF` sources-and-probes instance. Point the
window at the wait loop and the ratio IS the idle fraction -- exactly and
continuously, instead of a few hundred JTAG samples over twelve minutes.

    tools/slop prof 0x20607C 0x2060B8     set the window (rfjet)
    tools/slop prof                       read; each read prints the delta
                                          since the last, so it is a rate

    quartus_stp -t tools/jtag_peek.tcl prof 0x20607C 0x2060B8 30
                                          standalone, server down, one shot

Known windows: rdft `0x203F00..0x203F3A`, rfjet `0x20607C..0x2060B8`.

Four decisions worth keeping:

* **Programmable window, not per-set constants.** The loop is at a different
  address in every set, and a window that can point anywhere makes this a
  general "how long is the CPU in THIS routine" instrument rather than a
  single-purpose idle meter.
* **Free-running, never cleared.** The host takes the ratio of two DELTAS, which
  needs no clear and therefore no clear-domain crossing. 40 bits wraps in about
  10.7 hours at 28.636364 MHz; 32 would have wrapped in 150 s, which is shorter
  than the sampling runs this replaces, and the tools mask deltas so a single
  wrap inside an interval still reads correctly.
* **Cycles, not instructions.** A cycle stalled on SDRAM keeps `eip` on the
  stalled instruction, which is what we want -- waiting is waiting.
* **`PROF` is looked up softly in the server.** A bitstream built before this
  has no such instance and `idx_of` throws; `prof` reports the absence instead
  of killing a server that is working fine for everything else.

**Built, deployed and validated on hardware (2026-08-15).** Timing passed on
every clock with TNS 0.000: clk_ram +0.383, clk_sys +1.329, clk_cpu +1.965. The
profiler costs clk_cpu some margin -- two 32-bit compares and two 40-bit counters
-- but no profiler path appears in the worst 25.

Controls first, because an instrument that always answers is worth nothing:

    window FFFFFFF0..FFFFFFFF  (the CPU is never there)    IN WINDOW   0.0%
    window 00000000..FFFFFFFF  (the CPU is always there)   IN WINDOW 100.0%
    window 0020607C..002060B8  (rfjet's wait loop)         IN WINDOW  89.8%

Then twelve consecutive 12-second reads across rfjet attract, against the 1200
sampled points from 16.4:

                          sampling (12 min)   counter (12 x 12 s)
      light attract        4 - 12% busy        6.7 - 10.0%
      demo playing        24 - 36% busy       22.3 - 35.1%
      peak                     36.0%              35.1%

Two instruments, different physics -- one a JTAG sampler, one a hardware counter
-- agreeing on the peak to about one point. 16.4's numbers stand.

**One bug, and it is the same family as the switch-comment trap.** `prof` killed
the server outright with `can't read "PROF": no such variable`. `proc handle`
declares only `ctrl_val` and `OUTFILE` global, so ANY other global read from a
switch body throws. The fix is to keep globals out of the dispatch bodies and
let the called procs declare their own. Worth knowing before adding the next
command: that dispatch has two separate ways to bite, and both kill the server
rather than printing an error.

**First read after setting a window is always garbage** -- it spans back to the
previous window (0..0 at boot), so it reads ~0%. Set, read, discard, read.

What it unblocks: 16.5's missing number needs a MAME-side figure that MAME will
not give up, but the OUR-side half is now exact rather than sampled, and it can
run during PLAY -- which is what T-N still owes and where the peak load lives.
Attract's 36% peak (16.4) is an attract number.

---

## 17. The authentic boot-up flash: what the core still needs (2026-08-15)

Section 0 sketched this as "the authentic path" and priced it in one table. This
section is the engineering version of that table, written after re-reading the
RTL rather than from memory, because three of the six line items turn out to be
already built and one of the remaining ones fails SILENTLY if it is skipped.

The goal: ship `rdft-update.mra` (and rdft2, rfjet, and eventually senkyu,
viprp1, ejanhs) alongside the pre-flashed MRAs. The authentic MRA carries a
BLANK flash and the cartridge's sound ROMs, the game notices the stamp does not
match, and it runs its own "techno music" updater exactly as the real cartridge
does on first boot. No derived image, no per-game codec work.

### 17.1 What already exists

More than section 0's table implies, because the SXX2C board work landed in the
meantime (10b) and the YMF271's wave-memory port was built for SXX2E's ROM:

* **The whole Z80-in-RAM board.** 0x688 / 0x68C download, both FIFOs, 0x4009 d0,
  0x400a. The updater's Z80 half needs nothing new.
* **The wave memory port, read direction.** `rtl/ymf271.sv:346` decodes
  0x14/0x15/0x16 (23-bit address plus the R/W bit) and `:352` pre-increments on
  0x17; `rtl/ymf271_synth.sv:796` (`S_EXT`) services a read out of SDRAM at every
  slot boundary. `ext_addr[20:0]` already spans the full 2 MB, so "which of the
  two E28F008SA chips" is just bit 20 -- the `_unused` comment at
  `ymf271_synth.sv:1019` claiming the port has to be widened for SXX2C is wrong;
  2 MB is 21 bits and they are all there.
* **The flash region itself**, `SDR_PCM_BASE` (`spi_defs.vh:30`), already the
  memory the voices play from.

So the delta is the write direction, the source window, and persistence.

### 17.2 The 386's `sound01` source window -- do this FIRST

The updater reads the samples out of the 386's address space and passes them to
the Z80 a byte at a time. `spi_cpu.sv` decodes only `0x1200000-0x13FFFFF` (the
second sound ROM, packed, which is where rdft2 and rfjet keep their Z80
program), and `spi_top.sv:266` does not even enable that much for rdft.
Everything else in the window falls through to `S_NULL` and **reads as zero**.

That is the trap: with no other change, the ritual would run to completion, the
progress bar would fill, the game would say UPDATE COMPLETED, and the flash
would hold 2 MB of silence. Nothing errors. A pre-flashed MRA gets away with the
missing window only because the 386 never touches it once the stamp matches
(measured: 0 reads across 4800 frames, section 0).

The layout is not guesswork -- `tools/build_soundflash.py`'s `bank()` models it
and is verified bit-for-bit against MAME's own flash nvram for all seven sets:

| 386 range             | contents                                                  |
|-----------------------|-----------------------------------------------------------|
| `0x0A00000-0x0BFFFFF` | pcm ROM `0x000000-0x0FFFFF`, 2 bytes per dword, lanes 0/1 |
| `0x0C00000-0x0DFFFFF` | nothing -- the `ROM_CONTINUE(base+0x400000)` skip          |
| `0x0E00000-0x0FFFFFF` | pcm ROM `0x100000-0x1FFFFF`, same packing                  |
| `0x1200000-0x13FFFFF` | second sound ROM, 1 byte per dword -- ALREADY DECODED      |

The three sets the core has tables for -- rdft, rdft2, rfjet -- all have the
same shape: a 2 MB pcm ROM at region base 0 on two byte lanes and a 512 KB ROM
at region base 0x800000 on one.

**The gen-A sets do NOT, and the difference is one lane rather than one
window.** senkyu, batlball, ejanhs and viprp1 put a 1 MB PCM ROM on ONE lane.
A 1 MB ROM at one lane spans exactly what a 2 MB ROM at two lanes does, skip
included, so the two windows are in the same place for all six cartridge sets
and a gen-A set costs one more bit of mode in the decode, not new addresses.
Nothing reads them today -- there is no part table for any gen-A set -- but the
"every cartridge is the same shape" sentence this replaces was wrong, and it was
`tools/check_snd01_window.py` that said so on its first run.

viprp1 needs nothing extra beyond that: its second source is the program ROM,
which is already mapped.

Stored packed, a 4-dword 386 cache line is 8 consecutive source bytes, so a line
fill is exactly one aligned 64-bit SDRAM read. That is the same trick the
existing `SDR_SND01_BASE` arm uses, so the new arm is a copy of it with the
byte index doubled.

Work: one decode arm in `spi_cpu.sv`, a 2 MB `SDR_PCMSRC_BASE` at the top of the
map (`SDR_END` 41 MB -> 43 MB), and `snd01_en` extended to rdft.

### 17.3 The flash device

New `rtl/spi_soundflash.sv`, per-chip state selected by `ext_addr[20]`: Read
Array (FF), Read Status (70), Clear Status (50), Block Erase (20 / D0), Byte
Program (40 + datum), and a status register whose bit 7 (WSMS) is the one the
updater polls. Section 0's trace is the specification; it was taken off the real
command stream and includes the direction bit being flipped between steps, which
is why the port has to work both ways.

Erase is a 64 KB sweep of 0xFFFF through the write port, with status reading
BUSY until the sweep drains. That is what makes a timing model unnecessary: the
updater self-throttles against the sweep, and there is nothing to calibrate.

Two hooks into `ymf271.sv`:

* `:352` (write to 0x17) hands the flash the byte and the POST-increment
  address. The address register runs one behind -- the comment at `:340` already
  records why (the updater sets 0x7FFFFF so the first write lands at 0).
* `:403` / the `S_EXT` fetch: when the addressed chip is not in read-array mode,
  answer the status byte locally instead of going to SDRAM. Program-verify
  depends on the write having retired first, which holding BUSY until the SDRAM
  write acks gives for free.

### 17.4 A write path into the PCM region, and the cache

`ch5` is read-only in the controller (`sdram.sv:98`); `ch3` is the only writable
channel (`sdram.sv:44`) and its arbiter already carries a writer for the Z80
download. A fourth port on `spi_sdr_arb3.sv` is ~20 lines and touches
`sdram.sv` not at all. Byte granularity is native via `ch3_be`. Bandwidth is a
non-issue: a full 2 MB erase is about 1M 16-bit writes, ~130 ms.

**The cache is the subtle part.** `ymf271_synth.sv` holds a 64-bit sample line
(`line_tv` / `line_data`, `:198`) and a per-slot copy of it written back every
slot (`cch_*`, `:924`), so a flash write can leave up to 49 stale copies. Cheapest
exact fix: a one-bit generation tag stored beside the valid bit, toggled on any
flash write or erase -- every stale entry then misses at `:423` with no sweep and
no extra state. `S_EXT` reads go straight to SDRAM and are already coherent.

### 17.5 The MRA

Same skeleton as the pre-flashed files, different tail. **The blank flash is in
the zips** -- `flash0_blank_region80.u1053`, plus one per region (`rdftj`,
`rdftu`, `rdft2it`, `rfjett`, ...) -- so the region byte comes from MAME's own
dump instead of a literal:

```xml
<part name="flash0_blank_region80.u1053"/>   <!-- 1 MB, carries the region ID -->
<part repeat="0x100000">FF</part>            <!-- chip 1, blank -->
<part name="gun_dogs_pcm.u0217"/>            <!-- new: sound01 source, 2 MB -->
<part name="seibu_8.u0216"/>                 <!-- new: sound01 source, 512 KB -->
<nvram index="2" size="2097152"/>
```

Plus a new mod-byte bit (bit 4 is free; bit 0 is SXX2C and bits 3:1 the variant)
selecting an authentic part table, and the usual `tools/check_mra.py` and
`tb_rom_loader` extensions. Download size is roughly the pre-flashed figure plus
0.5 MB, since the 2 MB of derived flash is replaced by 2 MB of blank and the
sources are added.

This is also what makes the region variants free for the first time. The
pre-flashed trick binds an MRA to one program image, because the stamp is a copy
of that image's last four bytes; the authentic path derives nothing, so a
different region is a different blank plus different program ROMs and the game's
own stamp check does the rest.

### 17.6 Persistence, and why it is not optional

`sys/hps_io.sv:146` already carries the whole upload path (`ioctl_upload_req`,
`ioctl_upload_index`, `ioctl_din`, `ioctl_rd`); `SeibuSPI.sv` wires none of it.
The HPS side is `arcade_nvm_save()` in Main_MiSTer's
`support/arcade/mra_loader.cpp:88` -- a plain `spi_read` of `nvram_size` bytes,
**with no size cap**, triggered when the menu poll `UIO_CHK_UPLOAD` sees the
core's request. Load is the mirror, an `ioctl_download` at the nvram index.

So 2 MB works as an arcade nvram. What it needs on our side is a prefetch FIFO
on the read-back (one 64-bit SDRAM read feeds eight `ioctl_rd` beats), a route
for the nvram DOWNLOAD into the PCM region -- the same ch3 write port -- and a
dirty flag plus an idle timer to raise `ioctl_upload_req` once the flash stops
changing.

Why it is not optional: after updating, the game HALTS on "UPDATE COMPLETED.
PLEASE TURN THE POWER BACK ON." (16.6). Without a save file that is a
ritual-plus-manual-reset on every single boot.

The cost is smaller than the real hardware's, and deliberately so. The ritual is
one 386 -> Z80 FIFO round trip per byte (16.6), and like MAME we charge no
byte-program time, so the bound is the FIFO loop rather than the flash. MAME
finishes in about 7 emulated seconds. Ours will be slower -- the Z80's fetches
sit at the bottom of the SDRAM priority list (14.7) -- but tens of seconds, not
the minutes real hardware takes.

Worth copying from MAME: it re-asserts the region byte at `flash[0]` on every
`machine_reset` as an anti-brick hack. Doing the same after an nvram load costs
one write and makes a save file from the wrong region self-correcting.

### 17.7 Phasing, and how it is verified

1. **Source window + flash device + ch3 write port.** The ritual runs. Verify by
   dumping SDRAM `0x0280000-0x047FFFF` over JTAG and comparing sha256 against
   `tools/build_soundflash.py`'s image for the set. That image is already
   verified bit-for-bit against MAME's own flash nvram from two independent
   directions (section 0 and 16.6), so this is an exact pass/fail with nothing
   to eyeball -- the same standard the fast-load work was held to.
2. **Persistence.** The ritual runs once.
3. **Ship the `-update` MRAs.** The pre-flashed ones stay as the fast-boot
   option, and stay the only option for anyone who does not want to sit through
   a reflash at all.

### 17.8 Two open questions, neither blocking

* **JP1 (0x400a).** 10b found 0xFF (Update) deadlocked and 0xFC (Normal) booted
  -- but that run predates the 0x4009 d0 fix, which is what the deadlock
  actually was in the end, so the jumper's behaviour is NOT established. The
  cheap resolution is to stop guessing: expose JP1 as a DIP bit, default Update
  on the authentic MRA and Normal on the pre-flashed ones. Content-based
  triggering is already measured in one direction (a valid stamp under MAME's
  default Update jumper plays rather than reflashing, section 0); the other
  direction has never been tested.
* **Whether the updater polls one chip while the other is erasing.** Per-chip
  FSM state covers it either way. The rule is just: do not share one status
  register between the two chips.

### 17.9 BUILT 2026-08-15: the source window, and a checker that found a wrong claim

Step 1's first half. Lint-clean, `make verify` green, and NOT yet on hardware --
nothing downstream of it exists to run, since the flash device is still to come.

* **`spi_cpu.sv`** decodes the two PCM source windows. The fetch's one-bit `s01`
  flag became a two-bit `rd_src` (`R_PRG` / `R_S01` / `R_PCM`); all three share
  `S_ROM_REQ/ACK/OUT` and differ only in the group address, the cut, and where
  the group ends -- two dwords for the program, eight for sound1, four for the
  PCM source.
* **The window pair is one bit apart.** 0x0A00000 and 0x0E00000 are 101 and 111
  in 2 MB window units, so they differ in `byte_addr[22]` alone -- which is
  therefore the ROM's own address bit 20, and the 0x0C00000 hole (110) falls out
  of the decode for free rather than needing to be excluded.
* **`SDR_PCMSRC_BASE`** at 0x2900000, 2 MB, map to 43 MB. Written only by the
  authentic tables.
* **`rom_loader.sv`** carries both tails. rdft gains two parts (15 -> 17);
  rdft2 and rfjet keep seventeen, because their derived image was already two
  parts and part 16 was already a source ROM. The authentic tails are IDENTICAL
  across all three sets -- 2 MB blank, 2 MB PCM source, 512 KB second source --
  which is section 17's argument in one table.
* **mod byte bit 4**, ANDed with bit 0 in `SeibuSPI.sv` so it cannot open a
  source window on SXX2E.

**`tools/check_snd01_window.py`, and it earned its keep immediately.** It walks
every dword of the 10 MB region -- holes included -- comparing what `spi_cpu.sv`'s
arithmetic returns against what `build_soundflash.py`'s `load_sound01()` holds,
which is the code whose flash images match MAME's nvram bit for bit. 2,621,440
dwords per set, about 1.5 M of them populated, all three sets exact.

Covering the holes is the point: a decode that reads the windows it thought of
and misses a third still passes a spot check of the first two. Here a missed
window reads "we answer 0 and MAME has data".

Its first run refused to check ejanhs and named the reason, which is how 17.2's
"every cartridge set has the same shape" turned out to be false -- the gen-A
sets are one lane, not two. A checker that had quietly assumed the layout would
have agreed with the RTL and with itself.

**Three mutation controls**, because a checker that only ever passes is worth
nothing: drop the ROM_CONTINUE bit (521,026 dwords differ, first at 00E00000),
take one lane instead of two (1,013,467, first at 00A00008), shift the sound1
window by one dword (190,877, first at 01200000). Each is caught in its own
window, which is the part a single pass/fail cannot tell you.

`sim/tb_rom_loader.cpp` runs all three authentic tables; rfjet's is 41.6 MB, the
largest image the loader has ever placed, and it tripped the bench's fixed 400 M
cycle timeout -- now scaled to the image, since a timeout that depends on the set
reports the wrong thing. `tools/check_mra.py` learned to fold the conditional
table entries down to one arm before parsing, selected by mod bit 4; without
that it silently dropped parts 14 and 15 and failed rdft2 with leftover bytes.

**The authentic image builder, same day.** `tools/build_sdram_image.py --upd`
now writes the 43 MB image: MAME's own `flash0_blank_region80.u1053` in the
sample region, the PCM source ROM at `SDR_PCMSRC_BASE`, the second sound ROM at
`SDR_SND01_BASE`, and the second flash chip left as the 0xFF the image is
already filled with -- MAME has no dump for it because an erased chip has
nothing to dump. `--concat` produces the matching byte stream, including the
1 MB of FF an MRA writes as `<part repeat>`.

Three things fell out of it:

* **rdft was missing from the builder entirely**, so its table is new here. It
  had never been noticed because rdft.zip builds an *rdfts* image: rdfts is a
  CLONE of rdft, a merged zip carries its clones' ROMs, and the CRC probe
  matches both. First match still wins and SETS is ordered so that stays rdfts
  -- every existing invocation means that -- with a printed note and a new
  `--set` to ask for the other one.
* **rdft's pre-flashed `--concat` needed a trailing fill** the decoded sets do
  not: its payload is a plain concatenation that stops short of 2 MB, so its MRA
  pads with `<part repeat>` where rdft2's second part expands to the end on its
  own.
* **`sim/tb_boot.cpp` read 41 MB with a plain `fread`**, which would have
  truncated the source region away and left the 386 reading zeroes -- 17.2's
  failure mode, reproduced in the one bench that could have caught it. Now
  43 MB.

**Controls.** rdft2's and rfjet's pre-flashed images and concat streams are
sha256-identical before and after the change, and so is rdfts' from rdft.zip.

**`check_snd01_window.py --image` closes the loop.** It reads the two packed
ROMs out of a BUILT image rather than out of the zip, so the loader's placement
is inside the check as well as the decode arithmetic:

    tools/build_sdram_image.py rdft.zip upd.bin --upd --set rdft
    tools/check_snd01_window.py rdft.zip --set rdft --image upd.bin

All three sets pass, ~1.5 M populated dwords each. Controls: a pre-flashed image
is rejected on size, one flipped byte at PCMSRC is caught as 1 differing dword
of 2,621,440, and a one-byte shift of the snd01 region as 397,622.

**What is deliberately NOT done here** (all of it built later the same day,
17.10 and 17.11): the E28F008SA command FSM, the ch3 write port, the cache
invalidation, and the authentic MRAs -- the MRAs are the one piece still
outstanding. There is now an image to boot one from, so the next thing that
can be measured is whether a core with `set_upd` set reaches the updater at
all -- which it cannot finish, having nowhere to write.

### 17.10 BUILT 2026-08-15: the flash device and the write port

The rest of step 1. Lint-clean, `make verify` green, timing NOT yet run and
nothing on hardware.

* **`rtl/spi_soundflash.sv`** -- two E28F008SA behind one address, chip select
  being `addr[20]`, with per-chip mode and status. FF / 70 / 50 / 90 / 20+D0 /
  40+datum, written against section 0's command trace.
* **Erase is a sweep, and that IS the timing model.** A block erase writes
  0xFFFF over 32,768 halfwords through the SDRAM port and reports BUSY until
  the last one retires, so the updater throttles itself against the memory
  system rather than against a delay this core would otherwise have to invent.
  Programming costs one write and, like MAME's intelfsh, no time.
* **`spi_sdr_arb3` is now `spi_sdr_arb4`** -- renamed, because a module called
  arb3 with four ports is a trap. The flash is port `d`, BELOW the JTAG peek:
  an erase is 32,768 back-to-back writes and would otherwise lock a human out
  of the instrument for the length of it.
* **The read override is latched, not muxed.** The flash's status or identifier
  substitutes for the fetched byte where the read-ahead stores it, so the byte
  handed out always belongs to the address it was fetched at. Doing it at the
  read mux instead answers from the address the port has already moved on to --
  which the identifier test caught immediately (0xA2 for 0x00FFFF where
  0x010000 was wanted) and which at a chip boundary would answer from the wrong
  chip. MAME's `ymf271` read() has the same shape for the same reason.
* **`dbg_drops`** counts commands arriving while the part is busy. It should
  never move: the updater polls WSMS before every command and a byte program
  retires in a fraction of the ~88 clk_sys a Z80 `out` takes. If it is non-zero
  on hardware that assumption is wrong and the flash needs a real handshake --
  and a dropped byte is a silently wrong image, which is why it is counted
  rather than merely dropped.

### 17.11 The cache fix was wrong twice, and the test said so both times

A flash write has to retire the sample-line cache: there are 49 copies of it in
flight, the live line plus one per slot, restored when that slot comes round.

**Attempt 1, a generation TOGGLE, is wrong and the test found it.** Two writes
flip a one-bit generation back to where it started and bring a stale line back
to life. It showed up as exactly one wrong byte out of five -- `line+6` stale
while `line+4` and `line+5` were fresh -- which is the failure a coarser test
reports as a pass. A wider counter only makes it rarer, and an erase sweep
writes often enough to reach any width worth spending.

**What is built instead:** the valid bits move OUT of the tag RAM into a plain
48-bit register, so a write clears all of them in one cycle and the tags stay
where they were. Exact, and cheaper than the generation it replaces.

**The fold still happens at a slot boundary**, not the moment the write lands.
No fetch is outstanding there, which is the same reason the host read is served
from that point. Folding it immediately would race the store in S_FE1 and tag
stale data as fresh.

**The test.** `sim/tb_ymf271.cpp` now drives `tb_ymf_top` -- the YMF271 and its
flash, wired as the cartridge wires them -- rather than the chip alone, so every
flash test goes through the SAME wave-memory port the sound program uses. A
mistake in the port itself (the pre-increment, the direction bit, which register
file forwards the byte) therefore fails here instead of being papered over by a
back door. Every existing test kept its pin names and is untouched.

Two new tests:

* `test_flash_program` -- erase a block and check that BUSY was ever reported
  (an erase that finishes instantly is one the updater would race), that the
  block is 0xFF and its NEIGHBOURS are not, that six programmed bytes read back
  through the array after 0xFF, that the identifier is per chip, and that with
  `flash_en` low -- every pre-flashed MRA and every SXX2E build -- the identical
  command sequence does nothing at all.
* `test_flash_write_invalidates_cache` -- play a PCM voice, walk it to a line
  boundary so the line is cached with seven bytes still to come, program three
  bytes near the end of that line, and require the voice to sound the NEW ones.
  With the fold disabled it fails on all three; that control is what makes the
  pass mean anything.

One trap worth keeping: the wave-memory registers 0x14-0x17 are TIMER-bank
registers reached through 0xC/0xD, not bus offsets. Writing `wr(0x17, v)`
addresses bus offset 7 -- FM bank 3 data -- and the first version of the test
did exactly that, so every command went to the synthesiser and the flash saw
nothing. The symptom was a flash that never left ready with zero writes on its
port.

**What step 1 still owes:** a Quartus run. The MRAs landed in 17.12.

### 17.12 BUILT 2026-08-15: the authentic MRAs, and MAME's ROM_CONTINUE

`mra/rdft-update.mra`, `mra/rdft2-update.mra`, `mra/rfjet-update.mra`. 24.7,
36.7 and 39.7 MB. Step 1 of 17.7 is complete; none of it has run on hardware.

**The tail order changed to MAME's, and that is the whole reason the check is
worth anything.** 17.9 built the authentic tail as blank-flash, source, source.
It is now source, source, blank -- `sound01`'s two ROMs and then `soundflash1`'s
-- because `check_mra.py` holds each single-file part against the next ROM in
`ROM_START` IN ORDER, and only an MRA that sends them in MAME's own region order
can be checked that way. The alternative was to add the blank to the skip list,
which would have left its CRC unchecked: the one file in these MRAs that carries
the region lock.

So the authentic MRAs skip LESS than the pre-flashed ones. `sound01` and
`soundflash1` are carried and checked; only `audiocpu` (RAM) and `pals` remain.

**MAME's ROM_CONTINUE was being ignored, and the PCM source is where that first
mattered.** `ROM_LOAD32_WORD("gun_dogs_pcm.u0217", 0x000000, 0x100000)` followed
by `ROM_CONTINUE(0x400000, 0x100000)` is a 2 MB file; the checker read only the
first line and believed 1 MB, so part 14 took half a ROM and every part after it
shifted. Nothing before this carried a ROM with a continuation, so nothing
caught it. Sizes now accumulate.

Two more things the checker had to learn, both because these are the first parts
stored PACKED rather than scattered:

* a per-set map from ROM name to (region, mode), because the two ROMs of ONE
  `sound01` region go to two different places and neither uses the scatter its
  `ROM_LOAD32_*` macro implies -- `spi_cpu.sv` rebuilds the 386's view instead;
* a packed ROM's base is its region base with NO displacement, because where
  MAME puts it inside `sound01` (0x800000 for the second) says nothing about
  where the loader puts it.

**What agrees, and how much of it is independent.** MAME's `ROM_START` against
the MRA and the loader table, for all six MRAs, is the only comparison with an
outside authority and it passes. Then, ours against ours: the MRA's own byte
stream, assembled from the zips, is sha256-identical to
`build_sdram_image.py --upd --concat` for all three sets, and the download
totals (25,886,720 / 38,469,632 / 41,615,360) match `tb_rom_loader`'s tables
exactly. And an image built from those bytes passes `check_snd01_window --image`
over all 10 MB of the window. So MRA, loader table, image builder and the 386's
decode are one consistent chain, anchored to MAME at the top.

**No `<nvram>` element yet.** 17.6's plumbing does not exist, so an MRA that
declared one would have the HPS ask the core for 2 MB it cannot supply. The
files say so in a comment: until then the ritual runs on every boot.

### 17.13 Timing: it FAILED first, on a path that is not ours, and a seed fixed it

`make build` on the flash work: 0 errors, an RBF written, and

    Critical Warning (332148): Timing requirements not met

which is the trap this project has a rule about -- a clean compile still writes a
failing bitstream. The one failing path was in the FRAMEWORK, not the core:

    ascal:ascal|o_h_lum_pix.g[7] -> ascal:ascal|o_poly_lum[7]_OTERM113_OTERM876
    pll_hdmi ... divclk   -0.215 ns,  TNS -0.215

`sys/ascal.vhd`, on the HDMI pixel clock. Nothing added here is on that clock,
and all three of the core's own clocks passed with TNS 0.000 (clk_ram +0.422,
which is BETTER than 16.8's +0.383, clk_sys +1.528, clk_cpu +2.321).

That is not a free pass. `compileEip.log` from 2026-08-02 shows the same HDMI
path was already the tightest clock in the design at **+0.307**, so this work
plausibly ate that margin through placement pressure rather than through
anything structural: 83% of ALMs and 87% of RAM blocks are in use.

**SEED 3 -> SEED 4 fixes it**, which is the same lever 13c reached for when
clk_ram needed one. Refit and re-analysed (`make fit && make sta`), everything
positive with TNS 0.000 everywhere:

    pll_hdmi   +0.153      clk_ram  +0.517
    clk_sys    +1.389      clk_cpu  +1.878
    hold +0.245, recovery +3.587, removal +1.081, min pulse width +0.396

**A refit does not write the RBF.** `make fit` and `make sta` leave the
assembler's output alone, so the bitstream on disk was still the seed-3 one that
failed. `make asm` after them is what ships the placement that passed -- worth
knowing before flashing something that was "fixed" by a reseed.

**The core's own worst path is now the loader's table mux**, `mod_byte[0] ->
part_base_r[20]` at +0.517. That is the authentic-flash conditional: the mod
byte now selects between two entries per part rather than feeding one. The table
outputs were registered for exactly this reason when `part` widened to 5 bits
(rom_loader.sv), and there is half a nanosecond in hand, but it is the thing to
watch if the tables gain another variant.

## 18. First hardware run of the ritual: it starts, then stalls after one block

**2026-08-15.** `rdft-update.mra` on the MiSTer. The core boots, the game
notices the blank stamp, and the screen reads **NOW UPDATING. PLEASE WAIT A
MOMENT.** with the music playing. Then nothing: it never finishes.

The panel named the fault on the first read:

    flash prog = 0 bytes, 1 blocks erased, 2 DROPPED (drops must be 0)
    flash busy = 0
    Z80 PC     = 18FC   (moving)      voices = 24      ymf writes climbing
    EIP        = 0026D65A

`drops` is the counter added in 17.10 with the comment "should never move". It
moved on the first run. 0x26D65A is 16.6's three-instruction spin: the 386
waiting on a Z80 reply that never comes.

**What the ROM side got right**, checked before chasing the fault: `0x0480000`
holds `seibu_8.u0216` byte for byte against the local image, and `0x2900000`
holds `gun_dogs_pcm.u0217` byte for byte -- so the authentic part table, the
43 MB map and the new PCMSRC region all work on hardware. The updater got as far
as it did BECAUSE the source window feeds it.

### 18.1 The updater does two things this core said it would not

`tools/mame_flash_port.lua` -- a new probe that logs the wave-memory port in
BOTH directions, where the existing one logs only writes -- run against MAME
with a blank nvram:

    W 17 = 20  addr=000000     erase setup, chip 0
    W 17 = D0  addr=000001     confirm, chip 0 starts
    W 17 = 20  addr=100000     erase setup, chip 1, immediately
    W 17 = D0  addr=100001     confirm, chip 1 starts too
    R 02 -> 00 addr=000000     poll chip 0: busy
    R 02 -> 00 addr=100000     poll chip 1: busy
    ...
    W 17 = 40  addr=000004     program setup
    W 14 = 03                  rewind so the datum lands at 4
    W 17 = 03  addr=000004     the datum
    W 17 = 40  addr=000005     the NEXT setup, with no poll in between

1. **Both chips erase concurrently.** 17.10's module had ONE erase engine and a
   comment claiming "the updater walks them in lockstep anyway -- it erases a
   block, polls it, and only then moves on". That was an assumption, written as
   if it were a finding, and it is false.
2. **Programming never polls.** 40, datum, 40, datum, as fast as the Z80 can
   drive the port. The same comment claimed "it polls WSMS before every
   command", which is what the datasheet says a host should do and not what
   this one does.

The two dropped commands were chip 1's erase pair, refused because chip 0's
sweep had the single engine. Chip 1 then sat in read-array mode answering polls
with 0xFF out of the blank flash -- which is not a status byte at all -- and the
updater waited for a chip that had never been told to do anything.

### 18.2 What was built instead

* **One sweep per chip**, sharing the write port by alternating (`er_turn`), so
  two concurrent erases finish together rather than one starving the other.
* **A command is never refused.** A byte program parks in a one-deep slot per
  chip and jumps the queue ahead of the sweeps; `dbg_drops` now counts only the
  case where a second byte lands on a full slot, which needs a Z80 `out` faster
  than an SDRAM write.
* A test that reproduces the hardware sequence exactly -- both chips erased back
  to back, both polled, then eight bytes programmed with nothing waiting in
  between. **Against the old single-engine module it fails with `dbg_erases =
  1` and a busy mask of 1**, which is the MiSTer's reading reproduced in
  Verilator.

**And a second bug found by fixing the first.** The new scheduler was written as
`else if` off the write-retire branch -- which tests "did a write just finish",
not "is the port free" -- so it issued a second request on top of an outstanding
one and the toggle handshake lost writes. The testbench caught it immediately:
58,960 bytes of a 65,536-byte block left unerased. On hardware it would have
been a quietly incomplete flash image, which is the failure mode this whole
section exists to avoid.

### 18.3 The updater waits for the JUMPER, and the Z80's own code said so

Third run, with the erase queue: `2 blocks erased, 0 DROPPED, prog 0` -- exactly
the second run. The queue changed nothing, which means the updater was not
sending the other thirty pairs at all.

**Two controls, both cheap, and both changed the question.** Loading the
pre-flashed `rdft.mra` on the same bitstream reads `f2 push/pop = 14/14` -- the
identical figure the stalled run shows, so that counter was boot chatter and not
a stuck handshake. The working core's EIP sits at 0x203F0A, the vblank loop,
where the stalled one sits at 0x26D65A -- which is the updater's normal Z80
round-trip wait (16.6), so THAT reading was expected too. Between them they
killed both theories in about two minutes.

**What actually named it: the Z80's PC, sampled eight times.** 1901, 18F5, 1901,
18F9, 1903, 1901, 18F9, 1903 -- a fifteen-byte loop. The Z80's program is in
SDRAM, so the instrument for reading it already existed:

    tools/slop dump 0x2018F0

    18F5: 3A D4 3C     LD   A,(0x3CD4)
    18F8: B7           OR   A
    18F9: C4 47 01     CALL NZ,0x0147
    18FC: 3A 0A 40     LD   A,(0x400A)      ; JP1
    18FF: E6 03        AND  0x03
    1901: FE 03        CP   0x03            ; update mode?
    1903: C2 F5 18     JP   NZ,0x18F5       ; no -> spin

The updater erases its first block pair and then **waits for the jumper**. The
core ties `jumpers` to 0xFC, Normal, so it spins there forever with the music
playing -- which is why every symptom pointed at the flash and none of them was
the flash.

**17.8's open question is closed the other way.** Section 10b saw a deadlock with
this port all-ones and concluded update mode "is not reachable"; that deadlock
was the 0x4009 d0 bug fixed later in the same section, and the note it left
behind was wrong. `jumpers` is now `set_upd ? 8'hFF : 8'hFC` -- the authentic
MRAs run in update mode, the pre-flashed ones do not.

Leaving update mode selected does not make a programmed cartridge reflash: the
game skips the updater on a matching stamp whatever the jumper says, which is
what section 0 measured under MAME's own default of Update.

**The lesson, and it is 13b's again.** Three of the four instruments read
"wrong" and only one of them was: `flash prog = 0` was a symptom, `f2 14/14` and
`EIP 0x26D65A` were normal, and the fault was in a port nobody was watching.
Sampling the Z80 PC and disassembling out of SDRAM cost one command and found
it. Do that before building a new probe.

### 18.4 THE RITUAL RUNS, AND WHAT IT WROTE IS THE VERIFIED IMAGE

Fourth run, with JP1 in update mode. It works.

    flash prog = 1939011 bytes, 32 blocks erased, 0 DROPPED
    fifo reads = 40747     f2 push/pop = 40773/40773

**1,939,011 is exactly the payload section 0 measured under MAME**, to the byte,
and `tools/build_soundflash.py` accounts for the same total from the other end
(1,708,978 + 230,029 + the four stamp bytes). All 32 blocks erased, which is the
queue from 547f150 doing its job -- and 0 drops.

It ends on the screen the hardware ends on:

    UPDATE COMPLETED. AFTER SWITCHING OFF THE POWER, RETURN 'JP1' TO ITS
    ORIGINAL POSITION AND THEN TURN THE POWER BACK ON.

which is the game confirming 18.3 in its own words.

**The contents were checked, not assumed.** Eight windows dumped over JTAG and
compared against `build_soundflash.py`'s image -- itself verified bit-for-bit
against MAME's own flash nvram -- chosen at the places an off-by-one shows: the
stamp, the head, the middle, both sides of the seam at 0x1A13B6 where the second
source ROM takes over, the last payload byte at 0x1D9642, and the erased tail.
**All eight match.**

That is 17.7 step 1's acceptance test, passed: zip -> MRA -> loader -> the 386's
source window -> the Z80 -> the wave port -> the flash controller -> SDRAM, and
what comes out the far end is the image MAME produces.

**Pace: about 5,150 bytes a second, so ~6 minutes for the payload.** Slower than
16.6's "tens of seconds" guess -- that reasoned from MAME's ~7 emulated seconds,
and MAME charges nothing for the 386/FIFO/Z80 round trip that actually paces
this. Real hardware takes minutes for a different reason (flash program time),
so the figures coincide by accident.

### 18.5 IT PLAYS. The cartridge flashed itself and then booted from it

Reset from the OSD -- which keeps SDRAM, where `load_core` would re-download the
blank flash and start over -- and rdft comes up in **attract with sound**: the
title logo over a live demo, rock terrain, shot patterns and explosions, INSERT
COIN(S), the copyright line. 94 KB of screenshot, against the 13.7 KB the halt
screen was.

    voices = 21   synth ovrun = 0

Twenty-one PCM and FM slots sounding, which means the samples being played are
the ones the game programmed into its own flash a few minutes earlier. The
region's eight sample windows still match `build_soundflash.py` after the reset.

**And the updater was SKIPPED**, on a core still wired to update mode: the
panel's flash counters read 0 erases, 0 bytes, 0 drops on this boot. That is
section 0's last unverified claim -- a matching stamp skips the ritual whatever
JP1 says -- confirmed on hardware rather than inferred from MAME. So leaving the
authentic MRAs in update mode costs nothing once the flash is good, and the DIP
17.8 proposed is not needed.

The whole chain now runs on real hardware: a stock MRA with a BLANK flash, the
game's own updater reading its own ROMs through the 386's window, 1,939,011
bytes programmed a byte at a time through the wave-memory port, and the game
booting from the result.

### 18.6 What is still not tested

**Persistence: BUILT, not yet run on hardware.** See 18.7.

**The other two sets.** rdft2 and rfjet have the same table and the same
handshake but their own payloads and job tables; nothing about them has been run.

**Sound quality against MAME.** That the samples play is not that they are
right; 10d's method (`-wavwrite` against a hardware capture) is what would say
so, and rdft's pre-flashed audio has been through it while this image has not --
though the two images are byte-identical, which is most of the argument.

### 18.7 Persistence: the flash as an arcade NVRAM

`rtl/spi_nvram.sv`, both directions of MiSTer's `<nvram>` mechanism on index 2,
plus the element in the three `-update` MRAs. Lint-clean and `make verify`
green; NOT yet run on hardware.

**The two directions want different SDRAM ports, and that is the design.**

* **Load** arrives as an ordinary ioctl download at index 2, AFTER the ROM
  image, so it lands on top of the blank flash the MRA just carried. It takes
  ch3's write path -- the only writable one -- and holds the board in reset
  while it runs, exactly as the ROM image does. Nothing else is asking for ch3
  then.
* **Save** runs while the GAME is running, so it reads through **ch5**, the
  YMF271's own sample channel, behind a `spi_sdr_arb2` with the YMF winning
  ties. ch5 is idle between voice fetches and the sound CPU never waits on it,
  so a two-megabyte read-back cannot starve anything that matters.

**The save side cannot be stalled, so it prefetches two lines.** `hps_io`
samples `ioctl_din` on the same edge it advances its address and there is no
wait signal in that direction. Fetching a line when the address crosses into it
would arrive late; instead the NEXT line is fetched as soon as the current one
lands, so a crossing swaps in a line that is already here and the fetch that
follows has eight SPI byte times to complete.

**One save request per settled burst, not per byte.** The ritual programs two
million bytes; asking Main two million times would be absurd. `spi_nvram`
watches the flash's `dirty` toggle, restarts a counter on every store, and
raises `ioctl_upload_req` once when the flash has been quiet for ~0.1 s.

**When the save actually happens is Main's business, and it is worth knowing:**
`UIO_CHK_UPLOAD` is polled in `MENU_GENERIC_MAIN2` -- the OSD's main menu --
not on a background timer. So the flash is written to
`/media/fat/config/nvram/<mra>.nvm` the next time the user OPENS THE OSD, which
the MRAs now say in as many words. There is no way to make it happen unprompted
from the core side.

**Two ioctl consumers now share one stream**: `rom_loader` takes index 0 and
`spi_nvram` index 2, each with its own `ioctl_wait`, OR'd together on the way
back to `ddr_rom_reader`. The fast-load replay passes any non-zero index
straight through, so nothing there needed changing.

### 18.8 The save file came back wrong, and the bench that should have existed

The nvram work went to hardware untested. The ritual ran, the OSD was opened,
`/media/fat/config/nvram/rdft-update.nvm` appeared at exactly 2,097,152 bytes --
and its sha256 was not the image's. The file was:

    80 | 80 4A 4A 36 03 FC FB FB | 80 4A 4A 36 03 FC FB FB | ...

byte 0 twice over, then the first eight bytes repeated 262,143 times. Two
separate faults, one line each, and the byte stream names both:

* **The prefetch re-armed without asking for anything.** `fetching <= 1` with no
  `rd_req <= ~rd_req` leaves ack == req, so the completion branch fires again
  immediately and latches the PREVIOUS line's `rd_dout` as though it were the
  next one. `nxt` therefore always equalled `cur`, and every line crossing swapped
  in the line it already had.
* **The 0xAA's `ioctl_rd` was counted as a byte.** hps_io raises `ioctl_upload`
  and that first `ioctl_rd` on the same edge; it is a request for byte 0, not an
  acknowledgement of one. Counting it left the index a beat behind and sent byte
  0 twice.

**`sim/tb_nvram.cpp` is what should have gone first.** It drives both directions
against a behavioural SDRAM, modelling the save exactly as `sys/hps_io.sv` does
-- 0xAA opens the transfer, then each data word takes the byte on `ioctl_din`
and asks for the next, with no way to stall. Both faults reintroduced fail it in
under a second, and in the same shape hardware showed: the missing request makes
byte 8 the first wrong one, and the miscounted `ioctl_rd` shifts the whole file
by one from byte 0.

Two things the bench pinned down that hardware could not:

* **the read latency the prefetch must cover.** Its SDRAM model answers reads in
  30 cycles and it runs the host at 12 cycles a word -- faster than any real SPI
  transfer, and three times faster than the memory -- so a fetch issued at a
  crossing could not possibly arrive. Only the one-line lead makes that pass.
* **the quiet timer**, which is 2^24 clk_ram cycles in hardware and would need
  fifty million simulated ones. It is a parameter now, and the bench builds with
  `-GQUIET_BITS=8`.

The one thing the bench deliberately does NOT assert is that the first line is
ready before the first byte is asked for. It cannot be: the 0xAA and the first
data word are separate SPI transactions on the HPS side, microseconds apart, so
the bench gives that gap and stresses only the steady state.

### 18.9 The save is byte-exact; the LOAD was thrown away by the fast path

With 18.8's fixes, the second attempt:

    sha256  659df8c6a964c109465cc6d927f1565c57beae5d9d86b88b09e5976b57befee1
    2,097,152 bytes, /media/fat/config/nvram/rdft-update.nvm

**identical to `build_soundflash.py`'s image**, which is itself bit-exact
against MAME's own flash nvram. The save path is done: the game programmed the
flash, the core read all two megabytes back out through ch5 and the ioctl
handshake, and what landed on the SD card is the right image.

**Then reloading the MRA ran the ritual all over again.** The load did not take,
and `bytes_in` said where it went: 25,886,720, exactly the ROM image with no
extra two megabytes. The nvram had not reached the loader OR the nvram module --
it had been discarded outright, by our own fast-load path:

    assign dl_index = replay ? ROM_INDEX : ioctl_index;
    assign dl_wr    = replay ? ddr_wr    : ioctl_wr;

While `ddr_rom_reader` replays the image out of DDR3, everything arriving from
hps_io is masked to index 0 and its write strobe is ignored. A 24.7 MB fast load
replays for about two seconds, and Main sends the nvram the moment its own DMA
returns -- straight into that window. The file never had a chance.

**The fix is to take the raw ioctl, not the replayed copy.** The nvram is never
fast-loaded; it has no business downstream of that module. It now reads hps_io
directly and holds `ioctl_wait` high while the ROM image is still landing, so
its bytes wait for ch3 instead of racing the replay for it. The two consumers
now sit on opposite sides of `ddr_rom_reader` and their backpressure meets again
at hps_io's single `ioctl_wait`.

**And the counter that would have said so in one reading**: `nvram in` on the
sound panel, the bytes the core actually received. Zero after a load, with an
`.nvm` present, is a different fault from loading the wrong thing -- and this
whole diagnosis was inferred from `bytes_in` NOT moving, which is a much weaker
signal than the one that should have been there.
