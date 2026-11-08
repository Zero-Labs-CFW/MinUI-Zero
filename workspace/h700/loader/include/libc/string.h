/* SPDX-License-Identifier: GPL-2.0+ */
/*
 * MinUI Zero loader: the string functions libfdt, zlib and the loader's own code use (lib/string.c), nothing more.
 * Bare-metal build only.
 */
#ifndef ZL_STRING_H
#define ZL_STRING_H

#include <stddef.h>

void *memcpy(void *dst, const void *src, size_t n);
void *memmove(void *dst, const void *src, size_t n);
void *memset(void *s, int c, size_t n);
int memcmp(const void *a, const void *b, size_t n);
void *memchr(const void *s, int c, size_t n);
size_t strlen(const char *s);
size_t strnlen(const char *s, size_t max);
int strcmp(const char *a, const char *b);
char *strchr(const char *s, int c);
char *strrchr(const char *s, int c);

#endif
