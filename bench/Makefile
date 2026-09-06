# Seibu SPI 386 IPC benchmark ROM.
#
#   make                      build everything
#   make mame                 run it under MAME and print the table
#   make sim                  run it through the real core in Verilator
#   make report               compare whatever result files exist
#   make check                the harness's own known-answer test
#
# ROMS must point at a directory holding rfjet.zip. Everything else has a
# default that works from a clean checkout.

NASM     ?= nasm
PYTHON   ?= python3
ROMS     ?= $(HOME)/Downloads
MAMEBIN  ?= mame
TOOLS    := ../tools
OUTDIR   := out
QUICKDIR := out-quick
RESULTS  ?= /tmp/spi_bench

# The full build: 8-frame windows, every test. Used by MAME, the MiSTer core
# and a real cartridge.
WINDOW   ?= 8

# The quick build, for Verilator. Two-frame windows and a subset, because the
# simulator runs about 3M clk_ram half-steps a second and a frame is 4.24M of
# them. The metric is per-frame, so a shorter window costs precision and
# nothing else.
QWINDOW  ?= 2
QTESTS   ?= 0-9,20-24,32-36
QSTEPS   ?= 1400000000

SRCS := bench.asm spi.inc tests.inc vidinit.inc blocks.inc table.inc

.PHONY: all gen roms mra dist mame sim report check check-window clean

all: roms mra dist

# blocks.inc, table.inc and tests.json all come from the one TESTS list, so a
# test can never be described one way to the assembler and another to the
# report.
gen blocks.inc table.inc tests.json: gen_tests.py
	$(PYTHON) gen_tests.py .

# The register writes the real game makes between reset and its first tilemap
# DMA. Regenerating needs MAME and a real rfjet set; the captured trace is
# checked in so a normal build does not.
vidinit.inc: vidinit_trace.txt tools/gen_vidinit.py
	$(PYTHON) tools/gen_vidinit.py $< > $@

vidinit_trace.txt:
	@echo "vidinit_trace.txt is checked in. To recapture:"
	@echo "  SLOP_OUT=/tmp/vi.txt $(MAMEBIN) rfjet -rompath '$(ROMS)' \\"
	@echo "      -autoboot_script tools/mame_vidinit_trace.lua -noplugins \\"
	@echo "      -video none -sound none -nothrottle -skip_gameinfo -seconds_to_run 12"
	@false

# -w-number-overflow: the real-mode `lgdt [cs:0xF038]` uses an unsigned 16-bit
# direct offset, which NASM reports as out of signed range. The encoding it
# emits is correct; see the disassembly note in bench.asm.
bench.bin: $(SRCS)
	$(NASM) -f bin -w-number-overflow -o $@ bench.asm

roms: bench.bin
	$(PYTHON) build_rom.py bench.bin --out $(OUTDIR) --window $(WINDOW) --tests all
	$(PYTHON) build_rom.py bench.bin --out $(QUICKDIR) --window $(QWINDOW) \
	    --tests "$(QTESTS)" --zip bench_quick.zip

# --verify is the check that matters: rom_loader.sv's SET_RFJET table is
# POSITIONAL, so a part of the wrong length would shift every later region and
# the core would load garbage without complaining. It needs the real rfjet.zip,
# so it is skipped when ROMS does not have one.
mra: roms
	@if [ -f "$(ROMS)/rfjet.zip" ]; then \
	    $(PYTHON) gen_mra.py "../mra/Raiden Fighters Jet (Germany).mra" \
	        $(OUTDIR) "Raiden Fighters Jet (386 Benchmark).mra" \
	        --verify "$(ROMS)"; \
	else \
	    $(PYTHON) gen_mra.py "../mra/Raiden Fighters Jet (Germany).mra" \
	        $(OUTDIR) "Raiden Fighters Jet (386 Benchmark).mra"; \
	    echo "note: no rfjet.zip in $(ROMS), part sizes NOT verified"; \
	fi

# Everything the MiSTer needs, laid out the way the SD card is.
DISTDIR := dist
dist: mra
	@rm -rf $(DISTDIR)
	@mkdir -p "$(DISTDIR)/_Arcade/mame"
	@cp "$(OUTDIR)/Raiden Fighters Jet (386 Benchmark).mra" "$(DISTDIR)/_Arcade/"
	@cp "$(OUTDIR)/bench.zip" "$(DISTDIR)/_Arcade/mame/"
	@cp INSTALL.txt "$(DISTDIR)/"
	@echo "MiSTer package in $(CURDIR)/$(DISTDIR) -- see INSTALL.txt"
	@find $(DISTDIR) -type f | sort | sed 's/^/  /'

# The four EPROM images, for a real cartridge.
eproms: roms
	@echo "burn these into the SXX2C cartridge (512 KB each, 27C040-class):"
	@echo "  $(OUTDIR)/bprg0.u0211 -> u0211   D7-0"
	@echo "  $(OUTDIR)/bprg1.u0212 -> u0212   D15-8"
	@echo "  $(OUTDIR)/bprg2.u0221 -> u0221   D23-16"
	@echo "  $(OUTDIR)/bprg3.u0220 -> u0220   D31-24"

