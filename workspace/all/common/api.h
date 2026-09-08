#ifndef __API_H__
#define __API_H__
#include "sdl.h"
#include "platform.h"
#include "scaler.h"

///////////////////////////////

enum {
	LOG_DEBUG = 0,
	LOG_INFO,
	LOG_WARN,
	LOG_ERROR,
};

#define LOG_debug(fmt, ...) LOG_note(LOG_DEBUG, fmt, ##__VA_ARGS__)
#define LOG_info(fmt, ...) LOG_note(LOG_INFO, fmt, ##__VA_ARGS__)
#define LOG_warn(fmt, ...) LOG_note(LOG_WARN, fmt, ##__VA_ARGS__)
#define LOG_error(fmt, ...) LOG_note(LOG_ERROR, fmt, ##__VA_ARGS__)
void LOG_note(int level, const char* fmt, ...);

///////////////////////////////

#define PAGE_COUNT	2
#ifndef PAGE_SCALE
#define PAGE_SCALE	3
#endif
#define PAGE_WIDTH	(FIXED_WIDTH * PAGE_SCALE)
#define PAGE_HEIGHT	(FIXED_HEIGHT * PAGE_SCALE)
#define PAGE_PITCH	(PAGE_WIDTH * FIXED_BPP)
#define PAGE_SIZE	(PAGE_PITCH * PAGE_HEIGHT)

///////////////////////////////

// TODO: these only seem to be used by a tmp.pak in trimui (model s)
// used by minarch, optionally defined in platform.h
#ifndef PLAT_PAGE_BPP
#define PLAT_PAGE_BPP 	FIXED_BPP
#endif
#define PLAT_PAGE_DEPTH (PLAT_PAGE_BPP * 8)
#define PLAT_PAGE_PITCH (PAGE_WIDTH * PLAT_PAGE_BPP)
#define PLAT_PAGE_SIZE	(PLAT_PAGE_PITCH * PAGE_HEIGHT)

///////////////////////////////

#define RGBA_MASK_AUTO	0x0, 0x0, 0x0, 0x0
#define RGBA_MASK_565	0xF800, 0x07E0, 0x001F, 0x0000
#define RGBA_MASK_8888	0x00FF0000, 0x0000FF00, 0x000000FF, 0xFF000000

///////////////////////////////

#define FALLBACK_IMPLEMENTATION __attribute__((weak)) // used if platform doesn't provide an implementation

///////////////////////////////

extern uint32_t RGB_WHITE;
extern uint32_t RGB_BLACK;
extern uint32_t RGB_LIGHT_GRAY;
extern uint32_t RGB_GRAY;
extern uint32_t RGB_DARK_GRAY;

enum {
	ASSET_WHITE_PILL,
	ASSET_BLACK_PILL,
	ASSET_DARK_GRAY_PILL,
	ASSET_OPTION,
	ASSET_BUTTON,
	ASSET_PAGE_BG,
	ASSET_STATE_BG,
	ASSET_PAGE,
	ASSET_BAR,
	ASSET_BAR_BG,
	ASSET_BAR_BG_MENU,
	ASSET_UNDERLINE,
	ASSET_DOT,
	ASSET_HOLE,
	
	ASSET_COLORS,
	
	ASSET_BRIGHTNESS,
	ASSET_VOLUME_MUTE,
	ASSET_VOLUME,
	ASSET_BATTERY,
	ASSET_BATTERY_LOW,
	ASSET_BATTERY_FILL,
	ASSET_BATTERY_FILL_LOW,
	ASSET_BATTERY_BOLT,
	
	ASSET_SCROLL_UP,
	ASSET_SCROLL_DOWN,
	
	ASSET_WIFI,
	
	ASSET_COUNT,
};

typedef struct GFX_Fonts {
	TTF_Font* large; 	// menu
	TTF_Font* medium; 	// single char button label
	TTF_Font* small; 	// button hint
	TTF_Font* tiny; 	// multi char button label
} GFX_Fonts;
extern GFX_Fonts font;

