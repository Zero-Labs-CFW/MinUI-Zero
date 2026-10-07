// snd_ring_test.c: unit + threaded harness for snd_ring.h (D73), the lock-free audio ring and its space wake-up.
// The threaded cases use the real header with the same lock shapes as api.c: the producer holds prod_mx (released
// while it sleeps on a full ring), the consumer runs under audio_mx (standing in for the lock SDL holds around the
// callback, which the consumer itself never needs), and control ops take prod_mx then audio_mx. The audio
// backpressure scenarios 4-9 moved here from wakeup_test.c, which mirrored the old locked ring.
//
//   snd_ring_test [stress_frames]    (run-snd-ring-tests.sh builds plain, TSan and ASan)
#include "snd_ring.h"

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/time.h>
#include <unistd.h>

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { failures++; printf("  FAIL: " __VA_ARGS__); printf("\n"); } } while (0)

static uint64_t now_us(void) { struct timeval tv; gettimeofday(&tv, NULL); return (uint64_t)tv.tv_sec * 1000000 + tv.tv_usec; }
static void put_seq(SndRing* r, uint32_t seq) { snd_ring_put(r, (int16_t)(seq & 0xffff), (int16_t)(seq >> 16)); }
static uint32_t seq_of(const int16_t* f) { return (uint16_t)f[0] | ((uint32_t)(uint16_t)f[1] << 16); }

// ---------------- single-threaded ----------------
static void test_basics(void) {
	printf("[ring] empty, full at cap-1, order, publish visibility\n");
	int16_t buf[8 * 2]; SndRing r; snd_ring_reset(&r, buf, 8);
	int16_t out[16 * 2];
	CHECK(snd_ring_space(&r) == 7 && snd_ring_queued(&r, NULL) == 0, "empty ring: space %u", snd_ring_space(&r));
	CHECK(snd_ring_read(&r, out, 4) == 0, "read from an empty ring returned frames");
	for (uint32_t i = 0; i < 7; i++) put_seq(&r, i);
	CHECK(snd_ring_space(&r) == 0, "7 frames in an 8-slot ring must be full (space %u)", snd_ring_space(&r));
	CHECK(snd_ring_filled(&r) == 7, "producer sees its own unpublished writes (%u)", snd_ring_filled(&r));
	CHECK(snd_ring_queued(&r, NULL) == 0 && snd_ring_read(&r, out, 4) == 0, "unpublished frames must be invisible");
	snd_ring_publish(&r);
	uint32_t cap = 0;
	CHECK(snd_ring_queued(&r, &cap) == 7 && cap == 8, "published: queued %u cap %u", snd_ring_queued(&r, NULL), cap);
	CHECK(snd_ring_read(&r, out, 3) == 3 && seq_of(out) == 0 && seq_of(out + 4) == 2, "first three in order");
	CHECK(snd_ring_space(&r) == 3, "three read = three free (%u)", snd_ring_space(&r));
	CHECK(snd_ring_read(&r, out, 16) == 4 && seq_of(out) == 3 && seq_of(out + 6) == 6, "the rest, capped at what is there");
}

static void test_wrap_cycles(uint32_t start) {
	printf("[ring] random put/read cycles across the slot wrap, counters from 0x%08x\n", start);
	int16_t buf[13 * 2]; SndRing r; snd_ring_reset(&r, buf, 13);
	// start the free-running counters anywhere (0xffffff00 crosses the uint32 wrap within the run)
	r.w_count = start; atomic_store(&r.written, start); atomic_store(&r.read, start);
	uint32_t next_put = 0, next_get = 0; int16_t out[13 * 2]; unsigned s = 12345;
	for (int i = 0; i < 20000; i++) {
		s = s * 1103515245u + 12345u;
		uint32_t n = (s >> 16) % 14;
		uint32_t sp = snd_ring_space(&r);
		for (uint32_t k = 0; k < n && k < sp; k++) put_seq(&r, next_put++);
		snd_ring_publish(&r);
		CHECK(snd_ring_queued(&r, NULL) == next_put - next_get, "queued %u, want %u", snd_ring_queued(&r, NULL), next_put - next_get);
		uint32_t m = snd_ring_read(&r, out, (s >> 8) % 14);
		for (uint32_t k = 0; k < m; k++) {
			if (seq_of(out + 2 * k) != next_get) { CHECK(0, "sequence broke at %u (got %u)", next_get, seq_of(out + 2 * k)); return; }
			next_get++;
		}
	}
	CHECK(next_get > 50000, "cycles moved too few frames (%u)", next_get);
}

