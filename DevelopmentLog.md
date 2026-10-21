# Development Log — RetroArch-PI (shared)

Newest entries at the bottom. Record the wrong turns as well as the fixes.

Work specific to one board goes into that board's log, `docs/log/<board>.md`:
- `docs/log/opi-zero3.md`: the original project (RetroOPI_Z3), from bring-up to the
  boot-time, PSP and Dreamcast work.
- `docs/log/kickpi-k2b.md`: the KickPi K2B port (DDR3, Maxio PHY, power button, boot time).

---

## 2026-10-15 — Merge: one tree for all boards

The K2B port had been done in a separate copy of RetroOPI_Z3. A file comparison showed about 99%
of the ~5,100 files identical. The rest was either the K2B board layer, or fixes found on the K2B
that the Zero3 needed too:
- the CRLF core patches
- `/opt/roms`
- dash's `-nt`
- exFAT
- volumed's GPIO power key

That drift is the reason for the merge. The user chose a single public repository named
RetroArch-PI, made from the existing `Retro-OrangePI-Zero-3` repo (renamed on GitHub, so its
history and URL redirect carry over). The K2B and a later Raspberry Pi 4 are added as boards.

What was done, in `C:\RetroArch_PI` (a clone of the Zero3 repo, so its 37 commits carry over):

1. **Restructure** (`git mv`, Zero3 only) into `board/common`, `board/h616`, `board/opi-zero3`.
   - The defconfig lists the layers (overlays, global patch dirs, kernel fragments).
   - `post-build.sh` now checks every listed kernel fragment, taking the last value of each
     symbol.
   - `build.sh`/`board.sh` take a board name; the board table is `scripts/boards.sh`.
2. **Line endings:** this machine has `core.autocrlf=true`, and the clone came out with
   **CRLF in 454 text files**, including the kernel fragment. The per-type `.gitattributes`
   rules didn't cover `*.config`, Makefiles or extensionless files.
   - Now `* text=auto eol=lf` is the default.
   - Found on the way: **`grep $'\r'` in this Git Bash does not match CR**; it reported CRs in
     LF files. Use `git ls-files --eol`, or count bytes in Python.
3. **Shared fixes from the K2B port** applied to `common`/`h616`: the CRLF core patches
   (`-text`), `/opt/roms`, LZ4 on a fresh tree, exFAT + S46card + card README, volumed GPIO key,
   U-Boot `kernel_addr_r`.
4. **K2B added as a board.** Its defconfig was generated from the Zero3's and differs only in
   the board lines.
5. **Docs:** README (supported boards and setups), BUILDING, CLAUDE.md, Context.md, flashing.md.
   Per-board context and logs moved to `docs/`.

## 2026-10-15 — USB host drivers probe asynchronously (both boards)

With a USB DS3 attached at power-on, the K2B's boot could stall about 0.8 s. EHCI
registration waits on the USB core's EHCI/OHCI companion lock while the pad enumerates on
another port, and the host drivers probed in the init thread.

Both boards' extlinux.conf now have `driver_async_probe=ehci-platform,ohci-platform` (the K2B
also keeps `dwmac-sun8i`). On the K2B, init went from 1.92 s to 1.11 s with the pad attached.
Details in `docs/log/kickpi-k2b.md`.

## 2026-10-16 — parallel-n64: GoldenEye and Perfect Dark back on the dynarec

The SIGTRAP in both games was a stray `brk 0` at the start of the ARM64 `fp_exception_ds`
(Coprocessor Unusable in a delay slot), not the TLB handling the K2B log suspected. The new
parallel-n64 0004 removes it, and replaces the cached-interpreter workaround. Verified on the
Zero3: both games run on the dynarec at ~100%. Found on the way: Conker's Bad Fur Day segfaults
after ~25 s, with the old core too. Details in `docs/log/opi-zero3.md`.

## 2026-10-18 — Raspberry Pi 4: plan and skeleton; shared files made per family

