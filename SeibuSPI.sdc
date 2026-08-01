derive_pll_clocks
derive_clock_uncertainty

# Core specific constraints.
#
# SDRAM I/O timing is deliberately left to the framework, as in every shipping
# MiSTer arcade core: sys/sys.tcl fixes the pin locations and sys/sys_top.sdc
# groups the clock domains. Adding hand-written generated-clock constraints here
# only risks disagreeing with the framework.
