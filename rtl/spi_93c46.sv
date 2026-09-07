//============================================================================
//  SeibuSPI - 93C46 serial EEPROM (64 x 16), the SXX2F/SXX2G/SYS386 backup part
//
//  The single-board Seibu variants drop the SXX2C's DS2404 and keep their
//  bookkeeping in a 93C46 instead: `sxx2f()` is `sxx2e()` plus
//  `config.device_remove("ds2404")` and `EEPROM_93C46_16BIT` (seibuspi.cpp:1892).
//  The 386 bit-bangs it through one byte of one register -- 0x68E bits 7/6/5 are
//  DI/CLK/CS (`eeprom_w`, seibuspi.cpp:936) -- and reads DO back as bit 6 of
//  SYSTEM at 0x60C (`INPUT_PORTS sxx2f`, :1322).
//
//  MAME's eepromser.cpp IS the specification here, the same way ds2404.cpp is
//  for the other chip, and four details in it are worth stating because none of
//  them is what a datasheet would lead you to write.
//
//  1. THE GEOMETRY. 93C46 in 16-bit mode is 64 cells of 16 bits with SIX
//     command-address bits (`DEFINE_SERIAL_EEPROM_DEVICE(93cxx, 93c46, ..., 64, 6)`,
//     eepromser.cpp:1106). A command frame is the start bit, 2 opcode bits and 6
//     address bits -- nine clocks before anything happens.
//
//  2. DO IS A BUSY PIN, IN EXACTLY ONE STATE, AND THE GAME DEPENDS ON IT.
//     The 93cxx subclass does NOT use base_do_read() as-is:
//
//         int do_read() { return (m_state == STATE_WAIT_FOR_START_BIT)
//                                ? base_ready_read() : base_do_read(); }
//                                              -- eepromser.cpp:658
//
//     the header calling it "combined DO+READY/BUSY". So DO is the shift
//     register's top bit while a word is being clocked out, the write-completion
//     status while the chip sits with CS raised waiting for a start bit, and 1
//     otherwise. That is the datasheet's own behaviour: raise CS after a write
//     and DO reads 0 until programming finishes.
//
//     An earlier version of this file read only base_do_read(), concluded DO was
//     never a busy pin, and left the write timer out as unnecessary. rdft2us
//     then booted to a black screen and spun 94 frames in this loop, at
//     0x2A10A4 in its own program:
//
//         xor  $0x40,%al          ; toggle CLK
//         mov  %eax,0x68e
//         mov  0x60c,%cx          ; SYSTEM -- bit 6 is DO
//         xor  $0x40,%al
//         mov  %eax,0x68e
//         test $0x40,%cl
//         jne  ...                ; loop WHILE DO == 1, i.e. wait for BUSY
//
//     followed by the mirror image waiting for DO to go back to 1. A chip that
//     is never busy never satisfies the first loop. Nothing about the command
//     stream was wrong -- the trace showed READ 0x00..0x0F, EWEN, ERASE 0x00,
//     all decoded correctly -- which is exactly why this was invisible until the
//     game ran.
//
//  3. THE WRITE TIMER IS THEREFORE REQUIRED, and its LENGTH matters in both
//     directions. Too short and the game's poll misses the busy window between
//     two samples; too long and it breaks a game outright -- eeprom.cpp:41
//     carries the comment "a 2ms write time is too long for rfjetsa" and picks
//     1750us to avoid it. These are MAME's four numbers, unchanged, because they
//     are numbers someone already had to tune against these games. MAME's
//     `ready()` also gates the START BIT (eepromser.cpp:386), so a command
//     issued while busy is dropped; that is modelled here too.
//
//  4. WRITEALL IS AN AND, NOT A STORE. `write_all()` does
//     `internal_write(a, internal_read(a) & data)` (eeprom.cpp), which is why the
//     datasheet says ERAL must precede WRAL. ERASE and ERASEALL write all ones.
//
//  THE ARRAY, AND TWO WRONG ANSWERS ABOUT IT BEFORE THE RIGHT ONE. This is
//  1 Kbit of storage and it went through three fitted versions:
//
//      flops, one 16-bit array, combinational reads   1191 ALMs, 1169 regs
//      registered reads, two byte lanes               1511 ALMs, 1194 regs
//      the same, with the byte read ports MERGED       178 ALMs,  290 regs
//
//  against spi_ds2404's 643 ALMs for a real 512-byte SRAM. The first version
//  took the design from 94% ALMs to 99% and out of timing closure; the last one
//  returns it to 94% with +0.030 setup, and Quartus puts the array in 4 M10Ks
//  (block memory +2048 bits, RAM blocks 529 -> 533).
//
//  What made the difference was NOT the storage bits and not any of the things
//  tried first. A `ramstyle = "M10K"` attribute, byte lanes on their own, and a
//  scoped ALLOW_ANY_RAM_SIZE_FOR_RECOGNITION each changed the logic-cell count
//  by exactly nothing. **Every read port over a 64-entry array is a 64:1 mux per
//  lane**, and there were three ports, so six of them -- that was the whole
//  cost, and registering the reads even added flops without removing one.
//  Merging the save-file and savestate ports took six muxes to four, and at two
//  read ports Quartus inferred the RAM it had refused at three. Which of those
//  two effects mattered more was not isolated, so do not repeat the claim that
//  512 bits is simply "below the inference threshold": the same array infers
//  fine with fewer ports.
//
//  Read data is one cycle late, which every consumer already tolerates:
//  spi_nvram reads the DS2404's registered `nv_dout` the same way, spi_ss_bridge
//  has a two-cycle settle window, and the engine's word is prefetched cycles
//  before the first clock edge needs it.
//
//  NO HANDSHAKE, UNLIKE THE DS2404. That chip needed a req/ack toggle from
//  clk_cpu because its command bytes are EVENTS that must not be seen twice or
//  out of order. These three lines are LEVELS -- the 386 writes cs/sk/di and
//  they sit there for microseconds -- so this module samples them on its own
//  clock and finds the edges itself. clk_cpu is a gated clk_sys/2 off the same
//  PLL and every surviving edge coincides with a clk_ram edge
//  (rtl/spi_clk_throttle.sv), so the way in is a synchronous transfer, not a CDC.
//
//  BYTE ORDER, for the save file. MAME stores word N at bytes 2N and 2N+1
//  LITTLE-ENDIAN (`get_u16le(&m_data[address * 2])`, eeprom.cpp:286), and the
//  nvram file is that array verbatim. Matching it keeps the save file
//  byte-for-byte MAME's, the way the DS2404's 512-byte tail already is.
//============================================================================

