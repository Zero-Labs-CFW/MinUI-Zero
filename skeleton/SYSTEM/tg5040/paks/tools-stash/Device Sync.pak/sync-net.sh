#!/bin/sh
# Device Sync -- transport layer (SoftAP + busybox httpd/wget), on top of sync-engine.sh.
#
# Topology (confirmed on Brick Pro 2026-09-03): the SENDER hosts an AP on wlan1 while wlan0/home-wifi
# stays up (concurrent station+AP). It serves ONLY the in-scope files (a symlink export dir, so
# wifi.txt and the rest of the card are never exposed) plus a manifest, over httpd. The RECEIVER
# joins on wlan0, wgets the manifest, asks the engine for the delta, wgets ONLY the delta into a
# staging dir, verifies every file's size+hash against the manifest, then hands staging to the engine
# (atomic write + backup + undo). WiFi is up only during the transfer.
#
# HTTP-layer functions (build_export/serve/pull) are testable over 127.0.0.1 with no radios.
# WiFi functions (ap_up/ap_down/scan/join) need two devices and are exercised in Phase 2c.

HERE=$(cd "$(dirname "$0")" && pwd)
ENGINE="$HERE/sync-engine.sh"
eng() { sh "$ENGINE" "$@"; }

AP_IF=${AP_IF:-wlan1}
STA_IF=${STA_IF:-wlan0}
AP_IP=${AP_IP:-192.168.42.1}
AP_PORT=${AP_PORT:-8145}
MANIFEST_NAME=_dsync_manifest
TAB=$(printf '\t')

# URL-encode a relpath for wget: keep unreserved chars and '/', percent-encode everything else
# (spaces, parens, UTF-8 bytes -- byte-wise, so multibyte names encode correctly). Uses awk because
# busybox on the device has no `od`. awk is present (/usr/bin/awk).
urlenc() {
	printf '%s' "$1" | awk 'BEGIN{for(i=0;i<256;i++)o[sprintf("%c",i)]=i}
		{n=length($0);for(i=1;i<=n;i++){c=substr($0,i,1);
			if(c ~ /[a-zA-Z0-9._~\/-]/) printf "%s",c; else printf "%%%02X",o[c]}}'
}

######################################## SENDER ########################################

# Build a serve dir that exposes ONLY the chosen scope (symlinks, no data copy) + a manifest.
# Each scope entry is a relpath -- a top-level dir (Saves, Roms) OR a nested dir/file
# (.userdata/shared/GB-gambatte, .userdata/shared/.minui/recent.txt). Only the named paths are
# symlinked in, so the card root, wifi.txt, our own devicesync backups, and logs are never reachable.
build_export() { # <cardroot> <servedir> <scope-relpath>...
	card="$1"; sv="$2"; shift 2
	rm -rf "$sv"; mkdir -p "$sv"
	for d in "$@"; do
		[ -e "$card/$d" ] || continue
		mkdir -p "$sv/$(dirname "$d")"          # nested rels need their parent created first
		ln -s "$card/$d" "$sv/$d"
	done
	# generate the manifest to a temp then move it in, so the manifest never lists itself
	tmp=$(mktemp "${TMPDIR:-/tmp}/dsync.XXXXXX")
	eng manifest "$sv" > "$tmp"
	mv "$tmp" "$sv/$MANIFEST_NAME"
}

serve() { # <servedir> <port> : busybox httpd, backgrounded, pid tracked so we never killall a system httpd
	httpd -f -p "$2" -h "$1" >/tmp/dsync-httpd.log 2>&1 &
	echo $! > /tmp/dsync-httpd.pid
	sleep 1
	kill -0 "$(cat /tmp/dsync-httpd.pid)" 2>/dev/null   # 0 = up
}
stop_serve() {
	[ -f /tmp/dsync-httpd.pid ] && kill "$(cat /tmp/dsync-httpd.pid)" 2>/dev/null
	rm -f /tmp/dsync-httpd.pid
}

######################################## RECEIVER ######################################