# ---------------------------------------------------------------------------
# MAME. The image is written into the maincpu region and the machine is soft
# reset, so no doctored zip and no rebuilt driver -- see mame_bench.lua.
# ---------------------------------------------------------------------------
MAME_SECS ?= 180
mame: roms
	@mkdir -p $(RESULTS)
	BENCH_ROM=$(CURDIR)/$(OUTDIR)/bench_patched.bin \
	BENCH_OUT=$(RESULTS)/mame.txt \
	$(MAMEBIN) rfjet -rompath "$(ROMS)" -autoboot_script mame_bench.lua \
	    -noplugins -video none -sound none -nothrottle -skip_gameinfo \
	    -seconds_to_run $(MAME_SECS) >/dev/null
	@grep -c '^BENCH ' $(RESULTS)/mame.txt | xargs echo "results:"
	@grep '^BENCHINFO frame_period' $(RESULTS)/mame.txt || true

# ---------------------------------------------------------------------------
# The core, in Verilator. Graphics and sound come from the genuine set; only
# the 2 MB program region is substituted.
# ---------------------------------------------------------------------------
SDRAM ?= $(RESULTS)/sdram_bench.bin

$(SDRAM): $(QUICKDIR)/bench_patched.bin
	@mkdir -p $(RESULTS)
	$(PYTHON) $(TOOLS)/build_sdram_image.py "$(ROMS)/rfjet.zip" $@ \
	    --prg $(QUICKDIR)/bench_patched.bin

# Run it from sim/: z386's ucode_rom.sv $readmemh's ucode.hex by a relative
# path, and started anywhere else the core boots with an empty microcode ROM and
# stops on an assertion.
sim: roms $(SDRAM)
	$(MAKE) -C ../sim obj_dir/Vtb_boot_top
	cd ../sim && ./obj_dir/Vtb_boot_top $(abspath $(SDRAM)) $(QSTEPS) rfjet \
	    > $(RESULTS)/core_raw.txt 2>&1 || true
	@grep '^BENCH ' $(RESULTS)/core_raw.txt > $(RESULTS)/core.txt || true
	@wc -l < $(RESULTS)/core.txt | xargs echo "results:"

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------
# The core still runs the 386 at 28.636364 MHz. Once the 7/8 gate of PLAN.md
# 16.9 lands, this becomes 25056818.
CORE_HZ ?= 28636364

report:
	@args=""; \
	[ -f $(RESULTS)/mame.txt ] && args="$$args mame=$(RESULTS)/mame.txt"; \
	[ -f $(RESULTS)/core.txt ] && args="$$args core=$(RESULTS)/core.txt:$(CORE_HZ)"; \
	[ -f $(RESULTS)/hw.txt ]   && args="$$args hw=$(RESULTS)/hw.txt"; \
	[ -n "$$args" ] || { echo "no result files in $(RESULTS)"; exit 1; }; \
	$(PYTHON) analyze.py $$args

# The harness's own known-answer test. MAME's i386 is a straight lookup of
# Intel's published counts (src/devices/cpu/i386/cycles.h), so if the vblank
# window and the two-length differencing are right, the MAME column has to
# reproduce that table: 2 for ALU reg,reg, 4 for a load, 7 for a taken Jcc, 4
# and 5 per element for REP MOVSD/STOSD, and a FLAT MUL sweep, because MAME
# charges 41 clocks whatever the multiplier is. Anything else means the harness
# is wrong, not the CPU.
check:
	$(MAKE) mame
	$(PYTHON) check_harness.py $(RESULTS)/mame.txt

# The window length must not change the answer: it is divided out. Building the
# same suite at 8 and 32 frames and requiring the two columns to agree tests the
# whole chain -- the ISR's EBP snapshot, the frame accounting, the differencing
# -- against itself, and needs no reference at all. Every ratio should be 1.000.
check-window: roms
	@mkdir -p $(RESULTS)
	$(PYTHON) build_rom.py bench.bin --out $(RESULTS)/w32 --window 32 --zip ''
	BENCH_ROM=$(RESULTS)/w32/bench_patched.bin BENCH_OUT=$(RESULTS)/mame_w32.txt \
	$(MAMEBIN) rfjet -rompath "$(ROMS)" -autoboot_script mame_bench.lua \
	    -noplugins -video none -sound none -nothrottle -skip_gameinfo \
	    -seconds_to_run 200 >/dev/null
	$(PYTHON) analyze.py w8=$(RESULTS)/mame.txt w32=$(RESULTS)/mame_w32.txt

clean:
	rm -f bench.bin blocks.inc table.inc tests.json
	rm -rf $(OUTDIR) $(QUICKDIR) $(DISTDIR)
