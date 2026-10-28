#!/bin/bash
#
# Update a BCM2711 board's EEPROM bootloader over SSH, the way rpi-eeprom-update
# does it: the Raspberry Pi 4, or the CM4 in the GPi Case 2 (same images,
# firmware-2711). Run inside WSL:
#
#   wsl bash /mnt/c/RetroArch_PI/scripts/rpi4-eeprom.sh [board]            # fetch + prepare, show the config
#   wsl bash /mnt/c/RetroArch_PI/scripts/rpi4-eeprom.sh [board] install    # ...then write it to the board
#
# [board] is rpi4 (the default) or gpicase2; the config is
# board/<board>/eeprom-bootconf.txt. A CM4 Lite boots from its SD card, so the
# boot ROM runs recovery.bin from p1 exactly as on the Pi 4.
#
# This changes the BOARD, not the card: ask the user first, every time.
#
# What it does:
#  1. Downloads the pinned release from github.com/raspberrypi/rpi-eeprom (one
#     commit, the stable "default" channel) into ~/rpi4/eeprom/<commit>/, and
#     checks each file's git blob SHA against the values below.
#  2. Makes pieeprom.upd = that image with board/rpi4/eeprom-bootconf.txt as its
#     config (rpi-eeprom-config, run on the host), pieeprom.sig (sha256 + ts),
#     and takes recovery.bin from the same release.
#  3. install: copies the three to the FAT boot partition (p1, md5-checked) and
#     reboots. The boot ROM runs recovery.bin, which writes and verifies the
#     EEPROM, renames itself RECOVERY.000 and reboots. The script then checks
#     /proc/device-tree/chosen/bootloader/update-timestamp == the .sig's ts, and
#     removes the update files from p1.
# If power fails mid-update, the ROM runs recovery.bin again at the next power-on.
# Last resort: a "Bootloader" recovery card from Raspberry Pi Imager.
#
# Done once, 2026-10-18: build-timestamp 63bef4a4 (2023-01) -> 6ab3bfc6.
set -eo pipefail

COMMIT=7ed1cc2b210053b5d6537b2beb542663cab7e10b     # rpi-eeprom master, 2026-10-15
IMAGE=firmware-2711/default/pieeprom-2026-09-23.bin
# path  size  git-blob-sha (prefix), from the GitHub contents API at $COMMIT
FILES="
$IMAGE 524288 433d88ec77c6
firmware-2711/default/recovery.bin 101246 e03c104dc350
rpi-eeprom-config 26657 02f01b211dbf
"
PROJ=$(cd "$(dirname "$0")/.." && pwd)
B=rpi4
if [ -n "${1:-}" ] && [ "$1" != install ]; then B=$1; shift; fi
CONF=$PROJ/buildroot-external/board/$B/eeprom-bootconf.txt
[ -f "$CONF" ] || { echo "rpi4-eeprom: no $CONF" >&2; exit 1; }
. "$PROJ/scripts/boards.sh" "$B"
[ "$BOARD_BOOT" = rpi ] || { echo "rpi4-eeprom: $B does not boot through the Pi firmware" >&2; exit 1; }
S=$BOARD_WORK/eeprom/$COMMIT
U=$BOARD_WORK/eeprom/upd

mkdir -p "$S"
# The release files are the same for every board: reuse the Pi 4's verified
# copies instead of downloading them again (still checked below).
[ "$B" = rpi4 ] || cp -n ~/rpi4/eeprom/$COMMIT/* "$S/" 2>/dev/null || true
echo "$FILES" | while read -r p size blob; do
	[ -n "$p" ] || continue
	f=$S/$(basename "$p")
	[ -s "$f" ] || curl -sfL -o "$f" "https://raw.githubusercontent.com/raspberrypi/rpi-eeprom/$COMMIT/$p"
	s=$(stat -c %s "$f"); b=$( (printf 'blob %d\0' "$s"; cat "$f") | sha1sum | cut -c1-12)
	[ "$s" = "$size" ] && [ "$b" = "$blob" ] || { echo "rpi4-eeprom: $p: size $s blob $b, expected $size $blob" >&2; exit 1; }
done

rm -rf "$U"; mkdir -p "$U"
python3 -I "$S/rpi-eeprom-config" --config "$CONF" --out "$U/pieeprom.upd" "$S/$(basename $IMAGE)"
{ sha256sum "$U/pieeprom.upd" | awk '{print $1}'; echo "ts: $(date -u +%s)"; } > "$U/pieeprom.sig"
cp "$S/recovery.bin" "$U/recovery.bin"
echo "== $(basename $IMAGE), config:"; python3 -I "$S/rpi-eeprom-config" "$U/pieeprom.upd"
[ "${1:-}" = install ] || { echo "(not installed; run with 'install' to write it to the Pi)"; exit 0; }

BOARD_IP=$(cat "$BOARD_WORK/board_ip")
O=(-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 -i ~/.ssh/retroopi_ed25519)
r() { ssh "${O[@]}" "root@$BOARD_IP" "$@"; }
r 'pidof retroarch.bin >/dev/null && { echo "ABORT: a game is running"; exit 2; } || true'
echo "before: build-timestamp $(r 'od -A n -t x1 /proc/device-tree/chosen/bootloader/build-timestamp' | tr -d ' ')"
r 'mkdir -p /run/bootfs; grep -q " /run/bootfs " /proc/mounts || mount -t vfat /dev/mmcblk0p1 /run/bootfs; rm -f /run/bootfs/RECOVERY.000'
scp -O "${O[@]}" "$U/pieeprom.upd" "$U/pieeprom.sig" "$U/recovery.bin" "root@$BOARD_IP:/run/bootfs/"
for f in pieeprom.upd pieeprom.sig recovery.bin; do
	[ "$(md5sum "$U/$f" | cut -d' ' -f1)" = "$(r "md5sum /run/bootfs/$f" | cut -d' ' -f1)" ] \
		|| { echo "MISMATCH $f -- update withdrawn"; r 'rm -f /run/bootfs/recovery.bin; sync'; exit 1; }
done
r 'sync; cd /; umount /run/bootfs; sync; reboot'
echo "rebooting into the update; waiting for SSH"
sleep 20
for i in $(seq 1 36); do r true 2>/dev/null && break; sleep 5; done
sleep 10
ts=$(sed -n 's/^ts: //p' "$U/pieeprom.sig")
got=$(( 0x$(r 'od -A n -t x1 /proc/device-tree/chosen/bootloader/update-timestamp' | tr -d ' \n') ))
echo "after:  build-timestamp $(r 'od -A n -t x1 /proc/device-tree/chosen/bootloader/build-timestamp' | tr -d ' ')  update-timestamp $got (sig ts $ts)"
[ "$got" = "$ts" ] || { echo "rpi4-eeprom: the update did not apply (update-timestamp $got != $ts)" >&2; exit 1; }
r 'mkdir -p /run/bootfs; mount -t vfat /dev/mmcblk0p1 /run/bootfs && rm -f /run/bootfs/RECOVERY.000 /run/bootfs/pieeprom.upd /run/bootfs/pieeprom.sig && sync; umount /run/bootfs'
echo "EEPROM updated; update files removed from p1"
