// tg5040
#include <stdio.h>
#include <stdlib.h>
#include <linux/fb.h>
#include <sys/ioctl.h>
#include <sys/mman.h>

#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <pthread.h>
#include <linux/i2c-dev.h>

#include <msettings.h>

#include "defines.h"
#include "platform.h"
#include "api.h"
#include "utils.h"

#include "scaler.h"

int is_brick = 0;
int is_brickpro = 0;

///////////////////////////////

static SDL_Joystick *joystick;
void PLAT_initInput(void) {
	SDL_InitSubSystem(SDL_INIT_JOYSTICK);
	joystick = SDL_JoystickOpen(0);
}
void PLAT_quitInput(void) {
	SDL_JoystickClose(joystick);
	SDL_QuitSubSystem(SDL_INIT_JOYSTICK);
}

///////////////////////////////

static struct VID_Context {
	SDL_Window* window;
	SDL_Renderer* renderer;
	SDL_Texture* texture;
	SDL_Texture* target;
	SDL_Texture* effect;
	SDL_Surface* buffer;
	SDL_Surface* screen;
	
	GFX_Renderer* blit; // yeesh
	
	int width;
	int height;
	int pitch;
	int sharpness;
} vid;

static int device_width;
static int device_height;
static int device_pitch;

// --- MinUI Zero: optional GPU-dark software present straight to /dev/fb0 (env ZERO_FB_PRESENT=1) ---
// The Brick's display is a plain framebuffer (32bpp little-endian XRGB8888 => BGRA bytes). For the
// MENU (native 1024x768, no scaling) we can convert+copy vid.screen (RGB565) directly to fb0 and skip
// GLES entirely, so the PowerVR GPU can suspend while browsing. Games keep the GLES scaling path.
static int   fb_present = 0; // GPU-dark software present for the MENU (env ZERO_FB_PRESENT)
static int   fb_game    = 0; // GPU-dark software present for GAMES (env ZERO_FB_GAME) — light systems
static int   fb_fd      = -1;
static uint8_t* fb_mem  = NULL;
static struct fb_var_screeninfo fb_vinfo;
static struct fb_fix_screeninfo fb_finfo;
static int   fbg_xmap[1280]; // src-x sample index per dst column (recomputed on geometry change)
static uint32_t fbg_rowbuf[1280]; // one h-scaled+converted dst row, reused across identical dst rows
static int   fbg_last_dw=-1, fbg_last_dh=-1, fbg_last_dx=-1, fbg_last_dy=-1;

static void PLAT_flipFB(void) {
	// RGB565 -> XRGB8888 (BGRA in memory), native res, into the currently-visible fb page.
	uint16_t* src = (uint16_t*)vid.screen->pixels;
	int sp = vid.screen->pitch / 2;                 // src stride in uint16
	int dp = fb_finfo.line_length / 4;              // dst stride in uint32
	uint32_t* dst = (uint32_t*)(fb_mem + (long)fb_vinfo.yoffset * fb_finfo.line_length);
	int w = vid.width, h = vid.height;
	for (int y=0; y<h; y++) {
		uint16_t* s = src + y*sp;
		uint32_t* d = dst + y*dp;
		for (int x=0; x<w; x++) {
			uint16_t p = s[x];
			uint32_t r = (p>>11)&0x1f, g = (p>>5)&0x3f, b = p&0x1f;
			d[x] = 0xff000000u | ((r<<3|r>>2)<<16) | ((g<<2|g>>4)<<8) | (b<<3|b>>2);
		}
	}
}

static void PLAT_flipFB_game(void) {
	// GPU-dark GAME present: software nearest-neighbor scale of the native core frame straight to
	// /dev/fb0 (page 0), replacing the GLES RenderCopy — so the PowerVR domain can suspend during
	// light-system play. Mirrors PLAT_flip's aspect/native/fullscreen dst geometry. Effects/overlays
	// (scanlines, DMG grid) are GLES-only and skipped here.
	if (!vid.blit) return;
	int sx = vid.blit->src_x, sy = vid.blit->src_y;
	int sw = vid.blit->src_w, sh = vid.blit->src_h;
	int dw, dh;
	if (vid.blit->aspect==0) { dw = sw * vid.blit->scale; dh = sh * vid.blit->scale; } // native/cropped
	else if (vid.blit->aspect>0) {                                                     // aspect fit
		dh = device_height; dw = dh * vid.blit->aspect;
		if (dw>device_width) { dw = device_width; dh = dw / vid.blit->aspect; }
	}
	else { dw = device_width; dh = device_height; }                                    // fullscreen
	if (dw>device_width)  dw = device_width;
	if (dh>device_height) dh = device_height;
	int dx = (device_width - dw) / 2;
	int dy = (device_height - dh) / 2;

	int fbstride = fb_finfo.line_length / 4;
	uint32_t* fb = (uint32_t*)fb_mem; // page 0

	// first frame / geometry change: pan to page 0, black the whole page (letterbox bars), rebuild x-map
	if (dw!=fbg_last_dw || dh!=fbg_last_dh || dx!=fbg_last_dx || dy!=fbg_last_dy) {
		fb_vinfo.yoffset = 0;
		ioctl(fb_fd, FBIOPAN_DISPLAY, &fb_vinfo);
		memset(fb_mem, 0, (long)fb_vinfo.yres * fb_finfo.line_length);
		for (int x=0; x<dw; x++) fbg_xmap[x] = sx + (x * sw) / dw;
		fbg_last_dw=dw; fbg_last_dh=dh; fbg_last_dx=dx; fbg_last_dy=dy;
	}

	uint16_t* src = (uint16_t*)vid.blit->src;
	int src_p16 = vid.blit->src_p / 2;
	int prev_syy = -1;
	int rowbytes = dw * 4;
	for (int y=0; y<dh; y++) {
		int syy = sy + (y * sh) / dh;
		if (syy != prev_syy) {
			// this dst row maps to a new source row — h-scale + RGB565->XRGB8888 into the row buffer once
			uint16_t* srow = src + (long)syy * src_p16;
			for (int x=0; x<dw; x++) {
				uint16_t p = srow[fbg_xmap[x]];
				uint32_t r=(p>>11)&0x1f, g=(p>>5)&0x3f, b=p&0x1f;
				fbg_rowbuf[x] = 0xff000000u | ((r<<3|r>>2)<<16) | ((g<<2|g>>4)<<8) | (b<<3|b>>2);
			}
			prev_syy = syy;
		}
		// blast the cached row to fb0 (memcpy is NEON-optimized; identical dst rows reuse the buffer)
		memcpy(fb + (long)(dy + y) * fbstride + dx, fbg_rowbuf, rowbytes);
	}
}

