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

# Modules must match the kernel they were built with: a config change can
# add, remove or alter modules. Replace the tree wholesale (board.sh kernel).
install_modules() {
	KV=$(ls "$T/lib/modules" | head -1)
	echo "modules: /lib/modules/$KV"
	tar -C "$T/lib/modules" -cf - "$KV" | rsh "set -e; rm -rf /lib/modules/$KV.new; mkdir -p /lib/modules/$KV.new
		tar -C /lib/modules/$KV.new -xf -
		rm -rf /lib/modules/$KV.prev; [ -d /lib/modules/$KV ] && mv /lib/modules/$KV /lib/modules/$KV.prev
		mv /lib/modules/$KV.new/$KV /lib/modules/$KV; rmdir /lib/modules/$KV.new"
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
	# The copies in /tmp are numbered, not named: scp's remote path goes
	# through a shell, and names have spaces and parentheses
	# ("Sony PLAYSTATION(R)3 Controller.cfg").
	i=0
	for p in "$@"; do
		[ -f "$T$p" ] || { echo "not in target/: $p" >&2; exit 1; }
		i=$((i + 1))
		rcp "$T$p" "root@$BOARD_IP:/tmp/push.$$.$i"
	done
	rsh "/etc/init.d/S12launcher stop >/dev/null 2>&1 || true"
	# Write next to the target, sync, then rename over it. A rename is atomic,
	# so a power cut leaves the old file or the new one. A cp straight onto
	# the target truncates it first, and that is how flycast_libretro.so was
	# found EMPTY (md5 d41d8cd9...) after an unclean power-off.
	# The mode is copied from target/ too: scp lands files as 0700, which once
	# left /usr/bin/retroarch at 700 instead of the build's 755.
	# mkdir -p: a file new in this build may live in a folder the board lacks.
	i=0
	for p in "$@"; do
		i=$((i + 1))
		m=$(stat -c %a "$T$p")
		rsh "mkdir -p \"\$(dirname '$p')\" && cp '/tmp/push.$$.$i' '$p.new' && chmod $m '$p.new' && sync && mv '$p.new' '$p' && rm -f '/tmp/push.$$.$i'"
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
	DTB=$BOARD_DTB
	if [ "$BOARD_BOOT" = rpi ]; then
		# The Pi's firmware loads the kernel, DTB, config.txt and cmdline.txt
		# from the FAT boot partition (p1), which is not mounted at runtime.
		# Mount it, keep the last known-good set as *.prev, write *.new, sync,
		# then rename over. Overlays are left alone (they come with the
		# firmware package, not the kernel).
		# The *.prev set stays on the FAT partition when it fits (recoverable
		# from a PC: rename the files back); the first Pi 4 images had a 64 MiB
		# boot partition, where Image + Image.prev + Image.new (3 x 29 MB) do
		# not fit, and there it goes to /root/bootfs.prev on the rootfs instead
		# (recoverable over SSH or the serial console only).
		F=$I/rpi-firmware
		# The kernel file is whatever the new config.txt names (Image, Image.gz).
		# The previous set is the kernel the card's CURRENT config.txt names,
		# plus DTB, config.txt and cmdline.txt; when the name changes, the old
		# kernel goes into the previous set and then off p1.
		K=$(sed -n 's/^kernel=//p' "$F/config.txt")
		[ -n "$K" ] && [ -s "$I/$K" ] || { echo "board.sh: config.txt kernel=$K, not in $I" >&2; exit 1; }
		ksize=$(( $(stat -c %s "$I/$K") / 1024 ))
		rsh "set -e; mkdir -p /run/bootfs; grep -q ' /run/bootfs ' /proc/mounts || mount -t vfat /dev/mmcblk0p1 /run/bootfs
			cd /run/bootfs; rm -f *.new
			oldk=\$(sed -n 's/^kernel=//p' config.txt)
			free=\$(df -k /run/bootfs | awk 'NR==2 {print \$4}')
			oldsize=\$(( \$(wc -c < \$oldk) / 1024 ))
			# Room for the old kernel's .prev copy AND the new kernel's .new, plus 4 MiB.
			if ls *.prev >/dev/null 2>&1 || [ \"\$free\" -gt \$((oldsize + $ksize + 4096)) ]; then
				for f in \$oldk $DTB config.txt cmdline.txt; do [ -f \$f.prev ] || cp \$f \$f.prev; done
				echo 'previous set: *.prev on the FAT boot partition'
			else
				rm -rf /root/bootfs.prev; mkdir -p /root/bootfs.prev
				for f in \$oldk $DTB config.txt cmdline.txt; do cp \$f /root/bootfs.prev/\$f; done
				sync
				echo \"previous set: /root/bootfs.prev (\$oldk; no room for it on the FAT partition)\"
			fi"
		rcp "$I/$K" "root@$BOARD_IP:/run/bootfs/$K.new"
		rcp "$I/$DTB" "root@$BOARD_IP:/run/bootfs/$DTB.new"
		rcp "$F/config.txt" "root@$BOARD_IP:/run/bootfs/config.txt.new"
		rcp "$F/cmdline.txt" "root@$BOARD_IP:/run/bootfs/cmdline.txt.new"
		install_modules
		rsh "set -e; cd /run/bootfs
			grep -q '^kernel=$K\$' config.txt.new
			grep -q 'root=/dev/mmcblk0p2 ' cmdline.txt.new
			oldk=\$(sed -n 's/^kernel=//p' config.txt)
			sync
			for f in $K $DTB config.txt cmdline.txt; do mv -f \$f.new \$f; done
			sync
			[ \"\$oldk\" = $K ] || { rm -f \"\$oldk\"; echo \"removed the old kernel \$oldk from p1 (it is in the previous set)\"; }
			echo \"board $K: \$(md5sum $K | cut -d' ' -f1)  $DTB: \$(md5sum $DTB | cut -d' ' -f1)\"
			cd /; umount /run/bootfs"
		echo "host  $K: $(md5sum "$I/$K" | cut -d' ' -f1)  $DTB: $(md5sum "$I/$DTB" | cut -d' ' -f1)"
		echo "Reboot to use it. Previous set: see 'previous set:' above (*.prev on the FAT partition, or /root/bootfs.prev)"
		exit 0
	fi
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
	install_modules
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
