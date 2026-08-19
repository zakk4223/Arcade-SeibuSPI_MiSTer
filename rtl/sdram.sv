//
// sdram
// Copyright (c) 2015-2019 Sorgelig
//
// Some parts of SDRAM code used from project:
// http://hamsterworks.co.nz/mediawiki/index.php/Simple_SDRAM_Controller
//
// This source file is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This source file is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.
//
// ---------------------------------------------------------------------------
// SeibuSPI notes
//
// Vendored from Arcade-IGSPGM_MiSTer (5-channel variant). Local changes:
//   - refresh constants retuned for the 114.545455 MHz clk_ram used here.
//   - ch1 widened from 32 to 64 bits. It carries the 386's program ROM, and the
//     z386 caches fill 16-byte lines, so 64-bit reads make that two requests
//     rather than four. Costs 3 cycles of extra latency per access (ch1 used to
//     ack early, after two words); irrelevant for a line fill that needs all
//     four words anyway.
//
// Address mapping (per chip):
//   column = addr[9:1]   row = addr[22:10]   bank = addr[24:23]   chip = addr[26]
// addr[25] lands on A[9], which is a don't-care on the 512-column parts used by
// the usual 32 MB modules, so the usable range is addr[24:0] = 32 MB. The core's
// SDRAM map tops out at 0x1680000 (22.5 MB), comfortably inside that.
//
// Requests are toggle-based: flip ch*_req, wait for ch*_ack to match. Reads burst
// 4 x 16 bits and WRAP inside the aligned 8-byte column group, so every 64-bit
// read must be 8-byte aligned.
//
// Channel map for this core:
//   ch1  386 program ROM     ch2  tile / char graphics
//   ch3  ROM download, then Z80 program fetch (the only writable channel)
//   ch4  sprite graphics     ch5  YMF271 PCM samples
// Main RAM is on-chip, not here.
// ---------------------------------------------------------------------------

module sdram
#(
    // ch5 (YMF271 PCM) is unused until the sound core lands. Synthesising it
    // costs a level in the STATE_IDLE priority mux that feeds SDRAM_A and 64
    // more registers fanning off dq_reg, which is exactly where clk_ram was
    // failing setup. Set to 1 when T5 needs it.
    parameter USE_CH5 = 0
)
(
    input             init,        // reset to initialize RAM
    input             clk,         // clock 114.545455 MHz (clk_ram)

    input             doRefresh,

    // ---- the watch (PLAN.md 19.12) ------------------------------------
    // 19.12 put the sample flash's lost byte at this module's door: the write
    // is issued with the right address and lane, the arbiter latches it, and
    // it is not in memory afterwards. This is the other side of that door.
    //
    // For the first two ch3 WRITES to the watched halfword it records what
    // went on the bus -- data and byte masks -- and then what this controller
    // did in the four clocks after each, because STATE_RW1 issues CMD_WRITE
    // with auto-precharge and can be back at STATE_IDLE three clocks later,
    // against a tWR + tRP the part wants nearer four. Within one bank that
    // truncates the write; across banks it is harmless, which is why this
    // records the BANK of the write and of the next ACTIVE.
    //
    // Two entries, because the updater writes that halfword TWICE, one lane
    // each, and only the first byte goes missing. Same run, same address, one
    // lands and one does not -- so whatever differs between the two entries is
    // the fault, and the second entry is the control.
    output reg  [7:0] dbg_s_takes,    // watched ch3 writes taken in IDLE
    output reg  [7:0] dbg_s_writes,   // ...that reached CMD_WRITE
    output reg  [7:0] dbg_s_same,     // ...followed by a SAME-bank ACTIVE
    output reg  [1:0] dbg_s_wbank,
    output reg        dbg_s_wchip,
    output reg [15:0] dbg_s_e0_dq,
    output reg  [1:0] dbg_s_e0_dqm,   // as driven on A[12:11]; 1 = masked
    output reg  [3:0] dbg_s_e0_gap,   // clocks from the write to the next ACTIVE
    output reg  [1:0] dbg_s_e0_ab,    // that ACTIVE's bank
    output reg        dbg_s_e0_ac,
    output reg [14:0] dbg_s_e0_after, // the write, then four clocks of bus
    output reg [15:0] dbg_s_e1_dq,
    output reg  [1:0] dbg_s_e1_dqm,
    output reg  [3:0] dbg_s_e1_gap,
    output reg  [1:0] dbg_s_e1_ab,
    output reg        dbg_s_e1_ac,
    output reg [14:0] dbg_s_e1_after,

    inout      [15:0] SDRAM_DQ,    // 16 bit bidirectional data bus
    output reg [12:0] SDRAM_A,     // 13 bit multiplexed address bus
    output            SDRAM_DQML,  // two byte masks
    output            SDRAM_DQMH,  //
    output reg  [1:0] SDRAM_BA,    // two banks
    output            SDRAM_nCS,   // a single chip select
    output            SDRAM_nWE,   // write enable
    output            SDRAM_nRAS,  // row address select
    output            SDRAM_nCAS,  // columns address select
    output            SDRAM_CKE,   // clock enable
    output            SDRAM_CLK,   // clock for chip

    input      [26:0] ch1_addr,    // 25 bit address for 8bit mode. addr[0] = 0 for 16bit mode for correct operations.
    output reg [63:0] ch1_dout,    // data output to cpu
    input             ch1_req,     // request
    output reg        ch1_ack,

    input      [26:0] ch2_addr,
    output reg [63:0] ch2_dout,
    input             ch2_req,
    output reg        ch2_ack,

    input      [26:0] ch3_addr,
    output reg [63:0] ch3_dout,
    input      [15:0] ch3_din,
    input      [ 1:0] ch3_be,
    input             ch3_req,
    input             ch3_rnw,     // 1 - read, 0 - write
    output reg        ch3_ack,

    input      [26:0] ch4_addr,
    output reg [63:0] ch4_dout,
    input             ch4_req,
    output reg        ch4_ack,

    input      [26:0] ch5_addr,
    output reg [63:0] ch5_dout,
    input             ch5_req,
    output reg        ch5_ack
);

