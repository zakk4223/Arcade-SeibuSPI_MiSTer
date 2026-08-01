--
-- SlopperPI - capture a golden reference frame from MAME.
--
-- MAME exposes the SPI driver's video RAMs as named shares, which lets the
-- pipeline be verified in two independent halves instead of one lump:
--
--   mainram      + registers  ->  our DMA   ->  compare against MAME's
--                                                tilemap/palette/sprite RAM
--   MAME's video RAMs + GFX   ->  our renderer -> compare against MAME's frame
--
-- Everything is sampled inside the frame notifier. Reading memory from inside a
-- write tap re-enters the memory system and segfaults MAME, which is why the
-- registers are shadowed by a tap but the RAM contents are not read there.
--
-- Emits into $SLOP_OUT:
--   mainram.bin      256 KB, the 386's RAM
--   tilemap_ram.bin  16 KB, MAME's post-DMA tilemap RAM
--   palette_ram.bin  12 KB
--   sprite_ram.bin   4 KB
--   frame.bin        screen bitmap, raw ARGB32, width*height*4
--   regs.txt         CRTC / DMA register state
--
-- Usage:
--   SLOP_OUT=/path SLOP_FRAME=600 mame rdfts -autoboot_script mame_capture.lua
--
local OUT    = os.getenv("SLOP_OUT")   or "."
local TARGET = tonumber(os.getenv("SLOP_FRAME") or "600")

local mach  = manager.machine
local space = mach.devices[":maincpu"].spaces["program"]

-- Shadow of the registers the video hardware latches. Updated by the tap; no
-- memory is read here.
local reg = {
    dma_src = 0, dma_len = 0,
    layer_enable = 0, rowscroll = 0, fore_d13 = 0, rf2_bank = 0,
    bx = 0, by = 0, mx = 0, my = 0, fx = 0, fy = 0,
}
local counts = { tilemap = 0, palette = 0, sprite = 0 }
local frames = 0

-- Main RAM shadow.
--
-- The DMA copies out of main RAM the instant it is triggered, and the game has
-- usually overwritten that RAM again by the time the frame notifier runs -- a
-- dump taken there disagrees with MAME's tilemap RAM for ~20% of entries. We
-- cannot read memory from inside the write tap either; that re-enters the
-- memory system and segfaults MAME.
--
-- So: one frame before the target, copy main RAM into a Lua table and start
-- tapping writes to it. From then on the shadow tracks RAM exactly, and the
-- DMA triggers can snapshot it with a pure table copy. The expensive tap is
-- only live for a single frame.
local shadow = nil
local cap = { tilemap = nil, palette = nil, sprite = nil }

