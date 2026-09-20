// status.elf -- a no-button status/progress screen for the Device Sync pak.
// Unlike say.elf (a message box that always draws a dismiss button), this draws ONLY the message, so it
// never reads as "tap OK". It reads its message from a file each frame so the caller can update it live,
// optionally draws a progress bar from a second file ("<done>/<total>"), and exits CLEANLY on
// SIGTERM/SIGINT/SIGHUP (say.elf ignores SIGTERM via SDL, which is why backgrounded says stacked).
//
//   status.elf <message-file> [progress-file] [--timeout N] [--countdown N] [--cancel-b]
//
//   --timeout N    exit 0 on its own after N seconds (auto-dismissing "Done" screens)
//   --countdown N  append "Starting in N..." and exit 0 when it reaches 0 (auto-proceed)
//   --cancel-b     poll the pad; B exits 1 (a veto). ONLY B is read, so it never reads as "tap OK".
//                  Draws the standard bottom-left B pill, so the affordance looks like every other
//                  screen in the OS instead of being typed into the message (Dan, 2026-09-18).
//   --cancel-label the word on that pill (default STOP)
//   --steps "a|b|c" stepper mode: draw a dot-and-label progress row instead of a message; the message
//                  file then holds the CURRENT step number (1-based) and the caller advances it live, so
//                  one screen replaces a flurry of separate "Searching/Connecting/Comparing" texts.
// Exit code: 0 = proceeded / timed out / killed; 1 = user pressed B.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <math.h>
#include <msettings.h>

#include "defines.h"
#include "api.h"
#include "utils.h"

static volatile sig_atomic_t g_quit = 0;
static void on_sig(int s) { (void)s; g_quit = 1; }

static void fill_disc(SDL_Surface* s, int cx, int cy, int r, Uint32 c) {
	for (int dy=-r; dy<=r; dy++) { int half=(int)sqrtf((float)(r*r-dy*dy)); SDL_FillRect(s, &(SDL_Rect){cx-half, cy+dy, half*2+1, 1}, c); }
}
// A dot-and-label progress row: done+active dots filled white, pending gray; the connector to a done
// step is white too. `cur` is 1-based. Vertically centered in the area above the button row.
static void render_steps(SDL_Surface* s, char** labels, int n, int cur, int btn_h, const char* caption, int pulse) {
	Uint32 on  = SDL_MapRGB(s->format, 0xff,0xff,0xff);   // done + active
	Uint32 mid = SDL_MapRGB(s->format, 0x9a,0x9a,0x9a);   // active label / breath
	Uint32 off = SDL_MapRGB(s->format, 0x44,0x44,0x46);   // pending (dim, tinted)
	int R = SCALE1(9), lh = SCALE1(3);
	int cy = (s->h - btn_h)/2 - SCALE1(6);
	int margin = SCALE1(PADDING + 44);
	int span = s->w - 2*margin;
	if (span > s->w/2) span = s->w/2;              // cap the row width; edge-to-edge read too wide
	int stepx = (n>1) ? span/(n-1) : 0;
	int x0 = (n>1) ? (s->w - span)/2 : s->w/2;     // center the (capped) row
	for (int i=0; i<n-1; i++) {                      // connectors behind the dots
		int a = x0 + i*stepx, b = x0 + (i+1)*stepx;
		SDL_FillRect(s, &(SDL_Rect){a, cy - lh/2, b-a, lh}, (i < cur-1) ? on : off);
	}
	for (int i=0; i<n; i++) {
		int cx = x0 + i*stepx;
		if (i < cur-1)       fill_disc(s, cx, cy, R, on);                 // done: solid
		else if (i > cur-1)  fill_disc(s, cx, cy, R, off);               // pending: dim
		else {                                                            // active: a breathing halo says "here, working"
			fill_disc(s, cx, cy, R + SCALE1(4) + pulse, mid);
			fill_disc(s, cx, cy, R, on);
		}
		if (!labels[i]) continue;
		int w=0,h=0; GFX_sizeText(font.tiny, labels[i], SCALE1(12), &w, &h);
		SDL_Color lc = (i < cur-1) ? (SDL_Color){0xbb,0xbb,0xbb,0xff}
		            : (i == cur-1) ? COLOR_WHITE
		                           : (SDL_Color){0x77,0x77,0x77,0xff};
		GFX_blitText(font.tiny, labels[i], SCALE1(12), lc, s, &(SDL_Rect){cx - w/2, cy + R + SCALE1(4) + SCALE1(12), w, h});
	}
	if (caption && caption[0]) {   // a small hint under the row (e.g. "Open Device Sync on the other device")
		int w=0,h=0; GFX_sizeText(font.small, caption, SCALE1(12), &w, &h);
		GFX_blitText(font.small, caption, SCALE1(12), COLOR_WHITE, s, &(SDL_Rect){(s->w - w)/2, cy + R + SCALE1(52), w, h});
	}
}

static void read_file(const char* path, char* out, int cap) {
	out[0] = 0;
	if (!path || !path[0]) return;
	FILE* f = fopen(path, "r");
	if (!f) return;
	int n = fread(out, 1, cap - 1, f);
	if (n < 0) n = 0;
	out[n] = 0;
	fclose(f);
	while (n > 0 && (out[n-1] == '\n' || out[n-1] == '\r')) out[--n] = 0;
}

