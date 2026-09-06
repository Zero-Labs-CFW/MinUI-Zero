#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <SDL.h>
#include <SDL_ttf.h>

static int scale_num, scale_den, padding;
#define SCALE1(a) (((a)*scale_num + scale_den/2)/scale_den)
#define PADDING padding
#define HAS_SKINNY_SCREEN 0
#define BRIGHTNESS_BUTTON_LABEL "MENU"
#define MODE_MAIN 0
#define ASSET_DARK_GRAY_PILL 0
#define ASSET_BLACK_PILL 1
static struct { int mode; } gfx;
static struct { TTF_Font *small, *large, *tiny; } font;
static SDL_Rect pills[2];
static int pill_count;
static void GFX_blitPill(int a, SDL_Surface* s, SDL_Rect* r) {
	(void)a;
	assert(r->x>=0 && r->x+r->w<=s->w && r->y>=0 && r->y+r->h<=s->h);
	assert(pill_count<2);
	pills[pill_count++] = *r;
}
static void GFX_blitButton(char* h, char* b, SDL_Surface* s, SDL_Rect* r) {
	(void)h; (void)b; (void)s; (void)r;
}
#include "recent_layout.inc"

int main(int argc, char** argv) {
	assert(argc==2 && TTF_Init()==0);
	const int cases[][5] = {
		{640,480,2,1,10}, {720,560,2,1,5}, {1024,768,3,1,5},
		{1280,720,2,1,10}, {768,1024,5,2,7}
	};
	for (unsigned i=0; i<sizeof(cases)/sizeof(cases[0]); i++) {
		SDL_Surface surface = {0};
		surface.w = cases[i][0]; surface.h = cases[i][1];
		scale_num = cases[i][2]; scale_den = cases[i][3]; padding = cases[i][4];
		font.small = TTF_OpenFont(argv[1], SCALE1(FONT_SMALL));
		font.large = TTF_OpenFont(argv[1], SCALE1(FONT_LARGE));
		font.tiny = TTF_OpenFont(argv[1], SCALE1(FONT_TINY));
		assert(font.small && font.large && font.tiny);
		pill_count = 0;
		GFX_blitButtonGroup((char*[]){"Y","CLEAR","X","RESUME",NULL}, 0, &surface, 0);
		if (recentFooterCompact(surface.w))
			GFX_blitButtonGroup((char*[]){"A","OPEN",NULL}, 0, &surface, 1);
		else GFX_blitButtonGroup((char*[]){"B","BACK","A","OPEN",NULL}, 1, &surface, 1);
		assert(pills[0].x+pills[0].w+SCALE1(BUTTON_MARGIN)<=pills[1].x);
		char* messages[] = {"Clear Recently Played?", "Games and saves will stay.",
			"Couldn't clear history.", "Please check your SD card.", "No recently played games"};
		for (unsigned m=0; m<sizeof(messages)/sizeof(messages[0]); m++) {
			int width;
			assert(TTF_SizeUTF8(font.large, messages[m], &width, NULL)==0);
			assert(width<=surface.w-2*SCALE1(PADDING));
		}
		printf("recent footer: %dx%d, gap %dpx, confirmation text fits\n", surface.w, surface.h,
			pills[1].x-pills[0].x-pills[0].w);
		TTF_CloseFont(font.small); TTF_CloseFont(font.large); TTF_CloseFont(font.tiny);
	}
	TTF_Quit();
	return 0;
}
