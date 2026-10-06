// governor.c — closed-loop thermal/perf CPU governor. See governor.h and
// docs/thermal-governor-design.md.
//
// Self-contained: depends only on <stdio.h>/<stdlib.h> and a forward declaration of
// PLAT_setCPUMaxFreq() (provided by the platform layer on device, by a stub in the
// synthetic harness). No SDL / api.h, so the pure controller compiles and runs
// anywhere for testing.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "governor.h"

// Platform primitive: set the cpufreq ceiling (scaling_max_freq); the kernel schedutil
// governor picks beneath it. Real impl in <platform>/platform.c, stub in governor_test.c.
void PLAT_setCPUMaxFreq(int khz);
void PLAT_setCPUVoltForCeil(int khz);

// ---- Tunables (ASSUMED — safe by construction; confirm on device, see design doc) ----
// Why safe if wrong: (1) writes snap to the nearest valid OPP, (2) the loop self-corrects
// bad brackets at runtime, (3) the conservative ceiling bounds the downside to "too cautious".
// Thermal thresholds (GOV_T_TARGET_C / GOV_T_CEIL_C) live in governor.h so the unit tests
// can assert against the real values instead of hardcoding one platform's numbers.
// GOV_STEP_KHZ lives in governor.h (shared with minarch's per-game governor memory)
// GOV_DN_DWELL lives in governor.h (shared with the gov-memory accelerated ladder)
#define GOV_FAIL_HOLD  120     // ticks (~60s) before re-probing a ceiling that slipped. Without this
                               // the loop limit-cycles at a boundary (600 slip -> 816 clean -> sink
                               // -> 600 slip -> ... = periodic slowdown bursts; Contra 2026-07-01)
#define GOV_AUDIBLE_WINDOW 4   // ticks (~2s at 2 Hz) after our own sink within which a BIGSLIP is blamed on
                               // that probe: two generation publications (trackFPS posts ~1/s). Inclusive:
                               // since_sink is bumped at the top of the tick, so tick k sees k (`<` gave
                               // only 3 ticks; code review 2026-10-05, test_audible_window_edges). Wider
                               // windows risk blaming an unrelated scene change and holding one OPP high
                               // for the session (Codex review 2026-10-03).

// CONFIRMED tg5040 2026-06-30: thermal_zone0 = cpu_thermal_zone (milli-C).
#define GOV_T_SENSOR   "/sys/class/thermal/thermal_zone0/temp"
#define GOV_CUR_FREQ   "/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq"
// CONFIRMED miyoomini/SSD202D 2026-07-24: NO thermal_zone at all; the CPU temp lives in the
// cpufreq node in the form "Temp=44". Frequency also sits under policy0 on that BSP. These are
// fallbacks, not overrides — tg5040 still hits its own paths first, so one binary logic path
// serves both devices and the host unit tests are unaffected.
#define GOV_T_SENSOR_ALT "/sys/devices/system/cpu/cpufreq/temp_out"
#define GOV_CUR_FREQ_ALT "/sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq"

// MEASURED OPP table (device 2026-06-30): 408 600 816 1008 1200 1416 1608 1800 2000 MHz.
// 2000000 is exposed but is the OC we avoid (never require overclocking); cap at 1800.
#define GOV_STOCK_MAX_KHZ 1800000

