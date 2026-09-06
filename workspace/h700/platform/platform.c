// h700 — Anbernic RG35XX Plus / RG35XX-H (Allwinner sun50iw9). V0: HOSTED-DEV platform layer.
//
// This version runs as a GUEST inside muOS (launched over ssh with muxfrontend stopped), which
// shapes several choices on purpose:
//   * present = raw fbdev (mmap + FBIOPAN_DISPLAY), the path panelprobe/hellofb proved on-device.
//     The DESTINATION present is the Allwinner DE layer API (/dev/disp, MyMinUI's h700 reference);
//     see README-BRINGUP.md. Do not let this v0 ossify.
//   * CPU/governor = LOG ONLY. A guest must not fight the host OS's governor. The schedutil
//     ceiling model ports when we own the image.
//   * powerOff = exit(0), never poweroff(2) — this is someone's running muOS session.
//   * function surface intentionally mirrors workspace/macos/platform/platform.c, the smallest
//     set proven to link against the shared api.c.
//
// Panel: 640x480 MEASURED 59.9777 Hz. fb is ARGB8888 (stride 2560), virtual 640x960 = 2 pages.
// Render surface is RGB565 like every platform; flip converts 565->XRGB (NEON on the wide path)
// while copying to the back page, then pans. The plain-C conversion measurably halved the game
// loop (29.98fps panrate receipt); the DE layer would do the conversion for free — still the
// destination present path.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <linux/fb.h>
#include <stdint.h>
#include "sunxi_display2.h"
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

#if defined(__aarch64__)
#include <arm_neon.h>
#endif

#include "msettings.h"

#include "defines.h"
#include "platform.h"
#include "api.h"
#include "utils.h"

#include "scaler.h"

// Forward decl: zero_owns_os() is defined lower (with the governor code) but gates owned-OS-only
// behaviour used earlier in the file (PLAT_isToppingUp, PLAT_powerOff).
static int zero_owns_os(void);
// Debug HUD compositor: defined with the other HUD code lower down, called from PLAT_flip above it.
static void dbg_compose(void);
// Screen-effect selection. Declared here because PLAT_getScaler and PLAT_blitRenderer (above the
// effect code) both read it; PLAT_setEffect writes it from the menu.
static int next_effect = EFFECT_NONE;
static int effect_type = EFFECT_NONE;

///////////////////////////////
// msettings lives in ../libmsettings (guest stubs: muOS owns audio/brightness) — the shared
// minui/minarch makefiles link -lmsettings on every platform.

///////////////////////////////

// RAW EVDEV INPUT. muOS's SDL2 delivered zero keyboard events to us (live-tested: every button
// dead), so this platform reads the hardware nodes directly and overrides the weak PLAT_pollInput
// in api.c. Minimal evdev ABI declared by hand — <linux/input.h> defines BTN_* macros that collide
// with api.h's button names (the miyoomini port hit the same wall).
//
// The code table below is CANDIDATE mappings (standard gpio-keys arrows + standard gamepad BTN_*
// codes, Anbernic A-right/B-down orientation). Every event from an UNKNOWN code is logged once, so
// the first hands-on session corrects this table from its own log. That turns the capture problem
// into normal use.
struct raw_input_event { // struct input_event, aarch64 layout
	uint64_t tv_sec;
	uint64_t tv_usec;
	uint16_t type;   // EV_KEY=1, EV_ABS=3
	uint16_t code;
	int32_t  value;  // 1=down, 0=up, 2=autorepeat
};
#define EVDEV_COUNT 3
static int ev_fds[EVDEV_COUNT] = { -1, -1, -1 };
static const char* ev_paths[EVDEV_COUNT] = {
	"/dev/input/event0", // axp2202-pek: power button
	"/dev/input/event1", // muOS-Keys (gpio-keys-polled)
	"/dev/input/event2", // dierct-keys-polled (sic)
};

static SDL_Joystick *joystick;
void PLAT_initInput(void) {
	// SDL's joystick subsystem is NOT our input source: PLAT_pollInput below reads the evdev nodes
	// directly (muOS's SDL2 delivered zero events for these buttons, which is why this platform
	// overrides polling at all), and PLAT_pollInput flushes the SDL event queue every frame.
	// Opening it anyway cost 249ms of a 313ms launcher startup, MEASURED 2026-08-10, and every
	// process pays it: the launcher on boot and after each game, and minarch on every launch.
	// ZERO_SDL_JOYSTICK=1 restores the old behaviour if a device ever needs it.
	uint64_t t0 = getMicroseconds();
	const char* want_js = getenv("ZERO_SDL_JOYSTICK");
	if (want_js && want_js[0] && want_js[0] != '0') {
		SDL_InitSubSystem(SDL_INIT_JOYSTICK);
		joystick = SDL_JoystickOpen(0);
	}
	LOG_info("input: sdl joystick %s (+%llums)\n",
		(want_js && want_js[0] && want_js[0] != '0') ? "opened" : "skipped",
		(unsigned long long)((getMicroseconds() - t0) / 1000));
	for (int i = 0; i < EVDEV_COUNT; i++) {
		ev_fds[i] = open(ev_paths[i], O_RDONLY | O_NONBLOCK);
		LOG_info("evdev: %s -> fd %d\n", ev_paths[i], ev_fds[i]);
	}
}
void PLAT_quitInput(void) {
	for (int i = 0; i < EVDEV_COUNT; i++) if (ev_fds[i] >= 0) close(ev_fds[i]);
	if (joystick) SDL_JoystickClose(joystick);
	SDL_QuitSubSystem(SDL_INIT_JOYSTICK);
}

// code -> (btn, id). MEASURED 2026-08-05: counted-press session on the RG35XX Plus (each button
// pressed a distinct number of times, decoded from count + temporal order). The canonical evdev
// names are WRONG on this hardware — 315 "BTN_START" is R2, 314 "BTN_SELECT" is L2, 310 "BTN_TL"
// is Select — so this table is receipts, not <input-event-codes.h>. MENU is special (captured
// on-device 2026-08-09): one physical press emits 312 (the REAL button — down on press, up on
// release, duration tracks the hold) then a FIXED ~180ms 354 pulse at release (312-up and 354-down
// arrive simultaneously). Map ONLY 312. Mapping 354 too made the release pulse a SECOND BTN_MENU
// press one poll later, so the About screen opened then instantly closed ("finicky"). 354 -> BTN_NONE.
// The dpad is an ANALOG HAT (EV_ABS codes 16/17), handled separately in PLAT_pollInput.
static void ev_translate(uint16_t code, int* btn, int* id) {
	switch (code) {
	case 304: *btn = BTN_A;      *id = BTN_ID_A;      break;
	case 305: *btn = BTN_B;      *id = BTN_ID_B;      break;
	case 307: *btn = BTN_X;      *id = BTN_ID_X;      break;
	case 306: *btn = BTN_Y;      *id = BTN_ID_Y;      break;
	case 308: *btn = BTN_L1;     *id = BTN_ID_L1;     break;
	case 309: *btn = BTN_R1;     *id = BTN_ID_R1;     break;
	case 314: *btn = BTN_L2;     *id = BTN_ID_L2;     break;
	case 315: *btn = BTN_R2;     *id = BTN_ID_R2;     break;
	case 311: *btn = BTN_START;  *id = BTN_ID_START;  break;
	case 310: *btn = BTN_SELECT; *id = BTN_ID_SELECT; break;
	case 312: *btn = BTN_MENU;   *id = BTN_ID_MENU;   break; // MENU (real button; the 354 release-pulse is dropped)
	case 116: *btn = BTN_POWER;  *id = BTN_ID_POWER;  break; // KEY_POWER (event0, axp2202-pek)
	case 115: *btn = BTN_PLUS;   *id = BTN_ID_PLUS;   break; // KEY_VOLUMEUP
	case 114: *btn = BTN_MINUS;  *id = BTN_ID_MINUS;  break; // KEY_VOLUMEDOWN
	default:  *btn = BTN_NONE;   *id = -1;            break;
	}
}

// The dpad hat: EV_ABS code 16 (X: -1 left / +1 right) and 17 (Y: -1 up / +1 down), 0 = released.
static void ev_hat(uint16_t code, int32_t value, uint32_t tick) {
	int neg_btn, neg_id, pos_btn, pos_id;
	if (code == 16) { neg_btn = BTN_DPAD_LEFT; neg_id = BTN_ID_DPAD_LEFT; pos_btn = BTN_DPAD_RIGHT; pos_id = BTN_ID_DPAD_RIGHT; }
	else if (code == 17) { neg_btn = BTN_DPAD_UP; neg_id = BTN_ID_DPAD_UP; pos_btn = BTN_DPAD_DOWN; pos_id = BTN_ID_DPAD_DOWN; }
	else return;
	// release whichever direction is no longer held, press whichever is
	if (value <= 0 && (pad.is_pressed & pos_btn)) { pad.is_pressed &= ~pos_btn; pad.just_repeated &= ~pos_btn; pad.just_released |= pos_btn; }
	if (value >= 0 && (pad.is_pressed & neg_btn)) { pad.is_pressed &= ~neg_btn; pad.just_repeated &= ~neg_btn; pad.just_released |= neg_btn; }
	if (value < 0 && !(pad.is_pressed & neg_btn)) { pad.is_pressed |= neg_btn; pad.just_pressed |= neg_btn; pad.just_repeated |= neg_btn; pad.repeat_at[neg_id] = tick + PAD_REPEAT_DELAY; }
	if (value > 0 && !(pad.is_pressed & pos_btn)) { pad.is_pressed |= pos_btn; pad.just_pressed |= pos_btn; pad.just_repeated |= pos_btn; pad.repeat_at[pos_id] = tick + PAD_REPEAT_DELAY; }
}

