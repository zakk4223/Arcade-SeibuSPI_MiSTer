//============================================================================
//  SlopperPI - SDRAM channel 3 arbiter, two readers and one writer
//
//  ch3 has three owners once the ROM check is done:
//
//    a  Z80 program fetch          read,  latency matters
//    b  JTAG peek (tools/slop)     read,  manual, rare
//    c  Z80 program download       write, SXX2C only
//
//  On SXX2C the Z80's 256 KB is RAM, not ROM: the 386 pushes it a byte at a
//  time to port 0x688 and releases the CPU with 0x68C. That makes ch3 a write
//  channel again after the loader has finished with it.
//
//  Everything is serialised HERE rather than by muxing sdram.sv's request
//  lines, because those use a toggle handshake -- switching the mux with a
//  transaction outstanding would hand one master's ack to another. The FSM
//  owns the bus for a whole round trip, so that cannot happen.
//
//  `a` has priority: a stalled Z80 fetch stalls the sound CPU. The download
//  only runs while the Z80 is held in reset, so it never actually competes
//  with `a` -- the priority matters only for the peek.
//============================================================================

module spi_sdr_arb3
(
	input             clk,

	input      [24:0] a_addr,
	input             a_req,
	output reg        a_ack,

	input      [24:0] b_addr,
	input             b_req,
	output reg        b_ack,

	input      [24:0] c_addr,
	input      [15:0] c_din,
	input       [1:0] c_be,
	input             c_req,
	output reg        c_ack,

	output reg [24:0] m_addr,
	output reg [15:0] m_din,
	output reg  [1:0] m_be,
	output reg        m_rnw,
	output reg        m_req,
	input             m_ack,
	input      [63:0] m_dout,

	output reg [63:0] a_dout,
	output reg [63:0] b_dout
);

	localparam [1:0] S_IDLE = 2'd0, S_A = 2'd1, S_B = 2'd2, S_C = 2'd3;
	reg [1:0] state = S_IDLE;

	initial begin
		a_ack  = 1'b0;
		b_ack  = 1'b0;
		c_ack  = 1'b0;
		m_req  = 1'b0;
		m_addr = 25'd0;
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

			default: state <= S_IDLE;
		endcase
	end

endmodule
