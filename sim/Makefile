# Verilator unit tests for SeibuSPI
VERILATOR ?= verilator
MAME      ?= $(HOME)/proj/mame
RTL       := ../rtl
TOOLS     := ../tools
VFLAGS    := -Wall -I$(RTL) -CFLAGS "-O2 -I.." lint.vlt --cc --exe --build -j 0 --quiet

.PHONY: all check-tb clean lint lint-top lint-sound lint-derive capture run-ddr_rom_reader run-rom_decode run-bpe run-ymf271 run-ymf271-math run-rom_loader run-snd_window run-tile_decrypt run-spr_decrypt run-rise10 run-rise11 run-video run-dma run-boot run-sound run-sdram run-timing

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

all: run-rom_decode run-ddr_rom_reader run-rom_loader run-snd_window run-tile_decrypt run-spr_decrypt run-rise10 run-rise11 run-ymf271-math run-ymf271 run-nvram run-ds2404 run-timing

# The sound subsystem on its own, which is quicker to iterate on than the top.
lint-sound:
	$(VERILATOR) --lint-only -Wall -I$(RTL) lint.vlt --top-module spi_sound $(SOUND_SRCS)

# The flash derivation is not instantiated in spi_top yet, so `lint` above does
# not reach it. Until it is, lint it on its own or a break goes unnoticed until
# someone runs the testbench.
lint-derive:
	$(VERILATOR) --lint-only -Wall -I$(RTL) lint.vlt --top-module spi_flash_derive \
	    $(RTL)/spi_flash_derive.sv $(RTL)/spi_snd_window.sv $(RTL)/spi_rom_decode.sv


# The YMF271 step and envelope arithmetic against MAME's doubles, exhaustively.
# No RTL involved -- it checks the algebra ymf271_pcm.sv is built on.
# The PCM engine driven through the chip's own register interface. The Z80 is
# VHDL and cannot be simulated here, so this stands in for the sound driver.
run-ymf271: obj_dir/Vtb_ymf_top
	@./obj_dir/Vtb_ymf_top

# The fast-load path: a DDR3 image replayed as the byte stream rom_loader
# expects. This is the part of the ioctl download that CAN be simulated now,
# and PLAN.md 10c is what not simulating it cost last time.
run-ddr_rom_reader: obj_dir/Vddr_rom_reader
	@./obj_dir/Vddr_rom_reader

obj_dir/Vddr_rom_reader: $(RTL)/ddr_rom_reader.sv tb_ddr_rom_reader.cpp lint.vlt
	$(VERILATOR) $(VFLAGS) --top-module ddr_rom_reader $(RTL)/ddr_rom_reader.sv \
	    tb_ddr_rom_reader.cpp

obj_dir/Vtb_ymf_top: $(RTL)/ymf271.sv $(RTL)/ymf271_synth.sv $(RTL)/ymf271_tables.vh \
                 $(RTL)/spi_soundflash.sv $(RTL)/spi_nvram.sv $(RTL)/spi_defs.vh tb_ymf_top.sv \
                 tb_ymf271.cpp lint.vlt
	$(VERILATOR) $(VFLAGS) --top-module tb_ymf_top tb_ymf_top.sv \
	    $(RTL)/system_consts.sv $(RTL)/savestates.sv \
	    $(RTL)/ymf271.sv $(RTL)/ymf271_synth.sv $(RTL)/spi_soundflash.sv $(RTL)/spi_nvram.sv \
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

# The 386's view of MAME's sound01 region, checked against MAME's own scatter
# rule over every dword of it. Needs no ROM set -- the ROMs are synthetic,
# because what is being checked is an address mapping. This is the decode the
# in-core flash derivation will read its source material through, so it is
# checked at the RTL rather than only through the Python transcription in
# tools/check_snd01_window.py.
run-snd_window: obj_dir/Vspi_snd_window
	@./obj_dir/Vspi_snd_window

