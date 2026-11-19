#!/bin/sh
# zerokernel.sh: boot the Zero kernel (4.9.191-zero, an Android boot image in the unused recovery partition) on
# every healthy power-on, with the stock kernel as the automatic fallback (Dan, 2026-11-18: "Own kernel + own
# init"). Design and review: .notes/2026-11-18-own-kernel-ship/ (design-boot.md, critique-boot.md, impl-script.md).
#
# Levers, and nothing else: U-Boot env VALUES written with fw_setenv, the recovery partition, files on the
# overlay. The loader, boot0, monitor, U-Boot and boot_package are never touched, and neither is how the loader
# hands off (the stock boot_normal + bootm path runs unchanged; only boot_partition differs, in RAM).
#
# Overlay files (Dan, 2026-11-19): only files Zero adds, never a changed stock file, and all under /usr/lib/zero,
# except where something other than Zero's own scripts finds them at a fixed path: the kernel's module directory
# (MODDIR) and the two rc.d stubs procd runs (rc-stub). The WiFi MAC is $ZDIR/mac, passed to our driver as a module
# option (capture_mac, S01zero).
#
# How a power-on works. ARMED env: bootcmd = "run zero_once; setenv boot_partition recovery; run setargs_nand
# boot_normal". The loader runs zero_once first, which puts the stock bootcmd back and saves the env, then boots
# recovery. So the env on eMMC is DISARMED before our kernel starts, and any boot that fails before this script
# re-arms is followed by a stock boot. This script re-arms only after the menu is up and every check holds.
#
#   zerokernel.sh boot     MinUI.pak, background, after bootenv.sh apply in the same chain
#   zerokernel.sh revert   MinUI.pak, when restore-boot-env.txt is on the card, BEFORE bootenv.sh revert
#   zerokernel.sh enable   MinUI.pak, when enable-zero-kernel.txt is on the card: turns both back on after an undo
#   zerokernel.sh disarm   Optimize CPU, before a calibration starts (exit 1 = could not disarm)
#
# Busybox rules (memory: devicesync-device-facts, busybox-device-only-bugs): no `local`, every helper has its own
# variable prefix, no stat/nohup/setsid, kill by pid. ZK_ROOT is for the Mac harness only (prefix for device
# paths); it is empty on a device.
R="${ZK_ROOT:-}"
SD="${SDCARD_PATH:?}"
SHARED="${SHARED_USERDATA_PATH:?}"
SYS="${SYSTEM_PATH:?}"
PAY="$SYS/kernel"                     # shipped payload on the card (source of truth)
DIR="$SHARED/.minui/zerokernel"       # log, markers, recovery backup (per device serial)
LOG="$DIR/log.txt"
CMD=$1

REL=; read -r REL 2>/dev/null < "$PAY/VERSION"
IMG="$PAY/zero-recovery.img"
MODDIR=/lib/modules/4.9.191-zero     # outside ZDIR: the kernel and kmodloader look up modules by `uname -r` here
ZDIR=/usr/lib/zero                    # everything else Zero puts on the overlay (zinit reads gpu/ and procd here)
STATE="$R$ZDIR/state"                 # overlay: both kernels see it (rootfs_data, mounted sync)
RCD="/etc/rc.d/S01zero /etc/rc.d/K01zero"  # the stubs: procd only runs rc scripts from /etc/rc.d
# Through ship10 these lived outside ZDIR. The state moves at every start (st_pick), so no counted boot is lost;
# the rest goes once the new overlay is in (old_clean), and undo removes both layouts.
OLD_STATE="$R/etc/zero-kernel.state"
OLD_FILES="/etc/rc.d/S01zerogpu /etc/rc.d/K01zeroclean /etc/modules.d/zero-xr829"
OLD_MAC=/etc/wifi/xr_wifi.conf  # ship10's MAC file; also where our driver saves a random MAC when it gets none
MAXFAIL=2      # consecutive boots that did not reach the menu under our kernel, then stop for this image
MAXUNCLEAN=3   # consecutive zero sessions that ended without a clean power-off, then stop (escape hatch, H4)
REC_BYTES=16777216

STOCK_BOOTCMD='run setargs_nand boot_normal'
ONCE='setenv bootcmd run setargs_nand boot_normal; saveenv'
ARMED='run zero_once; setenv boot_partition recovery; run setargs_nand boot_normal'
BOOT_NORMAL='sunxi_flash read 45000000 ${boot_partition};bootm 45000000'

# ---- per-model allowlist, checked on EVERY boot before any arm (critique-gaps finding 1) ----
# model | uboot_message | lcd= | DT lcd0 lcd_driver_name | md5 of /sbin/procd (rootfs fingerprint) | menu path
# Every value VERIFIED from the 2026-11-18 read-only recon (.notes/2026-11-18-own-kernel-ship/recon/): model =
# TRIMUI_MODEL as launch.sh sets it, uboot_message and lcd= from /proc/cmdline (<dev>-recon.txt line 10), DT
# lcd0 lcd_driver_name = "otm1289a" on all three (<dev>.dts), procd md5 from the "rootfs gates" block of each
# <dev>-recon.txt (Brick 48214f50 = fastinit/bin/procd, the size zinit's patched-procd gate keys on; the Brick Pro
# and Smart Pro procd differ in size, so zinit runs their stock procd). menu path: fb0 = software menu (no GLES
# marker needed), gles = the menu is GLES and health also needs /tmp/zero-gles-ok, written by minui after its
# first accelerated GLES present (workspace/tg5040/platform/platform.c PLAT_menuPresented), so a menu that never
# presents on GLES never re-arms.
ZK_ALLOW="
Trimui Brick|2018.05(10/26/2025-11:56:42)|jd9168|otm1289a|48214f500f9d8061e2966228263b054d|fb0
Trimui Brick Pro|2018.05(07/11/2026-11:42:17)|gh7003|otm1289a|d2e5cca321ff95589de6f2ac0e24918c|gles
Trimui Smart Pro|2018.05(04/23/2024-18:42:17)|er68576|otm1289a|1c6b94986901b124f3ca0a9752351b06|gles
"
# Recovery content each model ships with ("recovery part not used!" + fill), for the no-backup undo path.
# Brick VERIFIED (recon/recovery.bin: the text, then zeros). The Brick Pro (abf495843c9be93262a44a87d8634bf0) and
# Smart Pro (e580852e45d1a70a4769ca173386a9a2, both 2026-11-18 recon) hold the same text, then leftover build-tool
# bytes that differ per firmware and are not reproduced here: no regenerate. Their undo source is the card backup,
# which install always takes first (an install without it is deferred, never done).
stock_rec_md5() { case "$TRIMUI_MODEL" in "Trimui Brick") echo 78f6f12ee2772c57527b38a71599e58a ;; *) echo none ;; esac; }

