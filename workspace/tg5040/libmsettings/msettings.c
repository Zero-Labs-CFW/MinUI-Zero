// tg5040
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <linux/fb.h>
#include <sys/ioctl.h>
#include <errno.h>
#include <sys/stat.h>
#include <dlfcn.h>
#include <string.h>
// #include <tinyalsa/mixer.h>

#include "msettings.h"

///////////////////////////////////////

#define SETTINGS_VERSION 3
typedef struct Settings {
	int version; // future proofing
	int brightness;
	int headphones;
	int speaker;
	int mute;
	int night; // 0, or night step 1..3 with brightness held at 0 (see SetBrightness); was unused[0]
	int unused[1]; // for future use
	// NOTE: doesn't really need to be persisted but still needs to be shared
	int jack; 
} Settings;
static Settings DefaultSettings = {
	.version = SETTINGS_VERSION,
	.brightness = 2,
	.headphones = 4,
	.speaker = 8,
	.mute = 0,
	.jack = 0,
};
static Settings* settings;

#define SHM_KEY "/SharedSettings"
static char SettingsPath[256];
static int shm_fd = -1;
static int is_host = 0;
static int shm_size = sizeof(Settings);

// #define BACKLIGHT_PATH "/sys/class/backlight/backlight/bl_power"
// #define BRIGHTNESS_PATH "/sys/class/backlight/backlight/brightness"
// #define JACK_STATE_PATH "/sys/bus/platform/devices/singleadc-joypad/hp"
// #define HDMI_STATE_PATH "/sys/class/extcon/hdmi/cable.0/state"

int getInt(char* path) {
	int i = 0;
	FILE *file = fopen(path, "r");
	if (file!=NULL) {
		fscanf(file, "%i", &i);
		fclose(file);
	}
	return i;
}
int exactMatch(char* str1, char* str2) {
	if (!str1 || !str2) return 0; // NULL isn't safe here
	int len1 = strlen(str1);
	if (len1!=strlen(str2)) return 0;
	return (strncmp(str1,str2,len1)==0);
}

static int is_brick = 0;
// The Brick Pro shares the Brick's backlight curve, NOT the Smart Pro's. NextUI's scaleBrightness
// carries a brickpro branch whose table is byte-identical to its brick branch and different from
// smartpro (checked 2026-08-30). Without this a Brick Pro fell to the else branch and its lowest
// step was raw 4 instead of raw 1, so "minimum brightness" was visibly brighter than it should be.
static int is_brickpro = 0;

void InitSettings(void) {	
	char* device = getenv("DEVICE");
	is_brick = exactMatch("brick", device);
	is_brickpro = exactMatch("brickpro", device);
	
	sprintf(SettingsPath, "%s/msettings.bin", getenv("USERDATA_PATH"));
	
	shm_fd = shm_open(SHM_KEY, O_RDWR | O_CREAT | O_EXCL, 0644); // see if it exists
	if (shm_fd==-1 && errno==EEXIST) { // already exists
		// puts("Settings client");
		shm_fd = shm_open(SHM_KEY, O_RDWR, 0644);
		settings = mmap(NULL, shm_size, PROT_READ | PROT_WRITE, MAP_SHARED, shm_fd, 0);
	}
	else { // host
		// puts("Settings host"); // keymon
		is_host = 1;
		// we created it so set initial size and populate
		ftruncate(shm_fd, shm_size);
		settings = mmap(NULL, shm_size, PROT_READ | PROT_WRITE, MAP_SHARED, shm_fd, 0);
		
		int fd = open(SettingsPath, O_RDONLY);
		if (fd>=0) {
			read(fd, settings, shm_size);
			// TODO: use settings->version for future proofing?
			close(fd);
		}
		else {
			// load defaults
			memcpy(settings, &DefaultSettings, shm_size);
		}
		
		// these shouldn't be persisted
		// settings->jack = 0;
		// settings->hdmi = 0;
		settings->mute = 0;
	}
	// printf("brightness: %i\nspeaker: %i \n", settings->brightness, settings->speaker);
	 
	system("amixer sset 'Headphone' 0"); // 100%
	system("amixer sset 'digital volume' 0"); // 100%
	system("amixer sset 'DAC Swap' Off"); // Fix L/R channels
	// volume is set with 'digital volume'
	
	SetVolume(GetVolume());
	SetBrightness(GetBrightness());
}
void QuitSettings(void) {
	munmap(settings, shm_size);
	if (is_host) shm_unlink(SHM_KEY);
}
static inline void SaveSettings(void) {
	int fd = open(SettingsPath, O_CREAT|O_WRONLY, 0644);
	if (fd>=0) {
		write(fd, settings, shm_size);
		close(fd);
		sync();
	}
}

