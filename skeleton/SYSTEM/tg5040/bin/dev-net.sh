#!/bin/sh
# dev-net.sh — DEV-MODE networking for the tg5040 fork: bring up wifi + SSH for testing.
# Runs from MinUI.pak/launch.sh ONLY when /mnt/SDCARD/.userdata/shared/enable-ssh exists, so a
# normal install never enables radios (stays runs-cold). Best-effort; every device-specific
# command is guarded. Inputs/outputs all live on the SD under .userdata/shared:
#   wifi.conf         (you fill in)  SSID="..."  PSK="..."
#   authorized_keys   (you provide)  the dev SSH public key (key auth, non-interactive)
#   ssh-ip.txt        (we write)     the obtained IP + the exact ssh command to use
SD=/mnt/SDCARD
SHARED="$SD/.userdata/shared"
LOG="$SHARED/ssh-ip.txt"

{
  echo "=== dev-net $(date 2>/dev/null) ==="

  # 0) STAY AWAKE while dev SSH is enabled (Dan, 2026-09-08: "fix our SSH problem with ALL devices").
  #    This is the whole fix for the reconnect rodeo. dev-net runs only when enable-ssh exists, but
  #    the C stay-awake in PWR_init arms on a DIFFERENT flag (devmode.txt), so a card with SSH on
  #    but no devmode.txt would keep deep-sleeping after ~2 min idle and drop SSH -- and on the
  #    Brick the sleep/wake cycle made dropbear's key auth flap. STAY_AWAKE_PATH (/tmp/stay_awake)
  #    is honored by PWR_preventAutosleep in api.c, so touching it blocks autosleep for this boot.
  #    /tmp clears on reboot and dev-net re-touches it every boot, so a dev session survives reboots.
  #    Enabling SSH IS asking to keep the device reachable, so tying the two together is correct;
  #    it is dev-gated (enable-ssh), never on a user card.
  touch /tmp/stay_awake 2>/dev/null && echo "stay-awake: armed (no autosleep while SSH is on)"

  # Respect the WiFi Toggle: if the user turned WiFi OFF (wifi.txt.off, no wifi.txt), do NOT bring the
  # radio up, even in dev mode. Steps 1-3 below otherwise reassociate from the PERSISTENT
  # /etc/wifi/wpa_supplicant.conf (stock firmware's or a prior session's) even once the derived
  # wifi.conf is gone, which lit the WiFi icon behind a toggle that read "off" (Dan, on-device
  # 2026-09-08, after a first fix that only cleared the derived file). Take the radio DOWN and stop;
  # stay-awake (above) still holds, and SSH is simply not reachable over WiFi, which is what off means.
  if [ -f "$SD/wifi.txt.off" ] && [ ! -f "$SD/wifi.txt" ]; then
    echo "wifi: toggled OFF (wifi.txt.off) -- leaving the radio DOWN, skipping SSH-over-wifi"
    killall -9 wpa_supplicant 2>/dev/null
    killall udhcpc 2>/dev/null
    ifconfig wlan0 down 2>/dev/null
    command -v rfkill >/dev/null 2>&1 && rfkill block wifi 2>/dev/null
    exit 0
  fi

  # 1) radios on
  rfkill unblock all 2>/dev/null || true
  ifconfig wlan0 up 2>/dev/null || true

  # 2) wifi config: build /etc/wifi/wpa_supplicant.conf from wifi.conf if provided,
  #    else use whatever the device already has (e.g. configured via stock firmware).
  if [ -f "$SHARED/wifi.conf" ]; then
    . "$SHARED/wifi.conf"
    if [ -n "$SSID" ]; then
      mkdir -p /etc/wifi/sockets
      if command -v wpa_passphrase >/dev/null 2>&1; then
        wpa_passphrase "$SSID" "$PSK" > /etc/wifi/wpa_supplicant.conf 2>/dev/null
      else
        printf 'ctrl_interface=/etc/wifi/sockets\nupdate_config=1\nnetwork={\n\tssid="%s"\n\tpsk="%s"\n}\n' "$SSID" "$PSK" > /etc/wifi/wpa_supplicant.conf
      fi
    fi
  fi

  # 3) (re)start wifi — same invocation the device's own suspend/resume uses
  killall -9 wpa_supplicant 2>/dev/null
  wpa_supplicant -B -D nl80211 -iwlan0 -c /etc/wifi/wpa_supplicant.conf -O /etc/wifi/sockets 2>/dev/null || true
  ( udhcpc -i wlan0 & ) 2>/dev/null || true

  # 4) install the dev SSH public key for non-interactive (key) auth as root
  if [ -f "$SHARED/authorized_keys" ]; then
    mkdir -p /root/.ssh
    cp "$SHARED/authorized_keys" /root/.ssh/authorized_keys
    chmod 700 /root/.ssh 2>/dev/null; chmod 600 /root/.ssh/authorized_keys 2>/dev/null
    # SAY whether it landed. /root is not writable on every firmware, and a silent failure here
    # looks exactly like a wrong key from the other end.
    if [ -s /root/.ssh/authorized_keys ]; then
      echo "authorized_keys: installed ($(wc -c < /root/.ssh/authorized_keys 2>/dev/null) bytes)"
    else
      echo "authorized_keys: FAILED to install into /root/.ssh (read-only or full?)"
    fi
  else
    echo "authorized_keys: none provided in $SHARED"
  fi

  # 5) start the SSH daemon. Try the device's own dropbear first (the Brick's firmware has
  #    one; the Smart Pro's does NOT — its dev-net log read "dropbear: NOT-running"), then
  #    fall back to the static dropbearmulti we ship in .system. Host key lives on the CARD
  #    so the fingerprint stays stable across boots and devices.
  /etc/init.d/dropbear start 2>/dev/null \
    || dropbear -p 2022 2>/dev/null \
    || /usr/sbin/dropbear -p 2022 2>/dev/null \
    || true
  # Start OUR OWN daemon on 2022 whenever the binary exists, regardless of what holds :22.
  # The old guard skipped it if ANYTHING was listening on :22, which assumed a foreign daemon
  # would accept the key installed above. The Brick Pro disproves that: its firmware ships
  # OpenSSH on :22, that daemon refused our key, and the guard then declined to start the one
  # daemon we actually control, leaving no way in at all (read off the card 2026-08-30).
  # A second listener is free in dev mode and is the difference between debuggable and not.
  if ! pgrep -f "dropbear.*2022" >/dev/null 2>&1; then
    DBM="$SD/.system/tg5040/bin/dropbearmulti"
    KEY="$SHARED/dropbear_ed25519_host_key"
    if [ -x "$DBM" ]; then
      [ -f "$KEY" ] || "$DBM" dropbearkey -t ed25519 -f "$KEY" 2>/dev/null
      "$DBM" dropbear -r "$KEY" -p 2022 2>/dev/null || true
    else
      echo "dropbearmulti: MISSING at $DBM"
    fi
  fi

  # 6) wait for an IP, then log it + the exact ssh command
  ip=""
  i=0
  while [ "$i" -lt 20 ]; do
    ip=$(ifconfig wlan0 2>/dev/null | sed -n 's/.*inet addr:\([0-9.]*\).*/\1/p')
    [ -z "$ip" ] && ip=$(ip -4 addr show wlan0 2>/dev/null | sed -n 's#.*inet \([0-9.]*\)/.*#\1#p' | head -1)
    [ -n "$ip" ] && break
    sleep 1; i=$((i + 1))
  done
  echo "wlan0 IP: ${ip:-<none — check wifi.conf / signal>}"
  echo "dropbear: $(pgrep dropbear >/dev/null 2>&1 && echo running || echo NOT-running)"
  echo "listening: $(netstat -tln 2>/dev/null | grep -E ':(22|2022) ' | tr -s ' ' | cut -d' ' -f4 | tr '\n' ' ')"
  echo "connect:  ssh -i ~/.ssh/tg5040_dev -p 2022 root@${ip:-<ip>}"
  echo "or (stock daemon on 22): ssh -i ~/.ssh/tg5040_dev root@${ip:-<ip>}"

  # ntpd is HOTPLUG-spawned: MinUI.pak/launch.sh kills it at boot, but that runs BEFORE wifi is
  # up, and ntpd-hotplug starts a fresh one when wlan0 gets an address, so in dev mode it always
  # came back (observed after a clean reboot, 2026-08-30). Killing it here catches the common case.
  # It is NOT airtight and is not claimed to be: waiting for an IP does not prove the hotplug
  # action has finished, and a late DHCP renew can start another one (noted in review 2026-08-30).
  # Accepted because this path is DEV MODE ONLY. A release card has no wifi.txt, so no hotplug ntp
  # event ever fires and the single boot-time kill in launch.sh is sufficient there.
  killall ntpd 2>/dev/null
  echo "ntpd: $(pgrep ntpd >/dev/null 2>&1 && echo STILL-RUNNING || echo stopped)"
} >> "$LOG" 2>&1
