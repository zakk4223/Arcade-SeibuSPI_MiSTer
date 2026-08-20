//============================================================================
//  SeibuSPI - the savestate sequencer
//
//  Sits between savestate_ui (which says save or load, and which slot),
//  spi_cpu's stub machinery (which stops the 386 at a point where its own
//  state is already in main RAM), and memory_stream (which moves the blob to
//  and from DDR3). PLAN.md 38 is the design record for the CPU half.
//
//  WHEN a save happens is chosen, not taken as it comes. The request arms, and
//  nothing else happens until the raster is one tick from raising the vblank
//  interrupt -- `vbl_next` -- at which point the board is paused and the raster
//  is left parked there.
//
//  That instant is worth waiting for because it makes the interrupt state
//  KNOWN rather than something that has to be carried in the blob. Parked
//  there, this frame's interrupt has not been raised yet and the previous
//  frame's has long since been acknowledged and returned from, so `irq_pending`
//  is clear and spi_cpu's two-cycle acknowledge machine is idle. There is
//  nothing to save because there is nothing in flight. Releasing lets the very
//  next tick raise vbl_rise exactly as it would have, so the interrupt is not
//  lost either -- it is deferred by the length of the transfer along with
//  everything else.
//
//  Measured: a save taken wherever the request happened to land failed the
//  determinism test at the one point in five where the game was inside its
//  vblank handler, and the same point failed on all three sets. Restoring
//  spi_cpu's interrupt state instead was tried and made things worse.
//
//  A SAVE:
//     wait for vbl_next               -> the canonical instant, above
//     ask spi_cpu for a save          -> NMI, the stub pushes, the marker
//                                        write freezes the machine
//     take the main RAM port           -> the CPU is frozen, so nothing else
//                                        is driving it
//     run memory_stream out            -> sections walk themselves; the 386's
//                                        register frame is inside MAIN_RAM
//     release                          -> the stub unwinds and irets, and the
//                                        game has not noticed
//
//  A LOAD is the mirror, with one extra step and one ordering constraint that
//  is not obvious:
//     ask spi_cpu for a restore        -> NMI, the restore stub's marker
//                                        freezes it. THIS HAPPENS FIRST: the
//                                        interrupt pushes three dwords at the
//                                        game's live ESP, which is within a few
//                                        words of where the saved frame sits,
//                                        so memory written back before the NMI
//                                        gets those pushes on top of it.
//     run memory_stream in
//     invalidate every cache set       -> memory moved underneath the CPU
//     release                          -> the stub points its stack at a dword
//                                        this module supplies and pops the
//                                        saved ESP out of it
//
//  Nothing in the game's memory is written to make a restore work. An earlier
//  version patched the stub's own marker slot with the saved ESP; that slot is
//  at the game's live ESP minus sixteen, the saved frame sits a few words either
//  side of it, and the patch corrupted a saved register -- measured landing
//  exactly on EAX. spi_cpu.sv's stub comment records the whole progression.
//
//  Runs on clk_sys, the DDR3 domain. spi_cpu is clk_cpu, exactly half and phase
//  aligned off the same PLL; every signal crossing between them here is a level
//  held until the far side acknowledges it by changing state, so there is
//  nothing for a synchroniser to do. The one streaming interface -- the main RAM
//  port -- goes through spi_ss_bridge, whose header explains why it takes seven
//  cycles an item rather than one.
//============================================================================

module spi_ss
	import system_consts::*;
