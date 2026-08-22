# Savestate debug kit

For the rapid-reload lockup. `PLAN.md` 45 is the design record; read it first.

* **`read_wedge.sh`** -- screenshots the MiSTer and decodes the on-screen wedge
  overlay `spi_top` paints when a savestate stays busy past ~146 ms. Prints the
  spi_ss state by name plus is_load, pause, the three io_stall sources, and the
  CPU's snapshot/in_stub flags. Validate it on a HEALTHY core first: it should
  say "not wedged". The overlay only exists in builds carrying `PLAN.md` 45's
  `ss_dbg_st` wiring; check `grep ss_wedged rtl/spi_top.sv`.

* **`rdft-ingame-wedges.ss` -- NOT IN THIS REPO.** A `.ss` carries the 386's
  256 KB of main RAM, which is live game state, so it is gitignored rather than
  committed. It was a real 312,544-byte savestate taken on hardware DURING
  ACTIVE GAMEPLAY on rdft, the condition that reproduced the rapid-reload
  lockup; an attract-mode save did not.

  **It is spent anyway** (`PLAN.md` 50): since the fix it replays six clean
  loads and cannot reproduce anything. If you need a reproducer for a future
  wedge, take a FRESH in-game save off the board -- which is what `PLAN.md` 50
  tells you to do regardless. Drop it in this directory and replay it:

      python3 tools/build_sdram_image.py rdft.zip /tmp/sdram_rdft.bin --upd --set rdft
      cd sim && SS_LOAD_FILE=../tools/savestate-debug/rdft-ingame-wedges.ss \
          SS_RESTORE_AT=6000000 SS_RELOADS=6 \
          ./obj_dir/Vtb_boot_top /tmp/sdram_rdft.bin 70000000 rdft

  **The replay harness is NOT VALIDATED.** Replaying a hardware blob into an
  independently booted simulation may not be sound. Replay an ATTRACT-mode save
  first -- the hardware restores those fine -- and only believe an in-game
  failure if the attract one passes.

Everything before this kit was tested with blobs the bench wrote itself, from
synthetic saves at arbitrary boot-time cycles on rdft2. Nothing exercised a real
in-game save, which is why simulation passed for hours while the board wedged.
