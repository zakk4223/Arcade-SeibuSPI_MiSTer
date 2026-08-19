--
-- SeibuSPI - how long does rfjet's 386 legitimately go without a sprite DMA?
--
--   DISPLAY=:0 SLOP_SECS=180 mame rfjet -autoboot_script tools/mame_sprdma_gap.lua \
--       -video none -sound none -nothrottle -skip_gameinfo
--
-- The core's `frame gap` telemetry is the longest interval between sprite DMA
-- triggers, as a stand-in for "the game loop hitched". That only means anything
-- against a reference: if the game itself stops triggering across a scene
-- change, a large reading is normal behaviour and not a stall at all.
--
-- rise_map puts the trigger at 0x562; sei252_map uses 0x50E. Both are watched.
--
local SECS = tonumber(os.getenv("SLOP_SECS") or "180")

local mach  = manager.machine
local space = mach.devices[":maincpu"].spaces["program"]

local last  = nil
local worst = 0
local worst_at = 0
local n = 0
local hist = {}

local function trigger()
    local t = mach.time:as_double()
    n = n + 1
    if last then
        local dt = t - last
        local bucket = math.floor(dt * 1000 / 20) * 20   -- 20 ms buckets
        hist[bucket] = (hist[bucket] or 0) + 1
        if dt > worst then worst = dt; worst_at = t end
    end
    last = t
end

slop_spr_tap = space:install_write_tap(0x500, 0x57f, "slop_spr", function(offset, data, mask)
    local dw = offset & 0xFFFFFFFC
    if (dw == 0x50C or dw == 0x560) and (mask & 0xFFFF0000) ~= 0 then trigger() end
    return data
end)

emu.register_periodic(function()
    if mach.time.seconds >= SECS then
        print(string.format("sprite DMA triggers: %d in %d s (%.1f/s; one per frame = 53.99)",
              n, SECS, n / SECS))
        print(string.format("WORST gap: %.3f s at t=%.1f  (the core reported 0.387 s)",
              worst, worst_at))
        local keys = {}
        for k in pairs(hist) do keys[#keys+1] = k end
        table.sort(keys)
        print("gap histogram, 20 ms buckets:")
        for _, k in ipairs(keys) do
            print(string.format("  %4d-%4d ms : %d", k, k + 19, hist[k]))
        end
        mach:exit()
    end
end)
