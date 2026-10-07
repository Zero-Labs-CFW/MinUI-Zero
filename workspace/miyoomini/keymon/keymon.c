// miyoomini/keymon.c

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <unistd.h>
#include <string.h>
#include <fcntl.h>
#include <dirent.h>
#include <time.h>

// The gap we care about is wall time the thread did NOT run, which includes any interval the whole
// system spent suspended — CLOCK_MONOTONIC excludes suspend, CLOCK_BOOTTIME does not. Fall back
// where the kernel headers predate it; on this SoC deep sleep is impossible anyway, so the
// difference only matters if that ever changes.
#ifdef CLOCK_BOOTTIME
#define ZERO_GAP_CLOCK CLOCK_BOOTTIME
#else
#define ZERO_GAP_CLOCK CLOCK_MONOTONIC
#endif
#include <linux/input.h>
#include <linux/i2c.h>
#include <linux/i2c-dev.h>

#include <msettings.h>

#include <sys/types.h>
#include <sys/stat.h>
#include <sys/ioctl.h>
#include <pthread.h>

//	Button Defines
#define	BUTTON_MENU		KEY_ESC
#define	BUTTON_POWER	KEY_POWER
#define	BUTTON_SELECT	KEY_RIGHTCTRL
#define	BUTTON_START	KEY_ENTER
#define	BUTTON_L1		KEY_E
#define	BUTTON_R1		KEY_T
#define	BUTTON_L2		KEY_TAB
#define	BUTTON_R2		KEY_BACKSPACE
#define BUTTON_PLUS		KEY_VOLUMEUP
#define BUTTON_MINUS	KEY_VOLUMEDOWN

//	for keyshm
#define VOLUME		0
#define BRIGHTNESS	1
#define VOLMAX		20
#define BRIMAX		10
#define BRIMIN		-4 // night steps, = platform.h BRIGHTNESS_MIN (msettings.c SetBrightness maps them)

//	for ev.value
#define RELEASED	0
#define PRESSED		1
#define REPEAT		2

//	for button_flag
#define SELECT_BIT	0
#define START_BIT	1
#define SELECT		(1<<SELECT_BIT)
#define START		(1<<START_BIT)

//	for DEBUG
//#define	DEBUG
#ifdef	DEBUG
#define ERROR(str)	fprintf(stderr,str"\n"); quit(EXIT_FAILURE)
#else
#define ERROR(str)	quit(EXIT_FAILURE)
#endif

//	mmplus axp223 (via eggs)
#define	AXPDEV	"/dev/i2c-1"
#define	AXPID	(0x34)

//
//	AXP223 write (plus)
//		32 .. bit7: Shutdown Control
//
int axp_write(unsigned char address, unsigned char val) {
	struct i2c_msg msg[1];
	struct i2c_rdwr_ioctl_data packets;
	unsigned char buf[2];
	int ret;
	int fd = open(AXPDEV, O_RDWR);
	ioctl(fd, I2C_TIMEOUT, 5);
	ioctl(fd, I2C_RETRIES, 1);

	buf[0] = address;
	buf[1] = val;
	msg[0].addr = AXPID;
	msg[0].flags = 0;
	msg[0].len = 2;
	msg[0].buf = buf;

	packets.nmsgs = 1;
	packets.msgs = &msg[0];
	ret = ioctl(fd, I2C_RDWR, &packets);

	close(fd);
	if (ret < 0) return -1;
	return 0;
}

//
//	AXP223 read (plus)
//		00 .. C4/C5(USBDC connected) 00(discharging)
//			bit7: ACIN presence indication 0:ACIN not exist, 1:ACIN exists
//			bit6: Indicating whether ACIN is usable (used by axp_test)
//			bit4: Indicating whether VBUS is usable (used by axp_test)
//			bit2: Indicating the Battery current direction 0: discharging, 1: charging
//			bit0: Indicating whether the boot source is ACIN or VBUS
//		01 .. 70(charging) 30(non-charging)
//			bit6: Charge indication 0:not charge or charge finished, 1: in charging
//		B9 .. (& 0x7F) battery percentage
//
int axp_read(unsigned char address) {
	struct i2c_msg msg[2];
	struct i2c_rdwr_ioctl_data packets;
	unsigned char val;
	int ret;
	int fd = open(AXPDEV, O_RDWR);
	ioctl(fd, I2C_TIMEOUT, 5);
	ioctl(fd, I2C_RETRIES, 1);

	msg[0].addr = AXPID;
	msg[0].flags = 0;
	msg[0].len = 1;
	msg[0].buf = &address;
	msg[1].addr = AXPID;
	msg[1].flags = I2C_M_RD;
	msg[1].len = 1;
	msg[1].buf = &val;

	packets.nmsgs = 2;
	packets.msgs = &msg[0];
	ret = ioctl(fd, I2C_RDWR, &packets);

	close(fd);
	if(ret < 0) return -1;
	return val;
}

