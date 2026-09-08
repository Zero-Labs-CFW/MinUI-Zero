// miyoomini
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <linux/fb.h>
#include <pthread.h>
#include <sys/ioctl.h>
#include <sys/mman.h>

#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

#include <msettings.h>

#include <linux/i2c.h>
#include <linux/i2c-dev.h>

#include "defines.h"
#include "platform.h"
#include "api.h"
#include "utils.h"
#include "scaler.h"

///////////////////////////////
// based on eggs GFXSample_rev15

#include <mi_sys.h>
#include <mi_gfx.h>
#include <mi_ao.h>   // MI_AO_Disable/DisableChn for PLAT_resetAudio

int is_560p = 0;
int is_plus = 0;
// has_axp: battery/charge come from the AXP PMIC over i2c (Plus AND Flip) rather than the
// original Mini's gpio59. Allium ships all three models off one card and maps the Flip to the
// SAME battery implementation as the Plus (Miyoo354Battery); only the original Mini gets its
// own. Keying this off is_plus alone would put a Flip on the original Mini path.
int has_axp = 0;

// Which of the TWO MMA render buffers (PAGE_COUNT==2) the frontend is currently drawing into.
// Deliberately independent of vid.page, which indexes the up-to-THREE scanout pages: indexing
// this 2-entry buffer with vid.page walks off the end of the allocation when vid.page==2.
static int mma_page = 0;

#define ALIGN4K(val)	((val+4095)&(~4095))

// NOTE: these 16bpp render targets use RGBA_MASK_565 — SDL2 requires real channel
// masks; RGBA_MASK_AUTO (0,0,0,0) was an SDL 1.2 convenience and fails there.
// SDL 1.2 let the upstream code stash the MMA physical address in SDL_Surface::unused1
// (`#define pixelsPa unused1`). SDL2 removed that field, so keep a tiny side table instead —
// only the render target and the framebuffer-page wrapper ever need a physical address.
#define PA_SLOTS 4
static struct { SDL_Surface* s; MI_PHY pa; } pa_tbl[PA_SLOTS];
static void surf_setPa(SDL_Surface* s, MI_PHY pa) {
	if (!s) return;
	for (int i=0;i<PA_SLOTS;i++) if (pa_tbl[i].s==s) { pa_tbl[i].pa=pa; return; }
	for (int i=0;i<PA_SLOTS;i++) if (!pa_tbl[i].s)   { pa_tbl[i].s=s; pa_tbl[i].pa=pa; return; }
}
static MI_PHY surf_getPa(SDL_Surface* s) {
	if (!s) return 0;
	for (int i=0;i<PA_SLOTS;i++) if (pa_tbl[i].s==s) return pa_tbl[i].pa;
	return 0;
}
static void surf_clearPa(SDL_Surface* s) {
	for (int i=0;i<PA_SLOTS;i++) if (pa_tbl[i].s==s) { pa_tbl[i].s=NULL; pa_tbl[i].pa=0; }
}

//
//	Get GFX_ColorFmt from SDL_Surface
//
static inline MI_GFX_ColorFmt_e	GFX_ColorFmt(SDL_Surface *surface) {
	if (surface) {
		if (surface->format->BytesPerPixel == 2) {
			if (surface->format->Amask == 0x0000) return E_MI_GFX_FMT_RGB565;
			if (surface->format->Amask == 0x8000) return E_MI_GFX_FMT_ARGB1555;
			if (surface->format->Amask == 0xF000) return E_MI_GFX_FMT_ARGB4444;
			if (surface->format->Amask == 0x0001) return E_MI_GFX_FMT_RGBA5551;
			if (surface->format->Amask == 0x000F) return E_MI_GFX_FMT_RGBA4444;
			return E_MI_GFX_FMT_RGB565;
		}
		if (surface->format->Bmask == 0x000000FF) return E_MI_GFX_FMT_ARGB8888;
		if (surface->format->Rmask == 0x000000FF) return E_MI_GFX_FMT_ABGR8888;
	}
	return E_MI_GFX_FMT_ARGB8888;
}

//
//	Flush write cache of needed segments
//		x and w are not considered since 4K units
//
// Range of the fbdev mmap. MI_SYS_FlushInvCache is only valid for MMA-allocated memory, and the
// framebuffer is not: flushing it takes down the process on the first present.
static void*  g_fb_base = NULL;
static size_t g_fb_len  = 0;

static inline void FlushCacheNeeded(void* pixels, uint32_t pitch, uint32_t y, uint32_t h) {
	if (g_fb_base && (uintptr_t)pixels >= (uintptr_t)g_fb_base
	              && (uintptr_t)pixels <  (uintptr_t)g_fb_base + g_fb_len) return; // fb: not MMA
	uintptr_t pixptr = (uintptr_t)pixels;
	uintptr_t startaddress = (pixptr + pitch*y)&(~4095);
	uint32_t size = ALIGN4K(pixptr + pitch*(y+h)) - startaddress;
	if (size) MI_SYS_FlushInvCache((void*)startaddress, size);
}

//
//	GFX BlitSurface (MI_GFX ver) / in place of SDL_BlitSurface
//		with scale/bpp convert and rotate/mirror
//		rotate : 1 = 90 / 2 = 180 / 3 = 270
//		mirror : 1 = Horizontal / 2 = Vertical / 3 = Both
//		nowait : 0 = wait until done / 1 = no wait
//
static inline void GFX_BlitSurfaceExec(SDL_Surface *src, SDL_Rect *srcrect, SDL_Surface *dst, SDL_Rect *dstrect, uint32_t rotate, uint32_t mirror, uint32_t nowait) {
	MI_PHY srcPa = surf_getPa(src), dstPa = surf_getPa(dst);
	if ((src)&&(dst)&&(srcPa)&&(dstPa)) {
		MI_GFX_Surface_t Src;
		MI_GFX_Surface_t Dst;
		MI_GFX_Rect_t SrcRect;
		MI_GFX_Rect_t DstRect;
		MI_GFX_Opt_t Opt;
		MI_U16 Fence;

		Src.phyAddr = srcPa;
		Src.u32Width = src->w;
		Src.u32Height = src->h;
		Src.u32Stride = src->pitch;
		Src.eColorFmt = GFX_ColorFmt(src);
		if (srcrect) {
			SrcRect.s32Xpos = srcrect->x;
			SrcRect.s32Ypos = srcrect->y;
			SrcRect.u32Width = srcrect->w;
			SrcRect.u32Height = srcrect->h;
		} else {
			SrcRect.s32Xpos = 0;
			SrcRect.s32Ypos = 0;
			SrcRect.u32Width = Src.u32Width;
			SrcRect.u32Height = Src.u32Height;
		}
		FlushCacheNeeded(src->pixels, src->pitch, SrcRect.s32Ypos, SrcRect.u32Height);

		Dst.phyAddr = dstPa;
		Dst.u32Width = dst->w;
		Dst.u32Height = dst->h;
		Dst.u32Stride = dst->pitch;
		Dst.eColorFmt = GFX_ColorFmt(dst);
		if (dstrect) {
			DstRect.s32Xpos = dstrect->x;
			DstRect.s32Ypos = dstrect->y;
			if (dstrect->w|dstrect->h) {
				DstRect.u32Width = dstrect->w;
				DstRect.u32Height = dstrect->h;
			} else {
				DstRect.u32Width = SrcRect.u32Width;
				DstRect.u32Height = SrcRect.u32Height;
			}
		} else {
			DstRect.s32Xpos = 0;
			DstRect.s32Ypos = 0;
			DstRect.u32Width = Dst.u32Width;
			DstRect.u32Height = Dst.u32Height;
		}
		if (rotate & 1) FlushCacheNeeded(dst->pixels, dst->pitch, DstRect.s32Ypos, DstRect.u32Width);
		else FlushCacheNeeded(dst->pixels, dst->pitch, DstRect.s32Ypos, DstRect.u32Height);

		memset(&Opt, 0, sizeof(Opt));
		// SDL2: blend/colorkey state moved off SDL_Surface::flags and format->{alpha,colorkey}
		// onto accessors. The present path is an opaque blit, so both are usually inactive.
		SDL_BlendMode bmode = SDL_BLENDMODE_NONE;
		SDL_GetSurfaceBlendMode(src, &bmode);
		if (bmode != SDL_BLENDMODE_NONE) {
			Uint8 amod = SDL_ALPHA_OPAQUE;
			SDL_GetSurfaceAlphaMod(src, &amod);
			Opt.eDstDfbBldOp = E_MI_GFX_DFB_BLD_INVSRCALPHA;
			if (amod != SDL_ALPHA_OPAQUE && src->format->Amask) {
				Opt.u32GlobalSrcConstColor = (amod << (src->format->Ashift - src->format->Aloss)) & src->format->Amask;
				Opt.eDFBBlendFlag = (MI_Gfx_DfbBlendFlags_e)
						   (E_MI_GFX_DFB_BLEND_SRC_PREMULTIPLY | E_MI_GFX_DFB_BLEND_COLORALPHA | E_MI_GFX_DFB_BLEND_ALPHACHANNEL);
			} else if (src->format->Amask) {
				// Per-pixel alpha with no alpha-mod: the screen-effect overlay. ALPHACHANNEL must be
				// asked for explicitly — SRC_PREMULTIPLY alone describes how the colour was stored,
				// not where the blend factor comes from, so without this the overlay blits opaque.
				Opt.eDFBBlendFlag = (MI_Gfx_DfbBlendFlags_e)
						   (E_MI_GFX_DFB_BLEND_SRC_PREMULTIPLY | E_MI_GFX_DFB_BLEND_ALPHACHANNEL);
			} else	Opt.eDFBBlendFlag = E_MI_GFX_DFB_BLEND_SRC_PREMULTIPLY;
		}
		{
			Uint32 ckey;
			if (SDL_HasColorKey(src) && SDL_GetColorKey(src, &ckey) == 0) {
				Opt.stSrcColorKeyInfo.bEnColorKey = TRUE;
				Opt.stSrcColorKeyInfo.eCKeyFmt = Src.eColorFmt;
				Opt.stSrcColorKeyInfo.eCKeyOp = E_MI_GFX_RGB_OP_EQUAL;
				Opt.stSrcColorKeyInfo.stCKeyVal.u32ColorStart =
				Opt.stSrcColorKeyInfo.stCKeyVal.u32ColorEnd = ckey;
			}
		}
		Opt.eSrcDfbBldOp = E_MI_GFX_DFB_BLD_ONE;
		Opt.eRotate = (MI_GFX_Rotate_e)rotate;
		Opt.eMirror = (MI_GFX_Mirror_e)mirror;
		Opt.stClipRect.s32Xpos = dst->clip_rect.x;
		Opt.stClipRect.s32Ypos = dst->clip_rect.y;
		Opt.stClipRect.u32Width = dst->clip_rect.w;
		Opt.stClipRect.u32Height = dst->clip_rect.h;

		MI_GFX_BitBlit(&Src, &SrcRect, &Dst, &DstRect, &Opt, &Fence);
		if (!nowait) MI_GFX_WaitAllDone(FALSE, Fence);
	} else SDL_BlitSurface(src, srcrect, dst, dstrect);
}

///////////////////////////////

#define LID_PATH "/sys/devices/soc0/soc/soc:hall-mh248/hallvalue"
void PLAT_initLid(void) {
	lid.has_lid = exists(LID_PATH);
}
int PLAT_lidChanged(int* state) {
	if (lid.has_lid) {
		int lid_open = getInt(LID_PATH);
		if (lid_open!=lid.is_open) {
			lid.is_open = lid_open;
			if (state) *state = lid_open;
			return 1;
		}
	}
	return 0;
}

// Minimal evdev ABI. We deliberately do NOT include <linux/input.h>: it defines BTN_* macros that
// collide with MinUI's own BTN_* button names in api.h.
struct zero_input_event { struct timeval time; unsigned short type; unsigned short code; int value; };
#define ZERO_EV_KEY 0x01

