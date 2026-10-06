// governor_test.c — standalone synthetic harness for the closed-loop governor.
//
// No hardware. Feeds scripted temperature + frame-slip traces into the pure
// controller (gov_step) and asserts the safety + convergence properties from
// docs/thermal-governor-design.md:
//   - the commanded clock never leaves [f_min, f_max];
//   - a hot trace (temp >= ceiling) backs the clock down monotonically and never
//     raises it — the thermal ceiling always wins;
//   - a cold/idle trace sinks to the lowest clock (f_min) and stays there;
//   - a real workload converges to the lowest *stable* clock that holds frame rate
//     (settles at/above the requirement but strictly below f_max — a real saving),
//     without hunting wildly even when slip/slack alternate.
//
// Build + run: see .notes/verify.sh, or workspace/all/common/run-governor-tests.sh.
//
// Most scenarios model overrun realistically: a frame overruns iff the current clock
// is below the workload's required clock (f_req). gov_step sees the slip produced by
// the clock it last commanded, exactly as the device loop does.

#include <stdio.h>
#include <stdlib.h>
#include "governor.h"

// ---- gov_tick's platform dependency, stubbed so governor.c links standalone ----
static int g_last_set_khz = -1;
void PLAT_setCPUMaxFreq(int khz) { g_last_set_khz = khz; }
static int g_last_volt_khz = 0;
void PLAT_setCPUVoltForCeil(int khz) { g_last_volt_khz = khz; } // voltage authority stub

