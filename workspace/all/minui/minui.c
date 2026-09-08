#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <msettings.h>
#include <sys/types.h>
#include <dirent.h>
#include <ctype.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>

#include <math.h>
#include <time.h>
#include "defines.h"
#include "api.h"
#include "utils.h"

///////////////////////////////////////

typedef struct Array {
	int count;
	int capacity;
	void** items;
} Array;

static Array* Array_new(void) {
	Array* self = malloc(sizeof(Array));
	self->count = 0;
	self->capacity = 8;
	self->items = malloc(sizeof(void*) * self->capacity);
	return self;
}
static void Array_push(Array* self, void* item) {
	if (self->count>=self->capacity) {
		self->capacity *= 2;
		self->items = realloc(self->items, sizeof(void*) * self->capacity);
	}
	self->items[self->count++] = item;
}
static void Array_unshift(Array* self, void* item) {
	if (self->count==0) return Array_push(self, item);
	Array_push(self, NULL); // ensures we have enough capacity
	for (int i=self->count-2; i>=0; i--) {
		self->items[i+1] = self->items[i];
	}
	self->items[0] = item;
}
static void* Array_pop(Array* self) {
	if (self->count==0) return NULL;
	return self->items[--self->count];
}
static void Array_reverse(Array* self) {
	int end = self->count-1;
	int mid = self->count/2;
	for (int i=0; i<mid; i++) {
		void* item = self->items[i];
		self->items[i] = self->items[end-i];
		self->items[end-i] = item;
	}
}
static void Array_free(Array* self) {
	free(self->items); 
	free(self);
}

static int StringArray_indexOf(Array* self, char* str) {
	for (int i=0; i<self->count; i++) {
		if (exactMatch(self->items[i], str)) return i;
	}
	return -1;
}
static void StringArray_free(Array* self) {
	for (int i=0; i<self->count; i++) {
		free(self->items[i]);
	}
	Array_free(self);
}

///////////////////////////////////////

typedef struct Hash {
	Array* keys;
	Array* values;
} Hash; // not really a hash

static Hash* Hash_new(void) {
	Hash* self = malloc(sizeof(Hash));
	self->keys = Array_new();
	self->values = Array_new();
	return self;
}
static void Hash_free(Hash* self) {
	StringArray_free(self->keys);
	StringArray_free(self->values);
	free(self);
}
static void Hash_set(Hash* self, char* key, char* value) {
	Array_push(self->keys, strdup(key));
	Array_push(self->values, strdup(value));
}
static char* Hash_get(Hash* self, char* key) {
	int i = StringArray_indexOf(self->keys, key);
	if (i==-1) return NULL;
	return self->values->items[i];
}

///////////////////////////////////////

enum EntryType {
	ENTRY_DIR,
	ENTRY_PAK,
	ENTRY_ROM,
};
typedef struct Entry {
	char* path;
	char* name;
	char* unique;
	int type;
	int alpha; // index in parent Directory's alphas Array, which points to the index of an Entry in its entries Array :sweat_smile:
} Entry;

static Entry* Entry_new(char* path, int type) {
	char display_name[256];
	getDisplayName(path, display_name);
	Entry* self = malloc(sizeof(Entry));
	self->path = strdup(path);
	self->name = strdup(display_name);
	self->unique = NULL;
	self->type = type;
	self->alpha = 0;
	return self;
}
static void Entry_free(Entry* self) {
	free(self->path);
	free(self->name);
	if (self->unique) free(self->unique);
	free(self);
}

static int EntryArray_indexOf(Array* self, char* path) {
	for (int i=0; i<self->count; i++) {
		Entry* entry = self->items[i];
		if (exactMatch(entry->path, path)) return i;
	}
	return -1;
}
static int EntryArray_sortEntry(const void* a, const void* b) {
	Entry* item1 = *(Entry**)a;
	Entry* item2 = *(Entry**)b;
	return strcasecmp(item1->name, item2->name);
}
static void EntryArray_sort(Array* self) {
	qsort(self->items, self->count, sizeof(void*), EntryArray_sortEntry);
}

static void EntryArray_free(Array* self) {
	for (int i=0; i<self->count; i++) {
		Entry_free(self->items[i]);
	}
	Array_free(self);
}

///////////////////////////////////////

#define INT_ARRAY_MAX 27
typedef struct IntArray {
	int count;
	int items[INT_ARRAY_MAX];
} IntArray;
static IntArray* IntArray_new(void) {
	IntArray* self = malloc(sizeof(IntArray));
	self->count = 0;
	memset(self->items, 0, sizeof(int) * INT_ARRAY_MAX);
	return self;
}
static void IntArray_push(IntArray* self, int i) {
	self->items[self->count++] = i;
}
static void IntArray_free(IntArray* self) {
	free(self);
}

///////////////////////////////////////

typedef struct Directory {
	char* path;
	char* name;
	Array* entries;
	IntArray* alphas;
	// rendering
	int selected;
	int start;
	int end;
} Directory;

static int getIndexChar(char* str) {
	char i = 0;
	char c = tolower(str[0]);
	if (c>='a' && c<='z') i = (c-'a')+1;
	return i;
}

static void getUniqueName(Entry* entry, char* out_name) {
	char* filename = strrchr(entry->path, '/')+1;
	char emu_tag[256];
	getEmuName(entry->path, emu_tag);
	
	char *tmp;
	strcpy(out_name, entry->name);
	tmp = out_name + strlen(out_name);
	strcpy(tmp, " (");
	tmp = out_name + strlen(out_name);
	strcpy(tmp, emu_tag);
	tmp = out_name + strlen(out_name);
	strcpy(tmp, ")");
}

static void Directory_index(Directory* self) {
	int is_collection = prefixMatch(COLLECTIONS_PATH, self->path);
	int skip_index = exactMatch(FAUX_RECENT_PATH, self->path) || is_collection; // not alphabetized
	
	Hash* map = NULL;
	char map_path[256];
	sprintf(map_path, "%s/map.txt", is_collection ? COLLECTIONS_PATH : self->path);
	if (exists(map_path)) {
		FILE* file = fopen(map_path, "r");
		if (file) {
			map = Hash_new();
			char line[256];
			while (fgets(line,256,file)!=NULL) {
				normalizeNewline(line);
				trimTrailingNewlines(line);
				if (strlen(line)==0) continue; // skip empty lines

				char* tmp = strchr(line,'\t');
				if (tmp) {
					tmp[0] = '\0';
					char* key = line;
					char* value = tmp+1;
					Hash_set(map, key, value);
				}
			}
			fclose(file);
			
			int resort = 0;
			int filter = 0;
			for (int i=0; i<self->entries->count; i++) {
				Entry* entry = self->entries->items[i];
				char* filename = strrchr(entry->path, '/')+1;
				char* alias = Hash_get(map, filename);
				if (alias) {
					free(entry->name);
					entry->name = strdup(alias);
					resort = 1;
					if (!filter && hide(entry->name)) filter = 1;
				}
			}
			
			if (filter) {
				Array* entries = Array_new();
				for (int i=0; i<self->entries->count; i++) {
					Entry* entry = self->entries->items[i];
					if (hide(entry->name)) {
						Entry_free(entry);
					}
					else {
						Array_push(entries, entry);
					}
				}
				Array_free(self->entries); // not EntryArray_free because we've just moved the entries from the original to the filtered one!
				self->entries = entries;
			}
			if (resort) EntryArray_sort(self->entries);
		}
	}
	
	Entry* prior = NULL;
	int alpha = -1;
	int index = 0;
	for (int i=0; i<self->entries->count; i++) {
		Entry* entry = self->entries->items[i];
		if (map) {
			char* filename = strrchr(entry->path, '/')+1;
			char* alias = Hash_get(map, filename);
			if (alias) {
				free(entry->name);
				entry->name = strdup(alias);
			}
		}
		
		if (prior!=NULL && exactMatch(prior->name, entry->name)) {
			if (prior->unique) free(prior->unique);
			if (entry->unique) free(entry->unique);
			
			char* prior_filename = strrchr(prior->path, '/')+1;
			char* entry_filename = strrchr(entry->path, '/')+1;
			if (exactMatch(prior_filename, entry_filename)) {
				char prior_unique[256];
				char entry_unique[256];
				getUniqueName(prior, prior_unique);
				getUniqueName(entry, entry_unique);
				
				prior->unique = strdup(prior_unique);
				entry->unique = strdup(entry_unique);
			}
			else {
				prior->unique = strdup(prior_filename);
				entry->unique = strdup(entry_filename);
			}
		}

		if (!skip_index) {
			int a = getIndexChar(entry->name);
			if (a!=alpha) {
				index = self->alphas->count;
				IntArray_push(self->alphas, i);
				alpha = a;
			}
			entry->alpha = index;
		}
		
		prior = entry;
	}
	
	if (map) Hash_free(map);
}

static Array* getRoot(void);
static Array* getRecents(void);
static Array* getCollection(char* path);
static Array* getDiscs(char* path);
static Array* getEntries(char* path);

