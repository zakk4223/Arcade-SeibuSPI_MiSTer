//============================================================================
//  SlopperPI - boot testbench wrapper
//
//  Everything else in sim/ feeds MAME's captured RAM contents into the video
//  path, which means the 386 itself has never actually been run. This wrapper
//  instantiates the whole board with a real SDRAM image behind it and exposes
//  enough internal state for the C++ side to answer one question: does the CPU
//  come out of reset, fetch from ROM, and reach the video DMA triggers?
//============================================================================

module tb_boot_top
(
	input             clk_sys,
	input             clk_cpu,
	input             clk_ram,
	input             reset,
	input             rom_ready,

	// SDRAM services, driven by the C++ model
	output     [24:0] sdr_prg_addr,
	input      [63:0] sdr_prg_dout,
	output            sdr_prg_req,
	input             sdr_prg_ack,

	output     [24:0] sdr_gfx_addr,
	input      [63:0] sdr_gfx_dout,
	output            sdr_gfx_req,
	input             sdr_gfx_ack,

	output     [24:0] sdr_spr_addr,
	input      [63:0] sdr_spr_dout,
	output            sdr_spr_req,
	input             sdr_spr_ack,

	// probes
	output            p_io_wr,
	output      [8:0] p_io_addr,
	output     [31:0] p_io_wdata,
	output            p_dma_tilemap,
	output            p_dma_palette,
	output            p_dma_sprite,
	output            p_vbl_rise,

	output     [29:0] p_cpu_addr,
	output            p_cpu_valid,
	output            p_cpu_ready,
	output            p_cpu_write,
	output            p_cpu_io,
	output            p_cpu_inta,
	output            p_cpu_rst,
	output      [2:0] p_cpu_state,
	output            p_dma_own,
	output            p_dma_busy,
	output            p_prg_outstanding,

	// video out, so the testbench can see what the core actually draws
	output            v_ce_pix,
	output      [7:0] v_r,
	output      [7:0] v_g,
	output      [7:0] v_b,
	output            v_hb,
	output            v_vb
);

	/* verilator lint_off UNUSEDSIGNAL */
	wire [24:0] sdr_pcm_addr;
	wire        sdr_pcm_req;
	/* verilator lint_on UNUSEDSIGNAL */

	spi_top dut
	(
		.clk_sys      (clk_sys),
		.clk_cpu      (clk_cpu),
		.clk_ram      (clk_ram),
		.reset        (reset),
		.rom_ready    (rom_ready),
		.dbg_en       (1'b0),
		// These grew on spi_top for the JTAG debug plumbing. Leaving them
		// unconnected made Verilator drive dbg_mask with X, which ORs into the
		// layer enables and blanked the whole frame in simulation.
		.chk_ok       (4'hF),
		.chk_done     (1'b1),
		.dbg_mask     (8'd0),
		.c_prg        (),
		.c_iowr       (),
		.c_dma_tm     (),
		.c_dma_pal    (),
		.c_vbl        (),
		.why          (),
		.eip          (),
		.cs           (),
		.irq          (),
		.gdt          (),
		.lay_ovr      (),
		.lay_ovr_layer(),
		.lay_text_col (),
		.spr_scanned  (),
		.spr_yhit     (),
		.spr_emitted  (),
		.spr_starved  (),
		.spr_tiles    (),
		.c_dma_spr    (),
		.spr_codes_nz (),
		.spr_ram_or   (),
		.dma_src_spr  (),
		.dma_text_dw  (),
		.cpu_wr_spr   (),
		.cpu_wr_tm    (),
		.rs_out       (),
		.fd13_out     (),
		.tm_dwords_out(),
		.scroll_out   (),
		.lay_en_out   (),

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
		.sdr_pcm_dout (64'd0),
		.sdr_pcm_req  (sdr_pcm_req),
		.sdr_pcm_ack  (1'b0),

		.inputs       (16'hFFFF),
		.system       (8'hFF),
		.coin         (8'hFF),

		.ce_pix       (v_ce_pix),
		.red          (v_r),
		.green        (v_g),
		.blue         (v_b),
		.hsync        (),
		.vsync        (),
		.hblank       (v_hb),
		.vblank       (v_vb),
		.audio_l      (),
		.audio_r      ()
	);

	assign p_io_wr       = dut.io_wr;
	assign p_io_addr     = dut.io_addr;
	assign p_io_wdata    = dut.io_wdata;
	assign p_dma_tilemap = dut.dma_tilemap;
	assign p_dma_palette = dut.dma_palette;
	assign p_dma_sprite  = dut.dma_sprite;
	assign p_vbl_rise    = dut.vbl_rise;

	assign p_cpu_addr    = dut.cpu.cpu_addr;
	assign p_cpu_valid   = dut.cpu.cpu_valid;
	assign p_cpu_ready   = dut.cpu.cpu_ready;
	assign p_cpu_write   = dut.cpu.cpu_write;
	assign p_cpu_io      = dut.cpu.cpu_io;
	assign p_cpu_inta    = dut.cpu.cpu_inta;
	assign p_cpu_rst     = dut.cpu.reset;
	assign p_cpu_state   = dut.cpu.state;
	assign p_dma_own     = dut.cpu.dma_own;
	assign p_dma_busy    = dut.dma_busy;
	assign p_prg_outstanding = dut.sdr_prg_req ^ dut.sdr_prg_ack;

endmodule
