#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <sys/ioctl.h>
#include <sys/mman.h>

#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h> // mkdir for the devmode screenshot dir
#include <pthread.h>

#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdatomic.h>

#include <msettings.h>

#include <time.h>
#include "defines.h"
#include "api.h"
#include "ff_audio_rate.h"
#include "snd_pacing.h"
#include "utils.h"

///////////////////////////////

void LOG_note(int level, const char* fmt, ...) {
	char buf[1024] = {0};
	va_list args;
	va_start(args, fmt);
	vsnprintf(buf, sizeof(buf), fmt, args);
	va_end(args);
	switch(level) {
#ifdef DEBUG
	case LOG_DEBUG:
		printf("[DEBUG] %s", buf);
		break;
#endif
	case LOG_INFO:
		printf("[INFO] %s", buf);
		break;
	case LOG_WARN:
		fprintf(stderr, "[WARN] %s", buf);
		break;
	case LOG_ERROR:
		fprintf(stderr, "[ERROR] %s", buf);
		break;
	default:
		break;
	}
	fflush(stdout);
}

///////////////////////////////

uint32_t RGB_WHITE;
uint32_t RGB_BLACK;
uint32_t RGB_LIGHT_GRAY;
uint32_t RGB_GRAY;
uint32_t RGB_DARK_GRAY;

static struct GFX_Context {
	SDL_Surface* screen;
	SDL_Surface* assets;

	int mode;
	int vsync;
} gfx;

static SDL_Rect asset_rects[ASSET_COUNT];
static uint32_t asset_rgbs[ASSET_COLORS];
GFX_Fonts font;

///////////////////////////////

static struct PWR_Context {
	int initialized;
	
	int can_sleep;
	int can_poweroff;
	int can_autosleep;
	int requested_sleep;
	int requested_wake;
	int resume_tick; // SDL ticks at last resume — used to debounce the wake button press

	pthread_t battery_pt;
	int is_charging;
	int charge;
	int should_warn;

	SDL_Surface* overlay;
} pwr = {0};

///////////////////////////////

static int _;

// GFX_blitPill/GFX_blitRect draw one shape from two sources: rounded caps blitted out of the
// asset sheet, and a flat SDL_FillRect for the straight middle. The fill colour came from the
// hardcoded TRIAD_* constants, so a sheet whose grays don't match those constants renders a
// visibly two-tone pill -- MEASURED on a card carrying a foreign sheet: caps 0x1C vs middle
// 0x26, i.e. luma 26 against 35 on the RGB565 panel, with a hard seam where the cap meets the
// fill. Sample the fill straight out of the sheet instead, so the two halves of a shape can
// never disagree no matter which assets are installed. Falls back to the TRIAD_* value for any
// sprite whose centre isn't opaque (and for a missing sheet), so behaviour is unchanged when
// the sheet already matches.
static uint32_t sampleAssetPixel(SDL_Surface* s, int x, int y, uint32_t fallback) {
	if (!s || !s->pixels) return fallback;
	if (x < 0 || y < 0 || x >= s->w || y >= s->h) return fallback;

	uint8_t* p = (uint8_t*)s->pixels + y * s->pitch + x * s->format->BytesPerPixel;
	uint32_t pixel;
	switch (s->format->BytesPerPixel) {
		case 1:  pixel = *p; break;
		case 2:  pixel = *(uint16_t*)p; break;
		case 4:  pixel = *(uint32_t*)p; break;
		default: return fallback; // 24bpp: byte order varies, not worth the risk
	}

	uint8_t r,g,b,a;
	SDL_GetRGBA(pixel, s->format, &r,&g,&b,&a);
	if (a != 255) return fallback; // transparent centre: sprite isn't a solid fill
	return SDL_MapRGB(gfx.screen->format, r,g,b);
}
static void GFX_sampleAssetRGBs(void) {
	if (!gfx.assets) return;

	int must_lock = SDL_MUSTLOCK(gfx.assets);
	if (must_lock && SDL_LockSurface(gfx.assets) != 0) return;

	// [0,ASSET_COLORS) is exactly the set of assets drawn by GFX_blitPill/GFX_blitRect
	for (int asset=0; asset<ASSET_COLORS; asset++) {
		SDL_Rect* r = &asset_rects[asset];
		asset_rgbs[asset] = sampleAssetPixel(gfx.assets,
			r->x + r->w/2, r->y + r->h/2, asset_rgbs[asset]);
	}

	if (must_lock) SDL_UnlockSurface(gfx.assets);
}

SDL_Surface* GFX_init(int mode) {
	// TODO: this doesn't really belong here...
	// tried adding to PWR_init() but that was no good (not sure why)
	PLAT_initLid();
	
	gfx.screen = PLAT_initVideo();
	gfx.vsync = VSYNC_STRICT;
	gfx.mode = mode;
	
	RGB_WHITE		= SDL_MapRGB(gfx.screen->format, TRIAD_WHITE);
	RGB_BLACK		= SDL_MapRGB(gfx.screen->format, TRIAD_BLACK);
	RGB_LIGHT_GRAY	= SDL_MapRGB(gfx.screen->format, TRIAD_LIGHT_GRAY);
	RGB_GRAY		= SDL_MapRGB(gfx.screen->format, TRIAD_GRAY);
	RGB_DARK_GRAY	= SDL_MapRGB(gfx.screen->format, TRIAD_DARK_GRAY);
	
	asset_rgbs[ASSET_WHITE_PILL]	= RGB_WHITE;
	asset_rgbs[ASSET_BLACK_PILL]	= RGB_BLACK;
	asset_rgbs[ASSET_DARK_GRAY_PILL]= RGB_DARK_GRAY;
	asset_rgbs[ASSET_OPTION]		= RGB_DARK_GRAY;
	asset_rgbs[ASSET_BUTTON]		= RGB_WHITE;
	asset_rgbs[ASSET_PAGE_BG]		= RGB_WHITE;
	asset_rgbs[ASSET_STATE_BG]		= RGB_WHITE;
	asset_rgbs[ASSET_PAGE]			= RGB_BLACK;
	asset_rgbs[ASSET_BAR]			= RGB_WHITE;
	asset_rgbs[ASSET_BAR_BG]		= RGB_BLACK;
	asset_rgbs[ASSET_BAR_BG_MENU]	= RGB_DARK_GRAY;
	asset_rgbs[ASSET_UNDERLINE]		= RGB_GRAY;
	asset_rgbs[ASSET_DOT]			= RGB_LIGHT_GRAY;
	asset_rgbs[ASSET_HOLE]			= RGB_BLACK;
	
	asset_rects[ASSET_WHITE_PILL]		= (SDL_Rect){SCALE4( 1, 1,30,30)};
	asset_rects[ASSET_BLACK_PILL]		= (SDL_Rect){SCALE4(33, 1,30,30)};
	asset_rects[ASSET_DARK_GRAY_PILL]	= (SDL_Rect){SCALE4(65, 1,30,30)};
	asset_rects[ASSET_OPTION]			= (SDL_Rect){SCALE4(97, 1,20,20)};
	asset_rects[ASSET_BUTTON]			= (SDL_Rect){SCALE4( 1,33,20,20)};
	asset_rects[ASSET_PAGE_BG]			= (SDL_Rect){SCALE4(64,33,15,15)};
	asset_rects[ASSET_STATE_BG]			= (SDL_Rect){SCALE4(23,54, 8, 8)};
	asset_rects[ASSET_PAGE]				= (SDL_Rect){SCALE4(39,54, 6, 6)};
	asset_rects[ASSET_BAR]				= (SDL_Rect){SCALE4(33,58, 4, 4)};
	asset_rects[ASSET_BAR_BG]			= (SDL_Rect){SCALE4(15,55, 4, 4)};
	asset_rects[ASSET_BAR_BG_MENU]		= (SDL_Rect){SCALE4(85,56, 4, 4)};
	asset_rects[ASSET_UNDERLINE]		= (SDL_Rect){SCALE4(85,51, 3, 3)};
	asset_rects[ASSET_DOT]				= (SDL_Rect){SCALE4(33,54, 2, 2)};
	asset_rects[ASSET_BRIGHTNESS]		= (SDL_Rect){SCALE4(23,33,19,19)};
	asset_rects[ASSET_VOLUME_MUTE]		= (SDL_Rect){SCALE4(44,33,10,16)};
	asset_rects[ASSET_VOLUME]			= (SDL_Rect){SCALE4(44,33,18,16)};
	asset_rects[ASSET_BATTERY]			= (SDL_Rect){SCALE4(47,51,17,10)};
	asset_rects[ASSET_BATTERY_LOW]		= (SDL_Rect){SCALE4(66,51,17,10)};
	asset_rects[ASSET_BATTERY_FILL]		= (SDL_Rect){SCALE4(81,33,12, 6)};
	asset_rects[ASSET_BATTERY_FILL_LOW]	= (SDL_Rect){SCALE4( 1,55,12, 6)};
	asset_rects[ASSET_BATTERY_BOLT]		= (SDL_Rect){SCALE4(81,41,12, 6)};
	asset_rects[ASSET_SCROLL_UP]		= (SDL_Rect){SCALE4(97,23,24, 6)};
	asset_rects[ASSET_SCROLL_DOWN]		= (SDL_Rect){SCALE4(97,31,24, 6)};
	asset_rects[ASSET_WIFI]				= (SDL_Rect){SCALE4(95,39,14,10)};
	asset_rects[ASSET_HOLE]				= (SDL_Rect){SCALE4( 1,63,20,20)};
	
	char asset_path[MAX_PATH];
	// The sheet is picked by SCALE_NAME, which can now name a sheet an older card does not carry
	// (the Brick Pro's 2.5x). Everything downstream -- SDLX_SetAlpha in PWR_initOverlay first --
	// dereferences gfx.assets without checking, so a miss here is a segfault at boot, not a
	// degraded UI. Fall back to the integer sheet, which has shipped since forever: wrong size
	// beats no launcher, and the log names the sheet that was missing.
	sprintf(asset_path, RES_PATH "/assets@%sx.png", SCALE_NAME);
	gfx.assets = IMG_Load(asset_path);
	if (!gfx.assets) {
		LOG_info("missing/unreadable %s, falling back to @%ix\n", asset_path, FIXED_SCALE);
		sprintf(asset_path, RES_PATH "/assets@%ix.png", FIXED_SCALE);
		gfx.assets = IMG_Load(asset_path);
	}
	if (!gfx.assets) LOG_info("no asset sheet at all, you're about to segfault dummy!\n");
	GFX_sampleAssetRGBs(); // fills must match the sheet they're capped with; see above

	TTF_Init();
	// Read the font ONCE and open all four sizes from that one in-memory copy.
	// TTF_OpenFont(path,...) re-opens and re-reads the file every call, so four sizes meant four
	// full reads of the same ~165KB OTF off FAT32 on every launch — pure boot latency on a cold
	// page cache. (MEASURED: graphics init is 90ms of a 174ms warm startup; it is worse cold.)
	// The buffer must outlive the fonts, so it is intentionally never freed — it is process-
	// lifetime state, like the fonts themselves.
	static void* font_buf = NULL;
	static size_t font_len = 0;
	if (!font_buf) {
		FILE* ff = fopen(FONT_PATH, "rb");
		if (ff) {
			fseek(ff, 0, SEEK_END);
			long n = ftell(ff);
			fseek(ff, 0, SEEK_SET);
			if (n > 0) {
				font_buf = malloc((size_t)n);
				if (font_buf && fread(font_buf, 1, (size_t)n, ff) == (size_t)n) font_len = (size_t)n;
				else { free(font_buf); font_buf = NULL; }
			}
			fclose(ff);
		}
	}
	#define OPEN_FONT(sz) ( font_buf \
		? TTF_OpenFontRW(SDL_RWFromConstMem(font_buf, (int)font_len), 1, (sz)) \
		: TTF_OpenFont(FONT_PATH, (sz)) )
	font.large 	= OPEN_FONT(SCALE1(FONT_LARGE));
	font.medium = OPEN_FONT(SCALE1(FONT_MEDIUM));
	font.small 	= OPEN_FONT(SCALE1(FONT_SMALL));
	font.tiny 	= OPEN_FONT(SCALE1(FONT_TINY));
	#undef OPEN_FONT
	
	TTF_SetFontStyle(font.large, TTF_STYLE_BOLD);
	TTF_SetFontStyle(font.medium, TTF_STYLE_BOLD);
	TTF_SetFontStyle(font.small, TTF_STYLE_BOLD);
	TTF_SetFontStyle(font.tiny, TTF_STYLE_BOLD);
	
	return gfx.screen;
}
void GFX_quit(void) {
	TTF_CloseFont(font.large);
	TTF_CloseFont(font.medium);
	TTF_CloseFont(font.small);
	TTF_CloseFont(font.tiny);
	
	SDL_FreeSurface(gfx.assets);
	
	GFX_freeAAScaler();
	
	GFX_clearAll();

	PLAT_quitVideo();
}

void GFX_setMode(int mode) {
	gfx.mode = mode;
}
int GFX_getVsync(void) {
	return gfx.vsync;
}
void GFX_setVsync(int vsync) {
	PLAT_setVsync(vsync);
	gfx.vsync = vsync;
}

int GFX_hdmiChanged(void) {
	static int had_hdmi = -1;
	int has_hdmi = GetHDMI();
	if (had_hdmi==-1) had_hdmi = has_hdmi;
	if (had_hdmi==has_hdmi) return 0;
	had_hdmi = has_hdmi;
	return 1;
}

// MEASURED (Brick disp sysfs, 2026-07-02): the panel refreshes at 60.8 fps, not 60.0. That's FASTER
// than every core we run (50-60.1), so vsync is never the pacing limiter and this budget math is
// safe as-is — but don't assume 60.0 panel timing when reasoning about present/vblank behavior.
#define FRAME_BUDGET 17 // 60fps
static uint32_t frame_start = 0;
static int frame_overran = 0; // closed-loop governor: did the last frame's CPU work exceed the budget?
static uint64_t frame_start_us = 0; // benchmark telemetry: us timestamp at frame start
static uint32_t frame_work_us = 0;  // us of CPU work from GFX_startFrame to GFX_flip
void GFX_startFrame(void) {
	// NOTE: an earlier per-frame PERIOD check here (frame gap vs core budget) was removed — the
	// pipeline is bursty by design (audio-block pacing + GL buffering), so a healthy 60fps
	// average still contains >17ms gaps and the check false-slipped every system to its max
	// ceiling (clean sweep, 2026-07-02). The governor's slowdown signal is the core generation
	// rate (cpu_double vs core.fps in minarch's gov tick) — jitter-immune ground truth.
	frame_start = SDL_GetTicks();
	frame_start_us = getMicroseconds();
}
uint32_t GFX_getFrameWorkUs(void) {
	return frame_work_us;
}
void GFX_finishFrameWork(void) {
	// present-skip path: the frame did real work even though it will not flip — close
	// the sample so per-frame work consumers (governor batch) never read a stale value
	if (frame_start_us) {
		frame_work_us = (uint32_t)(getMicroseconds() - frame_start_us);
		frame_start_us = 0;
	}
}
int GFX_didOverrun(void) {
	return frame_overran;
}

