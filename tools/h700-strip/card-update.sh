#!/bin/sh
# MinUI Zero card update for the h700 image: drop MinUI.zip on the card root and the next boot installs it, the
# same way the TrimUI and Miyoo cards update (workspace/tg5040/install/boot.sh is the model for every step here).
# minui-frontend.sh runs this at the top of every boot, before anything starts from the card.
#
# This file lives on the rootfs and a zip never replaces it, so a bad update cannot break the thing that applies
# the next one. Only the card payload updates this way: .system (the launcher, emulator, cores, paks, settings and
# the card copy of minui-frontend.sh) and Tools. The kernel, boot files and rootfs still change by reflashing.
#
# Order, so no step can leave the card worse than it found it:
#   1. CRC-test the whole archive. A corrupt one is renamed MinUI.zip.bad and nothing else changes.
#   2. Check it is an h700 payload. The TrimUI and Miyoo zips are valid archives too; one is KEPT, with a note.
#   3. Extract into a staging folder. Nothing live changes until the whole payload is on the card and checked.
#   4. Merge it in, sync, and only then delete the staging folder and the archive. A power cut before that sync
#      leaves the archive in place, and the next boot simply installs it again.
# A note in MinUI-update-failed.txt at the card root says what went wrong; a later success deletes it.
#
# Only .system/h700, .system/res, .system/version.txt and Tools/h700 are installed; anything else in the archive
# (other platforms, .userdata, Saves) is ignored. Device state is never taken from it either: .system/h700/board
# (the picked model, written by the picker) is dropped from the staged copy.

SDCARD_PATH=${SDCARD_PATH:-/mnt/mmc}
UPDATE_PATH="$SDCARD_PATH/MinUI.zip"
STAGE="$SDCARD_PATH/.minui-staging"   # inert name: nothing boots from it
FAILED="$SDCARD_PATH/MinUI-update-failed.txt"
UNZIP=${ZERO_UNZIP:-/usr/bin/unzip}   # Info-ZIP (the Debian build the donor rootfs carries); busybox's has no -t
MSG=/opt/minui-zero/boardpick.elf
[ -f "$UPDATE_PATH" ] || exit 0

note() { echo "$(date '+%F %T') $1" > "$FAILED"; sync; echo "update: $1"; }
_msg=
[ -x "$MSG" ] && { "$MSG" -m "Updating MinUI Zero..." "Leave it on. It starts by itself." >/dev/null 2>&1 & _msg=$!; }
done_msg() { [ -n "$_msg" ] && { kill "$_msg" 2>/dev/null; wait "$_msg" 2>/dev/null; }; }

rm -rf "$STAGE"
# sizes for the free-space check below, format-checked first: a bad value in $(( )) aborts this shell. A df that
# cannot answer skips the check rather than blocking every update.
_kb=$("$UNZIP" -l "$UPDATE_PATH" 2>/dev/null | tail -1 | awk '{print int($1/1024)}')
case "$_kb" in ''|*[!0-9]*) _kb=0 ;; esac
_need=$((_kb * 2 + 16384))
_free=$(df -k "$SDCARD_PATH" 2>/dev/null | awk 'NR==2 {print $4}')
case "$_free" in ''|*[!0-9]*) _free= ;; esac
if [ ! -x "$UNZIP" ]; then
	note "This system has no unzip, so MinUI.zip cannot be installed. Nothing was changed and the file was kept."
elif ! "$UNZIP" -tqq "$UPDATE_PATH" >/dev/null 2>&1; then
	mv -f "$UPDATE_PATH" "$UPDATE_PATH.bad"
	note "MinUI.zip is damaged (the download did not finish, or the copy failed). Nothing was changed; it was renamed MinUI.zip.bad. Download it again and reboot."
elif ! "$UNZIP" -l "$UPDATE_PATH" 2>/dev/null | grep -q '\.system/h700/paks/MinUI\.pak/launch\.sh'; then
	note "This MinUI.zip does not contain an Anbernic (h700) system: it is probably the download for a TrimUI or Miyoo. Nothing was changed and the file was kept; replace it with the Anbernic zip and reboot."
# ROOM FOR BOTH COPIES, checked before anything is written (Codex review 2026-11-04). The staged copy and the merge
# need space at once, and a merge that runs out partway has already cut live files short, then repeats on every
# boot. Need twice the unpacked size plus 16 MB; the last line of unzip -l is the unpacked total in bytes.
elif [ -n "$_free" ] && [ "$_free" -lt "$_need" ]; then
	note "Not enough free space to install MinUI.zip: it needs $((_need / 1024)) MB free and the card has $((_free / 1024)) MB. Nothing was changed and the file was kept; free some space and reboot."
elif ! mkdir -p "$STAGE"; then
	note "Could not create a staging folder on the card: it may be full or write-protected. Nothing was changed."
# a complete system, not just a launcher: the pieces that have to match each other (Codex review 2026-11-04)
elif "$UNZIP" -oq "$UPDATE_PATH" -d "$STAGE" && [ -f "$STAGE/.system/h700/paks/MinUI.pak/launch.sh" ] &&
	[ -f "$STAGE/.system/h700/bin/minui.elf" ] && [ -f "$STAGE/.system/h700/bin/minarch.elf" ] &&
	[ -f "$STAGE/.system/h700/bin/minui-frontend.sh" ] && [ -f "$STAGE/.system/h700/boards.txt" ] &&
	[ -d "$STAGE/.system/h700/cores" ] && [ -d "$STAGE/.system/res" ] && [ -f "$STAGE/.system/version.txt" ]; then
	rm -f "$STAGE/.system/h700/board"
	# only this platform's parts and the shared ones, so an archive that also carries other platforms (one zip for
	# every device) installs just the h700 system here
	_ok=1
	mkdir -p "$SDCARD_PATH/.system" "$SDCARD_PATH/Tools" || _ok=0
	cp -rf "$STAGE/.system/h700" "$SDCARD_PATH/.system/" || _ok=0
	[ -d "$STAGE/.system/res" ] && { cp -rf "$STAGE/.system/res" "$SDCARD_PATH/.system/" || _ok=0; }
	[ -f "$STAGE/.system/version.txt" ] && { cp -f "$STAGE/.system/version.txt" "$SDCARD_PATH/.system/" || _ok=0; }
	[ -d "$STAGE/Tools/h700" ] && { cp -rf "$STAGE/Tools/h700" "$SDCARD_PATH/Tools/" || _ok=0; }
	# commit the merge before discarding the way back (the archive), or a power cut could leave neither
	sync
	if [ $_ok = 1 ]; then
		rm -rf "$STAGE"
		rm -f "$UPDATE_PATH" "$FAILED"
		sync
		echo "update: installed $(head -1 "$SDCARD_PATH/.system/version.txt" 2>/dev/null)"
	else
		rm -rf "$STAGE"
		note "The update stopped partway (the card may be full). MinUI.zip was kept: free some space and reboot to install it again."
	fi
else
	rm -rf "$STAGE"
	mv -f "$UPDATE_PATH" "$UPDATE_PATH.failed"
	note "MinUI.zip could not be unpacked (the card may be full) or is not a complete system. Nothing was changed; it was renamed MinUI.zip.failed."
fi
sync
done_msg
exit 0
