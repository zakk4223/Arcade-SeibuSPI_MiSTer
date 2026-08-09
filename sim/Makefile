# Verilator unit tests for SlopperPI
VERILATOR ?= verilator
MAME      ?= $(HOME)/proj/mame
RTL       := ../rtl
TOOLS     := ../tools
VFLAGS    := -Wall -I$(RTL) -CFLAGS "-O2 -I.." lint.vlt --cc --exe --build -j 0 --quiet

.PHONY: all clean lint lint-top lint-sound capture run-ymf271 run-ymf271-math run-rom_loader run-tile_decrypt run-spr_decrypt run-video run-dma run-boot run-sdram

SLOP_BIAS ?= 1

# Golden-reference capture from MAME, used by run-video and run-dma. Neither is
# in `all` because both need this capture and a built SDRAM image, which are far
# too big to keep in the repo. `make capture` produces both:
#
#     make capture ROMS=~/Downloads          # then: make run-video
#
# FRAME picks the scene -- 600 is the early attract screen, 2400 the title with
# the jungle background and heavy sprite traffic. Capture your own rather than
# trusting one scene; PLAN.md 13 records two sprite bugs that a quiet scene hid.
CAP   ?= /tmp/slop_cap
ROMS  ?= $(HOME)/Downloads
FRAME ?= 2400
# A sibling of $(CAP), not inside it: the SDRAM image is built from the ROM set
# and is the same for every scene, so several captures share one.
SDRAM ?= $(CAP)/../sdram.bin

all: run-rom_loader run-tile_decrypt run-spr_decrypt run-ymf271-math run-ymf271

# The sound subsystem on its own, which is quicker to iterate on than the top.
lint-sound:
	$(VERILATOR) --lint-only -Wall -I$(RTL) lint.vlt --top-module spi_sound $(SOUND_SRCS)


# The YMF271 step and envelope arithmetic against MAME's doubles, exhaustively.
# No RTL involved -- it checks the algebra ymf271_pcm.sv is built on.
# The PCM engine driven through the chip's own register interface. The Z80 is
# VHDL and cannot be simulated here, so this stands in for the sound driver.
run-ymf271: obj_dir/Vymf271
	@./obj_dir/Vymf271

obj_dir/Vymf271: $(RTL)/ymf271.sv $(RTL)/ymf271_synth.sv $(RTL)/ymf271_tables.vh \
                 $(RTL)/spi_defs.vh tb_ymf271.cpp lint.vlt
	$(VERILATOR) $(VFLAGS) --top-module ymf271 $(RTL)/ymf271.sv $(RTL)/ymf271_synth.sv \
	    tb_ymf271.cpp

run-ymf271-math: $(RTL)/ymf271_tables.vh
	@python3 $(TOOLS)/check_ymf271_math.py $(MAME)

# Reference implementation copied verbatim out of MAME.
spi_ref.h: $(TOOLS)/gen_ref_c.py
	python3 $< $(MAME) > $@

# Sprite decrypt tables parsed out of MAME.
$(RTL)/spi_spr_tables.vh: $(TOOLS)/gen_spi_tables.py
	python3 $< $(MAME) > $@

# YMF271 fixed-point tables, likewise.
$(RTL)/ymf271_tables.vh: $(TOOLS)/gen_ymf271_tables.py
	python3 $< $(MAME) > $@

run-rom_loader: obj_dir/Vrom_loader
	@./obj_dir/Vrom_loader

run-tile_decrypt: obj_dir/Vspi_tile_decrypt
	@./obj_dir/Vspi_tile_decrypt

run-spr_decrypt: obj_dir/Vspi_spr_decrypt
	@./obj_dir/Vspi_spr_decrypt

# Produce the golden capture and the SDRAM image the two reference tests need.
# The bitmap is taken one frame after the video RAM snapshot, deliberately --
# see PLAN.md 12, it is the trap that made ~20% of tilemap entries look wrong.
capture:
	@mkdir -p $(CAP)
	cd $(MAME) && SLOP_OUT=$(abspath $(CAP)) SLOP_FRAME=$(FRAME) ./mame rdfts \
	    -rompath $(ROMS) -autoboot_script $(abspath $(TOOLS))/mame_capture.lua \
	    -video none -sound none -seconds_to_run 45 -nothrottle
	python3 $(TOOLS)/build_sdram_image.py $(ROMS)/rdft.zip $(SDRAM)
	@echo "capture in $(CAP), sdram image $(SDRAM)"

# Golden-reference tests. Need a capture from tools/mame_capture.lua in $(CAP).
run-dma: obj_dir/Vspi_dma
	@./obj_dir/Vspi_dma $(CAP)

obj_dir/Vspi_dma: $(RTL)/spi_dma.sv tb_dma.cpp lint.vlt
	$(VERILATOR) $(VFLAGS) --top-module spi_dma $(RTL)/spi_dma.sv tb_dma.cpp

run-video: obj_dir/Vtb_video_top
	@./obj_dir/Vtb_video_top $(CAP) $(SDRAM)

