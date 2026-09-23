#!/bin/sh

IS_PLUS=false
if [ -f "/customer/app/axp_test" ]; then
	IS_PLUS=true
fi
# Tested as [ "$IS_PLUS" = "true" ], never as bare `if $IS_PLUS`. The bare form expands to a SYNTAX
# ERROR if the variable is ever empty, and bin/shutdown already shipped that exact bug: it exited
# without powering off, and the caller waited forever for a shutdown that never came. It is set
# locally here so the bare form works today — but this file is the install bootstrap, and a syntax
# error in it strands the device.

SDCARD_PATH=/mnt/SDCARD
MIYOO_PATH=$(cd "$(dirname "$0")"/.. && pwd)

cd "$MIYOO_PATH/app"

export LD_LIBRARY_PATH=/lib:/config/lib:/customer/lib

# update bootcmd if necessary
contains() { [ -z "${2##*$1*}" ]; }
MIYOO_VERSION=`/etc/fw_printenv miyoo_version`
MIYOO_VERSION=${MIYOO_VERSION#miyoo_version=}
SUPPORTED_VERSION="202205010000" # date after latest known version
# TODO: pretty sure this bricks a subsequent update
if [ $MIYOO_VERSION -lt $SUPPORTED_VERSION ]; then
	OLD_CMD=`/etc/fw_printenv bootcmd`
	NEW_CMD="gpio output 85 1; bootlogo 0 0 0 0 0; mw 1f001cc0 11; gpio out 8 0; sf probe 0;sf read 0x22000000 \${sf_kernel_start} \${sf_kernel_size}; gpio out 8 1; gpio output 4 1; bootm 0x22000000"
	if contains "sleepms" "$OLD_CMD"; then
		/etc/fw_setenv bootcmd $NEW_CMD
		sleep 1
	fi
fi

# .tmp_update/updater does the actual installation (and later, updating)
#
# ORDER MATTERS AND IT USED TO BE WRONG. This copied the bootstrap, then deleted $MIYOO_PATH — the
# stock-firmware entry point, i.e. the only thing that re-runs this on the next boot — WITHOUT ever
# checking that the copy succeeded. On a full card or an interrupted write that left no bootstrap
# and no way back in.
#
# Now: copy to an INERT staging name, prove the payload actually arrived intact, promote it, and
# only then remove the entry point. If anything failed, leave everything alone and let the stock
# path run again.
#
# Why staging rather than copying straight to .tmp_update: that name is live. A copy interrupted
# part-way used to leave a real, dispatchable .tmp_update/updater sitting there with the rest of the
# payload missing. .tmp_update.new is a name nothing boots from, so a half-written one is inert.
#
# Why more than `-f updater`: the payload is FIVE files and `updater` is one of them. `cp` truncates
# the destination before writing, so a card that fills mid-copy leaves real-but-short files. The
# earlier check passed on a truncated updater, and passed on a complete updater whose companion
# miyoomini.sh — the script `updater` execs — never arrived. Either way the entry point was deleted
# and the device had no way back.
#
# REQUIRED is an explicit list rather than "whatever the source happened to contain": enumerating the
# source cannot detect an incomplete SOURCE. (The build no longer suppresses a failed bootstrap copy
# either, so a short source now fails the build instead of shipping.)
REQUIRED="updater miyoomini.sh"
STAGE="$SDCARD_PATH/.tmp_update.new"
INSTALL_OK=1

rm -rf "$STAGE"
cp -rf .tmp_update "$STAGE" || INSTALL_OK=0
sync                          # commit before believing any size we read back

for f in $REQUIRED; do
	# non-empty AND the same size as the source: catches both a missing file and a truncated one
	if [ ! -s "$STAGE/$f" ] || [ "$(wc -c < "$STAGE/$f" 2>/dev/null)" != "$(wc -c < ".tmp_update/$f" 2>/dev/null)" ]; then
		INSTALL_OK=0
	fi
done

if [ "$INSTALL_OK" != "1" ]; then
	rm -rf "$STAGE"   # reclaim the space so the retry has room
	echo "$(date '+%F %T') Could not copy the MinUI bootstrap to the SD card (full card, or a write error). Nothing was removed - free some space and try again." > "$SDCARD_PATH/MinUI-install-failed.txt"
	sync
	# EXIT, do not just power off. BusyBox poweroff/reboot SIGNAL init and RETURN immediately —
	# bin/shutdown relies on exactly that (`reboot && sleep 10`). Without the exit, execution fell
	# through to `rm -rf "$MIYOO_PATH"` below and deleted the stock entry point during the
	# multi-second shutdown window: the precise brick this bail-out exists to prevent.
	if [ "$IS_PLUS" = "true" ]; then poweroff; else reboot; fi
	exit 1
fi

# PROMOTE. The staged payload is verified, so publishing it under the live name is a directory
# rename — after which the presence of .tmp_update/updater once again implies the whole set arrived.
# Keep the previous bootstrap until the rename has been committed; it is the fallback if power is
# cut mid-promote, and the entry point below still has not been touched.
rm -rf "$SDCARD_PATH/.tmp_update.old"
[ -d "$SDCARD_PATH/.tmp_update" ] && mv "$SDCARD_PATH/.tmp_update" "$SDCARD_PATH/.tmp_update.old"
# CHECK THE RENAME. An earlier version of this let a failed mv fall through to the two deletions
# below — which threw away the rollback AND the entry point while the only complete payload sat
# under .tmp_update.new, a name nothing boots from. Put the previous bootstrap back and leave the
# entry point alone so the next boot simply retries.
if ! mv "$STAGE" "$SDCARD_PATH/.tmp_update"; then
	[ -d "$SDCARD_PATH/.tmp_update.old" ] && mv "$SDCARD_PATH/.tmp_update.old" "$SDCARD_PATH/.tmp_update"
	rm -rf "$STAGE"
	echo "$(date '+%F %T') Could not install the MinUI bootstrap (the card may be full or failing). Nothing was removed - free some space and try again." > "$SDCARD_PATH/MinUI-install-failed.txt"
	sync
	if [ "$IS_PLUS" = "true" ]; then poweroff; else reboot; fi
	exit 1
fi
sync                      # commit the bootstrap BEFORE deleting our way back to it
rm -rf "$SDCARD_PATH/.tmp_update.old"
rm -f "$SDCARD_PATH/MinUI-install-failed.txt"   # a later install succeeded: the old note is now false
rm -rf "$MIYOO_PATH"
sync
$SDCARD_PATH/.tmp_update/updater

# under no circumstances should stock be allowed to touch this card
if [ "$IS_PLUS" = "true" ]; then
	poweroff
else
	reboot
fi