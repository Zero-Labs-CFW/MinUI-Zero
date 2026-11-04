// bootclock: how long the boot took BEFORE Linux started counting, read once per boot by minui-frontend.sh.
//
// /proc/uptime starts at Linux's clock origin, so it never sees boot0, U-Boot or the kernel load. The ARM
// generic timer (CNTVCT_EL0, 24 MHz on the H700) starts at power-on/reset and is readable from userspace,
// so counter time minus CLOCK_MONOTONIC_RAW is the part before Linux (idea: BaseOS boot profiling, measured
// there as ~3.4-3.7 s on an RG SP). MONOTONIC_RAW, not BOOTTIME: NTP slews the latter.
//
// Prints "pre <s> post <s> total <s>" (post = Linux clock now, total = counter now), or nothing and exit 1
// when the counter is unusable (EL0 access off, or a frequency that is not a sane timer rate).
#include <stdio.h>
#include <stdint.h>
#include <time.h>

static inline uint64_t cntvct(void) { uint64_t v; __asm__ volatile("isb; mrs %0, cntvct_el0" : "=r"(v)); return v; }
static inline uint64_t cntfrq(void) { uint64_t v; __asm__ volatile("mrs %0, cntfrq_el0" : "=r"(v)); return v; }

int main(void) {
	uint64_t f = cntfrq();
	if (f < 1000000 || f > 100000000) return 1;
	// bracket the clock read with two counter reads and take the midpoint; a wide bracket (preempted) is retried
	for (int tries = 0; tries < 20; tries++) {
		struct timespec ts;
		uint64_t a = cntvct();
		clock_gettime(CLOCK_MONOTONIC_RAW, &ts);
		uint64_t b = cntvct();
		if ((b - a) * 10000 > f) continue; // wider than 100 us
		double total = (double)(a + (b - a) / 2) / (double)f;
		double post = (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
		if (total < post) return 1; // the counter did not start at reset on this boot
		printf("pre %.3f post %.3f total %.3f\n", total - post, post, total);
		return 0;
	}
	return 1;
}
