#!/bin/sh
#
# post-build, BCM2711 family (Raspberry Pi 4): the checks that depend on this
# family's boot chain. The VideoCore firmware reads config.txt and cmdline.txt
# from the FAT boot partition (p1) and loads the kernel itself: no U-Boot, no
# extlinux.conf. Runs after board/common/post-build.sh
# (BR2_ROOTFS_POST_BUILD_SCRIPT lists both).
#
# The boot-partition files are in $BINARIES_DIR already at this point: the
# rpi-firmware package installs them while it builds.
#
# TARGET_DIR is passed as $1 by Buildroot.

set -e
TARGET_DIR="$1"
FW="$BINARIES_DIR/rpi-firmware"

fail() {
	echo "post-build.sh (bcm2711): ERROR: $*" >&2
	exit 1
}

for f in start4.elf fixup4.dat config.txt cmdline.txt overlays/vc4-kms-v3d-pi4.dtbo; do
	[ -s "$FW/$f" ] || fail "boot partition file missing: rpi-firmware/$f"
done
cfg="$FW/config.txt"
cmd="$FW/cmdline.txt"

# KMS display through vc4 + v3d. Without the overlay the firmware's own
# framebuffer is all there is: no DRM display node, no GPU, no games.
grep -q '^dtoverlay=vc4-kms-v3d-pi4' "$cfg" \
	|| fail "config.txt has no dtoverlay=vc4-kms-v3d-pi4"
# Enough CMA for the 1080p scanout buffers (see the H616 boards' extlinux.conf:
# the 32 MiB default ran out and every game launch failed). On the Pi the size
# is the overlay's cma- parameter.
grep -q '^dtoverlay=vc4-kms-v3d-pi4.*,cma-[0-9]' "$cfg" \
	|| fail "config.txt: vc4-kms-v3d-pi4 has no cma- parameter -- 1080p scanout buffers will not fit"
# Only vc4 may turn HDMI on: if the firmware does too, the TV locks twice per
# boot (see config.txt).
grep -q '^hdmi_ignore_hotplug=1' "$cfg" \
	|| fail "config.txt lacks hdmi_ignore_hotplug=1 -- the TV would lock twice on every boot"
# The kernel and DTB config.txt names must be the ones genimage puts on p1.
k=$(sed -n 's/^kernel=//p' "$cfg")
[ -n "$k" ] && [ -s "$BINARIES_DIR/$k" ] \
	|| fail "config.txt kernel=$k, which is not in $BINARIES_DIR"
grep -q "\"$k\"" "$BR2_EXTERNAL_RETROOPI_PATH/board/rpi4/genimage.cfg" \
	|| fail "config.txt boots $k, but board/rpi4/genimage.cfg does not put it on p1"
# A gzip kernel must really be gzip: the firmware unpacks it by its magic.
case "$k" in *.gz)
	[ "$(od -A n -t x1 -N 2 "$BINARIES_DIR/$k" | tr -d ' ')" = 1f8b ] \
		|| fail "$k is not gzip-compressed" ;;
esac
d=$(sed -n 's/^device_tree=//p' "$cfg")
[ -s "$BINARIES_DIR/$d" ] || fail "config.txt device_tree=$d, not in $BINARIES_DIR"

# cmdline.txt must be ONE line: the firmware ignores everything after the
# first newline, silently.
[ "$(grep -c . "$cmd")" -eq 1 ] || fail "cmdline.txt must be a single line"
grep -q 'root=/dev/mmcblk0p2 ' "$cmd" || fail "cmdline.txt does not boot root=/dev/mmcblk0p2"

# /data (p3): the journaled ext4 data partition. Created here, because empty
# directories do not survive git (see /opt/roms in board/common/post-build.sh).
mkdir -p "$TARGET_DIR/data"
awk '$1 == "/dev/mmcblk0p3" && $2 == "/data"' "$TARGET_DIR/etc/fstab" | grep -q . \
	|| fail "/etc/fstab has no /dev/mmcblk0p3 /data line"
awk '$1 == "/dev/mmcblk0p4" && $2 == "/opt/roms"' "$TARGET_DIR/etc/fstab" | grep -q . \
	|| fail "/etc/fstab: the ROM partition must be /dev/mmcblk0p4 on the Pi 4"
# The ROM line is noauto: S02roms mounts it (p4, or p5 when Windows has made
# p4 an extended partition). Without the script nothing mounts /opt/roms.
awk '$2 == "/opt/roms" && $4 ~ /(^|,)noauto(,|$)/' "$TARGET_DIR/etc/fstab" | grep -q . \
	|| fail "/etc/fstab: the /opt/roms line must be noauto (S02roms mounts it)"
[ -f "$TARGET_DIR/etc/init.d/S02roms" ] || fail "no /etc/init.d/S02roms -- the ROM partition would never mount"

echo "post-build.sh (bcm2711): boot partition files, config.txt, cmdline.txt and fstab OK"
