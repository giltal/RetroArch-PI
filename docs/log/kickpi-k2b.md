# Development Log — K2B_RetroArch

Newest entries at the bottom. Record the wrong turns as well as the fixes;
the reference projects' logs showed they are often the more useful half.

The full history of everything above the board layer (kernel patches, Mesa,
RetroArch settings, cores, shaders, launcher, boot time) is in the reference's
log: `C:\OrangePI_Projects\RetroOPI_Z3\DevelopmentLog.md`.

---

## 2026-10-07 — Session 0: seeded from RetroOPI_Z3

The tree is RetroOPI_Z3 at commit `2db6a9f`, exported with `git archive`. The changes from it:

- **Paths retargeted.**
  - `board/opi-zero3` → `board/kickpi-k2b`.
  - `opi_zero3_retro_defconfig` → `kickpi_k2b_retro_defconfig`.
  - `~/opi` → `~/k2b`.
  - `/mnt/c/OrangePI_Projects/RetroOPI_Z3` → `/mnt/c/KickPI_Projects/K2B_RetroArch`.
  - The DTB name in `extlinux.conf` and `board.sh`.
  - Package and binary names stay `retroopi`.
- **Defconfig:** the kernel DTS is now `allwinner/sun50i-h618-kickpi-k2b`, and the issue string is
  `K2B_RetroArch`. The U-Boot defconfig is **still `orangepi_zero3`**, as a placeholder.
- **Kernel patch 0060** adds Armbian's `sun50i-h618-kickpi-k2b.dts` unmodified, taken from
  `~/opi/armbian-build` (`2843c11`, `sunxi-6.18/dt_64/`).
  - The first compile test failed. dtc couldn't resolve `uart2_ph_pins`, `uart5_pins` or
    `spi1_cs1_pin`. They come from Armbian's own h616.dtsi additions, which we don't vendor.
  - **Patch 0061** drops those three nodes. All three are `disabled` and unused.
  - Both patches dry-run apply in order, and the result compiles with the patched 6.18.53
    tree's dtc (39,610-byte DTB).

What the DTS shows about the board:
- **Same as the Zero3:**
  - The PMIC is an AXP313A.
  - The CPU rail (dcdc2) runs 810–1100 mV and the GPU rail (dcdc1) 810–990 mV, the same limits
    the Zero3's 0050/0051 were designed within.
- **Different:**
  - The DRAM rail is **1.5 V (DDR3)**, where the Zero3 is LPDDR4.
  - Ethernet uses an RTL8211F PHY.
  - The K2B adds eMMC and a power button on PC2.
- **The DRAM type is the first-boot risk:** the Zero3's U-Boot config will most likely fail DRAM
  init. Armbian's K2B U-Boot config and patches are the fix. Our Armbian checkout is blob-less,
  so they need a fetch, which waits for the user's OK.

Nothing has been built or booted yet. The next step is plan item 1 in `Context.md`.

---

## 2026-10-14 — Session 1: K2B U-Boot, DRAM rail, mmc aliases, first build

**The DRAM is LPDDR4, not DDR3.** Armbian's K2B U-Boot files are now in a separate sparse,
blob-less clone at `~/k2b/armbian-build` (same commit `2843c11`; `~/opi` untouched). At this
commit `patch/u-boot/v2026.01/board_kickpik2b/` is empty. Everything is in
`board_bananapim4zero/002-Add-board-KickPi-K2B.patch`:
- `kickpi_k2b_defconfig`: `SUNXI_DRAM_H616_LPDDR4`, `DRAM_CLK=792`.
  - Same as the Zero3: ODT/DRI/TPR10.
  - Different: TPR6 `0x48808080`, TPR11 `0x26262524`, TPR12 `0x100f100f`, and
    **`AXP_DCDC3_VOLT=1360`**.
  - `MMC_SUNXI_SLOT_EXTRA=2` adds the eMMC.
- The board DTS, under `dts/upstream`.