static Directory* Directory_new(char* path, int selected) {
	char display_name[256];
	getDisplayName(path, display_name);
	
	Directory* self = malloc(sizeof(Directory));
	self->path = strdup(path);
	self->name = strdup(display_name);
	if (exactMatch(path, SDCARD_PATH)) {
		self->entries = getRoot();
	}
	else if (exactMatch(path, FAUX_RECENT_PATH)) {
		self->entries = getRecents();
	}
	else if (!exactMatch(path, COLLECTIONS_PATH) && prefixMatch(COLLECTIONS_PATH, path) && suffixMatch(".txt", path)) {
		self->entries = getCollection(path);
	}
	else if (suffixMatch(".m3u", path)) {
		self->entries = getDiscs(path);
	}
	else {
		self->entries = getEntries(path);
	}
	self->alphas = IntArray_new();
	self->selected = selected;
	Directory_index(self);
	return self;
}
static void Directory_free(Directory* self) {
	free(self->path);
	free(self->name);
	EntryArray_free(self->entries);
	IntArray_free(self->alphas);
	free(self);
}

static void DirectoryArray_pop(Array* self) {
	Directory_free(Array_pop(self));
}
static void DirectoryArray_free(Array* self) {
	for (int i=0; i<self->count; i++) {
		Directory_free(self->items[i]);
	}
	Array_free(self);
}

///////////////////////////////////////

typedef struct Recent {
	char* path; // NOTE: this is without the SDCARD_PATH prefix!
	char* alias;
	int available;
} Recent;
 // yiiikes
static char* recent_alias = NULL;

static int hasEmu(char* emu_name);
static Recent* Recent_new(char* path, char* alias) {
	Recent* self = malloc(sizeof(Recent));

	char sd_path[256]; // only need to get emu name
	sprintf(sd_path, "%s%s", SDCARD_PATH, path);

	char emu_name[256];
	getEmuName(sd_path, emu_name);
	
	self->path = strdup(path);
	self->alias = alias ? strdup(alias) : NULL;
	self->available = hasEmu(emu_name);
	return self;
}
static void Recent_free(Recent* self) {
	free(self->path);
	if (self->alias) free(self->alias);
	free(self);
}

static int RecentArray_indexOf(Array* self, char* str) {
	for (int i=0; i<self->count; i++) {
		Recent* item = self->items[i];
		if (exactMatch(item->path, str)) return i;
	}
	return -1;
}
static void RecentArray_free(Array* self) {
	for (int i=0; i<self->count; i++) {
		Recent_free(self->items[i]);
	}
	Array_free(self);
}

///////////////////////////////////////

static Directory* top;
static Array* stack; // DirectoryArray
static Array* recents; // RecentArray

static int quit = 0;
static int can_resume = 0;
static int should_resume = 0; // set to 1 on BTN_RESUME but only if can_resume==1
static int simple_mode = 0;
static char slot_path[256];

static int restore_depth = -1;
static int restore_relative = -1;
static int restore_selected = 0;
static int restore_start = 0;
static int restore_end = 0;

///////////////////////////////////////

#define MAX_RECENTS 24 // a multiple of all menu rows
static int recentFooterCompact(int width) {
	// Two two-button pills plus a gap. Keep the new shortcut visible on narrow panels.
	return GFX_getButtonWidth("CLEAR", "Y") + GFX_getButtonWidth("RESUME", "X")
		+ GFX_getButtonWidth("BACK", "B") + GFX_getButtonWidth("OPEN", "A")
		+ SCALE1(BUTTON_MARGIN)*7 + SCALE1(PADDING)*2 > width;
}

static void openDirectory(char* path, int auto_launch); // defined below; clearRecents rebuilds the root
static int clearRecents(void) {
	if (!exactMatch(top->path, FAUX_RECENT_PATH)) return 0;
	// Only forget history after the on-card operation succeeds. Never touch ROMs or saves.
	if (unlink(RECENT_PATH) != 0 && errno != ENOENT) return 0;
	while (recents->count) Recent_free(Array_pop(recents));
	recent_alias = NULL;
	can_resume = should_resume = 0;
	restore_depth = restore_relative = -1;
	restore_selected = restore_start = restore_end = 0;
	// Return to a FRESHLY BUILT main menu rather than sitting in an empty history list: getRoot()
	// omits Recently Played now that hasRecents() is false, so the row disappears immediately
	// instead of lingering until the next ordinary root rebuild (Dan, 2026-09-07).
	// Drop the whole stack (DirectoryArray_pop frees each Directory) and re-open the root; top is
	// cleared first because openDirectory reads it when deciding whether to restore a selection.
	while (stack->count>0) DirectoryArray_pop(stack);
	top = NULL;
	openDirectory(SDCARD_PATH, 0);
	return 1;
}

static void saveRecents(void) {
	FILE* file = fopen(RECENT_PATH, "w");
	if (file) {
		for (int i=0; i<recents->count; i++) {
			Recent* recent = recents->items[i];
			fputs(recent->path, file);
			if (recent->alias) {
				fputs("\t", file);
				fputs(recent->alias, file);
			}
			putc('\n', file);
		}
		fclose(file);
	}
}
static void addRecent(char* path, char* alias) {
	if (flagExists(NO_RECENTS_PATH)) return; // opted out: permanent means we stop recording, not just hiding
	path += strlen(SDCARD_PATH); // makes paths platform agnostic
	int id = RecentArray_indexOf(recents, path);
	if (id==-1) { // add
		while (recents->count>=MAX_RECENTS) {
			Recent_free(Array_pop(recents));
		}
		Array_unshift(recents, Recent_new(path, alias));
	}
	else if (id>0) { // bump to top
		for (int i=id; i>0; i--) {
			void* tmp = recents->items[i-1];
			recents->items[i-1] = recents->items[i];
			recents->items[i] = tmp;
		}
	}
	saveRecents();
}

static int hasEmu(char* emu_name) {
	char pak_path[256];
	sprintf(pak_path, "%s/Emus/%s.pak/launch.sh", PAKS_PATH, emu_name);
	if (exists(pak_path)) return 1;

	sprintf(pak_path, "%s/Emus/%s/%s.pak/launch.sh", SDCARD_PATH, PLATFORM, emu_name);
	if (exists(pak_path)) return 1;
#ifdef PLATFORM_ALIAS
	// see getEmuPath (utils.c): also honour the platform folder name the community publishes under
	sprintf(pak_path, "%s/Emus/%s/%s.pak/launch.sh", SDCARD_PATH, PLATFORM_ALIAS, emu_name);
	if (exists(pak_path)) return 1;
#endif
	return 0;
}
static int hasCue(char* dir_path, char* cue_path) { // NOTE: dir_path not rom_path
	char* tmp = strrchr(dir_path, '/') + 1; // folder name
	sprintf(cue_path, "%s/%s.cue", dir_path, tmp);
	return exists(cue_path);
}
static int hasM3u(char* rom_path, char* m3u_path) { // NOTE: rom_path not dir_path
	char* tmp;
	
	strcpy(m3u_path, rom_path);
	tmp = strrchr(m3u_path, '/') + 1;
	tmp[0] = '\0';
	
	// path to parent directory
	char base_path[256];
	strcpy(base_path, m3u_path);
	
	tmp = strrchr(m3u_path, '/');
	tmp[0] = '\0';
	
	// get parent directory name
	char dir_name[256];
	tmp = strrchr(m3u_path, '/');
	strcpy(dir_name, tmp);
	
	// dir_name is also our m3u file name
	tmp = m3u_path + strlen(m3u_path); 
	strcpy(tmp, dir_name);

	// add extension
	tmp = m3u_path + strlen(m3u_path);
	strcpy(tmp, ".m3u");
	
	return exists(m3u_path);
}