# Pull the sender's scope into <dst>, backing up to <backup>. Verifies every file before the engine
# ever touches <dst>; a failed/partial download is skipped (never applied), so a bad transfer can
# corrupt nothing. Returns non-zero if any file failed (dst still consistent).
pull() { # <host> <port> <dst> <backup>
	host="$1"; port="$2"; dst="$3"; bdir="$4"
	base="http://$host:$port"
	work=$(mktemp -d "${TMPDIR:-/tmp}/dsync-pull.XXXXXX")
	mf="$work/manifest"; staging="$work/staging"; mkdir -p "$staging"

	if ! wget -q -O "$mf" "$base/$MANIFEST_NAME"; then
		echo "pull: manifest fetch failed" >&2; rm -rf "$work"; return 1
	fi
	eng delta "$mf" "$dst" > "$work/dl"
	total=$(grep -c . "$work/dl" 2>/dev/null)
	[ -n "$DS_PROGRESS" ] && echo "0/$total" > "$DS_PROGRESS"

	fail=0; n=0; got=0
	while IFS= read -r rel; do
		[ -n "$rel" ] || continue
		n=$((n+1))
		[ -n "$DS_PROGRESS" ] && echo "$n/$total" > "$DS_PROGRESS"
		mkdir -p "$staging/$(dirname "$rel")"
		want=$(awk -F"$TAB" -v r="$rel" '$1==r{print $2"|"$5}' "$mf")
		wsize=${want%|*}; whash=${want#*|}
		# retry each file up to 3 times (download + size + hash), so a WiFi blip does not fail the sync
		ok_file=0; try=0
		while [ "$try" -lt 3 ]; do
			try=$((try+1))
			wget -q -O "$staging/$rel" "$base/$(urlenc "$rel")" || { rm -f "$staging/$rel"; continue; }
			[ "$(wc -c < "$staging/$rel" | tr -d ' ')" = "$wsize" ] || { rm -f "$staging/$rel"; continue; }
			if [ "$whash" != "-" ] && [ "$(md5sum "$staging/$rel" 2>/dev/null | cut -d' ' -f1)" != "$whash" ]; then rm -f "$staging/$rel"; continue; fi
			ok_file=1; break
		done
		if [ "$ok_file" = 1 ]; then got=$((got+1)); else echo "pull: gave up on $rel after $try tries" >&2; fail=1; fi
	done < "$work/dl"

	# apply-net skips any file missing from staging, so only verified files are written
	eng apply-net "$mf" "$staging" "$dst" "$bdir"
	echo "pull: $got/$n verified and applied"
	rm -rf "$work"
	return $fail
}

######################################## WiFi (Phase 2c, device-pair) ##################

ap_up() { # <ssid> <psk> : raise AP on wlan1 at wlan0's channel; leaves wlan0 alone
	ssid="$1"; psk="$2"
	# match the AP to the station's current channel so the shared radio is never forced to switch
	# (that switch is what could drop the sender's home wifi). iw ... info often omits channel, so
	# fall back to deriving it from the associated frequency (iw ... link), then to 6.
	ch=$(iw dev "$STA_IF" info 2>/dev/null | sed -n 's/.*channel \([0-9]*\).*/\1/p' | head -1)
	if [ -z "$ch" ]; then
		fr=$(iw dev "$STA_IF" link 2>/dev/null | sed -n 's/.*freq:[[:space:]]*\([0-9]*\).*/\1/p' | head -1)
		if [ -n "$fr" ]; then
			if [ "$fr" -ge 5000 ]; then ch=$(( (fr - 5000) / 5 )); else ch=$(( (fr - 2407) / 5 )); fi
		fi
	fi
	[ -z "$ch" ] && ch=6
	cat > /tmp/dsync-hostapd.conf <<EOC
interface=$AP_IF
driver=nl80211
ssid=$ssid
hw_mode=g
channel=$ch
auth_algs=1
wpa=2
wpa_passphrase=$psk
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
ignore_broadcast_ssid=0
EOC
	ifconfig "$AP_IF" up 2>/dev/null
	ifconfig "$AP_IF" "$AP_IP" netmask 255.255.255.0 2>/dev/null
	hostapd -B /tmp/dsync-hostapd.conf >/tmp/dsync-hostapd.log 2>&1
	cat > /tmp/dsync-udhcpd.conf <<EOC
start 192.168.42.10
end 192.168.42.20
interface $AP_IF
option subnet 255.255.255.0
option router $AP_IP
max_leases 8
lease_file /tmp/dsync-udhcpd.leases
EOC
	: > /tmp/dsync-udhcpd.leases
	udhcpd /tmp/dsync-udhcpd.conf 2>/dev/null
	pidof hostapd >/dev/null 2>&1
}
ap_down() {
	killall hostapd 2>/dev/null; killall udhcpd 2>/dev/null
	ip addr flush dev "$AP_IF" 2>/dev/null; ifconfig "$AP_IF" down 2>/dev/null
}
scan() { iw dev "$STA_IF" scan 2>/dev/null | sed -n 's/.*SSID: \(MinUI-Sync-.*\)/\1/p'; }

# ---- receiver: leave home wifi to join the sender AP, then restore. The launch.sh trap calls
# restore_wifi on EXIT so home wifi always comes back. HOME_CONF is captured before joining. ----
HOME_CONF_FLAG=/tmp/dsync-home-conf
save_home_wifi() {
	c=$(ps 2>/dev/null | grep -v grep | grep wpa_supplicant | grep -- "-i$STA_IF" | sed -n 's/.*-c[ =]*\([^ ]*\).*/\1/p' | head -1)
	[ -z "$c" ] && c=/etc/wifi/wpa_supplicant.conf
	echo "$c" > "$HOME_CONF_FLAG"
}
join() { # <ssid> <psk> : leave home wifi, join the receiver AP BY NAME (no manual scan -- wpa_supplicant
	# finds it), patiently (the receiver may open after we start). Prints the acquired 192.168.42.x IP.
	ssid="$1"; psk="$2"; save_home_wifi
	printf 'network={\n\tssid="%s"\n\tpsk="%s"\n}\n' "$ssid" "$psk" > /tmp/dsync-join.conf
	killall wpa_supplicant 2>/dev/null; sleep 1
	ifconfig "$STA_IF" up 2>/dev/null          # in case WiFi was off (interface down)
	wpa_supplicant -B -Dnl80211 -i"$STA_IF" -c /tmp/dsync-join.conf 2>/dev/null
	i=0
	while [ "$i" -lt 90 ]; do
		udhcpc -i "$STA_IF" -n -q >/dev/null 2>&1
		ipx=$(ip -4 addr show "$STA_IF" 2>/dev/null | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -1)
		case "$ipx" in 192.168.42.*) echo "$ipx"; return 0 ;; esac
		sleep 3; i=$((i+3))
	done
	echo ""; return 1
}
restore_wifi() { # bring STA_IF back onto the saved home network
	# No saved config means we never changed the radio -- so do NOT restart wpa_supplicant with a
	# guessed conf. Doing exactly that (fallback /etc/wifi/wpa_supplicant.conf) knocked a Brick off its
	# home WiFi when a run was aborted before join (2026-09-05).
	c=$(cat "$HOME_CONF_FLAG" 2>/dev/null); [ -n "$c" ] || return 0
	rm -f "$HOME_CONF_FLAG"
	killall wpa_supplicant 2>/dev/null; sleep 1
	wpa_supplicant -B -Dnl80211 -i"$STA_IF" -c "$c" 2>/dev/null
	# wait for the association before asking for a lease: a fixed 4s then a single udhcpc -n was a
	# race (no lease = associated but addressless = unreachable). Poll up to ~20s, then retry the lease.
	i=0; while [ "$i" -lt 20 ]; do iw dev "$STA_IF" link 2>/dev/null | grep -q '^Connected' && break; sleep 1; i=$((i+1)); done
	udhcpc -i "$STA_IF" -n -q 2>/dev/null || { sleep 3; udhcpc -i "$STA_IF" -n -q 2>/dev/null; }
}
wifi_off() { # take the radio down and leave it off (as it was) -- do NOT reconnect to anything
	killall wpa_supplicant 2>/dev/null
	ip addr flush dev "$STA_IF" 2>/dev/null
	ifconfig "$STA_IF" down 2>/dev/null
}
sta_count() { iw dev "$AP_IF" station dump 2>/dev/null | grep -c '^Station'; }  # sender: # of joined devices

# CLI dispatch
cmd="$1"; [ $# -gt 0 ] && shift
case "$cmd" in
	urlenc)       urlenc "$@" ;;
	build-export) build_export "$@" ;;
	serve)        serve "$@" ;;
	stop-serve)   stop_serve "$@" ;;
	pull)         pull "$@" ;;
	ap-up)        ap_up "$@" ;;
	ap-down)      ap_down "$@" ;;
	scan)         scan "$@" ;;
	join)         join "$@" ;;
	save-home-wifi) save_home_wifi "$@" ;;
	restore-wifi) restore_wifi "$@" ;;
	wifi-off)     wifi_off "$@" ;;
	sta-count)    sta_count "$@" ;;
	*) echo "usage: sync-net.sh {build-export|serve|stop-serve|pull|ap-up|ap-down|scan|join|restore-wifi|sta-count|urlenc} ..." >&2; exit 2 ;;
esac
