#!/bin/bash
#
# Build the exFAT ROM partition image, then hand off to Buildroot's genimage.sh.
#
# The SD card gets two visible partitions:
#   p1  ext4   rootfs (kernel, DTBs and extlinux live in /boot inside it)
#   p2  exFAT  ROMs, mounted at /opt/roms -- readable/writable from Windows,
#              so ROMs can be dropped straight onto the card
#
# exFAT, not FAT32 (the reference's choice), at the user's request: no 4 GB file
# limit (PSP/Dreamcast/PSX images), and it is what Windows formats large cards
# as anyway. The kernel side was already in place (EXFAT_FS=y, 0052 readahead
# fix, fstab type "auto"), see the reference DevelopmentLog.
#
# The partition is created EMPTY. mtools, which pre-created the system folders
# on the FAT32 image, cannot write exFAT, and the build host cannot loop-mount
# without root. The folders and README.txt are made by /etc/init.d/S46card on
# the first boot instead (it already added missing folders to older cards), so
# boot a freshly flashed card once before copying ROMs onto it from a PC.
set -e

BINARIES_DIR="$1"
shift

ROMS_IMG="${BINARIES_DIR}/roms.exfat"
# Default sized for a 32 GB card. "32 GB" cards are sold in decimal GB, and
# their real capacity varies by brand from ~30.5e9 to ~32.0e9 bytes. The whole
# image is 1 MiB (bootloader) + 1024 MiB (rootfs) + this, so 27648 MiB makes
# a 28673 MiB (30.07e9 byte) image, which fits every 32 GB card seen so far.
# Override for other cards, e.g. RETROOPI_ROMS_SIZE_MB=2048 for a small
# dev image, or ~57000 for a 64 GB card.
ROMS_SIZE_MB="${RETROOPI_ROMS_SIZE_MB:-27648}"
LABEL="RETROROMS"

MKFS_EXFAT="${HOST_DIR}/sbin/mkfs.exfat"
[ -x "$MKFS_EXFAT" ] || MKFS_EXFAT="${HOST_DIR}/bin/mkfs.exfat"
if [ ! -x "$MKFS_EXFAT" ]; then
	echo "post-image.sh: ERROR: mkfs.exfat not found (need BR2_PACKAGE_HOST_EXFATPROGS)" >&2
	exit 1
fi

echo "post-image.sh: creating ${ROMS_SIZE_MB} MiB exFAT ROM partition"
rm -f "$ROMS_IMG" "${BINARIES_DIR}/roms.vfat"
# Sparse, not dd from /dev/zero: at 27 GiB that is 27 GiB of zeros written to
# the build disk every image build. mkfs.exfat only writes the boot region,
# bitmap, upcase table and root directory; the rest stays a hole, which
# genimage and xz both skip cheaply.
truncate -s "${ROMS_SIZE_MB}M" "$ROMS_IMG"
"$MKFS_EXFAT" -L "$LABEL" "$ROMS_IMG" >/dev/null

echo "post-image.sh: ROM partition ready: $(du -h "$ROMS_IMG" | cut -f1)"

# genimage.sh runs after this script: BR2_ROOTFS_POST_IMAGE_SCRIPT lists both,
# in order, and Buildroot passes the same arguments to each. We ignore the
# "-c <genimage.cfg>" args meant for genimage.
exit 0