assign SDRAM_nCS  = chip;
assign SDRAM_nRAS = command[2];
assign SDRAM_nCAS = command[1];
assign SDRAM_nWE  = command[0];
assign SDRAM_CKE  = 1;
assign {SDRAM_DQMH,SDRAM_DQML} = SDRAM_A[12:11];

// THE DQ OUTPUT: a continuous assign off a registered value and a registered
// enable, rather than a registered `inout` defaulting to 16'bZ.
//
// The two are the same hardware -- a flop for the data and a flop for the output
// enable, which is what the synthesiser inferred from the old form anyway -- but
// only this one SIMULATES. Verilator resolved the clocked `SDRAM_DQ <= 16'bZ` as
// a strong all-ones driver that won the net, so sim/sdram_model.sv's read data
// never reached dq_reg and every readback in tb_sdram came back 0xFF, on RTL
// nobody had changed. Proved rather than guessed: making the model drive 0x0000
// instead of Z when idle changed nothing, so it was this side winning the net,
// not the model losing it (PLAN.md 28).
reg [15:0] dq_drv;
reg        dq_oe;
assign SDRAM_DQ = dq_oe ? dq_drv : 16'bZ;


// Burst length = 4
localparam BURST_LENGTH        = 4;
localparam BURST_CODE          = (BURST_LENGTH == 8) ? 3'b011 : (BURST_LENGTH == 4) ? 3'b010 : (BURST_LENGTH == 2) ? 3'b001 : 3'b000;  // 000=1, 001=2, 010=4, 011=8
localparam ACCESS_TYPE         = 1'b0;     // 0=sequential, 1=interleaved
localparam CAS_LATENCY         = 3'd3;     // 2 for < 100MHz, 3 for >100MHz
localparam OP_MODE             = 2'b00;    // only 00 (standard operation) allowed
localparam NO_WRITE_BURST      = 1'b1;     // 0= write burst enabled, 1=only single access write
localparam MODE                = {3'b000, NO_WRITE_BURST, OP_MODE, CAS_LATENCY, ACCESS_TYPE, BURST_CODE};

localparam sdram_startup_cycles= 14'd12100;// 105us @ 114.545MHz (spec needs 100us)
localparam cycles_per_refresh  = 14'd880;  // (64ms/8192) * 114.545MHz = 894, with margin
localparam startup_refresh_max = 14'b11111111111111;

// SDRAM commands
wire [2:0] CMD_NOP             = 3'b111;
wire [2:0] CMD_ACTIVE          = 3'b011;
wire [2:0] CMD_READ            = 3'b101;
wire [2:0] CMD_WRITE           = 3'b100;
wire [2:0] CMD_PRECHARGE       = 3'b010;
wire [2:0] CMD_AUTO_REFRESH    = 3'b001;
wire [2:0] CMD_LOAD_MODE       = 3'b000;

reg [13:0] refresh_count = startup_refresh_max - sdram_startup_cycles;
reg  [2:0] command;
reg        chip;

localparam STATE_STARTUP = 0;
localparam STATE_WAIT    = 1;
localparam STATE_RW1     = 2;
localparam STATE_IDLE    = 4;
localparam STATE_IDLE_1  = 5;
localparam STATE_IDLE_2  = 6;
localparam STATE_IDLE_3  = 7;
localparam STATE_IDLE_4  = 8;
localparam STATE_IDLE_5  = 9;
localparam STATE_RFSH    = 10;


// The watched halfword (PLAN.md 19.12): byte 0x2829FE, which is
// SDR_PCM_BASE + 0x29FE. ch3 addresses arrive as bytes and are used from bit 1
// up, so this is the byte address shifted down one.
localparam [26:1] WATCH_HW = 26'h1414FF;

always @(posedge clk) begin
    reg [CAS_LATENCY+BURST_LENGTH+1:0] data_ready_delay1, data_ready_delay2, data_ready_delay3, data_ready_delay4, data_ready_delay5;

    reg        saved_wr;
    reg [12:0] cas_addr;
    reg [15:0] saved_data;
    // ONE capture register, shared by every channel -- do not duplicate it.
    // It sits directly on the DQ input path and belongs in the I/O cell. Splitting
    // it per channel (to chase a reported -0.054 ns fabric slack) let the fitter
    // drag copies out towards their consumers, which destroyed the input timing:
    // the first 16-bit word of every burst read came back as unstable garbage.
    // Reference cores run this same register single at 120 MHz.
    reg [15:0] dq_reg;
    // Fabric copy of the capture register, one cycle behind, and the ONLY thing
    // the channel dout registers read. dq_reg drives 5 channels x 64 bits = 320
    // flops spread across the die; with the capture register sitting in the I/O
    // cell the fitter cannot place that net well, and clk_ram was failing setup
    // on dq_reg -> chN_dout with literally no logic in the path -- pure routing.
    //
    // This is NOT the mistake above. That one duplicated dq_reg ITSELF per
    // channel and let the fitter pull the capture out of the I/O cell, which
    // destroyed the DQ input timing. Here dq_reg is untouched and still single;
    // the fanout moves to a plain fabric register with no I/O constraint, which
    // is free to be placed near its consumers. Every data_ready tap shifts one
    // position later to pay for the extra cycle.
    reg [15:0] dq_reg_d;
    reg  [3:0] state = STATE_STARTUP;

    // The emergency-refresh test, one cycle old. It used to be a live 14-bit
    // magnitude compare sitting at the TOP of the STATE_IDLE priority chain,
    // so refresh_count[12] -> SDRAM_A[11] was the whole address mux deep and
    // was the last endpoint failing clk_ram setup. Registering it is free: the
    // threshold is on a counter that takes 880 cycles to reach it, so firing
    // one cycle later changes nothing, and refresh_count is corrected by
    // subtraction rather than by being cleared.
    reg       refresh_due;
    reg       ch1_req_1, ch2_req_1, ch3_req_1, ch4_req_1, ch5_req_1;
    reg       ch1_rq, ch2_rq, ch3_rq, ch4_rq, ch5_rq;
    reg [2:0] ch;

    reg [26:1] ch1_addr_1, ch2_addr_1, ch3_addr_1, ch4_addr_1, ch5_addr_1;

    reg        ch3_rnw_1;
    reg [15:0] ch3_din_1;
    reg [ 1:0] ch3_be_1;

    reg        doRefresh_1;

    // The watch's own state (PLAN.md 19.12).
    reg        w_taken;      // the transaction in flight is the watched one
    reg  [3:0] w_run;        // cycles left in the window after CMD_WRITE
    reg        w_cur;        // which entry the window is filling
    reg  [1:0] w_idx;        // entries filled so far, saturating
    // The ROM loader fills this whole region with blank flash at download
    // time, one BYTE at a time, through this same channel -- so the first two
    // byte writes to the watched halfword are its, not the updater's, and they
    // ate both entries first time out. The sweep that erases the halfword sits
    // between the two, so arming on it takes the updater's writes and nothing
    // else. (The loader never writes both masks at once, which is what makes
    // the sweep distinguishable here.)
    reg        w_armed;
    // The address compare, registered off the RAW input alongside ch3_addr_1
    // so the two are the same vintage. Combinationally in the ch3 branch it put
    // a 26-bit comparator in the chain driving SDRAM_A and cost the build the
    // 0.087 ns it did not have; registered off ch3_addr_1 instead it describes
    // the address from BEFORE the request, and counted 2 writes to a halfword
    // that gets 5.
    reg        ch3_watch_r;

    ch1_req_1 <= ch1_req;
    ch2_req_1 <= ch2_req;
    ch3_req_1 <= ch3_req;
    ch4_req_1 <= ch4_req;
    ch5_req_1 <= ch5_req;

    ch3_rnw_1  <= ch3_rnw;
    ch3_addr_1 <= ch3_addr[26:1];
    ch3_din_1  <= ch3_din;
    ch3_be_1   <= ch3_be;

    ch1_addr_1 <= ch1_addr[26:1];
    ch2_addr_1 <= ch2_addr[26:1];
    ch4_addr_1 <= ch4_addr[26:1];
    ch5_addr_1 <= ch5_addr[26:1];

    doRefresh_1 <= doRefresh;
    ch3_watch_r <= (ch3_addr[26:1] == WATCH_HW) && ~ch3_rnw;

    if (ch1_req != ch1_req_1) ch1_rq <= 1;
    if (ch2_req != ch2_req_1) ch2_rq <= 1;
    if (ch3_req != ch3_req_1) ch3_rq <= 1;
    if (ch4_req != ch4_req_1) ch4_rq <= 1;
    if (USE_CH5 && (ch5_req != ch5_req_1)) ch5_rq <= 1;

    refresh_count <= refresh_count+1'b1;
    refresh_due   <= (refresh_count > cycles_per_refresh);

    data_ready_delay1 <= data_ready_delay1>>1;
    data_ready_delay2 <= data_ready_delay2>>1;
    data_ready_delay3 <= data_ready_delay3>>1;
    data_ready_delay4 <= data_ready_delay4>>1;
    data_ready_delay5 <= data_ready_delay5>>1;

    dq_reg   <= SDRAM_DQ;
    dq_reg_d <= dq_reg;

    if(data_ready_delay1[3]) ch1_dout[15:00] <= dq_reg_d;
    if(data_ready_delay1[2]) ch1_dout[31:16] <= dq_reg_d;
    if(data_ready_delay1[1]) ch1_dout[47:32] <= dq_reg_d;
    if(data_ready_delay1[0]) ch1_dout[63:48] <= dq_reg_d;
    if(data_ready_delay1[0]) ch1_ack <= ch1_req;

    if(data_ready_delay2[3]) ch2_dout[15:00] <= dq_reg_d;
    if(data_ready_delay2[2]) ch2_dout[31:16] <= dq_reg_d;
    if(data_ready_delay2[1]) ch2_dout[47:32] <= dq_reg_d;
    if(data_ready_delay2[0]) ch2_dout[63:48] <= dq_reg_d;
    if(data_ready_delay2[0]) ch2_ack <= ch2_req;

    if(data_ready_delay3[3]) ch3_dout[15:00] <= dq_reg_d;
    if(data_ready_delay3[2]) ch3_dout[31:16] <= dq_reg_d;
    if(data_ready_delay3[1]) ch3_dout[47:32] <= dq_reg_d;
    if(data_ready_delay3[0]) ch3_dout[63:48] <= dq_reg_d;
    if(data_ready_delay3[0]) ch3_ack <= ch3_req;

    if(data_ready_delay4[3]) ch4_dout[15:00] <= dq_reg_d;
    if(data_ready_delay4[2]) ch4_dout[31:16] <= dq_reg_d;
    if(data_ready_delay4[1]) ch4_dout[47:32] <= dq_reg_d;
    if(data_ready_delay4[0]) ch4_dout[63:48] <= dq_reg_d;
    if(data_ready_delay4[0]) ch4_ack <= ch4_req;

    if(data_ready_delay5[3]) ch5_dout[15:00] <= dq_reg_d;
    if(data_ready_delay5[2]) ch5_dout[31:16] <= dq_reg_d;
    if(data_ready_delay5[1]) ch5_dout[47:32] <= dq_reg_d;
    if(data_ready_delay5[0]) ch5_dout[63:48] <= dq_reg_d;
    if(data_ready_delay5[0]) ch5_ack <= ch5_req;

    // Default: not driving. STATE_RW1 overrides it for a write, exactly as the
    // old `SDRAM_DQ <= 16'bZ` default did.
    dq_oe <= 1'b0;

    // The watch window. Ahead of the case statement so that a new CMD_WRITE
    // arming it beats this cycle's decrement. `w_run` counts 5 down to 1, so
    // the age of what is on the bus is 5 - w_run: age 0 is the write itself,
    // and the earliest an ACTIVE can follow is age 3.
    if (|w_run) begin
        w_run <= w_run - 4'd1;
        if (!w_cur) begin
            dbg_s_e0_after <= {dbg_s_e0_after[11:0], command};
            if (w_run == 4'd5) begin
                dbg_s_e0_dq  <= saved_data;
                dbg_s_e0_dqm <= SDRAM_A[12:11];
            end
            if (command == CMD_ACTIVE && dbg_s_e0_gap == 4'd0) begin
                dbg_s_e0_gap <= 4'd5 - w_run;
                dbg_s_e0_ab  <= SDRAM_BA;
                dbg_s_e0_ac  <= chip;
                if (SDRAM_BA == dbg_s_wbank && chip == dbg_s_wchip)
                    dbg_s_same <= dbg_s_same + 8'd1;
            end
        end
        else begin
            dbg_s_e1_after <= {dbg_s_e1_after[11:0], command};
            if (w_run == 4'd5) begin
                dbg_s_e1_dq  <= saved_data;
                dbg_s_e1_dqm <= SDRAM_A[12:11];
            end
            if (command == CMD_ACTIVE && dbg_s_e1_gap == 4'd0) begin
                dbg_s_e1_gap <= 4'd5 - w_run;
                dbg_s_e1_ab  <= SDRAM_BA;
                dbg_s_e1_ac  <= chip;
                if (SDRAM_BA == dbg_s_wbank && chip == dbg_s_wchip)
                    dbg_s_same <= dbg_s_same + 8'd1;
            end
        end
    end

    command <= CMD_NOP;
    case (state)
        STATE_STARTUP: begin
            SDRAM_A    <= 0;
            SDRAM_BA   <= 0;

            if (refresh_count == (startup_refresh_max-64)) chip <= 0;
            if (refresh_count == (startup_refresh_max-32)) chip <= 1;

            // All the commands during the startup are NOPS, except these
            if (refresh_count == startup_refresh_max-63 || refresh_count == startup_refresh_max-31) begin
                // ensure all rows are closed
                command     <= CMD_PRECHARGE;
                SDRAM_A[10] <= 1;  // all banks
                SDRAM_BA    <= 2'b00;
            end
            if (refresh_count == startup_refresh_max-55 || refresh_count == startup_refresh_max-23) begin
                // these refreshes need to be at least tREF (66ns) apart
                command     <= CMD_AUTO_REFRESH;
            end
            if (refresh_count == startup_refresh_max-47 || refresh_count == startup_refresh_max-15) begin
                command     <= CMD_AUTO_REFRESH;
            end
            if (refresh_count == startup_refresh_max-39 || refresh_count == startup_refresh_max-7) begin
                // Now load the mode register
                command     <= CMD_LOAD_MODE;
                SDRAM_A     <= MODE;
            end

            if (!refresh_count) begin
                state   <= STATE_IDLE;
                refresh_count <= 0;
                // Not redundant: refresh_due was computed a cycle ago from a
                // counter that runs UP to a wrap during startup, so without
                // this the very first idle cycle would see a stale 1 and fire
                // an emergency refresh against a zeroed counter -- which then
                // underflows and produces a burst of them.
                refresh_due   <= 1'b0;
            end
        end

        STATE_IDLE_5: state <= STATE_IDLE_4;
        STATE_IDLE_4: state <= STATE_IDLE_3;
        STATE_IDLE_3: state <= STATE_IDLE_2;
        STATE_IDLE_2: state <= STATE_IDLE_1;
        STATE_IDLE_1: state <= STATE_IDLE;

        STATE_RFSH: begin
            state    <= STATE_IDLE_5;
            command  <= CMD_AUTO_REFRESH;
            chip     <= 1;
        end

        STATE_IDLE: begin
            // TRIED AND REJECTED, 2026-08-17: hoisting `command <= CMD_ACTIVE` out
            // of the five channel arms below, so this endpoint saw a five-input
            // OR instead of the priority cascade. It is a correct
            // transformation -- the round-trip test passed, 0 of 23,592,960
            // bytes -- and it made timing WORSE, from -0.020 to -0.522 on this
            // very path. The reason is worth keeping: `ch*_rq -> command[1]` is
            // ROUTING dominated, not logic dominated. The five rq flags sit near
            // their own channel logic, and a flat OR forces all five to converge
            // at one gate in one level, where the cascade lets the fitter spread
            // their arrival across levels. Flattening a cascade helps only when
            // the depth is the cost. PLAN.md 28.3.
            if (refresh_due) begin // emergency refresh, mainly for downloading rom/paused core
                state         <= STATE_RFSH;
                command       <= CMD_AUTO_REFRESH;
                refresh_count <= refresh_count - cycles_per_refresh + 1'd1;
                refresh_due   <= 1'b0;
                chip          <= 0;
            end
            else if(ch2_rq) begin
                {cas_addr[12:9],SDRAM_BA,SDRAM_A,cas_addr[8:0]} <= {2'b00, 1'b1, ch2_addr_1[25:1]};
                chip       <= ch2_addr_1[26];
                saved_wr   <= 0;
                ch         <= 1;
                ch2_rq     <= 0;
                command    <= CMD_ACTIVE;
                state      <= STATE_WAIT;
            end
            else if(ch1_rq) begin
                {cas_addr[12:9],SDRAM_BA,SDRAM_A,cas_addr[8:0]} <= {2'b00, 1'b1, ch1_addr_1[25:1]};
                chip       <= ch1_addr_1[26];
                saved_wr   <= 0;
                ch         <= 0;
                ch1_rq     <= 0;
                command    <= CMD_ACTIVE;
                state      <= STATE_WAIT;
            end
            else if(ch4_rq) begin
                {cas_addr[12:9],SDRAM_BA,SDRAM_A,cas_addr[8:0]} <= {2'b00, 1'b1, ch4_addr_1[25:1]};
                chip       <= ch4_addr_1[26];
                saved_wr   <= 0;
                ch         <= 3;
                ch4_rq     <= 0;
                command    <= CMD_ACTIVE;
                state      <= STATE_WAIT;
            end
            else if(ch5_rq) begin
                {cas_addr[12:9],SDRAM_BA,SDRAM_A,cas_addr[8:0]} <= {2'b00, 1'b1, ch5_addr_1[25:1]};
                chip       <= ch5_addr_1[26];
                saved_wr   <= 0;
                ch         <= 4;
                ch5_rq     <= 0;
                command    <= CMD_ACTIVE;
                state      <= STATE_WAIT;
            end
            else if(ch3_rq) begin
                chip       <= ch3_addr_1[26];
                saved_data <= ch3_din_1;
                saved_wr   <= ~ch3_rnw_1;
                ch         <= 2;
                ch3_rq     <= 0;
                if (ch3_watch_r) begin
                    dbg_s_takes <= dbg_s_takes + 8'd1;
                    dbg_s_wbank <= ch3_addr_1[24:23];
                    dbg_s_wchip <= ch3_addr_1[26];
                    w_taken     <= 1'b1;
                end
                if (ch3_rnw_1)
                    {cas_addr[12:9],SDRAM_BA,SDRAM_A,cas_addr[8:0]} <= {2'b00, 1'b1, ch3_addr_1[25:1]};
                else
                    {cas_addr[12:9],SDRAM_BA,SDRAM_A,cas_addr[8:0]} <= {~ch3_be_1, 1'b1, ch3_addr_1[25:1]};
                command    <= CMD_ACTIVE;
                state      <= STATE_WAIT;
            end
            else if (doRefresh_1) begin
                state         <= STATE_RFSH;
                command       <= CMD_AUTO_REFRESH;
                refresh_count <= 0;
                refresh_due   <= 1'b0;
                chip          <= 0;
            end
        end

        STATE_WAIT: state <= STATE_RW1;
        STATE_RW1: begin
            SDRAM_A <= cas_addr;
            if(saved_wr) begin
                command  <= CMD_WRITE;
                dq_drv   <= saved_data;
                dq_oe    <= 1'b1;
                if (w_taken) begin
                    dbg_s_writes <= dbg_s_writes + 8'd1;
                    w_taken      <= 1'b0;
                    // Only BYTE writes get an entry. The erase sweep writes
                    // this halfword too, with both masks open, and it arrives
                    // first -- so counting it would spend one of the two slots
                    // on it and leave no control. cas_addr[12:11] is ~be, so
                    // 00 there is the sweep and anything else is a program.
                    // Later writes are ignored rather than overwriting the
                    // evidence.
                    if (cas_addr[12:11] == 2'b00) w_armed <= 1'b1;
                    if (w_armed && w_idx < 2'd2 && cas_addr[12:11] != 2'b00) begin
                        w_cur <= w_idx[0];
                        w_run <= 4'd5;
                        w_idx <= w_idx + 2'd1;
                    end
                end
                if(ch == 0) ch1_ack  <= ch1_req;
                if(ch == 1) ch2_ack  <= ch2_req;
                if(ch == 2) ch3_ack  <= ch3_req;
                if(ch == 3) ch4_ack  <= ch4_req;
                if(ch == 4) ch5_ack  <= ch5_req;
                state <= STATE_IDLE_2;
            end
            else begin
                command <= CMD_READ;
                state   <= STATE_IDLE_5;
                     if(ch == 0) data_ready_delay1[CAS_LATENCY+BURST_LENGTH+1] <= 1;
                else if(ch == 1) data_ready_delay2[CAS_LATENCY+BURST_LENGTH+1] <= 1;
                else if(ch == 2) data_ready_delay3[CAS_LATENCY+BURST_LENGTH+1] <= 1;
                else if(ch == 3) data_ready_delay4[CAS_LATENCY+BURST_LENGTH+1] <= 1;
                else             data_ready_delay5[CAS_LATENCY+BURST_LENGTH+1] <= 1;
            end
        end

    endcase

    if (init) begin
        dbg_s_takes    <= 8'd0;
        dbg_s_writes   <= 8'd0;
        dbg_s_same     <= 8'd0;
        dbg_s_wbank    <= 2'd0;
        dbg_s_wchip    <= 1'b0;
        dbg_s_e0_dq    <= 16'd0;
        dbg_s_e0_dqm   <= 2'd0;
        dbg_s_e0_gap   <= 4'd0;
        dbg_s_e0_ab    <= 2'd0;
        dbg_s_e0_ac    <= 1'b0;
        dbg_s_e0_after <= 15'd0;
        dbg_s_e1_dq    <= 16'd0;
        dbg_s_e1_dqm   <= 2'd0;
        dbg_s_e1_gap   <= 4'd0;
        dbg_s_e1_ab    <= 2'd0;
        dbg_s_e1_ac    <= 1'b0;
        dbg_s_e1_after <= 15'd0;
        w_taken        <= 1'b0;
        w_run          <= 4'd0;
        w_cur          <= 1'b0;
        w_idx          <= 2'd0;
        w_armed        <= 1'b0;
        ch3_watch_r    <= 1'b0;
        state <= STATE_STARTUP;
        refresh_count <= startup_refresh_max - sdram_startup_cycles;
        refresh_due   <= 1'b0;
    end
end

altddio_out
#(
    .extend_oe_disable("OFF"),
    .intended_device_family("Cyclone V"),
    .invert_output("OFF"),
    .lpm_hint("UNUSED"),
    .lpm_type("altddio_out"),
    .oe_reg("UNREGISTERED"),
    .power_up_high("OFF"),
    .width(1)
)
sdramclk_ddr
(
    .datain_h(1'b0),
    .datain_l(1'b1),
    .outclock(clk),
    .dataout(SDRAM_CLK),
    .aclr(1'b0),
    .aset(1'b0),
    .oe(1'b1),
    .outclocken(1'b1),
    .sclr(1'b0),
    .sset(1'b0)
);

endmodule