static void test_drop_and_clamp(void) {
	printf("[ring] drop empties it; queued clamps; no ring reads as empty\n");
	int16_t buf[8 * 2]; SndRing r; snd_ring_reset(&r, buf, 8);
	for (uint32_t i = 0; i < 5; i++) put_seq(&r, i);
	snd_ring_publish(&r);
	snd_ring_drop(&r);
	CHECK(snd_ring_queued(&r, NULL) == 0 && snd_ring_space(&r) == 7, "after drop: queued %u space %u", snd_ring_queued(&r, NULL), snd_ring_space(&r));
	put_seq(&r, 99); snd_ring_publish(&r);
	int16_t out[4];
	CHECK(snd_ring_read(&r, out, 2) == 1 && seq_of(out) == 99, "the first frame after a drop is the next one written");
	// a third thread racing both counters: written read late can over-count (clamped), never go negative
	atomic_store(&r.read, 10); atomic_store(&r.written, 5);
	CHECK(snd_ring_queued(&r, NULL) == 0, "read > written must clamp to 0");
	atomic_store(&r.read, 0); atomic_store(&r.written, 100);
	CHECK(snd_ring_queued(&r, NULL) == 7, "over-count must clamp to cap-1 (%u)", snd_ring_queued(&r, NULL));
	snd_ring_reset(&r, NULL, 8);
	uint32_t cap = 9;
	CHECK(snd_ring_queued(&r, &cap) == 0 && cap == 0 && snd_ring_space(&r) == 0 && snd_ring_read(&r, out, 2) == 0,
		"a reset to no buffer must read as no ring (cap %u)", cap);
}

// ---------------- threaded, api.c lock shapes ----------------
static struct {
	SndRing ring;
	SndSpace space;
	pthread_mutex_t prod_mx;  // SND_batchSamples' producer mutex
	pthread_mutex_t audio_mx; // SDL's audio lock (held around the callback, and by control ops)
	int16_t* buf;
	uint32_t cap;
	int live;                 // under prod_mx: 0 = torn down
	atomic_int ff_nonblock;
	atomic_int producer_done;
	atomic_int stop;
	uint32_t epoch;           // under prod_mx + audio_mx: bumped by every drop/reset
	// producer stats (producer thread only, read after join)
	uint32_t next_put;
	uint64_t max_sleep_us;
	long sleeps;
	// consumer (consumer thread only)
	uint32_t next_get;
	uint32_t seen_epoch;
	atomic_uint consumed;
	uint32_t read_max;        // consumer chunk ceiling
	int sleepy;               // consumer pauses now and then (forces full-ring sleeps)
	uint32_t put_max;         // producer batch ceiling
	int prod_pause;           // producer pauses now and then (keeps the ring near empty)
} T;

static void t_setup(uint32_t cap) {
	memset(&T, 0, sizeof(T));
	SndSpace init = SND_SPACE_INIT; T.space = init;
	pthread_mutex_init(&T.prod_mx, NULL);
	pthread_mutex_init(&T.audio_mx, NULL);
	T.cap = cap;
	T.buf = calloc(cap, 2 * sizeof(int16_t));
	snd_ring_reset(&T.ring, T.buf, cap);
	T.live = 1;
	T.read_max = 200;
	T.sleepy = 1;
	T.put_max = 97;
}
static void t_teardown(void) { free(T.buf); T.buf = NULL; }