// ANALOG STICKS (RG35XX H only; the Plus has none and never emits these codes).
//
// MEASURED on-device 2026-08-14, not assumed, the axis assignment is NOT the conventional
// X/Y/RX/RY, so guessing would have been wrong:
//     ABS_Z  (2) = LEFT stick X      ABS_RX (3) = LEFT stick Y
//     ABS_RY (4) = RIGHT stick X     ABS_RZ (5) = RIGHT stick Y
// Range is +/-4096 (the vendor adc_joystick driver, 4 mux channels with per-channel calibration);
// negative is left/up. The shared code expects SDL-scale values, hence the *8.
//
// These axes only exist when the board's own kernel is running: the device tree declares the
// generic `gpio-keys-polled`, and only the H kernel carries the ADC/mux code that acts on its
// vendor properties. On the Plus kernel the same codes report a -1..1 digital hat.
#define STICK_RAW_MAX 4096
#define STICK_DEADZONE 512   // menu-navigation only; games still get the raw value
static void ev_stick(uint16_t code, int32_t value, uint32_t tick) {
	int scaled = value * (32768 / STICK_RAW_MAX);
	if (scaled >  32767) scaled =  32767;
	if (scaled < -32767) scaled = -32767;
	// Deadzone applies ONLY to the button-emulation used for menu navigation. pad.laxis/raxis keep
	// the full-fidelity value, because that is what minarch hands to cores as RETRO_DEVICE_ANALOG,
	// clamping there would quietly cost precision in every analog game.
	int nav = (value > STICK_DEADZONE || value < -STICK_DEADZONE) ? scaled : 0;
	switch (code) {
		case 2: // left X
			pad.laxis.x = scaled;
			PAD_setAnalog(BTN_ID_ANALOG_LEFT, BTN_ID_ANALOG_RIGHT, nav, tick + PAD_REPEAT_DELAY);
			break;
		case 3: // left Y
			pad.laxis.y = scaled;
			PAD_setAnalog(BTN_ID_ANALOG_UP, BTN_ID_ANALOG_DOWN, nav, tick + PAD_REPEAT_DELAY);
			break;
		case 4: pad.raxis.x = scaled; break; // right X, no menu emulation, matches tg5040
		case 5: pad.raxis.y = scaled; break; // right Y
	}
}

void PLAT_pollInput(void) {
	pad.just_pressed  = BTN_NONE;
	pad.just_released = BTN_NONE;
	pad.just_repeated = BTN_NONE;

	uint32_t tick = SDL_GetTicks();
	for (int i = 0; i < BTN_ID_COUNT; i++) {
		int btn = 1 << i;
		if ((pad.is_pressed & btn) && (tick >= pad.repeat_at[i])) {
			pad.just_repeated |= btn;
			pad.repeat_at[i] += PAD_REPEAT_INTERVAL;
		}
	}

	SDL_PumpEvents();
	SDL_FlushEvents(SDL_FIRSTEVENT, SDL_LASTEVENT); // SDL is not our input source here

	// Log EVERY key-down once per distinct code — mapped or not — so a single press-everything
	// session yields the complete map. (The first version deduped by code&7 and codes silenced
	// each other; a press session came back with 2 of ~15 codes. Receipts require a real set.)
	struct raw_input_event ev;
	for (int i = 0; i < EVDEV_COUNT; i++) {
		if (ev_fds[i] < 0) continue;
		while (read(ev_fds[i], &ev, sizeof(ev)) == sizeof(ev)) {
			// EV_ABS: codes 16/17 are the d-pad hat on every h700 board; 2-5 are the analog
			// sticks, which only report real values on hardware whose kernel drives the ADC mux.
			if (ev.type == 3) {
				if (ev.code >= 2 && ev.code <= 5) ev_stick(ev.code, ev.value, tick);
				else ev_hat(ev.code, ev.value, tick);
				continue;
			}
			if (ev.type != 1) continue;      // EV_KEY otherwise
			if (ev.value == 2) continue;     // autorepeat: we do our own
			// BOOT GRACE for the power key: the press that powers the device ON reaches minui
			// as a press+release pair — the manual-sleep gesture — so every image boot drew one
			// frame and went straight to hybrid sleep ("flash then logo", flash tests 4-7; the
			// menu was one wake-press away the whole time).
			if (ev.code == 116 && tick < 3000) continue;
			int btn, id;
			ev_translate(ev.code, &btn, &id);
			if (btn == BTN_NONE) continue;
			// Edge guard: only a REAL state change may set the just_* flags. MENU's double-fire is
			// now fixed at the source (ev_translate maps only the real 312 button, drops the 354
			// release-pulse), but this guard still protects every key from a repeated same-state event.
			if (ev.value) {
				if (!(pad.is_pressed & btn)) {
					pad.is_pressed    |= btn;
					pad.just_pressed  |= btn;
					pad.just_repeated |= btn; // CONTRACT: the initial press IS a repeat (api.c:1967);
					                          // minui's list nav gates on justRepeated alone
					pad.repeat_at[id] = tick + PAD_REPEAT_DELAY;
				}
			}
			else {
				if (pad.is_pressed & btn) {
					pad.is_pressed    &= ~btn;
					pad.just_repeated &= ~btn;
					pad.just_released |= btn;
				}
			}
		}
	}

	// APPLY volume/brightness here: on shipping platforms KEYMON does this and the shared
	// PWR_update only draws the OSD ("keymon is catching input on the next frame"). This
	// platform has no keymon, so the volume keys showed an OSD that never changed anything
	// (found live 2026-08-05). just_repeated fires on the initial press AND while held, so
	// press-and-hold ramps for free. MENU held = brightness, matching the BTN_MOD_BRIGHTNESS
	// convention every other platform uses.
	int adj = pad.just_repeated & (BTN_PLUS | BTN_MINUS);
	if (adj) {
		int delta = (adj & BTN_PLUS) ? 1 : -1;
		if (pad.is_pressed & BTN_MENU) SetBrightness(GetBrightness() + delta); // clamps 0-10
		else SetVolume(GetVolume() + delta);                                   // clamps 0-20
	}
}

// WAKE from faux-sleep. The shared PLAT_shouldWake (api.c) only reads SDL events — but SDL is DEAD
// on this device (the whole reason PLAT_pollInput above reads raw evdev), so the wake press was
// never seen and a slept device could NEVER wake (found live 2026-08-07: "Entering hybrid sleep",
// dark + muted, no exit). PWR_waitForWake calls this in a loop while PAD_poll is NOT running, so we
// read the evdev fds directly and wake on a POWER-key (code 116) RELEASE — matching the shared
// path's KEYUP semantics, and draining all queued events so a stale press can't false-wake.
int PLAT_shouldWake(void) {
	struct raw_input_event ev;
	int wake = 0;
	for (int i = 0; i < EVDEV_COUNT; i++) {
		if (ev_fds[i] < 0) continue;
		while (read(ev_fds[i], &ev, sizeof(ev)) == sizeof(ev)) {
			if (ev.type == 1 && ev.code == 116 && ev.value == 0) wake = 1; // KEY_POWER release
		}
	}
	return wake;
}

///////////////////////////////