static pthread_t input_pt;
static int input_run = 0;
static void* input_thread(void* arg) {
	int fd = open("/dev/input/event0", O_RDONLY);
	if (fd < 0) { LOG_info("input: cannot open /dev/input/event0\n"); return NULL; }
	struct zero_input_event ev;
	while (input_run) {
		int r = read(fd, &ev, sizeof(ev));
		if (r != sizeof(ev)) { if (r < 0 && errno == EINTR) continue; break; }
		if (ev.type != ZERO_EV_KEY) continue;
		if (ev.value != 0 && ev.value != 1) continue; // ignore key repeat (value 2)
		SDL_Event e;
		memset(&e, 0, sizeof(e));
		e.type = ev.value ? SDL_KEYDOWN : SDL_KEYUP;
		e.key.state = ev.value ? SDL_PRESSED : SDL_RELEASED;
		// api.c compares keysym.sym against platform.h's CODE_* — which are EVDEV codes.
		e.key.keysym.sym = (SDL_Keycode)ev.code;
		e.key.keysym.scancode = (SDL_Scancode)ev.code;
		SDL_PushEvent(&e);
	}
	close(fd);
	return NULL;
}

// MI_AO hardware mute. Same ioctl libmsettings uses for volume 0. Unmute is deferred slightly:
// the DAC needs a moment after being enabled before it is safe to let signal through, otherwise
// we just move the pop rather than remove it.
//
// keepAudioOpen is 0. It WAS 1: SDL2's MMIYOO driver calls MI_AO_Disable/DisableChn on close, that
// power-down is the exit pop, and leaving the codec enabled did genuinely remove it (confirmed on
// device). But it breaks the NEXT open outright — MEASURED:
//     MI_AO_SetPubAttr[3364]: Dev0 failed to set pub attr!!! error number:0xa0052009
//     SDL_OpenAudio error:  — audio disabled
//     MI_AO_Enable[3413]: Dev0 has not be set pub attribute.
// MI_AO_SetPubAttr cannot reconfigure a device that is still ENABLED, and the SDL driver calls it
// unconditionally on every open. So the trade was: no exit pop, but no audio at all in the next
// game. Silence is far worse than a click, so the codec closes normally again.
//
// The pop is still worth solving, but not this way. The remaining levers are the mute discipline
// around open/close (kept, see SND_init/SND_pause) and — if that is not enough — a persistent
// holder process that owns MI_AO for the whole session, which is how every other CFW on this SoC
// does it. Do not simply flip this back to 1 without handling SetPubAttr.
// 0 = close the codec when a game exits (i.e. MI_AO_Disable runs).
//
// This costs an audible pop on exit, and we know exactly why: the pop IS the analog power-down,
// CONFIRMED BY EAR — holding the codec open made the exit pop vanish completely. Muting and
// rail-settling around the disable does nothing, because the data path was never the problem.
//
// It is still 0, because holding it open breaks the NEXT launch: game 1 has sound, game 2 is
// silent (confirmed by ear, and the same failure that forced an earlier revert). The SigmaStar
// SDL driver calls MI_AO_SetPubAttr on every open, and that cannot reconfigure a device which is
// still enabled — so the second process opens "successfully" and produces nothing.
//
// Silence is worse than a click, so this stays 0 — and it is now the FALLBACK path only.
//
// RESOLVED 2026-07-26, the second way listed below: the stock /customer/app/audioserver owns MI_AO
// for the whole session, and SDL2 reaches it through its own OSS backend (SDL_AUDIODRIVER=dsp) with
// the vendor libpadsp.so redirecting /dev/dsp. The codec then powers up once and never cycles, so
// the game-boundary pops have nothing to fire on. Selected per launch by MinUI.pak/launch.sh, which
// exports AUDIO_DAEMON=1; this function is only consulted on the direct-MMIYOO fallback, where
// closing on exit is still mandatory for the reasons above.
//
// CORRECTION to what this comment used to claim: "libpadsp segfaults binaries built by this
// toolchain" is FALSE as a blanket statement. Retested — SDL2 runs fine under it. It is true for
// some raw /dev/dsp clients (a hand-written OSS probe did segfault under it), which is why the
// preload is scoped to the game process and never exported globally.
//
// STILL UNSOLVED: automatic AUDIBILITY verification. MI_AO_QueryChnStat was built as that oracle
// and FAILED its negative control (see PLAT_getAudioQueued). The bench can only assert that
// SDL_OpenAudio returned 0, which is not the claim "sound reaches the speaker" — that gap is what
// let this regression ship twice, and it is still open.
int PLAT_keepAudioOpen(void) { return 0; }

// Force the AO device back to a closed state so a fresh SDL_OpenAudio can succeed.
//
// MEASURED (automated bench, 5 systems back to back): the FIRST game gets audio, every one after
// it fails with
//     MI_AO_SetPubAttr[3364]: Dev0 failed to set pub attr!!! error number:0xa0052009
//     MI_AO_DisableChn[3667]: Dev0 has not been enabled.
//     SDL_OpenAudio error: — audio disabled
// MI_AO_SetPubAttr cannot reconfigure a device that is still ENABLED. Any abnormal exit — a crash,
// a SIGKILL, a force-quit — skips SND_quit, so the codec stays enabled and EVERY later game is
// silent until reboot. Nothing in the normal path repairs it.
// Disabling is safe when the device is already disabled (the driver just logs "has not been
// enabled" and returns), so this is idempotent and cheap to call on the failure path.
// Frames queued to the DAC right now, or -1 if the channel is not readable.
//
// NOT AN AUDIBILITY ORACLE — this was built as one and FAILED ITS NEGATIVE CONTROL. Running the
// known-silent build (keepAudioOpen=1, where game 2 onward is silent, confirmed by ear) still
// reported frames flowing on all five systems. So the DAC consuming frames is NECESSARY BUT NOT
// SUFFICIENT for sound: the silence lives downstream of the channel queue.
//
// What it DOES prove:
//   -1 / dac=?  -> the channel is not enabled or not readable: definitely no audio
//   STALLED     -> frames queued but not being consumed: definitely no audio
//   flowing     -> the channel is alive. Says NOTHING about whether it is audible.
// Useful as a cheap negative detector; useless as a green light.
//
// Only meaningful in-process: MI_AO tracks enablement per-process, so a separate probe binary
// gets "Dev0 has not been enabled" even mid-game (measured, .notes/mmp-build/aoprobe.c).
int PLAT_getAudioQueued(void) {
	MI_AO_ChnState_t st;
	memset(&st, 0, sizeof st);
	if (MI_AO_QueryChnStat(0, 0, &st) != MI_SUCCESS) return -1;
	return (int)st.u32ChnBusyNum;
}

// Audio ownership for THIS launch, latched at process start from the launcher.
//   AUDIO_DAEMON=1 -> the vendor audioserver owns the codec and outlives us; we are only an OSS
//                     client (SDL dsp driver + libpadsp).
//   AUDIO_DAEMON=0 -> direct MMIYOO: this process owns the codec, exactly as before.
//
// Latched in a constructor, not read on use, because the readers are SIGNAL HANDLERS
// (Term_handler/Crash_handler -> PLAT_resetAudio) and getenv() is not async-signal-safe. A
// constructor also runs before any handler can fire, so there is no ordering assumption.
static int audio_daemon_mode = 0;
__attribute__((constructor)) static void latch_audio_mode(void) {
	const char* e = getenv("AUDIO_DAEMON");
	audio_daemon_mode = (e && e[0] == '1');
}

// The codec belongs to audioserver in daemon mode, so device-global audio state (mute, disable) is
// not ours to change. Shared by PLAT_resetAudio below and by PWR_enterSleep via the api.c seam.
int PLAT_audioIsShared(void) { return audio_daemon_mode; }

void PLAT_resetAudio(void) {
	if (audio_daemon_mode) {
		// NOT OURS TO TEAR DOWN. The daemon owns the codec and survives this process, so disabling
		// it here would power down hardware still in use — and that transition IS the pop this
		// design exists to remove.
		//
		// Muting is equally wrong: MI_AO_SETMUTE is device-global, and in daemon mode nothing
		// unmutes per game (the daemon is already up), so a mute on exit would silence every
		// LATER game. Closing our own OSS stream is all we are entitled to do, and process exit
		// does that for us.
		return;
	}
	// Direct-MMIYOO path (including the explicit dead-daemon fallback): unchanged, and still
	// REQUIRED. libmi_ao tracks enablement per process, and a process that dies without disabling
	// leaves the codec wedged with no userspace way back — every later game silent until reboot
	// (measured across a reboot, 5 systems; see Crash_handler in minarch.c).
	//
	// Mute and let the rail settle BEFORE removing power. Disabling a live output stage is a step
	// discontinuity — the pop. The enable path mutes first for the same reason; this is its mirror.
	// PLAT_muteAudio already carries the settle delay, so no extra sleep here.
	PLAT_muteAudio(1);
	MI_AO_DisableChn(0, 0);
	MI_AO_Disable(0);
}

#define MI_AO_SETMUTE_IOCTL 0x4008690d
// Rail-settle window, both directions. The enable path in libmsettings already waits ~40ms
// between bringing the channel up and unmuting, for exactly this reason: the analog stage does
// not follow the digital gate instantly.
#define MI_AO_SETTLE_US 40000
void PLAT_muteAudio(int mute) {
	int fd = open("/dev/mi_ao", O_RDWR);
	if (fd < 0) return;
	if (!mute) usleep(60000); // let the rail settle before unmuting
	int buf2[] = {0, mute ? 1 : 0};
	uint64_t buf1[] = {sizeof(buf2), (uintptr_t)buf2};
	ioctl(fd, MI_AO_SETMUTE_IOCTL, buf1);
	close(fd);
	// SETTLE AFTER MUTING TOO. Every caller that mutes is about to tear the codec down
	// (SND_quit -> SDL_CloseAudio -> MI_AO_Disable, PWR_enterSleep, PLAT_resetAudio). Returning
	// the instant the ioctl lands meant the power-down hit an output stage that was still
	// settling, which is audible as the exit pop. Symmetric with the unmute side above.
	if (mute) usleep(MI_AO_SETTLE_US);
}

void PLAT_initInput(void) {
	// api.c PAD_poll also handles SDL_JOYBUTTON*; harmless when no joystick exists.
	SDL_InitSubSystem(SDL_INIT_JOYSTICK);
	if (SDL_NumJoysticks() > 0) SDL_JoystickOpen(0);
	input_run = 1;
	if (pthread_create(&input_pt, NULL, input_thread, NULL) != 0) {
		input_run = 0;
		LOG_info("input: pump thread failed to start\n");
	}
}
void PLAT_quitInput(void) {
	input_run = 0; // thread exits on its next read (or when the fd closes at process exit)
	SDL_QuitSubSystem(SDL_INIT_JOYSTICK);
}

///////////////////////////////

// MMA render-buffer page size.
// The frontend calls GFX_resize(dst_w, dst_h, dst_p) with the SCALED GAME buffer size
// (minarch.c: `screen = GFX_resize(dst_w,dst_h,dst_p)`, `dst_p = dst_w * FIXED_BPP`), and then
// writes straight into screen->pixels. So this page must hold the LARGEST scaled buffer, not just
// one panel. Upstream reserved PAGE_SCALE(=3) squared (5.5MB/page) for exactly that reason.
//
// I originally shrank this to one panel (614KB) because upstream's 10.5MB request failed against
// the ~6MB free in mma_heap_name0 — and that was the bug behind the garbage band: NES at 3x is
// 768x672 (~1MB), so the frontend wrote past the end of the page into the next one, and we
// presented the overflow. GBC stayed under a panel's worth, which is why it looked clean.
//
// 4x panel area per page (2.4MB for both pages) covers every integer scale the frontend picks
// here while still fitting the heap. resizeVideo hard-checks the request against it.
#define MMA_PAGE ALIGN4K(FIXED_PITCH * FIXED_HEIGHT * 4)

typedef struct HWBuffer {
	MI_PHY padd;
	void* vadd;
} HWBuffer;

static struct VID_Context {
	SDL_Surface* video;   // presentation target: a wrapper around the CURRENT fb page
	SDL_Surface* screen;  // render target handed to the frontend (MMA-backed, MI_GFX-blittable)
	HWBuffer buffer;

	int page;
	int width;
	int height;
	int pitch;

	int direct;
	int cleared;

	// fbdev presentation (SDL2 has no SDL_SetVideoMode/SDL_Flip, and this SoC's SDL2 video
	// driver refuses to init while another process owns the panel — MEASURED: "No available
	// video device". MyMinUI uses raw fbdev here too, so this is the proven path.)
	int fdfb;
	struct fb_fix_screeninfo finfo;
	struct fb_var_screeninfo vinfo;
	void* fbmmap;
	size_t fbsize;
	int page_bytes;       // bytes per visible page (line_length * yres)
	int pages;            // scanout pages the driver actually gave us (2 or 3)
} vid;