Session 0's "1.5 V rail ⇒ DDR3" came from the kernel DTS's dcdc3 value alone, and was wrong.
U-Boot 2026.07 has no K2B board upstream.

- **`patches/uboot/0001-board-add-kickpi-k2b.patch`**: Armbian's patch, unchanged. It applies
  cleanly to 2026.07. The defconfig now uses `BR2_TARGET_UBOOT_BOARD_DEFCONFIG="kickpi_k2b"`.
  - Compile-tested outside Buildroot (`kickpi_k2b_defconfig` + `uboot-fastboot.config`, using the
    reference's toolchain and BL31): `u-boot-sunxi-with-spl.bin` builds, and every DRAM symbol
    is in `.config`.
- **Kernel 0062: dcdc3 pinned to 1.36 V.** Armbian's kernel DTS pins dcdc3 at 1.5 V
  (min == max), so the regulator core would move the DRAM rail of a running,
  already-trained LPDDR4 from SPL's 1.36 V to 1.5 V, which is the LPDDR4 absolute maximum.
  Armbian ships with this mismatch. We match U-Boot instead.
  - **Still unverified:** whether dcdc3 really feeds the DRAM VDD2 (1.36 V is high for LPDDR4).
    Measure it, or read `/sys/class/regulator`, on the board.
- **Kernel 0063: mmc0/1/2 aliases.** The K2B enables SD, SDIO and eMMC. Without aliases the SD
  card isn't guaranteed to be `mmcblk0`, and `root=/dev/mmcblk0p1` and the `/opt/roms` fstab
  line rely on it. This is the same SD/SDIO race the reference board had.
  - 0060–0063 apply in order and compile with the patched 6.18.53 tree's dtc (checked by
    decompiling the DTB: dcdc3 `0x14c080`, three mmc aliases).
- **Kernel fragment:**
  - `KEYBOARD_GPIO_POLLED=y`: the PC2 power key. The arm64 defconfig has it as `=m`, and as a
    module the input device could appear after volumed starts.
  - `REALTEK_PHY=y`, made explicit (RTL8211F).
- Comments in `extlinux.conf` and `fstab` updated for the aliases.
- **Side finding:** Armbian's board config installs the **AIC8800** SDIO driver for the K2B
  (`AIC8800_TYPE="sdio"`). The "AW859A" is likely an AIC8800 under another name, and an
  out-of-tree driver for that does exist. This affects optional plan item 7.

The defconfig re-applied with 0 lines lost. **First full build started.**

**Build #1 failed after 127 min** in `libretro-atari800`'s patch step ("Hunk #1 FAILED ...
different line endings"). By then the kernel and `sun50i-h618-kickpi-k2b.dtb` had built, with
0060–0063 applied.

**Cause: three core patches need CRLF hunks.** Their target files are CRLF upstream:
- atari800 0001
- fbalpha 0001
- mame2010 0001

RetroOPI_Z3's **index** holds them as LF (`eol=lf`). Only its working copy has the CRLF bytes
(`git ls-files --eol`: `i/lf w/mixed`), so the reference builds from its working tree but a
fresh clone of it would fail too. `git archive` gave us the LF versions.

- **Fix:** copied the three files' bytes from the reference working tree, and marked them `-text`
  in `.gitattributes` so git can never normalise them again.
- Then `libretro-atari800-dirclean` and the build resumed.

**Resume #1 failed in under a minute: host-libopenssl re-extracted over its patched tree.**
- Its `.stamp_downloaded` (19:40:23) was newer than its `.stamp_patched` (19:40:22), so make
  re-ran extract and patch, and the patch then hit "duplicate filename".
- The cause is not understood. A scan of all 144 packages found no other out-of-order stamps.
- Fixed with `host-libopenssl-dirclean`. If it recurs, look at what touches the download stamp.