static int SND_ringPct(void); // defined after the snd context (presentation-drop catch-up)
static uint32_t SND_lastBatchMs(void); // last producer write, for the menu/pause gate
static uint32_t gfx_flip_wait_us_store; // defined below GFX_flip via alias
#define gfx_flip_wait_us gfx_flip_wait_us_store
static int gfx_drop_active = 0; // presentation-drop state (game path only); menu flips clear it
static int gfx_drop_enabled = 0;
void GFX_setPresentationDrop(int enabled) {
	gfx_drop_enabled = enabled;
	gfx_drop_active = 0;
	LOG_info("presentation-drop: %s\n", enabled ? "enabled" : "disabled");
}
void GFX_flip(SDL_Surface* screen) {
	GFX_maybeScreenshot(); // devmode: file-triggered PNG capture; cached no-op otherwise
	// UNCONDITIONAL present — the menu/UI/single-shot path. Presentation-drop must never
	// apply here: menu screens render once and then wait for input, so one skipped
	// present is an INVISIBLE MENU until the next input-driven redraw — Dan hit an
	// invisible menu in BR2 within minutes of the first candidate (2026-07-13). Only the
	// game run loop, which presents continuously, may skip (GFX_flipGame below).
	gfx_drop_active = 0; // a UI present re-anchors: leaving the menu re-evaluates fresh
	uint32_t frame_duration = SDL_GetTicks()-frame_start;
	if (frame_start_us) frame_work_us = (uint32_t)(getMicroseconds() - frame_start_us); // benchmark: frame work time
	// per-frame pure-work slip at us precision. No consumer today: GFX_didOverrun has no
	// callers (the governor reads frame_work_us via GFX_getFrameWorkUs for its p95 sink gate,
	// D24). The D14 note that its audio-pacing overcount was "protective" described the
	// pre-D24 design; kept as telemetry.
	frame_overran = (frame_start!=0 && frame_work_us > 16667);
	int should_vsync = (gfx.vsync!=VSYNC_OFF && (gfx.vsync==VSYNC_STRICT || frame_start==0 || frame_duration<FRAME_BUDGET));

	uint64_t flip_t0 = getMicroseconds();
	PLAT_flip(screen, should_vsync);
	gfx_flip_wait_us = (uint32_t)(getMicroseconds() - flip_t0); // how long the flip blocked (vsync-bound signal)
}
void GFX_flipGame(SDL_Surface* screen) {
	// GAME-RUN-LOOP present: the ONLY path where presentation-drop may skip.
	// Catch-up was measured on PS1, but Supafaust's healthy queue also crosses the
	// PS1-tuned 50% threshold in steady state. Never drop another system's frames.
	if (!gfx_drop_enabled) {
		GFX_flip(screen);
		return;
	}
	//
	// PRESENTATION-DROP CATCH-UP (task #13 phase 1 — "presentation-drop catch-up").
	// The v1.3 vsync-skip here was a NO-OP on tg5040: the renderer is created with
	// SDL_RENDERER_PRESENTVSYNC and PLAT_flip ignores its flag, so ring dips during
	// MDEC/FMV stalls were never actually mitigated. Real contract: below 50% ring
	// occupancy skip the ENTIRE present — no upload, no RenderCopy, no RenderPresent —
	// so this frame's present+vsync time goes to producing the next frame's audio
	// instead; resume presenting at 66% (hysteresis). Occupancy is a torn-free atomic
	// snapshot (SND_ringPct), not a raw index read.
	// Guard from the 2026-07-08 receipt (formerly on SND_ringLow): a refill target a
	// below-realtime game can never reach locks catch-up on and collapses pacing — as
	// presentation-drop that would be a frozen screen. So each engagement presents at
	// least every 7th frame (max 6 consecutive drops, ~100ms): a frozen screen is
	// structurally impossible and pacing re-anchors on every forced present.
	static int drop_streak = 0;
	int ring_pct = SND_ringPct();
	// engage only while the core is actually producing audio (a batch write in the last
	// 250ms — MDEC stalls measure 42-60ms, well inside). Belt on top of the GFX_flip
	// split above: in the pause/menu state the core stops producing and the callback
	// drains the ring to 0%; this gate alone proved insufficient at the menu-ENTRY edge
	// (production <250ms stale, ring still low), which is why menu presents now bypass
	// the drop entirely instead of relying on it.
	int producing = (SDL_GetTicks() - SND_lastBatchMs()) < 250;
	if (!producing || SND_isPrefilling()) gfx_drop_active = 0; // prefill: DAC paused, nothing
		// consumes, low occupancy is EXPECTED — dropping presents buys no audio ("engaged
		// (ring 8%)" at launch was this, a pure judder generator)
	else if (!gfx_drop_active) {
		if (ring_pct < 50) {
			gfx_drop_active = 1; drop_streak = 0;
			LOG_info("audio catch-up: presentation-drop engaged (ring %d%%)\n", ring_pct);
		}
	}
	else if (ring_pct >= 66) gfx_drop_active = 0;
	if (gfx_drop_active && drop_streak < 6) {
		drop_streak++;
		if (frame_start_us) frame_work_us = (uint32_t)(getMicroseconds() - frame_start_us);
		frame_overran = (frame_start!=0 && frame_work_us > 16667);
		// a dropped present blocked for 0us — report exactly that. Nothing consumes
		// gfx_flip_wait_us today (GFX_getFlipWaitUs has no callers), and neither does
		// frame_overran (GFX_didOverrun has none either). What the governor takes from
		// here is frame_work_us via GFX_getFrameWorkUs (closed above) for its p95 sink
		// gate, alongside minarch's generation-rate slip detector (D24).
		gfx_flip_wait_us = 0;
		return;
	}
	drop_streak = 0;

	int was_drop = gfx_drop_active;
	GFX_flip(screen);
	gfx_drop_active = was_drop; // GFX_flip clears it for UI presents; game path keeps hysteresis
}
uint32_t GFX_getFlipWaitUs(void) { return gfx_flip_wait_us; }
static uint32_t gfx_pace_period_us = 0; // 0 = stock FRAME_BUDGET; set by DRC to the panel period
void GFX_setPacePeriodUs(uint32_t us) { gfx_pace_period_us = us; }
void GFX_sync(void) {
	GFX_maybeScreenshot(); // devmode: file-triggered capture, checked here so static dialogs (say/confirm/Tools) that only GFX_flip when dirty are still reachable while idling
	uint32_t frame_duration = SDL_GetTicks() - frame_start;
	// Preserve the original gate (the "under budget / strict / first frame" condition helps SuperFX
	// chip games by not stalling a genuinely over-budget frame even further).
	int paced = (gfx.vsync!=VSYNC_OFF)
		? (gfx.vsync==VSYNC_STRICT || frame_start==0 || frame_duration<FRAME_BUDGET)
		: (frame_duration<FRAME_BUDGET);

	// Absolute-schedule pacer (ported from MyMinUI's GFX_flip_fixed_rate, api.c:437): pace against a
	// fixed anchor + N*budget instead of a per-frame relative delay, so pacing cannot accumulate drift
	// over a run. Waits via PLAT_vsync only (NO busy-spin — MyMinUI spins the tail for us-precision, but
	// that burns ~1ms/frame of CPU, against the runs-cold thesis). Resets the schedule if we drift more
	// than 2 frames (a stall/jump) so we re-anchor instead of bursting to catch up.
	static uint64_t anchor_us = 0;
	static int64_t  frame_index = -1;
	uint64_t period_us = gfx_pace_period_us ? gfx_pace_period_us : (uint64_t)FRAME_BUDGET * 1000;

	if (!paced) { anchor_us = 0; frame_index = -1; return; } // not pacing this frame -> resync next time

	uint64_t now = getMicroseconds();
	frame_index++;
	if (anchor_us==0 || frame_index==0) { anchor_us = now; frame_index = 0; }
	uint64_t target  = anchor_us + (uint64_t)frame_index * period_us;
	int64_t  offset  = (int64_t)(now - target);

	if (offset < -(int64_t)(2*period_us) || offset > (int64_t)(2*period_us)) { // lost sync -> re-anchor
		anchor_us = 0; frame_index = -1;
		return;
	}
	if (offset < 0) PLAT_vsync((int)((-offset) / 1000)); // sleep the remaining whole ms to the scheduled time
}

FALLBACK_IMPLEMENTATION SDL_Surface* PLAT_captureRendererToSurface(void) { return NULL; } // no live renderer to read on this platform

// DEVMODE SCREENSHOT (dev tool only; never runs on a user card). Two triggers, both gated on
// devmode: the MENU+SELECT chord (passed in as `hotkey`) and an SSH-friendly trigger file
// (`touch /tmp/take_screenshot`), so a dev can grab a frame remotely without touching the pad.
// Reads the live SDL renderer (PLAT_captureRendererToSurface) and writes a PNG to Screenshots/.
// flagExists is read once and cached, so a user card pays a single check and then nothing.
void GFX_maybeScreenshot(void) {
	// Devmode-gated. TWO triggers, both handled here (called from GFX_flip AND GFX_sync, so a static
	// dialog that only flips when dirty, like say.elf / confirm.elf / Optimize CPU, is still reachable
	// while it idles on GFX_sync):
	//   1. L2+R2 held + SELECT tapped: the offline physical trigger. Works with WiFi OFF, so the shot
	//      carries no network icon. L2+R2+SELECT is unbound everywhere and avoids MENU, whose hold
	//      raises the dimmer bar and mutates the very frame you are capturing. (MENU+SELECT was the
	//      first try and was wrong for exactly that reason; a per-binary chord also could not reach
	//      the Tools.) Dan, on-device 2026-09-08.
	//   2. touch /tmp/take_screenshot: the remote/SSH trigger, for scripted capture.
	static int dev = -1;
	if (dev<0) dev = flagExists(DEVMODE_PATH);
	if (!dev) return;
	int triggered = exists(SCREENSHOT_TRIGGER_PATH);
	int combo = PAD_isPressed(BTN_L2) && PAD_isPressed(BTN_R2) && PAD_justPressed(BTN_SELECT);
	if (!triggered && !combo) return;
	if (triggered) unlink(SCREENSHOT_TRIGGER_PATH);
	SDL_Surface* shot = PLAT_captureRendererToSurface();
	if (!shot) { LOG_info("screenshot: this platform has no readable renderer\n"); return; }
	mkdir(SCREENSHOTS_PATH, 0777);
	// name by uptime ticks: unique and sortable without depending on the (possibly wrong) RTC
	char path[512];
	snprintf(path, sizeof(path), "%s/screenshot-%010u.png", SCREENSHOTS_PATH, (unsigned)SDL_GetTicks());
	if (IMG_SavePNG(shot, path)==0) LOG_info("screenshot saved: %s (%dx%d)\n", path, shot->w, shot->h);
	else LOG_error("screenshot save failed: %s\n", IMG_GetError());
	SDL_FreeSurface(shot);
}

FALLBACK_IMPLEMENTATION int PLAT_supportsOverscan(void) { return 0; }
FALLBACK_IMPLEMENTATION void PLAT_setEffectColor(int next_color) { }
FALLBACK_IMPLEMENTATION void PLAT_setCPUMaxFreq(int khz) { } // platforms without a cpufreq cap: no-op
FALLBACK_IMPLEMENTATION int PLAT_supportsUndervolt(void) { return 0; } // undervolt off unless a platform confirms a mechanism
FALLBACK_IMPLEMENTATION void PLAT_setUndervolt(int millivolts) { } // no-op
FALLBACK_IMPLEMENTATION void PLAT_setCPUVoltForCeil(int khz) { } // voltage authority: no-op without a calibrated platform
FALLBACK_IMPLEMENTATION void PLAT_restoreCPUVolt(void) { } // no-op
FALLBACK_IMPLEMENTATION void PLAT_emergencyRestoreCPUVolt(void) { } // no-op
FALLBACK_IMPLEMENTATION void PLAT_uvReassert(void) { } // no-op
FALLBACK_IMPLEMENTATION void PLAT_setSystemRumble(int strength) { PLAT_setRumble(strength); }

int GFX_truncateText(TTF_Font* font, const char* in_name, char* out_name, int max_width, int padding) {
	int text_width;
	strcpy(out_name, in_name);
	TTF_SizeUTF8(font, out_name, &text_width, NULL);
	text_width += padding;
	
	while (text_width>max_width) {
		int len = strlen(out_name);
		strcpy(&out_name[len-4], "...\0");
		TTF_SizeUTF8(font, out_name, &text_width, NULL);
		text_width += padding;
	}
	
	return text_width;
}
int GFX_wrapText(TTF_Font* font, char* str, int max_width, int max_lines) {
	if (!str) return 0;
	
	int line_width;
	int max_line_width = 0;
	char* line = str;
	char buffer[MAX_PATH];
	
	TTF_SizeUTF8(font, line, &line_width, NULL);
	if (line_width<=max_width) {
		line_width = GFX_truncateText(font,line,buffer,max_width,0);
		strcpy(line,buffer);
		return line_width;
	}
	
	char* prev = NULL;
	char* tmp = line;
	int lines = 1;
	int i = 0;
	while (!max_lines || lines<max_lines) {
		tmp = strchr(tmp, ' ');
		if (!tmp) {
			if (prev) {
				TTF_SizeUTF8(font, line, &line_width, NULL);
				if (line_width>=max_width) {
					if (line_width>max_line_width) max_line_width = line_width;
					prev[0] = '\n';
					line = prev + 1;
				}
			}
			break;
		}
		tmp[0] = '\0';
		
		TTF_SizeUTF8(font, line, &line_width, NULL);

		if (line_width>=max_width) { // wrap
			if (line_width>max_line_width) max_line_width = line_width;
			tmp[0] = ' ';
			tmp += 1;
			prev[0] = '\n';
			prev += 1;
			line = prev;
			lines += 1;
		}
		else { // continue
			tmp[0] = ' ';
			prev = tmp;
			tmp += 1;
		}
		i += 1;
	}
	
	line_width = GFX_truncateText(font,line,buffer,max_width,0);
	strcpy(line,buffer);
	
	if (line_width>max_line_width) max_line_width = line_width;
	return max_line_width;
}

///////////////////////////////

// scale_blend (and supporting logic) from picoarch

struct blend_args {
	int w_ratio_in;
	int w_ratio_out;
	uint16_t w_bp[2];
	int h_ratio_in;
	int h_ratio_out;
	uint16_t h_bp[2];
	uint16_t *blend_line;
} blend_args;

// ARM32-only asm (rrx, movcs, conditional adds): __ARM_ARCH is also >=5 on AArch64, where these
// mnemonics do not exist, so the guard must exclude it or the macOS (Apple Silicon) dev-loop
// build breaks at compile. AArch64 takes the portable C below, which clang vectorizes fine.
#if __ARM_ARCH >= 5 && !defined(__aarch64__)
static inline uint32_t average16(uint32_t c1, uint32_t c2) {
	uint32_t ret, lowbits = 0x0821;
	asm ("eor %0, %2, %3\r\n"
	     "and %0, %0, %1\r\n"
	     "add %0, %3, %0\r\n"
	     "add %0, %0, %2\r\n"
	     "lsr %0, %0, #1\r\n"
	     : "=&r" (ret) : "r" (lowbits), "r" (c1), "r" (c2) : );
	return ret;
}
static inline uint32_t average32(uint32_t c1, uint32_t c2) {
	uint32_t ret, lowbits = 0x08210821;

	asm ("eor %0, %3, %1\r\n"
	     "and %0, %0, %2\r\n"
	     "adds %0, %1, %0\r\n"
	     "and %1, %1, #0\r\n"
	     "movcs %1, #0x80000000\r\n"
	     "adds %0, %0, %3\r\n"
	     "rrx %0, %0\r\n"
	     "orr %0, %0, %1\r\n"
	     : "=&r" (ret), "+r" (c2) : "r" (lowbits), "r" (c1) : "cc" );

	return ret;
}

#define AVERAGE16_NOCHK(c1, c2) (average16((c1), (c2)))
#define AVERAGE32_NOCHK(c1, c2) (average32((c1), (c2)))

#else

static inline uint32_t average16(uint32_t c1, uint32_t c2) {
	return (c1 + c2 + ((c1 ^ c2) & 0x0821))>>1;
}
static inline uint32_t average32(uint32_t c1, uint32_t c2) {
	uint32_t sum = c1 + c2;
	uint32_t ret = sum + ((c1 ^ c2) & 0x08210821);
	uint32_t of = ((sum < c1) | (ret < sum)) << 31;

	return (ret >> 1) | of;
}

#define AVERAGE16_NOCHK(c1, c2) (average16((c1), (c2)))
#define AVERAGE32_NOCHK(c1, c2) (average32((c1), (c2)))

#endif

#define AVERAGE16(c1, c2) ((c1) == (c2) ? (c1) : AVERAGE16_NOCHK((c1), (c2)))
#define AVERAGE16_1_3(c1, c2) ((c1) == (c2) ? (c1) : (AVERAGE16_NOCHK(AVERAGE16_NOCHK((c1), (c2)), (c2))))

#define AVERAGE32(c1, c2) ((c1) == (c2) ? (c1) : AVERAGE32_NOCHK((c1), (c2)))
#define AVERAGE32_1_3(c1, c2) ((c1) == (c2) ? (c1) : (AVERAGE32_NOCHK(AVERAGE32_NOCHK((c1), (c2)), (c2))))

static inline int gcd(int a, int b) {
	return b ? gcd(b, a % b) : a;
}