static int hasRecents(void) {
	if (flagExists(NO_RECENTS_PATH)) return 0; // opted out: no entry, and nothing is ever read
	LOG_info("hasRecents %s\n", RECENT_PATH);
	int has = 0;
	
	Array* parent_paths = Array_new();
	if (exists(CHANGE_DISC_PATH)) {
		char sd_path[256];
		getFile(CHANGE_DISC_PATH, sd_path, 256);
		if (exists(sd_path)) {
			char* disc_path = sd_path + strlen(SDCARD_PATH); // makes path platform agnostic
			Recent* recent = Recent_new(disc_path, NULL);
			if (recent->available) has += 1;
			Array_push(recents, recent);
		
			char parent_path[256];
			strcpy(parent_path, disc_path);
			char* tmp = strrchr(parent_path, '/') + 1;
			tmp[0] = '\0';
			Array_push(parent_paths, strdup(parent_path));
		}
		unlink(CHANGE_DISC_PATH);
	}
	
	FILE* file = fopen(RECENT_PATH, "r"); // newest at top
	if (file) {
		char line[256];
		while (fgets(line,256,file)!=NULL) {
			normalizeNewline(line);
			trimTrailingNewlines(line);
			if (strlen(line)==0) continue; // skip empty lines
			
			// LOG_info("line: %s\n", line);
			
			char* path = line;
			char* alias = NULL;
			char* tmp = strchr(line,'\t');
			if (tmp) {
				tmp[0] = '\0';
				alias = tmp+1;
			}
			
			char sd_path[256];
			sprintf(sd_path, "%s%s", SDCARD_PATH, path);
			if (exists(sd_path)) {
				if (recents->count<MAX_RECENTS) {
					// this logic replaces an existing disc from a multi-disc game with the last used
					char m3u_path[256];
					if (hasM3u(sd_path, m3u_path)) { // TODO: this might tank launch speed
						char parent_path[256];
						strcpy(parent_path, path);
						char* tmp = strrchr(parent_path, '/') + 1;
						tmp[0] = '\0';
						
						int found = 0;
						for (int i=0; i<parent_paths->count; i++) {
							char* path = parent_paths->items[i];
							if (prefixMatch(path, parent_path)) {
								found = 1;
								break;
							}
						}
						if (found) continue;
						
						Array_push(parent_paths, strdup(parent_path));
					}
					
					// LOG_info("path:%s alias:%s\n", path, alias);
					
					Recent* recent = Recent_new(path, alias);
					if (recent->available) has += 1;
					Array_push(recents, recent);
				}
			}
		}
		fclose(file);
	}
	
	saveRecents();
	
	StringArray_free(parent_paths);
	return has>0;
}
static int hasCollections(void) {
	int has = 0;
	if (!exists(COLLECTIONS_PATH)) return has;
	
	DIR *dh = opendir(COLLECTIONS_PATH);
	struct dirent *dp;
	while((dp = readdir(dh)) != NULL) {
		if (hide(dp->d_name)) continue;
		has = 1;
		break;
	}
	closedir(dh);
	return has;
}
static int hasRoms(char* dir_name) {
	int has = 0;
	char emu_name[256];
	char rom_path[256];

	getEmuName(dir_name, emu_name);
	
	// check for emu pak
	if (!hasEmu(emu_name)) return has;
	
	// check for at least one non-hidden file (we're going to assume it's a rom)
	sprintf(rom_path, "%s/%s/", ROMS_PATH, dir_name);
	DIR *dh = opendir(rom_path);
	if (dh!=NULL) {
		struct dirent *dp;
		while((dp = readdir(dh)) != NULL) {
			if (hide(dp->d_name)) continue;
			has = 1;
			break;
		}
		closedir(dh);
	}
	// if (!has) printf("No roms for %s!\n", dir_name);
	return has;
}
static Array* getRoot(void) {
	Array* root = Array_new();
	
	if (hasRecents()) Array_push(root, Entry_new(FAUX_RECENT_PATH, ENTRY_DIR));
	
	Array* entries = Array_new();
	DIR* dh = opendir(ROMS_PATH);
	if (dh!=NULL) {
		struct dirent *dp;
		char* tmp;
		char full_path[256];
		sprintf(full_path, "%s/", ROMS_PATH);
		tmp = full_path + strlen(full_path);
		Array* emus = Array_new();
		while((dp = readdir(dh)) != NULL) {
			if (hide(dp->d_name)) continue;
			if (hasRoms(dp->d_name)) {
				strcpy(tmp, dp->d_name);
				Array_push(emus, Entry_new(full_path, ENTRY_DIR));
			}
		}
		EntryArray_sort(emus);
		Entry* prev_entry = NULL;
		for (int i=0; i<emus->count; i++) {
			Entry* entry = emus->items[i];
			if (prev_entry!=NULL) {
				if (exactMatch(prev_entry->name, entry->name)) {
					Entry_free(entry);
					continue;
				}
			}
			Array_push(entries, entry);
			prev_entry = entry;
		}
		Array_free(emus); // just free the array part, entries now owns emus entries
		closedir(dh);
	}
	
	// copied/modded from Directory_index
	// we don't support hidden remaps here
	char map_path[256];
	sprintf(map_path, "%s/map.txt", ROMS_PATH);
	if (entries->count>0 && exists(map_path)) {
		FILE* file = fopen(map_path, "r");
		if (file) {
			Hash* map = Hash_new();
			char line[256];
			while (fgets(line,256,file)!=NULL) {
				normalizeNewline(line);
				trimTrailingNewlines(line);
				if (strlen(line)==0) continue; // skip empty lines

				char* tmp = strchr(line,'\t');
				if (tmp) {
					tmp[0] = '\0';
					char* key = line;
					char* value = tmp+1;
					Hash_set(map, key, value);
				}
			}
			fclose(file);
			
			int resort = 0;
			for (int i=0; i<entries->count; i++) {
				Entry* entry = entries->items[i];
				char* filename = strrchr(entry->path, '/')+1;
				char* alias = Hash_get(map, filename);
				if (alias) {
					free(entry->name);
					entry->name = strdup(alias);
					resort = 1;
				}
			} 
			if (resort) EntryArray_sort(entries);
			Hash_free(map);
		}
	}
	
	if (hasCollections()) {
		if (entries->count) Array_push(root, Entry_new(COLLECTIONS_PATH, ENTRY_DIR));
		else { // no visible systems, promote collections to root
			dh = opendir(COLLECTIONS_PATH);
			if (dh!=NULL) {
				struct dirent *dp;
				char* tmp;
				char full_path[256];
				sprintf(full_path, "%s/", COLLECTIONS_PATH);
				tmp = full_path + strlen(full_path);
				Array* collections = Array_new();
				while((dp = readdir(dh)) != NULL) {
					if (hide(dp->d_name)) continue;
					strcpy(tmp, dp->d_name);
					Array_push(collections, Entry_new(full_path, ENTRY_DIR)); // yes, collections are fake directories
				}
				EntryArray_sort(collections);
				for (int i=0; i<collections->count; i++) {
					Array_push(entries, collections->items[i]);
				}
				Array_free(collections); // just free the array part, entries now owns collections entries
				closedir(dh);
			}
		}
	}
	
	// add systems to root
	for (int i=0; i<entries->count; i++) {
		Array_push(root, entries->items[i]);
	}
	Array_free(entries); // root now owns entries' entries
	
	// hide-tools.txt hides Tools from the list like simple mode, but leaves an owner escape
	// hatch: the L1+R1+SELECT combo at root opens Tools directly (handled in the main loop).
	int hide_tools = flagExists(HIDE_TOOLS_PATH);
	char* tools_path = SDCARD_PATH "/Tools/" PLATFORM;
	if (exists(tools_path) && !simple_mode && !hide_tools) Array_push(root, Entry_new(tools_path, ENTRY_DIR));
#ifdef PLATFORM_ALIAS
	// community Tools paks publish under the scene's platform name (see getEmuPath, utils.c)
	char* tools_alias_path = SDCARD_PATH "/Tools/" PLATFORM_ALIAS;
	if (exists(tools_alias_path) && !simple_mode && !hide_tools) Array_push(root, Entry_new(tools_alias_path, ENTRY_DIR));
#endif
	
	return root;
}
static Array* getRecents(void) {
	Array* entries = Array_new();
	for (int i=0; i<recents->count; i++) {
		Recent* recent = recents->items[i];
		if (!recent->available) continue;
		
		char sd_path[256];
		sprintf(sd_path, "%s%s", SDCARD_PATH, recent->path);
		int type = suffixMatch(".pak", sd_path) ? ENTRY_PAK : ENTRY_ROM; // ???
		Entry* entry = Entry_new(sd_path, type);
		if (recent->alias) {
			free(entry->name);
			entry->name = strdup(recent->alias);
		}
		Array_push(entries, entry);
	}
	return entries;
}
static Array* getCollection(char* path) {
	Array* entries = Array_new();
	FILE* file = fopen(path, "r");
	if (file) {
		char line[256];
		while (fgets(line,256,file)!=NULL) {
			normalizeNewline(line);
			trimTrailingNewlines(line);
			if (strlen(line)==0) continue; // skip empty lines
			
			char sd_path[256];
			sprintf(sd_path, "%s%s", SDCARD_PATH, line);
			if (exists(sd_path)) {
				int type = suffixMatch(".pak", sd_path) ? ENTRY_PAK : ENTRY_ROM; // ???
				Array_push(entries, Entry_new(sd_path, type));
				
				// char emu_name[256];
				// getEmuName(sd_path, emu_name);
				// if (hasEmu(emu_name)) {
					// Array_push(entries, Entry_new(sd_path, ENTRY_ROM));
				// }
			}
		}
		fclose(file);
	}
	return entries;
}
static Array* getDiscs(char* path){
	
	// TODO: does path have SDCARD_PATH prefix?
	
	Array* entries = Array_new();
	
	char base_path[256];
	strcpy(base_path, path);
	char* tmp = strrchr(base_path, '/') + 1;
	tmp[0] = '\0';
	
	// TODO: limit number of discs supported (to 9?)
	FILE* file = fopen(path, "r");
	if (file) {
		char line[256];
		int disc = 0;
		while (fgets(line,256,file)!=NULL) {
			normalizeNewline(line);
			trimTrailingNewlines(line);
			if (strlen(line)==0) continue; // skip empty lines
			
			char disc_path[256];
			sprintf(disc_path, "%s%s", base_path, line);
						
			if (exists(disc_path)) {
				disc += 1;
				Entry* entry = Entry_new(disc_path, ENTRY_ROM);
				free(entry->name);
				char name[16];
				sprintf(name, "Disc %i", disc);
				entry->name = strdup(name);
				Array_push(entries, entry);
			}
		}
		fclose(file);
	}
	return entries;
}
static int getFirstDisc(char* m3u_path, char* disc_path) { // based on getDiscs() natch
	int found = 0;

	char base_path[256];
	strcpy(base_path, m3u_path);
	char* tmp = strrchr(base_path, '/') + 1;
	tmp[0] = '\0';
	
	FILE* file = fopen(m3u_path, "r");
	if (file) {
		char line[256];
		while (fgets(line,256,file)!=NULL) {
			normalizeNewline(line);
			trimTrailingNewlines(line);
			if (strlen(line)==0) continue; // skip empty lines
			
			sprintf(disc_path, "%s%s", base_path, line);
						
			if (exists(disc_path)) found = 1;
			break;
		}
		fclose(file);
	}
	return found;
}

