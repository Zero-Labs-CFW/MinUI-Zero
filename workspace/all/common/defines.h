#ifndef __DEFINES_H__
#define __DEFINES_H__

#include "platform.h"

#define VOLUME_MIN 		0
#define VOLUME_MAX 		20
#define BRIGHTNESS_MIN 	0
#define BRIGHTNESS_MAX 	10

#define MAX_PATH 512

#define ROMS_PATH SDCARD_PATH "/Roms"
#define ROOT_SYSTEM_PATH SDCARD_PATH "/.system/"
#define SYSTEM_PATH SDCARD_PATH "/.system/" PLATFORM
#define RES_PATH SDCARD_PATH "/.system/res"
#define FONT_PATH RES_PATH "/BPreplayBold-unhinted.otf"
#define USERDATA_PATH SDCARD_PATH "/.userdata/" PLATFORM
#define SHARED_USERDATA_PATH SDCARD_PATH "/.userdata/shared"
#define PAKS_PATH SYSTEM_PATH "/paks"
#define BIN_PATH SYSTEM_PATH "/bin"
#define RECENT_PATH SHARED_USERDATA_PATH "/.minui/recent.txt"
#define SHOW_CLOCK_PATH SHARED_USERDATA_PATH "/show-clock" // menu clock opt-in (Clock tool)
#define SIMPLE_MODE_PATH SHARED_USERDATA_PATH "/enable-simple-mode"
#define DEEP_SLEEP_OFF_PATH SHARED_USERDATA_PATH "/disable-deep-sleep" // deep sleep is ON by default; this file opts out (Deep Sleep tool)
// Suspend-inhibit lock files (idea: NextUI #756). tmpfs, so they self-clear on reboot.
// Touch from scripts/harnesses that need the device to stay up (sweeps, benches, deploys).
#define STAY_AWAKE_PATH "/tmp/stay_awake" // blocks autosleep entirely (no screen-off, no sleep)
#define STAY_ALIVE_PATH "/tmp/stay_alive" // blocks the deep-sleep escalation only (light sleep still ok)
#define AUTO_RESUME_PATH SHARED_USERDATA_PATH "/.minui/auto_resume.txt"
#define AUTO_RESUME_SLOT 9

#define FAUX_RECENT_PATH SDCARD_PATH "/Recently Played"
// Card-root flags — bare base names (upstream convention). Read with flagExists(), which also
// accepts a "<name>.txt" form, so both "no-recents" and "no-recents.txt" work.
#define NO_RECENTS_PATH SDCARD_PATH "/no-recents" // opt-out: hides Recently Played AND stops recording plays (r/trimui request, 2026-09-02)
#define HIDE_TOOLS_PATH SDCARD_PATH "/hide-tools" // opt-out: hides Tools from the menu; unlike simple mode, a combo (L1+R1+SELECT at root) still opens it (2026-09-03)
#define DEVMODE_PATH SDCARD_PATH "/devmode" // dev opt-in: stay-awake + SSH (read with flagExists, so "devmode" and "devmode.txt" both work, like every other card-root flag)
#define COLLECTIONS_PATH SDCARD_PATH "/Collections"

#define LAST_PATH "/tmp/last.txt" // transient
#define CHANGE_DISC_PATH "/tmp/change_disc.txt"
#define RESUME_SLOT_PATH "/tmp/resume_slot.txt"
#define NOUI_PATH "/tmp/noui"

#define TRIAD_WHITE 		0xff,0xff,0xff
#define TRIAD_BLACK 		0x00,0x00,0x00
#define TRIAD_LIGHT_GRAY 	0x7f,0x7f,0x7f
#define TRIAD_GRAY 			0x99,0x99,0x99
#define TRIAD_DARK_GRAY 	0x26,0x26,0x26

#define TRIAD_LIGHT_TEXT 	0xcc,0xcc,0xcc
#define TRIAD_DARK_TEXT 	0x66,0x66,0x66

#define COLOR_WHITE			(SDL_Color){TRIAD_WHITE}
#define COLOR_GRAY			(SDL_Color){TRIAD_GRAY}
#define COLOR_BLACK			(SDL_Color){TRIAD_BLACK}
#define COLOR_LIGHT_TEXT	(SDL_Color){TRIAD_LIGHT_TEXT}
#define COLOR_DARK_TEXT		(SDL_Color){TRIAD_DARK_TEXT}
#define COLOR_BUTTON_TEXT	(SDL_Color){TRIAD_GRAY}

