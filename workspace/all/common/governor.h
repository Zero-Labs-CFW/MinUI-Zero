// governor.h — closed-loop thermal/perf CPU governor for minarch (hybrid model).
//
// The frame-aware controller chooses an allowed CPU-frequency *ceiling* and the kernel
// `schedutil` governor picks the instantaneous frequency beneath it. So the controller
// answers "what is the lowest ceiling at which this game still holds correct frames?",
// and schedutil drops below that during lighter moments — cooler than pinning a clock.
// See docs/thermal-governor-design.md + docs/project-direction.md §1.
//
// Two layers:
//   gov_step() — the pure controller. No I/O. Fully unit-testable with scripted
//                temp + frame-overrun traces (see governor_test.c).
//   gov_tick() — the device entry point. Reads temp, runs gov_step(), and writes the
//                ceiling via PLAT_setCPUMaxFreq() (scaling_max_freq under schedutil).

#ifndef GOVERNOR_H
#define GOVERNOR_H

// Run the controller once per this many frames (~0.5s @ 60fps). minarch counts frames.
#define GOV_TICK_FRAMES 30

// One real OPP step in kHz (MEASURED gaps 192-216MHz; shared with per-game governor memory)
// tg5040 OPP spacing. Overridable per platform (-DGOV_STEP_KHZ=...): miyoomini/SSD202D steps
// 400/600/800/1000 in 200 MHz, so a 216 MHz stride would skip real OPPs on the way down.
#ifndef GOV_STEP_KHZ
#define GOV_STEP_KHZ 216000
#endif

// Thermal thresholds are PER-SOC. These are die readings, and the two platforms simply do not
// report in the same range.
// NOTE: deliberately OUTSIDE the GOV_STEP_KHZ guard above — the miyoomini build passes
// -DGOV_STEP_KHZ on the command line, so anything nested in that #ifndef silently vanishes there.
#if defined(GOV_PLATFORM_MIYOOMINI)
// SSD202D. MEASURED on device 2026-07-25: normal SNES gameplay sits at 71-75 C, and the panel/
// charger add to it. With the tg5040 numbers below (ceil 72) the "always wins" thermal backstop
// fired on virtually every tick, sinking the ceiling REGARDLESS of the slip signal — the log shows
// sinks at temp=72 and the recovery climb at temp=71, i.e. the controller limit-cycled on the
// threshold itself: 1200 -> sink -> game craters to 30-50fps -> BIGSLIP -> 1200 -> sink...
// That was the SNES stutter; it was never the core and never the clock floor.
// Headroom check: Cortex-A7 junction limits are far above this, and OnionOS ships 1900MHz
// overclocks on this SoC with NO thermal management whatsoever — so 72 C is nowhere near a
// hazard here. 85 keeps a real backstop while leaving normal play alone.
#define GOV_T_TARGET_C 78      // start probing the clock down when at/below this
#define GOV_T_CEIL_C   85      // hard back-off above this — always wins
#else
// tg5040 / A133P: runs far cooler (39-48 C under load, measured).
#define GOV_T_TARGET_C 60      // start probing the clock down when at/below this
#define GOV_T_CEIL_C   72      // hard back-off above this — always wins
#endif

// Ticks of slack before sinking (sink slow = no hunting; the gov-memory accelerated
// ladder waives exactly this dwell, never the other gates)
#define GOV_DN_DWELL 4

// Per-system ceiling bracket, in kHz. The controller keeps the ceiling within [f_min,f_max].
// f_max must be a verified-stock OPP — never an overclock (no 2.0GHz on tg5040).
//
// opps[]/n_opps: the kernel's REAL frequency ladder (ascending kHz), read at runtime from
// scaling_available_frequencies. When present, every ceiling the controller commands is an
// actual OPP. Without it (n_opps==0) the legacy GOV_STEP_KHZ stride applies — which on the
// A133P walks OFF the ladder (1200-216=984 -> kernel silently runs 816), so the sink gate's
// predicted ratio (1200/984 = 1.22x) undersold the real jump (1200/816 = 1.47x) and probe
// steps in the first seconds bit ~20%% harder than designed. The kernel always snapped the
// WRITE; the fiction lived in ceil_khz and every prediction computed from it.
#define GOV_MAX_OPPS 16
typedef struct {
	int f_min;
	int f_max;
	int opps[GOV_MAX_OPPS];
	int n_opps;
} GovProfile;

// Ladder helpers (pure). With no table they fall back to the stride so existing behavior
// (and the miyoomini -DGOV_STEP_KHZ path) is unchanged.
int gov_opp_below(const GovProfile* p, int khz); // greatest table entry < khz (or khz-STEP)
int gov_opp_above(const GovProfile* p, int khz); // least table entry > khz (or khz+STEP)
int gov_opp_snap(const GovProfile* p, int khz);  // nearest table entry (ties go UP: louder-safe)