static void scaleAA(void* __restrict src, void* __restrict dst, uint32_t w, uint32_t h, uint32_t pitch, uint32_t dst_w, uint32_t dst_h, uint32_t dst_p) {
	int dy = 0;
	int lines = h;

	int rat_w = blend_args.w_ratio_in;
	int rat_dst_w = blend_args.w_ratio_out;
	uint16_t *bw = blend_args.w_bp;

	int rat_h = blend_args.h_ratio_in;
	int rat_dst_h = blend_args.h_ratio_out;
	uint16_t *bh = blend_args.h_bp;

	while (lines--) {
		while (dy < rat_dst_h) {
			uint16_t *dst16 = (uint16_t *)dst;
			uint16_t *pblend = (uint16_t *)blend_args.blend_line;
			int col = w;
			int dx = 0;

			uint16_t *pnext = (uint16_t *)(src + pitch);
			if (!lines)
				pnext -= (pitch / sizeof(uint16_t));

			if (dy > rat_dst_h - bh[0]) {
				pblend = pnext;
			} else if (dy <= bh[0]) {
				/* Drops const, won't get touched later though */
				pblend = (uint16_t *)src;
			} else {
				const uint32_t *src32 = (const uint32_t *)src;
				const uint32_t *pnext32 = (const uint32_t *)pnext;
				uint32_t *pblend32 = (uint32_t *)pblend;
				int count = w / 2;

				if (dy <= bh[1]) {
					const uint32_t *tmp = pnext32;
					pnext32 = src32;
					src32 = tmp;
				}

				if (dy > rat_dst_h - bh[1] || dy <= bh[1]) {
					while(count--) {
						*pblend32++ = AVERAGE32_1_3(*src32, *pnext32);
						src32++;
						pnext32++;
					}
				} else {
					while(count--) {
						*pblend32++ = AVERAGE32(*src32, *pnext32);
						src32++;
						pnext32++;
					}
				}
			}

			while (col--) {
				uint16_t a, b, out;

				a = *pblend;
				b = *(pblend+1);

				while (dx < rat_dst_w) {
					if (a == b) {
						out = a;
					} else if (dx > rat_dst_w - bw[0]) { // top quintile, bbbb
						out = b;
					} else if (dx <= bw[0]) { // last quintile, aaaa
						out = a;
					} else {
						if (dx > rat_dst_w - bw[1]) { // 2nd quintile, abbb
							a = AVERAGE16_NOCHK(a,b);
						} else if (dx <= bw[1]) { // 4th quintile, aaab
							b = AVERAGE16_NOCHK(a,b);
						}

						out = AVERAGE16_NOCHK(a, b); // also 3rd quintile, aabb
					}
					*dst16++ = out;
					dx += rat_w;
				}

				dx -= rat_dst_w;
				pblend++;
			}

			dy += rat_h;
			dst += dst_p;
		}

		dy -= rat_dst_h;
		src += pitch;
	}
}

scaler_t GFX_getAAScaler(GFX_Renderer* renderer) {
	int gcd_w, div_w, gcd_h, div_h;
	blend_args.blend_line = calloc(renderer->src_w, sizeof(uint16_t));

	gcd_w = gcd(renderer->src_w, renderer->dst_w);
	blend_args.w_ratio_in = renderer->src_w / gcd_w;
	blend_args.w_ratio_out = renderer->dst_w / gcd_w;
	
	double blend_denominator = (renderer->src_w>renderer->dst_w) ? 5 : 2.5; // TODO: these values are really only good for the nano...
	// blend_denominator = 5.0; // better for trimui
	// LOG_info("blend_denominator: %f (%i && %i)\n", blend_denominator, HAS_SKINNY_SCREEN, renderer->dst_w>renderer->src_w);
	
	div_w = round(blend_args.w_ratio_out / blend_denominator);
	blend_args.w_bp[0] = div_w;
	blend_args.w_bp[1] = blend_args.w_ratio_out >> 1;

	gcd_h = gcd(renderer->src_h, renderer->dst_h);
	blend_args.h_ratio_in = renderer->src_h / gcd_h;
	blend_args.h_ratio_out = renderer->dst_h / gcd_h;

	div_h = round(blend_args.h_ratio_out / blend_denominator);
	blend_args.h_bp[0] = div_h;
	blend_args.h_bp[1] = blend_args.h_ratio_out >> 1;
	
	return scaleAA;
}
void GFX_freeAAScaler(void) {
	if (blend_args.blend_line != NULL) {
		free(blend_args.blend_line);
		blend_args.blend_line = NULL;
	}
}

///////////////////////////////

void GFX_blitAsset(int asset, SDL_Rect* src_rect, SDL_Surface* dst, SDL_Rect* dst_rect) {
	SDL_Rect* rect = &asset_rects[asset];
	SDL_Rect adj_rect = {
		.x = rect->x,
		.y = rect->y,
		.w = rect->w,
		.h = rect->h,
	};
	if (src_rect) {
		adj_rect.x += src_rect->x;
		adj_rect.y += src_rect->y;
		adj_rect.w  = src_rect->w;
		adj_rect.h  = src_rect->h;
	}
	SDL_BlitSurface(gfx.assets, &adj_rect, dst, dst_rect);
}
void GFX_blitPill(int asset, SDL_Surface* dst, SDL_Rect* dst_rect) {
	int x = dst_rect->x;
	int y = dst_rect->y;
	int w = dst_rect->w;
	int h = dst_rect->h;

	if (h==0) h = asset_rects[asset].h;
	
	// The two caps must ACCOUNT FOR EVERY COLUMN of h, which h/2 twice does not when h is odd:
	// at the Brick Pro's 2.5x a pill is 75px, both caps came out 37, and the pill rendered a pixel
	// narrow with the right cap's outermost column dropped from the sheet. Give the odd pixel to
	// the right cap so rl+rr==h and the two source spans tile [0,h) exactly. For even h
	// rr==rl==h/2 and this is the same code it always was. One integer-scale asset is odd and
	// deliberately CHANGES with this: ASSET_UNDERLINE (3 logical units) is 9px on the Brick at
	// 3x, and its right cap now includes the final anti-aliased sprite column that h/2+h/2 was
	// dropping (Clock tool only; every other pill asset is even at every integer scale).
	int rl = h / 2;
	int rr = h - rl;
	if (w < h) w = h;
	w -= h;
	
	GFX_blitAsset(asset, &(SDL_Rect){0,0,rl,h}, dst, &(SDL_Rect){x,y});
	x += rl;
	if (w>0) {
		SDL_FillRect(dst, &(SDL_Rect){x,y,w,h}, asset_rgbs[asset]);
		x += w;
	}
	GFX_blitAsset(asset, &(SDL_Rect){rl,0,rr,h}, dst, &(SDL_Rect){x,y});
}
void GFX_blitRect(int asset, SDL_Surface* dst, SDL_Rect* dst_rect) {
	int x = dst_rect->x;
	int y = dst_rect->y;
	int w = dst_rect->w;
	int h = dst_rect->h;
	int c = asset_rgbs[asset];
	
	SDL_Rect* rect = &asset_rects[asset];
	int d = rect->w;
	int r = d / 2;

	GFX_blitAsset(asset, &(SDL_Rect){0,0,r,r}, dst, &(SDL_Rect){x,y});
	SDL_FillRect(dst, &(SDL_Rect){x+r,y,w-d,r}, c);
	GFX_blitAsset(asset, &(SDL_Rect){r,0,r,r}, dst, &(SDL_Rect){x+w-r,y});
	SDL_FillRect(dst, &(SDL_Rect){x,y+r,w,h-d}, c);
	GFX_blitAsset(asset, &(SDL_Rect){0,r,r,r}, dst, &(SDL_Rect){x,y+h-r});
	SDL_FillRect(dst, &(SDL_Rect){x+r,y+h-r,w-d,r}, c);
	GFX_blitAsset(asset, &(SDL_Rect){r,r,r,r}, dst, &(SDL_Rect){x+w-r,y+h-r});
}
void GFX_blitBattery(SDL_Surface* dst, SDL_Rect* dst_rect) {
	// LOG_info("dst: %p\n", dst);
	int x = 0;
	int y = 0;
	if (dst_rect) {
		x = dst_rect->x;
		y = dst_rect->y;
	}
	SDL_Rect rect = asset_rects[ASSET_BATTERY];
	x += (SCALE1(PILL_SIZE) - (rect.w + SCALE1(1))) / 2;
	y += (SCALE1(PILL_SIZE) - rect.h) / 2;
	
	if (pwr.is_charging) {
		GFX_blitAsset(ASSET_BATTERY, NULL, dst, &(SDL_Rect){x,y});

		// Bolt only, no level fill — same as upstream, and it is not an oversight.
		//
		// ASSET_BATTERY_BOLT is a KNOCKOUT: an opaque 12x6 block with the bolt shape punched out as
		// transparency, so the bolt you see is the background showing through. It is the exact same
		// 12x6 rect as ASSET_BATTERY_FILL, so it covers any fill drawn beneath it completely — and
		// where it does not cover (the punched-out bolt), a white fill underneath shows through and
		// erases the bolt instead. Drawing both gives a featureless block, not a level + a bolt.
		// (That is what the charging Miyoo photo showed when this branch briefly drew the fill.)
		//
		// Showing level AND charge state in the same 12x6 needs a bolt asset that can be told apart
		// from the fill. Until that asset exists the bolt alone is the honest signal: it answers the
		// question the icon is actually asked while a cable is attached, at every level. The charge
		// screen (ChargingScreen / batmon) is where the number lives.
		GFX_blitAsset(ASSET_BATTERY_BOLT, NULL, dst, &(SDL_Rect){x+SCALE1(3),y+SCALE1(2)});
	}
	else {
		// Discharging path deliberately UNCHANGED.
		int percent = pwr.charge;
		GFX_blitAsset(percent<=10?ASSET_BATTERY_LOW:ASSET_BATTERY, NULL, dst, &(SDL_Rect){x,y});

		rect = asset_rects[ASSET_BATTERY_FILL];
		SDL_Rect clip = rect;
		clip.w *= percent;
		clip.w /= 100;
		if (clip.w<=0) return;
		clip.x = rect.w - clip.w;
		clip.y = 0;

		GFX_blitAsset(percent<=20?ASSET_BATTERY_FILL_LOW:ASSET_BATTERY_FILL, &clip, dst, &(SDL_Rect){x+SCALE1(3)+clip.x,y+SCALE1(2)});
	}
}
int GFX_getButtonWidth(char* hint, char* button) {
	int button_width = 0;
	int width;
	
	int special_case = !strcmp(button,BRIGHTNESS_BUTTON_LABEL); // TODO: oof
	
	if (strlen(button)==1) {
		button_width += SCALE1(BUTTON_SIZE);
	}
	else {
		button_width += SCALE1(BUTTON_SIZE) / 2;
		TTF_SizeUTF8(special_case ? font.large : font.tiny, button, &width, NULL);
		button_width += width;
	}
	button_width += SCALE1(BUTTON_MARGIN);
	
	TTF_SizeUTF8(font.small, hint, &width, NULL);
	button_width += width + SCALE1(BUTTON_MARGIN);
	return button_width;
}
void GFX_blitButton(char* hint, char*button, SDL_Surface* dst, SDL_Rect* dst_rect) {
	SDL_Surface* text;
	int ox = 0;
	
	int special_case = !strcmp(button,BRIGHTNESS_BUTTON_LABEL); // TODO: oof
	
	// button
	if (strlen(button)==1) {
		GFX_blitAsset(ASSET_BUTTON, NULL, dst, dst_rect);

		// label
		text = TTF_RenderUTF8_Blended(font.medium, button, COLOR_BUTTON_TEXT);
		SDL_BlitSurface(text, NULL, dst, &(SDL_Rect){dst_rect->x+(SCALE1(BUTTON_SIZE)-text->w)/2,dst_rect->y+(SCALE1(BUTTON_SIZE)-text->h)/2});
		ox += SCALE1(BUTTON_SIZE);
		SDL_FreeSurface(text);
	}
	else {
		text = TTF_RenderUTF8_Blended(special_case ? font.large : font.tiny, button, COLOR_BUTTON_TEXT);
		GFX_blitPill(ASSET_BUTTON, dst, &(SDL_Rect){dst_rect->x,dst_rect->y,SCALE1(BUTTON_SIZE)/2+text->w,SCALE1(BUTTON_SIZE)});
		ox += SCALE1(BUTTON_SIZE)/4;
		
		int oy = special_case ? -SCALE1(2) : 0; // scale the magnitude: SCALE1's +DEN/2 rounds the wrong way below zero
		SDL_BlitSurface(text, NULL, dst, &(SDL_Rect){ox+dst_rect->x,oy+dst_rect->y+(SCALE1(BUTTON_SIZE)-text->h)/2,text->w,text->h});
		ox += text->w;
		ox += SCALE1(BUTTON_SIZE)/4;
		SDL_FreeSurface(text);
	}
	
	ox += SCALE1(BUTTON_MARGIN);

	// hint text
	text = TTF_RenderUTF8_Blended(font.small, hint, COLOR_WHITE);
	SDL_BlitSurface(text, NULL, dst, &(SDL_Rect){ox+dst_rect->x,dst_rect->y+(SCALE1(BUTTON_SIZE)-text->h)/2,text->w,text->h});
	SDL_FreeSurface(text);
}
void GFX_blitMessage(TTF_Font* font, char* msg, SDL_Surface* dst, SDL_Rect* dst_rect) {
	if (!dst_rect) dst_rect = &(SDL_Rect){0,0,dst->w,dst->h};
	
	// LOG_info("GFX_blitMessage: %p (%ix%i)", dst, dst_rect->w,dst_rect->h);
	
	SDL_Surface* text;
#define TEXT_BOX_MAX_ROWS 16
#define LINE_HEIGHT 24
	char* rows[TEXT_BOX_MAX_ROWS];
	int row_count = 0;

	char* tmp;
	rows[row_count++] = msg;
	while ((tmp=strchr(rows[row_count-1], '\n'))!=NULL) {
		if (row_count+1>=TEXT_BOX_MAX_ROWS) return; // TODO: bail
		rows[row_count++] = tmp+1;
	}
	
	int rendered_height = SCALE1(LINE_HEIGHT) * row_count;
	int y = dst_rect->y;
	y += (dst_rect->h - rendered_height) / 2;
	
	char line[256];
	for (int i=0; i<row_count; i++) {
		int len;
		if (i+1<row_count) {
			len = rows[i+1]-rows[i]-1;
			if (len) strncpy(line, rows[i], len);
			line[len] = '\0';
		}
		else {
			len = strlen(rows[i]);
			strcpy(line, rows[i]);
		}
		
		
		if (len) {
			text = TTF_RenderUTF8_Blended(font, line, COLOR_WHITE);
			int x = dst_rect->x;
			x += (dst_rect->w - text->w) / 2;
			SDL_BlitSurface(text, NULL, dst, &(SDL_Rect){x,y});
			SDL_FreeSurface(text);
		}
		y += SCALE1(LINE_HEIGHT);
	}
}

