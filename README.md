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
   single board variants replaced it with a 40Mhz cpu says maybe not...

2. More investigation of the sound chip. It is functional but 'mame quality'
   which still clearly has some issues.

3. Validation/tests of the rendering system.

4. real/better memory/sub-cpu access timings

5. The core runs at 54Hz, investigate a 60hz mode (lol bullet speed)

6. savestates maybe (core is kinda full, but mayyyyyybe)

## Core utilization

Quartus Prime 17.0.0 Lite, Cyclone V `5CSEBA6U23I7` (MiSTer DE10-Nano),
top-level entity `sys_top`. From `output_files/SeibuSPI.fit.summary`,
fit dated 2026-08-19.

| Resource                | Used      | Available | Utilization |
|-------------------------|-----------|-----------|-------------|
| Logic utilization (ALMs)| 33,980    | 41,910    | 81 %        |
| Total registers         | 32,681    | -         | -           |
| Block memory bits       | 3,547,869 | 5,662,720 | 63 %        |
| RAM blocks              | 484       | 553       | 88 %        |
| DSP blocks              | 61        | 112       | 54 %        |
| PLLs                    | 3         | 6         | 50 %        |
| Pins                    | 145       | 314       | 46 %        |