//	Global Variables
typedef struct {
    int channel_value;
    int adc_value;
} SAR_ADC_CONFIG_READ;

#define SARADC_IOC_MAGIC                     'a'
#define IOCTL_SAR_INIT                       _IO(SARADC_IOC_MAGIC, 0)
#define IOCTL_SAR_SET_CHANNEL_READ_VALUE     _IO(SARADC_IOC_MAGIC, 1)

static SAR_ADC_CONFIG_READ  adc_config = {0,0};
static int is_charging = 0;
static int is_plus = 0;
// has_axp: this unit reads battery/charge from the AXP PMIC over i2c rather than the original
// Mini's SAR-ADC + gpio59. TRUE for the Plus and ALSO for the Flip.
//
// Why the Flip counts: Allium (goweiwen/Allium) ships all three models off one card and maps
// Flip -> the SAME battery implementation as the Mini Plus (Miyoo354Battery), only the original
// Mini gets its own (Miyoo283Battery). Keying battery off `is_plus` alone would hand a Flip the
// ORIGINAL MINI's hand-tuned voltage-divider constants below — silently wrong readings on
// hardware nobody here has tested. Detected via the hall sensor, which only the clamshell has.
static int has_axp = 0;
static int eased_charge = 0;
static int sar_fd = 0;
static struct input_event	ev;
static int	input_fd = 0;
static pthread_t check_pt;

void quit(int exitcode) {
	pthread_cancel(check_pt);
	pthread_join(check_pt, NULL);
	QuitSettings();
	
	if (input_fd > 0) close(input_fd);
	if (sar_fd > 0) close(sar_fd);
	exit(exitcode);
}

#define LID_PATH "/sys/devices/soc0/soc/soc:hall-mh248/hallvalue" // hall sensor: clamshell (Flip) only

// Last readings that were actually VALID. axp_read() returns -1 when the i2c transfer fails, and
// minui/minarch poll the same bus, so contention makes that happen transiently. Feeding -1 through
// the old masks was badly wrong in the UNSAFE direction:
//     getADCValue: -1 & 0x7F == 127  -> a failed read reported 127% charge
//     isCharging:  -1 & 0x04 == 4    -> a failed read reported "charging"
// so a device with a flaky bus never showed a low battery. Hold the last valid value instead.
static int last_valid_charge = -1;
static int last_valid_charging = -1;

// How many consecutive failed reads we will paper over before admitting we do not know. batmon uses
// the same budget for the same bus (batmon.c). Without a bound, a wedged i2c pins the reported
// charge for the whole session and the low-battery warning never fires — the device just dies flat.
#define ADC_MAX_MISS 5
static int adc_miss = 0;

