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
export ZK_T="$T" ZK_GLES_WAIT=6
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
mkpayload() { # $1 = release id, $2 = image seed
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
	echo "$1" > "$P/root/usr/lib/zero/VERSION"; echo "$1" > "$P/VERSION"
	( cd "$P/root" && find . -type f ! -path ./usr/lib/zero/VERSION | sort | while read -r p; do echo "$(md5 "$p")  ${p#.}"; done
	  echo "$(md5 ./usr/lib/zero/VERSION)  /usr/lib/zero/VERSION" ) > "$P/manifest.md5"
	{ [ -f "$T/known.prev" ] && cat "$T/known.prev"
	  echo "$(wc -c < "$P/zero-recovery.img" | tr -d ' ') $(md5 "$P/zero-recovery.img") $1-$(md5 "$P/zero-recovery.img" | cut -c1-8)"; } > "$P/known-images.txt"
	cp "$P/known-images.txt" "$T/known.prev"
	{ printf 'recovery part not used!\n'; i=0; while [ $i -lt 8 ]; do printf '\000'; i=$((i + 1)); done
	  i=0; while [ $i -lt 480 ]; do printf '\315'; i=$((i + 1)); done; } > "$P/recovery-stock-head.bin"
	IMGPATH="$P/zero-recovery.img"; IMGMD5=$(md5 "$IMGPATH"); IMGN=$(wc -c < "$IMGPATH" | tr -d ' ')
}

