//============================================================================
//  SlopperPI - boot testbench wrapper
//
//  Everything else in sim/ feeds MAME's captured RAM contents into the video
//  path, which means the 386 itself has never actually been run. This wrapper
//  instantiates the whole board with a real SDRAM image behind it and exposes
//  enough internal state for the C++ side to answer one question: does the CPU
//  come out of reset, fetch from ROM, and reach the video DMA triggers?
//
//  The board is now selectable, because the question worth asking on the SXX2C
//  cartridge is a different one: rdft2's 386 reads its Z80 program out of the
//  sound01 window and pushes it, a byte at a time, into what is SDRAM here.
//  Both ends of that are exposed -- the ch3 write port the download turns into
//  and the ch3 read port the Z80 fetches from -- so the C++ side can check that
//  what lands in the Z80's memory is the program that was in the ROM.
//============================================================================

module tb_boot_top
(
	input             clk_sys,
	input             clk_cpu,
	input             clk_ram,
	input             reset,
	input             rom_ready,

	// Which board and set, so one testbench covers rdfts and the cartridge.
	input             set_sxx2c,
	input       [1:0] set_id,

	// SDRAM services, driven by the C++ model
	output     [25:0] sdr_prg_addr,
	input      [63:0] sdr_prg_dout,
	output            sdr_prg_req,
	input             sdr_prg_ack,

	output     [25:0] sdr_gfx_addr,
	input      [63:0] sdr_gfx_dout,
	output            sdr_gfx_req,
	input             sdr_gfx_ack,

	output     [25:0] sdr_spr_addr,
	input      [63:0] sdr_spr_dout,
	output            sdr_spr_req,
	input             sdr_spr_ack,

	// ch3, both directions. The Z80 program download writes it and the Z80
	// itself reads it back; on the cartridge boards that is the same memory.
	output     [25:0] sdr_z80_addr,
	input      [63:0] sdr_z80_dout,
	output            sdr_z80_req,
	input             sdr_z80_ack,

	output     [25:0] z80dl_sdr_addr,
	output     [15:0] z80dl_sdr_din,
	output      [1:0] z80dl_sdr_be,
	output            z80dl_sdr_req,
	input             z80dl_sdr_ack,

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

	// The Z80 side of the cartridge: whether it has been let out of reset, and
	// the last address it fetched an opcode from.
	output            p_z80_rst_n,
	output     [15:0] p_snd_pc,

	// video out, so the testbench can see what the core actually draws
	output            v_ce_pix,
	output      [7:0] v_r,
	output      [7:0] v_g,
	output      [7:0] v_b,
	output            v_hb,
	output            v_vb
);

	/* verilator lint_off UNUSEDSIGNAL */
	wire [25:0] sdr_pcm_addr;   // 26 bits since the map outgrew 32 MB
	wire        sdr_pcm_req;
	/* verilator lint_on UNUSEDSIGNAL */

	spi_top dut
	(
		.clk_sys      (clk_sys),
		.clk_cpu      (clk_cpu),
		.clk_ram      (clk_ram),
		.reset        (reset),
		.rom_ready    (rom_ready),
		.set_sxx2c    (set_sxx2c),
		.set_id       (set_id),
		// SXX2C jumpers, as SeibuSPI.sv sends them: NOT update mode, which
		// would park the sound program in the reflash path forever.
		.jumpers      (8'hFC),
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
		.snd_pc       (p_snd_pc),
		.snd_fifo_rd  (),
		.snd_ymf_wr   (),
		.snd_stall    (),
		.ymf_overrun  (),
		.ymf_active   (),
		.snd_f2_wr    (),
		.snd_f2_rd    (),
		.snd_fifo_peak(),
		.snd_full_max (),
		.spr_gap_max  (),
		.snd_wait_max (),
		.stall_eip    (),
		.stall_cs     (),

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

		.z80dl_sdr_addr (z80dl_sdr_addr),
		.z80dl_sdr_din  (z80dl_sdr_din),
		.z80dl_sdr_be   (z80dl_sdr_be),
		.z80dl_sdr_req  (z80dl_sdr_req),
		.z80dl_sdr_ack  (z80dl_sdr_ack),

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
	assign p_z80_rst_n       = dut.z80_rst_n;

endmodule