// producer: the SND_batchSamples loop shape. Returns frames accepted.
static uint32_t t_batch(uint32_t n) {
	pthread_mutex_lock(&T.prod_mx);
	if (!T.live) { pthread_mutex_unlock(&T.prod_mx); return n; }
	uint32_t accepted = 0;
	while (n) {
		uint32_t sp;
		while ((sp = snd_ring_space(&T.ring)) == 0 && !atomic_load(&T.ff_nonblock)) {
			uint64_t t0 = now_us();
			if (snd_ring_wait_space(&T.ring, &T.space, &T.prod_mx, 2000)) {
				uint64_t d = now_us() - t0;
				T.sleeps++;
				if (d > T.max_sleep_us) T.max_sleep_us = d;
			}
			if (!T.live) { pthread_mutex_unlock(&T.prod_mx); return accepted; }
		}
		if (sp == 0) break; // FF: still full, drop the rest
		while (n && sp) { put_seq(&T.ring, T.next_put++); n--; sp--; accepted++; }
		snd_ring_publish(&T.ring);
	}
	pthread_mutex_unlock(&T.prod_mx);
	return accepted;
}
static void* t_producer(void* arg) {
	uint32_t total = (uint32_t)(uintptr_t)arg, sent = 0; unsigned s = 777;
	while (sent < total && !atomic_load(&T.stop)) {
		s = s * 1103515245u + 12345u;
		uint32_t want = 1 + (s >> 16) % T.put_max;
		if (T.prod_pause && (s >> 8) % 8 == 0) usleep(20);
		if (want > total - sent) want = total - sent;
		uint32_t got = t_batch(want);
		sent += got;
		pthread_mutex_lock(&T.prod_mx);
		int dead = !T.live;
		pthread_mutex_unlock(&T.prod_mx);
		if (dead || (!got && atomic_load(&T.ff_nonblock))) break;
	}
	atomic_store(&T.producer_done, 1);
	return NULL;
}
// consumer: the callback shape (under audio_mx, as SDL calls it), verifying order; gaps only across a drop/reset
static void t_consume(uint32_t k) {
	int16_t out[256 * 2];
	if (k > 256) k = 256;
	pthread_mutex_lock(&T.audio_mx);
	uint32_t got = snd_ring_read(&T.ring, out, k);
	int new_epoch = T.epoch != T.seen_epoch;
	for (uint32_t i = 0; i < got; i++) {
		uint32_t seq = seq_of(out + 2 * i);
		if (new_epoch && i == 0) { CHECK(seq >= T.next_get, "after a drop the stream went backwards (%u < %u)", seq, T.next_get); T.next_get = seq; }
		if (seq != T.next_get) { CHECK(0, "sequence broke: got %u want %u", seq, T.next_get); atomic_store(&T.stop, 1); break; }
		T.next_get++;
	}
	if (got) T.seen_epoch = T.epoch;
	pthread_mutex_unlock(&T.audio_mx);
	atomic_fetch_add(&T.consumed, got);
	snd_space_signal(&T.space);
}
static void* t_consumer(void* arg) {
	(void)arg; unsigned s = 4242;
	while (!atomic_load(&T.stop)) {
		s = s * 1103515245u + 12345u;
		t_consume(1 + (s >> 16) % T.read_max);
		if (T.sleepy && (s >> 8) % 4 == 0) usleep(200);
	}
	return NULL;
}
static void* t_observer(void* arg) {
	(void)arg;
	while (!atomic_load(&T.stop)) {
		uint32_t cap = 0, q = snd_ring_queued(&T.ring, &cap);
		if (cap && q > cap - 1) { CHECK(0, "observer saw %u queued in a %u-slot ring", q, cap); break; }
	}
	return NULL;
}
static void t_control_drop(void) { // SND_reprime / FF-exit shape
	pthread_mutex_lock(&T.prod_mx);
	pthread_mutex_lock(&T.audio_mx);
	snd_ring_drop(&T.ring);
	T.epoch++;
	pthread_mutex_unlock(&T.audio_mx);
	pthread_mutex_unlock(&T.prod_mx);
	snd_space_signal(&T.space);
}