// ---------------------------------------------------------------------------------------------
// DE-LAYER PRESENT (default; ZERO_H700_FB=1 falls back to the fbdev path below).
//
// The Allwinner Display Engine composes layers with a FREE hardware scaler: we hand it an
// RGB565 ION buffer at whatever size minarch rendered (crop) and a screen_win rect, and the
// silicon scales to fullscreen — no 565->XRGB convert, no CPU scale beyond minarch's integer
// prescale (sharp pixels + hardware finish, the same recipe as tg5040's Crisp).
//
// Plumbing adapted from MyMinUI's h700 port (Turro75/MyMinUI, workspace/h700/platform/) — the
// ION ioctl ABI and the 220-byte raw disp_layer_config2 packing are its hard-won discoveries;
// it uses the layer as a fullscreen page-flipper, we add the crop->screen_win scaling.
// FAILSAFE: a dead process leaves its layer configured OVER muOS's screen — tools/layerclean.c
// runs in every session.sh restore path.
// PROBED ABI (ionprobe3, RG35XX Plus muOS 4.9.170, 2026-08-05): this kernel wants the LEGACY
// ion API at aarch64-NATURAL layout — sizeof(alloc)=32 (u64 len/align + trailing pad), so the
// cmd is 0xC0204900, not MyMinUI's 32-bit-userspace 0xC0144900 (ENOTTY here). Heap bit 4 is
// the contiguous DMA heap (bit 0 = system, NOT contiguous — the display engine cannot scan it).
#define ION_IOC_ALLOC_A64 0xC0204900
#define ION_IOC_FREE_A64  0xC0044901
#define ION_IOC_SHARE_A64 0xC0084904
#define ION_HEAP_DMA_MASK (1u << 4)
struct ion_allocation_data_v1 {
	uint64_t len;
	uint64_t align;
	uint32_t heap_id_mask;
	uint32_t flags;
	int32_t handle;
	uint32_t pad;
};
struct ion_fd_data_v1 {
	int32_t handle;
	int32_t fd;
};
// The kernel's disp_layer_config2 ABI does not match the header struct (MyMinUI finding):
// SET_CONFIG2 consumes a raw 220-byte block. Pack the logical struct into it by dword index.
struct disp_layer_config2_raw {
	uint32_t dwords[55];
};
static void disp_pack(struct disp_layer_config2_raw* dst, const struct disp_layer_config2* src) {
	memset(dst, 0, sizeof(*dst));
	dst->dwords[0]  = (uint32_t)src->info.mode;
	dst->dwords[1]  = ((uint32_t)src->info.alpha_value << 16) |
	                  ((uint32_t)src->info.alpha_mode  << 8)  |
	                  ((uint32_t)src->info.zorder);
	dst->dwords[2]  = (uint32_t)src->info.screen_win.x;
	dst->dwords[3]  = (uint32_t)src->info.screen_win.y;
	dst->dwords[4]  = src->info.screen_win.width;
	dst->dwords[5]  = src->info.screen_win.height;
	dst->dwords[8]  = (uint32_t)src->info.fb.fd;
	dst->dwords[9]  = src->info.fb.size[0].width;
	dst->dwords[10] = src->info.fb.size[0].height;
	dst->dwords[18] = (uint32_t)src->info.fb.format;
	dst->dwords[19] = (uint32_t)src->info.fb.color_space;
	dst->dwords[23] = (uint32_t)(src->info.fb.crop.x >> 32);
	dst->dwords[24] = (uint32_t)(src->info.fb.crop.x & 0xFFFFFFFFULL);
	dst->dwords[25] = (uint32_t)(src->info.fb.crop.y >> 32);
	dst->dwords[26] = (uint32_t)(src->info.fb.crop.y & 0xFFFFFFFFULL);
	dst->dwords[27] = (uint32_t)(src->info.fb.crop.width  >> 32);
	dst->dwords[28] = (uint32_t)(src->info.fb.crop.width  & 0xFFFFFFFFULL);
	dst->dwords[29] = (uint32_t)(src->info.fb.crop.height >> 32);
	dst->dwords[30] = (uint32_t)(src->info.fb.crop.height & 0xFFFFFFFFULL);
	dst->dwords[52] = (uint32_t)src->enable;
	dst->dwords[53] = src->channel;
	dst->dwords[54] = src->layer_id;
}

// The display-engine path always cycles exactly two ION pages (vid.page = !vid.page).
// This is NOT vid.pages, which is the fbdev page count derived from yres_virtual and may be 1.
#define DISP_PAGES 2

static struct VID_Context {
	SDL_Surface* screen;   // RGB565 render target handed to the frontend
	GFX_Renderer* blit;

	int fdfb;
	struct fb_var_screeninfo vinfo;
	struct fb_fix_screeninfo finfo;
	uint8_t* fbmmap;
	size_t page_bytes;
	int pages;
	int page;              // page we will draw the NEXT frame into

	int width;
	int height;
	int pitch;

	// DE-layer state
	int use_disp;          // 1 = layer present path active
	int dispfd;
	int ionfd;
	int ion_fds[2];        // dma-buf fds, one per page
	void* ionmmap[DISP_PAGES];
	size_t ion_bytes;      // per-page capacity (panel W*H*2)
	struct disp_layer_config2 lcfg;
	struct disp_layer_config2_raw lraw;
	// the rect within the render surface that actually holds the image this frame.
	// minarch keeps the surface DEVICE-sized and centers the game (fit path, dst_x/dst_y);
	// the layer CROPS this rect and the hardware scales it to screen_win.
	int crop_x, crop_y, crop_w, crop_h;   // the DE crop: FIXED FULL SURFACE, never reprogrammed
	int game_x, game_y, game_w, game_h;   // where the game image sits INSIDE that surface (HUD anchor)
	int last_present_ui; // last flip was a UI frame -> PLAT_vsync must pace (see PLAT_vsync)
	// Countdown of back-pages still to be blacked before their game-rect copy. Game frames rewrite
	// ONLY their own rect, so whatever last wrote the letterbox stays there: closing the menu left
	// the chrome framing the game (Dan's photo, 2026-08-28), and a rect change left the old image's
	// border. Set to DISP_PAGES so each page is cleaned exactly once, on the frame it is the back
	// buffer. Never memset a page the panel is scanning; that is a visible black flash.
	int scrub_pages;
} vid;

// aspect-fit w x h into the panel, centered — the hardware scaler's output window
static void disp_screen_win(int w, int h, struct disp_rect* win) {
	int pw = (int)vid.vinfo.xres, ph = (int)vid.vinfo.yres;
	double scale = (double)pw / w;
	if ((double)ph / h < scale) scale = (double)ph / h;
	int ow = (int)(w * scale + 0.5), oh = (int)(h * scale + 0.5);
	if (ow > pw) ow = pw;
	if (oh > ph) oh = ph;
	win->x = (pw - ow) / 2;
	win->y = (ph - oh) / 2;
	win->width = ow;
	win->height = oh;
}

// (re)shape the layer: the buffer is the full render surface (vid.width x vid.height); the
// layer CROPS (cx,cy,cw,ch) out of it and the hardware scales that rect to screen_win
static void disp_shape_rect(int cx, int cy, int cw, int ch) {
	memset(&vid.lcfg, 0, sizeof(vid.lcfg));
	vid.lcfg.info.mode = LAYER_MODE_BUFFER;
	vid.lcfg.info.zorder = 20;             // above the (frozen) muOS fb
	vid.lcfg.info.alpha_mode = 1;
	vid.lcfg.info.alpha_value = 255;
	// minarch already padded this surface for the requested game aspect. Fit the
	// canonical UI canvas, not the intermediate surface's pixel ratio a second time.
	disp_screen_win(FIXED_WIDTH, FIXED_HEIGHT, &vid.lcfg.info.screen_win);
	vid.lcfg.info.fb.size[0].width = vid.width;
	vid.lcfg.info.fb.size[0].height = vid.height;
	vid.lcfg.info.fb.format = DISP_FORMAT_RGB_565;
	vid.lcfg.info.fb.color_space = DISP_BT601;
	vid.lcfg.info.fb.crop.x = (int64_t)cx << 32;
	vid.lcfg.info.fb.crop.y = (int64_t)cy << 32;
	vid.lcfg.info.fb.crop.width  = (uint64_t)cw << 32;
	vid.lcfg.info.fb.crop.height = (uint64_t)ch << 32;
	vid.lcfg.enable = 1;
	vid.lcfg.channel = 1;
	vid.lcfg.layer_id = 0;
	disp_pack(&vid.lraw, &vid.lcfg);
	vid.crop_x = cx; vid.crop_y = cy; vid.crop_w = cw; vid.crop_h = ch;
	LOG_info("disp: buf %dx%d crop %d,%d %dx%d -> win %d,%d %dx%d\n", vid.width, vid.height,
		cx, cy, cw, ch,
		vid.lcfg.info.screen_win.x, vid.lcfg.info.screen_win.y,
		vid.lcfg.info.screen_win.width, vid.lcfg.info.screen_win.height);
}

// The DE exposes its vsync IRQ count in the attr/sys dump; a commit latches at the NEXT
// vblank. Writing into the other buffer before that latch means scribbling on the live
// scanout (tear). disp_wait_latch parks until the count advances past the commit.
static uint32_t disp_irq_now(void) {
	static char buf[512];
	FILE* f = fopen("/sys/class/disp/disp/attr/sys", "r");
	if (!f) return 0;
	uint32_t irq = 0;
	while (fgets(buf, sizeof(buf) - 1, f)) {
		char* m = strstr(buf, "irq:");
		if (m && sscanf(m, "irq:%u", &irq) == 1) break;
	}
	fclose(f);
	return irq;
}
static uint32_t disp_commit_irq;
static void disp_wait_latch(void) {
	if (!vid.use_disp || !disp_commit_irq) return;
	for (int spins = 0; spins < 20; spins++) { // cap ~20ms: never wedge on a stalled counter
		if (disp_irq_now() != disp_commit_irq) return;
		usleep(1000);
	}
}

static int disp_commit(int page) {
	vid.lraw.dwords[8] = (uint32_t)vid.ion_fds[page];
	// unsigned long args: the sunxi disp_ioctl copies FOUR LONGS from userspace. uint32_t
	// worked for MyMinUI's 32-bit builds but truncated our 64-bit pointer (dmesg "para err").
	unsigned long args[4];
	args[0] = 0; args[1] = 1; args[2] = 0; args[3] = 0;
	if (ioctl(vid.dispfd, DISP_SHADOW_PROTECT, &args) < 0) return -1;
	args[0] = 0; args[1] = (unsigned long)&vid.lraw; args[2] = 1; args[3] = 0;
	int ret = ioctl(vid.dispfd, DISP_LAYER_SET_CONFIG2, &args);
	unsigned long cargs[4] = { 0, 4, 1, 0 };
	ioctl(vid.dispfd, DISP_HWC_COMMIT, &cargs);
	args[0] = 0; args[1] = 0; args[2] = 0; args[3] = 0;
	ioctl(vid.dispfd, DISP_SHADOW_PROTECT, &args);
	disp_commit_irq = disp_irq_now();
	return ret;
}

static void disp_layer_off(void) {
	if (vid.dispfd < 0) return;
	struct disp_layer_config2_raw raw;
	memset(&raw, 0, sizeof(raw));
	raw.dwords[52] = 0; // enable = 0
	raw.dwords[53] = 1; // channel
	raw.dwords[54] = 0; // layer_id
	unsigned long args[4] = { 0, (unsigned long)&raw, 1, 0 };
	ioctl(vid.dispfd, DISP_LAYER_SET_CONFIG2, &args);
}

