# Flashing and first boot

## Write the card

`firmware/<board>/sdcard.img.xz` is a complete, compressed card image: the
SPL/TF-A/U-Boot blob at 8 KB, p1 = 1 GiB ext4 rootfs, p2 = 27 GiB exFAT ROMs.
It is sized for a **32 GB card**: the uncompressed image is 30.07e9 bytes, and
32 GB cards hold roughly 30.5e9 to 32.0e9. For other card sizes, rebuild with
`RETROOPI_ROMS_SIZE_MB=<MiB>` (see `board/common/post-image.sh`).

- **Windows:** balenaEtcher or Rufus (DD mode). Both take the `.xz` directly.
  Pick the right disk. Writing takes a while: the card gets all ~30 GB.

**Faster alternative: `firmware/<board>/sdcard-small.img`** (2 GiB ROM partition,
built with `RETROOPI_ROMS_SIZE_MB=2048 IMAGE_TAG=small`). It flashes in about a
minute. Then grow `RETROROMS` to fill the card from Windows with a partition
tool such as MiniTool Partition Wizard or AOMEI Partition Assistant. The ROM
partition is the last one on the card, so it can grow in place, and the board
mounts it the same way at any size.
- **Linux:** `xz -dc sdcard.img.xz | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress`

A reflash **wipes the ROM partition**. For day-to-day iteration, push files
over SSH (`scripts/board.sh <board> push`, `... kernel`) instead of reflashing.
U-Boot can be updated in place too: write `u-boot-sunxi-with-spl.bin` at 8 KB
of the card (`dd ... bs=1024 seek=8 conv=fsync`), after backing up that region.

## Put ROMs on it

The ROM partition is created **empty**. Boot the card once: the console
creates one folder per system, `_system/` and a `README.txt` on it. Then put
the card in a PC: Windows sees the exFAT `RETROROMS` partition. Drop ROMs into
the per-system folders. The PSX BIOS goes in `_system\bios\`.

A card you reformat yourself (exFAT or FAT32) works too; the folders are added
on the next boot.

## First boot checklist

Connect serial (the board's debug UART, 115200 8N1, 3.3 V) **and** HDMI **and** Ethernet.

1. U-Boot banner, then the kernel on serial. A DRAM or device-tree failure
   shows only there; HDMI stays black.
2. The launcher appears on HDMI at 1920×1080. If it doesn't, check `/var/log/retroopi_launcher.log`.
   The launcher lists the modes the TV offers if 1080p is missing.
3. Find the board's IP (router, or `ip addr` on serial). Then write it to the
   board's work directory in WSL (`echo <ip> > ~/k2b/board_ip`, see
   `scripts/boards.sh`) and run `scripts/board.sh <board> status`.
4. `board.sh status` should show: a DRM HDMI connector `connected`, an ALSA card
   with "hdmi" in its name, `performance` governor, thermal zones, and a devfreq entry for the GPU.
5. Start a game. Check `/tmp/retroarch_verbose.log` for
   `[GL]: Vendor: Mesa, Renderer: Mali-G31 (Panfrost)`.

Root password: `retroopi` (development credential). Images built on a machine
with `~/.ssh/retroopi_ed25519.pub` accept that key, so SSH needs no password.