// Point vid.video at framebuffer page `page`. pixelsPa carries the PHYSICAL address so
// GFX_BlitSurfaceExec can hand it to MI_GFX and let the 2D engine scale straight into scanout.
static void fb_bindPage(int page) {
	vid.video->pixels   = (uint8_t*)vid.fbmmap + (size_t)page * vid.page_bytes;
	surf_setPa(vid.video, vid.finfo.smem_start + (size_t)page * vid.page_bytes);
}
// Returns 0 on success. The status MATTERS: page ownership may only advance on a pan that actually
// happened. Promoting active->front after a failed ioctl would hand the producer a page the panel
// is still scanning.
static int fb_pan(int page) {
	vid.vinfo.yoffset = vid.vinfo.yres * page;
	// activate is REQUIRED: without it some fbdev drivers accept the ioctl but never latch the
	// new yoffset, so the panel keeps scanning the old page while memory updates invisibly.
	vid.vinfo.activate = FB_ACTIVATE_VBL;
	return ioctl(vid.fdfb, FBIOPAN_DISPLAY, &vid.vinfo);
}

#define MODES_PATH "/sys/class/graphics/fb0/modes"
static int hasMode(const char *path, const char *mode) {
    FILE *f = fopen(path, "r"); if (!f) return 0;
    char s[128];
    while (fgets(s, sizeof s, f)) if (strstr(s, mode)) return fclose(f), 1;
    fclose(f); return 0;
}

// Reclaim MMA chunks orphaned by a process that died without freeing them.
//
// The SigmaStar MMA heap does no owner tracking across process death: if minarch is SIGKILLed or
// crashes, its render buffer stays allocated until reboot. Two or three of those exhaust the heap
// and then EVERY game fails to start with "MMA_Alloc failed" — the classic "black screen until I
// reboot" report. Parsing /proc and freeing by physical address is how eggs' freemma() solves it
// (OnionOS src/clock/gfx.c); the exclusion list below is copied from there and is load-bearing:
//   fb_device    — the framebuffer itself; freeing it kills the display
//   ao-Dev0-tmp  — the audio buffer
//   daemon*      — anything a long-lived helper declared as persistent
// The proc table gives heap-relative offsets, so the physical base is recovered from the known
// physical address of the fb_device chunk.
// Returns the number of chunks freed.
static int mmp_reclaimMMA(void) {
	FILE* fp = fopen("/proc/mi_modules/mi_sys_mma/mma_heap_name0", "r");
	if (!fp) return 0;
	char str[256];
	// skip the header; the chunk table starts after the "sys-logConfig" row
	do { if (fscanf(fp, "%255s", str) == EOF) { fclose(fp); return 0; } }
	while (strcmp(str, "sys-logConfig"));

	uint32_t offset, length, used;
	MI_PHY base = 0;
	int freed = 0;
	// first pass would be ideal, but the fb row appears before the app rows in practice and we
	// need its base before freeing anything, so bail out of freeing until we have it.
	while (fscanf(fp, "%x %x %x %255s", &offset, &length, &used, str) != EOF) {
		if (!used) continue;
		if (!strcmp(str, "fb_device")) { base = vid.finfo.smem_start - offset; continue; }
		if (!strcmp(str, "ao-Dev0-tmp")) continue;   // audio
		if (!strncmp(str, "daemon", 6)) continue;    // declared persistent
		if (!base) continue;                          // no physical base yet — cannot free safely
		if (MI_SYS_MMA_Free(base + offset) == MI_SUCCESS) {
			LOG_info("mi_sys: reclaimed stale chunk %s (%u bytes)\n", str, length);
			freed++;
		}
	}
	fclose(fp);
	return freed;
}

static void mmpFlipStart(void); // async flip thread; defined with the flip machinery below
static void mmpFlipStop(void);

static pthread_mutex_t flip_mx  = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  flip_req = PTHREAD_COND_INITIALIZER;
static pthread_cond_t  flip_ack = PTHREAD_COND_INITIALIZER;
// PAGE OWNERSHIP. Every page is in exactly one of these states, and the producer may only draw
// into a page owned by NONE of them.
//
// The bug this replaces: only `pending` and `active` existed, so the page being SCANNED OUT was
// tracked by nothing. With front=0/active=1/pending=2 the producer computed back=(2+1)%3=0, the
// guard tested only active and pending, and MI_GFX blitted a whole frame into the page on screen.
// Reproducible tearing, invisible to every counter (nothing was dropped). The old comment on the
// guard even claimed "never draw into the page that is on screen" — it could not, because no
// variable held that page.
//
// Why three pages still suffice: front + active + pending may legitimately own all three, and the
// correct response is for the producer to BLOCK before binding a page, not to find a fourth. The
// panner can always make progress without the producer, so this cannot deadlock.
static int flip_front   = 0;   // page currently scanned out by the panel — NEVER writable
static int flip_rendering = -1; // page reserved by the producer for an in-flight MI_GFX blit
static int flip_pending = -1;  // page awaiting pan, -1 = none
static unsigned flip_frames  = 0; // frames handed to the flip thread
static unsigned flip_dropped = 0; // frames COALESCED AWAY: a newer frame replaced an unpanned
                                  // one, so the older frame was never scanned out. This is the
                                  // cost of not blocking the producer, and it must be measured,
                                  // not assumed — dropped frames are invisible to an fps counter.
static int flip_active  = -1;  // page currently being panned, -1 = none
static int flip_run     = 0;
static int flip_scrub   = 0;   // pages still owed a zero (see fb_scrubPages)

// Zero the framebuffer WITHOUT writing into the page the panel is scanning.
//
// PLAT_clearAll used to memset the whole mmap unconditionally. That is the SAME defect the ownership
// state machine above exists to prevent, arriving through a different door: it blacked out the front
// page mid-scan, could erase a pending frame so a black one got presented, and could race a pan in
// flight. It is not a rare path either — GFX_clearAll has five callers in shared minarch code
// (geometry change, menu open, HUD toggle-off), so it fires mid-game on every system.
//
// A mutex cannot fix it, because the panel keeps scanning the front page regardless of what any
// thread holds. So: clear the pages nobody owns right now, and DEFER the rest to PLAT_flip, which
// zeroes each page it has exclusively reserved until the debt is paid. Every page becomes
// producer-owned within a few frames, so the clear completes without ever touching live scanout.
// Caller holds flip_mx, or has stopped the panner.
static void fb_scrubPages(void) {
	if (!vid.fbmmap || vid.fbmmap == MAP_FAILED) return;
	for (int i = 0; i < vid.pages; i++) {
		if (i == flip_front || i == flip_active || i == flip_pending) continue;
		memset((uint8_t*)vid.fbmmap + (size_t)i * vid.page_bytes, 0, vid.page_bytes);
	}
	flip_scrub = vid.pages; // each page still gets zeroed once it is safely ours
}

