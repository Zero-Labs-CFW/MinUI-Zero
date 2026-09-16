// settings.elf: the main-menu Settings screen, drawn exactly like minarch's in-game Options
// (MENU_VAR: label left, value right, a description under the list; Dan, 2026-09-16, from the
// Frontend menu photo: "options list then Description copy under"). Dumb and generic on purpose:
// rows come from argv, changes go to stdout, the calling pak owns every file it touches.
//
//   settings.elf KEY LABEL VALUES CURRENT DESC [KEY LABEL VALUES CURRENT DESC ...]
//     VALUES  = "On|Off" style list. "" makes an ACTION row: A leaves with OPEN=KEY.
//     CURRENT = the value shown now (for an action row any display text, e.g. the time).
//     DESC    = shown under the list while the row is selected; "\n" (or a real newline) breaks.
//   Controls: Up/Down move (wrap), Left/Right or A change a value, A on an action row opens it,
//             B leaves.
//   Output:   one KEY=VALUE line per row whose value changed, then OPEN=KEY if an action row was
//             chosen. Exit 0 always; nothing printed means nothing changed.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <msettings.h>

#include "defines.h"
#include "api.h"
#include "utils.h"

#define MAX_ROWS 16
#define MAX_VALUES 8
#define OPTION_PADDING 8 // same as minarch's

typedef struct {
	char* key;
	char* name;
	char* desc;
	char* values[MAX_VALUES+1];
	int count; // 0 = action row
	int value;
	int initial;
	char* current; // action rows: the text shown on the right
} Row;

// the shell passes "\n" inside DESC; turn it into a real newline in place
static void unescape(char* s) {
	char* d = s;
	for (char* p = s; *p; p++) {
		if (p[0]=='\\' && p[1]=='n') { *d++ = '\n'; p++; }
		else *d++ = *p;
	}
	*d = 0;
}

