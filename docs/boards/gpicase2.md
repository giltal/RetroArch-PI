# Board — Retroflag GPi Case 2 + Compute Module 4

> **Status 2026-10-28: docked (HDMI) and handheld (LCD) both run the menu and games.** The case
> switches the LCD off while docked; sound follows (HDMI or the case's speaker). Open: dock changes
> need a restart. Log in
> `docs/log/gpicase2.md`.

> Fourth target, and the first handheld. A Compute Module 4 (BCM2711, the Pi 4's SoC) in
> Retroflag's GPi Case 2: a 3.0" 640×480 LCD, built-in controls, speaker and headphone jack,
> a 4000 mAh battery, and a dock with HDMI and two USB 2.0 ports.
> Assessment 2026-10-27, from Retroflag's scripts and **the case's stock Recalbox card**
> (read only); nothing of ours has run on the hardware yet. Proposed build name: `gpicase2`.

## Verdict

**Feasible, and most of it already exists.** The SoC, kernel, firmware, Mesa (v3d + vc4),
RetroArch and every core are what the Pi 4 runs today. A `gpicase2` board would sit next to
`rpi4` in the `bcm2711` family and differ in its boot config, a few kernel options and
how the case's hardware is wired. Recalbox already runs this case under KMS, the same display
stack as ours, which settles most open questions. Two stages:

1. **Docked** (HDMI + USB): close to the Pi 4 as it is. New: the CM4's USB host mode, the
   power switch and power latch, and SSH over a USB Ethernet adapter.
2. **Handheld** (LCD, controls, speaker): the LCD through a stock KMS overlay with the panel's
   timings, the case's USB sound card and USB pad, and a launcher and RetroArch that run at
   640×480 and pick the screen at boot.

## The hardware

| Item | Detail | Source |
|---|---|---|
| Module | **CM4 Lite**: boots from an SD card in the cartridge, like the Pi 4 (no `rpiboot`). RAM size and Wi-Fi still to check | user |
| Screen | AUO **A030VVN01**, 3.0" 640×480, on the **DPI** pins, **18-bit, "cpadhi" pin mapping** (`dpi_18bit_cpadhi_gpio0`). Timings: 640 + 41/40/41, 480 + 18/9/18, **24 MHz** pixel clock (= 60.0 Hz) | stock card: `vc4-kms-dpi-a030vvn01-0.dtbo`, `recalbox-user-config.txt` |
| DPI pins | `gpio=0-17,19-25=a2`: GPIO0–25 except 18 | stock card |
| Dock | HDMI = the CM4's **HDMI-A-1** (the cmdline turns HDMI-A-2 off: `video=HDMI-A-2:d`), 2× USB 2.0, USB-C power | stock card; Retroflag |
| Dock detect | **GPIO18** = the HDMI hot-plug line (1 = docked). Recalbox instead reads `/sys/class/drm/card1-HDMI-A-1/status` (+ EDID) | Retroflag scripts; Recalbox `manage.py` |
| USB | `dtoverlay=dwc2,dr_mode=host`: the dock ports, the pad and the sound card are all behind it | stock card |
| Power switch | **GPIO26**, pull-up: sliding off = falling edge → shutdown | Retroflag and Recalbox `SafeShutdown.py` |
| Power latch | **GPIO27**, output, driven high while running; the case cuts power when it drops | same |
| Audio | A **USB sound card** in the case (`snd-usb-audio`), feeding a mono speaker and the headphone jack. Recalbox mixes it down to mono (PulseAudio remap) | `92-gpicase2-audio.rules`, `gpicase-audio` |
| Controls | A **USB "Xbox 360 Controller"** (045e:028e; kernel `xpad`): A/B/X/Y = BTN_SOUTH/EAST/NORTH/WEST, Select 314, Start 315, hotkey (Mode) 316, d-pad on the hat | `es_input.cfg` |
| Ethernet | The CM4 has a Gigabit PHY, but the case has no RJ45: **USB Ethernet adapter in the dock** (user) | — |

## Stage 1: docked (HDMI + USB)

| Need | Work | Size |
|---|---|---|
| Board layer | `board/gpicase2/` (config.txt, cmdline.txt, genimage, fstab) and `configs/gpicase2_retro_defconfig` (the Pi 4's, with `bcm2711-rpi-cm4.dtb`); `scripts/boards.sh` entry | small: a copy of `rpi4` |
| USB | `dtoverlay=dwc2,dr_mode=host`; `CONFIG_USB_DWC2` built in (the Pi 4 uses the PCIe XHCI instead) | small |
| USB Ethernet | `r8152`, `ax88179_178a`, `asix` built in (`lsusb` will tell which); S40network brings up whatever `eth*` appears | small |
| Power switch | `dtoverlay=gpio-shutdown,gpio_pin=26`: volumed already turns its KEY_POWER into a clean poweroff | small |
| Power latch | `gpio=27=op,dh` (the firmware drives it high at boot) and `dtoverlay=gpio-poweroff,gpiopin=27,active_low=1` (low at the very end of poweroff) | small; **verify** the case does not cut power before the halt |
| Display, games | HDMI-A-1 at 1080p, HDMI audio, the launcher and the game tests as on the Pi 4. `video=HDMI-A-2:d` as Recalbox does | none |
| Pads | A DS3 in the dock works as today. The built-in pad shows up too, as a second USB pad | none |

## Stage 2: handheld (LCD, controls, speaker)

| Need | Work | Size |
|---|---|---|
| LCD | `dtoverlay=vc4-kms-dpi-generic` (already in our firmware's overlays) with `rgb666-padhi`, `clock-frequency=24000000`, `hactive=640,hfp=41,hsync=40,hbp=41`, `vactive=480,vfp=18,vsync=9,vbp=18`, plus `gpio=0-17,19-25=a2`. vc4 then has **two connectors**: DPI-1 (the LCD) and HDMI-A-1 | small to medium (a test pattern first; pixel-clock polarity may need a flip) |
| Screen choice | Both connectors are on the same vc4 card, so no `config.txt` swap and no reboot: at boot the launcher (and RetroArch) use HDMI-A-1 when it is connected, else DPI-1. GPIO18 is the fallback signal | medium |
| Launcher at 640×480 | Its layout already scales with the screen height (`UI_SCALE`, tuned at 480 lines), but the size is a build option today (`SCREEN_W/H`). It has to become a runtime value from the chosen connector's mode | medium |
| RetroArch at 640×480 | `retroarch.cfg` fixes 1920×1080; the launcher adds a per-screen config. Fewer pixels: the heavy cores run faster on the LCD | small |
| Audio | The case's USB sound card: S11alsa (and the softvol control the launcher and volumed share) must pick it when undocked, HDMI when docked. Mono downmix in ALSA (`route` plugin) | medium |
| Built-in pad | `xpad` in the kernel (check), RetroArch's Xbox 360 autoconfig, and the launcher's button mapping (it knows the DS3's codes today). volumed's volume combo needs the pad's "hotkey" (BTN_MODE 316, same code as the DS3's PS) | small to medium |
| Battery | No fuel gauge (no I2C, ADC or power_supply). The launcher shows dock/battery and a low warning from the under-voltage alarm (`/etc/retroopi-battery`) | done |

## Still open

1. Whether the CM4 has **Wi-Fi** (not needed: USB Ethernet). RAM: **1 GB** (board `a03141`,
   bootloader 2023-01-11, seen on the boot screen 2026-10-28).
2. Whether the case presents anything on HDMI-A-1 when **undocked** (Recalbox's detection
   also reads an EDID). Check on the hardware at the first boot.

## Proposed order

1. `gpicase2` board layer and defconfig (a copy of `rpi4` + the stage 1 table), first build
   (~1 hour, as the Pi 4's: same packages, its own work directory).
2. First boot docked: HDMI menu, a pad in the dock, USB Ethernet + SSH, the power switch (clean
   off) and the latch (the case really turns off). Then the game tests.
3. Stage 2: the LCD (test pattern), then the launcher/RetroArch at 640×480 with the screen
   chosen at boot, then the USB sound card, then the built-in pad.