static int getADCValue(void) {
	if (has_axp) {
		int v = axp_read(0xB9);
		if (v >= 0) { v &= 0x7F; if (v > 100) v = -1; }
		if (v < 0) {
			// Hold the last VALID reading through a transient, but only for a bounded number of
			// them, and NEVER invent one. Returning a made-up 50 here (as this did) reports a
			// near-empty battery as half full and suppresses every low-battery warning until the
			// first successful read — a fabricated device value in the unsafe direction, which is
			// exactly what the project rules forbid.
			if (last_valid_charge >= 0 && ++adc_miss <= ADC_MAX_MISS) return last_valid_charge;
			return -1;   // unknown: callers must not treat this as a level
		}
		adc_miss = 0;
		last_valid_charge = v;
		return v;
	}

	ioctl(sar_fd, IOCTL_SAR_SET_CHANNEL_READ_VALUE, &adc_config);
	
	int current_charge = 0;
	if (adc_config.adc_value>=528) {
		current_charge = adc_config.adc_value - 478;
	}
	else if (adc_config.adc_value>=512){
		current_charge = adc_config.adc_value * 2.125 - 1068;
	}
	else if (adc_config.adc_value>=480){
		current_charge = adc_config.adc_value * 0.51613 - 243.742;
	}
	
	if (current_charge<0) current_charge = 0;
	else if (current_charge>100) current_charge = 100;
	
	return current_charge;
}
static int getInt(const char* path) {
    int i = 0;
    FILE *file = fopen(path, "r");
    if (file!=NULL) {
        fscanf(file, "%i", &i);
        fclose(file);
    }
	return i;
}
// Publish via temp-file-plus-rename, and pass a mode.
//
// Two real defects here. O_CREAT with NO mode argument takes the permission bits from whatever
// happens to sit in the varargs slot — undefined, and this creates /tmp/battery on a tmpfs that is
// empty at every boot, so it is the common path rather than a corner. And O_TRUNC published a
// ZERO-LENGTH file for the duration of the write: a reader landing in that window parses nothing
// and keeps its zero, which downstream means exactly PWR_LOW_CHARGE. rename(2) is atomic, so a
// reader now sees either the whole previous value or the whole new one, never a half-written file.
static void putInt(const char* path, int i) {
	char tmp[128];
	if (snprintf(tmp, sizeof(tmp), "%s.tmp", path) >= (int)sizeof(tmp)) return;

	int fd = open(tmp, O_CREAT | O_WRONLY | O_TRUNC, 0644);
	if (fd<0) return;

	char buffer[16];
	int len = snprintf(buffer, sizeof(buffer), "%d", i);
	int ok = (len>0 && write(fd, buffer, len)==len);
	close(fd);

	if (ok) { if (rename(tmp, path)!=0) unlink(tmp); }
	else unlink(tmp);
}
static int isCharging(void) {
	if (has_axp) {
		int v = axp_read(0x00);
		// A failed read must not read as "charging" — see last_valid_charging above.
		if (v < 0) return last_valid_charging >= 0 ? last_valid_charging : 0;
		// EXTERNAL POWER PRESENCE (bit7 ACIN, bit4 VBUS), matching platform.c and batmon.
		// NOT bit2, which is battery current DIRECTION and clears once the cell is full — that
		// made a plugged-in device at 100% read as discharging, in three different places.
		last_valid_charging = ((v & 0x80) || (v & 0x10)) ? 1 : 0;
		return last_valid_charging;
	}
	return getInt("/sys/devices/gpiochip0/gpio/gpio59/value");
}
static void initADC(void) {
	is_plus = access("/customer/app/axp_test", F_OK)==0;
	has_axp = is_plus || access(LID_PATH, F_OK)==0; // Plus, or Flip (clamshell hall sensor)
	sar_fd = open("/dev/sar", O_WRONLY);
	ioctl(sar_fd, IOCTL_SAR_INIT, NULL);
}
// Missed ticks, not a big delta, are what justifies abandoning the ease. Three periods of the 5s
// cadence: long enough that ordinary scheduling jitter never trips it.
#define ADC_GAP_SECONDS 15

static void checkADC(void) {
	int current_charge = getADCValue();
	// Unknown (-1) is not a level. Leave /tmp/battery holding whatever was last known rather than
	// publishing a guess; the eased value is only ever moved by a real reading.
	//
	// This returns BEFORE is_charging is updated, deliberately. Updating it first meant a failed
	// read landing on the same tick as an unplug consumed the transition: is_charging went to 0,
	// we returned, and the next call compared 0 against 0 with the edge already gone.
	if (current_charge < 0) return;

	int was_charging = is_charging;
	is_charging = isCharging();

	// The ease filters READING noise — mostly for the base Mini, where getADCValue converts a raw
	// SAR voltage that sags under load; the Plus reads an AXP fuel gauge already filtered in
	// hardware. What it cannot do is close a real GAP: it moves +/-1 per call at a 5s cadence, so
	// 12 points a minute. That tracks genuine charge or discharge and is hopeless at anything more.
	//
	// So snap when this thread actually MISSED TICKS, which is the thing that opens a gap — not
	// when the delta merely looks large. An earlier version of this fix snapped on any jump of 5+
	// points, and that was wrong: the display quantises to 100/80/60/40/20/10, and a 5-point swing
	// straddles EVERY one of those boundaries (59/64 flips the icon between the 60 and 80 buckets).
	// Being under the bucket width buys nothing when the readings sit near a boundary, so on the
	// base Mini's noisy path that would have traded a slow indicator for a flickering one.
	// Detecting the discontinuity directly costs the same and cannot flicker: with ticks arriving
	// on time we never snap at all, and the noise filter is left exactly as it was.
	struct timespec ts;
	static time_t last_tick = 0;
	int missed_ticks = 0;
	if (clock_gettime(ZERO_GAP_CLOCK, &ts) == 0) {
		if (last_tick && ts.tv_sec - last_tick >= ADC_GAP_SECONDS) missed_ticks = 1;
		last_tick = ts.tv_sec;
	}

	static int first_run = 1;
	if (first_run || missed_ticks || (was_charging && !is_charging)) {
		first_run = 0;
		eased_charge = current_charge;
	}
	else if (eased_charge<current_charge) {
		eased_charge += 1;
		if (eased_charge>100) eased_charge = 100;
	}
	else if (eased_charge>current_charge) {
		eased_charge -= 1;
		if (eased_charge<0) eased_charge = 0;
	}
	
	putInt("/tmp/battery", eased_charge);
}
static void checkUSB(void) {
	static int init = 0;
	static int is_flip;
	if (!init) {
		is_flip = access(LID_PATH, F_OK)==0;
		int has_gpio = access("/sys/class/gpio/gpio45/value", F_OK)==0;
		if (!has_gpio) putInt("/sys/class/gpio/export", 45);
		init = 1;
	}
	if (!is_flip) return;
		
	static int last_state = -1;
	int current_state = getInt("/sys/class/gpio/gpio45/value");
	if (last_state==-1 || current_state!=last_state) {
		last_state = current_state;
		putInt("/sys/class/gpio/gpio44/value", current_state);
		SetJack(!current_state);
	}
}
static void* runChecks(void *arg) {
	static int ticks = 0;
	while (1) {
		usleep(500000);

		// every half second
		checkUSB();
		ticks += 1;
		
		// every 5 seconds
		if (ticks==10) {
			checkADC();
			ticks = 0;
		}
	}
	return 0;
}

