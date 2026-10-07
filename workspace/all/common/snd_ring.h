// snd_ring.h: the audio ring between ONE producer (the emulator thread, SND_batchSamples) and ONE consumer (SDL's audio
// callback), lock-free on both sides (D73).
//
// Why: the producer used to hold SDL's audio lock for a whole batch, resampling included, and SDL holds that same lock
// around every callback. Since D72 the callback runs on a SCHED_FIFO thread feeding a 43 ms hardware buffer, so a
// normal-priority emulator thread preempted mid-batch could stall it (priority inversion). NextUI and RetroArch
// (sdl_audio.c) shorten the critical section to the copy, resampling outside it; this goes one step further, so
// the callback never waits on the producer at all.
//
// Protocol (single producer, single consumer):
// - The producer owns w_idx/w_count, writes frames, then publishes `written` (release). The consumer owns r_idx, reads
//   up to `written` (acquire), then publishes `read` (release), which hands the slots back to the producer.
// - `written` and `read` are free-running frame counts, so `written - read` is the occupancy with no wrap ambiguity,
//   even for a third thread reading both (snd_ring_queued; clamped).
// - At most cap-1 frames are ever queued (the classic full != empty slot).
// - Control operations (snd_ring_reset, snd_ring_drop) need BOTH sides excluded by the caller: api.c holds the
//   producer mutex and SDL's audio lock.
// - The producer publishes before it ever lets go of its mutex, so outside a batch w_count == written.
//
// Space wake-up (SndSpace): the producer sleeps only on a FULL ring. The consumer bumps `gen` after every read and
// touches the mutex only while the producer has armed `waiting`, so on the normal path the callback takes no lock at
// all; when it does, the ring is full (~133 ms queued), where a short wait costs nothing audible.
#ifndef SND_RING_H
#define SND_RING_H

#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <string.h>
#include <time.h>

typedef struct SndRing {
	int16_t* buf;             // cap stereo frames, interleaved left/right
	_Atomic uint32_t cap;     // frames allocated (0 = no ring); third threads read it, so atomic
	uint32_t w_idx;           // producer: next slot to write
	uint32_t w_count;         // producer: frames written so far, published or not (free-running)
	uint32_t r_idx;           // consumer: next slot to read
	_Atomic uint32_t written; // producer -> consumer: frames published (free-running)
	_Atomic uint32_t read;    // consumer -> producer: frames consumed (free-running)
} SndRing;

// Control: point the ring at `buf` (cap frames, may be NULL/0) and empty it. Both sides excluded by the caller.
static inline void snd_ring_reset(SndRing* r, int16_t* buf, uint32_t cap) {
	r->buf = buf;
	r->w_idx = r->r_idx = 0;
	r->w_count = 0;
	atomic_store_explicit(&r->written, 0, memory_order_relaxed);
	atomic_store_explicit(&r->read, 0, memory_order_relaxed);
	atomic_store_explicit(&r->cap, buf ? cap : 0, memory_order_release);
}

// Control: discard everything queued (the reprime at a pause seam). Both sides excluded, producer published.
static inline void snd_ring_drop(SndRing* r) {
	r->r_idx = r->w_idx;
	atomic_store_explicit(&r->read, r->w_count, memory_order_release);
}

// Producer: frames queued as the producer sees them (exact for its own writes; the consumer can only make it smaller).
static inline uint32_t snd_ring_filled(const SndRing* r) {
	uint32_t cap = atomic_load_explicit(&r->cap, memory_order_relaxed);
	uint32_t used = r->w_count - atomic_load_explicit(&r->read, memory_order_acquire);
	return cap && used > cap - 1 ? cap - 1 : used;
}
// Producer: frames it may write now.
static inline uint32_t snd_ring_space(const SndRing* r) {
	uint32_t cap = atomic_load_explicit(&r->cap, memory_order_relaxed);
	return cap ? cap - 1 - snd_ring_filled(r) : 0;
}
// Producer: write one frame. The caller has checked snd_ring_space; nothing is visible until snd_ring_publish.
static inline void snd_ring_put(SndRing* r, int16_t left, int16_t right) {
	int16_t* p = r->buf + 2 * r->w_idx;
	p[0] = left;
	p[1] = right;
	if (++r->w_idx == atomic_load_explicit(&r->cap, memory_order_relaxed)) r->w_idx = 0;
	r->w_count++;
}
static inline void snd_ring_publish(SndRing* r) {
	atomic_store_explicit(&r->written, r->w_count, memory_order_release);
}

