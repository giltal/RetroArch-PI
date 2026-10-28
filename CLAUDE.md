# RetroArch-PI — Project Instructions

## What This Is

Retro gaming console firmware for small ARM boards, output over **HDMI at 1920×1080**: a
DRM/KMS launcher, RetroArch on the GPU and 21 libretro cores, built with Buildroot 2026.02.3
on mainline Linux 6.18.53. **One tree, several boards:**

| Board (`build.sh` name) | SoC | Notes |
|---|---|---|
| Orange Pi Zero3 (`zero3`) | Allwinner H618, Mali-G31 MP2, 2 GB LPDDR4 | The reference board: almost every setting was measured on it |
| KickPi K2B V2.2 (`k2b`) | Allwinner H618, Mali-G31 MP2, 2 GB DDR3 | Maxio MAE0621A PHY; V1 not supported; no eMMC |
| Raspberry Pi 4 (`rpi4`) | BCM2711, V3D 4.2 | Working: family layer `board/bcm2711`, board `board/rpi4`; notes in `docs/boards/rpi4.md` |
| GPi Case 2 + CM4 Lite (`gpicase2`) | BCM2711, V3D 4.2 | Docked (HDMI) and handheld (LCD + speaker) both run; dock changes need a restart; board `board/gpicase2`; plan in `docs/boards/gpicase2.md` |

History: a port of RetroBPI_M2M (Banana Pi M2 Magic). The Zero3 tree (RetroOPI_Z3) became this
repo; the K2B was first ported in its own tree and merged here. Both old folders are
**superseded** and archived on the backup SSD (`H:\OrangePI_Projects\RetroOPI_Z3`,
`H:\KickPI_Projects\K2B_RetroArch`, verified by MD5). Read them if needed; never work in them.

- **Read `Context.md` first**, then the board's notes in `docs/boards/<board>.md`.
- **Read the last entry of `DevelopmentLog.md`** (shared work) and of the board's log in
  `docs/log/<board>.md` before continuing.
- Before changing a core choice, a RetroArch setting, a shader or a launcher behaviour, read
  `docs/log/opi-zero3.md`: almost every setting was measured there, and the log says why.

## Layers — put each change in the right one

| Layer | What lives there |
|---|---|
| `package/`, `launcher/`, `tools/`, `board/common/` | Shared by every board: RetroArch + cores, launcher, tools, rootfs overlay, shared kernel fragment and patches, post-build (invariants), post-image (exFAT) |
| `board/h616/` | Shared by the Allwinner H616/H618 boards: Armbian kernel patches, kernel fragment, U-Boot fragment and patches, genimage, boot-chain post-build |
| `board/bcm2711/` | Raspberry Pi 4 family (Pi 4, CM4): kernel fragment, kernel hash, boot-chain post-build, card layout (fstab, S02roms) |
| `board/<board>/` | Only that board: DT patches, PHY/board drivers, U-Boot board config, kernel `linux.config`, `extlinux.conf` (Pi 4, GPi Case 2: `config.txt`, `cmdline.txt`, genimage) |

A fix found on one board belongs in the most generic layer it applies to. Both defconfigs are
the same file apart from the board lines: change shared options in **both**, and keep the diff
between them limited to the board identity and layer paths. A new board also needs an entry in
`scripts/boards.sh`.

## Hard constraints

- **Mainline Linux has no H616/H618 HDMI.** HDMI, TCON-TV and DE33 come from Armbian's patch set
  in `board/h616/patches/linux/` (provenance in its `README.md`). **The kernel is pinned to that
  set** (6.18.53); bump them together.
- **panfrost needs LLVM** in Mesa 26 (`BR2_PACKAGE_MESA3D_LLVM=y`). Without it Kconfig silently
  drops panfrost, GBM, EGL and GLES.
- **K2B: only the V2.2** (DDR3, Maxio MAE0621A). Armbian's `kickpi-k2b` DTS/U-Boot describe the
  V1 (LPDDR4, RTL8211F). Ethernet needs kernel 0062 (Maxio driver) and 0064 (PI6 hog); without
  them: "EMAC reset timeout", no eth0. eMMC is disabled and not supported.
- **Onboard Wi-Fi/BT** has no mainline driver on either board and is **not enabled**. Networking
  is the onboard Ethernet. The DS3 needs a USB BT dongle.
- **Serial console** (115200 8N1, 3.3 V) is required for bring-up: a DRAM or DT failure shows
  nothing on HDMI. On the K2B it is COM8 on this PC; `scripts/serial.ps1` is a minimal terminal.

## Development Environment

- **Host OS:** Windows + WSL2 (Ubuntu 22.04). Per-board work directories (`scripts/boards.sh`):
  `~/zero3`, `~/k2b`, `~/rpi4`, each with `buildroot/`, `output/` (`O=`), `build.log`, `board_ip`.
  Buildroot outputs are not relocatable: never rename a work directory.
  - `~/bpi/dl`: download cache, **shared** by all boards (and the old reference trees) on purpose.
  - `~/k2b/armbian-build`: sparse, blob-less Armbian clone (the K2B files: Maxio, V2 U-Boot).
    `~/opi/armbian-build`: the original sparse clone at `2843c11` (source of `h616/patches/linux`).
- **Do not modify `~/bpi` or `~/opi`** (the old reference trees) except the shared `~/bpi/dl`.
- **WSL clock: `systemd-timesyncd` must stay disabled** (`wsl -u root systemctl disable --now
  systemd-timesyncd`; done 2026-10-14). With it on, it and Hyper-V's TimeSync step the clock back
  and forth about every 30 s, make sees finished steps as stale, and packages are re-extracted over
  their patched trees ("duplicate filename"). Fix: `<pkg>-dirclean`.