# The flash derivation, against the image MAME's own flash devices hold. Needs
# an authentic-flash SDRAM image, so it is not in `all` -- the offline twin is
# `make check-derive ROMS=...`, which does the same walk in Python.
#   make -C sim run-flash-derive SDRAM=/tmp/rdft2-upd.bin SET=rdft2
# BUILD every testbench, run none of them. Three of these had silently stopped
# building when their modules grew ports (PLAN.md 21.6, 22.3, 28) and a fourth --
# tb_boot_top -- did it again the moment spi_top grew the DS2404's SRAM port, so
# the rot is not a one-off: a bench that fails to build looks exactly like one
# nobody ran. Everything in `all` is covered by running it; these are the ones
# that need ROMs or an image and so cannot be.
check-tb: obj_dir/Vtb_boot_top obj_dir/Vtb_sdram_top obj_dir/Vtb_video_top \
          obj_dir/Vspi_romcheck obj_dir/Vspi_flash_derive obj_dir/Vspi_snd_window
	@echo "every testbench builds"

run-flash-derive: obj_dir/Vspi_flash_derive
	@./obj_dir/Vspi_flash_derive $(SDRAM) $(SET)

obj_dir/Vspi_flash_derive: $(RTL)/spi_flash_derive.sv $(RTL)/spi_snd_window.sv \
                           $(RTL)/spi_rom_decode.sv $(RTL)/spi_defs.vh \
                           tb_flash_derive.cpp lint.vlt
	$(VERILATOR) $(VFLAGS) --top-module spi_flash_derive \
	    $(RTL)/spi_flash_derive.sv $(RTL)/spi_snd_window.sv \
	    $(RTL)/spi_rom_decode.sv tb_flash_derive.cpp

obj_dir/Vspi_snd_window: $(RTL)/spi_snd_window.sv $(RTL)/spi_defs.vh \
                         tb_snd_window.cpp lint.vlt
	$(VERILATOR) $(VFLAGS) --top-module spi_snd_window \
	    $(RTL)/spi_snd_window.sv tb_snd_window.cpp

# The codec on its own: hand vectors from the disassembly, no ROM needed.
run-rom_decode: obj_dir/Vspi_rom_decode
	@./obj_dir/Vspi_rom_decode

# The same decoder against the REAL rdft2 stream. The reference comes from
# tools/build_soundflash.py, which is verified bit-for-bit against the flash
# image MAME's hardware model writes, so this is RTL == script == MAME.
#     make run-bpe ROMS=~/Downloads/roms
BPE_IN  ?= $(CAP)/../rdft2_sound1.bin
BPE_REF ?= $(CAP)/../rdft2_decoded.bin
run-bpe: obj_dir/Vspi_rom_decode $(BPE_REF)
	@./obj_dir/Vspi_rom_decode $(BPE_IN) $(BPE_REF)

$(BPE_REF):
	@mkdir -p $(dir $(BPE_REF))
	python3 -c "import zipfile,sys; \
	    open(sys.argv[2],'wb').write(zipfile.ZipFile(sys.argv[1]).read('sound1.u0222'))" \
	    "$(ROMS)/rdft2.zip" $(BPE_IN)
	python3 $(TOOLS)/build_soundflash.py "$(ROMS)/rdft2.zip" $(BPE_REF).flash \
	    --verify --decoded-out $(BPE_REF)

obj_dir/Vspi_rom_decode: $(RTL)/spi_rom_decode.sv $(RTL)/spi_defs.vh tb_rom_decode.cpp lint.vlt
	$(VERILATOR) $(VFLAGS) --top-module spi_rom_decode \
	    $(RTL)/spi_rom_decode.sv tb_rom_decode.cpp

run-tile_decrypt: obj_dir/Vspi_tile_decrypt
	@./obj_dir/Vspi_tile_decrypt

run-spr_decrypt: obj_dir/Vspi_spr_decrypt
	@./obj_dir/Vspi_spr_decrypt

# RISE10 constants are parsed out of MAME by one script and the reference is
# copied out of it by another, so this checks the parser rather than agreeing
# with itself.
run-rise10: obj_dir/Vspi_rise10_decrypt
	@./obj_dir/Vspi_rise10_decrypt

