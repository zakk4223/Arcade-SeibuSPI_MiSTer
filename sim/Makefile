# Verilator unit tests for SlopperPI
VERILATOR ?= verilator
MAME      ?= $(HOME)/proj/mame
RTL       := ../rtl
TOOLS     := ../tools
VFLAGS    := -Wall -I$(RTL) -CFLAGS "-O2 -I.." lint.vlt --cc --exe --build -j 0 --quiet

.PHONY: all clean lint run-rom_loader run-tile_decrypt run-spr_decrypt

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

obj_dir/Vrom_loader: $(RTL)/rom_loader.sv $(RTL)/spi_defs.vh tb_rom_loader.cpp lint.vlt
	$(VERILATOR) $(VFLAGS) --top-module rom_loader $(RTL)/rom_loader.sv tb_rom_loader.cpp

obj_dir/Vspi_tile_decrypt: $(RTL)/spi_tile_decrypt.sv $(RTL)/seibu_partial_add.sv tb_tile_decrypt.cpp spi_ref.h lint.vlt
	$(VERILATOR) $(VFLAGS) --top-module spi_tile_decrypt \
	    $(RTL)/spi_tile_decrypt.sv $(RTL)/seibu_partial_add.sv tb_tile_decrypt.cpp

obj_dir/Vspi_spr_decrypt: $(RTL)/spi_spr_decrypt.sv $(RTL)/seibu_partial_add.sv $(RTL)/spi_spr_tables.vh tb_spr_decrypt.cpp spi_ref.h lint.vlt
	$(VERILATOR) $(VFLAGS) --top-module spi_spr_decrypt \
	    $(RTL)/spi_spr_decrypt.sv $(RTL)/seibu_partial_add.sv tb_spr_decrypt.cpp

lint:
	$(VERILATOR) --lint-only -Wall -I$(RTL) lint.vlt --top-module spi_top \
	    $(RTL)/spi_top.sv $(RTL)/spi_video_timing.sv

clean:
	rm -rf obj_dir spi_ref.h
