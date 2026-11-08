/* SPDX-License-Identifier: GPL-2.0+ */
#define _GNU_SOURCE
#include "offline_util.h"
#include "offline_soc.h"
#include "zl.h"
#include "rtc.h"
#include "monitor.h"
#include <libfdt.h>
#include <sys/mman.h>
#include <u-boot/zlib.h>

/* Load host MMIO declarations first, then include the unmodified production entry body. */
#undef ZL_HOST_TEST
#define main zl_loader_run
#include "../main.c"
#undef main
#define ZL_HOST_TEST 1

/* Reuse the existing register model; escape only the fatal 0.5 s kick, not the 16 s policy kick. */
#define write32 model_write32
#define zl_test_counter model_counter
#include "offline_soc.c"
#undef write32
#undef zl_test_counter
static int sticky_mode;
static unsigned long stall_after_write;
static unsigned stall_dat_count;
void write32(unsigned long addr, uint32_t value)
{
	uint32_t previous = addr == 0x07000118 ? read32(addr) : 0;
	model_write32(addr, value);
	if (sticky_mode && addr == 0x07000118) mock_set(addr, previous);
	if (addr == 0x030090b0 && read32(0x030090b8) == 1)
		longjmp(mock_jmp, 1);
}

uint64_t zl_test_counter(void)
{
	unsigned dat = 0;
	for (unsigned i = 0; i < mock_count; i++)
		if (mock_writes[i].addr == 0x0300b130) dat++;
	if (stall_dat_count && dat >= stall_dat_count) return counter_now;
	if (stall_after_write)
		for (unsigned i = 0; i < mock_count; i++)
			if (mock_writes[i].addr == stall_after_write) return counter_now;
	return model_counter();
}

static unsigned flushes, flush_at, entered, cases;
static unsigned long flushed_start, flushed_end, entered_monitor, entered_rvbar;
static uint32_t budget;
static unsigned char *dtb, *hdr, *monitor, *gzip;
static size_t dtb_len, hdr_len, monitor_len, gzip_len;
static struct zero_params *p = (void *)(ZL_HDR_ADDR + 2048);

/* Execute real inflate, asserting that production main began reset once and has not sampled PE6 yet. */
#define zl_gunzip zl_real_gunzip
#include "../gunzip.c"
#undef zl_gunzip
int zl_gunzip(void *dst, unsigned long max, const void *src, unsigned long len, unsigned long *out)
{
	unsigned gpio = 0;
	for (unsigned i = 0; i < mock_count; i++) {
		unsigned long addr = mock_writes[i].addr;
		if (addr == 0x0300b124 || addr == 0x0300b130) gpio++;
		CHECK(addr != 0x0300b090 && addr != 0x0300b0ac && addr != ZL_RTC_GP4);
	}
	CHECK(gpio == 5);
	CHECK(read32(0x0300b130) & (1u << 14));
	return zl_real_gunzip(dst, max, src, len, out);
}

void flush_dcache_range(unsigned long start, unsigned long end)
{
	flushes++; flush_at = mock_count; flushed_start = start; flushed_end = end;
}

void zl_enter_monitor(unsigned long mon, unsigned long rvbar)
{
	entered++; entered_monitor = mon; entered_rvbar = rvbar;
	longjmp(mock_jmp, 2);
}

static void map_at(uint64_t addr, size_t len)
{
	CHECK(mmap((void *)(uintptr_t)addr, len, PROT_READ | PROT_WRITE,
		MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED_NOREPLACE, -1, 0) == (void *)(uintptr_t)addr);
}