# ---------------- fake device ----------------
fresh_device() {
	rm -rf "$R" "$CARD" "$T/known.prev" "$T/env.badcrc" "$T/broken" "$T/loader.nosave" "$T/setenv.count" \
		"$T/setenv.fail" "$T/df.card" "$T/df.overlay" "$T/fail.backup"; : > "$T/known.prev"
	export TRIMUI_MODEL="Trimui Brick"; PARTS="boot@mmcblk0p4:rootfs@mmcblk0p5:recovery@mmcblk0p8:pstore@mmcblk0p9"
	mkdir -p "$R/proc/sys/kernel" "$R/proc/sys/vm" "$R/proc/device-tree/soc@03000000/lcd0@01c0c000" "$R/sbin" \
		"$R/dev/by-name" "$R/sys/class/block/mmcblk0p8" "$R/sys/class/power_supply/axp2202-battery" \
		"$R/sys/class/power_supply/axp2202-usb" "$R/sys/class/net/wlan0" "$R/etc/wifi" "$R/overlay" "$R/tmp" \
		"$CARD/.userdata/shared/.minui" "$CARD/.userdata/tg5040" "$SYSTEM_PATH"
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
# gles-late | hang-health (the device hangs, or is held off, inside the GLES health wait) | cut-setenv=N | cut-dd
userspace() {
	us_k=$1; shift
	us_card=1; us_menu=1; us_gpu=1; us_gles=0; us_hang=0; unset ZK_CUT_SETENV ZK_CUT_DD
	for o in "$@"; do case "$o" in nocard) us_card=0 ;; nomenu) us_menu=0 ;; nogpu) us_gpu=0 ;; gles) us_gles=1 ;; gles-late) us_gles=2 ;;
		hang-health) us_hang=1 ;;
		cut-setenv=*) export ZK_CUT_SETENV=${o#cut-setenv=} ;; cut-dd) export ZK_CUT_DD="$SYSTEM_PATH/kernel/zero-recovery.img" ;; esac; done
	rm -f "$T/setenv.count"; rm -rf "$R/tmp"; mkdir -p "$R/tmp"
	[ "$us_k" = hang ] && return 0
	if [ "$us_k" = zero ]; then echo 4.9.191-zero > "$R/proc/sys/kernel/osrelease"; else echo 4.9.191 > "$R/proc/sys/kernel/osrelease"; fi
	echo "console=ttyS0 partitions=$PARTS androidboot.serialno=$SERIAL uboot_message=$UBOOT lcd=$LCD loglevel=1 rdinit=/rdinit" > "$R/proc/cmdline"
	: > "$R/proc/modules"; : > "$R/proc/mounts"
	if [ "$us_k" = zero ] && [ $us_gpu = 1 ]; then echo "pvrsrvkm 1000 0 - Live" > "$R/proc/modules"
		echo "/dev/by-name/rootfs_data /usr/lib/libsrv_um.so ext4 rw 0 0" > "$R/proc/mounts"; fi
	[ $us_card = 1 ] || return 0               # no card: MinUI never runs
	[ $us_menu = 1 ] && : > "$R/tmp/zero-menu-start"
	[ $us_menu = 1 ] && [ $us_gles = 1 ] && : > "$R/tmp/zero-gles-ok"
	# gles-late: an auto-resumed game, not the menu, writes the marker a few seconds later
	[ $us_menu = 1 ] && [ $us_gles = 2 ] && ( sleep 3; : > "$R/tmp/zero-gles-ok" ) &
	# launch.sh's spawn decision (builtin marker tests), then the chain. bootenv.sh revert removes the trigger.
	SPAWNED=0
	if [ -f "$CARD/restore-boot-env.txt" ]; then
		sh -c 'echo $$ > "$ZK_T/main.pid"; exec sh "$ZK_T/zk.sh" revert'; rm -f "$CARD/restore-boot-env.txt"; return 0
	elif [ -f "$ZD/revert-pending-$SERIAL" ]; then
		sh -c 'echo $$ > "$ZK_T/main.pid"; exec sh "$ZK_T/zk.sh" revert'; return 0
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
	sed -n '/^_zo=/,/^fi$/p' "$1" | sed "s|/proc/|$R/proc/|g; s|/usr/lib/zero/|$R/usr/lib/zero/|g; s|/tmp/|$R/tmp/|g" > "$T/zb.sh"; sh "$T/zb.sh"
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
[ "$(cat "$R/etc/wifi/xr_wifi.conf")" = "dc:44:60:38:9a:91" ] && ok || bad "MAC file"
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

CASE="card missing for one boot"
install_device; boot nocard; expect_kernel zero; expect_stock
boot; expect_kernel stock; expect_env zero_k_fail 1; expect_armed; expect_env zero_k on

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
[ "$(cat "$R/etc/wifi/xr_wifi.conf" 2>/dev/null)" = "dc:44:60:57:7f:91" ] && ok || bad "MAC file not rewritten"
CASE="no live MAC on a re-arm is not a gate"
setenv_raw bootcmd "$STOCKBC"; echo "menu x 0" > "$R/usr/lib/zero/state"   # a benign stock start, zero_k=on
rm -f "$R/sys/class/net/wlan0/address"; : > "$T/dmesg.txt"; userspace stock
expect_armed; [ "$(cat "$R/etc/wifi/xr_wifi.conf")" = "dc:44:60:57:7f:91" ] && ok || bad "MAC file changed"
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
[ "$(cat "$R/etc/wifi/xr_wifi.conf")" = "dc:44:60:38:9a:91" ] && ok || bad "stock-format MAC file replaced by the derived one"
CASE="a derived MAC fills a missing or non-stock file (finding 6)"
rm -f "$R/etc/wifi/xr_wifi.conf"; stock_start; expect_armed
[ "$(cat "$R/etc/wifi/xr_wifi.conf" 2>/dev/null)" = "dc:44:74:56:78:91" ] && ok || bad "derived MAC not written to a missing file"
echo "02:1a:2b:3c:4d:5e" > "$R/etc/wifi/xr_wifi.conf"; stock_start; expect_armed
[ "$(cat "$R/etc/wifi/xr_wifi.conf")" = "dc:44:74:56:78:91" ] && ok || bad "derived MAC did not replace a non-stock file"
CASE="a live MAC still replaces a different stock-format file (finding 6)"
echo "DC:44:60:57:7F:91" > "$R/sys/class/net/wlan0/address"; stock_start; expect_armed
[ "$(cat "$R/etc/wifi/xr_wifi.conf")" = "dc:44:60:57:7f:91" ] && ok || bad "live MAC did not win"
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
OUTSIDE='-e ^\./usr/lib/zero/ -e ^\./lib/modules/4\.9\.191-zero/ -e ^\./etc/rc\.d/S01zero$ -e ^\./etc/rc\.d/K01zero$ -e ^\./etc/wifi/xr_wifi\.conf$'
CASE="layout: Zero adds files only under /usr/lib/zero, plus the module directory, two rc.d stubs and the MAC file"
fresh_device; listfiles "$T/files.before"; boot; expect_armed; listfiles "$T/files.after"
NEW=$(comm -13 "$T/files.before" "$T/files.after" | grep -v $OUTSIDE)
[ -z "$NEW" ] && ok || bad "files outside the namespace: $(echo $NEW)"
[ "$(md5 "$R/sbin/procd")" = "$FP" ] && ok || bad "stock /sbin/procd changed"
cmp -s "$R/etc/rc.d/S01zero" "$STUB" && cmp -s "$R/etc/rc.d/K01zero" "$STUB" && ok || bad "rc.d entries are not the stub"
for f in procd state VERSION rc/S01zero rc/K01zero modules.d/zero-xr829; do expect_file "$R/usr/lib/zero/$f"; done
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
	rm -rf "$R/usr/lib/zero/rc" "$R/usr/lib/zero/modules.d" "$R/etc/rc.d/S01zero" "$R/etc/rc.d/K01zero"
}
expect_old_gone() {
	for f in /etc/rc.d/S01zerogpu /etc/rc.d/K01zeroclean /etc/modules.d/zero-xr829 /etc/zero-kernel.state; do expect_nofile "$R$f"; done
}
CASE="migration: a ship10 layout ends with only the new one after the update"
install_device; boot; expect_kernel zero; clean_off; expect_state zclean
old_layout; mkpayload ship3 K
boot; expect_kernel zero; expect_stock; expect_state menu; expect_nofile "$R/etc/zero-kernel.state"
boot; expect_kernel stock; expect_armed; expect_env zero_k_fail ""; expect_old_gone
for f in /etc/rc.d/S01zero /etc/rc.d/K01zero /usr/lib/zero/rc/S01zero /usr/lib/zero/rc/K01zero /usr/lib/zero/modules.d/zero-xr829; do
	expect_file "$R$f"; done
