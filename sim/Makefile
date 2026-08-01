# Verilator unit tests for SlopperPI
VERILATOR ?= verilator
MAME      ?= $(HOME)/proj/mame
RTL       := ../rtl
TOOLS     := ../tools
VFLAGS    := -Wall -I$(RTL) -CFLAGS "-O2 -I.." lint.vlt --cc --exe --build -j 0 --quiet

.PHONY: all clean lint run-rom_loader run-tile_decrypt run-spr_decrypt

CAP ?= /tmp/claude-1000/-home-zakk-proj-SlopperPI/efc84222-a8fe-4ba8-9ca2-3a1f50422bb8/scratchpad/cap

all: run-rom_loader run-tile_decrypt run-spr_decrypt

# Reference implementation copied verbatim out of MAME.
spi_ref.h: $(TOOLS)/gen_ref_c.py
	python3 $< $(MAME) > $@

# Sprite decrypt tables parsed out of MAME.
$(RTL)/spi_spr_tables.vh: $(TOOLS)/gen_spi_tables.py
	python3 $< $(MAME) > $@

run-rom_loader: obj_dir/Vrom_loader
	@./obj_dir/Vrom_loader

run-tile_decrypt: obj_dir/Vspi_tile_decrypt
	@./obj_dir/Vspi_tile_decrypt

run-spr_decrypt: obj_dir/Vspi_spr_decrypt
	@./obj_dir/Vspi_spr_decrypt

# Golden-reference tests. Need a capture from tools/mame_capture.lua in $(CAP).
run-dma: obj_dir/Vspi_dma
	@./obj_dir/Vspi_dma $(CAP)

obj_dir/Vspi_dma: $(RTL)/spi_dma.sv tb_dma.cpp lint.vlt
	$(VERILATOR) $(VFLAGS) --top-module spi_dma $(RTL)/spi_dma.sv tb_dma.cpp

obj_dir/Vrom_loader: $(RTL)/rom_loader.sv $(RTL)/spi_defs.vh tb_rom_loader.cpp lint.vlt
	$(VERILATOR) $(VFLAGS) --top-module rom_loader $(RTL)/rom_loader.sv tb_rom_loader.cpp

obj_dir/Vspi_tile_decrypt: $(RTL)/spi_tile_decrypt.sv $(RTL)/seibu_partial_add.sv tb_tile_decrypt.cpp spi_ref.h lint.vlt
	$(VERILATOR) $(VFLAGS) --top-module spi_tile_decrypt \
	    $(RTL)/spi_tile_decrypt.sv $(RTL)/seibu_partial_add.sv tb_tile_decrypt.cpp

obj_dir/Vspi_spr_decrypt: $(RTL)/spi_spr_decrypt.sv $(RTL)/seibu_partial_add.sv $(RTL)/spi_spr_tables.vh tb_spr_decrypt.cpp spi_ref.h lint.vlt
	$(VERILATOR) $(VFLAGS) --top-module spi_spr_decrypt \
	    $(RTL)/spi_spr_decrypt.sv $(RTL)/seibu_partial_add.sv tb_spr_decrypt.cpp

# z386_pkg.sv must come first: it declares the types the rest reference.
Z386_SRCS := $(RTL)/z386/z386_pkg.sv $(RTL)/z386/z386.sv $(RTL)/z386/l1_cache.sv \
             $(RTL)/z386/l1_icache.sv $(RTL)/z386/alu.sv $(RTL)/z386/alu_alt.sv \
             $(RTL)/z386/biu.sv $(RTL)/z386/decoder.sv $(RTL)/z386/dsp_mul.sv \
             $(RTL)/z386/paging_tlb.sv $(RTL)/z386/paging_unit.sv \
             $(RTL)/z386/paging_walker.sv $(RTL)/z386/prefetch.sv \
             $(RTL)/z386/protection.sv $(RTL)/z386/segmentation_unit.sv \
             $(RTL)/z386/ucode_rom.sv

CORE_SRCS := $(RTL)/spi_top.sv $(RTL)/spi_video_timing.sv $(RTL)/spi_cpu.sv \
             $(RTL)/spi_io.sv $(RTL)/spi_mainram.sv $(RTL)/spi_reset_sync.sv \
             $(RTL)/spi_dpram.sv $(RTL)/spi_dma.sv $(RTL)/spi_layers.sv \
             $(RTL)/spi_mixer.sv $(RTL)/spi_tile_decrypt.sv \
             $(RTL)/seibu_partial_add.sv

lint:
	$(VERILATOR) --lint-only -Wall -I$(RTL) -I$(RTL)/z386 lint.vlt --top-module spi_top \
	    $(CORE_SRCS) $(Z386_SRCS)

clean:
	rm -rf obj_dir spi_ref.h
