#!/bin/sh
# Self-checking all-core CPU stress test. Runs ON THE BOARD (BusyBox sh):
#
#   scripts/board.sh <board> run scripts/cpu-stress.sh ref        # at the old, trusted clock
#   scripts/board.sh <board> run scripts/cpu-stress.sh run [min]  # at the clock under test
#
# ref: writes a 48 MB random file and its md5 + sha256 to /root (kept across
#      reboots, so the references come from the clock you trust).
# run: 4 workers hash a tmpfs copy of that file in a loop for [min] minutes
#      (default 10) and compare every result with the references; a wrong hash
#      means the CPU computed something wrong at this clock/voltage. Logs the
#      CPU frequency, the hottest thermal zone and the cooling state every 30 s.
# Pass: 0 mismatches, the target frequency held all the time, temperatures
# below the 80 C passive trip. Method from the Zero3's 1512 MHz work
# (docs/log/opi-zero3.md).
F=/root/stress.bin
R=/root/stress.ref
MODE=${1:-run}
MIN=${2:-10}
CPU=/sys/devices/system/cpu/cpu0/cpufreq

hottest() {
	max=0
	for z in /sys/class/thermal/thermal_zone*/temp; do
		t=$(cat "$z" 2>/dev/null) || continue
		[ "$t" -gt "$max" ] && max=$t
	done
	echo $((max / 1000))
}

case "$MODE" in
ref)
	dd if=/dev/urandom of=$F bs=1M count=48 2>/dev/null
	cp $F /tmp/stress.bin
	{ md5sum < /tmp/stress.bin; sha256sum < /tmp/stress.bin; } > $R
	sync
	echo "ref: taken at $(cat $CPU/scaling_cur_freq) kHz (max $(cat $CPU/scaling_max_freq))"
	cat $R
	;;
run)
	[ -f $F ] && [ -f $R ] || { echo "run 'ref' first"; exit 1; }
	cp $F /tmp/stress.bin
	ref=$(cat $R)
	end=$(( $(date +%s) + MIN * 60 ))
	echo "run: $MIN min, 4 workers; available: $(cat $CPU/scaling_available_frequencies)"
	for w in 1 2 3 4; do
		(
			r=0; bad=0
			while [ "$(date +%s)" -lt $end ]; do
				got=$(md5sum < /tmp/stress.bin; sha256sum < /tmp/stress.bin)
				[ "$got" = "$ref" ] || bad=$((bad + 1))
				r=$((r + 1))
			done
			echo "worker $w: $r rounds, $bad mismatches"
		) &
	done
	maxt=0; low=0; n=0
	while [ "$(date +%s)" -lt $end ]; do
		sleep 30
		f=$(cat $CPU/scaling_cur_freq); t=$(hottest)
		cs=$(cat /sys/class/thermal/cooling_device*/cur_state 2>/dev/null | tr '\n' ' ')
		echo "  $(( (end - $(date +%s)) / 60 )) min left: $f kHz, hottest zone $t C, cooling state [$cs]"
		[ "$t" -gt "$maxt" ] && maxt=$t
		[ "$f" -lt "$(cat $CPU/scaling_max_freq)" ] && low=$((low + 1))
		n=$((n + 1))
	done
	wait
	echo "summary: peak $maxt C; $low of $n samples below the max frequency ($(cat $CPU/scaling_max_freq) kHz)"
	rm -f /tmp/stress.bin
	;;
*)
	echo "usage: $0 ref | run [minutes]"; exit 1 ;;
esac
