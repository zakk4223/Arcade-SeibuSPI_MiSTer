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

# ---------------------------------------------------------------------------
# The DS2404 command-arm register (clk_ram)
# ---------------------------------------------------------------------------
# `spi_ds2404|arm[]` is the tightest SETUP path in the design -- sptr/st -> arm
# at 114.5 MHz, chronically within a few ps of zero and the path that dictates
# the fitter SEED (spi_ds2404.sv:211 records the earlier -0.198 ns fight; a
# 6-seed sweep found it caps near +0.004). It is genuinely a MULTICYCLE path,
# not a marginal single-cycle one:
#
#   arm is written ONLY on a 1-wire request edge (req_edge, the toggle-
#   synchronised strobe from the 386 via spi_io). Its launch registers -- the
#   state stack st[], sptr, and the held din/port bytes -- change only on the
#   PREVIOUS such edge. spi_io holds req until this chip acks, and the 386
#   executes a full I/O instruction between DS2404 accesses, so consecutive
#   req_edges are hundreds of clk_ram cycles apart. arm's inputs are therefore
#   quasi-static: stable for far more than one clk_ram period before each
#   capture, and the single-cycle requirement TimeQuest assumes is pessimistic.
#   The consuming path OUT of arm (arm -> address next cycle) is left single-
#   cycle -- correct, it really is consumed the following cycle -- by scoping
#   this only to paths ENDING at arm.
#
# Two clk_ram periods is what the hardware demonstrably gives it. This retires
# the chronic-seed problem so the design closes on the canonical SEED again.
set_multicycle_path -setup -end 2 -to [get_registers {*spi_ds2404*|arm[*]}]
set_multicycle_path -hold  -end 1 -to [get_registers {*spi_ds2404*|arm[*]}]

# ---------------------------------------------------------------------------
# Handshake-qualified payloads across the phase-aligned domains
# ---------------------------------------------------------------------------
# clk_ram, clk_sys and clk_cpu are 4:2:1 off one PLL and phase aligned
# (rtl/pll.v), so every clk_sys edge coincides with a clk_ram edge and every
# clk_cpu edge with both. TimeQuest therefore checks HOLD between them on a
# coincident launch/capture pair -- the pessimistic case, where a datum
# launched on one domain is assumed to race into the other's flop on that very
# edge. Nothing here actually does that: every payload below is qualified by a
# handshake and is quasi-static across the capture.
#
# These are the paths that tip. Seed 3 fails HOLD by 0.798 ns on the ss_bridge
# read return; seed 5 passes that one and fails by 0.286 ns on the ch3
# arbiter's address instead, with the bridge's outbound address left at +0.200.
# Same family, a different victim per fit, in a design at 95% ALMs and 95% RAM
# blocks where placement alone decides which one loses. Chasing it with the
# fitter SEED treats the symptom; this states the contract the RTL already
# keeps.
#
# HOLD ONLY. Setup on every one of these is genuinely single-cycle -- the
# payload really is expected by the next capture edge -- and is left fully
# checked. One destination period of hold relaxation claims far less than the
# hardware gives: both mechanisms hold their payload for a whole transaction.
#
# THIS IS IN TENSION WITH THE ioctl BLOCK ABOVE, which deliberately leaves
# payload registers timed on the grounds that a strobe qualifies them and they
# therefore have real setup and hold requirements. Read together the two are
# consistent, and the line between them is worth stating so it is not
# rediscovered as a contradiction. There the payload is cut from NOTHING: both
# checks stay. Here only the hold check goes, and only by one period. A hold
# check is real coverage when the payload can change near the capture edge --
# the ioctl case, where the qualifying strobe is only two synchroniser stages
# away. It is an artefact when the payload cannot change anywhere near it: the
# bridge holds for six of its seven cycles and the arbiter for a whole SDRAM
# round trip, so no edge exists at which new data could race the capture. What
# the phase alignment produces there is a coincident launch/capture pair and a
# check with nothing behind it. Setup is what still carries the coverage, and
# setup is what is kept.
#
# ss_bridge (rtl/spi_ss_bridge.sv). The phase machine latches ram_addr and
# ram_din at ph 0 and holds them through ph 6, and answers the ssbus with
# ram_dout at ph 6 after a two-cycle settle window. Seven clk_sys cycles an
# item, with both directions stable for six of them.
#
# spi_sdr_arb4 (rtl/spi_sdr_arb4.sv). a_/b_/c_/d_ addr, din and be are set by
# the requester on the same edge it flips its `req` toggle, and held until the
# matching `ack` comes back -- a whole SDRAM round trip. The arbiter cannot
# capture a payload before it has seen the toggle, which is one clk_ram period
# after that payload settled at the earliest. The `req` toggles themselves are
# NOT relaxed: they are the qualifier that makes the payload quasi-static, and
# their own timing has to go on being checked. Nor is m_rnw, which the arbiter
# drives from its own constants and which crosses nothing.
set_multicycle_path -hold -end 1 -to   [get_registers {*spi_ss_bridge*|ssbus.data_out[*]}]
set_multicycle_path -hold -end 1 -from [get_registers {*spi_ss_bridge*|ram_addr[*]}]
set_multicycle_path -hold -end 1 -from [get_registers {*spi_ss_bridge*|ram_din[*]}]
set_multicycle_path -hold -end 1 -to   [get_registers {*spi_sdr_arb4*|m_addr[*]}]
set_multicycle_path -hold -end 1 -to   [get_registers {*spi_sdr_arb4*|m_din[*]}]
set_multicycle_path -hold -end 1 -to   [get_registers {*spi_sdr_arb4*|m_be[*]}]