int main(int argc, char* argv[]) {
	Row rows[MAX_ROWS];
	int count = 0;
	for (int i=1; i+4<argc && count<MAX_ROWS; i+=5) {
		Row* r = &rows[count];
		r->key = argv[i];
		r->name = argv[i+1];
		r->current = argv[i+3];
		r->desc = argv[i+4];
		unescape(r->desc);
		r->count = 0;
		r->value = 0;
		if (*argv[i+2]) {
			char* tok = strtok(argv[i+2], "|");
			while (tok && r->count<MAX_VALUES) { r->values[r->count++] = tok; tok = strtok(NULL, "|"); }
			r->values[r->count] = NULL;
			for (int j=0; j<r->count; j++) if (!strcmp(r->values[j], r->current)) r->value = j;
		}
		r->initial = r->value;
		count++;
	}
	if (!count) return EXIT_SUCCESS;

	PWR_setCPUSpeed(CPU_SPEED_MENU);

	SDL_Surface* screen = GFX_init(MODE_MAIN);
	PAD_init();
	PWR_init();
	InitSettings();

	// geometry copied from minarch's Menu_options (MENU_VAR) so the two screens match
	int max_visible = (screen->h - ((SCALE1(PADDING + PILL_SIZE) * 2) + SCALE1(BUTTON_SIZE))) / SCALE1(BUTTON_SIZE);
	int selected = 0;
	int start = 0;
	int end = MIN(count, max_visible);
	int visible_rows = end;

	// widest row: label in font.small plus the widest value in font.tiny
	int mw = 0;
	for (int i=0; i<count; i++) {
		Row* r = &rows[i];
		int lw = 0, rw = 0, w = 0;
		TTF_SizeUTF8(font.small, r->name, &lw, NULL);
		if (r->count) {
			for (int j=0; j<r->count; j++) {
				TTF_SizeUTF8(font.tiny, r->values[j], &rw, NULL);
				if (lw+rw>w) w = lw+rw;
			}
		}
		else {
			TTF_SizeUTF8(font.tiny, r->current, &rw, NULL);
			w = lw+rw;
		}
		w += SCALE1(OPTION_PADDING*4);
		if (w>mw) mw = w;
	}
	mw = MIN(mw, screen->w - SCALE1(PADDING*2));

	int open = -1;
	int quit = 0;
	int dirty = 1;
	int show_setting = 0;
	while (!quit) {
		GFX_startFrame();
		PAD_poll();

		if (PAD_justRepeated(BTN_UP)) {
			selected -= 1;
			if (selected<0) {
				selected = count - 1;
				start = MAX(0, count - max_visible);
				end = count;
			}
			else if (selected<start) {
				start -= 1;
				end -= 1;
			}
			dirty = 1;
		}
		else if (PAD_justRepeated(BTN_DOWN)) {
			selected += 1;
			if (selected>=count) {
				selected = 0;
				start = 0;
				end = visible_rows;
			}
			else if (selected>=end) {
				start += 1;
				end += 1;
			}
			dirty = 1;
		}
		else {
			Row* r = &rows[selected];
			if (r->count) {
				if (PAD_justRepeated(BTN_LEFT)) {
					r->value = r->value>0 ? r->value-1 : r->count-1;
					dirty = 1;
				}
				else if (PAD_justRepeated(BTN_RIGHT) || PAD_justPressed(BTN_A)) {
					r->value = (r->value+1) % r->count;
					dirty = 1;
				}
			}
			else if (PAD_justPressed(BTN_A)) {
				open = selected;
				quit = 1;
			}
		}
		if (PAD_justPressed(BTN_B)) quit = 1;

		PWR_update(&dirty, &show_setting, NULL, NULL);

		if (dirty) {
			GFX_clear(screen);
			GFX_blitHardwareGroup(screen, show_setting);

			char* desc = NULL;
			SDL_Surface* text;
			int ox = (screen->w - mw) / 2;
			int oy = SCALE1(PADDING + PILL_SIZE);
			int selected_row = selected - start;
			for (int i=start,j=0; i<end; i++,j++) {
				Row* r = &rows[i];
				SDL_Color text_color = COLOR_WHITE;

				if (j==selected_row) {
					// gray pill
					GFX_blitPill(ASSET_OPTION, screen, &(SDL_Rect){
						ox,
						oy+SCALE1(j*BUTTON_SIZE),
						mw,
						SCALE1(BUTTON_SIZE)
					});
					// white pill
					int w = 0;
					TTF_SizeUTF8(font.small, r->name, &w, NULL);
					w += SCALE1(OPTION_PADDING*2);
					GFX_blitPill(ASSET_BUTTON, screen, &(SDL_Rect){
						ox,
						oy+SCALE1(j*BUTTON_SIZE),
						w,
						SCALE1(BUTTON_SIZE)
					});
					text_color = COLOR_BLACK;
					if (r->desc && *r->desc) desc = r->desc;
				}
				text = TTF_RenderUTF8_Blended(font.small, r->name, text_color);
				SDL_BlitSurface(text, NULL, screen, &(SDL_Rect){
					ox+SCALE1(OPTION_PADDING),
					oy+SCALE1((j*BUTTON_SIZE)+1)
				});
				SDL_FreeSurface(text);

				char* val = r->count ? r->values[r->value] : r->current;
				if (val && *val) {
					text = TTF_RenderUTF8_Blended(font.tiny, val, COLOR_WHITE); // always white
					SDL_BlitSurface(text, NULL, screen, &(SDL_Rect){
						ox + mw - text->w - SCALE1(OPTION_PADDING),
						oy+SCALE1((j*BUTTON_SIZE)+3)
					});
					SDL_FreeSurface(text);
				}
			}

			if (count>max_visible) {
				#define SCROLL_WIDTH 24
				#define SCROLL_HEIGHT 4
				int sx = (screen->w - SCALE1(SCROLL_WIDTH))/2;
				int sy = SCALE1((PILL_SIZE - SCROLL_HEIGHT) / 2);
				if (start>0) GFX_blitAsset(ASSET_SCROLL_UP,   NULL, screen, &(SDL_Rect){sx, SCALE1(PADDING) + sy});
				if (end<count) GFX_blitAsset(ASSET_SCROLL_DOWN, NULL, screen, &(SDL_Rect){sx, screen->h - SCALE1(PADDING + PILL_SIZE + BUTTON_SIZE) + sy});
			}

			if (desc) {
				int w,h;
				GFX_sizeText(font.tiny, desc, SCALE1(12), &w,&h);
				GFX_blitText(font.tiny, desc, SCALE1(12), COLOR_WHITE, screen, &(SDL_Rect){
					(screen->w - w) / 2,
					screen->h - SCALE1(PADDING) - h,
					w,h
				});
			}

			GFX_flip(screen);
			dirty = 0;
		}
		else GFX_sync();
	}

	for (int i=0; i<count; i++) {
		Row* r = &rows[i];
		if (r->count && r->value!=r->initial) printf("%s=%s\n", r->key, r->values[r->value]);
	}
	if (open>=0) printf("OPEN=%s\n", rows[open].key);
	fflush(stdout);

	QuitSettings();
	PWR_quit();
	PAD_quit();
	GFX_quit();

	return EXIT_SUCCESS;
}
