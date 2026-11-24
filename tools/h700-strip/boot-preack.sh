#!/bin/sh
# Called before the ack wait or lock. No card writes under its lock: publish the
# completed RAM snapshot separately. Never acknowledge, clear, or re-arm anything.
umask 077
snap=/run/zero-boot-preack
[ ! -e "$snap" ] || exit 0
t=$(mktemp /run/zero-preack.XXXXXX) || exit 1
trap 'rm -f "$t"' 0
id=$(cat /proc/sys/kernel/random/boot_id) || exit 1
{
	printf 'version=1\nboot_id=%s\nuptime=%s\n' "$id" "$(cat /proc/uptime)"
	for addr in 134 138 13c; do
		v=$(busybox devmem "0x07000$addr" 32 2>/dev/null) || v=unreadable
		printf 'rtc_%s=%s\n' "$addr" "$v"
	done
	# Compare only the public attempt signature; never print arbitrary card bytes.
	a=$(dd if=/dev/mmcblk0 bs=512 skip=16640 count=1 2>/dev/null | od -An -tx1 -N15 | tr -d ' \n')
	case "$a" in 5a45524f2d415454454d50542d5631) a=pending ;;
	000000000000000000000000000000) a=clear-prefix ;; *) a=unknown ;; esac
	printf 'attempt=%s\n' "$a"
	dt=/sys/firmware/devicetree/base/chosen/zero,loader
	if [ -e "$dt" ]; then
		if cat "$dt" > "$snap.dt"; then echo loader_dt=present
		else rm -f "$snap.dt"; echo loader_dt=unreadable; fi
	else echo loader_dt=absent; fi
} > "$t" && mv "$t" "$snap" || exit 1
(
	# Never publish into an unmounted directory or a different volume.
	left=900
	until awk '$1=="/dev/mmcblk0p6" && $2=="/mnt/mmc" && $3=="vfat" {ok=1} END {exit !ok}' /proc/mounts; do
		[ "$left" -gt 0 ] || exit 0
		left=$((left-1)); sleep 1
	done
	dir=/mnt/mmc/.userdata/h700/logs
	mkdir -p "$dir" || exit 1
	p=$(mktemp "$dir/.preack.XXXXXX") || exit 1
	cat "$snap" > "$p" && mv -f "$p" "$dir/boot-preack.txt" || rm -f "$p"
	base=$dir/stage2-receipts
	prov=$(cat "$base/current" 2>/dev/null) || exit 0
	case "$prov:$id" in *[!0-9a-f:-]*) exit 1 ;; esac
	[ "${#prov}" = 36 ] && [ "${#id}" = 36 ] && [ "$prov" != "$id" ] || exit 0
	origin=$base/$prov
	[ -d "$origin/provisioned" ] && [ ! -e "$origin/first-return" ] || exit 0
	tmp=$(mktemp -d "$origin/.return.XXXXXX") || exit 1
	trap 'rm -rf "$tmp"' 0
	cp "$snap" "$tmp/preack-$id.txt" || exit 1
	if [ -f "$snap.dt" ]; then cp "$snap.dt" "$tmp/loader-$id.bin" || exit 1; fi
	mv "$tmp" "$origin/first-return"
) </dev/null >/dev/null 2>&1 &
exit 0
