#include <assert.h>
#include <stdio.h>
#define FIXED_WIDTH 640
#define FIXED_HEIGHT 480
struct disp_rect { int x, y; unsigned width, height; };
static struct {
	struct { unsigned xres, yres; } vinfo;
	int width, height, game_x, game_y, game_w, game_h;
} vid;
#include "h700-geometry.inc"
int main(void) {
	struct disp_rect window;
	vid.vinfo.xres = 640; vid.vinfo.yres = 480;
	disp_screen_win(FIXED_WIDTH, FIXED_HEIGHT, &window);
	assert(window.x == 0 && window.y == 0 && window.width == 640 && window.height == 480);
	// SNES' intermediate 8:7 buffer is stretched into the canonical 4:3 canvas.
	vid.width = 768; vid.height = 672;
	vid.game_x = vid.game_y = 0; vid.game_w = 768; vid.game_h = 672;
	int x, y, w, h;
	PLAT_getGameRect(&x, &y, &w, &h);
	assert(x == 0 && y == 0 && w == 640 && h == 480);
	// Native GB and output-size Aspect both report their actual visible rect.
	vid.width = 640; vid.height = 480;
	vid.game_x = 80; vid.game_y = 24; vid.game_w = 480; vid.game_h = 432;
	PLAT_getGameRect(&x, &y, &w, &h);
	assert(x == 80 && y == 24 && w == 480 && h == 432);
	vid.game_x = 53; vid.game_y = 0; vid.game_w = 533; vid.game_h = 480;
	PLAT_getGameRect(&x, &y, &w, &h);
	assert(x == 53 && y == 0 && w == 533 && h == 480);
	puts("h700 canvas + HUD geometry passed");
	return 0;
}