**Resume #2 built every package (10 min: LLVM, Mesa and the cores were already done) and
then failed in `post-build.sh`:** "boot/Image.lz4 is not an LZ4 frame".
- The script is `#!/bin/sh`, which is dash in WSL. In dash, `[ a -nt b ]` is **false** when b
  doesn't exist (bash says true). So a fresh build never creates `Image.lz4`.
- RetroOPI_Z3 has the same bug but never sees it, because its output tree has had an
  `Image.lz4` since that code was written. Like the CRLF patches above, the bug only shows on
  a fresh tree.
- **Fix:** an explicit `[ ! -f Image.lz4 ] ||`.

**Resume #3 failed the same way as openssl, this time in RetroArch.** All three of its stamps
came from one run, but `.stamp_patched` (22:51:17.86) was older than `.stamp_downloaded` and
`.stamp_extracted`, which no single make run can produce.

- **Root cause: the WSL clock was stepping backwards.**
  - `systemd-timesyncd` (NTP) was active while Hyper-V's TimeSync IC kept the clock too.
  - The journal showed `systemd-resolved: Clock change detected` about every 30 s, including at
    22:51:17.
  - Make compares mtimes, so a backward step makes a finished step look stale: the package is
    re-extracted over its patched tree, and the patch fails with "duplicate filename". That
    explains the openssl failure too.
- **Fix:** the user disabled timesyncd (`systemctl disable --now systemd-timesyncd`), leaving
  Hyper-V's sync as the only clock source. That gave 0 clock changes in the next 3 min.
  - A stamp scan found only RetroArch out of order. Ran `retroarch-dirclean` and resumed.
  - The rule is now in CLAUDE.md.

**Build #1 complete** (23:33). `firmware/sdcard.img.xz` is 164 MB. md5 of the raw image is
`a09b462a89c45a53d7b748326a7bc47e`; it is 29 GB apparent, 632 MB on disk.

Checked in the output:
- **U-Boot:** the image holds `u-boot-sunxi-with-spl.bin` at 8 KB, and its `.config` has the
  K2B DT, LPDDR4 at 792 MHz and DCDC3 at 1360.
- **target/boot:** `Image`, `Image.lz4` (a valid frame) and the K2B DTB.
  - The DTB has model "KickPi K2B", the three mmc aliases, and dcdc3 at 1.36 V.
- **Kernel config:** `REALTEK_PHY`, `KEYBOARD_GPIO_POLLED` and `DRM_PANFROST` are all `=y`.
- **Rootfs:** RetroArch plus 23 libretro `.so` files; `/etc/issue` is `K2B_RetroArch`.

**Next:** first boot on the serial console (plan item 3).

**Small image** (the user flashes this one, as on the Zero3): `RETROOPI_ROMS_SIZE_MB=2048
IMAGE_TAG=small` gives `firmware/sdcard-small.img` (3.2 GB raw, md5 `ac21766e…`) and `.img.xz`
(160 MB). The ROM partition is 2 GB FAT32 and is last on the card, so it can be grown after
flashing. `~/k2b/output/images/sdcard.img` is now this small variant; the 32 GB `.xz` in
`firmware/` is unchanged.

**Correction: the RAM is DDR3(L), not LPDDR4.** The user read the chips: two **Samsung
K4B4G0846E-BYK0**.
- `K4B` = DDR3, `4G` = 4 Gbit, `08` = x8. So 2 × 512 MB = **1 GB on a 16-bit bus**.
- `BYK0`: `Y` should mean the 1.35 V DDR3L grade (dual-voltage, so 1.5 V is in spec too), `K0` =
  DDR3-1600. Not checked against Samsung's decoder.
- Armbian's LPDDR4 config would have stopped at SPL DRAM init on this board. That is probably
  the "dram setup not supported" report from the Armbian forum.

This also explains the odd voltages:
- 1.36 V (Armbian U-Boot) is a DDR3L voltage, and 1.5 V (DTS) is a DDR3 voltage.
- Upstream **transpeed-8k618-t** (H618 + AXP313A + DDR3) uses exactly `AXP_DCDC3_VOLT=1360`.

