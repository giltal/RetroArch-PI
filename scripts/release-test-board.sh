#!/bin/sh
# Runs ON THE BOARD (BusyBox sh). Started by scripts/release-test.sh.
#
#   release-test-board.sh <test list> [result file]
#
# For each test: start RetroArch exactly as the launcher does (the
# /usr/bin/retroarch wrapper: --verbose, RETROARCH_LOG_SPEED=1), wait <settle>,
# collect the audio speed meter for <measure> seconds, check RetroArch is still
# alive, stop it. The launcher is stopped for the run and restarted at the end.
# One result line per test:
#   RESULT|system|rom|alive|speeds...|renderer|temp_mC|error
LIST=$1
OUT=${2:-/tmp/release-test.txt}
ROMS=/opt/roms
CORES=/usr/lib/libretro
LOG=/tmp/retroarch_verbose.log

stop_ra() {
	kill "$1" 2>/dev/null
	i=0
	while kill -0 "$1" 2>/dev/null && [ $i -lt 10 ]; do sleep 1; i=$((i + 1)); done
	kill -9 "$1" 2>/dev/null
	killall -9 retroarch.bin 2>/dev/null
	sleep 2
}

/etc/init.d/S12launcher stop >/dev/null 2>&1
sleep 2
: > "$OUT"
while IFS='|' read -r sys core rom settle measure envs; do
	case "$sys" in ''|'#'*) continue ;; esac
	path="$ROMS/$sys/$rom"
	if [ -d "$path" ]; then
		path=$(ls "$path"/*.gdi "$path"/*.cue "$path"/*.m3u 2>/dev/null | head -1)
	fi
	if [ -z "$path" ] || [ ! -e "$path" ]; then
		echo "SKIP|$sys|$rom|missing" >> "$OUT"
		continue
	fi
	[ -e "$CORES/$core" ] || { echo "RESULT|$sys|$rom|no|||0|core missing: $core" >> "$OUT"; continue; }

	: > "$LOG"
	# shellcheck disable=SC2086 -- envs is a list of VAR=value words
	env $envs /usr/bin/retroarch -L "$CORES/$core" "$path" </dev/null >/dev/null 2>&1 &
	pid=$!
	sleep "$settle"
	n0=$(grep -c 'Speed:' "$LOG")
	sleep "$measure"

	alive=no
	kill -0 $pid 2>/dev/null && alive=yes
	speeds=$(grep 'Speed:' "$LOG" | tail -n +$((n0 + 1)) \
		| sed -n 's/.*Speed: \([0-9.]*\)%.*/\1/p' | tr '\n' ' ')
	renderer=$(grep -m1 -o 'Renderer: .*' "$LOG" | cut -c11-60)
	temp=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
	err=$(grep -m1 -i -E 'failed to load|could not|segmentation|aborted|fatal' "$LOG" | cut -c1-100)
	# A LibCrypt-protected PAL PS1 disc without its .sbi runs fine at first and
	# freezes later (CTR, 2026-10-19): it must not pass at the title screen.
	grep -a -q 'LibCrypt game detected with missing SBI' "$LOG" \
		&& err="LibCrypt: .sbi missing next to the .cue (game freezes later)"
	stop_ra $pid
	echo "RESULT|$sys|$rom|$alive|$speeds|$renderer|$temp|$err" >> "$OUT"
done < "$LIST"

/etc/init.d/S12launcher start >/dev/null 2>&1
cat "$OUT"
