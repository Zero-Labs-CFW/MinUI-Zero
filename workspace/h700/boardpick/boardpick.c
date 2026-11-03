// boardpick: first-boot model picker for the one H700 image (tools/h700-strip/boardpick.sh drives it).
// The card boots one screen type at a time. Any screen that can be read lists EVERY model, so nobody hunts for
// theirs through other boards' screen setups (an H read the SP's screen fine, Dan 2026-11-03).
//   boardpick [-b] [-s <n>] <timeout_s> <id> <label> [<id> <label> ...]
//     Hold START 2 s on a model: prints its id, exit 0. No input before the countdown ends: exit 2 (try the next
//     screen type: a dark screen moves on by itself). With -b, hold B 2 s: exit 3 (back to the previous screen
//     type, the way back from a garbled one). -s <n> starts on model n.
//   boardpick -c <timeout_s> <label>: after a model is installed, ask whether the screen is right. Hold START 2 s:
//     exit 0 (keep it). Hold B 2 s or no input: exit 2 (the shell puts the last screen type back), so a wrong
//     pick that garbles the screen undoes itself.
//   boardpick -m <title> <line>: show a message until killed (the shell runs it while it installs and reboots,
//     which otherwise happens on a black screen; Dan 2026-11-02)
// A HOLD, never a press: mashing A through first boot must not pick a model.
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

static int message(char* title, char* line) {
	SDL_Surface* screen = GFX_init(MODE_MAIN);
	GFX_clear(screen);
	// both lines centered on the screen as one block (GFX_blitText centers across the rect's width)
	int title_h = TTF_FontHeight(font.large), line_h = TTF_FontHeight(font.small), gap = SCALE1(8);
	int y = (screen->h - (title_h + gap + line_h)) / 2;
	GFX_blitText(font.large, title, 0, COLOR_WHITE, screen, &(SDL_Rect){0, y, screen->w, title_h});
	GFX_blitText(font.small, line, 0, COLOR_GRAY, screen, &(SDL_Rect){0, y + title_h + gap, screen->w, line_h});
	GFX_flip(screen);
	for (;;) sleep(60); // the reboot (or the shell's kill) ends it
	return 0;
}

static void small_line(SDL_Surface* screen, char* text, int y) {
	GFX_blitText(font.small, text, 0, COLOR_GRAY, screen,
		&(SDL_Rect){SCALE1(PADDING+BUTTON_PADDING), y, screen->w - SCALE1(PADDING*2), SCALE1(PILL_SIZE)});
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
	PAD_init();
	PWR_init();
	InitSettings();

	// rows that fit between the title and the two hint lines above the button hints; the list scrolls past that
	int list_y = SCALE1(PADDING + PILL_SIZE + 8);
	int line_h = TTF_FontHeight(font.small) + SCALE1(4);
	int rows = (screen->h - list_y - SCALE1(8) - line_h * 2 - SCALE1(PILL_SIZE + PADDING * 2)) / SCALE1(PILL_SIZE);
	if (rows < 1) rows = 1;
	int first = 0; // the top row shown

	int result = 2, quit = 0, dirty = 1, shown_s = -1;
	uint32_t deadline = SDL_GetTicks() + timeout_ms;
	uint32_t start_at = 0, b_at = 0; // when the hold began, 0 = not held
	while (!quit) {
		PAD_poll();
		uint32_t now = SDL_GetTicks();
		if (PAD_anyJustPressed()) {
			deadline = now + TOUCHED_MS;
			dirty = 1;
		}
		if (!confirm) {
			if (PAD_justRepeated(BTN_UP)) { selected = (selected + count - 1) % count; dirty = 1; }
			else if (PAD_justRepeated(BTN_DOWN)) { selected = (selected + 1) % count; dirty = 1; }
		}

		if (PAD_isPressed(BTN_START)) { if (!start_at) start_at = now; }
		else start_at = 0;
		if ((back || confirm) && PAD_isPressed(BTN_B)) { if (!b_at) b_at = now; }
		else b_at = 0;

		if (start_at && now - start_at >= HOLD_MS) { result = 0; quit = 1; }
		else if (b_at && now - b_at >= HOLD_MS) { result = confirm ? 2 : 3; quit = 1; }
		else if ((int32_t)(deadline - now) <= 0) { result = 2; quit = 1; }

		int left_s = ((int32_t)(deadline - now) + 999) / 1000;
		if (left_s != shown_s || start_at || b_at) dirty = 1;
		if (dirty && !quit) {
			shown_s = left_s;
			GFX_clear(screen);
			char line[128];
			GFX_blitText(font.large, confirm ? "Does the screen look right?" : "Which handheld is this?", 0, COLOR_WHITE,
				screen, &(SDL_Rect){SCALE1(PADDING+BUTTON_PADDING), SCALE1(PADDING), screen->w - SCALE1(PADDING*2), SCALE1(PILL_SIZE)});
			int y = list_y;
			if (confirm) {
				snprintf(line, sizeof line, "Set up as %s", labels[0]);
				GFX_blitText(font.large, line, 0, COLOR_WHITE, screen,
					&(SDL_Rect){SCALE1(PADDING+BUTTON_PADDING), y + SCALE1(4), screen->w - SCALE1(PADDING*2), SCALE1(PILL_SIZE)});
				y += SCALE1(PILL_SIZE);
			}
			else {
				if (selected < first) first = selected;
				if (selected >= first + rows) first = selected - rows + 1;
				for (int i = first; i < count && i < first + rows; i++, y += SCALE1(PILL_SIZE)) {
					SDL_Color color = COLOR_WHITE;
					int w, h;
					GFX_sizeText(font.large, labels[i], 0, &w, &h);
					if (i == selected) {
						GFX_blitPill(ASSET_WHITE_PILL, screen, &(SDL_Rect){SCALE1(PADDING), y, w + SCALE1(BUTTON_PADDING*2), SCALE1(PILL_SIZE)});
						color = COLOR_BLACK;
					}
					GFX_blitText(font.large, labels[i], 0, color, screen,
						&(SDL_Rect){SCALE1(PADDING+BUTTON_PADDING), y + SCALE1(4), w, h});
				}
			}
			y += SCALE1(8);
			if (start_at) snprintf(line, sizeof line, confirm ? "Keep holding START to keep it" : "Keep holding START to choose %s", labels[selected]);
			else if (b_at) snprintf(line, sizeof line, confirm ? "Keep holding B to go back" : "Keep holding B to go back to the last screen type");
			else if (confirm) snprintf(line, sizeof line, "No answer in %ds goes back", left_s);
			else snprintf(line, sizeof line, "No choice in %ds tries the next screen type", left_s);
			small_line(screen, line, y);
			if (!confirm && count > rows) {
				snprintf(line, sizeof line, "UP and DOWN show all %d models", count);
				small_line(screen, line, y + line_h);
			}
			if (confirm) GFX_blitButtonGroup((char*[]){ "B", "HOLD TO GO BACK", NULL }, 0, screen, 0);
			GFX_blitButtonGroup((char*[]){ "START", confirm ? "HOLD TO KEEP" : "HOLD TO CHOOSE", NULL }, 0, screen, 1);
			GFX_flip(screen);
			dirty = 0;
		}
		else GFX_sync();
	}

	// clear both screens before handing back: the shell may write the boot area and reboot next
	GFX_clear(screen);
	GFX_flip(screen);
	QuitSettings();
	PWR_quit();
	PAD_quit();
	GFX_quit();
	fflush(stdout);
	if (result == 0 && !confirm) dprintf(answer, "%s\n", ids[selected]);
	return result;
}
