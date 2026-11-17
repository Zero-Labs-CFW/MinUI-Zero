#!/bin/sh
# bootenv.sh: faster TrimUI boot through two values in the vendor U-Boot env on internal storage (Dan, 2026-11-17:
# "Let's do and test all the things!"). loglevel=1 drops the serial console's kernel log; burn_key=0 skips U-Boot's
# factory USB key-burn wait, which only matters on a device whose secure storage is blank. Measured on the Smart Pro
# (4 warm reboots per arm, reboot command to menu): stock 16.0 s, loglevel 1 13.0 s, both 12.0 s.
#
# The values live in the DEVICE's env, so they outlive Zero. Both are harmless on stock firmware. Undo: put
# restore-boot-env.txt at the card root and boot once. That sets loglevel 8, removes burn_key if Zero set it, and
# records zero_fast_boot=off in the env, so no Zero card applies it to this device again.
#
#   bootenv.sh apply    MinUI.pak runs it in the background while /proc/cmdline still shows loglevel=8
#   bootenv.sh revert   MinUI.pak runs it when restore-boot-env.txt is on the card
#
# Every write is one fw_setenv --script call made only after every guard holds, then the whole env is read back and
# every changed line must be one we wrote; anything else is rolled back. The env itself carries Zero's state
# (zero_fast_boot = 1 loglevel only, 2 loglevel and burn_key, off = reverted); per-device files on the card only
# save a process spawn on later boots. If the env says we applied but the kernel still boots with loglevel=8,
# U-Boot is not using the copy fw_setenv writes, so the device is stopped for good.
SD="${SDCARD_PATH:?}"
SHARED="${SHARED_USERDATA_PATH:?}"
DIR="$SHARED/.minui/bootenv"
LOG="$DIR/log.txt"
CMD=$1
cmdline=; read -r cmdline < /proc/cmdline
serial=${cmdline##*androidboot.serialno=}; serial=${serial%% *}
[ "$serial" = "$cmdline" ] && serial=unknown
# card-side caches, per device; MinUI.pak tests these so a finished device pays nothing at boot
STOP="$DIR/stop-$serial" # write failed or unconfirmed: never touch this device's env again
SKIP="$DIR/skip-$serial" # a guard failed: nothing to retry
DONE="$DIR/done-$serial" # applied or reverted (the env holds the truth)
TRIGGER="$SD/restore-boot-env.txt"

mkdir -p "$DIR" 2>/dev/null
log() { echo "$(date '+%F %T') ${TRIMUI_MODEL:-?} $serial: $*" >> "$LOG"; }
mark() { touch "$1"; sync; } # rare (once per device), so a global sync is fine here
envget() { echo "$ENV" | sed -n "s/^$1=//p"; }
# U-Boot builds whose burn_key gate was measured on a device with blank secure storage (uboot_message in
# /proc/cmdline). An unlisted build still gets loglevel; burn_key waits until that build is measured.
BURN_OK_BUILDS="
2018.05(10/26/2025-11:56:42)
2018.05(04/23/2024-18:42:17)
"

case "$TRIMUI_MODEL" in
	"Trimui Brick"|"Trimui Brick Pro"|"Trimui Smart Pro") ;;
	*) [ "$CMD" = revert ] && mv -f "$TRIGGER" "$SD/restore-boot-env-FAILED.txt" 2>/dev/null; exit 0 ;;
esac

