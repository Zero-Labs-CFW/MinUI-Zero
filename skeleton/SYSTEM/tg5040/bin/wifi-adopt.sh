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
	# Only a config with exactly ONE network={} block, whose name and plain password are both simple quoted values
	# (no quote or backslash inside, nothing after the closing quote), taken from that block. Anything else is
	# skipped: adoption rewrites the config from wifi.txt at the next boot, so picking the wrong one of several
	# networks, or copying an escaped password literally, would replace a working config with a broken one, while
	# a skip only leaves the Settings row hidden (Codex review, 2026-10-07). wpa_passphrase keeps the plain
	# password as a #psk="..." comment beside the hashed one.
	pair=$(awk '
		/^[[:space:]]*network[[:space:]]*=[[:space:]]*\{/ { blocks++; inblk = 1; next }
		inblk && /^[[:space:]]*\}/ { inblk = 0; next }
		inblk && /^[[:space:]]*ssid=/ { if ($0 ~ /^[[:space:]]*ssid="[^"\\]+"[[:space:]]*\r?$/) { s = $0; sub(/^[[:space:]]*ssid="/, "", s); sub(/"[[:space:]]*\r?$/, "", s) } else bad = 1 }
		inblk && /^[[:space:]]*#?psk="/ { if ($0 ~ /^[[:space:]]*#?psk="[^"\\]+"[[:space:]]*\r?$/) { p = $0; sub(/^[[:space:]]*#?psk="/, "", p); sub(/"[[:space:]]*\r?$/, "", p) } else bad = 1; next }
		inblk && /^[[:space:]]*(ssid=|psk=|key_mgmt=WPA-PSK[[:space:]]*\r?$|priority=|#|\r?$)/ { next }
		inblk { bad = 1 }
		END { if (blocks == 1 && !bad && s != "" && p != "") { print s; print p } }
	' /etc/wifi/wpa_supplicant.conf)
	ssid=$(printf '%s\n' "$pair" | sed -n 1p)
	psk=$(printf '%s\n' "$pair" | sed -n 2p)
fi
# wifi.txt splits at the first colon, so a name with one cannot be written; a hashed-only password cannot either
[ -n "$ssid" ] && [ -n "$psk" ] || exit 0
case "$ssid" in *:*) exit 0 ;; esac

printf '%s:%s\n' "$ssid" "$psk" > "$SD/wifi.txt.tmp" && mv "$SD/wifi.txt.tmp" "$SD/wifi.txt" && sync