cmdline=; read -r cmdline < "$R/proc/cmdline"
serial=${cmdline##*androidboot.serialno=}; serial=${serial%% *}
[ "$serial" = "$cmdline" ] && serial=unknown
ub=${cmdline##*uboot_message=}; ub=${ub%% *}; [ "$ub" = "$cmdline" ] && ub=
lcd=" $cmdline"; lcd=${lcd##* lcd=}; lcd=${lcd%% *}; [ "$lcd" = " $cmdline" ] && lcd=
osr=; read -r osr < "$R/proc/sys/kernel/osrelease"

mkdir -p "$DIR" 2>/dev/null
log() { echo "$(date '+%F %T') ${TRIMUI_MODEL:-?} $serial $osr: $*" >> "$LOG"; }
mark() { touch "$1"; sync; }
envget() { echo "$ENV" | sed -n "s/^$1=//p"; }
envhas() { echo "$ENV" | grep -q "^$1="; }
failnote() { # card-root note, same pattern as restore-boot-env-FAILED.txt
	printf 'This device went back to the stock kernel (%s).\nNothing to do. Details: .userdata/shared/.minui/zerokernel/log.txt. Delete this file.\n' "$1" > "$SD/zero-kernel-FAILED.txt"
}
# The shipped image (or its id) on the card is damaged: a partial unzip or a card read error, not a kernel fault.
# Like an overlay md5 mismatch it is retried at every start, never a stop; the card note goes out once per release
# (imgbad marker), and both go once the image passes (update_and_arm).
imgnote() {
	log "$1: nothing written, retried next boot"
	[ -f "$DIR/imgbad-$serial-${REL:-none}" ] && return 0
	printf 'The Zero kernel was not installed: its file on the card is damaged (%s).\nCopy this release to the card again. Zero tries again at every start. Details: .userdata/shared/.minui/zerokernel/log.txt. Delete this file.\n' "$1" > "$SD/zero-kernel-image-FAILED.txt"
	mark "$DIR/imgbad-$serial-${REL:-none}"
}

case "$TRIMUI_MODEL" in
	"Trimui Brick"|"Trimui Brick Pro"|"Trimui Smart Pro") ;;
	*) case "$CMD" in
		disarm) ;;  # disarm keys on zero_k only (critique L9)
		enable) mv -f "$SD/enable-zero-kernel.txt" "$SD/enable-zero-kernel-FAILED.txt" 2>/dev/null; exit 0 ;;  # as bootenv.sh revert
		*) exit 0 ;;
	esac ;;
esac
PEND="$DIR/revert-pending-$serial"  # an undo that has not finished: retried at every start, nothing arms meanwhile
EN_TRIG="$SD/enable-zero-kernel.txt"
EPEND="$DIR/enable-pending-$serial" # a turn-back-on whose env write failed: retried at every start, like $PEND
BDIR="$SHARED/.minui/bootenv"       # bootenv.sh's markers (its done-<serial> after an undo)

# ---- env checks ----
# sane_base: everything except where bootcmd/boot_partition point. Used before ANY write, revert and repair
# included (critique H1: a bad-CRC dump is the fw tools' default env, and writing it back would replace the env).
sane_base() {
	command -v fw_printenv >/dev/null 2>&1 && command -v fw_setenv >/dev/null 2>&1 || { why="no fw tools"; return 1; }
	ENV=$(fw_printenv 2>&1) || { why="fw_printenv failed"; return 1; }
	echo "$ENV" | grep -qiE "bad crc|warning|cannot|error" && { why="fw_printenv: $(echo "$ENV" | grep -iE 'bad crc|warning|cannot|error' | head -n 1)"; return 1; }
	grep -qE "^/dev/by-name/env[[:space:]]+0x0+[[:space:]]+0x20000([[:space:]]|$)" "$R/etc/fw_env.config" 2>/dev/null || { why="fw_env.config is not the Tina layout"; return 1; }
	grep -qE "^/dev/by-name/env-redund[[:space:]]+0x0+[[:space:]]+0x20000([[:space:]]|$)" "$R/etc/fw_env.config" 2>/dev/null || { why="no env-redund"; return 1; }
	[ -e "$R/dev/by-name/env" ] && [ -e "$R/dev/by-name/env-redund" ] || { why="no env partitions"; return 1; }
	[ -e "$R/dev/by-name/app" ] && { why="dual-app layout"; return 1; }
	echo "$ENV" | grep -q "^parts_clean=" && { why="parts_clean is set"; return 1; }
	echo "$ENV" | grep -qxF "boot_normal=$BOOT_NORMAL" || { why="boot_normal differs"; return 1; }
	echo "$ENV" | grep -qxF "rdinit=/rdinit" || { why="rdinit is not /rdinit"; return 1; }
	echo "$ENV" | grep "^setargs_nand=" | grep -qF 'rdinit=${rdinit}' || { why="setargs_nand lacks rdinit"; return 1; }
	if envhas zero_once; then echo "$ENV" | grep -qxF "zero_once=$ONCE" || { why="zero_once differs"; return 1; }; fi
	return 0
}
# sane: sane_base + the invariant that userspace only ever sees a DISARMED env (stock bootcmd, boot_partition=boot)
sane() {
	sane_base || return 1
	echo "$ENV" | grep -qxF "bootcmd=$STOCK_BOOTCMD" || { why="bootcmd is not stock"; return 1; }
	echo "$ENV" | grep -qxF "boot_partition=boot" || { why="boot_partition is not boot"; return 1; }
	return 0
}