SDL_Surface* PLAT_initVideo(void) {
	is_plus = exists("/customer/app/axp_test");
	has_axp = is_plus || exists(LID_PATH); // Plus, or Flip (clamshell hall sensor)
	is_560p = hasMode(MODES_PATH, "752x560p") && exists(USERDATA_PATH "/enable-560p");
	LOG_info("is 560p: %i\n", is_560p);
	
	// SDL2: timers only. We do NOT init SDL video — this SoC's only SDL2 video driver (mmiyoo)
	// fails with "No available video device" when anything else owns the panel, and we present
	// through fbdev anyway. Audio is initialized separately by SND_init (driver: MMIYOO).
	// SDL2 delivers keyboard events through the VIDEO subsystem's input backend, and this device's
	// buttons are gpio_keys on the kbd handler. Without VIDEO, SDL_PollEvent never reports a button
	// and the game is uncontrollable. We still present through fbdev ourselves; VIDEO is initialized
	// for its input plumbing. If the mmiyoo video driver refuses (it does while another process owns
	// the panel), fall back so we at least keep rendering.
	if (SDL_Init(SDL_INIT_TIMER | SDL_INIT_EVENTS | SDL_INIT_VIDEO) < 0) {
		LOG_info("SDL: video init failed (%s) - input may not work; continuing\n", SDL_GetError());
		SDL_Init(SDL_INIT_TIMER | SDL_INIT_EVENTS);
	}

	// --- fbdev: 32bpp, TRIPLE-buffered where the reservation allows ---
	// FBIOPAN_DISPLAY BLOCKS ~16.76ms on this driver (measured, both activate flags). With only
	// two pages the render thread pays that stall every frame, so ONE late frame costs a whole
	// extra frame and the rate halves. MEASURED on GBC — the lightest core we ship, ~8% load —
	// dropping to exactly 29.8fps (59.7/2) with the audio ring backing up. A third page plus an
	// async flip thread lets the producer hand the pan off and keep working.
	// Room check: the fb reservation is 0x400000 (4MB); 3 x 640x480x4 = 3.69MB fits. We still
	// verify what the driver actually accepted and fall back to 2 pages if it refused.
	vid.fdfb = open("/dev/fb0", O_RDWR);
	ioctl(vid.fdfb, FBIOGET_FSCREENINFO, &vid.finfo);
	ioctl(vid.fdfb, FBIOGET_VSCREENINFO, &vid.vinfo);
	vid.vinfo.xres = FIXED_WIDTH;
	vid.vinfo.yres = FIXED_HEIGHT;
	vid.vinfo.xres_virtual = FIXED_WIDTH;
	vid.vinfo.yres_virtual = FIXED_HEIGHT * 3;
	vid.vinfo.bits_per_pixel = 32;
	vid.vinfo.yoffset = 0;
	vid.vinfo.activate = FB_ACTIVATE_NOW;
	if (ioctl(vid.fdfb, FBIOPUT_VSCREENINFO, &vid.vinfo) < 0) {
		// driver refused 3 pages — ask for the 2 we know work
		vid.vinfo.yres_virtual = FIXED_HEIGHT * 2;
		ioctl(vid.fdfb, FBIOPUT_VSCREENINFO, &vid.vinfo);
	}
	ioctl(vid.fdfb, FBIOBLANK, FB_BLANK_UNBLANK); // previous owner may have blanked the panel
	ioctl(vid.fdfb, FBIOGET_FSCREENINFO, &vid.finfo);
	ioctl(vid.fdfb, FBIOGET_VSCREENINFO, &vid.vinfo);

	// Trust what the driver reports, never what we asked for.
	vid.pages = vid.vinfo.yres ? (int)(vid.vinfo.yres_virtual / vid.vinfo.yres) : 1;
	if (vid.pages < 1) vid.pages = 1;
	if (vid.pages > 3) vid.pages = 3;

	vid.page_bytes = vid.finfo.line_length * vid.vinfo.yres;
	vid.fbsize     = (size_t)vid.page_bytes * vid.pages;
	if (vid.finfo.smem_len && vid.fbsize > vid.finfo.smem_len) {
		// reservation smaller than the geometry implies — clamp rather than map past the end
		vid.pages  = vid.finfo.smem_len / vid.page_bytes;
		vid.fbsize = (size_t)vid.page_bytes * vid.pages;
	}
	LOG_info("fb: %d page(s), yres_virtual=%d smem_len=%u\n",
		vid.pages, vid.vinfo.yres_virtual, (unsigned)vid.finfo.smem_len);
	vid.fbmmap     = mmap(NULL, vid.fbsize, PROT_READ|PROT_WRITE, MAP_SHARED, vid.fdfb, 0);
	g_fb_base = vid.fbmmap; g_fb_len = vid.fbsize;
	memset(vid.fbmmap, 0, vid.fbsize);
	LOG_info("fb: %dx%d %dbpp line=%d phys=%p\n", vid.vinfo.xres, vid.vinfo.yres,
		vid.vinfo.bits_per_pixel, vid.finfo.line_length, (void*)vid.finfo.smem_start);

	// Wrapper surface over a page; pixels + physical address are re-pointed per flip by
	// fb_bindPage(). NOTE: must be created with a REAL pointer — SDL2's CreateRGBSurfaceFrom
	// dereferences it (SDL 1.2 tolerated NULL, which is what upstream passed).
	vid.video = SDL_CreateRGBSurfaceFrom(vid.fbmmap, FIXED_WIDTH, FIXED_HEIGHT, 32,
		vid.finfo.line_length, 0x00FF0000,0x0000FF00,0x000000FF,0xFF000000); // ARGB (fbset: r@16 g@8 b@0 a@24)
	if (!vid.video) LOG_info("fb: SDL_CreateRGBSurfaceFrom failed: %s\n", SDL_GetError());
	fb_bindPage(0);

	// The MI (SigmaStar) layer used to be initialized for us by the custom SDL 1.2 inside
	// SDL_Init(SDL_INIT_VIDEO). We no longer init SDL video, so bring MI_SYS/MI_GFX up here.
	// Without this MI_SYS_MMA_Alloc silently returns NULL (MEASURED: vadd=(nil) padd=0) and
	// the first memset on the render buffer segfaults.
	if (MI_SYS_Init() != MI_SUCCESS) LOG_info("mi_sys: MI_SYS_Init FAILED\n");
	if (MI_GFX_Open() != MI_SUCCESS) LOG_info("mi_gfx: MI_GFX_Open FAILED\n");

	int buffer_size = ALIGN4K(MMA_PAGE) * PAGE_COUNT;
	// Name the heap explicitly. Passing NULL relied on the custom SDL having already selected a
	// default heap; on its own it returns NULL here. The device exposes exactly one:
	// /proc/mi_modules/mi_sys_mma/mma_heap_name0 (21MB total, ~6MB free at the menu).
	MI_S32 mma_rc = MI_SYS_MMA_Alloc((MI_U8*)"mma_heap_name0", ALIGN4K(buffer_size), &vid.buffer.padd);
	if (mma_rc != MI_SUCCESS) {
		LOG_info("mi_sys: MMA_Alloc(mma_heap_name0, %d) failed rc=%d, retrying default heap\n", ALIGN4K(buffer_size), mma_rc);
		mma_rc = MI_SYS_MMA_Alloc(NULL, ALIGN4K(buffer_size), &vid.buffer.padd);
	}
	if (mma_rc != MI_SUCCESS) {
		// Heap exhausted — almost always because a PREVIOUS minarch was killed or crashed. The
		// SigmaStar MMA heap has no owner tracking across process death: a SIGKILL leaks the whole
		// render buffer (4.9MB here) permanently, and after two or three of those NOTHING can
		// allocate and every game fails to start until reboot.
		// MEASURED: the automated bench force-killed each core and the heap went 1 -> 2 -> 3 stale
		// "app-mmaAlloc" chunks, after which MMA_Alloc returned failure for everyone.
		//
		// Reclaim stale chunks and retry once. Unlike Onion's freemma (which sweeps
		// unconditionally at every init) this only runs when we are ALREADY stuck, so a chunk
		// belonging to a live process is never freed out from under it.
		// Exclusions are load-bearing and come from eggs' original: never free the framebuffer,
		// the audio buffer, or anything a daemon declared.
		LOG_info("mi_sys: MMA_Alloc failed (rc=%d) — reclaiming stale chunks\n", mma_rc);
		int reclaimed = mmp_reclaimMMA();
		LOG_info("mi_sys: reclaimed %d stale chunk(s)\n", reclaimed);
		if (reclaimed > 0) {
			mma_rc = MI_SYS_MMA_Alloc((MI_U8*)"mma_heap_name0", ALIGN4K(buffer_size), &vid.buffer.padd);
			if (mma_rc != MI_SUCCESS)
				mma_rc = MI_SYS_MMA_Alloc(NULL, ALIGN4K(buffer_size), &vid.buffer.padd);
		}
	}
	if (mma_rc != MI_SUCCESS) {
		// Still nothing. Everything downstream assumes vadd is valid — the memset below
		// dereferences it directly — so bail loudly instead of segfaulting at startup with no
		// explanation.
		LOG_error("mi_sys: MMA_Alloc failed on every heap (rc=%d) — cannot bring up video\n", mma_rc);
		vid.buffer.vadd = NULL;
		return NULL;
	}
	if (MI_SYS_Mmap(vid.buffer.padd, ALIGN4K(buffer_size), &vid.buffer.vadd, true) != MI_SUCCESS
	    || !vid.buffer.vadd) {
		LOG_error("mi_sys: MMA_Mmap failed for padd=%llx — cannot bring up video\n",
			(unsigned long long)vid.buffer.padd);
		MI_SYS_MMA_Free(vid.buffer.padd);
		vid.buffer.vadd = NULL;
		return NULL;
	}

	// Front page comes from what the DRIVER reports, never from an assumption. This was `vid.page
	// = 1` while the hardware reported yoffset 0, i.e. the code disagreed with the panel about
	// which page was on screen before a single frame was drawn.
	vid.page = 0;
	flip_front = (vid.vinfo.yres && vid.vinfo.yoffset % vid.vinfo.yres == 0)
		? (int)(vid.vinfo.yoffset / vid.vinfo.yres) : 0;
	if (flip_front < 0 || flip_front >= vid.pages) flip_front = 0;
	flip_active = flip_pending = flip_rendering = -1;
	// The frontend renders RGB565 (FIXED_DEPTH) everywhere. Upstream could return vid.video
	// because SDL 1.2's SDL_SetVideoMode produced a 16bpp surface and the custom SDL converted
	// on flip. Our vid.video now wraps the RAW 32bpp framebuffer, so returning it is a depth
	// mismatch (observed: 'Unknown pixel format' + 'SDL_UpperBlit: passed a NULL surface').
	// Always render into the MMA-backed RGB565 screen and let MI_GFX convert 565->ARGB8888
	// during the present blit; format conversion is free in the 2D engine.
	vid.direct = 0;
	vid.width = FIXED_WIDTH;
	vid.height = FIXED_HEIGHT;
	vid.pitch = FIXED_PITCH;
	vid.cleared = 0;
	
	LOG_info("mi_sys: MMA vadd=%p padd=%llx\n", vid.buffer.vadd, (unsigned long long)vid.buffer.padd);
	vid.screen = SDL_CreateRGBSurfaceFrom(vid.buffer.vadd + ALIGN4K(mma_page*MMA_PAGE),vid.width,vid.height,FIXED_DEPTH,vid.pitch,RGBA_MASK_565);
	surf_setPa(vid.screen, vid.buffer.padd + ALIGN4K(mma_page*MMA_PAGE));
	memset(vid.screen->pixels, 0, vid.pitch * vid.height);

	mmpFlipStart(); // async pan, if the driver gave us 3 pages

	return vid.direct ? vid.video : vid.screen;
}

void PLAT_quitVideo(void) {
	mmpFlipStop(); // must be first: the thread pans through vid.fdfb/vid.vinfo

	// Free the PA side-table slots too. It only has PA_SLOTS entries; leaking two per
	// init->quit cycle eventually exhausts it, after which surf_setPa silently no-ops,
	// surf_getPa returns 0, and GFX_BlitSurfaceExec falls back to SDL_BlitSurface — which does
	// NO rotation. Symptom would be an upside-down screen with no diagnostic whatsoever.
	surf_clearPa(vid.screen);
	surf_clearPa(vid.video);

	SDL_FreeSurface(vid.screen);

	if (vid.video) { vid.video->pixels = NULL; SDL_FreeSurface(vid.video); vid.video = NULL; }

	// Hand the panel back on PAGE 0 before we go. We page-flip, so we may well be scanning out
	// page 1 at exit — while show.elf / batmon.elf / blank.elf all write page 0 and never touch
	// yoffset. Exiting on page 1 makes their images invisible (the charging screen and the
	// transition art simply never appear).
	if (vid.fdfb > 0) {
		vid.vinfo.yoffset = 0;
		vid.vinfo.activate = FB_ACTIVATE_NOW;
		ioctl(vid.fdfb, FBIOPAN_DISPLAY, &vid.vinfo);
	}

	if (vid.fbmmap && vid.fbmmap != MAP_FAILED) {
		memset(vid.fbmmap, 0, vid.fbsize);   // leave a black panel, not the last frame
		munmap(vid.fbmmap, vid.fbsize);
		vid.fbmmap = NULL;
	}
	// Deliberately `> 0`, not `>= 0`: vid is zero-initialised, so fdfb==0 means "never opened".
	// Treating 0 as valid here would close STDIN on a teardown that ran without a successful init.
	if (vid.fdfb > 0) { close(vid.fdfb); vid.fdfb = 0; }

	// Unmap what we actually mapped: initVideo maps ALIGN4K(MMA_PAGE) * PAGE_COUNT, not one page.
	MI_SYS_Munmap(vid.buffer.vadd, ALIGN4K(ALIGN4K(MMA_PAGE) * PAGE_COUNT));
	MI_SYS_MMA_Free(vid.buffer.padd);
	MI_GFX_Close();
	// Pair MI_SYS_Init() from PLAT_initVideo. This used to be masked by accident: SDL2's
	// MMIYOO_VideoQuit calls MI_SYS_Exit — but that backend never initializes here
	// (SDL_VIDEODRIVER is unset, so MMIYOO_Available() returns 0 and video init fails by design),
	// so nothing was ever unwinding MI_SYS.
	MI_SYS_Exit();

	// SDL_Quit() tears down EVERY initialized subsystem — including audio, which SDL_OpenAudio
	// brought up implicitly. SDL_AudioQuit closes the device, and the MMIYOO driver's CloseDevice
	// fires MI_AO_Disable/MI_AO_DisableChn: exactly the codec power-down that PLAT_keepAudioOpen()
	// exists to prevent. So SND_quit's careful "don't close the audio device" was undone two calls
	// later, and the exit pop survived. Quit only the subsystems we actually initialized and leave
	// the codec enabled; the kernel reclaims our fds at process exit without a disable ioctl, and
	// keymon.elf keeps /dev/mi_ao open regardless.
	if (PLAT_keepAudioOpen()) SDL_QuitSubSystem(SDL_INIT_TIMER | SDL_INIT_EVENTS | SDL_INIT_VIDEO);
	else SDL_Quit();
}

void PLAT_clearVideo(SDL_Surface* screen) {
	MI_SYS_FlushInvCache(vid.buffer.vadd + ALIGN4K(mma_page*MMA_PAGE), ALIGN4K(MMA_PAGE));
	MI_SYS_MemsetPa(vid.buffer.padd + ALIGN4K(mma_page*MMA_PAGE), 0, MMA_PAGE);
	SDL_FillRect(screen, NULL, 0);
	// memset(screen->pixels, 0, MMA_PAGE); // this causes crashing
}
void PLAT_clearAll(void) {
	// Clear the FRAMEBUFFER too, not just the render buffer. The present blit only covers the
	// game rect, so whatever sits in the letterbox/pillarbox region persists across a geometry
	// change (previous system's frame, or anything else that wrote to fb0). initVideo zeroes the
	// fb once at startup; this keeps it clean when the geometry changes mid-session.
	if (flip_run) {
		pthread_mutex_lock(&flip_mx);
		fb_scrubPages();
		pthread_mutex_unlock(&flip_mx);
	}
	else fb_scrubPages();

	PLAT_clearVideo(vid.screen); // clear backbuffer
	vid.cleared = 1; // defer clearing frontbuffer until offscreen
}

// "Prevent Tearing" is REAL on this platform now. It used to be a no-op — the option existed in
// the menu and did nothing, which is worse than not offering it.
//
// With the async flip thread the producer hands a page over and carries on. If it produces another
// frame before the panner has scanned the previous one out, the pending page is replaced and the
// older frame is never displayed (MEASURED: ~1.4% of frames). That is the right default — the
// alternative is the render thread eating the full 16.76ms pan, which is what used to halve GBC to
// 29.8fps. But it IS a dropped frame, so STRICT lets the user choose the other side of the trade:
//   STRICT  -> producer waits for the pan to complete: nothing is ever dropped, at the cost of the
//              stall (classic vsync).
//   LENIENT -> coalesce; newest frame wins. Default.
//   OFF     -> same as lenient here; there is no un-synced pan on this driver (FBIOPAN_DISPLAY
//              blocks regardless of the activate flag — measured on both).
static int flip_block = 0; // 1 = STRICT: never coalesce
void PLAT_setVsync(int vsync) {
	flip_block = (vsync == VSYNC_STRICT);
	LOG_info("fb: vsync=%d (%s)\n", vsync, flip_block ? "strict: wait for pan, drop nothing"
	                                                   : "lenient: coalesce, newest frame wins");
}

