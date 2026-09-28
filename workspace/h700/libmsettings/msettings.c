// h700 msettings — device settings (moved verbatim from platform.c when the makefile wiring
// landed; the shared minui/minarch makefiles link -lmsettings on every platform).
//
// On the MinUI Zero image we OWN the codec and panel: volume drives the ALSA 'digital volume'
// mixer directly (amixer, see SetRawVolume — pipewire is removed), brightness the Allwinner
// dispdbg debugfs. This library is standalone by design (no utils.c), so it carries its own
// tiny sysfs/mixer helpers.
#include <stdio.h>
#include <stdlib.h>
#include <alsa/asoundlib.h>

#include "msettings.h"

// Brightness: this device has NO /sys/class/backlight. muOS drives the panel through the
// Allwinner dispdbg debugfs (func.sh DISPLAY_WRITE): name=disp0, command=setbl/getbl,
// param=0-255 (max from /opt/muos/device/config/screen/bright), then start=1. getbl answers
// in /sys/kernel/debug/dispdbg/info, so brightness is READABLE (a file still keeps the user's level
// across boots, see BRIGHT_FILE: muOS rewrites the panel at every boot).
#define DISPDBG "/sys/kernel/debug/dispdbg/"
// UI 0-10 -> raw 0-255, a perceptual curve: the table upstream MinUI's rg35xxplus port shipped on this panel
// family (workspace/_unmaintained/rg35xxplus/libmsettings/msettings.c) and NextUI h700-rc11 uses too
// (msettings.c:604-621). Our muOS trees drive the backlight PWM exactly as the stock tree does (lcd_pwm_freq
// 50000, lcd_pwm_pol 1, lcd_pwm_max_limit 255, lcd_bright_curve_en 0). The old linear UI*255/10 spent the
// whole bottom of the range at raw 25/51/76, so the dim levels that save the most power were out of reach.
static const int bright_raw[11] = { 4, 6, 10, 16, 32, 48, 64, 96, 128, 192, 255 };
static int bright_nearest(int raw, int lo) { // the UI level (lo..10) whose raw value is closest to raw
	int best = lo;
	for (int i = lo; i <= 10; i++) {
		int d = bright_raw[i] - raw, bd = bright_raw[best] - raw;
		if ((d < 0 ? -d : d) < (bd < 0 ? -bd : bd)) best = i;
	}
	return best;
}

static void putStr(const char* path, const char* s) {
	FILE* file = fopen(path, "w");
	if (file != NULL) {
		fputs(s, file);
		fclose(file);
	}
}
static void dispdbg_cmd(const char* cmd, const char* param) {
	putStr(DISPDBG "name", "disp0");
	putStr(DISPDBG "command", cmd);
	if (param) putStr(DISPDBG "param", param);
	putStr(DISPDBG "start", "1");
}

// Volume drives the codec's 'digital volume' mixer via libasound in-process (snd_mixer), NOT a
// forked amixer. MinUI Zero removes pipewire — a headless rootfs can't autolaunch its D-Bus session
// bus so it never starts, and it is 9.5MB of idle weight against the thesis — so the old
// wpctl-on-the-sink path is gone. We OWN the codec now. An earlier version shelled out to `amixer &`
// per keypress; that forked ~9x/s on a held ramp with no ordering guarantee (Codex-confirmed race:
// a late-completing process could leave the level a step off). In-process is synchronous, ordered,
// and fork-free — no race and no audio-ring stall. This control's dB TLV is garbage (D33: reports
// tens of thousands of dB), so we map the RAW integer over the control's queried range, which is
// linear and higher=louder (MEASURED 2026-08-06 on this H700 codec: raw 0-63, 40 = 63% — NOT
// reversed like the A133P Brick).
#define VOL_CTL "digital volume"

static int cur_vol = -1; // 0-20 UI scale; -1 = not yet read
static snd_mixer_t*      vol_mixer = NULL;
static snd_mixer_elem_t* vol_elem  = NULL;
static long vol_min = 0, vol_max = 63; // 'digital volume' raw range, queried at open