# Write $1 (fw_setenv script), require the env diff to be exactly $2, else write $3 (inverse). As bootenv.sh.
write_checked() {
	wc_before=$ENV
	fw_setenv --script "$1" >> "$LOG" 2>&1 || { log "fw_setenv failed"; ENV=$(fw_printenv 2>&1); return 1; }
	wc_after=$(fw_printenv 2>&1)
	wc_changed=$( { echo "$wc_before" | sed 's/^/- /'; echo "$wc_after" | sed 's/^/+ /'; } | awk '
		{ s=substr($0,3); if (substr($0,1,1)=="-") b[s]=1; else a[s]=1 }
		END { for (s in b) if (!(s in a)) print "- " s; for (s in a) if (!(s in b)) print "+ " s }' | sort)
	wc_want=$(printf '%s\n' "$2" | grep -v '^$' | sort)
	if [ "$wc_changed" = "$wc_want" ]; then ENV=$wc_after; return 0; fi
	log "readback unexpected: got [$(echo "$wc_changed" | tr '\n' ';')] want [$(echo "$wc_want" | tr '\n' ';')], rolling back"
	fw_setenv --script "$3" >> "$LOG" 2>&1 || log "rollback fw_setenv failed"
	ENV=$(fw_printenv 2>&1)
	return 1
}
# Build script/want/inverse for a set of changes. Each arg: "key|newvalue" ("key|" deletes the key).
plan() {
	# not `: >`: busybox ash exits the whole script when a special builtin's redirect fails (read-only card, L5)
	printf '' 2>/dev/null > "$DIR/w.script" && printf '' 2>/dev/null > "$DIR/w.inv" || { log "card not writable, nothing written"; return 1; }
	WANT=
	for pl_kv in "$@"; do
		pl_k=${pl_kv%%|*}; pl_v=${pl_kv#*|}
		pl_old=$(envget "$pl_k"); pl_had=0; envhas "$pl_k" && pl_had=1
		[ "$pl_had" = 1 ] && [ "$pl_old" = "$pl_v" ] && [ -n "$pl_v" ] && continue
		[ "$pl_had" = 0 ] && [ -z "$pl_v" ] && continue
		if [ -n "$pl_v" ]; then echo "$pl_k $pl_v" >> "$DIR/w.script"; WANT="$WANT
+ $pl_k=$pl_v"; else echo "$pl_k" >> "$DIR/w.script"; fi
		if [ "$pl_had" = 1 ]; then echo "$pl_k $pl_old" >> "$DIR/w.inv"; WANT="$WANT
- $pl_k=$pl_old"; else echo "$pl_k" >> "$DIR/w.inv"; fi
	done
}
# Plans from a fresh read, never from a snapshot taken before a wait (critique L2: another writer in between).
setenv_checked() {
	ENV=$(fw_printenv 2>&1) || { log "fw_printenv failed, nothing written"; return 1; }
	echo "$ENV" | grep -qiE "bad crc|warning|cannot|error" && { log "env read failed its checks, nothing written"; return 1; }
	plan "$@" || return 1
	[ -s "$DIR/w.script" ] || return 0
	write_checked "$DIR/w.script" "$WANT" "$DIR/w.inv"
}

# ---- boot-progress state on the overlay: "<word> <image id> <unclean count>" ----
#   armed   armed from the stock path (install, update, retry)
#   menu    a zero boot reached the menu (launch.sh's menu loop), not re-armed (yet)
#   health  a zero boot is in its health check or the re-arm right after it: a hang or crash here (a black
#           screen held off, critique-release-prep finding 3) is counted like armed. An orderly stop (bin/shutdown,
#           K01zeroclean) turns it into menu.
#   zarmed  a zero boot re-armed; the session is running
#   zclean  that zero session powered off cleanly (bin/shutdown writes it)
#   bad     a zero boot reached the menu but failed health (already counted in zero_k_fail)
# On a stock boot with zero_k=on, menu/bad = benign (the zero boot got that far); anything else = the zero boot
# never reached the menu or hung in its health check, which is the failure the fallback exists for (critique H2).
st_read() { ST_W=; ST_I=; ST_N=0; read -r ST_W ST_I ST_N 2>/dev/null < "$STATE"; case "$ST_N" in ''|*[!0-9]*) ST_N=0 ;; esac; }
st_write() { mkdir -p "$R$ZDIR" 2>/dev/null; printf '%s %s %s\n' "$1" "${IMG_ID:-none}" "${2:-0}" > "$STATE.tmp" && mv -f "$STATE.tmp" "$STATE" && sync; }
# the ship10 state file, moved as it is: its word still decides whether the last zero boot is counted. It always
# wins over ours: it is deleted once moved, so one that exists was written since, by a ship10 card or overlay.
st_migrate() {
	[ -f "$OLD_STATE" ] || return 0
	mkdir -p "$R$ZDIR" && cp "$OLD_STATE" "$STATE.tmp" && mv -f "$STATE.tmp" "$STATE" || return 1
	rm -f "$OLD_STATE"; sync
}
# Under our kernel with the ship10 overlay still in (the stock boot after this one updates it), its K01zeroclean
# reads only the old path: keep the state there for this session, so an orderly reboot is still cleaned up.
st_pick() {
	if [ "$osr" = 4.9.191-zero ] && [ -f "$R/etc/rc.d/K01zeroclean" ]; then STATE=$OLD_STATE; return 0; fi
	st_migrate
}
# the ship10 files outside ZDIR, stock kernel only, once the new overlay is in: at the install, and again before any
# re-arm (a power cut after the VERSION swap). Never a file the read-only root ships.
old_clean() {
	for oc_f in $OLD_FILES $OLD_MAC; do
		[ -e "$R/rom$oc_f" ] || rm -f "$R$oc_f"
	done
	sync
}

# ---- allowlist tuple (model, U-Boot build, panel, DT panel driver, rootfs) ----
allow_ok() {
	al_dt=$(tr -d '\000' < "$(ls "$R"/proc/device-tree/soc@03000000/lcd0@*/lcd_driver_name 2>/dev/null | head -n 1)" 2>/dev/null)
	al_pd=$(md5sum < "$R/sbin/procd" 2>/dev/null | cut -d' ' -f1)
	TUPLE="$TRIMUI_MODEL|$ub|$lcd|$al_dt|$al_pd"
	MENU=
	while IFS='|' read -r al_m al_u al_l al_d al_p al_menu; do
		[ -n "$al_m" ] || continue
		[ "$al_m|$al_u|$al_l|$al_d|$al_p" = "$TUPLE" ] && { MENU=$al_menu; return 0; }
	done <<EOF
$ZK_ALLOW
EOF
	why="not on the allowlist: $TUPLE"; return 1
}

# ---- recovery partition ----
rec_dev() {
	rd_l=$(readlink "$R/dev/by-name/recovery" 2>/dev/null) || return 1
	# the by-name link must agree with the loader's own partition map (critique L7: zinit makes /dev/by-name)
	case ":${cmdline##*partitions=}" in *":recovery@${rd_l##*/}:"*|*":recovery@${rd_l##*/} "*) ;; *) return 1 ;; esac
	REC="$R/dev/${rd_l##*/}"
	rd_s=; read -r rd_s 2>/dev/null < "$R/sys/class/block/${rd_l##*/}/size"
	{ [ -b "$REC" ] || [ -n "$R" ]; } && [ -e "$REC" ] && [ "$rd_s" = $((REC_BYTES / 512)) ]
}
# REC_KIND = unused | ours:<image id> | foreign. known-images.txt lines: "<bytes> <md5> <image id>"
rec_kind() {
	REC_KIND=foreign
	rk_h=$(dd if="$REC" bs=24 count=1 2>/dev/null)
	[ "$rk_h" = "recovery part not used!" ] && { REC_KIND=unused; return; }  # $(...) strips the trailing \n
	[ "$(dd if="$REC" bs=8 count=1 2>/dev/null)" = "ANDROID!" ] || return
	# the shipped image (the last line) first: in steady state that is the match, and every dev image before it
	# would cost an 8 MB hash
	if img_parse && [ "$(dd if="$REC" bs="$IMG_N" count=1 2>/dev/null | md5sum | cut -d' ' -f1)" = "$IMG_M" ]; then
		REC_KIND="ours:$IMG_ID"; return
	fi
	while read -r rk_n rk_m rk_r; do
		[ -n "$rk_n" ] || continue
		[ "$(dd if="$REC" bs="$rk_n" count=1 2>/dev/null | md5sum | cut -d' ' -f1)" = "$rk_m" ] && { REC_KIND="ours:$rk_r"; return; }
	done < "$PAY/known-images.txt"
}
img_parse() { # shipped image: the last line of known-images.txt. No hashing: every boot runs this (critique M6)
	IMG_LINE=$(tail -n 1 "$PAY/known-images.txt" 2>/dev/null)
	IMG_N=${IMG_LINE%% *}; IMG_ID=${IMG_LINE##* }; IMG_M=${IMG_LINE#* }; IMG_M=${IMG_M%% *}
	[ -n "$IMG_LINE" ] && [ -n "$IMG_ID" ]
}
img_id() { # + the image on the card really is that one: only right before it is written to recovery
	img_parse && [ "$(wc -c < "$IMG" | tr -d ' ')" = "$IMG_N" ] && [ "$(md5sum < "$IMG" | cut -d' ' -f1)" = "$IMG_M" ]
}
# The readback must come from flash, not the page cache (critique H3). conv=fsync is UNVERIFIED on the device
# busybox: a dd that refuses it is run again without it, followed by sync.
ddw() { dd "$@" conv=fsync 2>>"$LOG" || dd "$@" 2>>"$LOG"; }
dropcache() { sync; echo 3 > "$R/proc/sys/vm/drop_caches" 2>/dev/null; }
write_image() {
	for wi_try in 1 2; do
		ddw if="$IMG" of="$REC" bs=1M; dropcache
		[ "$(dd if="$REC" bs="$IMG_N" count=1 2>/dev/null | md5sum | cut -d' ' -f1)" = "$IMG_M" ] && return 0
		log "image readback mismatch (try $wi_try)"
	done
	return 1
}

# ---- overlay payload (manifest.md5 lines: "<md5>  <overlay path>", source = $PAY/root/<overlay path>) ----
# Staged in ONE directory, never next to the targets: a power cut mid-copy must not leave an S* script in rc.d or
# a list in modules.d that stock would run (critique M2). The stage coexists with the installed files, so the
# free-space check covers the whole new payload on an update too. Any failure removes the stage.
install_overlay() {
	io_st="$R$ZDIR/.stage"
	rm -rf "$io_st"; rm -f "$R"/etc/rc.d/*.zk-new "$R"/etc/modules.d/*.zk-new
	io_free=$(df -k "$R/overlay" 2>/dev/null | awk 'END {print $(NF-2)}')  # last line, from the end: a long device name wraps
	io_need=$(du -sk "$PAY/root" 2>/dev/null | cut -f1)  # the 2048 KB spare also holds the procd made here (346 KB)
	[ -n "$io_free" ] && [ -n "$io_need" ] && [ "$io_free" -ge $((io_need + 2048)) ] \
		|| { why="overlay has ${io_free:-?} KB free, needs ${io_need:-?} + 2048"; return 1; }
	while read -r io_m io_p; do
		[ -n "$io_p" ] || continue
		mkdir -p "$(dirname "$io_st$io_p")" "$(dirname "$R$io_p")" || { why="mkdir $io_p"; rm -rf "$io_st"; return 1; }
		cp "$PAY/root$io_p" "$io_st$io_p" || { why="copy $io_p"; rm -rf "$io_st"; return 1; }
		[ "$(md5sum < "$io_st$io_p" | cut -d' ' -f1)" = "$io_m" ] || { why="md5 mismatch $io_p"; rm -rf "$io_st"; return 1; }
		case "$io_p" in /etc/rc.d/*|$ZDIR/rc/*) chmod 755 "$io_st$io_p" ;; *) chmod 644 "$io_st$io_p" ;; esac
	done < "$PAY/manifest.md5"
	# swap: VERSION is the manifest's last line, so a half-done swap never claims the new release
	while read -r io_m io_p; do
		[ -n "$io_p" ] && { mv -f "$io_st$io_p" "$R$io_p" || { why="move $io_p"; rm -rf "$io_st"; return 1; }; }
	done < "$PAY/manifest.md5"
	rm -rf "$io_st"
	# files a newer payload no longer ships (state, procd and mac are made on the device, never shipped)
	for io_f in "$R$MODDIR"/* "$R$ZDIR"/* "$R$ZDIR"/rc/* "$R$ZDIR"/modules.d/* "$R$ZDIR"/gpu/lib/* "$R$ZDIR"/gpu/firmware/*; do
		[ -f "$io_f" ] || continue
		case "${io_f#$R}" in "$ZDIR/state"|"$ZDIR/procd"|"$ZDIR/mac") continue ;; esac
		grep -qF "  ${io_f#$R}" "$PAY/manifest.md5" || rm -f "$io_f"
	done
	# the ship10 layout: its stubs, list and MAC file go once the new ones are in (its state file moved at this start)
	st_migrate
	old_clean
}
overlay_current() { ov_v=; read -r ov_v 2>/dev/null < "$R$ZDIR/VERSION"; [ -n "$ov_v" ] && [ "$ov_v" = "$REL" ]; }

# ---- patched procd, made on the device from its own /sbin/procd (Dan, 2026-11-19: TrimUI's bytes never ship) ----
# zinit (the Zero kernel's /rdinit) execs $ZDIR/procd instead of /sbin/procd only when /sbin/procd is the Brick's
# (353,800 B, mtime 1764128533) and $ZDIR/procd is 353,800 B; otherwise stock procd, which the Brick Pro and Smart
# Pro always run and the Brick ran before trim5. So a missing patched copy is safe: the boot is only slower by the
# timers below. The patches are mk-zprocd.py's (trim5 batch 3). Lines: "<md5 of /sbin/procd>|<md5 of the result>",
# one per stock procd we patch (the Brick's today); any other procd is never patched.
ZK_PROCD="
48214f500f9d8061e2966228263b054d|ee0dae427ece54ac8c58c072e4e40a02
"
# "<offset, decimal>|<new bytes, printf octal>"
ZK_PROCD_PATCH='
47324|\101\000\200\122
45848|\101\000\200\122
23736|\101\001\200\122
23520|\241\000\200\122
54067|/bin/true\000\000\000
'
# 0xb8dc  hotplug_last_event quiet timer 50 -> 2 ms     (mov w1,#50 -> #2)
# 0xb318  rule_handle_command re-arm 50 -> 2 ms
# 0x5cb8  procd_connect_ubus first try 50 -> 10 ms
# 0x5be0  ubus connect retry 50 -> 5 ms
# 0xd333  coldplug "udevtrigger" -> "/bin/true": S80udev's udevadm trigger replays every event anyway
pp_apply() {
	while IFS='|' read -r pp_o pp_b; do
		[ -n "$pp_o" ] || continue
		printf "$pp_b" | dd of="$1" bs=1 seek="$pp_o" conv=notrunc 2>/dev/null || return 1
	done <<EOF
$ZK_PROCD_PATCH
EOF
}
# Never fails the caller: every refusal leaves no patched copy, and zinit then runs stock procd. $1 = log (install).
make_procd() {
	mp_out="$R$ZDIR/procd"
	mp_in=$(md5sum < "$R/sbin/procd" 2>/dev/null | cut -d' ' -f1)
	mp_want=
	while IFS='|' read -r mp_a mp_b; do
		[ -n "$mp_a" ] && [ "$mp_a" = "$mp_in" ] && mp_want=$mp_b
	done <<EOF
$ZK_PROCD
EOF
	if [ -z "$mp_want" ]; then
		if [ -e "$mp_out" ]; then rm -f "$mp_out"; sync; log "procd: /sbin/procd is ${mp_in:-unreadable}, not one we patch: removed the patched copy, stock procd runs"
		elif [ -n "$1" ]; then log "procd: /sbin/procd is ${mp_in:-unreadable}, not one we patch: stock procd runs"; fi
		return 0
	fi
	[ -f "$mp_out" ] && [ "$(md5sum < "$mp_out" | cut -d' ' -f1)" = "$mp_want" ] && return 0
	rm -f "$mp_out" "$mp_out.tmp"
	if ! cp "$R/sbin/procd" "$mp_out.tmp" 2>/dev/null || ! pp_apply "$mp_out.tmp"; then
		rm -f "$mp_out.tmp"; sync; log "procd: copy or patch failed, not installed: stock procd runs"; return 0
	fi
	mp_got=$(md5sum < "$mp_out.tmp" | cut -d' ' -f1)
	if [ "$mp_got" != "$mp_want" ]; then
		rm -f "$mp_out.tmp"; sync; log "procd: patched copy is $mp_got, want $mp_want: not installed, stock procd runs"; return 0
	fi
	chmod 755 "$mp_out.tmp" && mv -f "$mp_out.tmp" "$mp_out" && sync && { log "procd: patched copy written ($mp_want)"; return 0; }
	rm -f "$mp_out.tmp" "$mp_out"; sync; log "procd: rename failed, not installed: stock procd runs"; return 0
}

capture_mac() { # fixes/mac/capture-stock-mac.sh, stock kernel only. Format-checked, and never kept over a live stock MAC.
	# $ZDIR/mac, read only by S01zero, which passes it to our xr829_core.ko as macaddr= (the driver uses that option
	# first: wlan/main.c xradio_get_mac_addrs). Through ship10 it was $OLD_MAC, the path compiled into the driver:
	# read once here as the old value, then removed by old_clean.
	cm_conf="$R$ZDIR/mac"
	cm_cur=; read -r cm_cur 2>/dev/null < "$cm_conf"; cm_old=$cm_cur
	[ -z "$cm_old" ] && [ ! -e "$R/rom$OLD_MAC" ] && read -r cm_old 2>/dev/null < "$R$OLD_MAC"
	cm_mac=$(cat "$R/sys/class/net/wlan0/address" 2>/dev/null | tr 'A-F' 'a-f')
	if [ -z "$cm_mac" ]; then
		# no live MAC: a file already in the stock format stays. The dmesg formula is unverified on these
		# firmwares, so it only fills a missing or non-stock file, never replaces a good one (critique-release-prep 6)
		case "$cm_old" in dc:44:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]) cm_mac=$cm_old ;; esac
		cm_s=; [ -z "$cm_mac" ] && cm_s=$(dmesg | sed -n 's/.*serial: \([0-9A-Fa-f]\{10\}\).*/\1/p' | tail -n 1)
		if [ -n "$cm_s" ]; then
			cm_x=$(( 0x${cm_s#??} )); cm_v=$(( (cm_x << 4) & 0xffffffff ))
			cm_mac=$(printf 'dc:44:%02x:%02x:%02x:%02x' $(( ((cm_v >> 24) & 0xff) | 0x60 )) $(( (cm_v >> 16) & 0xff )) \
				$(( (cm_v >> 8) & 0xff )) $(( (cm_v + 1) & 0xff )))
		fi
	fi
	case "$cm_mac" in
	dc:44:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]) ;;
	*)  # nothing usable: keep an existing file only if it has the stock format (a random MAC our driver saved does not)
		case "$cm_old" in dc:44:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]) cm_mac=$cm_old ;; *) return 1 ;; esac ;;
	esac
	[ "$cm_cur" = "$cm_mac" ] && return 0
	mkdir -p "$R$ZDIR" && printf '%s\n' "$cm_mac" > "$cm_conf.tmp" && chmod 600 "$cm_conf.tmp" && mv "$cm_conf.tmp" "$cm_conf" && sync
}