SDL_Surface* PLAT_initVideo(void) {
	char* device = getenv("DEVICE");
	is_brick = exactMatch("brick", device);
	is_brickpro = exactMatch("brickpro", device);
	// LOG_info("DEVICE: %s is_brick: %i\n", device, is_brick);
	
	SDL_InitSubSystem(SDL_INIT_VIDEO);
	SDL_ShowCursor(0);
	
	// SDL_version compiled;
	// SDL_version linked;
	// SDL_VERSION(&compiled);
	// SDL_GetVersion(&linked);
	// LOG_info("Compiled SDL version %d.%d.%d ...\n", compiled.major, compiled.minor, compiled.patch);
	// LOG_info("Linked SDL version %d.%d.%d.\n", linked.major, linked.minor, linked.patch);
	//
	// LOG_info("Available video drivers:\n");
	// for (int i=0; i<SDL_GetNumVideoDrivers(); i++) {
	// 	LOG_info("- %s\n", SDL_GetVideoDriver(i));
	// }
	// LOG_info("Current video driver: %s\n", SDL_GetCurrentVideoDriver());
	//
	// LOG_info("Available render drivers:\n");
	// for (int i=0; i<SDL_GetNumRenderDrivers(); i++) {
	// 	SDL_RendererInfo info;
	// 	SDL_GetRenderDriverInfo(i,&info);
	// 	LOG_info("- %s\n", info.name);
	// }
	//
	// LOG_info("Available display modes:\n");
	// SDL_DisplayMode mode;
	// for (int i=0; i<SDL_GetNumDisplayModes(0); i++) {
	// 	SDL_GetDisplayMode(0, i, &mode);
	// 	LOG_info("- %ix%i (%s)\n", mode.w,mode.h, SDL_GetPixelFormatName(mode.format));
	// }
	// SDL_GetCurrentDisplayMode(0, &mode);
	// LOG_info("Current display mode: %ix%i (%s)\n", mode.w,mode.h, SDL_GetPixelFormatName(mode.format));
	
	int w = FIXED_WIDTH;
	int h = FIXED_HEIGHT;
	int p = FIXED_PITCH;
	vid.window   = SDL_CreateWindow("", SDL_WINDOWPOS_UNDEFINED, SDL_WINDOWPOS_UNDEFINED, w,h, SDL_WINDOW_SHOWN);
	vid.renderer = SDL_CreateRenderer(vid.window,-1,SDL_RENDERER_ACCELERATED|SDL_RENDERER_PRESENTVSYNC);
	
	// SDL_RendererInfo info;
	// SDL_GetRendererInfo(vid.renderer, &info);
	// LOG_info("Current render driver: %s\n", info.name);
	
	SDL_SetHint(SDL_HINT_RENDER_SCALE_QUALITY,"0");
	vid.texture = SDL_CreateTexture(vid.renderer,SDL_PIXELFORMAT_RGB565, SDL_TEXTUREACCESS_STREAMING, w,h);
	vid.target	= NULL; // only needed for non-native sizes
	
	// SDL_SetTextureScaleMode(vid.texture, SDL_ScaleModeNearest);
	
	vid.buffer	= SDL_CreateRGBSurfaceFrom(NULL, w,h, FIXED_DEPTH, p, RGBA_MASK_565);
	vid.screen	= SDL_CreateRGBSurface(SDL_SWSURFACE, w,h, FIXED_DEPTH, RGBA_MASK_565);
	vid.width	= w;
	vid.height	= h;
	vid.pitch	= p;
	
	device_width	= w;
	device_height	= h;
	device_pitch	= p;
	
	vid.sharpness = SHARPNESS_SOFT;

	fb_present = getenv("ZERO_FB_PRESENT") && getenv("ZERO_FB_PRESENT")[0]=='1';
	fb_game    = getenv("ZERO_FB_GAME")    && getenv("ZERO_FB_GAME")[0]=='1';
	if (fb_present || fb_game) {
		fb_fd = open("/dev/fb0", O_RDWR);
		if (fb_fd>=0 && ioctl(fb_fd,FBIOGET_FSCREENINFO,&fb_finfo)==0 && ioctl(fb_fd,FBIOGET_VSCREENINFO,&fb_vinfo)==0) {
			fb_mem = mmap(0, fb_finfo.smem_len, PROT_READ|PROT_WRITE, MAP_SHARED, fb_fd, 0);
			if (fb_mem==MAP_FAILED) fb_mem = NULL;
		}
		if (!fb_mem) { fb_present = 0; fb_game = 0; if (fb_fd>=0) close(fb_fd); fb_fd = -1; }
		LOG_info("ZERO_FB: fb=%ux%u menu=%s game=%s (stride=%u yoff=%u)\n", fb_vinfo.xres, fb_vinfo.yres,
			fb_present?"on":"off", fb_game?"on":"off", fb_finfo.line_length, fb_vinfo.yoffset);
	}

	return vid.screen;
}

static void clearVideo(void) {
	for (int i=0; i<3; i++) {
		SDL_RenderClear(vid.renderer);
		SDL_FillRect(vid.screen, NULL, 0);
		
		SDL_LockTexture(vid.texture,NULL,&vid.buffer->pixels,&vid.buffer->pitch);
		SDL_FillRect(vid.buffer, NULL, 0);
		SDL_UnlockTexture(vid.texture);
		SDL_RenderCopy(vid.renderer, vid.texture, NULL, NULL);
		
		SDL_RenderPresent(vid.renderer);
	}
}

void PLAT_quitVideo(void) {
	if (!fb_present) clearVideo(); // direct-fb menu never scans the GLES buffers

	SDL_FreeSurface(vid.screen);
	SDL_FreeSurface(vid.buffer);
	if (vid.target) SDL_DestroyTexture(vid.target);
	if (vid.effect) SDL_DestroyTexture(vid.effect);
	SDL_DestroyTexture(vid.texture);
	SDL_DestroyRenderer(vid.renderer);
	SDL_DestroyWindow(vid.window);

	SDL_Quit();
	// Preserve the old fb0 clear without spawning cat to stream /dev/zero through the
	// device (~600ms). The direct-fb menu reuses its mapping; game/Smart Pro teardown
	// briefly maps fb0 so a layer switch can never expose stale pre-game contents.
	int clear_fd = fb_fd;
	uint8_t* clear_mem = fb_mem;
	size_t clear_size = clear_mem ? fb_finfo.smem_len : 0;
	if (!clear_mem) {
		struct fb_fix_screeninfo clear_finfo = {0};
		clear_fd = open("/dev/fb0", O_RDWR);
		if (clear_fd >= 0 && ioctl(clear_fd, FBIOGET_FSCREENINFO, &clear_finfo) == 0
				&& clear_finfo.smem_len) {
			clear_size = clear_finfo.smem_len;
			clear_mem = mmap(0, clear_size, PROT_READ|PROT_WRITE, MAP_SHARED, clear_fd, 0);
			if (clear_mem == MAP_FAILED) clear_mem = NULL;
		}
	}
	if (clear_mem) {
		memset(clear_mem, 0, clear_size);
		munmap(clear_mem, clear_size);
	}
	if (clear_fd >= 0) close(clear_fd);
	fb_mem = NULL;
	fb_fd = -1;
}

void PLAT_clearVideo(SDL_Surface* screen) {
	SDL_FillRect(screen, NULL, 0); // TODO: revisit
}
void PLAT_clearAll(void) {
	PLAT_clearVideo(vid.screen); // TODO: revist
	SDL_RenderClear(vid.renderer);
}

void PLAT_setVsync(int vsync) {
	
}

static int hard_scale = 4; // TODO: base src size, eg. 160x144 can be 4

static void resizeVideo(int w, int h, int p) {
	if (w==vid.width && h==vid.height && p==vid.pitch) return;
	
	// TODO: minarch disables crisp (and nn upscale before linear downscale) when native, is this true?
	
	if (w>=device_width && h>=device_height) hard_scale = 1;
	else {
		// smallest integer prescale that reaches the screen on either axis — anything
		// larger is pure GPU-bandwidth waste. A fixed 4x turned PS1 480i menus
		// (512/640x480, e.g. BR2 char select) into 2048x1920+ render targets
		// (~1GB/s of fill on the GE8300), saturating the GPU: present blocked, the
		// emulated machine slowed, and audio chopped while the CPU sat idle.
		// 240p-and-below content still resolves to 4x, unchanged.
		hard_scale = 4;
		for (int hs=2; hs<4; hs++) {
			if (w*hs>=device_width || h*hs>=device_height) { hard_scale = hs; break; }
		}
	}
	{ // dev A/B knob: force the Crisp prescale factor (ZERO_HARD_SCALE=1..4)
		char* hs_env = getenv("ZERO_HARD_SCALE");
		if (hs_env) { int v = atoi(hs_env); if (v >= 1 && v <= 4) hard_scale = v; }
	}

	LOG_info("resizeVideo(%i,%i,%i) hard_scale: %i crisp: %i\n",w,h,p, hard_scale,vid.sharpness==SHARPNESS_CRISP);

	SDL_FreeSurface(vid.buffer);
	SDL_DestroyTexture(vid.texture);
	if (vid.target) SDL_DestroyTexture(vid.target);
	
	SDL_SetHintWithPriority(SDL_HINT_RENDER_SCALE_QUALITY, vid.sharpness==SHARPNESS_SOFT?"1":"0", SDL_HINT_OVERRIDE);
	vid.texture = SDL_CreateTexture(vid.renderer,SDL_PIXELFORMAT_RGB565, SDL_TEXTUREACCESS_STREAMING, w,h);
	
	if (vid.sharpness==SHARPNESS_CRISP) {
		SDL_SetHintWithPriority(SDL_HINT_RENDER_SCALE_QUALITY, "1", SDL_HINT_OVERRIDE);
		vid.target = SDL_CreateTexture(vid.renderer,SDL_PIXELFORMAT_RGB565, SDL_TEXTUREACCESS_TARGET, w * hard_scale,h * hard_scale);
	}
	else {
		vid.target = NULL;
	}
	
	vid.buffer	= SDL_CreateRGBSurfaceFrom(NULL, w,h, FIXED_DEPTH, p, RGBA_MASK_565);

	vid.width	= w;
	vid.height	= h;
	vid.pitch	= p;
}

SDL_Surface* PLAT_resizeVideo(int w, int h, int p) {
	resizeVideo(w,h,p);
	return vid.screen;
}