enum {
	SHARPNESS_SHARP,
	SHARPNESS_CRISP,
	SHARPNESS_SOFT,
};

enum {
	EFFECT_NONE,
	EFFECT_LINE,
	EFFECT_LINE50, // half-opacity scanlines (GLES alpha on tg5040, lighter blend in the software scalers)
	EFFECT_LINE25, // quarter-opacity scanlines
	EFFECT_GRID,
	EFFECT_GRID50, // half-opacity LCD grid
	EFFECT_GRID25, // quarter-opacity LCD grid
	EFFECT_COUNT,
};

typedef struct GFX_Renderer {
	void* src;
	void* dst;
	void* blit;
	double aspect; // 0 for integer, -1 for fullscreen, otherwise aspect ratio, used for SDL2 accelerated scaling
	int scale;
	
	// TODO: document this better
	int true_w;
	int true_h;

	int src_x;
	int src_y;
	int src_w;
	int src_h;
	int src_p;
	
	// TODO: I think this is overscaled
	int dst_x;
	int dst_y;
	int dst_w;
	int dst_h;
	int dst_p;
} GFX_Renderer;

enum {
	MODE_MAIN,
	MODE_MENU,
};

SDL_Surface* GFX_init(int mode);
#define GFX_resize PLAT_resizeVideo // (int w, int h, int pitch);
#define GFX_setScaleClip PLAT_setVideoScaleClip // (int x, int y, int width, int height)
#define GFX_setNearestNeighbor PLAT_setNearestNeighbor // (int enabled)
#define GFX_setSharpness PLAT_setSharpness // (int sharpness)
#define GFX_setEffectColor PLAT_setEffectColor // (int color)
#define GFX_setEffect PLAT_setEffect // (int effect)
void GFX_setMode(int mode);
int GFX_hdmiChanged(void);

#define GFX_clear PLAT_clearVideo // (SDL_Surface* screen)
#define GFX_clearAll PLAT_clearAll // (void)

void GFX_startFrame(void);
void GFX_flip(SDL_Surface* screen); // menu/UI/single-shot presents: never skippable (invisible-menu fix 2026-07-13)
void GFX_flipGame(SDL_Surface* screen); // game run loop ONLY: presentation-drop catch-up may skip this present
void GFX_setPresentationDrop(int enabled); // measured PS1 audio protection; disabled for other systems
SDL_Surface* PLAT_captureRendererToSurface(void); // devmode screenshot: read the live renderer to a surface (weak fallback: NULL)
void GFX_maybeScreenshot(void); // devmode-gated: on the /tmp/take_screenshot trigger file, save a PNG of the live renderer to Screenshots/. Called from GFX_flip + GFX_sync so it reaches every UI, dialog, and Tool.
#define GFX_supportsOverscan PLAT_supportsOverscan // (void)
void GFX_sync(void); // call this to maintain 60fps when not calling GFX_flip() this frame
void GFX_setPacePeriodUs(uint32_t us); // dynamic rate control: pace GFX_sync above the panel (0 = stock)
uint32_t GFX_getFlipWaitUs(void); // how long the last flip blocked on vsync (telemetry; no consumer today)
int GFX_didOverrun(void); // 1 if the most recent frame's CPU work exceeded the frame budget (telemetry; no consumer today)
uint32_t GFX_getFrameWorkUs(void); // benchmark: us of CPU work in the last frame (GFX_startFrame->GFX_flip)
void GFX_finishFrameWork(void); // present-skip: close the work sample for a frame that will not flip
void GFX_quit(void);

enum {
	VSYNC_OFF = 0,
	VSYNC_LENIENT, // default
	VSYNC_STRICT,
};

int GFX_getVsync(void);
void GFX_setVsync(int vsync);

int GFX_truncateText(TTF_Font* font, const char* in_name, char* out_name, int max_width, int padding); // returns final width
int GFX_wrapText(TTF_Font* font, char* str, int max_width, int max_lines);