# GPU 1.11 active (zinit's binds or the S01zero backstop), plus the GLES-present marker on a gles-menu model
health() {
	grep -q '^pvrsrvkm ' "$R/proc/modules" || { why="pvrsrvkm not loaded"; return 1; }
	grep -q ' /usr/lib/libsrv_um.so ' "$R/proc/mounts" || { why="GPU 1.11 bind mounts missing"; return 1; }
	if [ "$MENU" = gles ]; then
		# up to 60 s: on an auto-resumed boot the game's first present writes the marker (PLAT_flip), after the core
		# and the content load, not the menu
		h_i=0; while [ $h_i -lt "${ZK_GLES_WAIT:-60}" ]; do [ -f "$R/tmp/zero-gles-ok" ] && return 0; sleep 1; h_i=$((h_i + 1)); done
		why="no GLES-present marker (menu may be black)"; return 1
	fi
	return 0
}

battery_ok() {
	b_c=; read -r b_c 2>/dev/null < "$R/sys/class/power_supply/axp2202-battery/capacity"
	b_u=; read -r b_u 2>/dev/null < "$R/sys/class/power_supply/axp2202-usb/online"
	[ "$b_u" = 1 ] || [ "${b_c:-0}" -ge 15 ]
}
uv_armed() {
	for a in "$SHARED/../tg5040/undervolt/ARMED" "$SD/.userdata/tg5040/undervolt/ARMED"; do [ -f "$a" ] && return 0; done
	return 1
}