static void t_run_stress(uint32_t frames, int expect_sleeps);
static void test_stress(uint32_t frames) {
	printf("[spsc] %u frames through a 37-slot ring: order kept, never over capacity, no lost wake-up\n", frames);
	t_setup(37);
	t_run_stress(frames, 1);
}
// Starved: a slow producer and an eager consumer keep a big ring near empty, so the producer never sleeps and the
// consumer reads each frame right after its publish: frames cross on the publish/acquire pair alone. (In the full-ring
// case above the sleep handshake orders memory as a side effect; a relaxed publish passed TSan there.)
static void test_stress_starved(uint32_t frames) {
	printf("[spsc] %u frames through a starved 1009-slot ring: frames cross on publish alone\n", frames);
	t_setup(1009);
	T.read_max = 256;
	T.sleepy = 0;
	T.put_max = 8;
	T.prod_pause = 1;
	t_run_stress(frames, 0);
}
static void t_run_stress(uint32_t frames, int expect_sleeps) {
	pthread_t p, c, o;
	pthread_create(&p, NULL, t_producer, (void*)(uintptr_t)frames);
	pthread_create(&c, NULL, t_consumer, NULL);
	pthread_create(&o, NULL, t_observer, NULL);
	pthread_join(p, NULL);
	while (atomic_load(&T.consumed) < frames && !atomic_load(&T.stop)) usleep(100);
	atomic_store(&T.stop, 1);
	pthread_join(c, NULL); pthread_join(o, NULL);
	CHECK(atomic_load(&T.consumed) == frames, "consumed %u of %u", atomic_load(&T.consumed), frames);
	if (expect_sleeps) CHECK(T.sleeps > 0, "the producer never slept on the full ring (test proves nothing)");
	// a consumer reading every ~0.2 ms must wake a full-ring sleeper long before the 2 s timeout
	CHECK(T.max_sleep_us < 500000, "a producer sleep lasted %" PRIu64 " us: lost wake-up", T.max_sleep_us);
	printf("  %ld sleeps, longest %" PRIu64 " us\n", T.sleeps, T.max_sleep_us);
	t_teardown();
}

static void test_drops_during_play(void) {
	printf("[spsc] reprime drops while both sides run: order holds, gaps only across a drop\n");
	t_setup(61);
	pthread_t p, c;
	pthread_create(&p, NULL, t_producer, (void*)(uintptr_t)400000);
	pthread_create(&c, NULL, t_consumer, NULL);
	for (int i = 0; i < 200 && !atomic_load(&T.producer_done); i++) { usleep(500); t_control_drop(); }
	pthread_join(p, NULL);
	atomic_store(&T.stop, 1);
	pthread_join(c, NULL);
	CHECK(T.epoch > 0, "no drop happened");
	t_teardown();
}

static void test_block_and_release(void) {
	printf("[snd] scenarios 4+5: the producer sleeps on a full ring and resumes on space, order kept\n");
	t_setup(64);
	pthread_t p;
	pthread_create(&p, NULL, t_producer, (void*)(uintptr_t)500);
	usleep(50000);
	CHECK(!atomic_load(&T.producer_done), "the producer finished without blocking on a 64-slot ring");
	while (atomic_load(&T.consumed) < 500) { t_consume(16); usleep(1000); }
	pthread_join(p, NULL);
	CHECK(atomic_load(&T.consumed) == 500 && T.sleeps > 0, "consumed %u of 500, %ld sleeps", atomic_load(&T.consumed), T.sleeps);
	t_teardown();
}

