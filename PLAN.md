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
NVRAM after that one-time flash. There is no dumped pre-flashed image, and the
mapping from the cartridge's `sound01` region into flash is a runtime software
transform we would have to reverse.

`rdfts` is the same game on a single board that replaces all of that with:

* a plain 128 KB Z80 program ROM (no `z80_prg_transfer_w` download from the 386),
* a plain 2 MB YMF271 sample ROM (`raiden-f_pcm2.u0975`), directly on the YMF bus,
* no cartridge, no flash, no region lock dance.

CPU, video, sprite chip, GFX ROMs and encryption are **identical** between the two.
So the core is built against SXX2E and the SPI cart variants can be added later
behind an MRA config bit once flash emulation exists.

Later targets sharing >90% of this core (deliberately kept in mind while designing):

| Set       | Board   | Sprite crypt | Notes                          |
|-----------|---------|--------------|--------------------------------|
| `rdfts`   | SXX2E   | SEI252       | **primary target**             |
| `rdft2us` | SXX2F   | RISE10       | + 93C46 EEPROM instead of DS2404 |
| `rfjets`  | SXX2G   | RISE11       | different clocks               |
| `rdft`…   | SXX2C   | SEI252       | needs flash + cart emulation   |

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
can go faster, but they build with Quartus **Standard** and keep a `seed_sweep.py`
in the repo, which says something about how hard 85 MHz is to hit.

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
   (`l1_cache.sv:108`). So the video DMA engines reading main RAM cannot see
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

3. *Self-modifying code works.* The icache snoops the dcache's own store stream
   (`z386.sv:678` `icache_write_snoop`) and patches the cached data, so code
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
   4-op FM. Until FM lands the core will have partial audio.
2. **Sprite bandwidth.** 3 SDRAM reads per 16-pixel sprite row; worst case 512
   sprites. Needs a per-line sprite list pre-pass in hblank and a hard per-line
   fetch budget. Measure in sim before trusting it.
3. **SDRAM at 114.5 MHz** with CAS3 — above the usual 100 MHz for this
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
6. **Alpha blending** is a MAME approximation, not the real hardware behaviour
   (MAME's own TODO). Ours will be equally approximate.
7. **DS2404** — the game reads it; a stub returning 0 may or may not satisfy the
   boot checks. `spi_ds2404_unknown_r` returning 0x00 is what MAME does.
8. **Toolchain.** Quartus Prime 17.0.0 Lite at `~/intelFPGA_lite/17.0/quartus`
   (`bin/quartus_sh`), target part `5CSEBA6U23I7` confirmed present. Note this is
   *Lite*, whereas MiSTer officially builds with 17.0.x **Standard** — watch for IP
   or fitter differences, and treat resource/timing numbers as indicative until
   confirmed on a Standard install. Verilator 5.050 is also available for lint and
   decrypt-unit unit tests.

---

## 10. Gotchas found the hard way

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
- [~] **T4** Video: DMA engines, palette, 4 layer pipelines, sprite engine,
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
      - [ ] **`spi_sprite.sv` — not started.** The mixer's sprite input is tied
            invalid, so it currently composites the four tile layers alone.
            The decrypt unit it needs is already done and verified (T2).
      - [x] Golden-reference harness against MAME (see section 12). The frame
            diff went from 100% wrong to **40.1%** as four real bugs fell out.
      - [x] **All four layers verified 299/300** against reference scanlines
            (back, midl, fore, text). The one remaining pixel is the phase
            edge at x=0.
      - [~] **Frame 35.8% wrong, and it is now all in the mixer.** The layer
            line buffers are correct, so the fault is in `spi_mixer`:
            composite order, palette indexing, the alpha table, or the
            output phase. That is a much smaller search space than before.

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

      **Next step should be a frame-level testbench, not the sprite engine.**
      Both bugs found while writing T4 (the RAM read off-by-one and the RGB
      multi-driver) produced silently wrong data rather than a build failure,
      and the same class of bug in the render path is invisible without
      comparing actual pixels. Drive the Verilator model with a captured
      tilemap/palette RAM dump from MAME and diff the line buffers.
- [ ] **T5** Sound: T80, banking, FIFOs, coin latch, YMF271 (PCM then FM).
- [ ] **T6** MRA, docs, build verification.

Order matters: T4 is the visible payoff and depends only on T1–T3. T5 can lag.
