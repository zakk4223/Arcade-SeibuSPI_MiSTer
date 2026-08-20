//============================================================================
//  Copyright (C) 2023 Martin Donlon
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//============================================================================
//
//  `ram_ss_adaptor`, lifted out of Arcade-IGSPGM_MiSTer's rtl/ram.sv -- the
//  rest of that file is PGM's own BRAM primitives, which this core does not
//  use. One bug fixed, marked below.
//
//  PORT STEALING, which is the whole reason a savestate costs no memory here.
//  The adaptor sits between a RAM's client and the RAM, and while the
//  savestate is addressing this section it substitutes its own address, data
//  and write enable. That is safe because the machine is frozen for the
//  duration: nothing else is driving the port. spi_mainram's header records
//  what the alternative costs -- made truly dual-ported, Quartus duplicated all
//  four byte lanes, took the array from 2 Mbit to 4 and blew the M10K budget
//  outright.
//============================================================================

`timescale 1ns / 1ps

module ram_ss_adaptor #(
    parameter WIDTH = 8,
    parameter WIDTHAD = 10,
    parameter SS_IDX
) (
    input                     clk,

    input                     wren_in,
    input       [WIDTHAD-1:0] addr_in,
    input       [WIDTH-1:0]   data_in,

    output                    wren_out,
    output      [WIDTHAD-1:0] addr_out,
    output      [WIDTH-1:0]   data_out,

    input       [WIDTH-1:0]   q,

    ssbus_if.slave            ssbus
);

assign addr_out = ssbus.access(SS_IDX) ? ssbus.addr[WIDTHAD-1:0] : addr_in;
assign data_out = ssbus.access(SS_IDX) ? ssbus.data[WIDTH-1:0] : data_in;
assign wren_out = ssbus.access(SS_IDX) ? ssbus.write : wren_in;

wire [31:0] SIZE = 2**WIDTHAD;

// -- SeibuSPI: the width CODE, not the byte count. Upstream computes
// ((WIDTH + 7) / 8) - 1, which is right for 8 and 16 bits and wrong for 32:
// it yields 3, the code for 64, so memory_stream packs one item per 64-bit
// word instead of two and the section is written at twice its size with every
// other word blank. Upstream carries a FIXME saying as much and only ever
// instantiates this at 8 and 16 bits. Every RAM in this core is 32 wide.
//
//   bytes 1 -> 0,  2 -> 1,  4 -> 2,  8 -> 3
localparam int SS_BYTES = (WIDTH + 7) / 8;
localparam int SS_WIDTH_CODE = SS_BYTES > 4 ? 3 : SS_BYTES > 2 ? 2 :
                              SS_BYTES > 1 ? 1 : 0;

reg read_delay;
always @(posedge clk) begin
    ssbus.setup(SS_IDX, SIZE, SS_WIDTH_CODE);

    if (ssbus.access(SS_IDX)) begin
        if (ssbus.write) begin
            ssbus.write_ack(SS_IDX);
        end else if (ssbus.read) begin
            if (read_delay) begin
                ssbus.read_response(SS_IDX, { {64-WIDTH{1'd0}}, q });
            end
            read_delay <= 1;
        end
    end else begin
        read_delay <= 0;
    end
end

endmodule