The Pi 4 gets a family layer, `board/bcm2711`, and a board layer, `board/rpi4`. It uses the
Raspberry Pi kernel (`rpi-6.18.y`, 6.18.57) and VideoCore firmware boot. Mesa runs v3d without
LLVM. The layout adds a `/data` partition for the planned read-only root. Plan:
`docs/boards/rpi4.md`; details: `docs/log/rpi4.md`.

For it, these shared files became per family, and the H616 boards' effective config did not
change:
- **Kernel fragment:** split into `common` and `h616` (same 77 lines).
- **exFAT readahead patch:** moved to `board/common/patches/linux/0001`.
- **`genimage.cfg`:** moved to `board/h616/`.
- **Post-build:** the extlinux/LZ4/CMA checks moved to `board/h616/post-build.sh`. The
  kernel-fragment check now fails instead of skipping when it cannot find the kernel `.config`.

Re-applying the Zero3 and K2B defconfigs lost no lines.

## 2026-10-18 — Save states never worked: "Core does not support save states" (all boards)

The user reported it on every board. The Pi 4 log showed it for Game Boy (Gambatte), PSP
(PPSSPP) and Dreamcast (Flycast).

**The cause is RetroArch 1.19.1 with no core info files**, and this image ships none.
- RetroArch decides save-state support per core from its `.info` file. For a core without one,
  the core info cache (`~/.config/retroarch/cores/core_info.cache`, rzip-compressed JSON)
  records `"savestate_support_level":0` (DISABLED) and `"has_info":false`. That held for
  every core.
- `task_save.c` checks only that level, so it refused before asking the core.
- The comment in `core_info.c` ("assume all cores have full savestate support") applies only
  when an info file exists.

Ruled out on the way:
- the save size: `retro_serialize_size()` of Flycast and PPSSPP return non-zero;
- our RetroArch patches and the launcher;
- RetroArch's stdin command interface for testing, which does not initialise here (as
  `tools/inject-input.c` already says). Testing used uinput F2/F4 instead.

**Second bug, found along the way:**
- `savestate_directory` was never set, so RetroArch wrote states to
  `/root/.config/retroarch/states/` on the rootfs.
- The launcher's resume-from-slot looks in `/opt/roms/_system/states/<core>/`
  (`launcher.c STATES_DIR`), so it could never have found a state.
- And the root is to become read-only.

**Fix** (shared `retroarch.cfg`, with post-build guards for both lines):
- `core_info_savestate_bypass = "true"`;
- `savestate_directory = "/opt/roms/_system/states"`. RetroArch adds the per-core folder
  itself.

**Verified on the Pi 4** with the shipped config: uinput F4 (load, nothing saved), F2 (save),
F4 (load), state slot 9, test files removed.

| Core | Load, nothing saved | Save | Load | On the card |
|---|---|---|---|---|
| Gambatte | "Failed to load state" (correct) | 26,704 B | OK | 5 KB |
| PPSSPP (Burnout Legends) | same | 50.3 MB | OK | 12.0 MB |
| Flycast (Sonic Adventure 2) | same | 36.4 MB | OK | 8.4 MB |

**Left over:**
- Pushed to the Pi only; the Zero3 and K2B were offline.
- The test plan's "save, quit, resume from the launcher" is still to be checked by hand.
- A PSP state is 12 MB written to exFAT, which has no journal: the power-cut work (rpi4 step 4)
  should cover it.

## 2026-10-19 — Nothing written to the rootfs during play (all boards)

The user asked whether the system is safe from power cuts without the read-only root (rpi4
step 4). Game data loss is acceptable to them; the system must keep booting.

**What was written at runtime.** Listed on the Pi 4 rootfs. It has no RTC, so runtime writes
carry 1970 dates and image files 2026 dates; a first `-newer /etc/os-release` check found
nothing because of that.
- **In-game saves:** `savefile_directory` was never set, so `.srm`, PS1 memory cards and PSP
  `SAVEDATA` went to `/root/.config/retroarch/saves/`.