# Arm: the state first (a power cut between the two writes then costs one counted fallback, never a missed one),
# then ONE env write that always carries zero_once and boot_partition=boot (critique C2), then an assert.
# $1 = state word, $2 = unclean count, rest = extra key|value pairs.
arm() {
	ar_w=$1; ar_n=$2; shift 2
	uv_armed && { log "not armed: Optimize CPU calibration armed"; return 1; }
	allow_ok || { log "not armed: $why"; return 1; }
	st_write "$ar_w" "$ar_n" || { log "not armed: state write failed"; return 1; }
	# a failed write is not a kernel fault: the state goes back to benign "menu" (critique L1)
	setenv_checked "zero_once|$ONCE" "boot_partition|boot" "$@" "bootcmd|$ARMED" \
		|| { log "arm write failed: next power-on is stock"; st_write menu "$ar_n"; return 1; }
	if [ "$(envget bootcmd)" != "$ARMED" ] || [ "$(envget zero_once)" != "$ONCE" ] || [ "$(envget boot_partition)" != boot ]; then
		log "arm readback wrong, disarming"
		setenv_checked "bootcmd|$STOCK_BOOTCMD" || log "disarm after a bad arm FAILED"
		st_write menu "$ar_n"; return 1
	fi
	if uv_armed; then  # Optimize CPU armed itself between the check above and the write (critique L3)
		log "Optimize CPU armed during the arm: disarming"
		setenv_checked "bootcmd|$STOCK_BOOTCMD" || log "disarm FAILED"
		st_write menu "$ar_n"; return 1
	fi
	# this boot armed: bin/shutdown and K01zeroclean may then call the session clean (a zarmed state left over
	# from an earlier session must not be, critique H3)
	[ "$ar_w" = zarmed ] && printf '' 2>/dev/null > "$R/tmp/zero-armed"
	return 0
}
# A stuck env (critique C1): the loader did not clear the one-shot, or persisted boot_partition. Put stock back at
# once and stop the kernel for good on this device; never retried automatically.
repair_stuck() {
	log "STUCK ENV ($1): bootcmd='$(envget bootcmd)' boot_partition='$(envget boot_partition)', restoring stock"
	setenv_checked "bootcmd|$STOCK_BOOTCMD" "boot_partition|boot" "zero_k|failed" "zero_k_bad|$1" "zero_k_fail|" \
		|| log "REPAIR WRITE FAILED"
	failnote "the boot loader did not clear the one-shot start"
	mark "$DIR/stop-$serial-${REL:-none}"
}
stop_image() { # $1 = reason text, $2 = zero_k_bad value, $3 = the image that failed
	setenv_checked "zero_k|failed" "zero_k_bad|$2" "zero_k_fail|" || log "failed-state write failed"
	failnote "$1"
	# stop marker only when the failed image is the card's: a newer release on the card still gets its retry (L4)
	[ "$3" = "$IMG_ID" ] && mark "$DIR/stop-$serial-$REL"
	return 0
}

# Write image + overlay with the env saying "writing" first, then arm in ONE write. bootcmd stays stock throughout.
# $1 = zero_k value while writing (installing on a fresh install, else on).
update_and_arm() {
	ua_state=$1
	img_id || { imgnote "shipped image fails its own md5"; return 1; }
	[ -f "$DIR/imgbad-$serial-$REL" ] && { rm -f "$DIR/imgbad-$serial-$REL" "$SD/zero-kernel-image-FAILED.txt"; sync; }
	allow_ok || { log "skip: $why"; mark "$DIR/skip-$serial-$REL"; return 1; }
	rec_kind
	case "$REC_KIND" in  # never overwrite something that is not ours (critique M4)
	unused|ours:*) ;;
	*) [ "$(envget zero_k_img)" = writing ] || { log "skip: recovery holds something that is not ours"; mark "$DIR/skip-$serial-$REL"; return 1; } ;;
	esac
	battery_ok || { log "deferred: battery low"; return 1; }
	setenv_checked "zero_once|$ONCE" "zero_k|$ua_state" "zero_k_img|writing" || { mark "$DIR/stop-$serial-$REL"; return 1; }
	install_overlay || { log "overlay install failed: $why (bootcmd stock, retried next boot)"; return 1; }
	make_procd install
	# recovery already holding this image in full (an overlay-only release): no 8 MB rewrite
	if [ "$REC_KIND" = "ours:$IMG_ID" ]; then log "recovery already holds $IMG_ID, not rewritten"
	else write_image || { log "STOP: image write failed twice"; mark "$DIR/stop-$serial-$REL"; return 1; }; fi
	# a count against this same image carries over: a new overlay is not a new kernel
	ua_f=; [ "$zimg" = "$IMG_ID" ] && [ "${zfail:-0}" -gt 0 ] && ua_f=$zfail
	arm armed 0 "zero_k|on" "zero_k_img|$IMG_ID" "zero_k_fail|$ua_f" "zero_k_bad|" || return 1
	log "image $IMG_ID written and armed; next power-on boots it"
}

