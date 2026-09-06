--
-- Run the SPI 386 benchmark ROM under MAME.
--
--   BENCH_ROM=bench/out/bench_patched.bin BENCH_OUT=/tmp/bench_mame.txt \
--   mame rfjet -rompath <roms> -autoboot_script bench/mame_bench.lua -noplugins \
--       -video none -sound none -nothrottle -skip_gameinfo -seconds_to_run 180
--
-- The ROM is written straight into the ":maincpu" region and the machine is
-- soft reset, which sidesteps MAME's CRC check entirely -- no doctored zip, no
-- rebuilt driver. The rfjet idle-loop speedup handler installed over 0x2894C
-- (seibuspi.cpp:2063) is harmless here: it only calls spin_until_interrupt when
-- the PC is 0x0206082, which is the game's loop and never ours.
--
-- MAME re-runs an autoboot script on every machine reset, so this is written to
-- be re-entrant: the first pass patches the region and resets, the second sees
-- its own image already in place and installs the poller. The marker has to be
-- the image sitting in the ROM region -- a Lua global does not survive the
-- state being rebuilt, and a marker in main RAM does not survive the benchmark
-- clearing RAM at startup.
--
-- Results come out of the results block the ROM maintains in main RAM at 0x800.
-- That needs no tap: a plain space:read_u32 on RAM always works, which is what
-- makes this the dependable half of the readout.
--
-- -noplugins is not optional; see tools/mame_crtc_trace.lua for why.
--
local ROM    = os.getenv("BENCH_ROM") or "bench/out/bench_patched.bin"
local OUT    = os.getenv("BENCH_OUT")
local CPU_HZ = tonumber(os.getenv("BENCH_CPU_HZ") or "25000000")

local SCREEN   = os.getenv("BENCH_SCREEN")
-- Number of P1 RIGHT presses to inject once the suite finishes, so a headless
-- run can prove the paging works and can dump page 2. Without this the only way
-- to see the second page is to press the button on a cabinet.
local PAGES    = tonumber(os.getenv("BENCH_PAGE") or "0")

local RESULTS  = 0x800
-- The tilemap DMA source, with rowscroll enabled: back, back-rs, fore, fore-rs,
-- midl, midl-rs, then 0x1000 bytes of text. See bench/spi.inc.
local TEXT_SRC = 0x38000 + 0x3000
local MAGIC    = 0x42495053             -- 'SPIB'
local REC_BASE = RESULTS + 32
local REC_SIZE = 32
local NAMELEN  = 12

local mach   = manager.machine
local mspace = mach.devices[":maincpu"].spaces["program"]
local region = mach.memory.regions[":maincpu"]

local out = nil
local function emit(s)
    print(s)
    if out then out:write(s .. "\n") out:flush() end
end

local function already_patched()
    return region:read_u8(0) == 0x42 and region:read_u8(1) == 0x43
       and region:read_u8(2) == 0x46 and region:read_u8(3) == 0x47
end

