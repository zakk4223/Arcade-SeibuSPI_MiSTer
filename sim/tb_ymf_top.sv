//============================================================================
//  SeibuSPI - YMF271 + its sample flash, as the cartridge wires them
//
//  tb_ymf271.cpp drove `ymf271` directly for everything up to the sample-flash
//  work. That is no longer the whole chip's worth of behaviour: on the SPI
//  cartridge the wave-memory port's write side goes to two E28F008SA, and the
//  read side comes back from them whenever they are not in read-array mode. A
//  testbench on `ymf271` alone can see the port move and nothing on the other
//  end of it.
//
//  This wrapper is the pair, with every pin the old top-module had kept at the
//  same name and width, so the existing tests are untouched and the flash ones
//  drive the SAME port the Z80 does rather than a back door.
//============================================================================

module tb_ymf_top
(
	input             clk,
	input             reset,
	input             stereo,
	// 1 = an authentic-flash cartridge. Held low, this is a board whose sample
	// memory is a mask ROM, which is what every test written before the flash
	// existed assumes.
	input             flash_en,

	input       [3:0] addr,
	input       [7:0] din,
	output      [7:0] dout,
	input             wr,
	input             rd,
	output            irq,

	// ch5, sample reads
	output     [25:0] sdr_addr,
	input      [63:0] sdr_dout,
	output            sdr_req,
	input             sdr_ack,

	// ch3's `d` port, flash writes
	output     [25:0] fl_addr,
	output     [15:0] fl_din,
	output      [1:0] fl_be,
	output            fl_req,
	input             fl_ack,

	output     [15:0] audio_l,
	output     [15:0] audio_r,
	output     [15:0] dbg_overrun,
	output     [15:0] dbg_active,
	output     [31:0] dbg_progs,
	output     [15:0] dbg_erases,
	output     [15:0] dbg_drops,
	output      [1:0] dbg_busy,

	// The watch (PLAN.md 19.11), brought out so the testbench can check the
	// INSTRUMENT before hardware is asked to trust it. The replayed page
	// contains the watched byte, so a watch that counts nothing here would
	// have read as "the write was never issued" on the board.
	output      [7:0] dbg_w_progs,
	output      [1:0] dbg_w_be,
	output      [7:0] dbg_w_data,
	output      [7:0] dbg_w_erases,
	output            dbg_w_er_after,
	output     [55:0] dbg_w_trace,
	// The byte-level half of the watch (PLAN.md 19.14), added to
	// spi_soundflash later than the six above and not brought out here with
	// them -- which broke this testbench's BUILD under -Wall (PINMISSING) and
	// so stopped `make test` running the YMF271 checks at all. Same reason as
	// the rest: the instrument gets checked here, where the answer is known,
	// before hardware is asked to believe it.
	output      [7:0] dbg_w_din,
	output            dbg_w_hit
);

	wire        ext_wr;
	wire  [7:0] ext_wd;
	wire [22:0] ext_a;
	wire        ext_ovr;
	wire  [7:0] ext_ovr_data;
	wire        dirty;

	// The savestate's four sections on the chip. This testbench drives the
	// register interface directly and never takes a state, so they are tied
	// off -- but the interfaces still have to exist to connect.
	ssbus_if ss_unused_regs(), ss_unused_par(), ss_unused_st(), ss_unused_fb();

	ymf271 ymf
	(
		// The savestate's board-wide pause. Nothing here ever asserts it.
		.pause    (1'b0),
		.ssbus_regs (ss_unused_regs),
		.ssbus_par  (ss_unused_par),
		.ssbus_st   (ss_unused_st),
		.ssbus_fb   (ss_unused_fb),
		.clk      (clk),
		.reset    (reset),
		.stereo   (stereo),
		.addr     (addr),
		.din      (din),
		.dout     (dout),
		.wr       (wr),
		.rd       (rd),
		.irq      (irq),

		.sdr_addr (sdr_addr),
		.sdr_dout (sdr_dout),
		.sdr_req  (sdr_req),
		.sdr_ack  (sdr_ack),

		.ext_wr       (ext_wr),
		.ext_wd       (ext_wd),
		.ext_a        (ext_a),
		.ext_ovr      (ext_ovr),
		.ext_ovr_data (ext_ovr_data),
		.mem_dirty    (dirty),

		.audio_l     (audio_l),
		.audio_r     (audio_r),
		.dbg_overrun (dbg_overrun),
		.dbg_active  (dbg_active)
	);

	spi_soundflash flash
	(
		.clk        (clk),
		.reset      (reset),
		.enable     (flash_en),

		.wr         (ext_wr),
		.addr       (ext_a[20:0]),
		.din        (ext_wd),

		.rd_ovr     (ext_ovr),
		.rd_data    (ext_ovr_data),

		.sdr_addr   (fl_addr),
		.sdr_din    (fl_din),
		.sdr_be     (fl_be),
		.sdr_req    (fl_req),
		.sdr_ack    (fl_ack),

		.dirty      (dirty),
		.dbg_progs  (dbg_progs),
		.dbg_erases (dbg_erases),
		.dbg_drops  (dbg_drops),
		.dbg_busy   (dbg_busy),

		.dbg_w_progs    (dbg_w_progs),
		.dbg_w_be       (dbg_w_be),
		.dbg_w_data     (dbg_w_data),
		.dbg_w_erases   (dbg_w_erases),
		.dbg_w_er_after (dbg_w_er_after),
		.dbg_w_trace    (dbg_w_trace),
		.dbg_w_din      (dbg_w_din),
		.dbg_w_hit      (dbg_w_hit)
	);

	/* verilator lint_off UNUSEDSIGNAL */
	wire _unused = &{1'b0, ext_a[22:21]};
	/* verilator lint_on UNUSEDSIGNAL */

endmodule
