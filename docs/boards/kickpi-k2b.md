# Context — K2B_RetroArch

> Port of **RetroOPI_Z3** (Orange Pi Zero3, Allwinner H618) to the **KickPi K2B** (also H618).
> Reference project: `C:\OrangePI_Projects\RetroOPI_Z3` (read-only)
> Seeded: 2026-10-07 from RetroOPI_Z3 commit `2db6a9f`

---

## Hardware — KickPi K2B

From Armbian's device tree (`sun50i-h618-kickpi-k2b.dts`, patch 0060) and the
[linux-sunxi page](https://linux-sunxi.org/Kickpi_K2B_H618). **Not yet verified on the board.**

| Item | Detail | vs. Zero3 |
|---|---|---|
| SoC | Allwinner **H618**, 4× Cortex-A53 | same |
| GPU | **Mali-G31 MP2**, panfrost; `mali-supply` = dcdc1 (810–990 mV) | same rail, same limits |
| Board revision | **Ours is the K2B V2.2.** Armbian's `kickpi-k2b` DTS and U-Boot describe the V1 (LPDDR4, RTL8211F). Armbian added the V2.2 in PRs #10894/#10902 | — |
| RAM | **DDR3(L), 2 GB** (U-Boot: `DRAM: 2048 MiB`): Samsung K4B4G0846E-BYK0 (4 Gbit x8) seen on the front, presumably more on the back. U-Boot: DDR3 at 648 MHz, DCDC3 1.5 V, Armbian's V2 values (`uboot/0002`) | **Zero3 is LPDDR4.** Different DRAM type, so a different SPL |
| PMIC | **AXP313A** on r_i2c @0x36: dcdc1 GPU, dcdc2 CPU (810–1100 mV), dcdc3 DRAM, aldo1 1.8 V, dldo1 3.3 V | **same chip, same CPU range** |
| Display | full-size HDMI (`type = "d"` in the DTS connector node, worth checking) | micro-HDMI on the Zero3 |
| Audio | HDMI audio via AHUB (`ahub1_*` nodes enabled), analog codec → LINEOUT | same driver stack |
| Network | Gigabit Ethernet over RGMII (emac0). **V2.2: Maxio MAE0621A** PHY (ID `0x7b744411`; kernel 0062 driver, 0064 hogs PI6 nRESET high). V1: RTL8211F | Zero3: YT8531 |
| Wireless | V1: AW859A/AIC8800 on SDIO + UART1. V2 (per Armbian PR #10902): Seekwave SWT6621S, vendor-only driver. Not enabled | Zero3: UWE5622. Same situation: USB BT dongle |
| Storage | microSD (mmc0, card detect PF6) only. eMMC (mmc2) is optional on the K2B, **not fitted on ours, and not supported**: disabled in the kernel DT (0065) and U-Boot (`uboot/0002`) | Zero3: SD only |
| USB | EHCI/OHCI 0–2, OTG as peripheral | similar |
| Buttons/LEDs | **power key** on PC2 (gpio-keys-polled, KEY_POWER), blue status LED PI16, IR receiver | Zero3 has no power key |
| Debug UART | UART0 on PH pins, 115200 8N1 | same |

## What was carried over, and what changed at seeding

- **Everything** from RetroOPI_Z3 HEAD (`git archive`), with paths retargeted:
  `board/opi-zero3` → `board/kickpi-k2b`, defconfig `kickpi_k2b_retro_defconfig`, WSL tree
  `~/opi` → `~/k2b`, project path, DTB name in `extlinux.conf` and `board.sh`.
- **Defconfig:** `BR2_LINUX_KERNEL_INTREE_DTS_NAME="allwinner/sun50i-h618-kickpi-k2b"`,
  `/etc/issue` = `K2B_RetroArch`. U-Boot was `orangepi_zero3` as a placeholder; Session 1 switched it to `kickpi_k2b`.
- **Kernel patches 0060/0061:** Armbian's K2B DTS added in-tree, minus three disabled nodes whose
  pin groups we don't carry. Compile-tested with the patched 6.18.53 tree's dtc: OK.
- **DevelopmentLog.md** restarted. The Zero3 history lives in the reference's log.
- **Not built yet.** No image exists for the K2B.

## Risks, in the order they'll bite

1. **DRAM / U-Boot.** `patches/uboot/0001` is Armbian's `kickpi_k2b_defconfig` (LPDDR4), and
   `0002` turns it into **DDR3** for the RAM actually on the board. It uses transpeed-8k618-t's
   parameters (H618 + AXP313A + DDR3, 648 MHz) with DCDC3 at 1.5 V. Still untested on hardware.
   - If SPL stops at DRAM init: try yuzukihd-chameleon's TPR10/11/12 (the same SoC/PMIC/DDR3
     combination), then `DRAM_CLK=600`.
   - **K2B batches differ:** Armbian's LPDDR4 config may be right for other boards, and one SPL
     cannot cover both RAM types.
2. **Armbian DTS against our tree.** It compiles, but it was written for Armbian's full kernel. At
   first boot, check the HDMI, AHUB audio, emac0/RTL8211F and mmc0 probes in `dmesg`.
3. ~~**SD-card boot order.**~~ Moot: no eMMC, and it is not supported.

## Plan

1. ~~**U-Boot for the K2B.**~~ Done (Session 1): `kickpi_k2b` defconfig via `patches/uboot/0001` + `0002` (DDR3).
2. **First full build** (`build.sh`), check every defconfig line in `.config`.
3. **First boot on serial.** SPL → BL31 → U-Boot → kernel → launcher on HDMI. Then Ethernet,
   SSH key login, HDMI audio, a USB BT dongle with the DS3.
4. **GPU and CPU clocks.** Port 0050 (GPU OPPs 432/600 MHz) and 0051 (CPU cooling binding +
   1512 MHz at 1.10 V for speed grades 0/2) to the K2B DTS as new patches. The rails match the
   Zero3's, but **re-verify** as the reference did: the 10-minute hashing stress test, and the
   temperatures. The K2B's cooling may differ.
5. **Power button.** The K2B has one (PC2, KEY_POWER). The reference's `volumed` already turns
   KEY_POWER into a clean shutdown, so check it works. This was dead code on the Zero3.
6. **Boot time.** Re-measure against the Zero3's ~6 s with a stopwatch.
7. **Optional:** branding; the onboard Wi-Fi/BT driver. (eMMC install: dropped, not supported.)