int main(int argc, char* argv[]) {
	const char* msgpath = NULL; const char* progpath = NULL;
	int timeout = 0, countdown = 0, cancel_b = 0, options_y = 0;
	char* cancel_label = "STOP";
	char* steps_arg = NULL;
	for (int i = 1; i < argc; i++) {
		if      (!strcmp(argv[i], "--timeout")   && i+1 < argc) timeout   = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--countdown") && i+1 < argc) countdown = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--cancel-label") && i+1 < argc) cancel_label = argv[++i];
		else if (!strcmp(argv[i], "--steps") && i+1 < argc) steps_arg = argv[++i];
		else if (!strcmp(argv[i], "--cancel-b")) cancel_b = 1;
		else if (!strcmp(argv[i], "--options-y")) options_y = 1;   // Y exits 2: the caller opens its options
		else if (!msgpath)  msgpath  = argv[i];
		else if (!progpath) progpath = argv[i];
	}
	// split "a|b|c" into up to 6 labels (in place; steps_arg is argv, writable for our lifetime)
	char* steps[6]; int nsteps = 0;
	if (steps_arg) {
		char* p = steps_arg;
		steps[nsteps++] = p;
		while (*p && nsteps < 6) { if (*p == '|') { *p = 0; steps[nsteps++] = p+1; } p++; }
	}
	signal(SIGTERM, on_sig);
	signal(SIGINT,  on_sig);
	signal(SIGHUP,  on_sig);

	PWR_setCPUSpeed(CPU_SPEED_MENU);
	SDL_Surface* screen = GFX_init(MODE_MAIN);
	if (cancel_b || options_y) PAD_init();
	PWR_init();
	InitSettings();

	uint32_t start = SDL_GetTicks();
	int rc = 0;
	char msg[1024] = "", prog[64] = "", shown[1280] = "";
	char lastshown[1280] = "\x01", lastprog[64] = "\x01";

	while (!g_quit) {
		uint32_t el = (SDL_GetTicks() - start) / 1000;
		if (cancel_b || options_y) { PAD_poll(); if (cancel_b && PAD_justPressed(BTN_B)) { rc = 1; break; } if (options_y && PAD_justPressed(BTN_Y)) { rc = 2; break; } }
		if (timeout && el >= (uint32_t)timeout) break;
		int remain = countdown ? countdown - (int)el : 0;
		if (countdown && remain <= 0) break;          // auto-proceed

		read_file(msgpath,  msg,  sizeof msg);
		read_file(progpath, prog, sizeof prog);
		// the B pill below carries the cancel affordance, so it is never spelled out in the text
		if (countdown) snprintf(shown, sizeof shown, "%s\n\nStarting in %d...", msg, remain);
		else           snprintf(shown, sizeof shown, "%s", msg);

		// stepper mode repaints every frame so the active dot can breathe; other modes repaint on change
		if (strcmp(shown, lastshown) != 0 || strcmp(prog, lastprog) != 0 || nsteps > 0) {
			int done = 0, total = 0;
			float frac = -1;
			if (prog[0] && sscanf(prog, "%d/%d", &done, &total) == 2 && total > 0) {
				frac = (float)done / (float)total;
				if (frac < 0) frac = 0;
				if (frac > 1) frac = 1;
			}
			GFX_clear(screen);
			// reserve the button row exactly as confirm.elf and say.elf do, so nothing collides with it
			int btn_h = cancel_b ? SCALE1(PADDING + PILL_SIZE + PADDING) : 0;
			if (nsteps > 0) {
				// stepper mode: the message IS the current step number (1-based); one screen for the whole
				// Searching -> Connecting -> Comparing sequence instead of separate texts (Dan, 2026-09-19)
				int cur = atoi(shown); if (cur < 1) cur = 1; if (cur > nsteps) cur = nsteps;
				const char* cap = strchr(shown, '\n'); cap = cap ? cap + 1 : "";
				int pulse = (int)(SCALE1(2) * (0.5f + 0.5f * sinf(SDL_GetTicks() / 350.0f)));  // ~2 s breath
				render_steps(screen, steps, nsteps, cur, btn_h, cap, pulse);
			} else {
				int msg_bottom = screen->h - btn_h - ((frac >= 0) ? SCALE1(56) : 0);
				GFX_blitMessage(font.large, shown, screen, &(SDL_Rect){0, 0, screen->w, msg_bottom});
				if (frac >= 0) {
					// the bar sits ABOVE the button row, never under it
					int bw = screen->w * 3 / 5, bh = SCALE1(14);
					int bx = (screen->w - bw) / 2, by = screen->h - btn_h - SCALE1(40);
					Uint32 track = SDL_MapRGB(screen->format, 0x3a, 0x3a, 0x3a);
					Uint32 fill  = SDL_MapRGB(screen->format, 0xff, 0xff, 0xff);
					SDL_FillRect(screen, &(SDL_Rect){bx, by, bw, bh}, track);
					SDL_FillRect(screen, &(SDL_Rect){bx, by, (int)(bw * frac), bh}, fill);
				}
			}
			// B is ALWAYS the bottom-left pill (the universal back button), same as every other screen
			if (cancel_b) GFX_blitButtonGroup((char*[]){ "B", cancel_label, NULL }, 0, screen, 0);
			if (options_y) GFX_blitButtonGroup((char*[]){ "Y", "Options", NULL }, 0, screen, 1);
			GFX_flip(screen);
			strcpy(lastshown, shown);
			strcpy(lastprog, prog);
		}
		SDL_Delay(cancel_b ? 40 : 120);   // poll the pad briskly when a veto is armed
	}

	QuitSettings();
	PWR_quit();
	if (cancel_b || options_y) PAD_quit();
	GFX_quit();
	return rc;
}