// all before scale
// PILL_SIZE is the row/pill height the whole layout is derived from, so it also sets how many list
// rows fit: MAIN_ROW_COUNT = FIXED_HEIGHT / (PILL_SIZE * FIXED_SCALE) - 2. Guarded so a platform
// whose panel divides badly can trade a little text size for a row (h700: 640x480 at 2x yields
// exactly 8 slots at 30, all spent on header + 6 rows + footer, with no fractional slack to claim).
#ifndef PILL_SIZE
#define PILL_SIZE 30
#endif
// ROW PITCH, separate from PILL height. Rows were positioned at j*PILL_SIZE, so the spacing
// between list items was welded to the size of the highlight pill. That is fine when the pill
// height divides the screen neatly and wasteful when it does not: the Brick Pro at 2.5x fits 8
// rows of 75px, leaving 67px of dead space above the footer. Widening PILL_SIZE to absorb it is
// the wrong lever, because the pill's rounded caps come from a fixed 30-unit sprite and would
// clip (the h700 learned this). Widening the PITCH just spreads the same pills further apart.
// Defaults to PILL_SIZE, so every platform that does not override it is unchanged.
#ifndef ROW_PITCH
#define ROW_PITCH PILL_SIZE
#endif
#define BUTTON_SIZE 20
#define BUTTON_MARGIN 5 // ((PILL_SIZE - BUTTON_SIZE) / 2)
#define BUTTON_PADDING 12
#define SETTINGS_SIZE 4
#define SETTINGS_WIDTH 80

#ifndef MAIN_ROW_COUNT
#define MAIN_ROW_COUNT 6 // FIXED_HEIGHT / (PILL_SIZE * FIXED_SCALE) - 2 (floor and subtract 1 if not an integer)
#endif

#ifndef PADDING
#define PADDING 10 // PILL_SIZE / 3 (or non-integer part of the previous calculatiom divided by three)
#endif

#define FONT_LARGE 16 	// menu
#define FONT_MEDIUM 14 	// single char button label
#define FONT_SMALL 12 	// button hint
#define FONT_TINY 10  	// multi char button label

///////////////////////////////

#define STR_HELPER(x) #x
#define STR(x) STR_HELPER(x)

#define MAX(a, b) (a) > (b) ? (a) : (b)
#define MIN(a, b) (a) < (b) ? (a) : (b)
#define CEIL_DIV(a,b) ((a) + (b) - 1) / (b)

// FRACTIONAL UI SCALE. FIXED_SCALE stays an int for every existing platform, but the scale is now
// applied as a RATIO so a device can sit between the prebuilt asset sheets. A platform that wants
// a half step defines SCALE_NUM/SCALE_DEN (and SCALE_NAME to pick its sheet); everything else gets
// NUM=FIXED_SCALE, DEN=1 and is bit-identical to before.
#ifndef SCALE_NUM
#define SCALE_NUM FIXED_SCALE
#endif
#ifndef SCALE_DEN
#define SCALE_DEN 1
#endif
#ifndef SCALE_NAME
#define SCALE_NAME STR(FIXED_SCALE) // a string EXPRESSION, used with %s, never concatenated
#endif
// Rounds to NEAREST, not toward zero. Truncating a ratio drifts pill caps a pixel short of the
// rows they cap, which is exactly the clipping the h700 hit when PILL_SIZE was trimmed.
#define SCALE1(a) (((a)*SCALE_NUM + SCALE_DEN/2)/SCALE_DEN)
// The inverse, for the few sites that divide BY the scale to get logical units back.
#define UNSCALE1(a) (((a)*SCALE_DEN + SCALE_NUM/2)/SCALE_NUM)
#define SCALE2(a,b) SCALE1(a),SCALE1(b)
#define SCALE3(a,b,c) SCALE1(a),SCALE1(b),SCALE1(c)
#define SCALE4(a,b,c,d) SCALE1(a),SCALE1(b),SCALE1(c),SCALE1(d)

///////////////////////////////

#define HAS_POWER_BUTTON (BUTTON_POWER!=BUTTON_NA||CODE_POWER!=CODE_NA||JOY_POWER!=JOY_NA)
#define HAS_POWEROFF_BUTTON (BUTTON_POWEROFF!=BUTTON_NA)
#define HAS_MENU_BUTTON (BUTTON_MENU!=BUTTON_NA||CODE_MENU!=CODE_NA||JOY_MENU!=JOY_NA)
#define HAS_SKINNY_SCREEN (FIXED_WIDTH<320)

///////////////////////////////

#define BUTTON_NA	-1
#define CODE_NA		-1
#define JOY_NA		-1
#define AXIS_NA		-1

#ifndef BUTTON_POWEROFF
#define BUTTON_POWEROFF BUTTON_NA
#endif
#ifndef CODE_POWEROFF
#define CODE_POWEROFF CODE_NA
#endif

#ifndef BUTTON_MENU_ALT
#define BUTTON_MENU_ALT BUTTON_NA
#endif
#ifndef CODE_MENU_ALT
#define CODE_MENU_ALT CODE_NA
#endif
#ifndef CODE_F1
#define CODE_F1 CODE_NA
#endif
#ifndef CODE_F2
#define CODE_F2 CODE_NA
#endif
#ifndef JOY_F1
#define JOY_F1 JOY_NA
#endif
#ifndef JOY_F2
#define JOY_F2 JOY_NA
#endif

#ifndef JOY_MENU_ALT
#define JOY_MENU_ALT JOY_NA
#endif

#ifndef JOY_MENU_ALT2
#define JOY_MENU_ALT2 JOY_NA
#endif

