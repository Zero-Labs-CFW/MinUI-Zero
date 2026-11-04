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
#   0. card-fsck.sh repaired the card's filesystem before it was mounted (boots with a MinUI.zip only). A card it
#      could not repair is not written to.
#   1. CRC-test the whole archive. A corrupt one is renamed MinUI.zip.bad and nothing else changes.
#   2. Check it is an h700 payload, and one this rootfs can run (min-rootfs in the zip against rootfs-level here).
#      Either failure KEEPS the zip, with a note.
#   3. Extract into a staging folder. Nothing live changes until the whole payload is on the card and checked.
#   4. Swap: rename .system/h700 and .system/res aside and the staged ones into place (renames on one FAT, so no
#      second copy of the data), then merge Tools/h700 and version.txt, sync, and only then delete the old folders,
#      the staging folder and the archive. A swap replaces the whole folder, so files a release drops are gone
#      too (a plain copy-over left them behind, and a stale library in .system/h700/lib shadows the rootfs one).
#      A journal file marks the swap: a power cut anywhere in it is finished or undone at the next boot, before
#      anything runs from the card, and the archive is still there to install again.
# A note in MinUI-update-failed.txt at the card root says what went wrong; a later success deletes it.
#
# Only .system/h700, .system/res, .system/version.txt and Tools/h700 are installed; anything else in the archive
# (other platforms, .userdata, Saves) is ignored. Tools/h700 is merged, never swapped: users install community
# tool paks there. Device state is never taken from the zip: .system/h700/board (the picked model, written by the
# picker, the only file anything writes into .system/h700 at runtime) is carried over from the live folder.

SDCARD_PATH=${SDCARD_PATH:-/mnt/mmc}
UPDATE_PATH="$SDCARD_PATH/MinUI.zip"
STAGE="$SDCARD_PATH/.minui-staging"   # inert name: nothing boots from it
SWAP="$SDCARD_PATH/.minui-swap"        # journal: present only while the folders are being swapped
SWAP_DIRS=".system/h700 .system/res"
FAILED="$SDCARD_PATH/MinUI-update-failed.txt"
UNZIP=${ZERO_UNZIP:-/usr/bin/unzip}   # Info-ZIP (the Debian build the donor rootfs carries); busybox's has no -t
STATE_DIR=${ZERO_STATE_DIR:-/opt/minui-zero}
MSG=/opt/minui-zero/boardpick.elf

# ---- the swap's recovery: finish it when every new folder is in place, else put back what was moved aside ----
# One routine for a power cut (next boot, below) and for a failure in this run (end of file). It succeeds, and only
# then drops the journal, when both live folders exist and no .old is left (Codex review 2026-11-04); otherwise the
# journal stays and the next boot tries again. Plain variables: busybox ash, no reliance on local.
recover_swap() {
	_rs_done=1
	for _d in $SWAP_DIRS; do
		{ [ -d "$SDCARD_PATH/$_d" ] && [ ! -e "$STAGE/$_d" ]; } || _rs_done=0
	done
	_rs_ok=1
	if [ $_rs_done = 1 ]; then
		# every new folder is in place: finish (the zip, if still there, installs again, which is harmless)
		for _d in $SWAP_DIRS; do rm -rf "$SDCARD_PATH/$_d.old" || _rs_ok=0; done
		_rs_what="finished an interrupted install"
	else
		# put back every old folder that was moved aside; the zip is still there and installs again
		for _d in $SWAP_DIRS; do
			if [ -d "$SDCARD_PATH/$_d.old" ]; then
				rm -rf "$SDCARD_PATH/$_d" && mv "$SDCARD_PATH/$_d.old" "$SDCARD_PATH/$_d" || _rs_ok=0
			elif [ ! -e "$SDCARD_PATH/$_d" ] && [ -d "$STAGE/$_d" ]; then
				# a card that had no such folder (wiped, then a zip dropped on it): no old copy exists, so the staged
				# one, already checked complete before the swap began, is the only way back to a working card
				mv "$STAGE/$_d" "$SDCARD_PATH/$_d" || _rs_ok=0
			fi
		done
		_rs_what="undid an interrupted install"
	fi
	for _d in $SWAP_DIRS; do [ -d "$SDCARD_PATH/$_d" ] && [ ! -e "$SDCARD_PATH/$_d.old" ] || _rs_ok=0; done
	sync
	if [ $_rs_ok = 0 ]; then
		echo "update: could not finish or undo an interrupted install; will retry at the next boot"
		echo "$(date '+%F %T') An interrupted update could not be finished or undone (the card may be failing). It is retried at every boot; if this stays, copy your Saves off and reflash the card." > "$FAILED"
		sync
		return 1
	fi
	rm -f "$SWAP"
	sync
	echo "update: $_rs_what"
	return 0
}

