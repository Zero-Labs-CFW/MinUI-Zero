#!/bin/sh
# net-keeper.sh: DEV MODE ONLY. Keeps a dev card reachable over SSH (Dan, 2026-11-18: "We need to fix this issue
# where you cannot connect to these devices"). Seen on the Brick Pro and Smart Pro that day: dev-net.sh joined WiFi
# at boot, the link was gone later, and only a WiFi Off/On in Settings (which reruns the full wpa_supplicant +
# udhcpc start) brought it back. This watches the link every 15 s and does that same full restart when the device
# has no address, or cannot reach its gateway eight checks in a row (about 2 min) while no big transfer is running, then holds off 2 min. It also restarts our SSH daemon if it died.
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
last_rx=
while dev_on; do
	sleep 15
	if radio_held; then fails=0; continue; fi
	a=$(addr); g=$(gw)
	# WiFi power save adds hundreds of ms to the first packet, so a Mac probe with a short timeout missed a healthy Brick
	# (2026-11-19; the Brick boots with it on, the Brick Pro and Smart Pro with it off). Every WiFi restart turns it back on.
	iw dev wlan0 get power_save 2>/dev/null | grep -q ': on' && iw dev wlan0 set power_save off 2>/dev/null
	# A big transfer (more than 64 KB received since the last check) proves the link is alive: under one the gateway
	# ping can time out, and bouncing WiFi then killed the transfer itself (an ssh copy to the Brick, 2026-11-18).
	# Small counts do not count: broadcast traffic keeps arriving on a link that is otherwise wedged.
	read -r rx < /sys/class/net/wlan0/statistics/rx_bytes 2>/dev/null || rx=0
	busy=0
	[ -n "$last_rx" ] && [ "$rx" -gt $((last_rx + 65536)) ] 2>/dev/null && busy=1
	last_rx=$rx
	if [ -n "$a" ] && { [ "$busy" = 1 ] || { [ -n "$g" ] && ping -c 1 -W 3 "$g" >/dev/null 2>&1; }; }; then
		fails=0
	else
		fails=$((fails + 1))
	fi
	# 8 checks (about 2 min) before acting, and a 2 min hold after each restart: an early version restarted every
	# 45 s while DHCP was still running, which itself kept the device off the network (2026-11-18).
	# The check at the top of the loop is seconds old by now (the 3 s ping): a WiFi Off, a game or a suspend that
	# started since then must not be undone (review 2026-11-19), so radio_held is asked again right before the
	# restart and again before the radio comes back up. A hold seen after the down leaves the radio as the off path
	# set it: our rfkill unblock runs only after that second check.
	if [ "$fails" -ge 8 ] && [ "${hold:-0}" -le 0 ] && radio_held; then
		say "link lost, but the radio is now held off on purpose: no restart"
		fails=0; last_rx=
	elif [ "$fails" -ge 8 ] && [ "${hold:-0}" -le 0 ]; then
		say "link lost (addr=${a:-none} gw=${g:-none}), restarting WiFi"
		for p in $(pidof wpa_supplicant udhcpc 2>/dev/null); do kill "$p" 2>/dev/null; done # by pid: busybox killall skips applets
		ifconfig wlan0 down 2>/dev/null
		sleep 1
		if radio_held; then
			say "radio held off during the restart: left down"
			fails=0; last_rx=; hold=8
			continue
		fi
		rfkill unblock wifi 2>/dev/null # only after the re-check, so it never cancels an off path's block
		ifconfig wlan0 up 2>/dev/null
		wpa_supplicant -B -D nl80211 -iwlan0 -c /etc/wifi/wpa_supplicant.conf -O /etc/wifi/sockets >/dev/null 2>&1
		( udhcpc -i wlan0 >/dev/null 2>&1 & )
		iw dev wlan0 set power_save off 2>/dev/null
		i=0
		while [ $i -lt 45 ] && [ -z "$(addr)" ]; do sleep 1; i=$((i + 1)); done
		say "after restart: addr=$(addr)"
		fails=0
		last_rx=
		hold=8
	fi
	[ "${hold:-0}" -gt 0 ] && hold=$((hold - 1))
	# heartbeat every 20 checks (about 5 min): when the Mac cannot reach a device, this shows whether the device
	# itself thought it was connected (a 2026-11-18 outage logged no restart at all)
	beat=$((${beat:-0} + 1))
	if [ "$beat" -ge 20 ]; then
		beat=0
		say "beat addr=${a:-none} gw=${g:-none} fails=$fails rx=$rx ap=$(iw dev wlan0 link 2>/dev/null | sed -n 's/^Connected to \([^ ]*\).*/\1/p')"
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
