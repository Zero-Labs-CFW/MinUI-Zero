#include "offline_util.h"
#include "offline_soc.h"
#include "monitor.h"
#include "rtc.h"
#include "zl.h"
#include <stddef.h>

static struct zero_params qualified(void)
{
	struct zero_params p = {0};
	p.magic = ZP_MAGIC; p.version = ZP_VERSION; p.size = sizeof(p); p.flags = ZP_FLAG_CARD;
	p.monitor = 0x48000000; p.uboot = 0x4a000000; p.dtb = 0x4a200000; p.dtb_len = 137714;
	p.dtbo = 0x4a100000; p.dtbo_len = 3072; p.bootimg_hdr = ZL_HDR_ADDR;
	p.kernel_gz = ZL_KGZ_ADDR; p.kernel_gz_len = 7244333; p.ramdisk = 0x42000000; p.ramdisk_len = 512;
	p.kernel_addr = 0x40080000; p.kernel_max = 0x1f80000; p.fdt_max = ZL_FDT_MAX; p.dram_mib = 1024;
	p.pmic_boot_regs = 1;
	return p;
}
int main(int argc, char **argv)
{
	struct zero_params p = qualified(), q;
	unsigned long pa = ZL_HDR_ADDR + 2048;
	size_t monitor_len, image_len;
	unsigned char *monitor, *original, *image;
	unsigned char stub[ZL_STUB_SIZE + 16];
	CHECK(argc == 4);
	monitor = read_file(argv[1], &monitor_len); image = read_file(argv[2], &image_len);
	original = malloc(monitor_len); CHECK(original != NULL); memcpy(original, monitor, monitor_len);
	CHECK(zl_params_ok_at(&p, pa)); CHECK(!zl_params_ok_at(NULL, pa));
#define BAD(field, value) do { q=p; q.field=(value); CHECK(!zl_params_ok_at(&q, pa)); } while (0)
	BAD(magic,0); BAD(version,ZP_VERSION+1); BAD(size,sizeof(p)-1); BAD(dram_mib,0); BAD(dram_mib,1025);
	BAD(monitor,0x48000004); BAD(uboot,0x4a000004); BAD(dtb,0x4a200001); BAD(dtb_len,39);
	BAD(dtb_len,ZL_FDT_MAX+1); BAD(fdt_max,ZL_FDT_MAX+1); BAD(fdt_max,1); BAD(kernel_gz,0x48000000);
	BAD(kernel_gz_len,0); BAD(kernel_gz_len,ZL_KGZ_MAX+1); BAD(kernel_addr,0x40080004);
	BAD(kernel_max,0x1f80001); BAD(kernel_max,0); BAD(ramdisk,0x48000000); BAD(ramdisk_len,0x100001);
	BAD(dtbo,0x4a200000); BAD(dtbo_len,0x100001); BAD(bootimg_hdr,0x44f00004);
	CHECK(!zl_params_ok_at(&p, pa+1)); CHECK(!zl_params_ok_at(&p, UINT64_MAX-7));
	/* Backend layout supports 2 GiB, but every accessed byte stays in the first mapped GiB. */
	q=p; q.dram_mib=2048; CHECK(zl_params_ok_at(&q, pa));
	CHECK(!zl_params_ok_at(&q, 0x80000000ull));
	BAD(dram_mib,2049); BAD(dram_mib,UINT32_MAX);
	q=p; q.ramdisk_len=0; q.dtbo_len=0; CHECK(zl_params_ok_at(&q, pa));
	CHECK(zl_image_ok(image, p.kernel_addr, p.kernel_max, image_len));
	CHECK(!zl_image_ok(image, p.kernel_addr+4, p.kernel_max, image_len));
	CHECK(!zl_image_ok(image, p.kernel_addr, image_len-1, image_len));
	CHECK(!zl_image_ok(image, p.kernel_addr, p.kernel_max, 63));
	image[56] ^= 1; CHECK(!zl_image_ok(image, p.kernel_addr, p.kernel_max, image_len)); image[56] ^= 1;
	for (unsigned i=0;i<32;i++) p.dram_words[i]=0x11111111u*i;
	p.dram_words[23]=0; memcpy(p.board_block,"BOARD123",8);
	memset(stub,0xa5,sizeof(stub));
	CHECK(zl_prepare_monitor(monitor,monitor_len,stub,ZL_STUB_SIZE,&p)==0);
	CHECK(!memcmp(monitor+0x24,p.board_block,8)); CHECK(!memcmp(monitor+0x30,p.dram_words,128));
	uint64_t fdt; memcpy(&fdt,monitor+0xb0,8); CHECK(fdt==p.dtb);
	for(size_t i=0;i<monitor_len;i++) {
		int changed=(i>=0x14&&i<0x1c)||(i>=0x24&&i<0x2c)||(i>=0x30&&i<0xb8);
		if(!changed) CHECK(monitor[i]==original[i]);
	}
	const uint32_t expected[20]={0xe59f0038,0xe59f1040,0xe3a02000,0xe3a03000,0xf57ff04f,0xf57ff06f,0xe1600070,
		0xe59f0020,0xe59f1020,0xe59f2020,0xe3a03001,0xf57ff04f,0xf57ff06f,0xe1600070,
		0xe320f003,0xeafffffd,0x8000ff14,0x8000ff04,0x40080000,0x4a200000};
	CHECK(!memcmp(stub,expected,sizeof(expected)));
	for(unsigned i=ZL_STUB_SIZE;i<sizeof(stub);i++) CHECK(stub[i]==0xa5);
	write_file(argv[3],stub,ZL_STUB_SIZE);
	CHECK(zl_prepare_monitor(monitor,0xb7,stub,ZL_STUB_SIZE,&p)<0);
	CHECK(zl_prepare_monitor(monitor,monitor_len,stub,ZL_STUB_SIZE-1,&p)<0);
	q=p;q.monitor+=4; CHECK(zl_prepare_monitor(monitor,monitor_len,stub,ZL_STUB_SIZE,&q)<0);
	mock_reset(); CHECK(!strcmp(zl_lcd_type(),"old")); CHECK(mock_count==7);
	CHECK(mock_writes[0].addr==0x0300b124 && mock_writes[0].value==0x11cdef01);
	CHECK(mock_writes[1].addr==0x0300b130 && mock_writes[1].value==0x12348000);
	CHECK(mock_writes[2].addr==0x0300b130 && mock_writes[2].value==0x1234c000);
	CHECK(mock_writes[3].addr==0x0300b130 && mock_writes[3].value==0x12348000);
	CHECK(mock_writes[4].addr==0x0300b130 && mock_writes[4].value==0x1234c000);
	const unsigned delays[]={30000,15000,50000,100000};
	for(unsigned i=0;i<4;i++) CHECK(mock_writes[i+2].ticks-mock_writes[i+1].ticks>=(uint64_t)delays[i]*24);
	CHECK(read32(0x0300b090)==((0xabcdef01u&~(0xfu<<24))|(6u<<24)));
	CHECK(read32(0x0300b0ac)==((0x76543210u&~(3u<<12))|(1u<<12)));
	mock_set(0x0300b0a0,0); CHECK(!strcmp(zl_lcd_type(),"boe"));
	mock_reset();mock_clock(2400123,0);CHECK(zl_lcd_type()==NULL);CHECK(mock_count==2);
	for(unsigned budget=0;budget<=16;budget++) {
		mock_reset();mock_set(ZL_RTC_GP5,0x5d000000|budget);zl_wdog_policy();
		if(budget>=1&&budget<=15) {
			CHECK(mock_count==3);CHECK(mock_writes[0].addr==0x030090b4&&mock_writes[0].value==1);
			CHECK(mock_writes[1].addr==0x030090b8&&mock_writes[1].value==0xb1);
			CHECK(mock_writes[2].addr==0x030090b0&&mock_writes[2].value==0x14af);
		} else { CHECK(mock_count==1);CHECK(mock_writes[0].addr==0x030090b8&&mock_writes[0].value==0); }
		CHECK(read32(ZL_RTC_GP5)==(0x5d000000|budget));
	}
	mock_reset();mock_set(ZL_RTC_GP5,0x5c000001);zl_wdog_policy();CHECK(mock_count==1&&mock_writes[0].value==0);
	mock_reset();mock_reset_escape(1);
	if(!setjmp(mock_jmp)) zl_reset_now();
	CHECK(mock_count==3&&mock_writes[1].value==1&&mock_writes[2].value==0x14af);
	mock_reset();CHECK(zl_prepare_hardware()==0);
	CHECK(read32(0x07000118)==0);
	CHECK(read32(0x03000000)==0);
	CHECK(read32(0x03000004)==(0x12345678u & ~(1u<<24)));
	CHECK(read32(0x03001804)==0x12345679);
	CHECK(read32(0x0300170c)==((0x12345678u|(1u<<16))&~1u));
	const unsigned long plls[]={0x03001028,0x03001040,0x03001048,0x03001050,0x03001060};
	for(unsigned i=0;i<5;i++) CHECK(read32(plls[i])==0x92345678);
	const unsigned modes[]={0x5a,0x5c,0x5f,0x60};
	for(unsigned i=0;i<4;i++) {
		mock_reset();mock_set(0x07000118,modes[i]);CHECK(zl_prepare_hardware()<0);
		CHECK(mock_count==0&&read32(0x07000118)==modes[i]);
	}
	mock_reset();mock_clock(1,0);CHECK(zl_prepare_hardware()<0);
	mock_reset(); const uint32_t marks[]={0x41,0x42,0x43,0x44,0x45,0x4d,0x4e,0x4f};
	for(unsigned i=0;i<sizeof(marks)/sizeof(marks[0]);i++) {
		zl_mark(marks[i]);CHECK(mock_writes[i].addr==ZL_RTC_GP15&&mock_writes[i].value==(ZL_MARK_BASE|marks[i]));
	}
	mock_clock(2400123,0);
	zl_stamp(ZL_RTC_GP4);CHECK(read32(ZL_RTC_GP4)==100005);
	zl_stamp(ZL_RTC_GP0);CHECK(read32(ZL_RTC_GP0)==100005);
	printf("PASS monitor/params/Image/RTC/watchdog/PE6: %u checks; ABI size=%zu pmic_offset=%zu\n",
		checks,sizeof(p),offsetof(struct zero_params,pmic_boot_regs));
	free(monitor);free(original);free(image);return 0;
}