static void addEntries(Array* entries, char* path) {
	DIR *dh = opendir(path);
	if (dh!=NULL) {
		struct dirent *dp;
		char* tmp;
		char full_path[256];
		sprintf(full_path, "%s/", path);
		tmp = full_path + strlen(full_path);
		while((dp = readdir(dh)) != NULL) {
			if (hide(dp->d_name)) continue;
			strcpy(tmp, dp->d_name);
			int is_dir = dp->d_type==DT_DIR;
			int type;
			if (is_dir) {
				// TODO: this should make sure launch.sh exists
				if (suffixMatch(".pak", dp->d_name)) {
					type = ENTRY_PAK;
				}
				else {
					type = ENTRY_DIR;
				}
			}
			else {
				if (prefixMatch(COLLECTIONS_PATH, full_path)) {
					type = ENTRY_DIR; // :shrug:
				}
				else {
					type = ENTRY_ROM;
				}
			}
			Array_push(entries, Entry_new(full_path, type));
		}
		closedir(dh);
	}
}

static int isConsoleDir(char* path) {
	char* tmp;
	char parent_dir[256];
	strcpy(parent_dir, path);
	tmp = strrchr(parent_dir, '/');
	tmp[0] = '\0';
	
	return exactMatch(parent_dir, ROMS_PATH);
}

static Array* getEntries(char* path){
	Array* entries = Array_new();

	if (isConsoleDir(path)) { // top-level console folder, might collate
		char collated_path[256];
		strcpy(collated_path, path);
		char* tmp = strrchr(collated_path, '(');
		// 1 because we want to keep the opening parenthesis to avoid collating "Game Boy Color" and "Game Boy Advance" into "Game Boy"
		// but conditional so we can continue to support a bare tag name as a folder name
		if (tmp) tmp[1] = '\0'; 
		
		DIR *dh = opendir(ROMS_PATH);
		if (dh!=NULL) {
			struct dirent *dp;
			char full_path[256];
			sprintf(full_path, "%s/", ROMS_PATH);
			tmp = full_path + strlen(full_path);
			// while loop so we can collate paths, see above
			while((dp = readdir(dh)) != NULL) {
				if (hide(dp->d_name)) continue;
				if (dp->d_type!=DT_DIR) continue;
				strcpy(tmp, dp->d_name);
			
				if (!prefixMatch(collated_path, full_path)) continue;
				addEntries(entries, full_path);
			}
			closedir(dh);
		}
	}
	else addEntries(entries, path); // just a subfolder
	
	EntryArray_sort(entries);
	return entries;
}

///////////////////////////////////////

// Set once in main() after GFX_init. queueNext lives far from main and still needs to put a
// frame on the panel before the process hands over to the emulator.
static SDL_Surface* ui_screen = NULL;
// Warm the emulator core into the page cache as soon as we know which system the user is looking
// at, so the bytes are already in RAM when they press A. MEASURED on h700 2026-08-10: the same
// game launches in 707ms warm vs 4348ms cold, and core_open alone is 513ms cold vs 216ms warm.
// This is pure readahead: no process stays resident and the kernel can evict it under pressure,
// so it costs nothing the thesis cares about (power, heat, resident memory).
static void prefetchCore(char* emu_name) {
	static char last[64] = "";
	if (!emu_name || !emu_name[0]) return;
	if (exactMatch(last, emu_name)) return;   // already warmed this one
	strncpy(last, emu_name, sizeof(last)-1); last[sizeof(last)-1] = '\0';

	char pak_path[256];
	getEmuPath(emu_name, pak_path);
	FILE* f = fopen(pak_path, "r");
	if (!f) return;
	// The core is named in the pak: either `EMU_EXE=<core>` (standard boilerplate) or an inline
	// `<core>_libretro.so` argument (the h700 paks). Accept both.
	char line[512], core[128] = "";
	while (fgets(line, sizeof(line), f)) {
		char* m = strstr(line, "_libretro.so");
		if (m) {
			char* start = m;
			while (start > line && (isalnum((unsigned char)start[-1]) || start[-1]=='_' || start[-1]=='-')) start--;
			size_t n = (size_t)(m - start);
			if (n && n < sizeof(core)-16) { memcpy(core, start, n); core[n] = '\0'; }
			break;
		}
		if (!strncmp(line, "EMU_EXE=", 8)) {
			char* v = line + 8;
			char* nl = strpbrk(v, " \t\r\n");
			if (nl) *nl = '\0';
			if (v[0]) snprintf(core, sizeof(core), "%s", v);
		}
	}
	fclose(f);
	if (!core[0]) return;

	// CORES_PATH is an environment variable (set by the frontend/pak), not a compile-time define.
	const char* cores_dir = getenv("CORES_PATH");
	if (!cores_dir || !cores_dir[0]) cores_dir = SYSTEM_PATH "/cores";
	char core_path[512];
	snprintf(core_path, sizeof(core_path), "%s/%s_libretro.so", cores_dir, core);
	// Read it in the background: a plain read is what actually populates the page cache, and doing
	// it inline would stall the UI for the very time we are trying to hide.
	char cmd[640];
	snprintf(cmd, sizeof(cmd), "(cat '%s' > /dev/null 2>&1 &) &", core_path);
	if (exists(core_path)) system(cmd);
}
static void queueNext(char* cmd) {
	LOG_info("cmd: %s\n", cmd);
	// NOTE: no transition frame here on purpose. This briefly cleared the panel (and before that
	// printed "Loading") to prove the button had registered, which was right when a launch cost
	// over a second. Removing the real cost changed the answer: the launcher is now ~57ms and a
	// game arrives in roughly half a second, so blanking the screen IS the artifact -- it reads as
	// a flash between two frames that would otherwise follow each other closely (Dan 2026-08-10).
	// Leave the menu on screen; the game's first frame replaces it.
	putFile("/tmp/next", cmd);
	quit = 1;
}

// Wrap a string in single quotes for /bin/sh, rewriting each embedded apostrophe as '\''.
// Writes to a SEPARATE destination and returns 0 rather than overrunning it.
//
// This replaces an in-place expansion that could corrupt the stack. The old escapeSingleQuotes()
// grew the string where it sat — one apostrophe became four characters, shifting the tail RIGHT —
// inside a fixed char[256] path buffer that knew nothing about the growth. The result was then
// sprintf'd as "'%s' '%s'" into ANOTHER char[256], so two long paths overflowed it on their own,
// apostrophes or not. Both are reachable from ordinary ROM names: a deep folder plus something
// like "Tony Hawk's Pro Skater (USA).bin" is a long path that also contains apostrophes.
//
// Callers MUST check the return value. Refusing to launch is the correct failure here — the
// alternative is a corrupted command string, or smashed stack, at the moment we hand control off.
static int shellQuote(const char* in, char* out, size_t out_sz) {
	size_t o = 0;
	if (out_sz < 3) return 0;
	out[o++] = '\'';
	for (const char* p = in; *p; p++) {
		if (*p == '\'') {
			// close quote, escaped literal apostrophe, reopen quote
			if (o + 4 + 1 > out_sz) return 0;
			out[o++] = '\''; out[o++] = '\\'; out[o++] = '\''; out[o++] = '\'';
		}
		else {
			if (o + 1 + 1 > out_sz) return 0;
			out[o++] = *p;
		}
	}
	if (o + 1 + 1 > out_sz) return 0;
	out[o++] = '\'';
	out[o] = '\0';
	return 1;
}

// Worst case: every character of a 255-char path is an apostrophe (4x) plus the two wrapping
// quotes. Sized so shellQuote never fails on any path that fits the char[256] buffers used here.
#define QUOTED_MAX (255 * 4 + 3)
#define CMD_MAX    (QUOTED_MAX * 2 + 2)

///////////////////////////////////////

static void readyResumePath(char* rom_path, int type) {
	char* tmp;
	can_resume = 0;
	char path[256];
	strcpy(path, rom_path);
	
	if (!prefixMatch(ROMS_PATH, path)) return;
	
	char auto_path[256];
	if (type==ENTRY_DIR) {
		if (!hasCue(path, auto_path)) { // no cue?
			tmp = strrchr(auto_path, '.') + 1; // extension
			strcpy(tmp, "m3u"); // replace with m3u
			if (!exists(auto_path)) return; // no m3u
		}
		strcpy(path, auto_path); // cue or m3u if one exists
	}
	
	if (!suffixMatch(".m3u", path)) {
		char m3u_path[256];
		if (hasM3u(path, m3u_path)) {
			// change path to m3u path
			strcpy(path, m3u_path);
		}
	}
	
	char emu_name[256];
	getEmuName(path, emu_name);
	
	char rom_file[256];
	tmp = strrchr(path, '/') + 1;
	strcpy(rom_file, tmp);
	
	sprintf(slot_path, "%s/.minui/%s/%s.txt", SHARED_USERDATA_PATH, emu_name, rom_file); // /.userdata/.minui/<EMU>/<romname>.ext.txt
	
	can_resume = exists(slot_path);
}
static void readyResume(Entry* entry) {
	readyResumePath(entry->path, entry->type);
}

static void saveLast(char* path);
static void loadLast(void);

static int autoResume(void) {
	// NOTE: bypasses recents

	if (!exists(AUTO_RESUME_PATH)) return 0;
	
	char path[256];
	getFile(AUTO_RESUME_PATH, path, 256);
	unlink(AUTO_RESUME_PATH);
	sync();
	
	// make sure rom still exists
	char sd_path[256];
	sprintf(sd_path, "%s%s", SDCARD_PATH, path);
	if (!exists(sd_path)) return 0;
	
	// make sure emu still exists
	char emu_name[256];
	getEmuName(sd_path, emu_name);
	
	char emu_path[256];
	getEmuPath(emu_name, emu_path);
	
	if (!exists(emu_path)) return 0;
	
	// putFile(LAST_PATH, FAUX_RECENT_PATH); // saveLast() will crash here because top is NULL
	
	char q_emu[QUOTED_MAX], q_rom[QUOTED_MAX];
	if (!shellQuote(emu_path, q_emu, sizeof(q_emu)) || !shellQuote(sd_path, q_rom, sizeof(q_rom))) {
		LOG_info("autoResume: path too long to quote, refusing to launch: %s\n", sd_path);
		return 0;
	}
	char cmd[CMD_MAX];
	snprintf(cmd, sizeof(cmd), "%s %s", q_emu, q_rom);
	putInt(RESUME_SLOT_PATH, AUTO_RESUME_SLOT);
	queueNext(cmd);
	return 1;
}

