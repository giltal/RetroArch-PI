#!/bin/bash
#
# Talk to the board over Ethernet + SSH. Run inside WSL:
#
#   wsl bash /mnt/c/RetroArch_PI/scripts/board.sh <board> <cmd> [args]
#
#   <board> is one of the names in scripts/boards.sh (zero3, k2b, rpi4).
#
#   status                 hostname, uptime, IP, what is running, temps, DRM/ALSA
#   push <path>...         copy target/ files (absolute board paths, e.g.
#                          /usr/bin/retroopi_launcher) from <work>/output/target,
#                          restarting the launcher around it; verifies md5
#   kernel                 install Image + DTB + extlinux.conf (from target/), keeping .prev copies
#   run <script> [args]    copy a local shell script over, strip CR, run it
#   ssh [cmd]              interactive shell, or one command
#
# Board address: $BOARD_IP, else <work>/board_ip (write the IP there once).
#
# Conventions carried over from the reference (RetroBPI_M2M scripts/):
#  - never touch the board while a game is running: a launcher restart under
#    RetroArch loses the game, and pushing a core it has mapped crashes it
#  - print the board-side md5 next to the host-side md5. "scp succeeded" is not
#    the same as "the board is running the new file"
#  - host keys change on every reflash (dropbear regenerates them), so skip
#    known_hosts entirely
#  - dropbear has no sftp-server, so scp needs -O (legacy protocol)
set -eo pipefail

PROJ=$(cd "$(dirname "$0")/.." && pwd)
. "$PROJ/scripts/boards.sh" "${1:-}"
shift
BOARD_IP=${BOARD_IP:-$(cat "$BOARD_WORK/board_ip" 2>/dev/null || true)}
[ -n "$BOARD_IP" ] || { echo "board.sh: set BOARD_IP=<ip> or write it to $BOARD_WORK/board_ip" >&2; exit 1; }

KEY=~/.ssh/retroopi_ed25519
O=(-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
   -o ConnectTimeout=10 -o LogLevel=ERROR)
[ -f "$KEY" ] && O+=(-i "$KEY")

T=$BOARD_WORK/output/target
I=$BOARD_WORK/output/images

rsh()  { ssh "${O[@]}" "root@$BOARD_IP" "$@"; }
rcp()  { scp -O "${O[@]}" "$@"; }

game_running() {
	[ "$(rsh 'pidof retroarch.bin >/dev/null && echo y || echo n')" = y ]
}

cmd=${1:-status}; shift || true
case "$cmd" in
status)
	rsh '
	echo "host    : $(hostname)  $(uname -r)"
	echo "uptime  : $(cut -d" " -f1 /proc/uptime) s"
	echo "ip      : $(ip -4 -o addr show eth0 2>/dev/null | awk "{print \$4}")"
	echo "launcher: $(pidof retroopi_launcher >/dev/null && echo running || echo NOT running)"
	echo "game    : $(pidof retroarch.bin >/dev/null && echo running || echo none)"
	echo "governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null) @ $(( $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo 0) / 1000 )) MHz"
	for z in /sys/class/thermal/thermal_zone*; do
		[ -r $z/temp ] && echo "thermal : $(cat $z/type) $(( $(cat $z/temp) / 1000 )) C"
	done
	for c in /sys/class/drm/card*-*; do
		[ -r $c/status ] && echo "drm     : ${c##*/} $(cat $c/status) $(head -1 $c/modes 2>/dev/null)"
	done
	echo "alsa    :"; sed "s/^/          /" /proc/asound/cards 2>/dev/null
	echo "gpu     : $(ls /sys/class/devfreq 2>/dev/null | tr "\n" " ")"
	[ -f /run/boottiming ] && echo "boot    : rcS done at $(sed -n "s/^end //p" /run/boottiming) s"
	'
	;;
