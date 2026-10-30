#!/bin/sh
# ONE IMAGE FOR EVERY H700 BOARD (Dan 2026-10-30). The card carries each board's boot files under
# /opt/minui-zero/boards/<board>/ (boot0.img, package.fex, device.tar.gz, and kernel: its name in boards/kernels/) and boots one screen
# type at a time. Each board's panel is set up by its own boot package, so a picker shown under the wrong
# board's package may be dark. Run by minui-frontend.sh until a model is chosen:
#   1. ask which model this is, among the boards that share the screen type installed now (boardpick.elf);
#   2. no choice in time (a dark or garbled screen): install the NEXT screen type's boot files and reboot,
#      so a dark screen moves on by itself and wraps around after the last type;
#   3. a choice: install that board's own full boot set (including its boot0) and its device files, reboot.
# RAM: boot0 decides whether the board reaches Linux at all, so the screen types are cycled under ONE boot0, the
# universal one the image ships (the LPDDR3-primary strap-selecting build: booted LPDDR4 on the RG35XX H,
# LPDDR3 by construction). Only the final choice writes the board's own boot0.
# Every write goes to the SD card, never the handheld: a power cut mid-write costs a reflash, nothing more.
# Exit 0 = the model is chosen (or was already), carry on booting. Otherwise this does not return (reboot).

B=/opt/minui-zero/boards
CHOSEN=$B/chosen      # the board name, once picked
TRYING=$B/trying      # index of the screen type installed now
LOG=/mnt/mmc/.userdata/h700/logs/boardpick.txt
mkdir -p "$(dirname "$LOG")"
log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

[ -f "$CHOSEN" ] && exit 0
[ -d "$B" ] || exit 0  # a single-board image: nothing to pick

# Screen types in try order: id list, then "id label" pairs for the picker. The first id of each type is the
# board whose boot files stand in for the type while it is tried. Plus first: the image ships its boot files.
TYPES="
rg35xx-plus rg35xx-h rg35xx-pro
rg35xx-sp
rg40xx-h rg40xx-v
rgcubexx-h
rg28xx-h
rg34xx-h
rg34xx-sp rgsp
"
label() {
	case "$1" in
		rg35xx-plus) echo "RG35XX Plus / 2024" ;;
		rg35xx-h) echo "RG35XX H" ;;
		rg35xx-pro) echo "RG35XX Pro" ;;
		rg35xx-sp) echo "RG35XX SP" ;;
		rg40xx-h) echo "RG40XX H" ;;
		rg40xx-v) echo "RG40XX V" ;;
		rgcubexx-h) echo "RG CubeXX" ;;
		rg28xx-h) echo "RG28XX" ;;
		rg34xx-h) echo "RG34XX" ;;
		rg34xx-sp) echo "RG34XX SP" ;;
		rgsp) echo "RG SP" ;;
	esac
}
NTYPES=$(echo "$TYPES" | grep -c .)
type_line() { echo "$TYPES" | grep . | sed -n "$(($1 + 1))p"; }

# The card. Prove mmcblk0 is the card we booted from before writing anything, as expand-roms.sh does (these
# boards have a second slot): the running root must be mmcblk0p5, compared by device number. Then check the
# layout the offsets below assume: p4 at 188416 and a boot0 at 8 KiB. Any doubt: pick nothing, write nothing.
DISK=/dev/mmcblk0
P4=/dev/mmcblk0p4
check_layout() {
	_root=$(awk '$5 == "/" {d = $3} END {print d}' /proc/self/mountinfo 2>/dev/null)
	[ -n "$_root" ] && [ "$_root" = "$(cat /sys/block/mmcblk0/mmcblk0p5/dev 2>/dev/null)" ] || { log "root is ${_root:-unreadable}, not mmcblk0p5"; return 1; }
	[ -b "$DISK" ] && [ -b "$P4" ] || { log "no $DISK or $P4"; return 1; }
	[ "$(cat /sys/block/mmcblk0/mmcblk0p4/start 2>/dev/null)" = 188416 ] || { log "$P4 does not start at 188416"; return 1; }
	dd if="$DISK" bs=512 skip=16 count=1 2>/dev/null | head -c 12 | tail -c 8 | grep -q eGON.BT0 || { log "no boot0 at 8 KiB on $DISK"; return 1; }
	return 0
}

