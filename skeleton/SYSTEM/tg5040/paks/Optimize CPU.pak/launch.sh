#!/bin/sh
# Optimize CPU — measures THIS chip's lowest safe operating voltage and runs it
# lean forever after. Per-device (silicon varies unit to unit); RAM-only at runtime, so
# any reboot returns to factory-safe voltages. See docs/dtb-undervolt-primer.md.

UV_DIR="$SHARED_USERDATA_PATH/../tg5040/undervolt"
[ -d "$UV_DIR" ] || UV_DIR="/mnt/SDCARD/.userdata/tg5040/undervolt"
mkdir -p "$UV_DIR"
BIN="$UV_DIR"
PAK_DIR="$(dirname "$0")"

# Self-install the exact packaged harness into the persistent working dir. Timestamps on
# FAT are not a reliable version check, and arming with a failed copy could resume old code.
INSTALL_FAILED=0
for f in uvtool stress deadman uvmap.sh; do
	if [ ! -f "$PAK_DIR/bin/$f" ]; then
		INSTALL_FAILED=1
	elif [ ! -f "$UV_DIR/$f" ] || ! cmp -s "$PAK_DIR/bin/$f" "$UV_DIR/$f"; then
		cp "$PAK_DIR/bin/$f" "$UV_DIR/$f" 2>/dev/null && chmod +x "$UV_DIR/$f" || INSTALL_FAILED=1
	fi
	[ -f "$UV_DIR/$f" ] && chmod +x "$UV_DIR/$f" 2>/dev/null || INSTALL_FAILED=1
done
if [ "$INSTALL_FAILED" != "0" ]; then
	say.elf "Optimize CPU could not install
its calibration harness.

Factory voltage remains active."
	exit 1
fi
unset INSTALL_FAILED f

