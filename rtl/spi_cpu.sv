//============================================================================
//  SlopperPI - Seibu SPI / SXX2E
//
//  386 subsystem: z386 core, address decode, main RAM, PRG ROM fetch, IRQ.
//
//  Address map (sxx2e_map, seibuspi.cpp:1004,1077):
//
//    0000_0000 - 0003_FFFF   main RAM, 256 KB, on chip
//      0000_0400 - 0000_07FF   memory-mapped I/O, overlaying RAM
//    0020_0000 - 003F_FFFF   PRG ROM, 2 MB, in SDRAM
//    FFE0_0000 - FFFF_FFFF   the same ROM again, for the real-mode reset vector
//    anything else            reads as 0, writes dropped
//
//  The I/O registers really do live inside the RAM address space with nothing
//  to mark them uncacheable, so the z386 data cache is instantiated with its
//  uncacheable window set to 0x400-0x7FF (a 1 KB aligned window is a single
//  compare and covers every register, which all sit in 0x400-0x6FF).
//
//  Bus protocol, from l1_cache.sv / l1_icache.sv:
//    - a transfer is accepted on the edge where valid && ready are both high,
//      so `ready` must be combinational -- a registered `ready` would let a
//      write be accepted twice, since the cache does not drop `valid` until it
//      has seen `ready`
//    - `burstcount` is 4 for a cache line fill, 1 otherwise
//    - reads answer with `burstcount` single-cycle `resp_valid` pulses carrying
//      sequential dwords from `addr`
//    - writes are always burstcount 1 and produce no `resp_valid`
//  Only one request is accepted at a time.
//
//  This whole block runs on clk_cpu (28.636364 MHz), which is exactly clk_sys/2
//  and phase aligned. Main RAM's DMA port and the I/O register file's consumers
//  live on clk_sys; see rtl/pll.v for why the 386 has its own clock.
//============================================================================

module spi_cpu
(
	input             clk,          // clk_cpu, 28.636364 MHz
	input             reset,
	input             cpu_en,       // 0 = stall the CPU (pause, throttle)

	// SDRAM channel 1 - PRG ROM
	output reg [24:0] sdr_addr,
	input      [63:0] sdr_dout,
	output reg        sdr_req,
	input             sdr_ack,

	// I/O bus (byte address; only 0x400-0x7FF is decoded here)
	output     [10:2] io_addr,
	output     [31:0] io_wdata,
	output      [3:0] io_be,
	output            io_wr,
	output            io_rd,
	input      [31:0] io_rdata,

	// Video DMA share of the main RAM port. The DMA runs in short bursts a few
	// times a frame; while it holds the port the CPU simply is not granted a
	// memory cycle, which is what the real board's DMA does too.
	input             dma_req,
	output            dma_gnt,
	input      [15:0] dma_addr,
	output     [31:0] dma_dout,

	// Vertical blanking interrupt. Crosses from clk_sys as a toggle: a one-cycle
	// clk_sys pulse would be invisible to a clock running at half the rate.
	input             vbl_toggle
);

