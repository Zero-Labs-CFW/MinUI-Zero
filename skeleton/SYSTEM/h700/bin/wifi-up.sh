#!/bin/sh
# wifi-up.sh: the h700 wifi connect from wifi.txt, as one callable step. Runs at boot from
# MinUI.pak/launch.sh (which keeps the reconnect monitor and SSH) and from Tools > WiFi on TURN ON
# (Dan, 2026-09-16: no reboot to turn it on). Credentials are USER-SUPPLIED and never baked into an
# image: wifi.txt at the card root, one "SSID:password" line, # comments.
SD="${SDCARD_PATH:?}"
LOG="${LOGS_PATH:?}/launch.txt"

[ -f "$SD/wifi.txt" ] || exit 0
_line=$(sed '/^#/d;/^[[:space:]]*$/d' "$SD/wifi.txt" | head -1)
_ssid=${_line%%:*}; _psk=${_line#*:}
[ -n "$_ssid" ] && [ "$_ssid" != "$_line" ] || exit 0
# Tools > WiFi blocks the radio on TURN OFF; undo that first (no-op at boot)
command -v rfkill >/dev/null 2>&1 && rfkill unblock wifi 2>/dev/null
if [ -x /opt/muos/script/system/network.sh ] && [ -f /opt/muos/script/var/func.sh ]; then
	# muOS layer: delegate to its proven bring-up (driver load, scan, wpa_passphrase, dhcp,
	# validate, keepalive with the rtw_power_mgnt=0 idle-drop fix). Hand-rolling this is what
	# broke wifi repeatedly, so on that layer we do not.
	( . /opt/muos/script/var/func.sh
	  SET_VAR "config" "network/ssid"   "$_ssid"
	  SET_VAR "config" "network/pass"   "$_psk"
	  SET_VAR "config" "network/hidden" "0"
	  SET_VAR "config" "network/type"   "0"
	  SET_VAR "config" "settings/network/con_retry"  "3"
	  SET_VAR "config" "settings/network/monitor"    "1" )
	/opt/muos/script/system/network.sh connect >> "$LOG" 2>&1 &
else
	# Bare OS layer: wpa_supplicant directly. The module is already loaded by rcS when
	# wifi.txt exists, so the interface should be present; wait briefly rather than assume.
	for _i in 1 2 3 4 5 6 7 8 9 10; do
		[ -d /sys/class/net/wlan0 ] && break
		sleep 1
	done
	ifconfig wlan0 up 2>/dev/null
	_conf=/tmp/wpa.conf
	{ echo "ctrl_interface=/var/run/wpa_supplicant"
	  echo "network={"
	  echo "	ssid=\"$_ssid\""
	  echo "	psk=\"$_psk\""
	  echo "}"; } > "$_conf"
	chmod 600 "$_conf"
	wpa_supplicant -B -i wlan0 -c "$_conf" >> "$LOG" 2>&1
	# udhcpc, not dhcpcd: busybox provides it and it is already in the rootfs.
	udhcpc -i wlan0 -b -q >> "$LOG" 2>&1 &
fi