# Retire every artifact before a fresh campaign. A stale log or identity can otherwise
# combine measurements from different chips into one table.
# Card-level campaign state only (ARMED, breadcrumb, retries, INVALID, identity, temps). Never
# touches a slot: a foreign or aborted campaign must not cost THIS device its calibration
# (review 2026-09-02).
archive_state() {
	rm -f "$UV_DIR/RETRIES" "$UV_DIR/state" "$UV_DIR/ARMED" "$UV_DIR/INVALID" \
	      "$UV_DIR/campaign.chip" "$UV_DIR/campaign.model" "$UV_DIR"/*.tmp
	sync
}
# Retire THIS chip's slot (raw log parked as .prev) plus the card-level state.
archive_campaign() {
	[ -f "$CHIP_DIR/margins.log" ] && mv "$CHIP_DIR/margins.log" "$CHIP_DIR/margins.log.prev" 2>/dev/null
	rm -f "$CHIP_DIR/table.conf" "$CHIP_DIR/table.model" "$CHIP_DIR/table.chip" \
	      "$CHIP_DIR/table.stock" \
	      "$CHIP_DIR/table.conf.reverted" "$CHIP_DIR/calibration" "$CHIP_DIR"/*.tmp
	archive_state
}

# Revert keeps the measurement: park the published table under .reverted and leave
# calibration/table.stock/table.chip/table.model in place. The runtime only ever opens
# table.conf, so parking it is exactly "factory voltage" -- and RE-ENABLE is a rename back.
# (Dan hit this 2026-09-02: a revert during an A/B cost the 90-minute campaign; the raw log had
# survived the whole time as margins.log.prev.)
disable_table() {
	mv "$CHIP_DIR/table.conf" "$CHIP_DIR/table.conf.reverted" 2>/dev/null
	sync
}

load_calibration() {
	[ -f "$CHIP_DIR/calibration" ] || return 1
	CAL_DATE=$(awk -F= '$1 == "calibrated" { n++; value=$2 } END { if (n == 1) print value; else exit 1 }' "$CHIP_DIR/calibration") || return 1
	CAL_MIN=$(awk -F= '$1 == "min_margin_mv" { n++; value=$2 } END { if (n == 1) print value; else exit 1 }' "$CHIP_DIR/calibration") || return 1
	CAL_TOP=$(awk -F= '$1 == "top_reduction_mv" { n++; value=$2 } END { if (n == 1) print value; else exit 1 }' "$CHIP_DIR/calibration") || return 1
	[ "$(wc -l < "$CHIP_DIR/calibration" | tr -d ' ')" = "3" ] || return 1
	printf '%s\n' "$CAL_DATE" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' || return 1
	case "$CAL_MIN" in ''|*[!0-9]*) return 1;; esac
	case "$CAL_TOP" in ''|*[!0-9]*) return 1;; esac
	[ "$CAL_MIN" -ge 0 ] && [ "$CAL_MIN" -le 500 ] &&
		[ "$CAL_TOP" -gt 0 ] && [ "$CAL_TOP" -le 500 ] || return 1
	calibrated=$CAL_DATE
	min_margin_mv=$CAL_MIN
	top_reduction_mv=$CAL_TOP
}

valid_table() {
	[ -f "$CHIP_DIR/table.conf" ] && [ -f "$CHIP_DIR/table.stock" ] || return 1
	awk '
		BEGIN { split("408000 600000 816000 1008000 1200000 1416000 1608000 1800000", opp) }
		FNR == NR {
			if (NF != 2 || $1 != opp[FNR] || $2 !~ /^[0-9]+$/ || $2 < 712500 || $2 > 1187500 || ($2-712500)%12500 || (FNR > 1 && $2 < stock[FNR-1])) bad=1
			stock[FNR]=$2; stock_n=FNR; next
		}
		{
			if (NF != 2 || $1 != opp[FNR] || $2 !~ /^[0-9]+$/ || $2 < 762500 || $2 > stock[FNR] || ($2-712500)%12500 || (FNR <= 3 && $2 != stock[FNR]) || (FNR > 1 && $2 < prev)) bad=1
			prev=$2; table_n=FNR
		}
		END { exit bad || stock_n != 8 || table_n != 8 }
	' "$CHIP_DIR/table.stock" "$CHIP_DIR/table.conf"
}

STATUS=$(cat /sys/class/power_supply/axp2202-battery/status 2>/dev/null)
DEV_CHIP=$(grep sunxi_serial /sys/class/sunxi_info/sys_info 2>/dev/null | awk -F: '{print $2}' | tr -d ' \t\r\n')
DEV_MODEL="$TRIMUI_MODEL"
[ -n "$DEV_MODEL" ] || DEV_MODEL=$(strings /usr/trimui/bin/MainUI 2>/dev/null | grep '^Trimui' | head -1)

# Per-chip slots (2026-09-02): chips/<serial>/ holds each device's own table, so one card can
# carry a calibration per device it visits and none can ever be applied to the wrong silicon.
[ -n "$DEV_CHIP" ] || { say.elf "Cannot read this chip's identity.

Optimize CPU needs it to keep every
calibration bound to its own device."; exit 0; }
CHIP_DIR="$UV_DIR/chips/$DEV_CHIP"
mkdir -p "$CHIP_DIR" || { say.elf "Cannot create this chip's tuning
folder on the card."; exit 0; }
# One-time migration of the flat layout. A published table is attributed by its table.chip; an
# in-flight campaign log by campaign.chip. Leftovers with no attribution are unusable to the
# runtime (it demands table.chip) and are dropped.
# A serial is hex from sysfs; anything else read from a card file is corruption, never a path.
is_serial() { case "$1" in ''|*[!0-9a-fA-F]*) return 1;; *) return 0;; esac; }
if [ -f "$UV_DIR/table.chip" ]; then
	LEG_CHIP=$(cat "$UV_DIR/table.chip" 2>/dev/null | tr -d ' \t\r\n')
	if is_serial "$LEG_CHIP" && mkdir -p "$UV_DIR/chips/$LEG_CHIP"; then
		MIG_OK=1
		for f in table.conf table.conf.reverted table.stock table.model calibration margins.log margins.log.prev; do
			[ -f "$UV_DIR/$f" ] || continue
			mv "$UV_DIR/$f" "$UV_DIR/chips/$LEG_CHIP/$f" || MIG_OK=0
		done
		# table.chip moves LAST: it is the marker this block keys on, so a power cut or a failed
		# move leaves it flat and the next open simply retries the remaining moves.
		[ "$MIG_OK" = 1 ] && mv "$UV_DIR/table.chip" "$UV_DIR/chips/$LEG_CHIP/table.chip"
		sync
	fi
fi
# Only once no flat table.chip remains: while a migration is pending, a pre-identity card's own
# log stays paired with its still-flat table for the retry.
if [ -f "$UV_DIR/margins.log" ] && [ ! -f "$UV_DIR/table.chip" ]; then
	CAM_CHIP=$(cat "$UV_DIR/campaign.chip" 2>/dev/null | tr -d ' \t\r\n')
	if is_serial "$CAM_CHIP"; then
		# attributed: file it under its chip; if the slot cannot be created, leave it for the retry
		mkdir -p "$UV_DIR/chips/$CAM_CHIP" && mv "$UV_DIR/margins.log" "$UV_DIR/chips/$CAM_CHIP/margins.log"
	else
		# No identity binds it (pre-identity releases never wrote campaign.chip): its verdicts
		# belong to an unknown chip and must never be adopted. Appended to the orphan record,
		# which nothing reads.
		cat "$UV_DIR/margins.log" >> "$UV_DIR/margins.log.orphan" && rm -f "$UV_DIR/margins.log"
	fi
	sync
fi
# Unattributable leftovers (no table.chip to name their chip) are unusable to the runtime.
# Only once no flat table.chip remains: a half-finished migration keeps retrying instead.
[ -f "$UV_DIR/table.chip" ] || rm -f "$UV_DIR/table.conf" "$UV_DIR/table.conf.reverted" "$UV_DIR/table.stock" "$UV_DIR/table.model" "$UV_DIR/calibration" 2>/dev/null
if [ -z "$DEV_CHIP" ] || [ -z "$DEV_MODEL" ]; then
	say.elf "Optimize CPU cannot verify
this device's chip identity.

Factory voltage remains active."
	exit 0
fi

# Invalid or internally inconsistent state cannot be resumed safely.
# A failed/aborted campaign (INVALID) is card-level: clear its state, keep every slot intact.
[ -f "$UV_DIR/INVALID" ] && archive_state
# Never judge a slot while a flat table.chip marks a half-finished migration (review 2, S11b).
if [ ! -f "$UV_DIR/table.chip" ] && { { [ -f "$CHIP_DIR/calibration" ] && [ ! -f "$CHIP_DIR/table.conf" ] && [ ! -f "$CHIP_DIR/table.conf.reverted" ]; } || \
	   { [ -f "$CHIP_DIR/table.conf.reverted" ] && [ ! -f "$CHIP_DIR/calibration" ]; } || \
	   { [ -f "$CHIP_DIR/table.conf" ] && [ ! -f "$CHIP_DIR/calibration" ]; } || \
	   { [ -f "$CHIP_DIR/calibration" ] && ! load_calibration; } || \
	   { [ -f "$CHIP_DIR/table.conf" ] && ! valid_table; }; }; then
	archive_campaign
fi

# A partial log in THIS chip's slot is attributed by the slot itself and always resumes; only
# another chip's in-flight card state is dropped (review 2: park-vs-resume must not depend on
# card-level leftovers).
if [ -f "$UV_DIR/ARMED" ] || { [ ! -f "$CHIP_DIR/calibration" ] && [ -f "$CHIP_DIR/margins.log" ]; }; then
	CAM_CHIP=$(cat "$UV_DIR/campaign.chip" 2>/dev/null | tr -d ' \t\r\n')
	if [ -n "$CAM_CHIP" ] && [ "$CAM_CHIP" != "$DEV_CHIP" ]; then
		archive_state    # another chip's campaign: drop its card state, keep every slot
	fi
fi

# ---------- STATE 3b: calibrated, but for a DIFFERENT chip (card swapped) ----------
TAB_CHIP=$(cat "$CHIP_DIR/table.chip" 2>/dev/null | tr -d ' \t\r\n')
if [ -f "$CHIP_DIR/calibration" ] && [ -f "$CHIP_DIR/table.conf" ] && [ "$DEV_CHIP" != "$TAB_CHIP" ]; then
	confirm.elf "Different Device Detected

This card was optimized on another
device. Every chip is different, so
the tuning is not applied here.

Optimize this device now?" "OPTIMIZE" "BACK" || exit 0
	archive_campaign # a different chip: EVERYTHING from the old campaign must go
	# fall through to the charger check + arming below
elif [ -f "$CHIP_DIR/calibration" ] && [ -f "$CHIP_DIR/table.conf" ]; then
	load_calibration || exit 1
	# headline from the APPLIED reduction (V^2 -> ~1.6x the mV% in rail power).
	# Dan's original pitch copy (3a76f3a2), restored 2026-07-12: both figures are
	# per-chip estimates — PCT is first-order V^2 at the top OPP; COOL is a rough
	# heavy-game figure consistent with the measured 1416MHz A/B (27% less heat).
	MV=${top_reduction_mv:-${min_margin_mv:-0}}
	PCT=$(( MV * 200 / 1187 ))        # first-order V^2 estimate at the 1187.5mV top OPP
	[ "$PCT" -lt 1 ] && PCT=1
	COOL=$(( MV / 30 ))               # ~degrees C cooler in heavy games
	[ "$COOL" -lt 1 ] && COOL=1
	confirm.elf --ok "CPU Optimized" "${PCT}% less CPU power. ${COOL}C cooler.
Tuned to this exact chip." "" "BACK" "MANAGE"
	RC=$?
	[ "$RC" != "2" ] && exit 0 # B (or anything but X): back to the menu

	# MANAGE: the deliberate second level
	confirm.elf "Manage Tuning

Calibrated ${calibrated:-unknown}
Top-clock reduction: ${top_reduction_mv:-${min_margin_mv:-?}}mV" "RE-RUN" "BACK" "REVERT"
	RC=$?
	if [ "$RC" = "2" ]; then
		confirm.elf "Revert to Factory?

Stock voltage resumes next launch.
Your measurements are kept, so you
can re-enable any time without
re-measuring." "REVERT" "BACK" || exit 0
		disable_table
		say.elf "Reverted to factory voltage.

Launch a game to apply. Open this
tool again to re-enable."
		exit 0
	elif [ "$RC" != "0" ]; then
		exit 0 # B: back
	fi
	# A: re-run measurement
	confirm.elf "Re-measure This Chip?

Takes ~90 min. Keep it charging." "RE-RUN" "BACK" || exit 0
	archive_campaign # fresh campaign: no stale cliffs/table may leak into the new table
	# fall through to arm
fi

# ---------- STATE 3c: reverted calibration on this card ----------
# table.conf is parked as .reverted (see disable_table). Same chip: offer the instant way back.
# Different chip (card moved): archive EVERYTHING -- another chip's table must never re-enable.
if [ -f "$CHIP_DIR/calibration" ] && [ -f "$CHIP_DIR/table.conf.reverted" ] && [ ! -f "$CHIP_DIR/table.conf" ]; then
	if [ "$DEV_CHIP" != "$TAB_CHIP" ]; then
		# Same rule as STATE 3b: ask before discarding another chip's tuning. BACK keeps the
		# parked table intact so the card can return to its own device and re-enable it.
		confirm.elf "Different Device Detected

This card holds tuning measured on
another device. Every chip is
different, so it is not used here.

Optimize this device now?" "OPTIMIZE" "BACK" || exit 0
		archive_campaign # committed to a fresh campaign for THIS chip
		# fall through to the pitch + arming
	else
		load_calibration || exit 1
		confirm.elf "Saved Tuning Available

Measured ${calibrated:-unknown}.
Top-clock reduction: ${top_reduction_mv:-${min_margin_mv:-?}}mV.
Currently on factory voltage." "RE-ENABLE" "BACK" "RE-MEASURE"
		RC=$?
		if [ "$RC" = "0" ]; then
			mv "$CHIP_DIR/table.conf.reverted" "$CHIP_DIR/table.conf" && sync
			if ! valid_table; then
				archive_campaign
				say.elf "Saved tuning failed validation
and was removed.

Re-measure to tune this chip again."
				exit 0
			fi
			say.elf "Optimized voltage re-enabled.

Launch a game to apply."
			exit 0
		elif [ "$RC" = "2" ]; then
			confirm.elf "Re-measure This Chip?

Takes ~90 min. Keep it charging." "RE-MEASURE" "BACK" || exit 0
			archive_campaign # fresh campaign: the saved table must not leak into the new one
			# fall through to arm
		else
			exit 0 # B: back
		fi
	fi
fi

# ---------- STATE 2: calibration in progress (armed, resuming across reboots) ----------
if [ -f "$UV_DIR/ARMED" ]; then
	MLOG="$CHIP_DIR/margins.log"
	DONE_N=$(grep -cE "^[0-9]+ (CLIFF|DONE)" "$MLOG" 2>/dev/null)
	[ -n "$DONE_N" ] || DONE_N=0
	LAST=$(grep "uV survived" "$MLOG" 2>/dev/null | tail -1 | awk '{f=$3; sub(/:/,"",f); printf "%d MHz: %.1f mV ok", f/1000, $4/1000}')
	if [ "$STATUS" != "Charging" ] && [ "$STATUS" != "Full" ]; then
		confirm.elf --ok "Measurement PAUSED

Not charging. Progress: $DONE_N of 8
steps done. Plug in the charger and
restart to resume." "" "BACK" "CANCEL"
		if [ "$?" = "2" ]; then
			confirm.elf "Cancel Measurement?

Progress is kept; re-run
Optimize CPU to resume later." "CANCEL IT" "BACK" || exit 0
			rm -f "$UV_DIR/ARMED"
			sync
			say.elf "Measurement cancelled.

Stops within about a minute.
Factory voltages remain active."
		fi
	else
		say.elf "Measuring... $DONE_N of 8 steps done.
${LAST:-Warming up.}

Keep it charging. The device
restarts itself several times.
Check back here any time."
	fi
	exit 0
fi

# ---------- STATE 1: not calibrated -> the pitch + disclaimer ----------
confirm.elf "Optimize CPU

Undervolt the CPU to your chip's
measured safe minimum. Cooler,
longer battery, same speed." "NEXT" "BACK" || exit 0

confirm.elf "Before You Start

* Takes ~90 min. Keep it charging.
* It restarts itself several times.
  This is how it measures.
* Reboots are always factory-safe.
  Back up saves before starting." "START" "BACK" || exit 0

# require an affirmative charging state — the PMIC also reports "Not charging",
# which the old != Discharging test let through (armed-but-paused-forever trap)
if [ "$STATUS" != "Charging" ] && [ "$STATUS" != "Full" ]; then
	say.elf "Connect the charger first,
then run Optimize CPU again."
	exit 0
fi

# Arm it: bind the campaign before ARMED becomes visible, install the resume hook, then
# kick off round one. A cancelled same-device campaign keeps these files and resumes.
AUTO="$SHARED_USERDATA_PATH/../tg5040/auto.sh"
[ -d "$(dirname "$AUTO")" ] || AUTO="/mnt/SDCARD/.userdata/tg5040/auto.sh"
if ! grep -q uvmap "$AUTO" 2>/dev/null; then
	[ -f "$AUTO" ] || echo "#!/bin/sh" > "$AUTO"   # only shebang a NEW file (audit nit)
	{
		echo "# Optimize CPU resume hook (inert once calibration completes)"
		echo "[ -f \"$UV_DIR/ARMED\" ] && ( sh \"$UV_DIR/uvmap.sh\" > /dev/null 2>&1 & )"
	} >> "$AUTO"
	chmod +x "$AUTO"
fi
# Bind the campaign to THIS device unconditionally. No campaign is in flight here (STATE 2
# catches ARMED), so any campaign.* left on the card is stale identity from a completed or
# cancelled run -- possibly another chip's. Review 2026-09-02: writing only-if-absent and then
# demanding a match made a second device exit 1 silently at START. A same-chip resume rewrites
# the same values.
# No campaign is in flight, so any crash breadcrumb / retry count / INVALID on the card belongs
# to another chip or a dead run and would abort this chip's first boot (review 2, S12).
rm -f "$UV_DIR/state" "$UV_DIR/RETRIES" "$UV_DIR/INVALID"
printf '%s\n' "$DEV_CHIP" > "$UV_DIR/campaign.chip.tmp" || exit 1
printf '%s\n' "$DEV_MODEL" > "$UV_DIR/campaign.model.tmp" || exit 1
sync
mv "$UV_DIR/campaign.chip.tmp" "$UV_DIR/campaign.chip" || exit 1
mv "$UV_DIR/campaign.model.tmp" "$UV_DIR/campaign.model" || exit 1
[ "$(cat "$UV_DIR/campaign.chip" 2>/dev/null)" = "$DEV_CHIP" ] &&
	[ "$(cat "$UV_DIR/campaign.model" 2>/dev/null)" = "$DEV_MODEL" ] || {
	say.elf "Could not bind the measurement
to this device. Nothing was started."
	exit 1
}
rm -f "$CHIP_DIR/table.conf" "$CHIP_DIR/table.model" "$CHIP_DIR/table.chip" "$CHIP_DIR/table.stock" "$CHIP_DIR/calibration"
touch "$UV_DIR/ARMED"
sync

say.elf "Measurement started.

Leave it charging.
It restarts itself several times and
finishes in about 90 minutes.
Check back here any time."

( sh "$UV_DIR/uvmap.sh" > /dev/null 2>&1 & )
exit 0
