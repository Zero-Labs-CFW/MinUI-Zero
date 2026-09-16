#!/bin/sh
# wifi-up.sh: the MMP wifi bring-up from wifi.txt, as one callable step. Runs at boot from
# MinUI.pak/launch.sh and from Tools > WiFi on TURN ON (Dan, 2026-09-16: no reboot to turn it on).
# The command sequence is not guessed: it is reconstructed from the old community pak's own set-x
# trace, which survived in .userdata/miyoomini/logs/Wifi.on-boot.txt (2026-08-31). Stock internal
# binaries do the work (/customer/app/*); only the 8188fu kernel module has no certain internal
# home, so the known candidates are tried and a probe is logged when all miss.
SD="${SDCARD_PATH:?}"
SYS="${SYSTEM_PATH:?}"
LOGS="${LOGS_PATH:?}"

[ -f "$SD/wifi.txt" ] || exit 0
_w=$(sed '/^#/d;/^[[:space:]]*$/d' "$SD/wifi.txt" | head -1)
_ssid=${_w%%:*}; _psk=${_w#*:}
[ -n "$_ssid" ] && [ "$_ssid" != "$_w" ] || exit 0
mkdir -p "$LOGS"
{
echo "== wifi.txt bring-up $(date 2>/dev/null)"
# stock config: wpa_supplicant.conf lives in the console's internal /appconfigs
printf 'ctrl_interface=/var/run/wpa_supplicant\nupdate_config=1\nnetwork={\n\tssid="%s"\n\tpsk="%s"\n}\n' "$_ssid" "$_psk" > /appconfigs/wpa_supplicant.conf
# driver module: card ship first (if we ever bundle one), then stock candidates
if ! grep -q 8188fu /proc/modules 2>/dev/null; then
	for KO in "$SYS/lib/modules/8188fu.ko" /config/wifi/8188fu.ko /customer/wifi/8188fu.ko /lib/modules/8188fu.ko; do
		[ -f "$KO" ] && { insmod "$KO"; echo "insmod $KO rc=$?"; break; }
	done
fi
if ! grep -q 8188fu /proc/modules 2>/dev/null; then
	echo "PROBE: no 8188fu.ko found; candidates on this console:"
	find /config /customer /lib -name "*8188*" 2>/dev/null
fi
# Tools > WiFi blocks the radio on TURN OFF; undo that first (no-op at boot)
command -v rfkill >/dev/null 2>&1 && rfkill unblock wifi 2>/dev/null
# power + interface + supplicant, straight from the old pak's trace
ifconfig lo up 2>/dev/null
/customer/app/axp_test wifion
sleep 2
ifconfig wlan0 up
killall wpa_supplicant 2>/dev/null; killall udhcpc 2>/dev/null
/customer/app/wpa_supplicant -B -D nl80211 -iwlan0 -c /appconfigs/wpa_supplicant.conf
udhcpc -i wlan0 -t 8 -T 3 -b 2>/dev/null &
command -v iw >/dev/null 2>&1 && iw dev wlan0 set power_save off 2>/dev/null
} >> "$LOGS/wifi.txt.log" 2>&1
