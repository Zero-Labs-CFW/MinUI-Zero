#!/bin/sh
# wifi-up.sh: bring WiFi up from wifi.txt NOW, no reboot (Dan, 2026-09-16: "fix the WiFi toggle so
# when turning it on, reboot is not required"). Called by Tools > WiFi on TURN ON. The boot path in
# MinUI.pak/launch.sh does this same wifi.txt -> wifi.conf + enable-ssh translation inline and then
# runs dev-net.sh; this is that pair as one callable step, so the tool never grows a bring-up of
# its own to drift from boot. dev-net.sh unblocks the radio, (re)starts wpa_supplicant + udhcpc and
# starts SSH, exactly as it does at boot.
SD="${SDCARD_PATH:?}"
SYS="${SYSTEM_PATH:?}"
SHARED="${SHARED_USERDATA_PATH:?}"

[ -f "$SD/wifi.txt" ] || exit 0
_w=$(sed '/^#/d;/^[[:space:]]*$/d' "$SD/wifi.txt" | head -1)
_ssid=${_w%%:*}; _psk=${_w#*:}
[ -n "$_ssid" ] && [ "$_ssid" != "$_w" ] || exit 0
mkdir -p "$SHARED"
printf 'SSID=%s\nPSK=%s\n' "$_ssid" "$_psk" > "$SHARED/wifi.conf"
touch "$SHARED/enable-ssh"
exec sh "$SYS/bin/dev-net.sh"
