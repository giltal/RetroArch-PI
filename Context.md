# Context — RetroArch-PI

One Buildroot tree that builds a retro gaming console image for several ARM boards. The
userspace (launcher, RetroArch, 21 cores, init scripts, tools, DS3 Bluetooth, volume and clean
shutdown) is identical on every board; only the board layer differs.

Per-board hardware notes, differences and plans: `docs/boards/<board>.md`.
Per-board history: `docs/log/<board>.md`. Shared work from the merge on: `DevelopmentLog.md`.

## Boards

| | Orange Pi Zero3 | KickPi K2B V2.2 |
|---|---|---|
| SoC / GPU | H618, Mali-G31 MP2 (panfrost) | same |
| RAM | 2 GB LPDDR4 | 2 GB DDR3(L), Samsung K4B4G0846E |
| U-Boot | upstream `orangepi_zero3` | Armbian's `kickpi_k2b` + our DDR3 patch (648 MHz, 1.5 V) |
| Ethernet PHY | Motorcomm YT8531 | Maxio MAE0621A (Armbian driver; PI6 nRESET hogged high) |
| HDMI | micro | full-size |
| Power button | none (power off from the launcher) | GPIO PC2: clean shutdown; cannot power on |
| eMMC | none | optional; not fitted on ours; not supported |
| CPU/GPU clocks | 1512 MHz CPU, 600 MHz GPU (patches 0050/0051) | stock tables so far; port of 0050/0051 still to do |

## Layers

```
board/common  ->  board/h616  ->  board/<board>
(any board)       (H616/H618)     (DT, U-Boot board config, PHY, extlinux)
```

Each defconfig lists them in that order for overlays, global patch directories and kernel
fragments. See BUILDING.md, "How the boards share the tree".

## Plan

1. **K2B:** DS3 over a USB Bluetooth dongle; port 0050/0051 (GPU OPPs, CPU cooling + 1512 MHz)
   as K2B patches and re-verify with the 10-minute stress test and temperatures; optional
   "soft off" so the power button can also power on.
2. **Zero3:** rebuild from this tree and re-verify on the board. It now gets the shared fixes
   from the K2B port: exFAT ROM partition (built empty, folders created on first boot), the CRLF
   core patches, `/opt/roms`, the LZ4 kernel on a fresh tree, and U-Boot's 2 MiB-aligned
   `kernel_addr_r` (0.3 s faster boot).
3. **Raspberry Pi 4:** a new family layer (`board/bcm2711`): Raspberry Pi firmware boot instead
   of U-Boot, its kernel, Mesa V3D instead of panfrost. The shared layers should need no change
   beyond what the GPU driver choice forces (Mesa options, RetroArch video settings).
