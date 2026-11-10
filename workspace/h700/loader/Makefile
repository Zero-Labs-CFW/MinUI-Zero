# SPDX-License-Identifier: GPL-2.0+
# MinUI Zero H700 stage 2 loader (see README.md).
#
#   make                         zero-loader.bin, then the ELF/image checks (native aarch64 gcc;
#                                elsewhere: make CROSS_COMPILE=aarch64-linux-gnu-)
#   make hosttest                capture-free sanitizer tests (host cc)
#   make captured-test FIXTURES=... TEST_OUTPUT=...  real-kernel/FDT/lifecycle tests
#   Always make clean before changing OPTS. The only supported handoff is the default real A32 stub.
#   make clean                   removes obj/ and zero-loader.bin (nothing else in this directory)

CROSS_COMPILE ?=
CC	:= $(CROSS_COMPILE)gcc
LD	:= $(CROSS_COMPILE)ld
OBJCOPY	:= $(CROSS_COMPILE)objcopy
OBJDUMP	:= $(CROSS_COMPILE)objdump
READELF	:= $(CROSS_COMPILE)readelf
NM	:= $(CROSS_COMPILE)nm
HOSTCC	?= gcc
PY	:= python3 -I
OPTS	?=

O	:= obj
GCC_INC	:= $(shell $(CC) -print-file-name=include)

LIBFDT	:= fdt.c fdt_ro.c fdt_rw.c fdt_wip.c fdt_sw.c fdt_strerror.c fdt_addresses.c fdt_overlay.c fdt_empty_tree.c \
	   fdt_check.c
ASRCS	:= start.S cache.S
INFLATE := libdeflate/lib/utils.c libdeflate/lib/deflate_decompress.c libdeflate/lib/gzip_decompress.c
CSRCS	:= main.c monitor.c fixup.c gunzip.c rtc.c wdt.c profile.c lib/sha256.c lib/string.c lib/malloc.c lib/crc32.c $(INFLATE) \
	   $(addprefix libfdt/,$(LIBFDT))
OBJS	:= $(addprefix $(O)/,$(ASRCS:.S=.o) $(CSRCS:.c=.o))

# freestanding, no FP/SIMD (the monitor may trap it), no PIC/GOT, no unwind tables, every warning an error
WARN	:= -Wall -Wextra -Werror
CFLAGS	:= -std=gnu11 -O2 -g -ffreestanding -nostdlib -nostdinc -isystem $(GCC_INC) \
	   -fno-pic -fno-pie -fno-builtin -fno-common -fno-strict-aliasing -fno-stack-protector \
	   -fno-asynchronous-unwind-tables -fno-unwind-tables -ffunction-sections -fdata-sections \
	   -march=armv8-a -mgeneral-regs-only -mstrict-align -mno-outline-atomics -ffixed-x18 \
	   $(WARN) -I. -Iinclude/libc -Iinclude -Ilibfdt -MMD -MP $(OPTS)
ASFLAGS	:= -nostdinc -fno-pic -fno-pie -march=armv8-a -g -Wall -Werror -MMD -MP
LDFLAGS	:= -T link.ld -nostdlib -static --no-dynamic-linker --gc-sections -z noexecstack \
	   --no-warn-rwx-segments --fatal-warnings

# Per-file flags. Upstream code keeps its warnings visible except the ones named here, file by file.
FLAGS_zlib/zlib.c	:= -D__UBOOT__ -Wno-sign-compare -Wno-unused-parameter
# start.S clears SCTLR.A and maps gzip buffers as Normal memory before this decoder runs.
$(foreach src,$(INFLATE),$(eval FLAGS_$(src) := -DFREESTANDING -mno-strict-align))
FLAGS_libdeflate/lib/deflate_decompress.c += -Wno-sign-compare -Wno-unused-parameter
FLAGS_lib/crc32.c	:= -march=armv8-a+crc
FLAGS_lib/string.c	:= -fno-tree-loop-distribute-patterns

all: zero-loader.bin $(O)/check.ok

.PHONY: identity
identity:
	$(PY) tools/profiles.py --check
	$(PY) tools/build_id.py

$(O)/build_id.h: identity
	@test -f $@

$(O)/%.o: %.c Makefile
	@mkdir -p $(@D)
	$(CC) $(CFLAGS) $(FLAGS_$<) -c $< -o $@

$(O)/fixup.o: $(O)/build_id.h

$(O)/%.o: %.S Makefile
	@mkdir -p $(@D)
	$(CC) $(ASFLAGS) -c $< -o $@

$(O)/zero-loader.elf: $(OBJS) link.ld
	$(LD) $(LDFLAGS) -Map $(O)/zero-loader.map -o $@ $(OBJS)

$(O)/zero-loader.raw: $(O)/zero-loader.elf
	$(OBJCOPY) -O binary $< $@

zero-loader.bin: $(O)/zero-loader.raw tools/mkloader.py zero_params.h
	$(PY) tools/mkloader.py zero_params.h $< $@

$(O)/check.ok: $(O)/zero-loader.elf zero-loader.bin tools/checkelf.py zero_params.h
	$(PY) tools/checkelf.py --params zero_params.h --elf $(O)/zero-loader.elf --bin zero-loader.bin \
		--objdump $(OBJDUMP) --readelf $(READELF) --nm $(NM)
	@touch $@

hosttest:
	$(PY) test/unit.py

captured-test: identity
	@test -n "$(FIXTURES)" -a -n "$(TEST_OUTPUT)" || { echo 'FIXTURES and TEST_OUTPUT are required'; exit 1; }
	$(PY) test/validation.py --fixtures "$(FIXTURES)" --output "$(TEST_OUTPUT)"

clean:
	rm -rf $(O) zero-loader.bin

.PHONY: all clean hosttest captured-test
-include $(OBJS:.o=.d)
