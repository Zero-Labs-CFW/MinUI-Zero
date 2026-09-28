// Favorites tests on a clean card. See run-favorites-tests.sh: the code under test is extracted from
// minarch.c, utils.c and minui.c, never copied.
//
// The invariant that broke in v1.8.0/v1.8.1: a favorites key must name a file that exists. When it
// does not, the launcher drops the entry (no Favorites row), and every game that derives the same
// key reads FAVORITED. The old bug gave every single-disc game in a folder the key
// "<folder>/<folder>.m3u". The card starts EMPTY here on purpose: favorites saved before that change
// used the right key and hid the bug on every test device.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>

#include "favorites_extracted.h"

static int failures = 0;
static void ck(int cond, const char* what) {
	printf("  %-4s %s\n", cond ? "ok" : "FAIL", what);
	if (!cond) failures++;
}

static void mkdirs(const char* path) {
	char buf[MAX_PATH];
	snprintf(buf, sizeof(buf), "%s", path);
	for (char* p = buf + 1; *p; p++) {
		if (*p != '/') continue;
		*p = '\0';
		mkdir(buf, 0755);
		*p = '/';
	}
	mkdir(buf, 0755);
}
// create a file on the temp card; rel is SD-relative like the favorites lines ("/Roms/...")
static void card_file(const char* rel, const char* body) {
	char path[MAX_PATH];
	snprintf(path, sizeof(path), "%s%s", SDCARD_PATH, rel);
	char dir[MAX_PATH];
	snprintf(dir, sizeof(dir), "%s", path);
	*strrchr(dir, '/') = '\0';
	mkdirs(dir);
	FILE* f = fopen(path, "w");
	if (body) fputs(body, f);
	fclose(f);
}

// What minarch holds for the running game: Game_open copies the rom path, then fills m3u_path via
// Game_findM3U. The struct starts dirty to prove a no-playlist open clears it (minarch's game is
// reused across opens).
static struct { char path[MAX_PATH]; char m3u_path[MAX_PATH]; } game;
static void game_open(const char* rel) {
	memset(&game, 'x', sizeof(game));
	game.m3u_path[MAX_PATH - 1] = '\0';
	snprintf(game.path, sizeof(game.path), "%s%s", SDCARD_PATH, rel);
	Game_findM3U(game.path, game.m3u_path, sizeof(game.m3u_path));
}
// minarch's key: `game.m3u_path[0] ? game.m3u_path : game.path` (the runner greps that it is unchanged)
static char* favorites_key(void) { return game.m3u_path[0] ? game.m3u_path : game.path; }

static int is_favorite(const char* rel) { game_open(rel); return Favorites_has(favorites_key()); }
static void press_y(const char* rel) { game_open(rel); Favorites_toggle(favorites_key()); }

static int list_lines(void) {
	FILE* f = fopen(FAVORITE_PATH, "r");
	if (!f) return 0;
	int n = 0;
	char line[MAX_PATH];
	while (fgets(line, sizeof(line), f)) if (line[0] != '\n') n++;
	fclose(f);
	return n;
}
// every line in the list names a real file on the card
static int list_all_exist(void) {
	FILE* f = fopen(FAVORITE_PATH, "r");
	if (!f) return 1;
	int ok = 1;
	char line[MAX_PATH], path[MAX_PATH * 2];
	while (fgets(line, sizeof(line), f)) {
		trimTrailingNewlines(line);
		if (!line[0]) continue;
		snprintf(path, sizeof(path), "%s%s", SDCARD_PATH, line);
		if (!exists(path)) { printf("       dead entry: %s\n", line); ok = 0; }
	}
	fclose(f);
	return ok;
}

#define GBC "/Roms/Game Boy Color (GBC)"
#define BOMBERMAN GBC "/Bomberman GB.gbc"
#define TETRIS GBC "/Tetris DX.gbc"
#define ZELDA "/Roms/Game Boy (GB)/Zelda/Zelda.gb" // a single-disc game in a folder named after it
#define FF7_M3U "/Roms/Sony PlayStation (PS)/FF7/FF7.m3u"
#define FF7_D1 "/Roms/Sony PlayStation (PS)/FF7/FF7 (Disc 1).cue"
#define FF7_D2 "/Roms/Sony PlayStation (PS)/FF7/FF7 (Disc 2).cue"

int main(void) {
	mkdirs(SHARED_USERDATA_PATH "/.minui"); // MinUI.pak/launch.sh makes this at every boot, on every platform
	card_file(BOMBERMAN, NULL);
	card_file(TETRIS, NULL);
	card_file(ZELDA, NULL);
	card_file(FF7_D1, NULL);
	card_file(FF7_D2, NULL);
	card_file(FF7_M3U, "FF7 (Disc 1).cue\nFF7 (Disc 2).cue\n");

	puts("clean card: nothing favorited");
	ck(!hasFavorites(), "no Favorites row");
	ck(!is_favorite(BOMBERMAN), "Bomberman not favorited");

	puts("single-disc game in a system folder");
	press_y(BOMBERMAN);
	ck(list_lines() == 1, "one entry written");
	ck(list_all_exist(), "the entry names a real file");
	ck(hasFavorites(), "Favorites row appears");
	ck(is_favorite(BOMBERMAN), "Bomberman reads FAVORITED");
	ck(!is_favorite(TETRIS), "Tetris, same folder, does NOT read FAVORITED");

	puts("single-disc game in a folder named after it (no playlist)");
	press_y(ZELDA);
	ck(list_lines() == 2 && list_all_exist(), "keyed by the rom, which exists");
	ck(is_favorite(ZELDA), "Zelda reads FAVORITED");

	puts("multi-disc game: one favorite, keyed by its playlist");
	press_y(FF7_D2);
	ck(list_lines() == 3 && list_all_exist(), "one entry for the game, and it exists");
	ck(is_favorite(FF7_D1), "disc 1 reads FAVORITED after favoriting from disc 2");
	ck(Favorites_has(SDCARD_PATH FF7_M3U), "the entry is the playlist");

	puts("unfavorite everything: the row goes away");
	press_y(BOMBERMAN);
	press_y(ZELDA);
	press_y(FF7_D1);
	ck(list_lines() == 0, "list empty");
	ck(!hasFavorites(), "no Favorites row");

	puts("a list written by v1.8.0/v1.8.1 (the shared fake key) is ignored, not honoured");
	card_file("/.userdata/shared/.minui/favorites.txt", GBC "/Game Boy Color (GBC).m3u\n");
	ck(!hasFavorites(), "no Favorites row for the dead entry");
	ck(!is_favorite(TETRIS), "Tetris does not read FAVORITED");
	press_y(TETRIS);
	ck(hasFavorites() && is_favorite(TETRIS) && !is_favorite(BOMBERMAN), "favoriting again works, for that game only");

	if (failures) { printf("FAIL: %d check(s)\n", failures); return 1; }
	puts("PASS");
	return 0;
}