static int disp_open(void) {
	vid.ionfd = open("/dev/ion", O_RDWR);
	if (vid.ionfd < 0) { LOG_info("disp: no /dev/ion (%s)\n", strerror(errno)); return -1; }
	vid.dispfd = open("/dev/disp", O_RDWR);
	if (vid.dispfd < 0) { LOG_info("disp: no /dev/disp (%s)\n", strerror(errno)); close(vid.ionfd); return -1; }
	// Size for the LARGEST render surface a core requests, not just the panel: minarch scales the
	// game to an integer multiple that can EXCEED 640x480 (GBA 720x540, SNES 784x672, PS1 hi-res),
	// and the DE hardware scaler then downscales the whole thing to the panel via screen_win. A
	// panel-sized buffer overflowed on those cores (segfault, sweep 2026-08-06). 1024x768 RGB565
	// = 1.5MB/page covers every core we ship.
	#define DISP_MAX_W 1024
	#define DISP_MAX_H 768
	vid.ion_bytes = (size_t)DISP_MAX_W * DISP_MAX_H * 2;
	for (int i = 0; i < DISP_PAGES; i++) {
		struct ion_allocation_data_v1 alloc = { .len = vid.ion_bytes, .align = 4096, .heap_id_mask = ION_HEAP_DMA_MASK, .flags = 0 };
		if (ioctl(vid.ionfd, ION_IOC_ALLOC_A64, &alloc) < 0) { LOG_info("disp: ION alloc %d failed (%s)\n", i, strerror(errno)); return -1; }
		struct ion_fd_data_v1 share = { .handle = alloc.handle, .fd = -1 };
		if (ioctl(vid.ionfd, ION_IOC_SHARE_A64, &share) < 0) { LOG_info("disp: ION share %d failed (%s)\n", i, strerror(errno)); return -1; }
		vid.ion_fds[i] = share.fd;
		vid.ionmmap[i] = mmap(NULL, vid.ion_bytes, PROT_READ|PROT_WRITE, MAP_SHARED, share.fd, 0);
		if (vid.ionmmap[i] == MAP_FAILED) { LOG_info("disp: ION mmap %d failed\n", i); return -1; }
		memset(vid.ionmmap[i], 0, vid.ion_bytes);
	}
	// When we OWN the OS (MinUI Zero image — marked by /opt/minui-zero, present on both the
	// from-scratch AND stripped-muOS images), (re)bind the display engine to the LCD and claim
	// the layer. Without it the static menu's single first commit sits in the back buffer and the
	// boot logo shows until an input forces a second commit — a game commits continuously so it
	// was never affected ("logo until A", stripped-muOS 2026-08-06). Detect ownership by our OWN
	// marker, NOT "!muos": the stripped image keeps /opt/muos yet we own the display.
	if (exists("/opt/minui-zero")) {
		unsigned long sw[4] = { 0, DISP_OUTPUT_TYPE_LCD, 0, 0 };
		if (ioctl(vid.dispfd, DISP_DEVICE_SWITCH, &sw) < 0)
			LOG_info("disp: DEVICE_SWITCH to LCD failed (%s)\n", strerror(errno));
		else {
			LOG_info("disp: output switched to LCD (owned OS)\n");
			// Let the mode-set LATCH before anyone commits: a commit issued while the switch is
			// still settling is silently eaten, and the static menu draws exactly once, so the
			// u-boot logo stayed up until a button forced a redraw.
			//
			// ONCE PER BOOT, not once per process. The race only exists on the first switch after
			// power-on; every later switch is a no-op on an already-live LCD. Charging every game
			// launch 80ms for it showed up as 80 of the 106ms gfx_init in the load breakdown
			// (2026-08-10), which is pure tax on "make loading instant".
			if (!exists("/tmp/zero-disp-settled")) {
				usleep(80000);
				putInt("/tmp/zero-disp-settled", 1);
			}
		}
	}
	disp_layer_off(); // clear any stale layer a crashed predecessor left behind
	return 0;
}

SDL_Surface* PLAT_initVideo(void) {
	// SDL video first, for its input plumbing (keyboard events ride the video subsystem; the MMP
	// taught us buttons die without it). muOS's SDL2 is Mali-fbdev; if it refuses because we are
	// not the fb owner of record, keep going — we present through fbdev ourselves regardless.
	if (SDL_Init(SDL_INIT_TIMER | SDL_INIT_EVENTS | SDL_INIT_VIDEO) < 0) {
		LOG_info("SDL video init failed (%s) — input may be joystick-only\n", SDL_GetError());
		SDL_Init(SDL_INIT_TIMER | SDL_INIT_EVENTS);
	}

	vid.fdfb = open("/dev/fb0", O_RDWR);
	if (vid.fdfb < 0) { LOG_error("fb0: %s\n", strerror(errno)); return NULL; }
	ioctl(vid.fdfb, FBIOGET_VSCREENINFO, &vid.vinfo);
	ioctl(vid.fdfb, FBIOGET_FSCREENINFO, &vid.finfo);

	// Trust what the driver reports (recon: 640x480, virtual x960, 32bpp, stride 2560).
	vid.pages = vid.vinfo.yres ? (int)(vid.vinfo.yres_virtual / vid.vinfo.yres) : 1;
	if (vid.pages < 1) vid.pages = 1;
	if (vid.pages > 2) vid.pages = 2;
	vid.page_bytes = (size_t)vid.finfo.line_length * vid.vinfo.yres;
	vid.fbmmap = mmap(NULL, vid.page_bytes * vid.pages, PROT_READ|PROT_WRITE, MAP_SHARED, vid.fdfb, 0);
	if (vid.fbmmap == MAP_FAILED) { LOG_error("fb mmap: %s\n", strerror(errno)); return NULL; }
	LOG_info("fb: %ux%u %ubpp stride=%u pages=%d\n", vid.vinfo.xres, vid.vinfo.yres,
		vid.vinfo.bits_per_pixel, vid.finfo.line_length, vid.pages);

	vid.screen = SDL_CreateRGBSurface(SDL_SWSURFACE, FIXED_WIDTH, FIXED_HEIGHT, FIXED_DEPTH, RGBA_MASK_565);
	vid.width  = FIXED_WIDTH;
	vid.height = FIXED_HEIGHT;
	vid.pitch  = FIXED_PITCH;

	// DE-layer present unless opted out or unavailable; fbdev remains the fallback
	// Model detect: muOS resolves the board (rg35xx-plus vs rg35xx-h vs cube/34xx variants)
	// into this device var. Logged now, consumed later: the H adds HDMI + analog sticks, and
	// the boot-image milestone reads the DT instead. Guest-mode = trust the host answer.
	{
		char model[64] = "unknown";
		FILE* f = fopen("/opt/muos/device/config/board/name", "r");
		if (f) {
			if (fgets(model, sizeof(model), f)) {
				char* nl = strchr(model, 10);
				if (nl) *nl = 0;
			}
			fclose(f);
		}
		LOG_info("model: %s\n", model);
	}

	vid.dispfd = vid.ionfd = -1;
	vid.use_disp = 0;
	if (!getenv("ZERO_H700_FB")) {
		if (disp_open() == 0) {
			disp_shape_rect(0, 0, vid.width, vid.height);
			vid.use_disp = 1;
			LOG_info("present: DE layer (hardware scaler)\n");
		}
		else LOG_info("present: fbdev fallback\n");
	}

	// Draw into the page the panel is NOT scanning. The MMP's whole tearing saga came from
	// nothing tracking the front page; with 2 pages and a SYNCHRONOUS pan (blocks ~16.7ms,
	// measured) the alternation IS the ownership invariant — MyMinUI's model, safe by structure.
	int front = (vid.vinfo.yres && vid.vinfo.yoffset % vid.vinfo.yres == 0)
		? (int)(vid.vinfo.yoffset / vid.vinfo.yres) : 0;
	vid.page = (vid.pages > 1) ? !front : 0;

	return vid.screen;
}

// RGB565 -> XRGB8888 while copying into a fb page. NEON on the wide path: this runs per GAME
// frame (207k px for GBC at 3x), and the per-pixel C version was a measured contributor to the
// loop locking at 29.98fps (panrate receipt, 2026-08-05 — every frame's work exceeded one 16.7ms
// vblank, so every pan waited for the second one and audio starved to ~2/3 supply).
static void fb_blit565(int page) {
	uint16_t* src = (uint16_t*)vid.screen->pixels;
	int src_stride = vid.screen->pitch / 2;
	uint32_t* dst = (uint32_t*)(vid.fbmmap + (size_t)page * vid.page_bytes);
	int dst_stride = vid.finfo.line_length / 4;
	int w = vid.vinfo.xres < (unsigned)vid.screen->w ? vid.vinfo.xres : vid.screen->w;
	int h = vid.vinfo.yres < (unsigned)vid.screen->h ? vid.vinfo.yres : vid.screen->h;
	// center a smaller-than-panel surface (scaled game); borders were cleared at resize
	int ox = ((int)vid.vinfo.xres - w) / 2; if (ox < 0) ox = 0;
	int oy = ((int)vid.vinfo.yres - h) / 2; if (oy < 0) oy = 0;
	for (int y = 0; y < h; y++) {
		uint16_t* s = src + y * src_stride;
		uint32_t* d = dst + (y + oy) * dst_stride + ox;
		int x = 0;
#if defined(__aarch64__)
		for (; x + 8 <= w; x += 8) {
			uint16x8_t p = vld1q_u16(s + x);
			uint8x8_t r = vshrn_n_u16(vandq_u16(p, vdupq_n_u16(0xF800)), 8);            // r5<<3
			uint8x8_t g = vshrn_n_u16(vandq_u16(p, vdupq_n_u16(0x07E0)), 3);            // g6<<2
			uint8x8_t b = vmovn_u16(vshlq_n_u16(vandq_u16(p, vdupq_n_u16(0x001F)), 3)); // b5<<3
			r = vsri_n_u8(r, r, 5); // replicate top bits into the low ones: full 0-255 range
			g = vsri_n_u8(g, g, 6);
			b = vsri_n_u8(b, b, 5);
			uint8x8x4_t o = {{ b, g, r, vdup_n_u8(0xFF) }}; // little-endian XRGB: B,G,R,X
			vst4_u8((uint8_t*)(d + x), o);
		}
#endif
		for (; x < w; x++) {
			uint16_t p = s[x];
			uint32_t r = (p >> 11) & 0x1F, g = (p >> 5) & 0x3F, b = p & 0x1F;
			d[x] = 0xFF000000 | (r << 3 | r >> 2) << 16 | (g << 2 | g >> 4) << 8 | (b << 3 | b >> 2);
		}
	}
}

