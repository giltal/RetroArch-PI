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
| CPU/GPU clocks | 1512 MHz CPU, 600 MHz GPU (patches 0050/0051) | same, patch 0066 (peak 78 °C in the stress test with the heatsink; fan to be added) |

## Layers

```
board/common  ->  board/h616  ->  board/<board>
(any board)       (H616/H618)     (DT, U-Boot board config, PHY, extlinux)
```

Each defconfig lists them in that order for overlays, global patch directories and kernel
fragments. See BUILDING.md, "How the boards share the tree".

## Plan

1. **K2B:** DS3 over a USB Bluetooth dongle; optional "soft off" so the power button can also
   power on; a fan (with the heatsink, the 1512 MHz stress test peaked at 78 °C, just under the
   80 °C trip), then re-run the stress test.
   Done: clocks ported as 0066 (1512 MHz CPU, 600 MHz GPU), stress-tested.
2. ~~**Zero3:** rebuild from this tree and re-verify on the board.~~ Done 2026-10-16: kernel,
   U-Boot and rootfs from this tree, release sweep 12 PASS / 0 FAIL, init 0.88 s. Still open
   there: mupen64plus-next, hardware PSX renderers, PicoDrive, onboard Wi-Fi/BT
   (`docs/boards/opi-zero3.md`).
3. **Raspberry Pi 4:** a new family layer (`board/bcm2711`): Raspberry Pi firmware boot instead
   of U-Boot, its kernel, Mesa V3D instead of panfrost. The shared layers should need no change
   beyond what the GPU driver choice forces (Mesa options, RetroArch video settings).
4. ~~**N64: GoldenEye 007 and Perfect Dark on the dynamic recompiler.**~~ Done 2026-10-16:
   the SIGTRAP was a stray `brk 0` in the ARM64 `fp_exception_ds`, not TLB handling.
   parallel-n64 0004 now removes it (the cached-interpreter workaround is gone). Both games run on
   the dynarec at 97–100%. Verified on the Zero3; on the K2B since 2026-10-16 (with 0005).
   Details: `docs/log/opi-zero3.md`.
5. ~~**N64: Conker's Bad Fur Day segfaults** on the dynarec about 25 s in.~~ Fixed 2026-10-16:
   `emit_andimm64` encoded its immediate inside an `assert()`, which `-DNDEBUG` compiles out, so
   SDL/SDR stored through a garbage-masked address. parallel-n64 0005 moves the encoding out of the
   `assert`. Conker alive past 75 s at ~100%; GoldenEye, Perfect Dark and Super Mario 64 still
   fine. Tested on the K2B (the Zero3 was off); installed and re-checked on
   both boards.
   Details: `docs/log/opi-zero3.md`.
