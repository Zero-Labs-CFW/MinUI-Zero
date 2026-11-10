// SPDX-License-Identifier: GPL-2.0+
/*
 * MinUI Zero loader host test (aarch64 Linux): runs the loader's gunzip.c, fixup.c, libdeflate, libfdt and crc32.c on
 * the real boot.img and boot package, with the host libc. test/hosttest.py extracts the inputs into <dir> and
 * compares out.dtb against the live tree afterwards.
 *
 *   hosttest <dir>    reads <dir>/{kernel.gz,Image,hdr.bin,dtb.bin,dtbo.bin,pin.bin,bootargs.txt}, writes out.dtb
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include <sys/auxv.h>
#include <libfdt.h>
#include "zl.h"
#include "rtc.h"

#ifndef HWCAP_CRC32
#define HWCAP_CRC32	(1 << 7)
#endif

void zl_crc32_force(int mode);
unsigned int crc32(unsigned int crc, const unsigned char *buf, unsigned int len);
extern uint32_t zl_test_sid[4];

static unsigned checks, fails;

#define CHECK(expr) do {							\
	checks++;								\
	if (!(expr)) {								\
		fails++;							\
		fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #expr);	\
	}									\
} while (0)

static unsigned char *slurp(const char *dir, const char *name, size_t *len, size_t extra)
{
	char path[1024];
	unsigned char *buf;
	FILE *f;
	long n;

	snprintf(path, sizeof(path), "%s/%s", dir, name);
	f = fopen(path, "rb");
	if (!f || fseek(f, 0, SEEK_END) || (n = ftell(f)) < 0 || fseek(f, 0, SEEK_SET)) {
		fprintf(stderr, "cannot read %s\n", path);
		exit(2);
	}
	buf = calloc(1, (size_t)n + extra + 1);
	if (!buf || fread(buf, 1, (size_t)n, f) != (size_t)n) {
		fprintf(stderr, "cannot read %s\n", path);
		exit(2);
	}
	fclose(f);
	*len = (size_t)n;
	return buf;
}

static double now(void)
{
	struct timespec t;

	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec + t.tv_nsec / 1e9;
}

static void test_crc(void)
{
	static const unsigned char v[] = "123456789";
	unsigned char buf[64];
	unsigned int i, a, b;

	for (i = 0; i < sizeof(buf); i++)
		buf[i] = (unsigned char)(i * 37 + 11);
	zl_crc32_force(1);
	CHECK(crc32(0, NULL, 0) == 0);
	CHECK(crc32(0, v, 9) == 0xcbf43926u);
	a = crc32(0, buf + 3, 50);
	if (getauxval(AT_HWCAP) & HWCAP_CRC32) {
		zl_crc32_force(2);
		CHECK(crc32(0, v, 9) == 0xcbf43926u);
		b = crc32(crc32(0, buf + 3, 7), buf + 10, 43);	/* split, odd alignment both sides */
		CHECK(a == b);
	} else {
		printf("note: host has no CRC32 instructions, table path only\n");
	}
}

static void test_gunzip(const char *dir)
{
	size_t gz_len, img_len;
	unsigned char *gz = slurp(dir, "kernel.gz", &gz_len, 64), *img = slurp(dir, "Image", &img_len, 0);
	unsigned long max = 0x2000000, out;
	unsigned char *dst = malloc(max + 16);
	int mode;

	for (mode = 1; mode <= 2; mode++) {
		double t;

		if (mode == 2 && !(getauxval(AT_HWCAP) & HWCAP_CRC32))
			break;
		zl_crc32_force(mode);
		memset(dst, 0xa5, max + 16);
		t = now();
		CHECK(zl_gunzip(dst, max, gz, gz_len, &out) == 0);
		t = now() - t;
		CHECK(out == img_len && !memcmp(dst, img, img_len));
		printf("gunzip (%s CRC): %zu -> %lu bytes in %.1f ms on this host\n", mode == 1 ? "table" : "CRC32X", gz_len,
		       out, t * 1e3);
	}
	/* refusals: output one byte short, truncated input, flipped data byte, flipped CRC, flipped ISIZE, garbage tail */
	CHECK(zl_gunzip(dst, img_len - 1, gz, gz_len, &out) != 0 && out == 0);
	CHECK(zl_gunzip(dst, max, gz, gz_len - 1, &out) != 0);
	gz[gz_len / 2] ^= 0x10;
	CHECK(zl_gunzip(dst, max, gz, gz_len, &out) != 0);
	gz[gz_len / 2] ^= 0x10;
	gz[gz_len - 8] ^= 1;
	CHECK(zl_gunzip(dst, max, gz, gz_len, &out) != 0);
	gz[gz_len - 8] ^= 1;
	gz[gz_len - 1] ^= 1;
	CHECK(zl_gunzip(dst, max, gz, gz_len, &out) != 0);
	gz[gz_len - 1] ^= 1;
	CHECK(zl_gunzip(dst, max, gz, gz_len + 16, &out) == 0 && out == img_len);	/* zero padding is fine */
	gz[gz_len + 3] = 1;
	CHECK(zl_gunzip(dst, max, gz, gz_len + 16, &out) != 0);
	free(dst);
	free(img);
	free(gz);
}