# ================================ revert ================================
# An undo that cannot finish its env write leaves $PEND: launch.sh then runs revert again at every start (also once
# restore-boot-env.txt is gone, critique M5), and boot never arms while it exists.
rv_fail() { # $1 = log text, $2 = what the user reads
	log "revert: $1"; mark "$PEND"
	printf '%s\nZero tries again at every start and does not arm its kernel in the meantime. Details: .userdata/shared/.minui/zerokernel/log.txt. Delete this file.\n' "$2" > "$SD/zero-kernel-restore-FAILED.txt"
	exit 0
}
if [ "$CMD" = revert ]; then
	# undo wins over enable-zero-kernel.txt (Dan, 2026-11-19): both on the card, or the enable file next to an undo
	# still pending, reads as "off". The enable file is set aside under a name that never fires, with a note, so it
	# cannot turn the kernel back on at some later start; a pending turn-back-on is dropped too.
	if [ -f "$EN_TRIG" ]; then
		# the note is a hint only: the enable file goes either way, so a card that took one write and not the other
		# cannot turn the undo around at the next start
		printf 'restore-boot-env.txt was on the card too, so the undo ran and this file was set aside.\nTo turn the Zero kernel and boot settings back on, rename this file to enable-zero-kernel.txt and start the device again.\n' \
			> "$SD/enable-zero-kernel-IGNORED.txt"
		rm -f "$EN_TRIG"
		log "revert: enable-zero-kernel.txt was on the card too: undo wins, set aside as enable-zero-kernel-IGNORED.txt"
	fi
	rm -f "$EPEND" "$SD/enable-zero-kernel-FAILED.txt"
	ENV=$(fw_printenv 2>/dev/null)
	# a deferred first install may have saved only the MAC (capture_mac runs before the recovery backup)
	if ! envhas zero_k && ! envhas zero_once && { [ ! -d "$R$ZDIR" ] || [ "$(ls -A "$R$ZDIR")" = mac ]; } && [ ! -d "$R$MODDIR" ]; then
		rm -rf "$R$ZDIR"
		# never installed: keep it that way (critique H1). zero_k=off covers any card, the off marker this card,
		# and bootenv.sh revert (next in the chain) adds zero_fast_boot=off, which boot also honors.
		if sane_base; then setenv_checked "zero_k|off" || log "revert: zero_k=off write failed (the off marker still holds)"
		else log "revert: $why, zero_k=off not written (the off marker still holds)"; fi
		mark "$DIR/off-$serial"; rm -f "$PEND"; sync
		log "revert: never installed, kept off on this device"
		exit 0
	fi
	sane_base || rv_fail "refused: $why" "The Zero kernel could not be removed yet: the boot settings did not pass their checks."
	case "$(envget bootcmd)" in "$STOCK_BOOTCMD"|"$ARMED") ;;
	*) rv_fail "refused: bootcmd is neither stock nor ours" "The Zero kernel could not be removed yet: the boot settings are not what Zero expects." ;; esac
	rv_img=$(envget zero_k_img)  # read before step 1 replaces it: "writing" = a half image of ours, "restoring" = an
	                             # undo cut short while it put recovery back (review 2026-11-19 finding 3)
	# 1. env: from here on every power-on is stock. zero_k_bad stays (inert while zero_k=off): it is the memory of a
	# kernel that stopped (a failed image, a loader that cannot do the one-shot), and enable puts zero_k=failed back
	# from it, so an off-then-on never reinstalls an image that was stopped for failing. zero_k_img=restoring stays
	# until recovery reads back as its original content, so a retry after a power cut finishes the restore.
	setenv_checked "bootcmd|$STOCK_BOOTCMD" "boot_partition|boot" "zero_once|" "zero_k_img|restoring" "zero_k_fail|" "zero_k|off" \
		|| rv_fail "env write failed" "The Zero kernel could not be removed yet: writing the boot settings failed."
	# 2. recovery back to its original content, only when it holds ours or a half write of ours (critique M4)
	rv_bad=
	if rec_dev; then
		rec_kind
		bk="$DIR/recovery-orig-$serial.bin"; bkm=; read -r bkm 2>/dev/null < "$bk.md5"
		rv_bok=; [ -f "$bk" ] && [ -n "$bkm" ] && [ "$(md5sum < "$bk" | cut -d' ' -f1)" = "$bkm" ] && rv_bok=1
		case "$REC_KIND" in
		unused)
			# a restore cut short puts the original header back first, in front of our bytes: the header alone proves
			# nothing, so with a verified backup the whole partition is compared
			if [ "$rv_img" = restoring ]; then rv_go=1
			elif [ -n "$rv_bok" ] && [ "$(dd if="$REC" bs=1M count=16 2>/dev/null | md5sum | cut -d' ' -f1)" != "$bkm" ]; then
				log "revert: recovery has the stock header but not the backup's content: putting the backup back"; rv_go=1
			fi ;;
		ours:*) rv_go=1 ;;
		*) case "$rv_img" in writing|restoring) rv_go=1 ;; *) log "revert: recovery holds something that is not ours, left alone" ;; esac ;;
		esac
		if [ "${rv_go:-0}" = 1 ]; then
			want_md5=
			if [ -n "$rv_bok" ]; then
				ddw if="$bk" of="$REC" bs=1M
				want_md5=$bkm
			elif [ "$(stock_rec_md5)" != none ] && [ -f "$PAY/recovery-stock-head.bin" ]; then  # Brick only (L4)
				ddw if=/dev/zero of="$REC" bs=1M count=16
				# plain fallback without conv=: a block device needs no notrunc (critique L6)
				dd if="$PAY/recovery-stock-head.bin" of="$REC" bs=512 count=1 conv=notrunc,fsync 2>>"$LOG" \
					|| { dd if="$PAY/recovery-stock-head.bin" of="$REC" bs=512 count=1 2>>"$LOG"; sync; }
				want_md5=$(stock_rec_md5)
			else
				log "revert: no backup and no known stock content for this model, recovery left as is (inert: bootcmd is stock)"
			fi
			if [ -n "$want_md5" ]; then
				dropcache
				[ "$(dd if="$REC" bs=1M count=16 2>/dev/null | md5sum | cut -d' ' -f1)" = "$want_md5" ] \
					|| { log "revert: recovery readback mismatch"; rv_bad=1; }
			fi
		fi
	else
		log "revert: no recovery partition of the expected size, left alone"
	fi
	# the restore is finished (or there was nothing of ours to put back): the marker goes. A readback mismatch keeps
	# it, so a later undo tries the restore again. A failed write here is inert (zero_k=off, bootcmd stock).
	[ -z "$rv_bad" ] && { setenv_checked "zero_k_img|" || log "revert: clearing zero_k_img=restoring failed (inert)"; }
	# 3. overlay files, this layout and the ship10 one (all inert under stock; removal is safe while running ours)
	rm -rf "$R$MODDIR" "$R$ZDIR" "$OLD_STATE"
	for rv_f in $RCD $OLD_FILES $OLD_MAC; do [ -e "$R/rom$rv_f" ] || rm -f "$R$rv_f"; done
	rm -f "$R"/etc/rc.d/*.zk-new "$R"/etc/modules.d/*.zk-new; sync
	mark "$DIR/off-$serial"; rm -f "$PEND"; sync
	[ -n "$rv_bad" ] && printf 'The Zero kernel is off: this device starts the stock kernel from now on.\nIts spare partition could not be put back exactly, which is harmless. Details: .userdata/shared/.minui/zerokernel/log.txt. Delete this file.\n' > "$SD/zero-kernel-restore-FAILED.txt"
	log "revert: done, stock kernel from the next power-on"
	exit 0  # restore-boot-env.txt stays for bootenv.sh revert, which runs next in the same chain and removes it
fi

# ================================ enable ================================
# enable-zero-kernel.txt at the card root (Dan, 2026-11-19: an undo was for good on that device; "as long as the user
# has the option to turn it back on (and off)"). Clears only what an undo leaves: zero_k=off and zero_fast_boot=off,
# except that zero_k=off next to a zero_k_bad (kept by revert) goes back to zero_k=failed, the state before the undo,
# in ONE checked write (boot reads zero_fast_boot=off as an opt-out and writes zero_k=off again, so the two never
# clear apart), then this device's off marker and bootenv.sh's done marker. Anything else stays as it is and is
# logged: zero_k=failed or any other value, the stop-/skip- markers (a failed health check, an unknown firmware, a
# guard that did not hold), an armed or mid-install env. launch.sh runs bootenv.sh apply and boot right after this
# in the same chain, so the boot settings come back and the kernel installs (card backup first) at this start.
# The same on either kernel: after an undo the next start is stock anyway, and with nothing to clear this is a
# no-op. A write that fails leaves $EPEND and exits 1 (the chain stops, nothing arms): retried at every start.
en_fail() { # $1 = log text, $2 = what the user reads
	log "enable: $1"; mark "$EPEND"
	[ -f "$EPEND" ] && rm -f "$EN_TRIG"  # the intent lives on in $EPEND; without it the card file stays and retries
	printf 'The Zero kernel and boot settings could not be turned back on yet: %s\nZero tries again at every start. To stop trying, put restore-boot-env.txt on the card. Details: .userdata/shared/.minui/zerokernel/log.txt.\n' "$2" > "$SD/enable-zero-kernel-FAILED.txt"
	exit 1
}
if [ "$CMD" = enable ]; then
	[ -f "$PEND" ] && { log "enable: an undo is still pending, it goes first"; exit 1; }  # launch.sh runs revert then
	ENV=$(fw_printenv 2>/dev/null)
	en_set=; en_what=; en_bad=$(envget zero_k_bad)
	if [ "$(envget zero_k)" = off ]; then
		# a kernel that had stopped before the undo stays stopped: zero_k=failed back, so boot's failed case decides
		# (a new image retries, the same image or a loader-* stop does not)
		if [ -n "$en_bad" ]; then en_set="zero_k|failed"; en_what=" zero_k (back to failed, zero_k_bad=$en_bad)"
		else en_set="zero_k|"; en_what=" zero_k"; fi
	fi
	[ "$(envget zero_fast_boot)" = off ] && { en_set="$en_set zero_fast_boot|"; en_what="$en_what zero_fast_boot"; }
	if [ -n "$en_set" ]; then
		sane_base || en_fail "refused: $why" "the boot settings did not pass their checks."
		# the unquoted list splits into one "key|value" per change (no value = delete); the values hold no spaces
		setenv_checked $en_set || en_fail "env write failed" "writing the boot settings failed."
	fi
	en_k=$(envget zero_k); en_b=$(envget zero_fast_boot)
	# markers go only once the env no longer holds the undo (the key absent, as on a device Zero never touched)
	# (or zero_k=failed: boot then follows the failed case, not the off marker)
	case "$en_k" in ''|failed) rm -f "$DIR/off-$serial" ;; esac
	[ -z "$en_b" ] && rm -f "$BDIR/done-$serial"
	case "$en_set" in zero_k\|failed*) ;; *) [ -n "$en_k" ] && log "enable: zero_k=$en_k kept (not an undo)" ;; esac
	[ -n "$en_b" ] && log "enable: zero_fast_boot=$en_b kept (not an undo)"
	for en_m in "$DIR/stop-$serial-"* "$DIR/skip-$serial-"* "$BDIR/stop-$serial" "$BDIR/skip-$serial"; do
		[ -e "$en_m" ] && log "enable: ${en_m##*/} kept (a failed check or an unknown firmware, not an undo)"
	done
	rm -f "$EPEND" "$EN_TRIG" "$SD/enable-zero-kernel-FAILED.txt"; sync
	if [ -n "$en_set" ]; then log "enable: cleared$en_what, the boot settings and kernel come back through the normal path"
	else log "enable: no undo in the env, nothing to turn back on"; fi
	exit 0