obj_dir/Vspi_rise10_decrypt: $(RTL)/spi_rise10_decrypt.sv $(RTL)/seibu_partial_add.sv \
                             $(RTL)/spi_rise10_tables.vh tb_rise10_decrypt.cpp spi_ref.h lint.vlt
	$(VERILATOR) $(VFLAGS) --top-module spi_rise10_decrypt \
	    $(RTL)/spi_rise10_decrypt.sv $(RTL)/seibu_partial_add.sv tb_rise10_decrypt.cpp

# RISE10 constants, parsed out of MAME.
$(RTL)/spi_rise10_tables.vh: $(TOOLS)/gen_rise10_tables.py
	python3 $< $(MAME) > $@

# RISE11 (rfjet). Same two-path arrangement as RISE10, plus a second pass that
# walks the words in the order the FETCH sees them -- RISE11 takes the word
# index as an operand, so the inverse of sprite_reorder is part of the contract
# and is checked here rather than only on screen.
run-rise11: obj_dir/Vspi_rise11_decrypt
	@./obj_dir/Vspi_rise11_decrypt

obj_dir/Vspi_rise11_decrypt: $(RTL)/spi_rise11_decrypt.sv $(RTL)/seibu_partial_add.sv \
                             $(RTL)/spi_rise11_tables.vh tb_rise11_decrypt.cpp spi_ref.h lint.vlt
	$(VERILATOR) $(VFLAGS) --top-module spi_rise11_decrypt \
	    $(RTL)/spi_rise11_decrypt.sv $(RTL)/seibu_partial_add.sv tb_rise11_decrypt.cpp

# RISE11 constants, parsed out of MAME.
$(RTL)/spi_rise11_tables.vh: $(TOOLS)/gen_rise11_tables.py
	python3 $< $(MAME) > $@

# Produce the golden capture and the SDRAM image the two reference tests need.
# The bitmap is taken one frame after the video RAM snapshot, deliberately --
# see PLAN.md 12, it is the trap that made ~20% of tilemap entries look wrong.
# GAME picks the set. rdft2 needs two extras, both one-offs:
#   * a rompath whose rdft2.zip carries three 0x117-byte placeholder files
#     (rm81.u0529.bin, rm82.u0330.bin, rm83.u0331.bin) -- MAME will not start
#     without the PAL dumps, which are not in the set;
#   * NVRAM=<dir> pointing at an already-flashed nvram, or the first boot
#     spends ~420 emulated seconds running the sample-flash updater. Produce
#     one by running rdft2 once with -seconds_to_run 520.
#
#     make capture GAME=rdft2 FRAME=4500 ROMS=<patched> NVRAM=<dir> \
#          CAP=/tmp/cap_rdft2 SDRAM=/tmp/sdram_rdft2.bin
#
# SECONDS has to cover FRAME at the SPI's 53.99 Hz, not 60 -- at 60 the capture
# silently never happens and the output directory is just empty.
GAME    ?= rdfts
GAMEZIP ?= $(if $(filter rdfts,$(GAME)),rdft.zip,$(GAME).zip)
MAMEBIN ?= mame
NVRAM   ?=
SECONDS ?= $(shell expr $(FRAME) / 50 + 6)
capture:
	@mkdir -p $(CAP)
	SLOP_OUT=$(abspath $(CAP)) SLOP_FRAME=$(FRAME) $(MAMEBIN) $(GAME) \
	    -rompath "$(ROMS)" $(if $(NVRAM),-nvram_directory "$(NVRAM)",) \
	    -autoboot_script $(abspath $(TOOLS))/mame_capture.lua \
	    -video none -sound none -seconds_to_run $(SECONDS) -nothrottle
	python3 $(TOOLS)/build_sdram_image.py "$(ROMS)/$(GAMEZIP)" $(SDRAM)
	@echo "capture in $(CAP), sdram image $(SDRAM)"

# Golden-reference tests. Need a capture from tools/mame_capture.lua in $(CAP).
run-dma: obj_dir/Vspi_dma
	@./obj_dir/Vspi_dma $(CAP)

