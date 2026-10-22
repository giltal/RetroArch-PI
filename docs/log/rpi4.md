# Development Log — Raspberry Pi 4

Newest entries at the bottom. Record the wrong turns as well as the fixes.
Plan and decisions: `docs/boards/rpi4.md`.

---

## 2026-10-18 — Step 1: the skeleton

The board layer and defconfig, with the shared files made per family. Nothing is built yet.

**Kernel: `rpi-6.18.y` @ `2341883` (Linux 6.18.57).** Buildroot 2026.02 pins `rpi-6.12.y`
(6.12.61, with firmware `063bcab`, 2025-12-08). The Raspberry Pi kernel also has `rpi-6.18.y`.
That is the same 6.18 series as the H616 boards, so 6.18-specific patches and findings carry
over. The tarball's sha256 is in `board/bcm2711/patches/linux/linux.hash`, and Buildroot
checks it (`linux-source`: OK).

**DT overlays: prebuilt, from the firmware package** (Buildroot's tested path,
`RPI_FIRMWARE_INSTALL_DTB_OVERLAYS`, which also builds the base DTB with `-@`). The other
option was building them from the kernel tree, which would keep them in step with 6.18. Kept
in reserve in case an overlay from the 2025-12 firmware does not suit the 6.18 DTB.

**Mesa: `v3d` + `vc4`, no LLVM.** Only panfrost needs LLVM (its precompiled OpenCL C library).
That saves the LLVM/clang build and the 65 MB libLLVM on the target.

**New layers:**
- `board/bcm2711/`:
  - `linux-retrogaming.config`: vc4, v3d, the firmware/clock/cpufreq/thermal drivers, the SD
    slot, bcmgenet + BCM54213PE, VL805 xHCI on PCIe, all =y;
  - `post-build.sh`: checks the boot-partition files, `vc4-kms-v3d-pi4` with `cma-`,
    `kernel=`/`device_tree=` against the built files, a one-line `cmdline.txt`, and the fstab
    (p3 `/data`, p4 ROMs); creates `/data`;
  - `patches/linux/`: README and hash.
- `board/rpi4/`:
  - `config.txt`: 64-bit, `kernel=Image`, explicit DTB, no initramfs,
    `vc4-kms-v3d-pi4,cma-256`, `boot_delay=0`, `disable_splash`, no camera/display
    detection, `arm_boost`, `enable_uart`;
  - `cmdline.txt`: `root=/dev/mmcblk0p2`, `quiet loglevel=4`, serial0 + tty1;
  - `genimage.cfg`: 64 MiB FAT boot, 1 GiB rootfs, 64 MiB ext4 `/data` (`RETRODATA`, empty),
    exFAT ROMs, all 4 MiB aligned; 28,804 MiB in all, which fits a 32 GB card;
  - `rootfs_overlay/etc/fstab`: replaces the common one.
- `rpi4_retro_defconfig`: generated from the Zero3's by a script that replaces only the board
  blocks (each replacement must match exactly once). The option lines that differ:
  - CPU (`cortex_a72`), issue, layer paths;
  - the kernel (tarball, `bcm2711` defconfig, DTS, not installed into the rootfs);
  - the firmware instead of TF-A/U-Boot;
  - Mesa;
  - `host-mtools` instead of `host-uboot-tools`.

**Shared files made per family.** The H616 boards' results must not change:
- **Kernel fragment split:** `board/common/linux-retrogaming.config` holds the DRM/fbcon core,
  sound core, USB-Ethernet dongles, input, Bluetooth and filesystems. `board/h616/` keeps the
  Allwinner drivers. The H616 boards get the same 77 lines, and no symbol is in both files.
- **exFAT readahead patch:** `h616/patches/linux/0052` → `common/patches/linux/0001`. No
  Armbian patch touches `fs/exfat`, so the patched source is unchanged. It applies to the RPi
  kernel too (dry run).
