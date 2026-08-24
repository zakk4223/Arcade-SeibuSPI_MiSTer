--
-- SeibuSPI - log every YMF271 register write the sound Z80 makes.
--
--   SLOP_OUT=/tmp/mame_ymf.txt SLOP_SECS=60 mame rdft \
--       -rompath ~/Downloads -autoboot_script tools/mame_ymf_trace.lua \
--       -video none -sound none -nothrottle -skip_gameinfo
--
-- This is the measurement a Z80 SWAP wants, and it is sharper than correlating
-- audio. The YMF271 synthesis is already verified against MAME on its own
-- (`make -C sim run-ymf271`); what changed when T80 became tv80 is only what
-- the sound CPU WRITES to the chip and when. So tap that stream on both sides
-- and compare it directly: a difference names the register and the write
-- index, where an audio correlation would only say the number got worse.
--
-- The tap sits at 0x6000-0x600F on the audio CPU's own space, which is exactly
-- where rtl/spi_sound.sv decodes `sel_ymf` -- the same point in the same map,
-- so the two logs are the same events and not two views of different ones.
--
-- Each line is
--
--     <sample index> <port> <data>
--
-- with the sample index in 44,100 Hz ticks, the chip's own output rate and the
-- unit the simulator counts in. It is written for ALIGNMENT, not for equality:
-- the two machines do not leave reset at the same instant and nothing here
-- claims they do. tools/compare_ymf_trace.py aligns on the write stream and
-- then reports how far the timing drifts.
--
local OUT  = os.getenv("SLOP_OUT")  or "/tmp/mame_ymf.txt"
local SECS = tonumber(os.getenv("SLOP_SECS") or "60")

local mach   = manager.machine
local zspace = mach.devices[":audiocpu"].spaces["program"]

local f = io.open(OUT, "w")
local n = 0

-- Buffered: at a few thousand writes a second an unbuffered io.write costs
-- more than the emulation does.
local buf, buf_n = {}, 0

slop_ymf = zspace:install_write_tap(0x6000, 0x600f, "slop_ymf", function(offset, data, mask)
    n = n + 1
    buf_n = buf_n + 1
    buf[buf_n] = string.format("%d %X %02X\n",
        math.floor(mach.time:as_double() * 44100),
        offset & 0xF, data & 0xFF)
    if buf_n >= 4096 then
        f:write(table.concat(buf)); buf, buf_n = {}, 0
    end
end)

local function report()
    if buf_n > 0 then f:write(table.concat(buf)); buf, buf_n = {}, 0 end
    f:close()
    print(string.format("YMF271 register writes : %d", n))
    print(string.format("wrote %s", OUT))
end

emu.add_machine_stop_notifier(report)
emu.register_periodic(function()
    if mach.time.seconds >= SECS then report(); mach:exit() end
end)
