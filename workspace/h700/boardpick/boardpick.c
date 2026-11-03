// boardpick: first-boot model picker for the one H700 image (tools/h700-strip/boardpick.sh drives it).
// The card boots one screen type at a time; this asks which handheld it is among the models that share it.
//   boardpick <timeout_s> <id> <label> [<id> <label> ...]
//   boardpick -m <title> <line>: show a message until killed (the shell runs it while it installs and reboots,
//   which otherwise happens on a black screen; Dan 2026-11-02)
// Hold START 2 s on a model: prints its id, exit 0. Hold SELECT 2 s, or no input before the countdown ends:
// exit 2 (try the next screen type). A HOLD, never a press: mashing A through first boot must not pick a model.
// Any button pushes the countdown out to at least a minute, so someone reading the list is never cut off;
// a dark screen gets no input and moves on by itself.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <msettings.h>

#include "defines.h"
#include "api.h"
#include "utils.h"

#define HOLD_MS 2000
#define MAX_MODELS 8

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

int main(int argc, char* argv[]) {
	if (argc == 4 && !strcmp(argv[1], "-m")) { dup2(2, 1); return message(argv[2], argv[3]); }
	if (argc < 4 || (argc - 2) % 2) {
		fprintf(stderr, "usage: boardpick <timeout_s> <id> <label> [<id> <label> ...]\n");
		return 1;
	}
	// stdout carries the answer alone: the shell reads it with $(...). The shared API logs [INFO] lines to
	// stdout (GFX_init, input setup), which would be read as part of the board id, so send them to stderr.
	int answer = dup(1);
	dup2(2, 1);
	uint32_t timeout_ms = atoi(argv[1]) * 1000;
	int count = (argc - 2) / 2;
	if (count > MAX_MODELS) count = MAX_MODELS;
	char** ids = calloc(count, sizeof(char*));
	char** labels = calloc(count, sizeof(char*));
	for (int i = 0; i < count; i++) { ids[i] = argv[2 + i*2]; labels[i] = argv[3 + i*2]; }

	PWR_setCPUSpeed(CPU_SPEED_MENU);
	SDL_Surface* screen = GFX_init(MODE_MAIN);
	PAD_init();
	PWR_init();
	InitSettings();

	int selected = 0, result = 2, quit = 0, dirty = 1, shown_s = -1;
	uint32_t deadline = SDL_GetTicks() + timeout_ms;
	uint32_t start_at = 0, select_at = 0; // when the hold began, 0 = not held
	while (!quit) {
		PAD_poll();
		uint32_t now = SDL_GetTicks();
		if (PAD_anyJustPressed()) {
			if (deadline < now + 60000) deadline = now + 60000;
			dirty = 1;
		}
		if (PAD_justRepeated(BTN_UP)) { selected = (selected + count - 1) % count; dirty = 1; }
		else if (PAD_justRepeated(BTN_DOWN)) { selected = (selected + 1) % count; dirty = 1; }

		if (PAD_isPressed(BTN_START)) { if (!start_at) start_at = now; }
		else start_at = 0;
		if (PAD_isPressed(BTN_SELECT)) { if (!select_at) select_at = now; }
		else select_at = 0;

		if (start_at && now - start_at >= HOLD_MS) { result = 0; quit = 1; }
		else if (select_at && now - select_at >= HOLD_MS) { result = 2; quit = 1; }
		else if ((int32_t)(deadline - now) <= 0) { result = 2; quit = 1; }

		int left_s = ((int32_t)(deadline - now) + 999) / 1000;
		if (left_s != shown_s || start_at || select_at) dirty = 1;
		if (dirty && !quit) {
			shown_s = left_s;
			GFX_clear(screen);
			int y = SCALE1(PADDING);
			GFX_blitText(font.large, "Which handheld is this?", 0, COLOR_WHITE, screen,
				&(SDL_Rect){SCALE1(PADDING+BUTTON_PADDING), y, screen->w - SCALE1(PADDING*2), SCALE1(PILL_SIZE)});
			y += SCALE1(PILL_SIZE + 8);
			for (int i = 0; i < count; i++, y += SCALE1(PILL_SIZE)) {
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
			char line[128];
			if (start_at) snprintf(line, sizeof line, "Keep holding START to choose %s", labels[selected]);
			else if (select_at) snprintf(line, sizeof line, "Keep holding SELECT to try the next screen type");
			else snprintf(line, sizeof line, "No choice in %ds tries the next screen type", left_s);
			y += SCALE1(8);
			GFX_blitText(font.small, line, 0, COLOR_GRAY, screen,
				&(SDL_Rect){SCALE1(PADDING+BUTTON_PADDING), y, screen->w - SCALE1(PADDING*2), SCALE1(PILL_SIZE)});
			GFX_blitButtonGroup((char*[]){ "SELECT", "NOT LISTED", NULL }, 0, screen, 0);
			GFX_blitButtonGroup((char*[]){ "START", "HOLD TO CHOOSE", NULL }, 0, screen, 1);
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
	if (result == 0) dprintf(answer, "%s\n", ids[selected]);
	return result;
}
