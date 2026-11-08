/* SPDX-License-Identifier: GPL-2.0+ */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "zl.h"
#include <u-boot/zlib.h>

void zl_crc32_force(int mode);

static unsigned checks;

#define CHECK(expr) do { \
	checks++; \
	if (!(expr)) { \
		fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #expr); \
		exit(1); \
	} \
} while (0)

static unsigned char *read_file(const char *path, size_t *len)
{
	FILE *f = fopen(path, "rb");
	unsigned char *data;
	long n;
	CHECK(f != NULL);
	CHECK(fseek(f, 0, SEEK_END) == 0);
	n = ftell(f);
	CHECK(n >= 0 && fseek(f, 0, SEEK_SET) == 0);
	data = malloc((size_t)n + 32);
	CHECK(data != NULL);
	CHECK(fread(data, 1, (size_t)n, f) == (size_t)n);
	CHECK(fclose(f) == 0);
	*len = (size_t)n;
	return data;
}

static void rejected(unsigned char *dst, size_t cap, const void *src, size_t len)
{
	unsigned long out = 123;
	memset(dst, 0xa5, cap + 16);
	CHECK(zl_gunzip(dst, cap, src, len, &out) != 0);
	CHECK(out == 0);
	for (size_t i = 0; i < 16; i++)
		CHECK(dst[cap + i] == 0xa5);
}

int main(int argc, char **argv)
{
	size_t gz_len, image_len;
	unsigned char *gz, *image, *dst, *bad;
	unsigned long out;
	CHECK(argc == 3);
	gz = read_file(argv[1], &gz_len);
	image = read_file(argv[2], &image_len);
	dst = malloc(image_len + 16);
	bad = malloc(gz_len * 2 + 32);
	CHECK(dst != NULL && bad != NULL && gz_len > 18 && image_len > 64);
	zl_crc32_force(1);
	CHECK(crc32(0, NULL, 0) == 0);
	CHECK(crc32(0, (const Bytef *)"123456789", 9) == 0xcbf43926u);
	CHECK(crc32(crc32(0, (const Bytef *)"1234", 4), (const Bytef *)"56789", 5) == 0xcbf43926u);
	memset(dst, 0xa5, image_len + 16);
	CHECK(zl_gunzip(dst, image_len, gz, gz_len, &out) == 0);
	CHECK(out == image_len && memcmp(dst, image, image_len) == 0);
	for (size_t i = 0; i < 16; i++)
		CHECK(dst[image_len + i] == 0xa5);
	CHECK(image[56] == 'A' && image[57] == 'R' && image[58] == 'M' && image[59] == 0x64);
	rejected(dst, image_len - 1, gz, gz_len);
	rejected(dst, 1, gz, gz_len);
	rejected(dst, image_len, gz, 0);
	rejected(dst, image_len, gz, 17);
	rejected(dst, image_len, gz, gz_len - 1);
	rejected(dst, image_len, gz, gz_len - 8);
	/* Mutate each independent integrity layer without changing the source fixture. */
	const size_t offsets[] = {0, 2, 3, gz_len / 2, gz_len - 8, gz_len - 4};
	for (size_t i = 0; i < sizeof(offsets) / sizeof(offsets[0]); i++) {
		memcpy(bad, gz, gz_len);
		bad[offsets[i]] ^= i == 2 ? 0xe0 : 0x80;
		rejected(dst, image_len, bad, gz_len);
	}
	memcpy(bad, gz, gz_len);
	memset(bad + gz_len, 0, 16);
	CHECK(zl_gunzip(dst, image_len, bad, gz_len + 16, &out) == 0 && out == image_len);
	bad[gz_len + 15] = 1;
	rejected(dst, image_len, bad, gz_len + 16);
	memcpy(bad + gz_len, gz, gz_len);
	rejected(dst, image_len, bad, gz_len * 2);
	rejected(dst, image_len, NULL, gz_len);
	out = 123;
	CHECK(zl_gunzip(NULL, image_len, gz, gz_len, &out) != 0 && out == 0);
	free(bad);
	free(dst);
	free(image);
	free(gz);
	printf("PASS gzip: %u checks; %zu compressed -> %zu bytes, byte-identical to gunzip\n", checks, gz_len, image_len);
	return 0;
}
