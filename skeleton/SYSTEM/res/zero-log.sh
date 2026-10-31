# Log helpers shared by every platform's launch loop: tg5040, miyoomini and h700 MinUI.pak/launch.sh and the h700
# stripped image's minui-frontend.sh source this one copy (it ships in .system/res, the root every platform
# carries), so a fix lands everywhere at once. Needs LOGS_PATH.

# Keep the previous game's log for each system (Dan 2026-10-08): an emulator pak truncates $LOGS_PATH/<TAG>.txt at
# every launch, so a crash's evidence was gone as soon as the next game of that system started. One .prev per
# system: bounded, never grows. Takes the launch command's own words, so the shell parses its quoting (a pak named
# with an apostrophe defeated the earlier sed, Codex review 2026-10-09); only an emulator pak's launch.sh counts.
zero_rotate_prev_log() {
	case "$1" in */Emus/*.pak/launch.sh) ;; *) return 0 ;; esac
	_rpl_tag=$(basename "$(dirname "$1")" .pak)
	[ -f "$LOGS_PATH/$_rpl_tag.txt" ] && mv -f "$LOGS_PATH/$_rpl_tag.txt" "$LOGS_PATH/$_rpl_tag.prev.txt"
	return 0
}
# The launch loop's /tmp/next line: its first word, read without running anything. Evaluating the line to split it
# ran every command of a compound line twice (2026-10-17). minui.c writes 'pak' 'rom', quotes escaped as '\''; the
# device test harnesses (tools/govsweep.sh, brickpro-autotest.sh, mmp-autotest.sh) write "pak" "rom".
zero_rotate_prev_log_cmd() {
	case "$1" in
		\'*"/launch.sh'"*)
			_rpl_p=${1#\'}
			_rpl_p=${_rpl_p%%"/launch.sh'"*}/launch.sh
			case "$_rpl_p" in *"' '"*) return 0 ;; esac # past the first word
			zero_rotate_prev_log "$(printf '%s' "$_rpl_p" | sed "s/'\\\\''/'/g")" ;;
		\"*'/launch.sh"'*)
			_rpl_p=${1#\"}
			_rpl_p=${_rpl_p%%'/launch.sh"'*}/launch.sh
			case "$_rpl_p" in *'" "'*) return 0 ;; esac # past the first word
			zero_rotate_prev_log "$_rpl_p" ;;
	esac
	return 0
}

# Boot receipt for dev cards (the caller checks devmode): kernel seconds at menu launch, one ~40-byte line per
# boot, the regression canary behind the README boot table (fleet measured 2026-08-31). Past 400 lines, keep the
# newest 200.
zero_boot_receipt() {
	BT="$LOGS_PATH/boot-time.txt"
	echo "$(cut -d" " -f1 /proc/uptime) menu-ready $(date +%Y-%m-%d 2>/dev/null)" >> "$BT"
	if [ "$(wc -l < "$BT")" -gt 400 ]; then
		tail -n 200 "$BT" > "$BT.tmp" 2>/dev/null && mv -f "$BT.tmp" "$BT" || rm -f "$BT.tmp"
	fi
}
