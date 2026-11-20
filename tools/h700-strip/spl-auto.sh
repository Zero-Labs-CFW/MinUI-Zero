#!/bin/sh
# FAST BOOT ON THE ONE IMAGE (2026-11-06): our first-stage loader (workspace/h700/spl: zero-spl.bin for LPDDR4 units,
# zero-spl-lp3.bin for LPDDR3, both built by the image build) goes onto the card by itself once the model is known, and
# comes off again when the card asks. boot0-slot.sh ack runs this in the background after the menu's first frame (and
# after acknowledging a boot through our SPL), so nothing here is on the boot path. It never reboots: an installed
# loader runs from the next start on. The rules, in order:
#   off      fast-boot-off.txt at the card root: take our SPL off (boot0-slot.sh remove), and keep it off while the
#            file is there. Deleting the file allows the install below again.
#   when     only on the one image, with a model chosen (boardpick.sh), and not on the boot that first sees the choice:
#            the picker writes the image's copy of the board's boot0, and this unit's own stock boot (its vendor U-Boot)
#            writes the trained copy back over both slots; zero-install.sh refuses the image's copy in any case. Never
#            with a sleep swap in flight, an attempt marker or a pending GP15 (an unacknowledged boot).
#   where    by itself only where it is qualified on hardware: LPDDR4 units of the RG35XX H and Plus. Any other board or
#            supported DRAM pair stays stock unless fast-boot.txt opts into both stages.
#            Qualified pairs install both without a marker. DRAM
#            types we have no build for (DDR3) stay stock either way.
#   once     an install the loader's own safety net took back (a refusal, or a boot never acknowledged) is not tried
#            again on this card, and an installer that refused three times stops being asked. A reflash starts over.
# State (rootfs, so it goes with a reflash): /opt/minui-zero/spl-state = ready | tries:N | installed | failed | gaveup |
# unsupported | off | stage2:<auto|trial>:<board>. Log: .userdata/h700/logs/fast-boot.txt on the card.
D=/dev/mmcblk0
exec 0</dev/null
Z=/opt/minui-zero
B=$Z/boards
S=$Z/spl
STATE=$Z/spl-state
FLAG=$Z/.spl-sleep-swapped
CARD=/mnt/mmc
OFF=$CARD/fast-boot-off.txt
TRIAL=$CARD/fast-boot.txt
L=$Z/loader
LOG=$CARD/.userdata/h700/logs/fast-boot.txt

log() { mkdir -p "${LOG%/*}" 2>/dev/null; echo "$(date '+%F %T') $*" >> "$LOG"; }
setst() { echo "$1" > "$STATE.new" && mv "$STATE.new" "$STATE" && sync; }
rd() { dd if=$D bs=512 skip=$1 count=$2 iflag=direct 2>/dev/null; }

[ -f "$B/chosen" ] || exit 0   # a single-board image, or no model chosen yet
[ -f "$S/zero-install.sh" ] && [ -x $Z/boot0-slot.sh ] || exit 0
grep -q " $CARD " /proc/mounts || exit 0
# Serialize policy/state updates, but let each child own the raw-card lock itself.
. "$Z/spl-lock.sh" || exit 1
spl_lock_acquire /run/zero-spl-auto || exit 0
st=
[ ! -e "$STATE" ] || st=$(cat "$STATE") || exit 1
rd 16 1 > /run/zero-header-check || exit 1
[ "$(wc -c < /run/zero-header-check)" -eq 512 ] || exit 1
spl16=0
[ "$(dd if=/run/zero-header-check bs=1 skip=20 count=3 2>/dev/null)" != SPL ] || spl16=1

if [ -f "$OFF" ]; then
	case "$st" in stage2:*)
		# Opt-out on the recovery boot must not erase evidence of a failed trial.
		if [ ! -e /run/zero-stage2-provisioned ] &&
		   { [ "$spl16" = 0 ] || [ ! -e /sys/firmware/devicetree/base/chosen/zero,loader ] || ! "$L/boot-health"; }; then
			setst failed || exit 1
			st=failed
		fi ;;
	esac
	# after a refusal or a failed install nothing of ours is in slot 16: keep that state, so deleting the file later
	# does not bring back a loader that already failed on this unit
	case "$st" in off|failed|gaveup|unsupported) [ "$spl16" = 1 ] || {
		rd 16896 1 > /run/zero-header-check || exit 1
		[ "$(wc -c < /run/zero-header-check)" -eq 512 ] || exit 1
		[ "$(tr -d '\000' < /run/zero-header-check | wc -c)" -ne 0 ] || exit 0
	} ;; esac
	if out=$($Z/boot0-slot.sh remove 2>&1); then
		log "fast-boot-off.txt: $out"
		case "$st" in failed|gaveup|unsupported) ;; *) setst off ;; esac
	else
		log "fast-boot-off.txt: could not take the loader off ($out); trying again next boot"
	fi
	exit 0
fi

