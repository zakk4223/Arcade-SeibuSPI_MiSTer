--
-- SlopperPI - dump MAME's state whenever YOU pause it.
--
--   SLOP_OUT=/tmp/mame_state mame rdfts -autoboot_script tools/mame_probe.lua
--
-- Play until the scene you want is on screen, then press P. On every
-- pause this writes the video RAMs and the framebuffer to $SLOP_OUT, so the
-- same scene can be compared against the hardware frozen at the same moment
-- with tools/jtag_server.tcl.
--
-- This is the MAME half of "stop guessing which scene you are looking at".
-- Picking frames by timing or by counting non-black pixels put several
-- measurements on the wrong scene entirely; a human pressing pause at the right
-- moment on both sides removes that.
--
-- Unpausing arms it again, so P, P, P walks through as many scenes as you like:
-- each dump lands in $SLOP_OUT/NNN/.
--
local OUT = os.getenv("SLOP_OUT") or "/tmp/mame_state"

local mach  = manager.machine
local space = mach.devices[":maincpu"].spaces["program"]
local was_paused = false
local seq = 0

-- Shadow of the CRTC / DMA registers, updated by a write tap. These are
-- write-only I/O, so they cannot be read back out of MAME later -- and without
-- them there is no way to compare against the hardware's own register
-- telemetry. Inferring them from RAM contents does not work: tilemap RAM
-- persists across frames, so a region can hold data left by an earlier frame
-- with different settings and look like proof of the wrong thing.
local reg = {
    dma_src = 0, dma_len = 0, layer_enable = 0, rowscroll = 0, fore_d13 = 0,
    bx = 0, by = 0, mx = 0, my = 0, fx = 0, fy = 0,
    tm_trigs = 0, pal_trigs = 0, spr_trigs = 0,
    spr_src = 0, tm_src = 0, pal_src = 0,
}

-- Must live in a global: if only a local holds the tap, the subscription is
-- garbage collected when this chunk ends and it silently stops firing.
slop_probe_tap = space:install_write_tap(0x400, 0x7ff, "slop_probe_io", function(offset, data, mask)
    local dw = offset & 0xFFFFFFFC
    if dw == 0x418 and (mask & 0xFFFF0000) ~= 0 then
        local v = (data >> 16) & 0xFFFF
        if (mask & 0xFF000000) ~= 0 then
            reg.rowscroll = (v >> 15) & 1
            reg.fore_d13  = (v >> 11) & 1
        end
    elseif dw == 0x41C and (mask & 0x0000FFFF) ~= 0 then
        reg.layer_enable = data & 0x1F
    elseif dw == 0x420 then
        if (mask & 0x0000FFFF) ~= 0 then reg.bx = data & 0xFFFF end
        if (mask & 0xFFFF0000) ~= 0 then reg.by = (data >> 16) & 0xFFFF end
    elseif dw == 0x424 then
        if (mask & 0x0000FFFF) ~= 0 then reg.mx = data & 0xFFFF end
        if (mask & 0xFFFF0000) ~= 0 then reg.my = (data >> 16) & 0xFFFF end
    elseif dw == 0x428 then
        if (mask & 0x0000FFFF) ~= 0 then reg.fx = data & 0xFFFF end
        if (mask & 0xFFFF0000) ~= 0 then reg.fy = (data >> 16) & 0xFFFF end
    elseif dw == 0x490 then reg.dma_len = data & 0xFFFF
    elseif dw == 0x494 then reg.dma_src = data & 0x3FFFF
    elseif dw == 0x480 then reg.tm_trigs  = reg.tm_trigs  + 1; reg.tm_src  = reg.dma_src
    elseif dw == 0x484 then reg.pal_trigs = reg.pal_trigs + 1; reg.pal_src = reg.dma_src
    elseif dw == 0x50c or dw == 0x560 then
        if (mask & 0xFFFF0000) ~= 0 then
            reg.spr_trigs = reg.spr_trigs + 1; reg.spr_src = reg.dma_src
        end
    end
    return data
end)

local function mkdir(d)
    -- lfs is not always available in MAME's lua; shell out instead.
    os.execute("mkdir -p '" .. d .. "'")
