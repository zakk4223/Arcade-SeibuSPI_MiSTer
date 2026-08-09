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
wire clk_ram;   //  96.923077 MHz - SDRAM controller
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
wire reset = RESET | status[0] | buttons[1] | (ioctl_download & (ioctl_index == 8'd0)) | ~pll_locked;

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

// MRA mod byte (ioctl index 1). Bit 0 selects the SXX2C cartridge board: a
// different ROM part table, the Z80 program arriving over port 0x688 instead
// of from a ROM, and the second FIFO. The HPS sends this before the index-0
// ROM image, so it is stable by the time the loader walks its table -- but it
// is latched on clk_sys and read by the loader on clk_ram, so it crosses as a
// static value that is settled long before rom_ready.
reg [7:0] mod_byte = 8'd0;
always @(posedge clk_sys) begin
	if (ioctl_wr && (ioctl_index == 8'd1) && ~|ioctl_addr[24:0]) mod_byte <= ioctl_dout;
end

wire set_sxx2c = mod_byte[0];

wire flip_screen_dip  = dsw[0][0];
wire service_mode_dip = dsw[0][1];

///////////////////////////  SDRAM  //////////////////////////////

// ch1 386 program ROM. The channel returns a 64-bit group and spi_cpu picks the
// dword it wants out of it -- declaring this 32 bits wide silently truncated the
// controller's output and zero-extended it back, so every odd dword the 386
// fetched read as zero and half the instruction stream was blank.
wire [24:0] sdr_prg_addr;
wire [63:0] sdr_prg_dout;
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

wire [24:0] sdr_z80_addr;
wire        sdr_z80_req, sdr_z80_ack;

// ch4 sprite graphics (64 bit)
wire [24:0] sdr_spr_addr;
wire [63:0] sdr_spr_dout;
wire        sdr_spr_req, sdr_spr_ack;

// ch5 YMF271 PCM samples (64 bit)
wire [24:0] sdr_pcm_addr;
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
wire [24:0] ldr_bytes;
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
wire  [3:0] ldr_part_end;
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
	.set_sxx2c      (set_sxx2c),

	.sdr_addr       (ldr_addr),
	.sdr_din        (ldr_din),
	.sdr_be         (ldr_be),
	.sdr_req        (ldr_req),
	.sdr_rnw        (ldr_rnw),
	.sdr_ack        (sdr_rw_ack),

	.rom_ready      (rom_ready),
	.bytes_in       (ldr_bytes),
	.part_end       (ldr_part_end)
);

// Channel 3 belongs to the loader while downloading, then to the ROM checker,
// and to the board after that.
// TODO(T5): drive the "after" side from the Z80 program fetcher.
wire [24:0] chk_addr, peek_addr;
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
	.ctrl(dbg_ctrl)
);

// Loader owns channel 3 during the download, the checker until it is done,
// and after that the Z80 and the JTAG peek share it through an arbiter. The
// Z80 is served first: it stalls a running CPU, while the peek is a human.
wire [24:0] arb_addr;
wire        arb_req, arb_ack;
wire [63:0] sdr_z80_dout, peek_dout;

spi_sdr_arb2 ch3_arb
(
	.clk    (clk_ram),
	.a_addr (sdr_z80_addr), .a_req (sdr_z80_req), .a_ack (sdr_z80_ack),
	.b_addr (peek_addr),    .b_req (peek_req),    .b_ack (peek_ack),
	.m_addr (arb_addr),     .m_req (arb_req),     .m_ack (arb_ack),
	.m_dout (sdr_rw_dout),
	.a_dout (sdr_z80_dout), .b_dout (peek_dout)
);

assign arb_ack     = sdr_rw_ack;
assign sdr_rw_addr = chk_done  ? arb_addr
                   : rom_ready ? chk_addr : ldr_addr;
assign sdr_rw_din  = ldr_din;
assign sdr_rw_be   = ldr_be;
assign sdr_rw_req  = chk_done  ? arb_req
                   : rom_ready ? chk_req  : ldr_req;
assign sdr_rw_rnw  = rom_ready ? 1'b1     : ldr_rnw;

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
