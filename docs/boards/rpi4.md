# Board — Raspberry Pi 4 (planned)

> Third board, and the first outside the Allwinner family. Build name: `rpi4` (to be added to
> `scripts/boards.sh`; work directory `~/rpi4`). History will go in `docs/log/rpi4.md`.
> Status: steps 1–3 done 2026-10-18: skeleton, first build (57 min), first boot (launcher,
> GLES, HDMI audio, USB DS3, ROM card). Next: the read-only root. Log: `docs/log/rpi4.md`.

The fundamentals stay the same as on the other boards: **the menu on HDMI within a few seconds of
power-on**, and **nothing a power cut can break**. Everything below is judged against those two.

---

## Decisions so far (user, 2026-10-18)

| Topic | Decision |
|---|---|
| Kernel | **Raspberry Pi's fork** (`raspberrypi/linux`), as Buildroot's own `raspberrypi4_64_defconfig` uses. The firmware's DT overlays (vc4-kms-v3d, UART, gpio-shutdown) are written for it. Pinned: `rpi-6.18.y` @ `2341883` (6.18.57), the same series as the Allwinner boards' 6.18.53 |
| Power-cut safety | **Read-only root filesystem**, as a shared change (all boards in the end). Writable state goes to a small journaled data partition |
| Gamepad | PS3 pad over **USB** first. Onboard Bluetooth (BCM43455, mainline/RPi drivers exist) later. Note: the DS3 is classic Bluetooth, not BLE; the chip does both |
| Hardware | **1 GB** RAM (970,752 KiB seen by the kernel; 256 MiB of it CMA), fan/cooled case, Ethernet. **No serial adapter yet**: the K2B's (COM8) can move over, and should for bring-up |

## Hardware — Raspberry Pi 4 Model B

| Item | Detail | vs. H618 boards |
|---|---|---|
| SoC | BCM2711, 4× Cortex-**A72** @ 1.5 GHz (1.8 GHz on newer boards) | A53 @ 1.5 GHz: the A72 is roughly 2× faster per clock |
| GPU | VideoCore VI: **V3D 4.2** render (Mesa `v3d`), display through **vc4** (Mesa kmsro, like panfrost + sun4i-drm) | GLES 3.1 on both |
| Display | 2× micro-HDMI; HDMI0 (next to USB-C) is the one to use | |
| Audio | HDMI audio via vc4-hdmi (an ALSA card per HDMI port); 3.5 mm analog | Different card names: S11alsa's softvol setup has to find the right one |
| Boot | **EEPROM bootloader → `start4.elf` on a FAT partition → kernel directly**. No U-Boot, no TF-A, no SPL | Fewer stages than SPL → BL31 → U-Boot |
| Network | Gigabit Ethernet (bcmgenet), onboard Wi-Fi/BT (BCM43455) | |
| USB | 2× USB 3.0 + 2× USB 2.0 behind a VL805 (PCIe) | |
| Power | USB-C 5 V/3 A. **GPIO3 to GND wakes a halted Pi**: with `dtoverlay=gpio-shutdown`, one button can do both off and on | The K2B's button can only power off |
| Serial | UART on GPIO14/15 (header pins 8/10), 3.3 V | |

## Layers

```
board/common  ->  board/bcm2711  ->  board/rpi4
(any board)       (Pi 4 family:      (config.txt, cmdline.txt,
                   kernel fragment,   genimage, fstab)
                   firmware config)
```

Shared files that are Allwinner-specific today and must become per-family:
- `board/common/genimage.cfg`: the U-Boot blob at 8 KB is sunxi-only. The Pi gets its own.
- `post-build.sh`: its extlinux.conf/LZ4/U-Boot checks are sunxi-only. They become conditional.
- `rootfs_overlay/etc/fstab`: the ROM partition is `mmcblk0p2` today. With a data partition the
  numbering differs, so the fstab lines move to the board layer (or go by partition label).
- The kernel fragment `board/h616/linux-retrogaming.config` is per family by design. bcm2711
  gets its own, starting from `bcm2711_defconfig`.

## Image layout (Pi 4)

