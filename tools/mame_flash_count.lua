--============================================================================
--  SeibuSPI - count what the updater issues, and when.
--
--  The core's telemetry says it ACCEPTED 2,028,340 byte programs for rdft2 and
--  dropped none, and the resulting flash still differs from MAME's in one byte
--  (PLAN.md 19.11). Two very different faults produce that: a command the core
--  never saw at all, or a command it saw and wrote somewhere it did not stick.
--  The totals separate them -- if MAME issues one more program than the core
--  accepted, the byte was lost on the way IN.
--
--  Erases are stamped with the program count at the moment they are issued,
--  which is the other thing worth knowing: the core queues them and drains the
--  queue slowly, so an erase commanded after programming has begun would sweep
--  back over bytes already written. Nothing else reveals that ordering.
--
--  SLOP_OUT names the file; it is rewritten on every erase and at the end, so
--  the totals survive a run that is cut short.
--============================================================================
local OUT = os.getenv("SLOP_OUT") or "/tmp/slop_count.txt"

local mach = manager.machine
local z80  = mach.devices[":audiocpu"].spaces["program"]

ext_addr, nprog, nerase, last_c, pending = 0, 0, 0, 0, nil
erases = {}

local function dump()
    local f = io.open(OUT, "w")
    f:write(string.format("programs %d\nerases %d\n", nprog, nerase))
    for _, e in ipairs(erases) do
        f:write(string.format("erase %06X at program %d\n", e[1], e[2]))
    end
    f:close()
end

slop_w = z80:install_write_tap(0x6000, 0x600f, "count_w", function(offset, data, mask)
    local a = offset & 0xF
    if a == 0xD then
        local reg = last_c or 0
        if     reg == 0x14 then ext_addr = (ext_addr & 0xFFFF00) | data
        elseif reg == 0x15 then ext_addr = (ext_addr & 0xFF00FF) | (data << 8)
        elseif reg == 0x16 then ext_addr = (ext_addr & 0x00FFFF) | ((data & 0x7f) << 16)
        elseif reg == 0x17 then
            ext_addr = (ext_addr + 1) & 0x7FFFFF
            if pending == 0x40 or pending == 0x10 then
                nprog = nprog + 1
                -- No emu.register_stop in this MAME build, so the totals are
                -- rewritten periodically instead; a run cut short still leaves
                -- a usable count behind.
                -- The stamp at flash[0..3] is programmed LAST, so a dump on
                -- those four bytes captures the FINAL total exactly; the
                -- periodic one only ever lands on a round number.
                if (nprog & 0x3FF) == 0 or ext_addr < 4 then dump() end
                pending = nil
            else
                if pending == 0x20 and data == 0xD0 then
                    nerase = nerase + 1
                    erases[#erases + 1] = { erase_addr or 0, nprog }
                    dump()
                end
                if data == 0x20 then erase_addr = ext_addr end
                pending = data
            end
        end
    elseif a == 0xC then
        last_c = data
    end
    return data
end)
