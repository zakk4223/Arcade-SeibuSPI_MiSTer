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
assign LED_USER  = ioctl_download;

//////////////////////////////////////////////////////////////////

wire [1:0] ar              = status[2:1];
wire [2:0] scandoubler_fx  = status[5:3];
wire [1:0] scale           = status[7:6];
wire       orientation_vert = ~status[10];   // default 0 => vertical
wire       rotate_cw       = status[11];
wire       flip_screen_opt = status[12];

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
	"P1O[12],Flip Screen,Off,On;",
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
wire [24:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire  [7:0] ioctl_index;
wire        ioctl_wait;

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

	.joystick_0(joystick_p1),
	.joystick_1(joystick_p2),

	.ps2_key(ps2_key)
);

///////////////////////   CLOCKS   ///////////////////////////////

wire clk_sys;   //  57.272727 MHz - video, I/O, sound
wire clk_cpu;   //  28.636364 MHz - the 386
wire clk_ram;   // 114.545455 MHz - SDRAM
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

wire reset = RESET | status[0] | buttons[1] | ioctl_download | ~pll_locked;

///////////////////////////  SDRAM  //////////////////////////////

// ch1 386 program ROM (32 bit)
wire [24:0] sdr_prg_addr;
wire [31:0] sdr_prg_dout;
wire        sdr_prg_req, sdr_prg_ack;

// ch2 tile / char graphics (64 bit)
wire [24:0] sdr_gfx_addr;
wire [63:0] sdr_gfx_dout;
wire        sdr_gfx_req, sdr_gfx_ack;

// ch3 shared: ROM download, then Z80 program fetch (16 bit rw)
wire [24:0] sdr_rw_addr;
wire [63:0] sdr_rw_dout;
wire [15:0] sdr_rw_din;
wire  [1:0] sdr_rw_be;
wire        sdr_rw_req, sdr_rw_ack, sdr_rw_rnw;

// ch4 sprite graphics (64 bit)
wire [24:0] sdr_spr_addr;
wire [63:0] sdr_spr_dout;
wire        sdr_spr_req, sdr_spr_ack;

// ch5 YMF271 PCM samples (64 bit)
wire [24:0] sdr_pcm_addr;
wire [63:0] sdr_pcm_dout;
wire        sdr_pcm_req, sdr_pcm_ack;

wire        sdr_refresh;

sdram sdram
(
	.init      (~pll_locked),
	.clk       (clk_ram),
	.doRefresh (sdr_refresh),

	.SDRAM_DQ, .SDRAM_A, .SDRAM_DQML, .SDRAM_DQMH, .SDRAM_BA,
	.SDRAM_nCS, .SDRAM_nWE, .SDRAM_nRAS, .SDRAM_nCAS, .SDRAM_CKE, .SDRAM_CLK,

	.ch1_addr(sdr_prg_addr), .ch1_dout(sdr_prg_dout),
	.ch1_req (sdr_prg_req),  .ch1_ack (sdr_prg_ack),

	.ch2_addr(sdr_gfx_addr), .ch2_dout(sdr_gfx_dout),
	.ch2_req (sdr_gfx_req),  .ch2_ack (sdr_gfx_ack),

	.ch3_addr(sdr_rw_addr),  .ch3_dout(sdr_rw_dout),
	.ch3_din (sdr_rw_din),   .ch3_be  (sdr_rw_be),
	.ch3_req (sdr_rw_req),   .ch3_rnw (sdr_rw_rnw), .ch3_ack(sdr_rw_ack),

	.ch4_addr(sdr_spr_addr), .ch4_dout(sdr_spr_dout),
	.ch4_req (sdr_spr_req),  .ch4_ack (sdr_spr_ack),

	.ch5_addr(sdr_pcm_addr), .ch5_dout(sdr_pcm_dout),
	.ch5_req (sdr_pcm_req),  .ch5_ack (sdr_pcm_ack)
);

/////////////////////////  ROM LOADER  ///////////////////////////

wire        rom_ready;

wire [24:0] ldr_addr;
wire [15:0] ldr_din;
wire  [1:0] ldr_be;
wire        ldr_req, ldr_rnw;

rom_loader rom_loader
(
	.clk            (clk_ram),
	.reset          (RESET | ~pll_locked),

	.ioctl_download (ioctl_download),
	.ioctl_wr       (ioctl_wr),
	.ioctl_index    (ioctl_index),
	.ioctl_dout     (ioctl_dout),
	.ioctl_wait     (ioctl_wait),

	.sdr_addr       (ldr_addr),
	.sdr_din        (ldr_din),
	.sdr_be         (ldr_be),
	.sdr_req        (ldr_req),
	.sdr_rnw        (ldr_rnw),
	.sdr_ack        (sdr_rw_ack),

	.rom_ready      (rom_ready)
);

// Channel 3 belongs to the loader while downloading and to the board after.
// TODO(T5): drive the "after" side from the Z80 program fetcher.
assign sdr_rw_addr = ldr_addr;
assign sdr_rw_din  = ldr_din;
assign sdr_rw_be   = ldr_be;
assign sdr_rw_req  = ldr_req;
assign sdr_rw_rnw  = ldr_rnw;

// Refresh aggressively while the board is idle; the controller also has its own
// emergency refresh, which is what covers the download.
assign sdr_refresh = ~rom_ready;

///////////////////////////  INPUTS  /////////////////////////////

// Both ports are active low on hardware.
// INPUTS: P1 u/d/l/r b1/b2/b3, P2 u/d/l/r b1/b2/b3, bit15 = flip screen dip.
wire [15:0] spi_inputs = ~{
	flip_screen_opt,
	joystick_p2[6], joystick_p2[5], joystick_p2[4],          // P2 b3 b2 b1
	joystick_p2[0], joystick_p2[1], joystick_p2[2], joystick_p2[3], // P2 r l d u
	1'b0,
	joystick_p1[6], joystick_p1[5], joystick_p1[4],          // P1 b3 b2 b1
	joystick_p1[0], joystick_p1[1], joystick_p1[2], joystick_p1[3]  // P1 r l d u
};

// SYSTEM: start1, start2, service mode, service coin.
wire [7:0] spi_system = ~{
	4'b0000,
	1'b0,                 // service dip handled through the DIP menu
	joystick_p1[9] | joystick_p2[9],   // service coin
	joystick_p2[8],       // start 2
	joystick_p1[8]        // start 1
};

// COIN is read by the Z80.
wire [7:0] spi_coin = ~{6'b000000, joystick_p2[7], joystick_p1[7]};

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
	.rom_ready    (rom_ready),

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

	.DDRAM_CLK      (DDRAM_CLK),
	.DDRAM_BUSY     (DDRAM_BUSY),
	.DDRAM_BURSTCNT (DDRAM_BURSTCNT),
	.DDRAM_ADDR     (DDRAM_ADDR),
	.DDRAM_DIN      (DDRAM_DIN),
	.DDRAM_BE       (DDRAM_BE),
	.DDRAM_WE       (DDRAM_WE),
	.DDRAM_RD       (DDRAM_RD)
);

assign FB_FORCE_BLANK = 0;

endmodule
