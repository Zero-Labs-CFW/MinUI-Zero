#!/bin/sh
# Writes a NEW report directory and private temporary files only. Never invoke
# install/ack/policy or take their locks. Input media may be missing or changing.
set -eu
export LC_ALL=C
umask 077
private=0
if [ "${1-}" = --include-identifiers ]; then private=1; shift; fi
[ "$#" = 1 ] || { echo 'usage: boot-evidence.sh [--include-identifiers] NEW_DIRECTORY' >&2; exit 2; }
case "$1" in /*) out=$1 ;; *) out=$PWD/$1 ;; esac
mkdir "$out" || exit 1
t=$(mktemp -d /tmp/zero-evidence.XXXXXX) || exit 1
trap 'rm -rf "$t"' 0
cd "$out"
z=/opt/minui-zero
card=/mnt/mmc
dev=/dev/mmcblk0
dt=/sys/firmware/devicetree/base/chosen/zero,loader
printf '1\n' > schema
note() { printf '%s\t%s\n' "$1" "$2" >> status.tsv; }
err() {
	case "$(cat "$t/err")" in *'Permission denied'*) echo permission-denied ;;
	*'No such file or directory'*) echo absent ;; *) echo read-error ;; esac
}
ok() { if [ -s "$1" ]; then note "$1" ok; else note "$1" empty; fi; }
get() {
	if cat "$2" > "$1" 2>"$t/err"; then ok "$1"
	else rm -f "$1"; note "$1" "$(err)"; fi
}
marker() {
	if ls -ld "$2" >/dev/null 2>"$t/err"; then
		if [ ! -f "$2" ]; then note "$1" invalid
		elif [ ! -r "$2" ]; then note "$1" permission-denied
		elif [ -s "$2" ]; then note "$1" present; else note "$1" empty; fi
	else note "$1" "$(err)"; fi
}
hash() {
	if sha256sum < "$2" > "$t/hash" 2>"$t/err"; then
		cut -d' ' -f1 "$t/hash" > "$1"; wc -c < "$2" | tr -d ' ' > "${1%.sha256}.bytes"; ok "$1"
	else note "$1" read-error; fi
}
filehash() {
	if ls -ld "$2" >/dev/null 2>"$t/err"; then
		if [ ! -r "$2" ]; then note "$1" permission-denied
		elif [ ! -s "$2" ]; then note "$1" empty
		else hash "$1" "$2"; fi
	else note "$1" "$(err)"; fi
}
registers() {
	for pair in gp13:0x07000134 gp14:0x07000138 gp15:0x0700013c; do
		k=${pair%:*}-$1
		if busybox devmem "${pair#*:}" 32 > "$k" 2>"$t/err"; then ok "$k"
		else rm -f "$k"; note "$k" "$(err)"; fi
	done
}
boundary() {
	get "boot-id-$1" /proc/sys/kernel/random/boot_id; get "uptime-$1" /proc/uptime
	get "state-$1" "$z/spl-state"
	for f in zero-spl-auto zero-spl-busy zero-spl-sleep; do get "$f-$1" "/run/$f"; done
	for f in zero-stage2-charger zero-stage2-provisioned zero-menu-frame; do marker "$f-$1" "/run/$f"; done
	marker "swap-$1" "$z/.spl-sleep-swapped"
	marker "off-$1" "$card/fast-boot-off.txt"; marker "trial-$1" "$card/fast-boot.txt"
	registers "$1"
}
boundary start
get chosen "$z/boards/chosen"; get board "$card/.system/h700/board"
get version "$card/.system/version.txt"; get rootfs-level "$z/rootfs-level"
get expected-id "$z/loader/build-id"; get loader.dt "$dt"
for p in model compatible; do get "dt-$p" "/sys/firmware/devicetree/base/$p"; done
for p in /sys/firmware/devicetree/base/memory /sys/firmware/devicetree/base/memory@*; do
	[ ! -d "$p" ] || get "dt-${p##*/}-reg" "$p/reg"
done
get display /sys/class/disp/disp/attr/sys; get frame /run/zero-display-frame
get preack-ram /run/zero-boot-preack; get preack-card "$card/.userdata/h700/logs/boot-preack.txt"
get meminfo /proc/meminfo
for f in capacity status voltage_now; do get "battery-$f" "/sys/class/power_supply/axp2202-battery/$f"; done
get usb-online /sys/class/power_supply/axp2202-usb/online
get kernel-release /proc/sys/kernel/osrelease
if [ "$private" = 1 ]; then
	get cid /sys/block/mmcblk0/device/cid; get cmdline /proc/cmdline
	get policy-log "$card/.userdata/h700/logs/fast-boot.txt"
else
	note cid withheld
	# Use a positive list. snum and androidboot.serialno both identify the unit.
	if awk '{for(i=1;i<=NF;i++) if ($i ~ /^(lcd_type|androidboot.mode|bootreason|androidboot.hardware)=/) print $i}' /proc/cmdline > cmdline 2>"$t/err"; then ok cmdline
	else rm -f cmdline; note cmdline "$(err)"; fi
	# Installer error messages can contain SID words on continuation lines.
	# Keep only the timestamp and known event type, never arbitrary message text.
	if awk '/^[0-9]+-[0-9]+-[0-9]+ [0-9]+:[0-9]+:[0-9]+ / {
		e="other"; if (/installed .* on /) e="installed"; else if (/stage2 removed/) e="removed";
		else if (/fast-boot-off.txt:/) e="opt-out"; else if (/refused/) e="refused";
		else if (/deferred/) e="deferred"; print $1,$2,e
	}' "$card/.userdata/h700/logs/fast-boot.txt" > policy-log 2>"$t/err"; then ok policy-log
	else rm -f policy-log; note policy-log "$(err)"; fi