obj_dir/Vtb_video_top: tb_video_top.sv tb_video.cpp lint.vlt \
                       $(RTL)/spi_layers.sv $(RTL)/spi_mixer.sv $(RTL)/spi_dpram.sv \
                       $(RTL)/spi_video_timing.sv $(RTL)/spi_tile_decrypt.sv \
                       $(RTL)/spi_sprite.sv $(RTL)/spi_spr_decrypt.sv \
                       $(RTL)/spi_spr_tables.vh \
                       $(RTL)/seibu_partial_add.sv
	$(VERILATOR) $(VFLAGS) -LDFLAGS "-lz" --top-module tb_video_top tb_video_top.sv \
	    $(RTL)/spi_layers.sv $(RTL)/spi_mixer.sv $(RTL)/spi_dpram.sv \
	    $(RTL)/spi_video_timing.sv $(RTL)/spi_tile_decrypt.sv \
	    $(RTL)/spi_sprite.sv $(RTL)/spi_spr_decrypt.sv \
	    $(RTL)/seibu_partial_add.sv tb_video.cpp

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

# T80s.sv here is the Verilator stand-in; Quartus builds the VHDL core instead.
SOUND_SRCS := $(RTL)/spi_sound.sv $(RTL)/ymf271.sv $(RTL)/ymf271_synth.sv T80s.sv

CORE_SRCS := $(RTL)/spi_top.sv $(RTL)/spi_video_timing.sv $(RTL)/spi_cpu.sv \
             $(RTL)/spi_io.sv $(RTL)/spi_mainram.sv $(RTL)/spi_reset_sync.sv \
             $(RTL)/spi_dpram.sv $(RTL)/spi_dma.sv $(RTL)/spi_layers.sv \
             $(RTL)/spi_mixer.sv $(RTL)/spi_tile_decrypt.sv \
             $(RTL)/seibu_partial_add.sv $(SOUND_SRCS)

lint:
	$(VERILATOR) --lint-only -Wall -I$(RTL) -I$(RTL)/z386 lint.vlt --top-module spi_top \
	    $(CORE_SRCS) $(Z386_SRCS)

# SeibuSPI.sv was never linted, and that is where a 32-bit declaration of a
# 64-bit SDRAM data bus went unnoticed: Quartus only warns on width mismatches,
# and the testbenches declare their own ports correctly so simulation was blind
# to it. WIDTHTRUNC/WIDTHEXPAND are the checks that matter here.
# -DMISTER_FB must match the QSF's VERILOG_MACRO settings. Without it this
# lints a DIFFERENT configuration than Quartus builds -- the framebuffer ports
# vanish and their drivers become implicit wires -- which defeats the whole
# point of a target that exists to check the integration file.
lint-top:
	$(VERILATOR) --lint-only -Wall -DMISTER_FB -I$(RTL) -I$(RTL)/z386 -I.. lint.vlt \
	    --top-module emu ../SeibuSPI.sv $(CORE_SRCS) $(Z386_SRCS) \
	    $(RTL)/spi_sprite.sv $(RTL)/spi_spr_decrypt.sv $(RTL)/spi_debug.sv \
	    $(RTL)/spi_romcheck.sv $(RTL)/sdram.sv $(RTL)/rom_loader.sv \
	    $(RTL)/spi_sdr_arb2.sv 2>&1 | \
	    grep -E "WIDTHTRUNC|WIDTHEXPAND|IMPLICIT|PINMISSING" || echo "no width or pin problems"


# Boots the real 386 against the real SDRAM image. STEPS is clk_ram half-steps.
STEPS ?= 40000000
run-boot: obj_dir/Vtb_boot_top
	@./obj_dir/Vtb_boot_top $(SDRAM) $(STEPS)

obj_dir/Vtb_boot_top: tb_boot_top.sv tb_boot.cpp lint.vlt $(CORE_SRCS) $(Z386_SRCS) \
                      $(RTL)/spi_sprite.sv $(RTL)/spi_spr_decrypt.sv $(RTL)/spi_debug.sv \
                      $(RTL)/spi_spr_tables.vh
	$(VERILATOR) $(VFLAGS) -I$(RTL)/z386 --top-module tb_boot_top \
	    tb_boot_top.sv $(CORE_SRCS) $(Z386_SRCS) \
	    $(RTL)/spi_sprite.sv $(RTL)/spi_spr_decrypt.sv $(RTL)/spi_debug.sv tb_boot.cpp


# Streams the real ROM image through rom_loader -> rtl/sdram.sv -> a behavioural
# SDRAM chip, then reads it all back. The download path is the one thing that
# runs on hardware before the 386 starts and that nothing else here covers.
CONCAT ?= $(CAP)/../rom_concat.bin
run-sdram: obj_dir/Vtb_sdram_top
	@./obj_dir/Vtb_sdram_top $(SDRAM) $(CONCAT)

obj_dir/Vtb_sdram_top: tb_sdram_top.sv tb_sdram.cpp sdram_model.sv altddio_out.sv \
                       $(RTL)/sdram.sv $(RTL)/rom_loader.sv $(RTL)/spi_defs.vh lint.vlt
	$(VERILATOR) $(VFLAGS) --top-module tb_sdram_top \
	    tb_sdram_top.sv sdram_model.sv altddio_out.sv \
	    $(RTL)/sdram.sv $(RTL)/rom_loader.sv tb_sdram.cpp


# spi_romcheck is the instrument that reports whether the hardware download
# worked, so it gets its own test.
run-romcheck: obj_dir/Vspi_romcheck
	@./obj_dir/Vspi_romcheck $(SDRAM)

obj_dir/Vspi_romcheck: $(RTL)/spi_romcheck.sv $(RTL)/spi_defs.vh tb_romcheck.cpp lint.vlt
	$(VERILATOR) $(VFLAGS) --top-module spi_romcheck $(RTL)/spi_romcheck.sv tb_romcheck.cpp

clean:
	rm -rf obj_dir spi_ref.h
