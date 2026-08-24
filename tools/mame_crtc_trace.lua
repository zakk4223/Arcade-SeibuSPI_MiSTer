--
-- SeibuSPI - log every write the 386 makes to the Seibu CRTC timing block, and
-- dump the settled register file at exit. The point is to VERIFY the claim that
-- "every SPI game programs the same raster timing": MAME never reads these
-- registers (seibu_crtc.cpp maps the whole 0x00-0x4f window as .ram() and the
-- screen is hardcoded via set_raw), so it cannot tell you -- you have to look.
--
--   SLOP_OUT=/tmp/crtc_rdft.txt SLOP_SECS=8 mame rdft \
--       -autoboot_script tools/mame_crtc_trace.lua -noplugins \
--       -video none -sound none -nothrottle -skip_gameinfo -seconds_to_run 8
--
-- -noplugins is not optional: this MAME's stock `data` plugin throws in its
-- machine-reset callback ("assign to const variable 'info'") and that aborts
-- the notifier chain, so the exit summary never prints. With plugins off the
-- machine-stop notifier fires and the settled register file is dumped.
--
-- The 386 map (seibuspi.cpp:1007) puts the CRTC at physical 0x400-0x43f, and
-- with paging off the linear address the CPU emits is physical, so a write tap
-- on the maincpu program space at those addresses is exactly the register
-- traffic. The four timing registers are 0x400 (H), 0x404 (HS), 0x408 (V),
-- 0x40c (VS); 0x410 is logged too as a cross-check against the older-chip dumps.
--
-- Each write line: <t_ms> W <addr> <data> mask=<mask>
-- The exit summary prints the settled dwords 0x400-0x410 with the same decode
-- the sim instrument uses, so the two paths can be compared directly.
--
local OUT  = os.getenv("SLOP_OUT")  or "/tmp/crtc_trace.txt"
local SECS = tonumber(os.getenv("SLOP_SECS") or "8")

local mach   = manager.machine
local mspace = mach.devices[":maincpu"].spaces["program"]

local f = io.open(OUT, "w")
local n = 0

-- Tap the timing/misc block only (0x400-0x41f). A byte/word/dword store shows
-- up with the byte-lanes it drove in `mask`, so partial 16-bit writes are
-- visible rather than silently merged.
crtc_tap = mspace:install_write_tap(0x400, 0x41f, "crtc", function(offset, data, mask)
    n = n + 1
    f:write(string.format("%d W %03X %08X mask=%08X\n",
        math.floor(mach.time:as_double() * 1000),
        offset & 0xFFF, data & 0xFFFFFFFF, mask & 0xFFFFFFFF))
end)

local function decode(f, addr, v)
    local lo = v & 0xFFFF
    local hi = (v >> 16) & 0xFFFF
    if addr == 0x400 then
        f:write(string.format("        H: active=%d blank=%d total=%d\n",
            hi + 1, lo + 1, (hi + 1) + (lo + 1)))
    elseif addr == 0x408 then
        f:write(string.format("        V: active=%d blank=%d total=%d\n",
            hi + 1, lo + 1, (hi + 1) + (lo + 1)))
    elseif addr == 0x404 or addr == 0x40c then
        -- width is exact (hi-lo); position is the inferred sim formula, needs
        -- the matching total which we don't recompute here -- width is the
        -- portable cross-game fingerprint.
        local kind = (addr == 0x404) and "HS" or "VS"
        f:write(string.format("        %s width=%d (hi-lo), lo=%04X hi=%04X\n",
            kind, hi - lo, lo, hi))
    end
end

local function report()
    -- Settled register file, read straight back out of the CRTC's RAM through
    -- the CPU's own view, so it is what the game left standing.
    f:write("\n-- settled CRTC timing block (via maincpu program space) --\n")
    for a = 0x400, 0x410, 4 do
        local v = mspace:read_u32(a)
        f:write(string.format("  %03X = %08X\n", a, v))
        decode(f, a, v)
    end
    f:write(string.format("\ntotal timing-block writes: %d\n", n))
    f:close()
    print(string.format("CRTC timing writes: %d  ->  %s", n, OUT))
end

emu.add_machine_stop_notifier(report)