int GFX_blitHardwareGroup(SDL_Surface* dst, int show_setting) {
	int ox;
	int oy;
	int ow = 0;
	
	int setting_value;
	int setting_min;
	int setting_max;
	
	if (show_setting && !GetHDMI()) {
		ow = SCALE1(PILL_SIZE + SETTINGS_WIDTH + 10 + 4);
		ox = dst->w - SCALE1(PADDING) - ow;
		oy = SCALE1(PADDING);
		GFX_blitPill(gfx.mode==MODE_MAIN ? ASSET_DARK_GRAY_PILL : ASSET_BLACK_PILL, dst, &(SDL_Rect){
			ox,
			oy,
			ow,
			SCALE1(PILL_SIZE)
		});
		
		if (show_setting==1) {
			setting_value = GetBrightness();
			setting_min = BRIGHTNESS_MIN;
			setting_max = BRIGHTNESS_MAX;
		}
		else {
			setting_value = GetVolume();
			setting_min = VOLUME_MIN;
			setting_max = VOLUME_MAX;
		}
		
		int asset = show_setting==1?ASSET_BRIGHTNESS:(setting_value>0?ASSET_VOLUME:ASSET_VOLUME_MUTE);
		int ax = ox + (show_setting==1 ? SCALE1(6) : SCALE1(8));
		int ay = oy + (show_setting==1 ? SCALE1(5) : SCALE1(7));
		GFX_blitAsset(asset, NULL, dst, &(SDL_Rect){ax,ay});
		
		ox += SCALE1(PILL_SIZE);
		oy += SCALE1((PILL_SIZE - SETTINGS_SIZE) / 2);
		GFX_blitPill(gfx.mode==MODE_MAIN ? ASSET_BAR_BG : ASSET_BAR_BG_MENU, dst, &(SDL_Rect){
			ox,
			oy,
			SCALE1(SETTINGS_WIDTH),
			SCALE1(SETTINGS_SIZE)
		});
		
		float percent = ((float)(setting_value-setting_min) / (setting_max-setting_min));
		if (show_setting==1 || setting_value>0) {
			GFX_blitPill(ASSET_BAR, dst, &(SDL_Rect){
				ox,
				oy,
				SCALE1(SETTINGS_WIDTH) * percent,
				SCALE1(SETTINGS_SIZE)
			});
		}
	}
	else {
		// TODO: handle wifi
		int show_wifi = PLAT_isOnline(); // NOOOOO! not every frame!

		int ww = SCALE1(PILL_SIZE-3);

		// Opt-in menu clock (Clock tool toggle). ZERO-SHIFT layout: the clock is at the FAR RIGHT of
		// the pill with monospaced digits, and WiFi is drawn LEFTMOST so toggling it grows the pill
		// leftward, never touching the clock. Each digit sits in a fixed cell. The pill width tracks
		// the hour's digit count, and because a wider hour grows the pill leftward by exactly one
		// cell, the colon, minutes and AM/PM keep the SAME absolute position every minute AND across
		// the 9->10 / 12->1 rollovers — so the part that ticks never moves. No leading blank cell, so
		// the spacing stays tight.
		int show_clock = exists(SHOW_CLOCK_PATH);
		int clock_24h = exists(USERDATA_PATH "/show_24hour"); // the Clock tool's existing preference
		static int cellw=0, colonw=0, spacew=0, apw=0, glyphh=0; // monospace metrics, measured once
		if (show_clock && !cellw) {
			for (char d='0'; d<='9'; d++) { char s1[2]={d,0}; SDL_Surface* g=TTF_RenderUTF8_Blended(font.tiny,s1,COLOR_WHITE); if(g){ if(g->w>cellw)cellw=g->w; glyphh=g->h; SDL_FreeSurface(g);} }
			SDL_Surface* c=TTF_RenderUTF8_Blended(font.tiny,":",COLOR_WHITE); if(c){colonw=c->w; SDL_FreeSurface(c);}
			SDL_Surface* sp=TTF_RenderUTF8_Blended(font.tiny," ",COLOR_WHITE); if(sp){spacew=sp->w; SDL_FreeSurface(sp);}
			SDL_Surface* am=TTF_RenderUTF8_Blended(font.tiny,"AM",COLOR_WHITE); if(am){apw=am->w; SDL_FreeSurface(am);}
			SDL_Surface* pm=TTF_RenderUTF8_Blended(font.tiny,"PM",COLOR_WHITE); if(pm){ if(pm->w>apw)apw=pm->w; SDL_FreeSurface(pm);}
		}
		int hh=0, mm=0, is_pm=0, disp_h=0, hdig=2, cw=0;
		if (show_clock) {
			time_t clock_time = time(NULL);
			struct tm* clock_tm = localtime(&clock_time);
			hh = clock_tm->tm_hour; mm = clock_tm->tm_min; is_pm = hh>=12;
			disp_h = clock_24h ? hh : (hh%12==0 ? 12 : hh%12);
			hdig = (clock_24h || disp_h>=10) ? 2 : 1;
			cw = hdig*cellw + colonw + 2*cellw;   // H(H):MM in fixed cells
			if (!clock_24h) cw += spacew + apw;   // + " AM"/" PM"
			cw += SCALE1(3) + SCALE1(8);          // left gap (tight) + right gap (room before the pill edge)
		}

		ow = (show_wifi ? ww : 0) + SCALE1(PILL_SIZE) + (show_clock ? cw : 0);
		ox = dst->w - SCALE1(PADDING) - ow;
		oy = SCALE1(PADDING);
		GFX_blitPill(gfx.mode==MODE_MAIN ? ASSET_DARK_GRAY_PILL : ASSET_BLACK_PILL, dst, &(SDL_Rect){
			ox,
			oy,
			ow,
			SCALE1(PILL_SIZE)
		});

		// WiFi first (leftmost) — its presence only changes the LEFT extent of the pill.
		if (show_wifi) {
			SDL_Rect rect = asset_rects[ASSET_WIFI];
			GFX_blitAsset(ASSET_WIFI, NULL, dst, &(SDL_Rect){
				ox + (SCALE1(PILL_SIZE) - rect.w) / 2,
				oy + (SCALE1(PILL_SIZE) - rect.h) / 2
			});
			ox += ww;
		}
		// Battery, then the clock at the far right (monospaced, tight left, room on the right).
		GFX_blitBattery(dst, &(SDL_Rect){ox,oy});
		ox += SCALE1(PILL_SIZE);
		if (show_clock) {
			int cx = ox + SCALE1(3);
			int cy = oy + (SCALE1(PILL_SIZE) - glyphh) / 2;
			char cb[3];
			#define CLK_DIGIT(D) do { cb[0]='0'+(D); cb[1]=0; SDL_Surface* g=TTF_RenderUTF8_Blended(font.tiny,cb,COLOR_WHITE); if(g){ SDL_BlitSurface(g,NULL,dst,&(SDL_Rect){cx+(cellw-g->w)/2,cy}); SDL_FreeSurface(g);} cx+=cellw; } while(0)
			#define CLK_TEXT(S,W) do { SDL_Surface* g=TTF_RenderUTF8_Blended(font.tiny,(S),COLOR_WHITE); if(g){ SDL_BlitSurface(g,NULL,dst,&(SDL_Rect){cx+((W)-g->w)/2,cy}); SDL_FreeSurface(g);} cx+=(W); } while(0)
			if (hdig==2) CLK_DIGIT(disp_h/10);
			CLK_DIGIT(disp_h%10);
			CLK_TEXT(":", colonw);
			CLK_DIGIT(mm/10);
			CLK_DIGIT(mm%10);
			if (!clock_24h) { cx += spacew; CLK_TEXT(is_pm?"PM":"AM", apw); }
			#undef CLK_DIGIT
			#undef CLK_TEXT
		}
	}

	return ow;
}
void GFX_blitHardwareHints(SDL_Surface* dst, int show_setting) {
	if (BTN_MOD_VOLUME==BTN_SELECT && BTN_MOD_BRIGHTNESS==BTN_START) {
		if (show_setting==1) GFX_blitButtonGroup((char*[]){ "SELECT","VOLUME",  NULL }, 0, dst, 0);
		else GFX_blitButtonGroup((char*[]){ "START","BRIGHTNESS",  NULL }, 0, dst, 0);
	}
	else {
		if (show_setting==1) GFX_blitButtonGroup((char*[]){ BRIGHTNESS_BUTTON_LABEL,"BRIGHTNESS",  NULL }, 0, dst, 0);
		else GFX_blitButtonGroup((char*[]){ "MENU","BRIGHTNESS",  NULL }, 0, dst, 0);
	}
	
}

int GFX_blitButtonGroup(char** pairs, int primary, SDL_Surface* dst, int align_right) {
	int ox;
	int oy;
	int ow;
	char* hint;
	char* button;

	struct Hint {
		char* hint;
		char* button;
		int ow;
	} hints[2]; 
	int w = 0; // individual button dimension
	int h = 0; // hints index
	ow = 0; // full pill width
	ox = align_right ? dst->w - SCALE1(PADDING) : SCALE1(PADDING);
	oy = dst->h - SCALE1(PADDING + PILL_SIZE);
	
	for (int i=0; i<2; i++) {
		if (!pairs[i*2]) break;
		if (HAS_SKINNY_SCREEN && i!=primary) continue; // space saving
		
		button = pairs[i * 2];
		hint = pairs[i * 2 + 1];
		w = GFX_getButtonWidth(hint, button);
		hints[h].hint = hint;
		hints[h].button = button;
		hints[h].ow = w;
		h += 1;
		ow += SCALE1(BUTTON_MARGIN) + w;
	}
	
	ow += SCALE1(BUTTON_MARGIN);
	if (align_right) ox -= ow;
	GFX_blitPill(gfx.mode==MODE_MAIN ? ASSET_DARK_GRAY_PILL : ASSET_BLACK_PILL, dst, &(SDL_Rect){
		ox,
		oy,
		ow,
		SCALE1(PILL_SIZE)
	});
	
	ox += SCALE1(BUTTON_MARGIN);
	oy += SCALE1(BUTTON_MARGIN);
	for (int i=0; i<h; i++) {
		GFX_blitButton(hints[i].hint, hints[i].button, dst, &(SDL_Rect){ox,oy});
		ox += hints[i].ow + SCALE1(BUTTON_MARGIN);
	}
	return ow;
}

#define MAX_TEXT_LINES 16
void GFX_sizeText(TTF_Font* font, char* str, int leading, int* w, int* h) {
	char* lines[MAX_TEXT_LINES];
	int count = 0;

	char* tmp;
	lines[count++] = str;
	while ((tmp=strchr(lines[count-1], '\n'))!=NULL) {
		if (count+1>MAX_TEXT_LINES) break; // TODO: bail?
		lines[count++] = tmp+1;
	}
	*h = count * leading;
	
	int mw = 0;
	char line[256];
	for (int i=0; i<count; i++) {
		int len;
		if (i+1<count) {
			len = lines[i+1]-lines[i]-1;
			if (len) strncpy(line, lines[i], len);
			line[len] = '\0';
		}
		else {
			len = strlen(lines[i]);
			strcpy(line, lines[i]);
		}
		
		if (len) {
			int lw;
			TTF_SizeUTF8(font, line, &lw, NULL);
			if (lw>mw) mw = lw;
		}
	}
	*w = mw;
}
void GFX_blitText(TTF_Font* font, char* str, int leading, SDL_Color color, SDL_Surface* dst, SDL_Rect* dst_rect) {
	if (dst_rect==NULL) dst_rect = &(SDL_Rect){0,0,dst->w,dst->h};
	
	char* lines[MAX_TEXT_LINES];
	int count = 0;

	char* tmp;
	lines[count++] = str;
	while ((tmp=strchr(lines[count-1], '\n'))!=NULL) {
		if (count+1>MAX_TEXT_LINES) break; // TODO: bail?
		lines[count++] = tmp+1;
	}
	int x = dst_rect->x;
	int y = dst_rect->y;
	
	SDL_Surface* text;
	char line[256];
	for (int i=0; i<count; i++) {
		int len;
		if (i+1<count) {
			len = lines[i+1]-lines[i]-1;
			if (len) strncpy(line, lines[i], len);
			line[len] = '\0';
		}
		else {
			len = strlen(lines[i]);
			strcpy(line, lines[i]);
		}
		
		if (len) {
			text = TTF_RenderUTF8_Blended(font, line, color);
			SDL_BlitSurface(text, NULL, dst, &(SDL_Rect){x+((dst_rect->w-text->w)/2),y+(i*leading)});
			SDL_FreeSurface(text);
		}
	}
}

///////////////////////////////

// based on picoarch's audio 
// implementation, rewritten 
// to (try to) understand it 
// better

#define MAX_SAMPLE_RATE 48000
#define BATCH_SIZE 100
#ifndef SAMPLES
	#define SAMPLES 512 // default
#endif

#define ms SDL_GetTicks

typedef int (*SND_Resampler)(const SND_Frame frame);
static struct SND_Context {
	int initialized;
	double frame_rate;
	
	int sample_rate_in;
	int sample_rate_in_adj; // sample_rate_in scaled by the DRC ratio (== _in when DRC off)
	int sample_rate_out;
	int rate_adjust_ppm;    // dynamic rate control: pace the core to the panel's true rate
	
	int buffer_seconds;     // current_audio_buffer_size
	int ring_override_ms;   // MINARCH_SND_RING_MS: ring capacity in DAC-output milliseconds (0 = default sizing)
	atomic_int paused;      // device closed for sleep: producers drop instead of waiting. Atomic:
	                        // the entry guard reads it pre-lock and a future concurrent CORE
	                        // producer must not race SND_pause/SND_resume (review r3)
	int prefilling;         // DAC gated until the ring is ~70% full (from NextUI: starting
	                        // on an empty ring guarantees startup underruns — the choppy
	                        // logo/demo audio on PS1, ear-found 2026-07-08)
	SND_Frame* buffer;		// buf
	size_t frame_count; 	// buf_len
	
	int frame_in;     // buf_w
	int frame_out;    // buf_r
	int frame_filled; // max_buf_w
	// Audio-health counters are consumed by MAIN and the depth-2 CORE work sampler.
	// Atomics keep telemetry and governor timing defined without taking the DAC lock.
	_Atomic long underruns;
	_Atomic long overruns;
	_Atomic long wait_ms;
	_Atomic uint32_t wait_us; // same waits, us precision, WRAP-SAFE — see SND_Stats in api.h

	int resample_diff;
	SND_Frame resample_prev;
	FFAudioRate ff_rate;
	int ff_active;
	int ff_audible;
	
	SND_Resampler resample;
} snd = {0};
static _Atomic int snd_ff_nonblock = 0;
static void SND_publishOccupancy(void); // defined with the ring helpers below
// Event-driven producer backpressure: SND_batchSamples waits here (never while holding
// the SDL audio lock) and the callback signals freed capacity once per consume pass.
// The generation counter closes the signal-before-wait race window.
static pthread_mutex_t snd_space_mx = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t snd_space_cv = PTHREAD_COND_INITIALIZER;
static unsigned snd_space_gen = 0;
static void SND_signalSpace(void) {
	pthread_mutex_lock(&snd_space_mx);
	snd_space_gen++;
	pthread_cond_broadcast(&snd_space_cv);
	pthread_mutex_unlock(&snd_space_mx);
}