(
	input             clk,          // clk_sys
	input             reset,

	// ---- from savestate_ui ----------------------------------------------
	input             ss_save,      // one clk_sys pulse
	input             ss_load,

	// The raster is one tick from the vblank interrupt: the instant a save or a
	// load is allowed to start.
	input             vbl_next,
	// Freeze the board. NOT the same as `busy`: while the request is armed and
	// waiting for vbl_next, the machine has to keep running to get there.
	output            pause,

	// ---- memory_stream / save_state_data --------------------------------
	output reg        stream_write, // start a save   (one pulse)
	output reg        stream_read,  // start a load
	input             stream_busy,

	// ---- the section this module answers itself -------------------------
	ssbus_if.slave    ssbus_global,
	// ...and the one it hands to the main RAM bridge
	ssbus_if.slave    ssbus_mainram,

	// ---- spi_cpu's stub machinery (clk_cpu, level-held) -----------------
	output reg        cpu_save_req,
	output reg        cpu_restore_req,
	input             cpu_snapshot,
	output reg        cpu_hold_rel,
	// The marker slot's address, valid at snapshot: on a save this is the ESP
	// the blob has to carry.
	input      [31:0] cpu_esp,
	// The video DMA still owns the main RAM port, or is asking for it. The CPU
	// being frozen means no NEW transfer can be triggered -- the trigger is a
	// CPU I/O write -- so this only ever waits out one that was already in
	// flight, which is a few thousand cycles at worst.
	input             cpu_dma_busy,
	// ...and on a restore, what the stub's `pop esp` will read.
	output     [31:0] cpu_esp_out,

	// ---- the main RAM port spi_cpu lends out ---------------------------
	output            ram_own,
	output     [15:0] ram_addr,
	output     [31:0] ram_din,
	output            ram_we,   // driven by the bridge alone
	input      [31:0] ram_dout,

	// ---- the cache invalidate sweep ------------------------------------
	output reg        inval,
	output reg  [7:0] inval_set,

	output            busy
);

	// ------------------------------------------------------------------
	// SSIDX_GLOBAL: one 32-bit item, the saved ESP.
	//
	// The 386's registers are not here and never will be -- the CPU pushes them
	// onto its own stack, which is inside SSIDX_MAIN_RAM. All the hardware has
	// to remember is where that stack ended up.
	// ------------------------------------------------------------------
	reg [31:0] saved_esp;

	// A SAVE has to put it there in the first place. Latched from spi_cpu at
	// the snapshot, which is well before memory_stream gets as far as reading
	// section 0: the engine reads the slot's header and queries every section
	// before it streams any of them. Without this the section carries whatever
	// the register happened to hold, the restore patches that into the marker
	// slot, and `pop esp` loads a garbage stack -- which looks like the restore
	// stub misbehaving and is not.
	reg capture_esp;

	always @(posedge clk) begin
		ssbus_global.setup(SSIDX_GLOBAL, 32'd1, 2);   // 1 item, 32 bits
		if (reset) saved_esp <= 32'd0;
		else if (capture_esp) saved_esp <= cpu_esp;
		else if (ssbus_global.access(SSIDX_GLOBAL)) begin
			if (ssbus_global.read)
				ssbus_global.read_response(SSIDX_GLOBAL, {32'd0, saved_esp});
			else if (ssbus_global.write) begin
				saved_esp <= ssbus_global.data[31:0];
				ssbus_global.write_ack(SSIDX_GLOBAL);
			end
		end
	end

	// Four bytes past the marker slot the save stub pushed, so `popad` lands
	// on the pushad frame and `iret` on the interrupt's.
	assign cpu_esp_out = saved_esp + 32'd4;

	// ------------------------------------------------------------------
	// The main RAM port. Only the bridge drives it: a restore writes nothing
	// of its own any more.
	// ------------------------------------------------------------------
	spi_ss_bridge #(
		.SS_IDX (SSIDX_MAIN_RAM),
		.AW     (16),
		.DW     (32),
		.ITEMS  (65536)
	) mainram_bridge (
		.clk      (clk),
		.ssbus    (ssbus_mainram),
		.ram_addr (ram_addr),
		.ram_din  (ram_din),
		.ram_we   (ram_we),
		.ram_dout (ram_dout)
	);

	// ------------------------------------------------------------------
	// The sequence
	// ------------------------------------------------------------------
	localparam [3:0] S_IDLE      = 4'd0,
	                 S_ARM       = 4'd8,   // wait for the canonical instant
	                 S_ASK       = 4'd1,   // hold the request until it is taken
	                 S_STREAM    = 4'd2,
	                 S_STREAMING = 4'd3,
	                 S_INVAL     = 4'd4,
	                 S_RELEASE   = 4'd5,
	                 S_DONE      = 4'd6;

	reg [3:0] st;
	reg       is_load;
	reg [1:0] inval_ph;

	assign busy    = (st != S_IDLE);
	// Everything except the wait is frozen.
	assign pause   = busy && (st != S_ARM);
	// The port is ours from the moment the machine is frozen until it is let go.
	// Not in S_STREAM until the DMA has let go, or the override in spi_cpu's
	// mux would cut a transfer off mid-flight.
	assign ram_own = ((st == S_STREAM) && !cpu_dma_busy) ||
	                 (st == S_STREAMING) || (st == S_INVAL);

	always @(posedge clk) begin
		stream_write <= 1'b0;
		stream_read  <= 1'b0;
		inval        <= 1'b0;
		capture_esp  <= 1'b0;

		if (reset) begin
			st              <= S_IDLE;
			cpu_save_req    <= 1'b0;
			cpu_restore_req <= 1'b0;
			cpu_hold_rel    <= 1'b0;
			inval_set       <= 8'd0;
			inval_ph        <= 2'd0;
			is_load         <= 1'b0;
			capture_esp     <= 1'b0;
		end
		else begin
			case (st)
			S_IDLE: if (ss_save || ss_load) begin
				is_load <= ss_load && !ss_save;
				st      <= S_ARM;
			end

			// The machine runs on until the raster reaches the one place a
			// snapshot is cheap to take.
			S_ARM: if (vbl_next) begin
				cpu_save_req    <= !is_load;
				cpu_restore_req <=  is_load;
				st              <= S_ASK;
			end

			// spi_cpu latches the request in its own idle state and then leaves
			// it, which is the acknowledgement. Dropping the request earlier
			// than that would race clk_cpu.
			S_ASK: if (cpu_snapshot) begin
				cpu_save_req    <= 1'b0;
				cpu_restore_req <= 1'b0;
				// On a save this is the ESP the blob has to carry. On a load
				// it is the marker slot to patch, which is held in cpu_esp
				// and must NOT overwrite what the blob is about to bring in.
				capture_esp     <= !is_load;
				st              <= S_STREAM;
			end

			S_STREAM: if (!cpu_dma_busy) begin
				// The port is ours now. Kick the stream in the right direction.
				if (is_load) stream_read  <= 1'b1;
				else         stream_write <= 1'b1;
				st <= S_STREAMING;
			end

			S_STREAMING: if (!stream_busy && !stream_read && !stream_write) begin
				inval_set <= 8'd0;
				inval_ph  <= 2'd0;
				st        <= is_load ? S_INVAL : S_RELEASE;
			end

			// Memory moved underneath the CPU, so both L1s have to go. One
			// snoop pulse retires a whole set and there are 256 of them; the
			// data cache is write-through and the TLB is a cache of page tables
			// with paging off, so nothing is lost by invalidating the lot.
			//
			// FOUR CYCLES A SET, not one. This module is clk_sys and the snoop
			// port is sampled on clk_cpu, which is half the rate -- so a pulse
			// one clk_sys cycle wide is missed about half the time, and the
			// sets that get missed keep their stale lines. That is not a
			// theoretical hazard: it is what made a restore return the CPU to a
			// wrong EIP at four save points out of five, while the fifth
			// happened to have nothing stale in the lines that mattered and
			// looked like proof the whole thing worked.
			S_INVAL: begin
				inval <= 1'b1;
				inval_ph <= inval_ph + 2'd1;
				if (inval_ph == 2'd3) begin
					if (inval_set == 8'd255) st <= S_RELEASE;
					else inval_set <= inval_set + 8'd1;
				end
			end

			S_RELEASE: begin
				cpu_hold_rel <= 1'b1;
				if (!cpu_snapshot) begin
					cpu_hold_rel <= 1'b0;
					st           <= S_DONE;
				end
			end

			S_DONE: st <= S_IDLE;

			default: st <= S_IDLE;
			endcase
		end
	end

endmodule
