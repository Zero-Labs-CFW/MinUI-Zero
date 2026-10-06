// Audio ring occupancy servo: the pure control law, unit-tested in audioservo_test.c
// (make test-audioservo). The loop wiring (eligibility, block detector, hand-back) lives in
// minarch.c; nothing here touches the resampler or knows about threads.
//
// Cubic on occupancy error: nearly silent within a few points of the setpoint (5 points off is
// 160ppm), the full rail at the band edges (setpoint +-BAND). Borrowed in shape from NextUI's
// buffer-fill term (their rail is ~4.3%; RetroArch caps timing skew at 5%); ours stops at 2%,
// ~35 cents of pitch for a second or two after a drain, because Zero's answer to a sustained
// slowdown is the clock or the stall, never detuned music. The applied trim is smoothed with a
// first-order filter so the resampler never sees a step (NextUI averages ~120 batches, ~2s).
//
// SIGN (the thing to get right): sample_rate_in_adj = in * (1e6 + ppm) / 1e6, so a HIGHER ppm
// treats the input as faster = fewer output frames per input frame = the ring DRAINS. Low
// occupancy therefore needs a NEGATIVE trim.
#ifndef AUDIOSERVO_H
#define AUDIOSERVO_H

#define AUDIOSERVO_SETPOINT 50    // % ring occupancy to hold: the midpoint, as NextUI does = ~67ms of the
                                  // 8-frame ring (RetroArch's 64ms class), with equal room for present
                                  // bursts above and stalls below (75% of a 5-frame ring left 21ms above
                                  // and the Brick hit full/empty every second, 2026-10-03)
#define AUDIOSERVO_BAND     25    // points from the setpoint at which the trim reaches the rail
#define AUDIOSERVO_RAIL_PPM 20000 // 2% pitch at the rails
#define AUDIOSERVO_SMOOTH   4     // first-order filter, in ticks; at 2Hz ~2s time constant

// Trim the resampler should converge to for this occupancy (clamped to +-RAIL by construction).
static inline int audioservo_target_ppm(int occ_pct) {
	int e = occ_pct - AUDIOSERVO_SETPOINT;
	if (e >  AUDIOSERVO_BAND) e =  AUDIOSERVO_BAND;
	if (e < -AUDIOSERVO_BAND) e = -AUDIOSERVO_BAND;
	long c = (long)e * e * e; // |c| <= BAND^3 = 15625; c * RAIL = 3.1e8, fits a 32-bit long
	return (int)(c * AUDIOSERVO_RAIL_PPM / ((long)AUDIOSERVO_BAND * AUDIOSERVO_BAND * AUDIOSERVO_BAND));
}

// A window in which the producer blocked on a FULL ring. A high reading then measures the block, not the
// level, so the cubic cannot be used. Where something other than audio clocks the loop (presents wait on
// vsync, skipped frames sleep to their slot) a full ring is only a ring that is too full: at equal video and
// audio rates it stays full forever, every window blocks, and the servo used to skip them all (Brick Pro
// 2026-10-05: pinned near full for whole sessions). Drain it gently, at RetroArch's rate-control delta (0.5%,
// ~9 cents), and never less than the trim already applied; once the ring is off full the cubic takes over.
// But a window can block early and still END low (a stall after the block drained it): a reading below the
// setpoint is a real level, not the pacer, so the cubic refills it (Codex review 4, 2026-10-06).
#define AUDIOSERVO_FULL_PPM 5000
static inline int audioservo_blocked_target_ppm(int adj, int occ_pct) {
	if (occ_pct < AUDIOSERVO_SETPOINT) return audioservo_target_ppm(occ_pct);
	return adj > AUDIOSERVO_FULL_PPM ? adj : AUDIOSERVO_FULL_PPM;
}

// One smoothing step of the applied trim toward the target; call once per tick. Integer and
// exact: the last ppm of a gap is closed by a unit step instead of sticking at a rounded zero.
static inline int audioservo_step(int adj, int target) {
	int diff = target - adj;
	int step = diff / AUDIOSERVO_SMOOTH;
	if (step == 0 && diff != 0) step = diff > 0 ? 1 : -1;
	return adj + step;
}

#endif