SDL_Surface* PLAT_resizeVideo(int w, int h, int pitch) {
	// QUIESCE THE PANNER FIRST. Everything below is hostile to a pan in flight: it memsets every
	// framebuffer page, frees vid.screen, and re-points it at a different MMA offset. The async
	// flip thread meanwhile may be inside fb_pan() on a page we are about to zero, or holding a
	// flip_pending index for one.
	//
	// This is a real, user-visible bug, not theory: entering the in-game menu calls GFX_resize
	// (minarch Menu_loop), so pressing MENU raced the panner and INTERMITTENTLY presented a
	// half-zeroed page — reported from device as "sometimes when I hit the menu button" with a
	// screen of blue garbage instead of the menu.
	//
	// mmpFlipStop() joins the thread (it does not cancel it), so once it returns no pan can be in
	// flight and no page index is held. Restarted at the bottom. Resizes are rare — menu open and
	// close, plus core geometry changes — so a thread teardown here costs nothing measurable.
	mmpFlipStop();

	// Geometry change => the region the present blit covers changes too. Anything outside the new
	// game rect (letterbox/pillarbox) would otherwise keep showing the PREVIOUS content, which is
	// the glitchy band. Clear BOTH framebuffer pages here; per-frame clearing would be wasteful.
	fb_scrubPages(); // panner is joined above, but the PANEL is still scanning flip_front

	vid.direct = 0; // see PLAT_initVideo: the frontend always gets the RGB565 surface
	vid.width = w;
	vid.height = h;
	vid.pitch = pitch;
	
	if (vid.direct) memset(vid.video->pixels, 0, vid.pitch * vid.height);
	else {
		vid.screen->pixels = NULL;
		surf_clearPa(vid.screen);
		SDL_FreeSurface(vid.screen);
		
		if (vid.pitch <= 0) {
			// Guard the division below: a pitch of 0 would SIGFPE rather than clamp.
			LOG_info("resizeVideo: refusing pitch=%d (%dx%d)\n", vid.pitch, vid.width, vid.height);
			vid.pitch = vid.width * FIXED_BPP;
		}
		if ((size_t)vid.pitch * vid.height > (size_t)MMA_PAGE) {
			// Clamp the surface height so we never advertise more page than we own.
			// NOTE: this is only ACTUALLY protective because minarch re-reads screen->h after
			// GFX_resize and lowers renderer.dst_h to match. The scalers take dst_h as a
			// parameter and never consult the surface, so clamping here alone would have hidden
			// the garbage band while the overflow continued — which is what it did before.
			int max_h = (int)((size_t)MMA_PAGE / (size_t)vid.pitch);
			LOG_info("resizeVideo: %dx%d p=%d needs %zu > MMA_PAGE %d — clamping height to %d\n",
				vid.width, vid.height, vid.pitch, (size_t)vid.pitch * vid.height, (int)MMA_PAGE, max_h);
			vid.height = max_h > 0 ? max_h : 1;
		}
		vid.screen = SDL_CreateRGBSurfaceFrom(vid.buffer.vadd + ALIGN4K(mma_page*MMA_PAGE),vid.width,vid.height,FIXED_DEPTH,vid.pitch,RGBA_MASK_565);
		surf_setPa(vid.screen, vid.buffer.padd + ALIGN4K(mma_page*MMA_PAGE));
		memset(vid.screen->pixels, 0, vid.pitch * vid.height);
	}

	mmpFlipStart(); // buffers are stable again; resume async panning

	return vid.direct ? vid.video : vid.screen;
}

void PLAT_setVideoScaleClip(int x, int y, int width, int height) {
	// buh
}
void PLAT_setNearestNeighbor(int enabled) {
	// buh
}
static int next_effect = EFFECT_NONE;
static int effect_type = EFFECT_NONE;
void PLAT_setSharpness(int sharpness) {
	// force effect to reload
	// on scaling change
	if (effect_type>=EFFECT_NONE) next_effect = effect_type;
	effect_type = -1;
}

void PLAT_setEffect(int effect) {
	next_effect = effect;
}

///////////////////////////////
// SCREEN EFFECT OVERLAY — composited by MI_GFX, not drawn by the CPU.
//
// v1.7.5 shipped a fused software scaler that sampled and patterned every panel pixel. It made the
// pattern screen-aligned (the point) but cost 5.3x the integer path it replaced: measured on the
// device as ~45% CPU vs ~25% with NES at Aspect, with the audio breaking up (Dan, 2026-09-08).
// Host benchmark, NES 256x240 -> 640x480, ms/frame: fused 0.479 line / 0.544 grid; integer 0.091;
// pattern-only over a hardware-scaled output 0.021 / 0.086. Dropping just the interpolation was NOT
// enough (0.184 / 0.411 — grid barely moved), because the cost is writing 307k panel pixels at all.
//
// So the game goes back to being scaled by the 2D engine (zero CPU) and the pattern is a separate
// hardware blit. The blit path already computes dst = src + dst*(1-srcAlpha), so a PREMULTIPLIED
// BLACK source (RGB=0) with per-pixel alpha `a` yields dst*(1-a) — arithmetically identical to the
// effect_dim the software scalers use.
//
// The pattern is SEPARABLE, which is why this costs ~36KB and not a full panel (614KB): scanlines
// vary only by row, so a narrow COLUMN stretched across the panel reproduces them exactly (every
// source pixel in a row is identical, so nearest and bilinear agree). Grid adds a short ROW
// stretched down. That matters here: the MMA heap has ~6MB with the render pages already taking
// most of it, and exhausting it is the documented "no game starts until reboot" failure.
#define FX_BAND 16          // source width/height of the two strips; >1 keeps the stride sanely aligned
static struct {
	HWBuffer buf;
	SDL_Surface* col;   // FX_BAND x FIXED_HEIGHT — horizontal scanlines
	SDL_Surface* row;   // FIXED_WIDTH x FX_BAND  — vertical grid lines
	int built_effect, built_period;
	int tried;          // allocation attempted (success or failure), so we retry only once
} fx = { .built_effect = -1 };
static int fx_period = 2;   // pattern period in PANEL pixels, from the live geometry

static int fx_alloc(void) {
	if (fx.tried) return fx.col != NULL;
	fx.tried = 1;
	size_t col_pitch = FX_BAND * 2, row_pitch = FIXED_WIDTH * 2;
	size_t need = ALIGN4K(col_pitch * FIXED_HEIGHT) + ALIGN4K(row_pitch * FX_BAND);
	if (MI_SYS_MMA_Alloc((MI_U8*)"mma_heap_name0", ALIGN4K(need), &fx.buf.padd) != MI_SUCCESS
	 && MI_SYS_MMA_Alloc(NULL, ALIGN4K(need), &fx.buf.padd) != MI_SUCCESS) {
		LOG_info("fx: MMA_Alloc(%zu) failed — effects fall back to the software scalers\n", need);
		fx.buf.padd = 0; return 0;
	}
	if (MI_SYS_Mmap(fx.buf.padd, ALIGN4K(need), &fx.buf.vadd, true) != MI_SUCCESS || !fx.buf.vadd) {
		LOG_info("fx: MMA_Mmap failed — effects fall back to the software scalers\n");
		MI_SYS_MMA_Free(fx.buf.padd); fx.buf.padd = 0; return 0;
	}
	memset(fx.buf.vadd, 0, ALIGN4K(need));
	uint8_t* base = fx.buf.vadd;
	size_t off = ALIGN4K(col_pitch * FIXED_HEIGHT);
	fx.col = SDL_CreateRGBSurfaceFrom(base, FX_BAND, FIXED_HEIGHT, 16, col_pitch,
		0x0F00, 0x00F0, 0x000F, 0xF000);
	fx.row = SDL_CreateRGBSurfaceFrom(base + off, FIXED_WIDTH, FX_BAND, 16, row_pitch,
		0x0F00, 0x00F0, 0x000F, 0xF000);
	if (!fx.col || !fx.row) {
		LOG_info("fx: CreateRGBSurfaceFrom failed: %s\n", SDL_GetError());
		if (fx.col) SDL_FreeSurface(fx.col);
		if (fx.row) SDL_FreeSurface(fx.row);
		fx.col = fx.row = NULL; return 0;
	}
	surf_setPa(fx.col, fx.buf.padd);
	surf_setPa(fx.row, fx.buf.padd + off);
	SDL_SetSurfaceBlendMode(fx.col, SDL_BLENDMODE_BLEND);
	SDL_SetSurfaceBlendMode(fx.row, SDL_BLENDMODE_BLEND);
	LOG_info("fx: overlay ready (%zu bytes, period-driven)\n", need);
	return 1;
}

// Alpha is the BLACK fraction, i.e. exactly what effect_dim removes: dim keeps (256-d)/256, so the
// overlay carries d/256 as 4-bit alpha. d = 102>>strength, matching the scalers' `edge`.
static void fx_build(int effect, int period) {
	if (!fx.col) return;
	unsigned strength = (effect==EFFECT_LINE50 || effect==EFFECT_GRID50) ? 1 :
	                    (effect==EFFECT_LINE25 || effect==EFFECT_GRID25) ? 2 : 0;
	unsigned a4 = ((102u >> strength) * 15u + 128u) / 256u;   // 4-bit alpha, rounded
	if (!a4) a4 = 1;
	uint16_t on = (uint16_t)(a4 << 12);                       // ARGB4444, RGB=0 => premultiplied black
	uint16_t* c = fx.col->pixels;
	for (int y = 0; y < FIXED_HEIGHT; y++) {
		uint16_t v = (period > 1 && y % period == period - 1) ? on : 0;
		for (int x = 0; x < FX_BAND; x++) c[y * FX_BAND + x] = v;
	}
	uint16_t* r = fx.row->pixels;
	for (int x = 0; x < FIXED_WIDTH; x++) {
		uint16_t v = (period > 1 && x % period == period - 1) ? on : 0;
		for (int y = 0; y < FX_BAND; y++) r[y * FIXED_WIDTH + x] = v;
	}
	fx.built_effect = effect; fx.built_period = period;
}

static int fx_wanted(void) { return next_effect > EFFECT_NONE && fx_alloc(); }

// Called from PLAT_flip with the framebuffer page already bound, right after the game blit.
static void fx_composite(void) {
	int effect = next_effect;
	if (effect <= EFFECT_NONE || !fx.col) return;
	if (effect != fx.built_effect || fx_period != fx.built_period) fx_build(effect, fx_period);
	int grid = (effect==EFFECT_GRID || effect==EFFECT_GRID50 || effect==EFFECT_GRID25);
	// Stretch the strips over the whole panel. Exact, not approximate: every source pixel along the
	// stretched axis is identical, so the filter cannot introduce error. Letterbox bands get dimmed
	// too, which is invisible — dimming black is black.
	GFX_BlitSurfaceExec(fx.col, NULL, vid.video, NULL, 0,0, grid);   // nowait until the last blit
	if (grid) GFX_BlitSurfaceExec(fx.row, NULL, vid.video, NULL, 0,0, 0);
}

// FBIO_WAITFORVSYNC is not in every libc's linux/fb.h, but the driver implements it (probed on
// device 2026-08-01: SUPPORTED, 120 waits = 59.6873Hz). Define it if the header did not.
#ifndef FBIO_WAITFORVSYNC
#define FBIO_WAITFORVSYNC _IOW('F', 0x20, __u32)
#endif

void PLAT_vsync(int remaining) {
	if (remaining > 0) {
		SDL_Delay(remaining);
		return;
	}
	// Out of budget. This used to RETURN IMMEDIATELY, which means a late frame was presented with
	// no raster synchronisation at all — the one moment sync matters most. MyMinUI, on this exact
	// panel, blocks on the vsync interrupt here instead, and this driver supports it.
	//
	// It matters more than it looks: the closer the producer runs to the panel's own rate, the more
	// often "already late" happens, so pacing the core toward the panel makes a no-op vsync fire
	// constantly rather than rarely. (Suspected cause of the tearing reported 2026-08-01 when the
	// rate match was enabled; the rate match itself is currently off.)
	//
	// Bounded by construction: the ioctl returns at the next vblank, ~16.76ms worst case. If the
	// driver ever refuses it, fall through rather than spin.
	if (vid.fdfb >= 0) {
		__u32 arg = 0;
		ioctl(vid.fdfb, FBIO_WAITFORVSYNC, &arg);
	}
}

static scaler_t PLAT_getPlainScaler(GFX_Renderer* renderer) {
	switch (renderer->scale) {
		case 6:  return scale6x6_n16;
		case 5:  return scale5x5_n16;
		case 4:  return scale4x4_n16;
		case 3:  return scale3x3_n16;
		case 2:  return scale2x2_n16;
		default: return scale1x1_n16;
	}
}

