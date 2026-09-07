#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <unistd.h>
#include <string.h>
#include <fcntl.h>
#include <dirent.h>
#include <linux/input.h>
#include <sys/ioctl.h>
#include <pthread.h>
#include <signal.h>
#include <poll.h>

#include <msettings.h>

#include <sys/types.h>
#include <sys/stat.h>
#include <sys/ioctl.h>

// #include "defines.h"

#define VOLUME_MIN 		0
#define VOLUME_MAX 		20
#define BRIGHTNESS_MIN 	0
#define BRIGHTNESS_MAX 	10

#define CODE_MENU0		314
#define CODE_MENU1		315
#define CODE_MENU2		316
#define CODE_PLUS		115
#define CODE_MINUS		114
#define CODE_MUTE		1
#define CODE_JACK		2

// keymon and api might need different codes

//	for ev.value
#define RELEASED	0
#define PRESSED		1
#define REPEAT		2

#define MUTE_STATE_PATH "/sys/class/gpio/gpio243/value"

#define INPUT_COUNT 4
static int inputs[INPUT_COUNT] = {};
static struct input_event ev;

static volatile int quit = 0;
static void on_term(int sig) { quit = 1; }

static int getInt(char* path) {
	int i = 0;
	FILE *file = fopen(path, "r");
	if (file!=NULL) {
		fscanf(file, "%i", &i);
		fclose(file);
	}
	return i;
}

static pthread_t mute_pt;
static int mute_pt_running = 0;
static void* watchMute(void *arg) {
	int is_muted,was_muted;
	
	is_muted = was_muted = getInt(MUTE_STATE_PATH);
	SetMute(is_muted);
	
	while(!quit) {
		usleep(200000); // 5 times per second
		
		is_muted = getInt(MUTE_STATE_PATH);
		if (was_muted!=is_muted) {
			was_muted = is_muted;
			SetMute(is_muted);
		}
	}
	
	return NULL;
}

