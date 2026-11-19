#!/bin/sh
# Offline harness for skeleton/SYSTEM/tg5040/bin/zerokernel.sh. Nothing here touches a device.
#
# Runs the REAL script against a fake device tree (ZK_ROOT), a fake U-Boot env (fw_printenv/fw_setenv over a
# key=value file), a fake loader (power_on: what the stock loader does with an ARMED env, per the README's
# "Loader facts"), and fakes for dd (power cut mid-write), dmesg and sleep. Power cuts kill the script with
# SIGKILL at a chosen fw_setenv or dd call.
#
# Prefers busybox ash in the local busybox:1.36 image (docker run --network none), the closest thing to the
# device shell; falls back to the host /bin/sh and says so. Usage: sh workspace/tg5040/zerokernel/run-tests.sh
set -u
HERE=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../../.." && pwd)
SCRIPT="${ZK_SCRIPT:-$ROOT/skeleton/SYSTEM/tg5040/bin/zerokernel.sh}"   # ZK_SCRIPT: run a mutant (harness self-check)
SHUTDOWN="$ROOT/skeleton/SYSTEM/tg5040/bin/shutdown"
KCLEAN="$ROOT/workspace/tg5040/zerokernel/K01zero"   # the real script /usr/lib/zero/rc/K01zero
STUB="$ROOT/workspace/tg5040/zerokernel/rc-stub"     # /etc/rc.d/S01zero and /etc/rc.d/K01zero
S01="$ROOT/workspace/tg5040/zerokernel/S01zero"
GUARD="$ROOT/workspace/tg5040/zerokernel/guard"     # /usr/lib/zero/rc/guard, started by S01zero

if [ "${1:-}" != --inner ]; then
	if command -v docker >/dev/null 2>&1 && docker image inspect busybox:1.36 >/dev/null 2>&1; then
		echo "zerokernel harness: busybox 1.36 ash (docker, no network)"
		exec docker run --rm --network none -e ZK_SCRIPT -v "$ROOT:$ROOT" -w "$ROOT" busybox:1.36 sh "$HERE/run-tests.sh" --inner
	fi
	echo "zerokernel harness: WARNING no busybox image, running under the host /bin/sh (less like the device)"
	exec sh "$HERE/run-tests.sh" --inner
fi

mkdir -p "$ROOT/.notes"
T=$(mktemp -d "$ROOT/.notes/zk-test.XXXXXX")
trap 'rc=$?; rm -rf "$T"; exit $rc' EXIT HUP INT TERM
export ZK_T="$T" ZK_GLES_WAIT=6 ZK_GUARD_WAIT=2
R="$T/root"; CARD="$T/card"; BIN="$T/bin"
export ZK_ROOT="$R" SDCARD_PATH="$CARD" SHARED_USERDATA_PATH="$CARD/.userdata/shared" SYSTEM_PATH="$CARD/.system/tg5040"
export TRIMUI_MODEL="Trimui Brick"
ZD="$SHARED_USERDATA_PATH/.minui/zerokernel"
ONCE='setenv bootcmd run setargs_nand boot_normal; saveenv'
ARMED='run zero_once; setenv boot_partition recovery; run setargs_nand boot_normal'
STOCKBC='run setargs_nand boot_normal'
SERIAL=TB0123456789
PASS=0; FAIL=0

if command -v busybox >/dev/null 2>&1; then REALDD="busybox dd"; else REALDD=/bin/dd; fi
md5() { md5sum "$1" 2>/dev/null | cut -d' ' -f1; }
# A fake stock procd: 353,800 B like the Brick's, with the Brick's bytes at the five patch sites (mk-zprocd.py), and
# what the patch must turn it into, written out here independently of zerokernel.sh's table. $1 = file, $2 = text.
mkprocd() {
	$REALDD if=/dev/zero of="$1" bs=353800 count=1 2>/dev/null
	printf '%s' "$2" | $REALDD of="$1" conv=notrunc 2>/dev/null
	for o in 47324 45848 23736 23520; do printf 'A\006\200R' | $REALDD of="$1" bs=1 seek=$o conv=notrunc 2>/dev/null; done
	printf 'udevtrigger\000' | $REALDD of="$1" bs=1 seek=54067 conv=notrunc 2>/dev/null
}
patched_procd() { # $1 = stock copy in, $2 = out
	cp "$1" "$2"
	printf 'A\000\200R' | $REALDD of="$2" bs=1 seek=47324 conv=notrunc 2>/dev/null
	printf 'A\000\200R' | $REALDD of="$2" bs=1 seek=45848 conv=notrunc 2>/dev/null
	printf 'A\001\200R' | $REALDD of="$2" bs=1 seek=23736 conv=notrunc 2>/dev/null
	printf '\241\000\200R' | $REALDD of="$2" bs=1 seek=23520 conv=notrunc 2>/dev/null
	printf '/bin/true\000\000\000' | $REALDD of="$2" bs=1 seek=54067 conv=notrunc 2>/dev/null
}

# ---------------- fakes on PATH ----------------
mkdir -p "$BIN"
cat > "$BIN/fw_printenv" <<'EOF'
#!/bin/sh
[ -f "$ZK_T/env.badcrc" ] && echo "Warning: Bad CRC, using default environment"
sort "$ZK_T/env.txt"
EOF
cat > "$BIN/fw_setenv" <<'EOF'
#!/bin/sh
[ "$1" = --script ] || exit 1
[ -f "$ZK_T/setenv.fail" ] && { echo "fake fw_setenv: write failed" >&2; exit 1; }
n=0; [ -f "$ZK_T/setenv.count" ] && read -r n < "$ZK_T/setenv.count"; n=$((n + 1)); echo "$n" > "$ZK_T/setenv.count"
if [ -n "${ZK_CUT_SETENV:-}" ] && [ "$n" = "$ZK_CUT_SETENV" ]; then   # power cut: a torn write loses (redundant env)
	kill -9 "$(cat "$ZK_T/main.pid")"; exit 1
fi
awk 'FNR==NR { if ($0 == "") next; sp = index($0, " ")
		if (sp) { k = substr($0, 1, sp - 1); set[k] = substr($0, sp + 1); gone[k] = 0 } else { gone[$0] = 1; delete set[$0] }
		next }
	{ eq = index($0, "="); k = substr($0, 1, eq - 1); if ((k in set) || gone[k] == 1) next; print }
	END { for (k in set) print k "=" set[k] }' "$2" "$ZK_T/env.txt" | sort > "$ZK_T/env.new" && mv "$ZK_T/env.new" "$ZK_T/env.txt"
EOF
cat > "$BIN/dd" <<EOF
#!/bin/sh
# real dd; never truncate the fake partition (a block device cannot be truncated); optional power cut
of=; inf=; args=
for a in "\$@"; do
	case "\$a" in of=*) of=\${a#of=} ;; if=*) inf=\${a#if=} ;; esac
	case "\$a" in conv=*) [ "$REALDD" = /bin/dd ] && a=\$(echo "\$a" | sed 's/fsync,\{0,1\}//; s/,\$//; s/^conv=\$//') ;; esac
	[ -n "\$a" ] && args="\$args \$a"
done
case "\$of" in *recovery-orig-*.tmp)
	if [ -f "$T/fail.backup" ]; then $REALDD if="\$inf" of="\$of" bs=4096 count=1 2>/dev/null; exit 1; fi ;;
esac
case "\$of" in "$T/root/dev/"*)
	case "\$args" in *notrunc*) ;; *conv=*) args=\$(echo "\$args" | sed 's/conv=/conv=notrunc,/') ;; *) args="\$args conv=notrunc" ;; esac
	if [ -n "\${ZK_CUT_DD:-}" ] && [ "\$inf" = "\$ZK_CUT_DD" ]; then
		$REALDD if="\$inf" of="\$of" bs=1024 count=20 conv=notrunc 2>/dev/null
		kill -9 "\$(cat "$T/main.pid")"; exit 1
	fi ;;
esac
exec $REALDD \$args
EOF
cat > "$BIN/df" <<'EOF'
#!/bin/sh
# real df, unless the test set a free-space figure for the card or the overlay
for a in "$@"; do last=$a; done
f=; case "$last" in "$SDCARD_PATH") f="$ZK_T/df.card" ;; */overlay) f="$ZK_T/df.overlay" ;; esac
if [ -n "$f" ] && [ -f "$f" ]; then
	echo "Filesystem 1K-blocks Used Available Use% Mounted on"; echo "/dev/fake 99999999 1 $(cat "$f") 1% $last"; exit 0