static void fb_pan(int page) {
	vid.vinfo.yoffset = vid.vinfo.yres * page;
	vid.vinfo.activate = FB_ACTIVATE_VBL;
	ioctl(vid.fdfb, FBIOPAN_DISPLAY, &vid.vinfo); // blocks ~16.7ms (measured): our vsync
}

void PLAT_quitVideo(void) {
	if (vid.use_disp) {
		disp_layer_off(); // a guest must hand the display back — a leaked layer covers muOS
		for (int i = 0; i < DISP_PAGES; i++) {
			if (vid.ionmmap[i] && vid.ionmmap[i] != MAP_FAILED) munmap(vid.ionmmap[i], vid.ion_bytes);
			if (vid.ion_fds[i] > 0) close(vid.ion_fds[i]);
		}
		if (vid.dispfd >= 0) close(vid.dispfd);
		if (vid.ionfd >= 0) close(vid.ionfd);
	}
	if (vid.screen) SDL_FreeSurface(vid.screen);
	if (vid.fbmmap && vid.fbmmap != MAP_FAILED) munmap(vid.fbmmap, vid.page_bytes * vid.pages);
	if (vid.fdfb >= 0) close(vid.fdfb);
	SDL_Quit();
}

void PLAT_clearVideo(SDL_Surface* screen) {
	SDL_FillRect(screen, NULL, 0);
}
void PLAT_clearAll(void) {
	PLAT_clearVideo(vid.screen);
	if (vid.use_disp) {
		// same live-scanout rule as fbdev: only the back page is ours to scrub
		memset(vid.ionmmap[vid.page], 0, vid.ion_bytes);
		return;
	}
	// Zero only the page WE own next; the pan in the next flip retires the other. Never memset
	// the whole mmap — that writes into live scanout (the MMP's PLAT_clearAll lesson).
	if (vid.fbmmap && vid.fbmmap != MAP_FAILED)
		memset(vid.fbmmap + (size_t)vid.page * vid.page_bytes, 0, vid.page_bytes);
}

void PLAT_setVsync(int vsync) {
	// the synchronous pan is the vsync; nothing to configure in v0
}

SDL_Surface* PLAT_resizeVideo(int w, int h, int p) {
	// minarch resizes the render surface to the SCALED game size (e.g. 480x432 for GBC at 3x) and
	// derives its row pitch from it. Ignoring this was the shear-and-repeat glitch: minarch wrote
	// 480-wide rows into a 640-wide surface. Recreate the surface at the requested size; the flip
	// centers it on the panel.
	if (w == vid.width && h == vid.height && p == vid.pitch) return vid.screen;
	LOG_info("resizeVideo(%d,%d,%d)\n", w, h, p);
	if (vid.screen) SDL_FreeSurface(vid.screen);
	vid.screen = SDL_CreateRGBSurface(SDL_SWSURFACE, w, h, FIXED_DEPTH, RGBA_MASK_565);
	vid.width = w; vid.height = h; vid.pitch = vid.screen->pitch;
	if (vid.use_disp) {
		// Accept any render surface that fits the ION buffer; the DE scaler downscales it to the
		// panel (screen_win). Refuse only if it would overflow the buffer (should never happen).
		if ((size_t)w * h * 2 > vid.ion_bytes)
			LOG_info("resizeVideo %dx%d exceeds ION buffer - refusing\n", w, h);
		else {
			// Reconfigure the shadow geometry ONLY — do NOT clear the ION pages. The old memsets
			// blanked BOTH pages including the one the panel was scanning at that instant, so
			// every menu open/close (game<->UI resize) flashed black + popped geometry mid-scan
			// ("jittery, like it was being resized", Dan 2026-08-10). Nothing stale can ever be
			// scanned without them: the new shape only takes effect at the next disp_commit, and
			// that commit always carries a freshly drawn frame at the new geometry.
			disp_shape_rect(0, 0, w, h);
			// forget the previous game rect: a new core with a coincidentally equal rect would
			// otherwise skip the letterbox scrub and inherit stale borders.
			vid.game_x = vid.game_y = vid.game_w = vid.game_h = 0;
		}
	}
	// geometry changed: scrub both fb pages so old borders do not linger (fbdev path)
	else if (vid.fbmmap && vid.fbmmap != MAP_FAILED) memset(vid.fbmmap, 0, vid.page_bytes * vid.pages);
	return vid.screen;
}

void PLAT_setVideoScaleClip(int x, int y, int width, int height) {}
void PLAT_setNearestNeighbor(int enabled) {}
void PLAT_setSharpness(int sharpness) {}

void PLAT_vsync(int remaining) {
	// GAME frames: NO-OP. The DE-layer flip is vblank-SYNCHRONOUS (disp_wait_latch blocks a full
	// refresh), so it IS the pacer. Sleeping here too would be a SECOND pace on top of the flip's,
	// landing inside the governor's frame-work window (startFrame->flip) and inflating "work" to
	// ~15ms for a Game Boy game, pinning the ceiling at max (gov-gate p95=15402us/16672us BUSY,
	// 2026-08-06). With the flip pacing and this a no-op, the closed loop can sink.
	//
	// UI frames: MUST SLEEP. A menu frame that changes nothing never reaches the flip — GFX_sync
	// is then the ONLY pacer, and with this a blanket no-op the menu loop spun free: MEASURED
	// 1,806,300 frames at avg=0ms (thousands of fps) instead of 60. That burns a core and lands
	// redraws at random scanout phase, which is the "jittery, not smooth" in-game menu (Dan
	// 2026-08-10). Every other platform sleeps here (tg5040: SDL_Delay(remaining)). Gate on the
	// last present's kind so gameplay keeps the no-op and only the UI gets paced.
	if (remaining > 0 && vid.last_present_ui) SDL_Delay(remaining);
}

// Integer scaling + centering, the MMP pattern exactly: minarch computes the scale and dst rect;
// the platform honors both. (v0 ignored them — the first game ran 1:1 in the corner.)
scaler_t PLAT_getScaler(GFX_Renderer* renderer) {
	// _c16 (portable C), never _n16: those are hand-written ARM 32-bit assembly and this is aarch64.
	scaler_t effect = NULL;
	switch (next_effect) {
		case EFFECT_LINE:   effect = scaler_effect(renderer->scale, 0, 0); break;
		case EFFECT_LINE50: effect = scaler_effect(renderer->scale, 0, 1); break;
		case EFFECT_LINE25: effect = scaler_effect(renderer->scale, 0, 2); break;
		case EFFECT_GRID:   effect = scaler_effect(renderer->scale, 1, 0); break;
		case EFFECT_GRID50: effect = scaler_effect(renderer->scale, 1, 1); break;
		case EFFECT_GRID25: effect = scaler_effect(renderer->scale, 1, 2); break;
	}
	if (effect) return effect;
	switch (renderer->scale) {
		case 6:  return scale6x6_c16;
		case 5:  return scale5x5_c16;
		case 4:  return scale4x4_c16;
		case 3:  return scale3x3_c16;
		case 2:  return scale2x2_c16;
		default: return scale1x1_c16;
	}
}