case "$st" in
installed)
	# installed by us, and stock is back in slot 16 without a sleep swap: the safety net put it back
	[ $spl16 = 1 ] || [ -f $FLAG ] || { log "the loader's safety net put stock back (GP14 $(busybox devmem 0x07000138)); staying stock on this card"; setst failed; }
	[ "$spl16" = 1 ] || exit 0 ;;
stage2:auto:*|stage2:trial:*) ;;  # written durably BEFORE install; reconcile even after a power loss
failed|gaveup|unsupported) exit 0 ;;
'') [ -e "$STATE" ] || setst ready; exit 0 ;;   # first chosen boot; never reset an unreadable state
ready|off|stock|tries:[0-3]) ;;
*) log "unrecognized fast boot state: refusing install"; exit 0 ;;
esac
case "$st" in installed|stage2:*) ;; *) [ $spl16 = 0 ] || exit 0 ;; esac
[ ! -f $FLAG ] || exit 0          # a sleep swap not finished (boot0-slot.sh boot finishes it)
[ "$(rd 16640 1 | head -c 15)" != ZERO-ATTEMPT-V1 ] || exit 0
[ "$(busybox devmem 0x0700013c)" = 0x00000000 ] || exit 0

# the board: the picker's choice, and the card's board file the installer reads must agree
bd=$(cat "$B/chosen"); bd=${bd#rg35xx-}
if [ "${st#stage2:}" != "$st" ]; then
	target=failed
	case "$st" in stage2:trial:*) [ -f "$TRIAL" ] || target=stock ;; esac
	if [ "$target" = failed ] && [ "${st##*:}" = "$bd" ] &&
	   [ "$bd" = "$(cat "$CARD/.system/h700/board" 2>/dev/null)" ] && [ "$spl16" = 1 ]; then
		# A second policy invocation on the provisioning boot cannot attest the next boot.
		[ ! -f /run/zero-stage2-provisioned ] || exit 0
		[ -e /sys/firmware/devicetree/base/chosen/zero,loader ] && "$L/boot-health" && exit 0
	fi
	if "$Z/boot0-slot.sh" remove; then
		setst "$target" || exit 1
		log "$bd: stage2 removed ($target)"
	fi
	exit 0
fi
[ "$bd" = "$(cat $CARD/.system/h700/board 2>/dev/null)" ] || { log "chosen $bd, card board file differs: not installing"; exit 0; }
# this unit's DRAM type: its own stock boot0 in the backup slot (zero-install.sh checks every word of it)
pt=$(rd 512 1 | od -An -tu4 -j60 -N4 | tr -d ' ')
case "$pt" in
8) spl=$S/zero-spl.bin ;;
7) spl=$S/zero-spl-lp3.bin ;;
*) log "$bd: DRAM type ${pt:-unreadable}, no loader build for it: staying stock"; setst unsupported; exit 0 ;;
esac
[ -f "$spl" ] || exit 0
trial=
stage2=
case "$pt:$bd" in
8:h|8:plus) stage2=auto ;;
*)	if [ ! -f "$TRIAL" ]; then
		[ "$st" != installed ] || exit 0  # retain ownership of an old stage-1-only installation
		[ "$st" = stock ] || { log "$bd, DRAM type $pt: not qualified, staying stock (fast-boot.txt at the card root tries it)"; setst stock; }
		exit 0
	fi
	ZERO_STAGE2_TRIAL=1 sh "$S/zero-install.sh" --stage2-board "$bd" "$pt" || exit 0
	trial=1; stage2=trial ;;
esac
n=0; case "$st" in tries:[0-9]*) n=${st#tries:} ;; esac
case "$n" in ''|*[!0-9]*) n=3 ;; esac
[ "$n" -lt 3 ] || { log "the installer refused 3 times: staying stock"; setst gaveup; exit 0; }
# counted before the install: a power cut during it uses a try too
sleep 5   # the menu's own start-up work first
[ ! -f "$OFF" ] || exit 0
[ "$stage2" != trial ] || [ -f "$TRIAL" ] || exit 0
: > /run/zero-stage2-provisioned || exit 1
setst "stage2:$stage2:$bd" || exit 1
if out=$(ZERO_SPL_AUTO=1 ZERO_STAGE2_TRIAL=$trial ZERO_SPL_TRIAL=$trial ZERO_SPL_KEYTEST= sh "$S/zero-install.sh" "$spl" "$L/zero-loader.bin" 2>&1); then
	log "installed ${spl##*/} on $bd${trial:+ (trial)}: $(echo "$out" | tail -n 1)"
else
	_install_rc=$?
	rm -f /run/zero-stage2-provisioned
	if [ "$_install_rc" = 76 ]; then
		setst failed
		log "$bd: profile refused before install: $out"
		exit 0
	fi
	if [ "$_install_rc" = 75 ]; then
		setst "$st"
		log "$bd: install deferred (boot write or sleep in progress)"
		exit 0
	fi
	log "$bd: install try $((n + 1)) refused: $(echo "$out" | tail -n 1)"
fi
exit 0