# Shared env sanity checks for both writes. Sets ENV to the current dump.
sane() {
	command -v fw_printenv >/dev/null 2>&1 && command -v fw_setenv >/dev/null 2>&1 || { why="no fw_printenv/fw_setenv"; return 1; }
	ENV=$(fw_printenv 2>&1) || { why="fw_printenv failed"; return 1; }
	echo "$ENV" | grep -qiE "bad crc|warning|cannot|error" && { why="fw_printenv: $(echo "$ENV" | grep -iE 'bad crc|warning|cannot|error' | head -1)"; return 1; }
	grep -qE "^/dev/by-name/env[[:space:]]+0x0+[[:space:]]+0x20000([[:space:]]|$)" /etc/fw_env.config 2>/dev/null || { why="fw_env.config is not the Tina layout"; return 1; }
	grep -qE "^/dev/by-name/env-redund[[:space:]]+0x0+[[:space:]]+0x20000([[:space:]]|$)" /etc/fw_env.config 2>/dev/null || { why="fw_env.config has no env-redund"; return 1; }
	[ -e /dev/by-name/env ] && [ -e /dev/by-name/env-redund ] || { why="no env partitions"; return 1; }
	[ -e /dev/by-name/app ] && { why="dual-app layout (the vendor boot script writes the env there too)"; return 1; }
	echo "$ENV" | grep -qx "bootcmd=run setargs_nand boot_normal" || { why="bootcmd is not stock"; return 1; }
	echo "$ENV" | grep -q "^parts_clean=" && { why="parts_clean is set (the vendor would wipe partitions)"; return 1; }
	echo "$ENV" | grep "^setargs_nand=" | grep -qF 'loglevel=${loglevel}' || { why="setargs_nand does not take loglevel from the env"; return 1; }
	return 0
}
# Write $1 (a fw_setenv script), then check that the env changed by exactly $2 (lines like "+ k=v" / "- k=v").
# On any surprise, write $3 (the inverse script) to put back what we changed.
write_checked() {
	before=$ENV
	fw_setenv --script "$1" >> "$LOG" 2>&1 || { log "fw_setenv failed"; return 1; }
	after=$(fw_printenv 2>&1)
	changed=$( { echo "$before" | sed 's/^/- /'; echo "$after" | sed 's/^/+ /'; } | awk '
		{ s=substr($0,3); if (substr($0,1,1)=="-") b[s]=1; else a[s]=1 }
		END { for (s in b) if (!(s in a)) print "- " s; for (s in a) if (!(s in b)) print "+ " s }' | sort)
	want=$(printf '%s\n' "$2" | grep -v '^$' | sort)
	[ "$changed" = "$want" ] && return 0
	log "readback unexpected: got [$(echo "$changed" | tr '\n' ';')] want [$(echo "$want" | tr '\n' ';')], rolling back"
	fw_setenv --script "$3" >> "$LOG" 2>&1 || log "rollback fw_setenv failed"
	return 1
}

if [ "$CMD" = revert ]; then
	if ! sane; then
		log "revert refused: $why"; mv -f "$TRIGGER" "$SD/restore-boot-env-FAILED.txt" 2>/dev/null; sync; exit 0
	fi
	zfb=$(envget zero_fast_boot)
	s="$DIR/revert.script"; inv="$DIR/revert-undo.script"; want=; : > "$s"; : > "$inv"
	if [ "$(envget loglevel)" = 1 ]; then
		echo "loglevel 8" >> "$s"; echo "loglevel 1" >> "$inv"; want="- loglevel=1
+ loglevel=8"
	fi
	if [ "$zfb" = 2 ] && [ "$(envget burn_key)" = 0 ]; then # only a burn_key Zero set
		echo "burn_key" >> "$s"; echo "burn_key 0" >> "$inv"; want="$want
- burn_key=0"
	fi
	echo "zero_fast_boot off" >> "$s"
	if [ -n "$zfb" ]; then echo "zero_fast_boot $zfb" >> "$inv"; want="$want
- zero_fast_boot=$zfb"; else echo "zero_fast_boot" >> "$inv"; fi
	[ "$zfb" = off ] && { log "revert: already reverted"; rm -f "$TRIGGER"; mark "$DONE"; exit 0; }
	want="$want
+ zero_fast_boot=off"
	if write_checked "$s" "$want" "$inv"; then
		log "revert: done ($(tr '\n' ' ' < "$s")); takes effect next boot"
		rm -f "$TRIGGER"; mark "$DONE"
	else
		log "revert FAILED"; mv -f "$TRIGGER" "$SD/restore-boot-env-FAILED.txt" 2>/dev/null; mark "$STOP"
	fi
	exit 0
fi

[ "$CMD" = apply ] || exit 0
[ -f "$STOP" ] || [ -f "$SKIP" ] || [ -f "$DONE" ] && exit 0
sleep 15 # off the boot path, and past an auto-resumed game's first seconds

# Optimize CPU calibrates by undervolting until the CPU fails and the device resets: never write the env then
for a in "$SHARED/../tg5040/undervolt/ARMED" "$SD/.userdata/tg5040/undervolt/ARMED"; do
	[ -f "$a" ] && { log "deferred: Optimize CPU calibration armed"; exit 0; }
done

sane || { log "skip: $why"; mark "$SKIP"; exit 0; }
case " $cmdline " in *" loglevel=8 "*) ;; *) exit 0 ;; esac
zfb=$(envget zero_fast_boot)
lvl=$(envget loglevel)
case "$zfb" in
	off) log "reverted earlier (zero_fast_boot=off), left alone"; mark "$DONE"; exit 0 ;;
	1|2) log "STOP: env says zero_fast_boot=$zfb loglevel=$lvl but the kernel booted with loglevel=8"; mark "$STOP"; exit 0 ;;
esac
[ "$lvl" = 8 ] || { log "skip: loglevel is '$lvl', not the stock 8 (a deliberate choice, left alone)"; mark "$SKIP"; exit 0; }

s="$DIR/apply.script"; inv="$DIR/apply-undo.script"
printf 'loglevel 1\n' > "$s"; printf 'loglevel 8\nzero_fast_boot\n' > "$inv"
want="- loglevel=8
+ loglevel=1"
level=1
ub=${cmdline##*uboot_message=}; ub=${ub%% *}
if echo "$ENV" | grep -q "^burn_key="; then
	log "burn_key already set ($(envget burn_key)), left alone"
elif ! echo "$BURN_OK_BUILDS" | grep -qxF "$ub"; then
	log "burn_key: U-Boot build '$ub' not measured, left alone"
else
	dt=$(hexdump -ve '1/1 "%02x"' /proc/device-tree/soc@03000000/target/burn_key 2>/dev/null)
	p1=$(cat /sys/block/mmcblk0/mmcblk0p1/start 2>/dev/null)
	nz=$(dd if=/dev/mmcblk0 bs=512 skip=12288 count=544 2>/dev/null | tr -d '\000' | wc -c)
	if [ "$dt" = 00000001 ] && [ -n "$p1" ] && [ "$p1" -gt 12831 ] && [ "$nz" = 0 ]; then
		echo "burn_key 0" >> "$s"; echo "burn_key" >> "$inv"; want="$want
+ burn_key=0"; level=2
	else
		log "burn_key: dt=$dt p1=$p1 secure-storage-bytes=$nz, left alone"
	fi
fi
echo "zero_fast_boot $level" >> "$s"
want="$want
+ zero_fast_boot=$level"

[ -s "$DIR/env-before-$serial.txt" ] || { echo "$ENV" > "$DIR/env-before-$serial.txt"; sync; }
if write_checked "$s" "$want" "$inv"; then
	log "applied: $(tr '\n' ' ' < "$s")(U-Boot $ub); takes effect next boot"
	mark "$DONE"
else
	log "STOP: apply failed"; mark "$STOP"
fi
