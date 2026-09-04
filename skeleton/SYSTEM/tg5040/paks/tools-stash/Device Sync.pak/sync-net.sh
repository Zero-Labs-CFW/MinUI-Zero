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
# Never serves the card root, so wifi.txt / .userdata are never reachable.
build_export() { # <cardroot> <servedir> <scope-dir>...
	card="$1"; sv="$2"; shift 2
	rm -rf "$sv"; mkdir -p "$sv"
	for d in "$@"; do [ -e "$card/$d" ] && ln -s "$card/$d" "$sv/$d"; done
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

	fail=0; n=0; got=0
	while IFS= read -r rel; do
		[ -n "$rel" ] || continue
		n=$((n+1))
		mkdir -p "$staging/$(dirname "$rel")"
		if ! wget -q -O "$staging/$rel" "$base/$(urlenc "$rel")"; then
			echo "pull: download failed: $rel" >&2; rm -f "$staging/$rel"; fail=1; continue
		fi
		# verify size + hash against the manifest line
		want=$(awk -F"$TAB" -v r="$rel" '$1==r{print $2"|"$5}' "$mf")
		wsize=${want%|*}; whash=${want#*|}
		gotsize=$(wc -c < "$staging/$rel" | tr -d ' ')
		if [ "$gotsize" != "$wsize" ]; then
			echo "pull: size mismatch $rel ($gotsize/$wsize)" >&2; rm -f "$staging/$rel"; fail=1; continue
		fi
		if [ "$whash" != "-" ]; then
			goth=$(md5sum "$staging/$rel" 2>/dev/null | cut -d' ' -f1)
			if [ "$goth" != "$whash" ]; then
				echo "pull: hash mismatch $rel" >&2; rm -f "$staging/$rel"; fail=1; continue
			fi
		fi
		got=$((got+1))
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
	*) echo "usage: sync-net.sh {build-export|serve|stop-serve|pull|ap-up|ap-down|scan|urlenc} ..." >&2; exit 2 ;;
esac
