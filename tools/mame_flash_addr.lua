--============================================================================
--  SlopperPI - log every wave-port access that touches ONE flash address.
--
--  tools/mame_flash_port.lua logs the whole handshake, which is the right tool
--  when the question is "what is the command sequence". This one exists for a
--  different question: rdft2's flash comes out with byte 0x29FE reading FF
--  where MAME's holds FE -- ONE byte in two megabytes, reproducibly, with the
--  core's accepted-program count still matching MAME's trace exactly (PLAN.md
--  19.11). So the program for that byte is issued and accepted and then does
--  not stick, and what settles it is knowing precisely what MAME does at that
--  address and in what order.
--
--  Dumping the whole ritual to find it would be ~16 million lines. This filters
--  to a window instead, and prints a running count of program commands so the
--  hits can be placed in the payload rather than just listed:
--
--    #10748  W 40 -> 0029FE                 program command
--    #10748  W FE -> 0029FE                 the datum
--    #10749  W 20 -> 0029FE / D0            an ERASE of the block it lives in
--
--  SLOP_LO/SLOP_HI bound the window (default 0x29F0-0x2A0F), SLOP_OUT names
--  the file. Erase and clear-status commands are logged wherever they land,
--  since a late erase of the containing block is exactly one of the candidate
--  explanations and its address is the BLOCK's, not the byte's.
--============================================================================
local OUT = os.getenv("SLOP_OUT") or "/tmp/slop_addr.txt"
local LO  = tonumber(os.getenv("SLOP_LO") or "0x29F0")
local HI  = tonumber(os.getenv("SLOP_HI") or "0x2A0F")

local mach = manager.machine
local z80  = mach.devices[":audiocpu"].spaces["program"]

ext_addr, ext_rw, nprog, last_c, pending = 0, 0, 0, 0, nil
f = io.open(OUT, "w")
f:write(string.format("window %06X-%06X\n", LO, HI))

local function hit(a) return a >= LO and a <= HI end

slop_w = z80:install_write_tap(0x6000, 0x600f, "addr_w", function(offset, data, mask)
    local a = offset & 0xF
    if a == 0xD then
        local reg = last_c or 0
        if     reg == 0x14 then ext_addr = (ext_addr & 0xFFFF00) | data
        elseif reg == 0x15 then ext_addr = (ext_addr & 0xFF00FF) | (data << 8)
        elseif reg == 0x16 then
            ext_addr = (ext_addr & 0x00FFFF) | ((data & 0x7f) << 16)
            ext_rw = (data & 0x80) ~= 0 and 1 or 0
        elseif reg == 0x17 then
            -- 0x17 pre-increments, so the byte written lands at addr+1.
            ext_addr = (ext_addr + 1) & 0x7FFFFF
            -- A datum following a 0x40 is a program; everything else is a
            -- command to the chip.
            if pending == 0x40 then
                nprog = nprog + 1
                if hit(ext_addr) then
                    f:write(string.format("#%d  PROGRAM %02X -> %06X\n",
                                          nprog, data, ext_addr))
                    f:flush()
                end
                pending = nil
            else
                if data == 0x20 or data == 0xD0 or data == 0x50 or data == 0xFF
                   or data == 0x70 or data == 0x90 then
                    -- Erases are block-wide: report one whenever the window
                    -- falls inside the 64 KB block this address selects.
                    local blk = ext_addr & 0xFFFF0000
                    if hit(ext_addr) or (data == 0x20 and LO >= blk and LO <= blk + 0xFFFF) then
                        f:write(string.format("#%d  CMD %02X @ %06X\n",
                                              nprog, data, ext_addr))
                        f:flush()
                    end
                end
                pending = data
            end
        end
    elseif a == 0xC then
        last_c = data
    end
    return data
end)
