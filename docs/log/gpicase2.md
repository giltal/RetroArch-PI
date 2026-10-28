# Development log — Retroflag GPi Case 2 + CM4 Lite

Plan and hardware: `docs/boards/gpicase2.md`. Shared work: `DevelopmentLog.md`.

## 2026-10-27 — Stage 1 (docked): board layer and first image

**Board layer.** `gpicase2` sits next to `rpi4` in the `bcm2711` family; the kernel, Mesa,
RetroArch and every core are the Pi 4's.
- `configs/gpicase2_retro_defconfig` is `rpi4_retro_defconfig` with the board lines changed:
  the issue string, the overlays, genimage, the DTB (`bcm2711-rpi-cm4`) and the firmware
  `config.txt`/`cmdline.txt`.
- `board/gpicase2/`: `config.txt`, `cmdline.txt`, `genimage.cfg` (the Pi 4's layout, with
  the CM4 DTB on p1).
- **The kernel config is the Pi 4's, unchanged.** Already built in: dwc2 (USB host), the
  USB Ethernet drivers (r8152, ax88179, asix, cdc), `snd-usb-audio`. `xpad` is a module that
  udev loads.
- Shared with the Pi 4 now (`board/bcm2711/rootfs_overlay`): `fstab` and `S02roms`, moved
  from `board/rpi4`. The family post-build takes the board's genimage file from its `-c`
  argument, and also checks that the DTB is on p1. The Pi 4 rebuilt clean after the move.

**config.txt, beyond the Pi 4's:**
- `dtoverlay=dwc2,dr_mode=host`: the CM4's USB port as a host (dock ports, built-in pad,
  the case's sound card).
- `dtoverlay=gpio-shutdown,gpio_pin=26`: the power switch → KEY_POWER → volumed powers off.
- `gpio=27=op,dh` + `dtoverlay=gpio-poweroff,gpiopin=27,active_low=1`: the power latch,
  high from boot and low at the end of poweroff.
- `video=HDMI-A-2:d` on the command line. No serial console: GPIO14/15 are the LCD's data
  lines here.

**Not yet run on the hardware.** First-boot checklist, docked, with a USB Ethernet adapter
and a pad in the dock:

| # | Check | Expected |
|---|---|---|
| 1 | Flash `firmware/gpicase2/sdcard.img.xz` to a microSD (not the stock Recalbox card) and boot docked | The launcher on the TV in ~10 s |
| 2 | Built-in pad, and a DS3 in the dock | Both work. The built-in one is an Xbox 360 pad: if the launcher ignores it, use the DS3 for now (its mapping is stage 2) |
| 3 | USB Ethernet | A DHCP address (look it up in the router), written to `~/gpicase2/board_ip`; then `scripts/board.sh gpicase2 status` answers |
| 4 | HDMI audio in a game | Sound on the TV |
| 5 | Power switch off | Clean shutdown, then **the case powers off** (the latch). No ext4 recovery on the next boot |
| 6 | `scripts/game-test.sh gpicase2` | After copying the slot-10 test states to this card (`test-states/`) |

The LCD stays dark in stage 1, and undocked there is nothing on the screen yet.

## 2026-10-28 — First boot (docked)

The CM4 is a **1 GB** module (`a03141`, bootloader 2023-01-11). Kernel and init came up
on the first boot; the USB Ethernet adapter (r8152, RTL8153B) took a DHCP address
(10.100.102.76, now in `~/gpicase2/board_ip`) and the built-in pad appeared as
`Microsoft X-Box 360 pad`.

**Boot loop.** The first attempt looked like an endless bootloader loop
(`SD: card not detected`). The cold boot with `quiet` removed and `panic=0` went through, so
the loop was a warm restart that the bootloader could not read the card on. Not reproduced
since; watch for it.

