// Relative cost of the Screen Effect scalers, host-side. NOT a device measurement: it answers
// "did the fused output path get more expensive than the integer path it replaced", which is the
// question Dan's MMP report raises (Zelda/NES, Aspect + effect: 45% CPU vs 25% without, choppy audio).
//
// Geometry is the real MMP case: NES 256x240 on a 640x480 panel at Aspect.
//   v1.7.5 fused path : source -> 640x480 directly, with seam interpolation + screen-pixel pattern
//   v1.7.4-equivalent : integer 3x prescale -> 768x720, pattern at source scale, MI_GFX does the rest
// The integer path writes MORE pixels (553k vs 307k) but does no interpolation, so which wins is a
// measurement, not an argument.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "scaler.h"

static double now_s(void) {
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

static double bench(const char* label, scaler_t fn, uint16_t* src, uint16_t* dst,
		uint32_t sw, uint32_t sh, uint32_t dw, uint32_t dh, int iters) {
	if (!fn) { printf("  %-34s unsupported\n", label); return 0; }
	fn(src, dst, sw, sh, sw * 2, dw, dh, dw * 2); // warm
	double t0 = now_s();
	for (int i = 0; i < iters; i++) fn(src, dst, sw, sh, sw * 2, dw, dh, dw * 2);
	double dt = now_s() - t0;
	double per = dt / iters * 1000.0;
	printf("  %-34s %7.3f ms/frame   %6.1f fps-equivalent   (%ux%u out)\n",
		label, per, 1000.0 / per, dw, dh);
	return per;
}


// OPTION UNDER TEST: let MI_GFX scale the game to the panel exactly as it did before (zero CPU), then
// apply ONLY the effect pattern to that output. No sampling, no interpolation, and it touches just the
// rows/columns that get dimmed instead of every pixel.
// local copy of the shipping effect_dim (it is static in scaler.c); identical arithmetic
static uint16_t bench_dim(uint16_t p, unsigned keep) {
	unsigned r = ((p >> 11) & 0x1f) * keep >> 8, g = ((p >> 5) & 0x3f) * keep >> 8, b = (p & 0x1f) * keep >> 8;
	return (uint16_t)((r << 11) | (g << 5) | b);
}

// LOW-RISK VARIANT: same single-pass structure that ships now, but sample NEAREST instead of
// interpolating at the seams. Keeps the screen-aligned pattern (the whole visual point) and the
// panel-sized output; drops only the blend math. Mirrors scale_effect_output otherwise.
static void fused_nearest(uint16_t* src, uint16_t* dst, uint32_t sw, uint32_t sh,
		uint32_t dw, uint32_t dh, uint32_t period, int grid, unsigned strength) {
	unsigned edge = 256 - (102 >> strength);
	unsigned corner = 256 - (154 >> strength);
	uint32_t xmap[4096];
	for (uint32_t x = 0; x < dw; x++) xmap[x] = x * sw / dw;
	for (uint32_t y = 0; y < dh; y++) {
		const uint16_t* a = src + (size_t)(y * sh / dh) * sw;
		uint16_t* d = dst + (size_t)y * dw;
		int line = (y % period == period - 1);
		uint32_t column = 0;
		for (uint32_t x = 0; x < dw; x++) {
			uint16_t p = a[xmap[x]];
			int vertical = grid && column == 0;
			if (line || vertical) p = bench_dim(p, line && vertical ? corner : edge);
			d[x] = p;
			if (++column == period) column = 0;
		}
	}
}

static void pattern_only(uint16_t* fb, uint32_t w, uint32_t h, uint32_t period, int grid, unsigned strength) {
	unsigned edge = 256 - (102 >> strength);
	unsigned corner = 256 - (154 >> strength);
	for (uint32_t y = 0; y < h; y++) {
		uint16_t* d = fb + (size_t)y * w;
		if (y % period == period - 1) {           // a scanline row: dim the whole row
			for (uint32_t x = 0; x < w; x++) {
				unsigned k = (grid && x % period == period - 1) ? corner : edge;
				d[x] = bench_dim(d[x], k);
			}
		} else if (grid) {                        // otherwise only the grid columns
			for (uint32_t x = period - 1; x < w; x += period) d[x] = bench_dim(d[x], edge);
		}
	}
}

int main(void) {
	enum { SW = 256, SH = 240 };          // NES
	enum { FW = 640, FH = 480 };          // panel, Aspect fills it for 4:3
	enum { IW = 768, IH = 720 };          // 3x integer prescale surface
	const int iters = 300;

	uint16_t* src = malloc(SW * SH * 2);
	uint16_t* dst = malloc((size_t)IW * IH * 2);   // big enough for both outputs
	if (!src || !dst) return 1;
	for (int i = 0; i < SW * SH; i++) src[i] = (uint16_t)(i * 2654435761u >> 16);

	printf("Screen Effect scaler cost — NES 256x240 on a 640x480 panel (Aspect)\n");
	printf("host build, -O2, no NEON; RELATIVE cost only\n\n");

	printf("v1.7.5 fused output path (what ships now):\n");
	double fused_line = bench("fit line (full)",   scaler_effect(-1, 0, 0), src, dst, SW, SH, FW, FH, iters);
	double fused_grid = bench("fit grid (full)",   scaler_effect(-1, 1, 0), src, dst, SW, SH, FW, FH, iters);
	bench("fit line 50%",                          scaler_effect(-1, 0, 1), src, dst, SW, SH, FW, FH, iters);

	printf("\nv1.7.4-equivalent integer path (3x prescale, hardware scales after):\n");
	double int_line = bench("3x line (full)",      scaler_effect(3, 0, 0), src, dst, SW, SH, IW, IH, iters);
	double int_grid = bench("3x grid (full)",      scaler_effect(3, 1, 0), src, dst, SW, SH, IW, IH, iters);

	printf("\npattern-only over a hardware-scaled 640x480 output:\n");
	double t1 = now_s();
	for (int i = 0; i < iters; i++) pattern_only(dst, FW, FH, 2, 0, 0);
	double pat_line = (now_s() - t1) / iters * 1000.0;
	printf("  %-34s %7.3f ms/frame\n", "line pattern only", pat_line);
	t1 = now_s();
	for (int i = 0; i < iters; i++) pattern_only(dst, FW, FH, 2, 1, 0);
	double pat_grid = (now_s() - t1) / iters * 1000.0;
	printf("  %-34s %7.3f ms/frame\n", "grid pattern only", pat_grid);

	printf("\nlow-risk variant: same fused pass, nearest sampling (no blends):\n");
	double t2 = now_s();
	for (int i = 0; i < iters; i++) fused_nearest(src, dst, SW, SH, FW, FH, 2, 0, 0);
	double nn_line = (now_s() - t2) / iters * 1000.0;
	printf("  %-34s %7.3f ms/frame\n", "fused nearest line", nn_line);
	t2 = now_s();
	for (int i = 0; i < iters; i++) fused_nearest(src, dst, SW, SH, FW, FH, 2, 1, 0);
	double nn_grid = (now_s() - t2) / iters * 1000.0;
	printf("  %-34s %7.3f ms/frame\n", "fused nearest grid", nn_grid);

	printf("\n== verdict ==\n");
	if (fused_line && nn_line) printf("  line: nearest is %.2fx cheaper than shipping fused\n", fused_line / nn_line);
	if (fused_grid && nn_grid) printf("  grid: nearest is %.2fx cheaper than shipping fused\n", fused_grid / nn_grid);
	if (fused_line && pat_line) printf("  line: pattern-only is %.2fx CHEAPER than fused\n", fused_line / pat_line);
	if (fused_grid && pat_grid) printf("  grid: pattern-only is %.2fx CHEAPER than fused\n", fused_grid / pat_grid);
	if (fused_line && int_line) printf("  line: fused is %.2fx the integer path\n", fused_line / int_line);
	if (fused_grid && int_grid) printf("  grid: fused is %.2fx the integer path\n", fused_grid / int_grid);
	free(src); free(dst);
	return 0;
}
