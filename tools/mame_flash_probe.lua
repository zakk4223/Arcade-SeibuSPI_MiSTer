--============================================================================
--  SeibuSPI - probe how an SPI cartridge game programs its sample flash.
--
--  This is the tool that produced PLAN.md section 0's rdft2 findings. Four
--  modes, chosen with SLOP_MODE:
--
--    reads    count 386 reads of the sound01 window (is it touched at all?)
--    pipe     log all three stages: sound01 reads, the 386 -> Z80 FIFO, and
--             the Z80's writes to the YMF271 external memory port
--    merged   the same reads and FIFO writes in ONE time-ordered stream, which
--             is what exposes the LOCAL expansion ratio and hence block
--             structure. Only logs once the compressed phase starts.
--    pc       record the 386's PC when it pushes a byte, to locate the codec
--
--  SLOP_OUT picks the output directory.
--
--  Two traps, both paid for already: subscriptions MUST live in globals or
--  they are collected when this chunk ends and silently stop firing; and never
--  read MEMORY inside a tap -- it re-enters the memory system and segfaults.
--  Reading a CPU register is fine.
--
--  Typical run (the reflash needs ~420 emulated seconds at ~570%):
--    SLOP_MODE=merged SLOP_OUT=/tmp/x mame rdft2 -rompath ROMS \
--      -nvram_directory /tmp/nv -autoboot_script tools/mame_flash_probe.lua \
--      -video none -sound none -seconds_to_run 420 -nothrottle
--============================================================================
local MODE = os.getenv("SLOP_MODE") or "reads"
local OUT  = os.getenv("SLOP_OUT")  or "/tmp/slop_flash"
os.execute("mkdir -p " .. OUT)

local mach = manager.machine
local cpu  = mach.devices[":maincpu"]
local m386 = cpu.spaces["program"]
local z80  = mach.devices[":audiocpu"] and mach.devices[":audiocpu"].spaces["program"] or nil

-- sound01 sits at 0xA00000 in the 386 map. On rdft2 the area below region
-- offset 0x980000 is the compressed sample source and 0x980000+ is the Z80
-- program, which is read FIRST.
local S01, S01_END = 0x00a00000, 0x013fffff
nrd, nfifo, nwr, frames = 0, 0, 0, 0
ext_addr, ext_rw, ymf_latch = 0, 0, 0
armed = (MODE ~= "merged")
pcs = {}

if MODE == "reads" then
    lo, hi = nil, nil
    slop_rd = m386:install_read_tap(S01, S01_END, "s01", function(offset, data, mask)
        nrd = nrd + 1
        if not lo or offset < lo then lo = offset end
        if not hi or offset > hi then hi = offset end
        return data
    end)
else
    if MODE == "pipe" or MODE == "merged" then
        frd = io.open(OUT .. "/s01_reads.bin", "wb")
        ffifo = io.open(OUT .. "/fifo_bytes.bin", "wb")
    end
    if MODE == "merged" then fmerge = io.open(OUT .. "/merged.bin", "wb") end
    if MODE == "pipe" and z80 then fwr = io.open(OUT .. "/flash_bytes.bin", "wb") end

    slop_rd = m386:install_read_tap(S01, S01_END, "s01", function(offset, data, mask)
        local o = offset - S01
        nrd = nrd + 1
        if MODE == "merged" then
            if o >= 0x800000 and o < 0x980000 then
                armed = true
                fmerge:write(string.char(0x52, o & 0xff, (o>>8)&0xff, (o>>16)&0xff, data & 0xff))
            end
        elseif MODE == "pipe" then
            frd:write(string.char(o & 0xff, (o>>8)&0xff, (o>>16)&0xff, (o>>24)&0xff,
                                  data & 0xff, (data>>8)&0xff, (data>>16)&0xff, (data>>24)&0xff))
        end
        return data
    end)

    slop_fifo = m386:install_write_tap(0x680, 0x683, "fifo", function(offset, data, mask)
        if (mask & 0xFF) == 0 then return data end
        nfifo = nfifo + 1
        if MODE == "pipe" then ffifo:write(string.char(data & 0xFF))
        elseif MODE == "merged" and armed then fmerge:write(string.char(0x57, data & 0xFF))
        elseif MODE == "pc" and armed then
            local pc = cpu.state["EIP"].value
            pcs[pc] = (pcs[pc] or 0) + 1
        end
        return data
    end)

    -- The Z80 relays every FIFO byte to the YMF271 external port, so this is
    -- only needed to confirm the relay is 1:1 (it is).
    if MODE == "pipe" and z80 then
        slop_ymf = z80:install_write_tap(0x6000, 0x600f, "ymf_ext", function(offset, data, mask)
            local reg = offset & 0xf
            if reg == 0xc then ymf_latch = data
            elseif reg == 0xd then
                local a = ymf_latch
                if     a == 0x14 then ext_addr = (ext_addr & 0xFFFF00) | data
                elseif a == 0x15 then ext_addr = (ext_addr & 0xFF00FF) | (data << 8)
                elseif a == 0x16 then
                    ext_addr = (ext_addr & 0x00FFFF) | ((data & 0x7f) << 16)
                    ext_rw = (data & 0x80) ~= 0 and 1 or 0
                elseif a == 0x17 then
                    ext_addr = (ext_addr + 1) & 0x7FFFFF
                    if ext_rw == 0 then
                        fwr:write(string.char(ext_addr & 0xff, (ext_addr>>8)&0xff,
                                              (ext_addr>>16)&0xff, data))
                        nwr = nwr + 1
                    end
                end
            end
            return data
        end)
    end
end

-- PC mode needs arming too: only the compressed phase is interesting.
if MODE == "pc" then
    slop_arm = m386:install_read_tap(S01, S01_END, "arm", function(offset, data, mask)
        local o = offset - S01
        if o >= 0x800000 and o < 0x980000 then armed = true end
        return data
    end)
end

slop_frames = emu.add_machine_frame_notifier(function()
    frames = frames + 1
    if frames % 3000 ~= 0 then return end
    if MODE == "reads" then
        print(string.format("SLOP f%d reads=%d range=%s..%s", frames, nrd,
              lo and string.format("%08X", lo) or "-",
              hi and string.format("%08X", hi) or "-"))
    elseif MODE == "pc" then
        local t = {}
        for pc,c in pairs(pcs) do t[#t+1] = {pc,c} end
        table.sort(t, function(a,b) return a[2] > b[2] end)
        local f = io.open(OUT .. "/pcs.txt", "w")
        for i=1,math.min(#t,32) do f:write(string.format("%08X %d\n", t[i][1], t[i][2])) end
        f:close()
        print(string.format("SLOP f%d: %d distinct PCs over %d pushes", frames, #t, nfifo))
    else
        if frd then frd:flush() end
        if ffifo then ffifo:flush() end
        if fwr then fwr:flush() end
        if fmerge then fmerge:flush() end
        print(string.format("SLOP f%d reads=%d fifo=%d flash=%d", frames, nrd, nfifo, nwr))
    end
end)

print("SLOP flash probe armed, mode=" .. MODE)