static int disp_warm = 0; // a completed present proves the mode-set settled; see settle_commits
void PLAT_blitRenderer(GFX_Renderer* renderer) {
	disp_warm = 1;
	// The effect changes from the menu between frames; minarch caches the chosen scaler in
	// renderer->blit, so re-resolve it when the selection moved (MMP pattern).
	if (effect_type != next_effect) {
		effect_type = next_effect;
		renderer->blit = PLAT_getScaler(renderer);
	}
	vid.blit = renderer;
	if (vid.use_disp) {
		disp_wait_latch(); // the OTHER buffer may still be scanning until the last commit latches
		// scale into the CACHED SDL surface exactly like the fbdev path — scaling straight
		// into the write-combined ION mapping cost +24% of a core (54% vs 30%, measured:
		// scale3x's per-pixel writes defeat write combining). The flip then streams just the
		// crop rect into the ION page as one sequential copy, which WC handles ideally.
		void* dst = renderer->dst + (renderer->dst_y * renderer->dst_p) + (renderer->dst_x * FIXED_BPP);
		((scaler_t)renderer->blit)(renderer->src, dst,
			renderer->src_w, renderer->src_h, renderer->src_p,
			renderer->dst_w, renderer->dst_h, renderer->dst_p);
		// the true drawn size is src * integer scale — on the fit path minarch leaves
		// dst_w/dst_h at DEVICE size (observed live: crop was 640x480 while the game was
		// a 3x 480x432), and only dst_x/dst_y locate the image
		int cw = renderer->scale >= 1 ? renderer->src_w * renderer->scale : renderer->dst_w;
		int ch = renderer->scale >= 1 ? renderer->src_h * renderer->scale : renderer->dst_h;
		// NO RESHAPE, EVER. The DE window is programmed ONCE at init and never touched again:
		// that is exactly what upstream MinUI does on this same sunxi disp (trimuismart sets
		// screen_win at init and only ever updates fb.addr per frame). Reprogramming the window
		// at menu boundaries was this port own invention, and it is the menu-open "resizing"
		// artifact: the DE latches window geometry on a different vblank than the buffer, so one
		// frame scans under the wrong mapping. Proven by elimination across seven builds
		// (2026-08-28) and confirmed against the shipped reference.
		//
		// The game image is placed by the CPU inside the fixed full-screen surface, which is what
		// minarch_screen_scaling = Native already asks for. Bonus: the old path silently
		// OVERRODE Native with a non-integer hardware stretch (512x448 shown at 549x480, blurry);
		// now integer scaling is pixel-exact as configured.
		if (renderer->dst_x != vid.game_x || renderer->dst_y != vid.game_y ||
		    cw != vid.game_w || ch != vid.game_h) {
			// letterbox changed: queue a scrub so no stale pixels survive around the new image.
			// Deferred, one page per frame, rather than memsetting both here: the panel is
			// actively scanning one of them right now.
			vid.scrub_pages = DISP_PAGES;
			vid.game_x = renderer->dst_x; vid.game_y = renderer->dst_y;
			vid.game_w = cw; vid.game_h = ch;
			LOG_info("disp: game rect %d,%d %dx%d inside fixed %dx%d surface\n",
				vid.game_x, vid.game_y, vid.game_w, vid.game_h, vid.width, vid.height);
		}
		return;
	}
	void* dst = renderer->dst + (renderer->dst_y * renderer->dst_p) + (renderer->dst_x * FIXED_BPP);
	((scaler_t)renderer->blit)(renderer->src, dst,
		renderer->src_w, renderer->src_h, renderer->src_p,
		renderer->dst_w, renderer->dst_h, renderer->dst_p);
}

void PLAT_flip(SDL_Surface* IGNORED, int ignored) {
	int fullframe = vid.blit != NULL; // renderer path = the game redraws its whole rect every frame
	// MENU CLOSED (UI frame -> game frame). Every page currently holds full-surface menu chrome,
	// and game frames only ever rewrite their own rect, so without this the chrome stays framing
	// the game forever (Dan's photo, 2026-08-28). Queue one scrub per page.
	if (fullframe && vid.last_present_ui) vid.scrub_pages = DISP_PAGES;
	vid.last_present_ui = !fullframe;
	// MENU-JITTER INSTRUMENTATION (ZERO_FLIP_TRACE=1): one line per UI flip with the inter-flip
	// gap in ms. The in-game menu open reads as discrete snaps on video (measured 2026-08-27);
	// this decides between "frames land unpaced/irregular" and "the transition only draws 2-3
	// frames". Env-gated, zero cost when unset.
	{
		static int trace = -1;
		if (trace < 0) { const char* e = getenv("ZERO_FLIP_TRACE"); trace = (e && e[0]=='1') ? 1 : 0; }
		if (trace && fullframe) {
			// the OPEN jitter lives in the final GAME frames while menu setup runs on this same
			// thread; log only irregular ones (>25ms) so 60fps play stays quiet
			static uint32_t last_game_flip = 0;
			uint32_t tg = SDL_GetTicks();
			if (last_game_flip && tg - last_game_flip > 25)
				LOG_info("fliptrace: GAME STUTTER gap=%ums\n", tg - last_game_flip);
			last_game_flip = tg;
		}
		if (trace && !fullframe) {
			static uint32_t last_ui_flip = 0;
			uint32_t t = SDL_GetTicks();
			// cheap content hash: same hash on consecutive lines = pixel-identical repaint
			uint32_t h = 2166136261u;
			uint16_t* px = (uint16_t*)vid.screen->pixels;
			int n = (vid.screen->pitch / 2) * vid.screen->h;
			for (int i = 0; i < n; i += 97) h = (h ^ px[i]) * 16777619u;
			LOG_info("fliptrace: ui gap=%ums hash=%08x\n", last_ui_flip ? t - last_ui_flip : 0, h);
			last_ui_flip = t;
		}
	}
	dbg_compose();   // HUD rides the frame: composited before the copy, scaled by the DE with it
	if (vid.use_disp) {
		// UI frames must honor the same latch invariant as the game path (PLAT_blitRenderer):
		// without this wait the menu's commits were unpaced — writes landed in a page the panel
		// was still scanning and back-to-back commits raced the shadow registers, which read as
		// "jittery, like it was being resized" (Dan 2026-08-10). The game path waits in
		// blitRenderer, so this only adds pacing where none existed: the in-game menu.
		if (!fullframe) disp_wait_latch();
		{
			// UI = full surface; game = just the crop rect (one sequential pass, the
			// write-combine-friendly shape). The MENU IS FULL DEVICE RESOLUTION, always -
			// it is system UI, not part of the game (Dan, 2026-08-28, correcting the
			// squeeze experiment which proved the transition glitch lives in the DE window
			// reprogram but shrank the menu to do it).
			int cx = fullframe ? vid.game_x : 0;
			int cy = fullframe ? vid.game_y : 0;
			int cw = fullframe ? vid.game_w : vid.width;
			int ch = fullframe ? vid.game_h : vid.height;
			// Black the letterbox on this back page before the game rect lands on top of it.
			// UI frames cover the whole surface themselves and never need it.
			if (vid.scrub_pages > 0 && fullframe) {
				vid.scrub_pages--;
				memset(vid.ionmmap[vid.page], 0, (size_t)vid.height * vid.width * FIXED_BPP);
			}
			uint8_t* srcp = (uint8_t*)vid.screen->pixels + cy * vid.screen->pitch + cx * FIXED_BPP;
			int rowbytes = vid.width * FIXED_BPP;
			uint8_t* dstp = (uint8_t*)vid.ionmmap[vid.page] + cy * rowbytes + cx * FIXED_BPP;
			int copybytes = cw * FIXED_BPP;
			for (int y = 0; y < ch; y++)
				memcpy(dstp + y * rowbytes, srcp + y * vid.screen->pitch, copybytes);
		}
		// UI needs no reshape: the window is fixed full-surface (see PLAT_blitRenderer).
		disp_commit(vid.page);
		int shown = vid.page;
		vid.page = !vid.page;
		// Suspenders for the settle race above: re-commit the first frames after a vsync-plus.
		// If the initial commit was eaten mid-mode-set, this one lands and replaces the boot
		// logo; once the pipeline is warm it is two no-op ioctls and the counter never rearms.
		static int settle_commits = 2;
		// Only while COLD. This guard exists for a boot-time race (a commit eaten mid-mode-set
		// leaving the boot logo up), but it used to fire on the first two UI flips of the
		// PROCESS - which for minarch is the in-game MENU OPEN, since game frames take the
		// blitRenderer path and never consume it. Every first menu open paid a 20ms stall and a
		// duplicate commit, a measurable hitch at the exact moment smoothness matters (found
		// chasing Dan's menu-open jitter, 2026-08-27). A presented game frame proves the
		// pipeline is warm, so the guard now stands down once one has happened.
		if (settle_commits > 0 && !disp_warm) {
			settle_commits--;
			usleep(20000);
			disp_commit(shown);
		}
		// NEVER write a page here. disp_commit() returns as soon as the ioctls are issued; the DE
		// does not latch until the next vblank, so until then the panel is STILL scanning the page
		// we just swapped away from, which is vid.page now. A UI page-coherency memcpy used to sit
		// here, and it dropped menu pixels into that page mid-scanout: a torn band across the middle
		// of the screen for the two frames of the menu open, which is exactly where the two pages
		// differ most (Dan's capture, 2026-08-28).
		//
		// It was redundant as well as harmful. It was cargo-culted from the fbdev path ("same
		// reasoning as the fbdev path"), but THIS path copies the FULL surface on every UI frame
		// (cx/cy = 0, cw/ch = the whole surface, above), so the back page is completely rewritten
		// each time and has nothing to inherit. vid.screen is a plain in-RAM SDL_SWSURFACE that
		// accumulates every draw, so it always holds the complete UI image; the "partial UI redraw"
		// rationale never applied here. Game frames get the letterbox scrub instead.
		vid.blit = NULL;
		return;
	}
	fb_blit565(vid.page);
	fb_pan(vid.page);                        // synchronous: returns with the page on its way out
	if (vid.pages > 1) {
		int shown = vid.page;
		vid.page = !vid.page;
		// Keep the pages COHERENT for the UI: minui only redraws dirty regions, so with strict
		// alternation each page misses the other page updates and the menu ghosts between two
		// half-states (seen in fb captures as composite frames). Games are exempt: they blit the
		// full game rect every frame (borders were scrubbed on both pages at resize), and this
		// 1.2MB copy per frame was part of the work that locked the loop at half rate.
		if (!fullframe)
			memcpy(vid.fbmmap + (size_t)vid.page * vid.page_bytes,
			       vid.fbmmap + (size_t)shown * vid.page_bytes, vid.page_bytes);
	}
	vid.blit = NULL;
}