# an interrupted swap first, zip or not: the card must be whole before anything runs from it, and nothing below may
# install over a card whose recovery failed
if [ -f "$SWAP" ]; then
	recover_swap || exit 0
fi

# card-fsck.sh's verdict for this boot (no file: the check did not run). Consumed here so it never outlives a boot.
_fsck=$(head -1 "$STATE_DIR/card-fsck.state" 2>/dev/null)
_framed=; grep -qx shown "$STATE_DIR/card-fsck.state" 2>/dev/null && _framed=1
rm -f "$STATE_DIR/card-fsck.state" 2>/dev/null
# fsck -a keeps the broken cluster chains it salvages as FSCKnnnn.REC in the card root: same home as expand-roms.sh
if [ "$_fsck" = repaired ] && ls "$SDCARD_PATH"/FSCK[0-9][0-9][0-9][0-9].REC >/dev/null 2>&1; then
	mkdir -p "$SDCARD_PATH/.userdata/h700/logs/fsck-recovered" &&
		mv "$SDCARD_PATH"/FSCK[0-9][0-9][0-9][0-9].REC "$SDCARD_PATH/.userdata/h700/logs/fsck-recovered/" 2>/dev/null
fi

# THE DOWNLOAD AS-IS (Dan 2026-11-04): the release asset is MinUI-Zero-h700-<version>.zip, and renaming it is the step
# people get wrong, so one such file on the card root is taken as MinUI.zip (a rename on the card, no copy). A browser's
# "(1)" copy matches too. Several of them: which one is meant is not ours to guess, so nothing installs and a note says
# so. MinUI.zip itself, when present, always wins.
if [ ! -f "$UPDATE_PATH" ]; then
	set -- "$SDCARD_PATH"/[Mm][Ii][Nn][Uu][Ii]-[Zz][Ee][Rr][Oo]-[Hh]700-*.[Zz][Ii][Pp]   # any case: names on vfat keep theirs, and the shell's glob is case-sensitive
	if [ $# -eq 1 ] && [ -f "$1" ]; then
		mv -f "$1" "$UPDATE_PATH" && sync && echo "update: taking ${1##*/} as MinUI.zip"
	elif [ $# -gt 1 ]; then
		echo "$(date '+%F %T') There are several MinUI-Zero-h700 zips on the card root. Nothing was changed: keep only the one to install and reboot." > "$FAILED"
		sync
		exit 0
	fi
fi
[ -f "$UPDATE_PATH" ] || exit 0

note() { echo "$(date '+%F %T') $1" > "$FAILED"; sync; echo "update: $1"; }
_msg=
# This runs before the frontend sets up the environment, so give boardpick.elf the two things it needs from it: the
# card's lib folder (it links libmsettings.so; without it the message never loaded and an update showed a blank
# screen, the H, 2026-11-04) and DEVICE, which platform.c reads for the panel size and rotation (unset, a CubeXX,
# RG28XX or 34XX drew the message at the 640x480 default; Codex review 2026-11-04). DEVICE is derived exactly as
# minui-frontend.sh does. A card with no lib folder just shows no message.
_dev=$(sed 's/^rg35xx-//' /opt/muos/device/config/board/name 2>/dev/null || echo plus)
# ONE screen: card-fsck.sh already put the "Updating MinUI Zero..." frame up (the same art the TrimUI and Miyoo updates
# show) and nothing draws over it until the menu, so only draw this message when it could not (Dan saw both, 2026-11-04).
[ -z "$_framed" ] && [ -x "$MSG" ] && { DEVICE="$_dev" LD_LIBRARY_PATH="$SDCARD_PATH/.system/h700/lib:/usr/lib:/lib" "$MSG" -m "Updating MinUI Zero..." "Leave it on. It starts by itself." >/dev/null 2>&1 & _msg=$!; }
# SIGKILL: SDL turns SIGTERM into a quit event the message never reads, so a plain kill left wait blocked forever and
# the H sat on "Updating" after the install had finished (2026-11-04)
done_msg() { [ -n "$_msg" ] && { kill -9 "$_msg" 2>/dev/null; wait "$_msg" 2>/dev/null; }; }

rm -rf "$STAGE"
# sizes for the free-space check below, format-checked first: a bad value in $(( )) aborts this shell. A df that
# cannot answer skips the check rather than blocking every update.
_kb=$("$UNZIP" -l "$UPDATE_PATH" 2>/dev/null | tail -1 | awk '{print int($1/1024)}')
case "$_kb" in ''|*[!0-9]*) _kb=0 ;; esac
_need=$((_kb + 16384))
_free=$(df -k "$SDCARD_PATH" 2>/dev/null | awk 'NR==2 {print $4}')
case "$_free" in ''|*[!0-9]*) _free= ;; esac
# ROOTFS LEVEL: the rootfs changes only by reflashing, so a payload that needs something newer here (a binary in
# /opt/minui-zero, a kernel module) must be refused, not installed and broken. The build stamps both numbers; a zip
# without min-rootfs predates them and runs anywhere.
_want=$("$UNZIP" -p "$UPDATE_PATH" .system/h700/min-rootfs 2>/dev/null | head -1)
case "$_want" in ''|*[!0-9]*) _want=0 ;; esac
_have=$(head -1 "$STATE_DIR/rootfs-level" 2>/dev/null)
case "$_have" in ''|*[!0-9]*) _have=0 ;; esac
if [ ! -x "$UNZIP" ]; then
	note "This system has no unzip, so MinUI.zip cannot be installed. Nothing was changed and the file was kept."
