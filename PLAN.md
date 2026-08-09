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
channel that is read-only today, and save-file plumbing — and without that last
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
  keys. Both are *address-independent*, unlike SEI252: fixed-constant bit
  permutations feeding `seibu_partial_carry_sum16/32`, so no `key_table[addr]`
  lookup and no per-tile key fetch. We already have the partial-carry
  primitive. Both then apply `sprite_reorder`, which permutes words inside
  64-byte groups; for on-the-fly decode that is an address swizzle at fetch
  rather than a pass over ROM.
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

Single 32 MB SDRAM module required. The ROM loader performs the MAME
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
  **Open item.**

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
4. **z386 accuracy/speed** vs a real 386DX-25 (see §6). Currently the core runs
   at the full 57.27 MHz `clk_sys`, which is 2.3x a 386DX-25 before counting
   z386x's caches and fast paths. Gameplay speed is locked to the 54 Hz vblank
   interrupt either way, but the per-frame compute budget is not: Raiden
   Fighters' slowdown under heavy fire is part of how the game plays, and at
   this speed it will not happen. `spi_cpu` already has a `cpu_en` input for
   this; what it needs is a calibrated throttle and an OSD control. z386 has no
   clock-enable port, so the lever is either wait-states on the memory
   interface or adding a real `cpu_en` to the core. **Unresolved.**
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

## 11. TASKS

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