// ---- Per-system ceiling brackets (f_min/f_max are real OPPs; f_max <= stock cap, no OC) ----
#if defined(GOV_PLATFORM_MIYOOMINI)
// miyoomini / SigmaStar SSD202D. MEASURED on-device 2026-07-24:
//   OPP table       = 400 600 800 1000 1100 1200 MHz (1200 = top stock step; no OC)
//   GBC (gambatte)  = 88% at 400 MHz, never saturated -> the light-system floor really is 400
//   SNES (supafaust)= 94% at 1200 MHz, saturated at every step -> heavy content needs the top
// Unlike tg5040 there is no schedutil: the commanded ceiling IS the clock (userspace +
// scaling_setspeed), so f_min is a real floor the CPU will sit at, not just a ceiling.
const GovProfile GOV_P_8BIT    = {  400000, 1200000 }; // GB/GBC/NES/SMS/GG/PCE — big headroom here
const GovProfile GOV_P_16BIT   = {  600000, 1200000 }; // SNES/Genesis/GBA/VB
const GovProfile GOV_P_PS1     = { 1000000, 1200000 }; // PS1 is clock-bound on a dual-A7
const GovProfile GOV_P_DEFAULT = {  600000, 1200000 };
#elif defined(GOV_PLATFORM_H700)
// h700 / Allwinner H700 (RG35XX Plus/H). OPP table READ from the device 2026-08-06:
//   480 720 936 1008 1104 1200 1320 1416 1512 MHz (1512 = cpuinfo_max_freq, the stock cap; no OC).
// schedutil available, so the commanded value is a CEILING and schedutil idles beneath it. f_max
// gives the closed loop room; f_min is a real floor. The ACTUAL floor each system reaches is
// discovered on-device by the loop (sink while frames hold, restore on slip) — not guessed here.
const GovProfile GOV_P_8BIT    = {  480000, 1008000 }; // GB/GBC/NES/SMS/GG/PCE — sink toward 480
const GovProfile GOV_P_16BIT   = {  480000, 1416000 }; // SNES/Genesis/GBA/VB
const GovProfile GOV_P_PS1     = {  720000, 1512000 }; // PS1 heaviest — full stock cap available
const GovProfile GOV_P_DEFAULT = {  480000, 1512000 };
#else
const GovProfile GOV_P_8BIT   = { 1008000, 1008000 }; // schedutil still idles below this; the ceiling preserves short GLES bursts
const GovProfile GOV_P_16BIT  = {  600000, 1416000 }; // MEASURED: 1416 is a real OPP (1320 was not)
const GovProfile GOV_P_PS1    = { 1008000, 1800000 };
const GovProfile GOV_P_DEFAULT = { 600000, 1800000 };
#endif

int gov_read_temp_c(void) {
	FILE* f = fopen(GOV_T_SENSOR, "r");
	if (f) {
		int mc = -1;
		if (fscanf(f, "%d", &mc) != 1) mc = -1;
		fclose(f);
		return mc < 0 ? -1 : mc / 1000; // milli-C -> C
	}
	// fallback: "Temp=44" (already whole degrees C), miyoomini/SSD202D
	f = fopen(GOV_T_SENSOR_ALT, "r");
	if (!f) return -1;
	char buf[32] = {0};
	int c = -1;
	if (fgets(buf, sizeof(buf), f)) {
		const char* eq = strchr(buf, '=');
		c = eq ? atoi(eq + 1) : atoi(buf);
	}
	fclose(f);
	return c > 0 ? c : -1;
}

int gov_read_cur_khz(void) {
	FILE* f = fopen(GOV_CUR_FREQ, "r");
	if (!f) f = fopen(GOV_CUR_FREQ_ALT, "r");
	if (!f) return -1;
	int khz = -1;
	if (fscanf(f, "%d", &khz) != 1) khz = -1;
	fclose(f);
	return khz;
}

void gov_init(GovState* st, const GovProfile* p) {
	st->ceil_khz = p->f_max; // start high so the first frames never starve; sink from there
	st->slip_run = 0;
	st->slack_run = 0;
	st->fail_khz = 0;
	st->fail_hold = 0;
	st->fail_streak = 0;
	st->presink_khz = 0;
	st->audible_khz = 0;
	st->since_sink = 255;
}