///////////////////////////////

#define OVERLAY_WIDTH PILL_SIZE
#define OVERLAY_HEIGHT PILL_SIZE
#define OVERLAY_BPP 4
#define OVERLAY_DEPTH 16
#define OVERLAY_PITCH (OVERLAY_WIDTH * OVERLAY_BPP)
#define OVERLAY_RGBA_MASK 0x00ff0000,0x0000ff00,0x000000ff,0xff000000
static struct OVL_Context {
	SDL_Surface* overlay;
} ovl;

SDL_Surface* PLAT_initOverlay(void) {
	ovl.overlay = SDL_CreateRGBSurface(SDL_SWSURFACE, SCALE2(OVERLAY_WIDTH,OVERLAY_HEIGHT),OVERLAY_DEPTH,OVERLAY_RGBA_MASK);
	return ovl.overlay;
}
void PLAT_quitOverlay(void) {
	if (ovl.overlay) SDL_FreeSurface(ovl.overlay);
}
void PLAT_enableOverlay(int enable) {}

///////////////////////////////
// AXP2202 — the Brick's exact PMIC, verified on-device 2026-08-04 (identical sysfs paths).

static int online = 0;
void PLAT_getBatteryStatus(int* is_charging, int* charge) {
	*is_charging = getInt("/sys/class/power_supply/axp2202-usb/online");

	int i = getInt("/sys/class/power_supply/axp2202-battery/capacity");
	// worry less about battery and more about the game you're playing
	     if (i>80) *charge = 100;
	else if (i>60) *charge =  80;
	else if (i>40) *charge =  60;
	else if (i>20) *charge =  40;
	else if (i>10) *charge =  20;
	else           *charge =  10;

	// wifi status, hooking into the regular PWR polling (same as tg5040 platform.c) — this is
	// what feeds PLAT_isOnline and lights the menu wifi glyph (GFX_blitHardwareGroup ASSET_WIFI).
	// `online` was declared but never SET here, so the icon could never appear (parity drift,
	// caught 2026-08-10 when Dan asked for a wifi indicator that upstream already ships).
	char status[16];
	getFile("/sys/class/net/wlan0/operstate", status, 16);
	online = prefixMatch("up", status);
}

// Fine-grained charge level. The AXP2202 here is the Brick exact PMIC with identical sysfs
// paths (verified on-device 2026-08-04), so this is the tg5040 implementation verbatim, including
// its honest-100% rule: the gauge rounds up before the charger actually terminates, so hold at 99%
// until the kernel says Full. Without this the UI fell back to PLAT_getBatteryStatus 20% buckets.
// Gap found by tools/check-plat-surface.sh (2026-08-10).
int PLAT_getChargePercent(void) {
	int pct = -1;
	FILE* bf = fopen("/sys/class/power_supply/axp2202-battery/capacity", "r");
	if (bf) { if (fscanf(bf, "%d", &pct) != 1) pct = -1; fclose(bf); }
	if (pct < 0) return -1;
	if (pct >= 100) {
		char st[16] = "";
		FILE* sf = fopen("/sys/class/power_supply/axp2202-battery/status", "r");
		if (sf) { if (!fgets(st, sizeof(st), sf)) st[0] = 0; fclose(sf); }
		if (strncmp(st, "Full", 4) != 0) pct = 99;
	}
	return pct;
}

// Charging inhibits autosleep (same behaviour as the Brick). Crucial in hosted dev: the 30s
// autosleep was ending input sessions before anyone pressed a button.
int PLAT_isToppingUp(void) {
	// GUEST (hosted-dev inside muOS): report always-topping-up so autosleep never fires — twice a
	// 30s autosleep ate an ssh input session. But on the OWNED MinUI Zero image, sleep policy is
	// ours and this stub disabled autosleep FOREVER (audit 2026-08-07). Report whether the cell is
	// actively FILLING (status "Charging"), not merely whether a cable is attached, so a full-but-
	// plugged device may still autosleep (PWR_preventAutosleep, api.c). Fall back to cable-present
	// if the status node is unreadable (never sleep mid-charge; coarser but safe).
	if (!zero_owns_os()) return 1;
	char status[16] = {0};
	FILE* f = fopen("/sys/class/power_supply/axp2202-battery/status", "r");
	if (f) {
		char* got = fgets(status, sizeof(status), f);
		fclose(f);
		if (got) return strncmp(status, "Charging", 8) == 0;
	}
	return getInt("/sys/class/power_supply/axp2202-usb/online");
}

void PLAT_enableBacklight(int enable) {
	// This device has NO /sys/class/backlight; brightness is the Allwinner dispdbg path (libmsettings
	// SetRawBrightness -> dispdbg setbl). Off = raw 0 (fully dark); on = restore the user's level.
	// GetBrightness reads the panel LIVE, so it would read back 0 after we dim — cache the UI level
	// across the off/on pair. Used by the sleep path (faux-sleep dim + deep-sleep resume).
	static int saved_ui = -1;
	if (enable) {
		if (saved_ui >= 0) { SetBrightness(saved_ui); saved_ui = -1; }
		else SetBrightness(GetBrightness());
	}
	else {
		if (saved_ui < 0) saved_ui = GetBrightness();
		SetRawBrightness(0);
	}
}

void PLAT_powerOff(void) {
	// The "Powering off" message was on screen for ONE FRAME: the teardown below drops the DE
	// layer the instant it runs, unlike platforms whose slower shutdown leaves the panel scanning
	// the message ("way too quick", Dan 2026-08-10). Hold the frame readable and buzz like the
	// other systems do — muOS's own halt.sh runs a 0.3s shutdown rumble on this hardware.
	PLAT_setRumble(1);
	usleep(300000);              // 0.3s buzz, muOS-matched
	PLAT_setRumble(0);
	usleep(1200000);             // message stays readable (~1.5s total with the buzz)
	// On the OWNED MinUI Zero image, signal the frontend launch loop to actually power the device
	// off (it can't otherwise tell a poweroff request from a normal game/menu exit — an in-game
	// poweroff re-launched the same game; audit 2026-08-07). As a GUEST inside muOS we must NOT
	// power off the host, and there's no frontend loop watching — just exit and hand the console back.
	if (zero_owns_os()) putInt("/tmp/poweroff", 1);
	SND_quit();
	VIB_quit();
	PWR_quit();
	GFX_quit();
	exit(0);
}

///////////////////////////////

// We own the governor only on the MinUI Zero image (marked /opt/minui-zero). As a guest on stock
// muOS we must not fight the host. Cached: the marker does not change within a run.
#define MAXFREQ_PATH "/sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq"
static int zero_owns_os(void) {
	static int owns = -1;
	if (owns < 0) owns = exists("/opt/minui-zero");
	return owns;
}

void PLAT_setCPUSpeed(int speed) {
	// The closed-loop governor drives clocks via PLAT_setCPUMaxFreq (the ceiling); this discrete
	// entry point just logs. Real ceiling writes happen in setCPUMaxFreq when we own the OS.
	if (!zero_owns_os()) LOG_info("PLAT_setCPUSpeed(%d) — guest mode, not applied\n", speed);
}

void PLAT_setCPUMaxFreq(int khz) {
	// THE THESIS, now real on our own OS: set the schedutil ceiling (scaling_max_freq); the
	// kernel governor picks beneath it. As a guest we only log. Re-asserted ~1/s, so log on
	// change only (thousands of identical lines otherwise).
	static int last_khz = -1;
	if (khz == last_khz) return;
	last_khz = khz;
	if (zero_owns_os()) {
		putInt(MAXFREQ_PATH, khz);
		LOG_info("PLAT_setCPUMaxFreq: %d kHz -> scaling_max_freq\n", khz);
	}
	else LOG_info("PLAT_setCPUMaxFreq: %d kHz — guest mode, not applied\n", khz);
}

void PLAT_setRumble(int strength) {
	// The motor is PMIC-driven: /sys/class/power_supply/axp2202-battery/moto, binary on/off
	// (echo 1 / echo 0 — muOS func.sh RUMBLE, default case). The old "no rumble hardware
	// reported in recon" was WRONG: recon missed it because it lives under power_supply, not
	// pwm/input. Ear/hand-confirmed live 2026-08-10. Binary motor: any nonzero strength = on.
	putInt("/sys/class/power_supply/axp2202-battery/moto", strength ? 1 : 0);
}