-- ---------------------------------------------------------------------------
-- Pass 2: watch the results block
-- ---------------------------------------------------------------------------
local function install_poller()
    local reported, last_gen, started = {}, -1, false
    local ntests, window = 0, 0
    local t_first, t_last, frames = nil, nil, 0

    local function read_name(base)
        local s = {}
        for i = 0, NAMELEN - 1 do
            local c = mspace:read_u8(base + i)
            if c == 0 then break end
            s[#s + 1] = string.char(c)
        end
        return (table.concat(s):gsub("%s+$", ""))
    end

    -- P1 RIGHT is bit 3 of the INPUTS port, active low (seibuspi.cpp:1259).
    local right = mach.ioport.ports[":INPUTS"].fields["P1 Right"]
    local presses, phase = PAGES, 0

    local function page_step()
        if presses <= 0 then return end
        phase = phase + 1
        if phase <= 3 then
            right:set_value(1)
        elseif phase <= 6 then
            right:set_value(0)
        else
            right:clear_value()
            phase = 0
            presses = presses - 1
            if presses == 0 then
                emit(string.format("BENCHINFO paged right %d times", PAGES))
            end
        end
    end

    local function poll()
        frames = frames + 1
        local now = mach.time:as_double()
        if not t_first then t_first = now end
        t_last = now

        if mspace:read_u32(RESULTS) ~= MAGIC then return end
        if not started then
            started = true
            window = mspace:read_u32(RESULTS + 12)
            ntests = mspace:read_u32(RESULTS + 16)
            emit(string.format("BENCHINFO window=%d ntests=%d", window, ntests))
        end

        -- The ROM only polls the pad from its idle loop, after the last test.
        -- RES_RUNNING going to 0 is that moment; paging before it does nothing
        -- and looks, from out here, exactly like a broken button.
        if mspace:read_u32(RESULTS + 24) == 0 then page_step() end

        local gen = mspace:read_u32(RESULTS + 4)
        if gen == last_gen then return end
        last_gen = gen

        for i = 0, ntests - 1 do
            local rec = REC_BASE + i * REC_SIZE
            if not reported[i] and mspace:read_u32(rec + 28) == 1 then
                reported[i] = true
                emit(string.format(
                    "BENCH idx=%d name=%q lo=%d hi=%d delta=%d window=%d",
                    i, read_name(rec),
                    mspace:read_u32(rec + 12), mspace:read_u32(rec + 16),
                    mspace:read_u32(rec + 20), window))
            end
        end
    end

    bench_frame_notifier = emu.add_machine_frame_notifier(poll)

    bench_stop_notifier = emu.add_machine_stop_notifier(function()
        local n = 0
        for _ in pairs(reported) do n = n + 1 end
        -- Frame period straight from emulated time. This is the number that
        -- turns iterations-per-window into cycles, so print it rather than
        -- assume it: CPF = cpu_hz * period.
        if frames > 1 and t_last > t_first then
            local period = (t_last - t_first) / (frames - 1)
            emit(string.format(
                "BENCHINFO frame_period=%.9f frame_hz=%.4f cpf=%.1f",
                period, 1.0 / period, CPU_HZ * period))
        end
        emit(string.format("BENCHINFO reported=%d of %d exc=%d", n, ntests,
            started and mspace:read_u32(RESULTS + 20) or 0))

        -- The text layer as it actually appears, read through the same ROT270
        -- transform the hardware applies: screen line L, column P, is
        -- framebuffer tile P*64 + (39-L). Reading it the other way round is how
        -- the first version of this ROM shipped a table laid out sideways and
        -- still passed its own dump.
        if SCREEN then
            local f = io.open(SCREEN, "w")
            for line = 0, 39 do
                local out = {}
                for col = 0, 29 do
                    local w = mspace:read_u16(
                        TEXT_SRC + (col * 64 + (39 - line)) * 2)
                    local c = w & 0xFFF
                    out[#out + 1] = (c >= 0x20 and c < 0x60)
                        and string.char(c) or "."
                end
                f:write((table.concat(out):gsub("%s+$", "")) .. "\n")
            end
            f:close()
            emit("BENCHINFO screen dumped to " .. SCREEN)
        end
        if out then out:close() end
    end)
end

-- ---------------------------------------------------------------------------
-- Pass 1: load the image
-- ---------------------------------------------------------------------------
local function patch_and_reset()
    local f = io.open(ROM, "rb")
    if not f then
        emit("BENCHERR cannot open " .. ROM)
        return
    end
    local img = f:read("a")
    f:close()

    if #img ~= region.size then
        emit(string.format("BENCHERR image is %d bytes, region is %d",
            #img, region.size))
        return
    end
    if img:sub(1, 4) ~= "BCFG" then
        emit("BENCHERR no BCFG block at ROM offset 0 -- wrong image?")
        return
    end

    for off = 0, #img - 4, 4 do
        region:write_u32(off, string.unpack("<I4", img, off + 1))
    end
    emit(string.format("BENCHINFO rom=%s bytes=%d cpu_hz=%d", ROM, #img, CPU_HZ))
    mach:soft_reset()
end

if already_patched() then
    out = OUT and io.open(OUT, "a") or nil
    emit("BENCHINFO image already resident, polling")
    install_poller()
else
    out = OUT and io.open(OUT, "w") or nil
    patch_and_reset()
end
