# SlopperPI - Seibu SPI / SXX2E for MiSTer

QUARTUS_DIR ?= $(HOME)/intelFPGA_lite/17.0/quartus/bin
PROJECT     := SeibuSPI

.PHONY: all build map fit asm sta timing clean lint test check-mra verify

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

test:
	@$(MAKE) -C sim

# The MRA carries no scatter information -- rom_loader.sv infers all of it from
# the part INDEX -- so a reordered or dropped part loads to the wrong address
# with no error anywhere. This checks the MRA, the RTL table and MAME's driver
# all agree. Pass ZIP=... to also confirm the parts resolve out of an archive.
#   make check-mra ZIP=~/Downloads/rdft.zip
check-mra:
	@python3 tools/check_mra.py $(if $(ZIP),--zip $(ZIP))

# Everything that can be checked without a Quartus run or a MiSTer.
verify: lint check-mra test

clean:
	rm -rf db incremental_db output_files
	$(MAKE) -C sim clean