// ---- tiny assert framework ----
static int g_fail = 0;
#define CHECK(cond, ...) do { \
	if (!(cond)) { g_fail++; printf("  FAIL: "); printf(__VA_ARGS__); printf("\n        (%s:%d: %s)\n", __FILE__, __LINE__, #cond); } \
} while (0)

// Run a workload-driven trace: overrun is derived from whether the live clock holds
// f_req. Returns final state via *st; fills tail min/max over the last `tail` ticks.
static void run_workload(GovState* st, const GovProfile* p, int f_req, int temp_c,
                         int ticks, int tail, int* tail_min, int* tail_max,
                         int* tail_overruns) {
	int tmin = p->f_max, tmax = p->f_min, oruns = 0;
	for (int i = 0; i < ticks; i++) {
		int overrun = (st->ceil_khz < f_req); // the slip the current clock produces
		int khz = gov_step(st, p, temp_c, overrun);
		CHECK(khz >= p->f_min && khz <= p->f_max,
		      "clock %d left bracket [%d,%d]", khz, p->f_min, p->f_max);
		if (i >= ticks - tail) {
			if (khz < tmin) tmin = khz;
			if (khz > tmax) tmax = khz;
			// did the (post-step) clock still fail the workload?
			if (khz < f_req) oruns++;
		}
	}
	*tail_min = tmin; *tail_max = tmax; *tail_overruns = oruns;
}

static void test_profile_brackets(void) {
	printf("[profiles] low-end ceiling preserves schedutil burst headroom\n");
	CHECK(GOV_P_8BIT.f_min == 1008000,
	      "8-bit f_min should preserve the proven 1008 MHz burst ceiling, got %d", GOV_P_8BIT.f_min);
	CHECK(GOV_P_8BIT.f_max == 1008000,
	      "8-bit f_max changed unexpectedly: %d", GOV_P_8BIT.f_max);
}

// Controller-mechanics tests need room to move even though the shipping low-end
// profile deliberately leaves schedutil under one fixed stock ceiling.
static const GovProfile TEST_WIDE_8BIT = { 408000, 1008000 };

// ---- scenario 1: cold / idle — should sink to f_min and stay ----
static void test_cold_idle(void) {
	printf("[cold/idle] sinks to f_min and stays there\n");
	const GovProfile* p = &TEST_WIDE_8BIT;
	GovState st; gov_init(&st, p);
	int tmin, tmax, oruns;
	// f_req at f_min: the clock always holds frame rate, so the controller is free to sink.
	run_workload(&st, p, p->f_min, 40 /*cool*/, 200, 30, &tmin, &tmax, &oruns);
	CHECK(st.ceil_khz == p->f_min, "expected to settle at f_min=%d, got %d", p->f_min, st.ceil_khz);
	CHECK(tmax == p->f_min, "tail clock should be pinned at f_min, saw up to %d", tmax);
	CHECK(oruns == 0, "cold/idle should never overrun, saw %d tail overruns", oruns);
}

// ---- scenario 2: hot / overrun — thermal ceiling must win over the climb ----
static void test_hot_ceiling(void) {
	printf("[hot/ceiling] temp >= ceiling backs clock down monotonically, never up\n");
	const GovProfile* p = &GOV_P_PS1; // widest bracket
	GovState st; gov_init(&st, p);
	// Demand maximum performance (overrun=1 every tick) while pinned above the ceiling.
	// The ceiling branch must override the climb and walk the clock down to f_min.
	int prev = st.ceil_khz;
	int reached_min = 0;
	for (int i = 0; i < 200; i++) {
		int khz = gov_step(&st, p, GOV_T_CEIL_C + 8, 1 /*frames slipping*/);
		CHECK(khz <= prev, "tick %d: clock rose to %d from %d while over the ceiling", i, khz, prev);
		CHECK(khz >= p->f_min && khz <= p->f_max, "clock %d left bracket", khz);
		prev = khz;
		if (khz == p->f_min) reached_min = 1;
	}
	CHECK(reached_min, "hot trace should drive the clock down to f_min");
	CHECK(st.ceil_khz == p->f_min, "should hold f_min under sustained overheat, got %d", st.ceil_khz);
}

// ---- scenario 2b: thermal ceiling caps a hot-but-demanding workload below f_max ----
static void test_hot_caps_below_max(void) {
	printf("[hot/cap] heavy load that wants f_max is capped by the ceiling\n");
	const GovProfile* p = &GOV_P_PS1;
	GovState st; gov_init(&st, p);
	// Heavy workload (needs f_max) but the chip is over the ceiling: ceiling wins,
	// clock is pulled to f_min and the governor never exceeds it.
	int peak = p->f_min;
	for (int i = 0; i < 200; i++) {
		int overrun = (st.ceil_khz < p->f_max); // wants to climb to the top
		int khz = gov_step(&st, p, GOV_T_CEIL_C + 3, overrun);
		if (khz > peak) peak = khz;
	}
	// After the first tick the ceiling dominates; the only clock at/above the start is the
	// initial f_max, which the ceiling immediately reduces. Final must be f_min.
	CHECK(st.ceil_khz == p->f_min, "ceiling should pin a hot heavy load at f_min, got %d", st.ceil_khz);
}

// ---- scenario 3: oscillation-prone — alternating slip/slack must not hunt low ----
static void test_oscillation(void) {
	printf("[oscillation] alternating slip/slack settles high, does not hunt down\n");
	const GovProfile* p = &GOV_P_16BIT;
	GovState st; gov_init(&st, p);
	// Force strict alternation independent of clock. UP_DWELL=1 climbs on any slip;
	// DN_DWELL=4 needs 4 *consecutive* slack ticks to sink. Alternation resets slack_run
	// every other tick, so it can never sink — it must settle at f_max and stay.
	int tail_min = p->f_max;
	for (int i = 0; i < 200; i++) {
		int overrun = (i % 2 == 0); // slip, slack, slip, slack, ...
		int khz = gov_step(&st, p, 50 /*cool*/, overrun);
		CHECK(khz >= p->f_min && khz <= p->f_max, "clock %d left bracket", khz);
		if (i >= 170 && khz < tail_min) tail_min = khz;
	}
	CHECK(st.ceil_khz == p->f_max, "oscillating load should settle at f_max, got %d", st.ceil_khz);
	CHECK(tail_min == p->f_max, "should not hunt below f_max once settled, dipped to %d", tail_min);
}

// ---- scenario 3b: boundary workload must not limit-cycle at the floor (D23 / Contra) ----
// A game that slips at f_min but holds one step up used to cycle forever: sink to 600 ->
// slip (a burst of slow frames) -> climb to 816 -> 4 clean ticks -> sink -> slip -> ...
// Failed-floor memory (fail_khz/GOV_FAIL_HOLD) must bound the re-probes: at most one dip
// per hold window, not one per DN_DWELL.
static void test_boundary_no_limit_cycle(void) {
	printf("[boundary] floor-slipping workload dips at most once per fail-hold window\n");
	const GovProfile* p = &GOV_P_16BIT; // 600000..1416000
	int f_req = 700000;                 // slips at 600, holds at 816 — the Contra shape
	GovState st; gov_init(&st, p);
	int dips = 0, prev_holds = 0;
	const int TICKS = 600;              // ~5 minutes of ticks
	for (int i = 0; i < TICKS; i++) {
		int overrun = (st.ceil_khz < f_req);
		int khz = gov_step(&st, p, 40 /*cool*/, overrun);
		CHECK(khz >= p->f_min && khz <= p->f_max, "clock %d left bracket", khz);
		int holds = (khz >= f_req);
		if (prev_holds && !holds) dips++; // transitioned back into the failing clock
		prev_holds = holds;
	}
	// Old controller: a dip every DN_DWELL+1 ticks (~120 dips in 600). With the 120-tick
	// fail hold: the initial sink plus at most ~5 re-probes. Allow slack, but the cycle
	// must be gone by an order of magnitude.
	CHECK(dips <= 8, "limit cycle: %d dips into the failing clock over %d ticks", dips, TICKS);
	CHECK(st.ceil_khz >= f_req, "should end settled at/above the requirement, got %d", st.ceil_khz);
	printf("  dips into failing clock: %d over %d ticks (old controller: ~120)\n", dips, TICKS);
}

// ---- scenario 3c: predictive sink gate (D24 refinement) ----
// gov_sink_fits: predicted p95 at the lower clock (p95 * cur/next) must fit 85% of budget.
// Validated against measured device data: Contra@Low fits 408, PS1 settles at 1416.
static void test_predictive_sink_gate(void) {
	printf("[sink-gate] predictive fit reproduces the measured per-system sweet spots\n");
	// Contra@Low measured p95 ~7500us at 600 -> predicted 11029 at 408 < 14166 (85%% of 16667): fits
	CHECK(gov_sink_fits(600000, 408000, 7500, 16667) == 1, "Contra-shape should fit at 408");
	// PS1 measured pure p95 ~12000us at 1800 (arithmetic ladder: 1800 -> 1584 -> 1368):
	CHECK(gov_sink_fits(1800000, 1584000, 12000, 16667) == 1, "PS1 should fit at 1584");
	CHECK(gov_sink_fits(1584000, 1368000, 13636, 16667) == 0, "PS1 must NOT sink to 1368 (D14 trap)"); // 12000*1800/1584
	// guards
	CHECK(gov_sink_fits(600000, 600000, 99999, 16667) == 1, "not-a-sink is always allowed");
	CHECK(gov_sink_fits(600000, 408000, 0, 16667) == 1, "no work data must not block (fps signal guards)");

	// full trace: PS1-shaped workload — p95 scales with the live ceiling from a 12ms@1800 base.
	// The controller's ladder is arithmetic (1800-216=1584); on device the kernel quantizes a
	// 1584 ceiling down to the 1416 OPP — i.e. settling at 1584 IS the D14-validated 1416 spot.
	const GovProfile* p = &GOV_P_PS1; // 1008000..1800000
	GovState st; gov_init(&st, p);
	int min_seen = p->f_max;
	for (int i = 0; i < 200; i++) {
		long long p95 = 12000LL * p->f_max / st.ceil_khz;      // work at the current ceiling
		int fps_short = (st.ceil_khz < 1584000);               // below the 1416-OPP band the game drops rate
		int next = gov_sink_target(&st, p);
		int sig = fps_short ? GOV_SIGNAL_SLIP
		        : (gov_sink_fits(st.ceil_khz, next, (int)p95, 16667) ? GOV_SIGNAL_SLACK : GOV_SIGNAL_BUSY);
		gov_step(&st, p, 45 /*cool*/, sig);
		if (st.ceil_khz < min_seen) min_seen = st.ceil_khz;
	}
	CHECK(st.ceil_khz == 1584000, "PS1 trace should settle at 1584 (=1416 OPP effective), got %d", st.ceil_khz);
	CHECK(min_seen >= 1584000, "PS1 trace must never probe below 1584 (gate holds), dipped to %d", min_seen);
	printf("  PS1 trace settled at %d (kernel quantizes to the 1416 OPP; never below %d)\n", st.ceil_khz, min_seen);
}

// ---- scenario 4: real workload converges to the lowest stable clock (a saving) ----
static void test_converges_to_lowest_stable(void) {
	printf("[converge] mid workload settles at/above requirement but below f_max\n");
	const GovProfile* p = &GOV_P_PS1; // 1008000..1800000 (stock cap), wide enough for a clear mid point
	int f_req = 1500000;              // needs ~1.5GHz; should settle near there, not at the 1.8 cap
	GovState st; gov_init(&st, p);
	int tmin, tmax, oruns;
	run_workload(&st, p, f_req, 55 /*cool, below target*/, 400, 60, &tmin, &tmax, &oruns);
	// Converged to the lowest stable clock that holds frame rate:
	CHECK(tmax >= f_req, "settled below the requirement (%d < %d) — would drop frames", tmax, f_req);
	CHECK(tmax < p->f_max, "stayed pinned at f_max=%d — found no saving", p->f_max);
	CHECK(tmin >= p->f_min && tmax <= p->f_max, "left bracket [%d,%d]: [%d,%d]", p->f_min, p->f_max, tmin, tmax);
	// Hunts by at most one OPP step around the requirement (probe-down controllers do this);
	// the high water after each climb satisfies the workload, so frame rate holds in steady state.
	printf("  settled band [%d, %d] kHz for f_req=%d\n", tmin, tmax, f_req);
}

// ---- scenario 5: gov_tick I/O path smoke test (temp sensor absent -> -1) ----

// ---- capped fractional FF must settle BELOW f_max once its target holds (Codex v1.4-ff #1) ----
// Models minarch's new mapping: enabling a reachable 1.25x target first reads as a gross deficit
// (BIGSLIP -> f_max), then, while the target HOLDS, capped FF emits SLACK (generation-rate-driven)
// so the ladder probes down; a probe that slips is undone and remembered. The old mapping emitted
// BUSY forever -> pinned f_max for the whole FF session.
static void test_capped_ff_settles_below_max(void) {
	printf("[ff-capped] reachable FF target converges below f_max after the initial jump\n");
	const GovProfile* p = &GOV_P_PS1; // 1008000..1800000
	int f_req = 1500000;              // the 75fps (1.25x) workload: holds at 1608, slips below
	GovState st; gov_init(&st, p);
	int a,b,c;
	run_workload(&st, p, 1008000, 45, 120, 10, &a, &b, &c); // normal 60fps play settled low
	int khz = gov_step(&st, p, 45, GOV_SIGNAL_BIGSLIP);      // user enables 1.25x: initial deficit
	CHECK(khz == p->f_max, "initial FF deficit must jump to f_max, got %d", khz);
	// FF held for a long session; signals per the new minarch mapping (slip iff below f_req)
	int tail_min = p->f_max, tail_max = 0, tail_overruns = 0;
	for (int i = 0; i < 400; i++) {
		int slipping = (st.ceil_khz < f_req);
		khz = gov_step(&st, p, 45, slipping ? GOV_SIGNAL_SLIP : GOV_SIGNAL_SLACK);
		if (i >= 360) {
			if (khz < tail_min) tail_min = khz;
			if (khz > tail_max) tail_max = khz;
			if (khz < f_req) tail_overruns++;
		}
	}
	CHECK(tail_max < p->f_max, "capped FF must settle BELOW f_max (old behavior pinned 1800), tail_max=%d", tail_max);
	CHECK(tail_min >= f_req || tail_overruns <= 1, "settled clock must hold the FF target (tail_min=%d overruns=%d)", tail_min, tail_overruns);
}

static void test_tick_io(void) {
	printf("[gov_tick] device entry point writes a clock via PLAT_setCPUMaxFreq\n");
	const GovProfile* p = &GOV_P_8BIT;
	GovState st; gov_init(&st, p);
	g_last_set_khz = -1;
	gov_tick(&st, p, 0); // temp sensor path absent on this host -> gov_read_temp_c()=-1
	// With GOV_DISABLE unset, gov_tick must have written something in-bracket.
	if (getenv("GOV_DISABLE") == NULL) {
		CHECK(g_last_set_khz >= p->f_min && g_last_set_khz <= p->f_max,
		      "gov_tick wrote %d, out of bracket [%d,%d]", g_last_set_khz, p->f_min, p->f_max);
	}
}

static void test_boot_slip_at_max_still_sinks(void) {
	printf("[boot-slip] slips at f_max must not arm fail memory (GBC 1008-pin, 2026-07-09)\n");
	const GovProfile* p = &TEST_WIDE_8BIT;
	GovState st; gov_init(&st, p);
	// boot churn: several slip ticks while fully provisioned (load spikes at f_max)
	for (int i = 0; i < 6; i++) gov_step(&st, p, 40, GOV_SIGNAL_SLIP);
	CHECK(st.fail_khz == 0, "slip at f_max armed fail memory (fail_khz=%d)", st.fail_khz);
	CHECK(st.fail_hold == 0, "slip at f_max armed a hold (fail_hold=%d)", st.fail_hold);
	// then a genuinely light workload: the controller must be free to sink to the floor
	for (int i = 0; i < 40; i++) gov_step(&st, p, 40, GOV_SIGNAL_SLACK);
	CHECK(st.ceil_khz == p->f_min, "post-boot light load should reach f_min=%d, stuck at %d",
	      p->f_min, st.ceil_khz);
}

static void test_sink_despite_busy_noise(void) {
	printf("[busy-noise] sporadic BUSY windows (fsync stalls) must not block sinking\n");
	const GovProfile* p = &TEST_WIDE_8BIT;
	GovState st; gov_init(&st, p);
	// light game with a stall window every 3rd tick: SLACK,SLACK,BUSY,repeat
	for (int i = 0; i < 120; i++)
		gov_step(&st, p, 40, (i % 3 == 2) ? GOV_SIGNAL_BUSY : GOV_SIGNAL_SLACK);
	CHECK(st.ceil_khz == p->f_min, "busy-noise pinned the ceiling at %d (want f_min=%d)",
	      st.ceil_khz, p->f_min);
}

// GOV_AUDIBLE_WINDOW is "~2 s, two generation reports" = 4 ticks at 2 Hz. since_sink is bumped at the top of
// gov_step, so the k-th tick after the sink sees k: the check is inclusive, or only 3 ticks (~1.5 s) counted
// and the first fully post-sink BIGSLIP often missed it (code review, 2026-10-05).
static void test_audible_window_edges(void) {
	printf("[audible] the window covers ticks 1-4 after our own sink, not 5\n");
	const GovProfile* p = &GOV_P_16BIT;
	for (int k = 4; k <= 5; k++) {
		GovState st; gov_init(&st, p);
		int probe = gov_opp_above(p, p->f_min);
		st.ceil_khz = probe; st.slack_run = GOV_DN_DWELL; st.fail_hold = 0;
		gov_step(&st, p, 40, GOV_SIGNAL_SLACK);                     // sink: since_sink = 0
		int failed = st.ceil_khz;
		for (int i = 1; i < k; i++) gov_step(&st, p, 40, GOV_SIGNAL_BUSY); // hold, no probe
		CHECK(st.ceil_khz == failed, "setup: BUSY must hold the sunk ceiling %d (got %d)", failed, st.ceil_khz);
		gov_step(&st, p, 40, GOV_SIGNAL_BIGSLIP);                   // since_sink == k on this tick
		if (k == 4) CHECK(st.audible_khz == failed, "BIGSLIP on tick 4 after the sink should mark %d audible (got %d)", failed, st.audible_khz);
		else        CHECK(st.audible_khz == 0, "BIGSLIP on tick 5 is outside the window (audible=%d)", st.audible_khz);
	}
}

static void test_audible_marks_the_probe(void) {
	printf("[audible] the clock banned is the one the probe set, not the one a SLIP restored\n");
	// code review 2026-10-06: sink 1032 -> 816, a SLIP restores 1032, then a BIGSLIP (window now fully
	// post-sink) marked 1032 audible, so the session sat at 1200 although only 816 had failed.
	const GovProfile* p = &GOV_P_16BIT;
	GovState st; gov_init(&st, p);
	int from = gov_opp_above(p, gov_opp_above(p, p->f_min));
	st.ceil_khz = from; st.slack_run = GOV_DN_DWELL; st.fail_hold = 0;
	gov_step(&st, p, 40, GOV_SIGNAL_SLACK);                     // sink: the probe
	int probe = st.ceil_khz;
	CHECK(probe < from, "setup: the sink should lower the ceiling (%d -> %d)", from, probe);
	gov_step(&st, p, 40, GOV_SIGNAL_SLIP);                      // probe-undo restores the pre-sink ceiling
	CHECK(st.ceil_khz == from, "setup: SLIP should restore %d (got %d)", from, st.ceil_khz);
	gov_step(&st, p, 40, GOV_SIGNAL_BIGSLIP);                   // the deep reading arrives a tick later
	CHECK(st.audible_khz == probe, "BIGSLIP should ban the probed %d, not %d (got %d)", probe, from, st.audible_khz);
	// and the session can still sink to the lowest clock above the failed probe (not one OPP higher)
	st.ceil_khz = p->f_max; st.slack_run = 0; st.fail_hold = 0;
	int lowest = p->f_max;
	for (int i = 0; i < 4000; i++) { gov_step(&st, p, 40, GOV_SIGNAL_SLACK); if (st.ceil_khz < lowest) lowest = st.ceil_khz; }
	CHECK(lowest > probe && gov_opp_below(p, lowest) <= probe,
	      "after the ban the floor should be the lowest clock above the failed probe %d (got %d)", probe, lowest);
}

static void test_audio_low_water(void) {
	printf("[low-water] a low audio ring climbs to f_max at once, like a deep slip\n");
	const GovProfile* p = &GOV_P_16BIT;
	GovState st; gov_init(&st, p);
	// sitting sunk for a while (not a fresh probe): climb + failure memory, no audible ban
	st.ceil_khz = p->f_min; st.since_sink = 100; st.probe_khz = p->f_min;
	g_last_set_khz = 0;
	CHECK(gov_audio_low(&st, p) == 1, "low-water below f_max must move the ceiling");
	CHECK(st.ceil_khz == p->f_max && g_last_set_khz == p->f_max, "low-water must write f_max at once (ceil=%d wrote=%d)", st.ceil_khz, g_last_set_khz);
	CHECK(st.fail_khz == p->f_min && st.fail_hold > 0, "low-water must remember the failed ceiling %d (fail=%d hold=%d)", p->f_min, st.fail_khz, st.fail_hold);
	CHECK(st.audible_khz == 0, "a low ring long after a sink is a scene change, not an audible probe (audible=%d)", st.audible_khz);
	// already at f_max: nothing to do, nothing written
	g_last_set_khz = 0;
	CHECK(gov_audio_low(&st, p) == 0 && g_last_set_khz == 0, "low-water at f_max must be a no-op");
	// right after our own sink: that probe is audible and banned
	gov_init(&st, p);
	int from = gov_opp_above(p, p->f_min);
	st.ceil_khz = from; st.slack_run = GOV_DN_DWELL; st.fail_hold = 0;
	gov_step(&st, p, 40, GOV_SIGNAL_SLACK);                     // sink: the probe
	int probe = st.ceil_khz;
	gov_step(&st, p, 40, GOV_SIGNAL_BUSY);                      // one tick later the ring runs low
	CHECK(gov_audio_low(&st, p) == 1 && st.audible_khz == probe, "low-water right after a sink must ban the probe %d (audible=%d)", probe, st.audible_khz);
}

static void test_slip_recovery_priority(void) {
	printf("[slip-recovery] BIGSLIP outranks probe undo; ordinary slip restores presink\n");
	const GovProfile* p = &GOV_P_PS1;
	GovState st; gov_init(&st, p);
	st.ceil_khz = 1200000;
	st.presink_khz = 1416000;
	st.since_sink = 1;
	CHECK(gov_step(&st, p, 40, GOV_SIGNAL_BIGSLIP) == p->f_max,
	      "BIGSLIP should jump directly to f_max=%d, got %d", p->f_max, st.ceil_khz);

	gov_init(&st, p);
	st.ceil_khz = 1200000;
	st.presink_khz = 1416000;
	st.since_sink = 1;
	CHECK(gov_step(&st, p, 40, GOV_SIGNAL_SLIP) == 1416000,
	      "probe-caused slip should restore presink=1416000, got %d", st.ceil_khz);
}

static void test_fail_hold_escalates(void) {
	printf("[fail-hold] repeat failures escalate 120 -> 240 -> 480 ticks\n");
	const GovProfile* p = &GOV_P_16BIT;
	GovState st; gov_init(&st, p);
	st.ceil_khz = p->f_min;
	gov_step(&st, p, 40, GOV_SIGNAL_SLIP);
	CHECK(st.fail_hold == 120 && st.fail_streak == 0,
	      "first failure should hold 120 ticks (hold=%d streak=%d)", st.fail_hold, st.fail_streak);
	st.ceil_khz = p->f_min; st.fail_hold = 0;
	gov_step(&st, p, 40, GOV_SIGNAL_SLIP);
	CHECK(st.fail_hold == 240 && st.fail_streak == 1,
	      "second failure should hold 240 ticks (hold=%d streak=%d)", st.fail_hold, st.fail_streak);
	st.ceil_khz = p->f_min; st.fail_hold = 0;
	gov_step(&st, p, 40, GOV_SIGNAL_SLIP);
	CHECK(st.fail_hold == 480 && st.fail_streak == 2,
	      "third failure should hold 480 ticks (hold=%d streak=%d)", st.fail_hold, st.fail_streak);
}

static void test_probe_bigslip_is_not_retried(void) {
	printf("[audible] a BIGSLIP caused by our own sink is never re-probed until a scene burst\n");
	const GovProfile* p = &GOV_P_16BIT;
	GovState st; gov_init(&st, p);
	int probe = gov_opp_above(p, p->f_min);
	st.ceil_khz = probe; st.slack_run = GOV_DN_DWELL; st.fail_hold = 0;
	gov_step(&st, p, 40, GOV_SIGNAL_SLACK);                 // sink one step
	CHECK(st.ceil_khz < probe, "setup: expected a sink below %d, got %d", probe, st.ceil_khz);
	int failed = st.ceil_khz;
	gov_step(&st, p, 40, GOV_SIGNAL_BIGSLIP);               // the probe collapsed generation
	CHECK(st.audible_khz == failed, "probe BIGSLIP should mark %d audible (got %d)", failed, st.audible_khz);
	// Codex 2026-10-03: a later ORDINARY slip rewrote fail_hold and re-opened the floor. Recover, sink
	// back toward it, slip mildly, then idle for ~16 min: the audible floor must never be re-entered.
	for (int i = 0; i < 40; i++) gov_step(&st, p, 40, GOV_SIGNAL_SLACK);
	gov_step(&st, p, 40, GOV_SIGNAL_SLIP);
	for (int i = 0; i < 2000; i++) {
		gov_step(&st, p, 40, GOV_SIGNAL_SLACK);
		if (st.ceil_khz <= failed) break;
	}
	CHECK(st.ceil_khz > failed, "re-probed the audible floor %d after an ordinary slip + slack (ceil=%d)", failed, st.ceil_khz);
	gov_burst(&st, p);                                      // a real scene change re-arms probing
	CHECK(st.audible_khz == 0, "scene burst should clear the audible floor (got %d)", st.audible_khz);
	// a BIGSLIP NOT caused by a recent sink (scene got heavier at a settled ceiling) is not audible-marked
	gov_init(&st, p); st.ceil_khz = probe; st.since_sink = 200;
	gov_step(&st, p, 40, GOV_SIGNAL_BIGSLIP);
	CHECK(st.audible_khz == 0, "unprovoked BIGSLIP should not mark an audible floor (got %d)", st.audible_khz);
	CHECK(st.fail_hold == 120, "unprovoked BIGSLIP should use the normal hold (hold=%d)", st.fail_hold);
}

static void test_scene_burst_resets_floor_memory(void) {
	printf("[scene-burst] geometry change resets stale floor memory and provisions f_max\n");
	const GovProfile* p = &GOV_P_PS1;
	GovState st; gov_init(&st, p);
	st.ceil_khz = 1200000;
	st.fail_khz = 1200000;
	st.fail_hold = 960;
	st.fail_streak = 3;
	st.presink_khz = 1416000;
	g_last_set_khz = -1;
	gov_burst(&st, p);
	CHECK(st.ceil_khz == p->f_max && g_last_set_khz == p->f_max,
	      "burst should command f_max=%d (state=%d write=%d)", p->f_max, st.ceil_khz, g_last_set_khz);
	CHECK(st.fail_khz == 0 && st.fail_hold == 0 && st.fail_streak == 0 && st.presink_khz == 0,
	      "burst retained stale failure memory (%d/%d/%d presink=%d)",
	      st.fail_khz, st.fail_hold, st.fail_streak, st.presink_khz);
}

// ---- OPP ladder: commanded ceilings must be REAL frequencies ---------------------------------
// The A133P table. With the ladder present, the stride-built phantoms (984, 768) must never
// appear in ceil_khz: descent 1200 -> 1008, not 984 (which the kernel would run as 816 while
// every prediction assumed 984 — the game-start mis-probe class, 2026-08-31).
static const int A133P[] = { 408000, 600000, 816000, 1008000, 1200000, 1416000, 1608000, 1800000 };

static GovProfile ladder_profile(int fmin, int fmax) {
	GovProfile p = { .f_min = fmin, .f_max = fmax, .n_opps = 8 };
	for (int i = 0; i < 8; i++) p.opps[i] = A133P[i];
	return p;
}

static void test_ladder_helpers(void) {
	GovProfile p = ladder_profile(600000, 1416000);
	CHECK(gov_opp_below(&p, 1200000) == 1008000, "below 1200 is 1008, not the phantom 984");
	CHECK(gov_opp_below(&p, 1008000) == 816000,  "below 1008 is 816");
	CHECK(gov_opp_above(&p, 816000) == 1008000,  "above 816 is 1008");
	CHECK(gov_opp_above(&p, 1800000) == 1800000 + GOV_STEP_KHZ, "above the top falls back to stride");
	CHECK(gov_opp_snap(&p, 984000) == 1008000,   "984 snaps to 1008 (ties/nearest go up)");
	GovProfile none = { .f_min = 600000, .f_max = 1416000, .n_opps = 0 };
	CHECK(gov_opp_below(&none, 1200000) == 1200000 - GOV_STEP_KHZ, "no table -> legacy stride");
}

static void test_ladder_descent_hits_only_real_opps(void) {
	GovProfile p = ladder_profile(600000, 1416000);
	GovState st; gov_init(&st, &p);
	// plenty of cool slack: descend all the way; every commanded ceiling must be in the table
	for (int t = 0; t < 64; t++) {
		int c = gov_step(&st, &p, 40, GOV_SIGNAL_SLACK);
		int real = 0;
		for (int i = 0; i < p.n_opps; i++) if (c == p.opps[i]) real = 1;
		CHECK(real, "every ceiling during descent is a real OPP");
	}
	CHECK(st.ceil_khz == 600000, "descent bottoms at f_min");
	// climb one step from the floor: must land on 816, not 600+216=816 coincidence... assert table membership
	gov_step(&st, &p, 40, GOV_SIGNAL_SLIP);
	int c = st.ceil_khz, real = 0;
	for (int i = 0; i < p.n_opps; i++) if (c == p.opps[i]) real = 1;
	CHECK(real && c > 600000, "single-step climb lands on a real OPP above the floor");
}

int main(void) {
	printf("== governor synthetic harness ==\n");
	test_ladder_helpers();
	test_ladder_descent_hits_only_real_opps();
	test_profile_brackets();
	test_cold_idle();
	test_boot_slip_at_max_still_sinks();
	test_sink_despite_busy_noise();
	test_slip_recovery_priority();
	test_fail_hold_escalates();
	test_probe_bigslip_is_not_retried();
	test_audible_window_edges();
	test_audible_marks_the_probe();
	test_audio_low_water();
	test_scene_burst_resets_floor_memory();
	test_hot_ceiling();
	test_hot_caps_below_max();
	test_oscillation();
	test_boundary_no_limit_cycle();
	test_predictive_sink_gate();
	test_converges_to_lowest_stable();
	test_capped_ff_settles_below_max();
	test_tick_io();
	printf("== %s ==\n", g_fail == 0 ? "ALL PASS" : "FAILURES");
	if (g_fail) { printf("%d check(s) failed\n", g_fail); return 1; }
	return 0;
}
