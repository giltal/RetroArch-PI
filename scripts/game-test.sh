#!/bin/bash
#
# Game tests: play each game in scripts/game-tests.txt from its slot-10 save
# state with a virtual DualShock 3, and check it is alive, not black, not
# frozen, at speed and making sound. Run inside WSL:
#
#   wsl bash /mnt/c/RetroArch_PI/scripts/game-test.sh <board> [name-filter]
#
# The TV shows every test. The board must be reachable over SSH, with no game
# running; the launcher is stopped for the run and restarted afterwards.
# Screenshots and logs are copied to <work>/game-tests/<date-time>/<n>/.
#
# Verdicts (per game):
#   FAIL  RetroArch died, the state did not load, every screenshot is black,
#         the picture never changed while the pad played, speed mean < 80%,
#         or the core produced only digital silence
#   WARN  speed mean 80-95%, a black or unchanged screenshot here and there,
#         or very quiet sound (RMS below -60 dBFS)
#   PASS  everything else
set -eo pipefail
PROJ=$(cd "$(dirname "$0")/.." && pwd)
. "$PROJ/scripts/boards.sh" "${1:-}"
FILTER=${2:-}
BOARD_IP=$(cat "$BOARD_WORK/board_ip")
O=(-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 -i ~/.ssh/retroopi_ed25519)
rsh() { ssh "${O[@]}" "root@$BOARD_IP" "$@"; }
RES=$BOARD_WORK/game-tests/$(date +%Y%m%d-%H%M%S)
mkdir -p "$RES"

grep -v -E '^\s*(#|$)' "$PROJ/scripts/game-tests.txt" | { [ -n "$FILTER" ] && grep -i -- "$FILTER" || cat; } > "$RES/list.txt" || true
[ -s "$RES/list.txt" ] || { echo "game-test: no tests match '$FILTER'"; exit 1; }
echo "game-test: $(wc -l < "$RES/list.txt") test(s) on $BOARD_NAME -- the TV shows each game"

scp -O "${O[@]}" "$PROJ/scripts/game-test-board.sh" "$RES/list.txt" "root@$BOARD_IP:/tmp/" >/dev/null
# If interrupted here, stop the board-side run too (it restarts the launcher).
# BusyBox has no pkill: kill the board-side script through ps.
trap 'rsh "ps | grep \"[g]ame-test-board\" | while read p rest; do kill \$p; done; killall inject-pad retroarch.bin; sleep 2; /etc/init.d/S12launcher start" >/dev/null 2>&1; exit 130' INT TERM
rsh "sed -i 's/\r\$//' /tmp/game-test-board.sh /tmp/list.txt; SHOT_EVERY=${SHOT_EVERY:-0} sh /tmp/game-test-board.sh /tmp/list.txt /tmp/game-test" > "$RES/board.txt" 2>&1 || true
trap - INT TERM
rsh "cd /tmp && tar cf - game-test" | tar -C "$RES" -xf -

printf '\n%-34s %-7s %-9s %-26s %-16s %s\n' GAME VERDICT SPEED PICTURE SOUND NOTES
for d in "$RES"/game-test/*/; do
	r=$(cat "$d/result.txt")
	IFS='|' read -r kind sys rom alive loaded speeds levels renderer temp err <<< "$r"
	name=$(basename "$rom"); name=${name%.*}; name=${name:0:33}
	if [ "$kind" = SKIP ]; then printf '%-34s %-7s %s\n' "$name" SKIP "$alive"; continue; fi
	settle=$(awk -F'|' -v r="$rom" '$3 == r { print $4; exit }' "$RES/list.txt")
	# Speed windows are ~5 s from RetroArch's start: skip the ones before the
	# sequence (settle time + ~4 s for the PS + L1 state load).
	skip=$(( (${settle:-10} + 4) / 5 ))
	read -r -a sp <<< "$speeds"; read -r -a lv <<< "$levels"
	sp=("${sp[@]:$skip}"); lv=("${lv[@]:$skip}")
	mean=$(printf '%s\n' "${sp[@]}" | awk 'NF { s += $1; n++ } END { if (n) printf "%.1f", s / n; else print "" }')
	rmsmax=$(printf '%s\n' "${lv[@]}" | awk -F/ 'NF { if ($1 > m || m == "") m = $1 } END { print m }')
	# An array: the file names carry the game title, with spaces.
	shots=(); while IFS= read -r f; do shots+=("$f"); done < <(ls "$d"/shots/*.png 2>/dev/null | sort)
	stats=$( [ ${#shots[@]} -gt 0 ] && python3 -I "$PROJ/scripts/png-stats.py" "${shots[@]}" | tee "$d/png-stats.txt" || true)
	nshots=$(printf '%s\n' "$stats" | grep -c '^mean ' || true)
	black=$(printf '%s\n' "$stats" | awk '$1 == "mean" && $2 < 8 && $4 < 4' | wc -l)
	moving=$(printf '%s\n' "$stats" | awk '$1 == "mean" && $6 >= 1.0' | wc -l)
	frozen=$(printf '%s\n' "$stats" | awk '$1 == "mean" && $6 >= 0 && $6 < 1.0' | wc -l)
	verdict=PASS; notes=""
	warn() { [ "$verdict" = FAIL ] || verdict=WARN; notes="$notes $1;"; }
	fail() { verdict=FAIL; notes="$notes $1;"; }
	[ "$alive" = yes ] || fail "RetroArch exited"
	[ "$loaded" = yes ] || fail "slot-10 state did not load"
	[ "$nshots" -gt 0 ] || fail "no screenshots"
	[ "$nshots" -gt 0 ] && [ "$black" -eq "$nshots" ] && fail "black screen"
	[ "$black" -gt 0 ] && [ "$black" -lt "$nshots" ] && warn "$black black shot(s)"
	[ "$nshots" -gt 1 ] && [ "$moving" -eq 0 ] && fail "picture frozen"
	[ "$frozen" -gt 0 ] && [ "$moving" -gt 0 ] && warn "$frozen unchanged shot(s)"
	if [ -z "$mean" ]; then fail "no speed samples"
	elif awk -v m="$mean" 'BEGIN { exit !(m < 80) }'; then fail "speed $mean%"
	elif awk -v m="$mean" 'BEGIN { exit !(m < 95) }'; then warn "speed $mean%"; fi
	if [ -n "$rmsmax" ] && awk -v r="$rmsmax" 'BEGIN { exit !(r <= -99) }'; then fail "silent"
	elif [ -n "$rmsmax" ] && awk -v r="$rmsmax" 'BEGIN { exit !(r < -60) }'; then warn "very quiet ($rmsmax dBFS)"; fi
	# LibCrypt-protected PAL PS1 disc without its .sbi: runs, then freezes later.
	grep -a -q 'LibCrypt game detected with missing SBI' "$d/ra.log" 2>/dev/null \
		&& warn "LibCrypt: .sbi missing next to the .cue (game freezes later)"
	[ -n "$err" ] && notes="$notes log: $err;"
	printf '%-34s %-7s %-9s %-26s %-16s %s\n' "$name" "$verdict" "${mean:--}%" \
		"$nshots shots, $moving moving" "rms ${rmsmax:--} dB" "${notes# }"
done | tee "$RES/summary.txt"
echo
echo "results: $RES  (screenshots in */shots, logs in */ra.log, */pad.log)"
