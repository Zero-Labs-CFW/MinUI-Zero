#define _GNU_SOURCE // for strcasestr
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <math.h>
#include <ctype.h>
#include <sys/time.h>
#include <sys/stat.h>
#include "defines.h"
#include "utils.h"

///////////////////////////////////////

int prefixMatch(char* pre, char* str) {
	return (strncasecmp(pre,str,strlen(pre))==0);
}
int suffixMatch(char* suf, char* str) {
	int len = strlen(suf);
	int offset = strlen(str)-len;
	return (offset>=0 && strncasecmp(suf, str+offset, len)==0);
}
int exactMatch(char* str1, char* str2) {
	if (!str1 || !str2) return 0; // NULL isn't safe here
	int len1 = strlen(str1);
	if (len1!=strlen(str2)) return 0;
	return (strncmp(str1,str2,len1)==0);
}
int containsString(char* haystack, char* needle) {
	return strcasestr(haystack, needle) != NULL;
}
int hide(char* file_name) {
	return file_name[0]=='.' || suffixMatch(".disabled", file_name) || exactMatch("map.txt", file_name);
}

void getDisplayName(const char* in_name, char* out_name) {
	char* tmp;
	char work_name[256];
	strcpy(work_name, in_name);
	strcpy(out_name, in_name);
	
	if (suffixMatch("/" PLATFORM, work_name)) { // hide platform from Tools path...
		tmp = strrchr(work_name, '/');
		tmp[0] = '\0';
	}
	
	// extract just the filename if necessary
	tmp = strrchr(work_name, '/');
	if (tmp) strcpy(out_name, tmp+1);
	
	// remove extension(s), eg. .p8.png
	while ((tmp = strrchr(out_name, '.'))!=NULL) {
		int len = strlen(tmp);
		if (len>2 && len<=5) tmp[0] = '\0'; // 1-4 letter extension plus dot (was 1-3, extended for .doom files)
		else break;
	}
	
	// remove trailing parens (round and square)
	strcpy(work_name, out_name);
	while ((tmp=strrchr(out_name, '('))!=NULL || (tmp=strrchr(out_name, '['))!=NULL) {
		if (tmp==out_name) break;
		tmp[0] = '\0';
		tmp = out_name;
	}
	
	// make sure we haven't nuked the entire name
	if (out_name[0]=='\0') strcpy(out_name, work_name);
	
	// remove trailing whitespace
	tmp = out_name + strlen(out_name) - 1;
    while(tmp>out_name && isspace((unsigned char)*tmp)) tmp--;
    tmp[1] = '\0';
}
void getEmuName(const char* in_name, char* out_name) { // NOTE: both char arrays need to be MAX_PATH length!
	char* tmp;
	strcpy(out_name, in_name);
	tmp = out_name;
	
	// printf("--------\n  in_name: %s\n",in_name); fflush(stdout);
	
	// extract just the Roms folder name if necessary
	if (prefixMatch(ROMS_PATH, tmp)) {
		tmp += strlen(ROMS_PATH) + 1;
		char* tmp2 = strchr(tmp, '/');
		if (tmp2) tmp2[0] = '\0';
		// printf("    tmp1: %s\n", tmp);
		strcpy(out_name, tmp);
		tmp = out_name;
	}

	// finally extract pak name from parenths if present
	tmp = strrchr(tmp, '(');
	if (tmp) {
		tmp += 1;
		// printf("    tmp2: %s\n", tmp);
		strcpy(out_name, tmp);
		tmp = strchr(out_name,')');
		tmp[0] = '\0';
	}
	
	// printf(" out_name: %s\n", out_name); fflush(stdout);
}
void getEmuPath(char* emu_name, char* pak_path) {
	sprintf(pak_path, "%s/Emus/%s/%s.pak/launch.sh", SDCARD_PATH, PLATFORM, emu_name);
	if (exists(pak_path)) return;
#ifdef PLATFORM_ALIAS
	// Community paks are published under the platform folder name the wider scene uses, which is
	// not always ours (h700 == "rg35xxplus" to NextUI/MinUI pak authors). Honour that name too so
	// third-party paks install drop-in — the compat rail for "lean core, opt-in features from the
	// community that exists today" (Dan 2026-08-10). Our own name wins when both exist.
	sprintf(pak_path, "%s/Emus/%s/%s.pak/launch.sh", SDCARD_PATH, PLATFORM_ALIAS, emu_name);
	if (exists(pak_path)) return;
#endif
	sprintf(pak_path, "%s/Emus/%s.pak/launch.sh", PAKS_PATH, emu_name);
}

