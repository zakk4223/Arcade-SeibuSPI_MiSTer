# Hardware session checklist

One sitting at the board with a pad closes most of what is left open. Everything
here needs someone physically at the MiSTer: there is no OSD command on
`/dev/MiSTer_cmd`, and the `.CFG` route only sets values at boot, so none of it
can be driven from a host.

Read `PLAN.md` 38-47 for the mechanism. This file is the checklist.

**On the board when this was written:** `49668c89` (PLAN.md 47), deployed
2026-08-22. Fallbacks in `/media/fat/_Arcade/cores/`: `SeibuSPI.rbf.20260822-0449`
is 46's margin version, which also passed; `.20260822-0022` is the last
pre-savestate clean build.

---

## The controls, read off the RTL

Not from the on-screen help, which is wrong here -- see the warning below.

**Pad.** `joySS` is wired to **Start** (`joystick_p1[7] | joystick_p2[7]`), and
`joyStart` is tied to 0. So every combination is Start plus a direction:

| hold | and press | does |
|---|---|---|
| Start | Right | slot + 1 (stops at 4) |
| Start | Left | slot - 1 (stops at 1) |
| Start | Down | **save** to the current slot |
| Start | Up | **load** the current slot |
| Start | (nothing, ~0.6 s) | shows the help text |

**Keyboard.** F1-F4 load slots 1-4. Alt+F1-F4 save slots 1-4.

**OSD.** `Savestate Slot` (1-4), `Autoincrement Slot` (Off/On),
`Save state (Alt-F1)`, `Restore state (F1)`.

**Savestates are gated on `rom_ready && !reset`** -- nothing responds until the
ROM has finished loading.

### Warning: the on-screen help text is wrong for this core

It reads `Slot=DPAD|Save/Load=Start+DPAD`. That is Robert Peip's generic string
for a core with a dedicated SS button. Here `joySS` IS Start, so **bare DPAD does
nothing** -- slot switching is Start+Left/Right, not DPAD. Anyone following the
on-screen text will conclude slot switching is broken when it is not.

Decide during this session whether to fix the string or the wiring. The string is
in `SeibuSPI.sv`'s `I,` list, which `savestate_ui` indexes by position -- the
order is fixed by that module, so edit the text in place, do not reorder.

### Evaluate, do not just test: Start is the game's Start button

`joystick_p1[7]` is **both** `joySS` and `m_start1`. So:

* pressing Start to begin a game also arms the savestate modifier;
* holding Start for ~0.6 s pops the help overlay over the game;
* Start+Up during play loads a state, and Start-while-pushing-up is a plausible
  thing to do by accident in a shooter.

**This is the one open design question in the savestate UI, and it is a judgement
call, not a bug to find.** Play a few minutes of rdft normally, using Start the
way a player would -- coin up, start, continue -- and see whether the overlay or
an accidental load fires. If it does, the options are a different modifier
(`joystick_p1[11]` is already `pause_btn`), a longer hold, or requiring a
direction to be held first.

---

## A. Savestate UI -- the main event

Files land in `/media/fat/savestates/Arcade/<MRA name>_<slot>.ss`, 312,544 bytes
for rdft. `Raiden Fighters (Germany)_1.ss` and `_2.ss` already exist, so some of
this has been exercised; verify rather than assume.

**A1. Slot switching, pad.** Load `Raiden Fighters (Germany).mra`. Hold
Start+Right three times, watching the OSD info line: it should read
`Active Slot 2`, `3`, `4` and then stop at 4. Start+Left back down to 1.
*A failure here is the OSD info line not appearing at all, which is
`ss_info_req` not reaching Main -- different from the slot not moving.*

**A2. The OSD and the pad agree.** Open the OSD, set `Savestate Slot` to 3.
Close it, and Start+Right once -- it must go to 4, not to 2. This is the
`status_in` feedback path at `SeibuSPI.sv:319`, which exists precisely so the
two do not drift apart. *If it jumps to 2, the pad never saw the OSD's value.*

**A3. Save and load per slot.** In slot 1, save during gameplay (Start+Down).
Confirm `..._1.ss` appears with a fresh timestamp. Move to slot 2, play on a
while, save. Then Start+Up in slot 1 and in slot 2 and confirm you get back the
two *different* moments. *This is the test that proves the slot index reaches
the DDR3 base address, not just the UI.*

**A4. Autoincrement.** Turn `Autoincrement Slot` On. Save three times in a row
from slot 1 and confirm `_1`, `_2`, `_3` all get written and the OSD follows.
Then set slot 4 and save once: **it should wrap to 1**, because the autoincrement
path has no upper bound where the Start+Right path stops at 4. Confirm that
wrap rather than assume it -- and if it wraps, decide whether silently
overwriting slot 1 is what you want.

**A5. Keyboard**, if one is attached. F1-F4 and Alt+F1-F4. Lower priority: the
pad path is the one players use.

**A6. Audio continuity across a load.** Never listened to. Save during a noisy
moment -- a boss, with music -- then load. Listen for: music resuming mid-phrase
rather than restarting, no click or burst at the transition, and no channel left
stuck on. *The YMF271's state is in the blob; a stuck channel would suggest a
register that restores but does not re-trigger.*

---

## B. Sample Flash toggle -- the last unverified path of the flash work

The mode itself ran end to end on hardware (`PLAN.md` 32.7) and all three states
work. What has never run outside simulation is the **0 -> 1 edge**.

**B1. The toggle at boot.** With rdft loaded, open the OSD and switch
`Sample Flash` to `Cart copy`, then reload the MRA. It should spend ~6 minutes on
"NOW UPDATING" with a counter running down, then "UPDATE COMPLETED". *This
confirms `derive_sel` actually reaches the logic -- until now that was only ever
proved by forcing it high in a throwaway build.*

**B2. The live edge.** With the game running in Pre-built, switch `Sample Flash`
to `Cart copy` **while it plays**. The board should blank the region stamp and
**self-reset within about a second**, coming back up copying. This is the 1.1 ms
self-reset that has only ever been simulated.

The save file is currently 516 bytes and holds a valid `80 4A 4A 36` stamp, so
there is something real for the edge to blank. `/media/fat/config/nvram/Raiden
Fighters (Germany).nvm`. Back it up before B2 if you want to repeat the test.

**B3.** Switching back to Pre-built should do nothing until the next boot.

---

## C. Cheap extras, if there is time

**C1. A variant has never been booted** -- 42 of them, all checked offline only.
`Raiden Fighters (Japan, earlier)` under `mra/_alternatives/` is the cheapest: it
shares rdft's job table address, so only the region lock and file names are new.

**C2. The unexplained observation.** On one build, rdft ran the six-minute
updater once on defaults and never again. Load a passing build several times and
watch for it. Intermittent would be worse than broken.

**C3. Service Mode -> INCOME with a coin inserted**, to see a DS2404 counter move
on screen rather than in a file.

---

## If something wedges

`tools/savestate-debug/read_wedge.sh` screenshots the board and decodes the
overlay `spi_top` paints when an operation stays busy past ~146 ms. Validate it
on a healthy core first -- it should say "not wedged".

**Take a fresh in-game save off the board before debugging anything.**
`rdft-ingame-wedges.ss` in this directory reproduced the old lockup and now
replays six clean loads, so it cannot reproduce anything any more.

The deferred simulation work -- the save-point sweep (`tools/savestate_sweep.py`)
and rfjet coverage -- is where to go if a wedge turns out to be systematic rather
than a UI problem.
