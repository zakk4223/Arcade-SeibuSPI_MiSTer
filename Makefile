# SlopperPI - Seibu SPI / SXX2E for MiSTer

QUARTUS_DIR ?= $(HOME)/intelFPGA_lite/17.0/quartus/bin
PROJECT     := SeibuSPI

.PHONY: all build map fit asm sta clean lint test

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

lint:
	@$(MAKE) -C sim lint

test:
	@$(MAKE) -C sim

clean:
	rm -rf db incremental_db output_files
	$(MAKE) -C sim clean
