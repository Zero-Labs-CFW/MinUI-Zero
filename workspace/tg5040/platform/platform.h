// tg5040

#ifndef PLATFORM_H
#define PLATFORM_H

///////////////////////////////

#include "sdl.h"

///////////////////////////////

extern int is_brick;
// The Brick Pro (TG4040) is its OWN device, not a Brick. It shares the Brick's 1024x768 panel and
// @3x assets, and its volume/stick buttons sit at the Brick's joystick indices rather than the
// Smart Pro's, so those read (is_brick||is_brickpro). It differs where it differs: a lower rumble
// drive voltage, plus L4/R4/HOME buttons the Brick does not have. Split mirrors NextUI's shipped
// tg5040 support, which is the only tested Brick Pro reference (checked 2026-08-30).
extern int is_brickpro;

// Night steps: brightness -1..-5 sit below the backlight floor and dim the picture in the display
// engine instead (msettings.c SetBrightness). keymon.c mirrors this value; it includes neither header.
#define BRIGHTNESS_MIN -5

///////////////////////////////

#define BUTTON_UP		BUTTON_NA
#define BUTTON_DOWN		BUTTON_NA
#define BUTTON_LEFT		BUTTON_NA
#define BUTTON_RIGHT	BUTTON_NA

#define BUTTON_SELECT	BUTTON_NA
#define BUTTON_START	BUTTON_NA

#define BUTTON_A		BUTTON_NA
#define BUTTON_B		BUTTON_NA
#define BUTTON_X		BUTTON_NA
#define BUTTON_Y		BUTTON_NA

#define BUTTON_L1		BUTTON_NA
#define BUTTON_R1		BUTTON_NA
#define BUTTON_L2		BUTTON_NA
#define BUTTON_R2		BUTTON_NA
#define BUTTON_L3		BUTTON_NA
#define BUTTON_R3		BUTTON_NA

#define BUTTON_MENU		BUTTON_NA
#define BUTTON_MENU_ALT	BUTTON_NA
#define	BUTTON_POWER	116 // BUTTON_NA
#define	BUTTON_PLUS		BUTTON_NA
#define	BUTTON_MINUS	BUTTON_NA

///////////////////////////////

#define CODE_UP			CODE_NA
#define CODE_DOWN		CODE_NA
#define CODE_LEFT		CODE_NA
#define CODE_RIGHT		CODE_NA

#define CODE_SELECT		CODE_NA
#define CODE_START		CODE_NA

#define CODE_A			CODE_NA
#define CODE_B			CODE_NA
#define CODE_X			CODE_NA
#define CODE_Y			CODE_NA

#define CODE_L1			CODE_NA
#define CODE_R1			CODE_NA
#define CODE_L2			CODE_NA
#define CODE_R2			CODE_NA
#define CODE_L3			CODE_NA
#define CODE_R3			CODE_NA

#define CODE_MENU		CODE_NA
// F1/F2 -- the two lit buttons in the middle of the Brick Pro's face. They arrive as JOYSTICK
// buttons, so these stay CODE_NA; the real mapping is JOY_F1/JOY_F2 below.
#define CODE_F1			CODE_NA
#define CODE_F2			CODE_NA
#define CODE_POWER		102

#define CODE_PLUS		128
#define CODE_MINUS		129

///////////////////////////////
						// HATS
#define JOY_UP			JOY_NA
#define JOY_DOWN		JOY_NA
#define JOY_LEFT		JOY_NA
#define JOY_RIGHT		JOY_NA

#define JOY_SELECT		6
#define JOY_START		7

// TODO: these ended up swapped in the first public release of stock :sob:
#define JOY_A			1
#define JOY_B			0
#define JOY_X			3
#define JOY_Y			2