static void openPak(char* path) {
	if (prefixMatch(ROMS_PATH, path)) {
		addRecent(path, NULL);
	}
	saveLast(path);

	// Quote the FULL launcher path, not the directory with "/launch.sh" appended outside the
	// quotes — otherwise the suffix sits outside the escaping the rest of the path relies on.
	char full[512];
	snprintf(full, sizeof(full), "%s/launch.sh", path);
	char cmd[QUOTED_MAX];
	if (!shellQuote(full, cmd, sizeof(cmd))) {
		LOG_info("openPak: path too long to quote, refusing to launch: %s\n", path);
		return;
	}
	queueNext(cmd);
}
static void openRom(char* path, char* last) {
	LOG_info("openRom(%s,%s)\n", path, last);
	
	char sd_path[256];
	strcpy(sd_path, path);
	
	char m3u_path[256];
	int has_m3u = hasM3u(sd_path, m3u_path);
	
	char recent_path[256];
	strcpy(recent_path, has_m3u ? m3u_path : sd_path);
	
	if (has_m3u && suffixMatch(".m3u", sd_path)) {
		getFirstDisc(m3u_path, sd_path);
	}

	char emu_name[256];
	getEmuName(sd_path, emu_name);

	if (should_resume) {
		char slot[16];
		getFile(slot_path, slot, 16);
		putFile(RESUME_SLOT_PATH, slot);
		should_resume = 0;

		if (has_m3u) {
			char rom_file[256];
			strcpy(rom_file, strrchr(m3u_path, '/') + 1);
			
			// get disc for state
			char disc_path_path[256];
			sprintf(disc_path_path, "%s/.minui/%s/%s.%s.txt", SHARED_USERDATA_PATH, emu_name, rom_file, slot); // /.userdata/arm-480/.minui/<EMU>/<romname>.ext.0.txt

			if (exists(disc_path_path)) {
				// switch to disc path
				char disc_path[256];
				getFile(disc_path_path, disc_path, 256);
				if (disc_path[0]=='/') strcpy(sd_path, disc_path); // absolute
				else { // relative
					strcpy(sd_path, m3u_path);
					char* tmp = strrchr(sd_path, '/') + 1;
					strcpy(tmp, disc_path);
				}
			}
		}
	}
	else putInt(RESUME_SLOT_PATH,8); // resume hidden default state
	
	char emu_path[256];
	getEmuPath(emu_name, emu_path);
	
	addRecent(recent_path, recent_alias); // yiiikes
	saveLast(last==NULL ? sd_path : last);

	char q_emu[QUOTED_MAX], q_rom[QUOTED_MAX];
	if (!shellQuote(emu_path, q_emu, sizeof(q_emu)) || !shellQuote(sd_path, q_rom, sizeof(q_rom))) {
		LOG_info("openRom: path too long to quote, refusing to launch: %s\n", sd_path);
		return;
	}
	char cmd[CMD_MAX];
	snprintf(cmd, sizeof(cmd), "%s %s", q_emu, q_rom);
	queueNext(cmd);
}
static void openDirectory(char* path, int auto_launch) {
	{ // warm this system's core while the user browses (see prefetchCore)
		char emu_tag[256]; getEmuName(path, emu_tag);
		if (emu_tag[0]) prefetchCore(emu_tag);
	}
	char auto_path[256];
	if (hasCue(path, auto_path) && auto_launch) {
		openRom(auto_path, path);
		return;
	}

	char m3u_path[256];
	strcpy(m3u_path, auto_path);
	char* tmp = strrchr(m3u_path, '.') + 1; // extension
	strcpy(tmp, "m3u"); // replace with m3u
	if (exists(m3u_path) && auto_launch) {
		auto_path[0] = '\0';
		if (getFirstDisc(m3u_path, auto_path)) {
			openRom(auto_path, path);
			return;
		}
		// TODO: doesn't handle empty m3u files
	}
	
	int selected = 0;
	int start = selected;
	int end = 0;
	if (top && top->entries->count>0) {
		if (restore_depth==stack->count && top->selected==restore_relative) {
			selected = restore_selected;
			start = restore_start;
			end = restore_end;
		}
	}
	
	top = Directory_new(path, selected);
	top->start = start;
	top->end = end ? end : ((top->entries->count<MAIN_ROW_COUNT) ? top->entries->count : MAIN_ROW_COUNT);

	Array_push(stack, top);
}
static void closeDirectory(void) {
	restore_selected = top->selected;
	restore_start = top->start;
	restore_end = top->end;
	DirectoryArray_pop(stack);
	restore_depth = stack->count;
	top = stack->items[stack->count-1];
	restore_relative = top->selected;
}

static void Entry_open(Entry* self) {
	recent_alias = self->name;  // yiiikes
	if (self->type==ENTRY_ROM) {
		char *last = NULL;
		if (prefixMatch(COLLECTIONS_PATH, top->path)) {
			char* tmp;
			char filename[256];
			
			tmp = strrchr(self->path, '/');
			if (tmp) strcpy(filename, tmp+1);
			
			char last_path[256];
			sprintf(last_path, "%s/%s", top->path, filename);
			last = last_path;
		}
		openRom(self->path, last);
	}
	else if (self->type==ENTRY_PAK) {
		openPak(self->path);
	}
	else if (self->type==ENTRY_DIR) {
		openDirectory(self->path, 1);
	}
}

///////////////////////////////////////

static void saveLast(char* path) {
	// special case for recently played
	if (exactMatch(top->path, FAUX_RECENT_PATH)) {
		// NOTE: that we don't have to save the file because
		// your most recently played game will always be at
		// the top which is also the default selection
		path = FAUX_RECENT_PATH;
	}
	putFile(LAST_PATH, path);
}
static void loadLast(void) { // call after loading root directory
	if (!exists(LAST_PATH)) return;

	char last_path[256];
	getFile(LAST_PATH, last_path, 256);
	
	char full_path[256];
	strcpy(full_path, last_path);
	
	char* tmp;
	char filename[256];
	tmp = strrchr(last_path, '/');
	if (tmp) strcpy(filename, tmp);
	
	Array* last = Array_new();
	while (!exactMatch(last_path, SDCARD_PATH)) {
		Array_push(last, strdup(last_path));
		
		char* slash = strrchr(last_path, '/');
		last_path[(slash-last_path)] = '\0';
	}
	
	while (last->count>0) {
		char* path = Array_pop(last);
		if (!exactMatch(path, ROMS_PATH)) { // romsDir is effectively root as far as restoring state after a game
			char collated_path[256];
			collated_path[0] = '\0';
			if (suffixMatch(")", path) && isConsoleDir(path)) {
				strcpy(collated_path, path);
				tmp = strrchr(collated_path, '(');
				if (tmp) tmp[1] = '\0'; // 1 because we want to keep the opening parenthesis to avoid collating "Game Boy Color" and "Game Boy Advance" into "Game Boy"
			}
			
			for (int i=0; i<top->entries->count; i++) {
				Entry* entry = top->entries->items[i];
			
				// NOTE: strlen() is required for collated_path, '\0' wasn't reading as NULL for some reason
				if (exactMatch(entry->path, path) || (strlen(collated_path) && prefixMatch(collated_path, entry->path)) || (prefixMatch(COLLECTIONS_PATH, full_path) && suffixMatch(filename, entry->path))) {
					top->selected = i;
					if (i>=top->end) {
						top->start = i;
						top->end = top->start + MAIN_ROW_COUNT;
						if (top->end>top->entries->count) {
							top->end = top->entries->count;
							top->start = top->end - MAIN_ROW_COUNT;
						}
					}
					if (last->count==0 && !exactMatch(entry->path, FAUX_RECENT_PATH) && !(!exactMatch(entry->path, COLLECTIONS_PATH) && prefixMatch(COLLECTIONS_PATH, entry->path))) break; // don't show contents of auto-launch dirs
				
					if (entry->type==ENTRY_DIR) {
						openDirectory(entry->path, 0);
						break;
					}
				}
			}
		}
		free(path); // we took ownership when we popped it
	}
	
	StringArray_free(last);
}

///////////////////////////////////////

static void Menu_init(void) {
	stack = Array_new(); // array of open Directories
	recents = Array_new();

	openDirectory(SDCARD_PATH, 0);
	loadLast(); // restore state when available
}
static void Menu_quit(void) {
	RecentArray_free(recents);
	DirectoryArray_free(stack);
}

///////////////////////////////////////

// filled rounded rectangle via per-row spans (same technique as confirm's check-circle)
static void fill_rrect(SDL_Surface* dst, int x, int y, int w, int h, int r, uint32_t c) {
	if (r > h/2) r = h/2;
	if (r > w/2) r = w/2;
	for (int row=0; row<h; row++) {
		int inset = 0;
		if (row < r) { float dy = r-row-0.5f; inset = r - (int)sqrtf((float)r*r - dy*dy); }
		else if (row >= h-r) { float dy = row-(h-r)+0.5f; inset = r - (int)sqrtf((float)r*r - dy*dy); }
		SDL_FillRect(dst, &(SDL_Rect){x+inset, y+row, w-2*inset, 1}, c);
	}
}

