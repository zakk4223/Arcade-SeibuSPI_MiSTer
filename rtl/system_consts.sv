//============================================================================
//  SeibuSPI - the savestate's section map and its DDR3 window
//
//  One SSIDX per thing that has to be remembered. `memory_stream` walks these
//  indices in order, asks each one how many items it holds and how wide they
//  are (`ssbus.setup`), and writes a section-tagged stream into DDR3. The blob
//  is therefore self-describing: nothing here is duplicated on the HPS side,
//  and a section can be added without the file format changing.
//
//  WHAT IS DELIBERATELY ABSENT, because it is not state:
//
//    * SDRAM. It holds ROMs. The one region the board writes is the 2 MB
//      sample flash, and PLAN.md 23/24 established that it is rebuilt from the
//      386's own program image in 0.3 s at every boot -- which is why the save
//      file keeps four bytes of stamp rather than two megabytes (PLAN.md 32),
//      and the same argument keeps it out of here.
//    * The z386 L1 caches and the TLB. The data cache is write-through, so
//      neither holds anything that is not also in main RAM, and with paging off
//      the TLB is a cache of nothing. All three are invalidated on restore.
//    * The tile and sprite line buffers, and the YMF271's sample-line cache.
//      Regenerated within one scanline.
//    * The 386's registers. There is no section for them because the CPU is
//      never read: it pushes its own state onto the game's stack, which is
//      inside SSIDX_MAIN_RAM. PLAN.md 38. SSIDX_GLOBAL carries only the one
//      thing the hardware has to remember for it -- where that stack ended up.
//============================================================================

package system_consts;

	// The 386, and everything it can reach on its own.
	parameter int SSIDX_GLOBAL      = 0;   // the saved ESP, and nothing else
	parameter int SSIDX_MAIN_RAM    = 1;   // 64K x 32, the 386's 256 KB

	// The video RAMs the DMA fills and the renderers read.
	parameter int SSIDX_TILEMAP_RAM = 2;   // 4K x 32
	parameter int SSIDX_PALETTE_RAM = 3;   // 4K x 30, streamed as 32
	parameter int SSIDX_SPRITE_RAM  = 4;   // 1K x 32

	// The raster. Small, and load-bearing out of proportion to its size: the
	// board-wide pause PRESERVES the phase between the 386 and the raster
	// across a transfer, but a restore has to SET it -- the CPU comes back to
	// where it was at save time and the raster would otherwise still be at
	// load time. Everything else on the video side is regenerated from these
	// counters within a line.
	parameter int SSIDX_VIDEO_TIMING = 5;  // {div, vcnt, hcnt}

	// spi_io's configuration: the whole 20-dword CRTC window, the six scroll
	// registers, the layer enables and banks, and the DMA source and length.
	// Not the strobes and not the boot-time Z80 download -- see the port
	// comment in rtl/spi_io.sv for what is left out and why.
	parameter int SSIDX_SPI_IO       = 6;  // 26 dwords

	// The sound board. The 386 polls the FIFO between itself and the Z80, so
	// none of this is optional: with the Z80 paused but not saved it comes back
	// from a restore wherever it was at LOAD time, the FIFO it feeds disagrees
	// with what the 386 expects, and the two machines take different branches.
	// Traced to exactly that -- 41,743 identical instructions after a restore
	// and then one conditional at 0x002018FC going the other way.
	parameter int SSIDX_Z80          = 7;  // tv80's own state, auto-generated
	parameter int SSIDX_Z80_RAM      = 8;  // 8 KB work RAM
	parameter int SSIDX_SND_FIFO     = 9;  // 386 -> Z80, 512 bytes
	parameter int SSIDX_SND_FIFO2    = 10; // Z80 -> 386, 512 bytes
	parameter int SSIDX_SND_REGS     = 11; // the pointers and the ROM bank

	// The YMF271. Its timer IRQ drives the Z80's INT_n, so it is in the 386's
	// causal path by way of the sound program: restore it wrong and the Z80's
	// interrupt timing is wrong and the FIFO the 386 polls follows.
	//
	// Only the PERSISTENT state is here. The synthesis engine's pipeline --
	// group, step, the operator accumulators, the working copies of a slot's
	// state -- is transient within one 44.1 kHz pass, and `pause` stops new
	// ticks rather than freezing mid-pass, so the engine has always drained to
	// S_IDLE by the time these sections are read. Same argument as parking the
	// raster one tick before vblank: choose the moment and the state stops
	// needing to be carried.
	//
	// The sample-line cache is absent for the other reason -- it caches sample
	// memory in SDRAM, which a savestate does not change.
	parameter int SSIDX_YMF_REGS     = 12; // registers, timers, IRQ, tick phase
	parameter int SSIDX_YMF_PAR      = 13; // 256 x 64, the slot parameter RAM
	parameter int SSIDX_YMF_ST       = 14; // 48 slots x 96 bits, + key pending
	parameter int SSIDX_YMF_FB       = 15; // 48 slots x 54 bits of feedback

	// The vblank interrupt's own state, which lives in spi_cpu rather than in
	// the 386: whether IRQ0 is asserted, where the two-cycle acknowledge got
	// to, and the toggle that carries vblank across from clk_sys.
	//
	// MEASURED, not guessed at this time. A save-only run hands the machine
	// back with irq_pending = 1 and a save-then-restore run hands it back with
	// 0, so the restored 386 sits in its vblank-wait loop for an extra frame --
	// which is the whole of the divergence that survived saving the raster, the
	// I/O registers, the DS2404, the Z80, the FIFOs and the YMF271.
	parameter int SSIDX_CPU_IRQ      = 16;

	// The DS2404. Its RTC counts real time at 256 Hz and a savestate does not
	// stop time passing between a save and the load that follows it -- so
	// without this the restored machine reads a clock that has moved on.
	//
	// MEASURED, and it is the last thing in the 386's causal path: the first
	// I/O read where a restored run differs from a saved one is 0x6DC, the
	// chip's data port, returning 0x0D against 0x12. Five ticks, which at
	// 256 Hz is the 21 ms between the save and the load in that test. The game
	// stores what it reads at 0x000369B8, which is the one main-RAM word that
	// had been differing since the raster was fixed.
	parameter int SSIDX_DS2404       = 17; // RTC, state machine, scratchpad
	parameter int SSIDX_DS2404_RAM   = 18; // the 512 bytes of bookkeeping SRAM

	// Sections after this point arrive with the later phases; the count below
	// is what `memory_stream` is told to walk, so it has to grow with them.
	parameter int SSIDX_COUNT       = 19;

	// ---- the DDR3 window -------------------------------------------------
	//
	// 4 slots of 512 KB at 0x3E00_0000, which is where every core that has
	// savestates puts them (`SS3E000000:80000` in the CONF_STR). Clear of both
	// existing DDR3 users by a wide margin: ddr_rom_reader replays the ROM
	// image from 0x3000_0000 and the largest is rfjet's ~40 MB, and
	// arcade_video's rotation framebuffer sits at 0x2400_0000 with three 8 MB
	// buffers.
	//
	// 512 KB against a blob of ~305 KB. The slack is deliberate: the sections
	// still to come are small, and a slot size in the CONF_STR is awkward to
	// change once states exist on people's SD cards.
	parameter bit [31:0] SS_DDR_BASE  = 32'h3E00_0000;
	parameter bit [31:0] SS_SLOT_SIZE = 32'h0008_0000;

endpackage