fi

# ================================ disarm ================================
if [ "$CMD" = disarm ]; then
	ENV=$(fw_printenv 2>/dev/null)
	envhas zero_k || exit 0
	sane_base || { log "disarm refused: $why"; exit 1; }
	[ "$(envget bootcmd)" = "$ARMED" ] || [ "$(envget boot_partition)" != boot ] || exit 0
	st_pick; st_read; IMG_ID=$ST_I; st_write menu 0  # the coming stock boot is benign, not a fallback
	setenv_checked "bootcmd|$STOCK_BOOTCMD" "boot_partition|boot" || { log "disarm FAILED"; exit 1; }
	log "disarmed (Optimize CPU): next power-on is stock"
	exit 0
fi

# ================================ boot ================================
[ "$CMD" = boot ] || exit 0
[ -f "$R/tmp/zerokernel.ran" ] && exit 0  # once per boot: an arm made by this boot is not a stuck env
: > "$R/tmp/zerokernel.ran"
case "$osr" in 4.9.191|4.9.191-zero) ;; *) exit 0 ;; esac
st_pick || log "state: moving the ship10 state file failed"

# 1. Stuck-env repair, first and before any wait (critique C1). Userspace must only ever see a disarmed env.
if sane_base; then
	if [ "$(envget bootcmd)" = "$ARMED" ]; then
		[ "$osr" = 4.9.191-zero ] && { repair_stuck loader-save; exit 0; }
		# ARMED under the stock kernel: the loader booted without running bootcmd. That may be a normal loader path
		# (a charger power-on, design gate B10), so the first time it only disarms and this boot re-arms as usual.
		# Final only when it happens again before any Zero start clears the marker (critique M4).
		[ -f "$DIR/loader-skip-$serial" ] && { repair_stuck loader-skip; exit 0; }
		log "armed env under the stock kernel (charger power-on?): disarming, re-armed below; final if it repeats before a Zero start"
		setenv_checked "bootcmd|$STOCK_BOOTCMD" "boot_partition|boot" || { repair_stuck loader-skip; exit 0; }
		mark "$DIR/loader-skip-$serial"
		st_read; IMG_ID=$ST_I; st_write menu "$ST_N"  # benign: not a kernel failure
	fi
	if [ "$(envget boot_partition)" != boot ] && envhas zero_k; then repair_stuck loader-partition; exit 0; fi
else
	log "skip: $why"; exit 0  # nothing is written to an env that fails the base checks
fi

[ -n "$REL" ] || exit 0
[ -f "$PEND" ] && { log "undo pending: not arming"; exit 0; }
[ -f "$DIR/off-$serial" ] || [ -f "$DIR/skip-$serial-$REL" ] || [ -f "$DIR/stop-$serial-$REL" ] && exit 0
# Optimize CPU calibrates by pushing the CPU until it fails (bootenv.sh: never write the env then). On the stock
# kernel every write below waits until it is done: install, update, retry, the fail count, zero_k=off, the recovery
# image and the overlay. The stuck-env repair above still runs: it only puts the stock bootcmd and boot_partition
# back, the same write Optimize's own disarm makes, and leaving a stuck env would boot our kernel at the campaign's
# next reset.
[ "$osr" = 4.9.191 ] && uv_armed && { log "deferred: Optimize CPU calibration armed"; exit 0; }
sane || { log "skip: $why"; mark "$DIR/skip-$serial-$REL"; exit 0; }
zk=$(envget zero_k); zimg=$(envget zero_k_img); zfail=$(envget zero_k_fail); zbad=$(envget zero_k_bad)
case "$zfail" in ''|*[!0-9]*) zfail=0 ;; esac
img_parse || { imgnote "no shipped image id"; exit 0; }  # hashed before a write
# The boot settings were put back to stock on this device (bootenv.sh revert, zero_fast_boot=off): that opt-out
# covers the kernel too, also when it came before this release (critique H1).
if [ "$(envget zero_fast_boot)" = off ] && [ "$zk" != off ]; then
	log "boot settings restored to stock earlier (zero_fast_boot=off): the Zero kernel stays off on this device (enable-zero-kernel.txt turns both back on)"
	setenv_checked "zero_k|off" || log "zero_k=off write failed (the off marker still holds)"
	mark "$DIR/off-$serial"; exit 0
fi