void PLAT_setVideoScaleClip(int x, int y, int width, int height) {
	// buh
}
void PLAT_setNearestNeighbor(int enabled) {
	// always enabled?
}
void PLAT_setSharpness(int sharpness) {
	if (vid.sharpness==sharpness) return;
	int p = vid.pitch;
	vid.pitch = 0;
	vid.sharpness = sharpness;
	resizeVideo(vid.width,vid.height,p);
}

static struct FX_Context {
	int scale;
	int type;
	int color;
	int next_scale;
	int next_type;
	int next_color;
	int live_type;
} effect = {
	.scale = 1,
	.next_scale = 1,
	.type = EFFECT_NONE,
	.next_type = EFFECT_NONE,
	.live_type = EFFECT_NONE,
	.color = 0,
	.next_color = 0,
};
static void rgb565_to_rgb888(uint32_t rgb565, uint8_t *r, uint8_t *g, uint8_t *b) {
    // Extract the red component (5 bits)
    uint8_t red = (rgb565 >> 11) & 0x1F;
    // Extract the green component (6 bits)
    uint8_t green = (rgb565 >> 5) & 0x3F;
    // Extract the blue component (5 bits)
    uint8_t blue = rgb565 & 0x1F;

    // Scale the values to 8-bit range
    *r = (red << 3) | (red >> 2);
    *g = (green << 2) | (green >> 4);
    *b = (blue << 3) | (blue >> 2);
}
static void updateEffect(void) {
	if (effect.next_scale==effect.scale && effect.next_type==effect.type && effect.next_color==effect.color) return; // unchanged
	
	int live_scale = effect.scale;
	int live_color = effect.color;
	effect.scale = effect.next_scale;
	effect.type = effect.next_type;
	effect.color = effect.next_color;
	
	if (effect.type==EFFECT_NONE) return; // disabled
	if (effect.type==effect.live_type && effect.scale==live_scale && effect.color==live_color) return; // already loaded
	
	char* effect_path;
	int opacity = 128; // 1 - 1/2 = 50%
	if (effect.type==EFFECT_LINE || effect.type==EFFECT_LINE50 || effect.type==EFFECT_LINE25) {
		if (effect.scale<3) {
			effect_path = RES_PATH "/line-2.png";
		}
		else if (effect.scale<4) {
			effect_path = RES_PATH "/line-3.png";
		}
		else if (effect.scale<5) {
			effect_path = RES_PATH "/line-4.png";
		}
		else if (effect.scale<6) {
			effect_path = RES_PATH "/line-5.png";
		}
		else if (effect.scale<8) {
			effect_path = RES_PATH "/line-6.png";
		}
		else {
			effect_path = RES_PATH "/line-8.png";
		}
	}
	else if (effect.type==EFFECT_GRID || effect.type==EFFECT_GRID50 || effect.type==EFFECT_GRID25) {
		if (effect.scale<3) {
			effect_path = RES_PATH "/grid-2.png";
			opacity = 64; // 1 - 3/4 = 25%
		}
		else if (effect.scale<4) {
			effect_path = RES_PATH "/grid-3.png";
			opacity = 112; // 1 - 5/9 = ~44%
		}
		else if (effect.scale<5) {
			effect_path = RES_PATH "/grid-4.png";
			opacity = 144; // 1 - 7/16 = ~56%
		}
		else if (effect.scale<6) {
			effect_path = RES_PATH "/grid-5.png";
			opacity = 160; // 1 - 9/25 = ~64%
			// opacity = 96; // TODO: tmp, for white grid
		}
		else if (effect.scale<8) {
			effect_path = RES_PATH "/grid-6.png";
			opacity = 112; // 1 - 5/9 = ~44%
		}
		else if (effect.scale<11) {
			effect_path = RES_PATH "/grid-8.png";
			opacity = 144; // 1 - 7/16 = ~56%
		}
		else {
			effect_path = RES_PATH "/grid-11.png";
			opacity = 136; // 1 - 57/121 = ~52%
		}
	}
	if (effect.type==EFFECT_LINE50 || effect.type==EFFECT_GRID50) opacity /= 2;      // half-opacity variants
	else if (effect.type==EFFECT_LINE25 || effect.type==EFFECT_GRID25) opacity /= 4; // quarter-opacity variants
	
	// LOG_info("effect: %s opacity: %i\n", effect_path, opacity);
	SDL_Surface* tmp = IMG_Load(effect_path);
	if (tmp) {
		if (effect.type==EFFECT_GRID || effect.type==EFFECT_GRID50 || effect.type==EFFECT_GRID25) {
			if (effect.color) {
				// LOG_info("dmg color grid...\n");
			
				uint8_t r,g,b;
				rgb565_to_rgb888(effect.color,&r,&g,&b);
				// LOG_info("rgb %i,%i,%i\n",r,g,b); 
			
				uint32_t* pixels = (uint32_t*)tmp->pixels;
				int width = tmp->w;
				int height = tmp->h;
				for (int y = 0; y < height; ++y) {
				    for (int x = 0; x < width; ++x) {
				        uint32_t pixel = pixels[y * width + x];
				        uint8_t _,a;
				        SDL_GetRGBA(pixel, tmp->format, &_, &_, &_, &a);
				        if (a) pixels[y * width + x] = SDL_MapRGBA(tmp->format, r,g,b, a);
				    }
				}
				
				// if (r==247 && g==243 & b==247) opacity = 64;
			}
		}

		if (vid.effect) SDL_DestroyTexture(vid.effect);
		vid.effect = SDL_CreateTextureFromSurface(vid.renderer, tmp);
		SDL_SetTextureAlphaMod(vid.effect, opacity);
		SDL_FreeSurface(tmp);
		effect.live_type = effect.type;
	}
}
void PLAT_setEffect(int next_type) {
	effect.next_type = next_type;
}
void PLAT_setEffectColor(int next_color) {
	effect.next_color = next_color;
}
void PLAT_vsync(int remaining) {
	if (remaining>0) SDL_Delay(remaining);
}

scaler_t PLAT_getScaler(GFX_Renderer* renderer) {
	// LOG_info("getScaler for scale: %i\n", renderer->scale);
	effect.next_scale = renderer->scale;
	return scale1x1_c16;
}

void PLAT_blitRenderer(GFX_Renderer* renderer) {
	vid.blit = renderer;
	SDL_RenderClear(vid.renderer);
	resizeVideo(vid.blit->true_w,vid.blit->true_h,vid.blit->src_p);
}

