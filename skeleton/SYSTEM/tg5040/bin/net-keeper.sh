#!/bin/sh
# net-keeper.sh: DEV MODE ONLY. Keeps a dev card reachable over SSH (Dan, 2026-11-18: "We need to fix this issue
# where you cannot connect to these devices"). Seen on the Brick Pro and Smart Pro that day: dev-net.sh joined WiFi
# at boot, the link was gone later, and only a WiFi Off/On in Settings (which reruns the full wpa_supplicant +
# udhcpc start) brought it back. This watches the link every 15 s and does that same full restart when the device
# has no address or cannot reach its gateway twice in a row. It also restarts our SSH daemon if it died.
# Started by dev-net.sh; one instance per boot; exits when dev mode is turned off.
SD=/mnt/SDCARD
SHARED="$SD/.userdata/shared"
LOGF="$SD/.userdata/tg5040/logs/net-keeper.txt"
PIDF=/tmp/net-keeper.pid

if [ -f "$PIDF" ]; then
	read -r old < "$PIDF"
	case "$(tr '\0' ' ' < "/proc/$old/cmdline" 2>/dev/null)" in *net-keeper*) exit 0 ;; esac
fi
echo $$ > "$PIDF"

say() { echo "$(date '+%F %T') $*" >> "$LOGF"; }
# devmode only: a user card with wifi.txt also runs dev-net.sh, and a ping every 15 s would keep its radio awake
dev_on() { [ -f "$SD/devmode.txt" ] || [ -f "$SD/devmode" ]; }
# Times the radio is down ON PURPOSE: WiFi toggled off, a game with WiFi off, Device Sync on a peer hotspot,
# or a suspend in progress (bin/suspend takes wlan0 down and brings it back itself).
radio_held() {
	{ [ -f "$SD/wifi.txt.off" ] && [ ! -f "$SD/wifi.txt" ]; } || [ -f /tmp/game-wifi-off ] ||
		[ -f /tmp/dsync-radio-busy ] || [ -f /tmp/wifi-restore-pending ] || pgrep -f "bin/suspend" >/dev/null 2>&1
}
addr() { ip -4 addr show wlan0 2>/dev/null | sed -n 's#.*inet \([0-9.]*\)/.*#\1#p' | head -1; }
gw() { ip route 2>/dev/null | awk '/^default/ {print $3; exit}'; }

say "start (pid $$)"
fails=0
while dev_on; do
	sleep 15
	if radio_held; then fails=0; continue; fi
	a=$(addr); g=$(gw)
	if [ -n "$a" ] && [ -n "$g" ] && ping -c 1 -W 3 "$g" >/dev/null 2>&1; then
		fails=0
	else
		fails=$((fails + 1))
		if [ "$fails" -ge 2 ]; then
			say "link lost (addr=${a:-none} gw=${g:-none}), restarting WiFi"
			rfkill unblock wifi 2>/dev/null
			for p in $(pidof wpa_supplicant udhcpc 2>/dev/null); do kill "$p" 2>/dev/null; done # by pid: busybox killall skips applets
			ifconfig wlan0 down 2>/dev/null
			sleep 1
			ifconfig wlan0 up 2>/dev/null
			wpa_supplicant -B -D nl80211 -iwlan0 -c /etc/wifi/wpa_supplicant.conf -O /etc/wifi/sockets >/dev/null 2>&1
			( udhcpc -i wlan0 >/dev/null 2>&1 & )
			iw dev wlan0 set power_save off 2>/dev/null
			i=0
			while [ $i -lt 20 ] && [ -z "$(addr)" ]; do sleep 1; i=$((i + 1)); done
			say "after restart: addr=$(addr)"
			fails=0
		fi
	fi
	# our key-only daemon on 2022 (dev-net.sh step 5); restart it if it died
	if ! pgrep -f "dropbear.*2022" >/dev/null 2>&1; then
		DBM="$SD/.system/tg5040/bin/dropbearmulti"
		KEY="$SHARED/dropbear_ed25519_host_key"
		[ -x "$DBM" ] && [ -f "$KEY" ] && "$DBM" dropbear -s -r "$KEY" -p 2022 2>/dev/null && say "restarted dropbear on 2022"
	fi
done
say "dev mode off, exiting"
rm -f "$PIDF"
