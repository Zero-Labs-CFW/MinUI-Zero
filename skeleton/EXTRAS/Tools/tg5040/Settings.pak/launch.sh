#!/bin/sh
# MinUI Zero Settings: the device-wide toggles on one screen, drawn like the in-game Options
# (label, value, a description under the list; Dan, 2026-09-16: "similar to Frontend design").
# Every row is also a small file on the card (README > Flags): this pak only creates or removes
# those files, so the computer path keeps working and nothing on an existing card migrates.
# ONE script, duplicated per platform (parity rule: change one, diff the others); the
# device-specific lines are guarded. settings.elf draws and reports, this script applies.

CARD="$SDCARD_PATH"
SHARED="$SHARED_USERDATA_PATH"
NO_RECENTS="$CARD/no-recents"
NO_FAVORITES="$CARD/no-favorites"
FOCUS="$CARD/focus"
HIDE_TOOLS="$CARD/hide-tools"
DEEP_SLEEP_OFF="$SHARED/disable-deep-sleep"
WTXT="$CARD/wifi.txt"
WOFF="$CARD/wifi.txt.off"

flag_off() { if [ -f "$1" ]; then echo Off; else echo On; fi; } # file present = Off (the opt-out flags)

# WiFi: the card's wifi.txt stays the ONE source of truth (SSID:password, opt-in by existing). The
# row shows the real state and flips the file between wifi.txt and wifi.txt.off. No file, no row
# (Dan, 2026-09-16: "I don't think we should promote networking, it's mostly for dev tooling").
wifi_state() { # prints: up <ip> | joined | down
	S=$(cat /sys/class/net/wlan0/operstate 2>/dev/null)
	if [ "$S" = "up" ]; then
		IP=$(ip -4 addr show wlan0 2>/dev/null | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -1)
		[ -n "$IP" ] || IP=$(ifconfig wlan0 2>/dev/null | sed -n 's/.*inet addr:\([0-9.]*\).*/\1/p') # busybox without ip (h700)
		[ -n "$IP" ] && echo "up $IP" || echo "joined"
	else
		echo "down"
	fi
}
wifi_ssid() { sed '/^#/d;/^[[:space:]]*$/d' "$1" | head -1 | cut -d: -f1; }
wifi_row() { # sets WIFI_VALUES WIFI_CURRENT WIFI_DESC
	if [ -f "$WTXT" ]; then
		WIFI_VALUES="On|Off"; WIFI_CURRENT=On
		case "$(wifi_state)" in
			up*)    WIFI_DESC="Connected to \"$(wifi_ssid "$WTXT")\", IP $(wifi_state | cut -d' ' -f2)." ;;
			joined) WIFI_DESC="Joining \"$(wifi_ssid "$WTXT")\"..." ;;
			*)      WIFI_DESC="Not connected to \"$(wifi_ssid "$WTXT")\" yet.\nTakes a minute, or the password is wrong." ;;
		esac
	else
		WIFI_VALUES="On|Off"; WIFI_CURRENT=Off
		WIFI_DESC="On: connects to \"$(wifi_ssid "$WOFF")\" and starts SSH."
	fi
}
wifi_off() {
	mv "$WTXT" "$WOFF"; sync
	# take the radio down NOW, not just at next boot
	# by pid: the Brick's busybox killall does nothing to applets, so udhcpc kept running (audit 2026-09-23)
	for p in $(pidof wpa_supplicant udhcpc 2>/dev/null); do kill "$p" 2>/dev/null; done
	ifconfig wlan0 down 2>/dev/null
	command -v rfkill >/dev/null 2>&1 && rfkill block wifi 2>/dev/null
	# Miyoo: the PMIC can cut the radio's power rail entirely (guarded no-op elsewhere)
	[ -x /customer/app/axp_test ] && /customer/app/axp_test wifioff >/dev/null 2>&1
}
wifi_on() {
	mv "$WOFF" "$WTXT"; sync
	# bring the radio up NOW: the same step the boot path runs, per platform
	sh "$SYSTEM_PATH/bin/wifi-up.sh" >/dev/null 2>&1 &
}

