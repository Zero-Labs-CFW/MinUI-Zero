// SPDX-License-Identifier: GPL-2.0+
/*
 * MinUI Zero loader: CRC-32 (the gzip trailer check: reflected polynomial 0xedb88320, zlib's crc32() semantics), which
 * libdeflate calls through the adapter below. Same interface and result as U-Boot's
 * lib/crc32.c (derived from zlib 1.1.3); written fresh here to avoid its EFI/host glue.
 *
 * Speed matters: the whole inflated kernel (~18 MB on the Plus) goes through here once. When the CPU has the ARMv8
 * CRC32 instructions (ID_AA64ISAR0_EL1.CRC32, bits 19:16, read at run time; CRC32X uses the same polynomial), 8 bytes
 * per instruction; otherwise a byte-wise table built on first use. The run-time check keeps units without the
 * extension safe. This file alone is built with -march=armv8-a+crc so
 * the assembler accepts the instructions; nothing else in it lets the compiler emit them.
 */
#include <stddef.h>
#include <stdint.h>
#include <limits.h>
#include "../libdeflate/libdeflate.h"
#include <u-boot/zlib.h>	/* the crc32() prototype zlib calls, so a mismatch fails to compile */

#define ZL_CRC_POLY	0xedb88320u

static uint32_t zl_crc_table[256];
static int zl_crc_mode;		/* 0 = not chosen yet, 1 = table, 2 = CRC32 instructions */

/* host test hook: force the table (1) or the instructions (2); 0 = choose by the CPU */
void zl_crc32_force(int mode)
{
	zl_crc_mode = mode;
}

static void zl_crc_choose(void)
{
	uint64_t isar0 = 0;
	uint32_t c;
	int n, k;

#ifndef ZL_HOST_TEST
	__asm__ volatile("mrs %0, id_aa64isar0_el1" : "=r"(isar0));
#endif
	for (n = 0; n < 256; n++) {
		c = n;
		for (k = 0; k < 8; k++)
			c = c & 1 ? ZL_CRC_POLY ^ (c >> 1) : c >> 1;
		zl_crc_table[n] = c;
	}
	if (!zl_crc_mode)
		zl_crc_mode = ((isar0 >> 16) & 0xf) ? 2 : 1;
}

#ifndef ZL_HOST_TEST
static inline uint32_t zl_crc32b(uint32_t c, uint32_t byte)
{
	__asm__("crc32b %w0, %w0, %w1" : "+r"(c) : "r"(byte));
	return c;
}

static inline uint32_t zl_crc32x(uint32_t c, uint64_t dword)
{
	__asm__("crc32x %w0, %w0, %x1" : "+r"(c) : "r"(dword));
	return c;
}
#endif

uInt crc32(uInt crc, const Bytef *buf, uInt len)
{
	uint32_t c = ~(uint32_t)crc;

	if (!buf)
		return 0;	/* zlib: crc32(x, Z_NULL, 0) is the initial value */
	if (zl_crc_mode == 0 || !zl_crc_table[1])
		zl_crc_choose();
#ifndef ZL_HOST_TEST
	if (zl_crc_mode == 2) {
		while (len && ((uintptr_t)buf & 7)) {
			c = zl_crc32b(c, *buf++);
			len--;
		}
		for (; len >= 8; len -= 8, buf += 8)
			c = zl_crc32x(c, *(const uint64_t *)buf);	/* aligned; little-endian = byte order */
		while (len--)
			c = zl_crc32b(c, *buf++);
	} else
#endif
	{
		while (len--)
			c = zl_crc_table[(c ^ *buf++) & 0xff] ^ (c >> 8);
	}
	return ~c;
}

uint32_t libdeflate_crc32(uint32_t crc, const void *buffer, size_t len)
{
	const unsigned char *bytes = buffer;
	if (!bytes)
		return 0;
	while (len) {
		uInt chunk = len > UINT_MAX ? UINT_MAX : (uInt)len;
		crc = crc32(crc, bytes, chunk);
		bytes += chunk;
		len -= chunk;
	}
	return crc;
}
