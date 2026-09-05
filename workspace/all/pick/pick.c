// pick.elf -- a D-pad multi-select checklist for the Device Sync "Customize" screen.
// confirm.elf is A/B/X only and say.elf is a message box, so neither can offer a real checklist;
// this fills that gap (and only that gap -- it stays a dumb, generic picker with no sync knowledge).
//
//   pick.elf "Title" KEY:LABEL:DEFAULT [KEY:LABEL:DEFAULT ...]
//     KEY     = machine token printed on stdout when that row is checked (no ':' or newline)
//     LABEL   = what the user sees
//     DEFAULT = 1 pre-checked, 0 unchecked
//
// Controls: Up/Down move (wrap), A toggles the row -- or, on the final "Start" row, confirms.
//           START confirms from anywhere; B cancels.
// Output:   on confirm, the KEY of every checked row, one per line, to stdout; exit 0.
//           on cancel, nothing; exit 1.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <msettings.h>

#include "defines.h"
#include "api.h"
#include "utils.h"

#define MAX_ITEMS 16

int main(int argc, char* argv[]) {
	char* title = argc > 1 ? argv[1] : "Choose";
	char* keys[MAX_ITEMS];
	char  labels[MAX_ITEMS][128];
	int   checked[MAX_ITEMS];
	int   n = 0;

	for (int i = 2; i < argc && n < MAX_ITEMS; i++) {
		// split KEY:LABEL:DEFAULT on the first two ':' (labels here never contain ':')
		char* s = argv[i];
		char* c1 = strchr(s, ':');
		if (!c1) continue;
		char* c2 = strchr(c1 + 1, ':');
		*c1 = 0;
		keys[n] = s;
		if (c2) { *c2 = 0; checked[n] = atoi(c2 + 1) ? 1 : 0; }
		else    { checked[n] = 0; }
		snprintf(labels[n], sizeof labels[n], "%s", c1 + 1);
		n++;
	}
	if (n == 0) return 1;

	int start_row = n;              // synthetic action row below the items
	int total     = n + 1;
	int selected  = 0;

	PWR_setCPUSpeed(CPU_SPEED_MENU);
	SDL_Surface* screen = GFX_init(MODE_MAIN);
	PAD_init();
	PWR_init();
	InitSettings();

	int quit = 0, rc = 1, dirty = 1;
	while (!quit) {
		PAD_poll();

		if (PAD_justRepeated(BTN_UP))   { selected = (selected - 1 + total) % total; dirty = 1; }
		if (PAD_justRepeated(BTN_DOWN)) { selected = (selected + 1) % total; dirty = 1; }
		if (PAD_justPressed(BTN_A)) {
			if (selected == start_row) { rc = 0; quit = 1; }
			else { checked[selected] = !checked[selected]; dirty = 1; }
		}
		if (PAD_justPressed(BTN_START)) { rc = 0; quit = 1; }
		if (PAD_justPressed(BTN_B))     { rc = 1; quit = 1; }

		if (dirty && !quit) {
			GFX_clear(screen);

			// title
			int y = SCALE1(PADDING);
			SDL_Surface* t = TTF_RenderUTF8_Blended(font.large, title, COLOR_WHITE);
			if (t) {
				SDL_BlitSurface(t, NULL, screen, &(SDL_Rect){ SCALE1(PADDING + BUTTON_PADDING), y });
				y += t->h + SCALE1(PADDING);
				SDL_FreeSurface(t);
			}

			// rows: items then the Start action
			for (int j = 0; j < total; j++) {
				char disp[160];
				if (j == start_row) snprintf(disp, sizeof disp, "Start sync");
				else snprintf(disp, sizeof disp, "%s %s", checked[j] ? "[x]" : "[ ]", labels[j]);

				int row_y = y + j * SCALE1(ROW_PITCH);
				SDL_Color text_color = COLOR_WHITE;
				if (j == selected) {
					char trunc[160];
					int tw = GFX_truncateText(font.large, disp, trunc, screen->w - SCALE1(PADDING * 2), SCALE1(BUTTON_PADDING * 2));
					GFX_blitPill(ASSET_WHITE_PILL, screen, &(SDL_Rect){
						SCALE1(PADDING), row_y, tw, SCALE1(PILL_SIZE) });
					text_color = COLOR_BLACK;
				}
				SDL_Surface* rt = TTF_RenderUTF8_Blended(font.large, disp, text_color);
				if (rt) {
					SDL_BlitSurface(rt, NULL, screen, &(SDL_Rect){
						SCALE1(PADDING + BUTTON_PADDING), row_y + SCALE1(4) });
					SDL_FreeSurface(rt);
				}
			}

			// footer: B back (left), A action (right) -- label reflects the current row
			GFX_blitButtonGroup((char*[]){ "B", "BACK", NULL }, 0, screen, 0);
			if (selected == start_row)
				GFX_blitButtonGroup((char*[]){ "A", "START", NULL }, 0, screen, 1);
			else
				GFX_blitButtonGroup((char*[]){ "A", "TOGGLE", NULL }, 0, screen, 1);

			GFX_flip(screen);
			dirty = 0;
		}
		else if (!quit) GFX_sync();
	}

	if (rc == 0) {
		for (int i = 0; i < n; i++) if (checked[i]) printf("%s\n", keys[i]);
		fflush(stdout);
	}

	QuitSettings();
	PWR_quit();
	PAD_quit();
	GFX_quit();
	return rc;
}
