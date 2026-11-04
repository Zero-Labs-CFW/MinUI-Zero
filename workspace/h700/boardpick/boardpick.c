// boardpick: first-boot model picker for the one H700 image (tools/h700-strip/boardpick.sh drives it).
// The card boots one screen type at a time. Any screen that can be read lists EVERY model, so nobody hunts for
// theirs through other boards' screen setups (an H read the SP's screen fine, Dan 2026-11-03).
//   boardpick [-b] [-s <n>] <timeout_s> <id> <label> [<id> <label> ...]
//     Hold START 2 s on a model, then hold START 2 s again on "Set up as <model>?" (B goes back to the list; Dan
//     2026-11-03): prints its id, exit 0. No input before the countdown ends: exit 2 (try the next
//     screen type: a dark screen moves on by itself). With -b, hold B 2 s: exit 3 (back to the previous screen
//     type, the way back from a garbled one). -s <n> starts on model n.
//   boardpick -c <timeout_s> <label>: after a model is installed, ask whether the screen is right. Hold START 2 s:
//     exit 0 (keep it). Hold B 2 s or no input: exit 2 (the shell puts the last screen type back), so a wrong
//     pick that garbles the screen undoes itself.
//   boardpick -m <title> <line>: show a message until killed (the shell runs it while it installs and reboots,
//     which otherwise happens on a black screen; Dan 2026-11-02)
// A HOLD, never a press: mashing A through first boot must not pick a model. A hold counts only from a press on the
// screen it is on, so the hold that picked a model does not run on into the next screen.
// Every button press restarts the countdown at three minutes, so someone reading the list is never cut off (the
// H moved on unseen after 30 s, Dan 2026-11-03); a dark screen gets no input and moves on by itself, and one
// mashed in the dark still moves on three minutes after the last press.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <msettings.h>

#include "defines.h"
#include "api.h"
#include "utils.h"

#define HOLD_MS 2000
#define TOUCHED_MS 180000 // the countdown after any press
#define MAX_MODELS 16

// The 720x480 screen setups (34XX) also reach the 640x480 panels while the card steps through screen types, and
// those panels show only the left 640 pixels (an H cut the right-hand hint, Dan 2026-11-03). Draw them in a
// 640-wide canvas so every board that can read the screen sees all of it.
static int canvas_w(SDL_Surface* screen) { return screen->w > 640 && screen->h <= 480 ? 640 : screen->w; }
static SDL_Surface* canvas_for(SDL_Surface* screen) {
	if (canvas_w(screen) == screen->w) return screen;
	return SDL_CreateRGBSurface(SDL_SWSURFACE, canvas_w(screen), screen->h, FIXED_DEPTH, RGBA_MASK_565);
}

static int message(char* title, char* line) {
	SDL_Surface* screen = GFX_init(MODE_MAIN);
	GFX_clear(screen);
	int cw = canvas_w(screen);
	// both lines centered on the screen as one block (GFX_blitText centers across the rect's width)
	int title_h = TTF_FontHeight(font.large), line_h = TTF_FontHeight(font.small), gap = SCALE1(8);
	int y = (screen->h - (title_h + gap + line_h)) / 2;
	GFX_blitText(font.large, title, 0, COLOR_WHITE, screen, &(SDL_Rect){0, y, cw, title_h});
	GFX_blitText(font.small, line, 0, COLOR_GRAY, screen, &(SDL_Rect){0, y + title_h + gap, cw, line_h});
	GFX_flip(screen);
	for (;;) sleep(60); // the reboot (or the shell's kill) ends it
	return 0;
}