// Consumer: copy up to `frames` stereo frames into `out`; returns how many.
static inline uint32_t snd_ring_read(SndRing* r, int16_t* out, uint32_t frames) {
	uint32_t cap = atomic_load_explicit(&r->cap, memory_order_relaxed);
	if (!cap) return 0;
	uint32_t done = atomic_load_explicit(&r->read, memory_order_relaxed); // our own counter
	uint32_t avail = atomic_load_explicit(&r->written, memory_order_acquire) - done;
	uint32_t n = avail < frames ? avail : frames;
	uint32_t first = cap - r->r_idx;
	if (first > n) first = n;
	memcpy(out, r->buf + 2 * r->r_idx, first * 2 * sizeof(int16_t));
	if (n > first) memcpy(out + 2 * first, r->buf, (n - first) * 2 * sizeof(int16_t));
	r->r_idx += n;
	if (r->r_idx >= cap) r->r_idx -= cap;
	atomic_store_explicit(&r->read, done + n, memory_order_release);
	return n;
}

// Any thread: frames queued, clamped to 0..cap-1 (0 with no ring). `read` is loaded first, so a racing update can only
// over-count, never report a full ring as nearly empty; *cap_out gets the capacity when non-NULL.
static inline uint32_t snd_ring_queued(const SndRing* r, uint32_t* cap_out) {
	uint32_t cap = atomic_load_explicit(&r->cap, memory_order_acquire);
	uint32_t rd = atomic_load_explicit(&r->read, memory_order_acquire);
	uint32_t wr = atomic_load_explicit(&r->written, memory_order_acquire);
	int32_t q = (int32_t)(wr - rd);
	if (q < 0 || !cap) q = 0;
	if (cap && (uint32_t)q > cap - 1) q = (int32_t)(cap - 1);
	if (cap_out) *cap_out = cap;
	return (uint32_t)q;
}

typedef struct SndSpace {
	pthread_mutex_t mx;
	pthread_cond_t cv;
	atomic_uint gen;     // bumped by every signal
	atomic_int waiting;  // 1 while the producer is asleep, or about to be, on a full ring
} SndSpace;
#define SND_SPACE_INIT { PTHREAD_MUTEX_INITIALIZER, PTHREAD_COND_INITIALIZER, 0, 0 }

// Consumer (after each read) and control ops (after any change a blocked producer must see). seq_cst on both atomics:
// either this sees `waiting` and broadcasts under the mutex, or the producer's later `gen` load sees this bump.
static inline void snd_space_signal(SndSpace* s) {
	atomic_fetch_add(&s->gen, 1);
	if (!atomic_load(&s->waiting)) return;
	pthread_mutex_lock(&s->mx);
	pthread_cond_broadcast(&s->cv);
	pthread_mutex_unlock(&s->mx);
}

// Producer: sleep until the ring has space, a signal arrives, or timeout_ms passes. Called and returns with prod_mx
// held, but RELEASES it while asleep so control ops can run: the caller rechecks liveness and the ring afterwards.
// Returns 1 if it slept.
static inline int snd_ring_wait_space(const SndRing* r, SndSpace* s, pthread_mutex_t* prod_mx, int timeout_ms) {
	atomic_store(&s->waiting, 1);
	unsigned g0 = atomic_load(&s->gen);
	if (snd_ring_space(r)) { // a read that landed before the arm: no sleep (and no lost wake-up after it)
		atomic_store(&s->waiting, 0);
		return 0;
	}
	pthread_mutex_unlock(prod_mx);
	struct timespec ts;
	clock_gettime(CLOCK_REALTIME, &ts);
	ts.tv_nsec += (long)timeout_ms * 1000000L;
	while (ts.tv_nsec >= 1000000000L) { ts.tv_sec += 1; ts.tv_nsec -= 1000000000L; }
	pthread_mutex_lock(&s->mx);
	while (atomic_load(&s->gen) == g0)
		if (pthread_cond_timedwait(&s->cv, &s->mx, &ts) == ETIMEDOUT) break;
	pthread_mutex_unlock(&s->mx);
	atomic_store(&s->waiting, 0);
	pthread_mutex_lock(prod_mx);
	return 1;
}

#endif
