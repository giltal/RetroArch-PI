# Board — KickPi K2B V2.2

> Ported from the Orange Pi Zero3 (same H618), seeded 2026-10-07 in its own tree
> (K2B_RetroArch) and merged into this tree on 2026-10-15.
> Build name: `k2b`. History: `docs/log/kickpi-k2b.md`.
> **Only the V2.2 is supported** (DDR3, Maxio MAE0621A). Armbian's `kickpi-k2b` DTS and
> U-Boot describe the V1 (LPDDR4, RTL8211F); Armbian added the V2.2 in PRs #10894/#10902.

---

## Hardware — KickPi K2B V2.2

Verified on our board unless noted. Sources: Armbian's device tree
(`sun50i-h618-kickpi-k2b.dts`, patch 0060) and the
[linux-sunxi page](https://linux-sunxi.org/Kickpi_K2B_H618).

| Item | Detail | vs. Zero3 |
|---|---|---|
| SoC | Allwinner **H618**, 4× Cortex-A53, **1512 MHz** (patch 0066) | same |
| GPU | **Mali-G31 MP2**, panfrost, **432/600 MHz** (patch 0066); `mali-supply` = dcdc1 | same |
| RAM | **DDR3(L), 2 GB**, Samsung K4B4G0846E. U-Boot: DDR3 at 648 MHz, DCDC3 1.5 V, Armbian's V2 values (`uboot/0002`: ODT_EN 0, TPR1 0x30fb) | Zero3: LPDDR4, a different SPL |
| PMIC | **AXP313A** on r_i2c @0x36: dcdc1 GPU, dcdc2 CPU (810–1100 mV), dcdc3 DRAM, aldo1 1.8 V, dldo1 3.3 V | same |
| Display | **full-size HDMI** | Zero3: micro-HDMI |
| Audio | HDMI audio via AHUB, verified. Analog codec → LINEOUT not tested | same |
| Network | Gigabit Ethernet over RGMII (emac0), **Maxio MAE0621A** PHY (ID `0x7b744411`). Kernel 0062 (Armbian's Maxio driver) and 0064 (PI6 nRESET hogged high). Without them: "EMAC reset timeout", no eth0 | Zero3: YT8531 |
| Wireless | Seekwave SWT6621S (per Armbian PR #10902), vendor-only driver. **Not enabled**: use a USB BT dongle | Zero3: UWE5622, same situation |
| Storage | microSD only (mmc0, card detect PF6). eMMC (mmc2) is optional on the K2B, **not fitted on ours, and not supported**: disabled in the kernel DT (0065) and U-Boot (`uboot/0002`) | same |
| USB | EHCI/OHCI 0–2, OTG as peripheral | similar |
| Buttons/LEDs | **Inner button = power key** on PC2 (gpio-keys-polled, KEY_POWER): volumed does a clean shutdown. It **cannot power on** (a GPIO, not the PMIC's PWRON); power-on is by replugging. The outer button doesn't power on either (reset or FEL?). Blue status LED on PI16, IR receiver (unused) | Zero3 has no power key |
| Cooling | **Heatsink fitted** (earlier notes said none; corrected by the user 2026-10-16). With it, the 10-minute stress test at 1512 MHz peaked at **78 °C**, still creeping up, just under the 80 °C passive trip. Games run 55–64 °C. **A fan is to be added** | Zero3: 60 °C |
| Debug UART | UART0 on PH pins, 115200 8N1, 3.3 V. COM8 on this PC (`scripts/serial.ps1`) | same |

## Board layer (`board/kickpi-k2b/`)

- **U-Boot:** Armbian's `kickpi_k2b` defconfig (`uboot/0001`), turned into DDR3 V2.2 with eMMC
  off (`uboot/0002`), plus the shared `board/h616` `kernel_addr_r` patch.
- **Kernel patches:**
  - 0060/0061: Armbian's K2B DTS in-tree, minus three disabled nodes whose pin groups we don't
    carry;
  - 0062: Maxio PHY driver (Armbian, unmodified);
  - 0063: `mmc0`/`mmc1` aliases;
  - 0064: PI6 PHY nRESET as a `gpio-hog`, output high;
  - 0065: `&mmc2` disabled;
  - 0066: CPU and GPU clocks (the Zero3's 0050 + 0051 on this DTS).
- `linux.config`: `MAXIO_PHY=y` and the other board-only options.
- `extlinux.conf`: `driver_async_probe=dwmac-sun8i,ehci-platform,ohci-platform`.

## Status (2026-10-16)

Runs this tree's build, verified on the board: DDR3 U-Boot, Ethernet at 1 Gbps (cold and warm
boot), HDMI video and audio, exFAT ROM card, SSH key login, power button, clocks. Init 1.11 s
with or without a USB DS3 attached; power-on to menu ~6 s by stopwatch. Release sweep at the new
clocks: same verdicts as at stock clocks.

## Open

1. **DS3 over a USB Bluetooth dongle.**
2. **Fan** (the heatsink alone reached 78 °C). Once it is fitted, re-run the 10-minute stress
   test (`scripts/cpu-stress.sh`). If the fan is GPIO- or PWM-controlled rather than always on,
   it needs a DT node (`gpio-fan`/`pwm-fan`) bound to the CPU thermal zone.
3. Optional **"soft off"**: the power key syncs and reboots into a U-Boot that blanks HDMI and
   polls PC2, then boots on a press. On/off from the button, at the cost of idle power while
   "off". The user's call.
4. `WARNING ... __request_module` at every boot, from `driver_async_probe=dwmac-sun8i`.
   Harmless (Maxio is built in). Options: drop the async probe and remove the Maxio driver's
   `msleep(100)`; a kernel patch that skips the request from async context; or leave it.
5. Re-measure boot time against the Zero3: kernel init is still about 0.24 s behind.
