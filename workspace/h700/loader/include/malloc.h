/* SPDX-License-Identifier: GPL-2.0+ */
/*
 * MinUI Zero loader: zlib/zutil.c (built with -D__UBOOT__) takes malloc/free from <malloc.h> for zcalloc/zcfree. In the
 * loader they are lib/malloc.c's bump allocator; calloc is only named in zcalloc's dead 16-bit branch (never linked).
 */
#ifndef ZL_MALLOC_H
#define ZL_MALLOC_H

#include <stddef.h>

void *malloc(size_t size);
void *calloc(size_t nmemb, size_t size);
void free(void *ptr);

#endif
