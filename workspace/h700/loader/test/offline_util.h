#ifndef OFFLINE_UTIL_H
#define OFFLINE_UTIL_H
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
static unsigned checks;
#define CHECK(x) do { checks++; if (!(x)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #x); exit(1); } } while (0)
static unsigned char *read_file(const char *path, size_t *len)
{
	FILE *f = fopen(path, "rb");
	long n;
	unsigned char *p;
	CHECK(f != NULL && fseek(f, 0, SEEK_END) == 0);
	n = ftell(f);
	CHECK(n >= 0 && fseek(f, 0, SEEK_SET) == 0);
	p = malloc((size_t)n + 1);
	CHECK(p != NULL && fread(p, 1, (size_t)n, f) == (size_t)n && fclose(f) == 0);
	p[n] = 0;
	*len = (size_t)n;
	return p;
}
static void write_file(const char *path, const void *data, size_t len)
{
	FILE *f = fopen(path, "wb");
	CHECK(f != NULL && fwrite(data, 1, len, f) == len && fclose(f) == 0);
}
#endif
