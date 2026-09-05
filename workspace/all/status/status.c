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
// Exit code: 0 = proceeded / timed out / killed; 1 = user pressed B.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <msettings.h>

#include "defines.h"
#include "api.h"
#include "utils.h"

static volatile sig_atomic_t g_quit = 0;
static void on_sig(int s) { (void)s; g_quit = 1; }

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
	int timeout = 0, countdown = 0, cancel_b = 0;
	for (int i = 1; i < argc; i++) {
		if      (!strcmp(argv[i], "--timeout")   && i+1 < argc) timeout   = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--countdown") && i+1 < argc) countdown = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--cancel-b")) cancel_b = 1;
		else if (!msgpath)  msgpath  = argv[i];
		else if (!progpath) progpath = argv[i];
	}
	signal(SIGTERM, on_sig);
	signal(SIGINT,  on_sig);
	signal(SIGHUP,  on_sig);

	PWR_setCPUSpeed(CPU_SPEED_MENU);
	SDL_Surface* screen = GFX_init(MODE_MAIN);
	if (cancel_b) PAD_init();
	PWR_init();
	InitSettings();

	uint32_t start = SDL_GetTicks();
	int rc = 0;
	char msg[1024] = "", prog[64] = "", shown[1280] = "";
	char lastshown[1280] = "\x01", lastprog[64] = "\x01";

	while (!g_quit) {
		uint32_t el = (SDL_GetTicks() - start) / 1000;
		if (cancel_b) { PAD_poll(); if (PAD_justPressed(BTN_B)) { rc = 1; break; } }
		if (timeout && el >= (uint32_t)timeout) break;
		int remain = countdown ? countdown - (int)el : 0;
		if (countdown && remain <= 0) break;          // auto-proceed

		read_file(msgpath,  msg,  sizeof msg);
		read_file(progpath, prog, sizeof prog);
		if (countdown) snprintf(shown, sizeof shown, "%s\n\nStarting in %d...%s", msg, remain, cancel_b ? "\nPress B to cancel" : "");
		else           snprintf(shown, sizeof shown, "%s", msg);

		if (strcmp(shown, lastshown) != 0 || strcmp(prog, lastprog) != 0) {
			int done = 0, total = 0;
			float frac = -1;
			if (prog[0] && sscanf(prog, "%d/%d", &done, &total) == 2 && total > 0) {
				frac = (float)done / (float)total;
				if (frac < 0) frac = 0;
				if (frac > 1) frac = 1;
			}
			GFX_clear(screen);
			int msg_bottom = (frac >= 0) ? screen->h - SCALE1(56) : screen->h;
			GFX_blitMessage(font.large, shown, screen, &(SDL_Rect){0, 0, screen->w, msg_bottom});
			if (frac >= 0) {
				int bw = screen->w * 3 / 5, bh = SCALE1(14);
				int bx = (screen->w - bw) / 2, by = screen->h - SCALE1(40);
				Uint32 track = SDL_MapRGB(screen->format, 0x3a, 0x3a, 0x3a);
				Uint32 fill  = SDL_MapRGB(screen->format, 0xff, 0xff, 0xff);
				SDL_FillRect(screen, &(SDL_Rect){bx, by, bw, bh}, track);
				SDL_FillRect(screen, &(SDL_Rect){bx, by, (int)(bw * frac), bh}, fill);
			}
			GFX_flip(screen);
			strcpy(lastshown, shown);
			strcpy(lastprog, prog);
		}
		SDL_Delay(cancel_b ? 40 : 120);   // poll the pad briskly when a veto is armed
	}

	QuitSettings();
	PWR_quit();
	if (cancel_b) PAD_quit();
	GFX_quit();
	return rc;
}