// NIGHT STEPS (Dan 2026-10-05, after a "Display too bright" report): levels -1..-7 hold the backlight at
// its floor (raw 1 Brick/Pro, 4 Smart Pro) and dim the PICTURE in the display engine: enhance_bright,
// 50 = neutral (the kernel default). Same node as NextUI's "Exposure" and spruce's brightness; 10 was the
// floor the stock OS and NextUI keep. -4..-6 go below it (Dan 2026-10-07: "still very bright at night"),
// never to 0, so the darkest step still shows a picture to step back up from. The node is only written when
// its value must change, so a device that never uses a night step never touches it.
#define ENHANCE_BRIGHT_PATH "/sys/class/disp/disp/attr/enhance_bright"
static void SetRawEnhanceBright(int val) {
	int cur = -1;
	FILE* f = fopen(ENHANCE_BRIGHT_PATH, "r");
	if (f) { if (fscanf(f, "%d", &cur) != 1) cur = -1; fclose(f); }
	if (cur == val) return;
	f = fopen(ENHANCE_BRIGHT_PATH, "w");
	if (f) { fprintf(f, "%d", val); fclose(f); }
}
// Below brightness 10 the engine's brightness barely moves the picture (Dan, 2026-10-07: 6, 3 and 1 "feel the
// same"), so the darkest night steps also lower contrast, which dims the whites. 50 = neutral; a node never
// written reads 0 (unset), which counts as neutral, so a device that never uses those steps never writes it.
#define ENHANCE_CONTRAST_PATH "/sys/class/disp/disp/attr/enhance_contrast"
static void SetRawEnhanceContrast(int val) {
	int cur = -1;
	FILE* f = fopen(ENHANCE_CONTRAST_PATH, "r");
	if (f) { if (fscanf(f, "%d", &cur) != 1) cur = -1; fclose(f); }
	if (cur == val || (cur == 0 && val == 50)) return;
	f = fopen(ENHANCE_CONTRAST_PATH, "w");
	if (f) { fprintf(f, "%d", val); fclose(f); }
}

int GetBrightness(void) { // -7..10 (below 0 = night steps)
	if (!settings) return 0; // callable before InitSettings (NextUI #273 class)
	if (settings->brightness < 0) return settings->brightness < -7 ? -7 : settings->brightness; // a pre-release save
	if (settings->brightness == 0 && settings->night > 0) return settings->night > 7 ? -7 : -settings->night;
	return settings->brightness;
}
void SetBrightness(int value) {
	if (!settings) return;
	if (value < -7) value = -7; // = BRIGHTNESS_MIN (platform.h); an out-of-range save left raw unset
	if (value > 10) value = 10;

	int raw;
	int enhance = 50; // neutral
	int contrast = 50; // neutral
	if (value < 0) {
		raw = (is_brick || is_brickpro) ? 1 : 4; // the level-0 backlight
		// -1..-7; the darkest (brightness 1, contrast 25) and dropping the old 10/50 step picked by eye on the Brick (Dan, 2026-10-07)
		static const int night_enhance[7]  = { 35, 20, 12,  6,  3,  2,  1 };
		static const int night_contrast[7] = { 50, 50, 46, 42, 33, 29, 25 };
		enhance = night_enhance[-value - 1];
		contrast = night_contrast[-value - 1];
	}
	else if (is_brick || is_brickpro) {
		switch (value) {
			case 0: raw=1; break; 		// 0
			case 1: raw=8; break; 		// 8
			case 2: raw=16; break; 		// 8
			case 3: raw=32; break; 		// 16
			case 4: raw=48; break;		// 16
			case 5: raw=72; break;		// 24
			case 6: raw=96; break;		// 24
			case 7: raw=128; break;		// 32
			case 8: raw=160; break;		// 32
			case 9: raw=192; break;		// 32
			case 10: raw=255; break;	// 64
		}
	}
	else {
		switch (value) {
			case 0: raw=4; break; 		//  0
			case 1: raw=6; break; 		//  2
			case 2: raw=10; break; 		//  4
			case 3: raw=16; break; 		//  6
			case 4: raw=32; break;		// 16
			case 5: raw=48; break;		// 16
			case 6: raw=64; break;		// 16
			case 7: raw=96; break;		// 32
			case 8: raw=128; break;		// 32
			case 9: raw=192; break;		// 64
			case 10: raw=255; break;	// 64
		}
	}
	SetRawBrightness(raw);
	SetRawEnhanceBright(enhance);
	SetRawEnhanceContrast(contrast);
	// A night step saves as brightness 0 + night N, never as a negative brightness: older builds read the
	// same file and know only 0..10. Their SetBrightness had no case for -3 (an unset raw value went to the
	// display) and their keymon could not step back up, so a downgrade could leave a black screen
	// (Codex review, 2026-10-05). To them a night step is simply 0, their darkest.
	settings->brightness = value < 0 ? 0 : value;
	settings->night = value < 0 ? -value : 0;
	SaveSettings();
}

