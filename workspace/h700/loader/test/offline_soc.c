#include "rtc.h"
#include "offline_soc.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
struct mock_write mock_writes[128];
unsigned mock_count;
static struct mock_write registers[128];
static unsigned register_count;
static int reset_escape;
static uint64_t counter_now, counter_step;
jmp_buf mock_jmp;
void mock_set(unsigned long addr, uint32_t value)
{
	for (unsigned i = 0; i < register_count; i++)
		if (registers[i].addr == addr) { registers[i].value = value; return; }
	if (register_count == 128) abort();
	registers[register_count++] = (struct mock_write){addr, value, 0};
}
void mock_reset(void)
{
	register_count = mock_count = 0;
	reset_escape = 0;
	counter_now = 2400123; counter_step = 24000;
	mock_set(0x03006200, 0x33806c00);
	mock_set(0x03006204, 0x6c004808);
	mock_set(0x03006208, 0x01071654);
	mock_set(0x0300620c, 0x4c921c12);
	mock_set(0x0300b090, 0xabcdef01);
	mock_set(0x0300b0ac, 0x76543210);
	mock_set(0x0300b0a0, 0x40);
	mock_set(0x0300b124, 0xabcdef01);
	mock_set(0x0300b130, 0x12340000);
	mock_set(ZL_RTC_GP5, 0);
	const unsigned long hardware[] = {0x03001028,0x03001040,0x03001048,0x03001050,0x03001060,
		0x03000000,0x03000004,0x03001804,0x0300170c,0x07000118};
	for (unsigned i=0;i<sizeof(hardware)/sizeof(hardware[0]);i++) mock_set(hardware[i],0x12345678);
}
uint32_t read32(unsigned long addr)
{
	for (unsigned i = 0; i < register_count; i++)
		if (registers[i].addr == addr) return registers[i].value;
	fprintf(stderr, "unexpected MMIO read %#lx\n", addr);
	abort();
}
void write32(unsigned long addr, uint32_t value)
{
	if (mock_count == 128) abort();
	mock_writes[mock_count++] = (struct mock_write){addr, value, counter_now};
	mock_set(addr, value);
	if (reset_escape && addr == 0x030090b0) longjmp(mock_jmp, 1);
}
void mock_reset_escape(int enabled) { reset_escape = enabled; }
void mock_clock(uint64_t now, uint64_t step) { counter_now = now; counter_step = step; }
uint64_t zl_test_counter(void) { uint64_t now = counter_now; counter_now += counter_step; return now; }
