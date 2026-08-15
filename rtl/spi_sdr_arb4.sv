//============================================================================
//  SlopperPI - SDRAM channel 3 arbiter, two readers and two writers
//
//  ch3 has four owners once the ROM check is done:
//
//    a  Z80 program fetch          read,  latency matters
//    b  JTAG peek (tools/slop)     read,  manual, rare
//    c  Z80 program download       write, SXX2C only
//    d  sample-flash programming   write, authentic-flash MRAs only
//
//  On SXX2C the Z80's 256 KB is RAM, not ROM: the 386 pushes it a byte at a
//  time to port 0x688 and releases the CPU with 0x68C. That makes ch3 a write
//  channel again after the loader has finished with it.
//
//  `d` writes the SAMPLE region, which ch5 reads -- it is here because ch3 is
//  the only channel sdram.sv gives a write path, not because the address has
//  anything to do with the Z80. See PLAN.md 17.4.
//
//  Everything is serialised HERE rather than by muxing sdram.sv's request
//  lines, because those use a toggle handshake -- switching the mux with a
//  transaction outstanding would hand one master's ack to another. The FSM
//  owns the bus for a whole round trip, so that cannot happen.
//
//  `a` has priority: a stalled Z80 fetch stalls the sound CPU. The download
//  only runs while the Z80 is held in reset, so it never actually competes
//  with `a` -- the priority matters only for the peek. `d` is LAST, below the
//  peek, because a block erase is 32,768 back-to-back writes and would
//  otherwise lock a human out of the instrument for the length of it.
//============================================================================

module spi_sdr_arb4
(
	input             clk,

	input      [25:0] a_addr,
	input             a_req,
	output reg        a_ack,

	input      [25:0] b_addr,
	input             b_req,
	output reg        b_ack,

	input      [25:0] c_addr,
	input      [15:0] c_din,
	input       [1:0] c_be,
	input             c_req,
	output reg        c_ack,

	input      [25:0] d_addr,
	input      [15:0] d_din,
	input       [1:0] d_be,
	input             d_req,
	output reg        d_ack,

	output reg [25:0] m_addr,
	output reg [15:0] m_din,
	output reg  [1:0] m_be,
	output reg        m_rnw,
	output reg        m_req,
	input             m_ack,
	input      [63:0] m_dout,

	output reg [63:0] a_dout,
	output reg [63:0] b_dout
);

	localparam [2:0] S_IDLE = 3'd0, S_A = 3'd1, S_B = 3'd2, S_C = 3'd3,
	                 S_D    = 3'd4;
	reg [2:0] state = S_IDLE;

	initial begin
		a_ack  = 1'b0;
		b_ack  = 1'b0;
		c_ack  = 1'b0;
		d_ack  = 1'b0;
		m_req  = 1'b0;
		m_addr = 26'd0;
		m_din  = 16'd0;
		m_be   = 2'd0;
		m_rnw  = 1'b1;
		a_dout = 64'd0;
		b_dout = 64'd0;
	end

	always @(posedge clk) begin
		case (state)
			S_IDLE:
				if (a_req != a_ack) begin
					m_addr <= a_addr;
					m_rnw  <= 1'b1;
					m_req  <= ~m_req;
					state  <= S_A;
				end
				else if (c_req != c_ack) begin
					m_addr <= c_addr;
					m_din  <= c_din;
					m_be   <= c_be;
					m_rnw  <= 1'b0;
					m_req  <= ~m_req;
					state  <= S_C;
				end
				else if (b_req != b_ack) begin
					m_addr <= b_addr;
					m_rnw  <= 1'b1;
					m_req  <= ~m_req;
					state  <= S_B;
				end
				else if (d_req != d_ack) begin
					m_addr <= d_addr;
					m_din  <= d_din;
					m_be   <= d_be;
					m_rnw  <= 1'b0;
					m_req  <= ~m_req;
					state  <= S_D;
				end

			S_A: if (m_ack == m_req) begin
				a_dout <= m_dout;
				a_ack  <= a_req;
				state  <= S_IDLE;
			end

			S_B: if (m_ack == m_req) begin
				b_dout <= m_dout;
				b_ack  <= b_req;
				state  <= S_IDLE;
			end

			S_C: if (m_ack == m_req) begin
				m_rnw <= 1'b1;          // leave the channel in its read default
				c_ack <= c_req;
				state <= S_IDLE;
			end

			S_D: if (m_ack == m_req) begin
				m_rnw <= 1'b1;
				d_ack <= d_req;
				state <= S_IDLE;
			end

			default: state <= S_IDLE;
		endcase
	end

endmodule
