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
# the Miyoo keeps its supplicant off PATH (/customer/app); the others have it on PATH
WPA=$(command -v wpa_supplicant 2>/dev/null || echo /customer/app/wpa_supplicant)
# The Miyoo vendor wpa_supplicant links libnl-tiny.so from /customer/lib; guarantee that dir is on
# the loader path for every vendor-binary call (host, join, restore). Harmless where the dir is absent.
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}/customer/lib:/config/lib"
MANIFEST_NAME=_dsync_manifest
TAB=$(printf '\t')

# busybox sleep may not take a fraction; probe ONCE rather than retrying `sleep 0.1 || sleep 1` in a
# loop, which turns a 3 s wait into 30 s of black screen on a build without it.
if sleep 0.1 2>/dev/null; then NAPN=30; nap(){ sleep 0.1; }; else NAPN=3; nap(){ sleep 1; }; fi

# KILL BY PID, never `killall`, for anything that might be a busybox applet. busybox killall matches on
# the EXE basename and every applet's /proc/<pid>/exe points at /bin/busybox, so `killall udhcpd` matches
# NOTHING while `killall busybox` would match everything. Verified on the Brick 2026-09-18: killall
# udhcpd was a no-op against a live udhcpd that `kill -9 <pid>` then removed instantly, so every run
# since this pak shipped has leaked its DHCP server onto the next one.
kill_named(){ for p in $(pidof "$1" 2>/dev/null); do kill "$p" 2>/dev/null; done
	i=0; while pidof "$1" >/dev/null 2>&1 && [ "$i" -lt "$NAPN" ]; do nap; i=$((i+1)); done
	for p in $(pidof "$1" 2>/dev/null); do kill -9 "$p" 2>/dev/null; done
	return 0; }

# URL-encode a relpath for wget: keep unreserved chars and '/', percent-encode everything else
# (spaces, parens, UTF-8 bytes -- byte-wise, so multibyte names encode correctly). Uses awk because
# busybox on the device has no `od`. awk is present (/usr/bin/awk).
urlenc() {
	printf '%s' "$1" | LC_ALL=C awk 'BEGIN{for(i=0;i<256;i++)o[sprintf("%c",i)]=i}
		{n=length($0);for(i=1;i<=n;i++){c=substr($0,i,1);
			if(c ~ /[a-zA-Z0-9._~\/-]/) printf "%s",c; else printf "%%%02X",o[c]}}'
}

######################################## SENDER ########################################