elif [ "$_fsck" = failed ]; then
	note "The card's filesystem is damaged and could not be repaired, so MinUI.zip was not installed (writing to a damaged card can lose files). Nothing was changed and the file was kept. Check the card on a computer, then reboot."
elif ! "$UNZIP" -tqq "$UPDATE_PATH" >/dev/null 2>&1; then
	mv -f "$UPDATE_PATH" "$UPDATE_PATH.bad"
	note "MinUI.zip is damaged (the download did not finish, or the copy failed). Nothing was changed; it was renamed MinUI.zip.bad. Download it again and reboot."
elif ! "$UNZIP" -l "$UPDATE_PATH" 2>/dev/null | grep -q '\.system/h700/paks/MinUI\.pak/launch\.sh'; then
	note "This MinUI.zip does not contain an Anbernic (h700) system: it is probably the download for a TrimUI or Miyoo. Nothing was changed and the file was kept; replace it with the Anbernic zip and reboot."
elif [ "$_want" -gt "$_have" ]; then
	note "This MinUI.zip needs a newer base system than this card has, so it can only be installed by flashing the full image. Nothing was changed and the file was kept."
# ROOM FOR THE STAGED COPY, checked before anything is written (Codex review 2026-11-04). The swap renames, so the
# staged copy is the only extra space needed, plus 16 MB; the last line of unzip -l is the unpacked total in bytes.
elif [ -n "$_free" ] && [ "$_free" -lt "$_need" ]; then
	note "Not enough free space to install MinUI.zip: it needs $((_need / 1024)) MB free and the card has $((_free / 1024)) MB. Nothing was changed and the file was kept; free some space and reboot."
