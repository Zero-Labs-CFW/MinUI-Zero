#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "scaler.h"

static unsigned cases;
static const uint16_t guard = 0xf81f;

static uint16_t dim(uint16_t p, unsigned keep) {
	return (((((p >> 11) & 31) * keep) >> 8) << 11) |
	       (((((p >> 5) & 63) * keep) >> 8) << 5) |
	       (((p & 31) * keep) >> 8);
}

static void line1_bounds(void) {
	for (unsigned strength = 0; strength < 3; strength++) {
		for (unsigned h = 1; h <= 7; h++) {
			for (unsigned pad = 0; pad <= 3; pad++) {
				unsigned w = 5, stride = w + pad;
				uint16_t* src = malloc(stride * h * 2);
				uint16_t* dst = malloc(stride * h * 2);
				assert(src && dst);
				for (unsigned i = 0; i < stride * h; i++) {
					src[i] = (uint16_t)(0xffff - i * 101);
					dst[i] = guard;
				}
				scaler_effect(1, 0, strength)(src, dst, w, h, stride * 2, w, h, stride * 2);
				for (unsigned y = 0; y < h; y++) {
					for (unsigned x = 0; x < stride; x++) {
						uint16_t expected = x >= w ? guard : src[y * stride + x];
						if (x < w && (y & 1)) expected = dim(expected, 256 - (64 >> strength));
						assert(dst[y * stride + x] == expected);
					}
				}
				memset(dst, 0, stride * h * 2);
				scaler_effect(1, 0, strength)(src, dst, w, h, stride * 2, 2, 1, stride * 2);
				assert(dst[0] == src[0] && dst[1] == src[1]);
				for (unsigned i = 2; i < stride * h; i++) assert(dst[i] == 0);
				free(src); free(dst); cases++;
			}
		}
	}
}

static void supported_scales(void) {
	assert(!scaler_effect(1, 1, 0));
	assert(!scaler_effect(7, 0, 0));
	assert(!scaler_effect(-2, 0, 0));
	assert(!scaler_effect(2, 0, 3));
	assert(scaler_effect(0, 0, 0) == scale1x_line);
	assert(scaler_effect(3, 1, 0) == scale3x_grid);
	assert(scaler_effect(4, 0, 0) == scale4x_line);
	for (unsigned scale = 2; scale <= 6; scale++) {
		for (unsigned grid = 0; grid < 2; grid++) {
			uint64_t last_sum = 0;
			for (unsigned strength = 0; strength < 3; strength++) {
				unsigned w = 5 * scale, h = 3 * scale, stride = w + 2;
				uint16_t src[5 * 3];
				uint16_t* dst = malloc(stride * h * 2);
				assert(dst);
				for (unsigned i = 0; i < 15; i++) src[i] = 0xffff;
				for (unsigned i = 0; i < stride * h; i++) dst[i] = guard;
				scaler_t fn = scaler_effect(scale, grid, strength);
				assert(fn);
				fn(src, dst, 5, 3, 10, w, h, stride * 2);
				uint64_t sum = 0;
				unsigned dark = 0;
				for (unsigned y = 0; y < h; y++) for (unsigned x = 0; x < stride; x++) {
					uint16_t p = dst[y * stride + x];
					if (x >= w) assert(p == guard);
					else { assert(p != guard); sum += p; dark += p != 0xffff; }
				}
				assert(dark && dark < w * h);
				assert(sum > last_sum); last_sum = sum;
				free(dst); cases++;
			}
		}
	}
}

static void fractional_pattern(unsigned sw, unsigned sh, unsigned w, unsigned h) {
	unsigned sp = sw + 3, dp = w + 5;
	uint16_t* src = malloc(sp * sh * 2);
	uint16_t* dst = malloc(dp * h * 2);
	assert(src && dst);
	for (unsigned i = 0; i < sp * sh; i++) src[i] = 0xffff;
	unsigned px = (w + sw - 1) / sw, py = (h + sh - 1) / sh;
	unsigned period = px < py ? px : py;
	if (period < 2) period = 2;
	for (unsigned grid = 0; grid < 2; grid++) for (unsigned strength = 0; strength < 3; strength++) {
		for (unsigned i = 0; i < dp * h; i++) dst[i] = guard;
		scaler_effect(-1, grid, strength)(src, dst, sw, sh, sp * 2, w, h, dp * 2);
		for (unsigned y = 0; y < h; y++) for (unsigned x = 0; x < dp; x++) {
			uint16_t expected = guard;
			if (x < w) {
				int line = y % period == period - 1, column = grid && x % period == 0;
				unsigned amount = line && column ? 154 : (line || column ? 102 : 0);
				expected = dim(0xffff, 256 - (amount >> strength));
			}
			if (dst[y * dp + x] != expected) fprintf(stderr,
				"%ux%u -> %ux%u grid=%u strength=%u at %u,%u: %04x != %04x\n",
				sw, sh, w, h, grid, strength, x, y, dst[y * dp + x], expected);
			assert(dst[y * dp + x] == expected);
		}
		cases++;
	}
	free(src); free(dst);
}

static void colored_edges(void) {
	uint16_t src[2] = {0xf800, 0x001f};
	uint16_t dst[13 * 3];
	scaler_effect(-1, 0, 0)(src, dst, 2, 1, 4, 13, 3, 26);
	assert(dst[0] == 0xf800 && dst[12] == 0x001f);
	for (unsigned i = 0; i < 13 * 3; i++) assert(!(dst[i] & 0x07e0));
	assert(dst[6] != src[0] && dst[6] != src[1]); // interpolation survives; not raw nearest
	uint16_t exact[1] = {0xffff};
	scaler_effect(-1, 1, 0)(exact, exact, 0, 1, 2, 1, 1, 2); // zero width rejects before access
	assert(exact[0] == 0xffff);
	cases++;
}

static void invalid_inputs(void) {
	uint16_t src[4] = {1, 2, 3, 4}, dst[4] = {9, 9, 9, 9};
	scaler_t fn = scaler_effect(-1, 1, 0);
	fn(src, dst, 2, 2, 2, 2, 2, 4); // short input pitch
	fn(src, dst, 2, 2, 4, 2, 2, 2); // short output pitch
	fn(src, dst, 2, 2, 5, 2, 2, 4); // unaligned pitch
	fn(src, dst, 2, 2, 4, 4097, 2, 4);
	fn(NULL, dst, 2, 2, 4, 2, 2, 4);
	fn(src, dst, 2, 0, 4, 2, 2, 4);
	for (unsigned i = 0; i < 4; i++) assert(dst[i] == 9);
	cases++;
}

int main(void) {
	line1_bounds(); supported_scales(); colored_edges(); invalid_inputs();
	fractional_pattern(160, 144, 533, 480); // GB/GBC Aspect
	fractional_pattern(160, 144, 640, 480); // Fullscreen, unequal axes
	fractional_pattern(240, 160, 640, 426); // GBA Aspect
	fractional_pattern(256, 224, 640, 480); // SNES non-square pixels
	fractional_pattern(320, 239, 640, 478); // odd source height
	fractional_pattern(512, 480, 640, 480); // PS1 high resolution
	fractional_pattern(1, 1, 3, 5);
	fractional_pattern(11, 9, 5, 4); // reduction
	printf("scaler effects: %u cases passed\n", cases);
	return 0;
}