obj_dir/Vspi_dma: $(RTL)/spi_dma.sv tb_dma.cpp lint.vlt
	$(VERILATOR) $(VFLAGS) --top-module spi_dma $(RTL)/spi_dma.sv tb_dma.cpp

# The raster itself: frame rate, pixel window lengths, sync widths and the
# analog offset clamp. Needs no capture, so unlike run-video it is in `all`.
# run-video renders through a fixed mode and cannot see the frame RATE, so a
# refresh option that silently fell back to Normal would still pass it.
run-timing: obj_dir/Vspi_video_timing
	@./obj_dir/Vspi_video_timing

obj_dir/Vspi_video_timing: $(RTL)/spi_video_timing.sv $(RTL)/spi_defs.vh tb_timing.cpp lint.vlt
	$(VERILATOR) $(VFLAGS) --top-module spi_video_timing \
	    $(RTL)/spi_video_timing.sv tb_timing.cpp

# Screen flip: the flipped render must be an EXACT 180 rotation of the plain
# one, from the SAME frozen capture. There is no reference to check a flipped
# frame against -- MAME drops reg_1a bit 0 -- so this checks the RTL against
# itself, which is what actually pins the mirror arithmetic. Needs a capture.
#   make run-flip CAP=/tmp/slop_cap SDRAM=/tmp/sdram.bin
run-flip: obj_dir/Vtb_video_top
	@# NEITHER render's exit status is meaningful here. The flipped one is
	@# compared against MAME's unflipped reference and MAME does not flip; the
	@# plain one also diverges whenever the capture has been doctored, as
	@# run-flip-rowscroll does. Only the two dumped frames matter, and run-video
	@# is what guards the reference.
	@SPI_FLIP=0 SPI_GOT=$(CAP)/flip_plain.bin ./obj_dir/Vtb_video_top $(CAP) $(SDRAM) >/dev/null || true
	@SPI_FLIP=1 SPI_GOT=$(CAP)/flip_180.bin  ./obj_dir/Vtb_video_top $(CAP) $(SDRAM) >/dev/null || true
	@python3 $(TOOLS)/check_flip.py $(CAP)/flip_plain.bin $(CAP)/flip_180.bin

# The same check with rowscroll actually carrying data. A capture can have
# rowscroll_enable=1 and a table of all zeroes -- the first one used here did --
# in which case run-flip exercises the fetch but proves nothing about WHICH row
# is indexed, and rs_index is the second thing screen flip mirrors. This copies
# the capture, fills the table with a pattern designed to fail loudly on a row
# error, and re-runs. Needs a capture.
#   make run-flip-rowscroll CAP=/tmp/slop_cap SDRAM=/tmp/sdram.bin
run-flip-rowscroll: obj_dir/Vtb_video_top
	@rm -rf $(CAP)_rs && cp -r $(CAP) $(CAP)_rs
	@python3 $(TOOLS)/inject_rowscroll.py $(CAP)_rs/tilemap_ram.bin
	@SPI_FLIP=0 SPI_GOT=$(CAP)_rs/flip_plain.bin ./obj_dir/Vtb_video_top $(CAP)_rs $(SDRAM) >/dev/null || true
	@SPI_FLIP=1 SPI_GOT=$(CAP)_rs/flip_180.bin  ./obj_dir/Vtb_video_top $(CAP)_rs $(SDRAM) >/dev/null || true
	@python3 $(TOOLS)/check_flip.py $(CAP)_rs/flip_plain.bin $(CAP)_rs/flip_180.bin

run-video: obj_dir/Vtb_video_top
	@./obj_dir/Vtb_video_top $(CAP) $(SDRAM)

