#!/bin/sh
#
# post-build, H616/H618 family (Orange Pi Zero3, KickPi K2B): the checks that
# depend on this family's boot chain -- U-Boot reading extlinux.conf and an
# LZ4 kernel from /boot in the rootfs. Runs after board/common/post-build.sh
# (BR2_ROOTFS_POST_BUILD_SCRIPT lists both); moved out of it unchanged when
# the Pi 4, which boots from its firmware instead, was added.
#
# TARGET_DIR is passed as $1 by Buildroot.

set -e
TARGET_DIR="$1"

fail() {
	echo "post-build.sh (h616): ERROR: $*" >&2
	exit 1
}

# Enough CMA for the scanout buffers at this resolution. At 1080p the kernel's
# default 32 MiB pool ran out and every game launch failed with
# "DRM_IOCTL_MODE_CREATE_DUMB failed: Cannot allocate memory".
grep -q ' cma=[0-9]*M' "$TARGET_DIR/boot/extlinux/extlinux.conf" \
	|| fail "extlinux.conf has no cma= -- 1080p scanout buffers will not fit in the default 32 MiB"

# LZ4-compressed kernel, which extlinux.conf boots by default: U-Boot reads
# ~20 MB off the card instead of the 44.7 MB Image, and unpacks it in memory
# (booti handles LZ4 *frames*, independent blocks; the kernel's own Image.lz4
# target writes the legacy LZ4 format, which booti does not recognise). The
# plain Image stays as extlinux.conf's fallback label: if the LZ4 one ever
# fails to boot, U-Boot tries the next label instead of stopping.
# The explicit ! -f matters: this is /bin/sh (dash on the build host), where
# "a -nt b" is FALSE when b does not exist (bash says true), so a fresh build
# never made Image.lz4 and the header check below failed.
if [ ! -f "$TARGET_DIR/boot/Image.lz4" ] \
	|| [ "$TARGET_DIR/boot/Image" -nt "$TARGET_DIR/boot/Image.lz4" ]; then
	LZ4="$HOST_DIR/bin/lz4"
	[ -x "$LZ4" ] || LZ4="$(command -v lz4 || true)"
	[ -n "$LZ4" ] || fail "lz4 not found (Buildroot's host lz4, or the build host's)"
	"$LZ4" -9 -f -q "$TARGET_DIR/boot/Image" "$TARGET_DIR/boot/Image.lz4" \
		|| fail "lz4 failed on boot/Image"
fi
# Frame magic 04 22 4D 18, then FLG with version 01 and independent blocks
# (FLG & 0xE0 == 0x60): what U-Boot's ulz4fn() accepts.
hdr=$(od -A n -t x1 -N 5 "$TARGET_DIR/boot/Image.lz4" | tr -d ' \n')
[ "${hdr%??}" = "04224d18" ] && [ $(( 0x${hdr#04224d18} & 0xe0 )) -eq $(( 0x60 )) ] \
	|| fail "boot/Image.lz4 is not an LZ4 frame with independent blocks (header $hdr)"

# Kernel and DTB where extlinux.conf says they are. A wrong fdt path boots to
# nothing at all, with the only clue on the serial console.
ext="$TARGET_DIR/boot/extlinux/extlinux.conf"
for f in $(sed -n 's/^[[:space:]]*\(kernel\|fdt\)[[:space:]]\+//p' "$ext"); do
	[ -e "$TARGET_DIR$f" ] || fail "extlinux.conf references $f, which is not in target/"
done
# The fallback label must boot the same system as the default one (apart from
# its retroopi.boot=uncompressed marker).
[ "$(grep -c '^[[:space:]]*append ' "$ext")" -eq 2 ] \
	&& [ "$(grep '^[[:space:]]*append ' "$ext" | sed 's/ retroopi\.boot=uncompressed$//' | sort -u | wc -l)" -eq 1 ] \
	|| fail "extlinux.conf: the LZ4 and fallback labels' append lines differ"

echo "post-build.sh (h616): extlinux.conf, Image.lz4 and CMA OK"
