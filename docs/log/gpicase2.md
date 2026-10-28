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
