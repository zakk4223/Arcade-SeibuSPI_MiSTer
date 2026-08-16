--============================================================================
--  SlopperPI - log the YMF271 wave-memory port in BOTH directions.
--
--  tools/mame_flash_probe.lua logs what the updater WRITES, which was enough to
--  work out the payload. This one logs what it READS BACK as well, because the
--  question here is different: the core's own flash controller stalls after one
--  block erase (PLAN.md 17.14) and what matters is the exact command/poll
--  handshake, not the data.
--
--  Every access to the Z80's 0x6000-0x600F is recorded in time order with the
--  port's address register and direction bit as this script tracks them:
--
--    W 16 = 8F   addr=00FFFF rw=1        an address/direction register write
--    W 17 = 20   addr=010000 rw=0        a byte to the wave port (pre-increment)
--    R 02 -> 80  addr=010000 rw=1        a read of the data port
--
--  SLOP_N caps the line count (default 4000) and SLOP_OUT names the file.
--
--  The traps from the other probe apply here too: subscriptions must live in
--  globals or they are collected when this chunk ends, and never touch MEMORY
--  from inside a tap.
--============================================================================
local OUT = os.getenv("SLOP_OUT") or "/tmp/slop_port.txt"
local N   = tonumber(os.getenv("SLOP_N") or "4000")

local mach = manager.machine
local z80  = mach.devices[":audiocpu"].spaces["program"]

ext_addr, ext_rw, nline = 0, 0, 0
f = io.open(OUT, "w")

local function emit(s)
    if nline >= N then return end
    nline = nline + 1
    f:write(s)
    if nline == N then f:write("-- capped at " .. N .. " lines\n"); f:flush() end
end

slop_w = z80:install_write_tap(0x6000, 0x600f, "port_w", function(offset, data, mask)
    local a = offset & 0xF
    -- Odd offsets are data; the register they land in was named by the even
    -- offset below them. Only the timer bank (0xC/0xD) reaches 0x14-0x17.
    if a == 0xD then
        local reg = last_c or 0
        if     reg == 0x14 then ext_addr = (ext_addr & 0xFFFF00) | data
        elseif reg == 0x15 then ext_addr = (ext_addr & 0xFF00FF) | (data << 8)
        elseif reg == 0x16 then
            ext_addr = (ext_addr & 0x00FFFF) | ((data & 0x7f) << 16)
            ext_rw = (data & 0x80) ~= 0 and 1 or 0
        elseif reg == 0x17 then
            ext_addr = (ext_addr + 1) & 0x7FFFFF
        end
        if reg >= 0x14 and reg <= 0x17 then
            emit(string.format("W %02X = %02X   addr=%06X rw=%d\n",
                               reg, data, ext_addr, ext_rw))
        end
    elseif a == 0xC then
        last_c = data
    end
    return data
end)

slop_r = z80:install_read_tap(0x6000, 0x600f, "port_r", function(offset, data, mask)
    local a = offset & 0xF
    if a == 0x2 then
        emit(string.format("R 02 -> %02X  addr=%06X rw=%d\n", data, ext_addr, ext_rw))
        if ext_rw == 1 then ext_addr = (ext_addr + 1) & 0x7FFFFF end
    end
    return data
end)

emit("-- port log start\n")
