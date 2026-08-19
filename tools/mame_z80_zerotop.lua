--
-- SeibuSPI - reproduce the core's Z80 bank bug inside MAME.
--
--   DISPLAY=:0 SLOP_SECS=60 mame rfjet -autoboot_script tools/mame_z80_zerotop.lua \
--       -wavwrite /tmp/rfjet_broken.wav -video none -nothrottle -skip_gameinfo
--
-- spi_sound.sv used to read the top 128 KB of the 256 KB Z80 region back as a
-- constant zero. This does the same thing to MAME, so the emulator plays the
-- game the way the FPGA did and the two can be compared by ear and by spectrum.
-- Without it the only description of the fault is "the sound is bad", which is
-- not something a fix can be checked against.
--
-- It has to be done on the READ side, not by clearing the region: on the SPI
-- cartridge that region is RAM and the 386 fills it at boot, so anything zeroed
-- before the machine runs is simply written over.
--
-- Run the same command without this script for the reference recording.
--
local SECS = tonumber(os.getenv("SLOP_SECS") or "60")

local mach   = manager.machine
local zspace = mach.devices[":audiocpu"].spaces["program"]

local bank    = 0
local blanked = 0

slop_zt_bank = zspace:install_write_tap(0x401b, 0x401b, "slop_zt_bank", function(offset, data, mask)
    bank = data & 7
end)

slop_zt_read = zspace:install_read_tap(0x8000, 0xffff, "slop_zt_read", function(offset, data, mask)
    if bank >= 4 then
        blanked = blanked + 1
        return 0
    end
    return data
end)

emu.register_periodic(function()
    if mach.time.seconds >= SECS then
        print(string.format("reads blanked (bank >= 4): %d", blanked))
        mach:exit()
    end
end)