- **genimage:** `common/genimage.cfg` → `h616/genimage.cfg` (the U-Boot blob at 8 KB is sunxi).
- **post-build:** the extlinux/LZ4/CMA checks moved, byte for byte, to `h616/post-build.sh`,
  which runs after the common one.
  - Changed in the common script: the ROM fstab line is found by mount point instead of as
    `mmcblk0p2`.
  - The kernel-fragment check also looks in `linux-custom/`. It used to skip quietly when the
    kernel `.config` was not found. That would have happened on the Pi, because a tarball
    kernel builds in `linux-custom`. Now it fails.
- **Checked:**
  - `rpi4` defconfig: 113 option lines, 0 lost in `.config`.
  - Zero3 and K2B re-applied: 127 lines each, 0 lost. Their `.config` changed only in the
    three expected lines (post-build list, genimage path, fragment list).
  - Common + h616 post-build run on the Zero3's existing `target/`: both pass, including the
    fragment check against its built kernel.
  - All scripts pass `sh -n`.
  - Not checked yet: a full H616 image build from the new layout. Expected to be identical; to
    confirm with the next Zero3/K2B build.

**Scripts:**
- `boards.sh` has `rpi4` (`~/rpi4`) and a new `BOARD_BOOT` (extlinux | rpi).
- `board.sh kernel` refuses `rpi` for now. The Pi's kernel goes to the FAT p1, which is a
  different install; it gets written with the first boot.

**Not done in this step, by plan:**
- S11alsa's HDMI card detection on vc4 (step 3);
- the read-only root (step 4);
- `board.sh kernel` for the Pi.

## 2026-10-18 — Step 2: first build, OK in 57 min

`build.sh rpi4` worked on the first try in **57 min** (the Zero3 took 116 min with LLVM/clang).
Nothing needed fixing.
- **Config:**
  - defconfig: 113 option lines, 0 lost.
  - Both post-build scripts passed: common, including every kernel-fragment line against
    `linux-custom/.config`, and bcm2711.
  - Kernel `6.18.57-v8`: vc4, v3d, SND, bcmgenet, xHCI-PCI, exFAT, BT and HID_SONY all =y.
  - The shared exFAT patch was applied.
- **Image** (`firmware/rpi4/sdcard.img.xz`, 91 MB; md5 `15c4b2b3…`):
  - p1 FAT32 64 MiB at 4 MiB;
  - p2 ext4 1 GiB;
  - p3 ext4 64 MiB (`RETRODATA`, journal, empty);
  - p4 exFAT 27 GiB.
  - Total 28,804 MiB, as planned.
- **Boot partition:**
  - `start4.elf`, `fixup4.dat`, `config.txt` and `cmdline.txt` as written;
  - `bcm2711-rpi-4-b.dtb`;
  - `Image`, 28.9 MB (the arm64 Image on the H616 boards is 44.7 MB);
  - `overlays/` with 358 overlays, `vc4-kms-v3d-pi4.dtbo` among them.
- **Rootfs:** 263 MB in `target/` (no libLLVM). Mesa 26.0.1 with `v3d_dri.so` and the
  `vc4_dri.so` display stub, so the common Mesa patch 0001 works for vc4 too. All 23 cores.
- **For later:**
  - **1,861 kernel modules**: `bcm2711_defconfig` builds nearly everything as a module.
    That costs udev work at boot and rootfs space. A candidate for the boot-time pass
    (step 5).
  - **HDMI audio:** `S11alsa` will pick `vc4hdmi0` (HDMI0), which is right. But vc4's HDMI
    PCM takes only `IEC958_SUBFRAME_LE`, so a softvol slave of plain `hw:N,0` will most likely
    refuse the stream. Expected fix: slave `hdmi:CARD=vc4hdmi0,DEV=0` (alsa-lib's
    `vc4-hdmi.conf` wraps the iec958 plugin). To verify at the first boot, not guessed now.
  - `board.sh kernel` for the Pi (the FAT p1) is still to write.

## 2026-10-18 — Step 3: first boot

The user flashed `sdcard-small.img.xz` to a 64 GB card. Windows' Disk Management then
recreated the ROM partition over the whole card.