#define GFX_getScaler PLAT_getScaler		// scaler_t:(GFX_Renderer* renderer)
#define GFX_blitRenderer PLAT_blitRenderer	// void:(GFX_Renderer* renderer)

scaler_t GFX_getAAScaler(GFX_Renderer* renderer);
void GFX_freeAAScaler(void);

// NOTE: all dimensions should be pre-scaled
void GFX_blitAsset(int asset, SDL_Rect* src_rect, SDL_Surface* dst, SDL_Rect* dst_rect);
void GFX_blitPill(int asset, SDL_Surface* dst, SDL_Rect* dst_rect);
void GFX_blitRect(int asset, SDL_Surface* dst, SDL_Rect* dst_rect);
void GFX_blitBattery(SDL_Surface* dst, SDL_Rect* dst_rect);
int GFX_getButtonWidth(char* hint, char* button);
void GFX_blitButton(char* hint, char*button, SDL_Surface* dst, SDL_Rect* dst_rect);
void GFX_blitMessage(TTF_Font* font, char* msg, SDL_Surface* dst, SDL_Rect* dst_rect);

int GFX_blitHardwareGroup(SDL_Surface* dst, int show_setting);
void GFX_blitHardwareHints(SDL_Surface* dst, int show_setting);
int GFX_blitButtonGroup(char** hints, int primary, SDL_Surface* dst, int align_right);

void GFX_sizeText(TTF_Font* font, char* str, int leading, int* w, int* h);
void GFX_blitText(TTF_Font* font, char* str, int leading, SDL_Color color, SDL_Surface* dst, SDL_Rect* dst_rect);

///////////////////////////////

typedef struct SND_Frame {
	int16_t left;
	int16_t right;
} SND_Frame;

void SND_reprime(void); // re-arm the prefill gate at a pause seam (menu close); see api.c
int SND_isPrefilling(void); // 1 while the launch/resume prefill gate holds the DAC paused
void SND_init(double sample_rate, double frame_rate);
size_t SND_batchSamples(const SND_Frame* frames, size_t frame_count);
void SND_setFastForward(int active, int audible);
void SND_setRateAdjustPPM(int ppm); // dynamic rate control: scale audio-paced core speed
void SND_pause(void);  // close the audio device during sleep (thread fully stops)
void SND_resume(void); // reopen after sleep at the rate negotiated in SND_init
void SND_quit(void);
// audio-health telemetry (benchmark): cumulative counters + current ring fill.
// wait_us: microsecond total of audio-backpressure blocking (the ring-full waits in
// SND_batchSamples), as a WRAP-SAFE uint32. It is deliberately not `long`: on armv7 (miyoomini)
// long is 32-bit, so a signed microsecond accumulator saturates after ~2147s of CUMULATIVE
// blocking — reachable in a couple of hours on PS1, where ~83%% of frames block — and the
// subtraction across that point yields garbage. Unsigned wraparound subtraction is exact for any
// true delta below 2^32us (~71min), which a per-frame delta never approaches.
// wait_ms survives for existing consumers, but per-frame DELTAS of a
// ms-rounded counter cannot be safely subtracted from a us work window: when rounding pushed
// the delta past the raw window the subtraction skipped, and a fully-paced frame recorded its
// whole ~20ms as "work" — which read as 1-in-6 frames over budget on PS1 games that were
// actually running at full speed (MMP, 2026-07-28: six A/B knobs including a pin-verified
// +24%% clock all "failed" to move a number that was never work).
typedef struct SND_Stats { long underruns; long overruns; long wait_ms; uint32_t wait_us; int queue_frames; int frame_count; } SND_Stats;
void SND_getStats(SND_Stats* out);
int SND_isActive(void); // audio device open and pacing (present-skip is only legal while true)

///////////////////////////////

typedef struct LID_Context {
	int has_lid;
	int is_open;
} LID_Context;
extern LID_Context lid;

