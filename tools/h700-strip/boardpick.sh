#!/bin/sh
# ONE IMAGE FOR EVERY H700 BOARD (Dan 2026-10-30). The card carries each board's boot files under
# /opt/minui-zero/boards/<board>/ (boot0.img, package.fex, device.tar.gz, and kernel: its name in boards/kernels/) and boots one screen
# type at a time. Each board's panel is set up by its own boot package, so a picker shown under the wrong
# board's package may be dark. Run by minui-frontend.sh until a model is chosen:
#   1. ask which model this is, listing EVERY model on any screen that can be read (boardpick.elf);
#   2. no choice in time (a dark or garbled screen): install the NEXT screen type's boot files and reboot,
#      so a dark screen moves on by itself and wraps around after the last type (B held goes back one);
#   3. a choice: install that board's own full boot set (including its boot0) and its device files, reboot,
#      and ask on the next boot whether the screen is right; no answer puts the screen type it was picked on
#      (and the boot0 that was on the card) back, so a wrong pick that garbles the screen undoes itself.
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

# Screen types in try order, from the board table (boards.txt, its type column, read through bin/board like every
# device script): type_line <n> lists that type's board ids in table order. The first id of each type is the board
# whose boot files stand in for the type while it is tried. Type 0 starts with the Plus: the image ships its files.
BOARDS_TXT=/mnt/mmc/.system/h700/boards.txt
BOARD=/mnt/mmc/.system/h700/bin/board
export BOARDS_TXT
label() { sh "$BOARD" label "$1"; }
NTYPES=$(sh "$BOARD" ntypes)
type_line() { sh "$BOARD" group "$1"; }
[ "${NTYPES:-0}" -gt 0 ] || { log "no board table at $BOARDS_TXT, not picking a model"; exit 0; }

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

# restart: the muOS way, which unmounts the card cleanly; plain reboot as the fallback. Only called after a
# complete install, so it never returns: a reboot that has not happened in 30 s must not fall through into the
# caller's failure branch (that would roll back a good install). Exit 0 instead and let the menu start; the next
# boot comes up on what was installed.
restart() {
	sync
	/opt/muos/script/system/halt.sh reboot 2>/dev/null
	reboot -f
	sleep 30
	log "no reboot after 30 s; carrying on to the menu, the next boot uses the new files"
	[ -z "$msg" ] || { kill "$msg" 2>/dev/null; wait "$msg" 2>/dev/null; }  # the menu needs the screen
	exit 0
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

# install <board> [full]: the board's kernel, boot package and device files (and with "full" its own boot0).
# Everything that can fail without touching the card runs first (every file present, the kernel and the device
# files unpacked); the raw writes come next, boot0 last, and the live device files are swapped only after every
# write has read back. A failure part way is put back by the caller (rollback).
install() {
	_d=$B/$1
	_k=$B/kernels/$(cat "$_d/kernel" 2>/dev/null)
	for _f in "$_d/package.fex" "$_d/device.tar.gz" "$_d/boot0.img" "$_k"; do [ -f "$_f" ] || { log "missing $_f"; return 1; }; done
	gunzip -c "$_k" > /tmp/bp-kernel.img || { log "cannot unpack $_k"; return 1; }
	# the rootfs tar is busybox built without -z, so gunzip first (to a file: sh has no pipefail)
	gunzip -c "$_d/device.tar.gz" > /tmp/bp-device.tar && rm -rf /opt/muos/device.new && mkdir -p /opt/muos/device.new &&
		tar -xf /tmp/bp-device.tar -C /opt/muos/device.new || { log "cannot unpack $_d/device.tar.gz"; return 1; }
	rm -f /tmp/bp-device.tar
	write /tmp/bp-kernel.img "$P4" 0 || return 1
	rm -f /tmp/bp-kernel.img
	write "$_d/package.fex" "$DISK" 32800 || return 1   # 16793600
	if [ "$2" = full ]; then
		write "$_d/boot0.img" "$DISK" 16 || return 1     # 8192
		write "$_d/boot0.img" "$DISK" 512 || return 1    # 262144
	fi
	rm -rf /opt/muos/device.old
	[ ! -d /opt/muos/device ] || mv /opt/muos/device /opt/muos/device.old || return 1
	mv /opt/muos/device.new /opt/muos/device || return 1
	rm -rf /opt/muos/device.old
	printf '%s\n' "${1#rg35xx-}" > /mnt/mmc/.system/h700/board || return 1
	sync
}

# rollback <board> [<boot0 file>]: put back the screen type that was installed (and the boot0 that was on the
# card) after a failed install, so a failed write never leaves a mixed set for the next boot.
rollback() {
	install "$1" && { [ -z "$2" ] || { write "$2" "$DISK" 16 && write "$2" "$DISK" 512; }; } && return 0
	log "ROLLBACK FAILED: the boot files on the card are mixed, it may need reflashing"
	return 1
}

check_layout || { log "card layout not recognized, not picking a model"; exit 0; }

# A model installed on the last boot waits for "the screen is right" before it counts as chosen (step 3).
PENDING=$B/pending    # the board installed, until confirmed
UNDO=$B/undo-boot0.img  # the boot0 that was on the card before it
if [ -f "$PENDING" ]; then
	p=$(cat "$PENDING")
	i=$(cat "$TRYING" 2>/dev/null || echo 0)
	case "$i" in ''|*[!0-9]*) i=0 ;; esac
	[ "$i" -lt "$NTYPES" ] || i=0
	/opt/minui-zero/boardpick.elf -c 60 "$(label "$p")" >/dev/null
	rc=$?
	if [ $rc -eq 0 ]; then
		echo "$p" > "$CHOSEN.new" && sync && mv "$CHOSEN.new" "$CHOSEN" || { log "cannot record $p as chosen"; exit 1; }
		rm -f "$PENDING" "$UNDO" "$TRYING"; sync
		log "confirmed: $p"
		exit 0
	fi
	[ $rc -eq 2 ] || { log "confirm screen failed (rc $rc), keeping $p unconfirmed"; exit 1; }
	cur=$(type_line "$i" | cut -d ' ' -f 1)
	log "not confirmed: $p; putting back screen type $i ($cur)"
	if [ -f "$UNDO" ] && install "$cur" && write "$UNDO" "$DISK" 16 && write "$UNDO" "$DISK" 512; then
		rm -f "$PENDING" "$UNDO"; sync
		restart
	fi
	log "putting back screen type $i failed; the menu starts on $p"
	exit 1