Changes:
- **`patches/uboot/0002-kickpi-k2b-ddr3.patch`**, on top of Armbian's 0001 so provenance stays
  readable:
  - `SUNXI_DRAM_H616_DDR3_1333`, `DRAM_CLK=648`.
  - DX_ODT, CA_DRI, TPR0/6/10/11/12 taken from transpeed-8k618-t.
  - ODT_EN left at its default.
  - **DCDC3 1500 mV**: in spec whether the chips are DDR3L or plain DDR3, and equal to the
    DTS's `vdd-dram`.
- **Kernel 0062 removed**, since the kernel no longer needs to hold the rail at 1.36 V. 0063
  (mmc aliases) stays.
- Next: `uboot-dirclean linux-dirclean`, then rebuild both images.
- **If DRAM init still fails:**
  - first, yuzukihd-chameleon's TPR10/11/12 (H618 + AXP313 + DDR3, 1.5 V);
  - then `DRAM_CLK=600`.

**DDR3 images built** (2026-10-15 00:00). U-Boot `.config` contents:
- `SUNXI_DRAM_H616_DDR3_1333=y`, `DRAM_CLK=648`, `AXP_DCDC3_VOLT=1500`.
- DX_ODT `0x03030303`, CA_DRI `0x1f12`, ODT_EN `0x1` (the default).
- TPR0 `0xc0001002`, TPR6 `0x33808080`, TPR10 `0x2f1107`, TPR11 `0xddddcccc`,
  TPR12 `0xeddc7665`.

Kernel DTB: dcdc3 at 1.5 V and three mmc aliases. `Image.lz4` was regenerated after the kernel
rebuild, so the post-build fix works.
- `firmware/sdcard.img.xz` (md5 `be00ba94…`)
- `firmware/sdcard-small.img(.xz)` (md5 `1b8c2d02…`)

The earlier LPDDR4 images are superseded. **Next session:** flash `sdcard-small`, first boot on
the serial console.

---

## 2026-10-15 — Session 2: first boot, exFAT ROM partition