scaler_t PLAT_getScaler(GFX_Renderer* renderer) {
	scaler_t effect = NULL;
	// The overlay draws the pattern in hardware, so the CPU scaler must NOT also draw it — otherwise
	// it is applied twice AND we keep paying for the expensive path we are removing. Falls through to
	// the software effect scalers when the overlay could not be allocated.
	if (fx_wanted()) return PLAT_getPlainScaler(renderer);
	switch (next_effect) {
		case EFFECT_LINE:   effect = scaler_effect(renderer->scale, 0, 0); break;
		case EFFECT_LINE50: effect = scaler_effect(renderer->scale, 0, 1); break;
		case EFFECT_LINE25: effect = scaler_effect(renderer->scale, 0, 2); break;
		case EFFECT_GRID:   effect = scaler_effect(renderer->scale, 1, 0); break;
		case EFFECT_GRID50: effect = scaler_effect(renderer->scale, 1, 1); break;
		case EFFECT_GRID25: effect = scaler_effect(renderer->scale, 1, 2); break;
	}
	if (effect) return effect;
	return PLAT_getPlainScaler(renderer);
}

void PLAT_blitRenderer(GFX_Renderer* renderer) {
	if (effect_type!=next_effect) {
		effect_type = next_effect;
		renderer->blit = PLAT_getScaler(renderer); // refresh the scaler
	}
	// Pattern period in PANEL pixels. vid.screen is stretched whole->whole onto the panel by the
	// present blit, so a source pixel lands on (game width on panel / src_w) panel pixels. Derived
	// per frame because it is cheap and geometry changes (scaling mode, core resolution) do not all
	// route through PLAT_setSharpness.
	if (renderer->src_w && renderer->src_h && vid.width && vid.height) {
		int gw = renderer->dst_w * FIXED_WIDTH  / (int)vid.width;
		int gh = renderer->dst_h * FIXED_HEIGHT / (int)vid.height;
		int px = gw / (int)renderer->src_w, py = gh / (int)renderer->src_h;
		int p = px < py ? px : py;
		fx_period = p < 2 ? 2 : (p > 16 ? 16 : p);
	}
	void* dst = renderer->dst + (renderer->dst_y * renderer->dst_p) + (renderer->dst_x * FIXED_BPP);
	((scaler_t)renderer->blit)(renderer->src,dst,renderer->src_w,renderer->src_h,renderer->src_p,renderer->dst_w,renderer->dst_h,renderer->dst_p);
}


static void drawDebugOverlay(void); // defined with the rest of the HUD code below

///////////////////////////////
// Async page flip.
//
// FBIOPAN_DISPLAY blocks ~16.76ms on this driver (MEASURED). Doing that on the render thread means
// one late frame costs a whole extra frame and the rate halves — observed on GBC at exactly
// 29.8fps (= 59.7/2) while the core itself used only ~8% CPU. Handing the pan to a thread lets the
// producer start the next frame immediately.
//
// Only enabled with 3 scanout pages: with 2 the producer would have to blit into the page the
// panner is still handing to scanout. With 3 there is always a free page (one on screen, one
// pending, one being drawn).
// The pending slot is 1-deep and COALESCING — a newer frame replaces an unpanned older one rather
// than queueing, so we never build latency.
static pthread_t       flip_pt;

static void* flip_thread(void* arg) {
	(void)arg;
	pthread_mutex_lock(&flip_mx);
	while (flip_run) {
		while (flip_run && flip_pending < 0) pthread_cond_wait(&flip_req, &flip_mx);
		if (!flip_run) break;
		flip_active  = flip_pending;
		flip_pending = -1;
		pthread_cond_broadcast(&flip_ack); // the pending slot is free now — release a STRICT producer
		pthread_mutex_unlock(&flip_mx);

		int rc = fb_pan(flip_active);   // the ~16.76ms block, off the render thread

		pthread_mutex_lock(&flip_mx);
		// RETIREMENT. On success the panned page becomes the front and the OLD front is released;
		// this is the transition that was missing. On failure nothing moves: the panel is still
		// scanning the old front, so releasing it would be exactly the bug we are fixing.
		//
		// NOTE (unproven, deliberately isolated here): this treats "pan returned" as the retirement
		// point. Evidence is strong — FB_ACTIVATE_VBL requests vblank activation, the pan blocks one
		// measured refresh period (16.76ms), and a tight pan loop runs at exactly panel rate — but
		// SigmaStar documents no completion contract, so it is not proven. The conservative
		// alternative (an FBIO_WAITFORVSYNC after each pan) costs a SECOND refresh period per frame
		// and would halve presentation to ~29.8Hz, which is the failure this thread exists to avoid.
		// Confining the assumption to this one place makes it replaceable if a probe disproves it.
		if (rc == 0) flip_front = flip_active;
		else LOG_info("fb: pan failed for page %d — page ownership unchanged\n", flip_active);
		flip_active = -1;
		pthread_cond_broadcast(&flip_ack); // a producer may be waiting for a page to free
	}
	pthread_mutex_unlock(&flip_mx);
	return NULL;
}

// Pick a page owned by nobody. Caller must hold flip_mx. Returns -1 if all pages are owned.
// The hint only affects fairness; the ownership predicate is what is authoritative. Selecting by
// `(vid.page + 1) % pages` was the original sin — it walks into the front page by construction.
static int flip_freePage(int hint) {
	for (int i = 0; i < vid.pages; i++) {
		int p = (hint + i) % vid.pages;
		if (p != flip_front && p != flip_active && p != flip_pending && p != flip_rendering)
			return p;
	}
	return -1;
}

static void mmpFlipStart(void) {
	if (vid.pages < 3) return;          // stay synchronous on 2 pages
	flip_run = 1;
	if (pthread_create(&flip_pt, NULL, flip_thread, NULL) != 0) {
		flip_run = 0;
		LOG_info("fb: flip thread failed to start — falling back to synchronous pan\n");
	}
	else LOG_info("fb: async flip thread started (%d pages)\n", vid.pages);
}

static void mmpFlipStop(void) {
	if (!flip_run) return;
	LOG_info("fb: flip stats — %u handed to panner, %u coalesced away (%.1f%%)\n",
		flip_frames, flip_dropped,
		flip_frames ? (100.0 * flip_dropped / flip_frames) : 0.0);
	pthread_mutex_lock(&flip_mx);
	flip_run = 0;
	pthread_cond_broadcast(&flip_req);
	pthread_cond_broadcast(&flip_ack); // also release a producer blocked waiting for a free page:
	                                   // unreachable today (every caller runs on the producer's own
	                                   // thread) but free insurance if that ever stops being true
	pthread_mutex_unlock(&flip_mx);
	pthread_join(flip_pt, NULL);        // join, don't cancel: a cancelled thread can die holding
	flip_pending = flip_active = -1;    // flip_mx and every later lock would deadlock
}

void PLAT_flip(SDL_Surface* IGNORED, int sync) {
	// Present: MI_GFX blits (and scales, when the render target is core-sized) from the MMA
	// buffer straight into the framebuffer page's PHYSICAL address, then we page-flip. The
	// 2D engine does the scale, so no CPU scaling happens here — that is the whole point of
	// using this SoC's hardware blitter instead of a software present.
	// Composite the debug HUD into the render surface BEFORE the present blit, so it goes through
	// the same rotate=2 as the game frame. No-op when the HUD is off.
	drawDebugOverlay();

	int back = (vid.pages > 1) ? (vid.page + 1) % vid.pages : 0;
	int scrub = 0;

	if (flip_run) {
		// RESERVE A PAGE BEFORE DRAWING. Everything about ownership has to be decided here: once
		// MI_GFX starts writing, waiting is too late to protect the destination. The old code
		// checked only active/pending (never the front), then did the Strict wait AFTER the blit.
		pthread_mutex_lock(&flip_mx);
		for (;;) {
			if (!flip_run) break;
			if (flip_block) {
				// STRICT: never lose a frame. Require the pending slot empty, then take any page
				// nobody owns. If front+active+pending hold all three, block — that is correct
				// backpressure, and the panner can always drain without us.
				if (flip_pending < 0) {
					int p = flip_freePage(back);
					if (p >= 0) { back = p; break; }
				}
			}
			else {
				// LENIENT: newest frame wins. Prefer a free page; if there is none, atomically
				// STEAL the pending one under the mutex. Stealing must happen here, not after the
				// blit: the panner either took it first (making it active, so freePage skips it)
				// or we withdrew it cleanly. Replacing flip_pending after drawing recreates the
				// original race.
				int p = flip_freePage(back);
				if (p >= 0) { back = p; break; }
				if (flip_pending >= 0) {
					back = flip_pending;
					flip_pending = -1;
					flip_dropped++; // this frame will never be scanned out
					break;
				}
			}
			pthread_cond_wait(&flip_ack, &flip_mx);
		}
		flip_rendering = back; // owned by us until the blit completes
		if (flip_scrub > 0) { flip_scrub--; scrub = 1; }
		pthread_mutex_unlock(&flip_mx);
	}
	else if (flip_scrub > 0) { flip_scrub--; scrub = 1; } // 2-page fallback: we own `back` too

	// Deferred clear from fb_scrubPages, paid on a page we exclusively own. The present blit only
	// covers the game rect, so without this the letterbox/pillarbox bands keep the previous
	// content — which is the glitchy band, and the HUD strip residue.
	if (scrub) memset((uint8_t*)vid.fbmmap + (size_t)back * vid.page_bytes, 0, vid.page_bytes);

	fb_bindPage(back);
	// nowait=1 when the effect overlay follows: the 2D engine queues both blits and we fence once,
	// after the last one, instead of stalling between them.
	int fx_on = (next_effect > EFFECT_NONE && fx.col != NULL);
	GFX_BlitSurfaceExec(vid.screen, NULL, vid.video, NULL, 2,0, fx_on); // rotate=2 (180, panel is mounted inverted)
	if (fx_on) fx_composite(); // screen-aligned scanlines/grid, composited by MI_GFX (see fx_* above)

	if (flip_run) {
		pthread_mutex_lock(&flip_mx);
		flip_rendering = -1; // blit fenced (nowait=0), page is now a complete frame
		flip_frames++;
		// Report periodically rather than at teardown: a SIGTERM/crash exit never reaches
		// PLAT_quitVideo, which is exactly when we most want this number.
		if ((flip_frames % 600) == 0)
			LOG_info("fb: flip %u handed, %u coalesced away (%.1f%%)\n", flip_frames, flip_dropped,
				100.0 * flip_dropped / flip_frames);
		// Lenient may have taken a FREE page while an older pending frame was still queued; that
		// older frame is replaced here and never scanned out, so it must be counted. Dropping this
		// made the coalescing figure read low exactly when it mattered. Strict never trips it: it
		// requires flip_pending < 0 before reserving, and there is only one producer.
		if (flip_pending >= 0) flip_dropped++;
		flip_pending = back;              // coalescing: a newer frame replaces an unpanned one
		pthread_cond_signal(&flip_req);
		pthread_mutex_unlock(&flip_mx);
	}
	// 2-page fallback: pan inline. On FAILURE the panel is still scanning the old page, so leaving
	// vid.page alone is what keeps the next frame off it — advancing regardless made the next
	// `(vid.page + 1) % 2` land on the real front page and blit into live scanout.
	else if (fb_pan(back) != 0) back = vid.page;

	vid.page = back;

	// Swap the render-side backbuffer. This is INDEPENDENT of the scanout page count: there are
	// exactly PAGE_COUNT(2) MMA render buffers, so it needs its own toggle. Keying it off
	// (vid.page&1) was correct for 2 scanout pages but yields 0,1,0,0,1,0 for 3.
	if (!vid.direct) {
		mma_page ^= 1;
		vid.screen->pixels = vid.buffer.vadd + ALIGN4K(mma_page*MMA_PAGE);
		surf_setPa(vid.screen, vid.buffer.padd + ALIGN4K(mma_page*MMA_PAGE));
	}

	if (vid.cleared) {
		PLAT_clearVideo(vid.screen);
		vid.cleared = 0;
	}
}

///////////////////////////////

// TODO:
#define OVERLAY_WIDTH PILL_SIZE // unscaled
#define OVERLAY_HEIGHT PILL_SIZE // unscaled
#define OVERLAY_BPP 4
#define OVERLAY_DEPTH 16
#define OVERLAY_PITCH (OVERLAY_WIDTH * OVERLAY_BPP) // unscaled
#define OVERLAY_RGBA_MASK 0x00ff0000,0x0000ff00,0x000000ff,0xff000000 // ARGB
static struct OVL_Context {
	SDL_Surface* overlay;
} ovl;

SDL_Surface* PLAT_initOverlay(void) {
	// setup surface
	ovl.overlay = SDL_CreateRGBSurface(SDL_SWSURFACE, SCALE2(OVERLAY_WIDTH,OVERLAY_HEIGHT),OVERLAY_DEPTH,OVERLAY_RGBA_MASK);
	return ovl.overlay;
}
void PLAT_quitOverlay(void) {
	if (ovl.overlay) SDL_FreeSurface(ovl.overlay);
}
void PLAT_enableOverlay(int enable) {

}

