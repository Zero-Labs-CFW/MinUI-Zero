// settings.elf: the main-menu Settings screen, drawn exactly like minarch's in-game Options
// (MENU_VAR: label left, value right, a description under the list; Dan, 2026-09-16, from the
// Frontend menu photo: "options list then Description copy under"). Dumb and generic on purpose:
// rows come from argv, changes go to stdout, the calling pak owns every file it touches.
//
//   settings.elf [--title TEXT] KEY LABEL VALUES CURRENT DESC [KEY LABEL VALUES CURRENT DESC ...]
//     --title = a heading at the top left (the folder name, the way the launcher shows one)
//     VALUES  = "On|Off" style list. "" makes an ACTION row: A leaves with OPEN=KEY.
//     KEY     = the name printed back. Two optional prefixes/suffixes, in this order:
//               '@' prefix  = value row that is ALSO an action: Left/Right cycle, A leaves with
//                             OPEN=KEY (the picker a value like "Picked" refers to).
//               '?dep=a,b'  = a SHOW CONDITION: this row is only listed while the row whose key is
//                             `dep` currently reads one of the comma-separated values a,b. It appears
//                             and disappears live as that other row is toggled (Dan, 2026-09-17:
//                             "Which games shows up after games is on"). The '@' and '?...' are both
//                             stripped from the printed key.
//     CURRENT = the value shown now (for an action row any display text, e.g. the time).
//     DESC    = shown under the list while the row is selected; "\n" (or a real newline) breaks.
//   Controls: Up/Down move (wrap), L1/R1 page, Left/Right or A change a value, A on an action row
//             opens it, B leaves.
//   Output:   one KEY=VALUE line per row whose value changed (and is still shown), then OPEN=KEY if
//             an action row was chosen. Exit 0 always; nothing printed means nothing changed.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <msettings.h>

#include "defines.h"
#include "api.h"
#include "utils.h"

#define MAX_ROWS 1024 // game lists (Device Sync) run to hundreds of rows
#define MAX_VALUES 8
#define OPTION_PADDING 8 // same as minarch's

typedef struct {
	char* key;   // printed key: after the '@' and before the '?'
	char* name;
	char* desc;
	char* values[MAX_VALUES+1];
	int count; // 0 = action row
	int value;
	int initial;
	char* current; // action rows: the text shown on the right
	int is_open;   // '@': a value row that also opens (A -> OPEN=key)
	char* dep_key; // '?dep=...': show only while row `dep_key` reads one of dep_vals; NULL = always
	char* dep_vals;// comma-separated allowed values for dep_key
} Row;

static Row rows[MAX_ROWS];
static int count = 0;

// the shell passes "\n" inside DESC; turn it into a real newline in place
static void unescape(char* s) {
	char* d = s;
	for (char* p = s; *p; p++) {
		if (p[0]=='\\' && p[1]=='n') { *d++ = '\n'; p++; }
		else *d++ = *p;
	}
	*d = 0;
}

// the value a row currently reads as text (value rows: the selected value; action rows: their current)
static char* row_value_text(Row* r) {
	return r->count ? r->values[r->value] : r->current;
}

// is `val` one of the comma-separated names in `list`?
static int in_csv(const char* list, const char* val) {
	if (!list || !val) return 0;
	size_t vl = strlen(val);
	const char* p = list;
	while (*p) {
		const char* c = strchr(p, ',');
		size_t n = c ? (size_t)(c - p) : strlen(p);
		if (n==vl && !strncmp(p, val, vl)) return 1;
		if (!c) break;
		p = c + 1;
	}
	return 0;
}

// a row is shown unless its dependency row is present and not reading an allowed value
static int row_shown(int i) {
	Row* r = &rows[i];
	if (!r->dep_key) return 1;
	for (int j=0; j<count; j++) {
		if (!strcmp(rows[j].key, r->dep_key)) return in_csv(r->dep_vals, row_value_text(&rows[j]));
	}
	return 1; // no such row: treat as unconditional rather than vanish
}