while :; do
	set --
	set -- "$@" recents   "Recents"   "On|Off" "$(flag_off "$NO_RECENTS")"   "On: Recently Played on the main menu.\nOff: hidden, and plays are not recorded."
	# Favorites and Focus are ONE row with three values (Dan, 2026-09-16: two rows made Focus depend
	# on Favorites in a way the user had to manage). Focus with nothing favorited just waits: the
	# launcher shows the normal menu until the first favorite exists.
	if [ -f "$NO_FAVORITES" ]; then FAV=Off; elif [ -f "$FOCUS" ]; then FAV=Focus; else FAV=On; fi
	set -- "$@" favorites "Favorites" "Off|On|Focus" "$FAV" "Y in a game's menu makes it a favorite.\nOn: Favorites appears on the main menu.\nFocus: the main menu is only your favorites."
	if [ -f "$HIDE_TOOLS" ]; then TOOLS=Hidden; else TOOLS=Shown; fi
	set -- "$@" tools "Tools" "Shown|Hidden" "$TOOLS" "Hidden: SELECT + START at the main menu\nstill opens Tools."
	# deep sleep exists on TrimUI and Anbernic; the Miyoo cannot (its bin/suspend is the faux sleep)
	if [ "$PLATFORM" != "miyoomini" ]; then
		set -- "$@" deepsleep "Deep Sleep" "On|Off" "$(flag_off "$DEEP_SLEEP_OFF")" "On: suspends to RAM when idle. Near-zero\npower, wakes instantly. Off: sleeps like stock."
	fi
	# Optimize CPU (TrimUI only; Dan, 2026-09-16: "saying it's been optimized or not"). The pak
	# keeps its own reviewed state machine; this row only READS this chip's result and hands off
	# to the pak on A. Same slot layout as the pak: undervolt/chips/<serial>/.
	UV_PAK="$SYSTEM_PATH/paks/Optimize CPU.pak/launch.sh"
	if [ -f "$UV_PAK" ]; then
		UV_DIR="$USERDATA_PATH/undervolt"
		UV_CHIP=$(grep sunxi_serial /sys/class/sunxi_info/sys_info 2>/dev/null | awk -F: '{print $2}' | tr -d ' \t\r\n')
		UV_SLOT="$UV_DIR/chips/$UV_CHIP"
		if [ -f "$UV_DIR/ARMED" ]; then
			UV_VALUE="Measuring"
			UV_DESC="$(grep -cE '^[0-9]+ (CLIFF|DONE)' "$UV_SLOT/margins.log" 2>/dev/null) of 8 steps done. Keep it charging.\nPress A for details."
		elif [ -n "$UV_CHIP" ] && [ -f "$UV_SLOT/table.conf" ] && [ -f "$UV_SLOT/calibration" ] && [ "$(tr -d ' \t\r\n' < "$UV_SLOT/table.chip" 2>/dev/null)" = "$UV_CHIP" ]; then
			UV_VALUE="Optimized"
			UV_DESC="Undervolted to this chip's measured minimum.\nPress A to manage."
		elif [ -n "$UV_CHIP" ] && [ -f "$UV_SLOT/table.conf.reverted" ] && [ -f "$UV_SLOT/calibration" ]; then
			UV_VALUE="Stock"
			UV_DESC="Saved tuning available, factory voltage now.\nPress A to re-enable."
		else
			UV_VALUE="Stock"
			UV_DESC="Finds this chip's lowest safe voltage.\nCooler, longer battery, same speed. Press A."
		fi
		set -- "$@" optimize "Optimize CPU" "" "$UV_VALUE" "$UV_DESC"
	fi
	if [ -f "$WTXT" ] || [ -f "$WOFF" ]; then
		wifi_row
		set -- "$@" wifi "WiFi" "$WIFI_VALUES" "$WIFI_CURRENT" "$WIFI_DESC"
	fi
	# same 12/24 h choice as the clock tool and the menu clock (clock.elf keeps it in show_24hour)
	if [ -f "$USERDATA_PATH/show_24hour" ]; then NOW=$(date '+%H:%M'); else NOW=$(date '+%l:%M %p' | sed 's/^ *//'); fi
	set -- "$@" datetime "Date & Time" "" "$NOW" "Press A to set. The clock can also\nshow on the main menu."

	OUT=$(settings.elf --title "Settings" "$@")
	AGAIN=0
	for line in $OUT; do # KEY=VALUE tokens; a value never contains a space
		case "$line" in
			recents=On)    rm -f "$NO_RECENTS" ;;
			recents=Off)   touch "$NO_RECENTS" ;;
			favorites=Off)   touch "$NO_FAVORITES"; rm -f "$FOCUS" ;;
			favorites=On)    rm -f "$NO_FAVORITES" "$FOCUS" ;;
			favorites=Focus) rm -f "$NO_FAVORITES"; touch "$FOCUS"
				# Focus with nothing favorited shows the normal menu until the first favorite: say so once, here
				grep -q . "$SHARED/.minui/favorites.txt" 2>/dev/null || say.elf "No favorites yet.

Press Y in a game's menu to add one.
Focus starts with your first favorite." ;;
			tools=Shown)   rm -f "$HIDE_TOOLS" ;;
			tools=Hidden)
				if confirm.elf "Hide Tools?

SELECT + START at the main menu
opens Tools anyway." "HIDE" "BACK"; then touch "$HIDE_TOOLS"; else AGAIN=1; fi ;;
			deepsleep=On)  rm -f "$DEEP_SLEEP_OFF" ;;
			deepsleep=Off) touch "$DEEP_SLEEP_OFF" ;;
			wifi=On)       [ -f "$WOFF" ] && wifi_on; AGAIN=1 ;;
			wifi=Off)      [ -f "$WTXT" ] && wifi_off; AGAIN=1 ;;
			OPEN=datetime) clock.elf; AGAIN=1 ;;
			OPEN=optimize) sh "$UV_PAK"; AGAIN=1 ;;
		esac
	done
	sync
	[ "$AGAIN" = "1" ] || break
done