// Open the codec mixer once and cache the 'digital volume' element for the process lifetime.
static void vol_open(void) {
	if (vol_mixer) return;
	if (snd_mixer_open(&vol_mixer, 0) < 0) { vol_mixer = NULL; return; }
	snd_mixer_selem_id_t* sid;
	snd_mixer_selem_id_alloca(&sid);
	snd_mixer_selem_id_set_index(sid, 0);
	snd_mixer_selem_id_set_name(sid, VOL_CTL);
	if (snd_mixer_attach(vol_mixer, "hw:0") < 0 ||
	    snd_mixer_selem_register(vol_mixer, NULL, NULL) < 0 ||
	    snd_mixer_load(vol_mixer) < 0 ||
	    !(vol_elem = snd_mixer_find_selem(vol_mixer, sid))) {
		snd_mixer_close(vol_mixer);
		vol_mixer = NULL; vol_elem = NULL;
		return;
	}
	if (snd_mixer_selem_get_playback_volume_range(vol_elem, &vol_min, &vol_max) < 0 || vol_max <= vol_min) {
		vol_min = 0; vol_max = 63;
	}
}

// Persisted UI volume. The codec register is NOT a reliable source of truth: opening a PCM powers
// the DAPM path up and ZEROES 'digital volume', so a process that only READS the register at start
// (what this did) adopts 0 and plays the whole game silent — the "no audio on first launch" bug
// (Dan, fixed 2026-08-10). tg5040 has the same read-then-WRITE contract via its own persistence
// (msettings.c: InitSettings ends with SetVolume(GetVolume())); this is that, file-backed.
#define VOL_FILE "/mnt/mmc/.userdata/h700/volume"
static void vol_persist(int ui) {
	FILE* f = fopen(VOL_FILE, "w");
	if (!f) return;
	fprintf(f, "%d\n", ui);
	fclose(f);
}
static int vol_restore(void) { // -1 = no saved value
	FILE* f = fopen(VOL_FILE, "r");
	if (!f) return -1;
	int ui = -1;
	if (fscanf(f, "%d", &ui) != 1) ui = -1;
	fclose(f);
	if (ui < 0 || ui > 20) return -1;
	return ui;
}

// Persisted UI brightness, same idea as the volume file. The panel IS readable (GetBrightness), but it is
// not the user's value after a boot: muOS device/start.sh runs bright.sh at every boot, which writes its
// OWN saved level (config settings/general/brightness, 88 raw in this image) to disp0, so whatever the
// user chose comes back as raw 88 (UI 7) after every reboot (read from the muOS scripts in the image,
// not yet seen on a device; cross-reference 2026-09-27). SetBrightness
// records the UI level here and InitSettings puts it back, so the user's value wins. No file (first boot,
// or a card from before this) = the panel is left exactly as muOS set it, as before.
// A NEW file for the curve: the old one ("brightness", linear UI*255/10, from b8971c06, in the 1049ef0e beta)
// is read once and mapped to the nearest curve level, so a card that has it does not jump from raw 76 (old
// UI 3) to raw 16 (new UI 3). The old file is left alone, for a downgrade.
#define BRIGHT_FILE    "/mnt/mmc/.userdata/h700/brightness2"
#define BRIGHT_FILE_V1 "/mnt/mmc/.userdata/h700/brightness"
static int cur_bright = -1; // 0-10 UI as last written by this process; -1 = not yet
static void bright_persist(int ui) {
	FILE* f = fopen(BRIGHT_FILE, "w");
	if (!f) return;
	fprintf(f, "%d\n", ui);
	fclose(f);
}
static int bright_read(const char* path) { // -1 = no saved value
	FILE* f = fopen(path, "r");
	if (!f) return -1;
	int ui = -1;
	if (fscanf(f, "%d", &ui) != 1) ui = -1;
	fclose(f);
	if (ui < 1 || ui > 10) return -1; // 0 is never saved (SetBrightness), so never restored either
	return ui;
}
static int bright_restore(void) { // -1 = no saved value
	int ui = bright_read(BRIGHT_FILE);
	if (ui >= 0) return ui;
	int old = bright_read(BRIGHT_FILE_V1);
	if (old < 0) return -1;
	ui = bright_nearest(old * 255 / 10, 1); // the old raw; never level 0, which is never restored
	bright_persist(ui);
	return ui;
}