push)
	[ $# -gt 0 ] || { echo "usage: board.sh push /board/path..." >&2; exit 1; }
	if game_running; then echo "ABORT: a game is running on the board."; exit 2; fi
	for p in "$@"; do
		[ -f "$T$p" ] || { echo "not in target/: $p" >&2; exit 1; }
		rcp "$T$p" "root@$BOARD_IP:/tmp/push.$$.$(basename "$p")"
	done
	rsh "/etc/init.d/S12launcher stop >/dev/null 2>&1 || true"
	# Write next to the target, sync, then rename over it. A rename is atomic,
	# so a power cut leaves the old file or the new one. A cp straight onto
	# the target truncates it first, and that is how flycast_libretro.so was
	# found EMPTY (md5 d41d8cd9...) after an unclean power-off.
	# The mode is copied from target/ too: scp lands files as 0700, which once
	# left /usr/bin/retroarch at 700 instead of the build's 755.
	for p in "$@"; do
		m=$(stat -c %a "$T$p")
		rsh "cp '/tmp/push.$$.$(basename "$p")' '$p.new' && chmod $m '$p.new' && sync && mv '$p.new' '$p' && rm -f '/tmp/push.$$.$(basename "$p")'"
	done
	rsh "sync; /etc/init.d/S12launcher start >/dev/null 2>&1"
	for p in "$@"; do
		b=$(rsh "md5sum '$p'" | cut -d' ' -f1)
		h=$(md5sum "$T$p" | cut -d' ' -f1)
		[ "$b" = "$h" ] && echo "OK       $p  $b" || { echo "MISMATCH $p  board $b host $h"; exit 1; }
	done
	;;
kernel)
	if game_running; then echo "ABORT: a game is running on the board."; exit 2; fi
	# The Pi boots its kernel from the FAT boot partition (p1), not from the
	# rootfs's /boot: a different install, written with its first boot.
	[ "$BOARD_BOOT" = extlinux ] || { echo "board.sh: kernel install for BOARD_BOOT=$BOARD_BOOT is not written yet" >&2; exit 1; }
	DTB=$BOARD_DTB
	# Keep the last known-good set, so a bad kernel is recoverable from the
	# U-Boot prompt on the serial console instead of by reflashing the card.
	rsh "cd /boot && cp -n Image Image.prev && cp -n $DTB $DTB.prev && cp -n extlinux/extlinux.conf extlinux/extlinux.conf.prev; [ -f Image.lz4 ] && cp -n Image.lz4 Image.lz4.prev; true"
	# extlinux.conf boots Image.lz4 and falls back to Image (see post-build.sh,
	# which makes the image build's copy the same way).
	LZ4="$BOARD_WORK/output/host/bin/lz4"; [ -x "$LZ4" ] || LZ4=$(command -v lz4)
	"$LZ4" -9 -f -q "$I/Image" "$I/Image.lz4"
	rcp "$I/Image.lz4" "root@$BOARD_IP:/boot/Image.lz4.new"
	rcp "$I/Image" "root@$BOARD_IP:/boot/Image.new"
	rcp "$I/$DTB" "root@$BOARD_IP:/boot/$DTB.new"
	rcp "$T/boot/extlinux/extlinux.conf" "root@$BOARD_IP:/boot/extlinux/extlinux.conf.new"
	# Modules must match the kernel they were built with: a config change can
	# add, remove or alter modules. Replace the tree wholesale.
	KV=$(ls "$T/lib/modules" | head -1)
	echo "modules: /lib/modules/$KV"
	tar -C "$T/lib/modules" -cf - "$KV" | rsh "set -e; rm -rf /lib/modules/$KV.new; mkdir -p /lib/modules/$KV.new
		tar -C /lib/modules/$KV.new -xf -
		rm -rf /lib/modules/$KV.prev; [ -d /lib/modules/$KV ] && mv /lib/modules/$KV /lib/modules/$KV.prev
		mv /lib/modules/$KV.new/$KV /lib/modules/$KV; rmdir /lib/modules/$KV.new"
	rsh "set -e; cd /boot
		sed -i 's/\r\$//' extlinux/extlinux.conf.new
		grep -q '^ *kernel /boot/Image' extlinux/extlinux.conf.new
		grep -q 'root=/dev/mmcblk0p1' extlinux/extlinux.conf.new
		mv Image.new Image; mv Image.lz4.new Image.lz4; mv $DTB.new $DTB; mv extlinux/extlinux.conf.new extlinux/extlinux.conf
		sync
		echo \"board Image: \$(md5sum Image | cut -d' ' -f1)  Image.lz4: \$(md5sum Image.lz4 | cut -d' ' -f1)\""
	echo "host  Image: $(md5sum "$I/Image" | cut -d' ' -f1)  Image.lz4: $(md5sum "$I/Image.lz4" | cut -d' ' -f1)"
	echo "Reboot to use it. Fallback: Image.prev / $DTB.prev / extlinux.conf.prev"
	;;
run)
	[ -f "${1:-}" ] || { echo "usage: board.sh run <script> [args]" >&2; exit 1; }
	s=$1; shift
	rcp "$s" "root@$BOARD_IP:/tmp/run.sh"
	rsh "sed -i 's/\r\$//' /tmp/run.sh && sh /tmp/run.sh $*"
	;;
ssh)
	if [ $# -eq 0 ]; then ssh "${O[@]/BatchMode=yes/BatchMode=no}" "root@$BOARD_IP"; else rsh "$@"; fi
	;;
*)
	sed -n '3,15p' "$0"; exit 1
	;;
esac