fi
exec /bin/df "$@"
EOF
printf '#!/bin/sh\ncat "$ZK_T/dmesg.txt" 2>/dev/null\n' > "$BIN/dmesg"
printf '#!/bin/sh\nexit 0\n' > "$BIN/sleep"
chmod +x "$BIN"/*
export PATH="$BIN:$PATH"

# ---------------- fake payload (small image, a few overlay files) ----------------
mkpayload() { # $1 = release id, $2 = image seed, $3 = image name (default: the release id), as stage-payload.sh
	P="$SYSTEM_PATH/kernel"; rm -rf "$P"; mkdir -p "$P/root/lib/modules/4.9.191-zero" "$P/root/usr/lib/zero/gpu/lib" \
		"$P/root/usr/lib/zero/gpu/firmware" "$P/root/etc/rc.d" "$P/root/usr/lib/zero/rc" "$P/root/usr/lib/zero/modules.d"
	{ printf 'ANDROID!'; i=0; while [ $i -lt 2000 ]; do echo "$2 kernel block $i"; i=$((i + 1)); done; } > "$P/zero-recovery.img"
	echo "pvr $1" > "$P/root/lib/modules/4.9.191-zero/pvrsrvkm.ko"
	echo "xr $1" > "$P/root/lib/modules/4.9.191-zero/xr829_core.ko"
	printf 'xr829_mac\nxr829_core\nxr829_wlan\n' > "$P/root/usr/lib/zero/modules.d/zero-xr829"
	echo "srv $1" > "$P/root/usr/lib/zero/gpu/lib/libsrv_um.so"
	echo "fw $1" > "$P/root/usr/lib/zero/gpu/firmware/rgx.fw.22.102.54.38"
	for f in S01zero K01zero; do cp "$STUB" "$P/root/etc/rc.d/$f"; done   # procd is made on the device, never shipped
	cp "$S01" "$P/root/usr/lib/zero/rc/S01zero"; cp "$KCLEAN" "$P/root/usr/lib/zero/rc/K01zero"
	[ -f "$GUARD" ] && cp "$GUARD" "$P/root/usr/lib/zero/rc/guard"
	echo "$1" > "$P/root/usr/lib/zero/VERSION"; echo "$1" > "$P/VERSION"
	( cd "$P/root" && find . -type f ! -path ./usr/lib/zero/VERSION | sort | while read -r p; do echo "$(md5 "$p")  ${p#.}"; done
	  echo "$(md5 ./usr/lib/zero/VERSION)  /usr/lib/zero/VERSION" ) > "$P/manifest.md5"
	{ [ -f "$T/known.prev" ] && cat "$T/known.prev"
	  echo "$(wc -c < "$P/zero-recovery.img" | tr -d ' ') $(md5 "$P/zero-recovery.img") ${3:-$1}-$(md5 "$P/zero-recovery.img" | cut -c1-8)"; } > "$P/known-images.txt"
	cp "$P/known-images.txt" "$T/known.prev"
	{ printf 'recovery part not used!\n'; i=0; while [ $i -lt 8 ]; do printf '\000'; i=$((i + 1)); done
	  i=0; while [ $i -lt 480 ]; do printf '\315'; i=$((i + 1)); done; } > "$P/recovery-stock-head.bin"
	IMGPATH="$P/zero-recovery.img"; IMGMD5=$(md5 "$IMGPATH"); IMGN=$(wc -c < "$IMGPATH" | tr -d ' ')
}

# ---------------- fake device ----------------
fresh_device() {
	rm -rf "$R" "$CARD" "$T/foreign" "$T/known.prev" "$T/env.badcrc" "$T/broken" "$T/loader.nosave" "$T/setenv.count" \
		"$T/setenv.fail" "$T/df.card" "$T/df.overlay" "$T/fail.backup"; : > "$T/known.prev"
	export TRIMUI_MODEL="Trimui Brick"; PARTS="boot@mmcblk0p4:rootfs@mmcblk0p5:recovery@mmcblk0p8:pstore@mmcblk0p9"
	mkdir -p "$R/proc/sys/kernel" "$R/proc/sys/vm" "$R/proc/device-tree/soc@03000000/lcd0@01c0c000" "$R/sbin" \
		"$R/dev/by-name" "$R/sys/class/block/mmcblk0p8" "$R/sys/class/power_supply/axp2202-battery" \
		"$R/sys/class/power_supply/axp2202-usb" "$R/sys/class/net/wlan0" "$R/etc/wifi" "$R/overlay" "$R/tmp" \
		"$CARD/.userdata/shared/.minui" "$CARD/.userdata/tg5040" "$SYSTEM_PATH/bin" "$R/mnt" "$T/foreign"
	cp "$SCRIPT" "$SYSTEM_PATH/bin/zerokernel.sh"   # the guard's marker for a MinUI Zero card
	ln -s "$CARD" "$R/mnt/SDCARD"; rm -f "$T/reboot.req"
	printf '/dev/by-name/env 0x00000 0x20000\n/dev/by-name/env-redund 0x00000 0x20000\n' > "$R/etc/fw_env.config"
	: > "$R/dev/by-name/env"; : > "$R/dev/by-name/env-redund"
	ln -s ../mmcblk0p8 "$R/dev/by-name/recovery"
	{ printf 'recovery part not used!\n'; i=0; while [ $i -lt 8 ]; do printf '\000'; i=$((i + 1)); done
	  i=0; while [ $i -lt 480 ]; do printf '\315'; i=$((i + 1)); done; } > "$R/dev/mmcblk0p8"
	$REALDD if=/dev/zero of="$R/dev/mmcblk0p8" bs=512 seek=1 count=32767 conv=notrunc 2>/dev/null
	echo 32768 > "$R/sys/class/block/mmcblk0p8/size"
	STOCKREC=$(md5 "$R/dev/mmcblk0p8")
	printf 'otm1289a\000' > "$R/proc/device-tree/soc@03000000/lcd0@01c0c000/lcd_driver_name"
	mkprocd "$R/sbin/procd" "stock procd 2025-11-25"
	echo 80 > "$R/sys/class/power_supply/axp2202-battery/capacity"; echo 0 > "$R/sys/class/power_supply/axp2202-usb/online"
	echo "DC:44:60:38:9A:91" > "$R/sys/class/net/wlan0/address"
	: > "$R/proc/sys/vm/drop_caches"
	cat > "$T/env.txt" <<EOF
boot_normal=sunxi_flash read 45000000 \${boot_partition};bootm 45000000
boot_partition=boot
bootcmd=$STOCKBC
burn_key=0
loglevel=1
rdinit=/rdinit
setargs_nand=setenv bootargs earlyprintk=\${earlyprintk} rdinit=\${rdinit} loglevel=\${loglevel}
zero_fast_boot=2
EOF
	UBOOT='2018.05(10/26/2025-11:56:42)'; LCD=jd9168
	mkpayload ship2 A
	# the real script, with every allowlist rootfs fingerprint pointed at the fake procd
	FP=$(md5 "$R/sbin/procd"); patched_procd "$R/sbin/procd" "$T/procd.want"; PFP=$(md5 "$T/procd.want")
	# (the procd patch list too, so every model's fake procd is one we patch; a case below takes it off the list)
	sed "s/48214f500f9d8061e2966228263b054d/$FP/; s/d2e5cca321ff95589de6f2ac0e24918c/$FP/; s/1c6b94986901b124f3ca0a9752351b06/$FP/
		s/ee0dae427ece54ac8c58c072e4e40a02/$PFP/" "$SCRIPT" > "$T/zk.sh"
}
envv() { sed -n "s/^$1=//p" "$T/env.txt"; }
# What bin/bootenv.sh does to the env and its markers, NOT the real script (it has no ZK_ROOT; its own guards are
# not tested here). revert: loglevel 8, burn_key gone, zero_fast_boot=off, done marker; refused on a bad CRC or a
# failing fw_setenv (then its stop marker). apply: on a device with no marker and no zero_fast_boot, loglevel 1,
# burn_key 0, zero_fast_boot=2, done marker.
BD="$SHARED_USERDATA_PATH/.minui/bootenv"
fake_bootenv() {
	mkdir -p "$BD"
	case "$1" in
	revert)
		if [ -f "$T/env.badcrc" ] || [ -f "$T/setenv.fail" ]; then : > "$BD/stop-$SERIAL"; return 0; fi
		[ "$(envv zero_fast_boot)" = 2 ] && setenv_raw burn_key ""
		setenv_raw loglevel 8; setenv_raw zero_fast_boot off; : > "$BD/done-$SERIAL" ;;
	apply)
		[ -f "$BD/stop-$SERIAL" ] || [ -f "$BD/skip-$SERIAL" ] || [ -f "$BD/done-$SERIAL" ] && return 0
		envhas_t zero_fast_boot && return 0
		setenv_raw loglevel 1; setenv_raw burn_key 0; setenv_raw zero_fast_boot 2; : > "$BD/done-$SERIAL" ;;
	esac
}
envhas_t() { grep -q "^$1=" "$T/env.txt"; }
setenv_raw() { grep -v "^$1=" "$T/env.txt" > "$T/env.new"; [ -n "$2" ] && echo "$1=$2" >> "$T/env.new"; sort "$T/env.new" > "$T/env.txt"; }

# What the stock loader does (README "Loader facts"): an ARMED bootcmd runs zero_once (stock bootcmd + saveenv;
# nothing after saveenv in it runs), then boots recovery. A missing zero_once fails and the list goes on (INFERRED,
# critique C2), so recovery boots with the env still ARMED. KERNEL = zero | stock | hang
power_on() {
	if [ "$(envv bootcmd)" = "$ARMED" ]; then
		if [ "$(envv zero_once)" = "$ONCE" ] && [ ! -f "$T/loader.nosave" ]; then setenv_raw bootcmd "$STOCKBC"; fi
		if [ -f "$T/broken" ] || [ "$($REALDD if="$R/dev/mmcblk0p8" bs=8 count=1 2>/dev/null)" != "ANDROID!" ]; then KERNEL=hang; else KERNEL=zero; fi
	else
		KERNEL=stock
	fi
}
# Userspace of one boot. $1 = kernel, rest: nocard | nomenu | nogpu | gles (minui wrote /tmp/zero-gles-ok) |
# gles-late | hang-health (the device hangs, or is held off, inside the GLES health wait) | cut-setenv=N | cut-dd |
# foreign (the card is another firmware: mounted, no zerokernel.sh, MinUI never runs) | slowcard (the card mounts
# 1 s into the guard's 2 s wait) | noguard (an overlay without rc/guard, as ship10's)
# Under our kernel the guard (rc/guard, started by S01zero) runs first; a restart it asks for ends this boot
# (REBOOTED=1, $T/reboot.req). The next boot() is the power-on after that restart.
userspace() {
	us_k=$1; shift
	us_card=1; us_menu=1; us_gpu=1; us_gles=0; us_hang=0; us_foreign=0; us_slow=0; us_guard=1; REBOOTED=0
	unset ZK_CUT_SETENV ZK_CUT_DD; rm -f "$T/reboot.req"
	for o in "$@"; do case "$o" in nocard) us_card=0 ;; nomenu) us_menu=0 ;; nogpu) us_gpu=0 ;; gles) us_gles=1 ;; gles-late) us_gles=2 ;;
		hang-health) us_hang=1 ;; foreign) us_foreign=1 ;; slowcard) us_slow=1 ;; noguard) us_guard=0 ;;
		cut-setenv=*) export ZK_CUT_SETENV=${o#cut-setenv=} ;; cut-dd) export ZK_CUT_DD="$SYSTEM_PATH/kernel/zero-recovery.img" ;;
		cut-dd-backup) export ZK_CUT_DD="$ZD/recovery-orig-$SERIAL.bin" ;; cut-dd-zero) export ZK_CUT_DD=/dev/zero ;; esac; done
	rm -f "$T/setenv.count"; rm -rf "$R/tmp"; mkdir -p "$R/tmp"
	[ "$us_k" = hang ] && return 0
	if [ "$us_k" = zero ]; then echo 4.9.191-zero > "$R/proc/sys/kernel/osrelease"; else echo 4.9.191 > "$R/proc/sys/kernel/osrelease"; fi
	echo "console=ttyS0 partitions=$PARTS androidboot.serialno=$SERIAL uboot_message=$UBOOT lcd=$LCD loglevel=1 rdinit=/rdinit" > "$R/proc/cmdline"
	: > "$R/proc/modules"; : > "$R/proc/mounts"
	if [ "$us_k" = zero ] && [ $us_gpu = 1 ]; then echo "pvrsrvkm 1000 0 - Live" > "$R/proc/modules"
		echo "/dev/by-name/rootfs_data /usr/lib/libsrv_um.so ext4 rw 0 0" > "$R/proc/mounts"; fi
	rm -f "$R/mnt/SDCARD"; if [ $us_foreign = 1 ]; then ln -s "$T/foreign" "$R/mnt/SDCARD"; else ln -s "$CARD" "$R/mnt/SDCARD"; fi
	US_MNT="/dev/mmcblk1p1 /mnt/SDCARD vfat rw,noatime 0 0"
	[ $us_card = 1 ] && [ $us_slow = 0 ] && echo "$US_MNT" >> "$R/proc/mounts"
	if [ "$us_k" = zero ] && [ $us_guard = 1 ] && [ -f "$R/usr/lib/zero/rc/guard" ]; then
		sed 's|^reboot$|echo reboot >> "$ZK_T/reboot.req"|' "$R/usr/lib/zero/rc/guard" > "$T/guard.sh"
		[ $us_card = 1 ] && [ $us_slow = 1 ] && ( sleep 1; echo "$US_MNT" >> "$R/proc/mounts" ) &
		sh "$T/guard.sh"; wait
		[ -f "$T/reboot.req" ] && { REBOOTED=1; return 0; }
	fi
	[ $us_card = 1 ] && [ $us_slow = 1 ] && ! grep -q " /mnt/SDCARD " "$R/proc/mounts" && echo "$US_MNT" >> "$R/proc/mounts"
	[ $us_card = 1 ] || return 0               # no card: MinUI never runs
	[ $us_foreign = 1 ] && return 0            # another firmware's card: MinUI never runs
	[ $us_menu = 1 ] && : > "$R/tmp/zero-menu-start"
	[ $us_menu = 1 ] && [ $us_gles = 1 ] && : > "$R/tmp/zero-gles-ok"
	# gles-late: an auto-resumed game, not the menu, writes the marker a few seconds later
	[ $us_menu = 1 ] && [ $us_gles = 2 ] && ( sleep 3; : > "$R/tmp/zero-gles-ok" ) &
	# launch.sh's spawn decision (builtin marker tests), then the chain. bootenv.sh revert removes the trigger.
	SPAWNED=0
	if [ -f "$CARD/restore-boot-env.txt" ]; then
		# a power cut inside zerokernel.sh revert also stops bootenv.sh revert after it (one chain in launch.sh)
		sh -c 'echo $$ > "$ZK_T/main.pid"; exec sh "$ZK_T/zk.sh" revert' && { fake_bootenv revert; rm -f "$CARD/restore-boot-env.txt"; }
		unset ZK_CUT_SETENV ZK_CUT_DD; return 0
	elif [ -f "$ZD/revert-pending-$SERIAL" ]; then
		sh -c 'echo $$ > "$ZK_T/main.pid"; exec sh "$ZK_T/zk.sh" revert'; return 0
	elif [ -f "$CARD/enable-zero-kernel.txt" ] || [ -f "$ZD/enable-pending-$SERIAL" ]; then
		# launch.sh's enable branch: enable, then (only if it succeeded) bootenv.sh apply and boot. The fake cmdline
		# says loglevel=1, so this stands in for a stock start after an undo, where it says loglevel=8.
		SPAWNED=1; rm -f "$T/main.pid"
		if sh -c 'echo $$ > "$ZK_T/main.pid"; exec sh "$ZK_T/zk.sh" enable'; then
			ENABLE_RC=0; fake_bootenv apply; sh -c 'echo $$ > "$ZK_T/main.pid"; exec sh "$ZK_T/zk.sh" boot'
		else ENABLE_RC=1; fi
		unset ZK_CUT_SETENV ZK_CUT_DD; return 0
	fi
	us_spawn=0
	if [ "$us_k" = zero ]; then us_spawn=1
	elif [ -f "$SYSTEM_PATH/kernel/VERSION" ]; then read -r us_v < "$SYSTEM_PATH/kernel/VERSION"
		[ ! -f "$ZD/off-$SERIAL" ] && [ ! -f "$ZD/skip-$SERIAL-$us_v" ] && [ ! -f "$ZD/stop-$SERIAL-$us_v" ] && us_spawn=1; fi
	SPAWNED=$us_spawn
	# hang-health: the device hangs (or is held off) 2 s into the GLES health wait (ZK_GLES_WAIT=6, no marker).
	# busybox ash runs sleep as an applet, not the fake on PATH, so the waits here are real.
	# The pid file is removed here in the foreground (a backgrounded rm can land after the spawn has written it), and
	# the killer gives up after about 5 s instead of spinning forever.
	rm -f "$T/main.pid"
	if [ $us_spawn = 1 ] && [ $us_hang = 1 ]; then
		( i=0; until [ -s "$T/main.pid" ] || [ $i -ge 50 ]; do sleep 0.1; i=$((i + 1)); done
		  sleep 2; [ -s "$T/main.pid" ] && kill -9 "$(cat "$T/main.pid")" 2>/dev/null ) &
	fi
	[ $us_spawn = 1 ] && sh -c 'echo $$ > "$ZK_T/main.pid"; exec sh "$ZK_T/zk.sh" boot'
	wait
	unset ZK_CUT_SETENV ZK_CUT_DD
	return 0
}
zblock() { # the Zero lines of bin/shutdown or K01zero, against the fake root
	sed -n '/^_zo=/,/^fi$/p' "$1" | sed "s|/proc/|$R/proc/|g; s|/usr/lib/zero/|$R/usr/lib/zero/|g; s|/tmp/|$R/tmp/|g; s|/etc/zero-kernel.state|$R/etc/zero-kernel.state|g" > "$T/zb.sh"; sh "$T/zb.sh"
}
clean_off() { zblock "$SHUTDOWN"; }   # menu power-off (PMIC cut, rc.d K* never runs)
reboot_k() { zblock "$KCLEAN"; }      # orderly reboot: procd runs /etc/rc.d/K* (File Transfer, update, dev)
stock_armed_boot() { # the loader booted stock without running an ARMED bootcmd (charger power-on?)
	rm -rf "$R/tmp"; mkdir -p "$R/tmp"; echo 4.9.191 > "$R/proc/sys/kernel/osrelease"; : > "$R/tmp/zero-menu-start"
	sh -c 'echo $$ > "$ZK_T/main.pid"; exec sh "$ZK_T/zk.sh" boot'
}
boot() { power_on; userspace "$KERNEL" "$@"; }

# ---------------- assertions ----------------
CASE=
ok() { PASS=$((PASS + 1)); }
LASTBAD=
bad() { FAIL=$((FAIL + 1)); echo "FAIL [$CASE] $*"
	[ "$LASTBAD" = "$CASE" ] || { LASTBAD=$CASE; echo "  --- zerokernel log:"; tail -n 8 "$ZD/log.txt" 2>/dev/null | sed 's/^/  /'; }; }
expect_env() { [ "$(envv "$1")" = "$2" ] && { [ -n "$2" ] || ! envhas_t "$1"; } && ok || bad "env $1='$(envv "$1")' want '$2'"; }
expect_kernel() { [ "$KERNEL" = "$1" ] && ok || bad "kernel $KERNEL want $1"; }
expect_file() { [ -e "$1" ] && ok || bad "missing $1"; }
expect_nofile() { [ ! -e "$1" ] && ok || bad "unexpected $1"; }
expect_state() { st=$(cut -d' ' -f1 "$R/usr/lib/zero/state" 2>/dev/null); [ "$st" = "$1" ] && ok || bad "state '$st' want '$1'"; }
expect_rec() { [ "$($REALDD if="$R/dev/mmcblk0p8" bs="$IMGN" count=1 2>/dev/null | md5sum | cut -d' ' -f1)" = "$1" ] && ok || bad "recovery head is not $1"; }
expect_armed() { expect_env bootcmd "$ARMED"; expect_env zero_once "$ONCE"; expect_env boot_partition boot; }
expect_stock() { expect_env bootcmd "$STOCKBC"; expect_env boot_partition boot; }
install_device() { fresh_device; boot; }

# ================= cases =================
CASE="fresh install"
install_device
expect_kernel stock; expect_armed; expect_env zero_k on; expect_env zero_k_img "ship2-$(echo "$IMGMD5" | cut -c1-8)"
expect_rec "$IMGMD5"; expect_state armed
expect_file "$ZD/recovery-orig-$SERIAL.bin"; [ "$(cat "$ZD/recovery-orig-$SERIAL.bin.md5")" = "$STOCKREC" ] && ok || bad "backup md5"
expect_file "$R/usr/lib/zero/procd"; expect_file "$R/usr/lib/zero/VERSION"; expect_file "$R/etc/rc.d/S01zero"
[ "$(cat "$R/usr/lib/zero/mac")" = "dc:44:60:38:9a:91" ] && ok || bad "MAC file"
[ -x "$R/etc/rc.d/S01zero" ] && [ -x "$R/etc/rc.d/K01zero" ] && [ -x "$R/usr/lib/zero/rc/S01zero" ] && [ -x "$R/usr/lib/zero/rc/K01zero" ] \
	&& ok || bad "rc scripts not executable"
expect_nofile "$R/usr/lib/zero/.stage"; ls "$R"/etc/rc.d/*.zk-new >/dev/null 2>&1 && bad "zk-new left in rc.d" || ok
expect_nofile "$ZD/recovery-orig-$SERIAL.bin.tmp"

CASE="healthy boot re-arm (3 boots, clean power-offs)"
for i in 1 2 3; do boot; expect_kernel zero; expect_armed; expect_state zarmed; expect_env zero_k_fail ""; clean_off; expect_state zclean; done
expect_nofile "$CARD/zero-kernel-FAILED.txt"

CASE="early power-off (before the menu), then healthy"
boot nomenu; expect_kernel zero; expect_stock
boot; expect_kernel stock; expect_env zero_k_fail 1; expect_armed
boot; expect_kernel zero; expect_armed; expect_env zero_k_fail ""

CASE="power cut at the re-arm write: counted once (state is written first), then recovers"
boot cut-setenv=1; expect_kernel zero; expect_stock; expect_state zarmed
boot; expect_kernel stock; expect_env zero_k_fail 1; expect_armed
boot; expect_kernel zero; expect_armed; expect_env zero_k_fail ""

CASE="broken image fallback x2"
install_device; : > "$T/broken"
boot; expect_kernel hang
boot; expect_kernel stock; expect_env zero_k_fail 1; expect_armed
boot; expect_kernel hang
boot; expect_kernel stock; expect_stock; expect_env zero_k failed; expect_file "$CARD/zero-kernel-FAILED.txt"
expect_file "$ZD/stop-$SERIAL-ship2"
boot; expect_kernel stock; [ "$SPAWNED" = 0 ] && ok || bad "a stopped device still spawns"
CASE="failed image, a new release retries once"
rm -f "$T/broken"; mkpayload ship3 B
boot; expect_kernel stock; expect_armed; expect_env zero_k on; expect_env zero_k_fail ""; expect_rec "$IMGMD5"
boot; expect_kernel zero; expect_armed

CASE="update with a power cut mid-dd"
install_device; boot; expect_kernel zero; clean_off
mkpayload ship3 C
boot; expect_kernel zero; expect_stock; expect_state menu   # M2: no update under a running zero kernel
boot cut-dd; expect_kernel stock; expect_stock; expect_env zero_k_img writing
boot; expect_kernel stock; expect_armed; expect_env zero_k_img "ship3-$(echo "$IMGMD5" | cut -c1-8)"; expect_rec "$IMGMD5"
[ "$(cat "$R/usr/lib/zero/VERSION")" = ship3 ] && ok || bad "overlay VERSION"
boot; expect_kernel zero; expect_armed

CASE="update with a power cut at the arm write"
install_device; boot; clean_off; mkpayload ship3 D; boot
boot cut-setenv=2; expect_kernel stock; expect_stock
boot; expect_kernel stock; expect_armed; expect_rec "$IMGMD5"

CASE="undo"
install_device; boot; clean_off
: > "$CARD/restore-boot-env.txt"; boot
expect_kernel zero; expect_stock; expect_env zero_once ""; expect_env zero_k off; expect_env zero_k_img ""
[ "$(md5 "$R/dev/mmcblk0p8")" = "$STOCKREC" ] && ok || bad "recovery not restored"
expect_nofile "$R/usr/lib/zero"; expect_nofile "$R/lib/modules/4.9.191-zero"; expect_nofile "$R/etc/zero-kernel.state"
expect_nofile "$R/etc/rc.d/K01zero"; expect_nofile "$R/etc/rc.d/S01zero"
expect_file "$ZD/off-$SERIAL"
for i in 1 2 3; do boot; expect_kernel stock; [ "$SPAWNED" = 0 ] && ok || bad "spawned after undo"; done
CASE="undo without a card backup (Brick regenerates the stock content)"
install_device; rm -f "$ZD/recovery-orig-$SERIAL.bin" "$ZD/recovery-orig-$SERIAL.bin.md5"
: > "$CARD/restore-boot-env.txt"; boot
[ "$(md5 "$R/dev/mmcblk0p8")" = "$STOCKREC" ] && ok || bad "regenerated recovery md5"
CASE="undo refused on a bad-CRC env (H1)"
install_device; : > "$T/env.badcrc"
: > "$CARD/restore-boot-env.txt"; power_on; cp "$T/env.txt" "$T/env.before"; userspace "$KERNEL"
cmp -s "$T/env.txt" "$T/env.before" && ok || bad "env written despite bad CRC"; expect_file "$CARD/zero-kernel-restore-FAILED.txt"
rm -f "$T/env.badcrc"

CASE="card missing for one boot: the guard restarts to stock, not counted once (guard)"
install_device; boot nocard; expect_kernel zero; expect_stock; [ "$REBOOTED" = 1 ] && ok || bad "no restart without a card"
expect_state nocard
boot; expect_kernel stock; expect_env zero_k_fail ""; expect_armed; expect_env zero_k on; expect_file "$ZD/nocard-$SERIAL"

CASE="allowlist mismatch at install (Brick Pro panel)"
fresh_device; LCD=gh7003; cp "$T/env.txt" "$T/env.before"; boot
cmp -s "$T/env.txt" "$T/env.before" && ok || bad "env written"; expect_file "$ZD/skip-$SERIAL-ship2"
[ "$($REALDD if="$R/dev/mmcblk0p8" bs=24 count=1 2>/dev/null)" = "recovery part not used!" ] && ok || bad "recovery touched"
CASE="allowlist mismatch after a firmware update while armed"
install_device; echo "new procd 2026" > "$R/sbin/procd"
boot; expect_kernel zero; expect_stock
boot; expect_kernel stock; expect_stock; expect_file "$ZD/skip-$SERIAL-ship2"
CASE="Optimize CPU armed: no install, no re-arm; disarm"
fresh_device; mkdir -p "$CARD/.userdata/tg5040/undervolt"; : > "$CARD/.userdata/tg5040/undervolt/ARMED"
boot; expect_stock; expect_env zero_k ""
rm -f "$CARD/.userdata/tg5040/undervolt/ARMED"; boot; expect_armed
: > "$CARD/.userdata/tg5040/undervolt/ARMED"; boot; expect_kernel zero; expect_stock; expect_state menu
rm -f "$CARD/.userdata/tg5040/undervolt/ARMED"; boot; expect_kernel stock; expect_env zero_k_fail ""; expect_armed
sh -c 'echo $$ > "$ZK_T/main.pid"; exec sh "$ZK_T/zk.sh" disarm'; expect_stock; expect_state menu
boot; expect_kernel stock; expect_env zero_k_fail ""

CASE="stuck env: loader did not save (C1)"
install_device; : > "$T/loader.nosave"
boot; expect_kernel zero; expect_stock; expect_env zero_k failed; expect_env zero_k_bad loader-save; expect_file "$CARD/zero-kernel-FAILED.txt"
rm -f "$T/loader.nosave"; boot; expect_kernel stock; expect_stock; [ "$SPAWNED" = 0 ] && ok || bad "spawned after stop"
CASE="stuck env: boot_partition persisted"
install_device; boot; setenv_raw boot_partition recovery; boot   # (env shows recovery, as if the loader saved late)
expect_stock; expect_env zero_k failed; expect_env zero_k_bad loader-partition
CASE="armed under stock once (charger power-on?): disarmed and re-armed, not final (M4)"
install_device; stock_armed_boot
expect_armed; expect_env zero_k on; expect_env zero_k_fail ""; expect_file "$ZD/loader-skip-$SERIAL"; expect_nofile "$CARD/zero-kernel-FAILED.txt"
boot; expect_kernel zero; expect_armed; expect_nofile "$ZD/loader-skip-$SERIAL"
stock_armed_boot; expect_armed; expect_env zero_k on
CASE="stuck env: armed under stock twice before a Zero start (loader skips the one-shot)"
stock_armed_boot
expect_stock; expect_env zero_k failed; expect_env zero_k_bad loader-skip; expect_file "$CARD/zero-kernel-FAILED.txt"
CASE="zero_once missing at a re-arm: every arm write puts it back (C2)"
install_device; power_on; setenv_raw zero_once ""; userspace "$KERNEL"
expect_kernel zero; expect_armed
CASE="zero_once missing when the loader runs (fake loader boots recovery, env stays armed)"
install_device; setenv_raw zero_once ""
boot; expect_kernel zero; expect_stock; expect_env zero_k failed; expect_env zero_k_bad loader-save

CASE="unhealthy zero boot (no GPU binds) x2"
install_device
boot nogpu; expect_kernel zero; expect_stock; expect_env zero_k_fail 1; expect_state bad
boot; expect_kernel stock; expect_env zero_k_fail 1; expect_armed
boot nogpu; expect_kernel zero; expect_stock; expect_env zero_k failed

CASE="GLES-menu model without the present marker never re-arms"
fresh_device
sed "s/^\(Trimui Brick|[^|]*|[^|]*|[^|]*|[^|]*\)|fb0$/\1|gles/" "$T/zk.sh" > "$T/zk.gles" && mv "$T/zk.gles" "$T/zk.sh"
grep -q '|gles$' "$T/zk.sh" && ok || bad "test setup: gles tuple not made"
boot; expect_armed
boot; expect_kernel zero; expect_stock; expect_env zero_k_fail 1; expect_state bad

CASE="three held starts in a row: the third is the last on our kernel (escape hatch, M1)"
install_device; ZIMG=$(envv zero_k_img)
boot; expect_kernel zero; expect_armed; boot; expect_kernel zero; expect_armed; expect_env zero_k on
boot; expect_kernel zero; expect_stock; expect_env zero_k failed; expect_env zero_k_bad "unclean:$ZIMG"; expect_file "$CARD/zero-kernel-FAILED.txt"
boot; expect_kernel stock; expect_stock; [ "$SPAWNED" = 0 ] && ok || bad "spawned after the unclean stop"
CASE="unclean stop is for that image only: a new release tries again (H3)"
mkpayload ship3 E
boot; expect_kernel stock; expect_armed; expect_env zero_k on; expect_rec "$IMGMD5"
boot; expect_kernel zero; expect_armed
CASE="clean power-off resets the unclean count"
install_device; boot; boot; clean_off; boot; boot; expect_armed; expect_env zero_k on

CASE="foreign recovery content is never written"
fresh_device; printf 'SOMEOTHEROS' | $REALDD of="$R/dev/mmcblk0p8" conv=notrunc 2>/dev/null; H=$(md5 "$R/dev/mmcblk0p8")
boot; expect_stock; [ "$(md5 "$R/dev/mmcblk0p8")" = "$H" ] && ok || bad "foreign recovery overwritten"


CASE="orderly reboots are not unclean sessions (K01zero, H3)"
install_device
for i in 1 2 3 4; do boot; expect_kernel zero; expect_armed; reboot_k; expect_state zclean; done
expect_env zero_k on; expect_nofile "$CARD/zero-kernel-FAILED.txt"
CASE="orderly reboot before the re-arm is benign, not a fallback (L8)"
boot nomenu; expect_kernel zero; expect_stock; reboot_k; expect_state menu
boot; expect_kernel stock; expect_env zero_k_fail ""; expect_armed
CASE="a zarmed state left from an earlier session is not called clean"
boot; expect_kernel zero; expect_state zarmed            # session ends uncleanly (held power)
boot nomenu; expect_kernel zero; reboot_k; expect_state menu   # this boot never re-armed
clean_off; expect_state menu

CASE="undo before the first boot keeps the kernel from ever installing (H1 A)"
fresh_device; : > "$CARD/restore-boot-env.txt"; boot
expect_env zero_k off; expect_file "$ZD/off-$SERIAL"; expect_stock
boot; expect_kernel stock; [ "$SPAWNED" = 0 ] && ok || bad "spawned after the opt-out"; expect_stock
[ "$($REALDD if="$R/dev/mmcblk0p8" bs=24 count=1 2>/dev/null)" = "recovery part not used!" ] && ok || bad "recovery touched"
rm -rf "$ZD"; boot; expect_env zero_k off; expect_stock; expect_nofile "$R/usr/lib/zero"   # another card: the env holds it
CASE="boot settings undone before this release (zero_fast_boot=off) keeps the kernel off (H1 B)"
fresh_device; setenv_raw zero_fast_boot off; boot
expect_stock; expect_env zero_k off; expect_file "$ZD/off-$SERIAL"; expect_nofile "$R/usr/lib/zero"
[ "$($REALDD if="$R/dev/mmcblk0p8" bs=24 count=1 2>/dev/null)" = "recovery part not used!" ] && ok || bad "recovery touched"
CASE="zero_fast_boot=off after an install stops the re-arm"
install_device; setenv_raw zero_fast_boot off
boot; expect_kernel zero; expect_stock; expect_env zero_k off
boot; expect_kernel stock; expect_stock

CASE="card too full for the recovery backup: deferred, nothing written (H2)"
fresh_device; echo 70000 > "$T/df.card"; cp "$T/env.txt" "$T/env.before"; boot
cmp -s "$T/env.txt" "$T/env.before" && ok || bad "env written"
expect_nofile "$ZD/recovery-orig-$SERIAL.bin"; expect_nofile "$ZD/recovery-orig-$SERIAL.bin.tmp"; expect_nofile "$ZD/skip-$SERIAL-ship2"
rm -f "$T/df.card"; boot; expect_armed; expect_file "$ZD/recovery-orig-$SERIAL.bin"
CASE="a failed recovery backup leaves no partial file (H2)"
fresh_device; : > "$T/fail.backup"; boot
expect_stock; expect_nofile "$ZD/recovery-orig-$SERIAL.bin"; expect_nofile "$ZD/recovery-orig-$SERIAL.bin.tmp"
expect_nofile "$ZD/recovery-orig-$SERIAL.bin.md5"
rm -f "$T/fail.backup"; boot; expect_armed

CASE="update with a short overlay: no stage and no zk-new left, retried (M2)"
install_device; boot; clean_off; mkpayload ship3 F; boot
echo 100 > "$T/df.overlay"; boot; expect_kernel stock; expect_stock
expect_nofile "$R/usr/lib/zero/.stage"; ls "$R"/etc/rc.d/*.zk-new >/dev/null 2>&1 && bad "zk-new left in rc.d" || ok
[ "$(cat "$R/usr/lib/zero/VERSION")" = ship2 ] && ok || bad "overlay VERSION changed"
rm -f "$T/df.overlay"; boot; expect_kernel stock; expect_armed; [ "$(cat "$R/usr/lib/zero/VERSION")" = ship3 ] && ok || bad "overlay VERSION"

CASE="failed undo is retried at every start and nothing arms meanwhile (M5)"
install_device; boot; clean_off
: > "$CARD/restore-boot-env.txt"; : > "$T/setenv.fail"; boot
expect_kernel zero; expect_stock; expect_env zero_k on; expect_file "$ZD/revert-pending-$SERIAL"
grep -q "tries again at every start" "$CARD/zero-kernel-restore-FAILED.txt" && ok || bad "FAILED text"
expect_nofile "$CARD/restore-boot-env.txt"     # bootenv.sh revert removed the trigger
rm -f "$T/setenv.fail"; boot
expect_kernel stock; expect_stock; expect_env zero_k off; expect_nofile "$ZD/revert-pending-$SERIAL"; expect_nofile "$R/usr/lib/zero"
[ "$(md5 "$R/dev/mmcblk0p8")" = "$STOCKREC" ] && ok || bad "recovery not restored"
CASE="boot never arms while an undo is pending"
install_device; : > "$ZD/revert-pending-$SERIAL"; rm -f "$ZD/revert-pending-$SERIAL.x"
power_on; setenv_raw bootcmd "$STOCKBC"; rm -rf "$R/tmp"; mkdir -p "$R/tmp"; echo 4.9.191 > "$R/proc/sys/kernel/osrelease"
sh -c 'echo $$ > "$ZK_T/main.pid"; exec sh "$ZK_T/zk.sh" boot'; expect_stock

CASE="a failed re-arm write is not counted as a fallback (L1)"
install_device; power_on; : > "$T/setenv.fail"; userspace "$KERNEL"; rm -f "$T/setenv.fail"
expect_kernel zero; expect_stock; expect_state menu
boot; expect_kernel stock; expect_env zero_k_fail ""; expect_armed

CASE="recovery link that disagrees with the loader's partition map is never written (L7)"
fresh_device; PARTS="boot@mmcblk0p4:recovery@mmcblk0p9"; cp "$T/env.txt" "$T/env.before"; boot
cmp -s "$T/env.txt" "$T/env.before" && ok || bad "env written"; expect_file "$ZD/skip-$SERIAL-ship2"

CASE="Smart Pro: installs, re-arms only with the GLES-present marker"
fresh_device; export TRIMUI_MODEL="Trimui Smart Pro"; UBOOT='2018.05(04/23/2024-18:42:17)'; LCD=er68576
boot; expect_kernel stock; expect_armed; expect_env zero_k on
boot; expect_kernel zero; expect_stock; expect_state bad; expect_env zero_k_fail 1
boot; expect_kernel stock; expect_armed
boot gles; expect_kernel zero; expect_armed; expect_state zarmed; expect_env zero_k_fail ""
CASE="Smart Pro: an auto-resumed boot (marker from the game, seconds later) is healthy and re-arms"
fresh_device; export TRIMUI_MODEL="Trimui Smart Pro"; UBOOT='2018.05(04/23/2024-18:42:17)'; LCD=er68576
boot; expect_kernel stock; expect_armed
boot gles-late; expect_kernel zero; expect_armed; expect_state zarmed; expect_env zero_k_fail ""
boot gles-late; expect_kernel zero; expect_armed; expect_env zero_k_fail ""
CASE="Brick Pro: installs, re-arms only with the GLES-present marker"
fresh_device; export TRIMUI_MODEL="Trimui Brick Pro"; UBOOT='2018.05(07/11/2026-11:42:17)'; LCD=gh7003
boot; expect_kernel stock; expect_armed
boot gles; expect_kernel zero; expect_armed; expect_state zarmed
CASE="Brick Pro and Smart Pro: undo puts back each one's own recovery from the card backup"
for m in "Trimui Brick Pro|2018.05(07/11/2026-11:42:17)|gh7003|priv" "Trimui Smart Pro|2018.05(04/23/2024-18:42:17)|er68576|:;I"; do
	fresh_device; export TRIMUI_MODEL="${m%%|*}"; r=${m#*|}; UBOOT=${r%%|*}; r=${r#*|}; LCD=${r%%|*}; FILL=${r#*|}
	# the real BP/SP partitions: the same text, then build-tool leftovers (not zeros) all the way through
	i=0; while [ $i -lt 4000 ]; do printf '%s %s ' "$FILL" "$i"; i=$((i + 1)); done | $REALDD of="$R/dev/mmcblk0p8" bs=1 seek=24 conv=notrunc 2>/dev/null
	ORIG=$(md5 "$R/dev/mmcblk0p8"); [ "$ORIG" != "$STOCKREC" ] && ok || bad "test setup: fill not changed"
	boot; expect_armed; [ "$(cat "$ZD/recovery-orig-$SERIAL.bin.md5")" = "$ORIG" ] && ok || bad "$TRIMUI_MODEL backup md5"
	boot gles; expect_kernel zero; expect_armed; clean_off
	: > "$CARD/restore-boot-env.txt"; boot
	expect_stock; expect_env zero_k off; [ "$(md5 "$R/dev/mmcblk0p8")" = "$ORIG" ] && ok || bad "$TRIMUI_MODEL recovery not its original"
	expect_nofile "$CARD/zero-kernel-restore-FAILED.txt"
done
CASE="Smart Pro undo without a card backup: no regenerate, recovery left inert, kernel off"
fresh_device; export TRIMUI_MODEL="Trimui Smart Pro"; UBOOT='2018.05(04/23/2024-18:42:17)'; LCD=er68576
boot; expect_armed; rm -f "$ZD/recovery-orig-$SERIAL.bin" "$ZD/recovery-orig-$SERIAL.bin.md5"
: > "$CARD/restore-boot-env.txt"; boot
expect_stock; expect_env zero_k off; expect_rec "$IMGMD5"; expect_nofile "$R/usr/lib/zero"
boot; expect_kernel stock; [ "$SPAWNED" = 0 ] && ok || bad "spawned after undo"
export TRIMUI_MODEL="Trimui Brick"

CASE="stock MAC file comes back after an overlay wipe (update path)"
install_device; boot; clean_off
rm -rf "$R/usr/lib/zero" "$R/lib/modules/4.9.191-zero" "$R/etc/wifi"; echo "DC:44:60:57:7F:91" > "$R/sys/class/net/wlan0/address"
boot; expect_kernel zero; expect_stock       # the wiped overlay is not current: no re-arm under ours (M2)
boot; expect_kernel stock; expect_armed
[ "$(cat "$R/usr/lib/zero/mac" 2>/dev/null)" = "dc:44:60:57:7f:91" ] && ok || bad "MAC file not rewritten"
CASE="no live MAC on a re-arm is not a gate"
setenv_raw bootcmd "$STOCKBC"; echo "menu x 0" > "$R/usr/lib/zero/state"   # a benign stock start, zero_k=on
rm -f "$R/sys/class/net/wlan0/address"; : > "$T/dmesg.txt"; userspace stock
expect_armed; [ "$(cat "$R/usr/lib/zero/mac")" = "dc:44:60:57:7f:91" ] && ok || bad "MAC file changed"
echo "DC:44:60:38:9A:91" > "$R/sys/class/net/wlan0/address"

CASE="a device holding an older listed dev image updates to the shipped one"
fresh_device; mkpayload ship9 G; OLDMD5=$IMGMD5; $REALDD if="$IMGPATH" of="$R/dev/mmcblk0p8" conv=notrunc 2>/dev/null
mkpayload ship10 H
boot; expect_kernel stock; expect_armed; expect_rec "$IMGMD5"; expect_env zero_k_img "ship10-$(echo "$IMGMD5" | cut -c1-8)"
[ "$OLDMD5" != "$IMGMD5" ] && ok || bad "test setup: same image"

CASE="Smart Pro with another U-Boot build is skipped"
fresh_device; export TRIMUI_MODEL="Trimui Smart Pro"; UBOOT='2018.05(10/26/2025-11:56:42)'; LCD=er68576
cp "$T/env.txt" "$T/env.before"; boot
cmp -s "$T/env.txt" "$T/env.before" && ok || bad "env written"; expect_file "$ZD/skip-$SERIAL-ship2"
export TRIMUI_MODEL="Trimui Brick"

CASE="Smart Pro: a hang inside the health window is counted, and twice stops the kernel (finding 3)"
fresh_device; export TRIMUI_MODEL="Trimui Smart Pro"; UBOOT='2018.05(04/23/2024-18:42:17)'; LCD=er68576; ZIMG=
boot; expect_kernel stock; expect_armed; ZIMG=$(envv zero_k_img)
boot hang-health; expect_kernel zero; expect_stock; expect_state health
boot; expect_kernel stock; expect_env zero_k_fail 1; expect_armed
grep -q "did not reach the menu (state 'health')" "$ZD/log.txt" && ok || bad "fallback log line"
boot hang-health; expect_kernel zero; expect_state health
boot; expect_kernel stock; expect_stock; expect_env zero_k failed; expect_env zero_k_bad "$ZIMG"; expect_file "$CARD/zero-kernel-FAILED.txt"
CASE="Smart Pro: an orderly power-off or reboot inside the health window is benign (finding 3)"
fresh_device; export TRIMUI_MODEL="Trimui Smart Pro"; UBOOT='2018.05(04/23/2024-18:42:17)'; LCD=er68576
boot; expect_armed
boot hang-health; expect_state health; clean_off; expect_state menu
boot; expect_kernel stock; expect_env zero_k_fail ""; expect_armed
boot hang-health; expect_state health; reboot_k; expect_state menu
boot; expect_kernel stock; expect_env zero_k_fail ""; expect_armed
boot gles; expect_kernel zero; expect_armed; expect_state zarmed
export TRIMUI_MODEL="Trimui Brick"

stock_start() { setenv_raw bootcmd "$STOCKBC"; echo "menu x 0" > "$R/usr/lib/zero/state"; userspace stock; }  # a benign stock start, zero_k=on
CASE="a derived MAC never replaces a stock-format file (finding 6)"
install_device
rm -f "$R/sys/class/net/wlan0/address"; echo "[    1.234] sunxi-chipid: serial: 0123456789" > "$T/dmesg.txt"
stock_start; expect_armed
[ "$(cat "$R/usr/lib/zero/mac")" = "dc:44:60:38:9a:91" ] && ok || bad "stock-format MAC file replaced by the derived one"
CASE="a derived MAC fills a missing or non-stock file (finding 6)"
rm -f "$R/usr/lib/zero/mac"; stock_start; expect_armed
[ "$(cat "$R/usr/lib/zero/mac" 2>/dev/null)" = "dc:44:74:56:78:91" ] && ok || bad "derived MAC not written to a missing file"
echo "02:1a:2b:3c:4d:5e" > "$R/usr/lib/zero/mac"; stock_start; expect_armed
[ "$(cat "$R/usr/lib/zero/mac")" = "dc:44:74:56:78:91" ] && ok || bad "derived MAC did not replace a non-stock file"
CASE="a live MAC still replaces a different stock-format file (finding 6)"
echo "DC:44:60:57:7F:91" > "$R/sys/class/net/wlan0/address"; stock_start; expect_armed
[ "$(cat "$R/usr/lib/zero/mac")" = "dc:44:60:57:7f:91" ] && ok || bad "live MAC did not win"
: > "$T/dmesg.txt"; echo "DC:44:60:38:9A:91" > "$R/sys/class/net/wlan0/address"

CASE="the zero-side re-arm re-hashes recovery: an older image of ours is rewritten (finding 7)"
fresh_device; mkpayload ship9 G; cp "$IMGPATH" "$T/old.img"; mkpayload ship10 H
boot; expect_kernel stock; expect_armed; boot; expect_kernel zero; expect_armed; clean_off
# recovery changed after this power-on loaded it: it holds the older (listed) image, the env says ship10
$REALDD if="$T/old.img" of="$R/dev/mmcblk0p8" conv=notrunc 2>/dev/null
boot; expect_kernel zero; expect_stock; expect_state menu; expect_env zero_k_fail ""
grep -q "not re-armed: recovery is 'ours:ship9-" "$ZD/log.txt" && ok || bad "rehash log line"
boot; expect_kernel stock; expect_env zero_k_fail ""; expect_armed; expect_rec "$IMGMD5"
boot; expect_kernel zero; expect_armed; expect_state zarmed; clean_off
CASE="the zero-side re-arm needs the recovery partition it booted from (finding 7)"
rm -f "$R/dev/by-name/recovery"; ln -s ../mmcblk0p9 "$R/dev/by-name/recovery"
boot; expect_kernel zero; expect_stock; expect_state menu; expect_env zero_k_fail ""
grep -q "not re-armed: no 16 MiB recovery partition" "$ZD/log.txt" && ok || bad "rec_dev log line"
rm -f "$R/dev/by-name/recovery"; ln -s ../mmcblk0p8 "$R/dev/by-name/recovery"
CASE="the zero-side re-arm re-hashes recovery: foreign bytes are never armed or written (finding 7)"
install_device; boot; expect_kernel zero; clean_off
printf 'XXXXXXXX' | $REALDD of="$R/dev/mmcblk0p8" bs=1 seek=4096 conv=notrunc 2>/dev/null; H=$(md5 "$R/dev/mmcblk0p8")
boot; expect_kernel zero; expect_stock; expect_state menu
boot; expect_kernel stock; expect_stock; expect_file "$ZD/skip-$SERIAL-ship2"
[ "$(md5 "$R/dev/mmcblk0p8")" = "$H" ] && ok || bad "foreign recovery overwritten"

# ---------------- namespace (Dan, 2026-11-19): only files Zero adds, all under /usr/lib/zero but the exceptions ----------------
listfiles() { ( cd "$R" && find . -type f ! -path './tmp/*' ! -path './proc/*' | sort ) > "$1"; }
OUTSIDE='-e ^\./usr/lib/zero/ -e ^\./lib/modules/4\.9\.191-zero/ -e ^\./etc/rc\.d/S01zero$ -e ^\./etc/rc\.d/K01zero$'
CASE="layout: Zero adds files only under /usr/lib/zero, plus the module directory and two rc.d stubs"
fresh_device; listfiles "$T/files.before"; boot; expect_armed; listfiles "$T/files.after"
NEW=$(comm -13 "$T/files.before" "$T/files.after" | grep -v $OUTSIDE)
[ -z "$NEW" ] && ok || bad "files outside the namespace: $(echo $NEW)"
[ "$(md5 "$R/sbin/procd")" = "$FP" ] && ok || bad "stock /sbin/procd changed"
cmp -s "$R/etc/rc.d/S01zero" "$STUB" && cmp -s "$R/etc/rc.d/K01zero" "$STUB" && ok || bad "rc.d entries are not the stub"
for f in procd state VERSION mac rc/S01zero rc/K01zero modules.d/zero-xr829; do expect_file "$R/usr/lib/zero/$f"; done
[ "$(md5 "$R/usr/lib/zero/procd")" = "$PFP" ] && ok || bad "patched procd md5"
[ -x "$R/usr/lib/zero/procd" ] && ok || bad "patched procd not executable"
expect_nofile "$R/usr/lib/zero/procd.tmp"; expect_nofile "$R/etc/zero-kernel.state"
grep -q procd "$SYSTEM_PATH/kernel/manifest.md5" && bad "the payload ships a procd" || ok
grep -q "procd: patched copy written ($PFP)" "$ZD/log.txt" && ok || bad "procd log line"
boot; expect_kernel zero; expect_armed; expect_state zarmed

CASE="layout: an update keeps the state and the patched procd (made on the device, not in the manifest)"
clean_off; mkpayload ship3 J; boot; expect_kernel zero; expect_state menu
boot; expect_kernel stock; expect_armed; expect_env zero_k_fail ""
[ "$(md5 "$R/usr/lib/zero/procd")" = "$PFP" ] && ok || bad "procd lost in the update"
[ "$(cat "$R/usr/lib/zero/VERSION")" = ship3 ] && ok || bad "overlay VERSION"

# what ship10 leaves on a device: state, stubs and module list outside /usr/lib/zero, procd shipped
old_layout() {
	mkdir -p "$R/etc/rc.d" "$R/etc/modules.d"
	echo '#!/bin/sh' > "$R/etc/rc.d/S01zerogpu"; echo '#!/bin/sh' > "$R/etc/rc.d/K01zeroclean"
	printf 'xr829_mac\nxr829_core\nxr829_wlan\n' > "$R/etc/modules.d/zero-xr829"
	[ -f "$R/usr/lib/zero/state" ] && mv "$R/usr/lib/zero/state" "$R/etc/zero-kernel.state"
	mkdir -p "$R/etc/wifi"; [ -f "$R/usr/lib/zero/mac" ] && mv "$R/usr/lib/zero/mac" "$R/etc/wifi/xr_wifi.conf"
	rm -rf "$R/usr/lib/zero/rc" "$R/usr/lib/zero/modules.d" "$R/etc/rc.d/S01zero" "$R/etc/rc.d/K01zero"
}
expect_old_gone() {
	for f in /etc/rc.d/S01zerogpu /etc/rc.d/K01zeroclean /etc/modules.d/zero-xr829 /etc/zero-kernel.state /etc/wifi/xr_wifi.conf; do
		expect_nofile "$R$f"; done
}
CASE="migration: a ship10 layout ends with only the new one after the update"
install_device; boot; expect_kernel zero; clean_off; expect_state zclean
old_layout; mkpayload ship3 K
boot; expect_kernel zero; expect_stock; expect_nofile "$R/usr/lib/zero/state"
[ "$(cut -d' ' -f1 "$R/etc/zero-kernel.state" 2>/dev/null)" = menu ] && ok || bad "state not kept at the ship10 path under ours"
boot; expect_kernel stock; expect_armed; expect_env zero_k_fail ""; expect_old_gone; expect_state armed
[ "$(cat "$R/usr/lib/zero/mac" 2>/dev/null)" = "dc:44:60:38:9a:91" ] && ok || bad "MAC not moved into the namespace"
for f in /etc/rc.d/S01zero /etc/rc.d/K01zero /usr/lib/zero/rc/S01zero /usr/lib/zero/rc/K01zero /usr/lib/zero/modules.d/zero-xr829; do
	expect_file "$R$f"; done
boot; expect_kernel zero; expect_armed; expect_state zarmed; reboot_k; expect_state zclean
CASE="migration: the ship10 state word still counts (a zero boot that never reached the menu)"
install_device; boot nocard noguard; expect_kernel zero; expect_stock   # state stays armed: MinUI never ran (ship10: no guard)
old_layout; [ "$(cut -d' ' -f1 "$R/etc/zero-kernel.state")" = armed ] && ok || bad "test setup: old state"
boot; expect_kernel stock; expect_env zero_k_fail 1; expect_armed; expect_nofile "$R/etc/zero-kernel.state"
CASE="migration: a benign ship10 state on a stock start is not counted"
install_device; boot; clean_off; setenv_raw bootcmd "$STOCKBC"; old_layout; echo "menu x 0" > "$R/etc/zero-kernel.state"
userspace stock; expect_armed; expect_env zero_k_fail ""; expect_state armed; expect_nofile "$R/etc/zero-kernel.state"

CASE="undo removes both layouts and leaves the device as it was"
fresh_device; listfiles "$T/files.before"; boot; boot; clean_off
old_layout; echo "menu x 0" > "$R/etc/zero-kernel.state"; mkdir -p "$R/usr/lib/zero/rc"; cp "$KCLEAN" "$R/usr/lib/zero/rc/K01zero"
for f in S01zero K01zero; do cp "$STUB" "$R/etc/rc.d/$f"; done
: > "$CARD/restore-boot-env.txt"; boot
expect_stock; expect_env zero_k off; [ "$(md5 "$R/dev/mmcblk0p8")" = "$STOCKREC" ] && ok || bad "recovery not restored"
listfiles "$T/files.after"; cmp -s "$T/files.before" "$T/files.after" && ok || bad "files differ from before the install: $(comm -3 "$T/files.before" "$T/files.after" | tr '\n' ' ')"
expect_nofile "$R/usr/lib/zero"; expect_nofile "$R/lib/modules/4.9.191-zero"; expect_old_gone
[ "$(md5 "$R/sbin/procd")" = "$FP" ] && ok || bad "stock /sbin/procd changed"
CASE="undo of a device that only has the ship10 layout"
install_device; boot; clean_off; old_layout; : > "$CARD/restore-boot-env.txt"; boot
expect_stock; expect_env zero_k off; expect_old_gone; expect_nofile "$R/usr/lib/zero"; expect_nofile "$R/etc/rc.d/S01zero"

CASE="procd: a /sbin/procd not on the patch list is never patched, and the kernel still arms (stock procd)"
fresh_device; sed "s/^$FP|$PFP\$/0123456789abcdef0123456789abcdef|$PFP/" "$T/zk.sh" > "$T/zk.x" && mv "$T/zk.x" "$T/zk.sh"
grep -q "^0123456789abcdef0123456789abcdef|$PFP\$" "$T/zk.sh" && ok || bad "test setup: patch list not changed"
boot; expect_armed; expect_nofile "$R/usr/lib/zero/procd"; expect_nofile "$R/usr/lib/zero/procd.tmp"
grep -q "procd: /sbin/procd is $FP, not one we patch: stock procd runs" "$ZD/log.txt" && ok || bad "refusal log line"
boot; expect_kernel zero; expect_armed; clean_off
CASE="procd: a patched copy that does not belong to this /sbin/procd is removed on a stock start"
cp "$T/procd.want" "$R/usr/lib/zero/procd"; stock_start; expect_armed; expect_nofile "$R/usr/lib/zero/procd"
grep -q "removed the patched copy" "$ZD/log.txt" && ok || bad "removal log line"
CASE="procd: a result with the wrong md5 is never installed, and the kernel still arms (stock procd)"
fresh_device; sed "s/^$FP|$PFP\$/$FP|fedcba9876543210fedcba9876543210/" "$T/zk.sh" > "$T/zk.x" && mv "$T/zk.x" "$T/zk.sh"
grep -q "^$FP|fedcba9876543210fedcba9876543210\$" "$T/zk.sh" && ok || bad "test setup: result md5 not changed"
boot; expect_armed; expect_nofile "$R/usr/lib/zero/procd"; expect_nofile "$R/usr/lib/zero/procd.tmp"
grep -q "procd: patched copy is $PFP, want fedcba9876543210fedcba9876543210: not installed" "$ZD/log.txt" && ok || bad "refusal log line"
boot; expect_kernel zero; expect_armed
CASE="procd: made again on a stock start when it is missing or damaged"
install_device; rm -f "$R/usr/lib/zero/procd"; stock_start; expect_armed
[ "$(md5 "$R/usr/lib/zero/procd")" = "$PFP" ] && ok || bad "missing procd not made again"
echo damaged > "$R/usr/lib/zero/procd"; stock_start; expect_armed
[ "$(md5 "$R/usr/lib/zero/procd")" = "$PFP" ] && ok || bad "damaged procd not replaced"
CASE="procd: the zero kernel side never writes it"
boot; expect_kernel zero; expect_armed; rm -f "$R/usr/lib/zero/procd"; clean_off
boot; expect_kernel zero; expect_armed; expect_nofile "$R/usr/lib/zero/procd"

CASE="rc.d stubs: nothing on the stock kernel, the real script of the same name under ours"
install_device; mkdir -p "$T/stub"; rm -f "$T/ran"
for f in S01zero K01zero; do
	sed "s|/proc/|$R/proc/|g; s|/usr/lib/zero/|$R/usr/lib/zero/|g" "$STUB" > "$T/stub/$f"
	printf '#!/bin/sh\necho "${0##*/} $*" >> "%s"\n' "$T/ran" > "$R/usr/lib/zero/rc/$f"
