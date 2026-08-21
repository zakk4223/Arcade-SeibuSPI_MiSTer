//============================================================================
//  SeibuSPI - Seibu SPI / SXX2E for MiSTer
//
//  Raiden Fighters (rdfts, SXX2E single board).
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//============================================================================

module emu
(
	//Master input clock
	input         CLK_50M,

	//Async reset from top-level module.
	//Can be used as initial reset.
	input         RESET,

	//Must be passed to hps_io module
	inout  [48:0] HPS_BUS,

	//Base video clock. Usually equals to CLK_SYS.
	output        CLK_VIDEO,

	//Multiple resolutions are supported using different CE_PIXEL rates.
	//Must be based on CLK_VIDEO
	output        CE_PIXEL,

	//Video aspect ratio for HDMI. Most retro systems have ratio 4:3.
	//if VIDEO_ARX[12] or VIDEO_ARY[12] is set then [11:0] contains scaled size instead of aspect ratio.
	output [12:0] VIDEO_ARX,
	output [12:0] VIDEO_ARY,

	output  [7:0] VGA_R,
	output  [7:0] VGA_G,
	output  [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_DE,    // = ~(VBlank | HBlank)
	output        VGA_F1,
	output [1:0]  VGA_SL,
	output        VGA_SCALER, // Force VGA scaler
	output        VGA_DISABLE, // analog out is off

	input  [11:0] HDMI_WIDTH,
	input  [11:0] HDMI_HEIGHT,
	output        HDMI_FREEZE,
	output        HDMI_BLACKOUT,
	output        HDMI_BOB_DEINT,

`ifdef MISTER_FB
	// Use framebuffer in DDRAM
	output        FB_EN,
	output  [4:0] FB_FORMAT,
	output [11:0] FB_WIDTH,
	output [11:0] FB_HEIGHT,
	output [31:0] FB_BASE,
	output [13:0] FB_STRIDE,
	input         FB_VBL,
	input         FB_LL,
	output        FB_FORCE_BLANK,

`ifdef MISTER_FB_PALETTE
	output        FB_PAL_CLK,
	output  [7:0] FB_PAL_ADDR,
	output [23:0] FB_PAL_DOUT,
	input  [23:0] FB_PAL_DIN,
	output        FB_PAL_WR,
`endif
`endif

	output        LED_USER,  // 1 - ON, 0 - OFF.

	// b[1]: 0 - LED status is system status OR'd with b[0]
	//       1 - LED status is controled solely by b[0]
	// hint: supply 2'b00 to let the system control the LED.
	output  [1:0] LED_POWER,
	output  [1:0] LED_DISK,

	// I/O board button press simulation (active high)
	// b[1]: user button
	// b[0]: osd button
	output  [1:0] BUTTONS,

	input         CLK_AUDIO, // 24.576 MHz
	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,
	output        AUDIO_S,   // 1 - signed audio samples, 0 - unsigned
	output  [1:0] AUDIO_MIX, // 0 - no mix, 1 - 25%, 2 - 50%, 3 - 100% (mono)

	//ADC
	inout   [3:0] ADC_BUS,

	//SD-SPI
	output        SD_SCK,
	output        SD_MOSI,
	input         SD_MISO,
	output        SD_CS,
	input         SD_CD,

	//High latency DDR3 RAM interface
	//Use for non-critical time purposes
	output        DDRAM_CLK,
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,

	//SDRAM interface with lower latency
	output        SDRAM_CLK,
	output        SDRAM_CKE,
	output [12:0] SDRAM_A,
	output  [1:0] SDRAM_BA,
	inout  [15:0] SDRAM_DQ,
	output        SDRAM_DQML,
	output        SDRAM_DQMH,
	output        SDRAM_nCS,
	output        SDRAM_nCAS,
	output        SDRAM_nRAS,
	output        SDRAM_nWE,

`ifdef MISTER_DUAL_SDRAM
	//Secondary SDRAM
	input         SDRAM2_EN,
	output        SDRAM2_CLK,
	output [12:0] SDRAM2_A,
	output  [1:0] SDRAM2_BA,
	inout  [15:0] SDRAM2_DQ,
	output        SDRAM2_nCS,
	output        SDRAM2_nCAS,
	output        SDRAM2_nRAS,
	output        SDRAM2_nWE,
`endif

	input         UART_CTS,
	output        UART_RTS,
	input         UART_RXD,
	output        UART_TXD,
	output        UART_DTR,
	input         UART_DSR,

	// Open-drain User port.
	input   [6:0] USER_IN,
	output  [6:0] USER_OUT,

	input         OSD_STATUS
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

assign VGA_F1       = 0;
assign VGA_SCALER   = 0;
assign VGA_DISABLE  = 0;
assign HDMI_FREEZE  = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_S   = 1;   // signed
assign AUDIO_MIX = 0;

assign LED_DISK  = 0;
assign LED_POWER = 0;
assign BUTTONS   = 0;
// dl_download rather than ioctl_download, so the activity light stays on for
// the DDR3 replay too -- with a fast download that is where nearly all of the
// wall clock goes.
assign LED_USER  = dl_download;

//////////////////////////////////////////////////////////////////

wire [1:0] ar              = status[2:1];
wire [2:0] scandoubler_fx  = status[5:3];
wire [1:0] scale           = status[7:6];
wire       orientation_vert = ~status[10];   // default 0 => vertical
wire       rotate_cw       = status[11];

`include "build_id.v"
localparam CONF_STR = {
	// SS<base>:<size> is how a core declares save states. Main_MiSTer parses it
	// out of the SECOND semicolon-delimited field (user_io.cpp parse_config,
	// i == 1), mmaps four slots of that size at that base, and polls a
	// generation counter in each slot's first dword -- so the core writes the
	// blob into DDR3 itself and nothing goes over ioctl. It works for an
	// MRA-loaded core exactly as for a ROM-loaded one (user_io.cpp:1554).
	// 4 x 512 KB at 0x3E000000; rtl/system_consts.sv is the other end of this.
	"SeibuSPI;SS3E000000:80000;",
	"-;",
	"O[42:41],Savestate Slot,1,2,3,4;",
	"O[40],Autoincrement Slot,Off,On;",
	"R[43],Save state (Alt-F1);",
	"R[44],Restore state (F1);",
	"-;",
	// The `I,` list is what savestate_ui's ss_info indexes into, so the OSD can
	// say what just happened. Order is fixed by that module.
	"I,",
	"Slot=DPAD|Save/Load=Start+DPAD,",
	"Active Slot 1,",
	"Active Slot 2,",
	"Active Slot 3,",
	"Active Slot 4,",
	"Save to slot 1,",
	"Restore slot 1,",
	"Save to slot 2,",
	"Restore slot 2,",
	"Save to slot 3,",
	"Restore slot 3,",
	"Save to slot 4,",
	"Restore slot 4;",
	"-;",
	"P1,Video Settings;",
	"P1O[2:1],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"P1O[5:3],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"P1O[7:6],Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer;",
	"P1-;",
	"P1O[10],Orientation,Vert,Horz;",
	"P1O[11],Rotation,CCW,CW;",
	"-;",
	// O[20] was the Vital Signs Panel and O[21] the Freeze Button switch. Both
	// are gone -- the panel with the telemetry (PLAN.md 29), the switch because
	// pausing is a BOUND BUTTON now (PLAN.md 33) rather than a menu setting. The
	// bits are left unused rather than reassigned, so a saved .CFG from an older
	// build cannot turn something else on by accident.
	// H1: hidden when status_menumask bit 1 is set, which is ~set_sxx2c. SXX2E
	// has a mask ROM where the cartridge has a flash chip, so there is nothing
	// to build and nothing to choose.
	// Pre-built is the DEFAULT. Before the MRAs collapsed, rdft, rdft2 and
	// rfjet each had a pre-flashed MRA that booted instantly; with one MRA
	// per set, defaulting to the ritual would have made those three boot in
	// six minutes where they used to boot in seconds. It also means the
	// common path does not depend on this option being touched at all.
	"H1O[22],Sample Flash,Pre-built,Cart copy;",
	"-;",
	"DIP;",
	"-;",
	"T[0],Reset;",
	"R[0],Reset and close OSD;",
	// The MRAs are named after the games now, not the sets, and rdfts is a
	// clone of rdft in MAME so it sits under _alternatives. This only matters
	// when the RBF is started directly rather than through an MRA.
	"DEFMRA,/_Arcade/Raiden Fighters (Germany).mra;",
	"V,v",`BUILD_DATE
};

wire        forced_scandoubler;
wire  [1:0] buttons;
wire [127:0] status;
wire [10:0] ps2_key;
wire [21:0] gamma_bus;
wire        direct_video;
wire        video_rotated;

wire        ioctl_download;
wire        ioctl_wr;
wire [25:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire  [7:0] ioctl_index;
wire        ioctl_wait;   // driven below, from two sources
wire        ioctl_upload;
wire        ioctl_upload_req;
wire  [7:0] ioctl_upload_index;
wire  [7:0] ioctl_din;
wire        ioctl_rd;

// The loader's side of ddr_rom_reader. For a slow download these are the ioctl
// signals unchanged; for a fast one the HPS has already put the image in DDR3
// and `dl_*` is that image replayed as the same byte stream. `dl_download`
// stays high until the last byte is handed over, which `ioctl_download` does
// NOT -- see the header of rtl/ddr_rom_reader.sv.
wire        dl_download;
wire        dl_wr;
wire  [7:0] dl_dout;
wire  [7:0] dl_index;
// Two consumers of the ioctl stream, on opposite sides of the DDR3 replay: the
// ROM loader takes index 0 out of `dl_*` (replayed or not), spi_nvram takes
// index 2 straight from hps_io. Their backpressure meets again here, because
// hps_io has only one ioctl_wait.
wire        dl_wait;
wire        ldr_wait, nv_dl_wait, rdr_wait;
assign      dl_wait = ldr_wait;
assign      ioctl_wait = rdr_wait | nv_dl_wait;

wire [15:0] joystick_p1, joystick_p2;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(gamma_bus),
	.direct_video(direct_video),

	.forced_scandoubler(forced_scandoubler),
	.new_vmode(0),
	.video_rotated(video_rotated),

	.buttons(buttons),
	.status(status),
	.status_menumask({~set_sxx2c, direct_video}),
	// savestate_ui moves the slot when the pad changes it, and the OSD has to
	// follow. status_in carries the whole word back with only the slot bits
	// replaced; status_set is the one-cycle "take it" strobe.
	.status_in({status[127:43], ss_slot, status[40:0]}),
	.status_set(ss_status_set),
	.info_req(ss_info_req),
	.info(ss_info),

	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_index(ioctl_index),
	.ioctl_wait(ioctl_wait),

	// The sample flash's save file. Main polls for the request when the OSD is
	// open, then reads the region back a byte at a time. See rtl/spi_nvram.sv.
	.ioctl_upload(ioctl_upload),
	.ioctl_upload_req(ioctl_upload_req),
	.ioctl_upload_index(ioctl_upload_index),
	.ioctl_din(ioctl_din),
	.ioctl_rd(ioctl_rd),

	.joystick_0(joystick_p1),
	.joystick_1(joystick_p2),

	.ps2_key(ps2_key)
);

///////////////////////   CLOCKS   ///////////////////////////////

wire clk_sys;   //  57.272727 MHz - video, I/O, sound
wire clk_cpu;   //  28.636364 MHz - the 386
wire clk_ram;   // 114.545455 MHz - SDRAM controller
wire pll_locked;

pll pll
(
	.refclk  (CLK_50M),
	.rst     (1'b0),
	.outclk_0(clk_ram),
	.outclk_1(clk_sys),
	.outclk_2(clk_cpu),
	.locked  (pll_locked)
);

// Only the ROM download (index 0) holds the board in reset. The DIP transfer
// (index 254) arrives on the same ioctl bus and must not restart the game.
//
// This follows `dl_download`, NOT `ioctl_download`. With a fast download the
// HPS drops ioctl_download as soon as its DMA into DDR3 is done, seconds before
// any of it has reached SDRAM; keying the reset off that releases the 386 into
// an empty image. dl_download stays high until ddr_rom_reader has handed over
// the last byte, and is identical to ioctl_download for a slow download.
// The nvram download is held down for exactly as long as the ROM image is, and
// for two reasons that are now separate lines in spi_nvram. `nv_hold` is this
// one: the file's tail is the DS2404's bookkeeping, and the game must not read
// it before it has landed. `nv_wr_active` is the other, and it only claims ch3
// while the FLASH half is being written -- in Pre-built mode there is no flash
// half and the derivation has the channel instead.
// derive_busy is here for the same reason: it owns ch3, which the running board
// also uses. It is a third of a second, once, at load.
// copy_reset is the OSD's Sample Flash option being moved to Cart copy: the
// stamp is blanked and the board restarted, because boot is the only moment the
// game looks at it. See the block around `blank_start` below.
wire reset = RESET | status[0] | buttons[1] | (dl_download & (dl_index == 8'd0))
           | nv_hold | derive_busy | copy_reset | ~pll_locked;

///////////////////////////  DIP SWITCHES  ///////////////////////

// MiSTer sends the MRA's <switches> block as ioctl index 254. Only one of these
// bits is a real hardware DIP: SW1:1, flip screen, which the GAME reads out of
// INPUTS bit 15 and acts on itself. The service switch is a panel pushbutton on
// the real cabinet (PORT_SERVICE_NO_TOGGLE), exposed here as a DIP as well
// because most MiSTer setups have nowhere else to put it.
reg [7:0] dsw[2];
always @(posedge clk_sys) begin
	if (ioctl_wr && (ioctl_index == 8'd254) && ~|ioctl_addr[24:1]) dsw[ioctl_addr[0]] <= ioctl_dout;
end

// MRA config (ioctl index 1). Byte 0 is the mod byte; bit 0 of it selects the
// SXX2C cartridge board: a different ROM part table, the Z80 program arriving
// over port 0x688 instead of from a ROM, and the second FIFO. The HPS sends
// this before the index-0 ROM image, so it is stable by the time the loader
// walks its table -- but it is latched on clk_sys and read by the loader on
// clk_ram, so it crosses as a static value that is settled long before
// rom_ready.
//
// Everything after byte 0 is a list of {part index, codec id} PAIRS, which is
// how an MRA says "decode this part on the way in" without the RTL having to
// know which set is loading. Codec ids are in rtl/spi_defs.vh; 0 is a straight
// copy, so an MRA that sends only the mod byte behaves exactly as before.
//
//     <rom index="1">
//       <part>01</part>          <!-- mod byte: SXX2C                     -->
//       <part>0E 01</part>       <!-- part 14 uses CODEC_BPE_DPCM         -->
//     </rom>
//
// A part index above 15 is ignored, so 'FF' works as a terminator for anyone
// who wants one. Writing byte 0 clears the whole codec table, so a stale
// assignment cannot survive into the next MRA.
//
// FIXED OFFSETS FROM 16 UP carry the sample-flash derivation's per-set
// constants (rtl/spi_flash_derive.sv). They are here rather than in an RTL
// table keyed by set_id for one reason: a CLONE has its own job-table address,
// because its program differs -- senkyu 0x00302324 against batlball 0x00302290
// -- so a table would make every clone an RTL change, which is the whole thing
// the single-MRA plan is trying to stop.
//
//     16..19  job_table, little endian, a 386 address
//     20..23  stamp,     little endian, a 386 address
//     24      generation: 0 = A, 1 = B0, 2 = B1
//
// Offsets rather than opcodes because the pair machine above is a strict
// two-byte alternation and a variable-length opcode does not fit it. Fifteen
// bytes is seven codec pairs and no set uses more than one.
//
// An MRA that stops before byte 16 leaves job_table zero, which
// spi_flash_derive rejects -- so an old MRA cannot accidentally derive.
reg  [7:0] mod_byte   = 8'd0;
reg [127:0] part_codec = 128'd0;
reg  [7:0] cfg_part   = 8'hFF;
reg [31:0] cfg_job_table = 32'd0;
reg [31:0] cfg_stamp     = 32'd0;
reg  [1:0] cfg_gen       = 2'd0;
always @(posedge clk_sys) begin
	if (ioctl_wr && (ioctl_index == 8'd1)) begin
		if (~|ioctl_addr[25:0]) begin
			mod_byte      <= ioctl_dout;
			part_codec    <= 128'd0;
			cfg_part      <= 8'hFF;
			cfg_job_table <= 32'd0;
			cfg_stamp     <= 32'd0;
			cfg_gen       <= 2'd0;
		end
		else if (ioctl_addr[25:5] == 21'd0) begin
			case (ioctl_addr[4:0])
			5'd16: cfg_job_table[7:0]   <= ioctl_dout;
			5'd17: cfg_job_table[15:8]  <= ioctl_dout;
			5'd18: cfg_job_table[23:16] <= ioctl_dout;
			5'd19: cfg_job_table[31:24] <= ioctl_dout;
			5'd20: cfg_stamp[7:0]       <= ioctl_dout;
			5'd21: cfg_stamp[15:8]      <= ioctl_dout;
			5'd22: cfg_stamp[23:16]     <= ioctl_dout;
			5'd23: cfg_stamp[31:24]     <= ioctl_dout;
			5'd24: cfg_gen              <= ioctl_dout[1:0];
			default:
				// Below 16 the stream is still {part index, codec} pairs.
				if (ioctl_addr[0]) cfg_part <= ioctl_dout;
				else if (cfg_part < 8'd32)
					part_codec[{cfg_part[4:0], 2'b00} +: 4] <= ioctl_dout[3:0];
			endcase
		end
	end
end

// Mod byte bit 0 is the SXX2C cartridge board; bits 3:1 pick the SET within
// that board, so an MRA that sends only bit 0 still selects the board's first
// set and nothing that already works has to change. Ids are in
// rtl/spi_defs.vh: 0 rdfts, 1 rdft, 2 rdft2, 3 rfjet.
//
// An unknown variant falls back to rdft rather than to the highest id: a wrong
// part table is a garbage download either way, but rdft is the board's own
// first set and the one whose table an unrecognised cartridge MRA is likeliest
// to have meant.
// The set ids and the SDRAM map, so the decode below and the derivation above
// name them rather than repeating their values in a comment. This file used the
// numbers with the symbol in a trailing comment, which is one edit away from
// being wrong -- and the derivation needs SDR_PCMSRC_* anyway, which cannot be
// written as a literal without repeating spi_defs.vh's arithmetic.
`include "spi_defs.vh"

// RE-REGISTERED ONTO clk_ram before anything on that clock reads them.
//
// These are captured on clk_sys and are STATIC from the moment the MRA's index-1
// element lands, long before rom_ready -- but "static" does not make the ROUTE
// short, and the route is what failed: `mod_byte[0] -> rom_loader|part_size_r`
// at -0.175 ns and `cfg_job_table[21] -> sdram|ch3_watch_r` at -0.108, on the
// clock with no margin. A register hop costs one clk_ram cycle of a value that
// settles seconds early, and it is the same fix 10a(2) applied to the loader's
// part table for the same reason.
//
// ONLY the clk_ram consumers use these. The clk_sys ones -- hps_io's menumask,
// and everything spi_top hands to spi_sound -- keep reading `mod_byte` itself.
// Moving them all was tried and was much worse: set_sxx2c feeds spi_sound's
// mono/stereo mux, so sourcing it from clk_ram put a cross-domain path into
// ymf271_synth's accumulator and general[1] closed at -2.906 with TNS -409.
// A static signal with consumers in two domains wants a copy in each, not a
// move.
// The OSD's Sample Flash option: 0 = Pre-built (the default), 1 = Cart copy.
// What it selects is documented where the derivation is instantiated below.
wire       cart_copy     = status[22];

reg  [7:0] mod_byte_r    = 8'd0;
reg [31:0] cfg_job_r     = 32'd0;
reg [31:0] cfg_stamp_r   = 32'd0;
reg  [1:0] cfg_gen_r     = 2'd0;
reg        cart_copy_s   = 1'b0;
reg        cart_copy_r   = 1'b0;
always @(posedge clk_ram) begin
	mod_byte_r  <= mod_byte;
	cfg_job_r   <= cfg_job_table;
	cfg_stamp_r <= cfg_stamp;
	cfg_gen_r   <= cfg_gen;
	// Not static, this one: the OSD moves it while the board is running, and its
	// EDGE is what triggers a re-blank. Two flops, because it is a real crossing
	// rather than a settled value.
	cart_copy_s <= cart_copy;
	cart_copy_r <= cart_copy_s;
end

wire       set_sxx2c   = mod_byte[0];
wire [2:0] set_variant = mod_byte[3:1];
reg  [2:0] set_id;
always @* begin
	if (!set_sxx2c)        set_id = SET_RDFTS;
	else case (set_variant)
		3'd1:              set_id = SET_RDFT2;
		3'd2:              set_id = SET_RFJET;
		3'd3:              set_id = SET_VIPRP1;
		3'd4:              set_id = SET_SENKYU;
		3'd5:              set_id = SET_EJANHS;
		default:           set_id = SET_RDFT;
	endcase
end

// Bit 4: the authentic-flash variant of whichever cartridge set bits 3:1 named
// -- a blank flash plus the cartridge's own sound ROMs, with the game running
// its own updater (PLAN.md section 17). ANDed with bit 0 rather than taken
// alone: on SXX2E it would open a source window with nothing behind it, and an
// MRA that sets it there has made a mistake worth ignoring rather than obeying.
wire set_upd = mod_byte[0] & mod_byte[4];

wire flip_screen_dip  = dsw[0][0];
wire service_mode_dip = dsw[0][1];

///////////////////////////  SDRAM  //////////////////////////////

// ch1 386 program ROM. The channel returns a 64-bit group and spi_cpu picks the
// dword it wants out of it -- declaring this 32 bits wide silently truncated the
// controller's output and zero-extended it back, so every odd dword the 386
// fetched read as zero and half the instruction stream was blank.
wire [25:0] sdr_prg_addr;
wire [63:0] sdr_prg_dout;
wire        sdr_prg_req, sdr_prg_ack;

// ch2 tile / char graphics (64 bit)
wire [25:0] sdr_gfx_addr;
wire [63:0] sdr_gfx_dout;
wire        sdr_gfx_req, sdr_gfx_ack;

// ch3 shared: ROM download, then Z80 program fetch (16 bit rw)
wire [25:0] sdr_rw_addr;
wire [63:0] sdr_rw_dout;
wire [15:0] sdr_rw_din;
wire  [1:0] sdr_rw_be;
wire        sdr_rw_req, sdr_rw_ack, sdr_rw_rnw;

wire [25:0] sdr_z80_addr;
wire        sdr_z80_req, sdr_z80_ack;

// ch4 sprite graphics (64 bit)
wire [25:0] sdr_spr_addr;
wire [63:0] sdr_spr_dout;
wire        sdr_spr_req, sdr_spr_ack;

// ch5 YMF271 PCM samples (64 bit)
wire [25:0] sdr_pcm_addr;
wire [63:0] sdr_pcm_dout;
wire        sdr_pcm_req, sdr_pcm_ack;

wire        sdr_refresh;

// USE_CH5 was 0 while nothing read PCM samples; the YMF271 does now.
sdram #(.USE_CH5(1)) sdram
(
	// The watch (PLAN.md 19.12), left unconnected: its counters have no fanout
	// now, so synthesis drops them. That matters more here than anywhere else
	// -- clk_ram's worst path is inside this module.
	.dbg_s_takes (),  .dbg_s_writes(),  .dbg_s_same  (),
	.dbg_s_wbank (),  .dbg_s_wchip (),
	.dbg_s_e0_dq (),  .dbg_s_e0_dqm(),  .dbg_s_e0_gap(),
	.dbg_s_e0_ab (),  .dbg_s_e0_ac (),  .dbg_s_e0_after(),
	.dbg_s_e1_dq (),  .dbg_s_e1_dqm(),  .dbg_s_e1_gap(),
	.dbg_s_e1_ab (),  .dbg_s_e1_ac (),  .dbg_s_e1_after(),
	.init      (~pll_locked),
	.clk       (clk_ram),
	.doRefresh (sdr_refresh),

	.SDRAM_DQ, .SDRAM_A, .SDRAM_DQML, .SDRAM_DQMH, .SDRAM_BA,
	.SDRAM_nCS, .SDRAM_nWE, .SDRAM_nRAS, .SDRAM_nCAS, .SDRAM_CKE, .SDRAM_CLK,

	.ch1_addr({1'b0, sdr_prg_addr}), .ch1_dout(sdr_prg_dout),
	.ch1_req (sdr_prg_req),  .ch1_ack (sdr_prg_ack),

	.ch2_addr({1'b0, sdr_gfx_addr}), .ch2_dout(sdr_gfx_dout),
	.ch2_req (sdr_gfx_req),  .ch2_ack (sdr_gfx_ack),

	.ch3_addr({1'b0, sdr_rw_addr}),  .ch3_dout(sdr_rw_dout),
	.ch3_din (sdr_rw_din),   .ch3_be  (sdr_rw_be),
	.ch3_req (sdr_rw_req),   .ch3_rnw (sdr_rw_rnw), .ch3_ack(sdr_rw_ack),

	.ch4_addr({1'b0, sdr_spr_addr}), .ch4_dout(sdr_spr_dout),
	.ch4_req (sdr_spr_req),  .ch4_ack (sdr_spr_ack),

	.ch5_addr({1'b0, ch5_addr}), .ch5_dout(ch5_dout),
	.ch5_req (ch5_req),      .ch5_ack (ch5_ack)
);

// The SDRAM traffic meter (spi_sdr_stats) used to tap the handshakes here and
// feed the JTAG probe. It went with the rest of the instrumentation; the module
// is still in rtl/. PLAN.md 29.

/////////////////////////  ROM LOADER  ///////////////////////////

wire        rom_ready;

wire [25:0] ldr_addr;
// ---------------------------------------------------------------------------
// PAUSE, on a bound button of its own
// ---------------------------------------------------------------------------
// Only spi_cpu's cpu_en is gated, so the video engines keep running and the
// frozen frame stays on screen rather than going black.
//
// It is joystick bit 11, the eighth name in the MRA's <buttons> list, and NOT
// button 3: four of the seven sets are MAME's spi_3button and use that as a game
// button. It used to be button 3 behind an OSD switch, which is a worse deal
// twice over -- pausing needed a trip through the menu first, and on those four
// sets the same press was also a game input.
//
// Two earlier shapes of this, both worse: it fired on ANY button of either pad,
// which made the game unplayable the moment anyone pressed shot; and the switch
// that replaced that was once shared with the vital signs panel, which REPLACED
// the picture with a telemetry screen and so could not show a frozen frame at all.
//
// The music keeps playing, deliberately-untouched rather than deliberately-kept:
// the Z80 and the YMF271 are on clk_sys and nothing here gates them. The 386
// stops feeding the sound FIFO, so what carries on is whatever the Z80's current
// loop plays.
// ---------------------------------------------------------------------------
wire pause_btn = joystick_p1[11] | joystick_p2[11];
reg  pause_btn_d, freeze_tgl;
always @(posedge clk_sys) begin
	pause_btn_d <= pause_btn;
	if (pause_btn && !pause_btn_d) freeze_tgl <= ~freeze_tgl;
	// A reset always resumes: coming up paused would look like a dead core, and
	// the OSD's own Reset is in `reset` too.
	if (reset) freeze_tgl <= 1'b0;
end

// The JTAG source register used to OR into this; with spi_jtag_peek out of the
// net the button is the only way to pause.
wire freeze = freeze_tgl;

wire [15:0] ldr_din;
wire  [1:0] ldr_be;
wire        ldr_req, ldr_rnw;

// Turns a fast (DDR3) download back into the byte stream rom_loader expects,
// and is a pass-through for a slow one. On clk_sys: that is the ioctl and
// DDRAM domain, and its strobe has to be one clk_sys cycle wide because the
// loader runs on clk_ram at 2x and edge-detects it.
ddr_rom_reader ddr_rom_reader
(
	.clk            (clk_sys),
	.reset          (RESET | ~pll_locked),

	.ioctl_download (ioctl_download),
	.ioctl_index    (ioctl_index),
	.ioctl_addr     (ioctl_addr),
	.ioctl_wr       (ioctl_wr),
	.ioctl_dout     (ioctl_dout),
	.ioctl_wait     (rdr_wait),

	.dl_download    (dl_download),
	.dl_wr          (dl_wr),
	.dl_dout        (dl_dout),
	.dl_index       (dl_index),
	.dl_wait        (dl_wait),

	.ddr_active     (ddr_rom_active),
	.ddr_addr       (ddr_rom_addr),
	.ddr_rd         (ddr_rom_rd),
	.ddr_dout       (DDRAM_DOUT),
	.ddr_dout_ready (DDRAM_DOUT_READY),
	.ddr_busy       (DDRAM_BUSY)
);

rom_loader rom_loader
(
	.clk            (clk_ram),
	.reset          (RESET | ~pll_locked),

	.ioctl_download (dl_download),
	.ioctl_wr       (dl_wr),
	.ioctl_index    (dl_index),
	.ioctl_dout     (dl_dout),
	.ioctl_wait     (ldr_wait),
	.set_id         (set_id),
	.set_upd        (set_upd),
	.part_codec     (part_codec),

	.sdr_addr       (ldr_addr),
	.sdr_din        (ldr_din),
	.sdr_be         (ldr_be),
	.sdr_req        (ldr_req),
	.sdr_rnw        (ldr_rnw),
	.sdr_ack        (sdr_rw_ack),

	.rom_ready      (rom_ready),

	// The byte counters and the part-end marker were read over JTAG; nothing
	// consumes them now.
	.bytes_in       (),
	.bytes_out      (),
	.part_end       ()
);

// Channel 3 belongs to the loader while downloading, and to the board after
// that.
//
// The spi_romcheck walker and the spi_jtag_peek host-read port used to sit
// between those two, and both are out of the net now (PLAN.md 29). What went
// with them:
//
//   * the four region checksums and the `ok` bits, which were only ever read
//     by the panel and over JTAG;
//   * `chk_done` as the board's release gate -- `rom_ready & derive_done` is
//     that gate now, and the sequence is rom_ready -> derive -> board;
//   * one of the four masters on the ch3 arbiter, whose b port is tied off
//     below.
//
// The two of them also carried a reset each for the nvram load and the
// derivation (21.3): both were ch3 masters outside the board's reset domain,
// so a walk or a peek in flight took the writer's acks. Neither exists to be
// confused now.

// Loader owns channel 3 during the download; after that the board's masters
// share it through an arbiter.
wire [25:0] arb_addr;
wire        arb_req, arb_ack;
wire [25:0] z80dl_sdr_addr;
wire [15:0] z80dl_sdr_din;
wire  [1:0] z80dl_sdr_be;
wire        z80dl_sdr_req, z80dl_sdr_ack;
wire [25:0] flash_sdr_addr;
wire [15:0] flash_sdr_din;
wire  [1:0] flash_sdr_be;
wire        flash_sdr_req, flash_sdr_ack;
wire [63:0] sdr_z80_dout;

// Three masters on ch3 once the download is done: the Z80 fetch, the 386
// writing the Z80's program into RAM on SXX2C, and the sample flash
// programming ITSELF on an authentic-flash MRA. The b port was the JTAG
// peek's and is tied off; the arbiter keeps four so nothing else has to move.
// The flash writes the SAMPLE region, which ch5 reads. It is on this channel
// because ch3 is the only one sdram.sv gives a write path, not because the
// address has anything to do with the Z80.
wire [15:0] arb_din;
wire  [1:0] arb_be;
wire        arb_rnw;

spi_sdr_arb4 ch3_arb
(
	.clk    (clk_ram),
	.a_addr (sdr_z80_addr), .a_req (sdr_z80_req), .a_ack (sdr_z80_ack),
	.b_addr (26'd0),        .b_req (1'b0),        .b_ack (),
	.c_addr (z80dl_sdr_addr), .c_din (z80dl_sdr_din), .c_be (z80dl_sdr_be),
	.c_req  (z80dl_sdr_req),  .c_ack (z80dl_sdr_ack),
	.d_addr (flash_sdr_addr), .d_din (flash_sdr_din), .d_be (flash_sdr_be),
	.d_req  (flash_sdr_req),  .d_ack (flash_sdr_ack),
	.m_addr (arb_addr),     .m_req (arb_req),     .m_ack (arb_ack),
	.m_din  (arb_din),      .m_be  (arb_be),      .m_rnw (arb_rnw),
	.m_dout (sdr_rw_dout),
	.a_dout (sdr_z80_dout), .b_dout (),
	// The d-port write watch (PLAN.md 19.13): no fanout, so it is dropped.
	.dbg_d_watch_n    (),
	.dbg_d_watch_be   (),
	.dbg_d_watch_data (),
	.dbg_d_total      ()
);

// ---------------------------------------------------------------------------
// The sample-flash derivation (rtl/spi_flash_derive.sv)
// ---------------------------------------------------------------------------
// Pre-built mode: instead of the game spending six minutes programming its own
// flash through the 386/FIFO/Z80/wave port, the core builds the same image out
// of SDRAM in about 0.3 s. Same job table, same sources, same bytes -- PLAN.md
// 24 has the seven hashes.
//
// It runs BETWEEN the download and the ROM check, so the sequence is
//
//     rom_ready -> derive -> board runs
//
// and every other ch3 master is provably idle for its window: the loader has
// finished (rom_ready), and the board is held in reset below. That is what
// makes the priority mux safe here rather than a repeat of 21.3 -- the claim
// "nothing else is asking" is ENFORCED, which is exactly what it was not when
// the nvram load made the same claim.
//
// Requires an authentic-flash MRA: the sources it reads are the ROMs only that
// MRA carries. On anything else derive_en is low and nothing changes.
// Where the loader put the PCM source for this set -- the same per-set base
// spi_top picks for spi_cpu, and it has to be the same one or the derivation
// reads sprite data as samples (spi_defs.vh SDR_PCMSRC_*).
reg [25:0] pcmsrc_base;
always @* case (set_id)
	SET_RDFT2: pcmsrc_base = SDR_PCMSRC_RDFT2;
	SET_RFJET: pcmsrc_base = SDR_PCMSRC_RFJET;
	default:   pcmsrc_base = SDR_PCMSRC_SEI252;
endcase

// BOTH MODES DERIVE, which is the change PLAN.md 32 is about. The payload is two
// megabytes the save file no longer stores, so it has to be rebuilt at every boot
// either way, and what `cart_copy` actually selects is whether the region STAMP is
// written with it:
//
//   Pre-built   payload + stamp. The game finds a programmed flash and plays.
//   Cart copy   payload only. The game finds the blank stamp its MRA loaded, or
//               the one the save file restored if the copy has been done before,
//               and runs its own six-minute updater over a payload that is
//               already correct.
//
// It is a fake and it is meant to be: what persists across boots is the fact of
// the copy, four bytes of it, not its two megabytes.
//
// Computed from the clk_ram copies of the config, because that is the domain the
// derivation, the nvram gate and ch3 all live in. JP1 used to need a clk_sys twin
// of this; it follows `cart_copy` now, which is already a clk_sys signal.
wire derive_en = mod_byte_r[0] & mod_byte_r[4] & (|cfg_job_r);

wire [25:0] drv_addr;
wire [15:0] drv_din;
wire  [1:0] drv_be;
wire        drv_req, drv_rnw, drv_done, drv_overrun, drv_badjob;

// The stamp goes with the payload in Pre-built and is left alone in Cart copy.
wire stamp_en = ~cart_copy_r;

// ---------------------------------------------------------------------------
// Switching INTO Cart copy un-programs the flash and restarts the board
// ---------------------------------------------------------------------------
// Without this the mode is a trap, and it was one: boot Pre-built, open the OSD,
// and Main takes a save whose stamp says the flash is programmed -- after which
// selecting Cart copy could never show the copy again, because the game skips its
// updater on a stamp that matches. So the CHANGE into Cart copy is an action, not
// just a setting: blank the stamp and reset the board, which is what the game
// tests at boot and the only moment it tests it.
//
// The blank write is `start_blank` on the derivation -- four bytes rather than the
// walk's third of a second -- and it reuses the walk's own write path, so nothing
// new touches ch3. While it runs, drv_done is low, which puts derive_busy up and
// holds the board down exactly as the boot derivation does.
//
// Coming back the other way does NOTHING, deliberately: Pre-built writes the real
// stamp at the next boot anyway, so there is nothing to undo.
// The window is a COUNTER and not a wait on the derivation's `done`, on purpose.
// The blank write is four SDRAM writes and a couple of reads -- a few hundred
// cycles against this 131,072 -- and a counter cannot fail to expire. Waiting on
// `done` could: if it never arrived, the reset would stay asserted and the board
// would be held down forever, which is the shape of the wedge PLAN.md's
// MiSTer_cmd note is about. The board is independently held while `drv_done` is
// low anyway, through derive_busy, so nothing is lost by bounding this.
reg        blank_start, blank_armed;
reg [16:0] blank_cnt;
reg        cart_copy_d;
// The reset the toggle asserts: ~1.1 ms at clk_ram, so the 386 sees a proper
// reset and not a few microseconds of one.
wire       copy_reset = |blank_cnt;

reg  derive_started;
wire derive_busy = derive_en & derive_started & ~drv_done & ~drv_overrun & ~drv_badjob;
always @(posedge clk_ram) begin
	if (RESET | ~pll_locked | ~rom_ready) derive_started <= 1'b0;
	else if (rom_ready)                   derive_started <= 1'b1;
end

always @(posedge clk_ram) begin
	blank_start <= 1'b0;
	if (RESET | ~pll_locked | ~rom_ready) begin
		// Take the option's value without acting on it: a saved .CFG that comes
		// up in Cart copy must not read as a change.
		cart_copy_d <= cart_copy_r;
		blank_armed <= 1'b0;
		blank_cnt   <= 17'd0;
	end
	else begin
		// Only watch the option once the boot derivation is out of the way.
		if (derive_done) blank_armed <= 1'b1;

		// `derive_en` because the blank write goes through the derivation, and on
		// a set that has none -- SXX2E, whose samples are a ROM -- there would be
		// nothing to answer and the option is hidden from the OSD anyway.
		if (blank_armed && derive_en && (cart_copy_r != cart_copy_d)) begin
			cart_copy_d <= cart_copy_r;
			if (cart_copy_r) begin          // ...into Cart copy, and only that way
				blank_start <= 1'b1;
				blank_cnt   <= '1;
			end
		end
		else if (!blank_armed || !derive_en) cart_copy_d <= cart_copy_r;

		if (|blank_cnt) blank_cnt <= blank_cnt - 17'd1;
	end
end
// Done means "the board may start": either it finished, or it failed, or it
// was never going to run. A failure leaves the flash blank, which is safe --
// the stamp is written last, so the game just runs its own updater.
//
// This is what spi_top's rom_ready is gated on, where it used to be gated on
// the ROM checker's `chk_done`. `derive_busy` in `wire reset` above is NOT
// enough on its own: it is qualified by `derive_started`, which is a register,
// so it rises one clk_ram cycle after rom_ready and leaves the board out of
// reset for that cycle. derive_done is low from the moment rom_ready is high,
// with no such hole.
wire derive_done = ~derive_en | drv_done | drv_overrun | drv_badjob;

spi_flash_derive derive
(
	.clk          (clk_ram),
	.reset        (RESET | ~pll_locked | ~derive_en),
	.start        (derive_en & rom_ready & ~derive_started),
	.stamp_en     (stamp_en),
	.start_blank  (blank_start),

	.job_table    (cfg_job_r),
	.stamp_addr   (cfg_stamp_r),
	.gen          (cfg_gen_r),

	.snd01_en     ((set_id == SET_RDFT2) || (set_id == SET_RFJET)
	               || (set_id == SET_SENKYU) || (set_id == SET_EJANHS)
	               || (set_id == SET_RDFT)),
	.pcmsrc_en    (1'b1),
	.pcmsrc_1lane ((set_id == SET_VIPRP1) || (set_id == SET_SENKYU)
	               || (set_id == SET_EJANHS)),
	.pcmsrc_base  (pcmsrc_base),

	.sdr_addr     (drv_addr),
	.sdr_din      (drv_din),
	.sdr_be       (drv_be),
	.sdr_rnw      (drv_rnw),
	.sdr_req      (drv_req),
	.sdr_ack      (sdr_rw_ack),
	.sdr_dout     (sdr_rw_dout),

	.done         (drv_done),
	.bytes_out    (),
	.jobs_done    (),
	.err_overrun  (drv_overrun),
	.err_badjob   (drv_badjob),
	.dbg_state    (), .dbg_esi (), .dbg_src (),
	.dbg_len      (), .dbg_mode(), .dbg_dec ()
);

// ch3's owners in order of life: the ROM loader, the derivation, then the
// board's arbiter -- and, cutting in front of all of them, the nvram
// load. That one arrives AFTER the image (Main sends <nvram> in file order) so
// it cannot use the loader's slot. Every arm here holds every other master in
// reset for its window; see the note above, and 21.3 for what happens when one
// of them only CLAIMS to.
assign arb_ack     = sdr_rw_ack;
assign sdr_rw_addr = nv_wr_active ? nv_wr_addr
                   : derive_busy  ? drv_addr
                   : rom_ready    ? arb_addr : ldr_addr;
assign sdr_rw_din  = nv_wr_active ? nv_wr_din
                   : derive_busy  ? drv_din
                   : rom_ready    ? arb_din  : ldr_din;
assign sdr_rw_be   = nv_wr_active ? nv_wr_be
                   : derive_busy  ? drv_be
                   : rom_ready    ? arb_be   : ldr_be;
assign sdr_rw_req  = nv_wr_active ? nv_wr_req
                   : derive_busy  ? drv_req
                   : rom_ready    ? arb_req  : ldr_req;
assign sdr_rw_rnw  = nv_wr_active ? 1'b0
                   : derive_busy  ? drv_rnw
                   : rom_ready    ? arb_rnw  : ldr_rnw;

// ch5 has two readers once there is a save file: the YMF271's sample fetch and
// spi_nvram reading the region back. The YMF wins ties -- it is feeding a
// running voice, while the save is paced by the HPS a byte at a time.
wire [25:0] ch5_addr;
wire [63:0] ch5_dout;
wire        ch5_req, ch5_ack;

spi_sdr_arb2 ch5_arb
(
	.clk    (clk_ram),
	.a_addr (sdr_pcm_addr), .a_req (sdr_pcm_req), .a_ack (sdr_pcm_ack),
	.b_addr (nv_rd_addr),   .b_req (nv_rd_req),   .b_ack (nv_rd_ack),
	.m_addr (ch5_addr),     .m_req (ch5_req),     .m_ack (ch5_ack),
	.m_dout (ch5_dout),
	.a_dout (sdr_pcm_dout), .b_dout (nv_rd_dout)
);

wire        flash_dirty;
wire [25:0] nv_wr_addr, nv_rd_addr;
wire [15:0] nv_wr_din;
wire  [1:0] nv_wr_be;
wire        nv_wr_req, nv_wr_active, nv_hold, nv_rd_req, nv_rd_ack;

// The DS2404's SRAM, between spi_nvram here and the chip inside spi_top. Both
// are on clk_ram, which is the whole reason the chip is not with the rest of the
// I/O on clk_cpu -- see spi_ds2404.sv.
wire  [8:0] ds_nv_addr;
wire  [7:0] ds_nv_din, ds_nv_dout;
wire        ds_nv_we, ds_nv_dirty;
wire [63:0] nv_rd_dout;

spi_nvram nvram
(
	.clk        (clk_ram),
	.reset      (RESET | ~pll_locked),
	// Every set the core runs has a DS2404 to remember, so there is always a
	// file. What varies is its SHAPE, and that is an MRA property rather than an
	// OSD one -- the size in the <nvram> element is fixed before the menu is
	// reachable, so it cannot depend on which way Sample Flash is set.
	.enable     (1'b1),
	// A cartridge set: the flash's four stamp bytes ahead of the DS2404's
	// 512-byte tail. On SXX2E the samples are a real ROM and the file is the tail
	// alone.
	.has_flash  (mod_byte_r[0] & mod_byte_r[4]),
	// ...and the STORED stamp is the one to use. Only in Cart copy: Pre-built
	// writes the real one from the program image a moment later, so restoring a
	// copy could only be the same bytes or a stale set.
	.flash_live (mod_byte_r[0] & mod_byte_r[4] & cart_copy_r),

	// Raw ioctl, not the replayed copy -- see the header of spi_nvram.sv.
	.ioctl_download (ioctl_download),
	.ioctl_wr       (ioctl_wr),
	.ioctl_index    (ioctl_index),
	.ioctl_dout     (ioctl_dout),
	.ioctl_wait     (nv_dl_wait),
	// "The ROM IMAGE is still landing", which is NOT the same as "a download is
	// in progress": ddr_rom_reader passes ioctl_download through for every
	// index, so `dl_download` alone is high during the nvram's own transfer and
	// the hold below could never release. It deadlocked Main solid -- ssh alive,
	// screenshots gone, nvram in = 0. The index term is what makes it mean the
	// image; during the DDR3 replay dl_index is forced to 0, which is exactly
	// the window this exists to cover.
	.rom_busy       (dl_download & (dl_index == 8'd0)),
	.ioctl_upload       (ioctl_upload),
	.ioctl_rd           (ioctl_rd),
	.ioctl_din          (ioctl_din),
	.ioctl_upload_req   (ioctl_upload_req),
	.ioctl_upload_index (ioctl_upload_index),

	.flash_dirty (flash_dirty),
	.sram_dirty  (ds_nv_dirty),

	.sram_addr  (ds_nv_addr),
	.sram_din   (ds_nv_din),
	.sram_we    (ds_nv_we),
	.sram_dout  (ds_nv_dout),

	.wr_addr    (nv_wr_addr),
	.wr_din     (nv_wr_din),
	.wr_be      (nv_wr_be),
	.wr_req     (nv_wr_req),
	.wr_ack     (sdr_rw_ack),
	.wr_active  (nv_wr_active),
	.hold       (nv_hold),

	.rd_addr    (nv_rd_addr),
	.rd_req     (nv_rd_req),
	.rd_ack     (nv_rd_ack),
	.rd_dout    (nv_rd_dout),

	.dbg_saves  (),
	.dbg_beats  (),
	.dbg_bytes  ()
);

// Refresh aggressively while the board is idle; the controller also has its own
// emergency refresh, which is what covers the download.
assign sdr_refresh = ~rom_ready;

///////////////////////////  INPUTS  /////////////////////////////

// Keyboard, for the buttons a pad usually has nowhere sensible to put.
reg key_1 = 0, key_2 = 0, key_5 = 0, key_6 = 0, key_9 = 0, key_f2 = 0;
always @(posedge clk_sys) begin
	reg old_state;
	old_state <= ps2_key[10];
	if (old_state != ps2_key[10]) begin
		case (ps2_key[7:0])
			8'h16: key_1  <= ps2_key[9];   // start 1
			8'h1E: key_2  <= ps2_key[9];   // start 2
			8'h2E: key_5  <= ps2_key[9];   // coin 1
			8'h36: key_6  <= ps2_key[9];   // coin 2
			8'h46: key_9  <= ps2_key[9];   // service coin
			8'h06: key_f2 <= ps2_key[9];   // service mode
			default: ;
		endcase
	end
end

// Joystick bit assignment. Bits 4 and up are the MRA's <buttons names="..."/>
// list in order, so this and the MRAs have to be changed together -- the
// hand-written ones in mra/ and the list in tools/gen_mras.py that generates
// the rest:
//
//   [3:0] right, left, down, up
//   [4]   Shot        [5] Bomb        [6] Button 3
//   [7]   Start       [8] Coin        [9] Service Coin   [10] Test
//   [11]  Pause -- not a board input at all, see the block above
//
// This used to read [7] as coin and [8] as start, which did not line up with
// the MRA at all -- the MRA named eight entries with two placeholders in the
// middle, putting Start on bit 9 and Coin on bit 10. Coin and start were
// therefore mapped to buttons nobody could press.
wire m_start1 = joystick_p1[7] | key_1;
wire m_start2 = joystick_p2[7] | key_2;
wire m_coin1  = joystick_p1[8] | key_5;
wire m_coin2  = joystick_p2[8] | key_6;
wire m_svc    = joystick_p1[9] | joystick_p2[9] | key_9;
wire m_test   = joystick_p1[10] | joystick_p2[10] | key_f2 | service_mode_dip;

// The button half of INPUTS is active low on hardware, so it is inverted here.
// Bit 15 is NOT: it is a DIPSWITCH field in MAME, which does not take the
// port's IP_ACTIVE_LOW inversion, and its Off state is the bit CLEAR.
// INPUTS: P1 u/d/l/r b1/b2/b3, P2 u/d/l/r b1/b2/b3, bit15 = flip screen dip.
wire [14:0] spi_buttons = ~{
	joystick_p2[6], joystick_p2[5], joystick_p2[4],          // P2 b3 b2 b1
	joystick_p2[0], joystick_p2[1], joystick_p2[2], joystick_p2[3], // P2 r l d u
	1'b0,
	joystick_p1[6], joystick_p1[5], joystick_p1[4],          // P1 b3 b2 b1
	joystick_p1[0], joystick_p1[1], joystick_p1[2], joystick_p1[3]  // P1 r l d u
};
wire [15:0] spi_inputs = {flip_screen_dip, spi_buttons};

// SYSTEM: b0 start1, b1 start2, b2 service mode, b3 service coin.
wire [7:0] spi_system = ~{
	4'b0000,
	m_svc,
	m_test,
	m_start2,
	m_start1
};

// COIN is read by the Z80 at 0x4013; the Z80 latches it into 0x680 for the 386.
wire [7:0] spi_coin = ~{6'b000000, m_coin2, m_coin1};

////////////////////////////  BOARD  /////////////////////////////

wire        ce_pix;
wire  [7:0] core_r, core_g, core_b;
wire        core_hs, core_vs, core_hb, core_vb;
wire [15:0] audio_l, audio_r;

spi_top spi_top
(
	.clk_sys      (clk_sys),
	.clk_cpu      (clk_cpu),
	.clk_ram      (clk_ram),
	.reset        (reset),
	.rom_ready    (rom_ready & derive_done),

	.set_sxx2c      (set_sxx2c),
	.set_id         (set_id),
	.set_upd        (set_upd),
	// JP1, SXX2C only. MAME's sxx2c port: bits [1:0] = 0x3 "Update", 0x0
	// "Normal"; bits [7:2] are unused IP_ACTIVE_LOW and read as 1. So 0xFF is
	// update mode and 0xFC is normal.
	//
	// THE AUTHENTIC MRAS NEED UPDATE MODE, and that is measured, not assumed.
	// The updater erases its first block pair and then sits in this loop, read
	// off the running hardware at Z80 0x18F5 (PLAN.md 18.3):
	//
	//     LD A,(0x400A) / AND 0x03 / CP 0x03 / JP NZ,0x18F5
	//
	// With 0xFC it spins there forever, with the music still playing. Section
	// 10b blamed an earlier deadlock on this port being all-ones; that was the
	// 0x4009 d0 bug, and the note it left behind ("update mode is not
	// reachable") was wrong.
	//
	// Leaving it in update mode does NOT make a programmed cartridge reflash:
	// the game skips the updater on a matching stamp whatever the jumper says,
	// which is what section 0 measured under MAME's own default of Update.
	// JP1. Pre-built mode sends the not-update position: the matching stamp
	// already makes the game skip its updater (18.5), and this says so twice.
	.jumpers        ((set_upd & cart_copy) ? 8'hFF : 8'hFC),
	.flash_dirty    (flash_dirty),

	// The DS2404's SRAM, which spi_nvram carries as the tail of the save file.
	.ds_nv_addr     (ds_nv_addr),
	.ds_nv_din      (ds_nv_din),
	.ds_nv_we       (ds_nv_we),
	.ds_nv_dout     (ds_nv_dout),
	.ds_nv_dirty    (ds_nv_dirty),

	.flash_sdr_addr (flash_sdr_addr),
	.flash_sdr_din  (flash_sdr_din),
	.flash_sdr_be   (flash_sdr_be),
	.flash_sdr_req  (flash_sdr_req),
	.flash_sdr_ack  (flash_sdr_ack),

	.z80dl_sdr_addr (z80dl_sdr_addr),
	.z80dl_sdr_din  (z80dl_sdr_din),
	.z80dl_sdr_be   (z80dl_sdr_be),
	.z80dl_sdr_req  (z80dl_sdr_req),
	.z80dl_sdr_ack  (z80dl_sdr_ack),

	.freeze       (freeze),

	.ss_save        (ss_save),
	.ss_load        (ss_load),
	.ss_busy        (),
	.ss_stream_write(ss_stream_write),
	.ss_stream_read (ss_stream_read),
	.ss_stream_busy (ss_stream_busy),
	.ssbus          (ssbus),
	// Probes, for sim/tb_boot_top. Pruned here.
	.ss_in_stub        (),
	.ss_snapshot       (),
	.ss_esp_out        (),
	.ss_writes         (),
	.ss_last_wa        (),
	.ss_last_wd        (),
	.ss_dbg_state      (),
	.ss_dbg_nmi        (),
	.ss_dbg_gate_dw0   (),
	.ss_dbg_gate_reads (),
	.ss_dbg_hold       (),
	.ss_dbg_stalls     (),
	.p_cpu_irq         (),
	.p_ds_rtc          (),
	.p_ds_tick         (),
	.p_io_rd           (),
	.p_io_raddr        (),
	.p_io_rdata        (),
	.ss_dbg_stub_reads (),
	.ss_dbg_stub_idx   (),
	.ss_dbg_stub_data  (),
	.ss_dbg_resume_eip (),
	.ss_dbg_esp_scratch(),
	.ss_dbg_ss_base    (),
	.ss_dbg_ss_limit   (),
	.ss_dbg_ss_type    (),
	.ss_dbg_ss_g       (),

	.sdr_prg_addr (sdr_prg_addr),
	.sdr_prg_dout (sdr_prg_dout),
	.sdr_prg_req  (sdr_prg_req),
	.sdr_prg_ack  (sdr_prg_ack),

	.sdr_gfx_addr (sdr_gfx_addr),
	.sdr_gfx_dout (sdr_gfx_dout),
	.sdr_gfx_req  (sdr_gfx_req),
	.sdr_gfx_ack  (sdr_gfx_ack),

	.sdr_spr_addr (sdr_spr_addr),
	.sdr_spr_dout (sdr_spr_dout),
	.sdr_spr_req  (sdr_spr_req),
	.sdr_spr_ack  (sdr_spr_ack),

	.sdr_z80_addr (sdr_z80_addr),
	.sdr_z80_dout (sdr_z80_dout),
	.sdr_z80_req  (sdr_z80_req),
	.sdr_z80_ack  (sdr_z80_ack),

	.sdr_pcm_addr (sdr_pcm_addr),
	.sdr_pcm_dout (sdr_pcm_dout),
	.sdr_pcm_req  (sdr_pcm_req),
	.sdr_pcm_ack  (sdr_pcm_ack),

	.inputs       (spi_inputs),
	.system       (spi_system),
	.coin         (spi_coin),

	.ce_pix       (ce_pix),
	.red          (core_r),
	.green        (core_g),
	.blue         (core_b),
	.hsync        (core_hs),
	.vsync        (core_vs),
	.hblank       (core_hb),
	.vblank       (core_vb),

	.audio_l      (audio_l),
	.audio_r      (audio_r)
);

assign AUDIO_L = audio_l;
assign AUDIO_R = audio_r;

////////////////////////////  VIDEO  /////////////////////////////

// Raiden Fighters is ROT270, so the default rotation is counter-clockwise.
wire no_rotate  = ~orientation_vert | direct_video;
wire rotate_ccw = ~rotate_cw;

assign CLK_VIDEO = clk_sys;

wire [7:0] rgb_out_r, rgb_out_g, rgb_out_b;
wire       vga_de_mixer;

arcade_video #(.WIDTH(320), .DW(24)) arcade_video
(
	.clk_video (clk_sys),
	.ce_pix    (ce_pix),

	.RGB_in    ({core_r, core_g, core_b}),
	.HBlank    (core_hb),
	.VBlank    (core_vb),
	.HSync     (core_hs),
	.VSync     (core_vs),

	.CLK_VIDEO (),
	.CE_PIXEL  (CE_PIXEL),
	.VGA_R     (rgb_out_r),
	.VGA_G     (rgb_out_g),
	.VGA_B     (rgb_out_b),
	.VGA_HS    (VGA_HS),
	.VGA_VS    (VGA_VS),
	.VGA_DE    (vga_de_mixer),
	.VGA_SL    (VGA_SL),

	.fx                 (scandoubler_fx),
	.forced_scandoubler (forced_scandoubler),
	.gamma_bus          (gamma_bus)
);

assign VGA_R = rgb_out_r;
assign VGA_G = rgb_out_g;
assign VGA_B = rgb_out_b;

video_freak video_freak
(
	.CLK_VIDEO  (CLK_VIDEO),
	.CE_PIXEL   (CE_PIXEL),
	.VGA_VS     (VGA_VS),
	.HDMI_WIDTH (HDMI_WIDTH),
	.HDMI_HEIGHT(HDMI_HEIGHT),
	.VGA_DE     (VGA_DE),
	.VIDEO_ARX  (VIDEO_ARX),
	.VIDEO_ARY  (VIDEO_ARY),

	.VGA_DE_IN  (vga_de_mixer),
	.ARX        ((!ar) ? (no_rotate ? 13'd4 : 13'd3) : {1'b0, ar} - 13'd1),
	.ARY        ((!ar) ? (no_rotate ? 13'd3 : 13'd4) : 13'd0),
	.CROP_SIZE  (12'd0),
	.CROP_OFF   (5'd0),
	.SCALE      (scale)
);

screen_rotate screen_rotate
(
	.CLK_VIDEO (CLK_VIDEO),
	.CE_PIXEL  (CE_PIXEL),

	.VGA_R     (VGA_R),
	.VGA_G     (VGA_G),
	.VGA_B     (VGA_B),
	.VGA_HS    (VGA_HS),
	.VGA_VS    (VGA_VS),
	.VGA_DE    (vga_de_mixer),

	.rotate_ccw    (rotate_ccw),
	.no_rotate     (no_rotate),
	.flip          (1'b0),
	.video_rotated (video_rotated),

	.FB_EN     (FB_EN),
	.FB_FORMAT (FB_FORMAT),
	.FB_WIDTH  (FB_WIDTH),
	.FB_HEIGHT (FB_HEIGHT),
	.FB_BASE   (FB_BASE),
	.FB_STRIDE (FB_STRIDE),
	.FB_VBL    (FB_VBL),
	.FB_LL     (FB_LL),

	// DDRAM is shared with the ROM reader now, so screen_rotate drives wires
	// and the mux below decides who reaches the pins.
	//
	// The 1'b0 is not a shortcut and feeding it a real busy would change
	// NOTHING: screen_rotate takes DDRAM_BUSY as an input and never reads it
	// (sys/arcade_video.v -- the only assignment is `DDRAM_WE = ram_wr`). It
	// has no back-pressure to offer, so a preempted write is dropped rather
	// than stalled whatever this is wired to. Checked while chasing the
	// savestate video glitch (PLAN.md 42); the glitch was the raster, not this.
	.DDRAM_CLK      (),
	.DDRAM_BUSY     (1'b0),
	.DDRAM_BURSTCNT (rot_burstcnt),
	.DDRAM_ADDR     (rot_addr),
	.DDRAM_DIN      (rot_din),
	.DDRAM_BE       (rot_be),
	.DDRAM_WE       (rot_we),
	.DDRAM_RD       (rot_rd)
);

// ---------------------------------------------------------------------------
// DDRAM: the framebuffer writer, and the ROM reader while a fast download is
// replaying.
//
// The ROM reader wins outright for the duration, and screen_rotate's writes are
// DROPPED rather than queued. That is deliberate and it is the cheap option:
// screen_rotate ignores DDRAM_BUSY entirely -- it is declared and never read --
// so it cannot be stalled, and giving it back-pressure means putting a FIFO in
// front of it. There is nothing worth queueing here: the core is held in reset
// for the whole replay, so the frames being dropped are blank ones, and the
// display refills within a frame of the load finishing. A core that used DDRAM
// for anything load-bearing during the load would need the FIFO.
//
// ---------------------------------------------------------------------------
// Save states
//
// The OSD and keyboard side is Robert Peip's savestate_ui, unmodified; the
// blob's format and its trip to DDR3 are Arcade-IGSPGM's memory_stream; the
// sequencing and the 386's own part are ours (rtl/spi_ss.sv, PLAN.md 38).
//
// `allow_ss` is gated on the ROM being loaded and the board being out of reset.
// Saving during the download would snapshot a machine that does not exist yet,
// and restoring into one would be worse.
// ---------------------------------------------------------------------------
wire        ss_save, ss_load;
wire  [1:0] ss_slot;
wire        ss_status_set;
wire        ss_info_req;
wire  [7:0] ss_info;

savestate_ui #(.INFO_TIMEOUT_BITS(25)) savestate_ui
(
	.clk           (clk_sys),
	.ps2_key       (ps2_key[10:0]),
	.allow_ss      (rom_ready && !reset),
	.joySS         (joystick_p1[7] | joystick_p2[7]),   // Start
	.joyRight      (joystick_p1[0] | joystick_p2[0]),
	.joyLeft       (joystick_p1[1] | joystick_p2[1]),
	.joyDown       (joystick_p1[2] | joystick_p2[2]),
	.joyUp         (joystick_p1[3] | joystick_p2[3]),
	.joyStart      (1'b0),
	.joyRewind     (1'b0),
	.rewindEnable  (1'b0),
	.status_slot   (status[42:41]),
	.autoincslot   (status[40]),
	.OSD_saveload  (status[44:43]),
	.ss_save       (ss_save),
	.ss_load       (ss_load),
	.ss_info_req   (ss_info_req),
	.ss_info       (ss_info),
	.statusUpdate  (ss_status_set),
	.selected_slot (ss_slot)
);

ssbus_if ssbus();
ddr_if   ss_ddr();

wire ss_stream_write, ss_stream_read, ss_stream_busy;

save_state_data ss_data
(
	.clk         (clk_sys),
	.reset       (reset),
	.ddr         (ss_ddr),
	.read_start  (ss_stream_read),
	.write_start (ss_stream_write),
	.index       (ss_slot),
	.busy        (ss_stream_busy),
	.ssbus       (ssbus)
);

// DDRAM_CLK is driven here instead of by screen_rotate, which used to assign it
// CLK_VIDEO. Same signal -- CLK_VIDEO is clk_sys -- but now it is stated once
// where both masters can be seen.
// ---------------------------------------------------------------------------
wire        ddr_rom_active;
wire [28:0] ddr_rom_addr;
wire        ddr_rom_rd;

wire  [7:0] rot_burstcnt;
wire [28:0] rot_addr;
wire [63:0] rot_din;
wire  [7:0] rot_be;
wire        rot_we, rot_rd;

// Three masters now, in priority order.
//
// ddr_rom_active wins outright and always has: it is the fast download, the
// board is in reset behind it, and rotate's writes are dropped for its duration
// (the note above says why that is free).
//
// The savestate comes next, and it preempts screen_rotate for the few
// milliseconds a transfer takes. That drops some framebuffer writes, so the
// rotated display tears for one frame -- which is the same trade the download
// already makes, and a save state is a deliberate act the player is expecting a
// hitch from. It is NOT allowed to preempt the download, because during one
// there is nothing worth saving.
//
// `ss_ddr.acquire` is memory_stream's own request line and it is deliberately
// narrow: that module drops it in its gather and query states, which wait on the
// ssbus rather than on DDR3, so rotate gets the bus back between accesses
// instead of being locked out for the whole transfer.
wire ss_ddr_active = ss_ddr.acquire && !ddr_rom_active;

assign DDRAM_CLK      = clk_sys;
assign DDRAM_BURSTCNT = ddr_rom_active ? 8'd1         :
                        ss_ddr_active  ? ss_ddr.burstcnt   : rot_burstcnt;
assign DDRAM_ADDR     = ddr_rom_active ? ddr_rom_addr :
                        ss_ddr_active  ? ss_ddr.addr[31:3] : rot_addr;
assign DDRAM_DIN      = ddr_rom_active ? 64'd0        :
                        ss_ddr_active  ? ss_ddr.wdata      : rot_din;
assign DDRAM_BE       = ddr_rom_active ? 8'hFF        :
                        ss_ddr_active  ? ss_ddr.byteenable : rot_be;
assign DDRAM_WE       = ddr_rom_active ? 1'b0         :
                        ss_ddr_active  ? ss_ddr.write      : rot_we;
assign DDRAM_RD       = ddr_rom_active ? ddr_rom_rd   :
                        ss_ddr_active  ? ss_ddr.read       : rot_rd;

// memory_stream's side of it. `busy` has to read as busy whenever it does not
// hold the bus, or it would issue into a mux that is pointing somewhere else.
assign ss_ddr.rdata       = DDRAM_DOUT;
assign ss_ddr.rdata_ready = ss_ddr_active && DDRAM_DOUT_READY;
assign ss_ddr.busy        = !ss_ddr_active || DDRAM_BUSY;

assign FB_FORCE_BLANK = 0;

endmodule