#define JOY_L1			4
#define JOY_R1			5
#define JOY_L2			JOY_NA
#define JOY_R2			JOY_NA
#define JOY_L3			(is_brick||is_brickpro?9:JOY_NA)
#define JOY_R3			(is_brick||is_brickpro?10:JOY_NA)
// F1/F2 on the Brick Pro = SDL joystick buttons 11/12, MEASURED by event injection with
// ZERO_INPUT_DEBUG (2026-08-31): injecting KEY_F1/KEY_F2 into the pad's event node arrives in
// PAD_poll as "JOY button=11/12", never as a key event. Two layers, both of which were separately
// mistaken for the whole answer before:
//   hardware: the pad sends evdev KEY_F1(59)/KEY_F2(60) -- its capability bitmap says so, and it
//     advertises exactly eleven BTN_* codes (joystick 0..10, the last two the real stick clicks);
//   SDL: the node carries BTN_GAMEPAD, so SDL's joystick driver claims it WHOLE and enumerates
//     every key code on it as a joystick button -- the 11 BTN codes become buttons 0..10, then
//     the KEY codes append in ascending order: KEY_F1 -> 11, KEY_F2 -> 12. They never reach the
//     keyboard path, so a CODE_* (SDL scancode) mapping for them can never fire.
// NextUI ships the same 11/12 pair (its JOY_L4/R4). The plain Brick has no sticks, so ITS F1/F2
// sit at joystick 9/10 and have always been reachable as L3/R3; kept named that way because saved
// shortcut cfgs store buttons by id and renaming would silently re-point existing bindings.
#define JOY_F1			(is_brickpro?11:JOY_NA)
#define JOY_F2			(is_brickpro?12:JOY_NA)
// NO JOY_MENU_ALT HERE. I previously set this to 15, copied from NextUI, without checking it
// against the hardware. The Brick Pro's gamepad advertises exactly ELEVEN BTN_* codes, so joystick
// indices are 0..10 and 15 can never fire (decoded from its own /proc/bus/input/devices KEY
// bitmap, 2026-08-30). Its HOME button arrives two other ways instead: BTN_MODE, which is already
// JOY_MENU = 8, and KEY_HOMEPAGE (172) as a key event. JOY_PLUS/JOY_MINUS at 14/13 are dead here
// for the same reason; volume still works because keymon reads KEY_VOLUMEUP/DOWN (115/114) off
// evdev directly, which is what this device actually sends.

#define JOY_MENU		8
#define JOY_POWER		102
#define JOY_PLUS		(is_brick||is_brickpro?14:128)
#define JOY_MINUS		(is_brick||is_brickpro?13:129)

///////////////////////////////

#define AXIS_L2			2 // ABSZ
#define AXIS_R2			5 // RABSZ

#define AXIS_LX			0 // ABS_X, -30k (left) to 30k (right)
#define AXIS_LY			1 // ABS_Y, -30k (up) to 30k (down)
#define AXIS_RX			3 // ABS_RX, -30k (left) to 30k (right)
#define AXIS_RY			4 // ABS_RY, -30k (up) to 30k (down)

///////////////////////////////

#define BTN_RESUME			BTN_X
#define BTN_SLEEP 			BTN_POWER
#define BTN_WAKE 			BTN_POWER
#define BTN_MOD_VOLUME 		BTN_NONE
#define BTN_MOD_BRIGHTNESS 	BTN_MENU
#define BTN_MOD_PLUS 		BTN_PLUS
#define BTN_MOD_MINUS 		BTN_MINUS

///////////////////////////////

// SPIKE: the Brick Pro renders at 2.5x. Its panel is the Brick's 1024x768, but on noticeably
// larger glass, so @3x reads oversized and @2x too small. 2.5x gives 75px rows and 40px menu text,
// between the two. FIXED_SCALE stays 3 so anything still reading it directly sees a sane integer;
// the ratio below is what actually drives layout, and SCALE_NAME picks the matching sheet.
#define FIXED_SCALE 	(is_brick||is_brickpro?3:2)
#define SCALE_NUM   	(is_brickpro?5:(is_brick?3:2))
#define SCALE_DEN   	(is_brickpro?2:1)
#define SCALE_NAME  	(is_brickpro?"2.5":(is_brick?"3":"2"))
#define FIXED_WIDTH		(is_brick||is_brickpro?1024:1280)
#define FIXED_HEIGHT	(is_brick||is_brickpro?768:720)
#define FIXED_BPP		2
#define FIXED_DEPTH		(FIXED_BPP * 8)
#define FIXED_PITCH		(FIXED_WIDTH * FIXED_BPP)
#define FIXED_SIZE		(FIXED_PITCH * FIXED_HEIGHT)

///////////////////////////////

#define MAIN_ROW_COUNT (is_brickpro?8:(is_brick?7:10))
// Brick Pro only: 8 rows at the 30-unit pill pitch leave 67px dead above the footer. Pitch 32
// (80px at 2.5x) spreads them toward it without touching the 30-unit pill sprite, which would
// clip if PILL_SIZE itself grew. Others keep PILL_SIZE and are unchanged.
#define ROW_PITCH (is_brickpro?32:PILL_SIZE) // Smart Pro: 8 was tuned for the old 80px padding; 10 fits at PADDING 5
// Brick Pro: 7 (18px at 2.5x) instead of 5 (13px). PADDING is the GLOBAL edge inset -- header,
// footer, clock, list and every message box measure from it -- so raising it moves the whole UI
// inward together rather than nudging one element out of alignment with the rest. Paired with
// ROW_PITCH 32 above: the tighter rows pay for the wider margin. MEASURED at these values: rows
// run 18..653 and the footer starts at 675, so 22px separates them and 18px sits below the footer.
#define PADDING (is_brickpro?7:(is_brick?5:10)) // was (is_brick?5:40) — 40 = an 80px inset per side; 10 (=20px) is a tasteful breathing ring

///////////////////////////////

#define SDCARD_PATH "/mnt/SDCARD"
#define MUTE_VOLUME_RAW 0

///////////////////////////////

#endif