An earlier card was dropped. Its factory partition was 64 GB, matching its 64 GB label, but
the card itself reported 240 GiB, and Etcher failed to write it. That looks like a faulty
controller, not a counterfeit (a counterfeit's label would show the larger number).

**Found it on the LAN** without a serial console: a ping sweep, then `arp -a` for Raspberry Pi
OUIs gave `d8:3a:dd:d4:15:d8` at 10.100.102.89 (now `~/rpi4/board_ip`). The dev SSH key worked
at once. It is a **1 GB** board (970,752 KiB, 256 MiB of it CMA); CPU at 1.8 GHz
(`arm_boost`).

**HDMI showed nothing, and three things were wrong:**
1. **No module could load.**
   - `bcm2711_defconfig` compresses modules (`.ko.xz`). The build's depmod (host-kmod
     without xz) wrote an **empty `modules.dep`**, and BusyBox modprobe cannot read xz either.
     `lsmod` was empty.
   - Fix: `# CONFIG_MODULE_COMPRESS is not set` in the bcm2711 fragment. Now 1,860 plain
     `.ko` files and a full `modules.dep`.
2. **vc4 never bound.**
   - `devices_deferred`: `gpu` "(reason unknown)". Every component (hvs, pixelvalves,
     hdmi0/1, txp) had its driver, and vc4 retried until 11 s. It was waiting on the HDMI
     ports' DDC (EDID) I²C adapters, which `i2c-brcmstb` provides, and that is `=m` in
     `bcm2711_defconfig`.
   - **Proved live:** `xz -d` of the module on the host, `insmod` on the board. vc4 bound at
     once: HDMI-A-1 connected 1920x1080, fbcon on the TV, `vc4hdmi0`/`vc4hdmi1` sound cards.
   - Fix: `CONFIG_I2C_BRCMSTB=y`.
3. **The ROM partition did not mount.**
   - Windows had made **p4 an extended partition** with the volume as logical **p5**. On an
     MBR disk with three primaries already, that is what Disk Management does. The fstab
     mount of p4 failed ("exFAT-fs: failed to read boot sector").
   - Fix, Pi only (`board/rpi4`): the fstab ROM line is `noauto`, and the new
     `/etc/init.d/S02roms` mounts p4, or p5 when p4 is a 2-sector container, with the fstab
     line's options. bcm2711 post-build checks both.

