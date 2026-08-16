//============================================================================
//  SlopperPI - Seibu SPI / SXX2E for MiSTer
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
	"SeibuSPI;;",
	"-;",
	"P1,Video Settings;",
	"P1O[2:1],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"P1O[5:3],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"P1O[7:6],Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer;",
	"P1-;",
	"P1O[10],Orientation,Vert,Horz;",
	"P1O[11],Rotation,CCW,CW;",
	"-;",
	"O[20],Vital Signs Panel,Off,On;",
	"O[21],Freeze Button (Btn 3),Off,On;",
	"-;",
	"DIP;",
	"-;",
	"T[0],Reset;",
	"R[0],Reset and close OSD;",
	"DEFMRA,/_Arcade/rdfts.mra;",
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
	.status_menumask({direct_video}),

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
// The nvram download writes the sample region through ch3, which the running
// board also uses, so the board is held down for it exactly as it is for the
// ROM image. It is two megabytes and arrives once, at load.
wire reset = RESET | status[0] | buttons[1] | (dl_download & (dl_index == 8'd0))
           | nv_wr_active | ~pll_locked;

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
reg  [7:0] mod_byte   = 8'd0;
reg [127:0] part_codec = 128'd0;
reg  [7:0] cfg_part   = 8'hFF;
always @(posedge clk_sys) begin
	if (ioctl_wr && (ioctl_index == 8'd1)) begin
		if (~|ioctl_addr[25:0]) begin
			mod_byte   <= ioctl_dout;
			part_codec <= 128'd0;
			cfg_part   <= 8'hFF;
		end
		else if (ioctl_addr[0]) cfg_part <= ioctl_dout;
		else if (cfg_part < 8'd32)
			part_codec[{cfg_part[4:0], 2'b00} +: 4] <= ioctl_dout[3:0];
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
wire       set_sxx2c   = mod_byte[0];
wire [2:0] set_variant = mod_byte[3:1];
reg  [1:0] set_id;
always @* begin
	if (!set_sxx2c)        set_id = 2'd0;    // SET_RDFTS
	else case (set_variant)
		3'd1:              set_id = 2'd2;    // SET_RDFT2
		3'd2:              set_id = 2'd3;    // SET_RFJET
		default:           set_id = 2'd1;    // SET_RDFT
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

// How busy that bus actually is. Taps the handshakes only -- nothing here
// touches sdram.sv, whose clk_ram paths PLAN.md 15.8 says to leave alone.
wire [94:0] sdr_trans;

spi_sdr_stats sdr_stats
(
	.clk   (clk_ram),
	.ack   ({sdr_pcm_ack, sdr_spr_ack, sdr_rw_ack, sdr_gfx_ack, sdr_prg_ack}),
	.trans (sdr_trans)
);

/////////////////////////  ROM LOADER  ///////////////////////////

wire        rom_ready;

wire [25:0] ldr_addr;
wire [25:0] ldr_bytes;
wire [25:0] ldr_bytes_out;
wire [15:0] v_prg, v_iowr, v_tm, v_pal, v_vbl;
wire  [3:0] v_why;
wire [31:0] v_eip;
wire [15:0] v_cs;
wire        v_irq;
wire [191:0] v_gdt;
wire   [7:0] dbg_ctrl;

// ---------------------------------------------------------------------------
// Freeze the CPU from a controller button -- a debugging aid, NOT a game
// control, so it is gated on the Vital Signs Panel option being on.
//
// Every attempt to catch a particular attract scene by timing a JTAG freeze
// went wrong: quartus_stp needs about five seconds just to claim the chain, and
// the ROM download shifts the whole attract sequence by seconds between runs.
// Several measurements taken that way landed on a completely different scene
// and were reported as faults that did not exist. A button is a zero-latency
// trigger that a human can aim by eye, which is the one thing this debugging
// actually needed.
//
// It used to fire on ANY button of either pad, which made the game
// unplayable the moment anyone pressed shot. It needs an option enabled, and
// only button 3 triggers it.
//
// The video engines keep running (only spi_cpu's cpu_en is gated), so a frozen
// frame stays on screen and can be instrumented over JTAG at leisure.
//
// This has its OWN option, separate from the Vital Signs Panel. It used to be
// gated on the panel option, which made it useless for the one job it exists
// for: spi_top drives the output as `panel ? dbg_r : mix_r`, so turning the
// panel on REPLACES the picture with the telemetry screen. Freezing a frame to
// look at a rendering fault meant enabling the very thing that hid the frame.
// The two are independent now -- freeze alone to study the picture, or both
// together to read the counters with the CPU stopped.
// ---------------------------------------------------------------------------
wire dbg_freeze_en = status[21];
wire any_btn   = dbg_freeze_en & (joystick_p1[6] | joystick_p2[6]);
reg  any_btn_d, freeze_tgl;
always @(posedge clk_sys) begin
	any_btn_d <= any_btn;
	if (any_btn && !any_btn_d) freeze_tgl <= ~freeze_tgl;
	if (!dbg_freeze_en) freeze_tgl <= 1'b0;
end

// The JTAG freeze bit and the button are ORed, so either can stop the core and
// tools/jtag_server.tcl still works exactly as before.
wire [7:0] dbg_mask_eff = {dbg_ctrl[7:6], dbg_ctrl[5] | freeze_tgl, dbg_ctrl[4:0]};
wire  [15:0] v_ovr;
wire   [1:0] v_ovrl;
wire   [5:0] v_tcol;
wire  [15:0] v_ss, v_sy, v_se;
wire   [4:0] v_len;
wire  [11:0] v_tdw;
wire  [15:0] v_sstv, v_stil;
wire  [15:0] v_dspr, v_nz;
wire  [31:0] v_sor;
wire         v_rs, v_fd13;
wire  [12:0] v_tmdw;
wire  [95:0] v_scr;
wire  [17:2] v_ssrc;
wire  [15:0] v_wspr, v_wtm;
wire [15:0] v_spc, v_sfr, v_syw, v_sst, v_yov, v_yac;
wire [15:0] v_f2w, v_f2r;
wire  [8:0] v_fpk;
wire [15:0] v_fmx;
wire [15:0] v_gap;
wire [15:0] v_wmx;
wire [31:0] v_seip;
wire [15:0] v_scs;
// EIP profiler: window down from the host, two free-running counters back up.
wire [31:0] v_plo, v_phi;
wire [39:0] v_pin, v_ptot;
wire  [4:0] ldr_part_end;
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
	.bytes_in       (ldr_bytes),
	// Wired now, for the reason this comment used to predict: rdft2 is the
	// first set with a decoded part to reach hardware, and bytes_in alone
	// cannot tell a stalled decoder from a working one.
	.bytes_out      (ldr_bytes_out),
	.part_end       (ldr_part_end)
);

// Channel 3 belongs to the loader while downloading, then to the ROM checker,
// and to the board after that.
// TODO(T5): drive the "after" side from the Z80 program fetcher.
wire [25:0] chk_addr, peek_addr;
wire        chk_req, chk_done, peek_req, peek_ack;
wire  [3:0] chk_ok;
wire [15:0] chk_passes, chk_fails;
wire [31:0] chk_sum_prg, chk_sum_chars, chk_sum_tiles, chk_sum_sprites;

spi_romcheck romcheck
(
	.clk      (clk_ram),
	.reset    (RESET | ~pll_locked),
	.start    (rom_ready),
	.sdr_addr (chk_addr),
	.sdr_dout (sdr_rw_dout),
	.sdr_req  (chk_req),
	.sdr_ack  (sdr_rw_ack),
	.done     (chk_done),
	.ok       (chk_ok),
	.passes   (chk_passes),
	.fails    (chk_fails),
	.sum_prg     (chk_sum_prg),
	.sum_chars   (chk_sum_chars),
	.sum_tiles   (chk_sum_tiles),
	.sum_sprites (chk_sum_sprites)
);

// Host-driven SDRAM reads over JTAG; see tools/jtag_peek.tcl.
spi_jtag_peek peek
(
	.clk      (clk_ram),
	.reset    (RESET | ~pll_locked),
	.enable   (chk_done),
	.sdr_addr (peek_addr),
	.sdr_dout (peek_dout),
	.sdr_req  (peek_req),
	.sdr_ack  (peek_ack),
	.sum_prg     (chk_sum_prg),
	.sum_chars   (chk_sum_chars),
	.sum_tiles   (chk_sum_tiles),
	.sum_sprites (chk_sum_sprites),
	.ok       (chk_ok),
	.passes   (chk_passes),
	.fails    (chk_fails),
	.bytes_in (ldr_bytes),
	.bytes_out(ldr_bytes_out),
	.part_end (ldr_part_end),
	.c_prg(v_prg), .c_iowr(v_iowr), .c_dma_tm(v_tm),
	.c_dma_pal(v_pal), .c_vbl(v_vbl), .why(v_why),
	.eip(v_eip), .cs(v_cs), .irq(v_irq), .gdt(v_gdt),
	.lay_ovr(v_ovr), .lay_ovr_layer(v_ovrl), .lay_text_col(v_tcol),
	.spr_scanned(v_ss), .spr_yhit(v_sy), .spr_emitted(v_se), .lay_en(v_len),
	.dma_text_dw(v_tdw), .spr_starved(v_sstv), .spr_tiles(v_stil),
	.c_dma_spr(v_dspr), .spr_codes_nz(v_nz), .spr_ram_or(v_sor), .dma_src_spr(v_ssrc),
	.cpu_wr_spr(v_wspr), .cpu_wr_tm(v_wtm),
	.frozen(dbg_mask_eff[5]),
	.rs_en(v_rs), .fd13(v_fd13), .tm_dwords(v_tmdw), .scrolls(v_scr),
	.snd_pc(v_spc), .snd_fifo_rd(v_sfr), .snd_ymf_wr(v_syw),
	.snd_stall(v_sst), .ymf_overrun(v_yov), .ymf_active(v_yac),
	.snd_f2_wr(v_f2w), .snd_f2_rd(v_f2r),
	.snd_fifo_peak(v_fpk), .snd_full_max(v_fmx), .spr_gap_max(v_gap), .snd_wait_max(v_wmx), .stall_eip(v_seip), .stall_cs(v_scs),
	.flash_progs(dbg_flash_progs), .flash_erases(dbg_flash_erases),
	.flash_drops(dbg_flash_drops), .flash_busy(dbg_flash_busy),
	.nv_bytes(dbg_nv_bytes), .nv_saves(dbg_nv_saves), .nv_beats(dbg_nv_beats),
	.sdr_trans(sdr_trans),
	.ctrl(dbg_ctrl),
	.prof_lo(v_plo), .prof_hi(v_phi), .prof_in(v_pin), .prof_total(v_ptot)
);

// Loader owns channel 3 during the download, the checker until it is done,
// and after that the Z80 and the JTAG peek share it through an arbiter. The
// Z80 is served first: it stalls a running CPU, while the peek is a human.
wire [25:0] arb_addr;
wire        arb_req, arb_ack;
wire [25:0] z80dl_sdr_addr;
wire [15:0] z80dl_sdr_din;
wire  [1:0] z80dl_sdr_be;
wire        z80dl_sdr_req, z80dl_sdr_ack;
wire [31:0] dbg_flash_progs;
wire [15:0] dbg_flash_erases, dbg_flash_drops;
wire  [1:0] dbg_flash_busy;
wire [25:0] flash_sdr_addr;
wire [15:0] flash_sdr_din;
wire  [1:0] flash_sdr_be;
wire        flash_sdr_req, flash_sdr_ack;
wire [63:0] sdr_z80_dout, peek_dout;

// Four masters on ch3 once the ROM check is done: the Z80 fetch, the JTAG
// peek, the 386 writing the Z80's program into RAM on SXX2C, and the sample
// flash programming ITSELF on an authentic-flash MRA. The arbiter serialises
// whole round trips, so the channel's toggle handshake is never handed to the
// wrong master. See rtl/spi_sdr_arb4.sv.
//
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
	.b_addr (peek_addr),    .b_req (peek_req),    .b_ack (peek_ack),
	.c_addr (z80dl_sdr_addr), .c_din (z80dl_sdr_din), .c_be (z80dl_sdr_be),
	.c_req  (z80dl_sdr_req),  .c_ack (z80dl_sdr_ack),
	.d_addr (flash_sdr_addr), .d_din (flash_sdr_din), .d_be (flash_sdr_be),
	.d_req  (flash_sdr_req),  .d_ack (flash_sdr_ack),
	.m_addr (arb_addr),     .m_req (arb_req),     .m_ack (arb_ack),
	.m_din  (arb_din),      .m_be  (arb_be),      .m_rnw (arb_rnw),
	.m_dout (sdr_rw_dout),
	.a_dout (sdr_z80_dout), .b_dout (peek_dout)
);

// ch3's owners in order of life: the ROM loader, the checker, then the board's
// arbiter -- and, cutting in front of all of them, the nvram load. That one
// arrives AFTER the image (Main sends <nvram> in file order) so it cannot use
// the loader's slot, and it holds the board in reset while it runs, so nothing
// else is asking.
assign arb_ack     = sdr_rw_ack;
assign sdr_rw_addr = nv_wr_active ? nv_wr_addr
                   : chk_done     ? arb_addr
                   : rom_ready    ? chk_addr : ldr_addr;
assign sdr_rw_din  = nv_wr_active ? nv_wr_din
                   : chk_done     ? arb_din  : ldr_din;
assign sdr_rw_be   = nv_wr_active ? nv_wr_be
                   : chk_done     ? arb_be   : ldr_be;
assign sdr_rw_req  = nv_wr_active ? nv_wr_req
                   : chk_done     ? arb_req
                   : rom_ready    ? chk_req  : ldr_req;
assign sdr_rw_rnw  = nv_wr_active ? 1'b0
                   : chk_done     ? arb_rnw
                   : rom_ready    ? 1'b1     : ldr_rnw;

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
wire        nv_wr_req, nv_wr_active, nv_rd_req, nv_rd_ack;
wire [63:0] nv_rd_dout;
wire [15:0] dbg_nv_saves, dbg_nv_beats;
wire [25:0] dbg_nv_bytes;

spi_nvram nvram
(
	.clk        (clk_ram),
	.reset      (RESET | ~pll_locked),
	.enable     (set_upd),

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

	.wr_addr    (nv_wr_addr),
	.wr_din     (nv_wr_din),
	.wr_be      (nv_wr_be),
	.wr_req     (nv_wr_req),
	.wr_ack     (sdr_rw_ack),
	.wr_active  (nv_wr_active),

	.rd_addr    (nv_rd_addr),
	.rd_req     (nv_rd_req),
	.rd_ack     (nv_rd_ack),
	.rd_dout    (nv_rd_dout),

	.dbg_saves  (dbg_nv_saves),
	.dbg_beats  (dbg_nv_beats),
	.dbg_bytes  (dbg_nv_bytes)
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
// list in order, so this and mra/rdfts.mra have to be changed together:
//
//   [3:0] right, left, down, up
//   [4]   Shot        [5] Bomb        [6] Button 3
//   [7]   Start       [8] Coin        [9] Service Coin   [10] Test
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
	.rom_ready    (rom_ready & chk_done),

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
	.jumpers        (set_upd ? 8'hFF : 8'hFC),
	.flash_dirty    (flash_dirty),
	.flash_sdr_addr (flash_sdr_addr),
	.flash_sdr_din  (flash_sdr_din),
	.flash_sdr_be   (flash_sdr_be),
	.flash_sdr_req  (flash_sdr_req),
	.flash_sdr_ack  (flash_sdr_ack),
	.dbg_flash_progs  (dbg_flash_progs),
	.dbg_flash_erases (dbg_flash_erases),
	.dbg_flash_drops  (dbg_flash_drops),
	.dbg_flash_busy   (dbg_flash_busy),

	.z80dl_sdr_addr (z80dl_sdr_addr),
	.z80dl_sdr_din  (z80dl_sdr_din),
	.z80dl_sdr_be   (z80dl_sdr_be),
	.z80dl_sdr_req  (z80dl_sdr_req),
	.z80dl_sdr_ack  (z80dl_sdr_ack),

	.dbg_en       (status[20]),
	.chk_ok       (chk_ok),
	.chk_done     (chk_done),
	.dbg_mask     (dbg_mask_eff),
	.c_prg(v_prg), .c_iowr(v_iowr), .c_dma_tm(v_tm),
	.c_dma_pal(v_pal), .c_vbl(v_vbl), .why(v_why),
	.eip(v_eip), .cs(v_cs), .irq(v_irq), .gdt(v_gdt),
	.lay_ovr(v_ovr), .lay_ovr_layer(v_ovrl), .lay_text_col(v_tcol),
	.spr_scanned(v_ss), .spr_yhit(v_sy), .spr_emitted(v_se), .lay_en_out(v_len),
	.c_dma_spr(v_dspr), .spr_codes_nz(v_nz), .spr_ram_or(v_sor), .dma_src_spr(v_ssrc),
	.cpu_wr_spr(v_wspr), .cpu_wr_tm(v_wtm),
	.dma_text_dw(v_tdw), .spr_starved(v_sstv), .spr_tiles(v_stil),
	.rs_out(v_rs), .fd13_out(v_fd13), .tm_dwords_out(v_tmdw), .scroll_out(v_scr),
	.snd_pc(v_spc), .snd_fifo_rd(v_sfr), .snd_ymf_wr(v_syw),
	.snd_stall(v_sst), .ymf_overrun(v_yov), .ymf_active(v_yac),
	.snd_f2_wr(v_f2w), .snd_f2_rd(v_f2r),
	.snd_fifo_peak(v_fpk), .snd_full_max(v_fmx), .spr_gap_max(v_gap), .snd_wait_max(v_wmx), .stall_eip(v_seip), .stall_cs(v_scs),
	.prof_lo(v_plo), .prof_hi(v_phi), .prof_in(v_pin), .prof_total(v_ptot),

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

assign DDRAM_CLK      = clk_sys;
assign DDRAM_BURSTCNT = ddr_rom_active ? 8'd1        : rot_burstcnt;
assign DDRAM_ADDR     = ddr_rom_active ? ddr_rom_addr : rot_addr;
assign DDRAM_DIN      = ddr_rom_active ? 64'd0       : rot_din;
assign DDRAM_BE       = ddr_rom_active ? 8'hFF       : rot_be;
assign DDRAM_WE       = ddr_rom_active ? 1'b0        : rot_we;
assign DDRAM_RD       = ddr_rom_active ? ddr_rom_rd  : rot_rd;

assign FB_FORCE_BLANK = 0;

endmodule