// Controller state for one game session. Reset via gov_init().
typedef struct {
	int ceil_khz;  // current commanded frequency ceiling (kHz) -> scaling_max_freq
	int slip_run;  // consecutive ticks of frame overrun (slip)
	int slack_run; // consecutive ticks of frame slack
	int fail_khz;  // highest ceiling that recently slipped — don't sink back to it while fail_hold>0
	int fail_hold; // ticks until we may re-probe at/below fail_khz (prevents 600<->816 limit cycling)
	int fail_streak; // consecutive re-probes that slipped again — escalates fail_hold (repeat offender)
	int presink_khz; // ceiling before the most recent sink — restored in one tick if the probe slips
	int since_sink;  // ticks since the most recent sink (saturates; small = a probe just happened)
	int probe_khz;   // the ceiling that sink set: what an audible slip bans (a SLIP's probe-undo moves ceil_khz)
	int audible_khz; // highest ceiling whose probe caused a BIGSLIP: never sunk to again until a scene
	                 // burst (gov_burst) or gov_init. Separate from fail_* so no later slip can shorten it.
} GovState;

// Named brackets from docs/thermal-governor-design.md (ASSUMED — verify the OPP ladder and
// the verified-stock max on device; nothing breaks if wrong: scaling_max_freq snaps to the
// nearest OPP and the loop self-corrects).
extern const GovProfile GOV_P_8BIT;  // NES/GB/GBC/SMS/GG/PCE: schedutil under a 1008 MHz stock ceiling
extern const GovProfile GOV_P_16BIT; // SNES/Genesis/GBA/VB
extern const GovProfile GOV_P_PS1;   // PlayStation
// Safe default for an unconfigured system: ceiling starts at the stock max, sinks from there.
extern const GovProfile GOV_P_DEFAULT;

// Initialize state for a new game session: ceil_khz = p->f_max, counters zeroed.
// Does not write hardware (caller writes the initial ceiling, e.g. via PLAT_setCPUMaxFreq).
void gov_init(GovState* st, const GovProfile* p);

// Slip-signal values for gov_step's frame_overrun input.
#define GOV_SIGNAL_SLACK 0 // holding frame rate with headroom -> may sink
#define GOV_SIGNAL_SLIP  1 // NOT holding frame rate -> climb + remember the failed ceiling
#define GOV_SIGNAL_BUSY  2 // holding, but saturated (no idle headroom) -> hold, don't probe lower
#define GOV_SIGNAL_BIGSLIP 3 // >=10% under target -> jump straight to f_max (the audible case)

// Pure controller step. No I/O.
//   temp_c        : current temperature in Celsius, or <0 if unknown/unavailable.
//   frame_overrun : a GOV_SIGNAL_* value (legacy 0/1 remain valid: slack/slip).
// Returns the next commanded ceiling (kHz) and updates *st. Clamped to [p->f_min, p->f_max];
// the thermal ceiling always wins.
int gov_step(GovState* st, const GovProfile* p, int temp_c, int frame_overrun);

// Predictive sink gate (pure, unit-tested). Where the controller would sink next
// (one OPP step below the current ceiling, clamped to f_min); and whether the workload
// would still fit there: frame work scales ~ inversely with clock, so predicted p95 at
// the lower clock is p95_us * cur/next. Fits = predicted < budget * 85% — the 15% idle
// headroom is the quantitative form of D14's race-to-idle rule (never sink into saturation).
// Callers feed PURE work p95 (audio-pacing wait excluded) or the gate over-holds.
int gov_sink_target(const GovState* st, const GovProfile* p);
int gov_sink_fits(int cur_khz, int next_khz, int p95_pure_us, int budget_us);

// Device entry point: read temp, run gov_step(), and write the ceiling via
// PLAT_setCPUMaxFreq(). Honors GOV_DISABLE=1 (no-op). Call once per GOV_TICK_FRAMES.
void gov_tick(GovState* st, const GovProfile* p, int frame_overrun);

// Scene-change burst: a video-mode/geometry switch announces new workload before its cost
// arrives — jump the ceiling to f_max now, let the sink ladder re-find the floor after.
void gov_burst(GovState* st, const GovProfile* p);

// Audio low-water: the frontend calls this the frame the audio ring falls under GOV_RING_LOW_PCT. Treated as a deep slip
// at the current ceiling and climbs to f_max at once (writes it). Returns 1 if the ceiling moved.
#define GOV_RING_LOW_PCT 20 // below the lowest healthy servo level measured (31%), ~27 ms of an 8-frame ring left
int gov_audio_low(GovState* st, const GovProfile* p);

// Read the CPU thermal zone in Celsius, or -1 if unavailable. Exposed for logging/tests.
int gov_read_temp_c(void);
int gov_read_cur_khz(void); // live scaling_cur_freq in kHz (-1 if unreadable)

#endif // GOVERNOR_H
