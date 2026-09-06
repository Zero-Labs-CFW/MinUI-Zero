#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "scaler.h"
#include "geometry-types.inc"

typedef struct { int w, h, pitch; void* pixels; } SDL_Surface;
static GFX_Renderer renderer;
static struct { double aspect_ratio; } core;
static int DEVICE_WIDTH = 640, DEVICE_HEIGHT = 480, DEVICE_PITCH = 1280;
static int screen_scaling, screen_effect, next_effect, fit, downsample;
static SDL_Surface surface, *screen = &surface;
#define HDMI_WIDTH 1280
#define FIXED_BPP 2
#define LOG_info(...) ((void)0)
#define scale1x1_n16 scale1x1_c16
#define scale2x2_n16 scale2x2_c16
#define scale3x3_n16 scale3x3_c16
#define scale4x4_n16 scale4x4_c16
#define scale5x5_n16 scale5x5_c16
#define scale6x6_n16 scale6x6_c16
static void buffer_realloc(int w, int h, int p) { (void)w; (void)h; (void)p; }
static SDL_Surface* GFX_resize(int w, int h, int p) {
	assert(w > 0 && h > 0 && p >= w * 2);
	free(surface.pixels);
	surface = (SDL_Surface){w, h, p, calloc(h, p)};
	assert(surface.pixels);
	return &surface;
}
#include "platform-scaler.inc"
#define GFX_getScaler PLAT_getScaler
// These are extracted verbatim at test time, never copied implementations.
#include "select-scaler.inc"
#include "menu-scale.inc"

static void run(int w, int h, double aspect, int mode, int effect) {
	core.aspect_ratio = aspect;
	screen_scaling = mode;
	screen_effect = next_effect = effect;
	selectScaler(w, h, w * 2);
}

static void check_menu(int sw, int sh) {
	SDL_Surface src = {sw, sh, sw * 2, malloc(sw * sh * 2)};
	assert(src.pixels);
	for (int i = 0; i < sw * sh; i++) ((uint16_t*)src.pixels)[i] = 0xffff;
	for (int divisor = 1; divisor <= 2; divisor++) {
		int w = DEVICE_WIDTH / divisor, h = DEVICE_HEIGHT / divisor;
		SDL_Surface dst = {w, h, w * 2, calloc(w * h, 2)};
		assert(dst.pixels);
		Menu_scale(&src, &dst);
		for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
			int rx = renderer.dst_x / divisor, ry = renderer.dst_y / divisor;
			int rw = renderer.dst_w / divisor, rh = renderer.dst_h / divisor;
			uint16_t expected = x >= rx && x < rx + rw && y >= ry && y < ry + rh ? 0xffff : 0;
			assert(((uint16_t*)dst.pixels)[y * w + x] == expected);
		}
		free(dst.pixels);
	}
	free(src.pixels);
}

int main(void) {
	for (int effect = EFFECT_LINE; effect < EFFECT_COUNT; effect++) {
		run(160, 144, 10.0 / 9, SCALE_NATIVE, effect);
		assert(renderer.scale == 3 && screen->w == 640 && screen->h == 480);
		assert(renderer.dst_x == 80 && renderer.dst_y == 24);
		run(160, 144, 10.0 / 9, SCALE_ASPECT, effect);
#if defined(GOV_PLATFORM_MIYOOMINI) || defined(GOV_PLATFORM_H700)
		assert(screen->w == 640 && screen->h == 480 && renderer.scale == -1);
		assert(renderer.dst_w == 533 && renderer.dst_h == 480);
		assert(renderer.dst_x == 53 && renderer.dst_y == 0);
		assert(renderer.blit != NULL);
		check_menu(160, 144);
		run(240, 160, 1.5, SCALE_ASPECT, effect);
		assert(renderer.dst_w == 640 && renderer.dst_h == 426 && renderer.dst_y == 27);
		check_menu(240, 160);
		run(256, 224, 4.0 / 3, SCALE_ASPECT, effect);
		assert(renderer.dst_w == 640 && renderer.dst_h == 480);
		check_menu(256, 224);
		run(160, 144, 10.0 / 9, SCALE_FULLSCREEN, effect);
		assert(renderer.dst_w == 640 && renderer.dst_h == 480 && renderer.scale == -1);
		check_menu(160, 144);
#else
		// tg5040 never opts into the new software path.
		assert(renderer.scale == 4 && screen->w == 768 && screen->h == 576);
#endif
		// Toggling off returns to the original oversized path; toggling back to Native
		// must restore its integer scaler rather than retain a stale fractional pointer.
		run(160, 144, 10.0 / 9, SCALE_ASPECT, EFFECT_NONE);
		assert(renderer.scale == 4 && screen->w == 768 && screen->h == 576);
		run(160, 144, 10.0 / 9, SCALE_NATIVE, effect);
		assert(renderer.scale == 3 && screen->w == 640 && screen->h == 480);
	}
	free(surface.pixels);
	puts("scaler integration: Native/Aspect/Fullscreen, toggles, menu + thumbnail passed");
	return 0;
}