static void SND_audioCallback(void* userdata, uint8_t* stream, int len) { // plat_sound_callback
	
	// return (void)memset(stream,0,len); // TODO: tmp, silent
	
	if (snd.frame_count==0) return;
	
	int16_t *out = (int16_t *)stream;
	len /= (sizeof(int16_t) * 2);
	// int full_len = len;
	
	// if (snd.frame_out!=snd.frame_in) LOG_info("%8i consuming samples (%i frames)\n", ms(), len);
	
	while (snd.frame_out!=snd.frame_in && len>0) {
		*out++ = snd.buffer[snd.frame_out].left;
		*out++ = snd.buffer[snd.frame_out].right;
		
		snd.frame_filled = snd.frame_out;
		
		snd.frame_out += 1;
		len -= 1;

		if (snd.frame_out>=snd.frame_count) snd.frame_out = 0;
	}
	SND_publishOccupancy(); // consumer side of the presentation-drop snapshot
	SND_signalSpace(); // wake a producer blocked on a full ring

	if (len>0) atomic_fetch_add_explicit(&snd.underruns, 1, memory_order_relaxed); // ring drained before the request was filled (audible crackle)
	int zero = len>0 && len==SAMPLES;
	if (zero) return (void)memset(out,0,len*(sizeof(int16_t) * 2));
	// else if (len>=5) LOG_info("%8i BUFFER UNDERRUN (%i/%i frames)\n", ms(), len,full_len);

	int16_t *in = out-1;
	while (len>0) {
		*out++ = (void*)in>(void*)stream ? *--in : 0;
		*out++ = (void*)in>(void*)stream ? *--in : 0;
		len -= 1;
	}
}
static void SND_resizeBuffer(void) { // plat_sound_resize_buffer
	size_t old_frame_count = snd.frame_count;
	size_t new_frame_count = snd.buffer_seconds * snd.sample_rate_in / snd.frame_rate;
	if (snd.ring_override_ms > 0 && snd.sample_rate_out > 0) {
		// capacity requested in wall-clock ms: the ring holds output-rate frames
		new_frame_count = (size_t)snd.ring_override_ms * snd.sample_rate_out / 1000;
		LOG_info("SND ring capacity override: %dms (%zu frames at %dHz out)\n",
			snd.ring_override_ms, new_frame_count, snd.sample_rate_out);
	}
	if (new_frame_count==0) return;
	
	// LOG_info("frame_count: %i (%i * %i / %f)\n", snd.frame_count, snd.buffer_seconds, snd.sample_rate_in, snd.frame_rate);
	// snd.frame_count *= 2; // no help
	
	SDL_LockAudio();
	
	int buffer_bytes = new_frame_count * sizeof(SND_Frame);
	void* grown = realloc(snd.buffer, buffer_bytes);
	if (!grown) { // OOM: keep the old ring (and its old frame_count) rather than crash
		snd.frame_count = snd.buffer ? old_frame_count : 0;
		SDL_UnlockAudio();
		LOG_info("SND_resizeBuffer: realloc(%i) failed, keeping previous ring\n", buffer_bytes);
		return;
	}
	snd.buffer = grown;
	snd.frame_count = new_frame_count;
	memset(snd.buffer, 0, buffer_bytes);
	
	snd.frame_in = 0;
	snd.frame_out = 0;
	snd.frame_filled = snd.frame_count - 1;
	
	SDL_UnlockAudio();
	SND_signalSpace(); // reshaped ring = new space; a waiter must see it (review 5)
}
static int SND_resampleNone(SND_Frame frame) { // audio_resample_passthrough
	snd.buffer[snd.frame_in++] = frame;
	if (snd.frame_in >= snd.frame_count) snd.frame_in = 0;
	return 1;
}
static int SND_resampleNear(SND_Frame frame) { // audio_resample_nearest
	int consumed = 0;

	if (snd.resample_diff < snd.sample_rate_out) {
		snd.buffer[snd.frame_in++] = frame;
		if (snd.frame_in >= snd.frame_count) snd.frame_in = 0;
		snd.resample_diff += snd.sample_rate_in_adj;
	}

	if (snd.resample_diff >= snd.sample_rate_out) {
		consumed++;
		snd.resample_diff -= snd.sample_rate_out;
	}

	return consumed;
}
static int SND_resampleLinear(SND_Frame frame) { // audio_resample_linear
	// Same accumulator scheme as SND_resampleNear, but each output is interpolated
	// between the previous and current input frame instead of duplicated/dropped.
	// Two multiplies per sample — audibly smoother on non-native rates (GBA 32.8kHz,
	// PS1 44.1kHz -> 48kHz) for effectively zero CPU. Sinc/libsamplerate rejected:
	// real CPU cost for fidelity this speaker can't reproduce.
	int consumed = 0;

	if (snd.resample_diff < snd.sample_rate_out) {
		SND_Frame out;
		out.left  = snd.resample_prev.left  + (int16_t)(((int64_t)(frame.left  - snd.resample_prev.left ) * snd.resample_diff) / snd.sample_rate_out);
		out.right = snd.resample_prev.right + (int16_t)(((int64_t)(frame.right - snd.resample_prev.right) * snd.resample_diff) / snd.sample_rate_out);
		snd.buffer[snd.frame_in++] = out;
		if (snd.frame_in >= snd.frame_count) snd.frame_in = 0;
		snd.resample_diff += snd.sample_rate_in_adj;
	}

	if (snd.resample_diff >= snd.sample_rate_out) {
		consumed++;
		snd.resample_diff -= snd.sample_rate_out;
		snd.resample_prev = frame;
	}

	return consumed;
}
static void SND_selectResampler(void) { // plat_sound_select_resampler
	if (snd.sample_rate_in_adj==snd.sample_rate_out) {
		snd.resample =  SND_resampleNone;
	}
	else if (getenv("ZERO_RESAMPLE_NEAR")) { // A/B escape hatch: stock nearest-neighbor
		snd.resample = SND_resampleNear;
	}
	else {
		snd.resample = SND_resampleLinear;
	}
}
static void SND_updateAdjustedRate(void) {
	int64_t adjusted;
	if (atomic_load(&snd_ff_nonblock)) {
		// Fast-forward: the MEASURED multiplier REPLACES the static ratio, it does not compound
		// with it. FFAudioRate_measure is fed the UNADJUSTED snd.sample_rate_in, so rate_q16 is
		// actual-production / nominal and already embodies any static slowdown. Multiplying by
		// (1 + ppm) again oversupplied the DAC by the ratio — ~1.28%, about 613 surplus frames/sec
		// at 48kHz — filling the ring until snd_ff_nonblock discarded chunks, which is exactly the
		// arbitrary dropping the FF resampler exists to avoid. (Adversarial review, 2026-08-01.)
		adjusted = (int64_t)snd.sample_rate_in * snd.ff_rate.rate_q16 / FF_AUDIO_RATE_ONE_Q16;
	}
	else {
		adjusted = (int64_t)snd.sample_rate_in * (1000000 + snd.rate_adjust_ppm) / 1000000;
	}
	if (adjusted < 1) adjusted = 1;
	snd.sample_rate_in_adj = (int)adjusted;
	SND_selectResampler();
}
void SND_setRateAdjustPPM(int ppm) { // dynamic rate control (see minarch drc block)
	snd.rate_adjust_ppm = ppm;
	SND_updateAdjustedRate();
}
// Torn-free ring-occupancy snapshot for the flip path ("presentation-drop catch-up"):
// producer (SND_batchSamples, under SDL_LockAudio) and consumer (SDL callback) each
// publish occupancy into ONE atomic word after moving their index; GFX_flip reads that
// word with an atomic load. Raw frame_in/frame_out reads from the flip path were
// unsynchronized (audit finding). 100 when audio is closed so catch-up can never engage
// against a dead ring.
static volatile int snd_ring_pct = 100;
// Upper 32 bits = ring capacity, lower 32 bits = queued frames. Published wherever
// producer/consumer indices move so SND_getStats never races those plain ring fields.
static _Atomic uint64_t snd_ring_frames = 0;
static volatile uint32_t snd_last_batch_ms = 0; // SDL_GetTicks of the last producer write
static uint32_t SND_lastBatchMs(void) {
	return __atomic_load_n(&snd_last_batch_ms, __ATOMIC_ACQUIRE);
}
static void SND_publishOccupancy(void) {
	int pct = 100;
	uint32_t count = 0;
	uint32_t queued = 0;
	if (snd.initialized && snd.frame_count > 0) {
		int q = snd.frame_in - snd.frame_out;
		if (q < 0) q += snd.frame_count;
		queued = (uint32_t)q;
		count = (uint32_t)snd.frame_count;
		pct = (int)((int64_t)queued * 100 / count);
	}
	atomic_store_explicit(&snd_ring_frames, ((uint64_t)count << 32) | queued,
	                      memory_order_release);
	__atomic_store_n(&snd_ring_pct, pct, __ATOMIC_RELEASE);
}
static int SND_ringPct(void) {
	return __atomic_load_n(&snd_ring_pct, __ATOMIC_ACQUIRE);
}

// FF input arrives faster than the DAC can consume it. Measure that actual production rate
// and drive the existing integer linear resampler at the same multiplier, evenly selecting
// samples instead of filling the ring and dropping arbitrary chunks. Non-blocking overflow
// remains as a safety valve while the first 50ms estimate converges or a core changes speed.
static const char zero_ff_audio_fingerprint[] __attribute__((used)) = "ff-audio";
// Public reprime for pause-like seams (in-game menu close). The DAC keeps consuming while
// the core is parked in Menu_loop, draining the ring to ~0%; resuming against that with the
// prefill gate unarmed made the callback race the producer at sub-frame occupancy for the
// first ~1-2s — partial fills through the mirror-pad path = audible ticks after EVERY menu
// close (confirmed in the 2026-08-31 start-hitch audit; sleep-resume and FF already re-arm,
// this seam never did). Costs the same deliberate ~80ms lead-in silence as launch.
int SND_isPrefilling(void) { return snd.initialized && snd.prefilling; }
static void SND_reprimeLocked(void);
void SND_reprime(void) {
	if (!snd.initialized) return;
	SDL_LockAudio();
	SND_reprimeLocked();
	SDL_UnlockAudio();
}
static void SND_reprimeLocked(void) {
	if (snd.initialized && snd.buffer && snd.frame_count>0) {
		snd.frame_out = snd.frame_in;
		snd.frame_filled = (snd.frame_in + snd.frame_count - 1) % snd.frame_count;
		snd.prefilling = 1;
		SDL_PauseAudio(1);
		SND_publishOccupancy();
	}
}
void SND_setFastForward(int active, int audible) {
	active = active ? 1 : 0;
	audible = active && audible ? 1 : 0;
	if (active == snd.ff_active && audible == snd.ff_audible) return;
	if (!snd.initialized) {
		// Silent fallback after SDL_OpenAudio failure: retain logical mode for callers,
		// but there is no device, producer, or resampler transaction to synchronize.
		snd.ff_active = active;
		snd.ff_audible = audible;
		atomic_store_explicit(&snd_ff_nonblock, 0, memory_order_relaxed);
		return;
	}

	// At depth two MAIN toggles FF while CORE is the audio producer. Serialize every
	// resampler/rate/ring mutation with SND_batchSamples and the DAC callback.
	SDL_LockAudio();
	int was_active = snd.ff_active;
	int was_audible = snd.ff_active && snd.ff_audible;
	int will_be_audible = active && audible;
	snd.ff_active = active;
	snd.ff_audible = audible;
	atomic_store(&snd_ff_nonblock, will_be_audible);

	if (will_be_audible && !was_audible) {
		FFAudioRate_begin(&snd.ff_rate, SDL_GetTicks());
		snd.resample_diff = 0;
		SND_updateAdjustedRate();
	}
	else if (!will_be_audible && was_audible) {
		FFAudioRate_end(&snd.ff_rate);
		snd.resample_diff = 0;
		SND_updateAdjustedRate();
	}

	// Silent FF must pause instead of draining into underruns. Every FF exit discards
	// stale compressed audio and uses the normal 70% prefill gate for a clean handoff.
	if ((active && !audible) || (!active && was_active)) SND_reprimeLocked();
	SDL_UnlockAudio();
	// Wake only after the complete mode/ring transaction is visible. A blocked producer
	// then observes either FF nonblocking mode or the reprime's newly-created space.
	SND_signalSpace();
}
static void SND_measureFastForward(size_t frames) {
	if (!atomic_load(&snd_ff_nonblock)) return;
	if (!FFAudioRate_accumulate(&snd.ff_rate, frames, snd.sample_rate_in)) return;
	if (FFAudioRate_measure(&snd.ff_rate, snd.sample_rate_in, SDL_GetTicks())) {
		SND_updateAdjustedRate();
		static int debug = -1;
		if (debug < 0) {
			const char* env = getenv("ZERO_GOV_DEBUG");
			debug = env && env[0] && env[0] != '0';
		}
		if (debug) LOG_info("ff-audio: measured rate %.2fx\n",
			(double)snd.ff_rate.rate_q16 / FF_AUDIO_RATE_ONE_Q16);
	}
}
// True iff a SND_batchSamples call would actually accept + pace audio (live, unpaused, with a
// usable ring and resampler). SND_batchSamples and SND_isActive share this so they can never
// drift (Codex F2); the field logic lives in snd_pacing.h so it is unit-testable without SND.
static int snd_can_pace(void) {
	return snd_pacing_ok(snd.initialized, atomic_load(&snd.paused), snd.buffer, snd.frame_count, snd.resample != NULL);
}
size_t SND_batchSamples(const SND_Frame* frames, size_t frame_count) { // plat_sound_write / plat_sound_write_resample
	// Libretro expects the number accepted. With no live device/consumer, discard audio
	// rather than filling a preserved ring and blocking the emulation thread forever.
	if (!snd_can_pace()) return frame_count;
	// (paused: device closed for sleep — no consumer exists; writing would only queue
	// stale audio for resume and leave a future concurrent producer waiting on timeouts)
	// return frame_count; // TODO: tmp, silent

	// LOG_info("%8i batching samples (%i frames)\n", ms(), frame_count);

	SDL_LockAudio();
	SND_measureFastForward(frame_count);
	// Hardened (v1.4 audit): the prefill gate reads ring indices + prefilling that the
	// FF->normal drain (SND_setFastForward) mutates under the audio lock — check under the
	// lock too, so a stale read can never unpause the DAC against just-emptied indices.
	// (SDL_PauseAudio under SDL_LockAudio is safe: SDL2's audio mutex is recursive, and the
	// same pattern already ships in SND_setFastForward.)
	if (snd.prefilling) {
		int queued = snd.frame_in - snd.frame_out;
		if (queued < 0) queued += snd.frame_count;
		if (queued >= snd.frame_count * 7 / 10) { // ~70% full: start the DAC — ABOVE the
			// presentation-drop hysteresis band (engage <50, release 66), so playback never
			// BEGINS inside catch-up. At the old 40% every PS launch started mid-band and
			// the drop engaged on the first frames by construction (2026-08-31 receipts).
			snd.prefilling = 0;
			SDL_PauseAudio(0);
		}
	}

	int consumed = 0;
	int consumed_frames = 0;
	while (frame_count > 0) {
		int amount = MIN(BATCH_SIZE, frame_count);

		// Event-driven backpressure (was: unlock/SDL_Delay(1)/relock poll — 5-15 relock
		// wakeups per paced frame). This block IS audio pacing: wait for the callback's
		// space signal under a dedicated mutex (never while holding the SDL audio lock,
		// so there is no order inversion with the callback). A generation counter makes
		// the wait race-free against a signal landing between unlock and wait, and the
		// 20ms timedwait cap is lost-wakeup insurance plus the escape hatch for pause/
		// quit/FF-toggle arriving while blocked (each iteration rechecks the ring and
		// liveness under the audio lock). wait_ms keeps its meaning — wall ms blocked —
		// which the governor's pure-work sensor and DRC consume as deltas.
		uint32_t wait_t0 = 0;
		uint64_t wait_t0_us = 0;
		while (!snd_ff_nonblock && snd.frame_in==snd.frame_filled) {
			if (!wait_t0) { wait_t0 = SDL_GetTicks(); wait_t0_us = getMicroseconds(); atomic_fetch_add_explicit(&snd.overruns, 1, memory_order_relaxed); }
			pthread_mutex_lock(&snd_space_mx);
			unsigned g0 = snd_space_gen;
			SDL_UnlockAudio();
			struct timespec ts;
			clock_gettime(CLOCK_REALTIME, &ts);
			ts.tv_nsec += 20 * 1000000L;
			if (ts.tv_nsec >= 1000000000L) { ts.tv_sec += 1; ts.tv_nsec -= 1000000000L; }
			while (snd_space_gen == g0)
				if (pthread_cond_timedwait(&snd_space_cv, &snd_space_mx, &ts) == ETIMEDOUT) break;
			pthread_mutex_unlock(&snd_space_mx);
			SDL_LockAudio();
			if (!snd.initialized || atomic_load(&snd.paused) || !snd.buffer || snd.frame_count==0) { // torn down/paused while blocked
				SDL_UnlockAudio();
				return consumed;
			}
		}
		if (wait_t0) {
			uint32_t waited = SDL_GetTicks() - wait_t0;
			atomic_fetch_add_explicit(&snd.wait_ms, waited ? waited : 1, memory_order_relaxed);
			atomic_fetch_add_explicit(&snd.wait_us, (uint32_t)(getMicroseconds() - wait_t0_us), memory_order_relaxed);
		}
		// FF non-blocking: ring still full after the (skipped) wait — drop the remaining
		// frames and return so emulation never blocks on audio during fast-forward.
		if (snd_ff_nonblock && snd.frame_in==snd.frame_filled) break;
		// if (tries) LOG_info("%8i waited %ims for buffer to get low...\n", ms(), tries);

		while (amount && snd.frame_in != snd.frame_filled) {
			consumed_frames = snd.resample(*frames);
			
			frames += consumed_frames;
			amount -= consumed_frames;
			frame_count -= consumed_frames;
			consumed += consumed_frames;
		}
	}
	SND_publishOccupancy(); // producer side of the presentation-drop snapshot (under lock)
	__atomic_store_n(&snd_last_batch_ms, SDL_GetTicks(), __ATOMIC_RELEASE);
	SDL_UnlockAudio();

	return consumed;
}

int SND_isActive(void) {
	// "Actively pacing", not merely "init attempted": present-skip relies on the audio ring to
	// backpressure emulation in place of the vsync waits it drops. A failed ring alloc leaves
	// initialized=1 with an unusable buffer (SND_batchSamples returns immediately, no
	// backpressure) — skipping then would let the core run free of any pacing (Codex P1).
	// Exactly the SND_batchSamples pacing predicate (Codex F2: one source, no drift).
	return snd_can_pace();
}
void SND_getStats(SND_Stats* out) {
	if (!out) return;
	out->underruns = atomic_load_explicit(&snd.underruns, memory_order_relaxed);
	out->overruns = atomic_load_explicit(&snd.overruns, memory_order_relaxed);
	out->wait_ms = atomic_load_explicit(&snd.wait_ms, memory_order_relaxed);
	out->wait_us = atomic_load_explicit(&snd.wait_us, memory_order_relaxed);
	uint64_t ring = atomic_load_explicit(&snd_ring_frames, memory_order_acquire);
	out->frame_count = (int)(ring >> 32);
	out->queue_frames = (int)(uint32_t)ring;
}
void SND_init(double sample_rate, double frame_rate) { // plat_sound_init
	uint64_t t_snd0 = getMicroseconds();
#define SNDMARK(what) do { const char* _e = getenv("ZERO_BOOT_TIMING"); \
		if (_e && _e[0] && _e[0] != '0') LOG_info("snd-timing: %-12s +%llums\n", (what), \
			(unsigned long long)((getMicroseconds()-t_snd0)/1000)); \
	} while (0)
	LOG_info("SND_init\n");
	
	SDL_InitSubSystem(SDL_INIT_AUDIO);
	SNDMARK("subsystem");
	
#if defined(USE_SDL2)
	LOG_info("Available audio drivers:\n");
	for (int i=0; i<SDL_GetNumAudioDrivers(); i++) {
		LOG_info("- %s\n", SDL_GetAudioDriver(i));
	}
	LOG_info("Current audio driver: %s\n", SDL_GetCurrentAudioDriver());