// Charging screen: while idle on the charger the menu would otherwise stay lit for the
// whole charge (autosleep is disabled while charging). Instead: near-dark screen, big
// battery percentage, refreshed once a minute. Any button (or unplugging) returns.
static void ChargingScreen(SDL_Surface* screen) {
	int old_brightness = GetBrightness();
	SetBrightness(0); // lowest visible step; restored on exit
	uint32_t rendered_at = 0;
	uint32_t entered_at = SDL_GetTicks();
	while (PWR_isCharging()) {
		PAD_poll();
		// NOTE: this loop CONSUMES the button down-edge. PWR_update's manual-sleep test requires
		// having seen POWER go down, so leaving through here used to swallow it and the user had to
		// press POWER twice to sleep. Hand the press back by re-arming the sleep request.
		//
		// On the RELEASE, though, never the press. PLAT_shouldWake wakes on POWER key-UP
		// (api.c, SDL_KEYUP/SDL_JOYBUTTONUP), so requesting sleep while the button is still held
		// means PWR_sleep starts, and the release of that very same press wakes it straight back
		// up. PWR_update's own manual-sleep test keys on `power_released` for exactly this reason.
		// So: swallow the POWER press, then act on its release.
		if (PAD_justReleased(BTN_POWER)) { PWR_requestSleep(); break; }
		// Held: wait for the release above. Delay explicitly — the loop's own SDL_Delay is at the
		// BOTTOM, so a bare `continue` would spin hot for as long as the button is down.
		if (PAD_isPressed(BTN_POWER)) { SDL_Delay(100); continue; }
		if (PAD_anyJustPressed()) break;
		uint32_t now = SDL_GetTicks();
		// after 5 minutes of showing the charge state, hand the device to sleep: charging
		// continues (cooler, and the charger can actually terminate -> green LED); any
		// button wakes back to the menu, and idling there returns here.
		if (now-entered_at >= 300000) { PWR_requestSleep(); break; }
		if (!rendered_at || now-rendered_at>=60000) {
			// The platform answers this. This function used to read axp2202 sysfs paths DIRECTLY
			// — tg5040 hardware detail sitting in shared menu code — so it was correct on the
			// Brick and rendered "..." on every other device. -1 means "no reading available".
			int pct = PLAT_getChargePercent();
			GFX_clear(screen);
			char msg[16];
			if (pct>=0) snprintf(msg, sizeof(msg), "%d%%", pct);
			else snprintf(msg, sizeof(msg), "...");

			// rounded battery (reference: iOS-style): outline ring + rounded nub +
			// proportional rounded fill with a clear gap
			uint32_t white = SDL_MapRGB(screen->format, 0xff,0xff,0xff);
			uint32_t black = SDL_MapRGB(screen->format, 0x00,0x00,0x00);
			int bw = SCALE1(92), bh = SCALE1(44);
			int t  = SCALE1(4);            // stroke
			int r  = bh/5;                 // a touch less rounded
			int bx = (screen->w - bw) / 2;
			int by = (screen->h - bh) / 2 - SCALE1(24);
			fill_rrect(screen, bx, by, bw, bh, r, white);                 // outer
			fill_rrect(screen, bx+t, by+t, bw-2*t, bh-2*t, r-t, black);   // punch the ring
			int nw = SCALE1(5), nh = bh*5/12;
			fill_rrect(screen, bx+bw-SCALE1(1), by+(bh-nh)/2, nw+SCALE1(1), nh, nw/2, white); // nub, attached
			if (pct > 0) {
				int gap = t + SCALE1(3);
				int fw = (bw - 2*gap) * pct / 100;
				int fr = (r-t-SCALE1(1)); if (fr < SCALE1(3)) fr = SCALE1(3);
				if (fw < 2*fr) fw = 2*fr; // keep the fill's corners round at low %
				fill_rrect(screen, bx+gap, by+gap, fw, bh-2*gap, fr, white);
			}
			SDL_Surface* txt = TTF_RenderUTF8_Blended(font.large, msg, COLOR_WHITE);
			if (txt) {
				SDL_BlitSurface(txt, NULL, screen, &(SDL_Rect){(screen->w - txt->w)/2, by + bh + SCALE1(16)});
				SDL_FreeSurface(txt);
			}
			GFX_flip(screen);
			rendered_at = now;
		}
		SDL_Delay(100);
	}
	SetBrightness(old_brightness);
}

