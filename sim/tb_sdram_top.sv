//============================================================================
//  SeibuSPI - ROM download round-trip through the real SDRAM controller
//
//  rom_loader -> rtl/sdram.sv -> sim/sdram_model.sv, then read every byte back
//  out through channel 1 and compare against the reference image.
//
//  Every other testbench here pre-loads a perfect SDRAM image and fakes
//  rom_ready, so the download path -- which is what actually runs on hardware
//  before the 386 executes a single instruction -- has never been simulated.
//============================================================================

module tb_sdram_top
(
	input             clk,
	input             init,

	// ioctl feed
	input             ioctl_download,
	input             ioctl_wr,
	input       [7:0] ioctl_dout,
	output            ioctl_wait,
	output            rom_ready,

	// verification read port (channel 1)
	input      [24:0] rd_addr,
	input             rd_req,
	output     [63:0] rd_dout,
	output            rd_ack,

	output     [31:0] n_act,
	output     [31:0] n_rd,
	output     [31:0] n_wr,
	output     [31:0] n_clk
);

	wire [15:0] SDRAM_DQ;
	wire [12:0] SDRAM_A;
	wire  [1:0] SDRAM_BA;
	wire        SDRAM_DQML, SDRAM_DQMH;
	wire        SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS, SDRAM_CKE;
	/* verilator lint_off UNUSEDSIGNAL */
	wire        SDRAM_CLK;   // the chip model is clocked from clk instead
	/* verilator lint_on UNUSEDSIGNAL */

	// 26 bits: the core's map outgrew 32 MB (PLAN.md section 4). This was 25
	// and silently stopped this bench elaborating at all.
	wire [25:0] ldr_addr;
	wire [15:0] ldr_din;
	wire  [1:0] ldr_be;
	wire        ldr_req, ldr_rnw, ldr_ack;

	rom_loader loader
	(
		.clk            (clk),
		.reset          (init),
		.ioctl_download (ioctl_download),
		.ioctl_wr       (ioctl_wr),
		.ioctl_index    (8'd0),
		.ioctl_dout     (ioctl_dout),
		.ioctl_wait     (ioctl_wait),
		.set_id         (3'd0),
	// Grew on rom_loader when the authentic-flash variants landed; 0 is the
	// pre-flashed tail, which is what this testbench streams.
	.set_upd        (1'b0),      // this bench drives the rdfts layout
		.part_codec     (128'd0),    // every part a straight copy
		.sdr_addr       (ldr_addr),
		.sdr_din        (ldr_din),
		.sdr_be         (ldr_be),
		.sdr_req        (ldr_req),
		.sdr_rnw        (ldr_rnw),
		.sdr_ack        (ldr_ack),
		.rom_ready      (rom_ready),
		// Telemetry outputs this bench does not look at. They were added to
		// rom_loader long after tb_sdram_top was written and never wired, which
		// left run-sdram failing to elaborate.
		.bytes_in       (),
		.bytes_out      (),
		.part_end       ()
	);

	sdram sdram
	(
		.init       (init),
		.clk        (clk),
		.doRefresh  (~rom_ready),
		// The 0x29FE write watch (PLAN.md 19.12), added to sdram.sv while the
		// rdft2 save byte was being chased. All outputs, all unconnected here:
		// this testbench streams the whole ROM image through and compares every
		// byte, which is a stronger statement than any one watched address --
		// but -Wall makes an unconnected pin an ERROR, so leaving them off is
		// what stopped this testbench BUILDING, and with it the only check that
		// would catch sdram.sv corrupting data.
		.dbg_s_takes    (), .dbg_s_writes   (), .dbg_s_same     (),
		.dbg_s_wbank    (), .dbg_s_wchip    (),
		.dbg_s_e0_dq    (), .dbg_s_e0_dqm   (), .dbg_s_e0_gap   (),
		.dbg_s_e0_ab    (), .dbg_s_e0_ac    (), .dbg_s_e0_after (),
		.dbg_s_e1_dq    (), .dbg_s_e1_dqm   (), .dbg_s_e1_gap   (),
		.dbg_s_e1_ab    (), .dbg_s_e1_ac    (), .dbg_s_e1_after (),

		.SDRAM_DQ   (SDRAM_DQ),
		.SDRAM_A    (SDRAM_A),
		.SDRAM_DQML (SDRAM_DQML),
		.SDRAM_DQMH (SDRAM_DQMH),
		.SDRAM_BA   (SDRAM_BA),
		.SDRAM_nCS  (SDRAM_nCS),
		.SDRAM_nWE  (SDRAM_nWE),
		.SDRAM_nRAS (SDRAM_nRAS),
		.SDRAM_nCAS (SDRAM_nCAS),
		.SDRAM_CKE  (SDRAM_CKE),
		.SDRAM_CLK  (SDRAM_CLK),

		.ch1_addr   ({2'b00, rd_addr}),
		.ch1_dout   (rd_dout),
		.ch1_req    (rd_req),
		.ch1_ack    (rd_ack),

		.ch2_addr   (27'd0),
		.ch2_dout   (),
		.ch2_req    (1'b0),
		.ch2_ack    (),

		.ch3_addr   ({1'b0, ldr_addr}),
		.ch3_dout   (),
		.ch3_din    (ldr_din),
		.ch3_be     (ldr_be),
		.ch3_req    (ldr_req),
		.ch3_rnw    (ldr_rnw),
		.ch3_ack    (ldr_ack),

		.ch4_addr   (27'd0),
		.ch4_dout   (),
		.ch4_req    (1'b0),
		.ch4_ack    (),

		.ch5_addr   (27'd0),
		.ch5_dout   (),
		.ch5_req    (1'b0),
		.ch5_ack    ()
	);

	sdram_model chip
	(
		.clk   (clk),          // SDRAM_CLK comes from an ALTDDIO_OUT primitive that does not simulate
		.cke   (SDRAM_CKE),
		.dq    (SDRAM_DQ),
		.a     (SDRAM_A),
		.ba    (SDRAM_BA),
		.dqml  (SDRAM_DQML),
		.dqmh  (SDRAM_DQMH),
		.n_cs  (SDRAM_nCS),
		.n_ras (SDRAM_nRAS),
		.n_cas (SDRAM_nCAS),
		.n_we  (SDRAM_nWE),
		.n_act (n_act),
		.n_rd  (n_rd),
		.n_wr  (n_wr),
		.n_clk (n_clk)
	);

endmodule
