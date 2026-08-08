//============================================================================
//  SlopperPI - behavioural SDRAM chip, for simulation only
//
//  Enough of a 16Mx16 SDR part to run rtl/sdram.sv against: ACTIVE / READ /
//  WRITE / PRECHARGE / AUTO REFRESH / LOAD MODE, CAS latency 3, burst length 4,
//  A10 auto-precharge, DQM byte masking.
//
//  Geometry matches what rtl/sdram.sv drives:
//      bank = byte_addr[24:23]   row = byte_addr[22:10]   col = byte_addr[9:1]
//  giving 4 x 8192 x 512 words = 32 MB, which covers the 22.5 MB image.
//
//  Deliberately NOT a timing-accurate part: it does not check tRCD, tRP or
//  refresh intervals. The point is to exercise the controller's command
//  sequencing and, above all, its request/ack handshaking under real burst
//  latency -- the one path the rest of sim/ has never touched.
//============================================================================

module sdram_model
(
	input             clk,
	input             cke,

	inout      [15:0] dq,
	input      [12:0] a,
	input       [1:0] ba,
	input             dqml,
	input             dqmh,
	input             n_cs,
	input             n_ras,
	input             n_cas,
	input             n_we,

	output reg [31:0] n_act,
	output reg [31:0] n_rd,
	output reg [31:0] n_wr,
	output reg [31:0] n_clk
);

	localparam CAS_LATENCY = 3;

	// 4 banks x 8192 rows x 512 cols
	reg [15:0] mem [0:16777215];

	reg [12:0] act_row [0:3];
	reg  [3:0] act_val;

	// Read pipeline: CAS latency stages, each carrying a word and a valid bit.
	reg [15:0] rd_data [0:CAS_LATENCY];
	reg        rd_val  [0:CAS_LATENCY];

	reg [15:0] dq_out;
	reg        dq_oe;

	assign dq = dq_oe ? dq_out : 16'bz;

	// Command tally, printed by the testbench via a hierarchical reference.


	// Burst state
	reg        burst_act;
	reg  [2:0] burst_left;
	reg  [1:0] burst_ba;
	reg  [8:0] burst_col;
	reg        burst_rd;
	reg        burst_ap;

	wire [2:0] cmd = {n_ras, n_cas, n_we};
	/* verilator lint_off UNUSEDPARAM */
	localparam [2:0] CMD_ACTIVE = 3'b011, CMD_READ = 3'b101, CMD_WRITE = 3'b100,
	                 CMD_PRE    = 3'b010, CMD_RFSH = 3'b001, CMD_MODE  = 3'b000,
	                 CMD_NOP    = 3'b111;
	/* verilator lint_on UNUSEDPARAM */

	function [23:0] addr_of(input [1:0] b, input [12:0] r, input [8:0] c);
		addr_of = {b, r, c};
	endfunction

	integer i;
	initial begin
		n_act = 0; n_rd = 0; n_wr = 0; n_clk = 0;
		act_val = 4'd0;
		burst_act = 1'b0;
		dq_oe = 1'b0;
		for (i = 0; i <= CAS_LATENCY; i = i + 1) rd_val[i] = 1'b0;
	end

	always @(posedge clk) begin
		n_clk <= n_clk + 32'd1;
		if (cke) begin
			// advance the read pipeline
			for (i = CAS_LATENCY; i > 0; i = i - 1) begin
				rd_data[i] <= rd_data[i-1];
				rd_val[i]  <= rd_val[i-1];
			end
			rd_val[0]  <= 1'b0;
			rd_data[0] <= 16'd0;

			// continue an in-flight burst
			if (burst_act && burst_left != 3'd0) begin
				burst_col <= burst_col + 9'd1;
				burst_left <= burst_left - 3'd1;
				if (burst_rd) begin
					rd_data[0] <= mem[addr_of(burst_ba, act_row[burst_ba], burst_col + 9'd1)];
					rd_val[0]  <= 1'b1;
				end
				else begin
					if (!dqml) mem[addr_of(burst_ba, act_row[burst_ba], burst_col + 9'd1)][ 7:0] <= dq[ 7:0];
					if (!dqmh) mem[addr_of(burst_ba, act_row[burst_ba], burst_col + 9'd1)][15:8] <= dq[15:8];
				end
				if (burst_left == 3'd1) begin
					burst_act <= 1'b0;
					if (burst_ap) act_val[burst_ba] <= 1'b0;
				end
			end

			if (!n_cs) begin
				case (cmd)
					CMD_ACTIVE: begin
						n_act <= n_act + 32'd1;
						act_row[ba] <= a;
						act_val[ba] <= 1'b1;
					end

					CMD_READ: begin
						n_rd <= n_rd + 32'd1;
						if (!act_val[ba]) $display("sdram_model: READ from unopened bank %0d", ba);
						rd_data[0] <= mem[addr_of(ba, act_row[ba], a[8:0])];
						rd_val[0]  <= 1'b1;
						burst_act  <= 1'b1;
						burst_left <= 3'd3;          // burst of 4, one already issued
						burst_ba   <= ba;
						burst_col  <= a[8:0];
						burst_rd   <= 1'b1;
						burst_ap   <= a[10];
					end

					CMD_WRITE: begin
						n_wr <= n_wr + 32'd1;
						if (!act_val[ba]) $display("sdram_model: WRITE to unopened bank %0d", ba);
						if (!dqml) mem[addr_of(ba, act_row[ba], a[8:0])][ 7:0] <= dq[ 7:0];
						if (!dqmh) mem[addr_of(ba, act_row[ba], a[8:0])][15:8] <= dq[15:8];
						burst_act  <= 1'b1;
						burst_left <= 3'd3;
						burst_ba   <= ba;
						burst_col  <= a[8:0];
						burst_rd   <= 1'b0;
						burst_ap   <= a[10];
					end

					CMD_PRE: begin
						if (a[10]) act_val <= 4'd0;
						else       act_val[ba] <= 1'b0;
						burst_act <= 1'b0;
					end

					default: ;   // refresh, mode set and NOP need no modelling here
				endcase
			end

			// Drive DQ so the first word of a burst is on the bus exactly
			// CAS_LATENCY cycles after the READ command. The controller
			// registers SDRAM_DQ into dq_regN and then captures that when
			// data_ready_delayN[4] comes round, so being one cycle late here
			// silently returns the previous word.
			dq_oe  <= rd_val[CAS_LATENCY-2];
			dq_out <= rd_data[CAS_LATENCY-2];
		end
	end

endmodule