# Build a serve dir that exposes ONLY the chosen scope (symlinks, no data copy) + a manifest.
# Each scope entry is a relpath -- a top-level dir (Saves, Roms) OR a nested dir/file
# (.userdata/shared/GB-gambatte, .userdata/shared/.minui/recent.txt). Only the named paths are
# symlinked in, so the card root, wifi.txt, our own devicesync backups, and logs are never reachable.
build_export() { # <cardroot> <servedir> <scope-relpath>...  |  <cardroot> <servedir> --list FILE (one rel per line)
	card="$1"; sv="$2"; shift 2
	rm -rf "$sv"; mkdir -p "$sv"
	# List files (Favorites, Collections) are MERGED on both sides, so the first device to apply rewrites
	# its own copy while the other is still pulling it: served through a live symlink, the peer got a
	# file that no longer matched the plan and "Connection lost" (Brick<>MMP, 2026-09-21). They are
	# tiny, so serve a SNAPSHOT copy (-p keeps the mtime the manifest and the merge rely on).
	# Roms is served BY TAG: Roms/<TAG> -> the real console folder, so every device sees the same path for
	# the same system whatever it named the folder ("6) PlayStation (PS)" vs "Sony PlayStation (PS)" made
	# duplicates, Dan 2026-09-22). _dsync_systems tells the peer our folder name per tag, for tags it lacks.
	_link_roms() { mkdir -p "$sv/Roms"; : > "$sv/_dsync_systems"
		for d in "$card"/Roms/*/; do [ -d "$d" ] || continue; d=${d%/}; n=${d##*/}
			case "$n" in .*) continue ;; *"("*")") t=${n##*(}; t=${t%)} ;; *) t=$n ;; esac
			[ -e "$sv/Roms/$t" ] && continue   # two folders with one tag: the first wins
			ln -s "$d" "$sv/Roms/$t"; printf '%s\t%s\n' "$t" "$n" >> "$sv/_dsync_systems"
		done; }
	_link() { [ -e "$card/$1" ] || return 0; mkdir -p "$sv/$(dirname "$1")"
		case "$1" in Roms) _link_roms ;;
		*/favorites.txt|Collections|Collections/*) cp -pR "$card/$1" "$sv/$1" 2>/dev/null || { rm -rf "$sv/$1"; ln -s "$card/$1" "$sv/$1"; } ;;
		*) ln -s "$card/$1" "$sv/$1" ;; esac; }  # nested rels need their parent first
	if [ "$1" = "--list" ]; then
		# per-game scopes carry spaces and parens in every path, so they arrive as a file, never as words
		while IFS= read -r d; do [ -n "$d" ] && _link "$d"; done < "$2"
	else
		for d in "$@"; do _link "$d"; done
	fi
	# generate the manifest to a temp then move it in, so the manifest never lists itself
	tmp=$(mktemp "${TMPDIR:-/tmp}/dsync.XXXXXX")
	eng manifest "$sv" > "$tmp"
	mv "$tmp" "$sv/$MANIFEST_NAME"
}

serve() { # <servedir> <port> : HTTP server, backgrounded, pid tracked so we never killall a system httpd
	# Two servers because not every firmware has one: TrimUI and Miyoo ship busybox with the httpd
	# applet, the Anbernic's busybox does not have it compiled in at all (checked against the muOS
	# rootfs we build h700 from), so we ship muOS's own darkhttpd in .system/h700/bin -- the same
	# borrow-from-the-vendor move as the TrimUI hostapd sitting next to it. True sync is bidirectional,
	# so BOTH devices must be able to serve; a device that cannot is receive-only.
	# Started in the FOREGROUND with & either way, so $! is the server itself and stop_serve can kill
	# it (darkhttpd --daemon would fork and orphan the pid). Both log one line per request to the same
	# file. Verified aarch64/glibc 2026-09-18: darkhttpd serves through the export symlinks and
	# percent-decodes the spaces/parens in game names exactly like busybox httpd.
	# darkhttpd FIRST where we ship it: busybox httpd on the Brick (1.27.2) has no Range support, so a stopped
	# or cut 1 GB game restarted from zero whenever a TrimUI was the sender. Our own static darkhttpd 1.16
	# (workspace/tg5040/other/darkhttpd, built in the tg5040 toolchain because the muOS binary wants glibc
	# 2.38 and the Brick has 2.33) answers 206; verified on the Brick 2026-09-22 with symlinked export paths
	# and percent-encoded names, and its log carries the URL the host greps for. The Miyoo keeps busybox
	# httpd, which does honour Range there (1.20.2, verified).
	DH=""; [ -x "${SYSTEM_PATH:-}/bin/darkhttpd" ] && DH="$SYSTEM_PATH/bin/darkhttpd"
	[ -z "$DH" ] && command -v darkhttpd >/dev/null 2>&1 && DH=darkhttpd
	if [ -n "$DH" ]; then
		"$DH" "$1" --port "$2" ${3:+--addr "$3"} >/tmp/dsync-httpd.log 2>&1 &    # docroot is positional here, not -h
	elif command -v httpd >/dev/null 2>&1; then
		# -vv, NOT -v. Verified on the Brick (busybox 1.27.2, 2026-09-18): -v logs only
		# "[ip]: response:200" with NO url, so every handshake that greps this log for a marker URL
		# (the peer reports progress/completion by REQUESTING /_dsync_<marker>) could never match and
		# both devices waited forever. -vv logs "[ip]: url:/_dsync_applied_7". This same bug is why the
		# v1 sender never showed its Done summary. darkhttpd logs the URL by default, so it needs no flag.
		httpd -f -vv -p "${3:+$3:}$2" -h "$1" >/tmp/dsync-httpd.log 2>&1 &   # $3 = bind address (optional)
	else
		# never fail silently: without this the caller waits out a peer that will never answer
		msg="serve: no HTTP server on this device (busybox has no httpd applet and darkhttpd is missing)"
		printf '%s\n' "$msg" > /tmp/dsync-httpd.log
		printf '%s\n' "$msg" >&2
		return 1
	fi
	echo $! > /tmp/dsync-httpd.pid
	sleep 1
	kill -0 "$(cat /tmp/dsync-httpd.pid)" 2>/dev/null && return 0   # 0 = up
	# a bind address that the interface does not hold yet: serve on every interface rather than not at all
	if [ -n "${3:-}" ]; then serve "$1" "$2"; return; fi
	return 1
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
			# ls -ln field 5, NEVER wc -c: busybox wc READS the whole file to count it, which on a card of
			# PS1 disc images means reading gigabytes just to size them. The engine states this rule at
			# the top of sync-engine.sh; this call site was the one place still breaking it (sweep).
			[ "$(ls -lnL "$staging/$rel" 2>/dev/null | { read -r _p _l _u _g z _r; printf '%s' "${z:-0}"; })" = "$wsize" ] \
				|| { rm -f "$staging/$rel"; continue; }
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

_ap_dhcp() { # DHCP for joiners on the AP subnet (shared by both AP mechanisms)
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
}
_ap_wpa_start() { # host the AP via wpa_supplicant's own AP mode (mode=2): the no-hostapd path AND the
  # fallback when hostapd will not beacon on a single-radio Realtek part (8188fu).
  freq=$((2407 + ch * 5))
  printf 'ctrl_interface=/var/run/wpa_supplicant\nnetwork={\n\tssid="%s"\n\tmode=2\n\tfrequency=%s\n\tkey_mgmt=WPA-PSK\n\tproto=RSN\n\tpairwise=CCMP\n\tpsk="%s"\n}\n' "$ssid" "$freq" "$psk" > /tmp/dsync-ap.conf
  ifconfig "$AP_IF" up 2>/dev/null
  ifconfig "$AP_IF" "$AP_IP" netmask 255.255.255.0 2>/dev/null
  echo "== wpa_supplicant AP mode=2 on $AP_IF freq=$freq ==" >> /tmp/dsync-hostapd.log
  "$WPA" -B -Dnl80211 -i"$AP_IF" -c /tmp/dsync-ap.conf >> /tmp/dsync-hostapd.log 2>&1
  pidof wpa_supplicant >/dev/null 2>&1
}
_ap_ensure_vif() { # a single-radio Realtek driver may not expose the AP interface until it is created
  [ -e "/sys/class/net/$AP_IF" ] && return 0
  command -v iw >/dev/null 2>&1 || { echo "$AP_IF missing, no iw to create it" >> /tmp/dsync-hostapd.log; return 1; }
  iw dev "$STA_IF" interface add "$AP_IF" type __ap >> /tmp/dsync-hostapd.log 2>&1 \
    || iw phy phy0 interface add "$AP_IF" type __ap >> /tmp/dsync-hostapd.log 2>&1
  [ -e "/sys/class/net/$AP_IF" ]
}
_ap_diag() { # one-time evidence so a failed AP-up is diagnosable without stranding the device
  { echo "== dsync ap-up PLATFORM=${PLATFORM:-UNSET} concurrent=${DSYNC_CONCURRENT:-0} ch=$ch AP_IF=$AP_IF STA_IF=$STA_IF =="
    printf 'ifaces:'; for i in /sys/class/net/*; do printf ' %s' "${i##*/}"; done; echo
    [ -e "/sys/class/net/$AP_IF" ] && echo "$AP_IF: present" || echo "$AP_IF: MISSING"
    printf '%s driver: ' "$STA_IF"; readlink "/sys/class/net/$STA_IF/device/driver" 2>/dev/null | sed 's|.*/||'
    if command -v iw >/dev/null 2>&1; then echo "AP-mode lines in iw list: $(iw list 2>/dev/null | grep -c '\* AP')"; else echo "iw: absent"; fi
  } >> /tmp/dsync-hostapd.log 2>&1
}
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
  # no iw (Miyoo): the running supplicant knows the frequency
  if [ -z "$ch" ]; then
    fr=$(wpa_cli -i "$STA_IF" status 2>/dev/null | sed -n "s/^freq=//p" | head -1)
    [ -n "$fr" ] && [ "$fr" -lt 5000 ] && ch=$(( (fr - 2407) / 5 ))
  fi
  [ -z "$ch" ] && ch=6
  # hw_mode=g below is 2.4 GHz only: a dual-band station on channel 36+ (5 GHz home WiFi) would make
  # hostapd refuse the channel and the wpa fallback ask for a 2.5 GHz frequency. The Brick hosts on a
  # separate radio and the single-radio devices dropped the station before this, so 6 is always free.
  [ "$ch" -gt 14 ] 2>/dev/null && ch=6
  # A shared-radio device (Miyoo 8188fu, Anbernic RTL8821CS: DSYNC_CONCURRENT=0) cannot beacon on wlan1
  # while wlan0 is still associated -- that is the "Could not open the hotspot" on the MMP. Drop home
  # WiFi first, exactly as OnionOS does; teardown's restore_wifi brings it back. The Brick (=1) skips
  # this and keeps home WiFi, because it has a genuine second radio. Channel was read ABOVE, while the
  # station was still associated.
  if [ "${DSYNC_CONCURRENT:-0}" != 1 ]; then
    save_home_wifi; muos_pause
    # dhcpcd (muOS) restarts the station supplicant on any wlan0 change; stop it for the run.
    kill_named dhcpcd
    kill_named wpa_supplicant
    kill_named udhcpc
    ip addr flush dev "$STA_IF" 2>/dev/null
    ifconfig "$STA_IF" down 2>/dev/null
    [ -x /customer/app/axp_test ] && [ ! -e "/sys/class/net/${STA_IF:-wlan0}" ] && /customer/app/axp_test wifion >/dev/null 2>&1   # Miyoo: keep the radio rail powered
  fi
  : > /tmp/dsync-hostapd.log
  ip neigh flush dev "$AP_IF" 2>/dev/null   # forget last run's stations (see sta_count)
  _ap_diag
  _ap_ensure_vif
  # Run the BUNDLED hostapd by FULL PATH. It is NOT on PATH on the Miyoo, which is why ap-up used to
  # fall through to the flaky wpa_supplicant mode=2 path and fail. Our hostapd is byte-identical to
  # OnionOS's (mainline v2.10, nl80211) and OnionOS drives this exact 8188fu with it. VERIFIED on-device
  # 2026-09-19: AP-ENABLED on wlan1, home WiFi kept (concurrent), and a Brick discovers the SSID. The
  # config mirrors OnionOS (ctrl_interface + CCMP/TKIP); channel follows wlan0 so a concurrent AP does
  # not knock the station off.
  HOSTAPD=$(command -v hostapd 2>/dev/null || echo "${SYSTEM_PATH:-/mnt/SDCARD/.system/miyoomini}/bin/hostapd")
  if [ -x "$HOSTAPD" ]; then
    cat > /tmp/dsync-hostapd.conf <<EOC
