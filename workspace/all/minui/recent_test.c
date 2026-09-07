#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define RECENT_PATH "recent.txt"
#define FAUX_RECENT_PATH "/recent"
#define SDCARD_PATH "/sdcard"
#define PLATFORM "test"
#define HIDE_TOOLS_PATH "hide-tools.txt"
#define MAIN_ROW_COUNT 6
#define HAS_POWER_BUTTON 1
#define exactMatch(a,b) (strcmp((a),(b))==0)

// These types, cleanup functions and input branches are extracted from minui.c.
#include "recent_types.inc"
#include "recent_cleanup.inc"
static Directory* top;
static Array* recents;
static Array* stack;
static char* recent_alias;
static int can_resume, should_resume, restore_depth, restore_relative;
static int restore_selected, restore_start, restore_end;
// clearRecents now drops the stack and re-opens the root, so the harness must model both. Declared
// before the extracted code because that code calls openDirectory.
static void Directory_free(Directory* self);
static void DirectoryArray_pop(Array* self);
static void openDirectory(char* path, int auto_launch);
static int root_opens; // how many times clearRecents rebuilt the root
#include "recent_clear.inc"

enum { BTN_A=1, BTN_B=2, BTN_Y=4, BTN_RESUME=8, BTN_UP=16, BTN_DOWN=32,
	BTN_LEFT=64, BTN_RIGHT=128, BTN_L1=256, BTN_R1=512, BTN_SELECT=1024, BTN_MENU=2048 };
static int pressed, released, opened, show_version, show_clear, dirty, show_setting, simple_mode;
static int hdmi;
static int GetHDMI(void) { return hdmi; }
static int PAD_justPressed(int b) { return !!(pressed & b); }
static int PAD_justRepeated(int b) { return PAD_justPressed(b); }
static int PAD_isPressed(int b) { return PAD_justPressed(b); }
static int PAD_justReleased(int b) { return !!(released & b); }
static int PAD_tappedMenu(unsigned long now) { (void)now; return PAD_justPressed(BTN_MENU); }
static int PWR_ignoreSettingInput(int b, int s) { (void)b; return s; }
static void PWR_disableSleep(void) {}
static void PWR_enableSleep(void) {}
static int flagExists(const char* p) { (void)p; return 0; }
static int exists(const char* p) { return access(p, F_OK)==0; }
static void readyResume(Entry* e) { assert(e); can_resume = 1; }
static void Entry_open(Entry* e) { assert(e); opened++; }
static void Directory_free(Directory* self) {
	if (!self) return;
	while (self->entries->count) Entry_free(Array_pop(self->entries));
	Array_free(self->entries);
	free(self->alphas);
	free(self->path);
	free(self);
}
static void DirectoryArray_pop(Array* self) { Directory_free(Array_pop(self)); }
// Stands in for the real openDirectory: builds a root whose contents come from getRoot(), which omits
// Recently Played once the history file is gone. One plain entry stands for the Roms folders.
static void openDirectory(char* path, int auto_launch) {
	(void)auto_launch;
	root_opens++;
	top = calloc(1, sizeof(*top));
	top->path = strdup(path);
	top->entries = Array_new();
	top->alphas = calloc(1, sizeof(*top->alphas));
	if (exists(RECENT_PATH)) { // hasRecents(): the faux folder is listed only while history exists
		Entry* e = calloc(1, sizeof(*e));
		e->path = strdup(FAUX_RECENT_PATH); e->name = strdup("Recently Played");
		Array_push(top->entries, e);
	}
	Entry* g = calloc(1, sizeof(*g));
	g->path = strdup("/sdcard/Roms"); g->name = strdup("Game Boy");
	Array_push(top->entries, g);
	top->selected = top->start = 0;
	top->end = top->entries->count<MAIN_ROW_COUNT ? top->entries->count : MAIN_ROW_COUNT;
	Array_push(stack, top);
}
static void closeDirectory(void) { free(top->path); top->path = strdup(SDCARD_PATH); }

static void input(int down, int up) {
	pressed = down;
	released = up;
	unsigned long now = 0;
	int total = top->entries->count, selected = top->selected;
#include "recent_input.inc"
}

static void write_file(const char* path) {
	FILE* f = fopen(path, "w");
	assert(f);
	assert(fputs("preserve me\n", f)>=0);
	assert(fclose(f)==0);
}

