
## 50. CHECK SUM ERROR in Cart copy: what is measured, what is not (2026-08-22)

Unfinished. The menu fix (49) works and C1 passed, but section B does not:
switching to Cart copy shows **CHECK SUM ERROR** and a number -- 1034 on rdft.

### 50.1 The save file on the board is corrupt, in two places

Fetched and compared against the reference recorded at 32.7:

    stamp        3a ff ff ff     should be ff ff ff ff (blank)
                                 or       80 4a 4a 36 (programmed)
    tail[20..27] 78 89 4f a9     should be 67 45 23 01
                 4d 1a dd 51              ef cd ab 89

**Those eight bytes are the game's own test patterns** -- 0x01234567 and
0x89ABCDEF -- which it writes, reads back, and checksums. 32.7 matched them to
MAME byte for byte. They are now high-entropy garbage, and that is what fails.

Ten of the first 36 tail bytes differ. Three of them -- 18, 24, 30 -- sit on the
six-byte stride that 32.7 already identified as RTC-derived and expected to
differ. The other seven are the test patterns. So the corruption is a single
contiguous eight-byte run, not a general scrambling.

Stamp byte 0 reading `3A` is its own anomaly: nothing in either mode should ever
write that value there.

### 50.2 What was ruled out, by measurement

* **The derivation.** `make check-derive` on rdft's real ROM: byte-identical to
  the recorded reference. The payload the core builds is correct.
* **The nvram split.** `run-nvram` passes, including the 516-byte stream's
  crossing at offset 4, which is not 512-aligned.
* **The savestate path preserving the SRAM.** `SSIDX_DS2404_RAM` is section 17,
  and **nothing had ever checked it** -- the bench could not see those 512 bytes.
  It can now (50.3), and a save/restore preserves them EXACTLY: single restore,
  eight back-to-back restores, and a later save point with the game running.

### 50.3 The probe, which is the durable part

`spi_ds2404` has a fourth read port on the SRAM, wired through `spi_top` to the
bench, and `tb_boot.cpp` hashes those 512 bytes at the save's snapshot and again
after the restore -- exactly as it already did for main RAM. The array had three
read ports already, so this changes nothing about how it infers.

    DS2404 SRAM        : 218035740D3F1B83  <- EXACT

**This does NOT reproduce the failure, and must not be read as clearing the
savestate path.** In the bench the SRAM holds power-on defaults: the game never
writes its test patterns inside the simulated window, so what the check proves is
that the plumbing preserves whatever is there, not that it preserves the game's
real bookkeeping. `make verify` exit 0.

### 50.4 The bisect to run next, and why in this order

The corruption is sticky -- it lives in a file -- so every boot will keep showing
it until the file is replaced. **Back up the corrupt file first; it is the only
evidence.**

1. **Delete the nvram and boot Pre-built.** The game writes fresh bookkeeping.
   If the error clears, the fault is in what WROTE the file, not in Cart copy.
2. **Then switch to Cart copy, without touching savestates.** Works -> something
   earlier in the session corrupted the file. Errors -> the Cart copy path does
   it, and the toggle's blank/self-reset is the only part of it that had never
   run outside simulation.
3. **Only then take a savestate and reload it, and re-check the file.** That
   isolates savestates, which 50.2 says are clean in the bench but which ran
   heavily just before this appeared.

### 50.5 The hypothesis worth holding, and holding loosely

`sram_we = ss_ram_we | nv_we | copy_sram`. `copy_sram` is the DS2404's own
scratchpad-to-SRAM copy, writing `pad[copy_i]` to `copy_addr`. A savestate
restore brings back `SSIDX_DS2404` -- the RTC, the state machine AND the
scratchpad -- so a restore landing with a copy armed would write scratchpad bytes
into the SRAM at a restored address. **An eight-byte contiguous run is the right
shape for that.**

It is a hypothesis and nothing more. The bench does not issue a copy command in
the simulated window, so 50.3 could not have caught it either way. 43 through 45
are four sections of confident mechanisms reasoned from source that were all
wrong; run the bisect before believing this one.
