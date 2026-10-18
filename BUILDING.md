# Building RetroArch-PI

The repo holds sources, patches, configs and docs. It does **not** hold build
outputs: `firmware/` is gitignored. Expect to build.

## Host requirements

| | |
|---|---|
| OS | Linux, or Windows with WSL2 (developed on Ubuntu 22.04) |
| Disk | **~30 GB per board** for its build tree. LLVM and clang are part of it |
| RAM | 16 GB recommended. LLVM links are memory-hungry |
| Time | Several hours for a board's first build: toolchain, LLVM/clang, kernel, TF-A, U-Boot, Mesa, RetroArch, 21 cores |
| Network | Required on first build (~1.5 GB of sources, shared by all boards) |

Buildroot's prerequisites (Debian/Ubuntu):

```bash
sudo apt-get install -y build-essential git bc bison flex libssl-dev \
    libncurses-dev python3 python3-dev unzip rsync wget cpio file \
    gawk gettext texinfo help2man libtool-bin pkg-config
```

**WSL2:** keep only one time source. With `systemd-timesyncd` running alongside
Hyper-V's own time sync, the clock steps backwards every ~30 s, make sees
finished steps as stale, and packages get re-extracted over their patched
trees ("duplicate filename" patch errors). Disable it once:
`wsl -u root systemctl disable --now systemd-timesyncd`.

## Building

`scripts/build.sh <board>` does it all. The boards and their work directories
are listed in `scripts/boards.sh`. On first use it clones Buildroot 2026.02.3
into `<work>/buildroot` and builds out-of-tree into `<work>/output`:

```bash
bash scripts/build.sh k2b                 # full image
bash scripts/build.sh k2b defconfig       # (re)apply the defconfig only
bash scripts/build.sh k2b linux-rebuild   # one target
```

Or by hand:

```bash
cd ~/k2b/buildroot
BR2_DL_DIR=~/bpi/dl make BR2_EXTERNAL=/path/to/RetroArch-PI/buildroot-external \
    O=~/k2b/output kickpi_k2b_retro_defconfig
BR2_DL_DIR=~/bpi/dl make O=~/k2b/output
```

The result is `<work>/output/images/sdcard.img`, copied (xz) to
`firmware/<board>/`. See `docs/flashing.md`.

`buildroot-external/` and `launcher/`, `tools/` must stay siblings: the
launcher and tools packages build from `$(BR2_EXTERNAL_RETROOPI_PATH)/../`.

## How the boards share the tree

Each defconfig lists layers, most generic first:

There are two families: `board/h616/` (Orange Pi Zero3, KickPi K2B: U-Boot,
extlinux.conf, mainline + Armbian kernel) and `board/bcm2711/` (Raspberry Pi 4:
VideoCore firmware boot, the Raspberry Pi kernel). The Pi 4's board layer is
`board/rpi4/`.

| Buildroot option | Layers |
|---|---|
| `BR2_ROOTFS_OVERLAY` | `board/common/rootfs_overlay`, then the board's (H616: `extlinux.conf`; Pi 4: its own `/etc/fstab`) |
| `BR2_GLOBAL_PATCH_DIR` | `board/common/patches`, the family's `patches`, the board's `patches` (applied in that order) |
| `BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES` | `board/common/linux-retrogaming.config`, the family's `linux-retrogaming.config`, the board's `linux.config` |
| `BR2_ROOTFS_POST_BUILD_SCRIPT` | `board/common/post-build.sh` (shared invariants), then the family's `post-build.sh` (boot-chain checks) |
| post-image | `board/common/post-image.sh` (exFAT ROM partition), then genimage with the family's or board's `genimage.cfg` (H616: `board/h616/`, Pi 4: `board/rpi4/`) |

A new board needs: a defconfig (generate it from an existing one and change
only the board lines), `board/<name>/` with its DT/boot files and kernel
fragment, and an entry in `scripts/boards.sh`. A new SoC family adds a layer
next to `board/h616/` and `board/bcm2711/`.

## What you must supply

- **ROMs**, on the exFAT `RETROROMS` partition, one folder per system.
- **PlayStation BIOS** (`SCPH1001.BIN`) in `_system/bios/` on that partition.
- **A USB Bluetooth dongle** if you want a wireless DS3. The onboard radios are not enabled.

## Things that will bite you

- **Kconfig drops things silently.** After changing a defconfig, check that
  every line made it into `<work>/output/.config`. panfrost silently vanished
  until `BR2_PACKAGE_MESA3D_LLVM=y` was added. `post-build.sh` checks every
  kernel fragment line against the kernel's `.config`.
- **`target/` is incremental.** Deleting or renaming an overlay file does not
  remove it from the image. `board/common/post-build.sh` deletes known
  stale paths and hard-fails on invariants. Add to it.
- **The kernel version is tied to the vendored patches.** `board/h616/patches/linux/`
  is Armbian's set for exactly 6.18.53. Bump both together, and re-run the apply
  test described in that directory's README. The Pi 4's kernel is a pinned
  `raspberrypi/linux` commit (hash in `board/bcm2711/patches/linux/linux.hash`).
  `board/common/patches/linux/` applies to both kernels.
- **Patches live in two places:** `package/retroarch/libretro-*/` for cores,
  and `board/*/patches/<pkg>/` (`BR2_GLOBAL_PATCH_DIR`) for linux, U-Boot,
  mesa3d, bluez5_utils and fuse.
- **Line endings.** `.gitattributes` makes every text file LF, whatever
  `core.autocrlf` says. Three core patches are deliberately CRLF (`-text`).
  Check with `git ls-files --eol`; in Git Bash, `grep $'\r'` does not match CR.
- **Empty directories do not survive git.** Create them in `post-build.sh`
  (as `/opt/roms` is), never as empty overlay folders.
- **Verify a change reached the image,** not just the source. `board.sh push`
  prints board and host md5 side by side for that reason.
