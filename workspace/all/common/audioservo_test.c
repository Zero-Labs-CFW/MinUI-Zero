// Pins the audio servo control law (audioservo.h). Pure unit: no SDL, no device.
#include <stdio.h>
#include <stdlib.h>
#include "audioservo.h"

static int fails = 0;
#define CHECK(cond, ...) do { if (!(cond)) { fails++; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

int main(void) {
	// sign: low occupancy -> negative trim (ring fills), high -> positive (ring drains)
	CHECK(audioservo_target_ppm(AUDIOSERVO_SETPOINT) == 0, "setpoint must be silent");
	CHECK(audioservo_target_ppm(AUDIOSERVO_SETPOINT - 5) < 0, "below setpoint must be negative");
	CHECK(audioservo_target_ppm(AUDIOSERVO_SETPOINT + 5) > 0, "above setpoint must be positive");

	// gentleness near the setpoint: 5 points off = 160ppm, 10 points = 1280ppm
	const int SP = AUDIOSERVO_SETPOINT, B = AUDIOSERVO_BAND;
	CHECK(audioservo_target_ppm(SP-5) == -160, "SP-5 -> %d (want -160)", audioservo_target_ppm(SP-5));
	CHECK(audioservo_target_ppm(SP+5) ==  160, "SP+5 -> %d (want +160)", audioservo_target_ppm(SP+5));
	CHECK(audioservo_target_ppm(SP-10) == -1280, "SP-10 -> %d (want -1280)", audioservo_target_ppm(SP-10));
	CHECK(audioservo_target_ppm(SP+10) ==  1280, "SP+10 -> %d (want +1280)", audioservo_target_ppm(SP+10));
	for (int occ = SP-5; occ <= SP+5; occ++)
		CHECK(abs(audioservo_target_ppm(occ)) <= 160, "occ %d inside +-5 must stay <= 160ppm", occ);

	// rails: exactly the rail at the band edges, clamped (not beyond) outside them
	CHECK(audioservo_target_ppm(SP-B) == -AUDIOSERVO_RAIL_PPM, "SP-BAND must be -rail");
	CHECK(audioservo_target_ppm(SP+B) ==  AUDIOSERVO_RAIL_PPM, "SP+BAND must be +rail");
	CHECK(audioservo_target_ppm(100) ==  AUDIOSERVO_RAIL_PPM, "100%% must clamp to +rail");
	CHECK(audioservo_target_ppm(0)   == -AUDIOSERVO_RAIL_PPM, "0%% must clamp to -rail");
	CHECK(audioservo_target_ppm(SP-B-5) == -AUDIOSERVO_RAIL_PPM, "a drained ring must be -rail");
	for (int occ = 0; occ <= 100; occ++)
		CHECK(abs(audioservo_target_ppm(occ)) <= AUDIOSERVO_RAIL_PPM, "occ %d exceeds the rail", occ);

	// monotonic: more occupancy never asks for less trim
	for (int occ = 1; occ <= 100; occ++)
		CHECK(audioservo_target_ppm(occ) >= audioservo_target_ppm(occ - 1), "not monotonic at %d", occ);

	// symmetry around the setpoint within the band
	for (int e = 0; e <= AUDIOSERVO_BAND; e++)
		CHECK(audioservo_target_ppm(AUDIOSERVO_SETPOINT + e) == -audioservo_target_ppm(AUDIOSERVO_SETPOINT - e), "asymmetric at +-%d", e);

	// smoothing: converges EXACTLY, never overshoots, ~2s time constant at 2Hz
	int adj = 0, target = -AUDIOSERVO_RAIL_PPM, ticks = 0;
	while (adj != target && ticks < 200) {
		int next = audioservo_step(adj, target);
		CHECK((target - next) * (target - adj) >= 0, "overshoot at tick %d (%d -> %d)", ticks, adj, next);
		adj = next; ticks++;
		if (ticks == AUDIOSERVO_SMOOTH) CHECK(adj <= -13000 && adj >= -14500, "after %d ticks want ~68%% of the way, got %d", AUDIOSERVO_SMOOTH, adj);
	}
	CHECK(adj == target, "did not converge to the rail: %d after %d ticks", adj, ticks);
	CHECK(ticks < 100, "convergence too slow: %d ticks", ticks);

	// and back to exactly zero (the hand-back case must not leave a 1ppm residue)
	target = 0; ticks = 0;
	while (adj != 0 && ticks < 200) { adj = audioservo_step(adj, 0); ticks++; }
	CHECK(adj == 0, "did not return to exactly 0: %d", adj);

	// a static target holds: stepping at the target is a no-op
	CHECK(audioservo_step(160, 160) == 160, "step at target must hold");
	CHECK(audioservo_step(-1, 0) == 0 && audioservo_step(1, 0) == 0, "1ppm gap must close in one step");

	if (fails) { printf("audioservo: %d FAILED\n", fails); return 1; }
	printf("audioservo: all checks passed\n");
	return 0;
}
