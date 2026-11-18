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
export ZK_T="$T"
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
case "\$of" in "$T/root/dev/"*)
	case "\$args" in *notrunc*) ;; *conv=*) args=\$(echo "\$args" | sed 's/conv=/conv=notrunc,/') ;; *) args="\$args conv=notrunc" ;; esac
	if [ -n "\${ZK_CUT_DD:-}" ] && [ "\$inf" = "\$ZK_CUT_DD" ]; then
		$REALDD if="\$inf" of="\$of" bs=1024 count=20 conv=notrunc 2>/dev/null
		kill -9 "\$(cat "$T/main.pid")"; exit 1
	fi ;;
esac
exec $REALDD \$args
EOF
printf '#!/bin/sh\ncat "$ZK_T/dmesg.txt" 2>/dev/null\n' > "$BIN/dmesg"
printf '#!/bin/sh\nexit 0\n' > "$BIN/sleep"
chmod +x "$BIN"/*
export PATH="$BIN:$PATH"

# ---------------- fake payload (small image, a few overlay files) ----------------
mkpayload() { # $1 = release id, $2 = image seed
	P="$SYSTEM_PATH/kernel"; rm -rf "$P"; mkdir -p "$P/root/lib/modules/4.9.191-zero" "$P/root/usr/lib/zero/gpu/lib" \
		"$P/root/usr/lib/zero/gpu/firmware" "$P/root/etc/rc.d" "$P/root/etc/modules.d"
	{ printf 'ANDROID!'; i=0; while [ $i -lt 2000 ]; do echo "$2 kernel block $i"; i=$((i + 1)); done; } > "$P/zero-recovery.img"
	echo "pvr $1" > "$P/root/lib/modules/4.9.191-zero/pvrsrvkm.ko"
	echo "xr $1" > "$P/root/lib/modules/4.9.191-zero/xr829_core.ko"
	printf 'xr829_mac\nxr829_core\nxr829_wlan\n' > "$P/root/etc/modules.d/zero-xr829"
	echo "srv $1" > "$P/root/usr/lib/zero/gpu/lib/libsrv_um.so"
	echo "fw $1" > "$P/root/usr/lib/zero/gpu/firmware/rgx.fw.22.102.54.38"
	echo "procd $1" > "$P/root/usr/lib/zero/procd"
	echo "#!/bin/sh" > "$P/root/etc/rc.d/S01zerogpu"
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
	rm -rf "$R" "$CARD" "$T/known.prev" "$T/env.badcrc" "$T/broken" "$T/loader.nosave" "$T/setenv.count"; : > "$T/known.prev"
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
	echo "stock procd 2025-11-25" > "$R/sbin/procd"
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
	# the real script, with the allowlist's rootfs fingerprint pointed at the fake procd
	sed "s/48214f500f9d8061e2966228263b054d/$(md5 "$R/sbin/procd")/" "$SCRIPT" > "$T/zk.sh"
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
# Userspace of one boot. $1 = kernel, rest: nocard | nomenu | nogpu | cut-setenv=N | cut-dd
userspace() {
	us_k=$1; shift
	us_card=1; us_menu=1; us_gpu=1; unset ZK_CUT_SETENV ZK_CUT_DD
	for o in "$@"; do case "$o" in nocard) us_card=0 ;; nomenu) us_menu=0 ;; nogpu) us_gpu=0 ;;
		cut-setenv=*) export ZK_CUT_SETENV=${o#cut-setenv=} ;; cut-dd) export ZK_CUT_DD="$SYSTEM_PATH/kernel/zero-recovery.img" ;; esac; done
	rm -f "$T/setenv.count"; rm -rf "$R/tmp"; mkdir -p "$R/tmp"
	[ "$us_k" = hang ] && return 0
	if [ "$us_k" = zero ]; then echo 4.9.191-zero > "$R/proc/sys/kernel/osrelease"; else echo 4.9.191 > "$R/proc/sys/kernel/osrelease"; fi
	echo "console=ttyS0 androidboot.serialno=$SERIAL uboot_message=$UBOOT lcd=$LCD loglevel=1 rdinit=/rdinit" > "$R/proc/cmdline"
	: > "$R/proc/modules"; : > "$R/proc/mounts"
	if [ "$us_k" = zero ] && [ $us_gpu = 1 ]; then echo "pvrsrvkm 1000 0 - Live" > "$R/proc/modules"
		echo "/dev/by-name/rootfs_data /usr/lib/libsrv_um.so ext4 rw 0 0" > "$R/proc/mounts"; fi
	[ $us_card = 1 ] || return 0               # no card: MinUI never runs
	[ $us_menu = 1 ] && : > "$R/tmp/zero-menu-start"
	# launch.sh's spawn decision (builtin marker tests), then the chain
	if [ -f "$CARD/restore-boot-env.txt" ]; then
		sh -c 'echo $$ > "$ZK_T/main.pid"; exec sh "$ZK_T/zk.sh" revert'; rm -f "$CARD/restore-boot-env.txt"; return 0
	fi
	us_spawn=0
	if [ "$us_k" = zero ]; then us_spawn=1
	elif [ -f "$SYSTEM_PATH/kernel/VERSION" ]; then read -r us_v < "$SYSTEM_PATH/kernel/VERSION"
		[ ! -f "$ZD/off-$SERIAL" ] && [ ! -f "$ZD/skip-$SERIAL-$us_v" ] && [ ! -f "$ZD/stop-$SERIAL-$us_v" ] && us_spawn=1; fi
	SPAWNED=$us_spawn
	[ $us_spawn = 1 ] && sh -c 'echo $$ > "$ZK_T/main.pid"; exec sh "$ZK_T/zk.sh" boot'
	unset ZK_CUT_SETENV ZK_CUT_DD
	return 0
}
clean_off() { # bin/shutdown's Zero lines, against the fake root
	sed -n '/^_zo=/,/^fi$/p' "$SHUTDOWN" | sed "s|/proc/|$R/proc/|g; s|/etc/|$R/etc/|g" > "$T/sd.sh"; sh "$T/sd.sh"
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
expect_state() { st=$(cut -d' ' -f1 "$R/etc/zero-kernel.state" 2>/dev/null); [ "$st" = "$1" ] && ok || bad "state '$st' want '$1'"; }
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
expect_file "$R/usr/lib/zero/procd"; expect_file "$R/usr/lib/zero/VERSION"; expect_file "$R/etc/rc.d/S01zerogpu"
[ "$(cat "$R/etc/wifi/xr_wifi.conf")" = "dc:44:60:38:9a:91" ] && ok || bad "MAC file"
[ -x "$R/etc/rc.d/S01zerogpu" ] && ok || bad "rc.d not executable"

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
CASE="stuck env: armed under stock (loader skipped the one-shot)"
install_device; rm -rf "$R/tmp"; mkdir -p "$R/tmp"; echo 4.9.191 > "$R/proc/sys/kernel/osrelease"; : > "$R/tmp/zero-menu-start"
sh -c 'echo $$ > "$ZK_T/main.pid"; exec sh "$ZK_T/zk.sh" boot'
expect_stock; expect_env zero_k failed; expect_env zero_k_bad loader-skip
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

CASE="three unclean zero sessions in a row (escape hatch)"
install_device
boot; expect_armed; boot; expect_armed; boot; expect_armed; expect_env zero_k on
boot; expect_kernel zero; expect_stock; expect_env zero_k failed; expect_env zero_k_bad unclean-x3; expect_file "$CARD/zero-kernel-FAILED.txt"
CASE="clean power-off resets the unclean count"
install_device; boot; boot; clean_off; boot; boot; expect_armed; expect_env zero_k on

CASE="foreign recovery content is never written"
fresh_device; printf 'SOMEOTHEROS' | $REALDD of="$R/dev/mmcblk0p8" conv=notrunc 2>/dev/null; H=$(md5 "$R/dev/mmcblk0p8")
boot; expect_stock; [ "$(md5 "$R/dev/mmcblk0p8")" = "$H" ] && ok || bad "foreign recovery overwritten"

echo "zerokernel harness: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
