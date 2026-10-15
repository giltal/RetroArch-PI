# RetroArch-PI

Retro gaming console firmware for small ARM boards, on **HDMI at 1080p**.
It boots straight into a custom DRM/KMS launcher; RetroArch runs on the GPU
with 21 emulator cores, from NES to PSP and Dreamcast.

Buildroot 2026.02.3 and mainline Linux 6.18.53. One source tree builds every
supported board: everything above the board layer (launcher, RetroArch, cores,
init scripts, tools) is shared, so a fix made for one board reaches all of them.

## Supported boards

| Board | SoC / GPU | RAM | Status |
|---|---|---|---|
| **Orange Pi Zero3** | Allwinner H618, 4× Cortex-A53, Mali-G31 MP2 | 2 GB LPDDR4 | **Working.** The reference board: every system and setting below was measured on it |
| **KickPi K2B V2.2** | Allwinner H618, 4× Cortex-A53, Mali-G31 MP2 | 2 GB DDR3 | **Working.** Boots to the launcher; HDMI video and audio, GPU, Gigabit Ethernet, ROM card, power button (clean shutdown). Same SoC as the Zero3, so the emulation results carry over. DualShock 3 over Bluetooth not yet re-tested |
| Raspberry Pi 4 | Broadcom BCM2711, V3D | | Planned |

**KickPi K2B: only the V2.2 is supported** (DDR3, Maxio MAE0621A Ethernet PHY).
The V1 (LPDDR4, RTL8211F) needs a different U-Boot DRAM setup. eMMC is not
supported; the K2B boots and runs from microSD.

## Setups

| | |
|---|---|
| **Display** | HDMI 1920×1080 (1280×720 as a build option). The launcher picks the matching TV mode and scales its layout to it |
| **Controller** | DualShock 3, wired, or over Bluetooth via a USB dongle (the boards' onboard Wi-Fi/BT has no mainline driver) |
| **Storage** | One microSD card: system partition plus an **exFAT ROM partition**, readable and writable from Windows. Boot the card once after flashing: the console creates a folder per system and a README on it |
| **Network** | Onboard Ethernet, for SSH access during development. Not needed to play |
| **Power** | Zero3: power off from the launcher's Settings. K2B: the inner button shuts down cleanly; power on by replugging |

## What it does

| | |
|---|---|
| **Systems** | NES, SNES, Game Boy / Color / Advance, Genesis, Master System, Game Gear, PC Engine, SuperGrafx, Atari 2600 / 7800 / 800 / 5200, ZX Spectrum, Neo Geo / CPS / arcade, Doom, PlayStation, Nintendo 64, **PSP** (PPSSPP), **Dreamcast** (Flycast) |
| **GPU** | Mali-G31 via Mesa panfrost, GLES 3.1. RetroArch `gl` driver on KMS/GBM |
| **Audio** | HDMI, with a software volume control the launcher and in-game hotkeys share |
| **Launcher** | Jump-to-letter, favourites, recents, save-state slots, search, themes. Full game titles for arcade (from the emulators' own game lists) and PSP (read from the disc). A tap of PS shows every control |

Measured on the H618 boards: NES, PlayStation and Nintendo 64 run smoothly; PSP
is playable, including heavy titles like Assassin's Creed Bloodlines (99% speed
with auto frameskip); Dreamcast runs Sonic Adventure 2 at roughly 85–90%,
limited by one CPU core rather than the GPU.

## Images

Ready-to-flash images and cover art are shared separately (not in this
repository): *link to follow*. Flash with Etcher or Rufus; see
[docs/flashing.md](docs/flashing.md). You supply your own ROMs and BIOS files.

## Why the kernel carries patches

Mainline Linux still has no HDMI for the H616/H618. The display engine driver
is there; the HDMI PHY, the TV timing controller and every display node are
not. Armbian carries Jernej Škrabec's refactor, which does all of that. Those
patches are vendored from Armbian unmodified, pinned to one commit. See
[`buildroot-external/board/h616/patches/linux/README.md`](buildroot-external/board/h616/patches/linux/README.md),
and each board's own `patches/README.md`.

## Building

See **[BUILDING.md](BUILDING.md)**. In short: WSL2 or Linux, ~30 GB of disk
per board, a few hours for the first build. LLVM is part of the build, because
Mesa's panfrost needs it.

```bash
scripts/build.sh zero3        # Orange Pi Zero3
scripts/build.sh k2b          # KickPi K2B V2.2
```

## Repository layout

```
buildroot-external/
  configs/              one defconfig per board
  package/              shared: RetroArch + cores, launcher, tools
  board/common/         shared: rootfs overlay, post-build/post-image, genimage
  board/h616/           shared by the Allwinner H616/H618 boards: kernel patches,
                        kernel and U-Boot fragments
  board/opi-zero3/      Zero3 only: DT patches, extlinux.conf, PHY driver
  board/kickpi-k2b/     K2B only: DT + PHY patches, U-Boot (DDR3), extlinux.conf
launcher/               the launcher (C, DRM/KMS + SDL2_ttf)
tools/                  volumed, inject-input, seed-credit, core-info
scripts/                build.sh / board.sh <board>, boards.sh (the board table)
docs/                   flashing, per-board notes, development logs
```

## Licence

GPL-2.0-or-later. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

Buildroot, Linux, U-Boot, TF-A, Mesa, RetroArch and the libretro cores are
fetched from their own upstreams at pinned revisions and remain under their
own licences. No ROMs or BIOS images are distributed here.