// Debug HUD strips: minarch renders bitmap text at native resolution and the GPU
// composites them at 2x over the finished game frame — text size is constant on
// every system instead of inheriting the game's scale (8x on GBC = unreadable).
static struct {
	uint16_t* top; uint16_t* bottom;
	int w, h, stride;
	SDL_Texture* tex_top; SDL_Texture* tex_bottom;
	int tex_w, tex_h;
	SDL_Rect game; // panel rect of the most recently presented frame
} dbg;
void PLAT_setDebugOverlay(uint16_t* top, uint16_t* bottom, int w, int h, int stride) {
	dbg.top = top; dbg.bottom = bottom; dbg.w = w; dbg.h = h; dbg.stride = stride;
}
void PLAT_getGameRect(int* x, int* y, int* w, int* h) {
	*x = dbg.game.x; *y = dbg.game.y; *w = dbg.game.w; *h = dbg.game.h;
}
#define DBG_KEY 0xF81F // magenta in the RGB565 strips = fully transparent
static uint32_t* dbg_argb = NULL;
static void dbgConvert(SDL_Texture* tex, uint16_t* px) {
	for (int y = 0; y < dbg.h; y++) {
		uint16_t* row = px + y * dbg.stride;
		uint32_t* out = dbg_argb + y * dbg.w;
		for (int x = 0; x < dbg.w; x++) {
			uint16_t p = row[x];
			out[x] = (p == DBG_KEY) ? 0x00000000
				: 0xFF000000
				| ((p & 0xF800) << 8) | ((p & 0xE000) << 3)   // R
				| ((p & 0x07E0) << 5) | ((p & 0x0600) >> 1)   // G
				| ((p & 0x001F) << 3) | ((p & 0x001C) >> 2);  // B
		}
	}
	SDL_UpdateTexture(tex, NULL, dbg_argb, dbg.w * 4);
}
static void drawDebugOverlay(void) {
	// convert+upload only when the strip content changed (text updates ~1Hz; doing this
	// per frame measured ~1.9ms/frame — the HUD must not distort what it displays)
	static uint16_t* prev_top = NULL; static uint16_t* prev_bot = NULL;
	static int prev_n = 0;
	if (!dbg.top || dbg.w <= 0 || dbg.stride < dbg.w) return;
	if (dbg.tex_top && (dbg.tex_w != dbg.w || dbg.tex_h != dbg.h)) {
		SDL_DestroyTexture(dbg.tex_top); SDL_DestroyTexture(dbg.tex_bottom);
		dbg.tex_top = dbg.tex_bottom = NULL;
		free(dbg_argb); dbg_argb = NULL;
	}
	if (!dbg.tex_top) {
		dbg.tex_top = SDL_CreateTexture(vid.renderer, SDL_PIXELFORMAT_ARGB8888, SDL_TEXTUREACCESS_STREAMING, dbg.w, dbg.h);
		dbg.tex_bottom = SDL_CreateTexture(vid.renderer, SDL_PIXELFORMAT_ARGB8888, SDL_TEXTUREACCESS_STREAMING, dbg.w, dbg.h);
		if (dbg.tex_top) SDL_SetTextureBlendMode(dbg.tex_top, SDL_BLENDMODE_BLEND);
		if (dbg.tex_bottom) SDL_SetTextureBlendMode(dbg.tex_bottom, SDL_BLENDMODE_BLEND);
		dbg_argb = malloc(dbg.w * dbg.h * sizeof(uint32_t));
		dbg.tex_w = dbg.w; dbg.tex_h = dbg.h;
		prev_n = 0; // fresh textures hold no pixels — the content cache must not claim otherwise
	}
	if (!dbg.tex_top || !dbg.tex_bottom || !dbg_argb) return;
	int strip_n = dbg.stride * dbg.h;
	if (prev_n != strip_n) {
		free(prev_top); free(prev_bot);
		prev_top = malloc(strip_n * 2); prev_bot = malloc(strip_n * 2);
		if (prev_top) memset(prev_top, 0, strip_n * 2);
		if (prev_bot) memset(prev_bot, 0, strip_n * 2);
		prev_n = (prev_top && prev_bot) ? strip_n : 0;
	}
	if (!prev_n || memcmp(prev_top, dbg.top, strip_n * 2) != 0) {
		dbgConvert(dbg.tex_top, dbg.top);
		if (prev_n) memcpy(prev_top, dbg.top, strip_n * 2);
	}
	if (!prev_n || memcmp(prev_bot, dbg.bottom, strip_n * 2) != 0) {
		dbgConvert(dbg.tex_bottom, dbg.bottom);
		if (prev_n) memcpy(prev_bot, dbg.bottom, strip_n * 2);
	}
	// anchor to the game's panel rect (classic in-frame HUD hugged the game image):
	// one scaled pixel of margin inside the frame edges, clamped to the panel
	int S = DBG_OVERLAY_SCALE;
	int m = S;
	int gx = dbg.game.w > 0 ? dbg.game.x : 0;
	int gy = dbg.game.h > 0 ? dbg.game.y : 0;
	int gh = dbg.game.h > 0 ? dbg.game.h : device_height;
	int ty = gy + m;
	int by = gy + gh - dbg.h * S - m;
	if (ty < 0) ty = 0;
	if (by + dbg.h * S > device_height) by = device_height - dbg.h * S;
	SDL_RenderCopy(vid.renderer, dbg.tex_top, NULL, &(SDL_Rect){gx, ty, dbg.w * S, dbg.h * S});
	SDL_RenderCopy(vid.renderer, dbg.tex_bottom, NULL, &(SDL_Rect){gx, by, dbg.w * S, dbg.h * S});
}

// DEVMODE SCREENSHOT: read the live SDL renderer into an opaque ARGB8888 surface (adapted from
// NextUI). This captures what the panel actually shows on the Brick Pro / Smart Pro, whose display
// is the GLES layer, not /dev/fb0 (a raw fb0 grab there is blank). Called only from the
// devmode-gated GFX_maybeScreenshot path.
static void forceOpaque(SDL_Surface* s) { // stop the PNG saving as transparent
	Uint32* px = (Uint32*)s->pixels;
	int n = (s->pitch/4) * s->h;
	Uint32 amask = s->format->Amask;
	for (int i=0;i<n;i++) px[i] |= amask;
	SDL_SetSurfaceBlendMode(s, SDL_BLENDMODE_NONE);
}
SDL_Surface* PLAT_captureRendererToSurface(void) {
	// UI capture (menu + Tools): read the software surface vid.screen, which deterministically holds
	// the last-drawn frame. SDL_RenderReadPixels on the GLES backbuffer returns BLACK for a static
	// dialog (say.elf / confirm.elf / Optimize CPU render once via GFX_flip, then idle on GFX_sync)
	// because the backbuffer is undefined after SDL_RenderPresent; the menu only escaped it by
	// redrawing periodically (clock, wifi poll). During a GAME (vid.blit set) the renderer presents
	// every frame, so its backbuffer stays fresh AND carries the scale + effects: read that instead.
	// (Dan: black Optimize CPU shot, 2026-09-08.)
	if (!vid.blit && vid.screen) {
		SDL_Surface* out = SDL_ConvertSurfaceFormat(vid.screen, SDL_PIXELFORMAT_ARGB8888, 0);
		if (out) { forceOpaque(out); return out; }
	}
	if (!vid.renderer) return NULL;
	int w, h;
	SDL_GetRendererOutputSize(vid.renderer, &w, &h);
	SDL_Surface* surface = SDL_CreateRGBSurfaceWithFormat(0, w, h, 32, SDL_PIXELFORMAT_ARGB8888);
	if (!surface) return NULL;
	if (SDL_RenderReadPixels(vid.renderer, NULL, SDL_PIXELFORMAT_ARGB8888, surface->pixels, surface->pitch)!=0) {
		SDL_FreeSurface(surface);
		return NULL;
	}
	forceOpaque(surface);
	return surface;
}

