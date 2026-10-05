#!/bin/sh
# File Transfer: move files on and off the card without taking it out (Dan, 2026-10-05, after a Reddit
# ask for FTP and USB). Each way runs ONLY while its screen is open: nothing in the background, nothing
# at boot, so it costs nothing the rest of the time.
#  - USB Drive: the card shows up on a computer as a drive. TrimUI's own recipe (the stock usb_storage
#    app; CrossMix's usb_storage/launch.sh): stop everything using the card, unmount it,
#    `setusbconfig mass_storage`, then check the card and restart. usb-drive.sh does that from RAM.
#  - FTP: an FTP server over WiFi (fclairamb/ftpserver, the one josegonzalez/minui-ftpserver-pak wraps)
#    with a new password every time, shown on screen. It stops when the screen closes.

cd "$(dirname "$0")" || exit 1
PAK="$(pwd)"

wifi_ip() {
	ip=$(ifconfig wlan0 2>/dev/null | sed -n 's/.*inet addr:\([0-9.]*\).*/\1/p')
	[ -z "$ip" ] && ip=$(ip -4 addr show wlan0 2>/dev/null | sed -n 's#.*inet \([0-9.]*\)/.*#\1#p' | head -1)
	echo "$ip"
}

ftp_run() {
	IP=$(wifi_ip)
	if [ -z "$IP" ]; then
		if [ -f "$SDCARD_PATH/wifi.txt" ]; then
			say.elf "WiFi isn't connected yet.

Try again in a minute."
		else
			say.elf "WiFi is off.

Turn it on in Settings first."
		fi
		return
	fi
	PIN=$(tr -dc 0-9 < /dev/urandom 2>/dev/null | head -c 4)
	[ ${#PIN} -eq 4 ] || PIN=$(( $(date +%s) % 9000 + 1000 ))
	CONF=/tmp/file-transfer-ftp.json
	cat > "$CONF" <<EOF
{
	"version": 1,
	"accesses": [{ "user": "minui", "pass": "$PIN", "fs": "os", "params": { "basePath": "$SDCARD_PATH" } }],
	"listen_address": "0.0.0.0:21",
	"passive_transfer_port_range": { "start": 2122, "end": 2130 }
}
EOF
	./ftpserver -conf "$CONF" > "$LOGS_PATH/File Transfer.txt" 2>&1 &
	FTP=$!
	i=0; while [ $i -lt 10 ] && ! netstat -tln 2>/dev/null | grep -q ':21 '; do sleep 0.3; i=$((i+1)); done
	if ! kill -0 "$FTP" 2>/dev/null; then
		rm -f "$CONF"
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
	rm -f "$CONF"
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
	set -- usb "USB Drive" "" "" "Use the card as a drive on a computer.
The device restarts afterwards. Press A."
	# only once WiFi is set up (Dan): same test as the WiFi row in Settings, so set-up-but-off still shows
	if [ -f "$SDCARD_PATH/wifi.txt" ] || [ -f "$SDCARD_PATH/wifi.txt.off" ]; then
		set -- "$@" ftp "FTP" "" "" "Copy files over WiFi with an FTP app.
Press A."
	fi
	# --wide: an action list, drawn like Device Sync's (no values, so the narrow layout read as broken)
	OUT=$(settings.elf --wide --title "File Transfer" "$@")
	case "$OUT" in
		*OPEN=usb*) usb_run ;;
		*OPEN=ftp*) ftp_run ;;
		*) break ;;
	esac
done
