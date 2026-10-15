# Board table, sourced by build.sh and board.sh:  . boards.sh <board>
#
# Each board has its own WSL work directory (Buildroot clone, O= output, build
# log, board IP). Buildroot outputs are not relocatable, so these names are
# fixed once a board has been built. All boards share the download cache
# ~/bpi/dl.
#
#   BOARD_DEFCONFIG  buildroot-external/configs/<name>
#   BOARD_WORK       WSL work directory: buildroot/, output/, build.log, board_ip
#   BOARD_DTB        DTB name in /boot (board.sh kernel)

BOARDS="zero3 k2b"

case "${1:-}" in
	zero3)
		BOARD_NAME="Orange Pi Zero3"
		BOARD_DEFCONFIG=opi_zero3_retro_defconfig
		BOARD_WORK=~/zero3
		BOARD_DTB=sun50i-h618-orangepi-zero3.dtb
		;;
	k2b)
		BOARD_NAME="KickPi K2B V2.2"
		BOARD_DEFCONFIG=kickpi_k2b_retro_defconfig
		BOARD_WORK=~/k2b
		BOARD_DTB=sun50i-h618-kickpi-k2b.dtb
		;;
	*)
		echo "unknown board '${1:-}' -- one of: $BOARDS" >&2
		return 1 2>/dev/null || exit 1
		;;
esac
BOARD="$1"
