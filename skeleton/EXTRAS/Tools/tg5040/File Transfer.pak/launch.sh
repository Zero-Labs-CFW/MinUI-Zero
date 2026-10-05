#!/bin/sh
# File Transfer: move files on and off the card without taking it out (Dan, 2026-10-05, after a Reddit
# ask for FTP and USB). Each way runs ONLY while its screen is open: nothing in the background, nothing
# at boot, so it costs nothing the rest of the time.
#  - USB Drive: the card shows up on a computer as a drive. TrimUI's own recipe (the stock usb_storage
#    app; CrossMix's usb_storage/launch.sh): stop everything using the card, unmount it,
#    `setusbconfig mass_storage`, then check the card and restart. usb-drive.sh does that from RAM.
#  - FTP: busybox ftpd behind tcpsvd (~44 KB; the community pak's Go server was 24.8 MB), with a new
#    6-character password every time, shown on screen. Our ftpd patch reads that one login from FTPD_USER/FTPD_PASS.
#  - USB (MTP): uMTP-Responder (umtprd), the open MTP server muOS runs, over FunctionFS the way muOS's
#    usb_gadget.sh and umtprd's own umtprd-ffs.sh set it up, sharing only the card. The card stays mounted, so
#    no restart. The firmware's MtpDaemon was tried first: it shares internal storage only and failed every
#    transfer from a Mac (libmtp and OpenMTP), so it is never used.
#  - Browser: dufs, a web file manager and WebDAV server (5 MB): drag files in any browser, or connect
#    Finder / Windows Explorer to the same address as a network drive. Same one-time password.

cd "$(dirname "$0")" || exit 1
PAK="$(pwd)"

