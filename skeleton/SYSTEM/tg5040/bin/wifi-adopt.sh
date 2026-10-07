#!/bin/sh
# wifi-adopt.sh: give a dev card's WiFi a wifi.txt, so Settings shows its On/Off row (Dan, 2026-10-07: "It should
# still be there, to turn it on/off. Brick Pro doesn't have it shown").
#
# The row exists only when the card has wifi.txt or wifi.txt.off, the one source of truth. TrimUI has a second way
# to bring WiFi up: a dev card (devmode) or the old two-file setup (enable-ssh plus a shell-syntax wifi.conf,
# before wifi.txt existed) runs dev-net.sh, which joins from wifi.conf or the firmware's /etc/wifi config. Such a
# card was on WiFi with no toggle. This writes the network it already joins into wifi.txt; boot then derives the
# same wifi.conf + enable-ssh from it, so nothing about the connection changes, and Off/On work as on any card.
# TrimUI only, earned: the Miyoo and Anbernic builds bring WiFi up from wifi.txt alone, so their row is never
# missing. Called by MinUI.pak at boot and by Settings when it opens. Silent; a no-op unless all of:
# no wifi.txt or wifi.txt.off, WiFi enabled by that route, and a readable network name + plain password.
SD="${SDCARD_PATH:?}"
SHARED="${SHARED_USERDATA_PATH:?}"

[ -f "$SD/wifi.txt" ] || [ -f "$SD/wifi.txt.off" ] && exit 0
[ -f "$SD/devmode" ] || [ -f "$SD/devmode.txt" ] || [ -f "$SHARED/enable-ssh" ] || exit 0

ssid=; psk=
if [ -f "$SHARED/wifi.conf" ]; then # dev-net.sh sources it too
	ssid=$(. "$SHARED/wifi.conf" >/dev/null 2>&1; printf '%s' "$SSID")
	psk=$(. "$SHARED/wifi.conf" >/dev/null 2>&1; printf '%s' "$PSK")
fi
if [ -z "$ssid" ] && [ -f /etc/wifi/wpa_supplicant.conf ]; then
	# the first network; wpa_passphrase keeps the plain password as a #psk="..." comment beside the hashed one
	ssid=$(sed -n 's/^[[:space:]]*ssid="\(.*\)"[[:space:]]*$/\1/p' /etc/wifi/wpa_supplicant.conf | head -1)
	psk=$(sed -n 's/^[[:space:]]*#\{0,1\}psk="\(.*\)"[[:space:]]*$/\1/p' /etc/wifi/wpa_supplicant.conf | head -1)
fi
# wifi.txt splits at the first colon, so a name with one cannot be written; a hashed-only password cannot either
[ -n "$ssid" ] && [ -n "$psk" ] || exit 0
case "$ssid" in *:*) exit 0 ;; esac

printf '%s:%s\n' "$ssid" "$psk" > "$SD/wifi.txt.tmp" && mv "$SD/wifi.txt.tmp" "$SD/wifi.txt" && sync