void PLAT_flip(SDL_Surface* IGNORED, int ignored) {
	PLAT_uvReassert(); // voltage authority: out-persist the kernel (no-op unless armed)
	
	if (!vid.blit) {
		if (fb_present) { PLAT_flipFB(); return; } // GPU-dark software present for the native-res menu
		resizeVideo(device_width,device_height,FIXED_PITCH); // !!!???
		SDL_UpdateTexture(vid.texture,NULL,vid.screen->pixels,vid.screen->pitch);
		SDL_RenderCopy(vid.renderer, vid.texture, NULL,NULL);
		SDL_RenderPresent(vid.renderer);
		return;
	}

	if (fb_game) { PLAT_flipFB_game(); vid.blit = NULL; return; } // GPU-dark software present for games

	// Present-stage instrumentation (ZERO_PRESENT_STATS=1): CPU-side block time of each
	// stage, aggregated per second. These are API-call stalls (submit/backpressure), not
	// GPU execution time — exactly the bursts D61 showed a low ceiling starves.
	static int ps_on = -1;
	if (ps_on == -1) ps_on = (getenv("ZERO_PRESENT_STATS") != NULL);
	uint64_t ps_t0 = 0, ps_t1 = 0, ps_t2 = 0, ps_t3 = 0, ps_t4 = 0;
	if (ps_on) ps_t0 = getMicroseconds();

	SDL_UpdateTexture(vid.texture,NULL,vid.blit->src,vid.blit->src_p);
	if (ps_on) ps_t1 = getMicroseconds();

	SDL_Texture* target = vid.texture;
	int x = vid.blit->src_x;
	int y = vid.blit->src_y;
	int w = vid.blit->src_w;
	int h = vid.blit->src_h;
	if (vid.sharpness==SHARPNESS_CRISP) {
		SDL_SetRenderTarget(vid.renderer,vid.target);
		SDL_RenderCopy(vid.renderer, vid.texture, NULL,NULL);
		SDL_SetRenderTarget(vid.renderer,NULL);
		x *= hard_scale;
		y *= hard_scale;
		w *= hard_scale;
		h *= hard_scale;
		target = vid.target;
	}
	if (ps_on) ps_t2 = getMicroseconds();
	
	SDL_Rect* src_rect = &(SDL_Rect){x,y,w,h};
	SDL_Rect* dst_rect = &(SDL_Rect){0,0,device_width,device_height};
	if (vid.blit->aspect==0) { // native or cropped
		// LOG_info("src_rect %i,%i %ix%i\n",src_rect->x,src_rect->y,src_rect->w,src_rect->h);
		
		int w = vid.blit->src_w * vid.blit->scale;
		int h = vid.blit->src_h * vid.blit->scale;
		int x = (device_width - w) / 2;
		int y = (device_height - h) / 2;
		dst_rect->x = x;
		dst_rect->y = y;
		dst_rect->w = w;
		dst_rect->h = h;
						
		// LOG_info("dst_rect %i,%i %ix%i\n",dst_rect->x,dst_rect->y,dst_rect->w,dst_rect->h);
	}
	else if (vid.blit->aspect>0) { // aspect
		int h = device_height;
		int w = h * vid.blit->aspect;
		if (w>device_width) {
			double ratio = 1 / vid.blit->aspect;
			w = device_width;
			h = w * ratio;
		}
		int x = (device_width - w) / 2;
		int y = (device_height - h) / 2;
		// dst_rect = &(SDL_Rect){x,y,w,h};
		dst_rect->x = x;
		dst_rect->y = y;
		dst_rect->w = w;
		dst_rect->h = h;
	}
	
	SDL_RenderCopy(vid.renderer, target, src_rect, dst_rect);

	updateEffect();
	if (vid.blit && effect.type!=EFFECT_NONE && vid.effect) {
		SDL_RenderCopy(vid.renderer, vid.effect, &(SDL_Rect){0,0,dst_rect->w,dst_rect->h}, dst_rect);
	}
	dbg.game = *dst_rect;
	drawDebugOverlay();
	if (ps_on) ps_t3 = getMicroseconds();
	// ZERO_PRESENT_FINISH=1 (experiment; needs ZERO_PRESENT_STATS): block on GPU completion
	// BEFORE the swap, so "gpu" measures execution of the pass and "present" only the display
	// handoff. Serializes the GPU, so it is a diagnostic, never a default. Fetched through
	// SDL so the platform build needs no GLES link.
	static int pf_on = -1; static void (*pglFinish)(void) = NULL;
	if (pf_on == -1) {
		pf_on = ps_on && getenv("ZERO_PRESENT_FINISH") != NULL;
		if (pf_on) pglFinish = (void (*)(void))SDL_GL_GetProcAddress("glFinish");
		if (pf_on && !pglFinish) { pf_on = 0; LOG_warn("present-finish: glFinish not resolvable, stage disabled\n"); }
	}
	uint64_t ps_tg = ps_t3;
	if (pf_on) { pglFinish(); ps_tg = getMicroseconds(); }
	SDL_RenderPresent(vid.renderer);
	if (ps_on) {
		ps_t4 = getMicroseconds();
		static uint64_t s_up, s_pass, s_copy, s_gpu, s_pres;
		static uint32_t m_up, m_pass, m_copy, m_gpu, m_pres;
		static int s_n; static uint32_t s_at;
		uint32_t up = (uint32_t)(ps_t1-ps_t0), pass = (uint32_t)(ps_t2-ps_t1);
		uint32_t copy = (uint32_t)(ps_t3-ps_t2), gpu = (uint32_t)(ps_tg-ps_t3), pres = (uint32_t)(ps_t4-ps_tg);
		s_up += up; s_pass += pass; s_copy += copy; s_gpu += gpu; s_pres += pres; s_n++;
		if (up > m_up) m_up = up;
		if (pass > m_pass) m_pass = pass;
		if (copy > m_copy) m_copy = copy;
		if (gpu > m_gpu) m_gpu = gpu;
		if (pres > m_pres) m_pres = pres;
		uint32_t now = SDL_GetTicks();
		if (!s_at) s_at = now;
		else if (now - s_at >= 1000) {
			LOG_info("present-stats: n=%d upload=%llu/%u pass=%llu/%u copy=%llu/%u gpu=%llu/%u present=%llu/%u us(avg/max) hs=%d\n",
				s_n, s_up/s_n, m_up, s_pass/s_n, m_pass, s_copy/s_n, m_copy, s_gpu/s_n, m_gpu, s_pres/s_n, m_pres, hard_scale);
			s_up = s_pass = s_copy = s_gpu = s_pres = 0; s_n = 0;
			m_up = m_pass = m_copy = m_gpu = m_pres = 0;
			s_at = now;
		}
	}
	vid.blit = NULL;
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
	ovl.overlay = SDL_CreateRGBSurface(SDL_SWSURFACE, SCALE2(OVERLAY_WIDTH,OVERLAY_HEIGHT),OVERLAY_DEPTH,OVERLAY_RGBA_MASK);
	return ovl.overlay;
}
void PLAT_quitOverlay(void) {
	if (ovl.overlay) SDL_FreeSurface(ovl.overlay);
}
void PLAT_enableOverlay(int enable) {

}

///////////////////////////////

// Exact charge percentage for the charging screen, or -1 if unavailable.
// This lived inline in minui.c's ChargingScreen() — these axp2202 sysfs paths only exist on this
// platform, so shared menu code was silently tg5040-specific and showed "..." everywhere else.
int PLAT_getChargePercent(void) {
	int pct = -1;
	FILE* bf = fopen("/sys/class/power_supply/axp2202-battery/capacity", "r");
	if (bf) { if (fscanf(bf, "%d", &pct) != 1) pct = -1; fclose(bf); }
	if (pct < 0) return -1;

	// Honest 100%: the gauge rounds up before the charger actually terminates (the LED stays red
	// through the final taper). Hold at 99% until the kernel reports Full — the same moment the
	// LED turns green.
	if (pct >= 100) {
		char st[16] = "";
		FILE* sf = fopen("/sys/class/power_supply/axp2202-battery/status", "r");
		if (sf) { if (!fgets(st, sizeof(st), sf)) st[0] = 0; fclose(sf); }
		if (strncmp(st, "Full", 4) != 0) pct = 99;
	}
	return pct;
}

static int online = 0;
void PLAT_getBatteryStatus(int* is_charging, int* charge) {
	// *is_charging = 0;
	// *charge = PWR_LOW_CHARGE;
	// return;
	
	*is_charging = getInt("/sys/class/power_supply/axp2202-usb/online");

	int i = getInt("/sys/class/power_supply/axp2202-battery/capacity");
	// worry less about battery and more about the game you're playing
	     if (i>80) *charge = 100;
	else if (i>60) *charge =  80;
	else if (i>40) *charge =  60;
	else if (i>20) *charge =  40;
	else if (i>10) *charge =  20;
	else           *charge =  10;

	// // wifi status, just hooking into the regular PWR polling
	char status[16];
	getFile("/sys/class/net/wlan0/operstate", status,16);
	online = prefixMatch("up", status);
}

// NOTE: stock MinUI lit the ambient LEDs (scale 60) whenever the screen slept and during
// power-off, as an "asleep, not dead" indicator (PLAT_enableLED). Removed 2026-07-03: it was
// the second LED re-arm vector (found glowing on a charging, sleeping Brick) and burning three
// LED rails during the exact window the fork promises to run dark is anti-thesis. Don't re-add.

#define BLANK_PATH "/sys/class/graphics/fb0/blank"
void PLAT_enableBacklight(int enable) {
	if (enable) {
		// putInt(BLANK_PATH,0);
		if (is_brick || is_brickpro) SetRawBrightness(8);
		SetBrightness(GetBrightness());
	}
	else {
		// putInt(BLANK_PATH,4);
		SetRawBrightness(0);
	}
}

void PLAT_powerOff(void) {
	PLAT_restoreCPUVolt(); // stock voltage for the shutdown path (Codex audit; no-op if uv never armed)

	// break the MinUI.pak/launch.sh while loop
	unlink("/tmp/minui_exec");
	sleep(2);

	SetRawVolume(MUTE_VOLUME_RAW);
	PLAT_enableBacklight(0);
	SND_quit();
	VIB_quit();
	PWR_quit();
	GFX_quit();
	
	exit(0); // poweroff handled by PLATFORM/bin/shutdown
}

int PLAT_supportsDeepSleep(void) { return 1; } // tg5040/Brick can suspend-to-RAM

///////////////////////////////

// Hybrid governor: boot.sh selects the `schedutil` kernel governor; all CPU control
// here sets the frequency *ceiling* (scaling_max_freq) and lets the kernel pick beneath
// it. The kernel snaps to the nearest supported OPP, so an out-of-ladder kHz is coerced,
// never an error. NOTE: 2.0GHz is an overclock — PERFORMANCE caps at the 1.8GHz stock max.
#define MAX_FREQ_PATH "/sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq"
// CEILING CHOKE POINT: every ceiling write orders voltage around it — raise volts BEFORE
// raising the ceiling, lower the ceiling BEFORE lowering volts. This must cover ALL
// callers, not just the governor: the in-game menu exit path (PWR_setCPUSpeed) jumps the
// ceiling from menu-low straight to 1608/1800, and without this ordering the hold thread
// kept asserting the low-ceiling voltage at the new high clock — below the chip's cliff
// — for up to one governor tick. Found in the pre-merge audit; do not bypass this helper.
static int uv_set_for_ceil(int khz);
static int uv_last_ceiling = 0;
static pthread_mutex_t uv_ceiling_lock = PTHREAD_MUTEX_INITIALIZER;

