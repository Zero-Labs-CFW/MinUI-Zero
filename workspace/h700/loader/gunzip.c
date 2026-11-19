// SPDX-License-Identifier: GPL-2.0+
/* Whole-buffer gzip decode; validate FHCRC as well as the data CRC and ISIZE. */
#include <stddef.h>
#include <stdint.h>
#include <limits.h>
#include <malloc.h>
#include <u-boot/zlib.h>
#include "libdeflate/libdeflate.h"
#include "zl.h"

static int header_crc_ok(const unsigned char *src, size_t len)
{
	size_t pos = 10, end = len - 8;
	unsigned flags = src[3];

	if (!(flags & 2))
		return 1;
	if (flags & 4) {
		if (end - pos < 2)
			return 0;
		size_t extra = src[pos] | ((size_t)src[pos + 1] << 8);
		pos += 2;
		if (extra > end - pos)
			return 0;
		pos += extra;
	}
	for (unsigned flag = 8; flag <= 16; flag <<= 1) {
		if (!(flags & flag))
			continue;
		while (pos < end && src[pos])
			pos++;
		if (pos == end)
			return 0;
		pos++;
	}
	if (end - pos < 2)
		return 0;
	return (crc32(0, src, (uInt)pos) & 0xffff) ==
	       (unsigned)(src[pos] | ((unsigned)src[pos + 1] << 8));
}

int zl_gunzip(void *dst, unsigned long dst_max, const void *src, unsigned long src_len, unsigned long *out_len)
{
	const unsigned char *bytes = src;
	struct libdeflate_options options = {
		.sizeof_options = sizeof(options), .malloc_func = malloc, .free_func = free,
	};
	size_t used = 0, written = 0;

	*out_len = 0;
	if (!dst || !src || src_len < 18 || src_len > UINT_MAX || !dst_max || dst_max > UINT_MAX)
		return -1;
	if (!header_crc_ok(bytes, src_len))
		return -1;
	struct libdeflate_decompressor *d = libdeflate_alloc_decompressor_ex(&options);
	if (!d)
		return -2;
	enum libdeflate_result result = libdeflate_gzip_decompress_ex(d, src, src_len, dst, dst_max,
								 &used, &written);
	libdeflate_free_decompressor(d);
	if (result != LIBDEFLATE_SUCCESS)
		return -3;
	/* Refuse concatenated members and appended data; permit boot.img zero padding only. */
	for (; used < src_len; used++)
		if (bytes[used])
			return -4;
	*out_len = written;
	return 0;
}