#endif	
	
	memset(&snd, 0, sizeof(struct SND_Context));
	atomic_store(&snd_ff_nonblock, 0);
	FFAudioRate_init(&snd.ff_rate);
	snd.frame_rate = frame_rate;

	SDL_AudioSpec spec_in;
	SDL_AudioSpec spec_out;

	spec_in.freq = PLAT_pickSampleRate(sample_rate, MAX_SAMPLE_RATE);
	spec_in.format = AUDIO_S16;
	spec_in.channels = 2;
	spec_in.samples = SAMPLES;
	spec_in.callback = SND_audioCallback;

	// Mute BEFORE the open as well. Opening reconfigures the DAC (the SigmaStar SDL driver sets
	// the public attrs / sample rate and calls MI_AO_Enable), and reconfiguring a LIVE codec is
	// itself an audible transient — that is the remaining "pop when a game starts".
	// This used to be impossible: MI_AO rejects SetMute on a disabled device, so a pre-open mute
	// was a silent no-op. Now that the codec is left enabled between processes (PLAT_keepAudioOpen
	// + the SDL_Quit fix), the device IS already enabled at game launch and this mute takes effect.
	// On a cold boot the device really is disabled, the ioctl no-ops as before, and the post-open
	// mute below still covers us.
	PLAT_muteAudio(1);
	SNDMARK("pre_open");

	if (SDL_OpenAudio(&spec_in, &spec_out)<0) {
		// no device: run silent but SAFE — spec_out is uninitialized on failure and the
		// producer paths gate on snd.initialized, so leave it cleared (audit 2026-07-11)
		// The device may still be enabled from a process that died without closing it, in which
		// case MI_AO_SetPubAttr refuses and EVERY launch after the first is silent until reboot
		// (MEASURED across 5 back-to-back systems). Reset it and try exactly once more.
		LOG_info("SDL_OpenAudio failed (%s) — resetting the audio device and retrying\n", SDL_GetError());
		PLAT_resetAudio();
		if (SDL_OpenAudio(&spec_in, &spec_out) >= 0) {
			LOG_info("audio recovered after reset\n");
			goto audio_open_ok;
		}
		LOG_info("SDL_OpenAudio error: %s — audio disabled\n", SDL_GetError());
		snd.initialized = 0;
		// MUST unmute before bailing. We muted just above, and on platforms that keep the codec
		// enabled across processes (PLAT_keepAudioOpen) that mute is GLOBAL and PERSISTENT — a
		// single failed open would otherwise leave the whole device silent, including the menu
		// and every later game, with nothing to undo it.
		PLAT_muteAudio(0);
		return;
	}
audio_open_ok:
	
	// Mute AFTER the open: MI_AO rejects SetMute/SetVolume before the device is enabled
	// (MEASURED in dmesg: "MI_AO_IMPL_SetMute: Dev0 has not been enabled"), so muting earlier was
	// a silent no-op. Held muted until the ring has prefilled, then released in one step.
	PLAT_muteAudio(1);

	snd.buffer_seconds = 12; // ring CAPACITY (~200ms), not latency — latency is occupancy,
	                         // set by the production/consumption balance. 5 frames (83ms)
	                         // could not absorb pcsx load-stalls (BR2/THPS logo+demo audio
	                         // chop at ANY clock, ear-found + counter-verified 2026-07-08)
	{	// per-system capacity (MINARCH_SND_RING_MS, exported by the pak launch.sh like
		// MINARCH_FMIN): audio-block pacing runs the ring near-full, so capacity IS the
		// steady-state latency. Applied in SND_resizeBuffer against the DAC OUTPUT rate —
		// the ring stores output-rate frames, so input-rate math would skew real latency
		// by the resample ratio (Codex review finding 5).
		char* ring_ms = getenv("MINARCH_SND_RING_MS");
		if (ring_ms) {
			int ms = atoi(ring_ms);
			if (ms >= 67 && ms <= 500) snd.ring_override_ms = ms;
		}
	}
	snd.sample_rate_in  = sample_rate;
	snd.sample_rate_out = spec_out.freq;
	
	SND_updateAdjustedRate();
	SND_resizeBuffer();
	
	snd.prefilling = 1; // DAC starts when the ring reaches ~70% (see SND_batchSamples)

	SNDMARK("open_done");
	LOG_info("sample rate: %i (req) %i (rec) [samples %i]\n", snd.sample_rate_in, snd.sample_rate_out, SAMPLES);
	snd.initialized = 1;
	SND_publishOccupancy();
	// device is up and the ring is prefilling — safe to let signal through now (settles first)
	PLAT_muteAudio(0);
}
void SND_pause(void) { // close the device so the SDL audio thread fully stops during sleep
	if (!snd.initialized) return;                 // (pause alone kept it spinning ~7% CPU; from MyMinUI)
	atomic_store(&snd.paused, 1); // no consumer exists now: producers drop instead of waiting (review 5/r3)
	// Mute BEFORE the close, exactly as SND_quit does. On SigmaStar the close IS
	// MI_AO_Disable/DisableChn, and that codec power-down is the audible pop — so without this,
	// every sleep popped and every wake popped again on reopen. This was the same defect SND_quit
	// was fixed for; this path was missed.
	// NOTE: unlike SND_quit we still CLOSE here even when PLAT_keepAudioOpen() is set. Closing is
	// what actually stops the SDL audio thread; leaving it open costs ~7% CPU for the whole
	// faux-sleep, which on a sleep path is a worse trade than a muted transient.
	PLAT_muteAudio(1);
	SDL_PauseAudio(1);
	SDL_CloseAudio();
	SND_signalSpace(); // a blocked producer wakes and exits via the paused check
}
void SND_resume(void) { // reopen at the rate negotiated in SND_init; ring buffer was preserved
	if (!snd.initialized) return;

	SDL_AudioSpec spec_in;
	SDL_AudioSpec spec_out;
	spec_in.freq = snd.sample_rate_out;
	spec_in.format = AUDIO_S16;
	spec_in.channels = 2;
	spec_in.samples = SAMPLES;
	spec_in.callback = SND_audioCallback;

	if (SDL_OpenAudio(&spec_in, &spec_out)<0) {
		// resume failed: without a consumer the producer would fill the ring and stall
		// forever — drop to silent-but-safe instead (audit 2026-07-11)
		LOG_info("SDL_OpenAudio error (resume): %s — audio disabled\n", SDL_GetError());
		snd.initialized = 0;
		atomic_store(&snd.paused, 0);
		return;
	}
	atomic_store(&snd.paused, 0); // consumer is back: producers may wait again
	snd.prefilling = 1; // re-arm the prefill gate (empty-ring starts chop audibly)
	// Release the mute SND_pause took. The reopen above re-enabled/reconfigured the codec, which
	// is the transient we were hiding; the ring is prefilling so nothing audible is lost.
	PLAT_muteAudio(0);
}
// Weak default: platforms without a hardware mute simply do nothing.
__attribute__((weak)) void PLAT_muteAudio(int mute) { (void)mute; }
__attribute__((weak)) int PLAT_keepAudioOpen(void) { return 0; }
__attribute__((weak)) void PLAT_resetAudio(void) { }
// -1 = "no idea", which the telemetry prints as dac=? rather than inventing a number.
__attribute__((weak)) int PLAT_getAudioQueued(void) { return -1; }

// Exact charge percentage for the charging screen, or -1 when this platform has no better source
// than PLAT_getBatteryStatus's coarse buckets. Added because the charging screen was reading
// tg5040-only sysfs (axp2202-battery/capacity) DIRECTLY, so on every other platform it rendered
// "..." instead of a number. Platforms that can answer override this; the rest are unchanged.
__attribute__((weak)) int PLAT_getChargePercent(void) { return -1; }

// Is the audio codec owned by ANOTHER process that outlives us? 1 = yes, do not touch device-global
// audio state. Default 0: we own it, current behaviour is unchanged everywhere that does.
__attribute__((weak)) int PLAT_audioIsShared(void) { return 0; }

// Is the battery still being filled? Platforms that cannot tell fall back to "same as charging",
// preserving existing behaviour; only platforms that distinguish the two override this.
__attribute__((weak)) int PLAT_isToppingUp(void) { return -1; }

void SND_quit(void) { // plat_sound_finish
	if (snd.initialized) {
		// Stop feeding the device first, either way.
		SDL_PauseAudio(1);
		// Closing calls MI_AO_Disable/DisableChn on SigmaStar, and that power-down IS the pop.
		// Leave the codec enabled and let the next process reuse it.
		//
		// MUTE ONLY IF WE ARE ACTUALLY CLOSING. The mute exists solely to silence the DAC across
		// that power-down. When the codec is kept open there is no power-down to protect, and
		// because the device stays ENABLED between processes the mute would be GLOBAL and
		// PERSISTENT — MEASURED on device: the exit pop went away but the next game launched
		// silent, because nothing in the new process cleared a mute it never set.
		if (!PLAT_keepAudioOpen()) {
			PLAT_muteAudio(1);
			SDL_CloseAudio();
		}
	}

	if (snd.buffer) {
		free(snd.buffer);
		snd.buffer = NULL;
	}
	snd.frame_count = 0;
	snd.frame_in = snd.frame_out = snd.frame_filled = 0;
	snd.initialized = 0;
	atomic_store(&snd_ff_nonblock, 0);
	FFAudioRate_end(&snd.ff_rate);
	SND_publishOccupancy(); // reads 100 now — catch-up can never engage on a closed ring
	SND_signalSpace(); // a producer blocked mid-teardown wakes and exits via its liveness recheck
}

///////////////////////////////

LID_Context lid = {
	.has_lid = 0,
	.is_open = 1,
};

FALLBACK_IMPLEMENTATION void PLAT_initLid(void) {  }
FALLBACK_IMPLEMENTATION int PLAT_lidChanged(int* state) { return 0; }

///////////////////////////////

PAD_Context pad;

#define AXIS_DEADZONE 0x4000
void PAD_setAnalog(int neg_id,int pos_id,int value,int repeat_at) {
	// LOG_info("neg %i pos %i value %i\n", neg_id, pos_id, value);
	int neg = 1 << neg_id;
	int pos = 1 << pos_id;	
	if (value>AXIS_DEADZONE) { // pressing
		if (!(pad.is_pressed&pos)) { // not pressing
			pad.is_pressed 		|= pos; // set
			pad.just_pressed	|= pos; // set
			pad.just_repeated	|= pos; // set
			pad.repeat_at[pos_id]= repeat_at;
		
			if (pad.is_pressed&neg) { // was pressing opposite
				pad.is_pressed 		&= ~neg; // unset
				pad.just_repeated 	&= ~neg; // unset
				pad.just_released	|=  neg; // set
			}
		}
	}
	else if (value<-AXIS_DEADZONE) { // pressing
		if (!(pad.is_pressed&neg)) { // not pressing
			pad.is_pressed		|= neg; // set
			pad.just_pressed	|= neg; // set
			pad.just_repeated	|= neg; // set
			pad.repeat_at[neg_id]= repeat_at;
		
			if (pad.is_pressed&pos) { // was pressing opposite
				pad.is_pressed 		&= ~pos; // unset
				pad.just_repeated 	&= ~pos; // unset
				pad.just_released	|=  pos; // set
			}
		}
	}
	else { // not pressing
		if (pad.is_pressed&neg) { // was pressing
			pad.is_pressed 		&= ~neg; // unset
			pad.just_repeated	&=  neg; // unset
			pad.just_released	|=  neg; // set
		}
		if (pad.is_pressed&pos) { // was pressing
			pad.is_pressed 		&= ~pos; // unset
			pad.just_repeated	&=  pos; // unset
			pad.just_released	|=  pos; // set
		}
	}
}

// Resolved once; an input hot path should not walk the environment per event.
static int zero_input_debug(void) {
	static int on = -1;
	if (on < 0) { const char* e = getenv("ZERO_INPUT_DEBUG"); on = (e && e[0] && e[0] != '0') ? 1 : 0; }
	return on;
}

