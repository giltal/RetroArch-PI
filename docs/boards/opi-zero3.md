# Board — Orange Pi Zero3

> The reference board of RetroArch-PI: almost every setting was measured on it.
> Ported from **RetroBPI_M2M** (Banana Pi M2 Magic, Allwinner A33, DSI panel), started
> 2026-09-23 as RetroOPI_Z3, merged into this tree on 2026-10-15.
> Build name: `zero3`. History: `docs/log/opi-zero3.md`.

---

## Hardware — Orange Pi Zero3 (2 GB)

| Item | Detail |
|---|---|
| SoC | Allwinner **H618**: 4× Cortex-A53. H616 family, `sun50i`. **1512 MHz** (patch 0051) |
| GPU | **Mali-G31 MP2** (Bifrost). Mesa **panfrost**, GLES 3.1. **432/600 MHz** (patch 0050) |
| RAM | 2 GB LPDDR4 |
| Display | **micro-HDMI** (DW-HDMI 2.0 behind the DE33 mixer and TCON-TV). No DSI |
| PMIC | AXP313a: dcdc1 → GPU (`mali-supply`), aldo1 → HDMI PHY (`hvcc-supply`) |
| Network | Gigabit Ethernet (Motorcomm YT8531 PHY). **Dev link** |
| Wireless | Unisoc **UWE5622** Wi-Fi + BT, needs an out-of-tree driver. **Not enabled** |
| USB | 1× USB-A host, USB-C (power + OTG), plus 2× USB 2.0 on the 13-pin header |
| Audio | HDMI audio (H616 audio hub), and analog LINEOUT on the 13-pin header |
| Storage | microSD only (SPI NOR on some SKUs, unused) |
| Power | 5 V via USB-C. **No power button**: power off from the launcher |
| Debug UART | 3-pin header, UART0 = `ttyS0`, 115200 8N1, 3.3 V |

## Board layer (`board/opi-zero3/`)

- U-Boot: upstream `orangepi_zero3`, plus the shared `board/h616` fragment and `kernel_addr_r`
  patch.
- Kernel patches 0046/0047 (DT), 0050 (GPU OPPs), 0051 (CPU cooling + 1512 MHz at 1.10 V).
- `linux.config`: board-only kernel options (e.g. `MOTORCOMM_PHY`).
- `extlinux.conf`: `driver_async_probe=ehci-platform,ohci-platform`.

## What differs from the A33 reference, and what we did about it

| Area | RetroBPI_M2M (A33) | Orange Pi Zero3 (H618) |
|---|---|---|
| Arch | ARMv7 hard-float | **AArch64**. Every core's platform detection re-audited |
| Kernel | mainline 6.18.8 + panel patches | mainline **6.18.53** + Armbian's patches for HDMI/audio/GPU (`board/h616`) |
| Display | DSI 800×480, mounted 180° | **HDMI 1920×1080**, no rotation (RetroArch patch 0007 dropped) |
| GPU | Mali-400 / lima, GLES 2.0 | **Mali-G31 / panfrost, GLES 3.1**. Mesa needs LLVM for it |
| Mode choice | panel's only mode | launcher **picks the mode matching SCREEN_W×H**. RetroArch uses `video_fullscreen_x/y` |
| Audio | A33 codec, analog 'Headphone' volume | HDMI via audio hub. **softvol 'Master'** in `/etc/asound.conf`, written by S11alsa |
| Vsync | off | **on** (RetroArch KMS drops frames with vsync off) |
| Boot | U-Boot SPL | U-Boot SPL + **TF-A BL31** (`lts-v2.12.9`) |
| Network | USB-Ethernet dongle | **onboard Ethernet** |
| Bluetooth | AP6212 (BCM43438) on UART | **USB dongle** (btusb as a module + Realtek firmware) |
| Power | AXP223 900 mA VBUS cap, `S05powercap` | not needed. `S05perf` keeps only the `performance` governor |
| Power button | axp20x-pek → volumed → clean poweroff | none on the Zero3. volumed's handler stays and is harmless |

## Display pipeline

```
DE33 mixer0 ──> TCON-TV0 ──> DW-HDMI (sun8i_dw_hdmi, H616 PHY)
  (sun8i-mixer, DE33 planes)          │
                                       └─ HDMI audio: AHUB I2S (sound/soc/sunxi_v2)
Mali-G31 (panfrost) — render only; Mesa kmsro scans out via sun4i-drm
```

The DRM nodes are panfrost (render-only, no connectors) and sun4i-drm (the display). Probe order
decides which one is `card0`. The launcher (`drm_open_kms()`) and RetroArch both pick the node that
has connectors, a lesson from the reference, where lima did the same.

## Status (2026-10-16)

Runs this tree's complete build (kernel, U-Boot, rootfs), verified on the board. Release sweep:
12 PASS, 1 WARN, 1 SKIP, 0 FAIL. Init 0.88 s; power-on to menu ~6 s by stopwatch.

Done: bring-up, measurement methods (vblank-counted fps, audio speed meter, xrun counts),
1080p output with `UI_SCALE`, PSP (PPSSPP v1.20.4) and Dreamcast (Flycast v2.7) on GLES3, N64
at 640x480, shaders, cover-art launcher, boot time (~14 s → ~6 s), CPU/GPU clocks with a
10-minute stress test (peak 60 °C).

## Open

1. mupen64plus-next against parallel-n64; hardware PSX renderers; PicoDrive for Sega CD / 32X.
2. Onboard Wi-Fi/BT via Armbian's uwe5622 extension, so no dongle is needed.
