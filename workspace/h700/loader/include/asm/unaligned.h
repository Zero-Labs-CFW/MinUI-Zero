/* SPDX-License-Identifier: GPL-2.0+ */
/*
 * MinUI Zero loader: the parts of U-Boot's asm/unaligned.h and asm/byteorder.h the copied zlib uses.
 * get_unaligned(): zlib/inffast.c reads 16-bit match bytes from any address (inffast.c:256); a fixed-size
 * __builtin_memcpy compiles to byte loads under -mstrict-align, so it is safe at any alignment.
 * __LITTLE_ENDIAN: inffast.c picks its 16-bit fill pattern with "#if defined(__BIG_ENDIAN) ... #elif
 * defined(__LITTLE_ENDIAN)" (the Linux convention: only one of the two is defined), so __BIG_ENDIAN must not be.
 */
#ifndef ZL_ASM_UNALIGNED_H
#define ZL_ASM_UNALIGNED_H

#if __BYTE_ORDER__ != __ORDER_LITTLE_ENDIAN__
#error "the loader is little-endian only"
#endif
#undef __BIG_ENDIAN
#ifndef __LITTLE_ENDIAN
#define __LITTLE_ENDIAN	1234
#endif

#define get_unaligned(ptr) ({					\
	const struct __attribute__((packed)) {			\
		__typeof__(*(ptr)) value;				\
	} *__zl_p = (const void *)(ptr);				\
	__zl_p->value; })

#endif