- **WSL command pattern:** `wsl bash /mnt/c/.../script.sh` from **PowerShell**. Put anything
  non-trivial in a script file. From git-bash, `wsl bash -c '...'` mangles `$vars`, pipes and
  `/mnt/c` paths. **WSL `/tmp` does not persist between calls.**
- **Backslashes get eaten one level** when generating files through heredocs or inline Python.
  Use the Edit tool for any line containing a backslash.
- **Line endings:** `.gitattributes` makes every text file LF (`* text=auto eol=lf`), whatever
  `core.autocrlf` says; three core patches are deliberately CRLF (`-text`). Check with
  `git ls-files --eol` (look for `w/crlf`). **In this Git Bash, `grep $'\r'` does not match CR**:
  it reported CRs in LF files. Python on Windows writes CRLF in text mode: use `newline=''`. It also reads and writes
  cp1252 by default, which corrupts any non-ASCII character it writes (`—`, `×`): pass
  `encoding='utf-8'` too.
- **Empty directories do not survive git** (`/opt/roms` was lost that way). Create them in
  `post-build.sh`.

## Build

```bash
wsl bash /mnt/c/RetroArch_PI/scripts/build.sh k2b              # full image
wsl bash /mnt/c/RetroArch_PI/scripts/build.sh k2b defconfig    # re-apply defconfig
wsl bash /mnt/c/RetroArch_PI/scripts/build.sh k2b linux-rebuild
```

The log is `<work>/build.log`. The result is `<work>/output/images/sdcard.img`, copied (xz) to
`firmware/<board>/`. `RETROOPI_ROMS_SIZE_MB=2048 IMAGE_TAG=small` makes the small image.
A board's first full build is several hours (LLVM, Mesa, cores).

**After editing a defconfig**, confirm every line survived into `<work>/output/.config`. Kconfig
drops symbols whose dependencies are unmet **without any error**.

## Board

`scripts/board.sh <board>` does status, push, kernel, run and ssh over Ethernet. Write the board IP
to `<work>/board_ip` once. Root password `retroopi` (a development credential; Claude never types
it; the user logs in on the serial console when needed). Images built on this machine include
`~/.ssh/retroopi_ed25519.pub`, so key login works right after a flash. It refuses kernel/push
while a game is running. U-Boot is updated by `dd` at 8 KB of the card over SSH: back up the
8 KB–1 MiB region first, verify by reading back.

**`core-info <core.so>`** (on the board) loads a libretro core and prints its options and allowed
values. Use it before writing any `.opt` file; invalid keys and values are silently ignored.

**Local packages** (`launcher/`, `tools/`) are not re-synced by a plain `make`. `build.sh` with no
target dircleans them first. For a single-target build, run `retroopi-launcher-dirclean` yourself.

**The ROM card is the user's.** Never regenerate or reflash it. Anything new a card needs goes into
`S46card`, which is strictly additive. No downloading ROMs or BIOS files. Cover art fetched by
`scripts/fetch-thumbnails.py --board <board>` stays in the git-ignored cache and is never committed.
Images and cover art are shared from the user's OneDrive, not from this repo.

Downloads, commits and pushes happen only when the user asks.

## Naming

Internal names stay `retroopi` (packages `retroopi-launcher`/`retroopi-tools`, the
`BR2_EXTERNAL_RETROOPI_PATH` variable, hostname, binaries, `/etc/retroopi*`) so diffs and history
stay readable. The project name is RetroArch-PI.

## Key Paths

```
C:\RetroArch_PI
  README.md, BUILDING.md, Context.md, DevelopmentLog.md (shared work)
  docs/  flashing.md, boards/<board>.md, log/<board>.md
  buildroot-external/
    configs/  opi_zero3_retro_defconfig, kickpi_k2b_retro_defconfig, rpi4_retro_defconfig,
              gpicase2_retro_defconfig
    package/  retroarch (RetroArch + cores, Flycast/PPSSPP patches), retroopi-launcher, retroopi-tools
    board/common/     rootfs_overlay/, linux-retrogaming.config, post-build.sh (invariants), post-image.sh (exFAT),
                      patches/linux (0001 exFAT readahead, both kernels),
                      patches/ (bluez5_utils, libretro-fuse, mesa3d)
    board/h616/       linux-retrogaming.config, uboot-fastboot.config, genimage.cfg, post-build.sh,
                      patches/linux (Armbian 0001-0049 + README), patches/uboot (kernel_addr_r)
    board/bcm2711/    linux-retrogaming.config, post-build.sh, patches/linux/linux.hash,
                      rootfs_overlay/etc (fstab, init.d/S02roms: the BCM2711 card layout)
    board/opi-zero3/  linux.config, patches/linux (0046/0047/0050/0051), extlinux.conf
    board/kickpi-k2b/ linux.config, patches/linux (0060-0066), patches/uboot (0001-0002), extlinux.conf
    board/rpi4/       config.txt, cmdline.txt, genimage.cfg, rootfs_overlay (LCD: lcdinfo, init file)
    board/gpicase2/   config.txt, cmdline.txt, genimage.cfg, rootfs_overlay (S03latch) (GPi Case 2 + CM4 Lite)
  launcher/  tools/
  hardware/rpi4-arcade-case/  arcade_case.py (Fusion API script: the source), step/, 3mf/, stl/, README.md
  scripts/   boards.sh, build.sh, board.sh, serial.ps1, fetch-thumbnails.py, gen-*.py,
             rpi4-eeprom.sh [board] (Pi 4 / CM4 bootloader update; changes the board: ask first)
  firmware/<board>/   build output (gitignored)
```