int main(int argc, char* argv[]) {
	if (argc == 4 && !strcmp(argv[1], "-m")) { dup2(2, 1); return message(argv[2], argv[3]); }
	int confirm = argc == 4 && !strcmp(argv[1], "-c");
	int back = 0, selected = 0;
	if (confirm) { argc--; argv++; }
	else {
		for (;;) {
			if (argc > 1 && !strcmp(argv[1], "-b")) { back = 1; argc--; argv++; }
			else if (argc > 2 && !strcmp(argv[1], "-s")) { selected = atoi(argv[2]); argc -= 2; argv += 2; }
			else break;
		}
		if (argc < 4 || (argc - 2) % 2) {
			fprintf(stderr, "usage: boardpick [-b] [-s <n>] <timeout_s> <id> <label> [<id> <label> ...]\n"
				"       boardpick -c <timeout_s> <label>\n       boardpick -m <title> <line>\n");
			return 1;
		}
	}
	// stdout carries the answer alone: the shell reads it with $(...). The shared API logs [INFO] lines to
	// stdout (GFX_init, input setup), which would be read as part of the board id, so send them to stderr.
	int answer = dup(1);
	dup2(2, 1);
	uint32_t timeout_ms = atoi(argv[1]) * 1000;
	int count = confirm ? 1 : (argc - 2) / 2;
	if (count > MAX_MODELS) count = MAX_MODELS;
	char** ids = calloc(count, sizeof(char*));
	char** labels = calloc(count, sizeof(char*));
	if (confirm) labels[0] = argv[2];
	else for (int i = 0; i < count; i++) { ids[i] = argv[2 + i*2]; labels[i] = argv[3 + i*2]; }
	if (selected < 0 || selected >= count) selected = 0;

	PWR_setCPUSpeed(CPU_SPEED_MENU);
	SDL_Surface* screen = GFX_init(MODE_MAIN);
	SDL_Surface* canvas = canvas_for(screen);
	PAD_init();
	PWR_init();
	InitSettings();

	// the list runs the full height, under the button hint, and scrolls past the rows that fit whole; a row cut
	// off at the bottom shows there is more (Dan 2026-11-03)
	int list_y = SCALE1(PADDING + PILL_SIZE + 8);
	int rows = (canvas->h - list_y) / SCALE1(PILL_SIZE);
	if (rows < 1) rows = 1;
	int first = 0; // the top row shown

	int result = 2, quit = 0, dirty = 1, shown_s = -1;
	int asking = 0; // on "Set up as <model>?" after a model was picked from the list
	uint32_t deadline = SDL_GetTicks() + timeout_ms;
	uint32_t start_at = 0, b_at = 0; // when the hold began, 0 = not held
	while (!quit) {
		PAD_poll();
		uint32_t now = SDL_GetTicks();
		if (PAD_anyJustPressed()) {
			deadline = now + TOUCHED_MS;
			dirty = 1;
		}
		if (!confirm && !asking) {
			if (PAD_justRepeated(BTN_UP)) { selected = (selected + count - 1) % count; dirty = 1; }
			else if (PAD_justRepeated(BTN_DOWN)) { selected = (selected + 1) % count; dirty = 1; }
		}
		if (asking && PAD_justPressed(BTN_B)) { asking = 0; start_at = b_at = 0; dirty = 1; continue; } // back to the list

		if (PAD_justPressed(BTN_START)) start_at = now;
		else if (!PAD_isPressed(BTN_START)) start_at = 0;
		if ((back || confirm) && !asking && PAD_justPressed(BTN_B)) b_at = now;
		else if (!PAD_isPressed(BTN_B)) b_at = 0;

		if (start_at && now - start_at >= HOLD_MS) {
			if (confirm || asking) { result = 0; quit = 1; }
			else { asking = 1; start_at = b_at = 0; dirty = 1; continue; } // a model picked: ask before installing
		}
		else if (b_at && now - b_at >= HOLD_MS) { result = confirm ? 2 : 3; quit = 1; }
		else if ((int32_t)(deadline - now) <= 0) {
			// someone picked a model on this screen, so it can be read: left on "Set up as" it goes back to the
			// list for another countdown rather than on to the next screen type
			if (asking) { asking = 0; deadline = now + TOUCHED_MS; dirty = 1; continue; }
			result = 2; quit = 1;
		}

		int left_s = ((int32_t)(deadline - now) + 999) / 1000;
		if (left_s != shown_s || start_at || b_at) dirty = 1;
		if (dirty && !quit) {
			shown_s = left_s;
			GFX_clear(screen);
			if (canvas != screen) SDL_FillRect(canvas, NULL, 0);
			char line[128];
			GFX_blitText(font.large, confirm ? "Does the screen look right?" : asking ? "Set up this handheld?" : "Which handheld is this?",
				0, COLOR_WHITE, canvas, &(SDL_Rect){SCALE1(PADDING+BUTTON_PADDING), SCALE1(PADDING), canvas->w - SCALE1(PADDING*2), SCALE1(PILL_SIZE)});
			int y = list_y;
			if (confirm || asking) {
				snprintf(line, sizeof line, "Set up as %s", labels[asking ? selected : 0]);
				GFX_blitText(font.large, line, 0, COLOR_WHITE, canvas,
					&(SDL_Rect){SCALE1(PADDING+BUTTON_PADDING), y + SCALE1(4), canvas->w - SCALE1(PADDING*2), SCALE1(PILL_SIZE)});
				y += SCALE1(PILL_SIZE);
			}
			else {
				if (selected < first) first = selected;
				if (selected >= first + rows) first = selected - rows + 1;
				for (int i = first; i < count && i <= first + rows; i++, y += SCALE1(PILL_SIZE)) {
					SDL_Color color = COLOR_WHITE;
					int w, h;
					GFX_sizeText(font.large, labels[i], 0, &w, &h);
					if (i == selected) {
						GFX_blitPill(ASSET_WHITE_PILL, canvas, &(SDL_Rect){SCALE1(PADDING), y, w + SCALE1(BUTTON_PADDING*2), SCALE1(PILL_SIZE)});
						color = COLOR_BLACK;
					}
					GFX_blitText(font.large, labels[i], 0, color, canvas,
						&(SDL_Rect){SCALE1(PADDING+BUTTON_PADDING), y + SCALE1(4), w, h});
				}
			}
			// no countdown or other text (Dan 2026-11-03): whoever can read this needs only the list and the
			// buttons, and a dark screen, the one the timer is for, shows nothing anyway
			if (confirm) GFX_blitButtonGroup((char*[]){ "B", "UNDO", "START", "HOLD TO KEEP", NULL }, 1, canvas, 1);
			else if (asking) GFX_blitButtonGroup((char*[]){ "B", "BACK", "START", "HOLD TO SET UP", NULL }, 1, canvas, 1);
			else GFX_blitButtonGroup((char*[]){ "START", "HOLD 2s", NULL }, 0, canvas, 1);
			if (canvas != screen) SDL_BlitSurface(canvas, NULL, screen, NULL);
			GFX_flip(screen);
			dirty = 0;
		}
		else GFX_sync();
	}

	// clear both screens before handing back: the shell may write the boot area and reboot next
	GFX_clear(screen);
	GFX_flip(screen);
	if (canvas != screen) SDL_FreeSurface(canvas);
	QuitSettings();
	PWR_quit();
	PAD_quit();
	GFX_quit();
	fflush(stdout);
	if (result == 0 && !confirm) dprintf(answer, "%s\n", ids[selected]);
	return result;
}