- `content_history.lpl` and `core_info.cache`, on every launch.
- `asound.state` at shutdown; Bluetooth pairings; the dropbear host key (once); the seedrng
  seed.

**Assessment.**
- The files a boot needs are never written at runtime: FAT p1 is unmounted, and the binaries
  change only through `board.sh push`, atomically.
- ext4's journal keeps the filesystem consistent.
- The remaining risk is the SD card. A power cut while the card is writing can damage other
  blocks it is moving internally, the usual way a Pi stops booting. So: no rootfs writes during
  play.

**Change** (shared `retroarch.cfg`, post-build guards for each line):
- `savefile_directory = "/opt/roms/_system/saves"`;
- `history_list_enable`, `core_info_cache_enable` and `content_runtime_log(_aggregate)` all
  `false`.

**Old saves:** S46card copies `/root/.config/retroarch/saves` to the card once, with `cp -rn`
(never overwrites), leaves the rootfs copies in place, and stamps
`_system/saves/.retroopi-copied-from-rootfs`.

**Two bugs found on the Pi while testing:**
- **`cp -rn "$OLDSAVES/." dest/` copied nothing and returned success.** BusyBox treats `dest/.`
  as an existing target, and `-n` skips the whole tree. S46card now copies file by file from a
  list file with `while read`, because names have spaces and [brackets]. It skips any file
  already on the card, and stamps only when every copy succeeded.
  - On the Pi: 8 files copied, all byte-identical (PS1 memory cards, CTR, PSP SAVEDATA,
    Mario Kart 64, PC Engine).
  - The first test session had already written a fresh Mario Kart save to the card. It was
    deleted, so the user's real one was copied instead.
- **Timestamp checks don't work on this clock.** It restarts at 1970 on every boot, so files
  from a longer earlier boot look newer than a marker, and exFAT stores pre-1980 times as 1980.
  The test now snapshots path, size and full mtime of the whole rootfs before and after a
  session, and diffs them.

**Mesa's shader cache** was the remaining writer during play (`/root/.cache/mesa_shader_cache`,
new shaders in 3D games). The RetroArch wrapper now exports
`MESA_SHADER_CACHE_DIR=/opt/roms/_system/cache/mesa`, and post-build checks it.

**Verified on the Pi 4** (30 s sessions, rootfs snapshot diff):
- Mario Kart 64: SRAM saved to `_system/saves/ParaLLEl N64/`, **0 rootfs changes**.
- PSP Burnout Legends, with an empty cache: shaders compiled into the card's cache (12.5 MB,
  43 files), **0 rootfs changes**.

The card README now explains `_system/saves`, `states` and `cache`.

What still writes the rootfs: `asound.state` (volume) at shutdown, Bluetooth pairing, the
seedrng seed at boot, and `asound.conf` only when the sound card changes. All are small, and
none happens during play; they are the rest of the read-only-root work.

**Not yet done:** the Zero3 and K2B were offline. They get this with their next build, or with
`board.sh push` of `retroarch.cfg`, `S46card`, `/usr/bin/retroarch` and `card-README.txt`,
followed by a reboot so S46card copies their old saves across.

## 2026-10-19 — Game tests: real gameplay, a virtual pad, screenshots and sound level

