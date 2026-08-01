# Verilator unit tests for SlopperPI
VERILATOR ?= verilator
RTL       := ../rtl
VFLAGS    := -Wall -I$(RTL) lint.vlt --cc --exe --build -j 0 \
             -CFLAGS "-O2" -Wno-fatal --quiet

TESTS := rom_loader

.PHONY: all clean $(addprefix run-,$(TESTS))

all: $(addprefix run-,$(TESTS))

run-rom_loader: obj_dir/Vrom_loader
	@./obj_dir/Vrom_loader

obj_dir/Vrom_loader: $(RTL)/rom_loader.sv $(RTL)/spi_defs.vh tb_rom_loader.cpp lint.vlt
	$(VERILATOR) $(VFLAGS) --top-module rom_loader $(RTL)/rom_loader.sv tb_rom_loader.cpp

clean:
	rm -rf obj_dir