static void test_ff_while_blocked(void) {
	printf("[snd] scenario 6: FF entered while the producer sleeps: prompt drop, no deadlock\n");
	t_setup(64);
	pthread_t p;
	pthread_create(&p, NULL, t_producer, (void*)(uintptr_t)100000);
	usleep(40000);
	pthread_mutex_lock(&T.prod_mx); // SND_setFastForward shape: change under the producer lock, signal after
	atomic_store(&T.ff_nonblock, 1);
	pthread_mutex_unlock(&T.prod_mx);
	snd_space_signal(&T.space);
	usleep(100000);
	CHECK(atomic_load(&T.producer_done), "the producer still blocked 100 ms after FF + signal");
	pthread_join(p, NULL);
	t_teardown();
}

static void test_teardown_while_blocked(void) {
	printf("[snd] scenario 8: teardown while the producer sleeps: prompt exit\n");
	t_setup(64);
	pthread_t p;
	pthread_create(&p, NULL, t_producer, (void*)(uintptr_t)100000);
	usleep(40000);
	pthread_mutex_lock(&T.prod_mx); // SND_quit shape
	T.live = 0;
	snd_ring_reset(&T.ring, NULL, 0);
	pthread_mutex_unlock(&T.prod_mx);
	snd_space_signal(&T.space);
	usleep(100000);
	CHECK(atomic_load(&T.producer_done), "the producer still blocked 100 ms after teardown + signal");
	pthread_join(p, NULL);
	t_teardown();
}

static void test_reinit_cycles(void) {
	printf("[snd] scenario 9: repeated resize/teardown with a live producer and consumer\n");
	for (int cyc = 0; cyc < 20; cyc++) {
		t_setup(32 + cyc);
		pthread_t p, c;
		pthread_create(&p, NULL, t_producer, (void*)(uintptr_t)50000);
		pthread_create(&c, NULL, t_consumer, NULL);
		usleep(2000);
		// SND_resizeBuffer shape: both locks, new buffer, empty ring
		pthread_mutex_lock(&T.prod_mx);
		pthread_mutex_lock(&T.audio_mx);
		uint32_t cap = 50 + cyc;
		int16_t* grown = realloc(T.buf, cap * 2 * sizeof(int16_t));
		if (grown) { T.buf = grown; T.cap = cap; snd_ring_reset(&T.ring, T.buf, cap); T.epoch++; }
		pthread_mutex_unlock(&T.audio_mx);
		pthread_mutex_unlock(&T.prod_mx);
		snd_space_signal(&T.space);
		usleep(2000);
		pthread_mutex_lock(&T.prod_mx); // then SND_quit
		T.live = 0;
		pthread_mutex_lock(&T.audio_mx);
		snd_ring_reset(&T.ring, NULL, 0);
		pthread_mutex_unlock(&T.audio_mx);
		pthread_mutex_unlock(&T.prod_mx);
		snd_space_signal(&T.space);
		pthread_join(p, NULL);
		atomic_store(&T.stop, 1);
		pthread_join(c, NULL);
		t_teardown();
	}
	printf("  20 cycles clean\n");
}

int main(int argc, char** argv) {
	uint32_t frames = argc > 1 ? (uint32_t)strtoul(argv[1], NULL, 0) : 2000000;
	printf("== snd_ring harness ==\n");
	test_basics();
	test_wrap_cycles(0);
	test_wrap_cycles(0xffffff00u);
	test_drop_and_clamp();
	test_stress(frames);
	test_stress_starved(frames / 4);
	test_drops_during_play();
	test_block_and_release();
	test_ff_while_blocked();
	test_teardown_while_blocked();
	test_reinit_cycles();
	if (failures) { printf("== %d FAILURES ==\n", failures); return 1; }
	printf("== ALL PASS ==\n");
	return 0;
}