void InitSettings(void) {
	// Saved brightness wins over the raw level muOS set at boot. cur_bright is primed first so this
	// re-apply is not itself counted as a change and rewritten to the card at every process start.
	int bright = bright_restore();
	if (bright >= 0) { cur_bright = bright; SetBrightness(bright); }
	vol_open();
	// Saved level wins. Only when there is none do we adopt the codec's current level (first boot
	// after a flash: the frontend's alsactl restore has set the baseline and nothing has opened a
	// PCM yet, so the register is still meaningful).
	int ui = vol_restore();
	if (ui < 0 && vol_elem) {
		long v = vol_min, range = vol_max - vol_min;
		if (range > 0 && snd_mixer_selem_get_playback_volume(vol_elem, SND_MIXER_SCHN_MONO, &v) >= 0)
			ui = (int)(((v - vol_min) * 20 + range / 2) / range);
	}
	if (ui < 0) ui = 10;
	if (ui > 20) ui = 20;
	// WRITE it back, always: minarch calls InitSettings AFTER SND_init (minarch.c "after we
	// initialize audio"), so this is what undoes the PCM-open zeroing for every game launch.
	SetVolume(ui);
}
void QuitSettings(void) {
	if (vol_mixer) { snd_mixer_close(vol_mixer); vol_mixer = NULL; vol_elem = NULL; }
}

int GetBrightness(void) { // 0-10 UI
	// This process's own level first, once it has one (the saved level from InitSettings, or the last
	// SetBrightness). muOS starts device/start.sh in the BACKGROUND (startup.sh:124), so its boot bright.sh
	// write can land after InitSettings; a live read would then adopt muOS's level, and the next sleep/wake
	// or MENU+volume step would save it over the user's. No level yet = read the panel itself, as before.
	if (cur_bright >= 0) return cur_bright;
	int raw = -1;
	dispdbg_cmd("getbl", NULL);
	FILE* f = fopen(DISPDBG "info", "r");
	if (f) {
		if (fscanf(f, "%d", &raw) != 1) raw = -1;
		fclose(f);
	}
	if (raw < 0) return 5;
	return bright_nearest(raw, 0);
}
int GetVolume(void) { return cur_vol; }

void SetRawBrightness(int value) { // 0-255
	char buf[16];
	snprintf(buf, sizeof(buf), "%d", value);
	dispdbg_cmd("setbl", buf);
}
void SetRawVolume(int value) { // 0-100 (SetVolume passes UI*5); MUTE_VOLUME_RAW (0) mutes
	// In-process snd_mixer write: a single mixer ioctl (microseconds), synchronous and ordered.
	// SetVolume runs on the emulation thread (the input hook) and this fires ~9x/s on a held ramp —
	// no fork means no ordering race and no fork+wait stall of the audio ring (the old `amixer &`
	// path had both). value 0 -> raw vol_min = mute; value 100 -> raw vol_max.
	if (value < 0) value = 0;
	if (value > 100) value = 100;
	if (!vol_elem) vol_open();
	if (!vol_elem) return;
	long raw = vol_min + ((long)value * (vol_max - vol_min) + 50) / 100;
	(void)snd_mixer_selem_set_playback_volume_all(vol_elem, raw);
}

void SetBrightness(int value) { // 0-10 UI
	if (value < 0) value = 0;
	if (value > 10) value = 10;
	SetRawBrightness(bright_raw[value]);
	// Persist only on a real change (a held MENU+volume ramp calls this repeatedly). Backlight-off paths
	// use SetRawBrightness and never reach here, so a sleep never saves a dark level. Level 0 is never
	// saved either: it is also the charging screen's dim (minui.c ChargingScreen), restored only on a clean
	// exit, so a hard power cut there would bring it back on every boot. A user who picks 0 keeps it until
	// the next boot, which restores their last level above 0.
	if (value != cur_bright) { cur_bright = value; if (value) bright_persist(value); }
}
void SetVolume(int value) { // 0-20 UI
	if (value < 0) value = 0;
	if (value > 20) value = 20;
	int changed = (value != cur_vol);
	cur_vol = value;
	SetRawVolume(value * 5);
	// Persist only on a real change: this runs ~9x/s on a held volume ramp, and the point is to
	// survive a process boundary, not to log every step.
	if (changed) vol_persist(value);
}

int GetJack(void) { return 0; }
void SetJack(int value) {}

int GetHDMI(void) { return 0; }
void SetHDMI(int value) {}

int GetMute(void) { return 0; }
