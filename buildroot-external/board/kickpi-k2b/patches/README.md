# KickPi K2B patches

Applied after `board/common/patches` and `board/h616/patches` (the defconfig's
`BR2_GLOBAL_PATCH_DIR` order). Our board is the **K2B V2.2** (DDR3, Maxio
MAE0621A PHY); Armbian's `kickpi-k2b` DTS and U-Boot describe the V1.

## linux/

| Ours | What for |
|---|---|
| 0060 | Adds Armbian's `sun50i-h618-kickpi-k2b.dts` unmodified (armbian/build `2843c11`, `patch/kernel/archive/sunxi-6.18/dt_64/`) plus its Makefile line. Armbian copies `dt_64/` files into the tree at build time; we carry it as a patch. |
| 0061 | Drops the disabled `&spi1`, `&uart2` and `&uart5` nodes from it. Their pin groups (`spi1_cs1_pin`, `uart2_ph_pins`, `uart5_pins`) come from Armbian's own `sun50i-h616.dtsi` additions, which we don't carry, so dtc failed on the references. Compile-tested against the patched 6.18.53 tree. |
| 0062 | Armbian's `drv-net-phy-add-maxio-mae0621-phy-driver.patch` (armbian/build `15d778ee7`, `patch/kernel/archive/sunxi-6.18/patches.armbian/`, PR #10894), unmodified. The K2B V2.2 (DDR3) has a Maxio MAE0621A PHY, not the RTL8211F. Without its driver the PHY never drives the RGMII RX clock, and the EMAC probe fails with "EMAC reset timeout" (no eth0). Needs `CONFIG_MAXIO_PHY=y`. (The number was used twice before and dropped both times: a 1.36 V `vdd-dram` pin, then a PI6 PHY-reset regulator that on-board sampling disproved.) |
| 0063 | Adds `mmc0`/`mmc1` aliases. SD and SDIO are both enabled, so this keeps the SD card at `mmcblk0` (`root=` and the `/opt/roms` mount rely on it). |
| 0064 | Holds the MAE0621A out of reset from early boot: PI6 is a `gpio-hog` (output high) in `&pio`, and the PHY node's `reset-gpios` is removed. The PHY must answer its ID read for its driver (0062) to bind. With a PHY-node reset, PI6 is still low at the read (our U-Boot leaves it low). With a bus-level reset (tried), the scan runs 100 ms after the pulse and the PHY doesn't answer yet either. Both ended in "EMAC reset timeout". Verified on the board: Maxio probe at 0.93 s, link 1 Gbps at 6.2 s, 1472-byte pings with 0% loss. |
| 0065 | Disables `&mmc2` (eMMC). It is optional on the K2B, not fitted on our board, and not supported. Every boot logged "mmc2: Failed to initialize a non-removable card". |

## uboot/

| Ours | What for |
|---|---|
| 0001 | Armbian's `patch/u-boot/v2026.01/board_bananapim4zero/002-Add-board-KickPi-K2B.patch` (armbian/build `2843c11`, Patrick Yavitz), unchanged: `kickpi_k2b_defconfig` and the board DTS. Applies cleanly to U-Boot 2026.07. It configures the V1's LPDDR4. |
| 0002 | Turns that into the **V2.2: DDR3 at 648 MHz**, DCDC3 1.5 V, with the values of Armbian's `kickpi_k2b_v2_defconfig` (PR #10902, cross-checked there against the vendor SPL). Also drops eMMC (`MMC_SUNXI_SLOT_EXTRA`, `SUPPORT_EMMC_BOOT`, `mmc2` in the U-Boot DTS): not fitted on our board, not supported. |

The 2 MiB-aligned `kernel_addr_r` patch is shared by all H616 boards: `board/h616/patches/uboot/`.