obj_dir/Vtb_video_top: tb_video_top.sv tb_video.cpp lint.vlt \
                       $(RTL)/spi_layers.sv $(RTL)/spi_mixer.sv $(RTL)/spi_dpram.sv \
                       $(RTL)/spi_video_timing.sv $(RTL)/spi_tile_decrypt.sv \
                       $(RTL)/spi_sprite.sv $(RTL)/spi_spr_decrypt.sv \
                       $(RTL)/spi_rise10_decrypt.sv $(RTL)/spi_rise10_tables.vh \
                       $(RTL)/spi_rise11_decrypt.sv $(RTL)/spi_rise11_tables.vh \
                       $(RTL)/spi_spr_tables.vh \
                       $(RTL)/seibu_partial_add.sv
	$(VERILATOR) $(VFLAGS) -LDFLAGS "-lz" --top-module tb_video_top tb_video_top.sv \
	    $(RTL)/spi_layers.sv $(RTL)/spi_mixer.sv $(RTL)/spi_dpram.sv \
	    $(RTL)/spi_video_timing.sv $(RTL)/spi_tile_decrypt.sv \
	    $(RTL)/spi_sprite.sv $(RTL)/spi_spr_decrypt.sv \
	    $(RTL)/spi_rise10_decrypt.sv $(RTL)/spi_rise11_decrypt.sv \
	    $(RTL)/seibu_partial_add.sv tb_video.cpp

obj_dir/Vrom_loader: $(RTL)/rom_loader.sv $(RTL)/spi_rom_decode.sv $(RTL)/spi_defs.vh \
                     tb_rom_loader.cpp spi_ref.h lint.vlt
	$(VERILATOR) $(VFLAGS) --top-module rom_loader \
	    $(RTL)/rom_loader.sv $(RTL)/spi_rom_decode.sv tb_rom_loader.cpp

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

# tv80 replaced T80 for savestates (PLAN.md 40), and it is Verilog -- so the
# simulator now runs the REAL Z80 instead of the stand-in T80s.sv that stood in
# for a VHDL core it could not read. sim/T80s.sv is kept for reference; nothing
# builds it any more.
SOUND_SRCS := $(RTL)/spi_sound.sv $(RTL)/ymf271.sv $(RTL)/ymf271_synth.sv \
              $(RTL)/tv80_auto_ss.sv

# The savestate framework. system_consts.sv first (it is the package) and
# savestates.sv next (it declares the interface the slaves take as a port).
SS_SRCS := $(RTL)/system_consts.sv $(RTL)/savestates.sv $(RTL)/memory_stream.sv \
           $(RTL)/ddram.sv $(RTL)/spi_ss.sv $(RTL)/spi_ss_bridge.sv \
           $(RTL)/spi_ss_vram.sv

# spi_ds2404.sv belongs here even though Verilator finds it under -I$(RTL)
# anyway: without it in the list make never rebuilds a bench when the chip
# changes. That cost a whole diagnostic round -- a fix to the RTC was applied,
# the bench was re-run, and it reported the OLD behaviour with make saying
# "up to date". Same silent-staleness family as the three benches that had
# stopped building (PLAN.md 21.6, 22.3, 28).
CORE_SRCS := $(SS_SRCS) $(RTL)/spi_top.sv $(RTL)/spi_video_timing.sv $(RTL)/spi_cpu.sv $(RTL)/spi_snd_window.sv \
             $(RTL)/spi_io.sv $(RTL)/spi_mainram.sv $(RTL)/spi_reset_sync.sv \
             $(RTL)/spi_dpram.sv $(RTL)/spi_dma.sv $(RTL)/spi_layers.sv \
             $(RTL)/spi_mixer.sv $(RTL)/spi_tile_decrypt.sv \
             $(RTL)/spi_ds2404.sv \
             $(RTL)/seibu_partial_add.sv $(SOUND_SRCS)

lint: lint-derive
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
	    $(RTL)/spi_sprite.sv $(RTL)/spi_spr_decrypt.sv \
	    $(RTL)/sdram.sv $(RTL)/rom_loader.sv $(RTL)/spi_flash_derive.sv \
	    $(RTL)/spi_sdr_arb2.sv $(RTL)/spi_sdr_arb4.sv $(RTL)/spi_soundflash.sv $(RTL)/spi_nvram.sv $(RTL)/spi_rom_decode.sv $(RTL)/ddr_rom_reader.sv \
	    $(RTL)/spi_rise10_decrypt.sv $(RTL)/spi_rise11_decrypt.sv 2>&1 | \
	    grep -E "%Error|WIDTHTRUNC|WIDTHEXPAND|IMPLICIT|PINMISSING" | \
	    grep -vE "MODMISSING|Exiting due to" || echo "no width or pin problems"


