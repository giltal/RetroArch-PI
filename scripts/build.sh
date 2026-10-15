#!/bin/bash
#
# Build a board's image in WSL.
#
#   wsl bash /mnt/c/RetroArch_PI/scripts/build.sh <board>             # full build
#   wsl bash /mnt/c/RetroArch_PI/scripts/build.sh <board> linux       # one target
#   wsl bash /mnt/c/RetroArch_PI/scripts/build.sh <board> defconfig   # re-apply defconfig
#
# <board> is one of the names in scripts/boards.sh (zero3, k2b).
#
# Layout, per board (BOARD_WORK in boards.sh):
#   <work>/buildroot  Buildroot 2026.02.3, cloned from ~/bpi/buildroot
#   <work>/output     out-of-tree build (O=)
#   ~/bpi/dl          download cache, SHARED by all boards on purpose --
#                     Buildroot keys downloads by package and version, so sharing
#                     is safe and saves re-fetching ~800 MB
#
# Output: <work>/output/images/sdcard.img. It is copied to firmware/<board>/ in
# the project, which is gitignored.
set -eo pipefail

PROJ=$(cd "$(dirname "$0")/.." && pwd)
. "$PROJ/scripts/boards.sh" "${1:-}"
shift
BR=$BOARD_WORK/buildroot
OUT=$BOARD_WORK/output
export BR2_DL_DIR=~/bpi/dl
# Keep git (WSL's) out of this repository during the build. Buildroot's
# support/scripts/setlocalversion runs "git update-index --refresh" on the
# BR2_EXTERNAL tree to put a version string into the build info: over /mnt/c
# that refreshed all ~5,100 files for minutes, held .git/index.lock, and
# collided with Windows git. Nothing in the image depends on that string.
# Buildroot's own git use (package downloads) is outside $PROJ, so unaffected.
export GIT_CEILING_DIRECTORIES="$PROJ"
LOG=$BOARD_WORK/build.log
mkdir -p "$BOARD_WORK"

if [ ! -d "$BR" ]; then
	echo "build.sh: cloning Buildroot 2026.02.3 into $BR"
	git clone -q --branch 2026.02.3 ~/bpi/buildroot "$BR" 2>/dev/null \
		|| git clone -q --depth 1 --branch 2026.02.3 https://gitlab.com/buildroot.org/buildroot.git "$BR"
fi
cd "$BR"

if [ ! -f "$OUT/.config" ] || [ "${1:-}" = "defconfig" ]; then
	make BR2_EXTERNAL="$PROJ/buildroot-external" O="$OUT" "$BOARD_DEFCONFIG"
	[ "${1:-}" = "defconfig" ] && exit 0
fi

# Parallelism: BR2_JLEVEL jobs INSIDE each package, one package at a time.
#
# Build #1 used a top-level `make -j$(nproc)` instead, which lets Buildroot
# build several packages concurrently, each with its own nproc jobs. On clang
# that meant dozens of cc1plus processes at 0.5-2 GB each, and the OOM killer
# took one mid-build (WSL has 15 GB). Lower JLEVEL further if it recurs:
#   JLEVEL=8 bash scripts/build.sh clang
JLEVEL=${JLEVEL:-$(nproc)}

# Our own packages (launcher/, tools/) are SITE_METHOD=local, and Buildroot
# does NOT re-sync a local package's source on an ordinary `make`. Edited
# sources then silently keep shipping the OLD binary. That happened: a full
# build carried a launcher without the new PSP/Dreamcast entries, and it was
# only caught by grepping the binary. They take seconds to build, so a full build
# always cleans them first.
if [ $# -eq 0 ]; then
	make O="$OUT" retroopi-launcher-dirclean retroopi-tools-dirclean >/dev/null
fi

echo "build.sh: $(date '+%F %T') make ${*:-all} BR2_JLEVEL=$JLEVEL (log: $LOG)"
start=$(date +%s)
if make O="$OUT" BR2_JLEVEL="$JLEVEL" "$@" > "$LOG" 2>&1; then
	echo "build.sh: OK after $(( ($(date +%s) - start) / 60 )) min"
else
	echo "build.sh: FAILED after $(( ($(date +%s) - start) / 60 )) min -- tail of $LOG:"
	tail -40 "$LOG"
	exit 1
fi

if [ $# -eq 0 ]; then
	F="$PROJ/firmware/$BOARD"
	I="$OUT/images/sdcard.img"
	mkdir -p "$F"
	# IMAGE_TAG names the deliverable, so image variants can sit side by side:
	#   bash build.sh                                          -> sdcard.img.xz (32 GB card)
	#   RETROOPI_ROMS_SIZE_MB=2048 IMAGE_TAG=small bash build.sh -> sdcard-small.img(.xz)
	# The small one flashes in about a minute; its FAT partition is last on the
	# card, so it can be grown afterwards with a partition tool.
	N="sdcard${IMAGE_TAG:+-$IMAGE_TAG}"
	# The image is sized for a 32 GB card (see ROMS_SIZE_MB in post-image.sh)
	# and is almost entirely empty FAT space, sparse on the WSL side. Copying it
	# raw to /mnt/c would write every hole out as real zeros, so the
	# deliverable is xz-compressed: Etcher and Rufus both flash .xz directly.
	# The raw .img is only copied when it is small enough to be convenient.
	rm -f "$F/$N.img" "$F/$N.img.md5"
	echo "build.sh: compressing $N.img ($(du -h --apparent-size "$I" | cut -f1) apparent, $(du -h "$I" | cut -f1) on disk)"
	xz -T0 -3 -c "$I" > "$F/$N.img.xz.tmp" && mv "$F/$N.img.xz.tmp" "$F/$N.img.xz"
	if [ "$(stat -c %s "$I")" -le $((4 * 1024 * 1024 * 1024)) ]; then
		cp --sparse=always "$I" "$F/$N.img"
	fi
	md5sum < "$I" | sed "s|-\$|$N.img|" | tee "$F/$N.img.md5"
	ls -la "$F"
fi