**The launcher exited: the display has no 1080p.** The dock was on a "YD2680" monitor whose
EDID tops out at 1280×720. The launcher only accepted exactly its build size (1920×1080) and
stopped with `FATAL: DRM init failed`, leaving the boot text on the screen. RetroArch would
have failed the same way (`video_fullscreen_x/y` = 1920×1080: "Did not find suitable video
mode"). Fixed in the launcher, for every board:
- `SCREEN_WIDTH/HEIGHT` are runtime values now. The build size is still preferred; a display
  without it gets the largest progressive mode below it, and the layout scales with it. The
  size is fixed after the first init (buffers such as the help image keep it).
- Every launch writes `/tmp/ra_launch.cfg` (was `ra_slot.cfg`, only with a state) with
  `video_fullscreen_x/y` = the launcher's mode, appended to `retroarch.cfg`.

Pushed to the case: the menu shows at 720p and a game starts and plays.

**At 720p the list icons overlapped.** They are 64-pixel pixel art drawn at whole multiples
only, and a 720p row has 49 pixels for them. `gfx_draw_icon()` takes the box size now
(nearest neighbour, any size); the list keeps whole multiples when they fit (64 at 1080p,
unchanged) and shrinks the icon otherwise.

**A second pad was ignored.** The launcher read only the first gamepad it found: here the
case's built-in pad, so a DS3 in the dock did nothing in the menu. It now reads every pad
(up to 4) and scans for new ones every 2 s. The analog-stick thresholds come from each
pad's own axis range (the DS3 is 0..255, the Xbox 360 pad -32768..32767; with the old
fixed 64/192 a moved Xbox stick would have read as held left/up).

Both pushed to the case and confirmed: the layout is right and the DS3 works in the menu.

**Serial getty.** `enable_uart=0` (GPIO14/15 are LCD data) leaves no ttyS0, and init
respawned the getty on it forever, filling tty1 with `can't open /dev/ttyS0`. The
defconfig has no getty now; log in over SSH.

Still open from the checklist: HDMI audio, the power switch and latch, the game tests, and
`udevadm settle failed` at boot.

## 2026-10-28 — Stage 2: the LCD, the power latch, the built-in pad