void normalizeNewline(char* line) {
	int len = strlen(line);
	if (len>1 && line[len-1]=='\n' && line[len-2]=='\r') { // windows!
		line[len-2] = '\n';
		line[len-1] = '\0';
	}
}
void trimTrailingNewlines(char* line) {
	int len = strlen(line);
	while (len>0 && line[len-1]=='\n') {
		line[len-1] = '\0'; // trim newline
		len -= 1;
	}
}
void trimSortingMeta(char** str) { // eg. `001) `
	// TODO: this code is suss
	char* safe = *str;
	while(isdigit(**str)) *str += 1; // ignore leading numbers

	if (*str[0]==')') { // then match a closing parenthesis
		*str += 1;
	}
	else { //  or bail, restoring the string to its original value
		*str = safe;
		return;
	}
	
	while(isblank(**str)) *str += 1; // ignore leading space
}

///////////////////////////////////////

int exists(char* path) {
	return access(path, F_OK)==0;
}
// Card-root opt-in/opt-out flags: accept the bare name OR a "<name>.txt" form, so the file works
// whether the user's OS added an extension or not. Pass the bare base (upstream's convention,
// e.g. "enable-simple-mode"); this also matches "<base>.txt".
int flagExists(char* base) {
	if (exists(base)) return 1;
	char with_txt[512];
	snprintf(with_txt, sizeof(with_txt), "%s.txt", base);
	return exists(with_txt);
}
void touch(char* path) {
	close(open(path, O_RDWR|O_CREAT, 0777));
}
void putFile(char* path, char* contents) {
	FILE* file = fopen(path, "w");
	if (file) {
		fputs(contents, file);
		fclose(file);
	}
}
void getFile(char* path, char* buffer, size_t buffer_size) {
	FILE *file = fopen(path, "r");
	if (file) {
		fseek(file, 0L, SEEK_END);
		size_t size = ftell(file);
		if (size>buffer_size-1) size = buffer_size - 1;
		rewind(file);
		fread(buffer, sizeof(char), size, file);
		fclose(file);
		buffer[size] = '\0';
	}
}
char* allocFile(char* path) { // caller must free!
	char* contents = NULL;
	FILE *file = fopen(path, "r");
	if (file) {
		fseek(file, 0L, SEEK_END);
		size_t size = ftell(file);
		contents = calloc(size+1, sizeof(char));
		fseek(file, 0L, SEEK_SET);
		fread(contents, sizeof(char), size, file);
		fclose(file);
		contents[size] = '\0';
	}
	return contents;
}
int getInt(char* path) {
	int i = 0;
	FILE *file = fopen(path, "r");
	if (file!=NULL) {
		fscanf(file, "%i", &i);
		fclose(file);
	}
	return i;
}
void putInt(char* path, int value) {
	char buffer[8];
	sprintf(buffer, "%d", value);
	putFile(path, buffer);
}

uint64_t getMicroseconds(void) {
    uint64_t ret;
    struct timeval tv;

    gettimeofday(&tv, NULL);

    ret = (uint64_t)tv.tv_sec * 1000000;
    ret += (uint64_t)tv.tv_usec;

    return ret;
}

///////////////////////////////////////
// Favorites: FAVORITE_PATH holds one SD-relative rom path per line, like recent.txt. WRITTEN by
// minarch (Y in the in-game menu toggles the running game) and READ by the launcher (the Favorites
// row). Shared here so both binaries agree on the format and the toggle semantics.

static const char* Favorites_rel(char* sd_path) {
	// SD-relative like recent.txt ("/Roms/GB/game.gb"); a path outside the card is stored as-is
	if (!strncmp(sd_path, SDCARD_PATH, strlen(SDCARD_PATH))) return sd_path + strlen(SDCARD_PATH);
	return sd_path;
}
int Favorites_has(char* sd_path) {
	const char* rel = Favorites_rel(sd_path);
	FILE* file = fopen(FAVORITE_PATH, "r");
	if (!file) return 0;
	int found = 0;
	char line[MAX_PATH];
	while (fgets(line, sizeof(line), file)) {
		normalizeNewline(line);
		trimTrailingNewlines(line);
		if (!strcmp(line, rel)) { found = 1; break; }
	}
	fclose(file);
	return found;
}
void Favorites_toggle(char* sd_path) {
	const char* rel = Favorites_rel(sd_path);
	mkdir(SHARED_USERDATA_PATH "/.minui", 0755); // where recent.txt lives; a no-op once it exists
	char tmp_path[MAX_PATH];
	snprintf(tmp_path, sizeof(tmp_path), "%s.tmp", FAVORITE_PATH);
	FILE* out = fopen(tmp_path, "w");
	if (!out) return;
	int was = 0;
	FILE* file = fopen(FAVORITE_PATH, "r");
	if (file) {
		char line[MAX_PATH];
		while (fgets(line, sizeof(line), file)) {
			normalizeNewline(line);
			trimTrailingNewlines(line);
			if (!line[0]) continue;
			if (!strcmp(line, rel)) { was = 1; continue; } // present: drop it (unfavorite)
			fputs(line, out); fputc('\n', out);
		}
		fclose(file);
	}
	if (!was) { fputs(rel, out); fputc('\n', out); } // absent: append (favorite); order stays stable
	fclose(out);
	rename(tmp_path, FAVORITE_PATH); // atomic swap, same discipline as the crash-safe save writes
}