The user asked for a more accurate release test. Their design: each test starts from a slot-10
save state they make in real gameplay, and they give the inputs, e.g. Sega Rally 2:
`R2 5 s, R2 + RIGHT 0.5 s, R2 5 s` (R2, the DS3's analog trigger, is the accelerator).

**Pieces:**
- **`tools/inject-pad.c`:** a uinput gamepad with the DS3's USB IDs (054c:0268), buttons and
  six axes (sticks; Z/RZ = analog L2/R2). RetroArch maps it with the shipped PS3 autoconfig.
  It is named "RetroArch-PI Test Pad". Steps are `INPUTS:SECONDS`, with analog `R2=60`,
  `LX=-50`. Each step is logged with a monotonic timestamp.
- **RetroArch 0009:**
  - `SIGUSR1` takes a screenshot (flag in the signal handler, `CMD_EVENT_TAKE_SCREENSHOT` on
    the main thread);
  - the speed line now also reports the level of what the core produced:
    `level rms -12.7 peak 0.0 dBFS`.
- **`scripts/game-tests.txt`, `game-test-board.sh`, `game-test.sh`, `png-stats.py`:**
  pure-Python PNG stats (mean, std, frame-to-frame diff on a 64x36 grid), so nothing needs to
  be installed on the build host.

**Wrong turns:**
- **`retroarch -e 10`** (load an entry state) did nothing for Flycast: no `[State]` line at
  all. It loads at content load, and Flycast loads its own disc ("Content loading skipped") and
  cannot take a state before its first frame. Slot 10 is now loaded the way a player does it:
  `state_slot = 10` in the test config, and the pad presses **PS + L1**.
- **Reserving player 1 by name** (`input_player1_reserved_device = "RetroArch-PI Test Pad"`,
  type 2) did not take: the user's DS3 kept port 1, so the test pad's input went to player 2.
  Now `input_player1_joypad_index` = the number of joysticks present before the pad is
  created (its index), and player 2 = 0.
- The last screenshot was cut off ("not a PNG"): wait 3 s after it before stopping RetroArch.
- Screenshot names carry the game title, with spaces: png-stats prints the path last, and
  game-test.sh passes the names as an array.

**First real run, Sega Rally 2 on the Pi 4: PASS.**
- State loaded (36 MB), speed 99.9% during the sequence, sound -10 to -13 dBFS RMS.
- Four screenshots, all different: the start straight at 17 mph at 1.5 s; at 10.9 s, 25 mph
  and off the road against the fence (the 0.5 s right steer at the first bend). The pad
  really drives.

**Also found:**
- **R2 is digital in our PS3 autoconfig** (`input_r2_btn = "7"`, no `input_r2_axis`). Games
  get full throttle or none. Mapping ABS_RZ/ABS_Z as analog triggers is a separate
  improvement; the virtual pad can test it.
- **Core `.opt` files are rewritten once per core.** RetroArch writes the full option set on a
  core's first launch, because our shipped files hold only the tuned keys (PCSX 15 → 59,
  PPSSPP 6 → 76), and it creates one for cores we ship none for. All shipped values survive.
  After that the file is complete: a Flycast session snapshot shows 0 rootfs changes, despite
  the "Saved core options file" log line. A one-time write per core on a fresh image. Shipping
  complete `.opt` files would remove it.

## 2026-10-19 — Launcher: quick start from slot 10 (START)

The user's idea: the slot-10 state they save for the game tests (RetroArch menu → State Slot
10 → Save State) is a "start here" bookmark the launcher could use. The slot picker only shows
slots 0–9 (`MAX_SLOTS`), so slot 10 was invisible.

The user chose (asked first; Triangle was proposed, but it already toggles favourites):
- **START in a game list** (system, favourites, recents) launches from slot 10 (`QUICK_SLOT`),
  through the same `launch_game()` path as the picker (copy to `.state.auto`,
  `savestate_auto_load`). No picker.
- **No slot-10 save:** a centred message for ~2 s, "No quick-start save (slot 10)" (`msg_show`,
  drawn and expired like the letter-jump hint). Nothing launches.
- **A ▶ marker** right of the name, left of the favourite star's column, on games with a
  slot-10 state. Checked for the visible rows at each redraw, so a new state shows when the
  list comes back.
- **Saves after a quick start go to slot 0** (PS + R). The launcher normally makes the
  launched slot the save slot. For slot 10 that would overwrite the bookmark and the tests'
  start point, so slot 10 changes only on purpose, from the menu.
- Footer: "START QUICK ▶". Help screen (PS tap): START now reads "Quick start (slot 10)" over
  "PS + Exit game" (`scripts/gen-help-image.py`, image regenerated).

