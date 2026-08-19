--============================================================================
--  SeibuSPI - raw wave-port register writes across a window of flash.
--
--  The other two scripts interpret the port: they track the address register
--  and decide what is a command and what is a datum. That interpretation is
--  exactly what is in question when one byte of rdft2's flash comes out FF and
--  MAME's holds FE (PLAN.md 19.11) -- the core's own address counter is the
--  same interpretation in RTL, so a trace that shares the assumption cannot
--  expose a fault in it.
--
--  So this one interprets nothing. Every write to the timer bank that reaches
--  registers 0x14-0x17 is printed in order with its raw datum, from the moment
--  the tracked address enters the window until it leaves:
--
--    W 14 = FD          low byte of the address
--    W 17 = 40          a command, which PRE-INCREMENTS
--    W 17 = FE          the datum, which pre-increments again
--
--  Read it for where the carries land and how many increments there are per
--  byte, which is what the RTL has to agree with.
--
--  SLOP_LO/SLOP_HI bound the window; SLOP_OUT names the file.
--============================================================================
local OUT = os.getenv("SLOP_OUT") or "/tmp/slop_raw.txt"
local LO  = tonumber(os.getenv("SLOP_LO") or "0x29F8")
local HI  = tonumber(os.getenv("SLOP_HI") or "0x2A04")

local mach = manager.machine
local z80  = mach.devices[":audiocpu"].spaces["program"]

ext_addr, last_c, armed, done, ext_rw, nline = 0, 0, false, false, 0, 0
BUDGET = tonumber(os.getenv("SLOP_N") or "60")
f = io.open(OUT, "w")
f:write(string.format("window %06X-%06X\n", LO, HI))

-- Reads at offset 2 PRE-INCREMENT the address register when the direction bit
-- says read, so a status poll MOVES the port. That is the whole reason this
-- logs reads as well as writes: the updater only rewrites the low address byte
-- before each datum, so a poll that carries the address across a 256-byte page
-- boundary sends the byte 256 bytes away (PLAN.md 19.11).
slop_r = z80:install_read_tap(0x6000, 0x600f, "raw_r", function(offset, data, mask)
    if done or not armed then return data end
    local a = offset & 0xF
    if a == 2 then
        if ext_rw == 1 then ext_addr = (ext_addr + 1) & 0x7FFFFF end
        f:write(string.format("R 02        addr now %06X   (rw=%d)\n", ext_addr, ext_rw or 0))
        f:flush()
        nline = nline + 1
    end
    return data
end)

slop_w = z80:install_write_tap(0x6000, 0x600f, "raw_w", function(offset, data, mask)
    if done then return data end
    local a = offset & 0xF
    if a == 0xC then last_c = data return data end
    if a ~= 0xD then return data end

    local reg = last_c or 0
    if reg < 0x14 or reg > 0x17 then return data end

    -- Track the address exactly as the other scripts do, but only to decide
    -- WHEN to print. What is printed is the raw write.
    if     reg == 0x14 then ext_addr = (ext_addr & 0xFFFF00) | data
    elseif reg == 0x15 then ext_addr = (ext_addr & 0xFF00FF) | (data << 8)
    elseif reg == 0x16 then
        ext_addr = (ext_addr & 0x00FFFF) | ((data & 0x7f) << 16)
        ext_rw = (data & 0x80) ~= 0 and 1 or 0
    elseif reg == 0x17 then ext_addr = (ext_addr + 1) & 0x7FFFFF
    end

    if not armed and ext_addr >= LO and ext_addr <= HI then armed = true end
    if armed then
        f:write(string.format("W %02X = %02X    addr now %06X\n", reg, data, ext_addr))
        f:flush()
        -- Stop on a LINE BUDGET, not on leaving the window. Setting the low
        -- address byte at a page boundary drives the tracked address through a
        -- transient far outside it (0x2A00 + 0xFF), and an address-based exit
        -- cuts the log exactly at the boundary handling that matters.
        nline = nline + 1
        if nline >= BUDGET then f:write("-- budget\n") f:flush() done = true end
    end
    return data
end)