`include "spi_defs.vh"

	// ------------------------------------------------------------------
	// z386
	// ------------------------------------------------------------------
	wire [31:2] cpu_addr;
	wire  [3:0] cpu_be;
	wire  [7:0] cpu_burstcount;
	wire [31:0] cpu_dout;
	wire        cpu_valid, cpu_write, cpu_io;
	wire        cpu_inta;

	reg  [31:0] mem_din;
	reg         mem_resp_valid;
	reg         irq_pending;

	// INTA responses are muxed over the memory path, exactly as
	// z386_MiSTer/src/system.sv does it.
	reg         inta_ready;
	wire [31:0] cpu_din        = cpu_inta ? 32'h0000_0020 : mem_din;
	wire        cpu_resp_valid = cpu_inta ? inta_ready    : mem_resp_valid;
	wire        cpu_ready;

	z386 #(
		.PROTECT_UMA_ROM      (0),
		.DCACHE_SET_BITS      (8),
		.ICACHE_SET_BITS      (8),
		.DCACHE_UNCACHED_MASK (32'hFFFF_FC00),   // I/O window
		.DCACHE_UNCACHED_BASE (32'h0000_0400)
	) cpu
	(
		.clk                (clk),
		.reset_n            (~reset),

		.addr               (cpu_addr),
		.be                 (cpu_be),
		.burstcount         (cpu_burstcount),
		.din                (cpu_din),
		.dout               (cpu_dout),
		.valid              (cpu_valid),
		.ready              (cpu_ready),
		.write              (cpu_write),
		.io                 (cpu_io),
		.resp_valid         (cpu_resp_valid),

		.intr               (irq_pending),
		.nmi                (1'b0),
		.inta               (cpu_inta),

		.snoop_addr         (32'd0),
		.snoop_valid        (1'b0),

		.a20_enable         (1'b1),
		.single_step        (1'b0),

		.dbg_CS             (),
		.dbg_EIP            (),
		.dbg_CS_base        (),
		.dbg_pe             (),
		.dbg_vm             (),
		.triple_fault_reset ()
	);

	// ------------------------------------------------------------------
	// Interrupt
	//
	// MAME drives IRQ0 with HOLD_LINE on vblank and the acknowledge callback
	// unconditionally returns vector 0x20 -- there is no PIC on this board.
	//
	// The z386 BIU runs a two-cycle INTA sequence and holds `inta` across two
	// posedges per cycle, so this mirrors pic_inta_bridge.sv: respond once per
	// assertion, wait for `inta` to fall between the cycles, and retire the
	// request on the second. The vector is constant, so the first cycle's data
	// does not matter.
	// ------------------------------------------------------------------
	localparam [1:0] I_IDLE = 2'd0, I_CYC1 = 2'd1, I_CYC2 = 2'd2;

	reg [1:0] istate;
	reg       inta_responded;
	reg       vbl_tgl_d;

	always @(posedge clk) begin
		inta_ready <= 1'b0;

		if (reset) begin
			istate         <= I_IDLE;
			inta_responded <= 1'b0;
			irq_pending    <= 1'b0;
			vbl_tgl_d      <= vbl_toggle;
		end
		else begin
			vbl_tgl_d <= vbl_toggle;
			if (vbl_toggle != vbl_tgl_d) irq_pending <= 1'b1;

			case (istate)
				I_IDLE: if (cpu_inta && !inta_responded) begin
					inta_ready     <= 1'b1;
					inta_responded <= 1'b1;
					istate         <= I_CYC1;
				end

				I_CYC1: if (!cpu_inta) begin
					inta_responded <= 1'b0;
					istate         <= I_CYC2;
				end

				I_CYC2: if (cpu_inta && !inta_responded) begin
					inta_ready     <= 1'b1;
					inta_responded <= 1'b1;
					irq_pending    <= 1'b0;
					istate         <= I_IDLE;
				end

				default: istate <= I_IDLE;
			endcase

			if (!cpu_inta) inta_responded <= 1'b0;
		end
	end

	// ------------------------------------------------------------------
	// Address decode
	// ------------------------------------------------------------------
	// Bits 1:0 are constant zero by construction; kept so the region tests below
	// read as the byte addresses quoted in the memory map.
	/* verilator lint_off UNUSEDSIGNAL */
	wire [31:0] byte_addr = {cpu_addr, 2'b00};
	/* verilator lint_on UNUSEDSIGNAL */

	wire sel_io  = (byte_addr[31:11] == 21'd0) && byte_addr[10];
	wire sel_ram = (byte_addr[31:18] == 14'd0) && !sel_io;
	wire sel_rom = ((byte_addr[31:22] == 10'd0) && byte_addr[21])   // 0020_0000
	            ||  (byte_addr[31:21] == 11'h7FF);                  // FFE0_0000

	// ------------------------------------------------------------------
	// Main RAM
	// ------------------------------------------------------------------
	reg  [15:0] ram_addr;
	reg  [31:0] ram_din;
	reg   [3:0] ram_be;
	reg         ram_we;
	wire [31:0] ram_dout;

	// The DMA is granted the port only when the CPU has nothing in flight, and
	// keeps it until it drops the request. Granting mid-access would corrupt a
	// read that has already been issued into the RAM's pipeline.
	reg dma_own;
	assign dma_gnt = dma_own;

	wire [15:0] ram_addr_mux = dma_own ? dma_addr : ram_addr;

	spi_mainram mainram
	(
		.clk  (clk),
		.addr (ram_addr_mux),
		.din  (ram_din),
		.be   (ram_be),
		.we   (ram_we && !dma_own),
		.dout (ram_dout)
	);

	assign dma_dout = ram_dout;

	// ------------------------------------------------------------------
	// I/O bus
	// ------------------------------------------------------------------
	reg        io_cyc_wr, io_cyc_rd;
	reg [10:2] io_addr_r;
	reg [31:0] io_wdata_r;
	reg  [3:0] io_be_r;

	assign io_addr  = io_addr_r;
	assign io_wdata = io_wdata_r;
	assign io_be    = io_be_r;
	assign io_wr    = io_cyc_wr;
	assign io_rd    = io_cyc_rd;

	// ------------------------------------------------------------------
	// Transaction engine
	// ------------------------------------------------------------------
	localparam [2:0] S_IDLE    = 3'd0;
	localparam [2:0] S_RAM_RD  = 3'd1;
	localparam [2:0] S_IO_RD   = 3'd2;
	localparam [2:0] S_ROM_REQ = 3'd3;
	localparam [2:0] S_ROM_ACK = 3'd4;
	localparam [2:0] S_ROM_OUT = 3'd5;
	localparam [2:0] S_NULL    = 3'd6;

	reg  [2:0] state;
	reg  [7:0] burst_left;
	reg [29:0] cur_dw;        // running dword address
	reg [63:0] rom_data;
	// Read delivery is two stages deep, not one: `ram_addr` is only visible to
	// the RAM the cycle AFTER it is assigned, and the RAM registers its output,
	// so data is valid two cycles after the issuing state.
	reg        ram_rd_q;
	reg        ram_rd_pipe;

	// Accept combinationally: the cache samples ready in the same cycle it
	// drives valid, and holds valid until it sees ready. `valid` is also
	// asserted during INTA cycles, which the INTA state machine answers
	// instead, so they are excluded here.
	wire mem_accept = cpu_valid && !cpu_inta && cpu_en && !dma_own && (state == S_IDLE);
	assign cpu_ready = cpu_inta ? inta_ready : mem_accept;

	// Guard against a zero burstcount, which would underflow the counter.
	wire [7:0] burst_n = (cpu_burstcount == 8'd0) ? 8'd1 : cpu_burstcount;

	// ROM offset: both the 0x0020_0000 window and the 0xFFE0_0000 mirror map to
	// the same 2 MB image, so the low 21 bits are the offset either way.
	// SDRAM 64-bit reads must be 8-byte aligned, so this is the address of the
	// aligned group containing cur_dw, i.e. (cur_dw & ~1) * 4.
	wire [24:0] rom_grp_addr = SDR_PRG_BASE + {4'd0, cur_dw[18:1], 3'b000};

	always @(posedge clk) begin
		mem_resp_valid <= 1'b0;
		ram_we         <= 1'b0;
		io_cyc_wr      <= 1'b0;
		io_cyc_rd      <= 1'b0;
		ram_rd_q    <= 1'b0;
		ram_rd_pipe <= ram_rd_q;

		// Deliver the dword read from main RAM two cycles ago.
		if (ram_rd_pipe) begin
			mem_din        <= ram_dout;
			mem_resp_valid <= 1'b1;
		end

		if (reset) begin
			state      <= S_IDLE;
			sdr_req    <= 1'b0;
			burst_left <= 8'd0;
			dma_own    <= 1'b0;
		end
		else begin
			// Grant the DMA the RAM port only from a fully quiescent state.
			if (!dma_own) begin
				if (dma_req && (state == S_IDLE) && !ram_rd_q && !ram_rd_pipe)
					dma_own <= 1'b1;
			end
			else if (!dma_req) begin
				dma_own <= 1'b0;
			end

			case (state)

			S_IDLE: if (mem_accept) begin
				cur_dw     <= cpu_addr;
				burst_left <= burst_n;

				if (cpu_io) begin
					// The board decodes no I/O ports; MAME's map has none.
					// Reads answer with zeroes so the CPU cannot hang.
					state <= cpu_write ? S_IDLE : S_NULL;
				end
				else if (cpu_write) begin
					if (sel_ram) begin
						ram_addr <= cpu_addr[17:2];
						ram_din  <= cpu_dout;
						ram_be   <= cpu_be;
						ram_we   <= 1'b1;
					end
					else if (sel_io) begin
						io_addr_r  <= byte_addr[10:2];
						io_wdata_r <= cpu_dout;
						io_be_r    <= cpu_be;
						io_cyc_wr  <= 1'b1;
					end
					// ROM and unmapped writes are dropped.
					state <= S_IDLE;
				end
				else if (sel_ram) begin
					ram_addr    <= cpu_addr[17:2];
					ram_rd_q    <= 1'b1;
					cur_dw      <= cpu_addr + 30'd1;
					burst_left  <= burst_n - 8'd1;
					state       <= (burst_n > 8'd1) ? S_RAM_RD : S_IDLE;
				end
				else if (sel_io) begin
					io_addr_r <= byte_addr[10:2];
					io_be_r   <= cpu_be;
					io_cyc_rd <= 1'b1;
					state     <= S_IO_RD;
				end
				else if (sel_rom) begin
					state <= S_ROM_REQ;
				end
				else begin
					state <= S_NULL;
				end
			end

			// Remaining dwords of a RAM burst: one BRAM read per cycle.
			S_RAM_RD: begin
				ram_addr    <= cur_dw[15:0];
				ram_rd_q    <= 1'b1;
				cur_dw      <= cur_dw + 30'd1;
				burst_left  <= burst_left - 8'd1;
				if (burst_left == 8'd1) state <= S_IDLE;
			end

			// I/O registers read combinationally.
			S_IO_RD: begin
				mem_din        <= io_rdata;
				mem_resp_valid <= 1'b1;
				state          <= S_IDLE;
			end

			S_ROM_REQ: begin
				sdr_addr <= rom_grp_addr;
				sdr_req  <= ~sdr_req;
				state    <= S_ROM_ACK;
			end

			S_ROM_ACK: if (sdr_ack == sdr_req) begin
				rom_data <= sdr_dout;
				state    <= S_ROM_OUT;
			end

			S_ROM_OUT: begin
				mem_din        <= cur_dw[0] ? rom_data[63:32] : rom_data[31:0];
				mem_resp_valid <= 1'b1;
				cur_dw         <= cur_dw + 30'd1;
				burst_left     <= burst_left - 8'd1;

				if (burst_left == 8'd1)  state <= S_IDLE;
				// Crossing into the next 8-byte group needs a fresh fetch;
				// otherwise the next dword is already in rom_data.
				else if (cur_dw[0])      state <= S_ROM_REQ;
			end

			// Unmapped read: answer with zeroes.
			S_NULL: begin
				mem_din        <= 32'd0;
				mem_resp_valid <= 1'b1;
				burst_left     <= burst_left - 8'd1;
				if (burst_left == 8'd1) state <= S_IDLE;
			end

			default: state <= S_IDLE;
			endcase
		end
	end

endmodule