ctrl_interface=/var/run/hostapd
interface=$AP_IF
ssid=$ssid
channel=$ch
hw_mode=g
ieee80211n=1
macaddr_acl=0
auth_algs=1
wpa=2
wpa_passphrase=$psk
wpa_key_mgmt=WPA-PSK
wpa_pairwise=CCMP TKIP
rsn_pairwise=CCMP
EOC
    ifconfig "$AP_IF" up 2>/dev/null
    ifconfig "$AP_IF" "$AP_IP" netmask 255.255.255.0 2>/dev/null
    echo "== hostapd on $AP_IF ch=$ch ($HOSTAPD) ==" >> /tmp/dsync-hostapd.log
    "$HOSTAPD" -P /var/run/hostapd.pid -B -i "$AP_IF" /tmp/dsync-hostapd.conf >> /tmp/dsync-hostapd.log 2>&1
    # last-ditch only: if hostapd truly will not stay up, try wpa_supplicant AP mode
    if ! pidof hostapd >/dev/null 2>&1; then
      echo "== hostapd did not stay up -> wpa_supplicant AP fallback ==" >> /tmp/dsync-hostapd.log
      kill_named hostapd
      _ap_wpa_start
    fi
  else
    _ap_wpa_start
  fi
  _ap_dhcp
  { printf 'wlan0-after: '; ifconfig "$STA_IF" 2>/dev/null | grep -i "inet addr" || echo DROPPED; } >> /tmp/dsync-hostapd.log 2>&1
  [ -n "${LOGS_PATH:-}" ] && cp /tmp/dsync-hostapd.log "$LOGS_PATH/dsync-ap.log" 2>/dev/null
  pidof hostapd >/dev/null 2>&1 || pidof wpa_supplicant >/dev/null 2>&1
}

