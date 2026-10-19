#!/bin/bash
#
# Bring a board's root filesystem up to date with the build's target/, over SSH,
# without reflashing (the card's ROM partition is the user's). Run inside WSL:
#
#   wsl bash /mnt/c/RetroArch_PI/scripts/sync-rootfs.sh <board> [-n]
#
#   -n   dry run: list what differs, change nothing
#
# Every file in <work>/output/target is md5-compared with the board; the ones
# that differ or are missing are installed with `board.sh push` (atomic
# rename, md5 verified, the launcher stopped around it, refused while a game
# runs). Files are never deleted from the board.
#
# Left alone on purpose:
#   /boot, /lib/modules   kernel side: board.sh kernel
#   /etc/passwd, group, shadow   target/ lacks the accounts added at image time
#                                (dbus, input, ...): pushing them breaks D-Bus
#                                and Bluetooth (K2B log, 2026-10-15)
#   /etc/dropbear         the board's SSH host keys
#   /etc/asound.conf      written by S11alsa at boot
#   /etc/udev/hwdb.d, /THIS_IS_NOT_YOUR_ROOT_FILESYSTEM
#                         removed by Buildroot when it makes the rootfs image
#   /root/.config/retroarch/config/**/*.opt
#                         RetroArch fills these in with every core option on a
#                         core's first launch (keeping our tuned values); the
#                         shipped ones hold only the tuned keys
#   /var                  runtime state (bluetooth pairings, ALSA state, seed)
set -eo pipefail
PROJ=$(cd "$(dirname "$0")/.." && pwd)
. "$PROJ/scripts/boards.sh" "${1:-}"
DRY=; [ "${2:-}" = -n ] && DRY=1
T=$BOARD_WORK/output/target
BOARD_IP=$(cat "$BOARD_WORK/board_ip")
O=(-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 -i ~/.ssh/retroopi_ed25519)
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT

(cd "$T" && find . -type f) | sed 's|^\.||' \
	| grep -v -E '^/(boot|lib/modules|etc/dropbear|var|etc/udev/hwdb\.d)/' \
	| grep -v -x -E '/etc/(passwd|group|shadow|asound\.conf)|/THIS_IS_NOT_YOUR_ROOT_FILESYSTEM' \
	| grep -v -E '^/root/\.config/retroarch/config/.*\.opt$' \
	| sort > "$W/list"
(cd "$T" && while IFS= read -r f; do md5sum ".$f"; done < "$W/list") | sed 's|  \./|  /|' > "$W/host.md5"
scp -O "${O[@]}" "$W/list" "root@$BOARD_IP:/tmp/sync.list" >/dev/null
ssh "${O[@]}" "root@$BOARD_IP" 'while IFS= read -r f; do if [ -f "$f" ]; then md5sum "$f"; else echo "missing  $f"; fi; done < /tmp/sync.list; rm -f /tmp/sync.list' > "$W/board.md5"
# diff exits 1 when anything differs, the normal case: not a failure here.
{ diff <(sort -k2 "$W/host.md5") <(sort -k2 "$W/board.md5") || true; } | sed -n 's/^< [0-9a-f]*  //p' > "$W/changed"
n=$(grep -c . "$W/changed" || true)
echo "sync-rootfs: $(grep -c . "$W/list") files compared, $n differ on $BOARD_NAME"
sed 's/^/  /' "$W/changed"
[ "$n" -gt 0 ] || exit 0
[ -n "$DRY" ] && { echo "(dry run: nothing changed)"; exit 0; }
# board.sh push takes the paths as arguments: names may have spaces.
mapfile -t files < "$W/changed"
bash "$PROJ/scripts/board.sh" "$BOARD" push "${files[@]}"