void PAD_reset(void) {
	// LOG_info("PAD_reset");
	pad.just_pressed = BTN_NONE;
	pad.is_pressed = BTN_NONE;
	pad.just_released = BTN_NONE;
	pad.just_repeated = BTN_NONE;
}
FALLBACK_IMPLEMENTATION void PLAT_pollInput(void) {
	// reset transient state
	pad.just_pressed = BTN_NONE;
	pad.just_released = BTN_NONE;
	pad.just_repeated = BTN_NONE;

	uint32_t tick = SDL_GetTicks();
	for (int i=0; i<BTN_ID_COUNT; i++) {
		int btn = 1 << i;
		if ((pad.is_pressed & btn) && (tick>=pad.repeat_at[i])) {
			pad.just_repeated |= btn; // set
			pad.repeat_at[i] += PAD_REPEAT_INTERVAL;
		}
	}
	
	// the actual poll
	SDL_Event event;
	while (SDL_PollEvent(&event)) {
		int btn = BTN_NONE;
		int pressed = 0; // 0=up,1=down
		int id = -1;
		if (event.type==SDL_KEYDOWN || event.type==SDL_KEYUP) {
			uint8_t code = event.key.keysym.scancode;
			pressed = event.type==SDL_KEYDOWN;
			// ZERO_INPUT_DEBUG=1 prints every key AND joystick event with the value this code actually
			// compares against. CODE_* are SDL SCANCODES, not evdev codes (CODE_POWER is 102 =
			// SDL_SCANCODE_POWER, while evdev KEY_POWER is 116), so mapping a new device straight
			// from its evdev numbers yields a define that can never match.
			if (zero_input_debug()) LOG_info("input: KEY scancode=%i pressed=%i\n", code, pressed);
				 if (code==CODE_UP) 		{ btn = BTN_DPAD_UP; 		id = BTN_ID_DPAD_UP; }
 			else if (code==CODE_DOWN)		{ btn = BTN_DPAD_DOWN; 		id = BTN_ID_DPAD_DOWN; }
			else if (code==CODE_LEFT)		{ btn = BTN_DPAD_LEFT; 		id = BTN_ID_DPAD_LEFT; }
			else if (code==CODE_RIGHT)		{ btn = BTN_DPAD_RIGHT; 	id = BTN_ID_DPAD_RIGHT; }
			else if (code==CODE_A)			{ btn = BTN_A; 				id = BTN_ID_A; }
			else if (code==CODE_B)			{ btn = BTN_B; 				id = BTN_ID_B; }
			else if (code==CODE_X)			{ btn = BTN_X; 				id = BTN_ID_X; }
			else if (code==CODE_Y)			{ btn = BTN_Y; 				id = BTN_ID_Y; }
			else if (code==CODE_START)		{ btn = BTN_START; 			id = BTN_ID_START; }
			else if (code==CODE_SELECT)		{ btn = BTN_SELECT; 		id = BTN_ID_SELECT; }
			else if (code==CODE_MENU)		{ btn = BTN_MENU; 			id = BTN_ID_MENU; }
			else if (code==CODE_MENU_ALT)	{ btn = BTN_MENU; 			id = BTN_ID_MENU; }
			else if (code==CODE_L1)			{ btn = BTN_L1; 			id = BTN_ID_L1; }
			else if (code==CODE_L2)			{ btn = BTN_L2; 			id = BTN_ID_L2; }
			else if (code==CODE_L3)			{ btn = BTN_L3; 			id = BTN_ID_L3; }
			else if (code==CODE_R1)			{ btn = BTN_R1; 			id = BTN_ID_R1; }
			else if (code==CODE_R2)			{ btn = BTN_R2; 			id = BTN_ID_R2; }
			else if (code==CODE_R3)			{ btn = BTN_R3; 			id = BTN_ID_R3; }
			else if (code==CODE_F1)			{ btn = BTN_F1; 			id = BTN_ID_F1; }
			else if (code==CODE_F2)			{ btn = BTN_F2; 			id = BTN_ID_F2; }
			else if (code==CODE_PLUS)		{ btn = BTN_PLUS; 			id = BTN_ID_PLUS; }
			else if (code==CODE_MINUS)		{ btn = BTN_MINUS; 			id = BTN_ID_MINUS; }
			else if (code==CODE_POWER)		{ btn = BTN_POWER; 			id = BTN_ID_POWER; }
			else if (code==CODE_POWEROFF)	{ btn = BTN_POWEROFF;		id = BTN_ID_POWEROFF; } // nano-only
		}
		else if (event.type==SDL_JOYBUTTONDOWN || event.type==SDL_JOYBUTTONUP) {
			uint8_t joy = event.jbutton.button;
			pressed = event.type==SDL_JOYBUTTONDOWN;
			if (zero_input_debug()) LOG_info("input: JOY button=%i pressed=%i\n", joy, pressed);
				 if (joy==JOY_UP) 		{ btn = BTN_DPAD_UP; 		id = BTN_ID_DPAD_UP; }
 			else if (joy==JOY_DOWN)		{ btn = BTN_DPAD_DOWN; 		id = BTN_ID_DPAD_DOWN; }
			else if (joy==JOY_LEFT)		{ btn = BTN_DPAD_LEFT; 		id = BTN_ID_DPAD_LEFT; }
			else if (joy==JOY_RIGHT)	{ btn = BTN_DPAD_RIGHT; 	id = BTN_ID_DPAD_RIGHT; }
			else if (joy==JOY_A)		{ btn = BTN_A; 				id = BTN_ID_A; }
			else if (joy==JOY_B)		{ btn = BTN_B; 				id = BTN_ID_B; }
			else if (joy==JOY_X)		{ btn = BTN_X; 				id = BTN_ID_X; }
			else if (joy==JOY_Y)		{ btn = BTN_Y; 				id = BTN_ID_Y; }
			else if (joy==JOY_START)	{ btn = BTN_START; 			id = BTN_ID_START; }
			else if (joy==JOY_SELECT)	{ btn = BTN_SELECT; 		id = BTN_ID_SELECT; }
			else if (joy==JOY_MENU)		{ btn = BTN_MENU; 			id = BTN_ID_MENU; }
			else if (joy==JOY_MENU_ALT) { btn = BTN_MENU; 			id = BTN_ID_MENU; }
			else if (joy==JOY_MENU_ALT2){ btn = BTN_MENU; 			id = BTN_ID_MENU; }
			else if (joy==JOY_L1)		{ btn = BTN_L1; 			id = BTN_ID_L1; }
			else if (joy==JOY_L2)		{ btn = BTN_L2; 			id = BTN_ID_L2; }
			else if (joy==JOY_L3)		{ btn = BTN_L3; 			id = BTN_ID_L3; }
			else if (joy==JOY_R1)		{ btn = BTN_R1; 			id = BTN_ID_R1; }
			else if (joy==JOY_R2)		{ btn = BTN_R2; 			id = BTN_ID_R2; }
			else if (joy==JOY_R3)		{ btn = BTN_R3; 			id = BTN_ID_R3; }
			else if (joy==JOY_F1)		{ btn = BTN_F1; 			id = BTN_ID_F1; }
			else if (joy==JOY_F2)		{ btn = BTN_F2; 			id = BTN_ID_F2; }
			else if (joy==JOY_PLUS)		{ btn = BTN_PLUS; 			id = BTN_ID_PLUS; }
			else if (joy==JOY_MINUS)	{ btn = BTN_MINUS; 			id = BTN_ID_MINUS; }
			else if (joy==JOY_POWER)	{ btn = BTN_POWER; 			id = BTN_ID_POWER; }
		}
		else if (event.type==SDL_JOYHATMOTION) {
			int hats[4] = {-1,-1,-1,-1}; // -1=no change,0=up,1=down,2=left,3=right btn_ids
			int hat = event.jhat.value;
			if (zero_input_debug()) LOG_info("input: HAT value=%i\n", hat);
			// TODO: safe to assume hats will always be the primary dpad?
			// TODO: this is literally a bitmask, make it one (oh, except there's 3 states...)
			switch (hat) {
				case SDL_HAT_UP:			hats[0]=1;	  hats[1]=0;	hats[2]=0;	  hats[3]=0;	break;
				case SDL_HAT_DOWN:			hats[0]=0;	  hats[1]=1;	hats[2]=0;	  hats[3]=0;	break;
				case SDL_HAT_LEFT:			hats[0]=0;	  hats[1]=0;	hats[2]=1;	  hats[3]=0;	break;
				case SDL_HAT_RIGHT:			hats[0]=0;	  hats[1]=0;	hats[2]=0;	  hats[3]=1;	break;
				case SDL_HAT_LEFTUP:		hats[0]=1;	  hats[1]=0;	hats[2]=1;	  hats[3]=0;	break;
				case SDL_HAT_LEFTDOWN:		hats[0]=0;	  hats[1]=1;	hats[2]=1;	  hats[3]=0;	break;
				case SDL_HAT_RIGHTUP:		hats[0]=1;	  hats[1]=0;	hats[2]=0;	  hats[3]=1;	break;
				case SDL_HAT_RIGHTDOWN:		hats[0]=0;	  hats[1]=1;	hats[2]=0;	  hats[3]=1;	break;
				case SDL_HAT_CENTERED:		hats[0]=0;	  hats[1]=0;	hats[2]=0;	  hats[3]=0;	break;
				default: break;
			}
			
			for (id=0; id<4; id++) {
				int state = hats[id];
				btn = 1 << id;
				if (state==0) {
					pad.is_pressed		&= ~btn; // unset
					pad.just_repeated	&= ~btn; // unset
					pad.just_released	|= btn; // set
				}
				else if (state==1 && (pad.is_pressed & btn)==BTN_NONE) {
					pad.just_pressed	|= btn; // set
					pad.just_repeated	|= btn; // set
					pad.is_pressed		|= btn; // set
					pad.repeat_at[id]	= tick + PAD_REPEAT_DELAY;
				}
			}
			btn = BTN_NONE; // already handled, force continue
		}
		else if (event.type==SDL_JOYAXISMOTION) {
			int axis = event.jaxis.axis;
			int val = event.jaxis.value;
			if (zero_input_debug()) LOG_info("input: AXIS axis=%i value=%i\n", axis, val);
			
			// triggers on tg5040
			if (axis==AXIS_L2) {
				btn = BTN_L2;
				id = BTN_ID_L2;
				pressed = val>0;
			}
			else if (axis==AXIS_R2) {
				btn = BTN_R2;
				id = BTN_ID_R2;
				pressed = val>0;
			}
			
			else if (axis==AXIS_LX) { pad.laxis.x = val; PAD_setAnalog(BTN_ID_ANALOG_LEFT, BTN_ID_ANALOG_RIGHT, val, tick+PAD_REPEAT_DELAY); }
			else if (axis==AXIS_LY) { pad.laxis.y = val; PAD_setAnalog(BTN_ID_ANALOG_UP,   BTN_ID_ANALOG_DOWN,  val, tick+PAD_REPEAT_DELAY); }
			else if (axis==AXIS_RX) pad.raxis.x = val;
			else if (axis==AXIS_RY) pad.raxis.y = val;
			
			// axis will fire off what looks like a release
			// before the first press but you can't release
			// a button that wasn't pressed
			if (!pressed && btn!=BTN_NONE && !(pad.is_pressed & btn)) {
				// LOG_info("cancel: %i\n", axis);
				btn = BTN_NONE;
			}
		}
		// else if (event.type==SDL_QUIT) PWR_powerOff(); // added for macOS debug
		
		if (btn==BTN_NONE) continue;
		
		if (!pressed) {
			pad.is_pressed		&= ~btn; // unset
			pad.just_repeated	&= ~btn; // unset
			pad.just_released	|= btn; // set
		}
		else if ((pad.is_pressed & btn)==BTN_NONE) {
			pad.just_pressed	|= btn; // set
			pad.just_repeated	|= btn; // set
			pad.is_pressed		|= btn; // set
			pad.repeat_at[id]	= tick + PAD_REPEAT_DELAY;
		}
	}
	
	// LID CLOSE REQUESTS SLEEP DIRECTLY — it must not go through a synthetic button release.
	//
	// This used to set `just_released |= BTN_SLEEP`, and BTN_SLEEP is #defined to BTN_POWER on the
	// platforms that have a lid. PWR_update's manual-sleep condition requires `power_pressed_at`,
	// i.e. proof of a preceding PHYSICAL press (the guard that stops a resume-press immediately
	// re-sleeping the device). A hall-sensor transition never sets it, so the condition was
	// unreachable and closing the clamshell did nothing: panel, audio and game stayed live in a
	// shut lid, draining and heating. `requested_sleep` is the existing hardware-request path and
	// bypasses that guard by design.
	//
	// Gate on !lid_open: the old code fired on ANY transition, so OPENING synthesized a sleep too.
	// That was masked only because the guard rejected both.
	//
	// PAD_poll owns the CLOSE and PLAT_shouldWake owns the OPEN. These do not race despite
	// PLAT_lidChanged being stateful: PAD_poll runs only while awake, and PLAT_shouldWake runs only
	// inside the wake loop, when PAD_poll is not running.
	int lid_open = 1;
	if (lid.has_lid && PLAT_lidChanged(&lid_open) && !lid_open) PWR_requestSleep();
}
FALLBACK_IMPLEMENTATION int PLAT_shouldWake(void) {
	int lid_open = 1; // assume open by default
	if (lid.has_lid && PLAT_lidChanged(&lid_open) && lid_open) return 1;
	
	
	SDL_Event event;
	while (SDL_PollEvent(&event)) {
		if (event.type==SDL_KEYUP) {
			uint8_t code = event.key.keysym.scancode;
			if ((BTN_WAKE==BTN_POWER && code==CODE_POWER) || (BTN_WAKE==BTN_MENU && (code==CODE_MENU || code==CODE_MENU_ALT))) {
				// ignore input while lid is closed
				if (lid.has_lid && !lid.is_open) return 0;  // do it here so we eat the input
				return 1;
			}
		}
		else if (event.type==SDL_JOYBUTTONUP) {
			uint8_t joy = event.jbutton.button;
			if ((BTN_WAKE==BTN_POWER && joy==JOY_POWER) || (BTN_WAKE==BTN_MENU && (joy==JOY_MENU || joy==JOY_MENU_ALT))) {
				// ignore input while lid is closed
				if (lid.has_lid && !lid.is_open) return 0;  // do it here so we eat the input
				return 1;
			}
		} 
	}
	return 0;
}
FALLBACK_IMPLEMENTATION int PLAT_supportsDeepSleep(void) { return 0; }
FALLBACK_IMPLEMENTATION int PLAT_deepSleep(void) {
	const char *state_path = "/sys/power/state";

	int state_fd = open(state_path, O_WRONLY);
	if (state_fd < 0) {
		LOG_error("failed to open %s: %d\n", state_path, errno);
		return -1;
	}

	LOG_info("suspending to RAM\n");
	int ret = write(state_fd, "mem", 3);
	if (ret < 0) {
		// Can fail shortly after resuming with EBUSY
		LOG_error("failed to set power state: %d\n", errno);
		close(state_fd);
		return -1;
	}

	LOG_info("returned from suspend\n");
	close(state_fd);
	return 0;
}

int PAD_anyJustPressed(void)	{ return pad.just_pressed!=BTN_NONE; }
int PAD_anyPressed(void)		{ return pad.is_pressed!=BTN_NONE; }
int PAD_anyJustReleased(void)	{ return pad.just_released!=BTN_NONE; }

int PAD_justPressed(int btn)	{ return pad.just_pressed & btn; }
int PAD_isPressed(int btn)		{ return pad.is_pressed & btn; }
int PAD_justReleased(int btn)	{ return pad.just_released & btn; }
int PAD_justRepeated(int btn)	{ return pad.just_repeated & btn; }

int PAD_tappedMenu(uint32_t now) {
	#define MENU_DELAY 250 // also in PWR_update()
	static uint32_t menu_start = 0;
	static int ignore_menu = 0; 
	if (PAD_justPressed(BTN_MENU)) {
		ignore_menu = 0;
		menu_start = now;
	}
	else if (PAD_isPressed(BTN_MENU) && BTN_MOD_BRIGHTNESS==BTN_MENU && (PAD_justPressed(BTN_MOD_PLUS) || PAD_justPressed(BTN_MOD_MINUS))) {
		ignore_menu = 1;
	}
	return (!ignore_menu && PAD_justReleased(BTN_MENU) && now-menu_start<MENU_DELAY);
}

///////////////////////////////

static struct VIB_Context {
	int initialized;
	pthread_t pt;
	pthread_mutex_t mx;
	pthread_cond_t cv;
	int queued_strength;
	int strength;
	int quit;
} vib = {0};
static void* VIB_thread(void *arg) {
	// Event-driven: the worker sleeps on the condvar until a strength change or quit —
	// ZERO idle wakeups (the old loop woke every 17ms forever, ~59/s). The deferred-off
	// behavior survives as a bounded timedwait: a request for 0 is held ~51ms (the old
	// DEFER_FRAMES*17ms) and abandoned if a non-zero request arrives in that window,
	// because this motor dislikes 0<->N vacillation.
#define VIB_DEFER_OFF_MS 51
	pthread_mutex_lock(&vib.mx);
	while (!vib.quit) {
		if (vib.queued_strength == vib.strength) {
			pthread_cond_wait(&vib.cv, &vib.mx); // blocks indefinitely; wakes on change/quit
			continue;
		}
		int target = vib.queued_strength;
		if (target == 0) {
			struct timespec ts;
			clock_gettime(CLOCK_REALTIME, &ts);
			ts.tv_nsec += VIB_DEFER_OFF_MS * 1000000L;
			if (ts.tv_nsec >= 1000000000L) { ts.tv_sec += 1; ts.tv_nsec -= 1000000000L; }
			while (!vib.quit && vib.queued_strength == 0)
				if (pthread_cond_timedwait(&vib.cv, &vib.mx, &ts) == ETIMEDOUT) break;
			if (vib.quit) break;
			if (vib.queued_strength != 0) continue; // rescued within the window: skip the off
		}
		vib.strength = target;
		pthread_mutex_unlock(&vib.mx);
		PLAT_setRumble(target); // device write outside the lock: setters never block on i2c/sysfs
		pthread_mutex_lock(&vib.mx);
	}
	pthread_mutex_unlock(&vib.mx);
	return 0;
}
void VIB_init(void) {
	vib.queued_strength = vib.strength = 0;
	vib.quit = 0;
	pthread_mutex_init(&vib.mx, NULL);
	pthread_cond_init(&vib.cv, NULL);
	pthread_create(&vib.pt, NULL, &VIB_thread, NULL);
	vib.initialized = 1;
}
void VIB_quit(void) {
	if (!vib.initialized) return;
	pthread_mutex_lock(&vib.mx);
	vib.quit = 1;
	pthread_cond_broadcast(&vib.cv);
	pthread_mutex_unlock(&vib.mx);
	pthread_join(vib.pt, NULL); // deterministic teardown (was pthread_cancel mid-SDL_Delay)
	PLAT_setRumble(0);          // motor off regardless of what was in flight
	vib.initialized = 0;
}
void VIB_setStrength(int strength) {
	if (!vib.initialized) return;
	pthread_mutex_lock(&vib.mx);
	if (vib.queued_strength != strength) {
		vib.queued_strength = strength;
		pthread_cond_signal(&vib.cv);
	}
	pthread_mutex_unlock(&vib.mx);
}
int VIB_getStrength(void) {
	if (!vib.initialized) return 0;
	pthread_mutex_lock(&vib.mx);
	int v = vib.strength;
	pthread_mutex_unlock(&vib.mx);
	return v;
}

///////////////////////////////

static void PWR_initOverlay(void) {
	// setup surface
	pwr.overlay = PLAT_initOverlay();

	// draw battery
	SDLX_SetAlpha(gfx.assets, 0,0);
	GFX_blitAsset(ASSET_BLACK_PILL, NULL, pwr.overlay, NULL);
	SDLX_SetAlpha(gfx.assets, SDL_SRCALPHA,0);
	GFX_blitBattery(pwr.overlay, NULL);
}

static void PWR_updateBatteryStatus(void) {
	PLAT_getBatteryStatus(&pwr.is_charging, &pwr.charge);
	PLAT_enableOverlay(pwr.should_warn && pwr.charge<=PWR_LOW_CHARGE);
}

static void* PWR_monitorBattery(void *arg) {
	while(1) {
		// TODO: the frequency of checking could depend on whether 
		// we're in game (less frequent) or menu (more frequent)
		sleep(5);
		PWR_updateBatteryStatus();
	}
	return NULL;
}

void PWR_init(void) {
	// DEV MODE (opt-in, off unless the user drops a "devmode" flag at the SD-card root): arm the
	// stay-awake inhibit for this boot, so the device never autosleeps and — critically — never
	// reaches the 2-minute sleep escalation that POWERS IT OFF on a platform without deep sleep
	// (PWR_waitForWake below: no PLAT_supportsDeepSleep -> falls through to PWR_powerOff). That
	// power-off is what made an idle h700 "die" mid-SSH and killed every remote debug session
	// (2026-08-09). STAY_AWAKE_PATH lives in /tmp, so a reboot clears it and it cannot be re-set
	// remotely on a device that just powered itself off; re-arming it HERE at every startup is
	// what makes a dev session survive reboots. No devmode flag = stock behaviour, untouched.
	// flagExists() accepts both "devmode" and "devmode.txt", matching every other card-root flag.
	if (flagExists(DEVMODE_PATH)) {
		putFile(STAY_AWAKE_PATH, "1");
		LOG_info("devmode: stay-awake armed (no autosleep, no idle power-off)\n");
	}
	pwr.can_sleep = 1;
	pwr.can_poweroff = 1;
	pwr.can_autosleep = 1;
	
	pwr.requested_sleep = 0;
	pwr.requested_wake = 0;
	pwr.resume_tick = 0;

	pwr.should_warn = 0;
	pwr.charge = PWR_LOW_CHARGE;
	
	PWR_initOverlay();

	PWR_updateBatteryStatus();
	pthread_create(&pwr.battery_pt, NULL, &PWR_monitorBattery, NULL);
	pwr.initialized = 1;
}
void PWR_quit(void) {
	if (!pwr.initialized) return;
	
	PLAT_quitOverlay();
	
	// cancel battery thread
	pthread_cancel(pwr.battery_pt);
	pthread_join(pwr.battery_pt, NULL);
}
void PWR_warn(int enable) {
	pwr.should_warn = enable;
	PLAT_enableOverlay(pwr.should_warn && pwr.charge<=PWR_LOW_CHARGE);
}