fi
h="$z/loader/boot-health"
if [ -x "$h" ]; then
	rc=0; "$h" --build-id > helper-id 2> helper-id.stderr || rc=$?
	printf '%s\n' "$rc" > helper-id.exit; ok helper-id
	rc=0; "$h" > health.stdout 2> health.stderr || rc=$?
	printf '%s\n' "$rc" > health.exit; ok health.stdout; ok health.stderr
else marker helper "$h"; fi

# All dd calls read from the device into one bounded, private RAM file.
region() {
	if ! dd if="$dev" bs=512 skip="$1" count="$2" > "$t/block" 2>"$t/err"; then
		note "$3" "$(err)"; return 1
	fi
	if [ "$(wc -c < "$t/block")" -ne "$(($2 * 512))" ]; then note "$3" short-read; return 1; fi
}
for pair in 16:128 512:128 16384:128 16512:128 16640:1 16641:1 16768:96 16896:1; do
	l=${pair%:*}; n=${pair#*:}
	if [ "$l" = 16641 ] && [ "$private" = 0 ]; then note lba16641 withheld; continue; fi
	region "$l" "$n" "lba$l" || continue
	hash "lba$l.sha256" "$t/block"
	if [ "$l" = 16768 ]; then head -c 512 "$t/block" > "$t/item"; hash store-header.sha256 "$t/item"; fi
	case "$l" in
	16641) cp "$t/block" binding.bin ;;
	16640) if [ "$(head -c 15 "$t/block")" = ZERO-ATTEMPT-V1 ]; then echo pending > attempt; else
		if [ "$(tr -d '\000' < "$t/block" | wc -c)" -eq 0 ]; then echo clear > attempt; else echo other > attempt; fi; fi ;;
	*) # Public header fields, not an arbitrary sector dump from a damaged card.
		if [ "$(dd if="$t/block" bs=1 skip=4 count=8 2>/dev/null)" = eGON.BT0 ]; then
			head -c 24 "$t/block" > "lba$l.header"
			if [ "$l" = 512 ]; then od -An -tu4 -j60 -N4 "$t/block" | tr -d ' ' > dram-type; fi
			if [ "$l" = 16 ] || [ "$l" = 16768 ]; then
				bytes=$(od -An -tu4 -j16 -N4 "$t/block")
				if [ "$bytes" -ge 512 ] && [ "$bytes" -le 49152 ] && [ $((bytes % 512)) -eq 0 ]; then
					head -c "$((bytes))" "$t/block" > "$t/item"; hash "spl-$l.sha256" "$t/item"
				fi
			fi
		elif [ "$l" = 16896 ] && [ "$(head -c 8 "$t/block")" = ZEROLDR1 ]; then
			head -c 28 "$t/block" > lba16896.header
			bytes=$(od -An -tu4 -j8 -N4 "$t/block")
			if [ "$bytes" -ge 512 ] && [ "$bytes" -le 983040 ] && [ $((bytes % 512)) -eq 0 ]; then
				region 16896 "$((bytes / 512))" loader-on-card && hash loader-on-card.sha256 "$t/block"
			fi
		fi ;;
	esac
done
for f in zero-spl.bin zero-spl-lp3.bin; do filehash "$f.sha256" "$z/spl/$f"; done
filehash loader.sha256 "$z/loader/zero-loader.bin"
b=$(cat chosen 2>/dev/null || :)
case "$b" in ''|*[!a-z0-9-]*) note package invalid-board ;;
*) pkg="$z/boards/$b/package.fex"
	filehash package.sha256 "$pkg"
	if [ -s "$pkg" ]; then
		n=$(wc -c < "$pkg")
		if [ "$n" -le 16777216 ]; then
			for l in 24576 32800; do
				if region "$l" "$(((n+511)/512))" "package-$l"; then
					head -c "$n" "$t/block" > "$t/item"; hash "package-$l.sha256" "$t/item"
				fi
			done
		fi
	fi
	k=$(cat "$z/boards/$b/kernel" 2>/dev/null || :)
	case "$k" in ''|.*|*[!a-zA-Z0-9._-]*) note kernel invalid-name ;;
	*) gz="$z/boards/kernels/$k"; filehash kernel-gz.sha256 "$gz"
		if [ -s "$gz" ]; then
			if (ulimit -f 98304; gzip -dc "$gz" > "$t/item") 2>/dev/null; then
				n=$(wc -c < "$t/item"); hash kernel.sha256 "$t/item"
				if [ "$n" -gt 0 ] && [ "$n" -le 50331648 ] && region 188416 "$(((n+511)/512))" kernel-on-card; then
					head -c "$n" "$t/block" > "$t/item"; hash kernel-on-card.sha256 "$t/item"
				fi
			else note kernel read-error; fi
		fi ;;
	esac ;;
esac
boundary end
printf '1\n' > complete
