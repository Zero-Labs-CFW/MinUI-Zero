// SPDX-License-Identifier: GPL-2.0+
/*
 * MinUI Zero loader: the string functions libfdt and zlib need (libfdt: memchr memcmp memcpy memmove memset strchr
 * strlen strnlen strrchr strtoul; zlib: memcpy memset), plus strcmp for fixup.c, nothing more. Built with
 * -fno-tree-loop-distribute-patterns so
 * the compiler cannot turn these loops back into calls to themselves. memcpy/memmove/memset go 8 bytes at a time when
 * the alignment allows (libfdt moves the tree tail on every property it grows); the rest are plain byte loops.
 */
#include <stddef.h>
#include <stdint.h>
#include <limits.h>
#include <string.h>
#include <stdlib.h>

#define ZL_WMASK	(sizeof(uint64_t) - 1)

void *memcpy(void *dst, const void *src, size_t n)
{
	unsigned char *d = dst;
	const unsigned char *s = src;

	if (!(((uintptr_t)d | (uintptr_t)s) & ZL_WMASK)) {
		for (; n >= 8; n -= 8, d += 8, s += 8)
			*(uint64_t *)d = *(const uint64_t *)s;
	}
	while (n--)
		*d++ = *s++;
	return dst;
}

void *memmove(void *dst, const void *src, size_t n)
{
	unsigned char *d = dst;
	const unsigned char *s = src;

	if (d == s || !n)
		return dst;
	if (d < s || d >= s + n)
		return memcpy(dst, src, n);	/* forward copy is safe */
	/* overlapping, destination above the source: copy from the end down */
	d += n;
	s += n;
	if (!(((uintptr_t)d | (uintptr_t)s) & ZL_WMASK)) {
		for (; n >= 8; n -= 8) {
			d -= 8;
			s -= 8;
			*(uint64_t *)d = *(const uint64_t *)s;
		}
	}
	while (n--)
		*--d = *--s;
	return dst;
}

void *memset(void *s, int c, size_t n)
{
	unsigned char *p = s;
	uint64_t w = (unsigned char)c;

	while (n && ((uintptr_t)p & ZL_WMASK)) {
		*p++ = (unsigned char)c;
		n--;
	}
	w |= w << 8;
	w |= w << 16;
	w |= w << 32;
	for (; n >= 8; n -= 8, p += 8)
		*(uint64_t *)p = w;
	while (n--)
		*p++ = (unsigned char)c;
	return s;
}

int memcmp(const void *a, const void *b, size_t n)
{
	const unsigned char *x = a, *y = b;

	for (; n; n--, x++, y++)
		if (*x != *y)
			return *x - *y;
	return 0;
}

int strcmp(const char *a, const char *b)
{
	while (*a && *a == *b) {
		a++;
		b++;
	}
	return (unsigned char)*a - (unsigned char)*b;
}

void *memchr(const void *s, int c, size_t n)
{
	const unsigned char *p = s;

	for (; n; n--, p++)
		if (*p == (unsigned char)c)
			return (void *)p;
	return NULL;
}

size_t strlen(const char *s)
{
	const char *p = s;

	while (*p)
		p++;
	return p - s;
}

size_t strnlen(const char *s, size_t max)
{
	size_t n = 0;

	while (n < max && s[n])
		n++;
	return n;
}

char *strchr(const char *s, int c)
{
	for (;; s++) {
		if (*s == (char)c)
			return (char *)s;
		if (!*s)
			return NULL;
	}
}

char *strrchr(const char *s, int c)
{
	const char *last = NULL;

	for (;; s++) {
		if (*s == (char)c)
			last = s;
		if (!*s)
			return (char *)last;
	}
}

static int zl_digit(char ch)
{
	if (ch >= '0' && ch <= '9')
		return ch - '0';
	if (ch >= 'a' && ch <= 'z')
		return ch - 'a' + 10;
	if (ch >= 'A' && ch <= 'Z')
		return ch - 'A' + 10;
	return 99;
}

/* C semantics: leading space, optional sign, base 0/16 "0x" prefix, base 0 octal; ULONG_MAX on overflow */
unsigned long strtoul(const char *nptr, char **endptr, int base)
{
	const char *s = nptr, *start;
	unsigned long v = 0;
	int neg = 0, over = 0, d;

	while (*s == ' ' || (*s >= '\t' && *s <= '\r'))
		s++;
	if (*s == '+' || *s == '-')
		neg = *s++ == '-';
	if ((base == 0 || base == 16) && s[0] == '0' && (s[1] == 'x' || s[1] == 'X') && zl_digit(s[2]) < 16) {
		s += 2;
		base = 16;
	} else if (base == 0) {
		base = s[0] == '0' ? 8 : 10;
	}
	if (base < 2 || base > 36) {
		if (endptr)
			*endptr = (char *)nptr;
		return 0;
	}
	for (start = s; (d = zl_digit(*s)) < base; s++) {
		if (v > (ULONG_MAX - d) / base)
			over = 1;
		else
			v = v * base + d;
	}
	if (endptr)
		*endptr = (char *)(s == start ? nptr : s);
	if (over)
		return ULONG_MAX;
	return neg ? -v : v;
}