static void fresh(void)
{
	mock_reset(); mock_set(ZL_RTC_GP5, budget); mock_set(ZL_RTC_GP(14), 0x11223344);
	mock_set(0x03000024, 0);
	sticky_mode = 0; stall_after_write = 0; stall_dat_count = 0;
	flushes = entered = 0;
	memcpy((void *)ZL_HDR_ADDR, hdr, hdr_len);
	memcpy((void *)ZL_KGZ_ADDR, gzip, gzip_len);
	memcpy((void *)0x48000000, monitor, monitor_len);
	memset((void *)0x4a000000, 0xa5, ZL_STUB_SIZE + 16);
	memset((void *)0x4a200000, 0xa5, ZL_FDT_MAX + 16);
	memcpy((void *)0x4a200000, dtb, dtb_len);
	*p = (struct zero_params){
		.magic = ZP_MAGIC, .version = ZP_VERSION, .size = sizeof(*p), .flags = ZP_FLAG_CARD | ZP_PROFILE_PLUS,
		.monitor = 0x48000000, .uboot = 0x4a000000, .dtb = 0x4a200000, .dtb_len = dtb_len,
		.dtbo = 0x4a100000, .dtbo_len = 3072, .bootimg_hdr = ZL_HDR_ADDR,
		.kernel_gz = ZL_KGZ_ADDR, .kernel_gz_len = gzip_len, .ramdisk = 0x42000000,
		.ramdisk_len = 512, .kernel_addr = 0x40080000, .kernel_max = 0x1f80000,
		.fdt_max = ZL_FDT_MAX, .dram_mib = 1024, .pmic_boot_regs = 1,
	};
	memset((void *)(uintptr_t)(p->kernel_addr + p->kernel_max), 0xa5, 16);
}

static void execute(const char *name, struct zero_params *arg, uint32_t failure, unsigned completed)
{
	static const uint32_t marks[] = {0x41, 0x42, 0x43, 0x44, 0x45};
	unsigned char before_monitor[0xb8], before_stub[ZL_STUB_SIZE];
	unsigned seen = 0, wdt = 0, stamp0 = 0, stamp4 = 0;
	unsigned char *guard = p->kernel_addr == 0x40080000 && p->kernel_max && p->kernel_max <= 0x1f80000 ?
		(void *)(uintptr_t)(p->kernel_addr + p->kernel_max) : NULL;
	if (guard) memset(guard, 0xa5, 16);
	memcpy(before_monitor, (void *)0x48000000, sizeof(before_monitor));
	memcpy(before_stub, (void *)0x4a000000, sizeof(before_stub));
	int result = setjmp(mock_jmp);
	if (!result) {
		zl_loader_run(arg);
		CHECK(0);
	}
	CHECK(result == (failure ? 1 : 2));
	for (unsigned i = 0; i < mock_count; i++) {
		unsigned long addr = mock_writes[i].addr;
		if (addr == ZL_RTC_GP15) {
			CHECK(seen <= completed + !!failure);
			uint32_t step = seen <= completed ? marks[seen] : failure;
			CHECK(mock_writes[i].value == (0x5a560000u | step));
			seen++;
		}
		if (addr >= 0x030090b0 && addr <= 0x030090b8) wdt++;
		if (addr == ZL_RTC_GP0) stamp0++;
		if (addr == ZL_RTC_GP4) stamp4++;
		CHECK(addr != ZL_RTC_GP5 && addr != ZL_RTC_GP(14));
	}
	CHECK(seen == completed + 1 + !!failure);
	CHECK(read32(ZL_RTC_GP5) == budget && read32(ZL_RTC_GP(14)) == 0x11223344);
	CHECK(entered == !failure);
	CHECK(stamp0 == !failure && stamp4 == (completed >= 1));
	if (!completed) CHECK(!memcmp((void *)0x4a200000, dtb, dtb_len));
	CHECK(flushes == (completed >= 2));
	if (flushes) {
		CHECK(flushed_start == 0x4a200000 && flushed_end == 0x4a200000 + fdt_totalsize((void *)0x4a200000));
		CHECK(mock_writes[flush_at].addr == ZL_RTC_GP15 && mock_writes[flush_at].value == 0x5a560043);
	}
	if (failure) {
		CHECK(wdt == 3 && mock_count >= 4);
		unsigned n = mock_count - 4;
		CHECK(mock_writes[n].addr == ZL_RTC_GP15 && mock_writes[n].value == (0x5a560000u | failure));
		CHECK(mock_writes[n+1].addr == 0x030090b4 && mock_writes[n+1].value == 1);
		CHECK(mock_writes[n+2].addr == 0x030090b8 && mock_writes[n+2].value == 1);
		CHECK(mock_writes[n+3].addr == 0x030090b0 && mock_writes[n+3].value == 0x14af);
		CHECK(!memcmp(before_monitor, (void *)0x48000000, sizeof(before_monitor)));
		CHECK(!memcmp(before_stub, (void *)0x4a000000, sizeof(before_stub)));
	} else {
		int pending = (budget ^ 0x5d000000u) >= 1 && (budget ^ 0x5d000000u) <= 15;
		unsigned n = mock_count - (pending ? 5 : 3);
		CHECK(wdt == (pending ? 3u : 1u));
		if (pending) {
			CHECK(mock_writes[n].addr == 0x030090b4 && mock_writes[n].value == 1);
			CHECK(mock_writes[n+1].addr == 0x030090b8 && mock_writes[n+1].value == 0xb1);
			CHECK(mock_writes[n+2].addr == 0x030090b0 && mock_writes[n+2].value == 0x14af);
		} else CHECK(mock_writes[n].addr == 0x030090b8 && mock_writes[n].value == 0);
		CHECK(mock_writes[mock_count-2].addr == ZL_RTC_GP0);
		CHECK(mock_writes[mock_count-1].addr == ZL_RTC_GP15 && mock_writes[mock_count-1].value == 0x5a560045);
		CHECK(entered_monitor == 0x48000000);
		CHECK(entered_rvbar == ((read32(0x03000024) & 0xff) ? 0x08100040 : 0x09010040));
	}
	for (unsigned i = 0; i < 16; i++) {
		CHECK(((unsigned char *)0x42000000)[i] == 0xa5);
		CHECK(((unsigned char *)0x4a280000)[i] == 0xa5);
		CHECK(((unsigned char *)0x4a000000)[ZL_STUB_SIZE+i] == 0xa5);
		if (guard) CHECK(guard[i] == 0xa5);
	}
	printf("PASS lifecycle %s: GP15=%08x, completed=%u, watchdog writes=%u\n",
		name, read32(ZL_RTC_GP15), completed, wdt);
	cases++;
}

