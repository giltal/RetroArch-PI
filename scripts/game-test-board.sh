#!/bin/sh
# Runs ON THE BOARD (BusyBox sh). Started by scripts/game-test.sh.
#
#   game-test-board.sh <test list> <out dir>
#
# For each test: start the virtual pad (inject-pad), then RetroArch exactly as
# the launcher does, with the virtual pad as player 1; the pad loads save-state
# slot 10 (PS + L1) and plays the sequence, while SIGUSR1 every 2 s takes a
# screenshot (RetroArch patch 0009). The launcher is stopped for the run and
# restarted at the end, also when interrupted.
#
# Per test, in <out dir>/<n>/: shots/*.png, pad.log, ra.log (the RetroArch log
# of that run), result.txt:
#   RESULT|system|rom|alive|state_loaded|speeds|levels|renderer|temp_mC|error
LIST=$1
OUT=${2:-/tmp/game-test}
ROMS=/opt/roms
CORES=/usr/lib/libretro
LOG=/tmp/retroarch_verbose.log
STATES=$ROMS/_system/states

cleanup() {
	killall inject-pad 2>/dev/null
	killall retroarch.bin 2>/dev/null; sleep 2; killall -9 retroarch.bin 2>/dev/null
	/etc/init.d/S12launcher start >/dev/null 2>&1
}
trap 'cleanup; exit 130' INT TERM HUP

pidof retroarch.bin >/dev/null && { echo "ABORT: a game is running"; exit 2; }
/etc/init.d/S12launcher stop >/dev/null 2>&1
sleep 1
rm -rf "$OUT"; mkdir -p "$OUT"
n=0
while IFS='|' read -r sys core rom settle seq; do
	case "$sys" in ''|'#'*) continue ;; esac
	n=$((n + 1)); d="$OUT/$n"; mkdir -p "$d/shots"
	path="$ROMS/$sys/$rom"
	if [ -d "$path" ]; then
		path=$(ls "$path"/*.gdi "$path"/*.cue "$path"/*.m3u 2>/dev/null | head -1)
	fi
	if [ -z "$path" ] || [ ! -e "$path" ]; then
		echo "SKIP|$sys|$rom|rom missing" > "$d/result.txt"; continue
	fi
	base=$(basename "$path"); base=${base%.*}
	if ! ls "$STATES"/*/"$base.state10" >/dev/null 2>&1; then
		echo "SKIP|$sys|$rom|no slot-10 state" > "$d/result.txt"; continue
	fi
	# Player 1 = the virtual pad. RetroArch numbers joypads in the order it
	# finds them, and the pad is created after any real one, so its index is
	# the number of joysticks already present. (Device reservation by name,
	# input_player1_reserved_device, did not take: the user's DS3 kept port 1.)
	njs=$(grep -c 'Handlers=.*js[0-9]' /proc/bus/input/devices)
	cat > /tmp/game-test.cfg <<EOF
input_player1_joypad_index = "$njs"
input_player2_joypad_index = "0"
state_slot = "10"
screenshot_directory = "$d/shots"
auto_screenshot_filename = "true"
video_font_enable = "false"
notification_show_screenshot = "false"
notification_show_screenshot_flash = "0"
savestate_auto_load = "false"
EOF
	# The pad exists before RetroArch starts, so RetroArch enumerates it at
	# startup. After the settle time it loads slot 10 the way a player does,
	# PS + L1 (state_slot is 10 in the test config), waits for the load, then
	# plays the sequence. Not "retroarch -e 10": that loads the state when the
	# content loads, which Flycast (it loads its own disc) cannot do before
	# its first frame, and it fails silently.
	# shellcheck disable=SC2086 -- seq is a list of steps
	inject-pad -s $(( (settle + 1) * 1000 )) PS+L1:0.3 WAIT:3 $seq > "$d/pad.log" 2>&1 &
	padpid=$!
	sleep 1
	: > "$LOG"
	/usr/bin/retroarch --appendconfig=/tmp/game-test.cfg -L "$CORES/$core" "$path" </dev/null >/dev/null 2>&1 &
	ra=$!
	sleep $(( settle + 4 ))
	# Screenshots every 2 s while the pad plays the sequence, one at its start.
	pidof retroarch.bin >/dev/null && kill -USR1 $(pidof retroarch.bin) 2>/dev/null
	while kill -0 $padpid 2>/dev/null; do
		sleep 2
		pidof retroarch.bin >/dev/null && kill -USR1 $(pidof retroarch.bin) 2>/dev/null
	done
	sleep 1
	alive=no; pidof retroarch.bin >/dev/null && alive=yes
	# The last screenshot needs time to be written before RetroArch is stopped.
	[ "$alive" = yes ] && kill -USR1 $(pidof retroarch.bin) 2>/dev/null && sleep 3
	killall retroarch.bin 2>/dev/null
	i=0; while kill -0 $ra 2>/dev/null && [ $i -lt 10 ]; do sleep 1; i=$((i + 1)); done
	killall -9 retroarch.bin 2>/dev/null
	cp "$LOG" "$d/ra.log"
	loaded=no; grep -a -q 'Loading state.*state10' "$LOG" && ! grep -a -q 'Failed to load state' "$LOG" && loaded=yes
	speeds=$(grep -a 'Speed:' "$LOG" | sed -n 's/.*Speed: *\([0-9.]*\)%.*/\1/p' | tr '\n' ' ')
	levels=$(grep -a 'Speed:' "$LOG" | sed -n 's/.*level rms \([-0-9.]*\) peak \([-0-9.]*\) dBFS.*/\1\/\2/p' | tr '\n' ' ')
	renderer=$(grep -a -m1 -o 'Renderer: .*' "$LOG" | cut -c11-60)
	temp=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
	err=$(grep -a -m1 -i -E 'failed to load content|could not|segmentation|aborted|fatal' "$LOG" | cut -c1-100)
	echo "RESULT|$sys|$rom|$alive|$loaded|$speeds|$levels|$renderer|$temp|$err" > "$d/result.txt"
	sleep 2
done < "$LIST"
cleanup
cat "$OUT"/*/result.txt
