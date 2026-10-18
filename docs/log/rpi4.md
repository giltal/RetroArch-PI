# Development Log — Raspberry Pi 4

Newest entries at the bottom. Record the wrong turns as well as the fixes.
Plan and decisions: `docs/boards/rpi4.md`.

---

## 2026-10-18 — Step 1: the skeleton

The board layer and defconfig, with the shared files made per family. Nothing is built yet.

**Kernel: `rpi-6.18.y` @ `2341883` (Linux 6.18.57).** Buildroot 2026.02 pins `rpi-6.12.y`
(6.12.61, with firmware `063bcab`, 2025-12-08). The Raspberry Pi kernel also has `rpi-6.18.y`.
That is the same 6.18 series as the H616 boards, so 6.18-specific patches and findings carry
over. The tarball's sha256 is in `board/bcm2711/patches/linux/linux.hash`, and Buildroot
checks it (`linux-source`: OK).

**DT overlays: prebuilt, from the firmware package** (Buildroot's tested path,
`RPI_FIRMWARE_INSTALL_DTB_OVERLAYS`, which also builds the base DTB with `-@`). The other
option was building them from the kernel tree, which would keep them in step with 6.18. Kept
in reserve in case an overlay from the 2025-12 firmware does not suit the 6.18 DTB.

**Mesa: `v3d` + `vc4`, no LLVM.** Only panfrost needs LLVM (its precompiled OpenCL C library).
That saves the LLVM/clang build and the 65 MB libLLVM on the target.

**New layers:**
- `board/bcm2711/`:
  - `linux-retrogaming.config`: vc4, v3d, the firmware/clock/cpufreq/thermal drivers, the SD
    slot, bcmgenet + BCM54213PE, VL805 xHCI on PCIe, all =y;
  - `post-build.sh`: checks the boot-partition files, `vc4-kms-v3d-pi4` with `cma-`,
    `kernel=`/`device_tree=` against the built files, a one-line `cmdline.txt`, and the fstab
    (p3 `/data`, p4 ROMs); creates `/data`;
  - `patches/linux/`: README and hash.
- `board/rpi4/`:
  - `config.txt`: 64-bit, `kernel=Image`, explicit DTB, no initramfs,
    `vc4-kms-v3d-pi4,cma-256`, `boot_delay=0`, `disable_splash`, no camera/display
    detection, `arm_boost`, `enable_uart`;
  - `cmdline.txt`: `root=/dev/mmcblk0p2`, `quiet loglevel=4`, serial0 + tty1;
  - `genimage.cfg`: 64 MiB FAT boot, 1 GiB rootfs, 64 MiB ext4 `/data` (`RETRODATA`, empty),
    exFAT ROMs, all 4 MiB aligned; 28,804 MiB in all, which fits a 32 GB card;
  - `rootfs_overlay/etc/fstab`: replaces the common one.
- `rpi4_retro_defconfig`: generated from the Zero3's by a script that replaces only the board
  blocks (each replacement must match exactly once). The option lines that differ:
  - CPU (`cortex_a72`), issue, layer paths;
  - the kernel (tarball, `bcm2711` defconfig, DTS, not installed into the rootfs);
  - the firmware instead of TF-A/U-Boot;
  - Mesa;
  - `host-mtools` instead of `host-uboot-tools`.

**Shared files made per family.** The H616 boards' results must not change:
- **Kernel fragment split:** `board/common/linux-retrogaming.config` holds the DRM/fbcon core,
  sound core, USB-Ethernet dongles, input, Bluetooth and filesystems. `board/h616/` keeps the
  Allwinner drivers. The H616 boards get the same 77 lines, and no symbol is in both files.
- **exFAT readahead patch:** `h616/patches/linux/0052` → `common/patches/linux/0001`. No
  Armbian patch touches `fs/exfat`, so the patched source is unchanged. It applies to the RPi
  kernel too (dry run).