/* One stored DEFLATE block: a valid gzip envelope around an independently mutable Image header. */
static void tiny_image(uint64_t text_offset, uint64_t image_size, uint32_t magic)
{
	unsigned char member[87] = {0x1f,0x8b,8,0,0,0,0,0,0,3,1,64,0,0xbf,0xff};
	uint32_t crc, size = 64;
	memcpy(member + 15 + 8, &text_offset, 8);
	memcpy(member + 15 + 16, &image_size, 8);
	memcpy(member + 15 + 56, &magic, 4);
	crc = crc32(0, member + 15, 64);
	memcpy(member + 79, &crc, 4); memcpy(member + 83, &size, 4);
	memcpy((void *)ZL_KGZ_ADDR, member, sizeof(member)); p->kernel_gz_len = sizeof(member);
}

static void fdt_edit(const char *path, const char *key, const void *value, int len)
{
	void *fdt = (void *)0x4a200000;
	CHECK(fdt_open_into(fdt, fdt, ZL_FDT_MAX) == 0);
	int off = fdt_path_offset(fdt, path); CHECK(off >= 0);
	CHECK(value ? fdt_setprop(fdt, off, key, value, len) == 0 : fdt_del_node(fdt, off) == 0);
	CHECK(fdt_pack(fdt) == 0); p->dtb_len = fdt_totalsize(fdt);
}

