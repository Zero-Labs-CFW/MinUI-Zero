// SPDX-License-Identifier: GPL-2.0+
/*
 * MinUI Zero loader: inflate the gzip kernel stored in boot.img.
 *
 * zlib in gzip mode: inflateInit2 with windowBits 16 + MAX_WBITS (wrap = 2, gzip only: zlib/inflate.c:52-60, GUNZIP is
 * defined by the glue in zlib/zlib.h:14). zlib then parses the gzip header itself (inflate.c HEAD/FLAGS..HCRC states)
 * and checks the CRC-32 (CHECK) and ISIZE (LENGTH) trailer, so a damaged or truncated kernel is refused here instead of
 * being run. U-Boot's own lib/gunzip.c is not used: it parses the header by hand and inflates raw (-MAX_WBITS,
 * lib/gunzip.c:330), with no trailer check.
 *
 * One inflate() call with the whole output buffer, like U-Boot's zunzip: zlib needs no 32 KiB window then (it only
 * allocates one when inflate returns early, inflate.c inf_leave), and the CRC runs once over the output at the end.
 */
#include <stddef.h>
#include <stdint.h>
#include <limits.h>
#include <string.h>
#include "zlib/zlib.h"
#include "zl.h"

#define ZL_GZ_MIN	18	/* 10-byte header + empty deflate block (2) + 8-byte trailer, roughly */

int zl_gunzip(void *dst, unsigned long dst_max, const void *src, unsigned long src_len, unsigned long *out_len)
{
	const unsigned char *rest;
	z_stream s;
	int r;

	*out_len = 0;
	/* zlib 1.2.3 keeps byte counts in 32-bit uInt */
	if (!dst || !src || src_len < ZL_GZ_MIN || src_len > UINT_MAX || !dst_max || dst_max > UINT_MAX)
		return -1;
	memset(&s, 0, sizeof(s));	/* zalloc/zfree NULL: zcalloc/zcfree, i.e. lib/malloc.c */
	if (inflateInit2(&s, 16 + MAX_WBITS) != Z_OK)
		return -2;
	s.next_in = (Bytef *)src;
	s.avail_in = (uInt)src_len;
	s.next_out = dst;
	s.avail_out = (uInt)dst_max;
	r = inflate(&s, Z_FINISH);
	/* Z_BUF_ERROR: output too small or input truncated; Z_DATA_ERROR: bad data, header, CRC-32 or ISIZE */
	if (r != Z_STREAM_END) {
		inflateEnd(&s);
		return -3;
	}
	/*
	 * Bytes after the gzip member: tolerate zero padding only. Anything else (a second gzip member, which zlib would
	 * not inflate, or an appended DTB) means the image is not what this loader expects.
	 */
	for (rest = s.next_in; s.avail_in; s.avail_in--, rest++)
		if (*rest) {
			inflateEnd(&s);
			return -4;
		}
	*out_len = s.total_out;
	inflateEnd(&s);
	return 0;
}
