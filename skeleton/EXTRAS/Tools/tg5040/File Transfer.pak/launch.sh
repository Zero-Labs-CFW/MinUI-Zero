#!/bin/sh
# File Transfer: move files on and off the card without taking it out (Dan, 2026-10-05, after a Reddit
# ask for FTP and USB). Each way runs ONLY while its screen is open: nothing in the background, nothing
# at boot, so it costs nothing the rest of the time.
#  - USB Drive: the card shows up on a computer as a drive. TrimUI's own recipe (the stock usb_storage
#    app; CrossMix's usb_storage/launch.sh): stop everything using the card, unmount it,
#    `setusbconfig mass_storage`, then check the card and restart. usb-drive.sh does that from RAM.
#  - USB (MTP): the firmware's own MTP daemon, started exactly as stock starts it (MtpDaemon -D) and
#    stopped when the screen closes. The card stays mounted, so no restart. Windows/Android open it
#    natively; a Mac needs an MTP app. Started WITHOUT -D once, a Brick Pro rebooted (2026-10-05).
#  - FTP: busybox ftpd behind tcpsvd (~44 KB; the community pak's Go server was 24.8 MB), with a new
#    password every time, shown on screen. Our ftpd patch reads that one login from FTPD_USER/FTPD_PASS.
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
new_pin() {
	PIN=$(tr -dc 0-9 < /dev/urandom 2>/dev/null | head -c 4)
	[ ${#PIN} -eq 4 ] || PIN=$(( $(date +%s) % 9000 + 1000 ))
}
# wait up to ~3 s for a listener on port $1; fails if pid $2 died
listening() {
	i=0; while [ $i -lt 10 ] && ! netstat -tln 2>/dev/null | grep -q ":$1 "; do sleep 0.3; i=$((i+1)); done
	kill -0 "$2" 2>/dev/null
}

ftp_run() {
	need_wifi FTP || return
	new_pin
	# -c 4: a client opens a few connections at once; -t/-T: idle 10 min, no 1 h session cap for big copies
	FTPD_USER=minui FTPD_PASS="$PIN" ./busybox tcpsvd -E -c 4 0.0.0.0 21 \
		"$PAK/busybox" ftpd -w -t 600 -T 86400 "$SDCARD_PATH" > "$LOGS_PATH/File Transfer.txt" 2>&1 &
	FTP=$!
	if ! listening 21 "$FTP"; then
		say.elf "FTP couldn't start.

Details are in the File Transfer log."
		return
	fi
	say.elf "FTP is on

Connect an FTP app to
ftp://$IP
User: minui    Password: $PIN

Press A when you're done."
	kill "$FTP" 2>/dev/null
	for p in $(pgrep -f "$PAK/busybox ftpd" 2>/dev/null); do kill "$p" 2>/dev/null; done # open sessions too
}

web_run() {
	need_wifi Browser || return
	new_pin
	# -A: upload, delete, rename, search and zip download; one login with read-write on the whole card
	./dufs "$SDCARD_PATH" -b 0.0.0.0 -p 80 -A -a "minui:$PIN@/:rw" > "$LOGS_PATH/File Transfer.txt" 2>&1 &
	WEB=$!
	if ! listening 80 "$WEB"; then
		say.elf "Browser couldn't start.

Details are in the File Transfer log."
		return
	fi
	say.elf "Browser is on

Open http://$IP
on a phone or computer.
User: minui    Password: $PIN
(Finder or Explorer: connect to the
same address as a network drive.)

Press A when you're done."
	kill "$WEB" 2>/dev/null
}

mtp_run() {
	# put USB back the way it was afterwards (dev cards run adb; a stock card may differ)
	C=/sys/kernel/config/usb_gadget/g1/configs/c.1
	PREV=none
	[ -e "$C/ffs.adb" ] && PREV=adb
	[ -e "$C/mtp.gs0" ] && PREV=mtp
	[ -e "$C/ffs.adb" ] && [ -e "$C/mtp.gs0" ] && PREV=mtp,adb
	/bin/setusbconfig mtp > /dev/null 2>&1
	( trap "" HUP; exec /usr/sbin/MtpDaemon -D ) < /dev/null > /dev/null 2>&1 &
	say.elf "USB (MTP) is on

Connect a computer or phone with a
USB cable. Windows and Android open it
directly; a Mac needs an MTP app
such as OpenMTP.

Press A when you're done."
	for p in $(pidof MtpDaemon); do kill "$p" 2>/dev/null; done
	/bin/setusbconfig "$PREV" > /dev/null 2>&1
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
	set -- "$@" mtp "USB (MTP)" "" "" "No restart. Windows and Android open it;
a Mac needs an MTP app. Press A."
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