end

local function dump_share(tag, dir, name)
    local sh = mach.memory.shares[tag]
    if not sh then return 0 end
    local t = {}
    for i = 0, sh.size - 1 do t[#t+1] = string.char(sh:read_u8(i)) end
    local f = assert(io.open(dir .. "/" .. name, "wb"))
    f:write(table.concat(t))
    f:close()
    return sh.size
end

-- How many sprites in the list carry a non-zero code. This is the single number
-- that identifies a scene most reliably, and it is directly comparable with the
-- hardware's `codes!=0` telemetry.
local function sprite_stats(dir)
    local sh = mach.memory.shares[":sprite_ram"]
    if not sh then return -1 end
    local nz, lines = 0, {}
    local n = sh.size // 8            -- 8 bytes (4 u16) per sprite
    for i = 0, n - 1 do
        local attr = sh:read_u16(i*8 + 0)
        local code = sh:read_u16(i*8 + 2)
        local x    = sh:read_u16(i*8 + 4) & 0x1ff
        local y    = sh:read_u16(i*8 + 6) & 0x1ff
        if code ~= 0 then
            nz = nz + 1
            if x >= 0x180 then x = x - 0x200 end
            if y >= 0x180 then y = y - 0x200 end
            lines[#lines+1] = string.format(
                "idx=%d code=%04X attr=%04X sizex=%d sizey=%d x=%d y=%d",
                i, code, attr, ((attr >> 8) & 7) + 1, ((attr >> 12) & 7) + 1, x, y)
        end
    end
    local f = assert(io.open(dir .. "/sprites.txt", "wb"))
    f:write("codes_nonzero " .. nz .. "\n")
    f:write(table.concat(lines, "\n"))
    f:write("\n")
    f:close()
    return nz
end

local function grab_frame(dir)
    local scr = mach.screens:at(1)
    local px  = scr:pixels()
    local f = assert(io.open(dir .. "/frame.bin", "wb"))
    f:write(px)
    f:close()
    local i = assert(io.open(dir .. "/frame.txt", "wb"))
    i:write(string.format("%d %d\n", scr.width, scr.height))
    i:close()
end

local function dump()
    seq = seq + 1
    local dir = string.format("%s/%03d", OUT, seq)
    mkdir(dir)

    dump_share(":mainram",     dir, "mainram.bin")
    dump_share(":tilemap_ram", dir, "tilemap_ram.bin")
    dump_share(":palette_ram", dir, "palette_ram.bin")
    dump_share(":sprite_ram",  dir, "sprite_ram.bin")
    local nz = sprite_stats(dir)
    grab_frame(dir)

    local f = assert(io.open(dir .. "/regs.txt", "wb"))
    f:write(string.format("rowscroll %d\n", reg.rowscroll))
    f:write(string.format("fore_d13 %d\n", reg.fore_d13))
    f:write(string.format("layer_enable %d\n", reg.layer_enable))
    f:write(string.format("scroll_back %d %d\n", reg.bx, reg.by))
    f:write(string.format("scroll_midl %d %d\n", reg.mx, reg.my))
    f:write(string.format("scroll_fore %d %d\n", reg.fx, reg.fy))
    f:write(string.format("tilemap_dma %d len %d\n", reg.tm_src, reg.dma_len))
    f:write(string.format("palette_dma %d\n", reg.pal_src))
    f:write(string.format("sprite_dma %d\n", reg.spr_src))
    f:write(string.format("dma_counts %d %d %d\n", reg.tm_trigs, reg.pal_trigs, reg.spr_trigs))
    f:close()

    print(string.format(
        "[slop] paused -> %s   sprites code!=0 = %d   rowscroll = %d", dir, nz, reg.rowscroll))
end

mkdir(OUT)
print("[slop] mame_probe armed. Press P at the scene you want; state goes to " .. OUT)

-- register_periodic keeps running while the machine is paused, which
-- register_frame_done does not -- and the whole point is to act on the pause.
emu.register_periodic(function()
    local p = mach.paused
    if p and not was_paused then dump() end
    was_paused = p
end)