void PLAT_initLid(void);
int PLAT_lidChanged(int* state);

///////////////////////////////

typedef struct PAD_Axis {
		int x;
		int y;
} PAD_Axis;
typedef struct PAD_Context {
	int is_pressed;
	int just_pressed;
	int just_released;
	int just_repeated;
	uint32_t repeat_at[BTN_ID_COUNT];
	PAD_Axis laxis;
	PAD_Axis raxis;
} PAD_Context;
extern PAD_Context pad;

#define PAD_REPEAT_DELAY	300
#define PAD_REPEAT_INTERVAL 100

#define PAD_init PLAT_initInput
#define PAD_quit PLAT_quitInput
#define PAD_poll PLAT_pollInput
#define PAD_wake PLAT_shouldWake

void PAD_setAnalog(int neg, int pos, int value, int repeat_at); // internal

void PAD_reset(void);
int PAD_anyJustPressed(void);
int PAD_anyPressed(void);
int PAD_anyJustReleased(void);

int PAD_justPressed(int btn);
int PAD_isPressed(int btn);
int PAD_justReleased(int btn);
int PAD_justRepeated(int btn);

int PAD_tappedMenu(uint32_t now); // special case, returns 1 on release of BTN_MENU within 250ms if BTN_PLUS/BTN_MINUS haven't been pressed

///////////////////////////////

void VIB_init(void);
void VIB_quit(void);
void VIB_setStrength(int strength);
 int VIB_getStrength(void);
	
///////////////////////////////

#define BRIGHTNESS_BUTTON_LABEL "+ -" // ew

typedef void (*PWR_callback_t)(void);
void PWR_init(void);
void PWR_quit(void);
void PWR_warn(int enable);

int PWR_ignoreSettingInput(int btn, int show_setting);
void PWR_update(int* dirty, int* show_setting, PWR_callback_t before_sleep, PWR_callback_t after_sleep);

void PWR_disablePowerOff(void);
void PWR_powerOff(void);
int PWR_isPoweringOff(void);

void PWR_sleep(void); // hybrid: faux-sleep, then escalate to deep sleep (was PWR_fauxSleep)
int PWR_deepSleep(void); // suspend-to-RAM via bin/suspend or PLAT_deepSleep

void PWR_disableSleep(void);
void PWR_enableSleep(void);

void PWR_disableAutosleep(void);
void PWR_enableAutosleep(void);
int PWR_preventAutosleep(void);

int PWR_isCharging(void);
void PWR_requestSleep(void); // programmatic sleep request (charging screen timeout)
int PWR_getBattery(void);

enum {
	CPU_SPEED_MENU,
	CPU_SPEED_POWERSAVE,
	CPU_SPEED_NORMAL,
	CPU_SPEED_PERFORMANCE,
};
#define PWR_setCPUSpeed PLAT_setCPUSpeed
#define PWR_setCPUMaxFreq PLAT_setCPUMaxFreq

///////////////////////////////

void PLAT_initInput(void);
void PLAT_quitInput(void);
void PLAT_pollInput(void);
int PLAT_shouldWake(void);