static void setup(int count) {
	top = calloc(1, sizeof(*top));
	top->path = strdup(FAUX_RECENT_PATH);
	top->entries = Array_new();
	top->alphas = calloc(1, sizeof(*top->alphas));
	recents = Array_new();
	stack = Array_new();
	Array_push(stack, NULL);
	Array_push(stack, top);
	for (int i=0; i<count; i++) {
		Recent* r = calloc(1, sizeof(*r));
		r->path = strdup("/Roms/test.gb");
		r->alias = i%2 ? strdup("Alias") : NULL;
		Array_push(recents, r);
		Entry* e = calloc(1, sizeof(*e));
		e->path = strdup("/sdcard/Roms/test.gb");
		e->name = strdup("Test");
		e->unique = strdup("Test (GB)");
		Array_push(top->entries, e);
	}
	top->selected = count ? count-1 : 0;
	top->end = count;
	top->start = count>MAIN_ROW_COUNT ? count-MAIN_ROW_COUNT : 0;
	recent_alias = count ? ((Entry*)top->entries->items[0])->name : NULL;
	can_resume = should_resume = 1;
	restore_depth = restore_relative = 4;
	show_version = show_clear = show_setting = dirty = opened = 0;
}

static void cleanup(void) {
	while (recents->count) Recent_free(Array_pop(recents));
	while (top->entries->count) Entry_free(Array_pop(top->entries));
	Array_free(recents);
	Array_free(top->entries);
	Array_free(stack);
	free(top->alphas);
	free(top->path);
	free(top);
}

int main(void) {
	write_file("game.gb"); write_file("game.sav"); write_file("game.st0");
	for (int count=1; count<=24; count++) {
		setup(count); write_file(RECENT_PATH);
		input(BTN_Y | BTN_A, 0);
		assert(show_clear==1 && exists(RECENT_PATH) && opened==0);
		int selected = top->selected;
		input(BTN_DOWN | BTN_RIGHT, BTN_RESUME);
		assert(top->selected==selected && opened==0);
		input(BTN_B | BTN_A, 0); // cancel wins over simultaneous confirm
		assert(show_clear==0 && recents->count==count && exists(RECENT_PATH));
		input(BTN_Y, 0); input(BTN_MENU, 0);
		assert(show_clear==0 && recents->count==count);
		root_opens = 0;
		input(BTN_Y, 0); input(BTN_A, 0);
		assert(show_clear==0 && !exists(RECENT_PATH));
		assert(!recents->count && !recent_alias);
		// Clearing returns to a REBUILT main menu, not an empty history list (Dan, 2026-09-07):
		// the stack is back to just the root, and Recently Played is no longer listed there.
		assert(root_opens==1 && stack->count==1 && exactMatch(top->path, SDCARD_PATH));
		for (int i=0; i<top->entries->count; i++)
			assert(!exactMatch(((Entry*)top->entries->items[i])->path, FAUX_RECENT_PATH));
		assert(top->entries->count && !top->selected && !top->start); // a usable root, selection reset
		assert(!can_resume && !should_resume && restore_depth==-1 && restore_relative==-1);
		assert(!restore_selected && !restore_start && !restore_end);
		// at the root the history shortcut is inert and nothing auto-launches. RESUME is deliberately
		// NOT exercised here: the root list is non-empty, so resuming from it is correct behavior.
		input(BTN_L1, 0); input(BTN_R1, 0); input(BTN_Y, 0);
		assert(!opened && !show_clear);
		assert(!clearRecents()); // guarded: only ever clears from inside the history list
		input(BTN_B, 0); // already at the root, so this cannot pop past it
		assert(exactMatch(top->path, SDCARD_PATH) && stack->count==1);
		cleanup();
	}
	setup(2);
	assert(mkdir(RECENT_PATH, 0700)==0); // deterministic unlink failure, even as root
	input(BTN_Y, 0); input(BTN_A, 0);
	assert(show_clear==2 && recents->count==2 && top->entries->count==2 && recent_alias);
	assert(rmdir(RECENT_PATH)==0);
	write_file(RECENT_PATH);
	input(BTN_A, 0); // retry after fixing card condition
	assert(!show_clear && !recents->count);
	cleanup();
	setup(1); write_file(RECENT_PATH);
	show_setting = 1; input(BTN_Y, 0); assert(!show_clear);
	hdmi = 1; input(BTN_Y, 0); assert(show_clear==1); input(BTN_B, 0); hdmi = 0;
	show_setting = 0; show_version = 1; input(BTN_Y, 0); assert(!show_clear);
	show_version = 0; input(0, BTN_RESUME); assert(opened==1 && exists(RECENT_PATH));
	free(top->path); top->path = strdup(SDCARD_PATH);
	input(BTN_Y, 0); assert(!show_clear && !clearRecents() && exists(RECENT_PATH));
	cleanup();
	assert(exists("game.gb") && exists("game.sav") && exists("game.st0"));
	puts("recent clear: confirmation, cancellation, failure/retry, 1-24 entries, empty navigation, resume and scope passed");
	return 0;
}