**HDMI audio, as predicted:**
- `hw:0,0` accepts only `IEC958_SUBFRAME_LE` ("Sample format non available"), and
  `hdmi:CARD=vc4hdmi0,DEV=0` (alsa-lib's iec958 wrapper) plays.
- `S11alsa` (common) now slaves softvol to `hdmi:CARD=<id>,DEV=0` for `vc4hdmi*` cards, and
  to `hw:N,0` as before for every other card.
- Tested live: `default` playback rc 0, Master 40%.
- **The user played Game Boy games with sound**, through the live-fixed setup.

**`board.sh kernel` for the Pi** (`BOARD_BOOT=rpi`):
- It mounts p1 at `/run/bootfs`, writes `*.new`, checks `config.txt`/`cmdline.txt`, syncs,
  renames over, then replaces the module tree (shared `install_modules`).
- The first run hit **"No space left on device"**: Image + Image.prev + Image.new is 3 x 29 MB,
  and p1 was 64 MiB. Nothing had been replaced.
- Now the `.prev` set stays on the FAT partition only when it fits, else it goes to
  `/root/bootfs.prev`.
- New images get a **128 MiB** boot partition (image 28,868 MiB, 30.27e9 bytes, still within
  a 32 GB card), so the `.prev` set stays on the FAT partition and can be restored from a PC.
- Installed: Image md5 `61edc208…` and the DTB match on host and board. Pushed S11alsa,
  S02roms and fstab.

**Reboot: everything came up by itself.**
- vc4 is card0, HDMI-A-1 is connected at 1920x1080, fbcon is on, and the launcher is running.
- Both HDMI sound cards are present, and `asound.conf` routes through `hdmi:CARD=vc4hdmi0`.
- `/opt/roms` is mounted from p5, `/data` from p3, and eth0 is up.
- The **USB PS3 pad** enumerated (`054c:0268`).
- CPU 1800 MHz, 47 °C.

**The cost of working modules:** rcS now ends at **4.29 s** (it was 2.11 s with nothing
loading). udev loads Wi-Fi (`brcmfmac`, with no firmware: "Direct firmware load ... failed"),
cfg80211 (no `regulatory.db`), `vc_sm_cma` and more. That is for step 5: build in what is
needed, and stop the rest from loading.

**Also noted:** the launcher's startup log prints "Platform: Orange Pi Zero3 (Allwinner H618)"
on every board (a hard-coded line, cosmetic).

## 2026-10-18 — Boot time, first pass: kernel side and the EEPROM bootloader

The user's stopwatch said **12 s** to the menu (the H616 boards take ~6 s). Kernel time to the
menu was only ~4.3 s. So **~7 s came before Linux**: the EEPROM bootloader, `start4.elf` and
the kernel load.

**Kernel side, measured with one `initcall_debug` boot** (`cmdline.txt` restored afterwards).
The biggest items:

| Item | Time | Fix |
|---|---|---|
| `init_kprobe_trace` | 393 ms | `# CONFIG_KPROBE_EVENTS`, `# CONFIG_FTRACE` (debug features from `bcm2711_defconfig`) |
| bcmgenet + PHY | 193 ms | `driver_async_probe=bcmgenet,brcm-pcie,xhci_hcd` |
| PCIe link (VL805) | 115 ms | same |
| xHCI | 94 ms | same |
| deferred probes (vc4) | 170 ms | — |

Also removed, because udev loaded them at every boot alongside rcS:
- the camera, codec, ISP, HEVC, MMAL, `vc_sm_cma` and VideoCore analog audio drivers (now
  `not set`);
- `brcmfmac` + `cfg80211` (no firmware for either): `dtoverlay=disable-wifi`;
- `hci_uart`: `dtparam=krnbt=off`. Both lines go when the onboard radios are wanted.

**`Image.gz`** (`BR2_LINUX_KERNEL_IMAGEGZ`): 10.3 MB for the firmware to read instead of the
28.9 MB `Image`. post-build checks the gzip magic and that genimage puts the named kernel on p1.

Result, kernel time:

| Marker | Before | After |
|---|---|---|
| SD card found | 2.82 s | **0.56 s** |
| `/sbin/init` | 2.87 s | **0.59 s** |
| Launcher start | 3.82 s | **1.40 s** |
| Menu ready | ~4.3 s | **~2.07 s** |
| Modules loaded | 29 | 5 |

The Pi's kernel now reaches the menu sooner than the Zero3's (~2.7 s).

**`board.sh kernel` (Pi), two bugs found on the way:**
- The free-space check sized the `.prev` copy by the *new* kernel (10 MB). But it copies the
  *old* one (29 MB), so p1 filled up ("No space left").
- BusyBox has no `stat`; it uses `wc -c` now.
- It now handles a kernel name change. The previous set is the kernel the card's current
  `config.txt` names (the old `Image` went to `/root/bootfs.prev`), and that kernel is removed
  from p1 after the switch.

**EEPROM bootloader:** **2023-01 (`63bef4a4`) → `6ab3bfc6`**, the stable `default` channel
`pieeprom-2026-09-23.bin` at rpi-eeprom `7ed1cc2`. The user approved the download and the
write.
- Downloaded files checked against the GitHub listing's sizes and git blob SHAs.
- Config: the release defaults (`BOOT_UART=0`, `WAKE_ON_GPIO=1`, `POWER_OFF_ON_HALT=0`) with
  **`NET_INSTALL_AT_POWER_ON=0`**. The default 1 means a USB keyboard scan for Shift at every
  power-on. HDMI diagnostics are kept, which matters without a serial adapter.
- Done the `rpi-eeprom-update` way: `pieeprom.upd` + `.sig` + `recovery.bin` on p1, reboot.
  The ROM ran `recovery.bin`, which renamed itself `RECOVERY.000`.
- `update-timestamp` = the `.sig`'s `ts` (`6ad52c8a`), so it was our file that got flashed.
  SSH was back 28 s after the reboot command, flash included. The update files were then
  removed from p1.
- Repeatable as `scripts/rpi4-eeprom.sh [install]`, with the config in
  `board/rpi4/eeprom-bootconf.txt`.

**Still to measure:** the stopwatch, power-on to menu, now that both the gzip kernel and the
new bootloader are in.

**Stopwatch after both changes: ~9.5 s** (was 12 s). The kernel accounts for ~2.2 s of the
gain, so the gzip kernel and the new bootloader saved only ~0.3 s before Linux. Pre-kernel is
still ~7.4 s by stopwatch.

**Remote A/B of firmware settings.** `reboot` → SSH answers, minus the uptime at that moment,
gives shutdown + bootloader + firmware: **11.6–11.8 s** (±0.5 s noise). Two reboots per
variant, original `config.txt` restored afterwards:
- `disable_fw_kms_setup=1`: no change.
- `force_eeprom_read=0` + `disable_poe_fan=1`: no change before the kernel, but rcS ended at
  4.0 s instead of 1.9 s. Out.
- Both together: no change.

**Open, parked by the user ("9.5 is reasonable, later"):**
- Is the firmware really slow? Its log can't be read from Linux (`/dev/mem` is blocked by
  `STRICT_DEVMEM`). `uart_2ndstage=1` with a serial adapter on pins 6/8/10 would show it with
  timestamps.