int gov_step(GovState* st, const GovProfile* p, int temp_c, int frame_overrun) {
	// 1) thermal backstop — always wins
	if (temp_c >= 0 && temp_c >= GOV_T_CEIL_C) {
		st->ceil_khz -= GOV_STEP_KHZ;
		if (st->ceil_khz < p->f_min) st->ceil_khz = p->f_min;
		st->slip_run = st->slack_run = 0;
		return st->ceil_khz;
	}

	// failed-floor memory decays each tick; on expiry allow one re-probe (scene may have
	// lightened). fail_khz itself is kept: if the re-probe slips again it's a repeat offense
	// and the hold escalates (see the slip branch) instead of limit-cycling every ~60s.
	if (st->fail_hold > 0) --st->fail_hold;
	if (st->since_sink < 255) st->since_sink++;

	if (frame_overrun == GOV_SIGNAL_BUSY) {
		// 2a) holding frame rate but with little headroom — do not probe lower this tick
		// (race-to-idle, D14/D21), but nothing is slipping, so don't climb either.
		// BUSY no longer ERASES slack progress: rare stall frames (SRAM fsync, ~20ms)
		// sprinkle BUSY windows through otherwise-idle games, and a hard reset meant the
		// 4-consecutive-slack requirement never accumulated — GBC pinned at 1008 with
		// p95=7.7ms/16.7 (2026-07-09 gate telemetry). A wrong sink is cheap now (one-tick
		// probe-undo + BIGSLIP-to-max + fail memory), so the gate can afford leniency.
		st->slip_run = 0;
	}
	else if (frame_overrun) {
		// 2) need more performance — climb fast, and remember the ceiling that proved too low.
		// A slip at/below a ceiling that already failed is a repeat offense: escalate the hold
		// (60s -> 2m -> 4m -> 8m) so known-bad probes become rare instead of periodic
		// (BR2 480i screens 2026-07-09: the ~60s re-probe cycle was an audible slowdown burst).
		// Fail memory only arms for a ceiling BELOW f_max: a slip while already fully
		// provisioned proves nothing about lower clocks (no probe failed), and remembering
		// it blocked ALL sinking — boot-load slips at f_max pinned GBC at 1008 for up to
		// 8 min (the escalated hold), refreshed forever by borderline slips. Found by the
		// 2026-07-09 gate telemetry: signal=SLACK, p95 7.7ms/16.7ms, ceiling frozen.
		if (st->ceil_khz < p->f_max) {
			if (st->fail_khz > 0 && st->ceil_khz <= st->fail_khz) {
				if (st->fail_streak < 3) st->fail_streak++;
			}
			else st->fail_streak = 0;
			if (st->ceil_khz > st->fail_khz) st->fail_khz = st->ceil_khz;
			st->fail_hold = GOV_FAIL_HOLD << st->fail_streak;
			// A deep deficit right after our own sink: that probe is proven audible, so it is never
			// retried until a scene burst (the 60s->8m re-probe ladder was a dropout burst per retry
			// on GBC, Brick + H 2026-10-02). Fixed-clock firmwares (NextUI's per-pak speeds) never
			// take this risk at all; we take it once. Own field: later ordinary slips rewrite
			// fail_hold and must not shorten this (Codex review 2026-10-03).
			if (frame_overrun == GOV_SIGNAL_BIGSLIP && st->since_sink <= GOV_AUDIBLE_WINDOW
			    && st->ceil_khz > st->audible_khz)
				st->audible_khz = st->ceil_khz;
		}
		st->slip_run++;
		st->slack_run = 0;
		if (st->ceil_khz < p->f_max) {
			// Recovery sizing, cheapest-adequate first (every extra tick under target is
			// audible — BR2 char select 2026-07-09: probe to 1008 on a ~1584 screen = crunch):
			// 1) the slip arrived right after a sink -> that probe CAUSED it; undo it in one
			//    tick by restoring the pre-sink ceiling;
			// 2) big deficit (>=10% under target) -> jump straight to f_max;
			// 3) small deficit -> one step, then f_max if it survives a second tick.
			if (frame_overrun == GOV_SIGNAL_BIGSLIP)
				st->ceil_khz = p->f_max; // severity outranks probe-undo: a deep deficit
				                         // restored to a too-low pre-sink ceiling pays twice
			else if (st->since_sink < 8 && st->presink_khz > st->ceil_khz)
				st->ceil_khz = st->presink_khz;
			else if (st->slip_run >= 2)
				st->ceil_khz = p->f_max;
			else st->ceil_khz = gov_opp_above(p, st->ceil_khz);
			if (st->ceil_khz > p->f_max) st->ceil_khz = p->f_max;
		}
	} else {
		// 3) have slack — probe downward (the cold win), but only when cool enough and not
		//    back into a ceiling that recently slipped (see GOV_FAIL_HOLD)
		st->slack_run++;
		st->slip_run = 0;
		int cool_enough = (temp_c < 0) || (temp_c <= GOV_T_TARGET_C);
		int next_khz = gov_opp_below(p, st->ceil_khz);
		if (next_khz < p->f_min) next_khz = p->f_min;
		int not_failed = ((st->fail_hold == 0) || (next_khz > st->fail_khz)) && next_khz > st->audible_khz;
		if (st->slack_run >= GOV_DN_DWELL && cool_enough && not_failed && st->ceil_khz > p->f_min) {
			st->presink_khz = st->ceil_khz; // remembered so a probe-caused slip undoes in one tick
			st->since_sink = 0;             // (thermal sinks deliberately don't set these: temp wins)
			st->ceil_khz = next_khz;
			st->slack_run = 0;
		}
	}
	return st->ceil_khz;
}

