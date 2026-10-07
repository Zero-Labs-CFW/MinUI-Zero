// wakeup_test.c — focused harness for the event-driven rumble worker (feat/wakeup-reduction). It mirrors the exact
// synchronization shapes in api.c with PLAT/SDL stubbed, so the wait/signal/teardown logic runs under ASan/TSan on
// the host. Scenarios follow the Codex task list 1-9; the audio ones (4-9) now live in snd_ring_test.c.
//
// Build (host):
//   cc wakeup_test.c -o wakeup_test -lpthread            (add -fsanitize=thread or address)
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <pthread.h>
#include <time.h>

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { failures++; printf("FAIL: " __VA_ARGS__); printf("\n"); } } while (0)

static void msleep(int ms) { usleep(ms * 1000); }
static void deadline_in(struct timespec* ts, int ms) {
	clock_gettime(CLOCK_REALTIME, ts);
	ts->tv_nsec += (long)ms * 1000000L;
	while (ts->tv_nsec >= 1000000000L) { ts->tv_sec += 1; ts->tv_nsec -= 1000000000L; }
}

// ---------------- VIB worker mirror ----------------
#define VIB_DEFER_OFF_MS 51
static struct {
	pthread_t pt;
	pthread_mutex_t mx;
	pthread_cond_t cv;
	int queued_strength, strength, quit;
	// instrumentation
	int loop_wakeups;      // times the worker loop body ran
	int rumble_writes;     // PLAT_setRumble calls
	int last_rumble;       // last written value
	int zero_writes;       // how many times the motor was written 0
} tvib;
static pthread_mutex_t stub_mx = PTHREAD_MUTEX_INITIALIZER;
static void stub_setRumble(int v) {
	pthread_mutex_lock(&stub_mx);
	tvib.rumble_writes++; tvib.last_rumble = v; if (v == 0) tvib.zero_writes++;
	pthread_mutex_unlock(&stub_mx);
}
static int stub_last(void)  { pthread_mutex_lock(&stub_mx); int v = tvib.last_rumble; pthread_mutex_unlock(&stub_mx); return v; }
static int stub_zeros(void) { pthread_mutex_lock(&stub_mx); int v = tvib.zero_writes; pthread_mutex_unlock(&stub_mx); return v; }
static void* tvib_thread(void* arg) {
	pthread_mutex_lock(&tvib.mx);
	while (!tvib.quit) {
		tvib.loop_wakeups++;
		if (tvib.queued_strength == tvib.strength) {
			pthread_cond_wait(&tvib.cv, &tvib.mx);
			continue;
		}
		int target = tvib.queued_strength;
		if (target == 0) {
			struct timespec ts; deadline_in(&ts, VIB_DEFER_OFF_MS);
			while (!tvib.quit && tvib.queued_strength == 0)
				if (pthread_cond_timedwait(&tvib.cv, &tvib.mx, &ts) == ETIMEDOUT) break;
			if (tvib.quit) break;
			if (tvib.queued_strength != 0) continue;
		}
		tvib.strength = target;
		pthread_mutex_unlock(&tvib.mx);
		stub_setRumble(target);
		pthread_mutex_lock(&tvib.mx);
	}
	pthread_mutex_unlock(&tvib.mx);
	return NULL;
}
static void tvib_start(void) {
	memset(&tvib, 0, sizeof(tvib));
	pthread_mutex_init(&tvib.mx, NULL);
	pthread_cond_init(&tvib.cv, NULL);
	pthread_create(&tvib.pt, NULL, tvib_thread, NULL);
}
static void tvib_set(int v) {
	pthread_mutex_lock(&tvib.mx);
	if (tvib.queued_strength != v) { tvib.queued_strength = v; pthread_cond_signal(&tvib.cv); }
	pthread_mutex_unlock(&tvib.mx);
}
static void tvib_quit(void) {
	pthread_mutex_lock(&tvib.mx);
	tvib.quit = 1;
	pthread_cond_broadcast(&tvib.cv);
	pthread_mutex_unlock(&tvib.mx);
	pthread_join(tvib.pt, NULL);
	stub_setRumble(0);
}

static void test_vib_idle_no_wakeups(void) {
	printf("[vib] scenario 1: extended idle produces zero loop wakeups\n");
	tvib_start();
	msleep(50); // let the worker reach its wait
	pthread_mutex_lock(&tvib.mx); int w0 = tvib.loop_wakeups; pthread_mutex_unlock(&tvib.mx);
	msleep(300);
	pthread_mutex_lock(&tvib.mx); int w1 = tvib.loop_wakeups; pthread_mutex_unlock(&tvib.mx);
	CHECK(w1 == w0, "idle worker woke %d times in 300ms (want 0)", w1 - w0);
	tvib_quit();
}
static void test_vib_rapid_toggle(void) {
	printf("[vib] scenario 2: rapid on/off converges, deferred-off rescues\n");
	tvib_start();
	for (int i = 0; i < 100; i++) { tvib_set(100); tvib_set(0); }
	tvib_set(100); // final state: ON — every intermediate 0 should have been rescued or applied
	msleep(120);
	CHECK(stub_last() == 100, "final motor state %d (want 100)", stub_last());
	// deferred-off: quick 0->N vacillation must not thrash the motor with zeros
	CHECK(stub_zeros() <= 2, "motor written 0 %d times during vacillation (want <=2)", stub_zeros());
	tvib_quit();
	CHECK(stub_last() == 0, "motor left on after quit");
}
static int tvib_get(void) { // mirrors the fixed VIB_getStrength: read under the mutex
	pthread_mutex_lock(&tvib.mx);
	int v = tvib.strength;
	pthread_mutex_unlock(&tvib.mx);
	return v;
}
static void test_vib_getter_race(void) {
	printf("[vib] getter: menu-entry save/restore sequence races the worker cleanly\n");
	tvib_start();
	for (int i = 0; i < 200; i++) {
		tvib_set(i % 7 ? 60 : 0);
		int saved = tvib_get();   // menu entry: capture current strength
		tvib_set(0);              // menu: rumble off
		tvib_set(saved);          // menu exit: restore
	}
	msleep(120);
	CHECK(tvib_get() == 0 || tvib_get() == 60, "getter returned torn value");
	tvib_quit();
}
static void test_vib_teardown(void) {
	printf("[vib] scenario 3: shutdown while active and while blocked\n");
	tvib_start();
	tvib_set(80);
	msleep(30);
	tvib_quit(); // active teardown
	CHECK(stub_last() == 0, "teardown-while-active left motor at %d", stub_last());
	tvib_start();
	msleep(30);  // worker parked in cond_wait
	tvib_quit(); // blocked teardown — must not hang (reaching here at all is the pass)
	CHECK(stub_last() == 0, "teardown-while-blocked left motor at %d", stub_last());
}

// The audio backpressure scenarios (4-9) moved to snd_ring_test.c (D73), which runs them against the real lock-free
// ring in snd_ring.h instead of a mirror of the old locked one.

int main(void) {
	printf("== wakeup-reduction synchronization harness ==\n");
	test_vib_idle_no_wakeups();
	test_vib_rapid_toggle();
	test_vib_getter_race();
	test_vib_teardown();
	if (failures) { printf("== %d FAILURES ==\n", failures); return 1; }
	printf("== ALL PASS ==\n");
	return 0;
}