- Or is part of the stopwatch time the TV? Nothing drives HDMI until vc4 starts at kernel
  ~0.3 s (no splash, no firmware picture), and the TV then needs its own time to lock on. To
  check: when does the first picture appear on a power-on?

**The user's observation settles the TV question.** On a power-on nothing is displayed; the TV
detects a signal at ~5 s, and the menu comes ~5 s later.
- The TV is not syncing twice. Its preferred mode is CEA 1080p60 (148.5 MHz), the firmware's
  `video=HDMI-A-1:1920x1080M@60` resolved to that same mode (`userdef`), and the launcher sets
  it as well.
- The firmware itself drives HDMI: `simple-framebuffer ... mode=1920x1080` comes before vc4.

So the timeline is roughly:
- 0–5 s: bootloader + firmware start, then the firmware's HDMI init (the TV's "signal");
- 5–7.4 s: firmware loads the kernel, DTB and overlays;
- 7.4–9.5 s: Linux to the menu.

The ~7.4 s is firmware time, before and after its HDMI step. The serial log
(`uart_2ndstage=1`) is what will show where it goes.

## 2026-10-19 — The TV locked twice on every boot: the firmware off HDMI

The user saw two phases: a signal at ~5 s, then the TV locking again before the menu appeared.

**Counted with one `drm.debug=0x14` boot** (`cmdline.txt` restored afterwards). Three things
touch HDMI:

| When | Who | What |
|---|---|---|
| ~5 s after power-on | VideoCore firmware | starts HDMI (`simple-framebuffer 1920x1080`, black because the splash is off): **lock 1** |
| kernel 0.35 s | vc4 | evicts simplefb, then "mode changed", "modeset on [ENCODER:34:TMDS-34]": a **full modeset**, HDMI restarts, **lock 2** |
| kernel ~1.5 s | launcher | same mode, "keeps [ENCODER:34:TMDS-34]": no modeset |

The launcher is not the cause. vc4 does not take over the firmware's HDMI seamlessly.