ap_down() {
	# kill_named WAITS for the process to actually go and then escalates. Returning while the old hostapd
	# still owns AP_IF made the next ap_up fail AND left `pidof hostapd` true, so the caller's ap_alive
	# guard saw the DYING process and believed its new hotspot was up (2026-09-18 re-review).
	kill_named hostapd
	kill_named udhcpd
	# the no-hostapd AP is a wpa_supplicant on AP_IF; restore_wifi relaunches the saved station one
	# stop an AP-mode wpa_supplicant (no-hostapd / Miyoo concurrent host) WITHOUT killing the station one
	for p in $(pidof wpa_supplicant 2>/dev/null); do
		case "$(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null)" in *"$AP_IF"*) kill "$p" 2>/dev/null ;; esac
	done
	ip addr flush dev "$AP_IF" 2>/dev/null; ifconfig "$AP_IF" down 2>/dev/null
}
# NEVER block in a scan. On the RTL8821CS (Anbernic Plus) `iw dev wlan0 scan` hangs for good while the
# station is associated (25 s timeout, no output, 2026-09-21): the tool sat in it, B could not break it,
# and the Plus never paired. The blocking scan is freshest where it works (Brick), so it gets an 8 s
# cap; if it hangs, the non-blocking trigger + cache dump is used instead (verified on the Plus: results
# in ~4 s), and a flag makes every later scan in this run skip straight to it. Only entries seen in the
# last 15 s count, so a hotspot from an earlier run that stopped beaconing is not chased.
SCAN_NB=/tmp/dsync-scan-nonblocking
scan() {
	t=$(mktemp "${TMPDIR:-/tmp}/dsync.XXXXXX")
	if [ ! -e "$SCAN_NB" ]; then
		iw dev "$STA_IF" scan > "$t" 2>/dev/null & sp=$!
		k=0; while kill -0 "$sp" 2>/dev/null && [ "$k" -lt 8 ]; do sleep 1; k=$((k+1)); done
		if kill -0 "$sp" 2>/dev/null; then kill -9 "$sp" 2>/dev/null; wait "$sp" 2>/dev/null; : > "$SCAN_NB"; fi
	fi
	if [ -e "$SCAN_NB" ]; then
		# right after a killed blocking scan the cache can still be empty at 4 s: one more dump at 7 s
		iw dev "$STA_IF" scan trigger >/dev/null 2>&1; sleep 4
		iw dev "$STA_IF" scan dump > "$t" 2>/dev/null
		grep -q 'SSID: MinUI-Sync-' "$t" || { sleep 3; iw dev "$STA_IF" scan dump > "$t" 2>/dev/null; }
	fi
	awk '/^BSS /{ls=-1} /last seen:/{ls=$3+0} /SSID: MinUI-Sync-/{ if (ls < 0 || ls < 15000) { sub(/.*SSID: /,""); print } }' "$t"
	rm -f "$t"
}

