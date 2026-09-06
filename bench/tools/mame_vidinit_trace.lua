--
-- SeibuSPI - capture the video-register init the REAL rfjet program performs,
-- from reset up to its first tilemap DMA trigger.
--
--   SLOP_OUT=/tmp/rfjet_vidinit.txt mame rfjet -rompath <roms> \
--       -autoboot_script bench/tools/mame_vidinit_trace.lua -noplugins \
--       -video none -sound none -nothrottle -skip_gameinfo -seconds_to_run 12
--
-- Why this exists. The benchmark ROM has to bring the video hardware up on a
-- REAL PCB, and neither emulator can tell us what that takes: MAME hardcodes
-- rfjet's tile decryption keys and its tile_decrypt_key_w (seibuspi_v.cpp:140)
-- only logs, and the core hardcodes TKEY*_RFJET in spi_defs.vh. So the game
-- writes SOMETHING to 0x414 and both emulators ignore it. Rather than reverse
-- engineer the RISE chip, replay what the game itself does.
--
-- Output is two blocks. TRACE is every write in order with a timestamp. INIT is
-- the replay list: one line per address, in FIRST-TOUCH order, carrying the
-- value that address had settled on when the first tilemap DMA fired. That
-- ordering matters -- 0x414 is written before the DMA and after the layer
-- registers, and a key load may well be order sensitive.
--
-- -noplugins is not optional; see tools/mame_crtc_trace.lua for why.
--
local OUT = os.getenv("SLOP_OUT") or "/tmp/rfjet_vidinit.txt"

local mach   = manager.machine
local mspace = mach.devices[":maincpu"].spaces["program"]

local f = io.open(OUT, "w")
local order, settled, mask_of = {}, {}, {}
local n, done = 0, false

f:write("TRACE\n")

local function note(offset, data, mask)
    if done then return end
    n = n + 1
    local a = offset & 0xFFF
    f:write(string.format("%8.3f W %03X %08X mask=%08X\n",
        mach.time:as_double() * 1000, a, data & 0xFFFFFFFF, mask & 0xFFFFFFFF))
    if settled[a] == nil then order[#order + 1] = a end
    settled[a] = data & 0xFFFFFFFF
    mask_of[a] = (mask_of[a] or 0) | (mask & 0xFFFFFFFF)
    -- 0x480 is tilemap_dma_start_w: the game has finished setting up.
    if a == 0x480 then
        done = true
        f:write(string.format("\nfirst tilemap DMA at %.3f ms after %d writes\n\n",
            mach.time:as_double() * 1000, n))
        f:write("INIT\n")
        for _, addr in ipairs(order) do
            f:write(string.format("%03X %08X %08X\n", addr, settled[addr], mask_of[addr]))
        end
        f:flush()
    end
end

-- The whole I/O overlay. Everything here is a handler in MAME's map (the CRTC
-- window is .ram() with handlers layered on top), so a tap sees it all; a tap
-- on plain main RAM would be bypassed.
vid_tap = mspace:install_write_tap(0x400, 0x6ff, "vidinit", note)

emu.add_machine_stop_notifier(function()
    if not done then
        f:write(string.format("\nNO tilemap DMA seen after %d writes\n", n))
    end
    f:close()
end)