**Fix: `hdmi_ignore_hotplug=1` in `config.txt`.** The firmware behaves as if no screen is
attached and leaves HDMI dark; vc4 detects the TV itself.
- No simplefb, and no firmware `video=` on the command line.
- vc4 initialised at **0.17 s** (was 0.30 s, without the simplefb handover).
- HDMI at 1080p, launcher and sound card OK.
- The firmware stage itself did not get shorter (remote reboot timing 11.4–12.5 s, as before).
- **User-verified on the TV: it locks once.**
- bcm2711 post-build now fails without the line.
- Installed with `board.sh kernel`. Image.gz is small enough that the previous set now stays
  as `*.prev` on p1.

**Stopwatch after the fix: 9 s** power-on to menu (user), was ~9.5 s, with one HDMI lock instead of two.

## 2026-10-21 — Mini arcade cabinet case

`hardware/rpi4-arcade-case/` holds a 96 × 88 × 165 mm cabinet for the Snapmaker U1 (4 colours:
black body, yellow trim, red and white side art). It has:
- a 2.4" ST7789V LCD (landscape);
- a 12 mm tactile power button on GPIO3 with a printed cap;
- a 30 mm exhaust fan;
- a decorative joystick, and coin slots that are the air intake.

The source is `arcade_case.py`, a Fusion API script run through the Fusion MCP. Its
parameters are at the top. It builds every part and checks them against reference models of
the Pi 4, LCD, fan and switch (0 clashes). It exports STEP and 3MF per part, in print
orientation with one body per colour, STL per body, and an assembly STEP.

Design choices:
- The core (all walls plus the left side) is one extrusion of the side profile, printed on
  its left side: no supports, and the side art is in the first layers.
- The LCD and the marquee slide into rails, and the tray hooks in at the back. The only
  screws are 5 for the right side, 2 for the tray, 4 for the fan and 4 for the Pi.
- The Pi lies with power, HDMI and audio at the back, USB and Ethernet on the right, and the
  SD card in a slot on the left.

Not checked yet: the LCD module's real size. The rails assume 44.0 mm across and 4.3 mm
thick. Not done yet: the firmware side (`gpio-shutdown` on GPIO3 and a DRM driver for the
ST7789V).

## 2026-10-22 — Arcade case: GPIO3 power button and the SPI status LCD

User decisions:
- The LCD is for **info only**. Games, the launcher and audio stay on HDMI.
- The overlays are always in `config.txt`.

What changed:
- **Power button (GPIO3, pin 5 to GND):** `dtoverlay=gpio-shutdown` makes it a gpio-keys
  KEY_POWER device (`gpio_keys` module, loaded by udev). volumed now also watches an input
  device whose name contains `shutdown_button` and powers off cleanly, as with the K2B's
  key. GPIO3 low wakes a halted Pi 4, so the same button powers it on.
- **LCD (ST7789V, 320x240 landscape):** `dtoverlay=mipi-dbi-spi,spi0-0,write-only` with
  `compatible=retroopi-st7789v`, DC GPIO25, RES GPIO27, BLK GPIO18.
  - panel-mipi-dbi reads its init sequence from `/lib/firmware/retroopi-st7789v.bin`
    (36 bytes: SLPOUT, COLMOD 565, MADCTL 0x60, INVON, NORON, DISPON), written by
    `scripts/gen-st7789v-bin.py`.
  - If the picture is rotated, mirrored, colour-inverted or has red and blue swapped,
    change `MADCTL`, `INVERT` or `BGR` there.
  - All four drivers were already `=m` in `bcm2711_defconfig`; the fragment now lists them
    with the reason.
- **Keeping the LCD off the game screen:**
  - As a module, the panel probes after the built-in vc4 and v3d and becomes the last DRM
    card.
  - The launcher also skips any card whose driver is `panel-mipi-dbi`.
  - RetroArch takes the first card with a connected connector, which is HDMI.