# ---- receiver: leave home wifi to join the sender AP, then restore. The launch.sh trap calls
# restore_wifi on EXIT so home wifi always comes back. HOME_CONF is captured before joining. ----
HOME_CONF_FLAG=/tmp/dsync-home-conf
# muOS (h700) runs two WiFi keepers that fight a sync: /opt/muos/script/web/keepalive.sh pings the home DNS
# every 60 s and on failure disconnects + reconnects home WiFi (killing our join supplicant: the Plus dropped
# the Brick Pro hotspot 30 s in, link test 2026-09-21), and our own frontend monitor re-runs the connect
# after 90 s without an IPv4 on wlan0 (which a Plus HOST has none). Pause both for the session: kill the
# keepalive (restarted at restore), freeze the monitor subshell (the parent of its `sleep 45`) with SIGSTOP
# and thaw it at restore. Nothing here runs on a device without muOS.
MUOS_MON=/tmp/dsync-muos-monitor
muos_pause() {
	[ -x /opt/muos/script/system/network.sh ] || return 0
	killall -9 keepalive.sh 2>/dev/null
	for p in $(pidof sleep 2>/dev/null); do
		case "$(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null)" in "sleep 45 "*|"sleep 45") 
			pp=$(awk '{print $4}' /proc/$p/stat 2>/dev/null)
			case "$(tr '\0' ' ' < /proc/$pp/cmdline 2>/dev/null)" in *minui-frontend.sh*) kill -STOP "$pp" 2>/dev/null && printf '%s\n' "$pp" >> "$MUOS_MON" ;; esac ;;
		esac
	done
}
muos_resume() {
	[ -x /opt/muos/script/system/network.sh ] || return 0
	for pp in $(cat "$MUOS_MON" 2>/dev/null); do kill -CONT "$pp" 2>/dev/null; done; rm -f "$MUOS_MON"
	pidof keepalive.sh >/dev/null 2>&1 || [ ! -x /opt/muos/script/web/keepalive.sh ] || (/opt/muos/script/web/keepalive.sh >/dev/null 2>&1 </dev/null &)
}
save_home_wifi() {
	# NEVER overwrite a good capture. On a retry our own join supplicant is the one running (or none is),
	# so a second call would fall through to the generic fallback below and lose the device-specific
	# arguments -- the -O socket dir, a non-default conf path -- that restore_wifi needs to put home WiFi
	# back exactly as the firmware had it (Codex, 2026-09-18).
	[ -s "$HOME_CONF_FLAG" ] && return 0
	# Read the running supplicant's -c path from /proc/<pid>/cmdline, NEVER from ps: busybox ps truncates
	# the line at the terminal width, so "-c /etc/wifi/wpa_supplicant.conf" was captured as "/etc/wifi/wp",
	# restore then launched the supplicant on a nonexistent file, it exited, and the device was left with
	# no wifi daemon at all. That was every strand on 2026-09-05. Handles "-c PATH" and "-cPATH".
	# Saved as the WHOLE command line (verified on the Brick: "wpa_supplicant -B -D nl80211 -iwlan0
	# -c /etc/wifi/wpa_supplicant.conf -O /etc/wifi/sockets") so restore relaunches it exactly, -O and all.
	line=""
	for p in $(pidof wpa_supplicant 2>/dev/null); do
		line=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)
		case "$line" in *"-i$STA_IF"*|*"-i $STA_IF"*) break ;; esac
		line=""
	done
	[ -z "$line" ] && line="$WPA -B -Dnl80211 -i$STA_IF -c /etc/wifi/wpa_supplicant.conf"
	printf '%s\n' "$line" > "$HOME_CONF_FLAG"
}
join() { # <ssid> <psk> : leave home wifi, join the receiver AP BY NAME (no manual scan -- wpa_supplicant
	# finds it), patiently (the receiver may open after we start). Prints the acquired 192.168.42.x IP.
	ssid="$1"; psk="$2"; save_home_wifi
	printf 'network={\n\tssid="%s"\n\tpsk="%s"\n}\n' "$ssid" "$psk" > /tmp/dsync-join.conf
	kill_named dhcpcd            # muOS: its wpa_supplicant hook would undo the join (see ap_up)
	kill_named wpa_supplicant
	[ -x /customer/app/axp_test ] && [ ! -e "/sys/class/net/${STA_IF:-wlan0}" ] && /customer/app/axp_test wifion >/dev/null 2>&1   # Miyoo: the radio rail may be off
	ifconfig "$STA_IF" up 2>/dev/null          # in case WiFi was off (interface down)
	# stdout too, NOT just stderr: wpa_supplicant prints "Successfully initialized wpa_supplicant"
	# on stdout, and the stdout of this function IS its return value (the IP). Redirecting only
	# stderr handed every caller a two-line answer (2026-09-18).
	muos_pause
	"$WPA" -B -Dnl80211 -i"$STA_IF" -c /tmp/dsync-join.conf >/dev/null 2>&1
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
	line=$(cat "$HOME_CONF_FLAG" 2>/dev/null); [ -n "$line" ] || return 0
	rm -f "$HOME_CONF_FLAG"
	kill_named wpa_supplicant
	# a single-radio host (Miyoo/Anbernic) took STA_IF DOWN to free the radio for wlan1; bring it back up
	# and re-power the rail before relaunching the supplicant, or it starts on a dead interface.
	[ -x /customer/app/axp_test ] && [ ! -e "/sys/class/net/${STA_IF:-wlan0}" ] && /customer/app/axp_test wifion >/dev/null 2>&1
	ifconfig "$STA_IF" up 2>/dev/null
	set -- $line; "$@" >/dev/null 2>&1   # relaunch the stock supplicant EXACTLY as it was running
	# wait for the association before asking for a lease: a fixed 4s then a single udhcpc -n was a
	# race (no lease = associated but addressless = unreachable). Poll up to ~20s, then retry the lease.
	i=0; while [ "$i" -lt 20 ]; do
		if command -v iw >/dev/null 2>&1; then iw dev "$STA_IF" link 2>/dev/null | grep -q '^Connected' && break
		else wpa_cli -i "$STA_IF" status 2>/dev/null | grep -q 'wpa_state=COMPLETED' && break; fi
		sleep 1; i=$((i+1))
	done
	udhcpc -i "$STA_IF" -n -q 2>/dev/null || { sleep 3; udhcpc -i "$STA_IF" -n -q 2>/dev/null; }
	# muOS (h700) manages the station through dhcpcd; we killed it to join, and without it the Plus
	# came back with no address management at all. Put it back exactly as the firmware runs it.
	if command -v dhcpcd >/dev/null 2>&1 && ! pidof dhcpcd >/dev/null 2>&1; then dhcpcd "$STA_IF" >/dev/null 2>&1; fi
	muos_resume
	# Last resort against the single-radio STRAND: if the saved relaunch did not put home WiFi back,
	# re-run the platform's OWN proven bring-up rather than a hand-rolled reconnect. Only the MMP ships
	# wifi-up.sh (the stock axp_test + /customer/app/wpa_supplicant + /appconfigs sequence), so the
	# file check keeps this a no-op on the Brick and h700, which reconnected above.
	ipx=$(ip -4 addr show "$STA_IF" 2>/dev/null | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -1)
	case "$ipx" in 192.168.42.*|"")
		[ -x /customer/app/axp_test ] && [ -n "${SYSTEM_PATH:-}" ] && [ -x "$SYSTEM_PATH/bin/wifi-up.sh" ] && sh "$SYSTEM_PATH/bin/wifi-up.sh" >/dev/null 2>&1 ;;
	esac
}
wifi_off() { # take the radio down and leave it off (as it was) -- do NOT reconnect to anything
	muos_resume
	kill_named wpa_supplicant
	ip addr flush dev "$STA_IF" 2>/dev/null
	ifconfig "$STA_IF" down 2>/dev/null
}
sta_count() { # receiver: number of joined devices; no iw (Miyoo) -> count hotspot-subnet ARP entries
	if command -v iw >/dev/null 2>&1; then iw dev "$AP_IF" station dump 2>/dev/null | grep -c '^Station'
	# only COMPLETE entries (flags 0x2) on the AP interface: a stale entry from an earlier run counted as a
	# station before anyone had joined, and the host resolved a peer that was not there
	else awk -v d="$AP_IF" '$1 ~ /^192\.168\.42\./ && $3=="0x2" && $6==d' /proc/net/arp 2>/dev/null | wc -l | tr -d ' '; fi
}

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
