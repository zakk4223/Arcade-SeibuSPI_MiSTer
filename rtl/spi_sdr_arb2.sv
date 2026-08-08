//============================================================================
//  SlopperPI - two-client arbiter for one SDRAM channel
//
//  SDRAM channel 3 is the only writable one, so it carries the ROM download,
//  then the ROM checker, then -- once the board is running -- BOTH the Z80's
//  program fetch and the host's JTAG peek. Those last two have no natural
//  ordering, hence this.
//
//  Every port uses sdram.sv's toggle protocol: a client inverts `req` to ask
//  and waits until `ack == req`. The arbiter holds one transaction in flight at
//  a time. Port A wins a tie; port B is the JTAG peek, which is a human
//  pressing enter.
//
//  Read data is latched per client rather than passed through. The channel's
//  dout register is overwritten by whatever transaction runs next, and the
//  other client can start one within a couple of cycles of this one's ack --
//  a small window, but a real one, and 64 flip-flops close it outright.
//
//  Client A may be in another clock domain (the Z80 runs on clk_sys, this runs
//  on clk_ram). That is the same arrangement spi_layers and spi_sprite already
//  use against sdram.sv directly: the two clocks come from one PLL at an exact
//  2:1 ratio and sit in one clock group, so the toggles are sampled cleanly.
//============================================================================

module spi_sdr_arb2
(
	input             clk,

	input      [24:0] a_addr,
	input             a_req,
	output reg        a_ack,

	input      [24:0] b_addr,
	input             b_req,
	output reg        b_ack,

	output reg [24:0] m_addr,
	output reg        m_req,
	input             m_ack,
	input      [63:0] m_dout,

	output reg [63:0] a_dout,
	output reg [63:0] b_dout
);

	localparam [1:0] S_IDLE = 2'd0, S_A = 2'd1, S_B = 2'd2;
	reg [1:0] state = S_IDLE;

	initial begin
		a_ack  = 1'b0;
		b_ack  = 1'b0;
		m_req  = 1'b0;
		m_addr = 25'd0;
		a_dout = 64'd0;
		b_dout = 64'd0;
	end

	always @(posedge clk) begin
		case (state)
			S_IDLE:
				if (a_req != a_ack) begin
					m_addr <= a_addr;
					m_req  <= ~m_req;
					state  <= S_A;
				end
				else if (b_req != b_ack) begin
					m_addr <= b_addr;
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

			default: state <= S_IDLE;
		endcase
	end

endmodule