static void test_snum(void)
{
	static const uint32_t plus[4] = { 0x33806c00, 0x6c004808, 0x01071654, 0x4c921c12 };
	static const uint32_t small[4] = { 0, 0x00104808, 0x00000001, 0x0000000f };
	char s[32];

	CHECK(zl_snum(s, sizeof(s), plus) == 19 && !strcmp(s, "6c0010716544c921c12"));
	/* fixed width: "001" "00000001" "0000000f" */
	CHECK(zl_snum(s, sizeof(s), small) == 19 && !strcmp(s, "001" "00000001" "0000000f"));
	CHECK(zl_snum(s, 19, plus) < 0);	/* no room for the terminator */
}

static const void *prop(const void *fdt, const char *path, const char *name, int *len)
{
	int off = fdt_path_offset(fdt, path);

	return off < 0 ? NULL : fdt_getprop(fdt, off, name, len);
}

static int has_rsv(const void *fdt, uint64_t a, uint64_t n)
{
	uint64_t x, y;
	int i;

	for (i = 0; i < fdt_num_mem_rsv(fdt); i++)
		if (!fdt_get_mem_rsv(fdt, i, &x, &y) && x == a && y == n)
			return 1;
	return 0;
}

static void params(struct zero_params *p, unsigned char *fdt, size_t dtb_len, const unsigned char *hdr,
		   const unsigned char *dtbo, size_t dtbo_len, const unsigned char *pin)
{
	memset(p, 0, sizeof(*p));
	p->magic = ZP_MAGIC;
	p->version = ZP_VERSION;
	p->size = sizeof(*p);
	p->monitor = 0x48000000;
	p->uboot = 0x4a000000;
	p->dtb = (uintptr_t)fdt;
	p->dtb_len = dtb_len;
	p->dtbo = (uintptr_t)dtbo;
	p->dtbo_len = dtbo_len;
	p->bootimg_hdr = (uintptr_t)hdr;
	p->ramdisk = 0x42000000;	/* only written into the tree, never read */
	p->ramdisk_len = 512;
	p->kernel_addr = 0x40080000;
	p->kernel_max = 0x2000000;
	p->fdt_max = ZL_FDT_MAX;
	p->dram_mib = 1024;
	p->pmic_boot_regs = 1;		/* power-on by button, as the live cmdline (bootreason=button) */
	memcpy(p->dram_words, pin + 0x38, sizeof(p->dram_words));
	memcpy(p->board_block, pin + 0xf0, sizeof(p->board_block));
}