done
echo 4.9.191 > "$R/proc/sys/kernel/osrelease"
sh "$T/stub/S01zero" boot && sh "$T/stub/K01zero" shutdown && ok || bad "stub exit status on stock"
expect_nofile "$T/ran"
echo 4.9.191-zero > "$R/proc/sys/kernel/osrelease"
sh "$T/stub/S01zero" boot; sh "$T/stub/K01zero" shutdown
[ "$(cat "$T/ran" 2>/dev/null | tr '\n' ';')" = "S01zero boot;K01zero shutdown;" ] && ok || bad "stubs ran '$(cat "$T/ran" 2>/dev/null | tr '\n' ';')'"
rm -f "$R/usr/lib/zero/rc/S01zero" "$T/ran"; sh "$T/stub/S01zero" boot && ok || bad "stub fails without its real script"
expect_nofile "$T/ran"

CASE="S01zero: nothing on the stock kernel; under ours the GPU backstop and the WiFi list"
install_device; mkdir -p "$R/usr/lib" "$R/lib/firmware"; : > "$R/usr/lib/libsrv_um.so"; : > "$R/lib/firmware/rgx.fw.22.102.54.38"
printf '#!/bin/sh\necho "kmodloader $*" >> "%s"\n' "$T/s01.log" > "$R/sbin/kmodloader"; chmod +x "$R/sbin/kmodloader"
{ printf 'zk_mount() { echo "mount $*" >> "%s"; }\nzk_guard() { echo guard >> "%s"; }\n' "$T/s01.log" "$T/guard.ran"
  sed "s|/bin/sh /usr/lib/zero/rc/guard|zk_guard|; s|\$(uname -r)|\$(cat @OSR@)|; s|/usr/lib/|$R/usr/lib/|g; s|/lib/firmware/|$R/lib/firmware/|g
	s|/proc/|$R/proc/|g; s|/sbin/|$R/sbin/|g; s|/tmp/|$R/tmp/|g; s|mount --bind|zk_mount --bind|g; s|@OSR@|$R/proc/sys/kernel/osrelease|" "$S01"; } > "$T/s01.sh"
rm -f "$T/s01.log" "$T/guard.ran"; echo 4.9.191 > "$R/proc/sys/kernel/osrelease"; : > "$R/proc/mounts"
sh "$T/s01.sh" boot && ok || bad "S01zero exit status on stock"; expect_nofile "$T/s01.log"; expect_nofile "$T/guard.ran"
echo 4.9.191-zero > "$R/proc/sys/kernel/osrelease"; sh "$T/s01.sh" boot
i=0; until [ -f "$T/guard.ran" ] || [ $i -ge 20 ]; do sleep 0.1; i=$((i + 1)); done
[ "$(cat "$T/guard.ran" 2>/dev/null)" = guard ] && ok || bad "S01zero did not start the guard under ours"
G="$R/usr/lib/zero/gpu"
[ "$(cat "$T/s01.log" 2>/dev/null | tr '\n' ';')" = "mount --bind $G/lib/libsrv_um.so $R/usr/lib/libsrv_um.so;mount --bind $G/firmware/rgx.fw.22.102.54.38 $R/lib/firmware/rgx.fw.22.102.54.38;kmodloader $R/tmp/zero-modules.d/;" ] \
	&& ok || bad "S01zero ran '$(cat "$T/s01.log" 2>/dev/null | tr '\n' ';')'"
rm -f "$T/s01.log"; echo "/dev/x $R/lib/firmware/rgx.fw.22.102.54.38 ext4 rw 0 0" > "$R/proc/mounts"; sh "$T/s01.sh" boot
[ "$(cat "$T/s01.log" 2>/dev/null)" = "kmodloader $R/tmp/zero-modules.d/" ] && ok || bad "zinit's binds already there: S01zero ran '$(cat "$T/s01.log" 2>/dev/null)'"
[ "$(cat "$R/tmp/zero-modules.d/zero-xr829" 2>/dev/null | tr '\n' ';')" = "xr829_mac;xr829_core macaddr=dc:44:60:38:9a:91;xr829_wlan;" ] \
	&& ok || bad "WiFi list with the MAC option '$(cat "$R/tmp/zero-modules.d/zero-xr829" 2>/dev/null | tr '\n' ';')'"
cmp -s "$R/usr/lib/zero/modules.d/zero-xr829" "$SYSTEM_PATH/kernel/root/usr/lib/zero/modules.d/zero-xr829" && ok || bad "shipped list changed"
CASE="S01zero: without a MAC the shipped list loads as is"
rm -f "$T/s01.log" "$R/usr/lib/zero/mac"; rm -rf "$R/tmp/zero-modules.d"; sh "$T/s01.sh" boot
[ "$(cat "$T/s01.log" 2>/dev/null)" = "kmodloader $R/usr/lib/zero/modules.d/" ] && ok || bad "no MAC: S01zero ran '$(cat "$T/s01.log" 2>/dev/null)'"
echo "02:1a:2b:3c:4d:5e" > "$R/usr/lib/zero/mac"; rm -f "$T/s01.log"; sh "$T/s01.sh" boot
[ "$(cat "$T/s01.log" 2>/dev/null)" = "kmodloader $R/usr/lib/zero/modules.d/" ] && ok || bad "non-stock MAC passed as an option"

# ---------------- review fixes (2026-11-19) ----------------
CASE="MAC: a ship10 MAC file is moved into the namespace even with no live MAC, then removed"
install_device; boot; clean_off; old_layout; rm -f "$R/sys/class/net/wlan0/address"; : > "$T/dmesg.txt"; mkpayload ship3 L
boot; expect_kernel zero; boot; expect_kernel stock; expect_armed
[ "$(cat "$R/usr/lib/zero/mac" 2>/dev/null)" = "dc:44:60:38:9a:91" ] && ok || bad "ship10 MAC not carried over"
expect_old_gone; echo "DC:44:60:38:9A:91" > "$R/sys/class/net/wlan0/address"
CASE="MAC: a random MAC our driver saved at the compiled-in path is removed on a stock start"
echo "02:1a:2b:3c:4d:5e" > "$R/etc/wifi/xr_wifi.conf"; stock_start; expect_armed; expect_nofile "$R/etc/wifi/xr_wifi.conf"
[ "$(cat "$R/usr/lib/zero/mac")" = "dc:44:60:38:9a:91" ] && ok || bad "MAC changed"
CASE="MAC: a file the read-only root ships at that path is never read, removed or hidden"
fresh_device; mkdir -p "$R/rom/etc/wifi"; echo "dc:44:11:22:33:44" > "$R/rom/etc/wifi/xr_wifi.conf"; cp "$R/rom/etc/wifi/xr_wifi.conf" "$R/etc/wifi/xr_wifi.conf"
rm -f "$R/sys/class/net/wlan0/address"; : > "$T/dmesg.txt"; boot; expect_stock; expect_nofile "$R/usr/lib/zero/mac"
echo "DC:44:60:38:9A:91" > "$R/sys/class/net/wlan0/address"; boot; expect_armed
[ "$(cat "$R/usr/lib/zero/mac")" = "dc:44:60:38:9a:91" ] && ok || bad "live MAC not used"
: > "$CARD/restore-boot-env.txt"; boot; expect_env zero_k off
[ "$(cat "$R/etc/wifi/xr_wifi.conf" 2>/dev/null)" = "dc:44:11:22:33:44" ] && ok || bad "stock file removed by undo"
CASE="undo after a first install deferred with only the MAC saved keeps the never-installed path"
fresh_device; echo 70000 > "$T/df.card"; boot; expect_stock; expect_file "$R/usr/lib/zero/mac"; rm -f "$T/df.card"
: > "$CARD/restore-boot-env.txt"; boot; expect_env zero_k off; expect_nofile "$R/usr/lib/zero"
grep -q "revert: never installed" "$ZD/log.txt" && ok || bad "not the never-installed path"

CASE="image id: a release with the same kernel image keeps the id, and a stop on that image holds"
fresh_device; mkpayload ship10 H; boot; expect_armed; ZIMG=$(envv zero_k_img)
boot; boot; boot; expect_kernel zero; expect_env zero_k failed; expect_env zero_k_bad "unclean:$ZIMG"
mkpayload ship10.1 H ship10; [ "$(tail -n 1 "$SYSTEM_PATH/kernel/known-images.txt" | cut -d' ' -f3)" = "$ZIMG" ] && ok || bad "image id changed"
cp "$T/env.txt" "$T/env.before"; boot; expect_kernel stock; expect_stock; [ "$SPAWNED" = 1 ] && ok || bad "test setup: not spawned"
cmp -s "$T/env.txt" "$T/env.before" && ok || bad "env written for a stopped image"; expect_file "$ZD/stop-$SERIAL-ship10.1"
CASE="image id: a pending fail count on the same image survives an overlay-only release, and recovery is not rewritten"
fresh_device; mkpayload ship10 H; boot; expect_armed
boot nomenu; expect_kernel zero; expect_stock
mkpayload ship10.1 H ship10; boot; expect_kernel stock; expect_armed; expect_env zero_k_fail 1
[ "$(cat "$R/usr/lib/zero/VERSION")" = ship10.1 ] && ok || bad "overlay not updated"
grep -q "recovery already holds ship10-" "$ZD/log.txt" && ok || bad "recovery rewritten"
boot nomenu; expect_kernel zero; boot; expect_kernel stock; expect_stock; expect_env zero_k failed
CASE="image id: a new image still resets the count"
fresh_device; boot; boot nomenu; mkpayload ship3 M; boot; expect_armed; expect_env zero_k_fail ""

CASE="window: ship10 overlay under ours, a hang in the health check, then the old K01zeroclean on a reboot is benign"
fresh_device; export TRIMUI_MODEL="Trimui Smart Pro"; UBOOT='2018.05(04/23/2024-18:42:17)'; LCD=er68576
boot; expect_armed; boot gles; expect_kernel zero; expect_armed; clean_off; old_layout; mkpayload ship3 N
sed 's|/usr/lib/zero/state|/etc/zero-kernel.state|g' "$KCLEAN" > "$T/K01zeroclean"   # what ship10's K01zeroclean reads
boot hang-health; expect_kernel zero; [ "$(cut -d' ' -f1 "$R/etc/zero-kernel.state")" = health ] && ok || bad "health not at the ship10 path"
zblock "$T/K01zeroclean"; [ "$(cut -d' ' -f1 "$R/etc/zero-kernel.state")" = menu ] && ok || bad "old K01zeroclean did not clean up"
boot; expect_kernel stock; expect_env zero_k_fail ""; expect_armed; expect_old_gone
CASE="window: the new bin/shutdown cleans up the ship10 path too"
boot gles; expect_kernel zero; clean_off; old_layout; echo "health x 0" > "$R/etc/zero-kernel.state"
echo 4.9.191-zero > "$R/proc/sys/kernel/osrelease"; clean_off
[ "$(cut -d' ' -f1 "$R/etc/zero-kernel.state")" = menu ] && ok || bad "bin/shutdown missed the ship10 path"
export TRIMUI_MODEL="Trimui Brick"

CASE="going back to ship10 and forward again: its state file wins over a stale one of ours"
install_device; boot; expect_state zarmed; clean_off; echo "zarmed x 2" > "$T/stale"
old_layout; echo "menu x 0" > "$R/etc/zero-kernel.state"; cp "$T/stale" "$R/usr/lib/zero/state"
setenv_raw bootcmd "$STOCKBC"; userspace stock; expect_armed; expect_env zero_k_fail ""; expect_old_gone
boot; expect_kernel zero; expect_armed; [ "$(cut -d' ' -f3 "$R/usr/lib/zero/state")" = 0 ] && ok || bad "stale unclean count used"

CASE="power cut after the VERSION swap: the ship10 files left behind go at the next stock start"
install_device; boot; clean_off
echo '#!/bin/sh' > "$R/etc/rc.d/S01zerogpu"; mkdir -p "$R/etc/modules.d"; printf 'xr829_core\n' > "$R/etc/modules.d/zero-xr829"
stock_start; expect_armed; expect_old_gone

# ---------------- turn back on after an undo: enable-zero-kernel.txt (Dan, 2026-11-19) ----------------
EN="$CARD/enable-zero-kernel.txt"
expect_on_again() { # the enable start: undo state gone, boot settings back (fake apply), kernel installed and armed
	expect_kernel stock; expect_nofile "$EN"; expect_nofile "$ZD/enable-pending-$SERIAL"; expect_nofile "$ZD/off-$SERIAL"
	expect_env zero_fast_boot 2; expect_env loglevel 1; expect_file "$BD/done-$SERIAL"
	expect_armed; expect_env zero_k on; expect_rec "$IMGMD5"; expect_file "$R/usr/lib/zero/VERSION"
}
undo_now() { : > "$CARD/restore-boot-env.txt"; boot; }
CASE="enable: off, then on (kernel reinstalled, boot settings back, the card backup kept)"
install_device; boot; clean_off; BKM=$(cat "$ZD/recovery-orig-$SERIAL.bin.md5")
undo_now; expect_kernel zero; expect_env zero_k off; expect_env zero_fast_boot off; expect_env loglevel 8; expect_env burn_key ""
boot; expect_kernel stock; [ "$SPAWNED" = 0 ] && ok || bad "spawned after undo"
: > "$EN"; boot; expect_on_again
[ "$(cat "$ZD/recovery-orig-$SERIAL.bin.md5")" = "$BKM" ] && [ "$(md5 "$ZD/recovery-orig-$SERIAL.bin")" = "$BKM" ] && ok || bad "card backup changed"
grep -q "enable: cleared zero_k zero_fast_boot" "$ZD/log.txt" && ok || bad "enable log line"
boot; expect_kernel zero; expect_armed; expect_state zarmed; clean_off
CASE="enable: off, on, off, on again"
for i in 1 2; do
	undo_now; expect_stock; expect_env zero_k off; expect_env zero_fast_boot off
	[ "$(md5 "$R/dev/mmcblk0p8")" = "$STOCKREC" ] && ok || bad "recovery not restored (round $i)"
	boot; [ "$SPAWNED" = 0 ] && ok || bad "spawned after undo (round $i)"
	: > "$EN"; boot; expect_on_again
	boot; expect_kernel zero; expect_armed; clean_off
done
CASE="enable: twice (already on) is a no-op, and the re-arm under ours still runs"
: > "$EN"; boot
expect_kernel zero; expect_nofile "$EN"; expect_armed; expect_env zero_k on; expect_state zarmed
grep -q "enable: no undo in the env, nothing to turn back on" "$ZD/log.txt" && ok || bad "no-op log line"
: > "$EN"; boot; expect_kernel zero; expect_nofile "$EN"; expect_armed; expect_env zero_fast_boot 2
CASE="enable: on a device with no undo before (fresh) is a no-op, then the install runs as usual"
fresh_device; : > "$EN"; boot; expect_kernel stock; expect_nofile "$EN"; expect_armed; expect_env zero_k on
expect_env zero_fast_boot 2; expect_nofile "$CARD/enable-zero-kernel-FAILED.txt"
CASE="enable: both files on the card, the undo wins and the enable file is set aside"
install_device; boot; clean_off
: > "$EN"; : > "$CARD/restore-boot-env.txt"; boot
expect_env zero_k off; expect_env zero_fast_boot off; expect_nofile "$EN"; expect_file "$CARD/enable-zero-kernel-IGNORED.txt"
grep -q "rename this file to enable-zero-kernel.txt" "$CARD/enable-zero-kernel-IGNORED.txt" && ok || bad "IGNORED note text"
boot; expect_kernel stock; [ "$SPAWNED" = 0 ] && ok || bad "the set-aside file fired"; expect_env zero_k off
mv "$CARD/enable-zero-kernel-IGNORED.txt" "$EN"; boot; expect_on_again
CASE="enable: next to an undo still pending, the undo goes first and the enable file is set aside"
boot; clean_off; : > "$T/setenv.fail"; undo_now; expect_file "$ZD/revert-pending-$SERIAL"; expect_env zero_k on
: > "$EN"; rm -f "$T/setenv.fail"; boot
expect_stock; expect_env zero_k off; expect_nofile "$ZD/revert-pending-$SERIAL"; expect_nofile "$EN"; expect_file "$CARD/enable-zero-kernel-IGNORED.txt"
CASE="enable: a failed env write keeps a pending marker, nothing arms, and the next start finishes it"
install_device; boot; clean_off; undo_now; rm -f "$CARD/enable-zero-kernel-IGNORED.txt"
: > "$EN"; : > "$T/setenv.fail"; boot
[ "$ENABLE_RC" = 1 ] && ok || bad "enable did not fail"; expect_stock; expect_env zero_k off; expect_env zero_fast_boot off
expect_file "$ZD/enable-pending-$SERIAL"; expect_file "$ZD/off-$SERIAL"; expect_file "$BD/done-$SERIAL"; expect_nofile "$EN"
grep -q "Zero tries again at every start" "$CARD/enable-zero-kernel-FAILED.txt" && ok || bad "FAILED text"
boot; [ "$ENABLE_RC" = 1 ] && ok || bad "pending not retried"; expect_stock; expect_env zero_k off
rm -f "$T/setenv.fail"; boot; expect_on_again; expect_nofile "$CARD/enable-zero-kernel-FAILED.txt"
boot; expect_kernel zero; expect_armed
CASE="enable: a bad-CRC env is refused, nothing written, pending kept"
undo_now; : > "$EN"; : > "$T/env.badcrc"; cp "$T/env.txt" "$T/env.before"; boot
cmp -s "$T/env.txt" "$T/env.before" && ok || bad "env written despite bad CRC"; expect_file "$ZD/enable-pending-$SERIAL"
rm -f "$T/env.badcrc"; boot; expect_on_again
CASE="enable: a readback surprise rolls back and stays pending"
undo_now; : > "$EN"
mv "$BIN/fw_setenv" "$BIN/fw_setenv.real"
printf '#!/bin/sh\n"%s" "$@"; rc=$?; [ -f "$ZK_T/setenv.extra" ] && echo "stray=1" >> "$ZK_T/env.txt"; exit $rc\n' "$BIN/fw_setenv.real" > "$BIN/fw_setenv"; chmod +x "$BIN/fw_setenv"
: > "$T/setenv.extra"; boot; rm -f "$T/setenv.extra"; setenv_raw stray ""
[ "$ENABLE_RC" = 1 ] && ok || bad "readback surprise accepted"; expect_env zero_k off; expect_env zero_fast_boot off; expect_file "$ZD/enable-pending-$SERIAL"
mv -f "$BIN/fw_setenv.real" "$BIN/fw_setenv"
boot; expect_on_again
CASE="enable: a failed image (zero_k=failed, stop marker) stays stopped; only the boot settings come back"
install_device; : > "$T/broken"; boot; boot; boot; boot; expect_env zero_k failed; expect_file "$ZD/stop-$SERIAL-ship2"
cp "$T/env.txt" "$T/env.pre"; : > "$EN"; boot
cmp -s "$T/env.txt" "$T/env.pre" && ok || bad "enable wrote to a stopped device's env"
expect_env zero_k failed; expect_file "$ZD/stop-$SERIAL-ship2"; expect_stock; expect_nofile "$EN"; [ "$ENABLE_RC" = 0 ] && ok || bad "enable rc"
grep -q "enable: zero_k=failed kept" "$ZD/log.txt" && ok || bad "failed kept log line"
grep -q "enable: stop-$SERIAL-ship2 kept" "$ZD/log.txt" && ok || bad "stop kept log line"
CASE="enable: a failed image with only the boot settings undone: those come back, the image stays stopped"
setenv_raw zero_fast_boot off; setenv_raw loglevel 8; setenv_raw burn_key ""; mkdir -p "$BD"; : > "$BD/done-$SERIAL"
: > "$EN"; boot
expect_env zero_k failed; expect_file "$ZD/stop-$SERIAL-ship2"; expect_stock; expect_env zero_fast_boot 2; expect_env loglevel 1
boot; expect_kernel stock; [ "$SPAWNED" = 0 ] && ok || bad "a stopped device spawns after enable"
rm -f "$T/broken"
CASE="enable: an allowlist skip and a bootenv stop are kept"
fresh_device; LCD=gh7003; boot; expect_file "$ZD/skip-$SERIAL-ship2"; mkdir -p "$BD"; : > "$BD/stop-$SERIAL"
: > "$CARD/restore-boot-env.txt"; boot; expect_env zero_k off; expect_env zero_fast_boot off
: > "$EN"; boot; expect_env zero_k ""; expect_env zero_fast_boot ""; expect_file "$ZD/skip-$SERIAL-ship2"; expect_file "$BD/stop-$SERIAL"
expect_stock; expect_nofile "$ZD/off-$SERIAL"
grep -q "enable: skip-$SERIAL-ship2 kept" "$ZD/log.txt" && ok || bad "skip kept log line"
grep -q "enable: stop-$SERIAL kept" "$ZD/log.txt" && ok || bad "bootenv stop kept log line"
LCD=jd9168
CASE="enable: armed or mid-install env is never touched"
fresh_device; power_on; setenv_raw zero_k installing; setenv_raw zero_k_img writing; setenv_raw bootcmd "$ARMED"; cp "$T/env.txt" "$T/env.pre"
echo 4.9.191 > "$R/proc/sys/kernel/osrelease"; : > "$EN"
echo "console=ttyS0 partitions=$PARTS androidboot.serialno=$SERIAL uboot_message=$UBOOT lcd=$LCD loglevel=8 rdinit=/rdinit" > "$R/proc/cmdline"
sh -c 'echo $$ > "$ZK_T/main.pid"; exec sh "$ZK_T/zk.sh" enable'
cmp -s "$T/env.txt" "$T/env.pre" && ok || bad "enable wrote to an armed, mid-install env"; expect_nofile "$EN"
CASE="enable: undo before the first boot, then on: installs as a fresh device"
fresh_device; undo_now; expect_env zero_k off; expect_env zero_fast_boot off; boot; [ "$SPAWNED" = 0 ] && ok || bad "spawned"
: > "$EN"; boot; expect_on_again; expect_file "$ZD/recovery-orig-$SERIAL.bin"
CASE="enable: a hand-cleared env with the markers left (the dev unit, 2026-11-19) gets its markers cleared"
install_device; boot; clean_off; undo_now; setenv_raw zero_k ""; setenv_raw zero_fast_boot ""
boot; [ "$SPAWNED" = 0 ] && ok || bad "test setup: the off marker should still stop the spawn"
: > "$EN"; boot; expect_on_again
CASE="enable: from our kernel (no undo, nothing to clear) the chain still re-arms"
boot; expect_kernel zero; clean_off; : > "$EN"; boot; expect_kernel zero; expect_armed; expect_state zarmed; expect_nofile "$EN"
# A kernel that stopped, then an undo, then enable (review 2026-11-19): the undo keeps zero_k_bad, enable puts
# zero_k=failed back from it, so boot's failed case decides as before the undo.
CASE="enable: failed, undo, on: the stopped image stays stopped (same card, a later release with the same image)"
install_device; : > "$T/broken"; boot; boot; boot; boot; expect_env zero_k failed; ZBAD=$(envv zero_k_bad)
[ -n "$ZBAD" ] && ok || bad "test setup: no zero_k_bad"
undo_now; expect_stock; expect_env zero_k off; expect_env zero_k_bad "$ZBAD"; expect_env zero_fast_boot off
: > "$EN"; boot; expect_kernel stock; expect_stock; expect_env zero_k failed; expect_env zero_k_bad "$ZBAD"
expect_env zero_fast_boot 2; expect_nofile "$EN"; expect_nofile "$ZD/off-$SERIAL"; expect_file "$ZD/stop-$SERIAL-ship2"
[ "$(md5 "$R/dev/mmcblk0p8")" = "$STOCKREC" ] && ok || bad "the stopped image was written again"
grep -q "enable: cleared zero_k (back to failed, zero_k_bad=$ZBAD) zero_fast_boot" "$ZD/log.txt" && ok || bad "restored log line"
boot; [ "$SPAWNED" = 0 ] && ok || bad "a stopped device spawns after enable"
rm -f "$T/broken"; mkpayload ship3 A ship2   # an overlay-only release: same image id, no stop marker for it yet
boot; expect_kernel stock; expect_stock; expect_env zero_k failed; expect_file "$ZD/stop-$SERIAL-ship3"
[ "$(md5 "$R/dev/mmcblk0p8")" = "$STOCKREC" ] && ok || bad "the same image was installed again after an undo"
CASE="enable: failed, undo, on: a new image still gets its retry"
mkpayload ship4 B; boot; expect_kernel stock; expect_armed; expect_env zero_k on; expect_rec "$IMGMD5"
boot; expect_kernel zero; expect_armed; clean_off
CASE="enable: a loader stop (final) survives an undo and an enable"
install_device; : > "$T/loader.nosave"; boot; expect_env zero_k failed; expect_env zero_k_bad loader-save; rm -f "$T/loader.nosave"
undo_now; expect_kernel stock; expect_env zero_k off; expect_env zero_k_bad loader-save
: > "$EN"; boot; expect_stock; expect_env zero_k failed; expect_env zero_k_bad loader-save; expect_nofile "$ZD/off-$SERIAL"
mkpayload ship3 B; boot; expect_kernel stock; expect_stock; expect_env zero_k failed; expect_file "$ZD/stop-$SERIAL-ship3"
CASE="enable: failed, undo, on, undo, on: zero_k_bad carries through every round"
undo_now; expect_env zero_k off; expect_env zero_k_bad loader-save
: > "$EN"; boot; expect_env zero_k failed; expect_env zero_k_bad loader-save; expect_stock
CASE="enable: the IGNORED note failing to write still takes the enable file off the card"
install_device; boot; clean_off; : > "$EN"; : > "$CARD/restore-boot-env.txt"; mkdir "$CARD/enable-zero-kernel-IGNORED.txt"
boot; expect_env zero_k off; expect_nofile "$EN"; rmdir "$CARD/enable-zero-kernel-IGNORED.txt"
boot; [ "$SPAWNED" = 0 ] && ok || bad "the enable file fired after the undo"; expect_env zero_k off
CASE="enable: an undo clears a stale enable FAILED note"
: > "$CARD/enable-zero-kernel-FAILED.txt"; undo_now; expect_nofile "$CARD/enable-zero-kernel-FAILED.txt"

# ---------------- release review 2026-11-19 ----------------
UVA="$CARD/.userdata/tg5040/undervolt/ARMED"
uv_on() { mkdir -p "${UVA%/*}"; : > "$UVA"; }
recmd5() { md5 "$R/dev/mmcblk0p8"; }
envdiff() { diff "$T/env.before" "$T/env.txt" | tr '\n' ' '; }
CASE="review 1: Optimize CPU armed on a stock start: a new release writes nothing"
install_device; boot; expect_kernel zero; clean_off
sh -c 'echo $$ > "$ZK_T/main.pid"; exec sh "$ZK_T/zk.sh" disarm'; expect_stock
uv_on; mkpayload ship3 B; cp "$T/env.txt" "$T/env.before"; RECB=$(recmd5)
boot; expect_kernel stock
cmp -s "$T/env.txt" "$T/env.before" && ok || bad "env written while a calibration is armed: $(envdiff)"
[ "$(recmd5)" = "$RECB" ] && ok || bad "recovery written while a calibration is armed"
[ "$(cat "$R/usr/lib/zero/VERSION")" = ship2 ] && ok || bad "overlay written while a calibration is armed"
grep -q "deferred: Optimize CPU calibration armed" "$ZD/log.txt" && ok || bad "no deferred log line"
rm -f "$UVA"; boot; expect_kernel stock; expect_armed; expect_rec "$IMGMD5"
[ "$(cat "$R/usr/lib/zero/VERSION")" = ship3 ] && ok || bad "overlay VERSION after the calibration"
CASE="review 1: Optimize CPU armed on a stock start: a stopped image's retry waits"
install_device; : > "$T/broken"; boot; boot; boot; boot; expect_env zero_k failed; rm -f "$T/broken"
uv_on; mkpayload ship3 B; cp "$T/env.txt" "$T/env.before"; RECB=$(recmd5)
boot; expect_kernel stock
cmp -s "$T/env.txt" "$T/env.before" && ok || bad "env written while a calibration is armed: $(envdiff)"
[ "$(recmd5)" = "$RECB" ] && ok || bad "recovery written while a calibration is armed"
rm -f "$UVA"; boot; expect_kernel stock; expect_armed; expect_env zero_k on; expect_rec "$IMGMD5"
CASE="review 1: Optimize CPU armed on a stock start: a fallback is counted only after it"
install_device; : > "$T/broken"; boot; expect_kernel hang; uv_on; cp "$T/env.txt" "$T/env.before"
boot; expect_kernel stock
cmp -s "$T/env.txt" "$T/env.before" && ok || bad "env written while a calibration is armed: $(envdiff)"
rm -f "$UVA" "$T/broken"; boot; expect_kernel stock; expect_env zero_k_fail 1; expect_armed
CASE="review 1: Optimize CPU armed: a stuck env is still put back to stock"
install_device; uv_on; setenv_raw boot_partition recovery; boot; expect_stock; expect_env zero_k failed
expect_env zero_k_bad loader-partition; rm -f "$UVA"

CASE="review 3: undo: a power cut while recovery is put back from the backup is finished at the next start"
install_device; boot; clean_off; : > "$CARD/restore-boot-env.txt"; boot cut-dd-backup; expect_kernel zero
expect_file "$CARD/restore-boot-env.txt"; [ "$(recmd5)" != "$STOCKREC" ] && ok || bad "test setup: the cut left recovery whole"
boot; expect_kernel stock; expect_stock; expect_env zero_k off; expect_env zero_k_img ""
[ "$(recmd5)" = "$STOCKREC" ] && ok || bad "recovery not put back after the cut"
expect_nofile "$CARD/restore-boot-env.txt"; expect_file "$ZD/off-$SERIAL"
CASE="review 3: undo: with a verified backup, recovery is compared in full whatever its header"
install_device; boot; clean_off; : > "$CARD/restore-boot-env.txt"; boot cut-dd-backup
setenv_raw zero_k_img ""   # what an undo from before this fix left in the env
boot; expect_kernel stock; [ "$(recmd5)" = "$STOCKREC" ] && ok || bad "a stock header in front of our bytes was taken for stock"
CASE="review 3: undo without a backup: a power cut during the zero fill is finished at the next start"
install_device; boot; clean_off; rm -f "$ZD/recovery-orig-$SERIAL.bin" "$ZD/recovery-orig-$SERIAL.bin.md5"
: > "$CARD/restore-boot-env.txt"; boot cut-dd-zero; expect_file "$CARD/restore-boot-env.txt"
boot; expect_kernel stock; [ "$(recmd5)" = "$STOCKREC" ] && ok || bad "a half zero fill was left alone"
expect_env zero_k_img ""

CASE="review 4: a shipped image that fails its md5 is retried at the next start, with one card note"
install_device; boot; clean_off; OLDIMG=$(envv zero_k_img); mkpayload ship3 B; cp "$IMGPATH" "$T/img.good"
printf 'X' | $REALDD of="$IMGPATH" bs=1 seek=100 conv=notrunc 2>/dev/null
boot; expect_kernel zero; boot; expect_kernel stock; expect_stock; expect_nofile "$ZD/stop-$SERIAL-ship3"
expect_file "$CARD/zero-kernel-image-FAILED.txt"; expect_env zero_k on; expect_env zero_k_img "$OLDIMG"
rm -f "$CARD/zero-kernel-image-FAILED.txt"; boot; expect_kernel stock; expect_stock
expect_nofile "$CARD/zero-kernel-image-FAILED.txt"; expect_nofile "$ZD/stop-$SERIAL-ship3"
cp "$T/img.good" "$IMGPATH"; boot; expect_kernel stock; expect_armed; expect_rec "$IMGMD5"
[ "$(cat "$R/usr/lib/zero/VERSION")" = ship3 ] && ok || bad "overlay VERSION after the image was fixed"
expect_nofile "$CARD/zero-kernel-image-FAILED.txt"
boot; expect_kernel zero; expect_armed
CASE="review 4: a card with no shipped image id is retried at the next start, not stopped"
fresh_device; cp "$SYSTEM_PATH/kernel/known-images.txt" "$T/known.good"; : > "$SYSTEM_PATH/kernel/known-images.txt"
boot; expect_kernel stock; expect_stock; expect_nofile "$ZD/stop-$SERIAL-ship2"; expect_file "$CARD/zero-kernel-image-FAILED.txt"
cp "$T/known.good" "$SYSTEM_PATH/kernel/known-images.txt"; boot; expect_armed; expect_rec "$IMGMD5"
expect_nofile "$CARD/zero-kernel-image-FAILED.txt"

# ---------------- the "not our card" guard (Dan, 2026-11-19): rc/guard, started by S01zero under ours ----------------
GL="$R/usr/lib/zero/guard.log"
expect_reboot() { [ "$REBOOTED" = "$1" ] && ok || bad "restart requested '$REBOOTED' want '$1'"; }
CASE="guard: a card that is not MinUI Zero restarts to stock, and the next stock start with ours is not counted"
install_device; boot; expect_kernel zero; expect_armed; expect_reboot 0; clean_off
boot foreign; expect_kernel zero; expect_stock; expect_reboot 1; expect_state foreign
grep -q "foreign: /mnt/SDCARD is not MinUI Zero" "$GL" 2>/dev/null && ok || bad "no guard log line"
[ "$(wc -l < "$GL" | tr -d ' ')" = 1 ] && ok || bad "guard log has $(wc -l < "$GL" | tr -d ' ') lines, want 1"
reboot_k; expect_state foreign   # the orderly restart runs K01zero: the word stays
boot foreign; expect_kernel stock; expect_reboot 0; expect_stock   # the restart lands on stock; a foreign card runs no Zero script
boot; expect_kernel stock; expect_env zero_k_fail ""; expect_armed; expect_env zero_k on; expect_state armed
grep -q "had a card that is not MinUI Zero" "$ZD/log.txt" && ok || bad "stock-side log line"
expect_nofile "$CARD/zero-kernel-FAILED.txt"
boot; expect_kernel zero; expect_armed; expect_state zarmed; expect_reboot 0
CASE="guard: a foreign card never counts, however often"
for i in 1 2 3; do boot foreign; expect_kernel zero; expect_reboot 1; boot; expect_kernel stock; expect_env zero_k_fail ""; expect_armed; done
expect_env zero_k on; expect_nofile "$ZD/stop-$SERIAL-ship2"
CASE="guard: our card, no restart and no log"
install_device; boot; expect_kernel zero; expect_reboot 0; expect_nofile "$GL"; expect_armed; expect_state zarmed
CASE="guard: a slow card that mounts inside the wait, no restart"
clean_off; boot slowcard; expect_kernel zero; expect_reboot 0; expect_nofile "$GL"; expect_armed; expect_state zarmed
CASE="guard: no card restarts to stock; benign once, counted when it repeats before a zero start"
clean_off; boot nocard; expect_kernel zero; expect_reboot 1; expect_state nocard
grep -q "nocard: no card at /mnt/SDCARD after 2 s" "$GL" && ok || bad "no-card guard log line"
boot; expect_kernel stock; expect_env zero_k_fail ""; expect_armed; expect_file "$ZD/nocard-$SERIAL"
boot nocard; expect_kernel zero; expect_reboot 1
boot; expect_kernel stock; expect_env zero_k_fail 1; expect_armed
grep -q "did not reach the menu (state 'nocard again')" "$ZD/log.txt" && ok || bad "repeat not counted in the log"
boot; expect_kernel zero; expect_armed; expect_nofile "$ZD/nocard-$SERIAL"; clean_off   # a zero start clears the run
boot nocard; expect_kernel zero; expect_reboot 1; boot; expect_kernel stock; expect_env zero_k_fail ""; expect_armed
CASE="guard: no card twice in a row with a working card in between stops the image at MAXFAIL (a card our kernel cannot read)"
install_device
boot nocard; boot; boot nocard; boot; expect_env zero_k_fail 1
boot nocard; boot; expect_kernel stock; expect_stock; expect_env zero_k failed; expect_file "$CARD/zero-kernel-FAILED.txt"
CASE="guard: never on the stock kernel"
install_device; echo 4.9.191 > "$R/proc/sys/kernel/osrelease"; rm -f "$R/mnt/SDCARD"; ln -s "$T/foreign" "$R/mnt/SDCARD"
echo "/dev/mmcblk1p1 /mnt/SDCARD vfat rw 0 0" > "$R/proc/mounts"; rm -f "$T/reboot.req"
sed 's|^reboot$|echo reboot >> "$ZK_T/reboot.req"|' "$R/usr/lib/zero/rc/guard" > "$T/guard.sh"; sh "$T/guard.sh"
expect_nofile "$T/reboot.req"; expect_nofile "$GL"; expect_state armed
CASE="guard: an env that still reads ARMED (the loader did not save) is left alone: no restart loop"
install_device; : > "$T/loader.nosave"; boot foreign; expect_kernel zero; expect_reboot 0; expect_state armed
grep -q "left alone, the env is not disarmed" "$GL" && ok || bad "not-disarmed log line"; rm -f "$T/loader.nosave"
CASE="guard: an env that cannot be read is left alone"
install_device; : > "$T/env.badcrc"; boot foreign; expect_reboot 0; rm -f "$T/env.badcrc"
grep -q "left alone, the env read failed its checks" "$GL" && ok || bad "bad-env log line"
CASE="guard: a guard state at a zero start (no stock start with ours in between) is left alone"
install_device; boot foreign; expect_reboot 1; setenv_raw bootcmd "$ARMED"   # as if something re-armed without our card
boot foreign; expect_kernel zero; expect_reboot 0; expect_state foreign
grep -q "left alone, the last zero start was a guard restart too" "$GL" && ok || bad "second-restart log line"
CASE="guard: its log stays bounded and survives an update"
install_device; i=0; while [ $i -lt 200 ]; do echo "filler line $i of the guard log, long enough to add up" >> "$GL"; i=$((i + 1)); done
boot foreign; expect_reboot 1; [ "$(wc -c < "$GL" | tr -d ' ')" -le 8192 ] && ok || bad "guard log $(wc -c < "$GL") bytes"
grep -q "foreign: /mnt/SDCARD is not MinUI Zero" "$GL" && ok || bad "newest line lost in the trim"
boot; expect_armed; mkpayload ship3 P; boot; expect_kernel zero; boot; expect_kernel stock; expect_armed
[ "$(cat "$R/usr/lib/zero/VERSION")" = ship3 ] && ok || bad "test setup: no update"; expect_file "$GL"

echo "zerokernel harness: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
