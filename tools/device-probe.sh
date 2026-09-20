#!/bin/sh
# Device Sync bring-up probe. Run ON a new device (or over ssh) BEFORE porting Device Sync to it. Prints
# the answers to every question that cost a day on an existing port (2026-09-18..20): the pak reads the
# same facts at runtime, and the on-device harness (.notes/2026-09-18-true-sync/e2e-device-test.sh) is
# the acceptance gate. Nothing here changes the device: no radio writes, no files outside /tmp.
#
#   sh tools/device-probe.sh            (on the device)
#   cat tools/device-probe.sh | ssh root@<ip> sh
T=$(printf '\t')
say(){ printf '%-34s %s\n' "$1" "$2"; }
echo "== Device Sync probe: $(hostname 2>/dev/null) $(cat /tmp/deviceModel 2>/dev/null) =="
say "busybox"            "$(busybox 2>&1 | head -1 | cut -c1-40)"
say "card root"          "$([ -d /mnt/SDCARD/.system ] && echo /mnt/SDCARD; [ -d /mnt/mmc/.system ] && echo /mnt/mmc)"
say "platform dir"       "$(ls -d /mnt/SDCARD/.system/*/ /mnt/mmc/.system/*/ 2>/dev/null | grep -vE 'res/|LICENSES' | tr '\n' ' ')"
echo "-- shell/tools the engine relies on --"
say "awk -F tab (must be 3)" "$(printf 'a%sb%sc\n' "$T" "$T" | awk -F'\t' '{print NF}') (literal \\t)  vs $(printf 'a%sb%sc\n' "$T" "$T" | awk -F"$T" '{print NF}') (real tab)"
say "stat -c (gnu)"      "$(stat -c %s . >/dev/null 2>&1 && echo yes || echo NO)"
say "/dev/stdin"         "$([ -e /dev/stdin ] && echo yes || echo NO)"
say "find -L"            "$(find -L /etc -maxdepth 0 >/dev/null 2>&1 && echo yes || echo "NO (use -follow)")"
say "cmp / md5sum / tar" "$(command -v cmp >/dev/null && echo cmp)/$(command -v md5sum >/dev/null && echo md5sum)/$(command -v tar >/dev/null && echo tar)"
say "wget -T supported"  "$(wget --help 2>&1 | grep -q -- '-T SEC' && echo yes || echo "NO (never pass -T)")"
say "/tmp size"          "$(df -k /tmp 2>/dev/null | awk 'NR==2{printf "%d MB (%d free)", $2/1024, $4/1024}')"
echo "-- network --"
say "interfaces"         "$(ls /sys/class/net | tr '\n' ' ')"
say "wlan0 driver"       "$(readlink /sys/class/net/wlan0/device/driver 2>/dev/null | sed 's|.*/||')"
say "wlan1 present"      "$([ -e /sys/class/net/wlan1 ] && echo yes || echo NO)"
say "iw"                 "$(command -v iw || echo "NONE (cannot scan: host-only device)")"
[ -x "$(command -v iw)" ] && say "  AP mode advertised" "$(iw list 2>/dev/null | grep -c '\* AP') band(s)"
say "hostapd"            "$(command -v hostapd || ls /mnt/SDCARD/.system/*/bin/hostapd /mnt/mmc/.system/*/bin/hostapd 2>/dev/null | head -1 || echo NONE)"
say "  hostapd drivers"  "$(strings "$(command -v hostapd || ls /mnt/SDCARD/.system/*/bin/hostapd /mnt/mmc/.system/*/bin/hostapd 2>/dev/null | head -1)" 2>/dev/null | grep -xE 'nl80211|rtl871xdrv|wext' | tr '\n' ' ')"
say "wpa_supplicant"     "$(command -v wpa_supplicant || ls /customer/app/wpa_supplicant 2>/dev/null || echo NONE)"
say "http server"        "$(command -v httpd >/dev/null && echo 'busybox httpd' || (command -v darkhttpd >/dev/null && echo darkhttpd) || echo NONE)"
say "dhcp server"        "$(command -v udhcpd >/dev/null && echo udhcpd || (command -v dnsmasq >/dev/null && echo dnsmasq) || echo NONE)"
say "station managed by" "$(pidof dhcpcd >/dev/null 2>&1 && echo dhcpcd; pidof wpa_supplicant >/dev/null 2>&1 && echo wpa_supplicant; pidof udhcpc >/dev/null 2>&1 && echo udhcpc)"
say "rfkill"             "$(command -v rfkill >/dev/null && rfkill list 2>/dev/null | grep -c 'Soft blocked: yes' | sed 's/^/soft-blocked=/' || echo none)"
say "vendor radio tool"  "$([ -x /customer/app/axp_test ] && echo '/customer/app/axp_test (Miyoo: wifion only when wlan0 absent!)' || echo none)"
echo "-- tool environment (as a pak sees it) --"
for pid in $(pidof minui.elf MainUI 2>/dev/null); do say "launcher env PLATFORM" "$(tr '\0' '\n' </proc/$pid/environ 2>/dev/null | sed -n 's/^PLATFORM=//p')"; say "launcher LD_LIBRARY_PATH" "$(tr '\0' '\n' </proc/$pid/environ 2>/dev/null | sed -n 's/^LD_LIBRARY_PATH=//p')"; done
echo "== next: run the harness loopback on this device, then two-device against a Brick =="