SDL_Surface* PLAT_initVideo(void);
void PLAT_quitVideo(void);
void PLAT_clearVideo(SDL_Surface* screen);
void PLAT_clearAll(void);
void PLAT_setVsync(int vsync);
SDL_Surface* PLAT_resizeVideo(int w, int h, int pitch);
void PLAT_setVideoScaleClip(int x, int y, int width, int height);
void PLAT_setNearestNeighbor(int enabled);
void PLAT_setSharpness(int sharpness);
void PLAT_setEffectColor(int color);
void PLAT_setEffect(int effect);
void PLAT_vsync(int remaining);
scaler_t PLAT_getScaler(GFX_Renderer* renderer);
void PLAT_blitRenderer(GFX_Renderer* renderer);
void PLAT_flip(SDL_Surface* screen, int sync);
// debug HUD strips (RGB565, native res, presented at DBG_OVERLAY_SCALE anchored to the
// game's panel rect); NULL top disables. w = used columns (game width / scale), stride =
// the buffer's allocated row width. 0xF81F = transparent.
// Platform-overridable (define in platform.h): 3x reads well on 1024x768 but is oversized
// relative to a 640x480 panel — miyoomini presents at 2x.
#ifndef DBG_OVERLAY_SCALE
#define DBG_OVERLAY_SCALE 3
#endif
void PLAT_setDebugOverlay(uint16_t* top, uint16_t* bottom, int w, int h, int stride);
// Frames currently queued to the audio DAC, or -1 if the platform cannot report it.
// MUST be called from the process that opened the device: the SigmaStar MI_AO layer tracks
// enablement per-process, so an out-of-process query always reports "not enabled".
int PLAT_getAudioQueued(void);
int PLAT_getChargePercent(void); // exact charge %, or -1 if unavailable (weak fallback: -1)
int PLAT_audioIsShared(void); // 1 when another process owns the codec (weak fallback: 0)
int PLAT_isToppingUp(void); // 1 while the cell is actually filling, -1 = cannot tell (weak fallback)
// panel-coordinate rect of the most recently presented game frame (0s before first flip)
void PLAT_getGameRect(int* x, int* y, int* w, int* h);
int PLAT_supportsOverscan(void);

SDL_Surface* PLAT_initOverlay(void);
void PLAT_quitOverlay(void);
void PLAT_enableOverlay(int enable);
	
#define PWR_LOW_CHARGE 10
void PLAT_getBatteryStatus(int* is_charging, int* charge); // 0,1 and 0,10,20,40,60,80,100
void PLAT_enableBacklight(int enable);
int PLAT_supportsDeepSleep(void); // 1 if this platform can suspend-to-RAM (weak fallback: 0)
int PLAT_deepSleep(void); // write "mem" to /sys/power/state; returns 0 on a full suspend/resume
void PLAT_powerOff(void);
	
void PLAT_setCPUSpeed(int speed); // enum (now sets the scaling_max_freq cap under schedutil)
void PLAT_setCPUMaxFreq(int khz);
// Silence the DAC across audio open/close. Analog transients (the audible POP) happen when
// the codec is enabled or torn down; platforms with a hardware mute implement this, all
// others get the weak no-op in api.c.
void PLAT_muteAudio(int mute);
// Return 1 if the audio device must NOT be closed on teardown. On SigmaStar the SDL2 MMIYOO driver
// calls MI_AO_Disable/DisableChn on close, and that power-down is an audible POP; leaving the codec
// enabled for the next process avoids the transient entirely.
int PLAT_keepAudioOpen(void);
// Force the audio device back to a closed/disabled state. Called only when opening it FAILED, to
// recover from a previous process that died without closing it. No-op where not applicable.
void PLAT_resetAudio(void); // closed-loop governor: set the cpufreq ceiling (scaling_max_freq, kHz)
int PLAT_supportsUndervolt(void); // 1 only if a confirmed runtime undervolt mechanism exists (tg5040: 0 for now)
void PLAT_setUndervolt(int millivolts); // legacy spike API, superseded by the table-driven authority below
void PLAT_setCPUVoltForCeil(int khz);   // apply the calibrated voltage covering any OPP <= (rounded-up) ceiling
void PLAT_restoreCPUVolt(void);         // always-safe stock restore (clean quit path)
void PLAT_emergencyRestoreCPUVolt(void); // lock-free variant for signal handlers ONLY
void PLAT_uvReassert(void);             // per-frame: rewrite the lean voltage if the kernel re-stocked it
void PLAT_setRumble(int strength);
void PLAT_setSystemRumble(int strength);
int PLAT_pickSampleRate(int requested, int max);

char* PLAT_getModel(void);
int PLAT_isOnline(void);
int PLAT_setDateTime(int y, int m, int d, int h, int i, int s);

#endif
