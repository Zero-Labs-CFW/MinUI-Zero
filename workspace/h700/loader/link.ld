/* SPDX-License-Identifier: GPL-2.0+ */
/*
 * MinUI Zero loader: one image at ZL_LOAD_ADDR (zero_params.h; tools/checkelf.py checks the two agree): the 64-byte
 * header, then the entry (start.S _start at +64), code, read-only data (incl. the page table), data. BSS follows the
 * image in memory (not in the file; start.S zeroes it), then a gap, then the stack, all inside the 1 MiB
 * ZL_LOAD_ADDR..+ZL_LOAD_MAX the SPL reserves for the loader.
 */
OUTPUT_FORMAT("elf64-littleaarch64")
OUTPUT_ARCH(aarch64)
ENTRY(_start)

ZL_LOAD_ADDR	= 0x4c000000;
ZL_IMAGE_MAX	= 512K;		/* the image file (header to end of .data) */
__stack_top	= 0x4c0f0000;	/* grows down */
ZL_STACK_SIZE	= 64K;

SECTIONS
{
	. = ZL_LOAD_ADDR;
	.zl_header : { KEEP(*(.zl_header)) }
	.text : {
		KEEP(*(.text.entry))
		*(.text .text.*)
	}
	/* start.S zl_vectors: own output section, so its 2 KiB alignment cannot move .text off ZL_LOAD_ADDR + 64 */
	.zl_vectors : { KEEP(*(.zl_vectors)) }
	.rodata : { *(.rodata .rodata.*) }
	.data : { *(.data .data.*) }
	. = ALIGN(16);
	__image_end = .;

	.bss (NOLOAD) : {
		. = ALIGN(16);
		__bss_start = .;
		*(.bss .bss.* COMMON)
		. = ALIGN(16);
		__bss_end = .;
	}

	/DISCARD/ : { *(.comment) *(.note .note.*) *(.eh_frame .eh_frame_hdr) }
}

ASSERT(_start == ZL_LOAD_ADDR + 64, "_start must be the first instruction after the 64-byte header")
ASSERT(__image_end - ZL_LOAD_ADDR <= ZL_IMAGE_MAX, "image over 512 KiB")
ASSERT(__bss_end <= __stack_top - ZL_STACK_SIZE, "BSS runs into the stack")