int PWR_ignoreSettingInput(int btn, int show_setting) {
	return show_setting && (btn==BTN_MOD_PLUS || btn==BTN_MOD_MINUS);
}

void PWR_update(int* _dirty, int* _show_setting, PWR_callback_t before_sleep, PWR_callback_t after_sleep) {
	int dirty = _dirty ? *_dirty : 0;
	int show_setting = _show_setting ? *_show_setting : 0;
	
	static uint32_t last_input_at = 0; // timestamp of last input (autosleep)
	static uint32_t checked_charge_at = 0; // timestamp of last time checking charge
	static uint32_t setting_shown_at = 0; // timestamp when settings started being shown
	static uint32_t power_pressed_at = 0; // timestamp when power button was just pressed
	static int power_press_is_wake = 0; // short post-resume presses must not immediately re-sleep
	static uint32_t mod_unpressed_at = 0; // timestamp of last time settings modifier key was NOT down
	static uint32_t was_muted = -1;
	if (was_muted==-1) was_muted = GetMute();
	
	static int was_charging = -1;
	if (was_charging==-1) was_charging = pwr.is_charging;
	// The drawn LEVEL, tracked separately from the charging flag. PWR_monitorBattery refreshes
	// pwr.charge on its own thread every 5s, but nothing here ever noticed: only a change of the
	// charging flag marked the UI dirty, so a level that moved while the menu sat idle was updated
	// in memory and never repainted. Reported on-device (2026-08-01): charged to 100%, indicator
	// kept showing low until something unrelated forced a redraw.
	static int was_charge = -1;
	if (was_charge==-1) was_charge = pwr.charge;

	uint32_t now = SDL_GetTicks();
	if (was_charging || PAD_anyPressed() || last_input_at==0) last_input_at = now;

	#define CHARGE_DELAY 1000
	if (dirty || now-checked_charge_at>=CHARGE_DELAY) {
		int is_charging = pwr.is_charging;
		if (was_charging!=is_charging) {
			was_charging = is_charging;
			dirty = 1;
		}
		if (was_charge!=pwr.charge) {
			was_charge = pwr.charge;
			dirty = 1;
		}
		checked_charge_at = now;
	}
	
	if (PAD_justReleased(BTN_POWEROFF) || (power_pressed_at && now-power_pressed_at>=1000)) {
		LOG_info("power: OFF branch (held %ums, poweroff_btn=%i)\n", power_pressed_at?now-power_pressed_at:0, PAD_justReleased(BTN_POWEROFF));
		// Haptic power cue (idea from SpruceOS): a short buzz the moment the quicksave+
		// shutdown commits — feel it and let go. Keep holding regardless and the PMIC
		// hardware long-hold cut remains the force-off escape hatch. This system cue bypasses
		// FN mute; game rumble still respects it.
		PLAT_setSystemRumble(1);
		SDL_Delay(150);
		PLAT_setSystemRumble(0);
		if (before_sleep) before_sleep();
		PWR_powerOff();
	}
	
	if (PAD_justPressed(BTN_POWER)) {
		power_pressed_at = now;
		LOG_info("power: DOWN edge seen\n");
		// NOT gated on PLAT_supportsDeepSleep(). pwr.resume_tick is set at the end of PWR_sleep(),
		// which is the COMMON path — faux sleep reaches it just as deep sleep does — so this
		// debounce is meaningful on every platform. Gating it meant that on a device without deep
		// sleep the guard below collapsed to "always sleep on release", so the release of the very
		// press that woke the device put it straight back to sleep.
		power_press_is_wake = pwr.resume_tick && now-pwr.resume_tick<1000;
		if (power_press_is_wake) LOG_debug("guarding power button release (just resumed)\n");
	}
	int power_released = PAD_justReleased(BTN_POWER);

	#define SLEEP_DELAY 30000 // 30 seconds
	if (now-last_input_at>=SLEEP_DELAY && PWR_preventAutosleep()) last_input_at = now;

	if (
		pwr.requested_sleep || // hardware requested sleep
		now-last_input_at>=SLEEP_DELAY || // autosleep
		(pwr.can_sleep && power_released && power_pressed_at && !power_press_is_wake) // manual sleep (resume-press guarded on EVERY platform)
	) {
		pwr.requested_sleep = 0;
		LOG_info("power: SLEEP branch (req=%i idle=%i manual=%i held=%ums)\n", pwr.requested_sleep, now-last_input_at>=SLEEP_DELAY, power_released&&power_pressed_at&&!power_press_is_wake, power_pressed_at?now-power_pressed_at:0);
		if (before_sleep) before_sleep();
		PWR_sleep();
		if (after_sleep) after_sleep();
		
		last_input_at = now = SDL_GetTicks();
		power_pressed_at = 0;
		power_press_is_wake = 0;
		dirty = 1;
	} else if (power_released) {
		power_pressed_at = 0;
		power_press_is_wake = 0;
	}
	
	int was_dirty = dirty; // dirty list (not including settings/battery)
	
	// TODO: only delay hiding setting changes if that setting didn't require a modifier button be held, otherwise release as soon as modifier is released
	
	int delay_settings = BTN_MOD_BRIGHTNESS==BTN_MENU; // when both volume and brighness require a modifier hide settings as soon as it is released
	#define SETTING_DELAY 500
	if (show_setting && (now-setting_shown_at>=SETTING_DELAY || !delay_settings) && !PAD_isPressed(BTN_MOD_VOLUME) && !PAD_isPressed(BTN_MOD_BRIGHTNESS)) {
		show_setting = 0;
		dirty = 1;
	}
	
	if (!show_setting && !PAD_isPressed(BTN_MOD_VOLUME) && !PAD_isPressed(BTN_MOD_BRIGHTNESS)) {
		mod_unpressed_at = now; // this feels backwards but is correct
	}
	
	#define MOD_DELAY 250
	if (
		(
			(PAD_isPressed(BTN_MOD_VOLUME) || PAD_isPressed(BTN_MOD_BRIGHTNESS)) && 
			(!delay_settings || now-mod_unpressed_at>=MOD_DELAY)
		) || 
		((!BTN_MOD_VOLUME || !BTN_MOD_BRIGHTNESS) && (PAD_justRepeated(BTN_MOD_PLUS) || PAD_justRepeated(BTN_MOD_MINUS)))
	) {
		setting_shown_at = now;
		if (PAD_isPressed(BTN_MOD_BRIGHTNESS)) {
			show_setting = 1;
		}
		else {
			show_setting = 2;
		}
	}
	
	int muted = GetMute();
	if (muted!=was_muted) {
		was_muted = muted;
		show_setting = 2;
		setting_shown_at = now;
	}
	
	if (show_setting) dirty = 1; // shm is slow or keymon is catching input on the next frame
	if (_dirty) *_dirty = dirty;
	if (_show_setting) *_show_setting = show_setting;
}

// TODO: this isn't whether it can sleep but more if it should sleep in response to the sleep button
void PWR_disableSleep(void) {
	pwr.can_sleep = 0;
}
void PWR_enableSleep(void) {
	pwr.can_sleep = 1;
}

void PWR_disablePowerOff(void) {
	pwr.can_poweroff = 0;
}
void PWR_powerOff(void) {
	if (pwr.can_poweroff) {
		
		int w = FIXED_WIDTH;
		int h = FIXED_HEIGHT;
		int p = FIXED_PITCH;
		if (GetHDMI()) {
			w = HDMI_WIDTH;
			h = HDMI_HEIGHT;
			p = HDMI_PITCH;
		}
		gfx.screen = GFX_resize(w,h,p);
		
		char* msg;
		if (HAS_POWER_BUTTON || HAS_POWEROFF_BUTTON) msg = exists(AUTO_RESUME_PATH) ? "Quicksave created,\npowering off" : "Powering off";
		else msg = exists(AUTO_RESUME_PATH) ? "Quicksave created,\npower off now" : "Power off now";
		
		// LOG_info("PWR_powerOff %s (%ix%i)\n", gfx.screen, gfx.screen->w, gfx.screen->h);
		
		// TODO: for some reason screen's dimensions end up being 0x0 in GFX_blitMessage...
		PLAT_clearVideo(gfx.screen);
		GFX_blitMessage(font.large, msg, gfx.screen,&(SDL_Rect){0,0,gfx.screen->w,gfx.screen->h}); //, NULL);
		GFX_flip(gfx.screen);
		PLAT_powerOff();
	}
}

static void PWR_enterSleep(void) {
	// Stop the haptics before anything else. Sleeping mid-rumble left the motor running for the
	// ENTIRE faux-sleep (up to the 2-minute escalation) — the vib thread has no timeout that stops
	// an already-active rumble, and nothing else on this path clears it. Onion calls rumble(0) in
	// its suspend sequence for the same reason.
	VIB_setStrength(0);
	// MUTE BEFORE closing the device, not after. SND_pause() tears the audio device down, and on
	// SigmaStar that power-down of a still-live output stage is audible as a pop — the same
	// discontinuity the game-exit path already mutes for (see PLAT_muteAudio). Volume was
	// previously dropped several lines later, i.e. after the pop had already happened.
	// Do NOT mute a codec we do not own. MI_AO_SETMUTE is DEVICE-GLOBAL, and when another process
	// owns the codec nothing unmutes per game on resume: PWR_exitSleep's SetVolume() reads the
	// current level first, and that read fails for a process which never brought AO up, so the
	// `old==-60 -> setMute(0)` boundary never fires and the device stays silent for the menu and
	// every later game until reboot. PLAT_resetAudio refuses the same operation for the same reason.
	if (!GetHDMI() && !PLAT_audioIsShared()) SetRawVolume(MUTE_VOLUME_RAW);
	SND_pause(); // fully closes the audio device (thread stops); no-op when sound isn't initialized (minui)
	if (GetHDMI()) {
		PLAT_clearVideo(gfx.screen);
		PLAT_flip(gfx.screen, 0);
	}
	else {
		PLAT_enableBacklight(0);
	}
	system("killall -STOP keymon.elf");
	
	sync();
}
static void PWR_exitSleep(void) {
	system("killall -CONT keymon.elf");
	// Reopen the audio device BEFORE re-applying volume. SND_resume() can do a full device open, and
	// opening the PCM can perturb the codec's volume register (DAPM power-up on h700) — so setting
	// volume first would be silently undone, leaving audio dead after wake (audit 2026-08-07). This
	// mirrors boot (SND_init THEN InitSettings applies volume), and it is ONE SetVolume, not two, so
	// platforms whose SetVolume persists to SD + sync/fsync (tg5040, miyoomini) do not eat an extra
	// flush on every wake (Codex debate 2026-08-08). SND_resume never reads saved volume, so the
	// reorder is safe on all platforms.
	SND_resume();
	if (GetHDMI()) {
		// buh
	}
	else {
		PLAT_enableBacklight(1);
		SetVolume(GetVolume());
	}
	// no sync() here: nothing was written during sleep, it only stalled resume
	// (the enter-sleep sync() already flushed everything before suspend)
}

// How long to stay in light faux-sleep (screen off, polling) before escalating to true
// suspend-to-RAM. Lower = cooler/less idle drain (our thesis), at the cost of slower resume.
// Tune on-device; keep the proven default until measured. See docs/deep-sleep-design.md.
#define DEEP_SLEEP_DELAY 120000 // two minutes
static void PWR_waitForWake(void) {
	uint32_t sleep_ticks = SDL_GetTicks();
	int deep_sleep_attempts = 0;
	while (!PAD_wake()) {
		if (pwr.requested_wake) {
			pwr.requested_wake = 0;
			break;
		}
		SDL_Delay(200);
		if (SDL_GetTicks()-sleep_ticks>=DEEP_SLEEP_DELAY) {
			// DEV MODE: never suspend-to-RAM and never idle-power-off (Dan, 2026-09-08). A dev
			// session must stay reachable over SSH, and deep sleep suspends the whole system (SSH
			// dies); the stay-awake flag blocks the IDLE path into here, but a POWER-press faux-sleep
			// still lands here and would escalate. Treat devmode like the charging case: reset the
			// timer and keep polling in light faux-sleep (screen off, system + SSH alive). Skipping
			// only the deep-sleep branch below would be wrong — it falls through to PWR_powerOff().
			if (flagExists(DEVMODE_PATH)) {
				sleep_ticks += 60000;
				continue;
			}
			if (pwr.is_charging) {
				sleep_ticks += 60000; // check again in a minute
				continue;
			}
			if (PLAT_supportsDeepSleep() && !exists(DEEP_SLEEP_OFF_PATH) && !exists(STAY_ALIVE_PATH)) { // ON by default; opt-out via the Deep Sleep tool (+ /tmp/stay_alive inhibit)
				int ret = PWR_deepSleep();
				if (ret==0) {
					return; // suspended and resumed
				}
				else if (deep_sleep_attempts<3) {
					// suspend can fail with EBUSY right after a resume — retry
					LOG_warn("failed to enter deep sleep - retrying in 5 seconds\n");
					sleep_ticks += 5000;
					deep_sleep_attempts++;
					continue;
				}
				else {
					LOG_warn("failed to enter deep sleep - powering off\n");
				}
			}
			if (pwr.can_poweroff) PWR_powerOff();
		}
	}

	return;
}
void PWR_sleep(void) {
	LOG_info("Entering hybrid sleep\n");

	GFX_clear(gfx.screen);
	PAD_reset();
	PWR_enterSleep();
	PWR_waitForWake();
	PWR_exitSleep();
	PAD_reset();

	pwr.resume_tick = SDL_GetTicks();
}

int PWR_deepSleep(void) {
	// Run ${BIN_PATH}/suspend if it exists (platform choreography: quiesce radios, save
	// the mixer, then `echo mem`); else fall back to the bare PLAT_deepSleep write. We
	// assume the suspend executable returns after a full suspend/resume cycle.
	char *suspend_path = BIN_PATH "/suspend";
	if (exists(suspend_path)) {
		LOG_info("suspending using platform suspend executable\n");
		int ret = system(suspend_path);
		if (ret<0) {
			LOG_error("failed to launch suspend executable: %d\n", errno);
			return -1;
		}
		LOG_info("suspend executable exited with %d\n", ret);
		return ret==0 ? 0 : -1;
	}
	return PLAT_deepSleep();
}

void PWR_disableAutosleep(void) {
	pwr.can_autosleep = 0;
}
void PWR_enableAutosleep(void) {
	pwr.can_autosleep = 1;
}
int PWR_preventAutosleep(void) {
	// Inhibit while the cell is still FILLING, not merely while a cable is attached. On a platform
	// that reports power presence (rather than charge current) as is_charging, the old test meant a
	// plugged-in device could never autosleep at any level — panel and core live indefinitely,
	// which is the opposite of this fork's thesis. Platforms that cannot distinguish the two return
	// -1 and keep the previous behaviour exactly.
	int topping = PLAT_isToppingUp();
	int charging_inhibit = (topping < 0) ? pwr.is_charging : topping;
	return charging_inhibit || !pwr.can_autosleep || GetHDMI() || exists(STAY_AWAKE_PATH);
}

// updated by PWR_updateBatteryStatus()
void PWR_requestSleep(void) {
	pwr.requested_sleep = 1; // consumed by the next PWR_update tick (same path as jack events)
}
int PWR_isCharging(void) {
	return pwr.is_charging;
}
int PWR_getBattery(void) { // 10-100 in 10-20% fragments
	return pwr.charge;
}

///////////////////////////////

// TODO: tmp? move to individual platforms or allow overriding like PAD_poll/PAD_wake?
int PLAT_setDateTime(int y, int m, int d, int h, int i, int s) {
	char cmd[512];
	// hwclock -w -u, NOT --utc -w: busybox hwclock rejects the long --utc option (rc=1, writes
	// nothing), so every time change was silently lost on reboot (the RTC kept its old value and
	// the kernel restored that). -u is required because the kernel reads the RTC as UTC at boot
	// (dmesg: "setting system clock to ... UTC"). Verified on a Brick Pro, 2026-09-01.
	sprintf(cmd, "date -s '%d-%d-%d %d:%d:%d'; hwclock -w -u", y,m,d,h,i,s);
	system(cmd);
	return 0; // why does this return an int?
}
