#!/bin/bash
#
# Copy every slot-10 save state (the game tests' start points) from a board's
# card into the project's git-ignored test-states/<board>/, in the card's own
# layout (<core>/<rom>.state10), and verify each copy by md5. Run inside WSL:
#
#   wsl bash /mnt/c/RetroArch_PI/scripts/fetch-test-states.sh <board>
#
# To put them on another card: copy test-states/<board>/<core>/ into that
# card's _system/states/<core>/ (from a PC, or over SSH). The states are tied
# to the exact ROM file and core version, so a card with a different dump of a
# game needs its own.
set -eo pipefail
PROJ=$(cd "$(dirname "$0")/.." && pwd)
. "$PROJ/scripts/boards.sh" "${1:-}"
BOARD_IP=$(cat "$BOARD_WORK/board_ip")
O=(-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 -i ~/.ssh/retroopi_ed25519)
DST=$PROJ/test-states/$BOARD
mkdir -p "$DST"
S=/opt/roms/_system/states
# tar over SSH: names have spaces, commas and brackets.
ssh "${O[@]}" "root@$BOARD_IP" "cd $S && find . -type f -name '*.state10' | tar cf - -T -" | tar -C "$DST" -xf -
# Verify: md5 on the board against md5 of the copy, file by file.
ssh "${O[@]}" "root@$BOARD_IP" "cd $S && find . -type f -name '*.state10' -exec md5sum {} +" | sort -k2 > "$DST/.md5-board"
(cd "$DST" && find . -type f -name '*.state10' -exec md5sum {} + | sort -k2) > "$DST/.md5-copy"
if cmp -s "$DST/.md5-board" "$DST/.md5-copy"; then
	echo "fetch-test-states: $(grep -c . "$DST/.md5-copy") state(s), md5 identical to the card:"
	(cd "$DST" && find . -type f -name '*.state10' -exec ls -l {} + | awk '{ printf "  %8.1f MB  %s\n", $5 / 1e6, substr($0, index($0, "./") + 2) }')
	rm -f "$DST/.md5-board" "$DST/.md5-copy"
else
	echo "fetch-test-states: MISMATCH between the card and the copy:" >&2
	diff "$DST/.md5-board" "$DST/.md5-copy" >&2 || true
	exit 1
fi
echo "in: $DST"