**User-verified on the Pi 4:** marker shown, START launched from slot 10, PS + R saved to
slot 0, the message appears on games without a slot-10 save. In the logs: Mario Kart 64
`LAUNCH ... (slot=10)`, auto-load from `.state.auto` succeeded, `state_slot = "0"`.

## 2026-10-19 — CTR froze mid-game: LibCrypt without its .sbi

The user: CTR starts, then hangs at some point; quitting still works. RetroArch's log of the
running session:

```
CD-ROM ID: SCES02105
LibCrypt game detected with missing SBI/subchannel
```

The card's CTR is the European release, which is LibCrypt-protected. Its protection checks
subchannel data that a `.bin/.cue` rip does not contain. When the check fails, the game
breaks itself later, typically freezing in or after a race. Only the game inside RetroArch is
stuck, so it is the same on every board. The sweeps never caught it, because they ran CTR for
30 s at the title screen.

**Fix: the user's disc's `.sbi` (from its redump entry) next to the `.cue`, same name.**
PCSX-ReARMed loads it automatically. The launcher does not list `.sbi`. The US release
(SCUS-94426) has no LibCrypt. No change to the image.

**So it cannot pass a test unnoticed again:**
- `release-test-board.sh` reports "LibCrypt: .sbi missing next to the .cue" in place of other
  log errors, and `release-test.sh` turns that PASS into WARN;
- `game-test.sh` WARNs on the same log line;
- the card README explains `.sbi` for PS1;
- `docs/test-plan.md` lists it under WARN.

## 2026-10-19 — K2B and Zero3 rebuilt from the current tree; the K2B synced and game-tested

**Builds** (`linux-dirclean` + `retroarch-dirclean`, then full): K2B 16 min, Zero3 17 min.
- **Kernel `.config` identical to before the per-family split** (4,701 settings each), and
  U-Boot identical. The split (common/h616 fragments, the exFAT patch now in
  `board/common/patches/linux`, genimage and post-build per family) changed nothing for them.
- Shared and h616 post-build pass. inject-pad and RetroArch with 0009 are built.

**New: `scripts/sync-rootfs.sh <board> [-n]`.** It md5-compares every file in `target/` with
the board and installs the differing ones with `board.sh push`.
- Left alone on purpose: kernel and modules (`board.sh kernel`), passwd/group/shadow
  (image-time accounts), SSH host keys, runtime files, and the core `.opt` files RetroArch
  filled in.
- First version: `diff` exits 1 when anything differs, which `pipefail` turned into a silent
  exit.
- **`board.sh push`** now numbers its `/tmp` copies, because scp's remote path goes through a
  shell and names have spaces and parentheses. It also creates missing parent folders.

**K2B:**
- Synced: 10 of 710 files differed (launcher, RetroArch + wrapper, inject-pad,
  parallel-n64, `retroarch.cfg`, S11alsa, S46card, card README, help image).
- `board.sh kernel` (md5 match), reboot. Afterwards 0 files differ. HDMI 1080p, both sound
  cards, launcher.
- rcS took 4.4 s on that boot: S46card's one-time copy of the old rootfs saves.
- The four slot-10 states copied from `test-states/rpi4` (same ROM files; md5-checked).

**Game tests on the K2B:**
- **First run:** Sega Rally 2 **crashed** on loading its state, and the other three ran
  ~86%.
