//============================================================================
//  SlopperPI - Seibu SPI / SXX2E
//
//  Shared constants. Included inside module bodies rather than provided as a
//  SystemVerilog package: Quartus 17.0 is fussy about package compile order and
//  about unpacked-array parameters, and a plain include sidesteps both.
//============================================================================

// Most modules use only a few of these; suppressing the unused-parameter
// warning here is simpler than a per-module waiver, and Verilator's -file
// filter does not reach into included files anyway.
/* verilator lint_off UNUSEDPARAM */

// --------------------------------------------------------------------------
// SDRAM byte-address map (see PLAN.md section 4)
//
// ONE map for every set, sized for the worst case in the family rather than
// for rdfts: rdft2 has 12 MB of tiles and rfjet 24 MB of sprites. A set that
// needs less simply leaves the tail of its region unwritten, which costs
// nothing but address space -- and address space is what a 64 MB module has.
//
// This is why the core's addresses are 26 bits. They were 25 (32 MB) and the
// controller's are 27; the five WIDTHEXPAND warnings that produced were
// harmless in themselves but were also the reason nothing above 32 MB could be
// reached, which put rdft2 (34.4 MB pre-flashed) out of range.
// --------------------------------------------------------------------------
localparam [25:0] SDR_PRG_BASE     = 26'h000_0000;  //  2 MB   386 program
localparam [25:0] SDR_Z80_BASE     = 26'h020_0000;  // 256 KB  Z80 program
localparam [25:0] SDR_CHARS_BASE   = 26'h024_0000;  // 192 KB  text tiles
localparam [25:0] SDR_PCM_BASE     = 26'h028_0000;  // 2.5 MB  YMF271 samples
// The cartridge sets' Z80 program, read by the 386 through the sound01 window.
// It lives in the half megabyte the sample region has spare above the 2 MB
// flash image, so nothing else in the map moves; the YMF271 only ever addresses
// the low 2 MB of SDR_PCM_BASE (ymf271_synth.sv masks to [20:0]), so the two
// cannot collide. Stored PACKED, one byte per 386 dword -- see spi_cpu.sv.
//
// The WHOLE of sound1.u0222 goes here, all 512 KB, for every set that has one.
// Only part of it is the Z80 program -- rdft2's is at 0x60000, rfjet's at
// 0x44000 -- but which part is a per-set constant of exactly the kind PLAN.md's
// rfjet notes warn gets copied across wrong, and rfjet's LENGTH has never been
// measured at all. Storing the region whole makes both facts irrelevant: the
// window answers with whatever MAME's region holds at that address, so the
// question of where the program starts is the game's business and not ours.
// The fit is exact, which is why this costs nothing: 0x500000 - 0x480000.
localparam [25:0] SDR_SND01_BASE   = 26'h048_0000;  // 512 KB  sound1.u0222
localparam [25:0] SDR_TILES_BASE   = 26'h050_0000;  //  12 MB  background tiles
localparam [25:0] SDR_SPRITES_BASE = 26'h110_0000;  //  24 MB  sprites (3 chunks)
localparam [25:0] SDR_END          = 26'h290_0000;  //  41 MB total

// Size of ONE sprite plane-pair chunk in the ROM set -- 4 MB for the SEI252
// games, 6 MB for rdft2, 8 MB for rfjet. It used to be the address stride
// between the three chunks in SDRAM; since rom_loader interleaves them
// (M_SPR_ILV) there is no stride, and what survives is the tile count this
// implies: elements = chunk / 64, which is what MAME's sprite extra-bank rule
// is stated in terms of.
localparam [25:0] SPR_CHUNK_SIZE       = 26'h040_0000;  // SEI252 sets
localparam [25:0] SPR_CHUNK_SIZE_RDFT2 = 26'h060_0000;
localparam [25:0] SPR_CHUNK_SIZE_RFJET = 26'h080_0000;

