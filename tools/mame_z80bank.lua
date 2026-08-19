--
-- SeibuSPI - which Z80 ROM banks does the sound driver actually select?
--
--   SLOP_SECS=90 mame rfjet -autoboot_script tools/mame_z80bank.lua -video none -sound none
--
-- The core zeroes the top half of the 256 KB Z80 region (spi_sound.sv's
-- rom_off[17] test), which is only correct for a set whose program is 128 KB.
-- This says, from the running driver rather than from the image, whether banks
-- 4-7 are ever selected -- i.e. whether that constant is silently deleting a
-- game's music data.
--
-- Prints a histogram at the end, and also the highest byte the Z80 ever fetched
-- out of the banked window, which is the region size the hardware really needs.
--
local SECS = tonumber(os.getenv("SLOP_SECS") or "60")

local mach  = manager.machine
local zspace = mach.devices[":audiocpu"].spaces["program"]

local banks = {}
local bank  = 0
local hi    = 0
local writes = 0

-- Global, or the subscription is collected when this chunk ends (mame_probe.lua
-- learned that one the hard way).
slop_bank_tap = zspace:install_write_tap(0x401b, 0x401b, "slop_z80_bank", function(offset, data, mask)
    bank = data & 7
    banks[bank] = (banks[bank] or 0) + 1
    writes = writes + 1
end)

-- Reads out of the banked window, to get the real high-water mark.
slop_read_tap = zspace:install_read_tap(0x8000, 0xffff, "slop_z80_fetch", function(offset, data, mask)
    local off = bank * 0x8000 + (offset - 0x8000)
    if off > hi then hi = off end
end)

local function report()
    print("---- Z80 bank selects over " .. SECS .. "s ----")
    print("total writes to 0x401B: " .. writes)
    for b = 0, 7 do
        local n = banks[b] or 0
        print(string.format("  bank %d  region 0x%05X-0x%05X  %8d selects%s",
              b, b * 0x8000, b * 0x8000 + 0x7fff, n,
              (b >= 4 and n > 0) and "   <-- ABOVE 128 KB" or ""))
    end
    print(string.format("highest banked byte fetched: 0x%05X (needs a %d KB region)",
          hi, math.floor(hi / 1024) + 1))
end

emu.add_machine_stop_notifier(report)

emu.register_periodic(function()
    if mach.time.seconds >= SECS then
        report()
        mach:exit()
    end
end)