**First boot reached the launcher** on the DDR3 image: SPL, U-Boot, kernel, HDMI and GPU all
work. So the DDR3 parameters (transpeed-8k618-t's, 648 MHz, 1.5 V) train on this board.
**Ethernet does not work yet**; diagnostics have been requested from the serial console.

**The ROM partition is now exFAT** (user request).
- **post-image.sh** runs `mkfs.exfat -L RETROROMS` from Buildroot's `host-exfatprogs`, which
  replaces host-mtools in the defconfig. genimage now uses partition type 0x07.
- **Board side** was already in place from the reference: `EXFAT_FS=y`, the 0052 readahead
  fix, and fstab type `auto` with only options both drivers accept.
- **The partition is built empty.** mtools can't write exFAT and WSL can't loop-mount without
  root.
  - **S46card** now holds the full SYSTEMS list (25 systems, moved from post-image.sh) and
    creates any missing folder, plus `_system/states`, `_system/bios/dc` and `README.txt`
    (from `/usr/share/retroopi/card-README.txt`), on every boot, strictly additively.
  - **A freshly flashed card needs one boot** before ROMs are copied to it from a PC.
- **post-build.sh** now reads SYSTEMS from the target's S46card, still checked against the
  launcher binary, and fails if the list looks truncated.
- `fsck.exfat` was added on the target (`BR2_PACKAGE_EXFATPROGS`).
- Checked in the image:
  - p2 type 7, with `EXFAT` in its boot sector;
  - 0 defconfig lines lost.
- `sdcard-small.img` md5 `05619daa…`.

**First-boot diagnostics over the serial console** (COM8, driven from PowerShell; the user logged
in):

**ROM partition not mounted ("No such file or directory"): `/opt/roms` does not exist.**
- The reference ships it as an empty overlay directory, which git doesn't track, so `git
  archive` dropped it (and `rootfs_overlay/lib`, `var/lib`, which don't matter).
- The user's card itself is fine: their own 57 GB exFAT `RETRO_ROMS`, which the kernel can
  mount.
- **Fix:** post-build.sh now runs `mkdir -p $TARGET_DIR/opt/roms`. That's the third
  fresh-tree-only bug inherited from the reference, after the CRLF patches and the dash `-nt`.

**Ethernet: `dwmac-sun8i 5020000.ethernet: EMAC reset timeout`, probe -110, no eth0.**
- First theory: PI6 (PHY nRESET) still asserted, since our U-Boot has networking off. Wrote a
  0062 regulator patch for it.
- **Disproved on the board.** Sampling PI6 with devmem during a re-bind showed:
  - the driver pulses it low for 20 ms at probe start;
  - the PHY is out of reset about 210 ms before the EMAC reset times out.
  - 0062 dropped.
- **PI16** is mainline's EPHY_CLK (25 MHz out) and part of upstream `ext_rgmii_pins`. Armbian's
  K2B DTS uses it as the blue LED instead. Switching it to function 2 live didn't help either
  (LED restored afterwards).
- Pinmux otherwise OK: PI0-5 and PI7-15 = emac0, syscon `0x03000030` = `0x1E86` (RGMII).
- Still open: is the PHY powered or clocked at all? First ask: the port's link LEDs.
- Also seen: `mmc2: Failed to initialize a non-removable card`, so this K2B has no eMMC fitted;
  `udevadm settle failed` at boot.

**Ethernet solved: this board is a K2B V2.2 with a Maxio MAE0621A PHY, not an RTL8211F.**
- The user reported the port LEDs dark, even with PI6 held high, and the blue LED blinking
  (so PI16 really is the LED).
- Search found armbian/build **PR #10894** (Maxio MAE0621 PHY driver, tested on 6.18.53) and
  **PR #10902** (K2B V2.2 DDR3 board), both merged Oct 4–5. Fetched into
  `~/k2b/armbian-build` (main `15d778ee7`).
- A hand-driven MDIO read (CCU EMAC gate/reset on, then the EMAC MDIO registers via devmem)
  gave PHY ID `0x7B74/0x4411` = MAE0621A-Q2C at address 0, BMSR `0x7949`.

The mechanism:
- The generic PHY driver never writes the Maxio clock-mode register (page `0xd92` reg 2 =
  `0x200a`), so there's no RGMII RX clock and the EMAC reset in `sun8i_dwmac_probe()` times out.
- The Maxio driver's `probe()` writes that register during MDIO registration, which is before
  that reset.

**But it only binds if the PHY ID read succeeds:**
- The DT's PHY-node `reset-gpios` is released only after the ID read.
- Our U-Boot (networking off) leaves PI6 low, so the read fails and no PHY device is created.
- Armbian's U-Boot leaves PI6 high, which hides this there.

Live proof:
- Built `maxio.ko` out of tree against our 6.18.53 tree and sent it over the serial line
  (gzip+base64 heredoc, md5 matched).
- `insmod`, set PI6 high, re-bind: `MAE0621A-Q2C` bound, `Link is Up - 1Gbps/Full`, DHCP
  10.100.102.88.
- SSH key login works; written to `~/k2b/board_ip`.

Permanent fix:
- **Kernel 0062** = Armbian's Maxio patch, unmodified (sha256 `af8ccd5c…`), with
  `CONFIG_MAXIO_PHY=y` in the fragment.
- **Kernel 0064** moves PI6 to the `&mdio0` bus reset (`reset-delay-us` 20 ms,
  `reset-post-delay-us` 100 ms), which is released before the scan.
- **U-Boot 0002**: now also has `ODT_EN=0x0` and `TPR1=0x30fb`, as in Armbian's
  `kickpi_k2b_v2_defconfig` (cross-checked there against the vendor SPL). Untested here until
  U-Boot is next written to a card.

Other changes:
- `/opt/roms` created on the running board. The user's 57 GB exFAT card mounts there (nes, gb,
  atari800, _system).
- The image-build failure ("wanted CONFIG_MAXIO_PHY=y") was a race: the fragment was edited
  mid-build. Clean `linux-dirclean` rebuild started.
- `scripts/serial.ps1`: a minimal serial terminal (Ctrl+] also matches raw 0x1D).
  - Closing its Terminal tab left the process holding COM8; it had to be stopped by PID.

**The bus-level PHY reset (first 0064) did not work at boot.**
- New kernel installed with `board.sh kernel`, rebooted. No network.
- Serial log: still "EMAC reset timeout", and no Maxio probe line, so the PHY ID read failed.
- PI6 sampling showed the bus reset releasing at probe start and the scan about 100 ms
  later. **The MAE0621A doesn't answer an ID read 100 ms after a reset pulse.** The run that
  worked had the PHY out of reset for minutes before the read.

**Final 0064: PI6 as a `gpio-hog` (output high) in `&pio`, no `reset-gpios` anywhere.**
- The PHY leaves reset when the pin controller registers, about 0.8 s before the EMAC probe,
  and is never pulsed.
- The test DTB went over the serial line (gzip+base64, md5 checked), with the old one kept
  as `.dtb.busreset`.
- **Reboot: the network came up on its own.**
  - Maxio probe at 0.93 s, link 1 Gbps/Full at 6.2 s, same MAC and IP (10.100.102.88).
  - `gpio-262 emac0-phy-nreset out hi`.
  - 1472-byte pings: 0% loss.
  - ROM card mounted; S46card added `psp`/`dreamcast`.
- Tested on a **warm** reboot only. A cold power-on test is still to do.

Also from this boot:
- **U-Boot says `DRAM: 2048 MiB`.** The board has 2 GB, so presumably two more K4B4G0846E on
  the back. The "1 GB, 16-bit bus" in the earlier entry was wrong.
- U-Boot prints `Net: eth0: ethernet@5020000`: its sun8i EMAC driver still probes with
  CMD_NET off, which is probably what leaves PI6 as a low output.
- `udevadm settle failed` still appears at every boot. Not investigated yet.

**Final kernel installed and verified** (clean `linux-dirclean` build with 0062 + final 0064).
- The built DTB has the hog and no `reset-gpios`/delay properties.
- `board.sh kernel`: Image md5 `69983d69…` is the same on host and board. Rebooted; SSH back
  after about 18 s.
- Maxio probe at 1.74 s, link 1 Gbps at 6.9 s, 10.100.102.88, ROM card mounted, launcher
  running.
- Images: `sdcard-small.img` md5 `63167aa8…`, plus the full `sdcard.img.xz`. Both carry this
  kernel and U-Boot with Armbian's V2 DDR3 values (ODT_EN 0, TPR1 0x30fb), which have **not
  booted yet**: the board still runs the SPL from the first DDR3 image.

The board's rootfs is still the first DDR3 image's, so it lacks the newer rootfs changes:
- S46card's full folder list and README,
- `/opt/roms` (created by hand),
- `fsck.exfat`.
The user's ROM card is p2 of that card, so a reflash is not an option. Those parts need a
push, or a second card.

Open: a cold power-on test, and `udevadm settle failed`.

**Rootfs brought up to date over SSH (no reflash; the user's ROMs are on p2).**
- Checksummed all 748 files of `target/` against the board, excluding boot, modules and
  runtime trees.
- **Pushed with `board.sh push`** (atomic rename, md5 verified): `/etc/fstab`, `S46card`,
  `card-README.txt`, and the 6 exfatprogs tools.
- **Not pushed, on purpose:**
  - `/etc/udev/hwdb.d/*` and `/THIS_IS_NOT_YOUR_ROOT_FILESYSTEM`: Buildroot removes them at
    rootfs creation.
  - `/etc/passwd`, `/etc/group`, `/etc/shadow`: `target/` lacks the dbus/input/kvm/sgx
    entries that are added at image time. The board's copies are the correct ones; pushing
    `target/`'s would break D-Bus and Bluetooth.
- Ran S46card once: it added 20 system folders and `README.txt` to the user's card, and
  changed nothing existing.
- `fsck.exfat` is present.
- The board now matches a fresh image except for U-Boot (still the first DDR3 SPL).

**Cold power-on verified** (the user power-cycled): Maxio probe at 0.94 s, link 1 Gbps at
6.1 s, ROM card mounted, SSH reachable. Ethernet is done.

**U-Boot with Armbian's V2.2 DDR3 values written over SSH, and verified.**
- **Precheck:** p1 starts at sector 2048 (1 MiB), and the 729,793-byte image fits at 8 KB.
- **Backed up the old 8 KB–1 MiB region first:** `/root/uboot-backup-8k.bin` on the board,
  `~/k2b/uboot-backup-8k.bin`, and `firmware/uboot-backup-8k.bin` (md5 `8e40fc5c…`).
  - To restore from a PC: write it at offset 8 KB, e.g.
    `dd if=uboot-backup-8k.bin of=/dev/sdX bs=1024 seek=8`.
- **Write:** `dd ... bs=1024 seek=8 conv=fsync`; the read-back md5 matched (`36b2082b…`).
- **Reboot (serial captured):** `U-Boot SPL 2026.07 (Oct 15 2026 - 17:16:46)`, `DRAM: 2048 MiB`,
  through to login. Link 1 Gbps.
- **Quick RAM check:** 800 MB of urandom in /dev/shm, md5 three times, all identical.
  - That is a consistency check, not a stress test. The reference's 10-minute stress run is
    still to do with the clock work.
- The board now matches the current images completely.

**`udevadm settle failed` at boot is expected; nothing to fix.**
- It comes from `rootfs_overlay/etc/default/udevd`: `SETTLE_TIMEOUT=0`, the reference's
  boot-time decision ("don't wait for udev to settle", worth about 0.3 s to the launcher
  start).
- S10udevd no longer waits for the coldplug queue, so `settle` reports failure while udev
  keeps working in the background.
- On the K2B the queue drains a moment later (`udevadm settle --timeout=3` → rc 0 right after
  boot), and everything behind S10 comes up: sound card + Master, launcher, gamepad.

**HDMI audio works on the K2B** (user-verified; AHUB path from the reference, no changes).

**Power button (PC2, plan item 5).**
- The input device exists: `gpio-keys-polled` = event0, KEY_POWER in its bitmap.
- But **volumed only opened `axp20x-pek`** (the A33 reference's PMIC key), so nothing
  listened to it.
- **`tools/volumed.c` now also opens `gpio-keys-polled`** (same KEY_POWER → sync →
  `poweroff`).
- Rebuilt retroopi-tools, pushed `/usr/bin/volumed`, restarted. It holds
  `/dev/input/event0`.
- Waiting on the user to press the button. Expect a halt with power left on: the AXP313A is
  not `system-power-controller` in the DT (as on the Zero3), and PC2 is not the PMIC's
  PWRON, so pressing it again probably won't power the board up.
- **Power button verified.** The user identified the **inner** button as power. Pressing it
  ran a clean shutdown: breadcrumb `KEY_POWER seen at uptime 4193.26`, and the next boot's
  ext4 mount needed **no journal recovery**.
  - The board ends up fully off.
  - **The button cannot power it back on**: PC2 is a GPIO only Linux reads, not the AXP313A's
    PWRON. Power-on is by replugging. That is a hardware limit.
  - The outer button's role is still unconfirmed (reset, or FEL?).
- My first two button-capture scripts were broken: BusyBox grep has no `--line-buffered`, and
  backgrounded `evtest` exited at once over SSH. Not needed in the end; the press itself
  answered it.
- The **outer** button doesn't power the board on either; probably reset or FEL. Power-on is
  by replugging only.
- Possible later: a "soft off". The power key would sync and reboot into a U-Boot that blanks
  HDMI and polls PC2, then boots on a press. That would give the button on/off at the cost of
  idle power while "off". Not done; the user's call.

### Boot time: 0.41 s off launcher start

The user's stopwatch said 7–8 s (Zero3 ~6 s). Measured with `sertime.ps1`, which reboots
over SSH and timestamps each serial line on the host, relative to the SPL banner:

| Stage | Time |
|---|---|
| SPL → BL31 (load u-boot.itb) | 0.61 s |
| U-Boot → extlinux | 0.20 s |
| read Image.lz4 | 0.82 s |
| LZ4 unpack | 0.90 s |
| **"Moving Image 0x40080000 → 0x40200000"** | **0.30 s** |
| kernel entry → launcher start | 2.48 s |
| Launcher start (from SPL banner) | 5.64 s |

Kernel side:
- `Run /sbin/init` at **1.23 s** (Zero3: 0.88 s).
- The Maxio probe's `msleep(100)` blocked about 108 ms, and the SD controller probes after
  the EMAC, so the rootfs card appeared late (1.13 s).

Fixes:
- **`uboot/0003`**: arm64 `KERNEL_ADDR_R` moves from DRAM + 512 KiB to DRAM + 2 MiB.
  - booti wants the Image 2 MiB aligned; with this it unpacks in place, with no 44.7 MB move.
  - The unpacked Image ends about 0x42f60000, below `kernel_comp_addr_r` 0x44000000.
  - This applies to the Zero3's U-Boot as well.
- **`driver_async_probe=dwmac-sun8i`** in both extlinux labels: the EMAC/PHY probe no longer
  holds up the SD probe. Nothing at boot waits for eth0.
- U-Boot written over SSH (old one backed up as `/root/uboot-backup-8k-v2.bin`), and
  extlinux.conf pushed.

Results:

| Marker | Before | After |
|---|---|---|
| Starting kernel | 3.16 s | 2.88 s |
| SD card found | 1.13 s | 1.01 s |
| `Run /sbin/init` | 1.23 s | 1.12 s |
| Launcher start | 5.64 s | **5.23 s** |

Ethernet still links at 1 Gbps, the ROM card mounts, and launcher "ready in" is 783 ms.

Left before the kernel: SPL loading U-Boot 0.6 s, the Image read 0.8 s and the LZ4 unpack
0.9 s. Kernel init is still about 0.24 s behind the Zero3.

**eMMC removed (user decision: not fitted on our board, not supported).**
- **Kernel:**
  - **0065** disables `&mmc2`.
  - **0063** now adds only the `mmc0`/`mmc1` aliases.
- **U-Boot `0002`:**
  - `MMC_SUNXI_SLOT_EXTRA` dropped (now -1) and `SUPPORT_EMMC_BOOT` dropped.
  - `mmc2` disabled in U-Boot's DTS.
- Comments in extlinux.conf and fstab updated; Context.md and the patch README too.
- Installed over SSH: `board.sh kernel`, pushed fstab, wrote U-Boot (read-back md5 matched).
- Reboot:
  - U-Boot lists only `mmc@4020000: 0, mmc@4021000: 1`.
  - No `mmc2` error.
  - SD at 1.00 s, init at 1.11 s, link 1 Gbps, ROM card mounted.
- **Side benefit: SPL → U-Boot proper 0.92 → 0.73 s**, presumably because the SPL no longer
  inits the eMMC slot.

| Marker | Before | After |
|---|---|---|
| Starting kernel | 2.88 s | 2.77 s |
| Launcher start | 5.23 s | **5.13 s** |

Over the day the launcher start went **5.64 → 5.13 s** from the SPL banner.