boot; expect_kernel zero; expect_armed; expect_state zarmed; reboot_k; expect_state zclean
CASE="migration: the ship10 state word still counts (a zero boot that never reached the menu)"
install_device; boot nocard; expect_kernel zero; expect_stock   # state stays armed: MinUI never ran
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
{ printf 'zk_mount() { echo "mount $*" >> "%s"; }\n' "$T/s01.log"
  sed "s|\$(uname -r)|\$(cat @OSR@)|; s|/usr/lib/|$R/usr/lib/|g; s|/lib/firmware/|$R/lib/firmware/|g
	s|/proc/|$R/proc/|g; s|/sbin/|$R/sbin/|g; s|mount --bind|zk_mount --bind|g; s|@OSR@|$R/proc/sys/kernel/osrelease|" "$S01"; } > "$T/s01.sh"
rm -f "$T/s01.log"; echo 4.9.191 > "$R/proc/sys/kernel/osrelease"; : > "$R/proc/mounts"
sh "$T/s01.sh" boot && ok || bad "S01zero exit status on stock"; expect_nofile "$T/s01.log"
echo 4.9.191-zero > "$R/proc/sys/kernel/osrelease"; sh "$T/s01.sh" boot
G="$R/usr/lib/zero/gpu"
[ "$(cat "$T/s01.log" 2>/dev/null | tr '\n' ';')" = "mount --bind $G/lib/libsrv_um.so $R/usr/lib/libsrv_um.so;mount --bind $G/firmware/rgx.fw.22.102.54.38 $R/lib/firmware/rgx.fw.22.102.54.38;kmodloader $R/usr/lib/zero/modules.d/;" ] \
	&& ok || bad "S01zero ran '$(cat "$T/s01.log" 2>/dev/null | tr '\n' ';')'"
rm -f "$T/s01.log"; echo "/dev/x $R/lib/firmware/rgx.fw.22.102.54.38 ext4 rw 0 0" > "$R/proc/mounts"; sh "$T/s01.sh" boot
[ "$(cat "$T/s01.log" 2>/dev/null)" = "kmodloader $R/usr/lib/zero/modules.d/" ] && ok || bad "zinit's binds already there: S01zero ran '$(cat "$T/s01.log" 2>/dev/null)'"

echo "zerokernel harness: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