| Part. | FS | Size | Mounted | Contents |
|---|---|---|---|---|
| p1 | FAT32 | 128 MB (64 MB on the first images) | not mounted at runtime (only by `board.sh kernel`) | firmware (`start4.elf`, `fixup4.dat`), `config.txt`, `cmdline.txt`, kernel, DTB, overlays |
| p2 | ext4, **read-only** | 1 GB | `/` ro | the system |
| p3 | ext4, journaled | 64 MB | `/data` rw | everything that must persist (below) |
| p4 | exFAT | rest of card | `/opt/roms` (mounted by `S02roms`: p4, or p5 if Windows made p4 an extended partition) | ROMs, saves, states, launcher data (as on the other boards) |

What writes to the root today, and where it goes (from the init scripts):
- `/etc/asound.conf`: S11alsa regenerates it at boot (only writes when it changes). Moves to `/run`
  (tmpfs), since it is regenerated anyway.
- `/var/lib/alsa/asound.state`: the volume, stored at shutdown by volumed. Goes to `/data`.
- `/var/lib/bluetooth`: pad pairings. Goes to `/data`.
- Dropbear host keys: regenerated on every boot if missing, which costs boot time. Go to `/data`.
- The seedrng seed. Goes to `/data`.
- `/root/.config/retroarch`: core options and remaps saved from RetroArch's menu. The shipped files
  stay in the read-only root; RetroArch's writable copy goes to `/data` (an overlay or a seeded copy:
  decided while implementing).
- `/var/log`, `/tmp`, `/run`: tmpfs (most already are).
- `board.sh push` and `kernel` remount `/` read-write for the update, then read-only again.

**Saves on exFAT.** exFAT has no journal, so a power cut during a save can damage the card's
allocation tables. Either mount it with `sync`, or flush right after each save and state write
(RetroArch and the launcher). Pick by measured cost: a PSP state is tens of MB.

**Existing Zero3/K2B cards.** Their ROM partition is p2 and fills the card, and the user's card
must not be repartitioned. So the read-only root reaches them on a fresh flash only, or with
another place for `/data` (e.g. a small partition carved from the rootfs partition's free space).
To be decided before porting the change back.

## Boot time

Targets: the Zero3 reaches the menu in ~6 s by stopwatch. The Pi's firmware stage is the unknown;
measure it first, with a stopwatch and serial timestamps (`sertime.ps1` as on the K2B).
- `config.txt`: `boot_delay=0`, `disable_splash=1`, `avoid_warnings=1`, `camera_auto_detect=0`,
  `display_auto_detect=0`, `auto_initramfs=0`. No initramfs.
- Kernel: try a gzip-compressed kernel (the Pi firmware unpacks it) against the plain `Image`, as
  with LZ4 on the Allwinner boards. Built-in drivers for everything used at boot: no module
  loading in the critical path, and less udev work.
- `cmdline.txt`: `quiet loglevel=4`, `rootwait`, `ro`, the same settle-free udev, async probe where
  it helps (USB through the VL805 is PCIe here).
- The EEPROM bootloader's own settings (e.g. `BOOT_UART=0`, the boot order) are changed only by
  flashing the EEPROM. That is outside the image; only with the user's go-ahead.

## Steps

1. ~~**Skeleton:**~~ Done 2026-10-18. `scripts/boards.sh` entry, `rpi4_retro_defconfig` (from the Zero3's, board lines
   swapped: `BR2_cortex_a72`, rpi-firmware, the RPi kernel, Mesa `v3d` + `vc4`), the
   `board/bcm2711` and `board/rpi4` layers, the shared files made per-family as listed above. The
   Allwinner builds must stay byte-identical (check their `.config` and image contents).
2. ~~**First build**~~ Done 2026-10-18, 57 min. (several hours: LLVM, Mesa, cores, on a new toolchain for the A72). Check every
   defconfig line in `.config`.
3. ~~**First boot**~~ Done 2026-10-18 (Game Boy with sound; GPU-heavy cores not yet tried)., writable root first: firmware → kernel → launcher on HDMI, Ethernet, SSH key
   login, HDMI audio, USB DS3, a game per GPU core (PSP, Dreamcast, N64).
4. **Read-only root + `/data`** on the Pi 4, then power-cut tests: pull the plug during a game, a
   save, a settings change and a boot; the next boot must be clean every time.
5. **Boot-time pass:** measure each stage, then cut.
6. **Release sweep** (`docs/test-plan.md`), with the Pi's numbers in it.
7. Later: onboard Bluetooth for the pad; the power button on GPIO3 (off and on); then the read-only
   root back on the Zero3/K2B.