fi

i=$(cat "$TRYING" 2>/dev/null || echo 0)
case "$i" in ''|*[!0-9]*) i=0 ;; esac
[ "$i" -lt "$NTYPES" ] || i=0
cur=$(type_line "$i" | cut -d ' ' -f 1)
# Every model, in table order, starting on the first of the screen type installed now. A list limited to that
# type sent an H that could read the SP's screen hunting through the RG40XX ones (Dan 2026-11-03).
set --
n=0; sel=0
for b in $(sh "$BOARD" ids); do
	[ "$b" = "$cur" ] && sel=$n
	set -- "$@" "$b" "$(label "$b")"
	n=$((n + 1))
done
log "screen type $i: $(type_line "$i")"
# Types 0 and 1 hold the Plus, H, Pro and SP and show a picture on all of them, so they wait two minutes: the
# first boot follows the card expansion, and 30 s there moved an H on to the wrong boards unseen (Dan
# 2026-11-03). The later types are the ones a dark screen sits on, so they move on after 30 s.
[ "$i" -le 1 ] && wait_s=120 || wait_s=30
# Past the first type, B held goes back one (-b): the way back from a garbled screen is one hold, not a trip
# through every other screen type (Dan 2026-11-03).
[ "$i" -gt 0 ] && back=-b || back=
pick=$(/opt/minui-zero/boardpick.elf $back -s "$sel" "$wait_s" "$@")
rc=$?
if [ $rc -eq 0 ]; then
	# only a model in the table: anything else (a stray line, an empty answer) picks nothing
	case " $(sh "$BOARD" ids | tr '\n' ' ') " in *" $pick "*) ;; *) log "picker answered [$pick], not a model"; exit 1 ;; esac
	log "chosen: $pick, on screen type $i"
	# the boot0 on the card now, so a failed install or an unconfirmed pick can put it back
	dd if="$DISK" of="$UNDO" bs=512 skip=16 count=128 2>>"$LOG" &&
		[ "$(wc -c < "$UNDO")" -eq 65536 ] && head -c 12 "$UNDO" | tail -c 8 | grep -q eGON.BT0 ||
		{ log "cannot save the boot0 on the card, not installing"; rm -f "$UNDO"; exit 1; }
	# the install and reboot take several seconds with nothing else on screen (a black screen, Dan 2026-11-02)
	/opt/minui-zero/boardpick.elf -m "Setting up $(label "$pick")..." "Leave it on. It restarts by itself." >/dev/null 2>&1 &
	msg=$!
	# TRYING stays: it names the screen type to put back if the next boot is not confirmed
	if echo "$pick" > "$PENDING.new" && sync && install "$pick" full && mv "$PENDING.new" "$PENDING" && sync; then
		restart
	fi
	kill "$msg" 2>/dev/null; wait "$msg" 2>/dev/null
	log "install of $pick failed; putting back screen type $i ($cur)"
	rm -f "$PENDING" "$PENDING.new"
	rollback "$cur" "$UNDO" && rm -f "$UNDO"
	exit 1
fi
# Only the picker's own "no choice" (2: timeout) moves on, and its "back" (3: B held) goes back one. Any other
# exit is the picker failing, which it would do the same way on every screen type, so stop here and let the menu
# start on what is installed.
case $rc in
2) next=$(( (i + 1) % NTYPES )); why="no choice" ;;
3) next=$(( (i + NTYPES - 1) % NTYPES )); why="back" ;;
*) log "picker failed (rc $rc), not cycling"; exit 1 ;;
esac
rep=$(type_line "$next" | cut -d ' ' -f 1)
log "$why: trying screen type $next ($rep)"
# Record the type BEFORE writing its files: a power cut after the write must ask about the screen type that is
# installed, and one during the write leaves a mixed set either way (reflash).
echo "$next" > "$TRYING" && sync || { log "cannot record screen type $next, not cycling"; exit 1; }
if install "$rep"; then
	restart
fi
log "install of $rep failed; putting back screen type $i ($cur)"
rollback "$cur"
echo "$i" > "$TRYING"; sync
exit 1
