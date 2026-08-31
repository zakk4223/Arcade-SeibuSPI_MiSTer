# Seibu SPI for MiSTer

## Games implemented

- Raiden Fighters
- Raiden Fighters 2
- Raiden Fighters Jet
- Viper Phase 1
- Senkyu

## Games that boot, but don't work

- E Jong High School - jong panel input not implemented (yet)

## About

As the kids say, this is an AI Slop mame core. It was built based on mame
seibuspi.cpp and some reference documentation/datasheets of the OPX sound chip.

The cpu is implemented via nand2mario's z386.

## Future work

I _do_ own some SPI hardware and plan on doing hardware validation of the core,
current gaps:

1. z386 is not running at the proper clock speed, and it is unlikely to be
   accurate even at the correct speed (z386 has performance enhancements).
   This will need some custom test roms to do comparison benchmarks to dial in
   the performance.

   Luckily the games are all properly vsync throttled; there may be some
   instances where the faster cpu is able to do more work and remove 'slowdown'.
   I'm not 100% sure if it ever happens on hardware, and the fact some of the
   single board variants replaced it with a 40Mhz cpu (but clocked it at 28, which is still faster) says maybe not...

2. More investigation of the sound chip. It is functional but 'mame quality'
   which still clearly has some issues.

3. Validation/tests of the rendering system.

4. real/better memory/sub-cpu access timings


## Core utilization

Quartus Prime 17.0.0 Lite, Cyclone V `5CSEBA6U23I7` (MiSTer DE10-Nano),
top-level entity `sys_top`, `SEED 1`. From `output_files/SeibuSPI.fit.summary`,
fit dated 2026-08-31 (`BUILD_DATE 260831`, bitstream `5a342091`).

| Resource                | Used      | Available | Utilization |
|-------------------------|-----------|-----------|-------------|
| Logic utilization (ALMs)| 39,217    | 41,910    | 94 %        |
| Total registers         | 38,705    | -         | -           |
| Block memory bits       | 3,841,857 | 5,662,720 | 68 %        |
| RAM blocks              | 529       | 553       | 96 %        |
| DSP blocks              | 58        | 112       | 52 %        |
| PLLs                    | 3         | 6         | 50 %        |
| Pins                    | 145       | 314       | 46 %        |

Timing: worst setup **+0.017 ns** on `pll_hdmi`, worst hold **+0.243 ns** on
`emu` (clk_ram). The core's own clock has more room than that headline suggests
— clk_ram is +0.120 setup — because the tightest path in the design belongs to
the HDMI PLL, which is framework territory and not something this core's RTL
moves. TNS 0.000 on every clock for setup, hold, recovery, removal and minimum
pulse width; no critical warnings. `make check-timing` is the gate, and `make
release` refuses to assemble a distribution without it.

**RAM blocks are the binding resource again, narrowly ahead of logic**, at 96 %
RAM against 94 % ALM. That is a reversal: the 2026-08-28 fit had them the other
way round (96 % ALM / 95 % RAM) and this section said logic was binding. The
YMF271 slot-output array is what turned it back. It was 48 x 18 flops read four
ways at once, and it became four copies of one M10K each holding all 48 — the
same trade `fb_mem` made earlier — which is 864 flip-flops and a 48-way write
decoder handed back to the fabric in exchange for block memory.

The fit-to-fit numbers across that change: ALMs 40,078 → 39,107 → 39,217 and RAM
blocks 526 → 529 over the 08-28, 08-30 and 08-31 fits. The direction matches the
intent, but the interval also contains the SDRAM grant register and the Z80
cache dropping from eight lines to six, and none of the three was fitted alone —
so the ALM saving is not attributable to any one of them here. The RAM cost came
out at +3 blocks rather than the +4 four copies would imply; that was not
isolated either.

Before that, the step to 96 % ALM was the YMF271 OPX rewrite, which trades
stored tables for computed logic — ALMs 37,569 → 40,078 while RAM blocks fell
539 → 526 and DSPs 69 → 58.

Neither resource has much left, and the RAM split still matters: 68 % of the
*bits* are used but 96 % of the *blocks*, because several arrays are wide and
shallow and pack badly. Two figures set that budget — `spi_mainram` is 256
blocks on its own, 47 % of the device, for the 386's 256 KB, and it is already
optimally packed (an M10K holds 8,192 usable
bits, so 2 Mbit needs exactly 256); and CRT V-Size's line ring is 52. The ring
is sized `RING_LINES=46` for |vsize| <= 21 while the OSD exposes +-8, so
dropping it to 20 returns roughly 28 blocks if anything else ever needs them.

The growth since the 2026-08-19 fit (81 % ALM / 88 % RAM) was almost entirely
CRT Adjust and CRT V-Size, at ~1,200 ALM and 52 RAM blocks; the refresh-rate
conversion and screen flip together cost less than the fit-to-fit noise.

At this utilization the fitter is fighting, and which marginal path fails
becomes seed-dependent — identical RTL failed hold on two entirely different
paths at two different seeds. `SeibuSPI.sdc` answers that by constraining the
class rather than chasing the seed; `PLAN.md` 56 is the record.