static int uv_readCeiling(void) {
	FILE* f = fopen(MAX_FREQ_PATH, "r");
	int khz = 0;
	if (f) {
		if (fscanf(f, "%d", &khz) != 1) khz = 0;
		fclose(f);
	}
	return khz;
}

static int uv_writeCeiling(int khz, int* actual) {
	FILE* f = fopen(MAX_FREQ_PATH, "w");
	int wrote = 0;
	if (f) {
		wrote = fprintf(f, "%d", khz) > 0 && fflush(f) == 0 && !ferror(f);
		if (fclose(f) != 0) wrote = 0;
	}
	int got = uv_readCeiling();
	if (actual) *actual = got;
	if (!wrote || got != khz) {
		LOG_info("uv: ceiling write %dkHz failed readback (actual=%d, errno=%d)\n",
			khz, got, errno);
		return 0;
	}
	return 1;
}

static void uv_ceilingWrite(int khz) {
	if (khz <= 0) return;
	// HARD stock cap at the choke point: the kernel exposes a 2.0GHz OC OPP, and env
	// overrides (MINARCH_FMIN/FMAX) or third-party paks could request it. The charter
	// is no-overclock-ever — enforce it where EVERY ceiling writer passes (Codex audit).
	if (khz > 1800000) khz = 1800000;
	pthread_mutex_lock(&uv_ceiling_lock);
	int current = uv_last_ceiling;
	if (current <= 0) {
		current = uv_readCeiling();
		if (current <= 0) {
			// Unknown startup state: assume the highest stock OPP so the first transition
			// can only lower the clock before it lowers voltage.
			current = 1800000;
			LOG_info("uv: could not read initial ceiling; assuming %dkHz for safe ordering\n", current);
		}
		uv_last_ceiling = current;
	}

	int actual = 0;
	if (khz > current) {
		if (!uv_set_for_ceil(khz)) {
			LOG_info("uv: refusing ceiling raise to %dkHz; voltage readback failed\n", khz);
			pthread_mutex_unlock(&uv_ceiling_lock);
			return;
		}
		if (!uv_writeCeiling(khz, &actual)) {
			// A readable ceiling is authoritative. If readback itself failed, hold the
			// voltage for stock max because the write may still have reached the kernel.
			if (actual > 0) uv_set_for_ceil(actual);
			else uv_set_for_ceil(1800000);
			if (actual > 0) uv_last_ceiling = actual;
			pthread_mutex_unlock(&uv_ceiling_lock);
			return;
		}
	}
	else {
		if (!uv_writeCeiling(khz, &actual)) {
			// Do not lower voltage unless a readback proves the live ceiling. Keeping the
			// previous (higher) target is inefficient but electrically safe.
			if (actual > 0) {
				uv_last_ceiling = actual;
				uv_set_for_ceil(actual);
			}
			pthread_mutex_unlock(&uv_ceiling_lock);
			return;
		}
		if (!uv_set_for_ceil(actual))
			LOG_info("uv: voltage update failed after lowering to %dkHz; retaining higher rail\n", actual);
	}
	uv_last_ceiling = actual;
	pthread_mutex_unlock(&uv_ceiling_lock);
}

void PLAT_setCPUSpeed(int speed) {
	int freq = 0;
	switch (speed) {
		case CPU_SPEED_MENU: 		freq =  600000; break;
		case CPU_SPEED_POWERSAVE:	freq = 1200000; break;
		case CPU_SPEED_NORMAL: 		freq = 1608000; break;
		case CPU_SPEED_PERFORMANCE: freq = 1800000; break; // stock max, NOT 2000000 (OC)
	}
	uv_ceilingWrite(freq);
}

// Closed-loop governor: set the cpufreq ceiling (kHz) via scaling_max_freq; schedutil
// picks the instantaneous frequency beneath it. Voltage ordering handled by the choke point.
void PLAT_setCPUMaxFreq(int khz) {
	uv_ceilingWrite(khz);
}

// ============================ Optimize Device: voltage authority ============================
// Runtime per-device undervolt (P2 campaign result, docs/dtb-undervolt-primer.md). The CPU
// rail is the external TCS4838 buck at i2c-6 0x41 (FAN53555-family VSEL registers,
// 712.5mV base + 12.5mV/step). Voltages are RAM-only: any reboot/crash returns to the
// kernel's stock OPP table by construction.
//
// SAFETY MODEL (all gates must pass or this stays a permanent no-op):
//   - table file present (written only by a completed calibration campaign)
//   - VSEL register decode matches the kernel regulator's reported voltage at init
//   - requested voltage within [table floor .. stock max], on a 12.5mV step
//   - ZERO_NO_UV=1 env kills it
// Every ceiling caller is ordered by uv_ceilingWrite (volt-up before clock-up,
// clock-down before volt-down).

#define SHARED_UV_DIR  "/mnt/SDCARD/.userdata/tg5040/undervolt"
#define UV_I2C_DEV     "/dev/i2c-6"
#define UV_I2C_ADDR    0x41
#define UV_BASE_UV     712500
#define UV_STEP_UV     12500
#define UV_CAL_FLOOR   762500
#define UV_STOCK_MAX   1187500 // stock voltage of the top OPP: always-safe restore value
// Per-chip slot (2026-09-02): chips/<serial>/ holds THIS chip's table so one card can carry a
// calibration per device it visits. Resolved in uv_init; falls back to the flat legacy layout so
// an un-migrated card keeps its undervolt after an update (the tool migrates on its next open).
static char uv_base[192] = SHARED_UV_DIR;
static const char* uv_path(const char* leaf) {
	static char p[256];
	snprintf(p, sizeof p, "%s/%s", uv_base, leaf);
	return p;
}

#define UV_TABLE_ROWS 8
static const int uv_expected_khz[UV_TABLE_ROWS] = {
	408000, 600000, 816000, 1008000, 1200000, 1416000, 1608000, 1800000
};
static struct { int khz; int uv; } uv_table[UV_TABLE_ROWS];
static int uv_stock[UV_TABLE_ROWS];
static int uv_n = 0;
static int uv_fd = -1;      // -1 = uninitialized, -2 = permanently disabled
static int uv_applied = 0;  // last commanded uV (0 = stock/untouched)
static int uv_target = 0;   // the voltage the authority wants HELD right now (0 = none)
static pthread_t uv_thread;
static pthread_mutex_t uv_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t uv_cv = PTHREAD_COND_INITIALIZER;
static int uv_thread_run = 0;
static int uv_thread_started = 0;

