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
// --------------------------------------------------------------------------
localparam [24:0] SDR_PRG_BASE     = 25'h000_0000;  //  2 MB  386 program
localparam [24:0] SDR_Z80_BASE     = 25'h020_0000;  // 256 KB Z80 program
localparam [24:0] SDR_CHARS_BASE   = 25'h024_0000;  // 192 KB text tiles
localparam [24:0] SDR_PCM_BASE     = 25'h028_0000;  //  2 MB  YMF271 samples
localparam [24:0] SDR_TILES_BASE   = 25'h048_0000;  //  6 MB  background tiles
localparam [24:0] SDR_SPRITES_BASE = 25'h0A8_0000;  // 12 MB  sprites (3 x 4 MB)
localparam [24:0] SDR_END          = 25'h168_0000;  // 22.5 MB total

// The three sprite plane-pair chunks are 4 MB apart.
localparam [24:0] SPR_CHUNK_STRIDE = 25'h040_0000;

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