restart() { # the muOS way, which unmounts the card cleanly; plain reboot as the fallback
	sync
	/opt/muos/script/system/halt.sh reboot 2>/dev/null
	reboot -f
	sleep 30
}

# write <file> <device> <sector>: write, flush, drop the cache, read back and compare
write() {
	_len=$(wc -c < "$1")
	dd if="$1" of="$2" bs=512 seek="$3" conv=notrunc 2>>"$LOG" || return 1
	sync; echo 3 > /proc/sys/vm/drop_caches
	_want=$(md5sum < "$1" | cut -d ' ' -f 1)
	_got=$(dd if="$2" bs=512 skip="$3" count=$(( (_len + 511) / 512 )) 2>/dev/null | head -c "$_len" | md5sum | cut -d ' ' -f 1)
	[ "$_want" = "$_got" ] || { log "readback mismatch writing $1 to $2 at $3"; return 1; }
}

# install <board> [full]: the board's kernel, boot package and device files (and with "full" its own boot0)
install() {
	_d=$B/$1
	_k=$B/kernels/$(cat "$_d/kernel" 2>/dev/null)
	for _f in "$_d/package.fex" "$_d/device.tar.gz" "$_k"; do [ -f "$_f" ] || { log "missing $_f"; return 1; }; done
	gunzip -c "$_k" > /tmp/bp-kernel.img || return 1
	write /tmp/bp-kernel.img "$P4" 0 || return 1
	rm -f /tmp/bp-kernel.img
	write "$_d/package.fex" "$DISK" 32800 || return 1   # 16793600
	if [ "$2" = full ] && [ -f "$_d/boot0.img" ]; then
		write "$_d/boot0.img" "$DISK" 16 || return 1     # 8192
		write "$_d/boot0.img" "$DISK" 512 || return 1    # 262144
	fi
	rm -rf /opt/muos/device.new && mkdir -p /opt/muos/device.new &&
		tar -xzf "$_d/device.tar.gz" -C /opt/muos/device.new || return 1
	rm -rf /opt/muos/device && mv /opt/muos/device.new /opt/muos/device || return 1
	printf '%s\n' "${1#rg35xx-}" > /mnt/mmc/.system/h700/board
	sync
}

check_layout || { log "card layout not recognized, not picking a model"; exit 0; }

i=$(cat "$TRYING" 2>/dev/null || echo 0)
case "$i" in ''|*[!0-9]*) i=0 ;; esac
[ "$i" -lt "$NTYPES" ] || i=0
set --
for b in $(type_line "$i"); do set -- "$@" "$b" "$(label "$b")"; done
log "screen type $i: $(type_line "$i")"
pick=$(/opt/minui-zero/boardpick.elf 30 "$@")
rc=$?
if [ $rc -eq 0 ] && [ -n "$pick" ]; then
	log "chosen: $pick"
	if install "$pick" full; then
		echo "$pick" > "$CHOSEN"
		rm -f "$TRYING"
		restart
	fi
	log "install of $pick failed; asking again"
	exit 1
fi
next=$(( (i + 1) % NTYPES ))
rep=$(type_line "$next" | cut -d ' ' -f 1)
log "no choice (rc $rc): trying screen type $next ($rep)"
# Record the type BEFORE writing its files: a power cut after the write must ask about the screen type that is
# installed, and one during the write leaves a mixed set either way (reflash).
echo "$next" > "$TRYING"; sync
if install "$rep"; then
	restart
fi
echo "$i" > "$TRYING"; sync
log "install of $rep failed"
exit 1
