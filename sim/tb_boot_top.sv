//============================================================================
//  SeibuSPI - boot testbench wrapper
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
	// Three bits since viprp1 became the fifth set. This was [1:0] against
	// spi_top's [2:0], which is a WIDTHEXPAND and, with the other 32 pins
	// below, is why this testbench had stopped building at all.
	input       [2:0] set_id,

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

	// Where the 386 has put its IDT. Phase 0 of the savestate work needs to
	// overlay one gate in it, and the first question is whether the base is
	// visible and sane once the boot code has run its LIDT.
	output     [31:0] p_idt_base,
	output     [19:0] p_idt_limit,
	output     [31:0] p_eip,
	output     [15:0] p_cs,
	output     [31:0] p_cs_base,
	output     [31:0] p_cr0,

	// Savestates. The C++ side asks for one the way the OSD does -- a single
	// pulse -- and the board does the rest: NMI, stub, freeze, and the whole
	// blob to and from a DDR3 the model below stands in for. Phase 0 drove
	// spi_cpu's ports directly from here; nothing does now, so what this
	// testbench exercises is the path the hardware will take.
	input             ss_save,
	input             ss_load,
	output            p_ss_busy,
	output            p_ss_snapshot,
	output     [31:0] p_ss_esp_out,

	// The DDR3 side of memory_stream, for the C++ model to answer.
	output     [31:0] ddr_addr,
	output     [63:0] ddr_wdata,
	input      [63:0] ddr_rdata,
	output            ddr_read,
	output            ddr_write,
	output      [7:0] ddr_burstcnt,
	output      [7:0] ddr_byteenable,
	input             ddr_busy,
	input             ddr_rdata_ready,
	output            ddr_acquire,

	output            p_ss_in_stub,
	output     [15:0] p_ss_writes,
	output     [31:0] p_ss_last_wa,
	output     [31:0] p_ss_last_wd,
	// A window onto main RAM for the testbench alone. The savestate work needs
	// to read back what the 386's stub pushed, and later to hash the whole
	// 256 KB either side of a restore; nothing synthesised has this.
	input      [15:0] peek_addr,
	output     [31:0] peek_data,

	output      [2:0] p_ss_state,
	output            p_ss_nmi,
	output     [15:0] p_ss_gate_dw0,
	output     [15:0] p_ss_gate_reads,
	output            p_ss_hold,
	output     [15:0] p_ss_stub_reads,
	output      [7:0] p_ss_stub_idx,
	output     [31:0] p_ss_stub_data,
	output     [31:0] p_ss_resume_eip,
	output     [31:0] p_ss_esp_scratch,
	output     [31:0] p_ss_base,
	output     [19:0] p_ss_limit,
	output      [3:0] p_ss_type,
	output            p_ss_g,

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
	wire        flash_sdr_req;
	/* verilator lint_on UNUSEDSIGNAL */

	// The blob's trip to DDR3, exactly as SeibuSPI.sv wires it. `ddr_if` is an
	// interface, so it is unrolled onto plain ports for the C++ model.
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
		.index       (2'd0),
		.busy        (ss_stream_busy),
		.ssbus       (ssbus)
	);

	assign ddr_addr           = ss_ddr.addr;
	assign ddr_wdata          = ss_ddr.wdata;
	assign ddr_read           = ss_ddr.read;
	assign ddr_write          = ss_ddr.write;
	assign ddr_burstcnt       = ss_ddr.burstcnt;
	assign ddr_byteenable     = ss_ddr.byteenable;
	assign ddr_acquire        = ss_ddr.acquire;
	assign ss_ddr.rdata       = ddr_rdata;
	assign ss_ddr.busy        = ddr_busy;
	assign ss_ddr.rdata_ready = ddr_rdata_ready;

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
		// The one debug control still in the core: the CPU freeze. Off here.
		.freeze       (1'b0),

		.ss_save         (ss_save),
		.ss_load         (ss_load),
		.ss_busy         (p_ss_busy),
		.ss_stream_write (ss_stream_write),
		.ss_stream_read  (ss_stream_read),
		.ss_stream_busy  (ss_stream_busy),
		.ssbus           (ssbus),
		.ss_snapshot     (p_ss_snapshot),
		.ss_esp_out      (p_ss_esp_out),

		.ss_in_stub   (p_ss_in_stub),
		.ss_writes    (p_ss_writes),
		.ss_last_wa   (p_ss_last_wa),
		.ss_last_wd   (p_ss_last_wd),
		.ss_dbg_state      (p_ss_state),
		.ss_dbg_nmi        (p_ss_nmi),
		.ss_dbg_gate_dw0   (p_ss_gate_dw0),
		.ss_dbg_gate_reads (p_ss_gate_reads),
		.ss_dbg_hold       (p_ss_hold),
		.ss_dbg_stub_reads (p_ss_stub_reads),
		.ss_dbg_stub_idx   (p_ss_stub_idx),
		.ss_dbg_stub_data  (p_ss_stub_data),
		.ss_dbg_resume_eip (p_ss_resume_eip),
		.ss_dbg_esp_scratch(p_ss_esp_scratch),
		.ss_dbg_ss_base    (p_ss_base),
		.ss_dbg_ss_limit   (p_ss_limit),
		.ss_dbg_ss_type    (p_ss_type),
		.ss_dbg_ss_g       (p_ss_g),

		// Ports spi_top grew after this file was last touched. Leaving them
		// off is not free: Verilator's -Wall makes PINMISSING an error, so the
		// whole boot testbench stopped BUILDING -- silently, since a testbench
		// that fails to build looks much like one nobody ran.
		//
		// set_upd stays 0 to match the jumpers above: this models a cartridge
		// whose flash is already programmed, which is the configuration the
		// Z80-program check below is written against. The sound1 window that
		// check reads through does not depend on it -- rdft2 and rfjet carry
		// that ROM either way -- so what run-boot covers is unchanged.
		.set_upd      (1'b0),

		// The sample-flash write port. Nothing programs it with set_upd low,
		// but the ack is a TOGGLE handshake, so tying it low rather than to
		// the request would stall the writer forever if anything ever did --
		// silently, and in the same shape as the ch3 bug in PLAN.md 21.3.
		// Looping it back models a memory that is always ready.
		.flash_sdr_addr(),
		.flash_sdr_din (),
		.flash_sdr_be  (),
		.flash_sdr_req (flash_sdr_req),
		.flash_sdr_ack (flash_sdr_req),
		.flash_dirty   (),

		// The DS2404's SRAM port, which spi_nvram drives at the top level and
		// nothing drives here. Tied off rather than left unconnected for the
		// reason the comment above gives: PINMISSING is an error, so an
		// unconnected port stops this file BUILDING. Nothing in the boot
		// sequence reads the chip's bookkeeping, so a quiet port is honest.
		.ds_nv_addr    (9'd0),
		.ds_nv_din     (8'd0),
		.ds_nv_we      (1'b0),
		.ds_nv_dout    (),
		.ds_nv_dirty   (),

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
	// The Z80's last opcode fetch. It used to arrive on a spi_top port, with the
	// rest of the telemetry the JTAG probe read; that plumbing is out of the
	// synthesised net now (PLAN.md 29), so this reaches into spi_sound the same
	// way every other probe in this file reaches into the DUT.
	assign p_snd_pc          = dut.sound.dbg_z80_pc;
	assign p_idt_base        = dut.cpu.dbg_idt_base;
	assign p_idt_limit       = dut.cpu.dbg_idt_limit;
	assign p_eip             = dut.cpu.dbg_eip;
	assign p_cs              = dut.cpu.dbg_cs;
	assign p_cs_base         = dut.cpu.dbg_cs_base;
	assign peek_data         = {dut.cpu.mainram.mem3[peek_addr],
	                            dut.cpu.mainram.mem2[peek_addr],
	                            dut.cpu.mainram.mem1[peek_addr],
	                            dut.cpu.mainram.mem0[peek_addr]};
	assign p_cr0             = dut.cpu.dbg_cr0;

endmodule
