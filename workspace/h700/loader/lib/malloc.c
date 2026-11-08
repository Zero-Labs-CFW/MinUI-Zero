// SPDX-License-Identifier: GPL-2.0+
/*
 * MinUI Zero loader: a bump allocator over a static 256 KiB arena, for zlib (zcalloc/zcfree in zlib/zutil.c call
 * malloc/free). Inflating in one call needs only the inflate state (~7 KiB): zlib allocates its 32 KiB window only
 * when inflate() returns before the end of the stream (zlib/inflate.c, inf_leave). free() is a no-op; the arena dies
 * with the loader.
 */
#include <stddef.h>
#include <stdint.h>
#include <malloc.h>

#define ZL_ARENA_SIZE	(256u << 10)
#define ZL_ARENA_ALIGN	16u

static unsigned char zl_arena[ZL_ARENA_SIZE] __attribute__((aligned(ZL_ARENA_ALIGN)));
static size_t zl_arena_used;

void *malloc(size_t size)
{
	void *p;

	if (!size || size > ZL_ARENA_SIZE)
		return NULL;
	size = (size + ZL_ARENA_ALIGN - 1) & ~(size_t)(ZL_ARENA_ALIGN - 1);
	if (size > ZL_ARENA_SIZE - zl_arena_used)
		return NULL;
	p = zl_arena + zl_arena_used;
	zl_arena_used += size;
	return p;
}

void free(void *ptr)
{
	(void)ptr;
}
