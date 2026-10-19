# Release test plan

Run before publishing images for a board. A release is the kernel, U-Boot,
rootfs and images built from one commit.

For each release: the automatic sweep (~20 min) launches a few games per heavy
emulator, **exactly as the player runs them**, and checks they load, stay up and
keep their sound up to speed. The manual checklist (~10 min) covers what a script
cannot judge. The Dreamcast speed benchmark (part 3) and the CPU stress test
(part 4) run only on request: after a clock or emulator-core change.

**The TV shows every test.** Tell the user before starting anything that will
look or sound worse by design, and never leave a test game running: the scripts
restart the launcher when they finish or are interrupted.

## 1. Automatic sweep: heavy emulators

```bash
wsl bash /mnt/c/RetroArch_PI/scripts/release-test.sh <board>      # zero3 | k2b
```

The board must be reachable over SSH, with the ROM card in and no game running.
The launcher is stopped during the run and the TV shows each game in turn.

- **Games:** `scripts/release-tests.txt`. Three per heavy system (PlayStation,
  Nintendo 64, PSP, Dreamcast) and one each for Neo Geo and MAME. A game that is
  not on the card is reported as SKIP, so the list can be shared between cards.
- **Per game:** RetroArch is started exactly as the launcher starts it. After a
  settle time (load, intro), the **audio speed meter** (RetroArch patch 0007) is
  read for 20–30 s. It measures emulated time against wall time, so frameskip
  and duplicated frames do not distort it.
  - Flycast runs with its normal threaded audio (patch 0007), so for Dreamcast
    the meter reads the **audio output**: ~100% means smooth sound, not full
    emulation speed. For the emulation speed, use the benchmark (part 3).
- **Verdicts:**

| | |
|---|---|
| PASS | RetroArch still running at the end, speed mean ≥ 95% |
| WARN | running, but mean 80–95%, or no speed samples (no audio yet, e.g. a silent menu) |
| FAIL | RetroArch exited (crash or load failure), or mean < 80% |
| SKIP | ROM not on this card |

  Each line also shows the GPU renderer (`Mali-G31 MC1 (Panfrost)` expected),
  the SoC temperature, and the first error line from the RetroArch log, if any.
- **What it does not show:** in-game performance at a demanding spot. Most
  titles sit at a title screen or attract demo during the window, which is
  usually lighter than play. Sonic Adventure 2's attract demo is the exception:
  it is the reference benchmark (see `docs/log/opi-zero3.md`). The sweep is a
  regression check: compare each run with the board's previous results below,
  and investigate any game that changed verdict or dropped by more than ~5%.

## 1b. Game tests: real gameplay with a virtual pad

```bash
wsl bash /mnt/c/RetroArch_PI/scripts/game-test.sh <board> [name-filter]
```

The sweep above measures title screens and attract demos, which run at full
speed anyway. The game tests play the hard part of each game:

- **Start point:** a save state in **slot 10** that the user made at a real
  gameplay moment (in the game: PS + triangle → State Slot → 10 → Save
  State). States are per card, so each board's card needs its own; a game
  without one is SKIP.