- **genimage:** `common/genimage.cfg` → `h616/genimage.cfg` (the U-Boot blob at 8 KB is sunxi).
- **post-build:** the extlinux/LZ4/CMA checks moved, byte for byte, to `h616/post-build.sh`,
  which runs after the common one.
  - Changed in the common script: the ROM fstab line is found by mount point instead of as
    `mmcblk0p2`.
  - The kernel-fragment check also looks in `linux-custom/`. It used to skip quietly when the
    kernel `.config` was not found. That would have happened on the Pi, because a tarball
    kernel builds in `linux-custom`. Now it fails.
- **Checked:**
  - `rpi4` defconfig: 113 option lines, 0 lost in `.config`.
  - Zero3 and K2B re-applied: 127 lines each, 0 lost. Their `.config` changed only in the
    three expected lines (post-build list, genimage path, fragment list).
  - Common + h616 post-build run on the Zero3's existing `target/`: both pass, including the
    fragment check against its built kernel.
  - All scripts pass `sh -n`.
  - Not checked yet: a full H616 image build from the new layout. Expected to be identical; to
    confirm with the next Zero3/K2B build.

**Scripts:**
- `boards.sh` has `rpi4` (`~/rpi4`) and a new `BOARD_BOOT` (extlinux | rpi).
- `board.sh kernel` refuses `rpi` for now. The Pi's kernel goes to the FAT p1, which is a
  different install; it gets written with the first boot.

**Not done in this step, by plan:**
- S11alsa's HDMI card detection on vc4 (step 3);
- the read-only root (step 4);
- `board.sh kernel` for the Pi.

## 2026-10-18 — Step 2: first build, OK in 57 min

`build.sh rpi4` worked on the first try in **57 min** (the Zero3 took 116 min with LLVM/clang).
Nothing needed fixing.
- **Config:**
  - defconfig: 113 option lines, 0 lost.
  - Both post-build scripts passed: common, including every kernel-fragment line against
    `linux-custom/.config`, and bcm2711.
  - Kernel `6.18.57-v8`: vc4, v3d, SND, bcmgenet, xHCI-PCI, exFAT, BT and HID_SONY all =y.
  - The shared exFAT patch was applied.
- **Image** (`firmware/rpi4/sdcard.img.xz`, 91 MB; md5 `15c4b2b3…`):
  - p1 FAT32 64 MiB at 4 MiB;
  - p2 ext4 1 GiB;
  - p3 ext4 64 MiB (`RETRODATA`, journal, empty);
  - p4 exFAT 27 GiB.
  - Total 28,804 MiB, as planned.
- **Boot partition:**
  - `start4.elf`, `fixup4.dat`, `config.txt` and `cmdline.txt` as written;
  - `bcm2711-rpi-4-b.dtb`;
  - `Image`, 28.9 MB (the arm64 Image on the H616 boards is 44.7 MB);
  - `overlays/` with 358 overlays, `vc4-kms-v3d-pi4.dtbo` among them.
- **Rootfs:** 263 MB in `target/` (no libLLVM). Mesa 26.0.1 with `v3d_dri.so` and the
  `vc4_dri.so` display stub, so the common Mesa patch 0001 works for vc4 too. All 23 cores.
- **For later:**
  - **1,861 kernel modules**: `bcm2711_defconfig` builds nearly everything as a module.
    That costs udev work at boot and rootfs space. A candidate for the boot-time pass
    (step 5).
  - **HDMI audio:** `S11alsa` will pick `vc4hdmi0` (HDMI0), which is right. But vc4's HDMI
    PCM takes only `IEC958_SUBFRAME_LE`, so a softvol slave of plain `hw:N,0` will most likely
    refuse the stream. Expected fix: slave `hdmi:CARD=vc4hdmi0,DEV=0` (alsa-lib's
    `vc4-hdmi.conf` wraps the iec958 plugin). To verify at the first boot, not guessed now.
  - `board.sh kernel` for the Pi (the FAT p1) is still to write.