local function shadow_grab(base, n)
    local t = {}
    for i = 0, n - 1 do t[#t+1] = string.char(shadow[base + i] or 0) end
    return table.concat(t)
end

-- NOTE: both the tap and the frame notifier must be stored in globals. If only
-- a local holds them the subscription is garbage collected once this chunk
-- finishes and they silently stop firing -- which looks exactly like the game
-- never touching the registers.
slop_tap = space:install_write_tap(0x400, 0x7ff, "spi_video_io", function(offset, data, mask)
    local dw = offset & 0xFFFFFFFC

    if dw == 0x418 and (mask & 0xFFFF0000) ~= 0 then
        local v = (data >> 16) & 0xFFFF
        reg.rowscroll = (v >> 15) & 1
        reg.fore_d13  = (v >> 11) & 1
    elseif dw == 0x41C and (mask & 0x0000FFFF) ~= 0 then
        reg.layer_enable = data & 0x1F
    elseif dw == 0x420 then
        if (mask & 0xFFFF) ~= 0     then reg.bx = data & 0xFFFF end
        if (mask & 0xFFFF0000) ~= 0 then reg.by = (data >> 16) & 0xFFFF end
    elseif dw == 0x424 then
        if (mask & 0xFFFF) ~= 0     then reg.mx = data & 0xFFFF end
        if (mask & 0xFFFF0000) ~= 0 then reg.my = (data >> 16) & 0xFFFF end
    elseif dw == 0x428 then
        if (mask & 0xFFFF) ~= 0     then reg.fx = data & 0xFFFF end
        if (mask & 0xFFFF0000) ~= 0 then reg.fy = (data >> 16) & 0xFFFF end
    elseif dw == 0x490 then
        reg.dma_len = data & 0xFFFF
    elseif dw == 0x494 then
        reg.dma_src = data & 0x3FFFF
    elseif dw == 0x68C and (mask & 0x00FF0000) ~= 0 then
        reg.rf2_bank = (data >> 16) & 7
    elseif dw == 0x480 then
        counts.tilemap = counts.tilemap + 1
        reg.tm_src, reg.tm_len, reg.tm_rs = reg.dma_src, reg.dma_len, reg.rowscroll
        if shadow then
            cap.tilemap = shadow_grab(reg.dma_src,
                                      (reg.rowscroll == 1) and 0x4000 or 0x2800)
        end
    elseif dw == 0x484 then
        counts.palette = counts.palette + 1
        reg.pal_src, reg.pal_len = reg.dma_src, reg.dma_len
        if shadow then
            cap.palette = shadow_grab(reg.dma_src, (reg.dma_len + 1) * 2)
        end
    elseif (dw == 0x50C or dw == 0x560) and (mask & 0xFFFF0000) ~= 0 then
        -- SEI252 boards trigger the sprite DMA at 0x50E, RISE10/11 at 0x562.
        counts.sprite = counts.sprite + 1
        reg.spr_src = reg.dma_src
        if shadow then cap.sprite = shadow_grab(reg.dma_src, 0x1000) end
    end
end)

-- MAME decrypts the graphics regions in place at init, so dumping one gives a
-- ground-truth decrypted image to check our fetch-time decryption against.
local function dump_region(tag, name, limit, start)
    local rg = mach.memory.regions[tag]
    if not rg then return 0 end
    start = start or 0
    local n = limit and math.min(limit, rg.size - start) or (rg.size - start)
    local t = {}
    for i = 0, n - 1 do t[#t+1] = string.char(rg:read_u8(start + i)) end
    local f = assert(io.open(OUT .. "/" .. name, "wb"))
    f:write(table.concat(t))
    f:close()
    return n
end

local function dump_share(tag, name)
    local sh = mach.memory.shares[tag]
    if not sh then return 0 end
    local t = {}
    for i = 0, sh.size - 1 do t[#t+1] = string.char(sh:read_u8(i)) end
    local f = assert(io.open(OUT .. "/" .. name, "wb"))
    f:write(table.concat(t))
    f:close()
    return sh.size
end

slop_frame_sub = emu.add_machine_frame_notifier(function()
    frames = frames + 1

    -- One frame early: snapshot main RAM and start tracking writes to it.
    if frames == TARGET - 1 then
        local sh = mach.memory.shares[":mainram"]
        shadow = {}
        for i = 0, sh.size - 1 do shadow[i] = sh:read_u8(i) end
        slop_ram_tap = space:install_write_tap(0x0, 0x3ffff, "spi_mainram_shadow",
            function(offset, data, mask)
                local a = offset & 0xFFFFFFFC
                if (mask & 0x000000FF) ~= 0 then shadow[a  ] =  data        & 0xFF end
                if (mask & 0x0000FF00) ~= 0 then shadow[a+1] = (data >>  8) & 0xFF end
                if (mask & 0x00FF0000) ~= 0 then shadow[a+2] = (data >> 16) & 0xFF end
                if (mask & 0xFF000000) ~= 0 then shadow[a+3] = (data >> 24) & 0xFF end
            end)
        return
    end

    if frames ~= TARGET then return end

    if counts.tilemap == 0 then
        print("SLOP: no tilemap DMA seen by frame " .. TARGET)
        mach:exit()
        return
    end

    if not (cap.tilemap and cap.palette) then
        print("SLOP: no DMA between frames " .. (TARGET-1) .. " and " .. TARGET)
        mach:exit()
        return
    end

    -- The DMA *sources*, sampled at trigger time from the shadow.
    local function wf(name, blob)
        local f = assert(io.open(OUT .. "/" .. name, "wb")); f:write(blob); f:close()
    end
    wf("dma_tilemap_src.bin", cap.tilemap)
    wf("dma_palette_src.bin", cap.palette)
    if cap.sprite then wf("dma_sprite_src.bin", cap.sprite) end

    dump_region(":maincpu", "maincpu.bin")
    dump_region(":chars", "chars_decrypted.bin")
    dump_region(":tiles", "tiles_decrypted_head.bin", 0x40000)
    dump_region(":tiles", "tiles_decrypted_bg2.bin", 0x40000, 0x480000)

    local n_main = dump_share(":mainram",     "mainram.bin")
    local n_tm   = dump_share(":tilemap_ram", "tilemap_ram.bin")
    local n_pal  = dump_share(":palette_ram", "palette_ram.bin")
    local n_spr  = dump_share(":sprite_ram",  "sprite_ram.bin")

    -- pixels() returns (data, width, height); assigning to one local keeps
    -- just the data, otherwise write() appends the dimensions as text.
    local scr = mach.screens:at(1)
    local px  = scr:pixels()
    local f = assert(io.open(OUT .. "/frame.bin", "wb"))
    f:write(px)
    f:close()

    f = assert(io.open(OUT .. "/regs.txt", "w"))
    f:write(string.format("frame %d\n", frames))
    f:write(string.format("screen %d %d\n", scr.width, scr.height))
    f:write(string.format("layer_enable %d\n", reg.layer_enable))
    f:write(string.format("rowscroll %d\n", reg.tm_rs or reg.rowscroll))
    f:write(string.format("fore_d13 %d\n", reg.fore_d13))
    f:write(string.format("rf2_bank %d\n", reg.rf2_bank))
    f:write(string.format("scroll_back %d %d\n", reg.bx, reg.by))
    f:write(string.format("scroll_midl %d %d\n", reg.mx, reg.my))
    f:write(string.format("scroll_fore %d %d\n", reg.fx, reg.fy))
    f:write(string.format("tilemap_dma %d %d\n", reg.tm_src or 0, reg.tm_len or 0))
    f:write(string.format("palette_dma %d %d\n", reg.pal_src or 0, reg.pal_len or 0))
    f:write(string.format("sprite_dma %d\n", reg.spr_src or 0))
    f:write(string.format("dma_counts %d %d %d\n",
                          counts.tilemap, counts.palette, counts.sprite))
    f:write(string.format("sizes %d %d %d %d\n", n_main, n_tm, n_pal, n_spr))
    f:close()

    print("SLOP: captured frame " .. frames)
    mach:exit()
end)