- **Input:** a virtual DualShock 3 (`tools/inject-pad.c`, a uinput pad with the
  DS3's IDs, named "RetroArch-PI Test Pad") becomes player 1, with the user's
  own DS3 moved to player 2. It loads slot 10 with PS + L1, waits 3 s, then
  plays the game's sequence from `scripts/game-tests.txt`, e.g.
  `R2:5 R2+RIGHT:0.5 R2:5` (hold R2 5 s, R2 + right 0.5 s, R2 5 s). Triggers and
  sticks are analog (`R2=60`, `LX=-50`).
- **Checks:** a screenshot every 2 s (RetroArch patch 0009: `kill -USR1`
  takes one, without touching input), the audio meter (patch 0007: speed,
  and 0009: level), the state load and the process.

| Verdict | When |
|---|---|
| FAIL | RetroArch exited; slot 10 did not load; every screenshot black; the picture never changed; speed mean < 80%; digital silence |
| WARN | speed 80–95%; some black or unchanged screenshots; very quiet sound (RMS < -60 dBFS); a LibCrypt PS1 disc without its `.sbi` (it would freeze later; also flagged by the sweep in part 1) |
| PASS | everything else |

Back up the slot-10 states with `scripts/fetch-test-states.sh <board>`: it copies
them into the git-ignored `test-states/<board>/<core>/` (md5-checked), in the
card's layout, ready to copy onto another card's `_system/states/`.

Results, screenshots and logs: `<work>/game-tests/<date-time>/`. Look at the
screenshots of anything that is not PASS; a sequence that drives the car into
a wall still tests the emulator, but a better one tests more.

## 2. Manual checklist

| Check | How | Expected |
|---|---|---|
| Boot | Power on, stopwatch to the menu | Zero3 ~6 s; K2B ~6 s |
| Controller | DS3 wired, and over Bluetooth (USB dongle) | Menu responds; PS shows the controls help |
| HDMI audio | Any game, PS + d-pad up/down | Sound; volume steps; level kept after a reboot |
| Save state | Save in a game, quit, resume from the launcher | Game continues where saved |
| Heavy play | 2 minutes each: Burnout Legends (PSP), Sonic Adventure 2 (Dreamcast), Mario Kart 64 | Playable; sound not crackling |
| ROM card | Card in a PC after the run | exFAT readable; folders and README present |
| Power | K2B: inner button. Zero3: Settings → Power Off | Clean shutdown; next boot shows no ext4 recovery (`dmesg \| grep -i recovery`) |
| Network | `scripts/board.sh <board> status` | Reachable; link 1 Gbps |

## 3. Dreamcast speed benchmark (on request)

```bash
wsl bash /mnt/c/RetroArch_PI/scripts/release-test.sh <board> /mnt/c/RetroArch_PI/scripts/benchmark-tests.txt
```

Runs Sonic Adventure 2 (the reference benchmark: its attract demo), Crazy Taxi 2
and MSR with `FLYCAST_THREADED_AUDIO=0`, Flycast's lockstep AICA, so the meter
reads the emulation speed. **The sound on the TV is choppy during this run by
design**; `release-test.sh` prints a warning. It is not what the player hears.

## 4. CPU stability (after a clock or voltage change)

```bash
wsl bash /mnt/c/RetroArch_PI/scripts/board.sh <board> run /mnt/c/RetroArch_PI/scripts/cpu-stress.sh ref     # at the old clock
wsl bash /mnt/c/RetroArch_PI/scripts/board.sh <board> run /mnt/c/RetroArch_PI/scripts/cpu-stress.sh run 10  # at the new one
```

Pass: 0 mismatches, the new top frequency held all 10 minutes, peak temperature
below the 80 °C passive trip.

## 5. Results

Record one line per game per release. Speed is the meter mean over the window.

### KickPi K2B V2.2

From patch 0066 on, the K2B runs the Zero3's clocks: CPU 1512 MHz, GPU 432/600 MHz
with devfreq. `scripts/cpu-stress.sh` at 1512 MHz: 0 mismatches in 1,443 rounds,
100% at 1512 MHz, peak 78 °C after 10 minutes of all-core load (Zero3: 60 °C). The
K2B runs close to the 80 °C passive trip under sustained full load, so a long all-core
load would throttle. (This was with the heatsink fitted; the note first said there was
none. A fan is to be added, then the stress test re-run.)

**2026-10-15, `493287f` + 0066 work in progress, stock clocks (CPU 1416 MHz, GPU fixed 432 MHz):**

| Game | Verdict | Speed mean (min) | Temp |
|---|---|---|---|
| PSX: CTR - Crash Team Racing | PASS | 100.1% (100.0) | 55 °C |
| PSX: Gran Turismo 2 | PASS* | 100.0% (100.0) | 56 °C |
| PSX: Resident 2 | PASS | 100.0% (100.0) | 56 °C |
| N64: Super Mario 64 | PASS | 100.2% (100.2) | 56 °C |
| N64: Mario Kart 64 | PASS | 100.1% (100.1) | 56 °C |
| N64: GoldenEye 007 | **FAIL** | RetroArch exits after 2 s, SIGTRAP in parallel-n64's dynarec | 54 °C |
| PSP: Burnout Legends | PASS | 100.4% (100.0) | 58 °C |
| PSP: Assassin's Creed Bloodlines | PASS | 100.7% (100.1) | 55 °C |
| PSP: Gran Turismo | PASS | 100.4% (100.0) | 58 °C |
| DC: Sonic Adventure 2 | WARN† | no samples in the window; separately 79–98% | 60 °C |
| DC: Crazy Taxi 2 | PASS | 100.1% (100.1) | 59 °C |
| DC: MSR | WARN† | no samples in the window | 60 °C |
| Neo Geo: Metal Slug | PASS | 101.4% (101.4) | 57 °C |
| MAME: 1944 | PASS | 100.3% (100.2) | 57 °C |

\* The card's `Gran Turismo 2.cue` names `Gran Turismo 2 (USA) (Simulation Mode) (v1.2).bin`,
but the file is `Gran Turismo 2.bin`, so the game ran without its disc. A card problem: fix the
`FILE` line in the .cue.
† The GD-ROM games took longer to load cold than the 50 s settle. The list now waits 90 s.

**2026-10-15, with 0066 (CPU 1512 MHz, GPU 432/600 MHz):** same verdicts as at stock clocks.
Every PASS still at 100.0–101.4%; GoldenEye FAIL (unrelated to clocks); SA2 and MSR again no
samples, even with the 90 s settle. Those two ran in lockstep-audio mode in this run, which the
sweep no longer uses. Temperatures 55–64 °C (3–4 °C above stock). Title screens and attract demos
run at full speed either way, so the sweep shows no gain; a gain shows in play and in the
benchmark (part 3).

**GoldenEye 007** (and Perfect Dark) crashed parallel-n64's ARM64 dynarec (SIGTRAP 2 s after
`Init new dynarec`). Fixed by parallel-n64 patch 0004: these two cartridge IDs run on the cached
interpreter. Verified: GoldenEye 87.6–100.2%, Perfect Dark 84.6–99.1% in their intros (expect
WARN rather than PASS in the sweep), Super Mario 64 still on the dynarec at 100%.
That workaround was replaced on 2026-10-16 by the real fix (see the Zero3 entry below).

### Orange Pi Zero3

**2026-10-16, `27f344b` (first build from this tree; U-Boot still the old one):**
12 PASS, 1 WARN, 1 SKIP, 0 FAIL, 44–48 °C. PSX CTR / GT2* 100%; N64 Mario 64 / Mario Kart 100%,
GoldenEye WARN (runs on the cached interpreter, no audio in its window); PSP Burnout 101.0%,
AC Bloodlines 100.6%, Gran Turismo 100.7%; Dreamcast SA2 / Crazy Taxi 2 / MSR 100.0% (threaded
audio, as played); Metal Slug 101.4%, 1944 100.3%. Resident 2: SKIP (not on this card).
\* Same .cue file-name problem as on the K2B's card.

**2026-10-16, new parallel-n64 0004 (dynarec `fp_exception_ds` fix), N64 only, 40 s each:**
GoldenEye 007 and Perfect Dark now on the **dynarec**, alive, settling at 100.1% (GoldenEye
98–100%, Perfect Dark 92–100% over the run). Super Mario 64 100.2%. Conker's Bad Fur Day:
**segfault after ~25 s**, the same on the old core (an earlier, separate bug).