int main (int argc, char *argv[]) {
	struct sigaction sa = {0};
	sa.sa_handler = on_term;
	sigaction(SIGTERM, &sa, NULL);
	
	InitSettings();
	// The Brick's mute slider is a HARDWARE mute (verified on-device 2026-07-01: flipping it mutes
	// with no evdev event and no claimed-GPIO change; PH19/gpio243 never toggles). The 5Hz poll
	// thread only serves devices where PH19 is a live software-mute line — skip it on the Brick
	// (launcher exports DEVICE=brick) so idle keymon schedules zero wakeups.
	//
	// The Brick Pro skips it too (2026-08-30). Both readings of that hardware lead to the same
	// answer, which is why this is safe without a mute-flip receipt:
	//   * it advertises an evdev mute switch (/proc/bus/input/devices "TRIMUI Player1" B: SW=2,
	//     i.e. bit 1 = CODE_MUTE), and the poll() loop below already handles EV_SW/CODE_MUTE at
	//     zero extra wakeup cost, so a live switch is delivered without polling; or
	//   * it is a hardware mute like the Brick, in which case there is nothing to poll: gpio243
	//     read a stable 0 across repeated samples on the device.
	// Either way the 5Hz thread observes nothing and costs a permanent +5 wakeups/sec, the exact
	// class the D21/D22 sweep drove to zero. If mute ever stops responding on a Brick Pro, this
	// gate is the first thing to revert.
	char* device = getenv("DEVICE");
	int is_brickpro = device && strcmp(device, "brickpro")==0;
	if (device && (strcmp(device, "brick")==0 || is_brickpro)) {
		// The BRICK reads its boot state from the GPIO, which is the truth there (hardware mute).
		// The BRICK PRO must NOT: gpio243 reads a permanent 0 on it, so trusting it would boot
		// muted-as-unmuted whenever the switch is already engaged at power-on. Input events are
		// edge-delivered, so the poll() loop below only ever sees LATER changes; the current state
		// has to be queried once with EVIOCGSW. Deferred until after the devices are open, just
		// below. (Caught in review 2026-08-30.)
		if (!is_brickpro) SetMute(getInt(MUTE_STATE_PATH));
	}
	else {
		pthread_create(&mute_pt, NULL, &watchMute, NULL);
		mute_pt_running = 1;
	}
	
	char path[32];
	for (int i=0; i<INPUT_COUNT; i++) {
		sprintf(path, "/dev/input/event%i", i);
		inputs[i] = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
	}

	// Brick Pro: seed mute from the CURRENT evdev switch state, once, at zero ongoing cost.
	// Input events are edge-delivered, so a switch already engaged before we opened the device is
	// never announced; EVIOCGSW is the only way to learn it.
	//
	// CAPABILITY FIRST, then state. EVIOCGSW SUCCEEDS on a device that supports no switches at
	// all: the kernel just hands back that device's all-zero current-state bitmap. So testing the
	// state ioctl's return value identifies "first node we could open", NOT "the node that owns
	// the mute switch", and on this hardware event0 is a plain keyboard that would answer first,
	// seed mute=0 and stop the scan. EVIOCGBIT(EV_SW, ...) is the ownership question.
	// (Both this file's author and an independent review walked into the same trap, 2026-08-30.)
	if (is_brickpro) {
		#define SW_LONGS ((SW_CNT + (8 * sizeof(long)) - 1) / (8 * sizeof(long)))
		#define SW_HAS(bits, code) \
			((bits[(code) / (8 * sizeof(long))] >> ((code) % (8 * sizeof(long)))) & 1)
		unsigned long swcaps[SW_LONGS], swbits[SW_LONGS];
		for (int i=0; i<INPUT_COUNT; i++) {
			if (inputs[i] < 0) continue;
			memset(swcaps, 0, sizeof(swcaps));
			if (ioctl(inputs[i], EVIOCGBIT(EV_SW, sizeof(swcaps)), swcaps) < 0) continue;
			if (!SW_HAS(swcaps, CODE_MUTE)) continue; // this node does not own the mute switch
			memset(swbits, 0, sizeof(swbits));
			if (ioctl(inputs[i], EVIOCGSW(sizeof(swbits)), swbits) < 0) continue;
			int muted = SW_HAS(swbits, CODE_MUTE);
			printf("mute: initial evdev state %i (event%i)\n", muted, i); fflush(stdout);
			SetMute(muted);
			break;
		}
	}
	
	uint32_t input;
	uint32_t val;
	uint32_t menu_pressed = 0;
	
	uint32_t up_pressed = 0;
	uint32_t up_just_pressed = 0;
	uint32_t up_repeat_at = 0;
	
	uint32_t down_pressed = 0;
	uint32_t down_just_pressed = 0;
	uint32_t down_repeat_at = 0;
	
	uint32_t now;   // `then` is gone: nothing reads a loop-cadence timestamp any more (see the note below)
	uint32_t ev_ms;
	struct timeval tod;

	struct pollfd fds[INPUT_COUNT];
	for (int i=0; i<INPUT_COUNT; i++) {
		fds[i].fd = inputs[i];
		fds[i].events = POLLIN;
	}

	while (!quit) {
		// block until input arrives; wake early only to drive key-repeat
		// (was a 60hz usleep busy-wait — ~60 wakeups/sec forever, kept a core out of deep idle)
		int timeout = -1;
		if (up_pressed || down_pressed) {
			gettimeofday(&tod, NULL);
			now = tod.tv_sec * 1000 + tod.tv_usec / 1000;
			uint32_t at = up_pressed ? up_repeat_at : down_repeat_at;
			if (down_pressed && (!up_pressed || down_repeat_at<at)) at = down_repeat_at;
			timeout = (at>now) ? (int)(at-now) : 0;
			if (timeout>100) timeout = 100;
		}
		poll(fds, INPUT_COUNT, timeout);

		gettimeofday(&tod, NULL);
		now = tod.tv_sec * 1000 + tod.tv_usec / 1000;
		// NO idle-based "we must have slept" reset here. It used to clear the held keys whenever
		// now-then>1000, which was safe only while this loop spun at 60fps (upstream/NextUI still do).
		// Since b8f15298 made poll() BLOCK, sitting idle for minutes is normal and says nothing about
		// sleeping -- so merely HOLDING the MENU/logo button for over a second cleared menu_pressed,
		// and the volume press that followed adjusted volume instead of brightness. That is the
		// "brightness bar shows but the volume keys do nothing" report (r/trimui, Brick Pro, v1.7.4;
		// reproduced on device 2026-09-07: hold logo >1s then press volume = no brightness change,
		// press immediately = works). A real sleep is detected below by STALE EVENTS instead, which
		// is the actual signal the reset always wanted.

		for (int i=0; i<INPUT_COUNT; i++) {
			input = inputs[i];
			while(read(input, &ev, sizeof(ev))==sizeof(ev)) {
				ev_ms = ev.time.tv_sec * 1000 + ev.time.tv_usec / 1000;
				if (now-ev_ms>1000) { // arrived before/during a sleep
					// Its matching release may never come, so forget held keys HERE -- where we have
					// evidence of the gap -- then drop the stale event. Fresh events later in this
					// same batch still register normally against the cleared state.
					menu_pressed = 0;
					up_pressed = up_just_pressed = 0;
					down_pressed = down_just_pressed = 0;
					up_repeat_at = 0;
					down_repeat_at = 0;
					continue;
				}
				val = ev.value;
				if (ev.type==EV_SW) {
					printf("switch: %i\n", ev.code);
					if (ev.code==CODE_JACK) {
					printf("jack: %i\n", val);
					SetJack(val);
				}
					else if (ev.code==CODE_MUTE) {
						printf("mute: %i\n", val);
						SetMute(val);
					}
				}
				if (( ev.type != EV_KEY ) || ( val > REPEAT )) continue;
				printf("code: %i (%i)\n", ev.code, val); fflush(stdout);
				switch (ev.code) {
					case CODE_MENU0:
					case CODE_MENU1:
					case CODE_MENU2:
						menu_pressed = val;
					break;
					break;
					case CODE_PLUS:
						up_pressed = up_just_pressed = val;
						if (val) up_repeat_at = now + 300;
					break;
					case CODE_MINUS:
						down_pressed = down_just_pressed = val;
						if (val) down_repeat_at = now + 300;
					break;
					default:
					break;
				}
			}
		}
		
		if (up_just_pressed || (up_pressed && now>=up_repeat_at)) {
			if (menu_pressed) {
				printf("brightness up\n"); fflush(stdout);
				val = GetBrightness();
				if (val<BRIGHTNESS_MAX) SetBrightness(++val);
			}
			else {
				printf("volume up\n"); fflush(stdout);
				val = GetVolume();
				if (val<VOLUME_MAX) SetVolume(++val);
			}
			
			if (up_just_pressed) up_just_pressed = 0;
			else up_repeat_at += 100;
		}
		
		if (down_just_pressed || (down_pressed && now>=down_repeat_at)) {
			if (menu_pressed) {
				printf("brightness down\n"); fflush(stdout);
				val = GetBrightness();
				if (val>BRIGHTNESS_MIN) SetBrightness(--val);
			}
			else {
				printf("volume down\n"); fflush(stdout);
				val = GetVolume();
				if (val>VOLUME_MIN) SetVolume(--val);
			}
			
			if (down_just_pressed) down_just_pressed = 0;
			else down_repeat_at += 100;
		}
	}
	
	for (int i=0; i<INPUT_COUNT; i++) {
		close(inputs[i]);
	}
	
	if (mute_pt_running) {
		pthread_cancel(mute_pt);
		pthread_join(mute_pt, NULL);
	}
}