`timescale 1ns/10ps

module spi_93c46
#(
	// clk cycles per microsecond, so the four operation times below can be
	// stated as MAME states them. clk_ram is 114.545455 MHz; the testbench turns
	// this right down rather than simulating 200,000 cycles per write.
	parameter int CLK_MHZ = 115
)
(
	input             clk,      // clk_ram, with spi_nvram and the arbiters
	// The state machine only. The ARRAY deliberately survives reset: it is the
	// battery-backed part, and it is loaded from the save file while the rest
	// of the core is still held down. Same contract as spi_ds2404's SRAM.
	input             reset,
	// Stop the write timer with the rest of the board while a savestate is
	// taken. It is the one thing in here that advances without the 386 asking,
	// which is the same reason spi_ds2404 gates its RTC tick.
	input             pause,

	// ---- the three host lines, as levels from clk_cpu -------------------
	input             cs,
	input             sk,
	input             di,
	output            dout,     // DO, as the game sees it at 0x60C bit 6

	// ---- the save file (spi_nvram, clk_ram) -----------------------------
	// A byte port over the 128 bytes, little-endian per word, so the stream is
	// MAME's nvram file unchanged.
	// The FACTORY default, written straight out of rom_loader as the MRA's
	// st93c46.bin part streams past (M_EEDEF). It lands before the save file,
	// which is the right precedence: a player's settings must beat the
	// factory's, and MiSTer sends the save file after the ROM image.
	input       [6:0] ld_addr,
	input       [7:0] ld_din,
	input             ld_we,

	input       [6:0] nv_addr,
	input       [7:0] nv_din,
	input             nv_we,
	output      [7:0] nv_dout,
	output reg        nv_dirty,

	// ---- the savestate ---------------------------------------------------
	// Two dwords of machine state, and the array as its own section through the
	// same byte-port shape spi_ds2404 uses for its SRAM.
	input       [1:0] ss_addr,
	input      [31:0] ss_din,
	input             ss_we,
	output     [31:0] ss_dout,
	input       [6:0] ss_ram_addr,
	input       [7:0] ss_ram_din,
	input             ss_ram_we,
	output      [7:0] ss_ram_dout
);

	// ------------------------------------------------------------------
	// States, mirroring eepromser.cpp's own names so the two read side by side.
	// ------------------------------------------------------------------
	localparam [2:0] S_RESET      = 3'd0;   // IN_RESET
	localparam [2:0] S_WAIT_START = 3'd1;   // WAIT_FOR_START_BIT
	localparam [2:0] S_WAIT_CMD   = 3'd2;   // WAIT_FOR_COMMAND
	localparam [2:0] S_READ       = 3'd3;   // READING_DATA
	localparam [2:0] S_WAIT_DATA  = 3'd4;   // WAIT_FOR_DATA
	localparam [2:0] S_WAIT_DONE  = 3'd5;   // WAIT_FOR_COMPLETION
	localparam [2:0] S_SWEEP      = 3'd6;   // ERAL / WRAL walking the array

	localparam [2:0] C_NONE  = 3'd0;        // EWEN / EWDS -- touches no cell
	localparam [2:0] C_READ  = 3'd1;
	localparam [2:0] C_WRITE = 3'd2;
	localparam [2:0] C_ERASE = 3'd3;
	localparam [2:0] C_WRALL = 3'd4;
	localparam [2:0] C_ERALL = 3'd5;

	// eepromser.cpp:623. Opcode 0 is not a command but an escape: the top two
	// ADDRESS bits pick between the four control operations. So only the top
	// four bits decide anything; the rest of the address rides separately.
	function automatic [2:0] decode_of(input [3:0] hi);
		case (hi[3:2])
			2'd0: case (hi[1:0])
				2'd1:    decode_of = C_WRALL;
				2'd2:    decode_of = C_ERALL;
				default: decode_of = C_NONE;   // 0 = EWDS, 3 = EWEN
			endcase
			2'd1:    decode_of = C_WRITE;
			2'd2:    decode_of = C_READ;
			default: decode_of = C_ERASE;
		endcase
	endfunction

	// ------------------------------------------------------------------
	// The array, and the one write port everything funnels through
	// ------------------------------------------------------------------
	// TWO BYTE LANES, not one 16-bit array, and the reason is spi_mainram.sv's:
	// "Split into four byte lanes to get byte enables; Quartus infers M10K from
	// this shape." A bit-select write -- `mem[a][15:8] <= x` -- is what stops it
	// considering the array at all. Measured: with one 16-bit array and
	// registered reads, the fit report showed `mem[0][8]` as a discrete register
	// and RAM blocks did not move, which is how this was found rather than
	// guessed at a second time.
	reg [7:0] mem_lo [0:63];
	reg [7:0] mem_hi [0:63];

	// A BLANK PART IS ALL ONES, and this is not cosmetic. MAME's
	// `nvram_default()` fills with `m_default_value_set ? m_default_value : ~0`
	// (eeprom.cpp) -- an erased EEPROM cell reads 1, which is also why ERASE
	// writes 0xFFFF and why the datasheet wants ERAL before WRAL. Power up at
	// zero instead and the first boot with no save file hands the game 128
	// bytes of zeroes where hardware and MAME both hand it 0xFF.
	//
	// Found by simulation, not by reading: rdft2us booted to a black screen and
	// spun, 94 frames with no DMA of any kind, because a zeroed EEPROM fails
	// whatever the game checks before it will draw. An `initial` block is how
	// Quartus states a power-up value for an inferred array, and it is what the
	// save file then overwrites.
	integer i;
	initial for (i = 0; i < 64; i = i + 1) begin
		mem_lo[i] = 8'hFF;  mem_hi[i] = 8'hFF;
	end

	reg        eng_we;
	reg  [5:0] eng_addr;
	reg [15:0] eng_data;

	// Three write sources, none of which can be live at the same time as
	// another: the loader runs before the board leaves reset, the save file
	// after it and still under nv_hold, and the savestate only when paused.
	wire       byte_we   = ld_we | nv_we | ss_ram_we;
	wire [6:0] byte_addr = ld_we ? ld_addr : nv_we ? nv_addr : ss_ram_addr;
	wire [7:0] byte_din  = ld_we ? ld_din  : nv_we ? nv_din  : ss_ram_din;

	// Every write below is a WHOLE byte into one lane, which is the shape that
	// infers. The save file and the savestate address a byte at a time; the
	// engine writes a word, which is one byte into each lane.
	wire       wr_lo = (byte_we && !byte_addr[0]) || eng_we;
	wire       wr_hi = (byte_we &&  byte_addr[0]) || eng_we;
	wire [5:0] wa_lo = byte_we ? byte_addr[6:1] : eng_addr;
	wire [5:0] wa_hi = wa_lo;
	wire [7:0] wd_lo = byte_we ? byte_din : eng_data[7:0];
	wire [7:0] wd_hi = byte_we ? byte_din : eng_data[15:8];

	always @(posedge clk) begin
		if (wr_lo) mem_lo[wa_lo] <= wd_lo;
		if (wr_hi) mem_hi[wa_hi] <= wd_hi;
	end

	// THREE REGISTERED READ PORTS. Registered is the whole point: it is what
	// makes Quartus infer an M10K instead of building the array out of flops
	// with a combinational mux in front of each reader. Quartus replicates the
	// array per read port, which at 1 Kbit costs blocks that were free and ALMs
	// that were not.
	//
	// The engine's port serves two addresses. In S_READ it holds `addr`, which
	// was latched at the command's eighth bit -- many host writes before the
	// first clock edge that needs the word, so it has long settled. In S_SWEEP
	// it walks `sweep`, one address per cycle, and the write lags it by one.
	wire [5:0] eng_rd_addr = (state == S_SWEEP) ? sweep : addr;

	// ONE byte read port, shared by the save file and the savestate, plus the
	// engine's word port. Every read port over a 64-entry flop array is a 64:1
	// mux per lane, and those muxes -- not the 1024 storage bits -- are what this
	// module costs. Three ports meant six of them.
	//
	// Sharing is safe because the two consumers cannot be live together: a
	// savestate section is read with the board PAUSED, and the save file is
	// uploaded while it runs. `pause` is right here to say which. The engine
	// keeps its own port because an EEPROM read takes milliseconds of host
	// writes and a save-file upload streams 128 bytes through the middle of one
	// often, not rarely -- that pair really would collide.
	wire [6:0] byte_ra = pause ? ss_ram_addr : nv_addr;

	reg [7:0]  byte_ql, byte_qh, word_ql, word_qh;
	reg        byte_hi_r;
	always @(posedge clk) begin
		byte_ql <= mem_lo[byte_ra[6:1]];  byte_qh <= mem_hi[byte_ra[6:1]];
		word_ql <= mem_lo[eng_rd_addr];   word_qh <= mem_hi[eng_rd_addr];
		// The byte select travels with the data, not the address: what came back
		// is last cycle's word.
		byte_hi_r <= byte_ra[0];
	end

	wire [15:0] word_q  = {word_qh, word_ql};
	wire  [7:0] byte_q  = byte_hi_r ? byte_qh : byte_ql;
	assign nv_dout      = byte_q;
	assign ss_ram_dout  = byte_q;

	// ------------------------------------------------------------------
	// Input synchronisers. The second copy is the edge detector's reference,
	// not a metastability stage -- see the header on why one hop is enough.
	// ------------------------------------------------------------------
	reg cs_r, sk_r, di_r, cs_q, sk_q;
	always @(posedge clk) begin
		cs_r <= cs;   sk_r <= sk;   di_r <= di;
		cs_q <= cs_r; sk_q <= sk_r;
	end

	wire cs_rise = cs_r & ~cs_q;
	wire cs_fall = ~cs_r & cs_q;
	wire sk_rise = sk_r & ~sk_q;

	// ------------------------------------------------------------------
	// The engine
	// ------------------------------------------------------------------
	reg  [2:0] state;
	reg  [2:0] cmd;
	reg  [7:0] accum;      // 2 opcode + 6 address bits
	reg  [4:0] bits;
	// 32 bits, not 16, and that is not slack. MAME loads `word << 16` into a
	// 32-bit register and reads bit 31 (eepromser.cpp:421), so a read that is
	// clocked past its sixteenth bit emits SIXTEEN ZEROES before the ones
	// arrive. That is reachable: MAME only warns about an overclocked read past
	// `m_data_bits + 1`, so a seventeenth clock is normal and its bit is a 0. A
	// 16-bit register here would put a 1 there instead. tb_93c46's overclock
	// test is what makes the difference visible.
	reg [31:0] shift;
	reg  [5:0] addr;
	reg        locked;
	reg  [5:0] sweep, sweep_w;
	reg        sweep_go;

	// The write-completion timer. MAME's four operation times (eeprom.cpp:41-45)
	// in clk cycles; `ready` is what DO reports while the chip waits for a start
	// bit, and what gates accepting one.
	localparam int T_WRITE     = 1750 * CLK_MHZ;
	localparam int T_WRITE_ALL = 8000 * CLK_MHZ;
	localparam int T_ERASE     = 1000 * CLK_MHZ;
	localparam int T_ERASE_ALL = 8000 * CLK_MHZ;
	localparam int BW = $clog2(T_WRITE_ALL + 1);

	reg [BW-1:0] busy;
	wire         ready = (busy == {BW{1'b0}});

	// DO is 1 in every state but S_READ, where it is the shift register's top
	// bit. Entering S_READ with shift = 0 is what produces the leading dummy
	// zero the datasheet promises.
	// eepromser.cpp:658, the 93cxx override: the shift register's top bit while a
	// word is going out, the write-completion status while waiting for a start
	// bit, 1 everywhere else.
	assign dout = (state == S_READ)       ? shift[31]
	            : (state == S_WAIT_START) ? ready
	                                      : 1'b1;

	// The command+address as it will be once this edge's bit has landed.
	wire [7:0] ca_now = {accum[6:0], di_r};
	wire [2:0] cmd_now = decode_of(ca_now[7:4]);

	always @(posedge clk) begin
		eng_we <= 1'b0;
		// The write timer is the one thing in here that advances without the 386
		// asking, so it is the one thing `pause` stops. A load below overrides
		// this, being the later assignment.
		if (!pause && !ready) busy <= busy - {{(BW-1){1'b0}}, 1'b1};

		if (reset) begin
			state    <= S_RESET;
			cmd      <= C_NONE;
			accum    <= 8'd0;
			bits     <= 5'd0;
			shift    <= 32'd0;
			addr     <= 6'd0;
			sweep    <= 6'd0;
			sweep_w  <= 6'd0;
			sweep_go <= 1'b0;
			// MAME's m_locked starts TRUE, so a game that forgets its EWEN
			// writes nothing. That is what protects the save file, and it is the
			// wrong default to "fix".
			locked   <= 1'b1;
			nv_dirty <= 1'b0;
			busy     <= {BW{1'b0}};
		end else if (ss_we) begin
			// Savestate restore. `shift` and `accum` come back with the rest
			// because a state can be taken mid-command.
			case (ss_addr)
			2'd0: shift <= ss_din;
			2'd2: busy  <= ss_din[BW-1:0];
			default: begin
				sweep  <= ss_din[31:26];
				locked <= ss_din[25];
				cmd    <= ss_din[24:22];
				addr   <= ss_din[21:16];
				accum  <= ss_din[15:8];
				bits   <= ss_din[7:3];
				state  <= ss_din[2:0];
			end
			endcase
		end else begin
			if (byte_we) nv_dirty <= 1'b0;   // a load is not a change

			// The ERAL/WRAL sweep is checked FIRST, and deliberately ignores
			// the host lines while it runs. MAME does the whole array inside
			// write_all()/erase_all(), so the operation is atomic there; the
			// real part is likewise busy internally for its 8 ms whether or not
			// CS is still asserted. Letting a CS fall abort it leaves the array
			// part-written -- five words in, at this module's clock -- which is
			// exactly the bug the WRAL test in tb_93c46 caught.
			if (state == S_SWEEP) begin
				// Two stages, because the read port is registered now: the
				// address walks here and `word_q` catches up one cycle later,
				// so the write is issued against the PREVIOUS address. ERALL
				// does not read at all, but runs the same pipeline rather than
				// carrying a second path for the sake of one cycle.
				sweep    <= sweep + 6'd1;
				sweep_w  <= sweep;
				sweep_go <= 1'b1;
				if (sweep_go) begin
					eng_we   <= 1'b1;
					eng_addr <= sweep_w;
					eng_data <= (cmd == C_ERALL) ? 16'hFFFF
					                             : (word_q & shift[15:0]);
					nv_dirty <= 1'b1;
				end
				// Ending in S_RESET rather than S_WAIT_DONE because the CS fall
				// that would have taken us there may already have happened and
				// been ignored. Both states are inert until a fresh CS rise, so
				// the two are equivalent from outside.
				if (sweep_go && sweep_w == 6'd63) begin
					busy  <= (cmd == C_ERALL) ? BW'(T_ERASE_ALL) : BW'(T_WRITE_ALL);
					// The sweep ignores the host lines while it runs, so a CS
					// fall AND the next CS rise can both happen inside it -- the
					// game drops CS the moment it has sent the last data bit and
					// raises it again to poll. Landing in S_RESET would then wait
					// for a rise that has already been and gone, and the poll
					// would hang. Finish in whichever state the CURRENT level
					// implies, which is what MAME reaches by handling those two
					// edges as they arrive.
					state <= cs_r ? S_WAIT_START : S_RESET;
				end

			// CS falling resets from any other state, and is considered before
			// anything else -- eepromser.cpp does this in every arm of its
			// switch.
			end else if (cs_fall) begin
				state <= S_RESET;
			end else if (cs_rise) begin
				// The rising CS edge moves us on, and a clock edge arriving in
				// the SAME cycle is ignored: MAME's
				// `machine().time() > m_last_cs_rising_edge_time` guard. The 386
				// writes all three lines in one store to 0x68E, so this is not a
				// corner case, it is the normal first write of every command.
				state <= S_WAIT_START;
				bits  <= 5'd0;
				accum <= 8'd0;
			end else begin
				case (state)
					S_RESET: ;                       // waits for cs_rise, above

					S_WAIT_START:
						// `&& ready` is MAME's guard: a command issued before
						// the previous write finished is silently dropped, not
						// queued.
						if (sk_rise && di_r && ready) begin
							accum <= 8'd0;
							bits  <= 5'd0;
							state <= S_WAIT_CMD;
						end

					S_WAIT_CMD:
						if (sk_rise) begin
							accum <= ca_now;
							bits  <= bits + 5'd1;
							if (bits == 5'd7) begin
								bits <= 5'd0;
								cmd  <= cmd_now;
								addr <= ca_now[5:0];
								case (cmd_now)
									C_READ: begin
										// shift = 0 is the leading dummy zero.
										shift <= 32'd0;
										state <= S_READ;
									end
									C_WRITE, C_WRALL: begin
										shift <= 32'd0;
										state <= S_WAIT_DATA;
									end
									C_ERASE:
										if (locked) state <= S_RESET;
										else begin
											eng_we   <= 1'b1;
											eng_addr <= ca_now[5:0];
											eng_data <= 16'hFFFF;
											nv_dirty <= 1'b1;
											busy     <= BW'(T_ERASE);
											state    <= S_WAIT_DONE;
										end
									C_ERALL:
										if (locked) state <= S_RESET;
										else begin
											sweep <= 6'd0; sweep_go <= 1'b0;
											state <= S_SWEEP;
										end
									default: begin
										// EWEN / EWDS. Neither touches a cell;
										// bits [5:4] say which.
										locked <= (ca_now[5:4] == 2'd0);
										state  <= S_RESET;
									end
								endcase
							end
						end

					S_READ:
						if (sk_rise) begin
							// The first edge loads the word, the rest shift ones
							// in. MAME shifts a 32-bit register and reads bit 31;
							// a 16-bit one read at bit 15 is the same sequence.
							// `bits` SATURATES rather than wrapping: with
							// streaming disabled only bit_index 0 ever reloads,
							// so an overclocked read must go on shifting ones and
							// must not come back round to the word.
							if (bits == 5'd0) shift <= {word_q, 16'd0};
							else              shift <= {shift[30:0], 1'b1};
							if (bits != 5'd31) bits <= bits + 5'd1;
						end

					S_WAIT_DATA:
						if (sk_rise) begin
							shift <= {shift[30:0], di_r};
							bits  <= bits + 5'd1;
							if (bits == 5'd15) begin
								bits <= 5'd0;
								// `locked` is checked HERE and not at decode
								// time, matching execute_write_command(): the
								// data is clocked in either way and only the
								// store is refused.
								if (locked) state <= S_RESET;
								else if (cmd == C_WRITE) begin
									eng_we   <= 1'b1;
									eng_addr <= addr;
									eng_data <= {shift[14:0], di_r};   // the low 16
									nv_dirty <= 1'b1;
									busy     <= BW'(T_WRITE);
									state    <= S_WAIT_DONE;
								end else begin
									sweep <= 6'd0; sweep_go <= 1'b0;      // WRAL
									state <= S_SWEEP;
								end
							end
						end

					S_WAIT_DONE: ;                   // waits for cs_fall, above

					default: state <= S_RESET;
				endcase
			end
		end
	end

	assign ss_dout = (ss_addr == 2'd0) ? shift
	               : (ss_addr == 2'd2) ? {{(32-BW){1'b0}}, busy}
	                                   : {sweep, locked, cmd, addr, accum, bits, state};

endmodule