int gov_opp_below(const GovProfile* p, int khz) {
	if (p->n_opps <= 0) return khz - GOV_STEP_KHZ;
	int best = -1;
	for (int i = 0; i < p->n_opps; i++)
		if (p->opps[i] < khz && p->opps[i] > best) best = p->opps[i];
	return best > 0 ? best : khz - GOV_STEP_KHZ;
}
int gov_opp_above(const GovProfile* p, int khz) {
	if (p->n_opps <= 0) return khz + GOV_STEP_KHZ;
	int best = 0x7fffffff;
	for (int i = 0; i < p->n_opps; i++)
		if (p->opps[i] > khz && p->opps[i] < best) best = p->opps[i];
	return best != 0x7fffffff ? best : khz + GOV_STEP_KHZ;
}
int gov_opp_snap(const GovProfile* p, int khz) {
	if (p->n_opps <= 0) return khz;
	int best = p->opps[0];
	for (int i = 1; i < p->n_opps; i++) {
		int d_best = best > khz ? best - khz : khz - best;
		int d_this = p->opps[i] > khz ? p->opps[i] - khz : khz - p->opps[i];
		if (d_this < d_best || (d_this == d_best && p->opps[i] > best)) best = p->opps[i];
	}
	return best;
}

// ---- predictive sink gate (pure; see governor.h) ----
#define GOV_SINK_MARGIN_PCT 85 // sink only if predicted p95 fits this % of the frame budget

int gov_sink_target(const GovState* st, const GovProfile* p) {
	int next = gov_opp_below(p, st->ceil_khz);
	if (next < p->f_min) next = p->f_min;
	return next;
}

int gov_sink_fits(int cur_khz, int next_khz, int p95_pure_us, int budget_us) {
	if (next_khz <= 0 || cur_khz <= 0 || budget_us <= 0) return 0;
	if (next_khz >= cur_khz) return 1;               // not actually sinking
	if (p95_pure_us <= 0) return 1;                  // no work data -> don't block (fps signal still guards)
	// predicted post-sink p95: work scales ~ inversely with clock (CPU-bound frame)
	long long predicted = (long long)p95_pure_us * cur_khz / next_khz;
	return predicted < (long long)budget_us * GOV_SINK_MARGIN_PCT / 100;
}

static int gov_disabled(void) {
	// Safety hatch: GOV_DISABLE=1 leaves the static menu clock in charge.
	static int disabled = -1;
	if (disabled < 0) {
		const char* e = getenv("GOV_DISABLE");
		disabled = (e && e[0] && e[0] != '0') ? 1 : 0;
	}
	return disabled;
}

void gov_burst(GovState* st, const GovProfile* p) {
	// A video-mode/geometry switch announces a scene change BEFORE its cost arrives —
	// provision for the worst immediately and let the sink ladder re-find the floor.
	// The reverse order (wait for the slip) is audible: BR2 title->demo / VS-card
	// transitions crunched for the 1-2 ticks the climb took (2026-07-09).
	if (gov_disabled()) return;
	st->ceil_khz = p->f_max;
	st->slip_run = 0;
	st->slack_run = 0;
	st->fail_khz = 0;
	st->fail_hold = 0;
	st->fail_streak = 0;
	st->presink_khz = 0;
	st->audible_khz = 0;
	st->since_sink = 255; // not a probe: a slip here must not "undo" to a stale ceiling
	PLAT_setCPUMaxFreq(st->ceil_khz);
}

void gov_tick(GovState* st, const GovProfile* p, int frame_overrun) {
	if (gov_disabled()) return;

	int temp_c = gov_read_temp_c();
	static int last_ceil = 0;
	int ceil_khz = gov_step(st, p, temp_c, frame_overrun);
	// Re-assert the ceiling every tick: keeps the controller authoritative over the static
	// CPU-speed cap and over whatever the menu restores. ~once/0.5s, negligible cost.
	// Voltage ordering lives in the platform ceiling choke point (uv_ceilingWrite) so that
	// EVERY ceiling writer gets it, not just the governor (audit fix: the menu-exit path).
	PLAT_setCPUMaxFreq(ceil_khz);
	(void)last_ceil; last_ceil = ceil_khz;
}