int GetVolume(void) { // 0-20
	if (!settings) return 0;
	if (settings->mute) return 0;
	return settings->jack ? settings->headphones : settings->speaker;
}
void SetVolume(int value) { // 0-20
	if (!settings) return;
	if (settings->mute) return SetRawVolume(0);
	// if (settings->hdmi) return;
	
	if (settings->jack) settings->headphones = value;
	else settings->speaker = value;

	int raw = value * 5;
	SetRawVolume(raw);
	SaveSettings();
}

#define DISP_LCD_SET_BRIGHTNESS  0x102
void SetRawBrightness(int val) { // 0 - 255
	// if (settings->hdmi) return;
	
	printf("SetRawBrightness(%i)\n", val); fflush(stdout);

    int fd = open("/dev/disp", O_RDWR);
	if (fd) {
	    unsigned long param[4]={0,val,0,0};
		ioctl(fd, DISP_LCD_SET_BRIGHTNESS, &param);
		close(fd);
	}
}
void SetRawVolume(int val) { // 0-100
	printf("SetRawVolume(%i)\n", val); fflush(stdout);
	if (settings->mute) val = 0;
	
	// Note: 'digital volume' mapping is reversed (attenuation-coded) on BOTH devices —
	// verified by ear on the Smart Pro 2026-07-03 (a "normal direction" branch made
	// volume-up quieter). Do not "fix" this from the dB table; trust the ear test.
	char cmd[256];
	sprintf(cmd, "amixer sset 'digital volume' -M %i%% >/dev/null 2>&1", 100-val);
	system(cmd);

	// Setting just 'digital volume' to 0 still plays audio quietly. Also set DAC volume to 0.
	// The DAC restore must stay RAW 160: that is the 0dB reference on BOTH devices (the Smart
	// Pro's DAC range runs to 255 = +72dB of digital GAIN — restoring "100%" there blows the
	// audio out; verified by ear on-device 2026-07-03). Same values stock and NextUI use.
	if (val == 0) system("amixer sset 'DAC volume' 0 >/dev/null 2>&1");
	else system("amixer sset 'DAC volume' 160 >/dev/null 2>&1");

	// TODO: unfortunately doing it this way creating a linker nightmare
	// struct mixer *mixer = mixer_open(0);
	// struct mixer_ctl *ctl;
	//
	// // digital volume (one-time?)
	// ctl = mixer_get_ctl(mixer, 3);
	// mixer_ctl_set_value(ctl,0,0);
	//
	// // Soft Volume Master (one-time?)
	// ctl = mixer_get_ctl(mixer, 16);
	// mixer_ctl_set_value(ctl,0,255);
	// mixer_ctl_set_value(ctl,1,255);
	//
	// // DAC volume
	// ctl = mixer_get_ctl(mixer, 7);
	// mixer_ctl_set_value(ctl,0,val);
	// mixer_ctl_set_value(ctl,1,val);
	// mixer_close(mixer);
	
	// char cmd[256];
	// sprintf(cmd, "amixer sset 'digital volume' %i%% &> /dev/null", 100-val);
	// // puts(cmd); fflush(stdout);
	// system(cmd);
}

// monitored and set by thread in keymon
int GetJack(void) {
	if (!settings) return 0;
	return settings->jack;
}
void SetJack(int value) {
	if (!settings) return;
	printf("SetJack(%i)\n", value); fflush(stdout);

	settings->jack = value;
	SetVolume(GetVolume());
}

int GetHDMI(void) {	
	// printf("GetHDMI() %i\n", settings->hdmi); fflush(stdout);
	// return settings->hdmi;
	return 0;
}
void SetHDMI(int value) {
	// printf("SetHDMI(%i)\n", value); fflush(stdout);
	
	// if (settings->hdmi!=value) system("/usr/lib/autostart/common/055-hdmi-check");
	
	// settings->hdmi = value;
	// if (value) SetRawVolume(100); // max
	// else SetVolume(GetVolume()); // restore
}
int GetMute(void) {
	if (!settings) return 0; // latent null-deref pre-InitSettings (NextUI #273)
	return settings->mute;
}
void SetMute(int value) {
	if (!settings) return;
	settings->mute = value;
	if (settings->mute) SetRawVolume(0);
	else SetVolume(GetVolume());
}