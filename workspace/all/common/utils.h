#ifndef UTILS_H
#define UTILS_H

#include <stdint.h>

int prefixMatch(char* pre, char* str);
int suffixMatch(char* suf, char* str);
int exactMatch(char* str1, char* str2);
int containsString(char* haystack, char* needle);
int hide(char* file_name);

void getDisplayName(const char* in_name, char* out_name);
void getEmuName(const char* in_name, char* out_name);
void getEmuPath(char* emu_name, char* pak_path);

void normalizeNewline(char* line);
void trimTrailingNewlines(char* line);
void trimSortingMeta(char** str);

int exists(char* path);
int flagExists(char* base); // true if <base> or <base>.txt exists (card-root flag, either form)
void touch(char* path);
void putFile(char* path, char* contents);
char* allocFile(char* path); // caller must free
void getFile(char* path, char* buffer, size_t buffer_size);
void putInt(char* path, int value);
int getInt(char* path);

// Favorites list (FAVORITE_PATH): toggled by minarch from the in-game menu, read by the launcher.
int Favorites_has(char* sd_path);      // is this rom (absolute card path) in the list?
void Favorites_toggle(char* sd_path);  // add if absent, remove if present; atomic rewrite

uint64_t getMicroseconds(void);

#endif