static int uv_reg_read(int reg) {
	unsigned char r = (unsigned char)reg, v;
	if (write(uv_fd, &r, 1) != 1 || read(uv_fd, &v, 1) != 1) return -1;
	return v;
}
static pthread_mutex_t uv_init_lock = PTHREAD_MUTEX_INITIALIZER;
static int uv_init(void) {
#ifndef ZERO_UV_ENGINE
	// The voltage engine compiles ONLY into minarch (-DZERO_UV_ENGINE). The menu carried it
	// by accident of shared compilation, and its regulator-sysfs cross-check PANICS the BSP
	// kernel when run during early cold boot (D39, the boot-loop incident root cause).
	uv_fd = -2;
	return 0;
#endif
	if (uv_fd == -2) return 0;
	if (uv_fd >= 0) return 1;
	// Early-boot guard: auto-resume can launch minarch straight from boot into the same
	// panic window. Stay unarmed (uv_fd = -1 keeps retrying) until the kernel has settled.
	{
		FILE* uf = fopen("/proc/uptime", "r");
		double up = 0;
		if (uf) { if (fscanf(uf, "%lf", &up) != 1) up = 0; fclose(uf); }
		if (up < 30.0) return 0; // not yet — the governor tick will retry
	}
	pthread_mutex_lock(&uv_init_lock); // thread_video can race the first call from two threads
	if (uv_fd != -1) { int ok = (uv_fd >= 0); pthread_mutex_unlock(&uv_init_lock); return ok; }
	uv_fd = -2; // assume failure; prove otherwise
	char* e = getenv("ZERO_NO_UV");
	if (e && e[0] && e[0] != '0') { pthread_mutex_unlock(&uv_init_lock); return 0; }
	// CARD-SWAP GUARD: the table describes ONE chip. Require the eFUSE chip serial
	// (sunxi_serial — globally unique per die); an unbound legacy table stays stock.
	{
		char dev_chip[64] = {0};
		FILE* sf = fopen("/sys/class/sunxi_info/sys_info", "r");
		if (sf) {
			char line[128];
			while (fgets(line, sizeof line, sf)) {
				if (strstr(line, "sunxi_serial")) {
					char* c = strchr(line, ':');
					if (c) { c++; while (*c == ' ' || *c == '\t') c++;
						snprintf(dev_chip, sizeof dev_chip, "%s", c);
						char* nl = strchr(dev_chip, '\n'); if (nl) *nl = 0; }
					break;
				}
			}
			fclose(sf);
		}
		{
			char probe[256];
			snprintf(uv_base, sizeof uv_base, SHARED_UV_DIR "/chips/%s", dev_chip);
			// the slot DIRECTORY is authoritative once it exists: a reverted slot must stay at
			// stock, never fall back to a stale flat table. Only a never-migrated card is flat.
			snprintf(probe, sizeof probe, "%s", uv_base);
			if (!dev_chip[0] || access(probe, F_OK) != 0) {
				snprintf(uv_base, sizeof uv_base, "%s", SHARED_UV_DIR);
				LOG_info("uv: legacy flat layout\n");
			}
			else LOG_info("uv: table slot chips/%s\n", dev_chip);
		}
		char tab_chip[64] = {0};
		FILE* cf = fopen(uv_path("table.chip"), "r");
		if (cf) { if (fgets(tab_chip, sizeof tab_chip, cf)) { char* nl = strpbrk(tab_chip, "\r\n "); if (nl) *nl = 0; } fclose(cf); }

		if (!dev_chip[0] || !tab_chip[0] || strcmp(dev_chip, tab_chip) != 0) {
			LOG_info("uv: table chip identity missing or mismatched — staying stock\n");
			pthread_mutex_unlock(&uv_init_lock);
			return 0;
		}
	}
	FILE* sf = fopen(uv_path("table.stock"), "r");
	if (!sf) { pthread_mutex_unlock(&uv_init_lock); return 0; }
	int khz, uv, valid = 1, stock_n = 0;
	char line[128], extra;
	while (fgets(line, sizeof line, sf)) {
		if (stock_n >= UV_TABLE_ROWS || sscanf(line, "%d %d %c", &khz, &uv, &extra) != 2 ||
		    khz != uv_expected_khz[stock_n] || uv < UV_BASE_UV || uv > UV_STOCK_MAX ||
		    (uv - UV_BASE_UV) % UV_STEP_UV || (stock_n > 0 && uv < uv_stock[stock_n-1])) {
			valid = 0;
			break;
		}
		uv_stock[stock_n++] = uv;
	}
	if (ferror(sf) || stock_n != UV_TABLE_ROWS) valid = 0;
	fclose(sf);
	FILE* f = valid ? fopen(uv_path("table.conf"), "r") : NULL;
	if (!f) { pthread_mutex_unlock(&uv_init_lock); return 0; } // no complete calibration -> stock
	uv_n = 0;
	while (fgets(line, sizeof line, f)) {
		if (uv_n >= UV_TABLE_ROWS || sscanf(line, "%d %d %c", &khz, &uv, &extra) != 2 ||
		    khz != uv_expected_khz[uv_n] || uv < UV_CAL_FLOOR || uv > UV_STOCK_MAX ||
		    (uv - UV_BASE_UV) % UV_STEP_UV || uv > uv_stock[uv_n] ||
		    (uv_n < 3 && uv != uv_stock[uv_n]) ||
		    (uv_n > 0 && uv < uv_table[uv_n-1].uv)) {
			valid = 0;
			break;
		}
		uv_table[uv_n].khz = khz;
		uv_table[uv_n].uv = uv;
		uv_n++;
	}
	if (ferror(f) || uv_n != UV_TABLE_ROWS) valid = 0;
	fclose(f);
	if (!valid) uv_n = 0;
	if (!uv_n) { LOG_info("uv: table invalid, staying stock\n"); pthread_mutex_unlock(&uv_init_lock); return 0; }
	int fd = open(UV_I2C_DEV, O_RDWR);
	if (fd < 0) { pthread_mutex_unlock(&uv_init_lock); return 0; }
	if (ioctl(fd, I2C_SLAVE_FORCE, UV_I2C_ADDR) < 0) { close(fd); pthread_mutex_unlock(&uv_init_lock); return 0; }
	uv_fd = fd;
	// decode-match gate: VSEL must agree with the kernel regulator before we ever write.
	// Retried: a single read can race a DVFS transition (register vs the kernel's cached
	// value) and false-negative — a real wrong-chip mismatch fails every attempt. (The
	// first deploy hit exactly this race; the gate fail-safed to stock, as designed.)
	int v0 = -1, kuv = -1, tries;
	for (tries = 0; tries < 5; tries++) {
	v0 = uv_reg_read(0x00);
	kuv = -1;
	for (int i = 0; i < 32; i++) {
		char path[96], name[32];
		snprintf(path, sizeof path, "/sys/class/regulator/regulator.%d/name", i);
		FILE* rf = fopen(path, "r");
		if (!rf) continue;
		if (fgets(name, sizeof name, rf) && !strncmp(name, "tcs4838-dcdc0", 13)) {
			fclose(rf);
			snprintf(path, sizeof path, "/sys/class/regulator/regulator.%d/microvolts", i);
			rf = fopen(path, "r");
			if (rf) { if (fscanf(rf, "%d", &kuv) != 1) kuv = -1; fclose(rf); }
			break;
		}
		fclose(rf);
	}
	if (v0 >= 0 && kuv >= 0 && UV_BASE_UV + (v0 & 0x3F) * UV_STEP_UV == kuv) break;
	usleep(20000); // let any in-flight DVFS transition settle
	}
	if (tries >= 5) {
		LOG_info("uv: decode mismatch after retries (reg=%d kernel=%d) — staying stock\n", v0, kuv);
		close(uv_fd); uv_fd = -2; pthread_mutex_unlock(&uv_init_lock); return 0;
	}
	LOG_info("uv: voltage authority armed (%d table entries)\n", uv_n);
	pthread_mutex_unlock(&uv_init_lock);
	return 1;
}
static int uv_write(int uv) {
	if (uv < UV_BASE_UV || uv > UV_STOCK_MAX || (uv - UV_BASE_UV) % UV_STEP_UV) return 0;
	int vsel = (uv - UV_BASE_UV) / UV_STEP_UV;
	int v0 = uv_reg_read(0x00), v1 = uv_reg_read(0x01);
	if (v0 < 0 || v1 < 0) return 0;
	unsigned char b0[2] = { 0x00, (unsigned char)((v0 & 0xC0) | vsel) };
	unsigned char b1[2] = { 0x01, (unsigned char)((v1 & 0xC0) | vsel) };
	if (write(uv_fd, b0, 2) != 2 || write(uv_fd, b1, 2) != 2) return 0;
	v0 = uv_reg_read(0x00);
	v1 = uv_reg_read(0x01);
	if (v0 < 0 || v1 < 0 || (v0 & 0x3F) != vsel || (v1 & 0x3F) != vsel) return 0;
	uv_applied = uv;
	return 1;
}
int PLAT_supportsUndervolt(void) { return uv_init(); }
static int uv_set_for_ceil(int khz) {
	// voltage that covers the highest OPP the kernel may round the ceiling UP to:
	// smallest table entry >= khz (table sorted ascending); above the table -> stock.
	if (!uv_init()) return 1; // stock regulator path remains authoritative
	int uv = 0;
	// LIGHT-LOAD FLOOR GUARD (2026-07-09, measured): undervolt holds at a <=816MHz
	// ceiling brownout-reboot the device within minutes (DK parked at the 408 floor died
	// twice with UV on, ran 12 min clean with UV off). The calibration proved the floor
	// voltage under STRESS; a game idling at the floor puts the buck in light-load mode
	// where the same rail is not stable — so run STOCK voltage at or below an 816MHz ceiling.
	// "Stock" means STAND DOWN (uv_target=0: the hold thread stops writing). The kernel
	// re-asserts its per-OPP stock voltage on the next DVFS transition; at a PINNED floor
	// (no transitions) the register simply retains the last held table voltage — which is
	// always >= stock for every OPP at or below the old ceiling, so never a brownout risk
	// (gate-verified 2026-07-11: 812.5mV retained at 408MHz vs 762.5 stock). The previous
	// code actively held UV_STOCK_MAX here — the TOP OPP's 1187.5mV against a 408MHz clock,
	// overvolting exactly the light loads this guard exists to protect (audit 2026-07-11).
	if (khz > 816000)
		for (int i = 0; i < uv_n; i++) if (uv_table[i].khz >= khz) { uv = uv_table[i].uv; break; }
	if (!uv) { // low ceiling, or ceiling above the table: stock rules, stop holding
		pthread_mutex_lock(&uv_lock);
		uv_target = 0;
		pthread_mutex_unlock(&uv_lock);
		return 1;
	}
	// The kernel RE-ASSERTS its stock voltage on every DVFS transition, so the register is
	// the only truth — read it and rewrite when it drifted (one i2c read per tick, ~2Hz).
	pthread_mutex_lock(&uv_lock);
	int v0 = uv_reg_read(0x00);
	int v1 = uv_reg_read(0x01);
	int applied = v0 >= 0 && v1 >= 0 &&
		UV_BASE_UV + (v0 & 0x3F) * UV_STEP_UV == uv &&
		UV_BASE_UV + (v1 & 0x3F) * UV_STEP_UV == uv;
	if (!applied && !uv_write(uv)) {
		pthread_mutex_unlock(&uv_lock);
		return 0;
	}
	uv_target = uv;
	pthread_cond_signal(&uv_cv);
	pthread_mutex_unlock(&uv_lock);
	return 1;
}
void PLAT_setCPUVoltForCeil(int khz) { (void)uv_set_for_ceil(khz); }
// Rail-war armistice (v1.4, D54). The old loop verified the rail over i2c EVERY tick —
// 400 bus reads/sec while holding uv_lock — and that bus contention inflated DVFS
// transition latency exactly in transition-heavy scenes (BR2 fights: gen 49/60 with UV
// vs 57+ without, both devices, first field day of calibrated silicon). The kernel only
// re-stocks the rail on a DVFS transition, and a transition is visible as a
// scaling_cur_freq change — a sysfs pread, no i2c. So: poll cur_freq each tick (cheap),
// touch the i2c bus only right after a transition plus a 1s heartbeat. A missed
// correction leaves the rail at stock — always >= our guarded value — so the failure
// direction is efficiency, never safety. Ordering safety unchanged: uv_target always
// covers the ceiling (raised before the clock, lowered after it). If cur_freq can't be
// read, every tick verifies — the old behavior, as fallback.
static void* uv_hold(void* arg) {
	(void)arg;
	int freq_fd = open("/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq", O_RDONLY);
	long last_freq = -1;
	int ticks_since_i2c = 200; // first armed tick verifies immediately
	while (__atomic_load_n(&uv_thread_run, __ATOMIC_ACQUIRE)) {
		pthread_mutex_lock(&uv_lock);
		while (__atomic_load_n(&uv_thread_run, __ATOMIC_ACQUIRE) && !uv_target)
			pthread_cond_wait(&uv_cv, &uv_lock);
		if (!__atomic_load_n(&uv_thread_run, __ATOMIC_ACQUIRE)) {
			pthread_mutex_unlock(&uv_lock);
			break;
		}
		int need_check = 0;
		if (freq_fd >= 0) {
			char fbuf[16];
			ssize_t n = pread(freq_fd, fbuf, sizeof(fbuf) - 1, 0);
			if (n > 0) {
				fbuf[n] = 0;
				long f = atol(fbuf);
				if (f != last_freq) { last_freq = f; need_check = 1; }
			} else need_check = 1;
		} else need_check = 1;
		if (++ticks_since_i2c >= 200) need_check = 1; // 1s heartbeat
		if (need_check && uv_fd >= 0 && uv_target) {
			ticks_since_i2c = 0;
			int v0 = uv_reg_read(0x00);
			int v1 = uv_reg_read(0x01);
			if (v0 < 0 || v1 < 0 || UV_BASE_UV + (v0 & 0x3F) * UV_STEP_UV != uv_target ||
			    UV_BASE_UV + (v1 & 0x3F) * UV_STEP_UV != uv_target) uv_write(uv_target);
		}
		pthread_mutex_unlock(&uv_lock);
		usleep(5000); // ~200Hz tick; i2c only on transitions + heartbeat
	}
	if (freq_fd >= 0) close(freq_fd);
	return NULL;
}
void PLAT_uvReassert(void) {
	// Lazily start the hold thread on first armed frame (no-op unless the authority armed).
	// Hot path (audit P2): once the thread is up, every flip returns on one atomic load —
	// the flip path must never queue behind uv_lock while it's busy with i2c.
	if (__atomic_load_n(&uv_thread_started, __ATOMIC_ACQUIRE)) return;
	pthread_mutex_lock(&uv_lock);
	if (uv_fd < 0 || !uv_target || __atomic_load_n(&uv_thread_started, __ATOMIC_ACQUIRE)) { pthread_mutex_unlock(&uv_lock); return; }
	__atomic_store_n(&uv_thread_run, 1, __ATOMIC_RELEASE);
	if (pthread_create(&uv_thread, NULL, uv_hold, NULL) != 0)
		__atomic_store_n(&uv_thread_run, 0, __ATOMIC_RELEASE);
	else {
		__atomic_store_n(&uv_thread_started, 1, __ATOMIC_RELEASE);
		LOG_info("uv: hold thread started (transition-gated, holding %duV)\n", uv_target);
	}
	pthread_mutex_unlock(&uv_lock);
}
void PLAT_emergencyRestoreCPUVolt(void) {
	// SIGNAL-HANDLER-SAFE restore: NO mutex (the hold thread holds uv_lock ~20% of the
	// time; locking here could deadlock a dying process into a frozen zombie). Ordering:
	// clear the target first so the hold thread stops re-asserting, then one best-effort
	// raw write of stock-max. Post-crash, the kernel re-stocks on the next DVFS transition
	// anyway (and sequences volts-before-freq), so this is belt on top of kernel braces.
	__atomic_store_n(&uv_thread_run, 0, __ATOMIC_RELEASE);
	uv_target = 0;
	if (uv_fd >= 0 && uv_applied) uv_write(UV_STOCK_MAX);
	uv_applied = 0;
}
void PLAT_restoreCPUVolt(void) {
	// one always-safe write: stock max voltage; the kernel re-asserts exact stock on the
	// next OPP transition. Called on quit and from the crash handler.
	__atomic_store_n(&uv_thread_run, 0, __ATOMIC_RELEASE); // stop the hold thread first
	if (__atomic_load_n(&uv_thread_started, __ATOMIC_ACQUIRE)) {
		pthread_mutex_lock(&uv_lock);
		pthread_cond_broadcast(&uv_cv);
		pthread_mutex_unlock(&uv_lock);
		pthread_join(uv_thread, NULL);
		__atomic_store_n(&uv_thread_started, 0, __ATOMIC_RELEASE);
	}
	pthread_mutex_lock(&uv_lock);
	uv_target = 0;
	if (uv_fd >= 0 && uv_applied) uv_write(UV_STOCK_MAX);
	uv_applied = 0;
	pthread_mutex_unlock(&uv_lock);
}
void PLAT_setUndervolt(int millivolts) { (void)millivolts; } // superseded by the table API