# Boots the real 386 against the real SDRAM image. STEPS is clk_ram half-steps
# (8 per clk_cpu cycle). GAME picks the board, and on the cartridge sets the run
# ends by checking the Z80 program the 386 downloaded against the ROM -- for
# rdft2 that is the sound01 window's only customer, so it is the check that says
# whether the window works. Reaching the download takes far more than the
# default STEPS; ~400M is the right order for rdft2.
#
#   make run-boot GAME=rdft2 SDRAM=/tmp/sdram_rdft2.bin STEPS=600000000
STEPS ?= 40000000
run-boot: obj_dir/Vtb_boot_top
	@./obj_dir/Vtb_boot_top $(SDRAM) $(STEPS) $(GAME)


# The sound path against MAME, in simulation, end to end (PLAN.md 51).
#
#   make run-sound GAME=rdft2 SDRAM=/tmp/sdram_rdft2.bin STEPS=3000000000 \
#       ROMS=~/Downloads/roms REFSECS=220
#
# This could not be run at all before the Z80 became tv80: sim/T80s.sv was a
# Verilator stand-in for a VHDL core and never executed a cycle, so every sound
# measurement in this repo's history was taken either on hardware -- through a
# capture chain nobody had calibrated (PLAN.md 19.4) -- or with an inert sound
# board. The core's audio is written at the YMF271's own 44,100 Hz sample tick,
# so there is no resampling on this side at all, and MAME is asked for the same
# rate so there is none on the other.
#
# Both machines start from power-on, which is why the alignment lands at 0.00 s
# and why nothing here trims the boot silence: the silent stretch before the
# music is itself the strongest thing to align on.
#
# STEPS: about 229M per second of audio. Music starts around 4 s on rdft and
# 6 s on rdft2, so anything under ~1.5G is boot and silence.
#
# rdft2 needs two things this cannot do for you: MAME 0.289 requires three PLD
# dumps that are not in circulation, and its sample flash has to have been
# programmed once (run it for 500 emulated seconds with a writable
# -nvram_directory and it does its own ritual). Point ROMS and NVRAM at those.
SNDOUT  ?= /tmp/spi_sound
REFSECS ?= 220
run-sound: obj_dir/Vtb_boot_top
	@mkdir -p $(SNDOUT)
	SND_WAV=$(SNDOUT)/core_$(GAME).wav SND_YMF=$(SNDOUT)/core_$(GAME).txt \
	    ./obj_dir/Vtb_boot_top $(SDRAM) $(STEPS) $(GAME) | \
	    grep -E "YMF271|audio samples|Z80 clock|wrote .*(wav|txt)" || true
	$(MAMEBIN) $(GAME) -rompath "$(ROMS)" \
	    $(if $(NVRAM),-nvram_directory "$(NVRAM)",) \
	    -video none -sound none -samplerate 44100 -seconds_to_run $(REFSECS) \
	    -nothrottle -skip_gameinfo -wavwrite $(SNDOUT)/mame_$(GAME).wav >/dev/null
	SLOP_OUT=$(SNDOUT)/mame_$(GAME).txt SLOP_SECS=$(REFSECS) $(MAMEBIN) $(GAME) \
	    -rompath "$(ROMS)" $(if $(NVRAM),-nvram_directory "$(NVRAM)",) \
	    -autoboot_script $(abspath $(TOOLS))/mame_ymf_trace.lua \
	    -video none -sound none -nothrottle -skip_gameinfo >/dev/null
	@echo; echo "---- YMF271 register writes ----"
	@python3 $(TOOLS)/compare_ymf_trace.py \
	    $(SNDOUT)/core_$(GAME).txt $(SNDOUT)/mame_$(GAME).txt | \
	    grep -vE "^  (slot group|control|PCM) .* ok$$"
	@echo; echo "---- audio ----"
	@python3 $(TOOLS)/compare_audio.py \
	    $(SNDOUT)/core_$(GAME).wav $(SNDOUT)/mame_$(GAME).wav