elif ! mkdir -p "$STAGE"; then
	note "Could not create a staging folder on the card: it may be full or write-protected. Nothing was changed."
# a complete system, not just a launcher: the pieces that have to match each other (Codex review 2026-11-04)
elif "$UNZIP" -oq "$UPDATE_PATH" -d "$STAGE" && [ -f "$STAGE/.system/h700/paks/MinUI.pak/launch.sh" ] &&
	[ -f "$STAGE/.system/h700/bin/minui.elf" ] && [ -f "$STAGE/.system/h700/bin/minarch.elf" ] &&
	[ -f "$STAGE/.system/h700/bin/minui-frontend.sh" ] && [ -f "$STAGE/.system/h700/boards.txt" ] &&
	[ -d "$STAGE/.system/h700/cores" ] && [ -d "$STAGE/.system/res" ] && [ -f "$STAGE/.system/version.txt" ]; then
	# the picked model comes from this card, never from the zip
	rm -f "$STAGE/.system/h700/board"
	_ok=1
	[ -f "$SDCARD_PATH/.system/h700/board" ] && { cp -f "$SDCARD_PATH/.system/h700/board" "$STAGE/.system/h700/board" || _ok=0; }
	mkdir -p "$SDCARD_PATH/.system" "$SDCARD_PATH/Tools" || _ok=0
	# a leftover .old must be gone before the swap: mv onto an existing folder moves INTO it, and an undo would then
	# restore that nested tree
	for _d in $SWAP_DIRS; do rm -rf "$SDCARD_PATH/$_d.old"; [ ! -e "$SDCARD_PATH/$_d.old" ] || _ok=0; done
	if [ $_ok = 1 ]; then
		sync
		: > "$SWAP" && sync || _ok=0
	fi
	if [ $_ok = 1 ]; then
		for _d in $SWAP_DIRS; do
			if [ -d "$SDCARD_PATH/$_d" ]; then mv "$SDCARD_PATH/$_d" "$SDCARD_PATH/$_d.old" || { _ok=0; break; }; fi
			mv "$STAGE/$_d" "$SDCARD_PATH/$_d" || { _ok=0; break; }
		done
	fi
	if [ $_ok = 1 ]; then
		# outside the swap, merged: version.txt is one file, and Tools/h700 also holds the user's own tool paks
		cp -f "$STAGE/.system/version.txt" "$SDCARD_PATH/.system/" || _ok=0
		[ -d "$STAGE/Tools/h700" ] && { cp -rf "$STAGE/Tools/h700" "$SDCARD_PATH/Tools/" || _ok=0; }
	fi
	# commit before discarding the way back (the old folders and the archive)
	sync
	if [ $_ok = 1 ]; then
		for _d in $SWAP_DIRS; do rm -rf "$SDCARD_PATH/$_d.old"; done
		rm -rf "$STAGE"
		# a new card frontend gets fresh tries, committed BEFORE the zip goes: a cut in between then reinstalls, where
		# the other order could keep a count of 3 with no zip left to clear it (Codex review 2026-11-04)
		rm -f "$STATE_DIR/card-fe-tries"
		sync
		rm -f "$UPDATE_PATH" "$FAILED"
		sync
		rm -f "$SWAP"
		sync
		echo "update: installed $(head -1 "$SDCARD_PATH/.system/version.txt" 2>/dev/null)"
	else
		# recover exactly as a power cut is recovered at the next boot, so there is one recovery path. A recovery that
		# fails keeps the journal and the staging folder (the next boot's recovery may need it) and its own note.
		if [ ! -f "$SWAP" ] || recover_swap; then
			rm -rf "$STAGE"
			note "The update stopped partway (the card may be full or failing). MinUI.zip was kept: free some space and reboot to install it again."
		fi
	fi
else
	rm -rf "$STAGE"
	mv -f "$UPDATE_PATH" "$UPDATE_PATH.failed"
	note "MinUI.zip could not be unpacked (the card may be full) or is not a complete system. Nothing was changed; it was renamed MinUI.zip.failed."
fi
sync
done_msg
exit 0