int main(int argc, char* argv[]) {
	char* title = NULL;
	char* x_label = NULL;   // opt-in bottom-right actions; when set, that button exits with ACTION=x/y
	char* y_label = NULL;
	char* a_label = NULL;   // opt-in: A on ANY row exits with ACTION=a (a confirm list, not an editor)
	int wide = 0;
	int first = 1;
	while (first < argc) {
		if (!strcmp(argv[first], "--wide")) { wide = 1; first += 1; }
		else if (first+1 < argc && !strcmp(argv[first], "--title"))   { title = argv[first+1]; first += 2; }
		else if (first+1 < argc && !strcmp(argv[first], "--x-label")) { x_label = argv[first+1]; first += 2; }
		else if (first+1 < argc && !strcmp(argv[first], "--y-label")) { y_label = argv[first+1]; first += 2; }
		else if (first+1 < argc && !strcmp(argv[first], "--a-label")) { a_label = argv[first+1]; first += 2; }
		else break;
	}
	for (int i=first; i+4<argc && count<MAX_ROWS; i+=5) {
		Row* r = &rows[count];
		r->key = argv[i];
		r->name = argv[i+1];
		r->current = argv[i+3];
		r->desc = argv[i+4];
		unescape(r->desc);
		r->count = 0;
		r->value = 0;
		r->is_open = 0;
		r->dep_key = NULL;
		r->dep_vals = NULL;
		// key = ['@'] name ['?' dep '=' vals]
		if (r->key[0]=='@') { r->is_open = 1; r->key++; }
		char* q = strchr(r->key, '?');
		if (q) {
			*q = 0;
			r->dep_key = q + 1;
			char* eq = strchr(r->dep_key, '=');
			if (eq) { *eq = 0; r->dep_vals = eq + 1; }
		}
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
	int selected = 0; // index into the currently-visible list
	int start = 0;

	// widest row: label in font.small plus the widest value in font.tiny (over all rows, so the
	// column does not jump as conditional rows appear)
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
		// OPTION_PADDING*4 is the pill padding; the extra 24 is breathing room between label and value,
		// which on the Smart Pro (@2x) otherwise touch (Dan, 2026-09-22)
		w += SCALE1(OPTION_PADDING*4 + 24);
		if (w>mw) mw = w;
	}
	// never narrower than two fifths of the panel: a two-row list of short words was a cramped island
	if (mw < screen->w * 2 / 5) mw = screen->w * 2 / 5;
	mw = MIN(mw, screen->w - SCALE1(PADDING*2));
	// An ACTION list (Device Sync's entry) is short labels with no values at all, so the widest-row
	// rule shrank the whole menu to one floating word and it read as a broken option instead of a
	// button (Dan, 2026-09-18). --wide pins the rows to the full content width, like the Tools list.
	if (wide) mw = screen->w - SCALE1(PADDING*2);

	int open = -1; // full-rows index of the chosen action row
	char* cursor_key = NULL; // the highlighted row when an X/Y action exits (vis/nvis live inside the loop)
	char action = 0; // 'x' or 'y' when a bottom-bar action button exits the screen
	int quit = 0;
	int dirty = 1;
	int show_setting = 0;
	while (!quit) {
		GFX_startFrame();
		PAD_poll();

		// rebuild the visible list every frame: a toggle on one row can show/hide another
		int vis[MAX_ROWS], nvis = 0;
		for (int i=0; i<count; i++) if (row_shown(i)) vis[nvis++] = i;
		if (nvis==0) { // degenerate (everything conditional-hidden): only B works
			if (PAD_justPressed(BTN_B)) quit = 1;
			PWR_update(&dirty, &show_setting, NULL, NULL);
			GFX_sync();
			continue;
		}
		if (selected>=nvis) selected = nvis-1;
		if (selected<0) selected = 0;

		if (PAD_justRepeated(BTN_UP)) {
			selected = selected>0 ? selected-1 : nvis-1;
			dirty = 1;
		}
		else if (PAD_justRepeated(BTN_DOWN)) {
			selected = selected<nvis-1 ? selected+1 : 0;
			dirty = 1;
		}
		else if (PAD_justRepeated(BTN_L1) || PAD_justRepeated(BTN_R1)) {
			// page jump for long lists
			if (PAD_justRepeated(BTN_L1)) selected -= max_visible; else selected += max_visible;
			if (selected<0) selected = 0;
			if (selected>=nvis) selected = nvis - 1;
			dirty = 1;
		}
		else {
			Row* r = &rows[vis[selected]];
			if (r->count) {
				if (PAD_justRepeated(BTN_LEFT)) {
					r->value = r->value>0 ? r->value-1 : r->count-1;
					dirty = 1;
				}
				else if (PAD_justPressed(BTN_A) && r->is_open) {
					open = vis[selected];
					quit = 1;
				}
				else if (PAD_justRepeated(BTN_RIGHT) || PAD_justPressed(BTN_A)) {
					r->value = (r->value+1) % r->count;
					dirty = 1;
				}
			}
			else if (PAD_justPressed(BTN_A)) {
				open = vis[selected];
				quit = 1;
			}
		}
		// B wins over an action pressed in the same frame (Back is never overridden), and X over Y
		if (PAD_justPressed(BTN_B)) quit = 1;
		else if (a_label && PAD_justPressed(BTN_A)) { action = 'a'; quit = 1; }
		else if (x_label && PAD_justPressed(BTN_X)) { action = 'x'; quit = 1; }
		else if (y_label && PAD_justPressed(BTN_Y)) { action = 'y'; quit = 1; }
		if (action && nvis>0 && selected>=0 && selected<nvis) cursor_key = rows[vis[selected]].key;

		PWR_update(&dirty, &show_setting, NULL, NULL);

		if (dirty) {
			// a value change this frame may have shown or hidden a conditional row (?dep=): rebuild
			// the visible list BEFORE drawing, so the new row appears in the same frame the toggle
			// set dirty. Rebuilding only at the top of the loop would draw the stale list and then
			// clear dirty, leaving the row missing until the next input (Codex, 2026-09-17).
			nvis = 0;
			for (int i=0; i<count; i++) if (row_shown(i)) vis[nvis++] = i;
			if (nvis>0) { if (selected>=nvis) selected = nvis-1; if (selected<0) selected = 0; }

			// window the visible list around the selection
			if (selected < start) start = selected;
			if (selected >= start + max_visible) start = selected - max_visible + 1;
			if (start > nvis - max_visible) start = nvis - max_visible;
			if (start < 0) start = 0;
			int end = MIN(nvis, start + max_visible);

			GFX_clear(screen);
			GFX_blitHardwareGroup(screen, show_setting);
			if (title) {
				SDL_Surface* t = TTF_RenderUTF8_Blended(font.small, title, COLOR_WHITE);
				SDL_BlitSurface(t, NULL, screen, &(SDL_Rect){SCALE1(PADDING + OPTION_PADDING), SCALE1(PADDING + 4)});
				SDL_FreeSurface(t);
			}

			char* desc = NULL;
			SDL_Surface* text;
			int ox = (screen->w - mw) / 2;
			int oy = SCALE1(PADDING + PILL_SIZE);
			int selected_row = selected - start;
			for (int i=start,j=0; i<end; i++,j++) {
				Row* r = &rows[vis[i]];
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

			if (nvis>max_visible) {
				#define SCROLL_WIDTH 24
				#define SCROLL_HEIGHT 4
				int sx = (screen->w - SCALE1(SCROLL_WIDTH))/2;
				int sy = SCALE1((PILL_SIZE - SCROLL_HEIGHT) / 2);
				if (start>0) GFX_blitAsset(ASSET_SCROLL_UP,   NULL, screen, &(SDL_Rect){sx, SCALE1(PADDING) + sy});
				if (end<nvis) GFX_blitAsset(ASSET_SCROLL_DOWN, NULL, screen, &(SDL_Rect){sx, screen->h - SCALE1(PADDING + PILL_SIZE + BUTTON_SIZE) + sy});
			}

			if (x_label || y_label || a_label) {
				// bottom bar: B Back on the left, the actions on the right, exactly like confirm.elf
				GFX_blitButtonGroup((char*[]){ "B", "Back", NULL }, 0, screen, 0);
				if (a_label)                 GFX_blitButtonGroup((char*[]){ "A", a_label, NULL }, 0, screen, 1);
				else if (x_label && y_label) GFX_blitButtonGroup((char*[]){ "Y", y_label, "X", x_label, NULL }, 0, screen, 1);
				else if (x_label)       GFX_blitButtonGroup((char*[]){ "X", x_label, NULL }, 0, screen, 1);
				else                    GFX_blitButtonGroup((char*[]){ "Y", y_label, NULL }, 0, screen, 1);
			}
			else if (desc) {
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
		if (r->count && r->value!=r->initial && row_shown(i)) printf("%s=%s\n", r->key, r->values[r->value]);
	}
	if (open>=0) printf("OPEN=%s\n", rows[open].key);
	if (action) printf("ACTION=%c\n", action);
	// the highlighted row goes with an action, so X can mean "this one" (Backups: X deletes the
	// highlighted backup, Y deletes all; Dan 2026-09-22)
	if (action && cursor_key) printf("CURSOR=%s\n", cursor_key);
	fflush(stdout);

	QuitSettings();
	PWR_quit();
	PAD_quit();
	GFX_quit();

	return EXIT_SUCCESS;
}
