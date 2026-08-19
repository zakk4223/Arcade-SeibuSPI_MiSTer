# SeibuSPI - Seibu SPI / SXX2E for MiSTer

QUARTUS_DIR ?= $(HOME)/intelFPGA_lite/17.0/quartus/bin
PROJECT     := SeibuSPI

.PHONY: all build map fit asm sta timing clean lint test check-mra check-snd01 \
        check-derive check-tb mras check-clones verify

all: build

# Full compile -> output_files/$(PROJECT).rbf
build:
	$(QUARTUS_DIR)/quartus_sh --flow compile $(PROJECT)

# Analysis & synthesis only - much faster, catches RTL errors
map:
	$(QUARTUS_DIR)/quartus_map $(PROJECT)

fit:
	$(QUARTUS_DIR)/quartus_fit $(PROJECT)

asm:
	$(QUARTUS_DIR)/quartus_asm $(PROJECT)

sta:
	$(QUARTUS_DIR)/quartus_sta $(PROJECT)

# Name the worst paths. The Setup Summary gives slack but not endpoints, and
# the .sta.rpt has no path listing, so a failing build otherwise says only how
# badly and on which clock.
timing:
	@$(QUARTUS_DIR)/quartus_sta -t tools/timing_paths.tcl 2>&1 | \
	    grep -vE "^Info|^\s+Info|^Warning"

lint:
	@$(MAKE) -C sim lint

# BUILD every testbench without running any. Three of them had silently stopped
# building when their modules grew ports, and tb_boot_top did it again the moment
# spi_top grew the DS2404's SRAM port -- a bench that fails to build looks exactly
# like one nobody ran. Cheap enough to be part of `verify`.
check-tb:
	@$(MAKE) -C sim check-tb

test:
	@$(MAKE) -C sim

# The MRA carries no scatter information -- rom_loader.sv infers all of it from
# the part INDEX -- so a reordered or dropped part loads to the wrong address
# with no error anywhere. This checks the MRA, the RTL table and MAME's driver
# all agree. Pass ZIP=... to also confirm the parts resolve out of an archive.
# With ZIP, pass SET too: --zip alone holds EVERY set against that one archive,
# so a single-game zip reports every other set's parts missing.
#   make check-mra
#   make check-mra ZIP=~/Downloads/rdft2.zip SET=rdft2
check-mra:
	@python3 tools/check_mra.py $(if $(ZIP),--zip "$(ZIP)") $(if $(SET),--set $(SET))

# The 386's sound01 window, which the authentic-flash MRAs need and which fails
# SILENTLY when it is wrong -- an undecoded window reads as zero and the game's
# sample-flash updater programs the zeroes without complaining. Checks
# spi_cpu.sv's arithmetic over the whole 10 MB region against MAME's own
# layout, so it needs ROMs and cannot be part of `verify`.
#   make check-snd01 ZIP=~/Downloads/rdft.zip
#   make check-snd01 ROMS=~/Downloads/roms
check-snd01:
	@python3 tools/check_snd01_window.py \
	    $(if $(ROMS),--all "$(ROMS)",$(if $(ZIP),"$(ZIP)",--help))

# The sample flash, derived from an SDRAM IMAGE alone, checked against the same
# image derived from the ROM set. This is the premise the single-MRA plan rests
# on -- the core deriving its own flash at reset instead of an MRA assembling it
# or the game spending six minutes programming it -- and the acceptance test the
# RTL walker will have to pass. Needs ROMs, so it cannot be part of `verify`.
#   make check-derive ROMS=~/Downloads/roms
#   make check-derive ZIP=~/Downloads/rdft2.zip IMAGE=/tmp/rdft2-upd.bin
check-derive:
	@python3 tools/check_flash_derive.py \
	    $(if $(ROMS),--all "$(ROMS)",$(if $(ZIP),"$(ZIP)" "$(IMAGE)" $(if $(SET),--set $(SET)),--help))

# Regenerate the clone MRAs from MAME's driver. Every one of them is a rename of
# its parent's part list plus its own job-table address, so they are generated
# rather than maintained. The six hand-written cartridge MRAs are the fixtures:
# gen_mras.py emits each of them too and refuses to write anything if what it
# emits no longer matches the file that is already on hardware.
#   make mras
#   make mras MRAFLAGS=--list      # what is supported, and why the rest is not
mras:
	@python3 tools/gen_mras.py $(MRAFLAGS)

# The clone MRAs' one per-set constant, re-derived from the ROMs: find each job
# table two independent ways, check the region code three ways, then build the
# flash and require it to be the parent's payload byte for byte. A wrong job
# table does not fail loudly on hardware -- spi_flash_derive rejects the bad
# source and the game quietly runs its own six-minute updater instead -- so this
# is the check that matters. Needs ROMs, so it is not part of `verify`.
#   make check-clones ROMS=~/Downloads/roms
check-clones:
	@python3 tools/gen_mras.py --verify "$(ROMS)"

# Everything that can be checked without a Quartus run or a MiSTer.
verify: lint check-mra check-tb test

clean:
	rm -rf db incremental_db output_files
	$(MAKE) -C sim clean