int PLAT_supportsDeepSleep(void) {
	// Suspend-to-RAM: the kernel exposes /sys/power/state "mem", and the AXP2202 power key
	// (i2c 5-0034, wakeup=enabled) + RTC are registered wake sources — same PMIC as the Brick,
	// and spruceOS ships real `echo mem` suspend on this H700 family. The choreography (mixer
	// save/restore, radio teardown, the `echo mem` write) lives in ${BIN_PATH}/suspend, invoked
	// by PWR_deepSleep(). Owned-OS only: never suspend the host while running as a guest in muOS.
	//
	// VALIDATED ON-DEVICE 2026-08-13 (RG35XX Plus): 3 supervised suspend/resume cycles, all clean,
	// with the kernel receipt `PM: Suspending system (mem)` / `PM: suspend exit` and uptime
	// continuous across each. Resume restores screen, volume (mixer read back the exact SetVolume
	// value) and wifi (~30s, via net.sh, sample later than that or it reads as a failure).
	// MEASURED PAYOFF: ~1.0 %/h suspended vs 8.79 %/h playing, i.e. ~9x cheaper and ~4 days of
	// standby, on a device whose ONLY previous option after an idle timeout was to power itself
	// off and lose the session.
	//
	// Validation was 3 supervised cycles, NOT the 10-cycle unattended soak originally planned: the
	// soak needs an RTC that can wake from `mem`, and rtc0 here is an external pcf8563 that is not
	// wired as a wake source (an armed alarm never fired; the device sat suspended until a power
	// press). rtc1 (sunxi-rtc) is untried. Recorded so nobody reads "on by default" as "soaked".
	//
	// Opt-out is the shared one the tg5040 already uses (DEEP_SLEEP_OFF_PATH, honored in
	// PWR_waitForWake), so the Deep Sleep tool works here identically.
	return zero_owns_os(); // owned OS only: never suspend the host while running as a muOS guest
}

int PLAT_pickSampleRate(int requested, int max) {
	// Open the device at the pipewire graph/hardware rate (48000, MEASURED via
	// /proc/asound/card0/pcm0p/sub0/hw_params + pw-top 2026-08-05) instead of the core's
	// native rate. At 32768 the alsa-pipewire plugin resampled us into the 48k graph in ITS
	// clock domain — the hw output node logged 118 xruns (pw-top ERR) while our client node
	// showed 0, i.e. the glitches happened downstream of a stream we fed correctly, and our
	// producer blocked on the plugin's drain clock instead of the real DAC (audibly choppy
	// AND slow, RG35XX Plus 2026-08-05). At 48000 pipewire mixes pass-through and OUR
	// resampler (which the rate-match/DRC machinery adjusts) owns the conversion.
	return MIN(48000, max);
}

// minarch-only surface, v0 stubs
// Effects share the MMP software scaler. Native uses integer patterns; Aspect/Fullscreen
// combine sampling and a panel-pixel pattern in one output pass, without an intermediate
// image. The fractional path's device cost must be measured, not assumed equal to plain scaling.
void PLAT_setEffect(int effect) {
	next_effect = effect;
}

// Debug HUD. minarch hands two RGB565 strips (top/bottom) generated at screen->w /
// DBG_OVERLAY_SCALE and expects them presented SCALED so they span the panel. 0xF81F (magenta) is
// the transparency key. This was a no-op stub, so the Frontend menu offered a HUD that drew
// nothing (Dan 2026-08-11: "missing some settings the Brick and Miyoo versions have").
//
// Our render surface is already RGB565 and the DE scaler stretches the WHOLE surface to the panel,
// so we composite into vid.screen before the flip copies it out and the hardware does the scaling
// for free. Sizing is relative to the render surface for exactly that reason: whatever fraction of
// the surface the strip covers is the fraction of the panel it ends up covering.
#define DBG_KEY 0xF81F
static struct { uint16_t *top, *bottom; int w, h, stride; } dbg;
static int dbg_was_on = 0;

void PLAT_setDebugOverlay(uint16_t* top, uint16_t* bottom, int w, int h, int stride) {
	// Turning the HUD OFF leaves residue: the strips span the full width, so the part overhanging
	// the game rect lands in the letterbox bands that the per-frame present never repaints. Scrub
	// both ION pages once on the off transition (the MMP learned this the hard way, twice).
	if (!top && dbg_was_on && vid.use_disp) {
		if (vid.ionmmap[0] && vid.ionmmap[0] != MAP_FAILED) memset(vid.ionmmap[0], 0, vid.ion_bytes);
		if (vid.ionmmap[1] && vid.ionmmap[1] != MAP_FAILED) memset(vid.ionmmap[1], 0, vid.ion_bytes);
	}
	dbg_was_on = (top != NULL);
	dbg.top = top; dbg.bottom = bottom; dbg.w = w; dbg.h = h; dbg.stride = stride;
}

// Nearest upscale with a 16.16 accumulator: one add per pixel instead of a multiply AND divide,
// which on a 640-wide strip is thousands of divides per frame in a fork whose whole point is not
// spending cycles it does not have to. Step rounded up so the index stays inside the strip.
static void dbg_blit_strip(uint16_t* strip, int dst_x, int dst_y, int dst_w, int dst_h) {
	if (!strip || dst_w <= 0 || dst_h <= 0 || dbg.w <= 0 || dbg.h <= 0) return;
	uint16_t* base = (uint16_t*)vid.screen->pixels;
	int dpitch = vid.screen->pitch / 2;
	const uint32_t xstep = (((uint32_t)dbg.w << 16) + (uint32_t)dst_w - 1) / (uint32_t)dst_w;
	const uint32_t ystep = (((uint32_t)dbg.h << 16) + (uint32_t)dst_h - 1) / (uint32_t)dst_h;
	int wlim = dst_w < vid.width ? dst_w : vid.width;
	uint32_t yacc = 0;
	for (int dy = 0; dy < dst_h; dy++, yacc += ystep) {
		int y = dst_y + dy;
		if (y < 0 || y >= vid.height) continue;
		uint16_t* srow = strip + (size_t)(yacc >> 16) * dbg.stride;
		uint16_t* drow = base + (size_t)y * dpitch;
		uint32_t xacc = 0;
		for (int dx = 0; dx < wlim; dx++, xacc += xstep) {
			int x = dst_x + dx;
			if (x < 0 || x >= vid.width) continue;
			uint16_t px = srow[xacc >> 16];
			if (px == DBG_KEY) continue;   // transparent
			drow[x] = px;
		}
	}
}

static void dbg_compose(void) {
	if (!dbg.top || !vid.screen || !vid.screen->pixels) return;
	const int S = DBG_OVERLAY_SCALE;
	// Strips are generated by minarch at screen->w / DBG_OVERLAY_SCALE, and on THIS platform
	// screen is the render surface (resized per game: 480x432 for GBC at 3x), not the panel. So
	// dbg.w * S is exactly vid.width and the strips span the surface, which the DE then stretches
	// to the panel. The Miyoo formula scales by vid.width/FIXED_WIDTH because ITS vid.width is the
	// framebuffer; borrowing that here shrank the strips to ~75% and clipped the text off the right
	// edge (Dan 2026-08-11).
	// OVERSCAN INSET. The strip content spans essentially the full surface (measured: fields at
	// x=2..211 of a 213-wide strip, so x=6..633 once tripled onto the 640 panel), and this LCD does
	// not display its outermost columns, so the leading and trailing characters were invisible.
	// Nothing was clipped in software: every field logged as DRAWN and in bounds. The Brick never
	// showed this because its 1024-wide surface leaves proportionally more slack.
	// COMPOSE INSIDE THE CROP RECT, not across the whole surface. The DE scans out only
	// vid.crop_* (the game image) and stretches THAT to the panel: SNES showed
	// `crop 64,16 512x448 -> win 45,0 549x480`, so a strip drawn at surface x=0 or y=0 fell
	// outside the crop and was never displayed. That is the "HUD cut off" report, and it is why
	// PS1 looked fine: its 320x240 at 2x filled the surface exactly, making crop == surface.
	// Anchoring to the crop puts the text hard against the visible image edge on every system.
	int cx = vid.game_w > 0 ? vid.game_x : 0;
	int cy = vid.game_h > 0 ? vid.game_y : 0;
	int cw = vid.game_w > 0 ? vid.game_w : vid.width;
	int ch = vid.game_h > 0 ? vid.game_h : vid.height;
	int dst_w = dbg.w * S;
	int dst_h = dbg.h * S;
	// A SMALL margin, not none: with the strip flush to the crop edge the panel sliced the text
	// through the middle of the glyphs, top and bottom (Dan, on-device 2026-08-14) — this LCD does
	// not display its outermost rows. 4*S (8px) clears that band while still reading as edge-anchored;
	// the 19px an earlier 4%-of-height inset produced was visibly too generous.
	int margin = S * 4;
	if (dst_w > cw - margin * 2) dst_w = cw - margin * 2;
	if (dst_h < 1) dst_h = 1;
	if (margin < 1) margin = 1;
	if (dst_h * 2 + margin * 2 > ch) return;   // no room: skip rather than overlap the game
	dbg_blit_strip(dbg.top, cx + margin, cy + margin, dst_w, dst_h);
	dbg_blit_strip(dbg.bottom, cx + margin, cy + ch - dst_h - margin, dst_w, dst_h);
}
void PLAT_getGameRect(int* x, int* y, int* w, int* h) {
	// Return panel-space coordinates even when an effects-off Aspect frame uses
	// an oversized intermediate surface. Native and final-size effects are 1:1.
	if (vid.game_w > 0 && vid.game_h > 0 && vid.width > 0 && vid.height > 0) {
		if (x) *x = vid.game_x * FIXED_WIDTH / vid.width;
		if (y) *y = vid.game_y * FIXED_HEIGHT / vid.height;
		if (w) *w = vid.game_w * FIXED_WIDTH / vid.width;
		if (h) *h = vid.game_h * FIXED_HEIGHT / vid.height;
		return;
	}
	if (x) *x = 0; if (y) *y = 0; if (w) *w = FIXED_WIDTH; if (h) *h = FIXED_HEIGHT;
}

char* PLAT_getModel(void) {
	// TODO: distinguish RG35XX Plus vs H (near-twins; likely a DT compatible string or a key count)
	return "Anbernic RG35XX";
}

int PLAT_isOnline(void) {
	return online;
}
