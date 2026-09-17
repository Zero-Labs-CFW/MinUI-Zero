#!/bin/sh
# Stay Awake net-keeper (DEV TOOL): the wifi driver on these devices occasionally wedges —
# device fine, radio dead — and only an interface bounce (or suspend/resume) revives it.
# Ping the gateway every 20s; on 3 consecutive failures, bounce wlan0 and reassociate.
# Killed by the Stay Awake tool's TURN OFF path; spawned by tool-on and the boot re-arm.
FAILS=0
LOGF=/mnt/SDCARD/.userdata/tg5040/logs/net-keeper.txt
while [ -f /mnt/SDCARD/.userdata/shared/dev-stay-awake ]; do
	# Device Sync deliberately drops home wifi to join a peer hotspot, then restores it. While that is in
	# flight the gateway is gone ON PURPOSE; bouncing wlan0 here tore down the join and then the restore
	# and stranded the Brick off wifi three times on 2026-09-05. Stand down while the flag exists.
	if [ -f /tmp/dsync-radio-busy ]; then FAILS=0; sleep 20; continue; fi
	GW=$(ip route 2>/dev/null | awk '/default/ {print $3; exit}')
	[ -z "$GW" ] && GW=$(route -n 2>/dev/null | awk '$1=="0.0.0.0" {print $2; exit}')
	if [ -n "$GW" ] && ping -c 1 -W 2 "$GW" >/dev/null 2>&1; then
		FAILS=0
	else
		FAILS=$((FAILS+1))
		if [ "$FAILS" -ge 3 ]; then
			echo "$(date +%H:%M:%S) wifi wedged (gw=$GW) — bouncing wlan0" >> $LOGF
			ip link set wlan0 down 2>/dev/null || ifconfig wlan0 down 2>/dev/null
			sleep 2
			ip link set wlan0 up 2>/dev/null || ifconfig wlan0 up 2>/dev/null
			wpa_cli -i wlan0 reassociate >/dev/null 2>&1
			sleep 8
			udhcpc -i wlan0 -n -q >/dev/null 2>&1
			iw dev wlan0 set power_save off 2>/dev/null
			FAILS=0
		fi
	fi
	sleep 20
done
