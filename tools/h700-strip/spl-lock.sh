#!/bin/sh
# Source in a single writer process. Never borrow a parent's lease or steal a stale one.
spl_lock_acquire() {
	_spl_lock_path=$1
	_spl_lock_dirty=0
	( set -C; echo "$$" > "$_spl_lock_path" ) 2>/dev/null || {
		echo "SPL transaction busy: $_spl_lock_path" >&2; return 75;
	}
	trap 'spl_lock_exit $?' 0
	trap 'exit 1' HUP INT TERM
}
spl_lock_release() {
	[ "$(cat "$_spl_lock_path" 2>/dev/null)" = "$$" ] || return 1
	rm "$_spl_lock_path" || return 1
	trap - 0 HUP INT TERM
}
spl_lock_exit() {
	_spl_lock_rc=$1
	trap - 0 HUP INT TERM
	if [ "$_spl_lock_rc" -ne 0 ] && [ "$_spl_lock_dirty" = 1 ]; then
		echo "SPL write failed: retaining $_spl_lock_path until reboot" >&2
	else
		spl_lock_release || _spl_lock_rc=1
	fi
	exit "$_spl_lock_rc"
}