int main (int argc, char *argv[]) {
	// Set Initial Volume / Brightness
	InitSettings();

	initADC();
	checkADC();
	checkUSB();
	pthread_create(&check_pt, NULL, &runChecks, NULL);
	
	input_fd = open("/dev/input/event0", O_RDONLY);

	// Main Loop
	register uint32_t val;
	register uint32_t code;
	register uint32_t button_flag = 0;
	register uint32_t menu_pressed = 0;
	register uint32_t power_pressed = 0;
	uint32_t repeat_LR = 0;
	while( read(input_fd, &ev, sizeof(ev)) == sizeof(ev) ) {
		val = ev.value;
		if (( ev.type != EV_KEY ) || ( val > REPEAT )) continue;
		code = ev.code;
		switch (code) {
		case BUTTON_MENU:
			if ( val != REPEAT ) menu_pressed = val;
			break;
		case BUTTON_POWER:
			if ( val != REPEAT ) power_pressed = val;
			break;
		case BUTTON_SELECT:
			if ( val != REPEAT ) button_flag = button_flag & (~SELECT) | (val<<SELECT_BIT);
			// if (val) {
			// 	static int tick = 0;
			// 	char cmd[256];
			//
			// 	sprintf(cmd, "ps ax -o pid,nice,comm,args &> /mnt/SDCARD/%04i-nice.txt", tick);
			// 	system(cmd);
			//
			// 	sprintf(cmd, "top -b -n 1 > /mnt/SDCARD/%04i-top.txt", tick++);
			// 	system(cmd);
			// }
			break;
		case BUTTON_START:
			if ( val != REPEAT ) button_flag = button_flag & (~START) | (val<<START_BIT);
			break;
		case BUTTON_L1:
		case BUTTON_L2:
		case BUTTON_MINUS:
			if (code==BUTTON_MINUS || !is_plus) {
				if ( val == REPEAT ) {
					// Adjust repeat speed to 1/2
					val = repeat_LR;
					repeat_LR ^= PRESSED;
				} else {
					repeat_LR = 0;
				}
			
				if ( val == PRESSED ) {
					if ((is_plus && !menu_pressed) || button_flag==SELECT) {
						// VOLUMEDOWN or SELECT + L : volume down
						val = GetVolume();
						if (val>0) SetVolume(--val);
					}
					else if ((is_plus && menu_pressed) || button_flag==START) {
						// VOLUMEDOWN or START + L : brightness down
						int b = GetBrightness(); // signed: night steps go below 0, and val is uint32_t
						if (b>BRIMIN) SetBrightness(b-1);
					}
				}
			}
			break;
		case BUTTON_R1:
		case BUTTON_R2:
		case BUTTON_PLUS:
			if (code==BUTTON_PLUS || !is_plus) {
				if ( val == REPEAT ) {
					// Adjust repeat speed to 1/2
					val = repeat_LR;
					repeat_LR ^= PRESSED;
				} else {
					repeat_LR = 0;
				}
			
				if ( val == PRESSED ) {
					if ((is_plus && !menu_pressed) || button_flag==SELECT) {
						// VOLUMEUP or SELECT + R : volume up
						val = GetVolume();
						if (val<VOLMAX) SetVolume(++val);
					}
					else if ((is_plus && menu_pressed) || button_flag==START) {
						// VOLUMEUP or START + R : brightness up
						int b = GetBrightness();
						if (b<BRIMAX) SetBrightness(b+1);
					}
				}
			}
			break;
		default:
			break;
		}
		
		if (menu_pressed && power_pressed) {
			menu_pressed = power_pressed = 0;
			system("shutdown");
			while (1) pause();
		}
	}
	ERROR("Failed to read input event");
}