int main(int argc, char **argv)
{
	CHECK(argc == 5);
	dtb = read_file(argv[1], &dtb_len); hdr = read_file(argv[2], &hdr_len);
	monitor = read_file(argv[3], &monitor_len); gzip = read_file(argv[4], &gzip_len);
	CHECK(hdr_len == 2048 && monitor_len >= 0xb8 && monitor_len <= 0x100000);
	CHECK(dtb_len < ZL_FDT_MAX && gzip_len <= ZL_KGZ_MAX);
	map_at(0x40080000, 0x1f81000); map_at(ZL_HDR_ADDR, 4096); map_at(ZL_KGZ_ADDR, ZL_KGZ_MAX);
	map_at(0x48000000, 0x100000); map_at(0x4a000000, 4096); map_at(0x4a200000, ZL_FDT_MAX + 4096);

	fresh(); execute("wrong-entry-pointer", NULL, 0x4d, 0); CHECK(mock_count == 5);
	fresh(); execute("wrong-entry-loader-address", (void *)ZL_LOAD_ADDR, 0x4d, 0); CHECK(mock_count == 5);
	fresh(); execute("wrong-entry-unaligned", (void *)(ZL_HDR_ADDR+2049), 0x4d, 0); CHECK(mock_count == 5);
#define BAD(field, value) do { fresh(); p->field = (value); execute("params-" #field "-" #value, p, 0x4d, 0); CHECK(mock_count == 5); } while (0)
	BAD(magic, 0); BAD(version, ZP_VERSION+1); BAD(size, sizeof(*p)-1); BAD(dram_mib, 192);
	BAD(dram_mib, 1025); BAD(dtb_len, 39); BAD(dtb_len, ZL_FDT_MAX+1);
	BAD(dtb, UINT64_MAX-7); BAD(kernel_gz_len, 0); BAD(kernel_gz_len, ZL_KGZ_MAX+1);
	BAD(kernel_max, 0); BAD(kernel_max, 0x1f80001); BAD(fdt_max, 39);
	BAD(ramdisk_len, UINT64_MAX); BAD(dtbo_len, UINT64_MAX);
	fresh();
	const uint64_t aliases[] = {0x48000000, 0x4a200000, 0x40080000, 0x4a000000,
		0x3ffffff8, 0x80000000-sizeof(*p)+8, UINT64_MAX-7};
	for (unsigned i=0;i<sizeof(aliases)/sizeof(aliases[0]);i++) CHECK(!zl_params_ok_at(p, aliases[i]));
	CHECK(zl_params_ok_at(p, ZL_LOAD_ADDR)); /* Read-only alias allowed here; main enforces the exact pointer. */
	p->dram_mib = 193; CHECK(zl_params_ok_at(p, ZL_HDR_ADDR+2048));

	const uint32_t modes[] = {0x5a,0x5c,0x5f,0x60};
	for (unsigned i=0;i<4;i++) {
		fresh(); mock_set(0x07000118,modes[i]); execute("recovery-request", p, 0x4d, 0);
		CHECK(read32(0x07000118)==modes[i] && mock_count==5);
	}
	fresh(); sticky_mode=1; execute("hardware-mode-clear-readback", p, 0x4d, 0);
	CHECK(read32(0x07000118)==0x12345678 && mock_count==6);
	fresh(); mock_clock(1,0); execute("hardware-counter-stall", p, 0x4d, 0);
	fresh(); ((unsigned char *)ZL_KGZ_ADDR)[0]^=1; execute("gzip-magic", p, 0x4e, 0);
	fresh(); p->kernel_gz_len--; execute("gzip-truncated", p, 0x4e, 0);
	fresh(); ((unsigned char *)ZL_KGZ_ADDR)[gzip_len-8]^=1; execute("gzip-crc", p, 0x4e, 0);
	fresh(); ((unsigned char *)ZL_KGZ_ADDR)[gzip_len-4]^=1; execute("gzip-isize", p, 0x4e, 0);
	fresh(); p->kernel_max=64; execute("gzip-capacity", p, 0x4e, 0);
	fresh(); tiny_image(0x80000,64,0); execute("Image-magic", p, 0x4e, 0);
	fresh(); tiny_image(UINT64_MAX,64,0x644d5241); execute("Image-offset-underflow", p, 0x4e, 0);
	fresh(); tiny_image(0x80001,64,0x644d5241); execute("Image-offset-alignment", p, 0x4e, 0);
	fresh(); tiny_image(0x80000,0x1f80001,0x644d5241); execute("Image-bss-over-cap", p, 0x4e, 0);
	fresh(); tiny_image(0x80000,63,0x644d5241); execute("Image-short-declared-size", p, 0x4e, 0);
	fresh(); tiny_image(0x80000,64,0x644d5241); p->kernel_max=63;
	execute("Image-short-output-buffer", p, 0x4e, 0);

	fresh(); ((unsigned char *)0x4a200000)[0]^=1; execute("FDT-magic", p, 0x4f, 1);
	fresh(); fdt_set_off_dt_struct((void *)0x4a200000, UINT32_MAX-3);
	execute("FDT-structure-offset", p, 0x4f, 1);
	fresh(); p->dtb_len=fdt_totalsize((void *)0x4a200000)-1; execute("FDT-truncated", p, 0x4f, 1);
	fresh(); p->fdt_max=dtb_len; execute("FDT-no-slack", p, 0x4f, 1);
	fresh(); CHECK(fdt_del_mem_rsv((void *)0x4a200000,0)==0); execute("FDT-no-monitor-reserve", p, 0x4f, 1);
	fresh(); fdt_edit("/dram",NULL,NULL,0); execute("FDT-no-dram-node", p, 0x4f, 1);
	fresh(); fdt_edit("/soc/charger0","pmu_safe_vol","x",2); execute("FDT-battery-policy", p, 0x4f, 1);
	fresh(); fdt_edit("/soc/power_sply","battery_exist","x",2); execute("FDT-battery-exist-size", p, 0x4f, 1);
	fresh(); fdt32_t bad_cells=cpu_to_fdt32(3); fdt_edit("/","#address-cells",&bad_cells,4);
	execute("FDT-address-cells", p, 0x4f, 1);
	fresh(); ((unsigned char *)ZL_HDR_ADDR)[0]^=1; execute("bootimg-magic", p, 0x4f, 1);
	fresh(); uint32_t ver=3; memcpy((void *)(ZL_HDR_ADDR+0x28),&ver,4); execute("bootimg-version", p, 0x4f, 1);
	fresh(); memset((void *)(ZL_HDR_ADDR+0x40),'x',512); execute("bootimg-unterminated-cmdline", p, 0x4f, 1);
	fresh(); ((unsigned char *)ZL_HDR_ADDR)[0x260]='x'; execute("bootimg-extra-cmdline", p, 0x4f, 1);
	fresh(); stall_after_write=0x0300b130; execute("panel-begin-clock-stall", p, 0x4d, 0);
	fresh(); stall_dat_count=2; execute("panel-reset-high-clock-stall", p, 0x4d, 0);
	fresh(); stall_dat_count=3; execute("panel-reset-low-clock-stall", p, 0x4d, 0);
	fresh(); stall_dat_count=4; execute("panel-reset-final-clock-stall", p, 0x4f, 1);
	fresh(); stall_after_write=0x0300b0ac; execute("FDT-panel-settle-clock-stall", p, 0x4f, 1);
	fresh(); ((unsigned char *)0x48000000)[4]^=1; execute("monitor-magic", p, 0x4d, 2);

	const uint32_t budgets[] = {0,0x5d000000,0x5d000001,0x5d00000f,0x5d000010,0x5c000001,0x5d010001,UINT32_MAX};
	for (unsigned i=0;i<sizeof(budgets)/sizeof(budgets[0]);i++) {
		budget=budgets[i]; fresh(); mock_set(0x03000024,i&1);
		execute("handoff-budget-and-rvbar", p, 0, 4);
		fresh(); p->magic=0; execute("fatal-overrides-budget", p, 0x4d, 0);
	}
	budget=0; fresh(); tiny_image(0x80000,0,0x644d5241); execute("Image-legacy-zero-size", p, 0, 4);
	free(dtb); free(hdr); free(monitor); free(gzip);
	printf("PASS production main lifecycle: %u cases, %u checks (MMIO/cache/monitor-entry mocked)\n", cases, checks);
	return 0;
}
