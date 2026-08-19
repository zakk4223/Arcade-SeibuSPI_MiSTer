derive_pll_clocks
derive_clock_uncertainty

# Core specific constraints.
#
# SDRAM I/O timing is deliberately left to the framework, as in every shipping
# MiSTer arcade core: sys/sys.tcl fixes the pin locations and sys/sys_top.sdc
# groups the clock domains. Adding hand-written generated-clock constraints here
# only risks disagreeing with the framework.

# ---------------------------------------------------------------------------
# The ioctl crossing into spi_nvram
# ---------------------------------------------------------------------------
# hps_io runs on clk_sys, spi_nvram on clk_ram, and both come off the same PLL --
# so TimeQuest times the transfer between them instead of ignoring it, and a fit
# from a cold elaboration failed HOLD by 0.136 ns on `ioctl_upload` reaching the
# flop that samples it. PLAN.md 37.
#
# The receiving side is a three-flop synchroniser now, which is what makes the
# transfer correct; this is what makes it honest. There is nothing useful the
# analyser can say about the first capture of an asynchronous signal, and leaving
# it timed means the design passes or fails on where the fitter happened to put
# one flop.
#
# TARGETED AT THE SYNCHRONISER'S FIRST STAGE, and deliberately not at the clock
# pair. `set_false_path -from clk_sys -to clk_ram` would cut this path and also
# every legitimate timed transfer between those domains -- the settled config
# registers, the video and sound interfaces -- which is a large amount of real
# coverage traded for one fix. Naming the destination flops cuts exactly the paths
# that are asynchronous by construction and nothing else.
#
# The payload registers are NOT cut: they are qualified by a strobe that arrives
# two stages later, so they have real setup and hold requirements that the
# analyser should keep checking.
set_false_path -to [get_registers {*spi_nvram*|ioctl_wr_s1}]
set_false_path -to [get_registers {*spi_nvram*|ioctl_rd_s1}]
set_false_path -to [get_registers {*spi_nvram*|ioctl_upload_s1}]
set_false_path -to [get_registers {*spi_nvram*|ioctl_dl_s1}]
