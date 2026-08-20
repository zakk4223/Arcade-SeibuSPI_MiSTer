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

	// Sections after this point arrive with the later phases; the count below
	// is what `memory_stream` is told to walk, so it has to grow with them.
	parameter int SSIDX_COUNT       = 5;

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