case "$osr" in
4.9.191-zero)
	rm -f "$DIR/loader-skip-$serial"  # a Zero start ends any run of loader skips
	[ "$zk" = on ] || { log "running zero with zero_k='$zk' (recovery key at power-on?), not arming"; exit 0; }
	st_read
	case "$ST_W" in zarmed) un=$((ST_N + 1)) ;; *) un=0 ;; esac  # zarmed at start = the last zero session ended uncleanly
	# wait for launch.sh's menu loop (MinUI.pak writes /tmp/zero-menu-start just before it)
	zw=0; while [ ! -f "$R/tmp/zero-menu-start" ] && [ $zw -lt 150 ]; do sleep 0.2; zw=$((zw + 1)); done
	[ -f "$R/tmp/zero-menu-start" ] || { log "menu never started: not re-armed, next power-on is stock"; exit 0; }
	st_write menu "$un"
	# This session is start $un+1 in a row: when that is the MAXUNCLEANth, it is not re-armed, so the MAXUNCLEANth
	# held start is the last one on our kernel (README: three, critique M1). Scoped to the running image: a later
	# release with a new image tries again (critique H3).
	if [ $((un + 1)) -ge "$MAXUNCLEAN" ]; then
		log "STOP: $un zero sessions in a row ended without a clean power-off, this is start $((un + 1)): not re-armed"
		stop_image "$((un + 1)) starts in a row with the Zero kernel ended without a normal power-off" "unclean:$zimg" "$zimg"; exit 0
	fi
	uv_armed && { log "deferred: Optimize CPU calibration armed"; exit 0; }
	allow_ok || { log "not re-armed: $why"; exit 0; }
	# from here to the re-arm, a hang or crash is counted on the next (stock) boot; every exit short of the
	# re-arm writes menu again (critique-release-prep finding 3)
	st_write health "$un"
	if ! health; then
		zfail=$((zfail + 1)); st_write bad "$un"
		log "unhealthy ($why): attempt $zfail of $MAXFAIL, next power-on is stock"
		if [ "$zfail" -ge "$MAXFAIL" ]; then stop_image "$MAXFAIL failed starts with the Zero kernel" "$zimg" "$zimg"
		else setenv_checked "zero_k_fail|$zfail" || log "fail count write failed"; fi
		exit 0
	fi
	# a new release on the card: the stock boot that follows does the update (critique M2: never swap modules
	# under a running kernel of another build)
	if [ "$zimg" != "$IMG_ID" ] || ! overlay_current; then log "release $REL on the card, running $zimg: next boot (stock) updates"; st_write menu "$un"; exit 0; fi
	# the next power-on boots whatever recovery holds now: re-hash it, as the stock path does before its arm
	# (critique-release-prep finding 7). Not a kernel fault: the stock boot that follows rewrites an image of ours
	# and skips anything else, as on any stock start.
	if ! rec_dev; then log "not re-armed: no 16 MiB recovery partition"; st_write menu "$un"; exit 0; fi
	rec_kind
	[ "$REC_KIND" = "ours:$IMG_ID" ] || { log "not re-armed: recovery is '$REC_KIND', not $IMG_ID (the next boot is stock)"; st_write menu "$un"; exit 0; }
	arm zarmed "$un" "zero_k_fail|" || { st_write menu "$un"; exit 0; }
	;;
4.9.191)
	rec_dev || { log "skip: no 16 MiB recovery partition"; mark "$DIR/skip-$serial-$REL"; exit 0; }
	st_read
	case "$zk" in
	off) mark "$DIR/off-$serial"; exit 0 ;;
	on)
		allow_ok || { log "skip: $why"; mark "$DIR/skip-$serial-$REL"; exit 0; }  # e.g. a firmware update while armed
		case "$ST_W" in
		menu|bad) ;;  # benign: the zero boot reached the menu (or was already counted)
		*)
			zfail=$((zfail + 1))
			log "FELL BACK to stock: the zero boot did not reach the menu (state '$ST_W'), attempt $zfail of $MAXFAIL on $zimg"
			if [ "$zfail" -ge "$MAXFAIL" ] && [ "$zimg" = "$IMG_ID" ]; then
				stop_image "$MAXFAIL failed starts with the Zero kernel" "$zimg" "$zimg"; exit 0
			fi
			setenv_checked "zero_k_fail|$zfail" || { log "fail count write failed: not re-armed"; exit 0; }
			;;
		esac
		# the stock MAC file, kept current on every stock start: an overlay wipe or a lost file must not leave our
		# driver on a random MAC. Not a gate here: WiFi may be off and the serial line rolled out of dmesg.
		capture_mac || log "stock WiFi MAC not found this boot, xr_wifi.conf left as is"
		if [ "$zimg" != "$IMG_ID" ] || ! overlay_current; then  # new release, or the overlay was wiped (M1)
			log "update $zimg -> $IMG_ID"
			update_and_arm on; exit 0
		fi
		rec_kind  # never arm from a stale env value: re-hash recovery first
		[ "$REC_KIND" = "ours:$IMG_ID" ] || { log "recovery is '$REC_KIND', not $IMG_ID: rewriting"; update_and_arm on; exit 0; }
		make_procd  # a power cut after the install's VERSION swap, or a lost file: made again, else stock procd
		old_clean   # the same power cut can leave the ship10 files
		# recovery already holds this image, so a card damaged and fixed since an imgnote never reaches update_and_arm:
		# clear the note and marker here (review 2026-11-19)
		[ -f "$DIR/imgbad-$serial-$REL" ] && { rm -f "$DIR/imgbad-$serial-$REL" "$SD/zero-kernel-image-FAILED.txt"; sync; }
		arm armed 0 || exit 0
		;;
	failed)
		# loader-*: the loader's one-shot does not work on this device, final. unclean:<image>: that image ended
		# MAXUNCLEAN sessions in a row uncleanly (also the dark-screen escape), stopped for that image only.
		case "$zbad" in loader-*) mark "$DIR/stop-$serial-$REL"; exit 0 ;; esac
		[ "${zbad#unclean:}" = "$IMG_ID" ] || [ -z "$zbad" ] && { mark "$DIR/stop-$serial-$REL"; exit 0; }
		log "retrying with new image $IMG_ID (failed before on $zbad)"
		update_and_arm on
		;;
	installing|"")
		# fresh install, or one interrupted by a power cut (zero_k=installing, zero_k_img=writing)
		allow_ok || { log "skip: $why"; mark "$DIR/skip-$serial-$REL"; exit 0; }
		uv_armed && { log "deferred install: Optimize CPU calibration armed"; exit 0; }
		rec_kind
		case "$REC_KIND" in
		unused|ours:*) ;;
		*) [ "$zk" = installing ] && [ "$zimg" = writing ] && [ -f "$DIR/recovery-orig-$serial.bin.md5" ] \
			|| { log "skip: recovery holds something else"; mark "$DIR/skip-$serial-$REL"; exit 0; } ;;
		esac
		battery_ok || { log "deferred install: battery low"; exit 0; }
		ov_free=$(df -k "$R/overlay" 2>/dev/null | awk 'END {print $(NF-2)}')  # last line, from the end: a long device name wraps
		ov_need=$(du -sk "$PAY/root" 2>/dev/null | cut -f1)
		[ -n "$ov_free" ] && [ -n "$ov_need" ] && [ "$ov_free" -ge $((ov_need + 2048)) ] \
			|| { log "skip: overlay has ${ov_free:-?} KB free, needs ${ov_need:-?} + 2048"; mark "$DIR/skip-$serial-$REL"; exit 0; }
		capture_mac || { log "deferred install: stock WiFi MAC not found yet"; exit 0; }
		if [ "$REC_KIND" = unused ] && [ ! -f "$DIR/recovery-orig-$serial.bin.md5" ]; then
			# 16 MiB to the card that holds the saves: only with room to spare, never left half-written (critique H2)
			bk="$DIR/recovery-orig-$serial.bin"
			sd_free=$(df -k "$SD" 2>/dev/null | awk 'END {print $(NF-2)}')
			[ -n "$sd_free" ] && [ "$sd_free" -ge $((REC_BYTES / 1024 + 65536)) ] \
				|| { log "deferred: the card has ${sd_free:-?} KB free, the recovery backup needs 16 MiB + 64 MiB spare"; exit 0; }
			rm -f "$bk.tmp" "$bk.md5.tmp"
			if dd if="$REC" of="$bk.tmp" bs=1M count=16 2>>"$LOG" && [ "$(wc -c < "$bk.tmp" | tr -d ' ')" = "$REC_BYTES" ] \
				&& md5sum < "$bk.tmp" | cut -d' ' -f1 > "$bk.md5.tmp" && [ -s "$bk.md5.tmp" ] \
				&& mv -f "$bk.tmp" "$bk" && mv -f "$bk.md5.tmp" "$bk.md5"; then
				echo "$ENV" > "$DIR/env-before-zk-$serial.txt"; sync
			else
				rm -f "$bk.tmp" "$bk.md5.tmp"; sync; log "deferred: recovery backup to card failed (partial removed)"; exit 0
			fi
		fi
		log "install $IMG_ID (U-Boot $ub, lcd $lcd)"
		update_and_arm installing
		;;
	*) log "unknown zero_k '$zk', left alone" ;;
	esac
	;;
esac
exit 0