- **The ~86% was the test.** A screenshot stalls the emulator ~2 s on the H616 (the shots came
  out 4 s apart instead of 2). Mario Kart: 85.6% with a shot every 2 s, 96.9% with shots only
  at start and end. `video_gpu_screenshot = false` (the core's frame instead of 1080p) did not
  help, so the cost is not the readback size.
  - Now: screenshots at the start and end by default (`SHOT_EVERY=0`; `SHOT_EVERY=2` for more).
- **Second run: all four PASS:**

| Game | Speed | Sound |
|---|---|---|
| Sega Rally 2 | 96.6% | -10 dBFS |
| Mario Kart 64 | 98.1% | -17 dBFS |
| CTR | 97.1% | -18 dBFS |
| Burnout Legends | 98.1% | -9 dBFS |

**Open: Flycast crashes intermittently on a state load.** Once in two loads on the K2B, never
in two on the Pi:

```
[State]: Loading state ".../Sega Rally 2 (USA).state10"
[AICA] AICA running on its own thread
terminate called after throwing an instance of 'std::system_error'
  what():  Invalid argument
```

The AICA line is our threaded-audio patch. A state load restarts that thread, and the restart
threw, typically a join or start on a thread in the wrong state. A race whose timing differs
by board. A player's PS + L in a Dreamcast game can hit it.

## 2026-10-19 — Flycast: crash on savestate load fixed (threaded-AICA start/stop race)

**Reproduced on the K2B:** the virtual pad loaded Sega Rally 2's slot 10 every 3 s, and the
18th of 25 loads crashed RetroArch:

```
terminate called after throwing an instance of 'std::system_error'
  what():  Invalid argument
```

**The cause is a race in our 0007 (threaded AICA).**
- `startThread()` runs on the SH4 thread (`AicaUpdate`), and set `threadRunning = true` before
  assigning the `std::thread`.
- `stopThread()` runs from the emulator's stop/reset/term on the frontend thread. On a load,
  `emu.stop()` stops the AICA thread while the SH4 thread may still be in `AicaUpdate`,
  restarting it (hence two "AICA running on its own thread" lines per load).
- Nothing serialised the two. A stop could `join()` a thread flagged running but not yet
  assigned, or one another stop had already joined. `join()` on a non-joinable `std::thread`
  throws EINVAL, which crashed RetroArch.

**Fix, in 0007:** a `threadCtl` mutex around start and stop, which both decide by
`thread.joinable()` instead of the flag; the flag is set only after the thread exists. No
deadlock path: the AICA thread never takes `threadCtl`.
- Regenerated only 0007's `aica.cpp` section: the before-state is the built file with that
  section reversed.
- The whole series 0001–0008 dry-run on pristine Flycast v2.7: all apply, and the result is the
  edited file.

**Verified on the K2B:**
- **75 reloads in 3 runs, 0 crashes** (before: a crash at the 18th);
- game tests all PASS: Sega Rally 2 97.3% at -10 dBFS, Mario Kart 96.8%, CTR 97.1%,
  Burnout 98.4%.

**Not yet installed** on the Pi 4 and the Zero3: both were offline. Install them with
`build.sh <board> libretro-flycast-dirclean` + build, then `sync-rootfs.sh`.

Also seen, still open:
- Flycast game tests take only the start screenshot; the end one is missing (other cores get
  both).
- The K2B's `Flycast.opt` holds three `reicast_texupscale*`/`dump_unique_textures` values the
  core rejects ("Invalid value"), left over from an older core. Harmless; defaults apply.

## 2026-10-21 — Zero3 aligned with the current tree

- Flycast rebuilt with the fixed 0007 (the Zero3's image had been built before the fix).
- `sync-rootfs.sh zero3`: 11 of 710 files (the K2B's 10, plus Flycast). Then
  `board.sh kernel` (md5 match) and a reboot.
- Afterwards 0 files differ. HDMI 1080p, both sound cards, launcher running.
- rcS took 5.6 s on that boot: S46card's one-time copy of the old rootfs saves, as on the K2B.
- The card has the same four test games, the same files as the K2B's (first-MB checksums). The
  four slot-10 states copied from `test-states/rpi4`, md5-checked.
- **Game tests, all PASS:**

| Game | Speed | Sound |
|---|---|---|
| Sega Rally 2 | 95.1% | -10 dBFS |
| Mario Kart 64 | 97.7% | -17 dBFS |
| CTR | 97.0% | -18 dBFS |
| Burnout Legends | 98.7% | -9 dBFS |

- **Flycast reload stress:** 50 slot-10 loads in 2 runs, 0 crashes.

Both H616 boards now run the current tree. The Pi 4 still lacks the Flycast fix (offline).