#ifndef AXIS_L2
#define AXIS_L2	AXIS_NA
#define AXIS_R2	AXIS_NA
#endif 

#ifndef AXIS_LX
#define AXIS_LX	AXIS_NA
#define AXIS_LY	AXIS_NA
#define AXIS_RX	AXIS_NA
#define AXIS_RY	AXIS_NA
#endif 

#ifndef HAS_HDMI
#define HDMI_WIDTH	FIXED_WIDTH
#define HDMI_HEIGHT	FIXED_HEIGHT
#define HDMI_PITCH	FIXED_PITCH
#define HDMI_SIZE	FIXED_SIZE
#endif

#ifndef BTN_A // prevent collisions with input.h in keymon
// TODO: doesn't this belong in api.h? it's meaningless without PAD_*
enum {
	BTN_ID_NONE = -1,
	BTN_ID_DPAD_UP,
	BTN_ID_DPAD_DOWN,
	BTN_ID_DPAD_LEFT,
	BTN_ID_DPAD_RIGHT,
	BTN_ID_A,
	BTN_ID_B,
	BTN_ID_X,
	BTN_ID_Y,
	BTN_ID_START,
	BTN_ID_SELECT,
	BTN_ID_L1,
	BTN_ID_R1,
	BTN_ID_L2,
	BTN_ID_R2,
	BTN_ID_L3,
	BTN_ID_R3,
// F1/F2: two extra face buttons that exist on some devices and not others. On the TrimUI Brick
// they arrive as joystick buttons 9/10, which this codebase historically called L3/R3 because that
// device has no analog sticks to claim those indices. The Brick Pro DOES have sticks, so 9/10 are
// genuine stick clicks there and its F1/F2 moved to KEY_F1/KEY_F2 (59/60) as key events instead.
// They therefore need identities of their own: reusing L3/R3 would cost the Brick Pro its stick
// clicks. Placed BEFORE BTN_ID_MENU so they fall inside the bindable range (LOCAL_BUTTON_COUNT).
// Safe to renumber what follows: bindings persist by NAME (button_labels), never by index.
	BTN_ID_F1,
	BTN_ID_F2,
	BTN_ID_MENU,
	BTN_ID_PLUS,
	BTN_ID_MINUS,
	BTN_ID_POWER,	
	BTN_ID_POWEROFF,

	BTN_ID_ANALOG_UP,
	BTN_ID_ANALOG_DOWN,
	BTN_ID_ANALOG_LEFT,
	BTN_ID_ANALOG_RIGHT,

	BTN_ID_COUNT,
};
enum {
	BTN_NONE		= 0,
	BTN_DPAD_UP 	= 1 << BTN_ID_DPAD_UP,
	BTN_DPAD_DOWN	= 1 << BTN_ID_DPAD_DOWN,
	BTN_DPAD_LEFT	= 1 << BTN_ID_DPAD_LEFT,
	BTN_DPAD_RIGHT	= 1 << BTN_ID_DPAD_RIGHT,
	BTN_A			= 1 << BTN_ID_A,
	BTN_B			= 1 << BTN_ID_B,
	BTN_X			= 1 << BTN_ID_X,
	BTN_Y			= 1 << BTN_ID_Y,
	BTN_START		= 1 << BTN_ID_START,
	BTN_SELECT		= 1 << BTN_ID_SELECT,
	BTN_L1			= 1 << BTN_ID_L1,
	BTN_R1			= 1 << BTN_ID_R1,
	BTN_L2			= 1 << BTN_ID_L2,
	BTN_R2			= 1 << BTN_ID_R2,
	BTN_L3			= 1 << BTN_ID_L3,
	BTN_R3			= 1 << BTN_ID_R3,
	BTN_F1			= 1 << BTN_ID_F1,
	BTN_F2			= 1 << BTN_ID_F2,
	BTN_MENU		= 1 << BTN_ID_MENU,
	BTN_PLUS		= 1 << BTN_ID_PLUS,
	BTN_MINUS		= 1 << BTN_ID_MINUS,
	BTN_POWER		= 1 << BTN_ID_POWER,
	BTN_POWEROFF	= 1 << BTN_ID_POWEROFF,

	BTN_ANALOG_UP 	= 1 << BTN_ID_ANALOG_UP,
	BTN_ANALOG_DOWN	= 1 << BTN_ID_ANALOG_DOWN,
	BTN_ANALOG_LEFT	= 1 << BTN_ID_ANALOG_LEFT,
	BTN_ANALOG_RIGHT= 1 << BTN_ID_ANALOG_RIGHT,
	
	BTN_UP 		= BTN_DPAD_UP | BTN_ANALOG_UP,
	BTN_DOWN 	= BTN_DPAD_DOWN | BTN_ANALOG_DOWN,
	BTN_LEFT	= BTN_DPAD_LEFT | BTN_ANALOG_LEFT,
	BTN_RIGHT	= BTN_DPAD_RIGHT | BTN_ANALOG_RIGHT,
};
#endif

#endif