#define RUMBLE_PATH "/sys/class/gpio/gpio227/value"
#define RUMBLE_VOLTAGE_PATH "/sys/class/motor/voltage"
static void setRumble(int strength, int respect_mute) {
	// the motor needs a drive voltage before the enable pin does anything — the Brick
	// boots with a usable default, the Smart Pro with none (silent motor). 1.5V per
	// NextUI's tg5040 implementation. Set once, lazily, only when rumble is first used.
	// The Brick Pro drives its motor at 0.9V, not 1.5V (NextUI's tg5040 keymon, the only tested
	// Brick Pro reference). Same enable pin, different drive; 1.5V here would over-drive it.
	static int motor_powered = 0;
	if (strength && !motor_powered) {
		putInt(RUMBLE_VOLTAGE_PATH, is_brickpro ? 900000 : 1500000);
		motor_powered = 1;
	}
	putInt(RUMBLE_PATH, (strength && (!respect_mute || !GetMute()))?1:0);
}
void PLAT_setRumble(int strength) { setRumble(strength, 1); }
void PLAT_setSystemRumble(int strength) { setRumble(strength, 0); }

int PLAT_pickSampleRate(int requested, int max) {
	return MIN(requested, max);
}

char* PLAT_getModel(void) {
	char* model = getenv("TRIMUI_MODEL");
	if (model) return model;
	return "Trimui Smart Pro";
}

int PLAT_isOnline(void) {
	return online;
}