///////////////////////////////

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

///////////////////////////////

// Exact fuel-gauge percentage (AXP reg 0xB9 bits[6:0]) — the SAME register and validation batmon
// uses, so the boot charging screen and the in-menu one cannot disagree about the battery.
// bit2 of AXP reg 0x00: current actually flowing INTO the cell. Updated by PLAT_getBatteryStatus.
static int axp_topping_up = 0;
// Only inhibit autosleep while the cell is ACTUALLY filling, not merely while a cable is present.
int PLAT_isToppingUp(void) { return has_axp ? axp_topping_up : 0; }

int PLAT_getChargePercent(void) {
	if (!has_axp) return -1;
	int v = axp_read(0xB9);
	if (v < 0) return -1;
	v &= 0x7F;
	return v > 100 ? -1 : v;   // the gauge returns garbage occasionally — reject it
}

static int online = 0;
void PLAT_getBatteryStatus(int* is_charging, int* charge) {
	// EXTERNAL POWER PRESENCE (reg 0x00: bit7 ACIN, bit4 VBUS), not bit2.
	// bit2 is battery CURRENT DIRECTION, and it CLEARS once the cell is full — so a device sitting
	// on the charger at 100% reported "not charging", which took the menu out of its charging
	// state and let it behave as if running on battery while plugged in. batmon gates on presence
	// (isPowered) and this must agree with it: two notions of "charging" in two places is exactly
	// how that divergence survived unnoticed.
	if (has_axp) {
		int v = axp_read(0x00);
		// A failed i2c read must not read as "unplugged"; keep the previous verdict.
		static int last_powered = 0;
		if (v >= 0) last_powered = ((v & 0x80) || (v & 0x10)) ? 1 : 0;
		*is_charging = last_powered;
		// bit2 = current actually flowing INTO the cell. Tracked separately because
		// PWR_preventAutosleep() keys off is_charging, and presence stays true forever while a
		// cable is attached — which meant a plugged-in device sitting in a game could NEVER
		// autosleep at any charge level, panel and core live indefinitely. Presence is right for
		// "show the charging icon"; "still filling" is right for "stay awake".
		if (v >= 0) axp_topping_up = (v & 0x04) ? 1 : 0;
	}
	else *is_charging = getInt("/sys/devices/gpiochip0/gpio/gpio59/value");

	// /tmp/battery is keymon's noise-eased level. It lives on TMPFS, so between a boot and keymon's
	// first valid ADC read the file simply does not exist — and getInt returns 0 for a file it
	// cannot open, which lands in the bucket below as exactly 10: PWR_LOW_CHARGE. Absent data was
	// therefore indistinguishable from a dying cell, right down to raising the low-battery warning.
	// Fall back to the fuel gauge we already read accurately a few lines up rather than inventing a
	// number; only claim 10% when something actually says 10%.
	int i = getInt("/tmp/battery"); // 0-100?
	if (i <= 0) {
		int direct = PLAT_getChargePercent(); // AXP reg 0xB9, same source batmon uses
		if (direct >= 0) i = direct;
	}

	// worry less about battery and more about the game you're playing
	     if (i>80) *charge = 100;
	else if (i>60) *charge =  80;
	else if (i>40) *charge =  60;
	else if (i>20) *charge =  40;
	else if (i>10) *charge =  20;
	else           *charge =  10;

	// TODO: tmp
	// *is_charging = 0;
	// *charge = PWR_LOW_CHARGE;
	
	// getFile() leaves the buffer UNTOUCHED when the open fails, and the base Mini (and any Plus
	// with the wifi module not inserted) has no wlan0 — so this was reading uninitialised stack
	// and re-rolling `online` from garbage every poll. Initialise it.
	char status[16] = {0};
	getFile("/sys/class/net/wlan0/operstate", status,16);
	online = prefixMatch("up", status);
}

#define PWM_DUTY_PATH "/sys/class/pwm/pwmchip0/pwm0/duty_cycle"
#define FB_CTRL_PATH  "/proc/mi_modules/fb/mi_fb0"

// Screen off/on. NO GPIO4 — deliberately.
//
// GPIO4 is PAD_GPIO4, and on this board PAD_GPIO4 *is the PWM0 output pad* (the stock MY354 DTB's
// pwm node carries `pad-ctrl = <0x4>`, and the vendor PWM driver maps pad id 4 to PWM0_MODE_3 in
// CHIPTOP reg 0x07 bits[2:0]). It is NOT a separate panel-power rail, which is what upstream MinUI
// and Onion's comments imply.
//
// Consequences, MEASURED on this device:
//  * Exporting gpio4 STEALS the pad from PWM0 via padmux, and `unexport` does NOT give it back —
//    only a pwm `enable` 0->1 bounce re-muxes it. We found gpio4 left exported from an earlier
//    sleep cycle, which had silently killed brightness control outright: duty writes went nowhere
//    because the pad was GPIO-owned.
//  * Reading /sys/class/gpio/gpio4/value returns the pad's INPUT receiver, not the output latch,
//    so "write 1, read 0" is expected and proves nothing. An earlier fix here was built on that
//    readback and its stated root cause was wrong.
//  * Driving the pad low is in any case REDUNDANT with setting duty to 0 — it is the same pin.
//
// So we blank the way Allium and spruceOS do: ask the framebuffer to hide its layer and zero the
// backlight duty. No padmux games, nothing to leak.
//
// HONEST CAVEAT, measured: the `GUI_SHOW 0 off` write SUCCEEDS (rc=0) but does NOT change the
// layer state on this firmware — /proc/mi_modules/fb/mi_fb0 still reports `Visible State=1`
// afterwards. So the blanking that actually happens here is duty=0, and the GUI_SHOW call is
// currently decorative. It is kept because it is a single harmless write, it is the documented
// SigmaStar interface, and it does work on the firmware revisions Allium/spruce target — but do
// NOT rely on it hiding anything on this device.
// Ordering follows Allium: dim BEFORE hiding, show BEFORE brightening, so no frame is ever
// displayed at the wrong level.
void PLAT_enableBacklight(int enable) {
	static int saved_duty = -1;

	if (enable) {
		putFile(FB_CTRL_PATH, "GUI_SHOW 0 on");
		if (saved_duty > 0) { SetRawBrightness(saved_duty); saved_duty = -1; }
		else {
			// Nothing saved (e.g. enable without a preceding disable): fall back to the user's
			// stored level rather than leaving the panel dark.
			int b = GetBrightness();
			SetRawBrightness(b==0 ? 6 : b*10);
		}
	}
	else {
		int d = getInt(PWM_DUTY_PATH);
		if (d > 0) saved_duty = d; // the user's live level; keep any earlier save otherwise
		SetRawBrightness(0);
		putFile(FB_CTRL_PATH, "GUI_SHOW 0 off");
	}
}
void PLAT_powerOff(void) {
	sleep(2);

	// RAMP the output down before cutting power, instead of stepping straight to mute.
	//
	// A single SetRawVolume(MUTE) was measurably better than nothing (reported audibly quieter on
	// device), which tells us the pop is not PURELY the supply rail collapsing — part of it is the
	// output LEVEL changing in one step. A step is broadband energy; a ramp spreads the same
	// change over time and moves it below the speaker's response.
	//
	// ~20 steps of 8ms = ~160ms, which is free here: the device is powering off and already waits
	// 2s above.
	//
	// HONEST LIMIT: this cannot remove the pop entirely. Whatever remains is the analog supply
	// collapsing, and this board exposes no speaker-amp enable line to shut the output stage down
	// first (gpio48 is the RUMBLE motor, not an amp — checked). Only an amp mute would close it.
	// Ramp DOWN FROM WHERE THE HARDWARE ACTUALLY IS, and never ramp if it is already muted.
	//
	// Starting the ramp from the SAVED level was a bug in the unsafe direction: the idle
	// auto-power-off path arrives here already muted (PWR_enterSleep does
	// SetRawVolume(MUTE_VOLUME_RAW), then the wake wait times out into PWR_powerOff). Ramping from
	// the saved level then wrote a LOUDER value first, and SetRawVolume's boundary rule
	// (`else if (old==-60) setMute(0)`) un-muted the codec — a full-volume burst on every idle
	// power-off, which is the opposite of what this ramp is for.
	{
		int raw = 0;
		if (MI_AO_GetVolume(0, &raw) != 0) raw = MUTE_VOLUME_RAW; // unknown: assume muted, do not raise
		while (raw > MUTE_VOLUME_RAW) {
			raw -= 3;                        // one user step, same 3dB grid libmsettings uses
			if (raw < MUTE_VOLUME_RAW) raw = MUTE_VOLUME_RAW;
			SetRawVolume(raw);
			usleep(8000);
		}
	}
	SetRawVolume(MUTE_VOLUME_RAW);
	PLAT_muteAudio(1);
	PLAT_enableBacklight(0);
	SND_quit();
	VIB_quit();
	PWR_quit();
	GFX_quit();
	
	system("shutdown");
	while (1) pause(); // lolwat
}

///////////////////////////////

// copy/paste of 35XX version now that we have our own overclock.elf
void PLAT_setCPUMaxFreq(int khz); // defined below, next to the OPP table

void PLAT_setCPUSpeed(int speed) {
	// WAS: upstream's verbatim `system("overclock.elf <freq>")` with a 504/1104/1296/1488 MHz
	// table. That OVERCLOCKS — 1488 MHz is 24% above this SoC's top stock OPP (1200 MHz, which
	// Onion's own shipped docs confirm as stock in two places) — and overclock.elf reaches it by
	// poking the SigmaStar MPLL registers through /dev/mem, bypassing cpufreq entirely, so
	// scaling_setspeed cannot undo it. The in-game "CPU Speed" menu made that reachable at will,
	// on a fork whose north star is NEVER overclock. 504000 was not a real OPP either, so the
	// menu left cpufreq and the actual MPLL disagreeing.
	//
	// Now: map to REAL measured OPPs and go through the same snapped, clamped actuator the
	// governor uses, so only one mechanism ever owns the clock (see the note above the OPP table).
	int khz = 0;
	switch (speed) {
		case CPU_SPEED_MENU:		khz =  600000; break; // matches MinUI.pak/launch.sh's boot clock
		case CPU_SPEED_POWERSAVE:	khz = 1000000; break;
		case CPU_SPEED_NORMAL:		khz = 1100000; break;
		case CPU_SPEED_PERFORMANCE:	khz = 1200000; break; // top STOCK OPP — never above
		default:			khz = 1000000; break;
	}
	PLAT_setCPUMaxFreq(khz);
}

void PLAT_setRumble(int strength) {
    static char lastvalue = 0;
    const char str_export[2] = "48";
    const char str_direction[3] = "out";
    char value[1];
    int fd;

    value[0] = (strength == 0 ? 0x31 : 0x30); // '0' : '1'
    if (lastvalue != value[0]) {
       fd = open("/sys/class/gpio/export", O_WRONLY);
       if (fd > 0) { write(fd, str_export, 2); close(fd); }
       fd = open("/sys/class/gpio/gpio48/direction", O_WRONLY);
       if (fd > 0) { write(fd, str_direction, 3); close(fd); }
       fd = open("/sys/class/gpio/gpio48/value", O_WRONLY);
       if (fd > 0) { write(fd, value, 1); close(fd); }
       lastvalue = value[0];
    }
}

int PLAT_pickSampleRate(int requested, int max) {
	return max;
}

char* PLAT_getModel(void) {
	char* model = getenv("MY_MODEL");
	if (exactMatch(model,"MY285")) return "Miyoo Mini Flip";
	else if (is_plus) return "Miyoo Mini Plus";
	else return "Miyoo Mini";
}

int PLAT_isOnline(void) {
	return online;
}

