#!/bin/bash
#
# Release smoke test over SSH: a few games per heavy emulator (docs/test-plan.md).
#
#   wsl bash /mnt/c/RetroArch_PI/scripts/release-test.sh <board> [test list]
#
# Copies scripts/release-tests.txt (or the given list) and release-test-board.sh
# to the board, runs them (the launcher is stopped meanwhile and the screen
# shows each game), and prints one verdict per game:
#   PASS  RetroArch still running, speed meter mean >= 95%
#   WARN  running, mean 80-95%, or no speed samples (no audio in the window)
#   FAIL  RetroArch exited (crash / load failure), or mean < 80%
#   SKIP  ROM not on this card
# Takes ~20 minutes with the default list. Refuses to start while a game runs.
set -eo pipefail
PROJ=$(cd "$(dirname "$0")/.." && pwd)
. "$PROJ/scripts/boards.sh" "${1:-}"
LIST=${2:-$PROJ/scripts/release-tests.txt}
BOARD_IP=${BOARD_IP:-$(cat "$BOARD_WORK/board_ip")}
KEY=~/.ssh/retroopi_ed25519
O=(-i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

ssh "${O[@]}" root@"$BOARD_IP" 'pidof retroarch.bin >/dev/null' && { echo "ABORT: a game is running on the board."; exit 2; }
sed 's/\r$//' "$LIST" | ssh "${O[@]}" root@"$BOARD_IP" 'cat > /tmp/release-tests.txt'
sed 's/\r$//' "$PROJ/scripts/release-test-board.sh" | ssh "${O[@]}" root@"$BOARD_IP" 'cat > /tmp/release-test-board.sh'

echo "release-test: $BOARD_NAME ($BOARD_IP), $(date '+%F %T')"
if grep -q '^[^#].*FLYCAST_THREADED_AUDIO=0' "$LIST"; then
	echo "NOTE: benchmark mode. Dreamcast runs with threaded audio OFF: the sound on the TV"
	echo "      will be choppy during this run by design. It is not what the player hears."
fi
ssh "${O[@]}" root@"$BOARD_IP" 'cat /etc/issue | head -1; uname -r; uptime'

# If this script is interrupted (Ctrl+C, closed terminal), stop the board-side
# run and give the board its launcher back: a test game must never be left
# playing on the TV (one was, once, in lockstep-audio mode).
cleanup() {
	ssh "${O[@]}" root@"$BOARD_IP" 'pkill -f release-test-board.sh; killall retroarch.bin 2>/dev/null; sleep 3;
		killall -9 retroarch.bin 2>/dev/null; pidof retroopi_launcher >/dev/null || /etc/init.d/S12launcher start' >/dev/null 2>&1 || true
}
trap 'echo "release-test: interrupted, stopping the run on the board"; cleanup; exit 130' INT TERM HUP
ssh "${O[@]}" root@"$BOARD_IP" 'sh /tmp/release-test-board.sh /tmp/release-tests.txt /tmp/release-test.txt >/dev/null; cat /tmp/release-test.txt' \
| awk -F'|' '
	$1 == "SKIP" { printf "SKIP  %-10s %-45.45s %s\n", $2, $3, $4; next }
	$1 != "RESULT" { next }
	{
		n = split($5, s, " "); sum = 0; min = 999
		for (i = 1; i <= n; i++) { sum += s[i]; if (s[i] < min) min = s[i] }
		mean = n ? sum / n : 0
		if ($4 != "yes") v = "FAIL"
		else if (n == 0) v = "WARN"
		else if (mean < 80) v = "FAIL"
		else if (mean < 95) v = "WARN"
		else v = "PASS"
		if (v == "PASS" && $8 ~ /LibCrypt/) v = "WARN"
		printf "%-5s %-10s %-45.45s alive=%-3s speed mean %5.1f%% min %5.1f%% (%d samples)  %d C  %s %s\n",
			v, $2, $3, $4, mean, (n ? min : 0), n, $7 / 1000, $6, ($8 != "" ? "ERR: " $8 : "")
	}'
