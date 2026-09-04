// status.elf -- a no-button status/progress screen for the Device Sync pak.
// Unlike say.elf (a message box that always draws a dismiss button), this draws ONLY the message,
// so it never reads as "tap OK". It reads its message from a file each frame so the caller can update
// it live, optionally draws a progress bar from a second file ("<done>/<total>"), and exits CLEANLY on
// SIGTERM/SIGINT/SIGHUP -- so the caller kills it with a plain kill and the framebuffer is left tidy
// (say.elf ignores SIGTERM via SDL, which is why backgrounded says stacked and garbled the screen).
//
//   status.elf <message-file> [progress-file]
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
	if (!path) return;
	FILE* f = fopen(path, "r");
	if (!f) return;
	int n = fread(out, 1, cap - 1, f);
	if (n < 0) n = 0;
	out[n] = 0;
	fclose(f);
	while (n > 0 && (out[n-1] == '\n' || out[n-1] == '\r')) out[--n] = 0;
}

int main(int argc, char* argv[]) {
	const char* msgpath  = argc > 1 ? argv[1] : NULL;
	const char* progpath = argc > 2 ? argv[2] : NULL;
	signal(SIGTERM, on_sig);
	signal(SIGINT,  on_sig);
	signal(SIGHUP,  on_sig);

	PWR_setCPUSpeed(CPU_SPEED_MENU);
	SDL_Surface* screen = GFX_init(MODE_MAIN);
	PWR_init();
	InitSettings();

	char msg[1024] = "", prog[64] = "";
	char lastmsg[1024] = "\x01", lastprog[64] = "\x01";

	while (!g_quit) {
		read_file(msgpath,  msg,  sizeof msg);
		read_file(progpath, prog, sizeof prog);

		if (strcmp(msg, lastmsg) != 0 || strcmp(prog, lastprog) != 0) {
			int done = 0, total = 0;
			float frac = -1;
			if (prog[0] && sscanf(prog, "%d/%d", &done, &total) == 2 && total > 0) {
				frac = (float)done / (float)total;
				if (frac < 0) frac = 0;
				if (frac > 1) frac = 1;
			}

			GFX_clear(screen);
			int msg_bottom = (frac >= 0) ? screen->h - SCALE1(56) : screen->h;
			GFX_blitMessage(font.large, msg, screen, &(SDL_Rect){0, 0, screen->w, msg_bottom});

			if (frac >= 0) {
				int bw = screen->w * 3 / 5, bh = SCALE1(14);
				int bx = (screen->w - bw) / 2, by = screen->h - SCALE1(40);
				Uint32 track = SDL_MapRGB(screen->format, 0x3a, 0x3a, 0x3a);
				Uint32 fill  = SDL_MapRGB(screen->format, 0xff, 0xff, 0xff);
				SDL_FillRect(screen, &(SDL_Rect){bx, by, bw, bh}, track);
				SDL_FillRect(screen, &(SDL_Rect){bx, by, (int)(bw * frac), bh}, fill);
			}

			GFX_flip(screen);
			strcpy(lastmsg, msg);
			strcpy(lastprog, prog);
		}
		SDL_Delay(120);   // poll the files ~8x/sec so live updates show without busy-spinning
	}

	QuitSettings();
	PWR_quit();
	GFX_quit();
	return EXIT_SUCCESS;
}
