#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "rtc.h"
#include "offline_soc.h"

#define US(x) ((uint64_t)(x) * 24)

static void intervals(void)
{
	assert(mock_count == 7);
	for (unsigned i = 1; i <= 4; i++) assert(mock_writes[i].addr == 0x0300b130);
	assert(mock_writes[1].value & (1u << 15));
	assert(mock_writes[2].value & (1u << 14));
	assert(!(mock_writes[3].value & (1u << 14)));
	assert(mock_writes[4].value & (1u << 14));
	assert(mock_writes[2].ticks - mock_writes[1].ticks >= US(30000));
	assert(mock_writes[3].ticks - mock_writes[2].ticks >= US(15000));
	assert(mock_writes[4].ticks - mock_writes[3].ticks >= US(50000));
	assert(mock_writes[5].addr == 0x0300b090);
	assert(mock_writes[5].ticks - mock_writes[4].ticks >= US(100000));
	assert(mock_writes[6].addr == 0x0300b0ac);
	assert(zl_counter() - mock_writes[6].ticks >= US(1000));
}

static void run(unsigned elapsed_us, int boe)
{
	mock_reset();
	mock_set(0x0300b0a0, boe ? 0 : 0x40);
	assert(zl_lcd_begin() == 0);
	uint64_t after_begin = zl_counter();
	mock_clock(after_begin + US(elapsed_us), US(1000));
	assert(strcmp(zl_lcd_type(), boe ? "boe" : "old") == 0);
	intervals();
	/* A slow inflate consumes the final settle interval, not another whole 100 ms wait. */
	if (elapsed_us >= 100000)
		assert(mock_writes[5].ticks - after_begin - US(elapsed_us) <= US(2000));
}

static void boundary(unsigned elapsed_us, int wrap)
{
	mock_reset();
	if (wrap) mock_clock(UINT64_MAX - US(100000), US(1000));
	assert(zl_lcd_begin() == 0);
	uint64_t release = mock_writes[4].ticks;
	mock_clock(release + US(elapsed_us), US(1));
	assert(strcmp(zl_lcd_type(), "old") == 0);
	intervals();
	assert(mock_writes[5].ticks - release <= US(100003));
}

int main(void)
{
	const unsigned elapsed[] = {0, 1000, 50000, 99000, 100000, 337000, 1000000};
	for (unsigned i = 0; i < sizeof(elapsed) / sizeof(elapsed[0]); i++)
		for (int boe = 0; boe <= 1; boe++) run(elapsed[i], boe);
	for (unsigned us = 99999; us <= 100001; us++)
		for (int wrap = 0; wrap <= 1; wrap++) boundary(us, wrap);
	/* No prior begin, repeated use, and unsigned counter wrap retain synchronous behavior. */
	for (int i = 0; i < 3; i++) {
		mock_reset();
		if (i == 2) mock_clock(UINT64_MAX - US(10000), US(1000));
		assert(strcmp(zl_lcd_type(), "old") == 0);
		intervals();
	}
	mock_reset();
	mock_clock(0, 0);
	assert(zl_lcd_begin() < 0);
	assert(zl_lcd_type() == NULL);
	/* Stall after reset release and ensure the unconsumed interval is not skipped. */
	mock_reset();
	assert(zl_lcd_begin() == 0);
	uint64_t now = zl_counter();
	mock_clock(now, 0);
	assert(zl_lcd_type() == NULL);
	assert(mock_count == 5);
	/* A subsequent standalone call starts afresh, even after failure. */
	mock_reset();
	assert(strcmp(zl_lcd_type(), "old") == 0);
	intervals();
	puts("PASS panel overlap: 14 elapsed/strap +6 microsecond/wrap boundaries, sync/repeat, stalls and recovery");
	return 0;
}