static void test_fdt(const char *dir)
{
	size_t dtb_len, hdr_len, dtbo_len, pin_len, args_len;
	unsigned char *dtb = slurp(dir, "dtb.bin", &dtb_len, 0), *hdr = slurp(dir, "hdr.bin", &hdr_len, 0);
	unsigned char *dtbo = slurp(dir, "dtbo.bin", &dtbo_len, 0), *pin = slurp(dir, "pin.bin", &pin_len, 0);
	char *args = (char *)slurp(dir, "bootargs.txt", &args_len, 0), path[1024];
	unsigned char *fdt = calloc(1, ZL_FDT_MAX), *bad;
	struct zero_params p;
	const fdt32_t *c;
	const char *s;
	FILE *f;
	int len, i;

	while (args_len && (args[args_len - 1] == '\n' || args[args_len - 1] == ' '))
		args[--args_len] = 0;
	memcpy(fdt, dtb, dtb_len);
	params(&p, fdt, dtb_len, hdr, dtbo, dtbo_len, pin);
	CHECK(zl_build_fdt(&p) == 0);
	CHECK(fdt_check_full(fdt, fdt_totalsize(fdt)) == 0);
	s = prop(fdt, "/chosen", "bootargs", &len);
	CHECK(s && len == (int)args_len + 1 && !strcmp(s, args));
	if (s && strcmp(s, args))
		fprintf(stderr, "bootargs:\n got  %s\n want %s\n", s, args);
	c = prop(fdt, "/chosen", "linux,initrd-start", &len);
	CHECK(c && len == 8 && fdt32_to_cpu(c[0]) == 0 && fdt32_to_cpu(c[1]) == 0x42000000);
	c = prop(fdt, "/chosen", "linux,initrd-end", &len);
	CHECK(c && len == 8 && fdt32_to_cpu(c[0]) == 0 && fdt32_to_cpu(c[1]) == 0x42000200);
	CHECK(has_rsv(fdt, 0x48000000, 0x1000000) && has_rsv(fdt, 0x42000000, 512));
	c = prop(fdt, "/memory@40000000", "reg", &len);
	CHECK(c && len == 16 && fdt32_to_cpu(c[0]) == 0 && fdt32_to_cpu(c[1]) == 0x40000000 &&
	      fdt32_to_cpu(c[2]) == 0 && fdt32_to_cpu(c[3]) == 0x40000000);
	c = prop(fdt, "/soc/platform", "debug_mode", &len);
	CHECK(c && len == 4);
	c = prop(fdt, "/dram", "dram_tpr11", &len);
	CHECK(c && len == 4 && fdt32_to_cpu(*c) == p.dram_words[21]);
	snprintf(path, sizeof(path), "%s/out.dtb", dir);
	f = fopen(path, "wb");
	CHECK(f && fwrite(fdt, 1, fdt_totalsize(fdt), f) == fdt_totalsize(fdt));
	if (f)
		fclose(f);
	printf("fdt: %zu -> %u bytes, bootargs %d bytes, %d reserved ranges\n", dtb_len, fdt_totalsize(fdt),
	       (int)strlen(args), fdt_num_mem_rsv(fdt));

	/* refusals */
	bad = calloc(1, ZL_FDT_MAX);
	memcpy(bad, dtb, dtb_len);
	params(&p, bad, dtb_len - 1, hdr, dtbo, dtbo_len, pin);		/* read short of totalsize */
	CHECK(zl_build_fdt(&p) != 0);
	memcpy(bad, dtb, dtb_len);
	params(&p, bad, dtb_len, hdr, dtbo, dtbo_len, pin);
	p.fdt_max = dtb_len - 8;					/* no room */
	CHECK(zl_build_fdt(&p) != 0);
	memcpy(bad, dtb, dtb_len);
	hdr[0] ^= 1;							/* not a boot.img header */
	params(&p, bad, dtb_len, hdr, dtbo, dtbo_len, pin);
	CHECK(zl_build_fdt(&p) != 0);
	hdr[0] ^= 1;
	memcpy(bad, dtb, dtb_len);
	params(&p, bad, dtb_len, hdr, dtbo, dtbo_len, pin);
	p.ramdisk_len = 0;						/* no ramdisk: no initrd properties */
	CHECK(zl_build_fdt(&p) == 0 && !prop(bad, "/chosen", "linux,initrd-start", &len) &&
	      !has_rsv(bad, 0x42000000, 512));
	for (i = 0; i < 4; i++)
		zl_test_sid[i] = 0;
	memcpy(bad, dtb, dtb_len);
	params(&p, bad, dtb_len, hdr, dtbo, dtbo_len, pin);
	CHECK(zl_build_fdt(&p) == 0);
	s = prop(bad, "/chosen", "bootargs", &len);
	CHECK(s && strstr(s, " snum=" "000" "00000000" "00000000" " "));
	free(bad);
	free(fdt);
	free(args);
	free(pin);
	free(dtbo);
	free(hdr);
	free(dtb);
}

int main(int argc, char **argv)
{
	if (argc != 2) {
		fprintf(stderr, "usage: hosttest <dir>\n");
		return 2;
	}
	test_crc();
	test_snum();
	test_gunzip(argv[1]);
	test_fdt(argv[1]);
	printf("%s: %u checks, %u failed\n", fails ? "FAIL" : "PASS", checks, fails);
	return fails ? 1 : 0;
}