- **`lcdinfo`** (tools, started by `S13lcdinfo` in the Pi 4 overlay):
  - draws once a second, using libdrm dumb buffers, DIRTYFB and SDL2_ttf with the
    launcher's font;
  - shows the running ROM and its system folder (from RetroArch's command line) or
    "In the menu", plus the IP address, CPU temperature, clock and load, and uptime;
  - exits if no panel appears within 60 s;
  - on stop it blanks the panel and sets the backlight's `bl_power` to off.
- **`post-build` (bcm2711):** fails if any overlay in `config.txt` is missing from p1, or if
  the LCD init file is missing.
- **`build.sh` trap:** the first "OK" build shipped the **old** `config.txt`. The
  rpi-firmware package copies `config.txt` and `cmdline.txt` when it installs, so edits
  never reached the image. A full build now dircleans rpi-firmware too, as it already did
  the local packages.

**Tested on the Pi 4 with the LCD and button wired (same day):**
- **The LCD stayed dark at first.** An SPI device's uevent carries only
  `MODALIAS=spi:<first compatible>` (`spi:retroopi-st7789v`), which no module claims, so
  udev never loaded panel-mipi-dbi. The driver matches the second compatible once it is
  loaded: `modprobe panel-mipi-dbi` brought it up as card2 with the init file accepted.
  `S13lcdinfo` now loads it when an SPI device lists `panel-mipi-dbi-spi`. After a reboot
  the panel is up at 1.4 s, and lcdinfo draws.
- **The picture is right** (user-checked): landscape, correct colours, with the defaults
  (MADCTL 0x60, INVON).
- **The launcher stays on HDMI:** `DRM: using /dev/dri/card0`.
- **The button works:** the input device is `soc:shutdown_button@3` (event4), and volumed
  opens it. The user pressed it once: clean poweroff (`KEY_POWER seen at uptime 20.67`, no
  ext4/FAT recovery on the next boot), the LCD blanked. A second press booted the Pi back
  to the menu.
- **Aside (not from this change):** volumed does not open this USB pad. It is named
  "PS3 Controller", not "Sony PLAYSTATION(R)3 Controller", so PS + d-pad volume does not
  work with it on the Pi 4.

**Regression found the same evening: no game started.**
- **Cause:** RetroArch's KMS context (`gfx/drivers_context/drm_ctx.c`) lists `/dev/dri` in
  readdir order and takes the first card with a connected connector. The LCD's card2 came
  before vc4's card0, so every game opened on the 320x240 panel and exited ("Did not find
  suitable video mode for 1920 x 1080"). The launcher's guard did not cover RetroArch, and
  the hardware test above only checked the launcher.
- **Quick fix on the board:** the LCD lines in p1's `config.txt` are commented out (backup
  `config.txt.lcd-on` on p1), and `panel_mipi_dbi` is unloaded. Mario Kart 64 quick start
  runs again (user).
- **Proper fix:** RetroArch patch `0010-drm-ctx-never-take-a-status-panel.patch` skips
  panel-mipi-dbi cards in `gfx_ctx_drm_init()`. Built (with Flycast, so the Pi 4 now has the
  0007 threaded-AICA race fix too), synced, LCD lines restored in `config.txt`, rebooted.
  The log shows `[KMS]: Skipping /dev/dri/card2 (status panel).` and then 1920x1080 on
  HDMI. Mario Kart 64 quick start runs (user).

**lcdinfo now shows the cover art.**
- The layout: the cover is on the left (fitted in 90x100), with the system and the game's
  name wrapped over up to three lines beside it. IP, CPU and uptime are below a yellow
  line.
- The art is found the way the launcher finds it: `thumbnails/<system folder>/<game>.jpg`
  or `.png`, with the folder's name for a game kept in its own folder.
- **Bug found while testing:** nothing showed during a game, because `/usr/bin/retroarch`
  is a wrapper that execs `retroarch.bin`, so the process name is `retroarch.bin`.
  lcdinfo now accepts both names.
- User-checked during Mario Kart 64: cover, system and name are shown.
- **Per-core load:** the bottom line has one bar per core with its %, red at 90% or more.
  It sits under `CPU <temp> <clock> avg N%`, and IP and uptime now share the first line.
  The average alone hid a maxed-out emulator thread (one full core of four reads 25%).
  User-checked.