**A hang that could not be switched off.** The first LCD attempt (`vc4-kms-dpi-generic` with
the panel's timings, plus `gpio=0-17,19-25=a2`) hung the boot: both screens black, no network,
the SoC hot. The power switch did nothing. Two findings:
- **Docked, the dock powers the board and the switch is only a signal**; pulling the dock's
  power does not help either, the battery takes over (uptime kept counting). Undocked, the
  switch plus the latch decide.
- **The latch was held from power-on** (`gpio=27=op,dh`, and `gpio-poweroff` drives it high
  at probe), so undocked a hung boot stayed on too, until the battery ran down. Recalbox sets
  it from its shutdown script once the system is up. Now: no firmware line, no
  `gpio-poweroff`; `init.d/S03latch` (board/gpicase2 overlay) sets GPIO27 high via sysfs.
  Power-off still cuts the case: a Pi powers off through a watchdog reset that returns the pins
  to their defaults (GPIO27: input, pull-down). Tested undocked: the switch after 30 s shuts
  down cleanly and the LED goes out; the switch 2 s after power-on cuts it at once.

**The LCD hang: panel-simple was a module.** Found in steps, each one undocked-switchable:
- Without the `gpio=` line it still hung: the overlay itself.
- A diagnostic boot (firmware HDMI and splash on, `loglevel=7`) showed the rainbow, then black:
  no kernel text.
- Loaded at runtime over SSH (configfs), the same overlay applied, panel-simple bound and
  DPI-1 appeared at 640x480. (Rebinding vc4 at runtime gives `flip_done timed out` even
  without the LCD, so the live test could not show a picture.)
- A boot that wrote its log to the FAT partition every second left no file: the kernel never
  reached init.
- vc4 is built in and waited for the DPI's panel, whose driver (panel-simple) was a module that
  needs the root filesystem. The same trap as i2c-brcmstb before. `CONFIG_DRM_PANEL_SIMPLE=y`
  (and `CONFIG_BACKLIGHT_CLASS_DEVICE=y`, without which Kconfig silently kept it =m) in the
  bcm2711 fragment: clean boot, DPI bound at 0.26 s.

**Docked, the LCD stays off.** Colour bars from `modetest` on DPI-1 at 640x480, with every pin
in alt2 and the pixel clock at 24 MHz: no backlight. Undocked, the LCD lit at once. The case
switches the LCD off while docked, so the screens are never lit together: docked = HDMI,
undocked = LCD. (So an info-only LCD beside HDMI, as on the Pi 4, is not possible here.)

**The launcher chooses the screen at boot.** It prefers a connected HDMI connector (2 s, since
the LCD is always "connected"), else the panel; `RETROOPI_CONNECTOR` forces one. It passes
`video_monitor_index` with the size to RetroArch. Undocked: the menu on the LCD at 640x480,
and a Game Boy game started.

**The built-in pad in games.** RetroArch had no profile for `Microsoft X-Box 360 pad`
(045e:028e), so the game ignored it. New autoconfig profile (buttons from the pad's key list,
d-pad on hat 0). The hotkeys moved from `retroarch.cfg` into each pad's profile, because
RetroArch only uses a profile's hotkeys when retroarch.cfg leaves them unset, and the modifier
is button 10 on the DS3 (PS) but 8 on this pad (home). Tested docked: both pads play, and
Hotkey/PS + Start quits on each.

**Bootloader card errors.** `SD: card not detected` (or garbage partition table) came back on
some boots, cold ones too; a reseat fixed it. Linux runs the card at 3.3 V high speed, so it is
not a 1.8 V card mode left over. Suspects: the no-name 125 GiB "APPSD" card, or the CM4's old
bootloader (2023-01-11).

**Sound undocked.** S11alsa picked the first card named "hdmi", and the vc4 HDMI cards exist
undocked too, so the handheld was silent. It now takes a `USB-Audio` card when no HDMI
connector is connected (the case's speaker card: `GeneralPlus USB Audio Device`, card 2);
boards without one are unchanged. Tested undocked: sound from the speaker, and Hotkey +
Up/Down changes the volume.

Still open: docking or undocking while running needs a restart (the screen and the sound card
are chosen at boot; a TV slow to raise hot-plug could also send the sound to the speaker); the
bootloader card errors.

## 2026-10-28 — Boot time: where the 20+ s go

Measured docked (process start times from `/proc/<pid>/stat`, the launcher's STARTUP marks,
and a test-only init script sampling the launcher's `/proc/<pid>/stack` every 50 ms):

| Stage | GPi Case 2 | Pi 4 |
|---|---|---|
| Power-on to kernel (bootloader + firmware) | ~10 s or more | ~7 s |
| Kernel to init | 0.5 s | 0.6 s |
| init to launcher start | 2-3 s (udev ~2 s) | 1.4 s |
| Launcher start to menu | 4.5-7.9 s | 0.7 s |

**The launcher's slow step was card I/O.** `favorites+recents` (two files under 1 KB) took
2.3-6.6 s: blocked in `filemap_get_pages` / `mmc_blk_rw_wait`, behind every other boot
service reading its binaries from the card at the same time. The card is slow: a no-name
"APPSD" (manfid 0), 17 MB/s sequential, in 3.3 V high-speed mode (no UHS on this carrier).

**A bug of mine found on the way: the pad hot-plug scan froze the menu.** Every 2 s the
launcher opened and closed every input device; each close of a non-pad device waits for an
RCU grace period, ~220 ms blocked per scan. It now checks the mtime of `/dev/input` every 2 s
and rescans only when it changed. After the fix the idle launcher stays in S (sleeping), and a
restart reaches the menu in 0.76 s.
The mtime check then missed a hot-plugged DS3 (its two nodes appear in the same tick, the
second one unseen until a replug). Now the launcher remembers which event numbers it has
looked at (a bitmask), opens only new ones every 2 s, and forgets a number when its node goes
or its fd fails. Tested: a DS3 plugged in with the menu up works, and again after a replug.

**A DS3 plugged in at a cold boot never appears on USB** (no Sony device in `lsusb`, no connect
on the dock's hub port), though its LEDs flash. The dock's ports have power from switch-on, but
the host starts ~10 s later; the DS3 seems to give up on USB until it is replugged. A software
port power-cycle (`1-1.1-port4/disable`) did nothing: the dock's hub (Terminus 1a40:0101) has
ganged port power. Workarounds: plug the DS3 in once the menu is up, or Bluetooth with a dongle.

Next: the bootloader (2023-01-11) and its ~10 s; a known-good card would also tell how much
of the Linux time is this card.

## 2026-10-28 — CM4 bootloader update

**EEPROM bootloader: `63bef4a4` (2023-01) → `6ab3bfc6`** (`pieeprom-2026-09-23.bin`, the Pi 4's
release, rpi-eeprom `7ed1cc2`). The user approved the write. `scripts/rpi4-eeprom.sh` takes the
board name now (`rpi4-eeprom.sh gpicase2 [install]`) and reuses the Pi 4's verified release
files. Config `board/gpicase2/eeprom-bootconf.txt`: the Pi 4's (`NET_INSTALL_AT_POWER_ON=0`)
plus **`BOOT_ORDER=0xf1`**: SD, else restart and retry SD. It was `0xf25641`, which spent ~30 s
on USB, NVMe and network whenever the card was not detected. The update timestamp matched the
`.sig` (`1793190878`); both warm reboots of the update came back.

DS3 at a cold boot: still not on USB after the update, with or without the PS button; only a
replug wakes it. So it is the dock's ganged port power, not the bootloader's timing.
To check: power-on to menu by stopwatch, and whether the `SD: card not detected` boots still
happen.

**Warm reboots do not come back.** A `reboot` from Linux ends in the bootloader's
`SD: card not detected` and needs a power cycle (the bootloader's own reboots during the update
did come back). Linux runs the card at 3.3 V high speed, so it is not a leftover 1.8 V mode.
The launcher's Restart item would leave the case stuck: to fix, or make it safe on this board.

**Boot writes: relatime without a clock.** After a cold boot the rootfs had done 61 writes
(1.1 MiB, all journal: `jbd2` wrote 372 KiB) that took 24 s of card time, ~400 ms each, and the
launcher's reads queued behind them. With no RTC every boot starts in 1970, the files carry their
build dates, and relatime then updates the access time of every file read at every boot. Fix,
all boards: board/common/post-build.sh makes inittab's remount `remount,rw,noatime` (BusyBox's
remount does not take options from fstab: tried, the root stayed relatime) and fails without it.
Power-on to menu after the bootloader update and before this fix: 18 s (stopwatch).
After the fix (applied to the case's inittab, cold boot): root `noatime`; rootfs writes 61 → 9
(24 s → 3.5 s of card time); launcher start to menu 8.0 → 4.3 s; Linux to menu ~10 → ~6.4 s;
**stopwatch 18 → 15 s**. Left: ~8.5 s before Linux, and the launcher's 3.1 s on the ROM
partition (exFAT, 128 KiB clusters: 122 reads at boot, 39 ms each).

**What still slows the launcher: writes, not the ROM partition.** A test-only sampler logged
every ROM-partition read at boot with the running init script. The exFAT mount (29 reads), the
launcher's files and S46card's folder check (~60 reads, 3.5 MB) are all done by 3.1 s. From
4.3 to 10.2 s the launcher sat in `mmc_blk_rw_wait` with no new ROM reads: behind writes. That
boot the rootfs did 20 writes in 18.5 s of card time (~0.9 s each; 9 the boot before): the
random seed, ext4's mount record, journal commits, the ALSA config. All normal, and fast on a
decent card. Options: a known-brand A1/A2 card first; then ext4 `commit=60` and a later seed
write; or the read-only rootfs.

**Batching the writes (all boards).** S51seedrefresh's detached `seedrng` now waits 20 s (on the
GPi rcS ends while the launcher is still reading the card; `stop` still saves a seed at
shutdown), and the root remount adds `commit=60` (post-build makes it
`remount,rw,noatime,commit=60` and checks it). Cold boot: launcher ready in **1,045 ms**
(`favorites+recents` 1 ms, was 3-7 s), started at 1.92 s, so **Linux to menu ~3 s**.
**Stopwatch 15 → 11.5 s.** Boot-time pass on the GPi: 20+ s → 11.5 s. What is left is mostly
before Linux (~8.5 s: bootloader, firmware, the kernel read from this slow card).

## 2026-10-28 — Battery indicator (dock / battery / low)

**The case gives the CM4 no battery level.** Probed on the case: no `/sys/class/power_supply`,
the only I2C buses are the two HDMI DDC ones (i2c-20/21), no IIO, and the USB devices are the
hub, the pad (Nuvoton "GBA Pi Case+", 045e:028e) and the sound card. The case's own LED is
the only charge display. What the CM4 can see: the dock (it drives HDMI, so HDMI connected =
on the dock's power) and the firmware's under-voltage alarm, hwmon `rpi_volt`
`in0_lcrit_alarm`, which trips as the battery nears empty.

**The launcher shows that, not a percentage** (launcher.c, "Power source"): a plug when docked,
a battery outline when not, a red battery with a `Battery low: dock the case` message once the
alarm holds for two polls running (2 s apart; a load spike can trip it for a moment). LOW then
stays until the case is docked. The icon sits in the header, left of the game count (theme
name in Settings). Opt-in per board with `/etc/retroopi-battery` (gpicase2 overlay): a Pi 4
on a weak supply raises the same alarm. Polled every 2 s: two sysfs reads, no card I/O. Not
shown during a game (RetroArch has the screen); the launcher catches up within 2 s of the
return.

Tested on the case: plug on the TV docked, battery outline on the LCD undocked. **The low state
is untested**: it needs a battery run down to the alarm.

## 2026-10-28 — Handheld fixes: sound, N64 steering, keyboard; slot 10

**No sound undocked again, after the boot got faster.** The case's USB sound card registers at
2.4 s (kernel time), and S11alsa now runs at ~1.2 s: with no USB card yet it picked HDMI. Fix
(board/common S11alsa, so every board): when no HDMI display is connected and no USB card is
there yet, it waits for one (up to 5 s) **in the background** and then configures. The launcher
sets its volume only after its own 2 s HDMI wait, and `alsactl restore` sets the saved level
anyway. Docked, or with a USB card already up, nothing changes. Tested: sound undocked.

**Mario Kart 64 could not steer**: the built-in pad has no stick. `input_playerN_analog_dpad_mode`
works the other way (the stick as a d-pad), so this is a core remap,
`gpicase2/rootfs_overlay/root/.config/retroarch/config/remaps/ParaLLEl N64/ParaLLEl N64.rmp`:
d-pad buttons 4/5/6/7 → left stick 19/18/17/16 (Y-, Y+, X-, X+), ports 1 and 2. A remap
replaces the d-pad on N64, and a DS3 keeps its own stick. Tested: steers.

**On-screen keyboard cut off at 640×480.** Its sizes scale with the height and were tuned for
16:9: ten 68 px keys are 716 px. The key width is now also capped to fit ten keys between the
margins (56 px at 640). Tested: fits.

**Slot-10 quick start "not working": the file, not the code.** RetroArch found the copied
`CTR - Crash Team Racing (USA).state10` (via the launcher's `.state.auto` copy) and the core
rejected it ("is not a savestate?"): all 2,078,056 bytes were zeros, and the other copied
slot-10 files were not on the card at all. A copy cut short before Windows wrote the data
(real states here start with `#RZIPv`). Copy again and eject before pulling the card.
