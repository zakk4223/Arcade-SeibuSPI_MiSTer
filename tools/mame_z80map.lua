--
-- SlopperPI - check the Z80 sound map the core implements against MAME's.
--
--   DISPLAY=:0 SLOP_SECS=45 mame rfjet -autoboot_script tools/mame_z80map.lua \
--       -video none -sound none -nothrottle -skip_gameinfo
--
-- spi_sound.sv reads the fixed window 0x0000-0x1FFF as region offset 0 and the
-- banked window 0x8000-0xFFFF as region offset bank*0x8000 + (addr - 0x8000).
-- Both of those are transcriptions of MAME's map, which is exactly the kind of
-- thing this project keeps getting caught by -- the 128 KB region size in the
-- same module was wrong for rfjet and cost every byte of banks 4-7.
--
-- So: tap every fetch the driver actually makes and require the byte MAME
-- returns to equal the byte at the region offset the RTL's formula computes.
--
local SECS = tonumber(os.getenv("SLOP_SECS") or "45")

local mach   = manager.machine
local zspace = mach.devices[":audiocpu"].spaces["program"]
local rgn    = mach.memory.regions[":audiocpu"]

local bank   = 0
local checked_lo, checked_hi = 0, 0
local bad_lo,     bad_hi     = 0, 0
local first_bad = nil

slop_map_bank = zspace:install_write_tap(0x401b, 0x401b, "slop_map_bank", function(offset, data, mask)
    bank = data & 7
end)

local function check(where, addr, got, want_off)
    local want = rgn:read_u8(want_off)
    if got ~= want then
        if not first_bad then
            first_bad = string.format(
                "%s addr 0x%04X bank %d -> region 0x%05X: MAME %02X, formula %02X",
                where, addr, bank, want_off, got, want)
        end
        return false
    end
    return true
end

slop_map_lo = zspace:install_read_tap(0x0000, 0x1fff, "slop_map_lo", function(offset, data, mask)
    checked_lo = checked_lo + 1
    if not check("fixed", offset, data & 0xff, offset) then bad_lo = bad_lo + 1 end
end)

slop_map_hi = zspace:install_read_tap(0x8000, 0xffff, "slop_map_hi", function(offset, data, mask)
    checked_hi = checked_hi + 1
    local off = bank * 0x8000 + (offset - 0x8000)
    if not check("banked", offset, data & 0xff, off) then bad_hi = bad_hi + 1 end
end)

local function report()
    print(string.format("region size            : 0x%X", rgn.size))
    print(string.format("fixed  0x0000-0x1FFF   : %d fetches, %d disagree", checked_lo, bad_lo))
    print(string.format("banked 0x8000-0xFFFF   : %d fetches, %d disagree", checked_hi, bad_hi))
    if first_bad then print("first disagreement     : " .. first_bad)
    else print("VERDICT: the RTL's address formula reproduces every byte MAME returned") end
end

emu.add_machine_stop_notifier(report)
emu.register_periodic(function()
    if mach.time.seconds >= SECS then report(); mach:exit() end
end)