///////////////////////////////
// Closed-loop governor actuation (MinUI Zero).
//
// This SoC has NO schedutil — `scaling_available_governors` is exactly
// "userspace powersave ondemand performance" (MEASURED on-device 2026-07-24). So the tg5040
// model (write a scaling_max_freq ceiling and let schedutil pick beneath it) does not apply.
// Here the commanded ceiling IS the clock: userspace governor + scaling_setspeed, which is
// also MinUI's own historical model on this platform.
//
// NOTE: MinUI/MyMinUI otherwise drive the clock with overclock.elf, which pokes the SigmaStar
// MPLL registers directly and bypasses cpufreq entirely. Whoever writes last wins, so the
// governor stays the ONLY writer here — the OC translation below runs INSIDE the governor's
// write, never beside it.
//
// MEASURED OPP table (scaling_available_frequencies, 2026-07-24):
//   400000 600000 800000 1000000 1100000 1200000 kHz.
// Requests are snapped DOWN to a real OPP (never up — never silently overclock) and clamped
// to the table. 1200000 is the top *stock* step.
//
// MINARCH_OC_KHZ (per-pak opt-in; CLAUDE.md overclock rule as amended 2026-07-28): when set,
// a request that lands on the TABLE TOP is served by overclock.elf at the requested OC clock
// instead of a plain setspeed write. overclock.elf itself writes governor=userspace +
// setspeed=1200000 and then raises the PLL, so the kernel's bookkeeping stays at the top stock
// step. Every request BELOW the top takes the normal cpufreq path, and that write reprograms
// the PLL back to a stock clock — so menu dips cool down as before, and climbing back to the
// top re-applies the OC. A crash while overclocked self-heals the same way: the next process
// to touch cpufreq (the menu, at menu clock) resets the PLL.
//
// Receipt for existence (2026-07-27 autotest, PS1 at the 1200 ceiling): BR2 p95 18.5-20.5ms,
// THPS 20.4-20.8ms vs the 16.7ms budget — holding rate needs ~1.5GHz. Upstream MinUI ran this
// device at 1296/1488 (its NORMAL/PERFORMANCE) via this same tool.
// KNOWN LIE while overclocked: scaling_cur_freq still reads 1200000 (cpufreq cannot see the
// PLL), so the HUD/telemetry clock column under-reports; judge OC by the p95/over%% delta.
#define MMP_CPUF_DIR "/sys/devices/system/cpu/cpufreq/policy0"
static const int mmp_opp_khz[] = { 400000, 600000, 800000, 1000000, 1100000, 1200000 };
#define MMP_OPP_COUNT ((int)(sizeof(mmp_opp_khz)/sizeof(mmp_opp_khz[0])))

static int mmp_writeStr(const char* path, const char* val) {
	int fd = open(path, O_WRONLY);
	if (fd < 0) return 0;
	ssize_t n = write(fd, val, strlen(val));
	close(fd);
	return n == (ssize_t)strlen(val);
}

// Latched once: the env cannot change mid-process, and re-reading it per tick is a getenv on
// the hot path. Clamped to the range upstream shipped (1296..1488); above the clamp we take
// 1488, at/below the stock top the opt-in is OFF.
static int mmp_oc_khz(void) {
	static int oc = -2; // -2 unread, 0 off
	if (oc == -2) {
		const char* v = getenv("MINARCH_OC_KHZ");
		oc = 0;
		if (v && *v) {
			int k = atoi(v);
			if (k > 1488000) k = 1488000;
			if (k > 1200000) oc = k;
			if (oc) LOG_info("gov: MPLL OC armed at %d kHz for table-top requests\n", oc);
		}
	}
	return oc;
}

void PLAT_setCPUMaxFreq(int khz) {
	static int last_khz = -1;
	static int gov_set = 0;

	// snap DOWN to a real OPP, clamp into the table
	int target = mmp_opp_khz[0];
	for (int i = 0; i < MMP_OPP_COUNT; i++) {
		if (mmp_opp_khz[i] <= khz) target = mmp_opp_khz[i];
	}
	if (khz >= mmp_opp_khz[MMP_OPP_COUNT-1]) target = mmp_opp_khz[MMP_OPP_COUNT-1];

	if (!gov_set) { // take ownership of the clock once per session
		// Only latch this if it actually succeeded — otherwise we would stop trying to claim
		// the governor after a single transient failure and every later setspeed write would be
		// applied under whatever governor happens to be active.
		gov_set = mmp_writeStr(MMP_CPUF_DIR "/scaling_governor", "userspace");
	}
	if (target == last_khz) return; // avoid pointless sysfs writes every tick

	// Table-top request with the OC opt-in armed: overclock.elf does the whole write (it sets
	// governor+setspeed itself, then raises the PLL). See the block comment above for why this
	// is the governor's OWN write and not a second writer.
	if (target == mmp_opp_khz[MMP_OPP_COUNT-1] && mmp_oc_khz()) {
		char cmd[64];
		snprintf(cmd, sizeof(cmd), "overclock.elf %d", mmp_oc_khz());
		if (system(cmd) == 0) last_khz = target;
		else LOG_info("gov: overclock.elf FAILED for %d kHz (will retry)\n", mmp_oc_khz());
		return;
	}

	char buf[16];
	snprintf(buf, sizeof(buf), "%d", target);
	// Cache ONLY on success. This used to assign last_khz before the write, so one failed write
	// convinced the governor it had already applied that clock and it never retried — the closed
	// loop silently went open and the ceiling stuck wherever it was.
	if (mmp_writeStr(MMP_CPUF_DIR "/scaling_setspeed", buf)) last_khz = target;
	else LOG_info("gov: scaling_setspeed write FAILED for %d kHz (will retry)\n", target);
}

///////////////////////////////
// Debug-HUD hooks. (This block used to say the HUD was "not implemented on this platform yet,
// so these are honest no-ops" — that is stale: the code below draws real pixels and the HUD is
// verified working on device. PLAT_getGameRect must still report a sane rect — callers divide
// by w/h.)

// Debug HUD. minarch hands us two RGB565 strips (top/bottom) generated at screen->w /
// DBG_OVERLAY_SCALE and expects them presented SCALED so they span the panel — see minarch.c:3809
// ("presented scaled -> strips span the panel"). 0xF81F (magenta) is the transparency key.
//
// tg5040 uploads these as ARGB textures and lets SDL's renderer scale them. We have no renderer,
// and MI_GFX exposes no filter or convenient sub-rect compositing (its Opt struct has no filter
// field at all — verified against three SigmaStar SDK drops). But our render surface is ALREADY
// RGB565, so we can skip the Brick's ARGB conversion entirely and composite straight into
// vid.screen with an integer nearest upscale, BEFORE the present blit. The HUD then rides the
// same MI_GFX rotate+scale as the game, which is what keeps it right-side up on this inverted
// panel — anything drawn directly into the framebuffer instead would come out upside-down.
#define DBG_KEY 0xF81F
static struct { uint16_t *top, *bottom; int w, h, stride; } dbg = {0};
static int dbg_was_on = 0; // for the OFF-transition repaint below

void PLAT_setDebugOverlay(uint16_t* top, uint16_t* bottom, int w, int h, int stride) {
	// HUD OFF transition: repaint everything, via the same primitive geometry changes use.
	//
	// The residue is NOT in the render surface (the game rewrites its own rect there every frame).
	// It is in the FRAMEBUFFER's letterbox/pillarbox bands — see PLAT_clearAll's own comment: "the
	// present blit only covers the game rect, so whatever sits in the letterbox/pillarbox region
	// persists". The HUD strips span the full width, so the part overhanging the game rect lands in
	// those bands and nothing ever overwrites it.
	//
	// PLAT_clearAll is the right hammer because it zeroes the WHOLE fb mmap (every page, not just
	// the one about to be flipped) plus the backbuffer. A previous attempt scrubbed only the render
	// surface, only once, and only on the frame the toggle happened: wrong surface, and a present
	// that gets skipped or a page that is not the current one both defeat it. Reported twice
	// on-device before this landed (2026-07-28, 2026-07-31).
	if (!top && dbg_was_on) PLAT_clearAll();
	dbg_was_on = (top != NULL);
	dbg.top = top; dbg.bottom = bottom; dbg.w = w; dbg.h = h; dbg.stride = stride;
}

// Scale the strip into a destination rect measured as a FRACTION of the render surface, not as a
// fixed pixel count.
//
// This is the whole fix for "the HUD keeps changing size mid-game". We composite into vid.screen,
// which is the CORE-SIZED render target, and PLAT_flip then hands it to MI_GFX to scale up to the
// panel. So a HUD drawn at a fixed integer scale occupies a fixed number of SOURCE pixels — which
// is a DIFFERENT fraction of the panel for every game resolution, and PS1 changes resolution
// constantly (320x240 gameplay vs 640x480 menus), so the HUD visibly doubled and halved.
//
// tg5040 never had this because it draws the HUD through SDL's renderer in PANEL space
// (SDL_RenderCopy), after the game has already been scaled.
//
// Here, dst_w/dst_h are pre-scaled by vid.width/FIXED_WIDTH, so after MI_GFX scales the surface to
// the panel the HUD lands at the SAME on-screen size at every core resolution. That needs a
// dst->src mapping rather than integer pixel replication, because the ratio is not an integer.
static void dbgBlitStrip(uint16_t* strip, int dst_y, int dst_w, int dst_h) {
	if (dst_w <= 0 || dst_h <= 0) return;
	uint16_t* base = (uint16_t*)vid.screen->pixels;
	int dpitch = vid.pitch / 2; // vid.pitch is bytes; RGB565 => 2 bytes/px
	// Fixed-point stepping, NOT a divide per pixel. The obvious `srow[dx * dbg.w / dst_w]` costs an
	// integer multiply AND divide for every destination pixel — on a 640-wide strip that is ~9k
	// divides per frame on a dual Cortex-A7, added to the present path, in a fork whose whole thesis
	// is not spending cycles it does not have to. A 16.16 accumulator gives the identical
	// nearest-neighbour mapping with one add per pixel.
	// The step is rounded UP. A truncated step lets the accumulator lag by one source pixel at the
	// far edge; rounding up makes this bit-for-bit identical to `dx * dbg.w / dst_w` at every
	// destination pixel (verified exhaustively over the resolutions this device produces) and keeps
	// the index strictly inside the strip.
	const uint32_t xstep = (((uint32_t)dbg.w << 16) + (uint32_t)dst_w - 1) / (uint32_t)dst_w;
	const uint32_t ystep = (((uint32_t)dbg.h << 16) + (uint32_t)dst_h - 1) / (uint32_t)dst_h;
	int wlim = dst_w < vid.width ? dst_w : vid.width;
	uint32_t yacc = 0;
	for (int dy = 0; dy < dst_h; dy++, yacc += ystep) {
		int y = dst_y + dy;
		if (y < 0 || y >= vid.height) continue;
		uint16_t* srow = strip + (yacc >> 16) * dbg.stride;
		uint16_t* drow = base + (size_t)y * dpitch;
		uint32_t xacc = 0;
		for (int dx = 0; dx < wlim; dx++, xacc += xstep) {
			uint16_t p = srow[xacc >> 16];
			if (p == DBG_KEY) continue;           // transparent
			drow[dx] = p;
		}
	}
}

static void drawDebugOverlay(void) {
	// minarch calls PLAT_setDebugOverlay(NULL,...) when the HUD is off, so this is a null check
	// on the hot path and nothing more.
	if (!dbg.top || !dbg.bottom || dbg.w <= 0 || dbg.h <= 0) return;
	if (dbg.stride < dbg.w) return;                       // malformed: refuse rather than read OOB
	if (!vid.screen || !vid.screen->pixels) return;
	const int S = DBG_OVERLAY_SCALE;
	if (vid.width <= 0 || vid.height <= 0) return;

	// Target size expressed in RENDER-SURFACE pixels such that, once MI_GFX scales the surface to
	// the panel, the HUD is the same size it would be if we had drawn it at panel resolution.
	// Rounded UP so the strip never leaves a sliver of unpainted background at low core widths.
	int dst_w = (dbg.w * S * vid.width  + FIXED_WIDTH  - 1) / FIXED_WIDTH;
	int dst_h = (dbg.h * S * vid.height + FIXED_HEIGHT - 1) / FIXED_HEIGHT;
	int margin = (S * vid.height + FIXED_HEIGHT - 1) / FIXED_HEIGHT;
	if (dst_w > vid.width) dst_w = vid.width;
	if (dst_h < 1) dst_h = 1;                             // a tiny core must still show something
	if (margin < 1) margin = 1;

	if (dst_h * 2 + margin * 2 > vid.height) return;      // no room; skip rather than overlap
	dbgBlitStrip(dbg.top, margin, dst_w, dst_h);
	dbgBlitStrip(dbg.bottom, vid.height - dst_h - margin, dst_w, dst_h);
}

void PLAT_getGameRect(int* x, int* y, int* w, int* h) {
	*x = 0; *y = 0;
	*w = vid.video ? vid.video->w : FIXED_WIDTH;
	*h = vid.video ? vid.video->h : FIXED_HEIGHT;
}