int main (int argc, char *argv[]) {
	uint64_t t_ui0 = getMicroseconds();
#define UIMARK(what) do { const char* _e = getenv("ZERO_BOOT_TIMING"); \
		if (_e && _e[0] && _e[0] != '0') LOG_info("ui-timing: %-12s +%llums\n", (what), \
			(unsigned long long)((getMicroseconds()-t_ui0)/1000)); \
	} while (0)
	// OPT-IN boot timing (ZERO_BOOT_TIMING=1). These probes are shared with tg5040 and stdout is
	// redirected to a file on the SD card by MinUI.pak/launch.sh, so shipping them enabled would
	// add SD writes to every launch on the primary platform. Left available, not on.
	const char* bt_env = getenv("ZERO_BOOT_TIMING");
	int boot_timing = (bt_env && bt_env[0] && bt_env[0] != '0');
	if (boot_timing) LOG_info("time from launch to:\n");
	unsigned long main_begin = SDL_GetTicks();
	unsigned long first_draw = 0;
	
	if (autoResume()) return 0; // nothing to do
	
	simple_mode = exists(SIMPLE_MODE_PATH);

	LOG_info("MinUI\n");
	InitSettings();
	UIMARK("settings");
	
	SDL_Surface* screen = GFX_init(MODE_MAIN);
	ui_screen = screen;
	UIMARK("gfx_init");
	if (boot_timing) LOG_info("- graphics init: %lu\n", SDL_GetTicks() - main_begin);
	
	PAD_init();
	if (boot_timing) LOG_info("- input init: %lu\n", SDL_GetTicks() - main_begin);
	
	PWR_init();
	if (!HAS_POWER_BUTTON && !simple_mode) PWR_disableSleep();
	if (boot_timing) LOG_info("- power init: %lu\n", SDL_GetTicks() - main_begin);
	
	SDL_Surface* version = NULL;
	
	Menu_init();
	if (boot_timing) LOG_info("- menu init: %lu\n", SDL_GetTicks() - main_begin);
	
	// now that (most of) the heavy lifting is done, take a load off
	PWR_setCPUSpeed(CPU_SPEED_MENU);
	UIMARK("pre_scan");
	GFX_setVsync(VSYNC_STRICT);

	PAD_reset();
	int dirty = 1;
	int show_version = 0;
	int show_clear = 0; // 1=confirmation, 2=write error
	int show_setting = 0; // 1=brightness,2=volume
	int was_online = PLAT_isOnline();
	
	if (boot_timing) LOG_info("- loop start: %lu\n", SDL_GetTicks() - main_begin);
	while (!quit) {
		GFX_startFrame();
		unsigned long now = SDL_GetTicks();
		
		PAD_poll();

		// devmode screenshot: MENU+SELECT chord (or the /tmp trigger). No-op without a devmode flag.
		GFX_maybeScreenshot(PAD_isPressed(BTN_MENU) && PAD_justPressed(BTN_SELECT));

		int selected = top->selected;
		int total = top->entries->count;
		
		PWR_update(&dirty, &show_setting, NULL, NULL);

		// charging screen: 30s of no input while on the charger
		{
			static uint32_t charge_idle_at = 0;
			static uint32_t charge_last_tick = 0;
			uint32_t charge_now = SDL_GetTicks();
			// Restart the idle countdown across a sleep/resume. PWR_update above can sleep for
			// minutes or hours, and SDL_GetTicks advances by the WHOLE sleep — so on wake the idle
			// timer reads as long expired and the charge screen re-opens before the menu is ever
			// drawn. The user then has to press a SECOND time to reach the menu, which is the
			// opposite of this block's contract ("any button wakes back to the menu, and idling
			// there returns here"). Reported on-device 2026-07-31 while charging.
			// The wake press cannot serve as the reset: PAD_anyPressed is level-triggered and wake
			// fires on key-UP, so by the time we get here nothing is held. A gap this large is only
			// ever sleep — a normal menu iteration is tens of milliseconds.
			if (charge_last_tick && charge_now - charge_last_tick > 5000) charge_idle_at = charge_now;
			charge_last_tick = charge_now;
			if (PAD_anyPressed() || !charge_idle_at) charge_idle_at = charge_now;
			if (PWR_isCharging() && charge_now-charge_idle_at>=30000) {
				ChargingScreen(screen);
				charge_idle_at = SDL_GetTicks();
				dirty = 1;
			}
		}

		// menu clock: refresh the header once a minute while enabled (near-zero cost;
		// the menu autosleeps in 30s anyway, so this rarely fires)
		{
			static int clock_last_min = -1;
			time_t clock_time = time(NULL);
			struct tm* clock_tm = localtime(&clock_time);
			if (clock_tm->tm_min != clock_last_min) {
				if (clock_last_min >= 0 && exists(SHOW_CLOCK_PATH)) dirty = 1;
				clock_last_min = clock_tm->tm_min;
			}
		}
		
		int is_online = PLAT_isOnline();
		if (was_online!=is_online) dirty = 1;
		was_online = is_online;
		
		if (show_version) {
			if (PAD_justPressed(BTN_B) || PAD_tappedMenu(now)) {
				show_version = 0;
				dirty = 1;
				if (!HAS_POWER_BUTTON && !simple_mode) PWR_disableSleep();
			}
		}
		else if (show_clear) {
			if (PAD_justPressed(BTN_B) || PAD_tappedMenu(now)) {
				show_clear = 0;
				dirty = 1;
			}
			else if (PAD_justPressed(BTN_A)) {
				show_clear = clearRecents() ? 0 : 2;
				total = top->entries->count;
				dirty = 1;
			}
		}
		else if (total>0 && exactMatch(top->path, FAUX_RECENT_PATH)
			&& PAD_justPressed(BTN_Y) && (!show_setting || GetHDMI())) {
			show_clear = 1;
			dirty = 1;
		}
		else {
			if (PAD_tappedMenu(now)) {
				show_version = 1;
				dirty = 1;
				if (!HAS_POWER_BUTTON && !simple_mode) PWR_enableSleep();
			}
			else if (total>0) {
				if (PAD_justRepeated(BTN_UP)) {
					if (selected==0 && !PAD_justPressed(BTN_UP)) {
						// stop at top
					}
					else {
						selected -= 1;
						if (selected<0) {
							selected = total-1;
							int start = total - MAIN_ROW_COUNT;
							top->start = (start<0) ? 0 : start;
							top->end = total; 
						}
						else if (selected<top->start) {
							top->start -= 1;
							top->end -= 1;
						}
					}
				}
				else if (PAD_justRepeated(BTN_DOWN)) {
					if (selected==total-1 && !PAD_justPressed(BTN_DOWN)) {
						// stop at bottom
					}
					else {
						selected += 1;
						if (selected>=total) {
							selected = 0;
							top->start = 0;
							top->end = (total<MAIN_ROW_COUNT) ? total : MAIN_ROW_COUNT;
						}
						else if (selected>=top->end) {
							top->start += 1;
							top->end += 1;
						}
					}
				}
				if (PAD_justRepeated(BTN_LEFT)) {
					selected -= MAIN_ROW_COUNT;
					if (selected<0) {
						selected = 0;
						top->start = 0;
						top->end = (total<MAIN_ROW_COUNT) ? total : MAIN_ROW_COUNT;
					}
					else if (selected<top->start) {
						top->start -= MAIN_ROW_COUNT;
						if (top->start<0) top->start = 0;
						top->end = top->start + MAIN_ROW_COUNT;
					}
				}
				else if (PAD_justRepeated(BTN_RIGHT)) {
					selected += MAIN_ROW_COUNT;
					if (selected>=total) {
						selected = total-1;
						int start = total - MAIN_ROW_COUNT;
						top->start = (start<0) ? 0 : start;
						top->end = total;
					}
					else if (selected>=top->end) {
						top->end += MAIN_ROW_COUNT;
						if (top->end>total) top->end = total;
						top->start = top->end - MAIN_ROW_COUNT;
					}
				}
			}

			// hide-tools escape hatch: L1+R1+SELECT at the root opens Tools even when hidden by
			// hide-tools.txt. Holding both shoulders also suppresses the L1/R1 alpha jump below
			// (those require the OTHER shoulder released), so there is no collision.
			if (exactMatch(top->path, SDCARD_PATH) && flagExists(HIDE_TOOLS_PATH)
				&& PAD_isPressed(BTN_L1) && PAD_isPressed(BTN_R1) && PAD_justPressed(BTN_SELECT)) {
				char* tp = SDCARD_PATH "/Tools/" PLATFORM;
				if (exists(tp)) {
					openDirectory(tp, 0);
					total = top->entries->count;
					selected = 0;
					dirty = 1;
				}
			}

			if (total>0 && PAD_justRepeated(BTN_L1) && !PAD_isPressed(BTN_R1) && !PWR_ignoreSettingInput(BTN_L1, show_setting)) { // previous alpha
				Entry* entry = top->entries->items[selected];
				int i = entry->alpha-1;
				if (i>=0) {
					selected = top->alphas->items[i];
					if (total>MAIN_ROW_COUNT) {
						top->start = selected;
						top->end = top->start + MAIN_ROW_COUNT;
						if (top->end>total) top->end = total;
						top->start = top->end - MAIN_ROW_COUNT;
					}
				}
			}
			else if (total>0 && PAD_justRepeated(BTN_R1) && !PAD_isPressed(BTN_L1) && !PWR_ignoreSettingInput(BTN_R1, show_setting)) { // next alpha
				Entry* entry = top->entries->items[selected];
				int i = entry->alpha+1;
				if (i<top->alphas->count) {
					selected = top->alphas->items[i];
					if (total>MAIN_ROW_COUNT) {
						top->start = selected;
						top->end = top->start + MAIN_ROW_COUNT;
						if (top->end>total) top->end = total;
						top->start = top->end - MAIN_ROW_COUNT;
					}
				}
			}
	
			if (selected!=top->selected) {
				top->selected = selected;
				dirty = 1;
			}
	
			if (dirty && total>0) readyResume(top->entries->items[top->selected]);

			if (total>0 && can_resume && PAD_justReleased(BTN_RESUME)) {
				should_resume = 1;
				Entry_open(top->entries->items[top->selected]);
				dirty = 1;
			}
			else if (total>0 && PAD_justPressed(BTN_A)) {
				Entry_open(top->entries->items[top->selected]);
				total = top->entries->count;
				dirty = 1;

				if (total>0) readyResume(top->entries->items[top->selected]);
			}
			else if (PAD_justPressed(BTN_B) && stack->count>1) {
				closeDirectory();
				total = top->entries->count;
				dirty = 1;
				// can_resume = 0;
				if (total>0) readyResume(top->entries->items[top->selected]);
			}
		}
		
		if (dirty) {
			GFX_clear(screen);
			
			int ox;
			int oy;
			
			// simple thumbnail support a thumbnail for a file or folder named NAME.EXT needs a corresponding /.res/NAME.EXT.png 
			// that is no bigger than platform FIXED_HEIGHT x FIXED_HEIGHT
			int had_thumb = 0;
			if (!show_version && !show_clear && total>0) {
				Entry* entry = top->entries->items[top->selected];
				char res_path[MAX_PATH];
				
				char res_root[MAX_PATH];
				strcpy(res_root, entry->path);
				
				char tmp_path[MAX_PATH];
				strcpy(tmp_path, entry->path);
				char* res_name = strrchr(tmp_path, '/') + 1;

				char* tmp = strrchr(res_root, '/');
				tmp[0] = '\0';
				
				sprintf(res_path, "%s/.res/%s.png", res_root, res_name);
				// NO logging here: this runs on every menu redraw (i.e. every button press), and
				// stdout is redirected to a file ON THE SD CARD by MinUI.pak/launch.sh — so a
				// debug line here is an SD write per keypress, for a path that usually does not
				// even exist. Card wear and I/O for nothing.
				if (exists(res_path)) {
					// IMG_Load returns NULL on a corrupt/unsupported file, and the old code
					// dereferenced it immediately (thumb->w) — a guaranteed crash on any bad PNG.
					SDL_Surface* thumb = IMG_Load(res_path);
					if (thumb) {
						had_thumb = 1;
						ox = MAX(FIXED_WIDTH - FIXED_HEIGHT, (FIXED_WIDTH - thumb->w));
						oy = (FIXED_HEIGHT - thumb->h) / 2;
						SDL_BlitSurface(thumb, NULL, screen, &(SDL_Rect){ox,oy});
						SDL_FreeSurface(thumb);
					}
					else LOG_info("thumbnail: IMG_Load failed for %s: %s\n", res_path, IMG_GetError());
				}
			}
			
			int ow = GFX_blitHardwareGroup(screen, show_setting);
			
			if (show_clear) {
				char* message = show_clear==1 ? "Clear Recently Played?\nGames and saves will stay."
					: "Couldn't clear history.\nPlease check your SD card.";
				GFX_blitMessage(font.large, message, screen, &(SDL_Rect){
					0,0,screen->w,screen->h-SCALE1(PADDING + PILL_SIZE + PADDING)});
				GFX_blitButtonGroup((char*[]){ "B","CANCEL", NULL }, 0, screen, 0);
				GFX_blitButtonGroup((char*[]){ "A",show_clear==1 ? "CLEAR" : "RETRY", NULL }, 0, screen, 1);
			}
			else if (show_version) {
				if (!version) {
					char release[256] = {0};
					getFile(ROOT_SYSTEM_PATH "/version.txt", release, 256);

					char *commit;
					// version.txt is "release\ncommit\n". A MISSING or malformed file (no newline)
					// made strrchr return NULL and the next deref crashed minui — pressing MENU on
					// the home screen looked like a no-op because minui died + respawned (h700, no
					// version.txt shipped, 2026-08-06). Guard every strrchr/strchr.
					char* nl = strrchr(release, '\n'); // trailing newline
					if (!nl) { strcpy(release, "unknown\n?\n"); nl = strrchr(release, '\n'); }
					nl[0] = '\0';                      // strip the trailing newline
					char* mid = strrchr(release, '\n');// the newline between release and commit
					commit = mid ? mid + 1 : "?";      // commit = the second line
					if (mid) mid[0] = '\0';            // strip -> release = the first line
					
					// TODO: not sure if I want bare PLAT_* calls here
					char* extra_key = "Model";
					char* extra_val = PLAT_getModel(); 
					
					SDL_Surface* fw_key_txt = TTF_RenderUTF8_Blended(font.large, "Firmware", COLOR_DARK_TEXT);
					SDL_Surface* fw_val_txt = TTF_RenderUTF8_Blended(font.large, "MinUI Zero", COLOR_WHITE);
					SDL_Surface* release_txt = TTF_RenderUTF8_Blended(font.large, "Release", COLOR_DARK_TEXT);
					SDL_Surface* version_txt = TTF_RenderUTF8_Blended(font.large, release, COLOR_WHITE);
					SDL_Surface* commit_txt = TTF_RenderUTF8_Blended(font.large, "Commit", COLOR_DARK_TEXT);
					SDL_Surface* hash_txt = TTF_RenderUTF8_Blended(font.large, commit, COLOR_WHITE);
					
					SDL_Surface* key_txt = TTF_RenderUTF8_Blended(font.large, extra_key, COLOR_DARK_TEXT);
					SDL_Surface* val_txt = TTF_RenderUTF8_Blended(font.large, extra_val, COLOR_WHITE);
					
					int l_width = 0;
					int r_width = 0;
					
					if (fw_key_txt->w>l_width) l_width = fw_key_txt->w;
					if (release_txt->w>l_width) l_width = release_txt->w;
					if (commit_txt->w>l_width) l_width = commit_txt->w;
					if (key_txt->w>l_width) l_width = commit_txt->w;

					if (fw_val_txt->w>r_width) r_width = fw_val_txt->w;
					if (version_txt->w>r_width) r_width = version_txt->w;
					if (hash_txt->w>r_width) r_width = hash_txt->w;
					if (val_txt->w>r_width) r_width = val_txt->w;
					
					#define VERSION_LINE_HEIGHT 24
					int x = l_width + SCALE1(8);
					int w = x + r_width;
					int h = SCALE1(VERSION_LINE_HEIGHT*5);
					version = SDL_CreateRGBSurface(0,w,h,16,0,0,0,0);
					
					SDL_BlitSurface(fw_key_txt, NULL, version, &(SDL_Rect){0, 0});
					SDL_BlitSurface(fw_val_txt, NULL, version, &(SDL_Rect){x, 0});
					SDL_BlitSurface(release_txt, NULL, version, &(SDL_Rect){0,SCALE1(VERSION_LINE_HEIGHT)});
					SDL_BlitSurface(version_txt, NULL, version, &(SDL_Rect){x,SCALE1(VERSION_LINE_HEIGHT)});
					SDL_BlitSurface(commit_txt, NULL, version, &(SDL_Rect){0,SCALE1(VERSION_LINE_HEIGHT*2)});
					SDL_BlitSurface(hash_txt, NULL, version, &(SDL_Rect){x,SCALE1(VERSION_LINE_HEIGHT*2)});
					
					SDL_BlitSurface(key_txt, NULL, version, &(SDL_Rect){0,SCALE1(VERSION_LINE_HEIGHT*4)});
					SDL_BlitSurface(val_txt, NULL, version, &(SDL_Rect){x,SCALE1(VERSION_LINE_HEIGHT*4)});
					
					SDL_FreeSurface(fw_key_txt);
					SDL_FreeSurface(fw_val_txt);
					SDL_FreeSurface(release_txt);
					SDL_FreeSurface(version_txt);
					SDL_FreeSurface(commit_txt);
					SDL_FreeSurface(hash_txt);
					SDL_FreeSurface(key_txt);
					SDL_FreeSurface(val_txt);
				}
				SDL_BlitSurface(version, NULL, screen, &(SDL_Rect){(screen->w-version->w)/2,(screen->h-version->h)/2});
				
				// buttons (duped and trimmed from below)
				if (show_setting && !GetHDMI()) GFX_blitHardwareHints(screen, show_setting);
				else GFX_blitButtonGroup((char*[]){ BTN_SLEEP==BTN_POWER?"POWER":"MENU","SLEEP",  NULL }, 0, screen, 0);
				
				GFX_blitButtonGroup((char*[]){ "B","BACK",  NULL }, 0, screen, 1);
			}
			else {
				// list
				if (total>0) {
					int selected_row = top->selected - top->start;
					for (int i=top->start,j=0; i<top->end; i++,j++) {
						Entry* entry = top->entries->items[i];
						char* entry_name = entry->name;
						char* entry_unique = entry->unique;
						int available_width = (had_thumb && j!=selected_row ? ox : screen->w) - SCALE1(PADDING * 2);
						if (i==top->start && !(had_thumb && j!=selected_row)) available_width -= ow; // 
					
						SDL_Color text_color = COLOR_WHITE;
					
						trimSortingMeta(&entry_name);
					
						char display_name[256];
						int text_width = GFX_truncateText(font.large, entry_unique ? entry_unique : entry_name, display_name, available_width, SCALE1(BUTTON_PADDING*2));
						int max_width = MIN(available_width, text_width);
						if (j==selected_row) {
							GFX_blitPill(ASSET_WHITE_PILL, screen, &(SDL_Rect){
								SCALE1(PADDING),
								SCALE1(PADDING+(j*ROW_PITCH)),
								max_width,
								SCALE1(PILL_SIZE)
							});
							text_color = COLOR_BLACK;
						}
						else if (entry->unique) {
							trimSortingMeta(&entry_unique);
							char unique_name[256];
							GFX_truncateText(font.large, entry_unique, unique_name, available_width, SCALE1(BUTTON_PADDING*2));
						
							SDL_Surface* text = TTF_RenderUTF8_Blended(font.large, unique_name, COLOR_DARK_TEXT);
							SDL_BlitSurface(text, &(SDL_Rect){
								0,
								0,
								max_width-SCALE1(BUTTON_PADDING*2),
								text->h
							}, screen, &(SDL_Rect){
								SCALE1(PADDING+BUTTON_PADDING),
								SCALE1(PADDING+(j*ROW_PITCH)+4)
							});
						
							GFX_truncateText(font.large, entry_name, display_name, available_width, SCALE1(BUTTON_PADDING*2));
						}
						SDL_Surface* text = TTF_RenderUTF8_Blended(font.large, display_name, text_color);
						SDL_BlitSurface(text, &(SDL_Rect){
							0,
							0,
							max_width-SCALE1(BUTTON_PADDING*2),
							text->h
						}, screen, &(SDL_Rect){
							SCALE1(PADDING+BUTTON_PADDING),
							SCALE1(PADDING+(j*ROW_PITCH)+4)
						});
						SDL_FreeSurface(text);
					}
				}
				else {
					// TODO: for some reason screen's dimensions end up being 0x0 in GFX_blitMessage...
					GFX_blitMessage(font.large, exactMatch(top->path, FAUX_RECENT_PATH) ? "No recently played games" : "Empty folder", screen, &(SDL_Rect){0,0,screen->w,screen->h});
				}
			
				// buttons
				if (show_setting && !GetHDMI()) GFX_blitHardwareHints(screen, show_setting);
				else if (total>0 && exactMatch(top->path, FAUX_RECENT_PATH)) {
					if (can_resume) GFX_blitButtonGroup((char*[]){ "Y","CLEAR", "X","RESUME", NULL }, 0, screen, 0);
					else GFX_blitButtonGroup((char*[]){ "Y","CLEAR", NULL }, 0, screen, 0);
				}
				else if (can_resume) GFX_blitButtonGroup((char*[]){ "X","RESUME",  NULL }, 0, screen, 0);
				else GFX_blitButtonGroup((char*[]){ 
					BTN_SLEEP==BTN_POWER?"POWER":"MENU",
					BTN_SLEEP==BTN_POWER||simple_mode?"SLEEP":"INFO",  
					NULL }, 0, screen, 0);
			
				if (total==0) {
					if (stack->count>1) {
						GFX_blitButtonGroup((char*[]){ "B","BACK",  NULL }, 0, screen, 1);
					}
				}
				else {
					if (stack->count>1) {
						if (can_resume && exactMatch(top->path, FAUX_RECENT_PATH)
							&& recentFooterCompact(screen->w))
							GFX_blitButtonGroup((char*[]){ "A","OPEN", NULL }, 0, screen, 1);
						else GFX_blitButtonGroup((char*[]){ "B","BACK", "A","OPEN", NULL }, 1, screen, 1);
					}
					else {
						GFX_blitButtonGroup((char*[]){ "A","OPEN", NULL }, 0, screen, 1);
					}
				}
			}

			GFX_flip(screen);
			{ static int ui_first = 1; if (ui_first) { ui_first = 0; UIMARK("first_frame"); } }
			dirty = 0;
		}
		else GFX_sync();
		
		if (!first_draw) {
			first_draw = SDL_GetTicks();
			if (boot_timing) LOG_info("- first draw: %lu\n", first_draw - main_begin);
		}
		
		// handle HDMI change
		static int had_hdmi = -1;
		int has_hdmi = GetHDMI();
		if (had_hdmi==-1) had_hdmi = has_hdmi;
		if (has_hdmi!=had_hdmi) {
			had_hdmi = has_hdmi;

			char* path = total>0 ? ((Entry*)top->entries->items[top->selected])->path : top->path;
			LOG_info("restarting after HDMI change... (%s)\n", path);
			saveLast(path); // NOTE: doesn't work in Recents (by design)
			sleep(4);
			quit = 1;
		}
	}
	
	if (version) SDL_FreeSurface(version);

	Menu_quit();
	PWR_quit();
	PAD_quit();
	GFX_quit();
	QuitSettings();
}
