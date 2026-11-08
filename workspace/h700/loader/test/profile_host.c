/* SPDX-License-Identifier: GPL-2.0+ */
/* Host-only driver: production profile.c/SHA, read-only guarded inputs, no MMIO mocks. */
#define _GNU_SOURCE
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include "profile.h"
#include "lib/sha256.h"

#define CHECK(c) do { if (!(c)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #c); exit(1); } } while (0)
struct region { uint8_t *base, *data; size_t span, size; };
struct fixture { uint32_t id, ram, lengths[8]; const void *parts[8]; struct region regions[8]; };
static size_t page;
static unsigned checks;

static void read_exact(void *p, size_t n) { CHECK(fread(p, 1, n, stdin) == n); }
static uint32_t le32(const void *p)
{
    const uint8_t *b = p;
    return b[0] | (uint32_t)b[1]<<8 | (uint32_t)b[2]<<16 | (uint32_t)b[3]<<24;
}
static uint32_t read_word(void) { uint8_t b[4]; read_exact(b, 4); return le32(b); }
static struct region region_new(size_t n)
{
    size_t span = ((n ? n : 1) + page - 1) / page * page;
    uint8_t *base = mmap(NULL, span + 2*page, PROT_NONE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
    CHECK(base != MAP_FAILED);
    CHECK(!mprotect(base + page, span, PROT_READ|PROT_WRITE));
    return (struct region){base, base + page + span - n, span, n};
}
static void region_protect(struct region *r, int prot) { CHECK(!mprotect(r->base + page, r->span, prot)); }
static void region_free(struct region *r) { CHECK(!munmap(r->base, r->span + 2*page)); }

static void expect_match(const void *parts[8], uint32_t lengths[8], uint32_t ram, unsigned expected)
{
    const void *saved_parts[8];
    uint32_t saved_lengths[8];
    memcpy(saved_parts, parts, sizeof(saved_parts));
    memcpy(saved_lengths, lengths, sizeof(saved_lengths));
    CHECK(zl_profile_match(parts, lengths, ram) == expected);
    CHECK(!memcmp(parts, saved_parts, sizeof(saved_parts)));
    CHECK(!memcmp(lengths, saved_lengths, sizeof(saved_lengths)));
    checks++;
}

static void sha_tests(void)
{
    uint32_t count = read_word();
    CHECK(count && count < 1000);
    for (uint32_t i = 0; i < count; i++) {
        uint32_t n = read_word(), chunk = read_word(), at = 0;
        uint8_t expected[32], actual[32];
        sha256_context ctx;
        CHECK(n <= 1000000 && chunk);
        struct region r = region_new(n);
        read_exact(r.data, n); read_exact(expected, 32);
        region_protect(&r, PROT_READ);
        memset(&ctx, 0xa5, sizeof(ctx));
        sha256_starts(&ctx);
        sha256_update(&ctx, r.data, 0);
        while (at < n) {
            uint32_t take = n - at < chunk ? n - at : chunk;
            sha256_update(&ctx, r.data + at, take);
            at += take;
        }
        sha256_finish(&ctx, actual);
        CHECK(!memcmp(actual, expected, 32));
        region_free(&r);
    }
    printf("PASS SHA256 known-answer/padding/chunk tests: %u\n", count);
}

static void fixture_read(struct fixture *f)
{
    f->id = read_word(); f->ram = read_word();
    for (unsigned i = 0; i < 8; i++) {
        f->lengths[i] = read_word();
        CHECK(f->lengths[i] && f->lengths[i] <= 32*1024*1024);
        f->regions[i] = region_new(f->lengths[i]);
        f->parts[i] = f->regions[i].data;
        read_exact(f->regions[i].data, f->lengths[i]);
        region_protect(&f->regions[i], PROT_READ);
    }
}

static int same_fixture(const void *parts[8], const uint32_t lengths[8], const struct fixture *f)
{
    for (unsigned i = 0; i < 8; i++)
        if (lengths[i] != f->lengths[i] || memcmp(parts[i], f->parts[i], lengths[i]))
            return 0;
    return 1;
}

static void profile_tests(struct fixture f[2])
{
    for (unsigned row = 0; row < 2; row++) {
        struct fixture *a = &f[row];
        expect_match(a->parts, a->lengths, a->ram, a->id);
        for (unsigned i = 0; i < 8; i++) {
            uint32_t original = a->lengths[i];
            const uint32_t bad[] = {0, original-1, original+1, UINT32_MAX};
            for (unsigned j = 0; j < sizeof(bad)/sizeof(bad[0]); j++) {
                a->lengths[i] = bad[j];
                expect_match(a->parts, a->lengths, a->ram, 0);
            }
            a->lengths[i] = original;
            const void *saved = a->parts[i];
            a->parts[i] = NULL;
            expect_match(a->parts, a->lengths, a->ram, 0);
            a->parts[i] = saved;
            const size_t positions[] = {0, original/2, original-1};
            for (unsigned j = 0; j < 3; j++) {
                struct region *r = &a->regions[i];
                region_protect(r, PROT_READ|PROT_WRITE);
                r->data[positions[j]] ^= 1;
                region_protect(r, PROT_READ);
                expect_match(a->parts, a->lengths, a->ram, 0);
                region_protect(r, PROT_READ|PROT_WRITE);
                r->data[positions[j]] ^= 1;
                region_protect(r, PROT_READ);
            }
        }
        const uint32_t bad_ram[] = {0, 512, 1023, 1025, 2048, UINT32_MAX};
        for (unsigned j = 0; j < sizeof(bad_ram)/sizeof(bad_ram[0]); j++)
            expect_match(a->parts, a->lengths, bad_ram[j], 0);
        const void *unreadable[8] = {(void *)1, (void *)1, (void *)1, (void *)1,
                                    (void *)1, (void *)1, (void *)1, (void *)1};
        uint32_t wrong_lengths[8];
        memcpy(wrong_lengths, a->lengths, sizeof(wrong_lengths));
        wrong_lengths[0]++;
        expect_match(unreadable, wrong_lengths, a->ram, 0);
        expect_match(unreadable, a->lengths, 0, 0);
        expect_match(a->parts, a->lengths, a->ram, a->id);
    }
    for (unsigned mask = 0; mask < 256; mask++) {
        const void *parts[8]; uint32_t lengths[8];
        for (unsigned i = 0; i < 8; i++) {
            unsigned row = (mask >> i) & 1;
            parts[i] = f[row].parts[i]; lengths[i] = f[row].lengths[i];
        }
        unsigned expected = same_fixture(parts, lengths, &f[0]) ? f[0].id :
                            same_fixture(parts, lengths, &f[1]) ? f[1].id : 0;
        expect_match(parts, lengths, f[0].ram, expected);
    }
    printf("PASS production matcher: %u checks, all 256 component mixes, byte/length/RAM/null mutations; inputs read-only\n", checks);
}

#if defined(__linux__) && defined(__aarch64__)
/* Preserve the host caller, then seed every platform/callee-saved GPR before BLR. */
extern unsigned long profile_abi_call(void *, const struct zero_params *, unsigned int *);
__asm__(
".text\n.balign 4\n.global profile_abi_call\n.type profile_abi_call,%function\n"
"profile_abi_call:\n"
" sub sp,sp,#128\n stp x18,x19,[sp,#0]\n stp x20,x21,[sp,#16]\n"
" stp x22,x23,[sp,#32]\n stp x24,x25,[sp,#48]\n stp x26,x27,[sp,#64]\n"
" stp x28,x29,[sp,#80]\n str x30,[sp,#96]\n str x2,[sp,#104]\n"
" mov x3,sp\n str x3,[sp,#112]\n mov x16,x0\n mov x0,x1\n"
" mov x18,#0x1818\n mov x19,#0x1919\n mov x20,#0x2020\n mov x21,#0x2121\n"
" mov x22,#0x2222\n mov x23,#0x2323\n mov x24,#0x2424\n mov x25,#0x2525\n"
" mov x26,#0x2626\n mov x27,#0x2727\n mov x28,#0x2828\n mov x29,#0x2929\n"
" blr x16\n ldr x2,[sp,#104]\n str w0,[x2]\n mov x0,#0\n"
#define ABI_CHECK(reg, val) " mov x17,#" #val "\n cmp " #reg ",x17\n cset x1,ne\n orr x0,x0,x1\n"
ABI_CHECK(x18,0x1818) ABI_CHECK(x19,0x1919) ABI_CHECK(x20,0x2020) ABI_CHECK(x21,0x2121)
ABI_CHECK(x22,0x2222) ABI_CHECK(x23,0x2323) ABI_CHECK(x24,0x2424) ABI_CHECK(x25,0x2525)
ABI_CHECK(x26,0x2626) ABI_CHECK(x27,0x2727) ABI_CHECK(x28,0x2828) ABI_CHECK(x29,0x2929)
#undef ABI_CHECK
" mov x3,sp\n ldr x4,[sp,#112]\n cmp x3,x4\n cset x1,ne\n orr x0,x0,x1\n"
" ldp x18,x19,[sp,#0]\n ldp x20,x21,[sp,#16]\n ldp x22,x23,[sp,#32]\n"
" ldp x24,x25,[sp,#48]\n ldp x26,x27,[sp,#64]\n ldp x28,x29,[sp,#80]\n"
" ldr x30,[sp,#96]\n add sp,sp,#128\n ret\n.size profile_abi_call,.-profile_abi_call\n");

static void image_tests(struct fixture f[2], const char *path, uintptr_t bss, size_t bss_size)
{
    CHECK(bss >= ZL_LOAD_ADDR+64 && bss < ZL_LOAD_ADDR+ZL_LOAD_MAX &&
          bss_size && bss_size <= ZL_LOAD_ADDR+ZL_LOAD_MAX-bss);
    FILE *fp = fopen(path, "rb");
    CHECK(fp && !fseek(fp, 0, SEEK_END));
    long file_size = ftell(fp);
    CHECK(file_size >= 512 && file_size <= (long)ZL_LOAD_MAX && !fseek(fp, 0, SEEK_SET));
    uint8_t *image = malloc((size_t)file_size);
    CHECK(image && fread(image, 1, (size_t)file_size, fp) == (size_t)file_size && !fclose(fp));
    uint32_t entry = le32(image+24), sum = 0;
    CHECK(!memcmp(image, ZL_HDR_MAGIC, 8) && le32(image+8) == (uint32_t)file_size &&
          !(file_size & 511) && le32(image+12) == 64 && le32(image+20) == ZL_IMAGE_VERSION &&
          entry >= 64 && entry <= (uint32_t)file_size-4 && !(entry & 3));
    for (long i = 0; i < file_size; i += 4)
        sum += i == 16 ? ZL_SUM_STAMP : le32(image+i);
    CHECK(sum == le32(image+16));
    uint8_t *loaded = mmap((void *)(uintptr_t)ZL_LOAD_ADDR, ZL_LOAD_MAX, PROT_READ|PROT_WRITE,
                          MAP_PRIVATE|MAP_ANONYMOUS|MAP_FIXED_NOREPLACE, -1, 0);
    CHECK(loaded == (void *)(uintptr_t)ZL_LOAD_ADDR);
    const uintptr_t addresses[8] = {0x42e00000, 0x48000000, 0x4a000000, 0x4a200000,
                                     0x4a100000, ZL_HDR_ADDR, ZL_KGZ_ADDR, 0x42000000};
    unsigned calls = 0;
    for (unsigned row = 0; row < 2; row++) {
        size_t sizes[8];
        for (unsigned i = 0; i < 8; i++) {
            sizes[i] = (f[row].lengths[i] + page-1) / page * page;
            if (i == 5) sizes[i] = 2*page;
            void *p = mmap((void *)addresses[i], sizes[i], PROT_READ|PROT_WRITE,
                           MAP_PRIVATE|MAP_ANONYMOUS|MAP_FIXED_NOREPLACE, -1, 0);
            CHECK(p == (void *)addresses[i]);
            memcpy(p, f[row].parts[i], f[row].lengths[i]);
        }
        struct zero_params *p = (void *)(uintptr_t)(ZL_HDR_ADDR+2048);
        *p = (struct zero_params){.magic=ZP_MAGIC, .version=ZP_VERSION, .size=sizeof(*p),
            .flags=ZP_FLAG_CARD, .dram_mib=f[row].ram, .monitor=addresses[1], .uboot=addresses[2],
            .dtb=addresses[3], .dtb_len=f[row].lengths[3], .dtbo=addresses[4], .dtbo_len=f[row].lengths[4],
            .toc1_head=addresses[0], .toc1_head_len=f[row].lengths[0], .toc1_len=le32(f[row].parts[0]+36),
            .bootimg_hdr=addresses[5], .kernel_gz=addresses[6], .kernel_gz_len=f[row].lengths[6],
            .ramdisk=addresses[7], .ramdisk_len=f[row].lengths[7], .kernel_addr=0x40080000,
            .kernel_max=0x42000000-0x40080000, .fdt_max=ZL_FDT_MAX};
        struct zero_params saved = *p;
        for (unsigned i = 0; i < 8; i++) CHECK(!mprotect((void *)addresses[i], sizes[i], PROT_READ));
        const unsigned char poison[] = {0xa5, 0x5a, 0};
        for (unsigned pass = 0; pass < sizeof(poison); pass++) {
            CHECK(!mprotect(loaded, ZL_LOAD_MAX, PROT_READ|PROT_WRITE));
            memset(loaded, poison[pass], ZL_LOAD_MAX);
            memcpy(loaded, image, (size_t)file_size);
            /* BSS can start inside the packer's final sector of zero padding. */
            memset((void *)bss, poison[pass], bss_size);
            __builtin___clear_cache((char *)loaded, (char *)loaded+file_size);
            CHECK(!mprotect(loaded, ZL_LOAD_MAX, PROT_READ|PROT_EXEC));
            unsigned result = 0;
            CHECK(!profile_abi_call(loaded+entry, p, &result) && result == f[row].id);
            CHECK(!memcmp(p, &saved, sizeof(saved)));
            calls++;
            CHECK(!mprotect((void *)(uintptr_t)ZL_HDR_ADDR, sizes[5], PROT_READ|PROT_WRITE));
            p->dram_mib = 2048;
            CHECK(!mprotect((void *)(uintptr_t)ZL_HDR_ADDR, sizes[5], PROT_READ));
            CHECK(!profile_abi_call(loaded+entry, p, &result) && result == 0);
            calls++;
            CHECK(!mprotect((void *)(uintptr_t)ZL_HDR_ADDR, sizes[5], PROT_READ|PROT_WRITE));
            *p = saved;
            /* Real binary rejection after content hashing, not just a guard return. */
            ((uint8_t *)(uintptr_t)ZL_HDR_ADDR)[100] ^= 1;
            CHECK(!mprotect((void *)(uintptr_t)ZL_HDR_ADDR, sizes[5], PROT_READ));
            CHECK(!profile_abi_call(loaded+entry, p, &result) && result == 0);
            calls++;
            CHECK(!mprotect((void *)(uintptr_t)ZL_HDR_ADDR, sizes[5], PROT_READ|PROT_WRITE));
            ((uint8_t *)(uintptr_t)ZL_HDR_ADDR)[100] ^= 1;
            CHECK(!mprotect((void *)(uintptr_t)ZL_HDR_ADDR, sizes[5], PROT_READ));
        }
        for (unsigned i = 0; i < 8; i++) CHECK(!munmap((void *)addresses[i], sizes[i]));
    }
    CHECK(!munmap(loaded, ZL_LOAD_MAX));
    free(image);
    printf("PASS ACTUAL zero-loader.bin preflight: %u calls, Plus/H accept + RAM/content refusal, 3 BSS poisons, RX image/read-only inputs, x18-x29/SP preserved; no MMIO mocks\n", calls);
}
#endif

int main(int argc, char **argv)
{
    (void)argv;
    page = (size_t)sysconf(_SC_PAGESIZE);
    CHECK(page && (argc == 1 || argc == 4));
    setvbuf(stdout, NULL, _IOLBF, 0);
    sha_tests();
    struct fixture f[2];
    for (unsigned i = 0; i < 2; i++) fixture_read(&f[i]);
    CHECK(f[0].id == 1 && f[1].id == 2 && f[0].ram == 1024 && f[1].ram == 1024);
    CHECK(fgetc(stdin) == EOF);
    profile_tests(f);
    if (argc == 4) {
#if defined(__linux__) && defined(__aarch64__)
        image_tests(f, argv[1], (uintptr_t)strtoull(argv[2], NULL, 0), (size_t)strtoull(argv[3], NULL, 0));
#else
        fprintf(stderr, "Actual binary execution requires Linux AArch64\n");
        return 2;
#endif
    }
    for (unsigned row = 0; row < 2; row++)
        for (unsigned i = 0; i < 8; i++) region_free(&f[row].regions[i]);
    return 0;
}