wifi_ip() {
	ip=$(ifconfig wlan0 2>/dev/null | sed -n 's/.*inet addr:\([0-9.]*\).*/\1/p')
	[ -z "$ip" ] && ip=$(ip -4 addr show wlan0 2>/dev/null | sed -n 's#.*inet \([0-9.]*\)/.*#\1#p' | head -1)
	echo "$ip"
}
# "Set up" = connected right now by ANY route (a dev card on the firmware's saved network has no
# wifi.txt) or a wifi.txt / wifi.txt.off on the card
wifi_set_up() { [ -n "$(wifi_ip)" ] || [ -f "$SDCARD_PATH/wifi.txt" ] || [ -f "$SDCARD_PATH/wifi.txt.off" ]; }
# prints the IP, or explains what is missing and fails ($1 names the mode)
need_wifi() {
	IP=$(wifi_ip)
	[ -n "$IP" ] && return 0
	if [ -f "$SDCARD_PATH/wifi.txt.off" ] && [ ! -f "$SDCARD_PATH/wifi.txt" ]; then
		say.elf "WiFi is off.

Turn it on in Settings first."
	elif [ -f "$SDCARD_PATH/wifi.txt" ]; then
		say.elf "WiFi isn't connected yet.

Try again in a minute."
	else
		say.elf "$1 needs WiFi.

On a computer, add a file named wifi.txt
to the card with one line:
NetworkName:password
Then restart."
	fi
	return 1
}
# 6 characters from 32 easy-to-type ones (no 0/o, 1/l): ~10^9 codes. dufs has no failed-login delay, so a
# 4-digit code could be walked in minutes from the same WiFi (Codex review, 2026-10-05); FTP shares the style.
new_pin() {
	PIN=$(tr -dc 'abcdefghijkmnpqrstuvwxyz23456789' < /dev/urandom 2>/dev/null | head -c 6)
	[ ${#PIN} -eq 6 ] || PIN=$(printf '%06d' $(( $(date +%s) * 7919 % 1000000 )))
}
# up to ~3 s for pid $2 ITSELF to listen on port $1: a leftover server holding the port must not pass
# for the new one, which would show a password nothing accepts (Codex review)
listening() {
	i=0
	while [ $i -lt 10 ]; do
		netstat -tlnp 2>/dev/null | grep ":$1 " | grep -q "[[:space:]]$2/" && return 0
		kill -0 "$2" 2>/dev/null || return 1
		sleep 0.3; i=$((i+1))
	done
	return 1
}
# stop any server this tool started, including one a crashed or killed earlier run left behind
stop_ftp() {
	for p in $(pgrep -f "File Transfer.pak/busybox tcpsvd" 2>/dev/null) $(pgrep -f "File Transfer.pak/busybox ftpd" 2>/dev/null); do
		kill "$p" 2>/dev/null
	done
}
stop_web() { for p in $(pidof dufs 2>/dev/null); do kill "$p" 2>/dev/null; done; }
G=/sys/kernel/config/usb_gadget/g1
FFS=/dev/usb-ffs/mtp
# MTP off and USB back the way it was (MTP_PREV, recorded by mtp_run; dev cards run adb)
stop_mtp() {
	[ -n "$MTP_PREV" ] || return 0
	for p in $(pidof umtprd 2>/dev/null); do kill "$p" 2>/dev/null; done
	echo "" > "$G/UDC" 2>/dev/null
	rm -f "$G/configs/c.1/ffs.mtp"
	umount "$FFS" 2>/dev/null
	rmdir "$G/functions/ffs.mtp" 2>/dev/null
	rm -f "$G/os_desc/c.1"
	echo "${MTP_OSDESC:-0}" > "$G/os_desc/use" 2>/dev/null
	/bin/setusbconfig "$MTP_PREV" > /dev/null 2>&1
	MTP_PREV=
}
# The "is on" screens: say.elf in the background plus `wait`, because a trapped TERM/HUP interrupts `wait`
# at once, while a foreground say.elf held the trap (and the running server) until A was pressed
# (found testing the trap on-device, 2026-10-05). -9 for say.elf: SDL eats SIGTERM.
SAY=
say_wait() { say.elf "$@" & SAY=$!; wait "$SAY"; SAY=; }
cleanup() { [ -n "$SAY" ] && kill -9 "$SAY" 2>/dev/null; stop_ftp; stop_web; stop_mtp; }
# however this script ends (B, a crash, a kill), nothing it started keeps serving the card
trap cleanup EXIT
trap 'exit 1' INT TERM HUP

ftp_run() {
	need_wifi FTP || return
	new_pin
	stop_ftp
	# -c 4: a client opens a few connections at once; -t/-T: idle 10 min, no 1 h session cap for big copies
	FTPD_USER=minui FTPD_PASS="$PIN" ./busybox tcpsvd -E -c 4 0.0.0.0 21 \
		"$PAK/busybox" ftpd -w -t 600 -T 86400 "$SDCARD_PATH" > "$LOGS_PATH/File Transfer.txt" 2>&1 &
	FTP=$!
	if ! listening 21 "$FTP"; then
		stop_ftp
		say.elf "FTP couldn't start.

Details are in the File Transfer log."
		return
	fi
	say_wait "FTP is on

Connect an FTP app to
ftp://$IP
User: minui    Password: $PIN

Press A when you're done."
	stop_ftp # the listener and any open sessions
}

web_run() {
	need_wifi Browser || return
	new_pin
	stop_web
	# upload, delete (rename is a move), search and zip download, named one by one: -A would also enable
	# --allow-symlink, which relaxes dufs's stay-inside-the-root check (Codex review). One read-write login.
	./dufs "$SDCARD_PATH" -b 0.0.0.0 -p 80 --allow-upload --allow-delete --allow-search --allow-archive \
		-a "minui:$PIN@/:rw" > "$LOGS_PATH/File Transfer.txt" 2>&1 &
	WEB=$!
	if ! listening 80 "$WEB"; then
		stop_web
		say.elf "Browser couldn't start.

Details are in the File Transfer log."
		return
	fi
	say_wait "Browser is on

Open http://$IP
on a phone or computer.
User: minui    Password: $PIN
(Finder or Explorer: connect to the
same address as a network drive.)

Press A when you're done."
	stop_web
}

mtp_run() {
	C=$G/configs/c.1
	MTP_PREV=none
	[ -e "$C/ffs.adb" ] && MTP_PREV=adb
	[ -e "$C/mtp.gs0" ] && MTP_PREV=mtp
	[ -e "$C/ffs.adb" ] && [ -e "$C/mtp.gs0" ] && MTP_PREV=mtp,adb
	MTP_OSDESC=$(cat "$G/os_desc/use" 2>/dev/null)
	# muOS's umtprd.conf, sharing only the card; loop_on_disconnect keeps it serving across unplug/replug.
	# Interface class 0xff + "MTP", as Android announces MTP, not muOS's 0x06: macOS's camera agent
	# (ptpcamerad) claims any 0x06 still-image device, and every Mac MTP app then failed to open it
	# (libusb_claim_interface -3, on-device 2026-10-05). Windows finds MTP through the MS OS descriptor our
	# umtprd patch sends instead.
	CONF=/tmp/umtprd.conf
	cat > "$CONF" <<EOF
loop_on_disconnect 1
storage "$SDCARD_PATH" "SD Card" "rw"
manufacturer "MinUI Zero"
product "TrimUI"
serial "MinUIZero"
firmware_version "1"
interface "MTP"
usb_vendor_id 0x1D6B
usb_product_id 0x0100
usb_class 0xff
usb_subclass 0xff
usb_protocol 0x0
usb_dev_version 0x3008
usb_functionfs_mode 0x1
usb_dev_path "$FFS/ep0"
usb_epin_path "$FFS/ep1"
usb_epout_path "$FFS/ep2"
usb_epint_path "$FFS/ep3"
usb_max_packet_size 0x200
EOF
	# the firmware's gadget, emptied (setusbconfig none unlinks every function and leaves it unbound), then
	# FunctionFS MTP: function, mount, link, umtprd writes its descriptors, and only then bind the controller
	/bin/setusbconfig none > /dev/null 2>&1
	echo 0x1D6B > "$G/idVendor"; echo 0x0100 > "$G/idProduct"
	echo "MinUI Zero MTP" > "$G/strings/0x409/product"
	# MS OS descriptors on (Android: os_desc/use, b_vendor_code, qw_sign, the config linked in); put back in stop_mtp
	echo 1 > "$G/os_desc/use" 2>/dev/null
	echo 0x1 > "$G/os_desc/b_vendor_code" 2>/dev/null
	echo MSFT100 > "$G/os_desc/qw_sign" 2>/dev/null
	[ -e "$G/os_desc/c.1" ] || ln -s "$C" "$G/os_desc/c.1" 2>/dev/null
	mkdir -p "$G/functions/ffs.mtp" "$FFS"
	grep -q " $FFS " /proc/mounts || mount -t functionfs mtp "$FFS"
	ln -s "$G/functions/ffs.mtp" "$C/ffs.mtp" 2>/dev/null
	./umtprd -conf "$CONF" > "$LOGS_PATH/File Transfer.txt" 2>&1 &
	i=0; while [ $i -lt 10 ] && [ ! -e "$FFS/ep1" ]; do sleep 0.3; i=$((i+1)); done
	if [ ! -e "$FFS/ep1" ] || ! ls /sys/class/udc > "$G/UDC" 2>/dev/null; then
		stop_mtp
		say.elf "USB (MTP) couldn't start.

Details are in the File Transfer log."
		return
	fi
	say_wait "USB (MTP) is on

Connect a computer or phone with a USB
cable. Windows and Android open it
directly; a Mac needs an MTP app
such as OpenMTP.

Press A when you're done."
	stop_mtp
}

usb_run() {
	confirm.elf "Use the card as a USB drive?

Connect a computer with a USB cable.
When you're done, eject the drive
there, then unplug or press A here.
The device restarts afterwards." "START" "BACK" || return
	# Everything phase 2 needs comes off the card NOW: once it is shared, the card is gone.
	T=/tmp/usb-drive
	rm -rf "$T"; mkdir -p "$T/bin" "$T/lib" "$T/res"
	cp "$PAK/usb-drive.sh" "$T/" &&
	cp "$SYSTEM_PATH/bin/say.elf" "$SYSTEM_PATH/bin/setterm" "$T/bin/" &&
	cp "$SYSTEM_PATH/lib/libmsettings.so" "$T/lib/" &&
	cp -R "$SDCARD_PATH/.system/res/." "$T/res/" || { rm -rf "$T"; say.elf "Couldn't prepare USB Drive."; return; }
	sync
	# every fd off the card, or this process would hold the card it is about to unmount
	exec sh "$T/usb-drive.sh" < /dev/null > /tmp/usb-drive.log 2>&1
}

while :; do
	set -- usb "USB Drive" "" "" "The card shows up as a drive on any computer.
The device restarts afterwards. Press A."
	# FTP and Browser are always listed, so people learn they exist (Dan, 2026-10-05); without WiFi set
	# up, the description and the A screen say how
	if wifi_set_up; then
		FTP_DESC="Copy files over WiFi with an FTP app.
Press A."
		WEB_DESC="Drag files in a web browser over WiFi,
or use it as a network drive. Press A."
	else
		FTP_DESC="Copy files over WiFi with an FTP app.
Needs WiFi: add wifi.txt to the card."
		WEB_DESC="Drag files in a web browser over WiFi.
Needs WiFi: add wifi.txt to the card."
	fi
	set -- "$@" mtp "USB (MTP)" "" "" "No restart. Windows and Android open it;
a Mac needs an MTP app. Press A."
	set -- "$@" ftp "FTP" "" "" "$FTP_DESC"
	set -- "$@" web "Browser" "" "" "$WEB_DESC"
	# --wide: left-aligned like the Tools list; rows without a value draw only their label pill
	OUT=$(settings.elf --wide --title "File Transfer" "$@")
	case "$OUT" in
		*OPEN=usb*) usb_run ;;
		*OPEN=mtp*) mtp_run ;;
		*OPEN=ftp*) ftp_run ;;
		*OPEN=web*) web_run ;;
		*) break ;;
	esac
done