// --------------------------------------------------------------------------
// Which ROM set is loading. The MRA's mod byte says so: bit 0 picks the SXX2C
// cartridge board wiring, and bits 3:1 pick the set WITHIN that board, so an
// existing MRA that sends only bit 0 keeps selecting the board's first set.
//
//   mod 0x00  SXX2E, set 0  -> rdfts
//   mod 0x01  SXX2C, set 0  -> rdft
//   mod 0x03  SXX2C, set 1  -> rdft2
//   mod 0x05  SXX2C, set 2  -> rfjet
//
// set_id is 2 bits and rfjet fills it. A fifth set needs it widened here, in
// rom_loader's `set_id` port and in SeibuSPI.sv's decode -- the mod byte itself
// has room for eight.
// --------------------------------------------------------------------------
localparam [1:0] SET_RDFTS = 2'd0;
localparam [1:0] SET_RDFT  = 2'd1;
localparam [1:0] SET_RDFT2 = 2'd2;
localparam [1:0] SET_RFJET = 2'd3;

// --------------------------------------------------------------------------
// ROM download codecs (rtl/spi_rom_decode.sv).
//
// A part can be decoded on its way into SDRAM instead of copied. WHICH parts
// is the MRA's call, not the RTL's: the MRA's index-1 config carries
// {part index, codec id} pairs and rom_loader applies them by part number.
// Everything defaults to CODEC_RAW, so an MRA that says nothing behaves
// exactly as before.
//
// Keep these ids in step with the table in the MRA comment block; they are the
// contract between the two.
// --------------------------------------------------------------------------
localparam [3:0] CODEC_RAW      = 4'd0;  // straight copy
localparam [3:0] CODEC_BPE_DPCM = 4'd1;  // rdft2 sample flash: BPE over DPCM

// --------------------------------------------------------------------------
// Video timing (seibuspi.cpp:898)
//   dot clock 28.63636 MHz / 4 = 7.1590909 MHz = clk_sys / 8
//   448 x 296 total, 320 x 240 visible => 53.99 Hz
// --------------------------------------------------------------------------
localparam [9:0] HTOTAL  = 10'd448;
localparam [9:0] HBSTART = 10'd320;   // first blanked pixel
localparam [9:0] VTOTAL  = 10'd296;
localparam [9:0] VBSTART = 10'd240;   // first blanked line (real hw 253)

// Sync pulse positions are not documented for the Seibu CRTC; these sit inside
// the blanking interval and keep the analog output roughly centred.
localparam [9:0] HSSTART = 10'd344;
localparam [9:0] HSEND   = 10'd392;
localparam [9:0] VSSTART = 10'd250;
localparam [9:0] VSEND   = 10'd253;

// --------------------------------------------------------------------------
// Layer / palette geometry
// --------------------------------------------------------------------------
localparam [12:0] PAL_BASE_TILES = 13'd4096;  // back / fore / midl colour base
localparam [12:0] PAL_BASE_TEXT  = 13'd5632;  // text colour base

// --------------------------------------------------------------------------
// Tile / char decryption keys (seibuspi_v.cpp:90). Selected by game id so that
// rdft2 / rfjet can be added later without touching the decrypt unit.
// --------------------------------------------------------------------------
localparam [23:0] TKEY1_SEI252 = 24'h5A3845;
localparam [23:0] TKEY2_SEI252 = 24'h77CF5B;
localparam [23:0] TKEY3_SEI252 = 24'h1378DF;

localparam [23:0] TKEY1_RDFT2  = 24'h823146;
localparam [23:0] TKEY2_RDFT2  = 24'h4DE2F8;
localparam [23:0] TKEY3_RDFT2  = 24'h157ADC;

localparam [23:0] TKEY1_RFJET  = 24'hAEA754;
localparam [23:0] TKEY2_RFJET  = 24'hFE8530;
localparam [23:0] TKEY3_RFJET  = 24'hCCB666;

/* verilator lint_on UNUSEDPARAM */