obj_dir/Vtb_boot_top: tb_boot_top.sv tb_boot.cpp lint.vlt $(CORE_SRCS) $(Z386_SRCS) \
                      $(RTL)/spi_sprite.sv $(RTL)/spi_spr_decrypt.sv \
                      $(RTL)/spi_rise10_decrypt.sv $(RTL)/spi_rise10_tables.vh \
                      $(RTL)/spi_spr_tables.vh
	$(VERILATOR) $(VFLAGS) -I$(RTL)/z386 --top-module tb_boot_top \
	    tb_boot_top.sv $(CORE_SRCS) $(Z386_SRCS) \
	    $(RTL)/spi_sprite.sv $(RTL)/spi_spr_decrypt.sv \
	    $(RTL)/spi_rise10_decrypt.sv tb_boot.cpp


# Streams the real ROM image through rom_loader -> rtl/sdram.sv -> a behavioural
# SDRAM chip, then reads it all back. The download path is the one thing that
# runs on hardware before the 386 starts and that nothing else here covers.
CONCAT ?= $(CAP)/../rom_concat.bin
run-sdram: obj_dir/Vtb_sdram_top
	@./obj_dir/Vtb_sdram_top $(SDRAM) $(CONCAT)

obj_dir/Vtb_sdram_top: tb_sdram_top.sv tb_sdram.cpp sdram_model.sv altddio_out.sv \
                       $(RTL)/sdram.sv $(RTL)/rom_loader.sv $(RTL)/spi_rom_decode.sv \
                       $(RTL)/spi_defs.vh lint.vlt
	$(VERILATOR) $(VFLAGS) --top-module tb_sdram_top \
	    tb_sdram_top.sv sdram_model.sv altddio_out.sv \
	    $(RTL)/sdram.sv $(RTL)/rom_loader.sv $(RTL)/spi_rom_decode.sv tb_sdram.cpp


# spi_romcheck is the instrument that reports whether the hardware download
# worked, so it gets its own test.
# The sample flash's save file, both directions. Went to hardware untested once
# and came back as byte 0 twice followed by one line repeated 262,143 times.
run-nvram: obj_dir/Vspi_nvram
	@./obj_dir/Vspi_nvram

obj_dir/Vspi_nvram: $(RTL)/spi_nvram.sv $(RTL)/spi_defs.vh tb_nvram.cpp lint.vlt
	$(VERILATOR) $(VFLAGS) -GQUIET_BITS=8 --top-module spi_nvram \
	    $(RTL)/spi_nvram.sv tb_nvram.cpp

# The DS2404's 512 bytes of bookkeeping SRAM, against a transliteration of
# MAME's own device. TICK_DIV is turned right down so the RTC ticks in tens of
# cycles rather than in half a million.
run-ds2404: obj_dir/Vspi_ds2404
	@./obj_dir/Vspi_ds2404

obj_dir/Vspi_ds2404: $(RTL)/spi_ds2404.sv tb_ds2404.cpp lint.vlt
	$(VERILATOR) $(VFLAGS) -GTICK_DIV=64 --top-module spi_ds2404 \
	    $(RTL)/spi_ds2404.sv tb_ds2404.cpp

run-romcheck: obj_dir/Vspi_romcheck
	@./obj_dir/Vspi_romcheck $(SDRAM)

obj_dir/Vspi_romcheck: $(RTL)/spi_romcheck.sv $(RTL)/spi_defs.vh tb_romcheck.cpp lint.vlt
	$(VERILATOR) $(VFLAGS) --top-module spi_romcheck $(RTL)/spi_romcheck.sv tb_romcheck.cpp

clean:
	rm -rf obj_dir spi_ref.h
