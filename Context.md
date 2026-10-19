# Context — RetroArch-PI

One Buildroot tree that builds a retro gaming console image for several ARM boards. The
userspace (launcher, RetroArch, 21 cores, init scripts, tools, DS3 Bluetooth, volume and clean
shutdown) is identical on every board; only the board layer differs.

Per-board hardware notes, differences and plans: `docs/boards/<board>.md`.
Per-board history: `docs/log/<board>.md`. Shared work from the merge on: `DevelopmentLog.md`.

## Boards

| | Orange Pi Zero3 | KickPi K2B V2.2 | Raspberry Pi 4 |
|---|---|---|---|
| SoC / GPU | H618, Mali-G31 MP2 (panfrost) | same | BCM2711, 4x A72, V3D 4.2 (v3d + vc4) |
| RAM | 2 GB LPDDR4 | 2 GB DDR3(L), Samsung K4B4G0846E | 1 GB (ours) |
| Boot | U-Boot `orangepi_zero3`, extlinux | Armbian's `kickpi_k2b` + our DDR3 patch (648 MHz, 1.5 V) | VideoCore firmware, `config.txt`; EEPROM bootloader updated 2026-09 |
| Kernel | mainline 6.18.53 + Armbian | same | Raspberry Pi `rpi-6.18.y` (6.18.57) |
| Ethernet PHY | Motorcomm YT8531 | Maxio MAE0621A (Armbian driver; PI6 nRESET hogged high) | BCM54213PE (bcmgenet) |
| HDMI | micro | full-size | micro (HDMI0) |
| Power button | none (power off from the launcher) | GPIO PC2: clean shutdown; cannot power on | none yet (GPIO3 planned: off and on) |
| eMMC | none | optional; not fitted on ours; not supported | none |
| CPU/GPU clocks | 1512 MHz CPU, 600 MHz GPU (patches 0050/0051) | same, patch 0066 (peak 78 °C in the stress test with the heatsink; fan to be added) | 1800 MHz (`arm_boost`) |
| Power-on to menu | ~6 s | ~6 s | 9 s (~7 s of it firmware) |

## Layers

```
board/common  ->  board/h616     ->  board/opi-zero3, board/kickpi-k2b
(any board)       board/bcm2711  ->  board/rpi4
                  (family: kernel     (DT, boot config, PHY, extlinux or
                   fragment, boot      config.txt, genimage)
                   chain, genimage)
```

Each defconfig lists them in that order for overlays, global patch directories and kernel
fragments. See BUILDING.md, "How the boards share the tree".

## Plan

Shared work done since the merge (`DevelopmentLog.md`): save states work on every core and live
on the card with the in-game saves; nothing is written to the rootfs during play; quick start
from slot 10 (START); game tests with a virtual DualShock 3 (`scripts/game-test.sh`, 4 games);
GoldenEye/Perfect Dark and Conker fixed on the N64 dynarec (parallel-n64 0004/0005).

1. **Bring the Zero3 and K2B up to date** (in progress 2026-10-19): both last built before the
   per-family split and the shared work above. Rebuild, `scripts/sync-rootfs.sh` +
   `board.sh kernel`, then the game tests with `test-states/` copied to their cards.
2. **Raspberry Pi 4** (`docs/boards/rpi4.md`): release sweep; analog L2/R2 (triggers are
   digital in our PS3 autoconfig); onboard Bluetooth; GPIO3 power button. Parked: the ~7 s
   of firmware boot (needs the serial log), the rest of the read-only root.
3. **K2B** (`docs/boards/kickpi-k2b.md`): DS3 over a USB Bluetooth dongle; a fan, then the stress
   test again; optional "soft off"; the harmless `__request_module` warning.
4. **Zero3** (`docs/boards/opi-zero3.md`): mupen64plus-next, hardware PSX renderers, PicoDrive,
   onboard Wi-Fi/BT.
5. **Small:** ship complete core `.opt` files (each core writes its `.opt` once on a fresh
   card); the launcher's startup log names the Zero3 on every board.
