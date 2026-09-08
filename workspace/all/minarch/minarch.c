#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <signal.h>
#include <msettings.h>

#include <unistd.h>
#include <fcntl.h>
#include <dlfcn.h>
#include <libgen.h>
#include <time.h>
#include <math.h>
#include <sys/stat.h>
#include <errno.h>
#include <zlib.h>
#include <pthread.h>
#include <stdatomic.h>

#include "libretro.h"
#include "defines.h"
#include "api.h"
#include "utils.h"
#include "save_io.h"
#include "scaler.h"
#include "governor.h"
#include "gov_memory.h"
#include "dupskip.h"
#include "audioservo.h"
#include "telemetry.h"
#include "ff_visual_cadence.h"

#ifdef ZERO_FRONTEND_THREADING_V2
// ============================================================================
// Threading v2 candidate (docs/threading-v2-design.md): one CORE thread owns every
// libretro call from callback registration through teardown. MAIN owns input, menus,
// SDL/GLES presentation, and lifecycle. PS.pak requests the depth-2 pipeline; systems
// without ZERO_FTV2_DEPTH use the unchanged plain serial path and never initialize it.
// ============================================================================
#include "frontend_core.h" // pulls framering.h
#include "frame_pool.h"

// v2 engine handle + running flag declared HERE (early) because video_refresh_callback —
// far above main() — references them for the frame divert. The rest of the engine
// wiring (vtable, stubs, drain cb) lives in the block just before main() where core/game/
// State_* are in scope.
static fc zero_ftv2;          // engine handle (MAIN-side); ring/state live inside it
static _Atomic int zero_ftv2_running; // published after fc_boot_finish; read by CORE/signal paths
static int zero_ftv2_inited;  // fc_init succeeded far enough to own a CORE thread
static void zero_ftv2_drain(void* ctx, const fr_event* ev);

// WP-A depth-2 input. MAIN runs the input tick before the grant and packs the button/
// analog snapshot; the CORE thread reads it from `zero_ftv2_isnap` (its per-epoch immutable copy,
// set in zero_ftv2_run) instead of the live globals racing MAIN.
static int zero_ftv2_depth2 = 0; // immutable after bootstrap publication
static __thread uint64_t zero_ftv2_isnap[4] = {0};
// Crash canary (depth-2 auto-fallback): armed on the way into a depth-2 session, cleared at every
// known-good point — clean exit, and the parked sleep/poweroff autosave (Menu_beforeSleep is the
// choke point for BOTH; re-armed on wake). One failed depth-2 attempt gets one clean serial
// fallback before retrying. A second consecutive depth-2 failure disables it for this game and
// build; a new build retries automatically. Self-healing, no UI, no user action.
#define ZERO_FTV2_CRASH_LIMIT 2
static char zero_ftv2_canary[MAX_PATH];
static char zero_ftv2_failures[MAX_PATH];
static int  zero_ftv2_canary_armed = 0;
static int  zero_ftv2_canary_clearable = 1;

// WP-B: the depth-2 frame pool. The CORE thread copies each produced frame into a free
// buffer and rides its index in the FRAME payload; MAIN presents from it (present_frame) and
// the D-a2 retirement hook (zero_pool_retire) frees it. Size = depth + spill (D-j2): more
// than `depth` so a multi-video_refresh epoch has headroom; exhaustion DROPS the frame
// (never blocks the core). CORE is the sole acquirer (no acquire/acquire race); MAIN only
// retires. Buffers grow-only (realloc); freed at process exit.
#define ZERO_FTV2_POOL (FR_MAX_DEPTH + 2)
static frame_pool_buffer zero_pool_buffers[ZERO_FTV2_POOL];
static frame_pool zero_pool = { zero_pool_buffers, ZERO_FTV2_POOL, realloc };
static _Atomic int zero_ftv2_fatal;

static int zero_pool_acquire(unsigned w, unsigned h, size_t pitch) {
	int rc = frame_pool_acquire(&zero_pool, w, h, pitch);
	if (rc == FRAME_POOL_OOM)
		atomic_store_explicit(&zero_ftv2_fatal, 1, memory_order_release);
	return rc;
}
static void zero_pool_retire(void* ctx, uint64_t payload) {  // MAIN, via the D-a2 hook
	(void)ctx;
	frame_pool_retire(&zero_pool, (size_t)payload);
}

// Pure CORE work per credit slot. CORE publishes before RUN_DONE; MAIN reads that slot from
// the RUN_DONE callback before framering returns its credit, so it cannot be overwritten.
static _Atomic uint32_t zero_ftv2_work_us[FR_MAX_DEPTH];
// Depth-2 generation telemetry (Codex #5): epochs completed, counted on MAIN from non-cancelled
// FR_EV_RUN_DONE events in the drain — the TRUE generation rate (duped frames count; a 30fps-
// internal game generating 60 epochs/s reads 60, not 30). Replaces the old cross-thread
// fps_ticks read at depth-2 (CORE-incremented, MAIN-reset = data race + wrong semantics).
static uint32_t zero_ftv2_gen_ticks = 0;   // MAIN-only: read+reset by trackFPS
// Per-epoch FF snapshot (Codex #6): CORE-side callbacks must not read the live `fast_forward`
// global MAIN mutates — zero_ftv2_run stores this epoch's snap[3] here (CORE TLS).
static __thread int zero_ftv2_ff_snap = 0;
static __thread int zero_ftv2_emit_visual = 1;
// Ordered CORE->MAIN state commands (Codex #3): SET_GEOMETRY / SET_SYSTEM_AV_INFO arrive on the
// CORE thread mid-epoch; writing core.aspect_ratio/core.fps/renderer.dst_p there races MAIN's
// present. Route them through FR_EV_CMD (never dropped, applied by the drain on MAIN in global
// order against frames). Payload: op in the top byte, an IEEE-754 float's bits in the low 32.
#define ZERO_CMD_ASPECT 1
#define ZERO_CMD_FPS    2
#define ZERO_CMD_SRATE  3
#define ZERO_CMD_RUMBLE 4
static uint64_t zero_cmd_pack(int op, float v) {
	uint32_t bits; memcpy(&bits, &v, 4);
	return ((uint64_t)op << 56) | bits;
}
// Durable canary write (Codex #11): putFile ignores failures and never syncs — a full card or
// instant power cut could leave no marker and the next launch would wrongly retry depth-2.
// Only report armed on a synced, complete write.
static int zero_ftv2_sync_parent(const char* path) {
	char parent[MAX_PATH];
	if (snprintf(parent, sizeof(parent), "%s", path) >= (int)sizeof(parent)) return -1;
	char* slash = strrchr(parent, '/');
	if (!slash) return -1;
	*slash = '\0';
	int fd = open(parent, O_RDONLY|O_DIRECTORY|O_CLOEXEC);
	if (fd < 0) return -1;
	int rc = fsync(fd);
	close(fd);
	return rc;
}
static int zero_ftv2_canary_write(const char* path, const char* state) {
	return save_write_atomic(path, state, strlen(state));
}
static int zero_ftv2_canary_state(const char* path) {
	char buf[16] = {0};
	int fd = open(path, O_RDONLY|O_CLOEXEC);
	if (fd < 0) return 0;
	ssize_t n = read(fd, buf, sizeof(buf)-1);
	close(fd);
	if (n >= 6 && !memcmp(buf, "serial", 6)) return 2;
	return 1; // legacy "armed" and malformed markers are conservatively depth-2 failures
}
static int zero_ftv2_canary_remove(const char* path) {
	if (unlink(path)) return errno == ENOENT ? 0 : -1;
	return zero_ftv2_sync_parent(path);
}
static int zero_ftv2_failures_read(const char* path) {
	char buf[128] = {0}, build[96] = {0};
	int count = 0;
	int fd = open(path, O_RDONLY|O_CLOEXEC);
	if (fd < 0) return 0;
	ssize_t n = read(fd, buf, sizeof(buf)-1);
	close(fd);
	if (n <= 0 || sscanf(buf, "%95s %d", build, &count) != 2) return 0;
	if (strcmp(build, BUILD_HASH) || count < 0 || count > ZERO_FTV2_CRASH_LIMIT) return 0;
	return count;
}
static int zero_ftv2_failures_write(const char* path, int count) {
	char buf[128];
	int n = snprintf(buf, sizeof(buf), "%s %d\n", BUILD_HASH, count);
	if (n < 0 || n >= (int)sizeof(buf)) return -1;
	return save_write_atomic(path, buf, (size_t)n);
}
static void zero_ftv2_failures_clear(void) {
	if (zero_ftv2_failures[0] && save_remove_file(zero_ftv2_failures))
		LOG_error("threading v2: cannot clear crash count (%s)\n", strerror(errno));
}
// D61 pacer: MAIN-side count of frames actually presented (bumped in zero_ftv2_drain). At
// depth-2 fc_pump is non-blocking, so the run loop uses the delta to decide whether to block
// for the CORE (no present this tick) or let the vsync flip self-pace (a frame WAS presented).
static uint64_t zero_ftv2_presented = 0;

// Build fingerprint as a real string literal (a comment never reaches the binary):
// `strings minarch.elf | grep threading-v2` distinguishes a guard-ON test build.
static const char zero_ftv2_fingerprint[] __attribute__((used)) =
	"threading-v2 depth-2 (CORE producer, credit-owned frame pool, MAIN presenter)";

// The filled vtable and drain integration are defined just before main(), after the
// core/game/State_*/Core_* functions they reference.
#endif // ZERO_FRONTEND_THREADING_V2

///////////////////////////////////////

static SDL_Surface* screen;
static _Atomic int quit = 0;
static int show_menu = 0;
static int simple_mode = 0;
static int thread_video = 0;
static int was_threaded = 0;
static int should_run_core = 1; // used by threaded video
// thread-aware governor telemetry: ring of recent core.run() durations (us), written by
// the core thread, read by the gov tick (p95, mirroring the single-thread sink gate).
// Racy by design: a torn read misjudges one sample in one window, self-corrects next tick.
#define CORE_WORK_RING 32
static volatile uint32_t core_work_ring[CORE_WORK_RING];
static volatile uint32_t core_work_n = 0;
static volatile int core_pace_ppm = 0; // DRC rate adjustment, honored by the core pacer
static int zero_static_rate_ppm = 0;   // non-zero when a static panel match owns the clocks


static pthread_t		core_pt;
static pthread_mutex_t	core_mx;
static pthread_cond_t	core_rq; // not sure this is required
static SDL_Surface*	backbuffer = NULL;
static SDL_Surface*	readybuffer = NULL;   // mailbox: latest complete frame from the core
static SDL_Surface*	presentbuffer = NULL; // owned by the main thread while presenting
static int frame_ready = 0;
// threaded-DRC sensor: mailbox pressure. waits = main found no frame (core below panel
// rate -> nudge ppm up); overwrites = core replaced an unconsumed frame (core above panel
// rate -> nudge down). Plain ints, single-writer each, read at tick cadence.
static volatile int mb_waits = 0;
static volatile int mb_overwrites = 0;
static volatile int mb_waits_total = 0;      // never reset: HUD/stats read deltas
static volatile int mb_overwrites_total = 0;
// REAL smoothness events (the waits counter reads ~1/frame in healthy operation — main
// normally waits for each next frame — so it is NOT a dup signal; learned the hard way):
static volatile int mb_dups = 0;        // flip interval spanned 2+ vsync periods
static volatile int mb_dups_total = 0;
static volatile int mb_flips_total = 0; // every threaded present (panel-lock rate sensor)
static pthread_cond_t core_pause_cv = PTHREAD_COND_INITIALIZER; // pause/exit handshake (separate from the frame signal)
static volatile int core_thread_exit = 0;
static volatile int core_parked = 0; // set by the core thread while waiting in the pause cv
static int core_thread_alive = 0;    // guards join: FF auto-disable already joined the thread

// AUTO-THREADING: measure, decide, remember — same philosophy as the governor, no menu.
// Launch single-threaded; if the settled ceiling shows the game fighting for headroom,
// trial threading and keep it only if the ceiling verifiably sinks. Verdict persists in
// a sidecar (game cfgs get rewritten by the options menu; a sidecar survives).
static int thread_auto = 1;      // 0 when the user set minarch_thread_video explicitly (unlocked cfg line)
static int game_running = 0;     // set after bootstrap: gates runtime thread toggles (config load must not arm them)
static int ta_phase = 0;         // 0 observing single-thread, 1 trialing threaded, 2 decided
static int ta_decided_by_user = 0;
static uint32_t ta_phase_at = 0;
static int ta_base_ceil = 0;
#define TA_OBSERVE_MS 60000
#define TA_TRIAL_MS 60000
#define TA_TRIAL_THRESHOLD_KHZ 1008000

static void* coreThread(void *arg);

enum {
	SCALE_NATIVE,
	SCALE_ASPECT,
	SCALE_FULLSCREEN,
	SCALE_CROPPED,
	SCALE_COUNT,
};

// default frontend options
static int screen_scaling = SCALE_ASPECT;
static int screen_sharpness = SHARPNESS_SOFT;
static int screen_effect = EFFECT_NONE;
static int prevent_tearing = 1; // lenient
static int show_debug = 0;
static int dup_force_present = 0; // menu exit / sleep resume repaint identical bytes on purpose
static unsigned present_dirty_gen = 1; // any frontend option change invalidates "identical is invisible"
static int max_ff_speed = 6; // 4x (index into max_ff_labels/max_ff_mults — fractional speeds occupy 1-3)
static int fast_forward = 0;
static int ff_audio = 1; // FF-with-sound: feed sped-up audio during fast-forward (see audio callbacks)
static int presentation_drop_supported = 0;
static int drc_system_allowed = 0;
static int overclock = 1; // normal
static int has_custom_controllers = 0;
static int gamepad_type = 0; // index in gamepad_labels/gamepad_values
static int downsample = 0; // set to 1 to convert from 8888 to 565

// these are no longer constants as of the RG CubeXX (even though they look like it)
static int DEVICE_WIDTH = 0; // FIXED_WIDTH;
static int DEVICE_HEIGHT = 0; // FIXED_HEIGHT;
static int DEVICE_PITCH = 0; // FIXED_PITCH;

GFX_Renderer renderer;

///////////////////////////////////////

static struct Core {
	int initialized;
	int need_fullpath;
	
	const char tag[8]; // eg. GBC
	const char name[128]; // eg. gambatte
	const char version[128]; // eg. Gambatte (v0.5.0-netlink 7e02df6)
	const char extensions[128]; // eg. gb|gbc|dmg
	
	const char config_dir[MAX_PATH]; // eg. /mnt/sdcard/.userdata/rg35xx/GB-gambatte
	const char states_dir[MAX_PATH]; // eg. /mnt/sdcard/.userdata/arm-480/GB-gambatte
	const char saves_dir[MAX_PATH]; // eg. /mnt/sdcard/Saves/GB
	const char bios_dir[MAX_PATH]; // eg. /mnt/sdcard/Bios/GB
	
	double fps;
	double sample_rate;
	double aspect_ratio;
	
	void* handle;
	void (*init)(void);
	void (*deinit)(void);
	
	void (*get_system_info)(struct retro_system_info *info);
	void (*get_system_av_info)(struct retro_system_av_info *info);
	void (*set_controller_port_device)(unsigned port, unsigned device);
	void (*set_environment_callback)(retro_environment_t);
	void (*set_video_refresh_callback)(retro_video_refresh_t);
	void (*set_audio_sample_callback)(retro_audio_sample_t);
	void (*set_audio_sample_batch_callback)(retro_audio_sample_batch_t);
	void (*set_input_poll_callback)(retro_input_poll_t);
	void (*set_input_state_callback)(retro_input_state_t);
	
	void (*reset)(void);
	void (*run)(void);
	size_t (*serialize_size)(void);
	bool (*serialize)(void *data, size_t size);
	bool (*unserialize)(const void *data, size_t size);
	bool (*load_game)(const struct retro_game_info *game);
	bool (*load_game_special)(unsigned game_type, const struct retro_game_info *info, size_t num_info);
	void (*unload_game)(void);
	unsigned (*get_region)(void);
	void *(*get_memory_data)(unsigned id);
	size_t (*get_memory_size)(unsigned id);
	
	// retro_audio_buffer_status_callback_t audio_buffer_status;
} core;

// Parse an integer env var STRICTLY. Returns 0 and leaves *out untouched unless the whole string
// is a valid number in range. atoi() was the previous form and is unusable here: it maps "banana"
// to 0, which silently CANCELLED a good panel-derived correction, and its behaviour on out-of-range
// input is undefined so a later clamp cannot be trusted (adversarial review, 2026-08-01).
static int zero_envInt(const char* name, long lo, long hi, long* out) {
	const char* v = getenv(name);
	if (!v || !*v) return 0;
	errno = 0;
	char* end = NULL;
	long n = strtol(v, &end, 10);
	if (errno == ERANGE || end == v || (end && *end)) {
		LOG_info("%s: ignoring malformed value \"%s\"\n", name, v);
		return 0;
	}
	if (n < lo || n > hi) {
		LOG_info("%s: ignoring out-of-range value %ld (allowed %ld..%ld)\n", name, n, lo, hi);
		return 0;
	}
	*out = n;
	return 1;
}

// Apply (or clear) the static panel rate match for the CURRENT core.fps.
//
// Idempotent and re-entrant by design: cores change timing at runtime (SET_SYSTEM_AV_INFO on a
// region switch), and a correction derived for 60.0988fps is badly wrong for 50fps content. The
// previous version computed once at startup and never revisited, so an NTSC->PAL switch kept
// -12609ppm (running PAL at ~49.4fps) and PAL->NTSC left no correction at all under Strict.
//
// MAIN THREAD ONLY. Under threading v2 the environment callback runs on CORE; call this from the
// ordered-command drain on MAIN instead, after every timing field has been published.
static void Zero_applyRateMatch(void) {
	int ppm = 0;

	// Automatic path: declare the PANEL rate, derive the per-core correction. The same panel needs
	// a different correction for every system (NES 60.0988 vs GBC 59.7275 differ by ~6000ppm), so a
	// single shared ppm would be wrong for all but one.
	const char* hz = getenv("MINARCH_PANEL_FPS");
	if (hz && *hz && core.fps > 1.0) {
		double panel = atof(hz);
		// GATE BOTH SIDES. This corrects a ~60Hz core to a nearby ~60Hz panel and must never
		// touch anything else:
		//  * PAL/50Hz content would compute +186000ppm and run 5%% FAST. Reachable in cores we ship
		//    (fceumm, picodrive, snes9x2005_plus, pcsx_rearmed all report PAL timing).
		//  * an absurd panel value must not be "corrected" into a clamp. MINARCH_PANEL_FPS=30 with
		//    a 60fps core used to clamp to -50000ppm and target 57fps while the panel actually
		//    delivered 30 — the resampler compensated 5%% against a 50%% shortfall and underran
		//    continuously. Requiring the panel within a few %% of the core makes the clamp
		//    unreachable from this path.
		// Below-core band is 5%% (MMP: panel 59.672 under GBC 59.7275 — audio deficit repaid by
		// slowing the core). Above-core band is a tight 1%%: the h700 panel (59.978 measured) sits
		// 0.42%% ABOVE the GBC core, and under Strict the pan-blocked loop stepped the core 0.42%%
		// fast with nothing pacing the surplus — the ring filled, the producer blocked, and one
		// vblank slipped every ~4s (a visible judder beat, RG35XX Plus 2026-08-05). Matching the
		// core up to the panel locks the cadence; +1%% is inaudible in pitch (<17 cents) while
		// keeping PAL and typo'd panels unreachable.
		int core_ok  = (core.fps >= 58.0 && core.fps <= 61.0);
		int panel_ok = (panel > 1.0 && panel >= core.fps * 0.95 && panel <= core.fps * 1.01);
		if (core_ok && panel_ok)
			ppm = (int)lround((panel / core.fps - 1.0) * 1000000.0);
		else if (panel > 1.0)
			LOG_info("rate match: skipped (core %.4f fps, panel %.3f — needs 58-61fps core and a panel within 5%% below / 1%% above)\n",
			         core.fps, panel);
	}

	// Explicit override for deliberate experiments. Deliberately NOT fps-gated — but it IS
	// validated, which is what makes it safe: the hazard was never that a developer could ask for
	// something unwise, it was that a typo silently became 0 and cancelled a good correction.
	long explicit_ppm = 0;
	if (zero_envInt("MINARCH_RATE_PPM", -50000, 50000, &explicit_ppm)) {
		ppm = (int)explicit_ppm;
		if (core.fps < 58.0 || core.fps > 61.0)
			LOG_warn("MINARCH_RATE_PPM applied to %.4f fps content — outside the 58-61 window this feature is designed for\n",
			         core.fps);
	}

	if (ppm == zero_static_rate_ppm) return; // nothing changed; do not disturb the clocks

	zero_static_rate_ppm = ppm; // publish BEFORE writing clocks: DRC reads this to stand down
	if (ppm) {
		double target_fps = core.fps * (1.0 + ppm / 1000000.0);
		SND_setRateAdjustPPM(ppm);
		core_pace_ppm = ppm;
		GFX_setPacePeriodUs((uint32_t)(1000000.0 / target_fps));
		LOG_info("rate match: %+dppm -> %.3f fps target (core %.4f)\n", ppm, target_fps, core.fps);
	}
	else { // correction no longer applies (e.g. switched to PAL) — hand the clocks back to stock
		SND_setRateAdjustPPM(0);
		core_pace_ppm = 0;
		GFX_setPacePeriodUs(0);
		LOG_info("rate match: cleared (core %.4f fps)\n", core.fps);
	}
}


static void Core_flushMemory(void);
static void Core_setController(unsigned device);
static int zero_ftv2_core_enter(void);
static void zero_ftv2_core_leave(int parked);

///////////////////////////////////////
// based on picoarch/unzip.c

#define ZIP_HEADER_SIZE 30
#define ZIP_CHUNK_SIZE 65536
#define ZIP_LE_READ16(buf) ((uint16_t)(((uint8_t *)(buf))[1] << 8 | ((uint8_t *)(buf))[0]))
#define ZIP_LE_READ32(buf) ((uint32_t)(((uint8_t *)(buf))[3] << 24 | ((uint8_t *)(buf))[2] << 16 | ((uint8_t *)(buf))[1] << 8 | ((uint8_t *)(buf))[0]))
typedef int (*Zip_extract_t)(FILE* zip, FILE* dst, size_t size);

static int Zip_copy(FILE* zip, FILE* dst, size_t size) { // uncompressed?
	uint8_t buffer[ZIP_CHUNK_SIZE];
	while (size) {
		size_t sz = MIN(size, ZIP_CHUNK_SIZE);
		if (sz!= fread(buffer, 1, sz, zip)) return -1;
		if (sz!=fwrite(buffer, 1, sz, dst)) return -1;
		size -= sz;
	}
	return 0;
}
static int Zip_inflate(FILE* zip, FILE* dst, size_t size) { // compressed
	z_stream stream = {0};
	size_t have = 0;
	uint8_t  in[ZIP_CHUNK_SIZE];
	uint8_t out[ZIP_CHUNK_SIZE];
	int ret = -1;

	ret = inflateInit2(&stream, -MAX_WBITS);
	if (ret != Z_OK)
		return ret;
	
	do {
		size_t insize = MIN(size, ZIP_CHUNK_SIZE);

		stream.avail_in = fread(in, 1, insize, zip);
		if (ferror(zip)) {
			(void)inflateEnd(&stream);
			return Z_ERRNO;
		}

		if (!stream.avail_in)
			break;
		stream.next_in = in;

		do {
			stream.avail_out = ZIP_CHUNK_SIZE;
			stream.next_out = out;

			ret = inflate(&stream, Z_NO_FLUSH);
			switch(ret) {
				case Z_NEED_DICT:
					ret = Z_DATA_ERROR;
				case Z_DATA_ERROR:
				case Z_MEM_ERROR:
					(void)inflateEnd(&stream);
					return ret;
			}

			have = ZIP_CHUNK_SIZE - stream.avail_out;
			if (fwrite(out, 1, have, dst) != have || ferror(dst)) {
				(void)inflateEnd(&stream);
				return Z_ERRNO;
			}
		} while (stream.avail_out == 0);

		size -= insize;
	} while (size && ret != Z_STREAM_END);

	(void)inflateEnd(&stream);

	if (!size || ret == Z_STREAM_END) {
		return Z_OK;
	} else {
		return Z_DATA_ERROR;
	}
}

///////////////////////////////////////

static struct Game {
	char path[MAX_PATH];
	char name[MAX_PATH]; // TODO: rename to basename?
	char m3u_path[MAX_PATH];
	char tmp_path[MAX_PATH]; // location of unzipped file
	void* data;
	size_t size;
	int is_open;
} game;

// park the core thread before anything touches core state (savestates, SRAM, disc,
// autosave). Bounded but generous; parking normally completes within one frame.
static int park_core(const char* why) {
	if (!thread_video) return 1;
	pthread_mutex_lock(&core_mx);
	should_run_core = 0;
	pthread_mutex_unlock(&core_mx);
	for (int w=0; w<500 && !core_parked; w++) usleep(1000);
	if (!core_parked) LOG_info("park_core TIMEOUT (%s) — proceeding is unsafe\n", why);
	return core_parked;
}
static void ta_sidecar_path(char* out) {
	sprintf(out, "%s/%s.thread", core.config_dir, game.name);
}
static int ta_read_verdict(void) { // -1 none, 0 no-benefit, 1 threaded
	char path[MAX_PATH];
	ta_sidecar_path(path);
	FILE* f = fopen(path, "r");
	if (!f) return -1;
	int v = fgetc(f) == '1' ? 1 : 0;
	fclose(f);
	return v;
}
static void ta_write_verdict(int v) {
	char path[MAX_PATH];
	ta_sidecar_path(path);
	putFile(path, v ? "1" : "0");
	LOG_info("auto-thread: verdict %s persisted\n", v ? "THREADED" : "single");
}

// ---- per-game governor memory: every session re-converges from f_max, spending the
// hottest minute of play re-learning a floor the last session already proved. Remember
// each game's settled ceiling (the time-dominant one, not the exit snapshot) in a .gov
// sidecar beside the .thread verdict, and start the next session one OPP step above it.
// Safety is the existing machinery: BIGSLIP jumps to f_max within ~1s if the memory is
// stale, and scene-change bursts are unaffected. ZERO_NO_GOV_MEMORY disables.
// The policy itself (arm / accelerated ladder / vote attribution) lives in the PURE
// gov_memory unit with its own host matrix (review round 4). minarch owns only the
// sidecar file I/O, env gating, burst-site policy, and logging.
static GovMemState gov_mem;
static unsigned rate_seq = 0; // bumped by trackFPS each time cpu_double refreshes
static void gov_mem_path(char* out) {
	sprintf(out, "%s/%s.gov", core.config_dir, game.name);
}
static int gov_mem_read(void) {
	char path[MAX_PATH];
	gov_mem_path(path);
	return exists(path) ? getInt(path) : 0;
}
static void gov_mem_save(void) {
	int best = govmem_best(&gov_mem, 60); // 60 qualified ~1Hz votes = ~60-90s of clean play (votes are per rate publication, not per tick)
	if (best <= 0) return;
	if (best == gov_mem_read()) return;   // unchanged: spare the card write
	char path[MAX_PATH];
	gov_mem_path(path);
	char val[16];
	sprintf(val, "%d", best);
	putFile(path, val);
	LOG_info("gov-memory: settled ceiling %d kHz persisted\n", best);
}
// (gov_scene_burst is defined after Gov_start: it needs gov_state/gov_profile)
static int Game_findM3U(const char* path, char* out, size_t out_size) {
	char dir[MAX_PATH];
	if (snprintf(dir, sizeof(dir), "%s", path) >= (int)sizeof(dir)) return 0;
	char* slash = strrchr(dir, '/');
	if (!slash) return 0;
	*slash = '\0';
	const char* dirname = strrchr(dir, '/');
	dirname = dirname ? dirname + 1 : dir;
	int n = snprintf(out, out_size, "%s/%s.m3u", dir, dirname);
	return n > 0 && (size_t)n < out_size && exists(out);
}
static void Game_getIdentity(const char* path, char* out, size_t out_size) {
	const char* name = strrchr(path, '/');
	name = name ? name + 1 : path;
	snprintf(out, out_size, "%s", name);
	char m3u[MAX_PATH];
	if (Game_findM3U(path, m3u, sizeof(m3u))) {
		name = strrchr(m3u, '/');
		snprintf(out, out_size, "%s", name ? name + 1 : m3u);
	}
}
static uint64_t Game_identityHash(const char* path) {
	char m3u[MAX_PATH];
	const char* identity = Game_findM3U(path, m3u, sizeof(m3u)) ? m3u : path;
	if (!strncmp(identity, SDCARD_PATH, strlen(SDCARD_PATH))) identity += strlen(SDCARD_PATH);
	uint64_t hash = UINT64_C(14695981039346656037);
	for (const unsigned char* p = (const unsigned char*)identity; *p; p++) {
		hash ^= *p;
		hash *= UINT64_C(1099511628211);
	}
	return hash;
}
static void Game_open(char* path) {
	LOG_info("Game_open\n");
	memset(&game, 0, sizeof(game));
	
	strcpy((char*)game.path, path);
	Game_getIdentity(path, (char*)game.name, sizeof(game.name));
	
	// if we have a zip file
	if (suffixMatch(".zip", game.path)) {
		LOG_info("is zip file\n");
		int supports_zip = 0;
		int i = 0;
		char* ext;
		char exts[128];
		char* extensions[32];
		strcpy(exts,core.extensions);
		while ((ext=strtok(i?NULL:exts,"|"))) {
			extensions[i++] = ext;
			if (!strcmp("zip", ext)) {
				supports_zip = 1;
				break;
			}
		}
		extensions[i] = NULL;
	
		// if the core doesn't support zip files natively
		if (!supports_zip) {
			FILE *zip = fopen(game.path, "r");
			if (zip==NULL) {
				LOG_error("Error opening archive: %s\n\t%s\n", game.path, strerror(errno));
				return;
			}
			
			// extract a known file format
			uint8_t header[ZIP_HEADER_SIZE];
			uint32_t next = 0;
			uint16_t len = 0;
			char filename[MAX_PATH];
			uint32_t compressed_size = 0;
			char extension[8];
			while (1) {
				if (next) fseek(zip, next, SEEK_CUR);
				
				if (ZIP_HEADER_SIZE!=fread(header, 1, ZIP_HEADER_SIZE, zip)) break;
				
				if ((uint16_t)(header[6]) & 0x0008) break;
				
				len = ZIP_LE_READ16(&header[26]);
				if (len>=MAX_PATH) break;
				
				if (len!=fread(filename,1,len,zip)) break;
				filename[len] = '\0';
				LOG_info("filename: %s\n", filename);
				
				compressed_size = ZIP_LE_READ32(&header[18]);
				
				fseek(zip, ZIP_LE_READ16(&header[28]), SEEK_CUR);
				next = compressed_size;
				
				int found = 0;
				for (i=0; extensions[i]; i++) {
					sprintf(extension, ".%s", extensions[i]);
					if (suffixMatch(extension, filename)) {
						
						found = 1;
						break;
					}
				}
				if (!found) continue;
				
				char tmp_template[MAX_PATH];
				strcpy(tmp_template, "/tmp/minarch-XXXXXX");
				char* tmp_dirname = mkdtemp(tmp_template);
				// LOG_info("tmp_dirname: %s\n", tmp_dirname);
				sprintf(game.tmp_path, "%s/%s", tmp_dirname, basename(filename));
				
				// TODO: we need to clear game.tmp_path if anything below this point fails!
				
				FILE* dst = fopen(game.tmp_path, "w");
				if (dst==NULL) {
					game.tmp_path[0] = '\0';
					LOG_error("Error extracting file: %s\n\t%s\n", filename, strerror(errno));
					return;
				}
				
				Zip_extract_t extract = NULL;
				switch (ZIP_LE_READ16(&header[8])) {
					case 0: extract = Zip_copy; break;
					case 8: extract = Zip_inflate; break;
				}
				
				if (!extract || extract(zip,dst,compressed_size)) {
					game.tmp_path[0] = '\0';
					LOG_error("Error extracting file: %s\n\t%s\n", filename, strerror(errno));
					return;
				}
				
				fclose(dst);
				
				break;
			}
			
			fclose(zip);
		}
	}
		
	// some cores handle opening files themselves, eg. pcsx_rearmed
	// if the frontend tries to load a 500MB file itself bad things happen
	if (!core.need_fullpath) {
		path = game.tmp_path[0]=='\0'?game.path:game.tmp_path;
		
		FILE *file = fopen(path, "r");
		if (file==NULL) {
			LOG_error("Error opening game: %s\n\t%s\n", path, strerror(errno));
			return;
		}
	
		fseek(file, 0, SEEK_END);
		game.size = ftell(file);
	
		rewind(file);
		game.data = malloc(game.size);
		if (game.data==NULL) {
			LOG_error("Couldn't allocate memory for file: %s\n", path);
			return;
		}
	
		fread(game.data, sizeof(uint8_t), game.size, file);
	
		fclose(file);
	}
	
	// m3u-based multi-disc identity (the same helper keys the pre-core crash canary).
	Game_findM3U(game.path, game.m3u_path, sizeof(game.m3u_path));
	
	game.is_open = 1;
}
static void Game_close(void) {
	if (game.data) free(game.data);
	if (game.tmp_path[0]) remove(game.tmp_path);
	game.is_open = 0;
	VIB_setStrength(0); // just in case
}

static struct retro_disk_control_ext_callback disk_control_ext;
static int Core_changeDisc(void);
static void Game_changeDisc(char* path) {
	
	if (exactMatch(game.path, path) || !exists(path)) return;
	int ftv2_parked = zero_ftv2_core_enter();
	char original_path[MAX_PATH];
	snprintf(original_path, sizeof(original_path), "%s", game.path);
	
	Game_close();
	Game_open(path);
	if (!game.is_open) {
		LOG_error("Could not open replacement disc: %s\n", path);
		Game_open(original_path);
		zero_ftv2_core_leave(ftv2_parked);
		return;
	}
	
	if (!Core_changeDisc())
		putFile(CHANGE_DISC_PATH, path); // MinUI still needs to know this to update recents.txt
	else {
		LOG_error("Core rejected disc change: %s\n", path);
		// replace_image_index failed, so CORE still owns the original disc. Restore MAIN's
		// file/data identity before releasing it; callers can detect failure from game.path.
		Game_close();
		Game_open(original_path);
	}
	zero_ftv2_core_leave(ftv2_parked);
}

///////////////////////////////////////

static void SRAM_getPath(char* filename) {
	sprintf(filename, "%s/%s.sav", core.saves_dir, game.name);
}
static void Memory_read(const char* filename, void* memory, size_t memory_size, const char* kind) {
	if (!memory) {
		LOG_error("Error getting %s data\n", kind);
		return;
	}

	void* staged = malloc(memory_size);
	if (!staged) {
		LOG_error("Couldn't allocate memory for %s data\n", kind);
		return;
	}

	size_t file_size = 0;
	if (save_read_file(filename, staged, memory_size, 1, &file_size)) {
		if (errno != ENOENT) LOG_error("Error reading %s data: %s\n", kind, strerror(errno));
		free(staged);
		return;
	}
	if (!file_size) {
		LOG_error("Empty %s file: %s\n", kind, filename);
		free(staged);
		return;
	}

	size_t copy_size = file_size < memory_size ? file_size : memory_size;
	memcpy(memory, staged, copy_size);
	if (file_size != memory_size) {
		LOG_warn("%s size mismatch: file=%zu core=%zu (%s)\n",
			kind, file_size, memory_size, filename);
	}
	free(staged);
}
static void SRAM_read(void) {
	size_t sram_size = core.get_memory_size(RETRO_MEMORY_SAVE_RAM);
	if (!sram_size) return;
	
	char filename[MAX_PATH];
	SRAM_getPath(filename);
	printf("sav path (read): %s\n", filename);
	
	void* sram = core.get_memory_data(RETRO_MEMORY_SAVE_RAM);
	Memory_read(filename, sram, sram_size, "SRAM");
}
static void SRAM_write(void) {
	size_t sram_size = core.get_memory_size(RETRO_MEMORY_SAVE_RAM);
	if (!sram_size) return;
	
	char filename[MAX_PATH];
	SRAM_getPath(filename);
	printf("sav path (write): %s\n", filename);
		
	void *sram = core.get_memory_data(RETRO_MEMORY_SAVE_RAM);
	if (!sram) {
		LOG_error("Error getting SRAM data\n");
		return;
	}

	if (save_write_atomic(filename, sram, sram_size)) {
		LOG_error("Error writing SRAM data: %s\n", strerror(errno));
	}
}

///////////////////////////////////////

static void RTC_getPath(char* filename) {
	sprintf(filename, "%s/%s.rtc", core.saves_dir, game.name);
}
static void RTC_read(void) {
	size_t rtc_size = core.get_memory_size(RETRO_MEMORY_RTC);
	if (!rtc_size) return;
	
	char filename[MAX_PATH];
	RTC_getPath(filename);
	printf("rtc path (read): %s\n", filename);
	
	void* rtc = core.get_memory_data(RETRO_MEMORY_RTC);
	Memory_read(filename, rtc, rtc_size, "RTC");
}
static void RTC_write(void) {
	size_t rtc_size = core.get_memory_size(RETRO_MEMORY_RTC);
	if (!rtc_size) return;
	
	char filename[MAX_PATH];
	RTC_getPath(filename);
	printf("rtc path (write) size(%u): %s\n", rtc_size, filename);
		
	void *rtc = core.get_memory_data(RETRO_MEMORY_RTC);
	if (!rtc) {
		LOG_error("Error getting RTC data\n");
		return;
	}

	if (save_write_atomic(filename, rtc, rtc_size)) {
		LOG_error("Error writing RTC data: %s\n", strerror(errno));
	}
}

///////////////////////////////////////

// Crash-safe saves (pillar 5): if the core segfaults, stock loses every bit of SRAM progress
// since the last flush (menu-open/sleep). Cache the SRAM/RTC pointers + paths once at load;
// on a fatal signal, emergency-write them using only async-signal-safe raw syscalls
// (open/write/fsync/rename), atomically via a .tmp so a mid-write death can never corrupt an
// existing good save. Then re-raise so the crash still crashes (exit code, launcher recovery).

static struct {
	void* data;
	size_t size;
	char path[MAX_PATH];
	char tmp[MAX_PATH+8];
} crash_save[2]; // [0]=SRAM [1]=RTC
static int crash_save_dir_fd = -1;

static int Crash_writeAll(int fd, const void* data, size_t size) {
	const unsigned char* in = data;
	size_t done = 0;
	while (done < size) {
		ssize_t wrote = write(fd, in + done, size - done);
		if (wrote > 0) done += (size_t)wrote;
		else if (wrote < 0 && errno == EINTR) continue;
		else return -1;
	}
	return 0;
}

// Async-signal-safe teardown for an orderly kill: release the audio device, restore the clock,
// then die with the default disposition so the exit status still reads as signalled.
static void Term_handler(int sig) {
	signal(SIGTERM, SIG_DFL); signal(SIGINT, SIG_DFL); // no recursion
	PLAT_resetAudio();
	PLAT_emergencyRestoreCPUVolt();
	raise(sig);
}

static void Crash_handler(int sig) {
	signal(SIGSEGV, SIG_DFL); signal(SIGBUS, SIG_DFL); signal(SIGILL, SIG_DFL);
	signal(SIGFPE, SIG_DFL); signal(SIGABRT, SIG_DFL); // no recursion
	// Release the audio device FIRST. On SigmaStar, MI_AO_SetPubAttr cannot reconfigure a codec
	// that is still enabled, and libmi_ao tracks enablement PER PROCESS — so a process that dies
	// without disabling leaves the device wedged with NO userspace way back. Every game launched
	// afterwards is silent until reboot (MEASURED across a reboot, 5 systems). Dying is the one
	// moment we must not skip this.
	PLAT_resetAudio();
#ifdef ZERO_FRONTEND_THREADING_V2
	// Codex #4: only the thread that OWNS core execution may emergency-save. At depth-2 a
	// MAIN-side fault (present path) can fire while CORE is mid-mutation of emulated memory —
	// writing the cached SRAM/RTC pointers then would atomically rename a TORN snapshot over
	// the last good save. Non-core faults restore volts and die; the on-disk save stays good.
	// fc_current_phase is CORE-TLS: NONE on MAIN, non-NONE while CORE owns libretro work.
		int ring_idle = fr_get_state(&zero_ftv2.fr) == FR_QUIESCENT
		             && !atomic_load_explicit(&zero_ftv2.fr.in_run, memory_order_relaxed)
		             && !atomic_load_explicit(&zero_ftv2.fr.release_req, memory_order_relaxed)
		             && !atomic_load_explicit(&zero_ftv2.fr.stop_req, memory_order_relaxed)
		             && atomic_load_explicit(&zero_ftv2.fr.svc_acked, memory_order_relaxed)
		                >= atomic_load_explicit(&zero_ftv2.fr.svc_requested, memory_order_relaxed);
		if (zero_ftv2_inited && zero_ftv2_depth2 && zero_ftv2_running
		 && fc_current_phase() == FCP_NONE && !ring_idle) {
		static const char skip[] = "minarch: fatal signal on non-core thread — skipping emergency save (torn-write guard)\n";
		write(STDERR_FILENO, skip, sizeof(skip)-1);
		PLAT_emergencyRestoreCPUVolt();
		raise(sig);
		return;
	}
#endif
	static const char msg[] = "minarch: fatal signal — emergency-saving SRAM/RTC\n";
	write(STDERR_FILENO, msg, sizeof(msg)-1);
	int renamed = 0;
	for (int i=0; i<2; i++) {
		if (!crash_save[i].data || !crash_save[i].size) continue;
		int fd = open(crash_save[i].tmp, O_WRONLY|O_CREAT|O_TRUNC, 0644);
		if (fd < 0) continue;
		int okay = !Crash_writeAll(fd, crash_save[i].data, crash_save[i].size);
		if (okay && fsync(fd)) okay = 0;
		if (close(fd)) okay = 0;
		if (okay && !rename(crash_save[i].tmp, crash_save[i].path)) renamed = 1;
		else unlink(crash_save[i].tmp);
	}
	if (renamed && crash_save_dir_fd >= 0) fsync(crash_save_dir_fd);
	// voltage authority: restore stock volts before dying. MUST be the lock-free emergency
	// variant — the normal restore takes uv_lock, which the hold thread owns ~20% of the
	// time; a mutex here could deadlock the dying process into a frozen zombie (audit fix).
	PLAT_emergencyRestoreCPUVolt();
	raise(sig);
}

static void Crash_install(void) { // call after core.load_game + SRAM_read (pointers are live)
	crash_save[0].size = core.get_memory_size(RETRO_MEMORY_SAVE_RAM);
	crash_save[0].data = crash_save[0].size ? core.get_memory_data(RETRO_MEMORY_SAVE_RAM) : NULL;
	SRAM_getPath(crash_save[0].path);
	crash_save[1].size = core.get_memory_size(RETRO_MEMORY_RTC);
	crash_save[1].data = crash_save[1].size ? core.get_memory_data(RETRO_MEMORY_RTC) : NULL;
	RTC_getPath(crash_save[1].path);
	for (int i=0; i<2; i++) {
		strcpy(crash_save[i].tmp, crash_save[i].path);
		strcat(crash_save[i].tmp, ".tmp");
	}
	crash_save_dir_fd = open(core.saves_dir, O_RDONLY|O_DIRECTORY|O_CLOEXEC);
	signal(SIGSEGV, Crash_handler);
	signal(SIGBUS,  Crash_handler);
	signal(SIGILL,  Crash_handler);
	signal(SIGFPE,  Crash_handler);
	signal(SIGABRT, Crash_handler);
	// SIGTERM/SIGINT previously had NO handler: a force-quit killed us outright, SND_quit never
	// ran, and the audio device stayed enabled — poisoning audio for every later game until
	// reboot. Same reasoning as the crash path above.
	signal(SIGTERM, Term_handler);
	signal(SIGINT,  Term_handler);
}
static void Crash_uninstall(void) {
	signal(SIGSEGV, SIG_DFL); signal(SIGBUS, SIG_DFL); signal(SIGILL, SIG_DFL);
	signal(SIGFPE, SIG_DFL); signal(SIGABRT, SIG_DFL);
	memset(crash_save, 0, sizeof(crash_save));
	if (crash_save_dir_fd >= 0) close(crash_save_dir_fd);
	crash_save_dir_fd = -1;
}

///////////////////////////////////////

static int state_slot = 0;
static void State_getPath(char* filename) {
	sprintf(filename, "%s/%s.st%i", core.states_dir, game.name, state_slot);
}
static int State_readDirect(void) { // from picoarch; caller guarantees CORE ownership
	size_t state_size = core.serialize_size();
	if (!state_size) return 0;
	int result = 0;

	void *state = calloc(1, state_size);
	if (!state) {
		LOG_error("Couldn't allocate memory for state\n");
		goto error;
	}

	char filename[MAX_PATH];
	State_getPath(filename);

	size_t file_size = 0;
	// allow_larger=1 (v1.4 final-review decision): cores with varying serialize_size() (mgba —
	// see the Wario Land 4 note) can report M < N after writing a state of size N; refusing the
	// load would make v1.4 reject a save v1.3.1 accepted (prefix-load was v1.3.1's de-facto
	// semantics for years, harmlessly). The buffer is state_size; the read is bounded either way.
	if (save_read_file(filename, state, state_size, 1, &file_size)) {
		// st8 is a default state in MiniUI and may not exist, that's okay.
		if (errno != ENOENT || state_slot!=8) {
			LOG_error("Error reading state file: %s (%s)\n", filename, strerror(errno));
		}
		goto error;
	}
	if (!file_size) {
		LOG_error("Empty state file: %s\n", filename);
		goto error;
	}

	// some cores report the wrong serialize size initially for some games, eg. mgba: Wario Land 4
	// so we allow a size mismatch as long as the actual size fits in the buffer we've allocated
	if (file_size != state_size) {
		LOG_warn("State size mismatch: file=%zu core=%zu (%s)\n",
			file_size, state_size, filename);
	}

	if (!core.unserialize(state, state_size)) {
		LOG_error("Error restoring save state: %s\n", filename);
		goto error;
	}
	result = 1;

error:
	if (state) free(state);
	return result;
}
static int State_writeDirect(void) { // from picoarch; caller guarantees CORE ownership
	size_t state_size = core.serialize_size();
	if (!state_size) return 0;
	int result = 0;

	char filename[MAX_PATH];
	void *state = calloc(1, state_size);
	if (!state) {
		LOG_error("Couldn't allocate memory for state\n");
		goto error;
	}

	State_getPath(filename);

	if (!core.serialize(state, state_size)) {
		LOG_error("Error creating save state: %s (%s)\n", filename, strerror(errno));
		goto error;
	}

	if (save_write_atomic(filename, state, state_size)) {
		LOG_error("Error writing state data: %s (%s)\n", filename, strerror(errno));
		goto error;
	}
	result = 1;

error:
	if (state) free(state);
	return result;
}
static int State_read(void) {
#ifdef ZERO_FRONTEND_THREADING_V2
	if (zero_ftv2_inited && fc_current_phase() != FCP_NONE)
		return State_readDirect();
#endif
	int was_ff = fast_forward;
	fast_forward = 0;
	int result;
#ifdef ZERO_FRONTEND_THREADING_V2
	if (zero_ftv2_inited)
		result = fc_menu_op(&zero_ftv2, FC_OP_UNSERIALIZE, (uint64_t)state_slot,
		                    zero_ftv2_drain, NULL) == 0;
	else
#endif
		result = State_readDirect();
	fast_forward = was_ff;
	return result;
}
static int State_write(void) {
#ifdef ZERO_FRONTEND_THREADING_V2
	if (zero_ftv2_inited && fc_current_phase() != FCP_NONE)
		return State_writeDirect();
#endif
	int was_ff = fast_forward;
	fast_forward = 0;
	int result;
#ifdef ZERO_FRONTEND_THREADING_V2
	if (zero_ftv2_inited)
		result = fc_menu_op(&zero_ftv2, FC_OP_SERIALIZE, (uint64_t)state_slot,
		                    zero_ftv2_drain, NULL) == 0;
	else
#endif
		result = State_writeDirect();
	fast_forward = was_ff;
	return result;
}
static int State_autosave(void) {
	int last_state_slot = state_slot;
	state_slot = AUTO_RESUME_SLOT;
	int result = State_write();
	state_slot = last_state_slot;
	return result;
}
static void State_resume(void) {
	if (!exists(RESUME_SLOT_PATH)) return;
	
	int last_state_slot = state_slot;
	state_slot = getInt(RESUME_SLOT_PATH);
	unlink(RESUME_SLOT_PATH);
	State_read();
	state_slot = last_state_slot;
}

///////////////////////////////

typedef struct Option {
	char* key;
	char* name; // desc
	char* desc; // info, truncated
	char* full; // info, longer but possibly still truncated
	char* var;
	int default_value;
	int value;
	int count; // TODO: drop this?
	int lock;
	char** values;
	char** labels;
} Option;
typedef struct OptionList {
	int count;
	int changed;
	Option* options;
	
	int enabled_count;
	Option** enabled_options;
	// OptionList_callback_t on_set;
} OptionList;

static char* threading_labels[] = {
	"Auto",
	"On",
	"Off",
	NULL,
};
static char* onoff_labels[] = {
	"Off",
	"On",
	NULL
};
static char* scaling_labels[] = {
	"Native",
	"Aspect",
	"Fullscreen",
	"Cropped",
	NULL
};
static char* effect_labels[] = {
	"None",
	"Line",
	"Line 50%",
	"Line 25%",
	"Grid",
	"Grid 50%",
	"Grid 25%",
	NULL
};
static char* sharpness_labels[] = {
	"Sharp",
	"Crisp",
	"Soft",
	NULL
};
static char* tearing_labels[] = {
	"Off",
	"Lenient",
	"Strict",
	NULL
};
static char* max_ff_labels[] = {
	"None",
	"1.25x",
	"1.5x",
	"1.75x",
	"2x",
	"3x",
	"4x",
	"5x",
	"6x",
	"7x",
	"8x",
	NULL,
};
// FF speed multipliers, index-aligned with max_ff_labels (0 = "None" = uncapped; guarded at
// every use). Fractional speeds (v1.4, D60): the "watchable" band — speech stays intelligible
// with FF audio at 1.25-1.75x, and heavy PS1 games that can't reach 2x CAN reach these, making
// PS1 fast-forward real for the first time. Config compat is free: cfgs persist the label
// string (e.g. "4x") and resolve by string match, so inserting entries can't remap old saves.
static const double max_ff_mults[] = { 0, 1.25, 1.5, 1.75, 2, 3, 4, 5, 6, 7, 8 };

///////////////////////////////

enum {
	FE_OPT_SCALING,
	FE_OPT_EFFECT,
	FE_OPT_SHARPNESS,
	FE_OPT_TEARING,
	FE_OPT_OVERCLOCK,
	FE_OPT_THREAD,
	FE_OPT_DEBUG,
	FE_OPT_MAXFF,
	FE_OPT_FF_AUDIO,
	FE_OPT_COUNT,
};

enum {
	SHORTCUT_SAVE_STATE,
	SHORTCUT_LOAD_STATE,
	SHORTCUT_RESET_GAME,
	SHORTCUT_SAVE_QUIT,
	SHORTCUT_CYCLE_SCALE,
	SHORTCUT_CYCLE_EFFECT,
	SHORTCUT_TOGGLE_FF,
	SHORTCUT_HOLD_FF,
	SHORTCUT_TOGGLE_HUD,
	SHORTCUT_COUNT,
};

#define LOCAL_BUTTON_COUNT 18 // depends on device; 16 + F1/F2 (present on Brick and Brick Pro)
#define RETRO_BUTTON_COUNT 16 // allow L3/R3 to be remapped by user if desired, eg. Virtual Boy uses extra buttons for right d-pad

typedef struct ButtonMapping { 
	char* name;
	int retro;
	int local; // TODO: dislike this name...
	int mod;
	int default_;
	int ignore;
} ButtonMapping;

static ButtonMapping default_button_mapping[] = { // used if pak.cfg doesn't exist or doesn't have bindings
	{"Up",			RETRO_DEVICE_ID_JOYPAD_UP,		BTN_ID_DPAD_UP},
	{"Down",		RETRO_DEVICE_ID_JOYPAD_DOWN,	BTN_ID_DPAD_DOWN},
	{"Left",		RETRO_DEVICE_ID_JOYPAD_LEFT,	BTN_ID_DPAD_LEFT},
	{"Right",		RETRO_DEVICE_ID_JOYPAD_RIGHT,	BTN_ID_DPAD_RIGHT},
	{"A Button",	RETRO_DEVICE_ID_JOYPAD_A,		BTN_ID_A},
	{"B Button",	RETRO_DEVICE_ID_JOYPAD_B,		BTN_ID_B},
	{"X Button",	RETRO_DEVICE_ID_JOYPAD_X,		BTN_ID_X},
	{"Y Button",	RETRO_DEVICE_ID_JOYPAD_Y,		BTN_ID_Y},
	{"Start",		RETRO_DEVICE_ID_JOYPAD_START,	BTN_ID_START},
	{"Select",		RETRO_DEVICE_ID_JOYPAD_SELECT,	BTN_ID_SELECT},
	{"L1 Button",	RETRO_DEVICE_ID_JOYPAD_L,		BTN_ID_L1},
	{"R1 Button",	RETRO_DEVICE_ID_JOYPAD_R,		BTN_ID_R1},
	{"L2 Button",	RETRO_DEVICE_ID_JOYPAD_L2,		BTN_ID_L2},
	{"R2 Button",	RETRO_DEVICE_ID_JOYPAD_R2,		BTN_ID_R2},
	{"L3 Button",	RETRO_DEVICE_ID_JOYPAD_L3,		BTN_ID_L3},
	{"R3 Button",	RETRO_DEVICE_ID_JOYPAD_R3,		BTN_ID_R3},
	{NULL,0,0}
};
static ButtonMapping button_label_mapping[] = { // used to lookup the retro_id and local btn_id from button name
	{"NONE",	-1,								BTN_ID_NONE},
	{"UP",		RETRO_DEVICE_ID_JOYPAD_UP,		BTN_ID_DPAD_UP},
	{"DOWN",	RETRO_DEVICE_ID_JOYPAD_DOWN,	BTN_ID_DPAD_DOWN},
	{"LEFT",	RETRO_DEVICE_ID_JOYPAD_LEFT,	BTN_ID_DPAD_LEFT},
	{"RIGHT",	RETRO_DEVICE_ID_JOYPAD_RIGHT,	BTN_ID_DPAD_RIGHT},
	{"A",		RETRO_DEVICE_ID_JOYPAD_A,		BTN_ID_A},
	{"B",		RETRO_DEVICE_ID_JOYPAD_B,		BTN_ID_B},
	{"X",		RETRO_DEVICE_ID_JOYPAD_X,		BTN_ID_X},
	{"Y",		RETRO_DEVICE_ID_JOYPAD_Y,		BTN_ID_Y},
	{"START",	RETRO_DEVICE_ID_JOYPAD_START,	BTN_ID_START},
	{"SELECT",	RETRO_DEVICE_ID_JOYPAD_SELECT,	BTN_ID_SELECT},
	{"L1",		RETRO_DEVICE_ID_JOYPAD_L,		BTN_ID_L1},
	{"R1",		RETRO_DEVICE_ID_JOYPAD_R,		BTN_ID_R1},
	{"L2",		RETRO_DEVICE_ID_JOYPAD_L2,		BTN_ID_L2},
	{"R2",		RETRO_DEVICE_ID_JOYPAD_R2,		BTN_ID_R2},
	{"L3",		RETRO_DEVICE_ID_JOYPAD_L3,		BTN_ID_L3},
	{"R3",		RETRO_DEVICE_ID_JOYPAD_R3,		BTN_ID_R3},
	{NULL,0,0}
};
static ButtonMapping core_button_mapping[RETRO_BUTTON_COUNT+1] = {0};

static const char* device_button_names[LOCAL_BUTTON_COUNT] = {
	[BTN_ID_DPAD_UP]	= "UP",
	[BTN_ID_DPAD_DOWN]	= "DOWN",
	[BTN_ID_DPAD_LEFT]	= "LEFT",
	[BTN_ID_DPAD_RIGHT]	= "RIGHT",
	[BTN_ID_SELECT]		= "SELECT",
	[BTN_ID_START]		= "START",
	[BTN_ID_Y]			= "Y",
	[BTN_ID_X]			= "X",
	[BTN_ID_B]			= "B",
	[BTN_ID_A]			= "A",
	[BTN_ID_L1]			= "L1",
	[BTN_ID_R1]			= "R1",
	[BTN_ID_L2]			= "L2",
	[BTN_ID_R2]			= "R2",
	[BTN_ID_L3]			= "L3",
	[BTN_ID_R3]			= "R3",
	[BTN_ID_F1]			= "F1",
	[BTN_ID_F2]			= "F2",
};


// NOTE: these must be in BTN_ID_ order also off by 1 because of NONE (which is -1 in BTN_ID_ land)
static char* button_labels[] = {
	"NONE", // displayed by default
	"UP",
	"DOWN",
	"LEFT",
	"RIGHT",
	"A",
	"B",
	"X",
	"Y",
	"START",
	"SELECT",
	"L1",
	"R1",
	"L2",
	"R2",
	"L3",
	"R3",
	"F1",
	"F2",
	"MENU+UP",
	"MENU+DOWN",
	"MENU+LEFT",
	"MENU+RIGHT",
	"MENU+A",
	"MENU+B",
	"MENU+X",
	"MENU+Y",
	"MENU+START",
	"MENU+SELECT",
	"MENU+L1",
	"MENU+R1",
	"MENU+L2",
	"MENU+R2",
	"MENU+L3",
	"MENU+R3",
	"MENU+F1",
	"MENU+F2",
	NULL,
};
static char* overclock_labels[] = {
	"Powersave",
	"Normal",
	"Performance",
	NULL,
};

// TODO: this should be provided by the core
static char* gamepad_labels[] = {
	"Standard",
	"DualShock",
	NULL,
};
static char* gamepad_values[] = {
	"1",
	"517",
	NULL,
};

enum {
	CONFIG_NONE,
	CONFIG_CONSOLE,
	CONFIG_GAME,
};

static inline char* getScreenScalingDesc(void) {
	if (GFX_supportsOverscan()) {
		return "Native uses integer scaling. Aspect uses core\nreported aspect ratio. Fullscreen has non-square\npixels. Cropped is integer scaled then cropped.";
	}
	else {
		return "Native uses integer scaling.\nAspect uses core reported aspect ratio.\nFullscreen has non-square pixels.";
	}
}
static inline int getScreenScalingCount(void) {
	return GFX_supportsOverscan() ? 4 : 3;
}
	

static struct Config {
	char* system_cfg; // system.cfg based on system limitations
	char* default_cfg; // pak.cfg based on platform limitations
	char* user_cfg; // minarch.cfg or game.cfg based on user preference
	char* device_tag;
	OptionList frontend;
	OptionList core;
	ButtonMapping* controls;
	ButtonMapping* shortcuts;
	int loaded;
	int initialized;
} config = {
	.frontend = { // (OptionList)
		.count = FE_OPT_COUNT,
		.options = (Option[]){
			[FE_OPT_SCALING] = {
				.key	= "minarch_screen_scaling", 
				.name	= "Screen Scaling",
				.desc	= NULL, // will call getScreenScalingDesc()
				.default_value = 1,
				.value = 1,
				.count = 3, // will call getScreenScalingCount()
				.values = scaling_labels,
				.labels = scaling_labels,
			},
			[FE_OPT_EFFECT] = {
				.key	= "minarch_screen_effect",
				.name	= "Screen Effect",
				.desc	= "Line simulates CRT scanlines. Grid an LCD grid.\nThe 50%% and 25%% variants are subtler.\nEffects usually look best at native scaling.",
				.default_value = 0,
				.value = 0,
				.count = EFFECT_COUNT, // 7 on every platform
				.values = effect_labels,
				.labels = effect_labels,
			},
			[FE_OPT_SHARPNESS] = {
				.key	= "minarch_screen_sharpness",
				.name	= "Screen Sharpness",
				.desc	= "Sharp uses nearest neighbor sampling.\nCrisp integer upscales before linear sampling.\nSoft uses linear sampling.",
				.default_value = 2,
				.value = 2,
				.count = 3,
				.values = sharpness_labels,
				.labels = sharpness_labels,
			},
			[FE_OPT_TEARING] = {
				.key	= "minarch_prevent_tearing",
				.name	= "Prevent Tearing",
				.desc	= "Wait for vsync before drawing the next frame.\nLenient only waits when within frame budget.\nStrict always waits.",
				.default_value = VSYNC_LENIENT,
				.value = VSYNC_LENIENT,
				.count = 3,
				.values = tearing_labels,
				.labels = tearing_labels,
			},
			[FE_OPT_OVERCLOCK] = {
				.key	= "minarch_cpu_speed",
				.name	= "CPU Speed",
				.desc	= "Over- or underclock the CPU to prioritize\npure performance or power savings.",
				.default_value = 1,
				.value = 1,
				.count = 3,
				.values = overclock_labels,
				.labels = overclock_labels,
			},
			[FE_OPT_THREAD] = {
				.key	= "minarch_threading",
				.name	= "Multithreading",
				.desc	= "Auto measures the active game and threads it\nonly when that verifiably lowers the CPU clock.\nOn always threads it. Off never does.",
#ifdef ZERO_DISABLE_FRONTEND_THREADING
				.default_value = 2,
				.value = 2,
				.lock = 1,
#else
				.default_value = 0, // Auto
				.value = 0,
#endif
				.count = 3,
				.values = threading_labels,
				.labels = threading_labels,
			},
			[FE_OPT_DEBUG] = {
				.key	= "minarch_debug_hud",
				.name	= "Debug HUD",
				.desc	= "Overlay: clock/ceiling MHz, temp,\nactual/target fps, cpu load, scaling.",
				.default_value = 0,
				.value = 0,
				.count = 2,
				.values = onoff_labels,
				.labels = onoff_labels,
			},
			[FE_OPT_MAXFF] = {
				.key	= "minarch_max_ff_speed",
				.name	= "Max FF Speed",
				.desc	= "Fast forward will not exceed the\nselected speed (but may be less\ndepending on game and emulator).",
				.default_value = 6, // 4x (index shifted by the three fractional speeds; cfgs
				.value = 6,         // resolve by label string, so saved "4x" stays 4x)
				.count = 11,
				.values = max_ff_labels,
				.labels = max_ff_labels,
			},
			[FE_OPT_FF_AUDIO] = {
				.key	= "minarch_ff_audio",
				.name	= "Fast-forward Audio",
				.desc	= "Play sped-up audio while fast-forwarding.\nTurn off for silent fast-forward.",
				.default_value = 1,
				.value = 1,
				.count = 2,
				.values = onoff_labels,
				.labels = onoff_labels,
			},
			[FE_OPT_COUNT] = {NULL}
		}
	},
	.core = { // (OptionList)
		.count = 0,
		.options = (Option[]){
			{NULL},
		},
	},
	.controls = default_button_mapping,
	.shortcuts = (ButtonMapping[]){
		[SHORTCUT_SAVE_STATE]			= {"Save State",		-1, BTN_ID_NONE, 0},
		[SHORTCUT_LOAD_STATE]			= {"Load State",		-1, BTN_ID_NONE, 0},
		[SHORTCUT_RESET_GAME]			= {"Reset Game",		-1, BTN_ID_NONE, 0},
		[SHORTCUT_SAVE_QUIT]			= {"Save & Quit",		-1, BTN_ID_NONE, 0},
		[SHORTCUT_CYCLE_SCALE]			= {"Cycle Scaling",		-1, BTN_ID_NONE, 0},
		[SHORTCUT_CYCLE_EFFECT]			= {"Cycle Effect",		-1, BTN_ID_NONE, 0},
		[SHORTCUT_TOGGLE_FF]			= {"Toggle FF",			-1, BTN_ID_NONE, 0},
		[SHORTCUT_HOLD_FF]				= {"Hold FF",			-1, BTN_ID_NONE, 0},
		[SHORTCUT_TOGGLE_HUD]			= {"Toggle HUD",		-1, BTN_ID_NONE, 0},
		{NULL}
	},
};
static int Config_getValue(char* cfg, const char* key, char* out_value, int* lock) { // gets value from string
	char* tmp = cfg;
	while ((tmp = strstr(tmp, key))) {
		if (lock!=NULL && tmp>cfg && *(tmp-1)=='-') *lock = 1; // prefixed with a `-` means lock
		tmp += strlen(key);
		if (!strncmp(tmp, " = ", 3)) break; // matched
	};
	if (!tmp) return 0;
	tmp += 3;
	
	strncpy(out_value, tmp, 256);
	out_value[256 - 1] = '\0';
	tmp = strchr(out_value, '\n');
	if (!tmp) tmp = strchr(out_value, '\r');
	if (tmp) *tmp = '\0';

	// LOG_info("\t%s = %s (%s)\n", key, out_value, (lock && *lock) ? "hidden":"shown");
	return 1;
}

static void setOverclock(int i) {
	overclock = i;
	switch (i) {
		case 0: PWR_setCPUSpeed(CPU_SPEED_POWERSAVE); break;
		case 1: PWR_setCPUSpeed(CPU_SPEED_NORMAL); break;
		case 2: PWR_setCPUSpeed(CPU_SPEED_PERFORMANCE); break;
	}
}

///////////////////////////////
// closed-loop thermal/perf governor (see docs/thermal-governor-design.md)

static GovState gov_state;
static GovProfile gov_profile;
static int gov_active = 0; // governor owns the clock during gameplay once a profile is picked

// Pick the per-system clock bracket. The per-pak launch.sh exports MINARCH_FMIN/FMAX
// in kHz; fall back to a safe default (max holds frame rate, governor sinks from there).
static void Gov_start(void) {
	int fmin = 0, fmax = 0;
	char* s_min = getenv("MINARCH_FMIN");
	char* s_max = getenv("MINARCH_FMAX");
	if (s_min) fmin = atoi(s_min);
	if (s_max) fmax = atoi(s_max);
	if (fmin>0 && fmax>=fmin) {
		gov_profile.f_min = fmin;
		gov_profile.f_max = fmax;
	}
	else {
		gov_profile = GOV_P_DEFAULT;
	}
	// The kernel's REAL OPP ladder, read from the kernel itself (never fabricated). With it,
	// every commanded ceiling is a real OPP; without it the legacy stride walked off the
	// A133P ladder (1200-216=984 -> kernel ran 816) and the sink gate under-predicted every
	// probe step (.notes/2026-08-31-game-start-hitches). Absent/unparsable -> n_opps=0 ->
	// stride behavior, bit-identical to before (macOS harness has no cpufreq at all).
	gov_profile.n_opps = 0;
	{
		FILE* af = fopen("/sys/devices/system/cpu/cpu0/cpufreq/scaling_available_frequencies", "r");
		if (af) {
			int khz;
			while (gov_profile.n_opps < GOV_MAX_OPPS && fscanf(af, "%d", &khz) == 1)
				if (khz > 0) gov_profile.opps[gov_profile.n_opps++] = khz;
			fclose(af);
			if (gov_profile.n_opps > 0) {
				char lad[256]; int off = 0;
				for (int i = 0; i < gov_profile.n_opps && off < 240; i++)
					off += snprintf(lad+off, sizeof(lad)-off, "%d ", gov_profile.opps[i]);
				LOG_info("governor: OPP ladder [%s] (%d entries)\n", lad, gov_profile.n_opps);
			}
		}
	}
	gov_init(&gov_state, &gov_profile);
	gov_active = 1;
	// FAST-SINK, not start-low (reviews r1-r4): boot always starts at f_max; the pure
	// unit arms the remembered floor and the tick loop descends one OPP per fresh
	// healthy sample. Range/fixed-bracket/disable validation lives in govmem_init.
	{
		int gm_enabled = (getenv("ZERO_NO_GOV_MEMORY") == NULL);
		const char* gd = getenv("GOV_DISABLE"); // value semantics match governor.c ("0" = enabled)
		if (gd && gd[0] && gd[0] != '0') gm_enabled = 0;
		govmem_init(&gov_mem, gm_enabled, gm_enabled ? gov_mem_read() : 0, &gov_profile);
		if (govmem_arm_khz(&gov_mem))
			LOG_info("gov-memory: fast-sink armed to %d kHz\n", govmem_arm_khz(&gov_mem));
	}
	PWR_setCPUMaxFreq(gov_profile.f_max); // start high so the first frames never starve
	LOG_info("governor: f_min=%d f_max=%d kHz\n", gov_profile.f_min, gov_profile.f_max);
}
static void Gov_restore(void) {
	if (gov_active) PWR_setCPUMaxFreq(gov_state.ceil_khz);
	else setOverclock(overclock);
}
// The ONLY way to burst: every burst invalidates the in-flight vote window (an f_max
// burst still changes the workload the window measured — review r4); arm cancellation
// is caller policy (later geometry + FF toggles cancel, initial geometry does not).
static void gov_scene_burst(const char* why, int cancel_arm) {
	int had_arm = govmem_arm_khz(&gov_mem);
	govmem_on_burst(&gov_mem, cancel_arm);
	if (had_arm && cancel_arm) LOG_info("gov-memory: fast-sink canceled (%s)\n", why);
	gov_burst(&gov_state, &gov_profile);
}
static int* g_drc_ppm_ptr = NULL;
static void drc_ppm_expose(int* p) { g_drc_ppm_ptr = p; }
static int drc_ppm_now(void) { return g_drc_ppm_ptr ? *g_drc_ppm_ptr : 0; }

// Audio ring occupancy servo (serial path; see the block in the game loop). State is
// file-scope so the thread toggle can hand the resampler back BEFORE a CORE thread starts
// producing — on MAIN, while MAIN still owns production, so it is race-free.
// Setpoint, band, rail and smoothing live in audioservo.h with the control law (unit-tested).
static int zero_servo_adj = 0;    // ppm currently trimmed on top of the static rate match
static int zero_servo_static = 0; // the static ppm that trim was applied against
static void zero_servo_release(void) {
	if (!zero_servo_adj) return;
	zero_servo_adj = 0;
	SND_setRateAdjustPPM(zero_static_rate_ppm); // static match (or 0) back, untrimmed
}
static int toggle_thread = 0;
static void Config_syncFrontend(char* key, int value) {
	present_dirty_gen++; // scaling/effect/sharpness/HUD changes must reach the panel even on duplicate frames
	int i = -1;
	if (exactMatch(key,config.frontend.options[FE_OPT_SCALING].key)) {
		screen_scaling 	= value;
		
		if (screen_scaling==SCALE_NATIVE) GFX_setSharpness(SHARPNESS_SHARP);
		else GFX_setSharpness(screen_sharpness);
		
		renderer.dst_p = 0;
		i = FE_OPT_SCALING;
	}
	else if (exactMatch(key,config.frontend.options[FE_OPT_EFFECT].key)) {
		screen_effect = value;
		// Apply immediately only OUTSIDE the in-game menu. Menu_loop clears the effect on entry and
		// re-applies screen_effect on exit, so while the menu is up this call is both redundant and
		// visible: on miyoomini the effect is a present-time MI_GFX overlay, and toggling it here
		// drew scanlines over the menu itself until you closed it (Dan, 2026-09-08). Platforms that
		// bake the effect into the game scaler never showed the difference, but the deferral is
		// correct for all of them — the menu is not supposed to carry the effect.
		if (!show_menu) GFX_setEffect(value);
		renderer.dst_p = 0;
		i = FE_OPT_EFFECT;
	}
	else if (exactMatch(key,config.frontend.options[FE_OPT_SHARPNESS].key)) {
		screen_sharpness = value;
		
		if (screen_scaling==SCALE_NATIVE) GFX_setSharpness(SHARPNESS_SHARP);
		else GFX_setSharpness(screen_sharpness);

		renderer.dst_p = 0;
		i = FE_OPT_SHARPNESS;
	}
	else if (exactMatch(key,config.frontend.options[FE_OPT_TEARING].key)) {
		prevent_tearing = value;
		#ifdef GOV_PLATFORM_MIYOOMINI
		// STRICT NEEDS A MEASURED PANEL RATE — on this platform specifically.
		//
		// Here Strict means the producer blocks on a raw fbdev pan, so the core is paced by the
		// panel itself. On a panel SLOWER than the core that throttles the core below native and
		// audio production runs at a deficit. The static rate match is what repays it, and it only
		// exists when the platform declared a MEASURED MINARCH_PANEL_FPS. DRC cannot stand in: it
		// is clamped >= 0 and only ever climbs (see drc_supported), so it cannot express a
		// slow-panel correction at all.
		//
		// This is guarded rather than global because it is a property of THIS present path. On
		// tg5040 Strict runs through SDL_RENDERER_PRESENTVSYNC, which needs no declared rate.
		//
		// It matters because one Miyoo build serves three models from identical binaries and only
		// the Mini Plus's panel has been measured; without this an unmeasured Mini or Mini Flip
		// would inherit the Plus's locked Strict with nothing to repay the deficit.
		if (prevent_tearing == VSYNC_STRICT && !getenv("MINARCH_PANEL_FPS")) {
			LOG_info("tearing: Strict requested but no measured MINARCH_PANEL_FPS — using Lenient\n");
			prevent_tearing = VSYNC_LENIENT;
		}
		#endif
		i = FE_OPT_TEARING;
	}
	else if (exactMatch(key,config.frontend.options[FE_OPT_THREAD].key)) {
	#ifdef ZERO_FRONTEND_THREADING_V2
		if (zero_ftv2_depth2) {
			thread_video = 0;
			was_threaded = 0;
			thread_auto = 0;
			ta_phase = 2;
			ta_decided_by_user = 1;
			toggle_thread = 0;
			config.frontend.options[FE_OPT_THREAD].value = 2;
			config.frontend.options[FE_OPT_THREAD].lock = 1;
		}
		else {
	#endif
	#ifdef ZERO_DISABLE_FRONTEND_THREADING
		// The current mailbox path mutates renderer/scaler state from the core thread.
		// Keep it unreachable on the release platform until ownership is redesigned.
		thread_video = 0;
		was_threaded = 0;
		thread_auto = 0;
		ta_phase = 2;
		ta_decided_by_user = 1;
		toggle_thread = 0;
		config.frontend.options[FE_OPT_THREAD].value = 2;
		config.frontend.options[FE_OPT_THREAD].lock = 1;
#else
		// 0=Auto (trial machinery owns it), 1=On, 2=Off (explicit user override).
		// During config LOAD this only records the value — arming toggle_thread while
		// thread_video is still false made a persisted On start threaded and then
		// immediately tear itself down on the first main-loop pass (Codex finding #1).
		thread_auto = (value == 0);
		if (value != 0) {
			ta_phase = 2; // decided by the user
			ta_decided_by_user = 1;
			if (game_running) {
				int want = (value == 1);
				int have = thread_video || was_threaded;
				toggle_thread = have != want;
			}
		}
		else {
			toggle_thread = 0; // cancel any pending explicit toggle (On->Off->Auto cycling)
			if (ta_phase == 2 && ta_decided_by_user) {
				ta_phase = 0; ta_phase_at = 0; // back to Auto: re-observe
			}
		}
	#endif
	#ifdef ZERO_FRONTEND_THREADING_V2
		}
	#endif
		i = FE_OPT_THREAD;
	}
	else if (exactMatch(key,config.frontend.options[FE_OPT_OVERCLOCK].key)) {
		overclock = value;
		i = FE_OPT_OVERCLOCK;
	}
	else if (exactMatch(key,config.frontend.options[FE_OPT_DEBUG].key)) {
		show_debug = value;
		i = FE_OPT_DEBUG;
	}
	else if (exactMatch(key,config.frontend.options[FE_OPT_MAXFF].key)) {
		max_ff_speed = value;
		i = FE_OPT_MAXFF;
	}
	else if (exactMatch(key,config.frontend.options[FE_OPT_FF_AUDIO].key)) {
		ff_audio = value;
		SND_setFastForward(fast_forward, ff_audio);
		i = FE_OPT_FF_AUDIO;
	}
	if (i==-1) return;
	Option* option = &config.frontend.options[i];
	option->value = value;
}
static void OptionList_setOptionValue(OptionList* list, const char* key, const char* value);
enum {
	CONFIG_WRITE_ALL,
	CONFIG_WRITE_GAME,
};
static void Config_getPath(char* filename, int override) {
	char device_tag[64] = {0};
	if (config.device_tag) sprintf(device_tag,"-%s",config.device_tag);
	if (override) sprintf(filename, "%s/%s%s.cfg", core.config_dir, game.name, device_tag);
	else sprintf(filename, "%s/minarch%s.cfg", core.config_dir, device_tag);
	LOG_info("Config_getPath %s\n", filename);
}
static void Config_init(void) {
	if (!config.default_cfg || config.initialized) return;
	
	LOG_info("Config_init\n");
	char* tmp = config.default_cfg;
	char* tmp2;
	char* key;
	
	char button_name[128];
	char button_id[128];
	int i = 0;
	while ((tmp = strstr(tmp, "bind "))) {
		tmp += 5; // tmp now points to the button name (plus the rest of the line)
		key = tmp;
		tmp = strstr(tmp, " = ");
		if (!tmp) break;
		
		int len = tmp-key;
		strncpy(button_name, key, len);
		button_name[len] = '\0';
		
		tmp += 3;
		strncpy(button_id, tmp, 128);
		tmp2 = strchr(button_id, '\n');
		if (!tmp2) tmp2 = strchr(button_id, '\r');
		if (tmp2) *tmp2 = '\0';
		
		int retro_id = -1;
		int local_id = -1;
		
		tmp2 = strrchr(button_id, ':');
		int remap = 0;
		if (tmp2) {
			for (int j=0; button_label_mapping[j].name; j++) {
				ButtonMapping* button = &button_label_mapping[j];
				if (!strcmp(tmp2+1,button->name)) {
					retro_id = button->retro;
					break;
				}
			}
			*tmp2 = '\0';
		}
		for (int j=0; button_label_mapping[j].name; j++) {
			ButtonMapping* button = &button_label_mapping[j];
			if (!strcmp(button_id,button->name)) {
				local_id = button->local;
				if (retro_id==-1) retro_id = button->retro;
				break;
			}
		}
		
		tmp += strlen(button_id); // prepare to continue search
		
		LOG_info("\tbind %s (%s) %i:%i\n", button_name, button_id, local_id, retro_id);
		
		// TODO: test this without a final line return
		tmp2 = calloc(strlen(button_name)+1, sizeof(char));
		strcpy(tmp2, button_name);
		ButtonMapping* button = &core_button_mapping[i++];
		button->name = tmp2;
		button->retro = retro_id;
		button->local = local_id;
	};
	
	config.initialized = 1;
}
static void Config_quit(void) {
	if (!config.initialized) return;
	for (int i=0; core_button_mapping[i].name; i++) {
		free(core_button_mapping[i].name);
	}
}
// is_user: this is the player's SAVED cfg, not something we ship.
//
// A saved cfg must not silently override a value we LOCKED. Load order is
// system.cfg -> pak default.cfg -> saved cfg, and last-write-wins on value, so a stale save pinned
// settings forever: a disabled NES turbo survived the pak default that re-enabled it, and per D48 a
// stale `gpu_thread_rendering` survived the default that turned it off.
//
// A locked option is one the player cannot reach in the menu, so a differing saved value can only
// be an artifact of an older build — never a deliberate choice. Shipped files still override each
// other in order (a pak may specialise system.cfg); only the saved cfg is held back.
//
// The lock gate above is inert for options we ship UNLOCKED, and that left a real hole: a saved cfg
// carries EVERY option, because Config_write dumps the whole list on any change. Touch one setting
// and scaling is frozen at whatever it happened to be, forever — so cards written before the pak
// default became `Native` kept `minarch_screen_scaling = Aspect` and kept shimmering on fractional
// scale, even though nobody ever chose it.
//
// Locking scaling would fix it and cost the menu entry. Instead: version the saved cfg. A save
// written before CFG_VERSION predates the defaults we have since changed, so the keys in
// cfg_stale_keys are dropped from it exactly once and the shipped default wins. The next
// Config_write stamps the version, and from then on a deliberate choice sticks like any other.
//
// An entry names the value it migrates TO, and the version that introduced it. Both fields are
// load-bearing:
//
//   `to`      A stale value is dropped ONLY where the shipped chain actually resolves to `to`.
//             Merely "some shipped file mentions this key" is not enough, and getting this wrong
//             regresses the Brick: tg5040's system.cfg sets `minarch_screen_scaling = Aspect`
//             GLOBALLY, so a "was it shipped at all" test fires on every Brick launch for every
//             core and resets any deliberate Native/Fullscreen/Cropped choice to Aspect. Only the
//             MMP GB/GBC/FC paks actually moved to Native, and those are the only places this
//             should fire. (Not hypothetical — caught in review against the real config tree.)
//
//   `version` Per-entry, NOT a single global `user_version < CFG_VERSION`. Otherwise adding a v2
//             key would re-drop every v1 key on a valid v1 save, destroying a choice the player
//             made deliberately after the v1 migration already ran.
//
// Add an entry when a shipped default changes in a way a stale save would defeat, and bump
// CFG_VERSION to match. Keep the list SHORT — every entry discards a player's setting once.
#define CFG_VERSION 1
#define CFG_VERSION_KEY "minarch_cfg_version"
#define CFG_STALE_MAX 8
typedef struct CfgStaleKey {
	const char* key;
	const char* to;   // drop the saved value only if the shipped chain resolves to exactly this
	int version;      // drop only if the save predates this version
} CfgStaleKey;
static const CfgStaleKey cfg_stale_keys[] = {
	// v1: the MMP GB/GBC/FC pak defaults moved to Native; saves predating that pinned Aspect and
	// shimmered on fractional scale. tg5040 ships Aspect and is deliberately NOT affected.
	{ "minarch_screen_scaling", "Native", 1 },
	{ NULL, NULL, 0 },
};
static int Config_staleIndex(const char* key) {
	for (int i=0; cfg_stale_keys[i].key; i++) if (!strcmp(key, cfg_stale_keys[i].key)) return i;
	return -1;
}
static int Config_isStaleKey(const char* key) { return Config_staleIndex(key) >= 0; }

// What the SHIPPED chain (system.cfg -> pak default.cfg) last said for each stale key this launch;
// empty means it said nothing. Load order is preserved because the shipped passes run in order, so
// this ends up holding the value the shipped chain actually resolves to. Reset by
// Config_readOptions.
static char cfg_stale_shipped[CFG_STALE_MAX][64];

// Strict: the value must be ALL digits, non-empty, and in range. A bare strtol() reads "1garbage"
// as 1 — i.e. a corrupted stamp would claim to be current and the migration would never run, which
// is the silent-failure direction. Anything we cannot fully parse is treated as version 0
// (unstamped), so the worst case is that the migration re-evaluates rather than being skipped.
static int Config_parseVersion(const char* value) {
	if (!value || !*value) return 0;
	long v = 0;
	for (const char* p = value; *p; p++) {
		if (*p < '0' || *p > '9') return 0;
		v = v * 10 + (*p - '0');
		if (v > 100000) return 0; // absurd; treat as corrupt rather than wrapping an int
	}
	return (int)v;
}

// The whole drop decision, in one place so the frontend and core loops cannot drift.
static int Config_shouldDropStale(int stale_i, int user_version) {
	if (stale_i < 0 || stale_i >= CFG_STALE_MAX) return 0;
	const CfgStaleKey* e = &cfg_stale_keys[stale_i];
	if (user_version >= e->version) return 0;       // save is current for THIS entry
	if (!cfg_stale_shipped[stale_i][0]) return 0;   // nothing shipped to replace it with
	return !strcmp(cfg_stale_shipped[stale_i], e->to);
}

// user_version: the CFG_VERSION stamped in this saved cfg (0 = unstamped/pre-migration). Ignored
// unless is_user, since shipped files are always current by definition.
static void Config_readOptionsString(char* cfg, int is_user, int user_version) {
	if (!cfg) return;
	if (!is_user) user_version = CFG_VERSION; // shipped files are current by definition

	LOG_info("Config_readOptions\n");
	char key[256];
	char value[256];
	for (int i=0; config.frontend.options[i].key; i++) {
		Option* option = &config.frontend.options[i];
		int was_locked = option->lock;
		if (!Config_getValue(cfg, option->key, value, &option->lock)) continue;
		int stale_i = Config_staleIndex(option->key);
		if (stale_i >= 0 && stale_i < CFG_STALE_MAX) {
			// Record what the SHIPPED chain says; later shipped files override earlier ones, which
			// is exactly the resolution order we need to compare against.
			if (!is_user) snprintf(cfg_stale_shipped[stale_i], sizeof(cfg_stale_shipped[stale_i]), "%s", value);
			else if (Config_shouldDropStale(stale_i, user_version)) {
				// Say so — same reason as the locked case below. A dropped line that IS in the
				// file otherwise sends anyone debugging chasing a setting that looks applied and
				// is not.
				LOG_info("migrating saved cfg (v%d -> v%d): dropping %s = %s (shipped says %s)\n",
					user_version, CFG_VERSION, option->key, value, cfg_stale_shipped[stale_i]);
				continue;
			}
		}
		if (is_user && was_locked) {
			// Say so. Silently discarding a line that IS in the file on the card sends anyone
			// debugging (us included) chasing a setting that looks applied and is not.
			LOG_info("ignoring locked frontend option from saved cfg: %s = %s\n", option->key, value);
			continue;
		}
		OptionList_setOptionValue(&config.frontend, option->key, value);
		Config_syncFrontend(option->key, option->value);
	}
	
	if (has_custom_controllers && Config_getValue(cfg,"minarch_gamepad_type",value,NULL)) {
		gamepad_type = strtol(value, NULL, 0);
		int device = strtol(gamepad_values[gamepad_type], NULL, 0);
		Core_setController(device);
	}
	
	for (int i=0; config.core.options[i].key; i++) {
		Option* option = &config.core.options[i];
		int was_locked = option->lock;
		if (!Config_getValue(cfg, option->key, value, &option->lock)) continue;
		// Core options migrate too — cfg_stale_keys is not frontend-only. D48's stale
		// `gpu_thread_rendering` is exactly this shape, and it is a CORE key.
		int stale_i = Config_staleIndex(option->key);
		if (stale_i >= 0 && stale_i < CFG_STALE_MAX) {
			if (!is_user) snprintf(cfg_stale_shipped[stale_i], sizeof(cfg_stale_shipped[stale_i]), "%s", value);
			else if (Config_shouldDropStale(stale_i, user_version)) {
				LOG_info("migrating saved cfg (v%d -> v%d): dropping %s = %s (shipped says %s)\n",
					user_version, CFG_VERSION, option->key, value, cfg_stale_shipped[stale_i]);
				continue;
			}
		}
		if (is_user && was_locked) {
			LOG_info("ignoring locked core option from saved cfg: %s = %s\n", option->key, value);
			continue;
		}
		OptionList_setOptionValue(&config.core, option->key, value);
	}
}
static void Config_readControlsString(char* cfg) {
	if (!cfg) return;

	LOG_info("Config_readControlsString\n");
	
	char key[256];
	char value[256];
	char* tmp;
	for (int i=0; config.controls[i].name; i++) {
		ButtonMapping* mapping = &config.controls[i];
		sprintf(key, "bind %s", mapping->name);
		sprintf(value, "NONE");
		
		if (!Config_getValue(cfg, key, value, NULL)) continue;
		if ((tmp = strrchr(value, ':'))) *tmp = '\0'; // this is a binding artifact in default.cfg, ignore
		
		int id = -1;
		for (int j=0; button_labels[j]; j++) {
			if (!strcmp(button_labels[j],value)) {
				id = j - 1;
				break;
			}
		}
		// LOG_info("\t%s (%i)\n", value, id);
		
		int mod = 0;
		if (id>=LOCAL_BUTTON_COUNT) {
			id -= LOCAL_BUTTON_COUNT;
			mod = 1;
		}
		
		mapping->local = id;
		mapping->mod = mod;
	}
	
	for (int i=0; config.shortcuts[i].name; i++) {
		ButtonMapping* mapping = &config.shortcuts[i];
		sprintf(key, "bind %s", mapping->name);
		sprintf(value, "NONE");

		if (!Config_getValue(cfg, key, value, NULL)) continue;
		
		int id = -1;
		for (int j=0; button_labels[j]; j++) {
			if (!strcmp(button_labels[j],value)) {
				id = j - 1;
				break;
			}
		}
		
		int mod = 0;
		if (id>=LOCAL_BUTTON_COUNT) {
			id -= LOCAL_BUTTON_COUNT;
			mod = 1;
		}
		// LOG_info("shortcut %s:%s (%i:%i)\n", key,value, id, mod);

		mapping->local = id;
		mapping->mod = mod;
	}
}
static void Config_load(void) {
	LOG_info("Config_load\n");
	
	config.device_tag = getenv("DEVICE");
	LOG_info("config.device_tag %s\n", config.device_tag);
	
	// update for crop overscan support
	Option* scaling_option = &config.frontend.options[FE_OPT_SCALING];
	scaling_option->desc = getScreenScalingDesc();
	scaling_option->count = getScreenScalingCount();
	if (!GFX_supportsOverscan()) {
		scaling_labels[3] = NULL;
	}
	
	char* system_path = SYSTEM_PATH "/system.cfg";
	
	char device_system_path[MAX_PATH] = {0};
	if (config.device_tag) sprintf(device_system_path, SYSTEM_PATH "/system-%s.cfg", config.device_tag);
	
	if (config.device_tag && exists(device_system_path)) {
		LOG_info("usng device_system_path: %s\n", device_system_path);
		config.system_cfg = allocFile(device_system_path);
	}
	else if (exists(system_path)) config.system_cfg = allocFile(system_path);
	else config.system_cfg = NULL;
	
	// LOG_info("config.system_cfg: %s\n", config.system_cfg);
	
	char default_path[MAX_PATH];
	getEmuPath((char *)core.tag, default_path);
	char* tmp = strrchr(default_path, '/');
	strcpy(tmp,"/default.cfg");

	char device_default_path[MAX_PATH] = {0};
	if (config.device_tag) {
		getEmuPath((char *)core.tag, device_default_path);
		tmp = strrchr(device_default_path, '/');
		char filename[64];
		sprintf(filename,"/default-%s.cfg", config.device_tag);
		strcpy(tmp,filename);
	}
	
	if (config.device_tag && exists(device_default_path)) {
		LOG_info("usng device_default_path: %s\n", device_default_path);
		config.default_cfg = allocFile(device_default_path);
	}
	else if (exists(default_path)) config.default_cfg = allocFile(default_path);
	else config.default_cfg = NULL;
	
	// LOG_info("config.default_cfg: %s\n", config.default_cfg);
	
	char path[MAX_PATH];
	config.loaded = CONFIG_NONE;
	int override = 0;
	Config_getPath(path, CONFIG_WRITE_GAME);
	if (exists(path)) override = 1; 
	if (!override) Config_getPath(path, CONFIG_WRITE_ALL);
	
	config.user_cfg = allocFile(path);
	if (!config.user_cfg) return;
	
	LOG_info("using user config: %s\n", path);
	
	config.loaded = override ? CONFIG_GAME : CONFIG_CONSOLE;
}
static void Config_free(void) {
	if (config.system_cfg) free(config.system_cfg);
	if (config.default_cfg) free(config.default_cfg);
	if (config.user_cfg) free(config.user_cfg);
	config.system_cfg = config.default_cfg = config.user_cfg = NULL; // freed pointers must not look usable
}
static void Config_readOptions(void) {
	// Per-launch: the shipped chain is re-read every time, so its opinions must be too.
	memset(cfg_stale_shipped, 0, sizeof(cfg_stale_shipped));

	Config_readOptionsString(config.system_cfg, 0, CFG_VERSION);
	Config_readOptionsString(config.default_cfg, 0, CFG_VERSION);

	// An unstamped saved cfg is pre-migration, which is the whole point of the check — treat a
	// missing key as version 0 rather than assuming current.
	int user_version = 0;
	if (config.user_cfg) {
		char value[256];
		if (Config_getValue(config.user_cfg, CFG_VERSION_KEY, value, NULL))
			user_version = Config_parseVersion(value);
	}
	Config_readOptionsString(config.user_cfg, 1, user_version); // saved: no lock override, migrated

	// screen_scaling = SCALE_NATIVE; // TODO: tmp
}
static void Config_readControls(void) {
	Config_readControlsString(config.default_cfg);
	Config_readControlsString(config.user_cfg);
}

typedef struct ConfigBuffer {
	char* data;
	size_t size;
	size_t capacity;
	int failed;
} ConfigBuffer;

static void ConfigBuffer_append(ConfigBuffer* buffer, const char* format, ...) {
	if (buffer->failed) return;

	va_list args;
	va_start(args, format);
	va_list measure;
	va_copy(measure, args);
	int added = vsnprintf(NULL, 0, format, measure);
	va_end(measure);
	if (added < 0 || buffer->size > SIZE_MAX - (size_t)added - 1) {
		if (added >= 0) errno = EOVERFLOW;
		buffer->failed = 1;
		va_end(args);
		return;
	}

	size_t required = buffer->size + (size_t)added + 1;
	if (required > buffer->capacity) {
		size_t capacity = buffer->capacity ? buffer->capacity : 1024;
		while (capacity < required) {
			if (capacity > SIZE_MAX / 2) {
				capacity = required;
				break;
			}
			capacity *= 2;
		}
		char* data = realloc(buffer->data, capacity);
		if (!data) {
			buffer->failed = 1;
			va_end(args);
			return;
		}
		buffer->data = data;
		buffer->capacity = capacity;
	}

	vsnprintf(buffer->data + buffer->size, buffer->capacity - buffer->size, format, args);
	buffer->size += (size_t)added;
	va_end(args);
}

static void Config_write(int override) {
	char path[MAX_PATH];
	char game_path[MAX_PATH];
	Config_getPath(game_path, CONFIG_WRITE_GAME);
	if (override) strcpy(path, game_path);
	else Config_getPath(path, CONFIG_WRITE_ALL);

	ConfigBuffer contents = {};

	// Stamp FIRST, so a save that is truncated mid-write is never mistaken for a current one.
	// This is what makes the migration one-shot: everything below is a deliberate choice now.
	ConfigBuffer_append(&contents, "%s = %d\n", CFG_VERSION_KEY, CFG_VERSION);

	for (int i=0; config.frontend.options[i].key; i++) {
		Option* option = &config.frontend.options[i];
		ConfigBuffer_append(&contents, "%s = %s\n", option->key, option->values[option->value]);
	}
	for (int i=0; config.core.options[i].key; i++) {
		Option* option = &config.core.options[i];
		ConfigBuffer_append(&contents, "%s = %s\n", option->key, option->values[option->value]);
	}
	
	if (has_custom_controllers) ConfigBuffer_append(&contents, "%s = %i\n", "minarch_gamepad_type", gamepad_type);
	
	for (int i=0; config.controls[i].name; i++) {
		ButtonMapping* mapping = &config.controls[i];
		int j = mapping->local + 1;
		if (mapping->mod) j += LOCAL_BUTTON_COUNT;
		ConfigBuffer_append(&contents, "bind %s = %s\n", mapping->name, button_labels[j]);
	}
	for (int i=0; config.shortcuts[i].name; i++) {
		ButtonMapping* mapping = &config.shortcuts[i];
		int j = mapping->local + 1;
		if (mapping->mod) j += LOCAL_BUTTON_COUNT;
		ConfigBuffer_append(&contents, "bind %s = %s\n", mapping->name, button_labels[j]);
	}

	if (!contents.failed && save_write_atomic(path, contents.data, contents.size)) contents.failed = 1;
	free(contents.data);
	if (contents.failed) {
		LOG_error("Error writing config: %s (%s)\n", path, strerror(errno));
		return;
	}

	// Keep the active game override until its replacement console config is durable.
	if (!override && config.loaded==CONFIG_GAME && save_remove_file(game_path)) {
		LOG_error("Error removing game config: %s (%s)\n", game_path, strerror(errno));
		return;
	}
	config.loaded = override ? CONFIG_GAME : CONFIG_CONSOLE;
}
static void Config_restore(void) {
	char path[MAX_PATH];
	int remove_config = 0;
	if (config.loaded==CONFIG_GAME) {
		if (config.device_tag) sprintf(path, "%s/%s-%s.cfg", core.config_dir, game.name, config.device_tag);
		else sprintf(path, "%s/%s.cfg", core.config_dir, game.name);
		remove_config = 1;
	}
	else if (config.loaded==CONFIG_CONSOLE) {
		if (config.device_tag) sprintf(path, "%s/minarch-%s.cfg", core.config_dir, config.device_tag);
		else sprintf(path, "%s/minarch.cfg", core.config_dir);
		remove_config = 1;
	}
	if (remove_config) {
		if (save_remove_file(path)) {
			LOG_error("Error removing config: %s (%s)\n", path, strerror(errno));
			return;
		}
		LOG_info("deleted config: %s\n", path);
	}
	config.loaded = CONFIG_NONE;
	
	for (int i=0; config.frontend.options[i].key; i++) {
		Option* option = &config.frontend.options[i];
		option->value = option->default_value;
		Config_syncFrontend(option->key, option->value);
	}
	for (int i=0; config.core.options[i].key; i++) {
		Option* option = &config.core.options[i];
		option->value = option->default_value;
	}
	config.core.changed = 1; // let the core know
	
	if (has_custom_controllers) {
		gamepad_type = 0;
		Core_setController(RETRO_DEVICE_JOYPAD);
	}

	for (int i=0; config.controls[i].name; i++) {
		ButtonMapping* mapping = &config.controls[i];
		mapping->local = mapping->default_;
		mapping->mod = 0;
	}
	for (int i=0; config.shortcuts[i].name; i++) {
		ButtonMapping* mapping = &config.shortcuts[i];
		mapping->local = BTN_ID_NONE;
		mapping->mod = 0;
	}
	
	Config_load();
	Config_readOptions();
	Config_readControls();
	Config_free();
	
	renderer.dst_p = 0;
}

///////////////////////////////
static struct Special {
	int palette_updated;
} special;
static void Special_updatedDMGPalette(int frames) {
	// LOG_info("Special_updatedDMGPalette(%i)\n", frames);
	special.palette_updated = frames; // must wait a few frames
}
static void Special_refreshDMGPalette(void) {
	special.palette_updated -= 1;
	if (special.palette_updated>0) return;

	int rgb = getInt("/tmp/dmg_grid_color");
	GFX_setEffectColor(rgb);
	present_dirty_gen++; // effect-color change must reach the panel even on duplicate frames (review 6)
}
static void Special_init(void) {
	if (special.palette_updated>1) special.palette_updated = 1;
	// else if (exactMatch((char*)core.tag, "GBC"))  {
	// 	putInt("/tmp/dmg_grid_color",0xF79E);
	// 	special.palette_updated = 1;
	// }
}
static void Special_render(void) {
	if (special.palette_updated) Special_refreshDMGPalette();
}
static void Special_quit(void) {
	system("rm -f /tmp/dmg_grid_color");
}
///////////////////////////////

static  int Option_getValueIndex(Option* item, const char* value) {
	if (!value) return item->value;
	for (int i=0; i<item->count; i++) {
		if (!strcmp(item->values[i], value)) return i;
	}
	// Unknown label (hand-edited cfg or a label removed by an update): KEEP the current —
	// usually default — value instead of silently becoming index 0. For Max FF Speed index 0
	// is "None" = uncapped FF, and a locked unknown line would freeze that with no menu
	// escape (Codex v1.4-ff review #2). Applies to every option; strictly safer.
	return item->value;
}
static void Option_setValue(Option* item, const char* value) {
	// TODO: store previous value?
	item->value = Option_getValueIndex(item, value);
}

// TODO: does this also need to be applied to OptionList_vars()?
static const char* option_key_name[] = {
	"pcsx_rearmed_analog_combo", "DualShock Toggle Combo",
	NULL
};
static const char* getOptionNameFromKey(const char* key, const char* name) {
	char* _key = NULL;
	for (int i=0; (_key = (char*)option_key_name[i]); i+=2) {
		if (exactMatch((char*)key,_key)) return option_key_name[i+1];
	}
	return name;
}

// the following 3 functions always touch config.core, the rest can operate on arbitrary OptionLists
static void OptionList_init(const struct retro_core_option_definition *defs) {
	LOG_info("OptionList_init\n");
	int count;
	for (count=0; defs[count].key; count++);
	
	// LOG_info("count: %i\n", count);
	
	// TODO: add frontend options to this? so the can use the same override method? eg. minarch_*
	
	config.core.count = count;
	if (count) {
		config.core.options = calloc(count+1, sizeof(Option));
		
		for (int i=0; i<config.core.count; i++) {
			int len;
			const struct retro_core_option_definition *def = &defs[i];
			Option* item = &config.core.options[i];
			len = strlen(def->key) + 1;
		
			item->key = calloc(len, sizeof(char));
			strcpy(item->key, def->key);
			
			len = strlen(def->desc) + 1;
			item->name = calloc(len, sizeof(char));
			strcpy(item->name, getOptionNameFromKey(def->key,def->desc));
			
			if (def->info) {
				len = strlen(def->info) + 1;
				item->desc = calloc(len, sizeof(char));
				strncpy(item->desc, def->info, len);

				item->full = calloc(len, sizeof(char));
				strncpy(item->full, item->desc, len);
				// item->desc[len-1] = '\0';
				
				// these magic numbers are more about chars per line than pixel width 
				// so it's not going to be relative to the screen size, only the scale
				// what does that even mean?
				GFX_wrapText(font.tiny, item->desc, SCALE1(240), 2); // TODO magic number!
				GFX_wrapText(font.medium, item->full, SCALE1(240), 7); // TODO: magic number!
			}
		
			for (count=0; def->values[count].value; count++);
		
			item->count = count;
			item->values = calloc(count+1, sizeof(char*));
			item->labels = calloc(count+1, sizeof(char*));
	
			for (int j=0; j<count; j++) {
				const char* value = def->values[j].value;
				const char* label = def->values[j].label;
		
				len = strlen(value) + 1;
				item->values[j] = calloc(len, sizeof(char));
				strcpy(item->values[j], value);
		
				if (label) {
					len = strlen(label) + 1;
					item->labels[j] = calloc(len, sizeof(char));
					strcpy(item->labels[j], label);
				}
				else {
					item->labels[j] = item->values[j];
				}
				// printf("\t%s\n", item->labels[j]);
			}
			
			item->value = Option_getValueIndex(item, def->default_value);
			item->default_value = item->value;
			
			// LOG_info("\tINIT %s (%s) TO %s (%s)\n", item->name, item->key, item->labels[item->value], item->values[item->value]);
		}
	}
	// fflush(stdout);
}
static void OptionList_vars(const struct retro_variable *vars) {
	LOG_info("OptionList_vars\n");
	int count;
	for (count=0; vars[count].key; count++);
	
	config.core.count = count;
	if (count) {
		config.core.options = calloc(count+1, sizeof(Option));
	
		for (int i=0; i<config.core.count; i++) {
			int len;
			const struct retro_variable *var = &vars[i];
			Option* item = &config.core.options[i];

			len = strlen(var->key) + 1;
			item->key = calloc(len, sizeof(char));
			strcpy(item->key, var->key);
			
			len = strlen(var->value) + 1;
			item->var = calloc(len, sizeof(char));
			strcpy(item->var, var->value);
			
			char* tmp = strchr(item->var, ';');
			if (tmp && *(tmp+1)==' ') {
				*tmp = '\0';
				item->name = item->var;
				tmp += 2;
			}
			
			char* opt = tmp;
			for (count=0; (tmp=strchr(tmp, '|')); tmp++, count++);
			count += 1; // last entry after final '|'
		
			item->count = count;
			item->values = calloc(count+1, sizeof(char*));
			item->labels = calloc(count+1, sizeof(char*));

			tmp = opt;
			int j;
			for (j=0; (tmp=strchr(tmp, '|')); j++) {
				item->values[j] = opt;
				item->labels[j] = opt;
				*tmp = '\0';
				tmp += 1;
				opt = tmp; 
			}
			item->values[j] = opt;
			item->labels[j] = opt;
			
			// no native default_value support for retro vars
			item->value = 0;
			item->default_value = item->value;
			// printf("SET %s to %s (%i)\n", item->key, default_value, item->value); fflush(stdout);
		}
	}
	// fflush(stdout);
}
static void OptionList_reset(void) {
	if (!config.core.count) return;
	
	for (int i=0; i<config.core.count; i++) {
		Option* item = &config.core.options[i];
		if (item->var) {
			// values/labels are all points to var
			// so no need to free individually
			free(item->var);
		}
		else {
			if (item->desc) free(item->desc);
			if (item->full) free(item->full);
			for (int j=0; j<item->count; j++) {
				char* value = item->values[j];
				char* label = item->labels[j];
				if (label!=value) free(label);
				free(value);
			}
		}
		free(item->values);
		free(item->labels);
		free(item->key);
		free(item->name);
	}
	if (config.core.enabled_options) free(config.core.enabled_options);
	config.core.enabled_count = 0;
	free(config.core.options);
}

static Option* OptionList_getOption(OptionList* list, const char* key) {
	for (int i=0; i<list->count; i++) {
		Option* item = &list->options[i];
		if (!strcmp(item->key, key)) return item;
	}
	return NULL;
}
static char* OptionList_getOptionValue(OptionList* list, const char* key) {
	Option* item = OptionList_getOption(list, key);
	// if (item) LOG_info("\tGET %s (%s) = %s (%s)\n", item->name, item->key, item->labels[item->value], item->values[item->value]);
	
	if (item) return item->values[item->value];
	else LOG_warn("unknown option %s \n", key);
	return NULL;
}
static void OptionList_setOptionRawValue(OptionList* list, const char* key, int value) {
	Option* item = OptionList_getOption(list, key);
	if (item) {
		item->value = value;
		list->changed = 1;
		// LOG_info("\tRAW SET %s (%s) TO %s (%s)\n", item->name, item->key, item->labels[item->value], item->values[item->value]);
		// if (list->on_set) list->on_set(list, key);

		if (exactMatch((char*)core.tag, "GB") && containsString(item->key, "palette")) Special_updatedDMGPalette(3); // from options
	}
	else LOG_info("unknown option %s \n", key);
}
static void OptionList_setOptionValue(OptionList* list, const char* key, const char* value) {
	Option* item = OptionList_getOption(list, key);
	if (item) {
		Option_setValue(item, value);
		list->changed = 1;
		// LOG_info("\tSET %s (%s) TO %s (%s)\n", item->name, item->key, item->labels[item->value], item->values[item->value]);
		// if (list->on_set) list->on_set(list, key);
		
		if (exactMatch((char*)core.tag, "GB") && containsString(item->key, "palette")) Special_updatedDMGPalette(2); // from core
	}
	else LOG_info("unknown option %s \n", key);
}
// static void OptionList_setOptionVisibility(OptionList* list, const char* key, int visible) {
// 	Option* item = OptionList_getOption(list, key);
// 	if (item) item->visible = visible;
// 	else printf("unknown option %s \n", key); fflush(stdout);
// }

///////////////////////////////

static void Menu_beforeSleep(void);
static void Menu_afterSleep(void);

static int Menu_saveState(void);
static int Menu_loadState(void);
void Core_reset(void);

static int setFastForward(int enable) {
	int changed = (fast_forward != enable);
	// Depth two may already have CORE inside core.run/audio while MAIN handles this input.
	// Land the FF control and resampler transition at an epoch boundary so the next grant's
	// snapshot and the audio mode change together. Serial/menu-held paths are no-ops here.
	int ftv2_parked = changed ? zero_ftv2_core_enter() : 0;
	{ // ZERO_GOV_DEBUG: trace every FF transition + caller context (FF-busted hunt 2026-07-10)
		static int zfd = -1;
		if (zfd < 0) { const char* e = getenv("ZERO_GOV_DEBUG"); zfd = (e && e[0] && e[0] != '0') ? 1 : 0; }
		if (zfd && fast_forward != enable)
			LOG_info("ff-trace: %d -> %d (thread_video=%d was_threaded=%d)\n", fast_forward, enable, thread_video, was_threaded);
	}
	if (!fast_forward && enable && thread_video) {
		// LOG_info("entered fast forward with threaded core...\n");
		was_threaded = 1;
		toggle_thread = 1;
	}
	else if (fast_forward && !enable && !thread_video && was_threaded) {
		// LOG_info("exited fast forward with previously threaded core...\n");
		was_threaded = 0;
		toggle_thread = 1;
	}
	fast_forward = enable;
	// FF entry/exit is a WORKLOAD change — burst the governor like a scene change (device
	// finding, 2026-07-17): during a long capped-FF session the convergence probes repeatedly
	// fail the step below the FF floor and ESCALATE fail-memory (60s->2m->4m). That memory is
	// only valid for the FF workload; without this burst it kept 1x play pinned at the FF
	// clock for minutes after FF ended (Dr. Mario stuck at 1008 for 85s+, fresh session
	// descended normally). Burst clears fail/futile state and re-finds the floor honestly
	// in either direction.
	if (changed && gov_active) gov_scene_burst("ff toggle", 1);
	// PS1's presentation-drop catch-up protects normal-play audio, but deliberately
	// outrunning presentation during FF must not be mistaken for a delivery underrun.
	if (changed && presentation_drop_supported) GFX_setPresentationDrop(!enable);
	// Match the audio reduction to the speed the core actually achieves. Ring-full writes
	// remain non-blocking so audio can never throttle fast-forward back toward real time.
	SND_setFastForward(enable, ff_audio);
	zero_ftv2_core_leave(ftv2_parked);
	return enable;
}

static uint32_t buttons = 0; // RETRO_DEVICE_ID_JOYPAD_* buttons
static int ignore_menu = 0;

// Depth-2 MAIN-side core entry (sleep autosave, Save/Load/Reset shortcuts). At depth-2 the
// CORE thread may be mid core.run() when MAIN touches core state (serialize/unserialize/reset/SRAM);
// park it first so the op can't corrupt state. fr_park is NOT counted, so park+release ONLY when the
// ring is actually RUNNING — a menu-context caller already parked (ring QUIESCENT) and an unbalanced
// release would unpark it mid-menu. Depth-1 / guard-OFF: no-op (no CORE thread; serial already safe).
#ifdef ZERO_FRONTEND_THREADING_V2
static void zero_ftv2_drain(void* ctx, const fr_event* ev); // defined near the run loop; used by the park helper
#endif
static int zero_ftv2_core_enter(void) {
#ifdef ZERO_FRONTEND_THREADING_V2
	if (zero_ftv2_inited && fc_current_phase() == FCP_NONE) {
		pthread_mutex_lock(&zero_ftv2.fr.lk);
		fr_state state = fr_get_state(&zero_ftv2.fr);
		int owns_park = state == FR_RUNNING
		              || atomic_load_explicit(&zero_ftv2.fr.release_req, memory_order_acquire);
		pthread_mutex_unlock(&zero_ftv2.fr.lk);
		if (!owns_park) return 0; // already held by the outer menu/sleep transaction
		fc_park(&zero_ftv2, zero_ftv2_drain, NULL, 0);
		return 1;
	}
#endif
	return 0;
}
static void zero_ftv2_core_leave(int parked) {
#ifdef ZERO_FRONTEND_THREADING_V2
	if (parked) fc_release(&zero_ftv2);
#else
	(void)parked;
#endif
}

// The per-frame input tick: poll hardware, handle power/menu/FF/shortcuts, compute `buttons`.
// On the plain path this runs from the libretro input_poll callback. At depth-2 it runs on
// MAIN before a grant; core entries below route through the parked service channel.
static void input_tick(void) {
	PAD_poll();

	// devmode screenshot: MENU+SELECT chord (or the /tmp trigger). No-op without a devmode flag.
	GFX_maybeScreenshot(PAD_isPressed(BTN_MENU) && PAD_justPressed(BTN_SELECT));

	int show_setting = 0;
	PWR_update(NULL, &show_setting, Menu_beforeSleep, Menu_afterSleep);

	// I _think_ this can stay as is...
	if (PAD_justPressed(BTN_MENU)) {
		ignore_menu = 0;
	}
	if (PAD_isPressed(BTN_MENU) && (PAD_isPressed(BTN_PLUS) || PAD_isPressed(BTN_MINUS))) {
		ignore_menu = 1;
	}
	
	if (PAD_justPressed(BTN_POWER)) {
		if (thread_video) {
			// LOG_info("pressed power with threaded core...\n");
			was_threaded = 1;
			toggle_thread = 1;
		}
	}
	else if (PAD_justReleased(BTN_POWER)) {
		if (!thread_video && was_threaded) {
			// LOG_info("released power with previously threaded core before power off...\n");
			was_threaded = 0;
			toggle_thread = 1;
		}
	}
	
	static int toggled_ff_on = 0; // this logic only works because TOGGLE_FF is before HOLD_FF in the menu...
	for (int i=0; i<SHORTCUT_COUNT; i++) {
		ButtonMapping* mapping = &config.shortcuts[i];
		if (mapping->local < 0) continue; // not bound (1 << -1 is UB)
		int btn = 1 << mapping->local;
		if (btn==BTN_NONE) continue; // not bound
		if (!mapping->mod || PAD_isPressed(BTN_MENU)) {
			if (i==SHORTCUT_TOGGLE_FF) {
				if (PAD_justPressed(btn)) {
					toggled_ff_on = setFastForward(!fast_forward);
					if (mapping->mod) ignore_menu = 1;
					break;
				}
				else if (PAD_justReleased(btn)) {
					if (mapping->mod) ignore_menu = 1;
					break;
				}
			}
			else if (i==SHORTCUT_HOLD_FF) {
				// don't allow turn off fast_forward with a release of the hold button
				// if it was initially turned on with the toggle button
				if (PAD_justPressed(btn) || (!toggled_ff_on && PAD_justReleased(btn))) {
					{ static int zfd2 = -1;
					  if (zfd2 < 0) { const char* e = getenv("ZERO_GOV_DEBUG"); zfd2 = (e && e[0] && e[0] != '0') ? 1 : 0; }
					  if (zfd2) LOG_info("ff-trace: HOLD branch fired (btn=0x%x jp=%d jr=%d ip=%d toggled=%d)\n",
					      btn, PAD_justPressed(btn), PAD_justReleased(btn), PAD_isPressed(btn), toggled_ff_on); }
					fast_forward = setFastForward(PAD_isPressed(btn));
					if (mapping->mod) ignore_menu = 1; // very unlikely but just in case
				}
			}
			else if (PAD_justPressed(btn)) {
				switch (i) {
					case SHORTCUT_SAVE_STATE: Menu_saveState(); break;
					case SHORTCUT_LOAD_STATE: Menu_loadState(); break;
					case SHORTCUT_RESET_GAME: Core_reset(); break;
					case SHORTCUT_SAVE_QUIT:
						if (Menu_saveState()) quit = 1;
						break;
					case SHORTCUT_CYCLE_SCALE:
						screen_scaling += 1;
						int count = config.frontend.options[FE_OPT_SCALING].count;
						if (screen_scaling>=count) screen_scaling -= count;
						Config_syncFrontend(config.frontend.options[FE_OPT_SCALING].key, screen_scaling);
						break;
					case SHORTCUT_CYCLE_EFFECT:
						screen_effect += 1;
						if (screen_effect>=EFFECT_COUNT) screen_effect -= EFFECT_COUNT;
						Config_syncFrontend(config.frontend.options[FE_OPT_EFFECT].key, screen_effect);
						break;
					case SHORTCUT_TOGGLE_HUD:
						show_debug = !show_debug;
						Config_syncFrontend(config.frontend.options[FE_OPT_DEBUG].key, show_debug);
						break;
					default: break;
				}
				
				if (mapping->mod) ignore_menu = 1;
			}
		}
	}
	
	if (!ignore_menu && PAD_justReleased(BTN_MENU)) {
		show_menu = 1;
		
		if (thread_video) {
			pthread_mutex_lock(&core_mx);
			should_run_core = 0;
			pthread_mutex_unlock(&core_mx);
			// NOTE: no park-wait here — this code runs on the CORE thread (input_poll
			// is called from core.run). The main thread waits before Menu_loop instead.
		}
	}
	
	// TODO: figure out how to ignore button when MENU+button is handled first
	// TODO: array size of LOCAL_ whatever that macro is
	// TODO: then split it into two loops
	// TODO: first check for MENU+button
	// TODO: when found mark button the array
	// TODO: then check for button
	// TODO: only modify if absent from array
	// TODO: the shortcuts loop above should also contribute to the array
	
	buttons = 0;
	for (int i=0; config.controls[i].name; i++) {
		ButtonMapping* mapping = &config.controls[i];
		int btn = 1 << mapping->local;
		if (btn==BTN_NONE) continue; // present buttons can still be unbound
		if (gamepad_type==0) {
			switch(btn) {
				case BTN_DPAD_UP: 		btn = BTN_UP; break;
				case BTN_DPAD_DOWN: 	btn = BTN_DOWN; break;
				case BTN_DPAD_LEFT: 	btn = BTN_LEFT; break;
				case BTN_DPAD_RIGHT: 	btn = BTN_RIGHT; break;
			}
		}
		if (PAD_isPressed(btn) && (!mapping->mod || PAD_isPressed(BTN_MENU))) {
			buttons |= 1 << mapping->retro;
			if (mapping->mod) ignore_menu = 1;
		}
		//  && !PWR_ignoreSettingInput(btn, show_setting)
	}
	
	// if (buttons) LOG_info("buttons: %i\n", buttons);
}

// The libretro input_poll callback. At depth-2 MAIN already ran input_tick before the grant, so
// this is a no-op and the epoch reads its immutable snapshot. The plain path polls inline.
static void input_poll_callback(void) {
#ifdef ZERO_FRONTEND_THREADING_V2
	if (zero_ftv2_inited && zero_ftv2_depth2 && fc_current_phase() != FCP_NONE) return;
#endif
	input_tick();
}
static int16_t input_state_callback(unsigned port, unsigned device, unsigned index, unsigned id) {
#ifdef ZERO_FRONTEND_THREADING_V2
	// WP-A: at depth-2 the core reads THIS epoch's immutable input snapshot (packed by MAIN into
	// snap, delivered via run() -> zero_ftv2_isnap) rather than the live globals racing MAIN.
	if (zero_ftv2_inited && zero_ftv2_depth2 && fc_current_phase() != FCP_NONE) {
		uint32_t b = (uint32_t)zero_ftv2_isnap[0];
		if (port==0 && device==RETRO_DEVICE_JOYPAD && index==0) {
			if (id == RETRO_DEVICE_ID_JOYPAD_MASK) return (int16_t)b;
			return (b >> id) & 1;
		}
		if (port==0 && device==RETRO_DEVICE_ANALOG) {
			int16_t lx=(int16_t)(zero_ftv2_isnap[1]>>16), ly=(int16_t)(uint16_t)zero_ftv2_isnap[1];
			int16_t rx=(int16_t)(zero_ftv2_isnap[2]>>16), ry=(int16_t)(uint16_t)zero_ftv2_isnap[2];
			if (index==RETRO_DEVICE_INDEX_ANALOG_LEFT)  { if(id==RETRO_DEVICE_ID_ANALOG_X) return lx; if(id==RETRO_DEVICE_ID_ANALOG_Y) return ly; }
			if (index==RETRO_DEVICE_INDEX_ANALOG_RIGHT) { if(id==RETRO_DEVICE_ID_ANALOG_X) return rx; if(id==RETRO_DEVICE_ID_ANALOG_Y) return ry; }
		}
		return 0;
	}
#endif
	if (port==0 && device==RETRO_DEVICE_JOYPAD && index==0) {
		if (id == RETRO_DEVICE_ID_JOYPAD_MASK) return buttons;
		return (buttons >> id) & 1;
	}
	else if (port==0 && device==RETRO_DEVICE_ANALOG) {
		if (index==RETRO_DEVICE_INDEX_ANALOG_LEFT) {
			if (id==RETRO_DEVICE_ID_ANALOG_X) return pad.laxis.x;
			else if (id==RETRO_DEVICE_ID_ANALOG_Y) return pad.laxis.y;
		}
		else if (index==RETRO_DEVICE_INDEX_ANALOG_RIGHT) {
			if (id==RETRO_DEVICE_ID_ANALOG_X) return pad.raxis.x;
			else if (id==RETRO_DEVICE_ID_ANALOG_Y) return pad.raxis.y;
		}
	}
	return 0;
}
///////////////////////////////

static void Input_init(const struct retro_input_descriptor *vars) {
	static int input_initialized = 0;
	if (input_initialized) return;

	LOG_info("Input_init\n");
	
	config.controls = core_button_mapping[0].name ? core_button_mapping : default_button_mapping;
	
	puts("---------------------------------");

	const char* core_button_names[RETRO_BUTTON_COUNT] = {0};
	int present[RETRO_BUTTON_COUNT] = {0};
	int core_mapped = 0;
	if (vars) {
		core_mapped = 1;
		// identify buttons available in this core
		for (int i=0; vars[i].description; i++) {
			const struct retro_input_descriptor* var = &vars[i];
			if (var->port!=0 || var->device!=RETRO_DEVICE_JOYPAD || var->index!=0) continue;

			// TODO: don't ignore unavailable buttons, just override them to BTN_ID_NONE!
			if (var->id>=RETRO_BUTTON_COUNT) {
				printf("UNAVAILABLE: %s\n", var->description); fflush(stdout);
				continue;
			}
			else {
				printf("PRESENT    : %s\n", var->description); fflush(stdout);
			}
			present[var->id] = 1;
			core_button_names[var->id] = var->description;
		}
	}
	
	puts("---------------------------------");

	for (int i=0;default_button_mapping[i].name; i++) {
		ButtonMapping* mapping = &default_button_mapping[i];
		LOG_info("DEFAULT %s (%s): <%s>\n", core_button_names[mapping->retro], mapping->name, (mapping->local==BTN_ID_NONE ? "NONE" : device_button_names[mapping->local]));
		if (core_button_names[mapping->retro]) mapping->name = (char*)core_button_names[mapping->retro];
	}
	
	puts("---------------------------------");

	for (int i=0; config.controls[i].name; i++) {
		ButtonMapping* mapping = &config.controls[i];
		mapping->default_ = mapping->local;

		// ignore mappings that aren't available in this core
		if (core_mapped && !present[mapping->retro]) {
			mapping->ignore = 1;
			continue;
		}
		LOG_info("%s: <%s> (%i:%i)\n", mapping->name, (mapping->local==BTN_ID_NONE ? "NONE" : device_button_names[mapping->local]), mapping->local, mapping->retro);
	}
	
	puts("---------------------------------");
	input_initialized = 1;
}

static bool set_rumble_state(unsigned port, enum retro_rumble_effect effect, uint16_t strength) {
	// TODO: handle other args? not sure I can
#ifdef ZERO_FRONTEND_THREADING_V2
	// Keep the physical effect ordered with this epoch's frame. The event is persistent:
	// a menu/sleep park may discard visuals, but it must still converge the motor state.
	if (zero_ftv2_inited && zero_ftv2_depth2 && fc_current_phase() != FCP_NONE)
		return fc_emit_cmd(&zero_ftv2, FR_EVF_PERSISTENT,
		                   zero_cmd_pack(ZERO_CMD_RUMBLE, (float)strength)) != FR_DROPPED;
#endif
	VIB_setStrength(strength);
	return 1;
}
static bool environment_callback(unsigned cmd, void *data) { // copied from picoarch initially
	// LOG_info("environment_callback: %i\n", cmd);
	
	switch(cmd) {
	// case RETRO_ENVIRONMENT_SET_ROTATION: { /* 1 */
	// 	LOG_info("RETRO_ENVIRONMENT_SET_ROTATION %i\n", *(int *)data); // core requests frontend to handle rotation
	// 	break;
	// }
	case RETRO_ENVIRONMENT_GET_OVERSCAN: { /* 2 */
		bool *out = (bool *)data;
		if (out)
			*out = true;
		break;
	}
	case RETRO_ENVIRONMENT_GET_CAN_DUPE: { /* 3 */
		bool *out = (bool *)data;
		if (out)
			*out = true;
		break;
	}
	case RETRO_ENVIRONMENT_SET_MESSAGE: { /* 6 */
		const struct retro_message *message = (const struct retro_message*)data;
		if (message) LOG_info("%s\n", message->msg);
		break;
	}
	case RETRO_ENVIRONMENT_SHUTDOWN: { /* 7 */
		// core-initiated shutdown (in-game quit menus: PRBoom, PICO-8, ...). Stock had no
		// handler, so the request was dropped and the game appeared to hang. (idea: NextUI #699)
		quit = 1;
		break;
	}
	case RETRO_ENVIRONMENT_SET_PERFORMANCE_LEVEL: { /* 8 */
		// puts("RETRO_ENVIRONMENT_SET_PERFORMANCE_LEVEL");
		// TODO: used by fceumm at least
		break;
	}
	case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY: { /* 9 */
		const char **out = (const char **)data;
		if (out) {
			*out = core.bios_dir;
		}
		break;
	}
	case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT: { /* 10 */
		const enum retro_pixel_format *format = (enum retro_pixel_format *)data;

		if (*format != RETRO_PIXEL_FORMAT_RGB565) { // TODO: pull from platform.h?
			/* 565 is only supported format */
			return false;
			// downsample = 1; // TODO: not ready for primetime yet
		}
		break;
	}
	case RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS: { /* 11 */
		// puts("RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS\n");
		Input_init((const struct retro_input_descriptor *)data);
		return false;
	} break;
	case RETRO_ENVIRONMENT_SET_DISK_CONTROL_INTERFACE: { /* 13 */
		const struct retro_disk_control_callback *var =
			(const struct retro_disk_control_callback *)data;

		if (var) {
			memset(&disk_control_ext, 0, sizeof(struct retro_disk_control_ext_callback));
			memcpy(&disk_control_ext, var, sizeof(struct retro_disk_control_callback));
		}
		break;
	}

	// TODO: this is called whether using variables or options
	case RETRO_ENVIRONMENT_GET_VARIABLE: { /* 15 */
		// puts("RETRO_ENVIRONMENT_GET_VARIABLE ");
		struct retro_variable *var = (struct retro_variable *)data;
		if (var && var->key) {
			var->value = OptionList_getOptionValue(&config.core, var->key);
			// printf("\t%s = %s\n", var->key, var->value);
		}
		// fflush(stdout);
		break;
	}
	// TODO: I think this is where the core reports its variables (the precursor to options)
	// TODO: this is called if RETRO_ENVIRONMENT_GET_CORE_OPTIONS_VERSION sets out to 0
	// TODO: not used by anything yet
	case RETRO_ENVIRONMENT_SET_VARIABLES: { /* 16 */
		// puts("RETRO_ENVIRONMENT_SET_VARIABLES");
		const struct retro_variable *vars = (const struct retro_variable *)data;
		if (vars) {
			OptionList_reset();
			OptionList_vars(vars);
		}
		break;
	}
	case RETRO_ENVIRONMENT_SET_SUPPORT_NO_GAME: { /* 18 */
		bool flag = *(bool*)data;
		// LOG_info("%i: RETRO_ENVIRONMENT_SET_SUPPORT_NO_GAME: %i\n", cmd, flag);
		break;
	}
	case RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE: { /* 17 */
		bool *out = (bool *)data;
		if (out) {
			*out = config.core.changed;
			config.core.changed = 0;
		}
		break;
	}
	case RETRO_ENVIRONMENT_SET_FRAME_TIME_CALLBACK: { /* 21 */
		// LOG_info("%i: RETRO_ENVIRONMENT_SET_FRAME_TIME_CALLBACK\n", cmd);
		// MinArch does not retain or invoke this callback. Claiming support makes the core
		// switch to a timing path the frontend never services.
		return false;
	}
	case RETRO_ENVIRONMENT_SET_AUDIO_CALLBACK: { /* 22 */
		// LOG_info("%i: RETRO_ENVIRONMENT_SET_AUDIO_CALLBACK\n", cmd);
		// Audio is driven synchronously from retro_run through the sample callbacks.
		// Returning true here would advertise an asynchronous callback we never invoke.
		return false;
	}
	case RETRO_ENVIRONMENT_GET_RUMBLE_INTERFACE: { /* 23 */
	        struct retro_rumble_interface *iface = (struct retro_rumble_interface*)data;

	        // LOG_info("Setup rumble interface.\n");
	        iface->set_rumble_state = set_rumble_state;
		break;
	}
	case RETRO_ENVIRONMENT_GET_INPUT_DEVICE_CAPABILITIES: {
		unsigned *out = (unsigned *)data;
		if (out)
			*out = (1 << RETRO_DEVICE_JOYPAD) | (1 << RETRO_DEVICE_ANALOG);
		break;
	}
	case RETRO_ENVIRONMENT_GET_LOG_INTERFACE: { /* 27 */
		struct retro_log_callback *log_cb = (struct retro_log_callback *)data;
		if (log_cb)
			log_cb->log = (void (*)(enum retro_log_level, const char*, ...))LOG_note; // same difference
		break;
	}
	case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY: { /* 31 */
		const char **out = (const char **)data;
		if (out)
			*out = core.saves_dir; // save_dir;
		break;
	}
	case RETRO_ENVIRONMENT_SET_CONTROLLER_INFO: { /* 35 */
		// LOG_info("RETRO_ENVIRONMENT_SET_CONTROLLER_INFO\n");
		const struct retro_controller_info *infos = (const struct retro_controller_info *)data;
		if (infos) {
			// TODO: store to gamepad_values/gamepad_labels for gamepad_device
			const struct retro_controller_info *info = &infos[0];
			for (int i=0; i<info->num_types; i++) {
				const struct retro_controller_description *type = &info->types[i];
				if (exactMatch((char*)type->desc,"dualshock")) { // currently only enabled for PlayStation
					has_custom_controllers = 1;
					break;
				}
				// printf("\t%i: %s\n", type->id, type->desc);
			}
		}
		fflush(stdout);
		return false; // TODO: tmp
		break;
	}
	// RETRO_ENVIRONMENT_SET_MEMORY_MAPS (36 | RETRO_ENVIRONMENT_EXPERIMENTAL)
	// RETRO_ENVIRONMENT_GET_LANGUAGE 39
	case RETRO_ENVIRONMENT_GET_CURRENT_SOFTWARE_FRAMEBUFFER: { /* (40 | RETRO_ENVIRONMENT_EXPERIMENTAL) */
		// v1.4 audit fix: this stub fell through to `return true` with the retro_framebuffer
		// UNFILLED — claiming support while handing the core garbage. Cores only survived it
		// because they zero-init the struct and format 0 fails their own check (pcsx/fceumm/
		// pce_fast all verified). Decline honestly; the core uses its own buffer.
		return false;
	}
	
	case RETRO_ENVIRONMENT_GET_AUDIO_VIDEO_ENABLE: {
		// fixes fbneo save state graphics corruption
		// puts("RETRO_ENVIRONMENT_GET_AUDIO_VIDEO_ENABLE");
		int *out_p = (int *)data;
		if (out_p) {
			int out = 0;
			out |= RETRO_AV_ENABLE_VIDEO;
			out |= RETRO_AV_ENABLE_AUDIO;
			*out_p = out;
		}
		break;
	}
	
	// RETRO_ENVIRONMENT_SET_SUPPORT_ACHIEVEMENTS (42 | RETRO_ENVIRONMENT_EXPERIMENTAL)
	// RETRO_ENVIRONMENT_GET_VFS_INTERFACE (45 | RETRO_ENVIRONMENT_EXPERIMENTAL)
	// RETRO_ENVIRONMENT_GET_AUDIO_VIDEO_ENABLE (47 | RETRO_ENVIRONMENT_EXPERIMENTAL)
	// RETRO_ENVIRONMENT_GET_INPUT_BITMASKS (51 | RETRO_ENVIRONMENT_EXPERIMENTAL)
	case RETRO_ENVIRONMENT_GET_INPUT_BITMASKS: { /* 51 | RETRO_ENVIRONMENT_EXPERIMENTAL */
		bool *out = (bool *)data;
		if (out)
			*out = true;
		break;
	}
	case RETRO_ENVIRONMENT_GET_CORE_OPTIONS_VERSION: { /* 52 */
		// puts("RETRO_ENVIRONMENT_GET_CORE_OPTIONS_VERSION");
		unsigned *out = (unsigned *)data;
		if (out)
			*out = 1;
		break;
	}
	case RETRO_ENVIRONMENT_SET_CORE_OPTIONS: { /* 53 */
		// puts("RETRO_ENVIRONMENT_SET_CORE_OPTIONS");
		if (data) {
			OptionList_reset();
			OptionList_init((const struct retro_core_option_definition *)data); 
		}
		break;
	}
	case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_INTL: { /* 54 */
		// puts("RETRO_ENVIRONMENT_SET_CORE_OPTIONS_INTL");
		const struct retro_core_options_intl *options = (const struct retro_core_options_intl *)data;
		if (options && options->us) {
			OptionList_reset();
			OptionList_init(options->us);
		}
		break;
	}
	case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_DISPLAY: { /* 55 */
		// puts("RETRO_ENVIRONMENT_SET_CORE_OPTIONS_DISPLAY");
		// const struct retro_core_option_display *display = (const struct retro_core_option_display *)data;
	// 	if (display) OptionList_setOptionVisibility(&config.core, display->key, display->visible);
		break;
	}
	case RETRO_ENVIRONMENT_GET_DISK_CONTROL_INTERFACE_VERSION: { /* 57 */
		unsigned *out =	(unsigned *)data;
		if (out) *out = 1;
		break;
	}
	case RETRO_ENVIRONMENT_SET_DISK_CONTROL_EXT_INTERFACE: { /* 58 */
		const struct retro_disk_control_ext_callback *var =
			(const struct retro_disk_control_ext_callback *)data;

		if (var) {
			memcpy(&disk_control_ext, var, sizeof(struct retro_disk_control_ext_callback));
		}
		break;
	}
	// TODO: RETRO_ENVIRONMENT_GET_MESSAGE_INTERFACE_VERSION 59
	// TODO: used by mgba, (but only during frameskip?)
	// case RETRO_ENVIRONMENT_SET_AUDIO_BUFFER_STATUS_CALLBACK: { /* 62 */
	// 	LOG_info("RETRO_ENVIRONMENT_SET_AUDIO_BUFFER_STATUS_CALLBACK\n");
	// 	const struct retro_audio_buffer_status_callback *cb = (const struct retro_audio_buffer_status_callback *)data;
	// 	if (cb) {
	// 		LOG_info("has audo_buffer_status callback\n");
	// 		core.audio_buffer_status = cb->callback;
	// 	} else {
	// 		LOG_info("no audo_buffer_status callback\n");
	// 		core.audio_buffer_status = NULL;
	// 	}
	// 	break;
	// }
	// TODO: used by mgba, (but only during frameskip?)
	// case RETRO_ENVIRONMENT_SET_MINIMUM_AUDIO_LATENCY: { /* 63 */
	// 	LOG_info("RETRO_ENVIRONMENT_SET_MINIMUM_AUDIO_LATENCY\n");
	//
	// 	const unsigned *latency_ms = (const unsigned *)data;
	// 	if (latency_ms) {
	// 		unsigned frames = *latency_ms * core.fps / 1000;
	// 		if (frames < 30)
	// 			// audio_buffer_size_override = frames;
	// 			LOG_info("audio_buffer_size_override = %i (unused?)\n", frames);
	// 		else
	// 			LOG_info("Audio buffer change out of range (%d), ignored\n", frames);
	// 	}
	// 	break;
	// }

	// TODO: RETRO_ENVIRONMENT_SET_FASTFORWARDING_OVERRIDE 64
	case RETRO_ENVIRONMENT_SET_CONTENT_INFO_OVERRIDE: { /* 65 */
		// const struct retro_system_content_info_override* info = (const struct retro_system_content_info_override* )data;
		// if (info) LOG_info("has overrides");
		break;
	}
	// RETRO_ENVIRONMENT_GET_GAME_INFO_EXT 66
	// TODO: RETRO_ENVIRONMENT_SET_CORE_OPTIONS_UPDATE_DISPLAY_CALLBACK 69
	// used by fceumm
	// TODO: used by gambatte for L/R palette switching (seems like it needs to return true even if data is NULL to indicate support)
	case RETRO_ENVIRONMENT_SET_VARIABLE: {
		// puts("RETRO_ENVIRONMENT_SET_VARIABLE");
		const struct retro_variable *var = (const struct retro_variable *)data;
		if (var && var->key) {
			// printf("\t%s = %s\n", var->key, var->value);
			OptionList_setOptionValue(&config.core, var->key, var->value);
			break;
		}

		int *out = (int *)data;
		if (out) *out = 1;
		
		break;
	}
	
	// unused
	// case RETRO_ENVIRONMENT_SET_FRAME_TIME_CALLBACK: {
	// 	puts("RETRO_ENVIRONMENT_SET_FRAME_TIME_CALLBACK"); fflush(stdout);
	// 	break;
	// }
	// case RETRO_ENVIRONMENT_GET_THROTTLE_STATE: {
	// 	puts("RETRO_ENVIRONMENT_GET_THROTTLE_STATE"); fflush(stdout);
	// 	break;
	// }
	// case RETRO_ENVIRONMENT_GET_FASTFORWARDING: {
	// 	puts("RETRO_ENVIRONMENT_GET_FASTFORWARDING"); fflush(stdout);
	// 	break;
	// };
	
	case RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO: { /* 32 */
		// A core changed its timing/geometry mid-run (PAL/NTSC toggle, some arcade cores). Stock let
		// this fall through to `return false`, telling the core the frontend rejected the change, which
		// desyncs frame pacing + the scaler. Re-read the fields and reset dst_p so the scaler re-inits
		// on the next frame. (When sent during load — before SND_init — the updated sample_rate/fps
		// flow into SND_init automatically; a post-audio-init rate change is rare and would still need
		// an SND re-init, left for if a real core needs it.)
		const struct retro_system_av_info *info = (const struct retro_system_av_info *)data;
		if (info) {
			double a = info->geometry.aspect_ratio;
			if (a<=0) a = (double)info->geometry.base_width / info->geometry.base_height;
#ifdef ZERO_FRONTEND_THREADING_V2
			// Codex #3: at depth-2 this arrives ON THE CORE THREAD mid-epoch; writing the shared
			// fields here races MAIN's in-flight present (torn double, lost scaler reset). Route
			// through FR_EV_CMD — never dropped, applied by the drain on MAIN in global order
			// against the frames, so the new geometry lands BEFORE the frame that uses it.
			if (zero_ftv2_inited && zero_ftv2_depth2 && fc_current_phase() != FCP_NONE) {
				fc_emit_cmd(&zero_ftv2, FR_EVF_PERSISTENT, zero_cmd_pack(ZERO_CMD_FPS,   (float)info->timing.fps));
				fc_emit_cmd(&zero_ftv2, FR_EVF_PERSISTENT, zero_cmd_pack(ZERO_CMD_SRATE, (float)info->timing.sample_rate));
				// AV/timing changes are synchronous in libretro: applying the final command as a
				// barrier guarantees MAIN has consumed the entire ordered update before CORE
				// continues producing audio or frames under the new timing.
				fc_emit_barrier(&zero_ftv2, zero_cmd_pack(ZERO_CMD_ASPECT, (float)a));
				break;
			}
#endif
			core.fps = info->timing.fps;
			core.sample_rate = info->timing.sample_rate;
			core.aspect_ratio = a;
			renderer.dst_p = 0; // force selectScaler() on the next frame (see :2837)
			// Timing moved, so the rate match derived from the OLD fps is now wrong (a region
			// switch is the real case). Serial path only — under threading v2 this callback runs
			// on CORE, and the drain below re-applies it on MAIN after the barrier instead.
			Zero_applyRateMatch();
		}
		break;
	}
	case RETRO_ENVIRONMENT_SET_GEOMETRY: { /* 37 */
		// Geometry-only change (aspect / base size), no timing change. Re-read aspect + reset dst_p
		// so the scaler re-syncs; stock rejected it.
		const struct retro_game_geometry *geom = (const struct retro_game_geometry *)data;
		if (geom) {
			double a = geom->aspect_ratio;
			if (a<=0) a = (double)geom->base_width / geom->base_height;
#ifdef ZERO_FRONTEND_THREADING_V2
			// Codex #3: pcsx fires this on every PS1 resolution switch — on the CORE thread at
			// depth-2. Ordered-command routing (see SET_SYSTEM_AV_INFO above for the rationale).
			if (zero_ftv2_inited && zero_ftv2_depth2 && fc_current_phase() != FCP_NONE) {
				fc_emit_cmd(&zero_ftv2, FR_EVF_PERSISTENT, zero_cmd_pack(ZERO_CMD_ASPECT, (float)a));
				break;
			}
#endif
			core.aspect_ratio = a;
			renderer.dst_p = 0;
		}
		break;
	}

	default:
		// LOG_debug("Unsupported environment cmd: %u\n", cmd);
		return false;
	}
	return true;
}

///////////////////////////////

static void hdmimon(void) {
	// handle HDMI change
	static int had_hdmi = -1;
	int has_hdmi = GetHDMI();
	if (had_hdmi==-1) had_hdmi = has_hdmi;
	if (has_hdmi!=had_hdmi) {
		had_hdmi = has_hdmi;

		LOG_info("restarting after HDMI change...\n");
		park_core("hdmi restart"); // autosave must not overlap a running core (Codex #2)
		Menu_beforeSleep();
		sleep(4);
		show_menu = 0;
		quit = 1;
	}
}

///////////////////////////////

// TODO: this is a dumb API
SDL_Surface* digits;
#define DIGIT_WIDTH 9
#define DIGIT_HEIGHT 8
#define DIGIT_TRACKING -2
enum {
	DIGIT_SLASH = 10,
	DIGIT_DOT,
	DIGIT_PERCENT,
	DIGIT_X,
	DIGIT_OP, // (
	DIGIT_CP, // )
	DIGIT_COUNT,
};
#define DIGIT_SPACE DIGIT_COUNT
static void MSG_init(void) {
	digits = SDL_CreateRGBSurface(SDL_SWSURFACE,SCALE2(DIGIT_WIDTH*DIGIT_COUNT,DIGIT_HEIGHT),FIXED_DEPTH, 0,0,0,0);
	SDL_FillRect(digits, NULL, RGB_BLACK);
	
	SDL_Surface* digit;
	char* chars[] = { "0","1","2","3","4","5","6","7","8","9","/",".","%","x","(",")", NULL };
	char* c;
	int i = 0;
	while ((c = chars[i])) {
		digit = TTF_RenderUTF8_Blended(font.tiny, c, COLOR_WHITE);
		SDL_BlitSurface(digit, NULL, digits, &(SDL_Rect){ (i * SCALE1(DIGIT_WIDTH)) + (SCALE1(DIGIT_WIDTH) - digit->w)/2, (SCALE1(DIGIT_HEIGHT) - digit->h)/2});
		SDL_FreeSurface(digit);
		i += 1;
	}
}
static int MSG_blitChar(int n, int x, int y) {
	if (n!=DIGIT_SPACE) SDL_BlitSurface(digits, &(SDL_Rect){n*SCALE1(DIGIT_WIDTH),0,SCALE2(DIGIT_WIDTH,DIGIT_HEIGHT)}, screen, &(SDL_Rect){x,y});
	return x + SCALE1(DIGIT_WIDTH + DIGIT_TRACKING);
}
static int MSG_blitInt(int num, int x, int y) {
	int i = num;
	int n;
	
	if (i > 999) {
		n = i / 1000;
		i -= n * 1000;
		x = MSG_blitChar(n,x,y);
	}
	if (i > 99) {
		n = i / 100;
		i -= n * 100;
		x = MSG_blitChar(n,x,y);
	}
	else if (num>99) {
		x = MSG_blitChar(0,x,y);
	}
	if (i > 9) {
		n = i / 10;
		i -= n * 10;
		x = MSG_blitChar(n,x,y);
	}
	else if (num>9) {
		x = MSG_blitChar(0,x,y);
	}
	
	n = i;
	x = MSG_blitChar(n,x,y);
	
	return x;
}
static int MSG_blitDouble(double num, int x, int y) {
	int i = num;
	int r = (num-i) * 10;
	int n;
	
	x = MSG_blitInt(i, x,y);

	n = DIGIT_DOT;
	x = MSG_blitChar(n,x,y);
	
	n = r;
	x = MSG_blitChar(n,x,y);
	return x;
}
static void MSG_quit(void) {
	SDL_FreeSurface(digits);
}

///////////////////////////////

static const char* bitmap_font[] = {
	['M'] =
		"1   1"
		"11 11"
		"1 1 1"
		"1 1 1"
		"1   1"
		"1   1"
		"1   1"
		"1   1"
		"1   1",
	['H'] =
		"1   1"
		"1   1"
		"1   1"
		"11111"
		"1   1"
		"1   1"
		"1   1"
		"1   1"
		"1   1",
	['Z'] =
		"11111"
		"    1"
		"    1"
		"   1 "
		"  1  "
		" 1   "
		"1    "
		"1    "
		"11111",
	['T'] =
		"11111"
		"  1  "
		"  1  "
		"  1  "
		"  1  "
		"  1  "
		"  1  "
		"  1  "
		"  1  ",
	['R'] =
		"1111 "
		"1   1"
		"1   1"
		"1111 "
		"1 1  "
		"1  1 "
		"1  1 "
		"1   1"
		"1   1",
	['C'] =
		" 111 "
		"1   1"
		"1    "
		"1    "
		"1    "
		"1    "
		"1    "
		"1   1"
		" 111 ",
	['0'] =
		" 111 "
		"1   1"
		"1   1"
		"1  11"
		"1 1 1"
		"11  1"
		"1   1"
		"1   1"
		" 111 ",
	['1'] =
		"   1 "
		" 111 "
		"   1 "
		"   1 "
		"   1 "
		"   1 "
		"   1 "
		"   1 "
		"   1 ",
	['2'] =
		" 111 "
		"1   1"
		"    1"
		"   1 "
		"  1  "
		" 1   "
		"1    "
		"1    "
		"11111",
	['3'] =
		" 111 "
		"1   1"
		"    1"
		"    1"
		" 111 "
		"    1"
		"    1"
		"1   1"
		" 111 ",
	['4'] =
		"1   1"
		"1   1"
		"1   1"
		"1   1"
		"1   1"
		"1   1"
		"11111"
		"    1"
		"    1",
	['5'] =
		"11111"
		"1    "
		"1    "
		"1111 "
		"    1"
		"    1"
		"    1"
		"1   1"
		" 111 ",
	['6'] =
		" 111 "
		"1    "
		"1    "
		"1111 "
		"1   1"
		"1   1"
		"1   1"
		"1   1"
		" 111 ",
	['7'] =
		"11111"
		"    1"
		"    1"
		"   1 "
		"  1  "
		"  1  "
		"  1  "
		"  1  "
		"  1  ",
	['8'] =
		" 111 "
		"1   1"
		"1   1"
		"1   1"
		" 111 "
		"1   1"
		"1   1"
		"1   1"
		" 111 ",
	['9'] =
		" 111 "
		"1   1"
		"1   1"
		"1   1"
		"1   1"
		" 1111"
		"    1"
		"    1"
		" 111 ",
	['.'] = 
		"     "
		"     "
		"     "
		"     "
		"     "
		"     "
		"     "
		" 11  "
		" 11  ",
	[','] = 
		"     "
		"     "
		"     "
		"     "
		"     "
		"     "
		"  1  "
		"  1  "
		" 1   ",
	[' '] = 
		"     "
		"     "
		"     "
		"     "
		"     "
		"     "
		"     "
		"     "
		"     ",
	['('] = 
		"   1 "
		"  1  "
		" 1   "
		" 1   "
		" 1   "
		" 1   "
		" 1   "
		"  1  "
		"   1 ",
	[')'] = 
		" 1   "
		"  1  "
		"   1 "
		"   1 "
		"   1 "
		"   1 "
		"   1 "
		"  1  "
		" 1   ",
	['/'] = 
		"   1 "
		"   1 "
		"   1 "
		"  1  "
		"  1  "
		"  1  "
		" 1   "
		" 1   "
		" 1   ",
	['x'] = 
		"     "
		"     "
		"1   1"
		"1   1"
		" 1 1 "
		"  1  "
		" 1 1 "
		"1   1"
		"1   1",
	['%'] = 
		" 1   "
		"1 1  "
		"1 1 1"
		" 1 1 "
		"  1  "
		" 1 1 "
		"1 1 1"
		"  1 1"
		"   1 ",
	['-'] =
		"     "
		"     "
		"     "
		"     "
		" 111 "
		"     "
		"     "
		"     "
		"     ",
	};
static void blitBitmapText(char* text, int ox, int oy, uint16_t* data, int stride, int width, int height) {
	#define CHAR_WIDTH 5
	#define CHAR_HEIGHT 9
	#define LETTERSPACING 1
	
	int len = strlen(text);
	int w = ((CHAR_WIDTH+LETTERSPACING)*len)-1;
	int h = CHAR_HEIGHT;
	
	if (ox<0) ox = width-w+ox;
	if (oy<0) oy = height-h+oy;

	// clip hard: the border writes reach one px left, one row above, and one row
	// below the text. The core-owned frame buffers are over-allocated and forgave
	// out-of-bounds writes for years; the threaded mailbox buffer is exact-size
	// (malloc(h*pitch)) and segfaults on the same math during boot dims churn.
	if (ox < 1 || oy < 1 || ox + w + 1 > width || oy + h + 1 > height) return;

	data += oy * stride + ox;
	uint16_t* row = data - stride; // TODO: this will crash and burn if ox,oy==0,0 but is fine as used currently :sweat_smile:
	memset(row-1, 0, (w+2)*2);
	for (int y=0; y<CHAR_HEIGHT; y++) {
		row = data + y * stride;
		memset(row-1, 0, (w+2)*2);
		for (int i=0; i<len; i++) {
			const char* c = bitmap_font[(unsigned char)text[i]];
			if (!c) { row += CHAR_WIDTH + LETTERSPACING; continue; } // undefined glyph: blank, not a NULL deref
			for (int x=0; x<CHAR_WIDTH; x++) {
				int j = y * CHAR_WIDTH + x;
				if (c[j]=='1') *row = 0xffff;
				row++;
			}
			row += LETTERSPACING;
		}
	}
	row = data + CHAR_HEIGHT * stride;
	memset(row-1, 0, (w+2)*2);
}

///////////////////////////////

static int cpu_ticks = 0;
static int gen_ticks = 0;   // GENERATED frames = completed serial core.run() epochs (Codex F1);
static int fps_ticks = 0;   // PRESENTED frames = actual on-screen presents (distinct from gen_ticks)
static int use_ticks = 0;
static int last_use_ticks = 0;
static double fps_double = 0;
static double cpu_double = 0;
static double use_double = 0;
static uint32_t sec_start = 0;
static unsigned run_window_epoch = 0;
static int gov_frames = 0;
static long gov_prev_wait_ms = 0;
#define GOV_WORK_CAP (GOV_TICK_FRAMES + 2) // depth-2 can drain two boundaries in one MAIN pump
static uint32_t gov_work[GOV_WORK_CAP];
static unsigned getUsage(void);

static void RunLoop_resetWindow(void) {
	sec_start = SDL_GetTicks();
	cpu_ticks = 0;
	fps_ticks = 0;
	gen_ticks = 0;
	fps_double = 0;
	cpu_double = 0;
	use_double = 0;
	use_ticks = last_use_ticks = (int)getUsage();
	SND_Stats as; SND_getStats(&as);
	gov_frames = 0;
	gov_prev_wait_ms = as.wait_ms;
	run_window_epoch++;
#ifdef ZERO_FRONTEND_THREADING_V2
	zero_ftv2_gen_ticks = 0;
#endif
}

#ifdef USES_SWSCALER
	static int fit = 1;
#else
	static int fit = 0;
#endif	

// buffer to convert xrgb8888 to rgb565
static void* buffer = NULL;
static void buffer_dealloc(void) {
	if (!buffer) return;
	free(buffer);
	buffer = NULL;
}
static void buffer_realloc(int w, int h, int p) {
	buffer_dealloc();
	buffer = malloc((w * FIXED_BPP) * h);
	// LOG_info("buffer_realloc(%i,%i,%i)\n", w,h,p);
}
static void buffer_downsample(const void *data, unsigned width, unsigned height, size_t pitch) {
	// from picoarch! https://git.crowdedwood.com/picoarch/tree/video.c#n51
	const uint32_t *input = data;
	uint16_t *output = buffer;
	size_t extra = pitch / sizeof(uint32_t) - width;

	for (int y = 0; y < height; y++) {
		for (int x = 0; x < width; x++) {
			*output =  (*input & 0xF80000) >> 8;
			*output |= (*input & 0xFC00) >> 5;
			*output |= (*input & 0xF8) >> 3;
			input++;
			output++;
		}

		input += extra; // TODO: commenting this out fixes geolith when cropped, it appears to be lying about the pitch...
	}
}

static void selectScaler(int src_w, int src_h, int src_p) {
	LOG_info("selectScaler\n");
	int render_fit = fit;
#if defined(GOV_PLATFORM_H700)
	// Software effects need a final-resolution surface: stretching their already-drawn
	// lines/grid through the DE creates uneven bands. Native stays integer.
	// MIYOOMINI IS NO LONGER HERE: it composites the pattern with MI_GFX after the present scale
	// (platform.c fx_*), so it wants the CHEAP geometry back — a panel-sized surface meant the CPU
	// scaled every pixel in software, which is the ~45%-vs-25% regression Dan measured on 2026-09-08.
	if (screen_effect != EFFECT_NONE) render_fit = 1;
#endif
	
	if (downsample) buffer_realloc(src_w,src_h,src_p);
	
	int src_x,src_y,dst_x,dst_y,dst_w,dst_h,dst_p,scale;
	double aspect;
	
	int aspect_w = src_w;
	int aspect_h = CEIL_DIV(aspect_w, core.aspect_ratio);
	
	// TODO: make sure this doesn't break fit==1 devices
	if (aspect_h<src_h) {
		aspect_h = src_h;
		aspect_w = aspect_h * core.aspect_ratio;
		aspect_w += aspect_w % 2;
	}

	char scaler_name[16];
	
	src_x = 0;
	src_y = 0;
	dst_x = 0;
	dst_y = 0;

	// unmodified by crop
	renderer.true_w = src_w;
	renderer.true_h = src_h;
	
	// TODO: this is saving non-rgb30 devices from themselves...or rather, me
	int scaling = screen_scaling;
	if (scaling==SCALE_CROPPED && DEVICE_WIDTH==HDMI_WIDTH) {
		scaling = SCALE_NATIVE;
	}
	
	if (scaling==SCALE_NATIVE || scaling==SCALE_CROPPED) {
		// this is the same whether fit or oversized
		scale = MIN(DEVICE_WIDTH/src_w, DEVICE_HEIGHT/src_h);
		if (!scale) {
			sprintf(scaler_name, "forced crop");
			dst_w = DEVICE_WIDTH;
			dst_h = DEVICE_HEIGHT;
			dst_p = DEVICE_PITCH;
			
			int ox = (DEVICE_WIDTH  - src_w) / 2; // may be negative
			int oy = (DEVICE_HEIGHT - src_h) / 2; // may be negative
			
			if (ox<0) src_x = -ox;
			else dst_x = ox;
			
			if (oy<0) src_y = -oy;
			else dst_y = oy;
		}
		// TODO: this is all kinds of messed up
		// TODO: is this blowing up because the smart has to rotate before scaling?
		// TODO: or is it just that I'm trying to cram 4 logical rects into 2 rect arguments
		// TODO: eg. src.size + src.clip + dst.size + dst.clip
		else if (scaling==SCALE_CROPPED) {
			int scale_x = CEIL_DIV(DEVICE_WIDTH, src_w);
			int scale_y = CEIL_DIV(DEVICE_HEIGHT, src_h);
			scale = MIN(scale_x, scale_y);

			sprintf(scaler_name, "cropped");
			dst_w = DEVICE_WIDTH;
			dst_h = DEVICE_HEIGHT;
			dst_p = DEVICE_PITCH;

			int scaled_w = src_w * scale;
			int scaled_h = src_h * scale;

			int ox = (DEVICE_WIDTH  - scaled_w) / 2; // may be negative
			int oy = (DEVICE_HEIGHT - scaled_h) / 2; // may be negative

			if (ox<0) {
				src_x = -ox / scale;
				src_w -= src_x * 2;
			}
			else {
				dst_x = ox;
				// dst_w -= ox * 2;
			}

			if (oy<0) {
				src_y = -oy / scale;
				src_h -= src_y * 2;
			}
			else {
				dst_y = oy;
				// dst_h -= oy * 2;
			}
		}
		else {
			sprintf(scaler_name, "integer");
			int scaled_w = src_w * scale;
			int scaled_h = src_h * scale;
			dst_w = DEVICE_WIDTH;
			dst_h = DEVICE_HEIGHT;
			dst_p = DEVICE_PITCH;
			dst_x = (DEVICE_WIDTH  - scaled_w) / 2; // should always be positive
			dst_y = (DEVICE_HEIGHT - scaled_h) / 2; // should always be positive
		}
	}
	else if (render_fit) {
		// Final-size scaler: plain nearest on SWSCALER platforms, fused effects on MMP/H700.
		if (scaling==SCALE_FULLSCREEN) {
			sprintf(scaler_name, "full fit");
			dst_w = DEVICE_WIDTH;
			dst_h = DEVICE_HEIGHT;
			dst_p = DEVICE_PITCH;
			scale = -1; // nearest neighbor
		}
		else {
			double scale_f = MIN(((double)DEVICE_WIDTH)/aspect_w, ((double)DEVICE_HEIGHT)/aspect_h);
			LOG_info("scale_f:%f\n", scale_f);
			
			sprintf(scaler_name, "aspect fit");
			dst_w = aspect_w * scale_f;
			dst_h = aspect_h * scale_f;
#if defined(GOV_PLATFORM_H700)
			// Fit the reported aspect directly; rounding an intermediate aspect_w/h
			// changes the game's rectangle when an effect is toggled (e.g. SNES 4:3).
			dst_h = DEVICE_HEIGHT;
			dst_w = dst_h * core.aspect_ratio;
			if (dst_w > DEVICE_WIDTH) {
				dst_w = DEVICE_WIDTH;
				dst_h = dst_w / core.aspect_ratio;
			}
#endif
			dst_p = DEVICE_PITCH;
			dst_x = (DEVICE_WIDTH  - dst_w) / 2;
			dst_y = (DEVICE_HEIGHT - dst_h) / 2;
			scale = (scale_f==1.0 && dst_w==src_w && dst_h==src_h) ? 1 : -1;
		}
	}
	else {
		int scale_x = CEIL_DIV(DEVICE_WIDTH, src_w);
		int scale_y = CEIL_DIV(DEVICE_HEIGHT,src_h);
		
		// odd resolutions (eg. PS1 Rayman: 320x239) is throwing this off, need to snap to eights
		int r = (DEVICE_HEIGHT-src_h)%8;
		if (r && r<8) scale_y -= 1;
		
		scale = MAX(scale_x, scale_y);
		// cap the supersample so the dst buffer never exceeds ~2x the panel area — the
		// CPU scales into and uploads this buffer EVERY frame. Uncapped, PS1 480i content
		// on the 1280x720 SP picked scale 3 (a 2048x1440 padded dst, ~3x the Brick's cost
		// for the same screen = the SP VS-card slowdown, 2026-07-09). The cap leaves every
		// pre-existing Brick/SP case unchanged; only the pathological combos shrink.
		while (scale > 1 && (long)src_w*scale*src_h*scale > 2L*DEVICE_WIDTH*DEVICE_HEIGHT) scale--;
		
		int scaled_w = src_w * scale;
		int scaled_h = src_h * scale;
		
		if (scaling==SCALE_FULLSCREEN) {
			sprintf(scaler_name, "full%i", scale);
			// type = 'full (oversized)';
			dst_w = scaled_w;
			dst_h = scaled_h;
			dst_p = dst_w * FIXED_BPP;
		}
		else {
			double src_aspect_ratio = ((double)src_w) / src_h;
			// double core_aspect_ratio
			double fixed_aspect_ratio = ((double)DEVICE_WIDTH) / DEVICE_HEIGHT;
			int core_aspect = core.aspect_ratio * 1000;
			int fixed_aspect = fixed_aspect_ratio * 1000;
			
			// still having trouble with FC's 1.306 (13/10? wtf) on 4:3 devices
			// specifically I think it has trouble when src, core, and fixed 
			// ratios don't match
			
			// it handles src and core matching but fixed not, eg. GB and GBA 
			// or core and fixed matching but not src, eg. odd PS resolutions
			
			// we need to transform the src size to core aspect
			// then to fixed aspect
						
			if (core_aspect>fixed_aspect) {
				sprintf(scaler_name, "aspect%iL", scale);
				// letterbox
				// dst_w = scaled_w;
				// dst_h = scaled_w / fixed_aspect_ratio;
				// dst_h += dst_h%2;
				int aspect_h = DEVICE_WIDTH / core.aspect_ratio;
				double aspect_hr = ((double)aspect_h) / DEVICE_HEIGHT;
				dst_w = scaled_w;
				dst_h = scaled_h / aspect_hr;

				dst_y = (dst_h - scaled_h) / 2;
			}
			else if (core_aspect<fixed_aspect) {
				sprintf(scaler_name, "aspect%iP", scale);
				// pillarbox
				// dst_w = scaled_h * fixed_aspect_ratio;
				// dst_w += dst_w%2;
				// dst_h = scaled_h;
				aspect_w = DEVICE_HEIGHT * core.aspect_ratio;
				double aspect_wr = ((double)aspect_w) / DEVICE_WIDTH;
				dst_w = scaled_w / aspect_wr;
				dst_h = scaled_h;
				
				dst_w = (dst_w/8)*8;
				dst_x = (dst_w - scaled_w) / 2;
			}
			else {
				sprintf(scaler_name, "aspect%iM", scale);
				// perfect match
				dst_w = scaled_w;
				dst_h = scaled_h;
			}
			dst_p = dst_w * FIXED_BPP;
		}
	}
	
	// TODO: need to sanity check scale and demands on the buffer
	
	// LOG_info("aspect: %ix%i (%f)\n", aspect_w,aspect_h,core.aspect_ratio);
	
	renderer.src_x = src_x;
	renderer.src_y = src_y;
	renderer.src_w = src_w;
	renderer.src_h = src_h;
	renderer.src_p = src_p;
	renderer.dst_x = dst_x;
	renderer.dst_y = dst_y;
	renderer.dst_w = dst_w;
	renderer.dst_h = dst_h;
	renderer.dst_p = dst_p;
	renderer.scale = scale;
	renderer.aspect = (scaling==SCALE_NATIVE||scaling==SCALE_CROPPED)?0:(scaling==SCALE_FULLSCREEN?-1:core.aspect_ratio);
	LOG_info("aspect: %f\n", renderer.aspect);
	renderer.blit = GFX_getScaler(&renderer);
		
	// LOG_info("coreAR:%0.3f fixedAR:%0.3f srcAR: %0.3f\nname:%s\nfit:%i scale:%i\nsrc_x:%i src_y:%i src_w:%i src_h:%i src_p:%i\ndst_x:%i dst_y:%i dst_w:%i dst_h:%i dst_p:%i\naspect_w:%i aspect_h:%i\n",
	// 	core.aspect_ratio, ((double)DEVICE_WIDTH) / DEVICE_HEIGHT, ((double)src_w) / src_h,
	// 	scaler_name,
	// 	fit,scale,
	// 	src_x,src_y,src_w,src_h,src_p,
	// 	dst_x,dst_y,dst_w,dst_h,dst_p,
	// 	aspect_w,aspect_h
	// );

	if (render_fit) {
		dst_w = DEVICE_WIDTH;
		dst_h = DEVICE_HEIGHT;
	}
	
	// if (screen->w!=dst_w || screen->h!=dst_w || screen->pitch!=dst_p) {
		screen = GFX_resize(dst_w,dst_h,dst_p);
	// }

	// A platform may hand back a SMALLER surface than requested (miyoomini clamps when the
	// requested buffer would overflow its fixed MMA render page). The scalers take dst_h as a
	// parameter and step the destination by dst_p — they never look at the surface's h — so
	// without this the frontend would keep writing the full unclamped height straight past the
	// end of the platform's buffer. Honour what we were actually given.
	// No-op on platforms that never clamp (screen->h == dst_h there, so this is identity).
	if (screen && screen->h > 0 && renderer.dst_h > screen->h) {
		LOG_info("resize: platform clamped dst_h %d -> %d\n", renderer.dst_h, screen->h);
		renderer.dst_h = screen->h;
	}
}
static void present_frame(const void *data, unsigned width, unsigned height, size_t pitch, int do_flip) {
	// return;

	Special_render();

	// (duplicate detection lives below the early-returns: only frames that would
	// actually present may update the comparison snapshot — Codex review finding 1)
	
	// static int tmp_frameskip = 0;
	// if ((tmp_frameskip++)%2) return;
	
	static uint32_t last_flip_time = 0;
	
	// 10 seems to be the sweet spot that allows 2x in NES and SNES and 8x in GB at 60fps
	// 14 will let GB hit 10x but NES and SNES will drop to 1.5x at 30fps (not sure why)
	// but 10 hurts PS...
	// TODO: 10 was based on rg35xx, probably different results on other supported platforms
	if (fast_forward && SDL_GetTicks()-last_flip_time<10) return;
	
	// FFVII menus 
	// 16: 30/200
	// 15: 30/180
	// 14: 45/180
	// 12: 30/150
	// 10: 30/120 (optimize text off has no effect)
	//  8: 60/210 (with optimize text off)
	// you can squeeze more out of every console by turning prevent tearing off
	// eg. PS@10 60/240
	
	if (!data) return;

	// Duplicate detection + present-skip. Policy is the pure, tested dupskip.{h,c} unit
	// (Codex P1#2); this site owns only the env gate and the 1Hz stats log (SDL/SND/LOG).
	// A byte-identical frame changes nothing on screen — skip upload/submit/swap and let the
	// CPU idle sooner. Pacing is owned by the audio ring, so skipping is legal only while
	// audio is actually pacing (SND_isActive now proves that, not just init — Codex P1#1);
	// presentation-drop cores (PS) are excluded; geometry/settings-generation must be clean;
	// and a forced present lands at least every 31 frames. Work telemetry is finalized on a
	// skipped frame so governor batches never consume a stale sample.
	{
		static DupSkip g_dup = {0};
		static int dup_on = -1, skip_on = -1, stats_on = -1;
		if (dup_on == -1) {
			stats_on = (getenv("ZERO_PRESENT_STATS") != NULL);
			skip_on  = (getenv("ZERO_DUP_SKIP") != NULL);
			dup_on   = stats_on || skip_on;     // detection needed for either
		}
		if (dup_on) {
			int dup_frame = dupskip_detect(&g_dup, data, width, height, pitch, downsample ? 4 : 2);
			tlm_dup(dup_frame); // dup rate -> opt-in BENCH CSV (no-op unless BENCH; the reliable path)
			// 1Hz text dup-stats: ONLY under ZERO_PRESENT_STATS — never coupled to ZERO_DUP_SKIP,
			// which would add a per-second synchronous SD flush to the default-on feature (Codex P1).
			if (stats_on) {
				static int df_n = 0, df_dup = 0; static uint32_t df_at = 0;
				df_n++; if (dup_frame) df_dup++;
				uint32_t df_now = SDL_GetTicks();
				if (!df_at) df_at = df_now;
				else if (df_now - df_at >= 1000) {
					static long df_ur0 = 0;
					SND_Stats dfs; SND_getStats(&dfs);
					LOG_info("dup-stats: frames=%d dups=%d (%.0f%%) underruns=%ld\n",
						df_n, df_dup, df_n ? 100.0*df_dup/df_n : 0, dfs.underruns - df_ur0);
					df_ur0 = dfs.underruns;
					df_n = df_dup = 0; df_at = df_now;
				}
			}
			DupSkipCtx dc = {
				.enabled           = skip_on,
				.dup_frame         = dup_frame,
				.geometry_dirty    = (renderer.dst_p==0 || width!=renderer.true_w || height!=renderer.true_h),
				.present_dirty_gen = present_dirty_gen,
				.fast_forward      = fast_forward,
				.presentation_drop = presentation_drop_supported,
				.audio_active      = SND_isActive(),
				.force_present     = dup_force_present,
				.max_streak        = 30,
			};
			if (dupskip_should_skip(&g_dup, &dc)) {
				GFX_finishFrameWork(); // close this frame's work sample for the governor batch
				return;
			}
			dup_force_present = 0;
		}
	}

	fps_ticks += 1; // PRESENTED frame (we did not skip) — distinct from gen_ticks (generation)

	if (downsample) pitch /= 2; // everything expects 16 but we're downsampling from 32
	
	// if source has changed size (or forced by dst_p==0)
	// eg. true src + cropped src + fixed dst + cropped dst
	if (renderer.dst_p==0 || width!=renderer.true_w || height!=renderer.true_h) {
		// burst only on a TRUE size change — same-size re-inits (SET_GEOMETRY aspect
		// resyncs, menu returns) fire selectScaler too, and bursting on those pinned
		// GBC at 1008 instead of its 408 floor (gambatte resyncs periodically; caught
		// by the 2026-07-09 regression sweep). A real scene switch changes dimensions.
		int size_changed = (width!=renderer.true_w || height!=renderer.true_h);
		static int geometry_established = 0; // review r3: the FIRST callback always differs
		int first_geometry = size_changed && !geometry_established;
		if (size_changed) geometry_established = 1;
		selectScaler(width, height, pitch);
		GFX_clearAll();
		if (size_changed) { // provision before the cost lands
			// initial geometry acquisition is how every session begins — only a LATER
			// real dimension change invalidates the remembered floor (reviews r3/r4)
			gov_scene_burst("scene change", !first_geometry);
		}
	}
	if (show_debug) {
		int x = 2 + renderer.src_x;
		int y = 2 + renderer.src_y;
		char debug_text[128];
		int scale = renderer.scale;
		if (scale==-1) scale = 1; // nearest neighbor flag

		// Render the HUD into two native-resolution strips presented by the GPU at 2x
		// AFTER the game frame (PLAT_setDebugOverlay). Drawn into the core's frame the
		// text was magnified by the game scale — 8x on GBC filled the screen and the
		// corner fields collided/clipped. ZERO_FB_GAME presents before the overlay
		// draw ever runs, so that dev path keeps the legacy in-frame text.
		static int dbg_legacy = -1;
		if (dbg_legacy == -1) dbg_legacy = (getenv("ZERO_FB_GAME") != NULL);
		static uint16_t* dbg_top = NULL;
		static uint16_t* dbg_bot = NULL;
		static int dbg_w = 0, dbg_h = 0;
		if (!dbg_legacy && !dbg_top) {
			dbg_w = screen->w / DBG_OVERLAY_SCALE; // presented scaled -> strips span the panel
			dbg_h = CHAR_HEIGHT + 2;
			dbg_top = calloc(dbg_w * dbg_h, sizeof(uint16_t));
			dbg_bot = calloc(dbg_w * dbg_h, sizeof(uint16_t));
			if (!dbg_top || !dbg_bot) dbg_legacy = 1; // allocation failed: keep old path
		}
		uint16_t* t_px = (uint16_t*)data; int t_stride = pitch/2, t_w = width, t_h = height, t_x = x, t_y = y;
		uint16_t* b_px = (uint16_t*)data; int b_stride = pitch/2, b_w = width, b_h = height, b_x = x, b_y = -y;
		int dbg_eff_w = dbg_w;
		if (!dbg_legacy) {
			// align the text field to the game's panel rect (last presented frame) so
			// left/right text hug the game image like the classic in-frame HUD did
			int gx, gy, gw, gh;
			PLAT_getGameRect(&gx, &gy, &gw, &gh);
			if (gw > 0) dbg_eff_w = gw / DBG_OVERLAY_SCALE;
			if (dbg_eff_w > dbg_w) dbg_eff_w = dbg_w;
			if (dbg_eff_w < 64) dbg_eff_w = 64; // degenerate rect: keep text drawable
			// 0xF81F magenta = transparent (the platform keys it out); blitBitmapText
			// black-fills exactly the text rectangle, so only the text carries a bg
			for (int i = 0; i < dbg_w * dbg_h; i++) { dbg_top[i] = 0xF81F; dbg_bot[i] = 0xF81F; }
			t_px = dbg_top; t_stride = dbg_w; t_w = dbg_eff_w; t_h = dbg_h; t_x = 2; t_y = 1;
			b_px = dbg_bot; b_stride = dbg_w; b_w = dbg_eff_w; b_h = dbg_h; b_x = 2; b_y = 1;
		}

		sprintf(debug_text, "%ix%i %ix", renderer.src_w,renderer.src_h, scale);
		blitBitmapText(debug_text,t_x,t_y,t_px,t_stride, t_w,t_h);

		sprintf(debug_text, "%i,%i %ix%i", renderer.dst_x,renderer.dst_y, renderer.src_w*scale,renderer.src_h*scale);
		blitBitmapText(debug_text,-t_x,t_y,t_px,t_stride, t_w,t_h);

		// governor dashboard: live clock/ceiling / temp / generation-vs-target fps / % of total CPU
		static int hud_temp = -1;
		static int hud_cur_khz = -1;
		static uint32_t hud_temp_at = 0;
		uint32_t hud_now = SDL_GetTicks();
		if (hud_now - hud_temp_at >= 1000) {
			hud_temp = gov_read_temp_c();
			hud_cur_khz = gov_read_cur_khz();
			hud_temp_at = hud_now;
		}
		// cur/ceil: what schedutil picked this second vs the governor's cap. On fixed
		// brackets (8-bit 1008/1008) the cap never moves — the live clock is the story.
		char hud_mhz[24];
		if (hud_cur_khz > 0) snprintf(hud_mhz, sizeof(hud_mhz), "%i/%iMHZ", hud_cur_khz/1000, gov_state.ceil_khz/1000);
		else snprintf(hud_mhz, sizeof(hud_mhz), "%iMHZ", gov_state.ceil_khz/1000);
		if (thread_video && core.fps > 0) {
			uint64_t thr_sum = 0;
			int thr_n = core_work_n < CORE_WORK_RING ? (int)core_work_n : CORE_WORK_RING;
			for (int a=0; a<thr_n; a++) thr_sum += core_work_ring[a];
			int thr_util = thr_n > 0 ? (int)(100.0 * (double)thr_sum / (thr_n * (1000000.0 / core.fps))) : 0;
			static uint32_t sm_at = 0; static int sm_w0 = 0, sm_o0 = 0; static long sm_u0 = 0;
			static int sm_d = 0, sm_s = 0, sm_u = 0;
			uint32_t sm_now = SDL_GetTicks();
			if (sm_now - sm_at >= 1000) {
				SND_Stats ss; SND_getStats(&ss);
				sm_d = mb_dups_total - sm_w0;       sm_w0 = mb_dups_total;
				sm_s = mb_overwrites_total - sm_o0; sm_o0 = mb_overwrites_total;
				sm_u = (int)(ss.underruns - sm_u0); sm_u0 = ss.underruns;
				sm_at = sm_now;
			}
			snprintf(debug_text, sizeof(debug_text), "%s %iC %.0f/%.0f %i%% THR %i%% D%i S%i U%i", hud_mhz, hud_temp, cpu_double, core.fps, (int)use_double, thr_util, sm_d, sm_s, sm_u);
		}
	#ifdef ZERO_FRONTEND_THREADING_V2
		else if (zero_ftv2_depth2)
			snprintf(debug_text, sizeof(debug_text), "%s %iC %.0f/%.0f %i%% T2", hud_mhz, hud_temp, fps_double, core.fps, (int)use_double);
	#endif
		else snprintf(debug_text, sizeof(debug_text), "%s %iC %.0f/%.0f %i%%", hud_mhz, hud_temp, cpu_double, core.fps, (int)use_double);
		blitBitmapText(debug_text,b_x,b_y,b_px,b_stride, b_w,b_h);

		sprintf(debug_text, "%ix%i", renderer.dst_w,renderer.dst_h);
		blitBitmapText(debug_text,-b_x,b_y,b_px,b_stride, b_w,b_h);

		if (!dbg_legacy) PLAT_setDebugOverlay(dbg_top, dbg_bot, dbg_eff_w, dbg_h, dbg_w);
	}
	else PLAT_setDebugOverlay(NULL, NULL, 0, 0, 0);

	if (downsample) {
		buffer_downsample(data,width,height,pitch*2);
		renderer.src = buffer;
	}
	else {
		renderer.src = (void*)data;
	}
	renderer.dst = screen->pixels;
#ifdef ZERO_FRONTEND_THREADING_V2
	if (zero_ftv2_depth2 && do_flip) {
		// Depth-2 present is always the never-skip GFX_flip: this vsync is the pipeline pacer.
		GFX_blitRenderer(&renderer);
		GFX_flip(screen);
		return;
	}
#endif
	GFX_blitRenderer(&renderer);
	if (do_flip) {
		// Route the present by context (v1.3.1 GFX_flip/GFX_flipGame split): a serial game-loop
		// present may skip under presentation-drop catch-up (GFX_flipGame); a menu redraw (Menu_loop
		// repaints the paused frame — show_menu) must NEVER skip or the menu goes invisible; and the
		// depth-2 present IS the vsync pacer, also never-skip. Both of the latter take GFX_flip.
		int never_skip = show_menu;
#ifdef ZERO_FRONTEND_THREADING_V2
		if (zero_ftv2_depth2) never_skip = 1;
#endif
		if (never_skip) GFX_flip(screen);
		else            GFX_flipGame(screen);
	}
}

static void video_refresh_callback_main(const void *data, unsigned width, unsigned height, size_t pitch) {
	// return;
	
	// static int tmp_frameskip = 0;
	// if ((tmp_frameskip++)%2) return;
	
	static uint32_t last_flip_time = 0;
	int ftv2_run_phase = 0;
#ifdef ZERO_FRONTEND_THREADING_V2
	fc_phase phase = zero_ftv2_inited ? fc_current_phase() : FCP_NONE;
	ftv2_run_phase = phase == FCP_RUN_EPOCH;
	// A strict-vsync present in every pipelined FF epoch caps CORE at roughly realtime:
	// with depth two, CORE can run only one epoch while MAIN is blocked in the flip. The
	// achieved-rate cadence publishes at most nominal-fps visuals while every epoch's
	// audio/input/emulation still runs. Under-target heavy scenes publish every frame.
	if (zero_ftv2_inited && phase == FCP_RUN_EPOCH
	    && zero_ftv2_ff_snap && !zero_ftv2_emit_visual) return;
#endif

	// Codex #6: on the CORE thread at depth-2 the live `fast_forward` global is MAIN-mutated —
	// read this epoch's snapshot instead (delivered via snap[3], stored in CORE TLS).
	int ff_now = fast_forward;
#ifdef ZERO_FRONTEND_THREADING_V2
	if (phase != FCP_NONE) ff_now = zero_ftv2_ff_snap;
#endif
	// 10 seems to be the sweet spot that allows 2x in NES and SNES and 8x in GB at 60fps
	// 14 will let GB hit 10x but NES and SNES will drop to 1.5x at 30fps (not sure why)
	// but 10 hurts PS...
	// TODO: 10 was based on rg35xx, probably different results on other supported platforms
	if (ff_now && !ftv2_run_phase && SDL_GetTicks()-last_flip_time<10) return;
	
	// FFVII menus 
	// 16: 30/200
	// 15: 30/180
	// 14: 45/180
	// 12: 30/150
	// 10: 30/120 (optimize text off has no effect)
	//  8: 60/210 (with optimize text off)
	// you can squeeze more out of every console by turning prevent tearing off
	// eg. PS@10 60/240
	
	if (!data) return;

#ifdef ZERO_FRONTEND_THREADING_V2
	if (zero_ftv2_inited && phase != FCP_NONE) {
		if (phase == FCP_RUN_EPOCH) {
			// CORE is a pure producer: copy the core-owned transient framebuffer verbatim.
			// Downsampling, scaler/HUD state, and GLES presentation remain MAIN-owned.
			int buf = zero_pool_acquire(width, height, pitch);
			if (buf < 0) fc_signal_dup(&zero_ftv2); // pool exhausted: retain the last visual frame
			else {
				memcpy(zero_pool_buffers[buf].px, data, (size_t)height * pitch);
				if (fc_emit_frame(&zero_ftv2, (uint64_t)buf) != FR_OK)
					zero_pool_retire(NULL, (uint64_t)buf); // no event exists to retire it on MAIN
			}
			last_flip_time = SDL_GetTicks();
		}
		// Frames emitted by serialize/unload/deinit have no visual epoch. Never enter the
		// MAIN-owned renderer from a CORE service callback.
		return;
	}
#endif
	present_frame(data, width, height, pitch, !thread_video);
	last_flip_time = SDL_GetTicks();
}
static void video_refresh_callback(const void *data, unsigned width, unsigned height, size_t pitch) {
	if (!data) {
#ifdef ZERO_FRONTEND_THREADING_V2
		if (zero_ftv2_inited && fc_current_phase() == FCP_RUN_EPOCH)
			fc_signal_dup(&zero_ftv2);
#endif
		return;
	}
	
	if (thread_video) {
		// the write buffer is core-thread-exclusive: alloc + copy happen OUTSIDE the lock
		if (backbuffer && (backbuffer->w!=width || backbuffer->h!=height || backbuffer->pitch!=pitch)) {
			free(backbuffer->pixels);
			SDL_FreeSurface(backbuffer);
			backbuffer = NULL;
		}
		if (!backbuffer) {
			uint16_t* pixels = malloc(height*pitch);
			if (pixels) backbuffer = SDL_CreateRGBSurfaceFrom(pixels, width, height, FIXED_DEPTH, pitch, RGBA_MASK_565);
			if (!backbuffer) { free(pixels); return; } // OOM: drop this frame, latest-wins mailbox recovers on the next
		}
		
		memcpy(backbuffer->pixels, data, backbuffer->h*backbuffer->pitch);
		
		// mailbox handoff: swap the fresh frame in under a brief lock. Latest wins; the
		// core never blocks behind the present. (The old handoff held the lock through
		// GFX_flip's vsync wait and relied on lossy cond signals — ~15fps presented.)
		pthread_mutex_lock(&core_mx);
		if (frame_ready) { mb_overwrites++; mb_overwrites_total++; } // main had not consumed the last frame
		SDL_Surface* t = readybuffer; readybuffer = backbuffer; backbuffer = t;
		frame_ready = 1;
		pthread_cond_signal(&core_rq);
		pthread_mutex_unlock(&core_mx);
	}
	else video_refresh_callback_main(data,width,height,pitch);
}
///////////////////////////////

// FF-with-sound (ff_audio, on by default): SND measures the actual FF production rate and
// evenly resamples to the DAC rate, with non-blocking overflow only as a convergence
// fallback. FF speed stays governed by limitFF(); ff_audio=0 restores silent FF.
static inline int zero_ff_now(void) {
#ifdef ZERO_FRONTEND_THREADING_V2
	if (zero_ftv2_inited && fc_current_phase() != FCP_NONE) return zero_ftv2_ff_snap;
#endif
	return fast_forward;
}
static size_t audio_submit(const SND_Frame* data, size_t frames) {
	size_t accepted = SND_batchSamples(data, frames);
#ifdef ZERO_FRONTEND_THREADING_V2
	if (zero_ftv2_inited && fc_current_phase() == FCP_RUN_EPOCH && accepted < frames) {
		size_t shortfall = frames - accepted;
		fc_signal_audio_shortfall(&zero_ftv2,
			(uint32_t)(shortfall > UINT32_MAX ? UINT32_MAX : shortfall));
	}
#endif
	return accepted;
}
static void audio_sample_callback(int16_t left, int16_t right) {
	if (!zero_ff_now() || ff_audio) audio_submit(&(const SND_Frame){left,right}, 1);
}
static size_t audio_sample_batch_callback(const int16_t *data, size_t frames) {
	if (!zero_ff_now() || ff_audio) return audio_submit((const SND_Frame*)data, frames);
	else return frames;
};

///////////////////////////////////////

void Core_getName(char* in_name, char* out_name) {
	strcpy(out_name, basename(in_name));
	char* tmp = strrchr(out_name, '_');
	tmp[0] = '\0';
}
void Core_open(const char* core_path, const char* tag_name) {
	LOG_info("Core_open\n");
	core.handle = dlopen(core_path, RTLD_LAZY);

	if (!core.handle) {
		// a missing/corrupt core used to fall through into dlsym(NULL)+call = segfault;
		// exit cleanly so the launcher returns to the menu (pillar 5, audit 2026-07-12)
		LOG_error("dlopen %s failed: %s\n", core_path, dlerror());
		exit(EXIT_FAILURE);
	}

	core.init = dlsym(core.handle, "retro_init");
	core.deinit = dlsym(core.handle, "retro_deinit");
	core.get_system_info = dlsym(core.handle, "retro_get_system_info");
	core.get_system_av_info = dlsym(core.handle, "retro_get_system_av_info");
	core.set_controller_port_device = dlsym(core.handle, "retro_set_controller_port_device");
	core.reset = dlsym(core.handle, "retro_reset");
	core.run = dlsym(core.handle, "retro_run");
	core.serialize_size = dlsym(core.handle, "retro_serialize_size");
	core.serialize = dlsym(core.handle, "retro_serialize");
	core.unserialize = dlsym(core.handle, "retro_unserialize");
	core.load_game = dlsym(core.handle, "retro_load_game");
	core.load_game_special = dlsym(core.handle, "retro_load_game_special");
	core.unload_game = dlsym(core.handle, "retro_unload_game");
	core.get_region = dlsym(core.handle, "retro_get_region");
	core.get_memory_data = dlsym(core.handle, "retro_get_memory_data");
	core.get_memory_size = dlsym(core.handle, "retro_get_memory_size");
	
	core.set_environment_callback = dlsym(core.handle, "retro_set_environment");
	core.set_video_refresh_callback = dlsym(core.handle, "retro_set_video_refresh");
	core.set_audio_sample_callback = dlsym(core.handle, "retro_set_audio_sample");
	core.set_audio_sample_batch_callback = dlsym(core.handle, "retro_set_audio_sample_batch");
	core.set_input_poll_callback = dlsym(core.handle, "retro_set_input_poll");
	core.set_input_state_callback = dlsym(core.handle, "retro_set_input_state");

	// every libretro core exports all of these; any NULL means a truncated/corrupt build
	// and the calls below would segfault (audit 2026-07-12)
	if (!core.init || !core.deinit || !core.get_system_info || !core.get_system_av_info
	 || !core.set_controller_port_device || !core.reset || !core.run
	 || !core.serialize_size || !core.serialize || !core.unserialize
	 || !core.load_game || !core.load_game_special || !core.unload_game
	 || !core.get_region || !core.get_memory_data || !core.get_memory_size
	 || !core.set_environment_callback || !core.set_video_refresh_callback
	 || !core.set_audio_sample_callback || !core.set_audio_sample_batch_callback
	 || !core.set_input_poll_callback || !core.set_input_state_callback) {
		LOG_error("core %s is missing required libretro symbols\n", core_path);
		exit(EXIT_FAILURE);
	}
	
	Core_getName((char*)core_path, (char*)core.name);
	strcpy((char*)core.tag, tag_name);
	sprintf((char*)core.config_dir, USERDATA_PATH "/%s-%s", core.tag, core.name);
	sprintf((char*)core.states_dir, SHARED_USERDATA_PATH "/%s-%s", core.tag, core.name);
	sprintf((char*)core.saves_dir, SDCARD_PATH "/Saves/%s", core.tag);
	sprintf((char*)core.bios_dir, SDCARD_PATH "/Bios/%s", core.tag);
	
	char cmd[512];
	sprintf(cmd, "mkdir -p \"%s\"; mkdir -p \"%s\"", core.config_dir, core.states_dir);
	system(cmd);
}
static void Core_registerCallbacks(void) {
	core.set_environment_callback(environment_callback);
	core.set_video_refresh_callback(video_refresh_callback);
	core.set_audio_sample_callback(audio_sample_callback);
	core.set_audio_sample_batch_callback(audio_sample_batch_callback);
	core.set_input_poll_callback(input_poll_callback);
	core.set_input_state_callback(input_state_callback);
}
static void Core_applyInfo(const struct retro_system_info* info) {
	snprintf((char*)core.version, sizeof(core.version), "%s (%s)",
		info->library_name ? info->library_name : "Unknown",
		info->library_version ? info->library_version : "Unknown");
	snprintf((char*)core.extensions, sizeof(core.extensions), "%s",
		info->valid_extensions ? info->valid_extensions : "");
	core.need_fullpath = info->need_fullpath;
	LOG_info("core: %s version: %s tag: %s (valid_extensions: %s need_fullpath: %i)\n",
		core.name, core.version, core.tag, core.extensions, core.need_fullpath);
}

enum {
	ZERO_RT_FLUSH_MEMORY = 1,
	ZERO_RT_SET_CONTROLLER,
	ZERO_RT_CHANGE_DISC,
};
static int Core_runtimeDirect(uint32_t op, uint32_t arg) {
	switch (op) {
		case ZERO_RT_FLUSH_MEMORY:
			SRAM_write();
			RTC_write();
			return 0;
		case ZERO_RT_SET_CONTROLLER:
			core.set_controller_port_device(0, arg);
			return 0;
		case ZERO_RT_CHANGE_DISC: {
			if (!disk_control_ext.replace_image_index) return -1;
			struct retro_game_info info = {0};
			info.path = game.path;
			info.data = game.data;
			info.size = game.size;
			return disk_control_ext.replace_image_index(0, &info) ? 0 : -1;
		}
		default:
			return -1;
	}
}
static int Core_runtime(uint32_t op, uint32_t arg) {
#ifdef ZERO_FRONTEND_THREADING_V2
	if (zero_ftv2_inited && fc_current_phase() == FCP_NONE) {
		uint64_t request = (uint64_t)op | ((uint64_t)arg << 8);
		return fc_menu_op(&zero_ftv2, FC_OP_RUNTIME, request,
		                  zero_ftv2_drain, NULL);
	}
#endif
	return Core_runtimeDirect(op, arg);
}
static void Core_flushMemory(void) {
	if (Core_runtime(ZERO_RT_FLUSH_MEMORY, 0))
		LOG_error("Error flushing core memory\n");
}
static void Core_setController(unsigned device) {
	if (Core_runtime(ZERO_RT_SET_CONTROLLER, device))
		LOG_error("Error setting controller device %u\n", device);
}
static int Core_changeDisc(void) {
	return Core_runtime(ZERO_RT_CHANGE_DISC, 0);
}
void Core_init(void) {
	LOG_info("Core_init\n");
	core.init();
	core.initialized = 1;
}
static void Core_applyAV(const struct retro_system_av_info* av_info) {
	core.fps = av_info->timing.fps;
	core.sample_rate = av_info->timing.sample_rate;
	double a = av_info->geometry.aspect_ratio;
	if (a<=0) a = (double)av_info->geometry.base_width / av_info->geometry.base_height;
	core.aspect_ratio = a;
	LOG_info("aspect_ratio: %f (%ix%i) fps: %f\n", a,
		av_info->geometry.base_width, av_info->geometry.base_height, core.fps);
}
int Core_load(void) {
	LOG_info("Core_load\n");
	struct retro_game_info game_info;
	game_info.path = game.tmp_path[0]?game.tmp_path:game.path;
	game_info.data = game.data;
	game_info.size = game.size;
	LOG_info("game path: %s (%i)\n", game_info.path, game.size);

	if (!core.load_game(&game_info)) {
		// core rejected the ROM (bad/unsupported file). Stock ignored this and ran an
		// unloaded core -> hang/black-screen needing a hard power-off. Bail cleanly instead.
		LOG_error("core.load_game failed for %s\n", game_info.path);
		return 0;
	}

	SRAM_read();
	RTC_read();
	Crash_install(); // crash-safe saves: arm the emergency SRAM/RTC writer (pointers live now)

	// NOTE: must be called after core.load_game!
	struct retro_system_av_info av_info = {};
	core.get_system_av_info(&av_info);
	core.set_controller_port_device(0, RETRO_DEVICE_JOYPAD); // set a default, may update after loading configs
	Core_applyAV(&av_info);
	return 1;
}
void Core_reset(void) {
#ifdef ZERO_FRONTEND_THREADING_V2
	if (zero_ftv2_inited && fc_current_phase() == FCP_NONE) {
		if (fc_menu_op(&zero_ftv2, FC_OP_RESET, 0, zero_ftv2_drain, NULL))
			LOG_error("Error resetting core\n");
		return;
	}
#endif
	core.reset();
}
void Core_unload(void) {
	SND_quit();
}
void Core_quit(void) {
	if (core.initialized) {
		SRAM_write();
		RTC_write();
		// SRAM/RTC are durable now. Disarm pointers before unload/deinit invalidates them.
		Crash_uninstall();
		core.unload_game();
		core.deinit();
		core.initialized = 0;
	}
}
void Core_close(void) {
	if (core.handle) dlclose(core.handle);
}

///////////////////////////////////////

#define MENU_ITEM_COUNT 5
#define MENU_SLOT_COUNT 8

enum {
	ITEM_CONT,
	ITEM_SAVE,
	ITEM_LOAD,
	ITEM_OPTS,
	ITEM_QUIT,
};

enum {
	STATUS_CONT =  0,
	STATUS_SAVE =  1,
	STATUS_LOAD = 11,
	STATUS_OPTS = 23,
	STATUS_DISC = 24,
	STATUS_QUIT = 30,
	STATUS_RESET= 31,
};

// TODO: I don't love how overloaded this has become
static struct {
	SDL_Surface* bitmap;
	SDL_Surface* overlay;
	char* items[MENU_ITEM_COUNT];
	char* disc_paths[9]; // up to 9 paths, Arc the Lad Collection is 7 discs
	char minui_dir[256];
	char slot_path[256];
	char base_path[256];
	char bmp_path[256];
	char txt_path[256];
	char txn_path[MAX_PATH+8];
	int disc;
	int total_discs;
	int slot;
	int save_exists;
	int preview_exists;
} menu = {
	.bitmap = NULL,
	.disc = -1,
	.total_discs = 0,
	.save_exists = 0,
	.preview_exists = 0,
	
	.items = {
		[ITEM_CONT] = "Continue",
		[ITEM_SAVE] = "Save",
		[ITEM_LOAD] = "Load",
		[ITEM_OPTS] = "Options",
		[ITEM_QUIT] = "Quit",
	}
};

void Menu_init(void) {
	menu.overlay = SDL_CreateRGBSurface(SDL_SWSURFACE,DEVICE_WIDTH,DEVICE_HEIGHT,FIXED_DEPTH,RGBA_MASK_AUTO);
	SDLX_SetAlpha(menu.overlay, SDL_SRCALPHA, 0x80);
	SDL_FillRect(menu.overlay, NULL, 0);
	
	char emu_name[256];
	getEmuName(game.path, emu_name);
	sprintf(menu.minui_dir, SHARED_USERDATA_PATH "/.minui/%s", emu_name);
	mkdir(menu.minui_dir, 0755);

	sprintf(menu.slot_path, "%s/%s.txt", menu.minui_dir, game.name);
	
	if (simple_mode) menu.items[ITEM_OPTS] = "Reset";
	
	if (game.m3u_path[0]) {
		char* tmp;
		strcpy(menu.base_path, game.m3u_path);
		tmp = strrchr(menu.base_path, '/') + 1;
		tmp[0] = '\0';
		
		//read m3u file
		FILE* file = fopen(game.m3u_path, "r");
		if (file) {
			char line[256];
			while (fgets(line,256,file)!=NULL) {
				normalizeNewline(line);
				trimTrailingNewlines(line);
				if (strlen(line)==0) continue; // skip empty lines
		
				char disc_path[256];
				strcpy(disc_path, menu.base_path);
				tmp = disc_path + strlen(disc_path);
				strcpy(tmp, line);
				
				// found a valid disc path
				if (exists(disc_path)) {
					menu.disc_paths[menu.total_discs] = strdup(disc_path);
					// matched our current disc
					if (exactMatch(disc_path, game.path)) {
						menu.disc = menu.total_discs;
					}
					menu.total_discs += 1;
				}
			}
			fclose(file);
		}
	}
}
void Menu_quit(void) {
	SDL_FreeSurface(menu.overlay);
}
void Menu_beforeSleep(void) {
	// LOG_info("beforeSleep\n");
	// depth-2: SRAM_write/RTC_write/State_autosave all read/serialize core state — park the CORE
	// thread first so they can't race an in-flight core.run() (no-op at depth-1/guard-OFF, and no-op
	// when already parked in a menu-context sleep). See zero_ftv2_core_enter.
	int ftv2_parked = zero_ftv2_core_enter();
	Core_flushMemory();
	const char* resume_path = game.path + strlen(SDCARD_PATH);
	int state_saved = State_autosave();
	zero_ftv2_core_leave(ftv2_parked);
	int marker_saved = state_saved
		&& !save_write_atomic(AUTO_RESUME_PATH, resume_path, strlen(resume_path));
	if (!marker_saved) {
		if (!state_saved) LOG_error("Error creating auto-resume state\n");
		else LOG_error("Error publishing auto-resume marker (%s)\n", strerror(errno));
		if (save_remove_file(AUTO_RESUME_PATH))
			LOG_error("Error clearing failed auto-resume marker (%s)\n", strerror(errno));
	}
	#ifdef ZERO_FRONTEND_THREADING_V2
		// Known-good point: everything is saved. Clear the depth-2 crash canary so a poweroff from
		// here (the quicksave flow never returns) doesn't read as a bad exit. Re-armed on wake.
		if (marker_saved && zero_ftv2_canary_armed && zero_ftv2_canary_clearable) {
			if (!zero_ftv2_canary_remove(zero_ftv2_canary)) zero_ftv2_canary_armed = 0;
		}
		if (marker_saved && zero_ftv2_depth2) zero_ftv2_failures_clear();
	#endif
	PWR_setCPUSpeed(CPU_SPEED_MENU);
}
void Menu_afterSleep(void) {
	// LOG_info("beforeSleep\n");
	if (save_remove_file(AUTO_RESUME_PATH))
		LOG_error("Error clearing auto-resume marker (%s)\n", strerror(errno));
	// PWR_sleep blocked inside core.run. Discard the partial timing window so the
	// sleep interval cannot be classified as a gameplay slowdown on resume.
	RunLoop_resetWindow();
	Gov_restore();
	dup_force_present = 1; // wake repaint may be byte-identical; present it anyway
#ifdef ZERO_FRONTEND_THREADING_V2
	// Woke back into a live depth-2 session: re-arm the crash canary (cleared by Menu_beforeSleep).
	if (zero_ftv2_inited && zero_ftv2_depth2 && zero_ftv2_canary[0] && !zero_ftv2_canary_armed) {
			if (zero_ftv2_canary_write(zero_ftv2_canary, "depth2\n") == 0)
				zero_ftv2_canary_armed = 1;   // Codex #11: only on a synced, complete write
		// (write failure: continue unprotected-but-running — the session was already depth-2;
		// the next launch's arm attempt will fall back to serial if the card is still bad)
	}
#endif
}

typedef struct MenuList MenuList;
typedef struct MenuItem MenuItem;
enum {
	MENU_CALLBACK_NOP,
	MENU_CALLBACK_EXIT,
	MENU_CALLBACK_NEXT_ITEM,
};
typedef int (*MenuList_callback_t)(MenuList* list, int i);
typedef struct MenuItem {
	char* name;
	char* desc;
	char** values;
	char* key; // optional, used by options
	int id; // optional, used by bindings
	int value;
	MenuList* submenu;
	MenuList_callback_t on_confirm;
	MenuList_callback_t on_change;
} MenuItem;

enum {
	MENU_LIST, // eg. save and main menu
	MENU_VAR, // eg. frontend
	MENU_FIXED, // eg. emulator
	MENU_INPUT, // eg. renders like but MENU_VAR but handles input differently
};
typedef struct MenuList {
	int type;
	int max_width; // cached on first draw
	char* desc;
	MenuItem* items;
	MenuList_callback_t on_confirm;
	MenuList_callback_t on_change;
} MenuList;

static int Menu_message(char* message, char** pairs) {
	GFX_setMode(MODE_MAIN);
	int dirty = 1;
	while (1) {
		GFX_startFrame();
		PAD_poll();

		if (PAD_justPressed(BTN_A) || PAD_justPressed(BTN_B)) break;
		
		PWR_update(&dirty, NULL, Menu_beforeSleep, Menu_afterSleep);
		
		if (dirty) {
			GFX_clear(screen);
			GFX_blitMessage(font.medium, message, screen, &(SDL_Rect){0,SCALE1(PADDING),screen->w,screen->h-SCALE1(PILL_SIZE+PADDING)});
			GFX_blitButtonGroup(pairs, 0, screen, 1);
			GFX_flip(screen);
			dirty = 0;
		}
		else GFX_sync();
		
		hdmimon();
	}
	GFX_setMode(MODE_MENU);
	return MENU_CALLBACK_NOP; // TODO: this should probably be an arg
}

static int Menu_options(MenuList* list);

static int MenuList_freeItems(MenuList* list, int i) {
	// TODO: what calls this? do menu's register for needing it? then call it on quit for each?
	if (list->items) free(list->items);
	return MENU_CALLBACK_NOP;
}

static int OptionFrontend_optionChanged(MenuList* list, int i) {
	MenuItem* item = &list->items[i];
	Config_syncFrontend(item->key, item->value);
	return MENU_CALLBACK_NOP;
}
static MenuList OptionFrontend_menu = {
	.type = MENU_VAR,
	.on_change = OptionFrontend_optionChanged,
	.items = NULL,
};
static int OptionFrontend_openMenu(MenuList* list, int i) {
	if (OptionFrontend_menu.items==NULL) {
		// TODO: where do I free this? I guess I don't :sweat_smile:
		if (!config.frontend.enabled_count) {
			int enabled_count = 0;
			for (int i=0; i<config.frontend.count; i++) {
				if (!config.frontend.options[i].lock) enabled_count += 1;
			}
			config.frontend.enabled_count = enabled_count;
			config.frontend.enabled_options = calloc(enabled_count+1, sizeof(Option*));
			int j = 0;
			for (int i=0; i<config.frontend.count; i++) {
				Option* item = &config.frontend.options[i];
				if (item->lock) continue;
				config.frontend.enabled_options[j] = item;
				j += 1;
			}
		}

		OptionFrontend_menu.items = calloc(config.frontend.enabled_count+1, sizeof(MenuItem));
		for (int j=0; j<config.frontend.enabled_count; j++) {
			Option* option = config.frontend.enabled_options[j];
			MenuItem* item = &OptionFrontend_menu.items[j];
			item->key = option->key;
			item->name = option->name;
			item->desc = option->desc;
			item->value = option->value;
			item->values = option->labels;
		}
	}
	else {
		// update values
		for (int j=0; j<config.frontend.enabled_count; j++) {
			Option* option = config.frontend.enabled_options[j];
			MenuItem* item = &OptionFrontend_menu.items[j];
			item->value = option->value;
		}
	}
	
	Menu_options(&OptionFrontend_menu);
	return MENU_CALLBACK_NOP;
}

static int OptionEmulator_optionChanged(MenuList* list, int i) {
	MenuItem* item = &list->items[i];
	Option* option = OptionList_getOption(&config.core, item->key);
	LOG_info("%s (%s) changed from `%s` (%s) to `%s` (%s)\n", item->name, item->key, 
		item->values[option->value], option->values[option->value], 
		item->values[item->value], option->values[item->value]
	);
	OptionList_setOptionRawValue(&config.core, item->key, item->value);
	return MENU_CALLBACK_NOP;
}
static int OptionEmulator_optionDetail(MenuList* list, int i) {
	MenuItem* item = &list->items[i];
	Option* option = OptionList_getOption(&config.core, item->key);
	if (option->full) return Menu_message(option->full, (char*[]){ "B","BACK", NULL });
	else return MENU_CALLBACK_NOP;
}
static MenuList OptionEmulator_menu = {
	.type = MENU_FIXED,
	.on_confirm = OptionEmulator_optionDetail, // TODO: this needs pagination to be truly useful
	.on_change = OptionEmulator_optionChanged,
	.items = NULL,
};
static int OptionEmulator_openMenu(MenuList* list, int i) {
	if (OptionEmulator_menu.items==NULL) {
		// TODO: where do I free this? I guess I don't :sweat_smile:
		if (!config.core.enabled_count) {
			int enabled_count = 0;
			for (int i=0; i<config.core.count; i++) {
				if (!config.core.options[i].lock) enabled_count += 1;
			}
			config.core.enabled_count = enabled_count;
			config.core.enabled_options = calloc(enabled_count+1, sizeof(Option*));
			int j = 0;
			for (int i=0; i<config.core.count; i++) {
				Option* item = &config.core.options[i];
				if (item->lock) continue;
				config.core.enabled_options[j] = item;
				j += 1;
			}
		}
		
		OptionEmulator_menu.items = calloc(config.core.enabled_count+1, sizeof(MenuItem));
		for (int j=0; j<config.core.enabled_count; j++) {
			Option* option = config.core.enabled_options[j];
			MenuItem* item = &OptionEmulator_menu.items[j];
			item->key = option->key;
			item->name = option->name;
			item->desc = option->desc;
			item->value = option->value;
			item->values = option->labels;
		}
	}
	else {
		// update values
		for (int j=0; j<config.core.enabled_count; j++) {
			Option* option = config.core.enabled_options[j];
			MenuItem* item = &OptionEmulator_menu.items[j];
			item->value = option->value;
		}
	}
	
	if (OptionEmulator_menu.items[0].name) { // TODO: why doesn't this just use (enabled_)count?
		Menu_options(&OptionEmulator_menu);
	}
	else {
		Menu_message("This core has no options.", (char*[]){ "B","BACK", NULL });
	}
	
	return MENU_CALLBACK_NOP;
}

int OptionControls_bind(MenuList* list, int i) {
	MenuItem* item = &list->items[i];
	if (item->values!=button_labels) {
		// LOG_info("changed gamepad_type\n");
		return MENU_CALLBACK_NOP;
	}
	
	ButtonMapping* button = &config.controls[item->id];
	
	int bound = 0;
	while (!bound) {
		GFX_startFrame();
		PAD_poll();
		
		// NOTE: off by one because of the initial NONE value
		for (int id=0; id<=LOCAL_BUTTON_COUNT; id++) {
			if (PAD_justPressed(1 << (id-1))) {
				item->value = id;
				button->local = id - 1;
				if (PAD_isPressed(BTN_MENU)) {
					item->value += LOCAL_BUTTON_COUNT;
					button->mod = 1;
				}
				else {
					button->mod = 0;
				}
				bound = 1;
				break;
			}
		}
		GFX_sync();
		hdmimon();
	}
	return MENU_CALLBACK_NEXT_ITEM;
}
static int OptionControls_unbind(MenuList* list, int i) {
	MenuItem* item = &list->items[i];
	if (item->values!=button_labels) return MENU_CALLBACK_NOP;
	
	ButtonMapping* button = &config.controls[item->id];
	button->local = -1;
	button->mod = 0;
	return MENU_CALLBACK_NOP;
}
static int OptionControls_optionChanged(MenuList* list, int i) {
	MenuItem* item = &list->items[i];
	if (item->values!=gamepad_labels) return MENU_CALLBACK_NOP;

	if (has_custom_controllers) {
		gamepad_type = item->value;
		int device = strtol(gamepad_values[item->value], NULL, 0);
		Core_setController(device);
	}
	return MENU_CALLBACK_NOP;
}
static MenuList OptionControls_menu = {
	.type = MENU_INPUT,
	.desc = "Press A to set and X to clear."
		"\nSupports single button and MENU+button." // TODO: not supported on nano because POWER doubles as MENU
	,
	.on_confirm = OptionControls_bind,
	.on_change = OptionControls_unbind,
	.items = NULL
};
static int OptionControls_openMenu(MenuList* list, int i) {
	LOG_info("OptionControls_openMenu\n");

	if (OptionControls_menu.items==NULL) {
		
		// TODO: where do I free this?
		OptionControls_menu.items = calloc(RETRO_BUTTON_COUNT+1+has_custom_controllers, sizeof(MenuItem));
		int k = 0;
		
		if (has_custom_controllers) {
			MenuItem* item = &OptionControls_menu.items[k++];
			item->name = "Controller";
			item->desc = "Select the type of controller.";
			item->value = gamepad_type;
			item->values = gamepad_labels;
			item->on_change = OptionControls_optionChanged;
		}
		
		for (int j=0; config.controls[j].name; j++) {
			ButtonMapping* button = &config.controls[j];
			if (button->ignore) continue;
			
			LOG_info("\t%s (%i:%i)\n", button->name, button->local, button->retro);
			
			MenuItem* item = &OptionControls_menu.items[k++];
			item->id = j;
			item->name = button->name;
			item->desc = NULL;
			item->value = button->local + 1;
			if (button->mod) item->value += LOCAL_BUTTON_COUNT;
			item->values = button_labels;
		}
	}
	else {
		// update values
		int k = 0;
		
		if (has_custom_controllers) {
			MenuItem* item = &OptionControls_menu.items[k++];
			item->value = gamepad_type;
		}
		
		for (int j=0; config.controls[j].name; j++) {
			ButtonMapping* button = &config.controls[j];
			if (button->ignore) continue;
			
			MenuItem* item = &OptionControls_menu.items[k++];
			item->value = button->local + 1;
			if (button->mod) item->value += LOCAL_BUTTON_COUNT;
		}
	}
	Menu_options(&OptionControls_menu);
	return MENU_CALLBACK_NOP;
}

static int OptionShortcuts_bind(MenuList* list, int i) {
	MenuItem* item = &list->items[i];
	ButtonMapping* button = &config.shortcuts[item->id];
	int bound = 0;
	while (!bound) {
		GFX_startFrame();
		PAD_poll();
		
		// NOTE: off by one because of the initial NONE value
		for (int id=0; id<=LOCAL_BUTTON_COUNT; id++) {
			if (PAD_justPressed(1 << (id-1))) {
				item->value = id;
				button->local = id - 1;
				if (PAD_isPressed(BTN_MENU)) {
					item->value += LOCAL_BUTTON_COUNT;
					button->mod = 1;
				}
				else {
					button->mod = 0;
				}
				bound = 1;
				break;
			}
		}
		GFX_sync();
		hdmimon();
	}
	return MENU_CALLBACK_NEXT_ITEM;
}
static int OptionShortcuts_unbind(MenuList* list, int i) {
	MenuItem* item = &list->items[i];
	ButtonMapping* button = &config.shortcuts[item->id];
	button->local = -1;
	button->mod = 0;
	return MENU_CALLBACK_NOP;
}
static MenuList OptionShortcuts_menu = {
	.type = MENU_INPUT,
	.desc = "Press A to set and X to clear." 
		"\nSupports single button and MENU+button." // TODO: not supported on nano because POWER doubles as MENU
	,
	.on_confirm = OptionShortcuts_bind,
	.on_change = OptionShortcuts_unbind,
	.items = NULL
};
static char* getSaveDesc(void) {
	switch (config.loaded) {
		case CONFIG_NONE:		return "Using defaults."; break;
		case CONFIG_CONSOLE:	return "Using console config."; break;
		case CONFIG_GAME:		return "Using game config."; break;
	}
	return NULL;
}
static int OptionShortcuts_openMenu(MenuList* list, int i) {
	if (OptionShortcuts_menu.items==NULL) {
		// TODO: where do I free this? I guess I don't :sweat_smile:
		OptionShortcuts_menu.items = calloc(SHORTCUT_COUNT+1, sizeof(MenuItem));
		for (int j=0; config.shortcuts[j].name; j++) {
			ButtonMapping* button = &config.shortcuts[j];
			MenuItem* item = &OptionShortcuts_menu.items[j];
			item->id = j;
			item->name = button->name;
			item->desc = NULL;
			item->value = button->local + 1;
			if (button->mod) item->value += LOCAL_BUTTON_COUNT;
			item->values = button_labels;
		}
	}
	else {
		// update values
		for (int j=0; config.shortcuts[j].name; j++) {
			ButtonMapping* button = &config.shortcuts[j];
			MenuItem* item = &OptionShortcuts_menu.items[j];
			item->value = button->local + 1;
			if (button->mod) item->value += LOCAL_BUTTON_COUNT;
		}
	}
	Menu_options(&OptionShortcuts_menu);
	return MENU_CALLBACK_NOP;
}

static void OptionSaveChanges_updateDesc(void);
static int OptionSaveChanges_onConfirm(MenuList* list, int i) {
	char* message;
	switch (i) {
		case 0: {
			Config_write(CONFIG_WRITE_ALL);
			message = "Saved for console.";
			break;
		}
		case 1: {
			Config_write(CONFIG_WRITE_GAME);
			message = "Saved for game.";
			break;
		}
		default: {
			Config_restore();
			if (config.loaded) message = "Restored console defaults.";
			else message = "Restored defaults.";
			break;
		}
	}
	Menu_message(message, (char*[]){ "A","OKAY", NULL });
	OptionSaveChanges_updateDesc();
	return MENU_CALLBACK_EXIT;
}
static MenuList OptionSaveChanges_menu = {
	.type = MENU_LIST,
	.on_confirm = OptionSaveChanges_onConfirm,
	.items = (MenuItem[]){
		{"Save for console"},
		{"Save for game"},
		{"Restore defaults"},
		{NULL},
	}
};
static int OptionSaveChanges_openMenu(MenuList* list, int i) {
	OptionSaveChanges_updateDesc();
	OptionSaveChanges_menu.desc = getSaveDesc();
	Menu_options(&OptionSaveChanges_menu);
	return MENU_CALLBACK_NOP;
}

static int OptionQuicksave_onConfirm(MenuList* list, int i) {
	Menu_beforeSleep();
	PWR_powerOff();
}

static MenuList options_menu = {
	.type = MENU_LIST,
	.items = (MenuItem[]) {
		{"Frontend", "MinUI (" BUILD_DATE " " BUILD_HASH ")",.on_confirm=OptionFrontend_openMenu},
		{"Emulator",.on_confirm=OptionEmulator_openMenu},
		{"Controls",.on_confirm=OptionControls_openMenu},
		{"Shortcuts",.on_confirm=OptionShortcuts_openMenu}, 
		{"Save Changes",.on_confirm=OptionSaveChanges_openMenu},
		{NULL},
		{NULL},
		{NULL},
	}
};

static void OptionSaveChanges_updateDesc(void) {
	options_menu.items[4].desc = getSaveDesc();
}

#define OPTION_PADDING 8

static int Menu_options(MenuList* list) {
	MenuItem* items = list->items;
	int type = list->type;

	int dirty = 1;
	int show_options = 1;
	int show_settings = 0;
	int await_input = 0;
	
	// dependent on option list offset top and bottom, eg. the gray triangles
	int max_visible_options = (screen->h - ((SCALE1(PADDING + PILL_SIZE) * 2) + SCALE1(BUTTON_SIZE))) / SCALE1(BUTTON_SIZE); // 7 for 480, 10 for 720
	
	int count;
	for (count=0; items[count].name; count++);
	int selected = 0;
	int start = 0;
	int end = MIN(count,max_visible_options);
	int visible_rows = end;
	
	OptionSaveChanges_updateDesc();
	
	int defer_menu = false;
	while (show_options) {
		if (await_input) {
			defer_menu = true;
			list->on_confirm(list, selected);
			
			selected += 1;
			if (selected>=count) {
				selected = 0;
				start = 0;
				end = visible_rows;
			}
			else if (selected>=end) {
				start += 1;
				end += 1;
			}
			dirty = 1;
			await_input = false;
		}
		
		GFX_startFrame();
		PAD_poll();
		
		if (PAD_justRepeated(BTN_UP)) {
			selected -= 1;
			if (selected<0) {
				selected = count - 1;
				start = MAX(0,count - max_visible_options);
				end = count;
			}
			else if (selected<start) {
				start -= 1;
				end -= 1;
			}
			dirty = 1;
		}
		else if (PAD_justRepeated(BTN_DOWN)) {
			selected += 1;
			if (selected>=count) {
				selected = 0;
				start = 0;
				end = visible_rows;
			}
			else if (selected>=end) {
				start += 1;
				end += 1;
			}
			dirty = 1;
		}
		else {
			MenuItem* item = &items[selected];
			if (item->values && item->values!=button_labels) { // not an input binding
				if (PAD_justRepeated(BTN_LEFT)) {
					if (item->value>0) item->value -= 1;
					else {
						int j;
						for (j=0; item->values[j]; j++);
						item->value = j - 1;
					}
				
					if (item->on_change) item->on_change(list, selected);
					else if (list->on_change) list->on_change(list, selected);
				
					dirty = 1;
				}
				else if (PAD_justRepeated(BTN_RIGHT)) {
					if (item->values[item->value+1]) item->value += 1;
					else item->value = 0;
				
					if (item->on_change) item->on_change(list, selected);
					else if (list->on_change) list->on_change(list, selected);
				
					dirty = 1;
				}
			}
		}
		
		// uint32_t now = SDL_GetTicks();
		if (PAD_justPressed(BTN_B)) { // || PAD_tappedMenu(now)
			show_options = 0;
		}
		else if (PAD_justPressed(BTN_A)) {
			MenuItem* item = &items[selected];
			int result = MENU_CALLBACK_NOP;
			if (item->on_confirm) result = item->on_confirm(list, selected); // item-specific action, eg. Save for all games
			else if (item->submenu) result = Menu_options(item->submenu); // drill down, eg. main options menu
			// TODO: is there a way to defer on_confirm for MENU_INPUT so we can clear the currently set value to indicate it is awaiting input? 
			// eg. set a flag to call on_confirm at the beginning of the next frame?
			else if (list->on_confirm) {
				if (item->values==button_labels) await_input = 1; // button binding
				else result = list->on_confirm(list, selected); // list-specific action, eg. show item detail view or input binding
			}
			if (result==MENU_CALLBACK_EXIT) show_options = 0;
			else {
				if (result==MENU_CALLBACK_NEXT_ITEM) {
					// copied from PAD_justRepeated(BTN_DOWN) above
					selected += 1;
					if (selected>=count) {
						selected = 0;
						start = 0;
						end = visible_rows;
					}
					else if (selected>=end) {
						start += 1;
						end += 1;
					}
				}
				dirty = 1;
			}
		}
		else if (type==MENU_INPUT) {
			if (PAD_justPressed(BTN_X)) {
				MenuItem* item = &items[selected];
				item->value = 0;
				
				if (item->on_change) item->on_change(list, selected);
				else if (list->on_change) list->on_change(list, selected);
				
				// copied from PAD_justRepeated(BTN_DOWN) above
				selected += 1;
				if (selected>=count) {
					selected = 0;
					start = 0;
					end = visible_rows;
				}
				else if (selected>=end) {
					start += 1;
					end += 1;
				}
				dirty = 1;
			}
		}
		
		if (!defer_menu) PWR_update(&dirty, &show_settings, Menu_beforeSleep, Menu_afterSleep);
		
		if (defer_menu && PAD_justReleased(BTN_MENU)) defer_menu = false;
		
		if (dirty) {
			GFX_clear(screen);
			GFX_blitHardwareGroup(screen, show_settings);

			char* desc = NULL;
			SDL_Surface* text;

			if (type==MENU_LIST) {
				int mw = list->max_width;
				if (!mw) {
					// get the width of the widest item
					for (int i=0; i<count; i++) {
						MenuItem* item = &items[i];
						int w = 0;
						TTF_SizeUTF8(font.small, item->name, &w, NULL);
						w += SCALE1(OPTION_PADDING*2);
						if (w>mw) mw = w;
					}
					// cache the result
					list->max_width = mw = MIN(mw, screen->w - SCALE1(PADDING *2));
				}
				
				int ox = (screen->w - mw) / 2;
				int oy = SCALE1(PADDING + PILL_SIZE);
				int selected_row = selected - start;
				for (int i=start,j=0; i<end; i++,j++) {
					MenuItem* item = &items[i];
					SDL_Color text_color = COLOR_WHITE;

					// int ox = (screen->w - w) / 2; // if we're centering these (but I don't think we should after seeing it)
					if (j==selected_row) {
						// move out of conditional if centering
						int w = 0;
						TTF_SizeUTF8(font.small, item->name, &w, NULL);
						w += SCALE1(OPTION_PADDING*2);
						
						GFX_blitPill(ASSET_BUTTON, screen, &(SDL_Rect){
							ox,
							oy+SCALE1(j*BUTTON_SIZE),
							w,
							SCALE1(BUTTON_SIZE)
						});
						text_color = COLOR_BLACK;
						
						if (item->desc) desc = item->desc;
					}
					text = TTF_RenderUTF8_Blended(font.small, item->name, text_color);
					SDL_BlitSurface(text, NULL, screen, &(SDL_Rect){
						ox+SCALE1(OPTION_PADDING),
						oy+SCALE1((j*BUTTON_SIZE)+1)
					});
					SDL_FreeSurface(text);
				}
			}
			else if (type==MENU_FIXED) {
				// NOTE: no need to calculate max width
				int mw = screen->w - SCALE1(PADDING*2);
				// int lw,rw;
				// lw = rw = mw / 2;
				int ox,oy;
				ox = oy = SCALE1(PADDING);
				oy += SCALE1(PILL_SIZE);
				
				int selected_row = selected - start;
				for (int i=start,j=0; i<end; i++,j++) {
					MenuItem* item = &items[i];
					SDL_Color text_color = COLOR_WHITE;

					if (j==selected_row) {
						// gray pill
						GFX_blitPill(ASSET_OPTION, screen, &(SDL_Rect){
							ox,
							oy+SCALE1(j*BUTTON_SIZE),
							mw,
							SCALE1(BUTTON_SIZE)
						});
					}
					
					if (item->value>=0) {
						text = TTF_RenderUTF8_Blended(font.tiny, item->values[item->value], COLOR_WHITE); // always white
						SDL_BlitSurface(text, NULL, screen, &(SDL_Rect){
							ox + mw - text->w - SCALE1(OPTION_PADDING),
							oy+SCALE1((j*BUTTON_SIZE)+3)
						});
						SDL_FreeSurface(text);
					}
					
					// TODO: blit a black pill on unselected rows (to cover longer item->values?) or truncate longer item->values?
					if (j==selected_row) {
						// white pill
						int w = 0;
						TTF_SizeUTF8(font.small, item->name, &w, NULL);
						w += SCALE1(OPTION_PADDING*2);
						GFX_blitPill(ASSET_BUTTON, screen, &(SDL_Rect){
							ox,
							oy+SCALE1(j*BUTTON_SIZE),
							w,
							SCALE1(BUTTON_SIZE)
						});
						text_color = COLOR_BLACK;
						
						if (item->desc) desc = item->desc;
					}
					text = TTF_RenderUTF8_Blended(font.small, item->name, text_color);
					SDL_BlitSurface(text, NULL, screen, &(SDL_Rect){
						ox+SCALE1(OPTION_PADDING),
						oy+SCALE1((j*BUTTON_SIZE)+1)
					});
					SDL_FreeSurface(text);
				}
			}
			else if (type==MENU_VAR || type==MENU_INPUT) {
				int mw = list->max_width;
				if (!mw) {
					// get the width of the widest row
					int mrw = 0;
					for (int i=0; i<count; i++) {
						MenuItem* item = &items[i];
						int w = 0;
						int lw = 0;
						int rw = 0;
						TTF_SizeUTF8(font.small, item->name, &lw, NULL);
						
						// every value list in an input table is the same
						// so only calculate rw for the first item...
						if (!mrw || type!=MENU_INPUT) {
							for (int j=0; item->values[j]; j++) {
								TTF_SizeUTF8(font.tiny, item->values[j], &rw, NULL);
								if (lw+rw>w) w = lw+rw;
								if (rw>mrw) mrw = rw;
							}
						}
						else {
							w = lw + mrw;
						}
						w += SCALE1(OPTION_PADDING*4);
						if (w>mw) mw = w;
					}
					fflush(stdout);
					// cache the result
					list->max_width = mw = MIN(mw, screen->w - SCALE1(PADDING *2));
				}
				
				int ox = (screen->w - mw) / 2;
				int oy = SCALE1(PADDING + PILL_SIZE);
				int selected_row = selected - start;
				for (int i=start,j=0; i<end; i++,j++) {
					MenuItem* item = &items[i];
					SDL_Color text_color = COLOR_WHITE;

					if (j==selected_row) {
						// gray pill
						GFX_blitPill(ASSET_OPTION, screen, &(SDL_Rect){
							ox,
							oy+SCALE1(j*BUTTON_SIZE),
							mw,
							SCALE1(BUTTON_SIZE)
						});
						
						// white pill
						int w = 0;
						TTF_SizeUTF8(font.small, item->name, &w, NULL);
						w += SCALE1(OPTION_PADDING*2);
						GFX_blitPill(ASSET_BUTTON, screen, &(SDL_Rect){
							ox,
							oy+SCALE1(j*BUTTON_SIZE),
							w,
							SCALE1(BUTTON_SIZE)
						});
						text_color = COLOR_BLACK;
						
						if (item->desc) desc = item->desc;
					}
					text = TTF_RenderUTF8_Blended(font.small, item->name, text_color);
					SDL_BlitSurface(text, NULL, screen, &(SDL_Rect){
						ox+SCALE1(OPTION_PADDING),
						oy+SCALE1((j*BUTTON_SIZE)+1)
					});
					SDL_FreeSurface(text);
					
					if (await_input && j==selected_row) {
						// buh
					}
					else if (item->value>=0) {
						text = TTF_RenderUTF8_Blended(font.tiny, item->values[item->value], COLOR_WHITE); // always white
						SDL_BlitSurface(text, NULL, screen, &(SDL_Rect){
							ox + mw - text->w - SCALE1(OPTION_PADDING),
							oy+SCALE1((j*BUTTON_SIZE)+3)
						});
						SDL_FreeSurface(text);
					}
				}
			}
			
			if (count>max_visible_options) {
				#define SCROLL_WIDTH 24
				#define SCROLL_HEIGHT 4
				int ox = (screen->w - SCALE1(SCROLL_WIDTH))/2;
				int oy = SCALE1((PILL_SIZE - SCROLL_HEIGHT) / 2);
				if (start>0) GFX_blitAsset(ASSET_SCROLL_UP,   NULL, screen, &(SDL_Rect){ox, SCALE1(PADDING) + oy});
				if (end<count) GFX_blitAsset(ASSET_SCROLL_DOWN, NULL, screen, &(SDL_Rect){ox, screen->h - SCALE1(PADDING + PILL_SIZE + BUTTON_SIZE) + oy});
			}
			
			if (!desc && list->desc) desc = list->desc;
			
			if (desc) {
				int w,h;
				GFX_sizeText(font.tiny, desc, SCALE1(12), &w,&h);
				GFX_blitText(font.tiny, desc, SCALE1(12), COLOR_WHITE, screen, &(SDL_Rect){
					(screen->w - w) / 2,
					screen->h - SCALE1(PADDING) - h,
					w,h
				});
			}
			
			GFX_flip(screen);
			dirty = 0;
		}
		else GFX_sync();
		hdmimon();
	}
	
	// GFX_clearAll();
	// GFX_flip(screen);
	
	return 0;
}

// 50% darken, in place, pure RGB565 arithmetic. This replaces the menu.overlay alpha blit as the
// menu's dim layer: SDLX_SetAlpha + a 16bpp alpha-mod blit depends on the platform SDL build
// honouring per-surface alpha on 565 surfaces, and on the h700 SDL2 it silently does nothing, so
// the in-game menu drew raw over the undimmed game art and every ~1s repaint read as a visible
// flash (Dan video, measured 2026-08-27). A shift-and-mask halving cannot be skipped by any SDL.
static void Menu_dim(SDL_Surface* dst) {
	uint16_t* d = dst->pixels;
	int dp = dst->pitch / FIXED_BPP;
	for (int y = 0; y < dst->h; y++, d += dp)
		for (int x = 0; x < dst->w; x++)
			d[x] = (d[x] >> 1) & 0x7BEF; // halve R,G,B in place (565)
}
static void Menu_scale(SDL_Surface* src, SDL_Surface* dst) {
	// LOG_info("Menu_scale src: %ix%i dst: %ix%i\n", src->w,src->h,dst->w,dst->h);
	
	uint16_t* s = src->pixels;
	uint16_t* d = dst->pixels;
	
	int sw = src->w;
	int sh = src->h;
	int sp = src->pitch / FIXED_BPP;
	
	int dw = dst->w;
	int dh = dst->h;
	int dp = dst->pitch / FIXED_BPP;
	
	int rx = 0;
	int ry = 0;
	int rw = dw;
	int rh = dh;
	
	int scaling = screen_scaling;
	if (scaling==SCALE_CROPPED && DEVICE_WIDTH==HDMI_WIDTH) {
		scaling = SCALE_NATIVE;
	}
	if (0) {} else if (scaling==SCALE_NATIVE) {
		// LOG_info("native\n");
		
		rx = renderer.dst_x;
		ry = renderer.dst_y;
		rw = renderer.src_w;
		rh = renderer.src_h;
		if (renderer.scale) {
			// LOG_info("scale: %i\n", renderer.scale);
			rw *= renderer.scale;
			rh *= renderer.scale;
		}
		else {
			// LOG_info("forced crop\n"); // eg. fc on nano, vb on smart
			rw -= renderer.src_x * 2;
			rh -= renderer.src_y * 2;
			sw = rw;
			sh = rh;
		}
		
		if (dw==DEVICE_WIDTH/2) {
			// LOG_info("halve\n");
			rx /= 2;
			ry /= 2;
			rw /= 2;
			rh /= 2;
		}
	}
	else if (scaling==SCALE_CROPPED) {
		// LOG_info("cropped\n");
		sw -= renderer.src_x * 2;
		sh -= renderer.src_y * 2;

		rx = renderer.dst_x;
		ry = renderer.dst_y;
		rw = sw * renderer.scale;
		rh = sh * renderer.scale;
		
		if (dw==DEVICE_WIDTH/2) {
			// LOG_info("halve\n");
			rx /= 2;
			ry /= 2;
			rw /= 2;
			rh /= 2;
		}
	}
	
	if (scaling==SCALE_ASPECT || rw>dw || rh>dh) {
		// LOG_info("aspect\n");
		double fixed_aspect_ratio = ((double)DEVICE_WIDTH) / DEVICE_HEIGHT;
		int core_aspect = core.aspect_ratio * 1000;
		int fixed_aspect = fixed_aspect_ratio * 1000;
		
		if (core_aspect>fixed_aspect) {
			// LOG_info("letterbox\n");
			rw = dw;
			rh = rw / core.aspect_ratio;
			rh += rh%2;
		}
		else if (core_aspect<fixed_aspect) {
			// LOG_info("pillarbox\n");
			rh = dh;
			rw = rh * core.aspect_ratio;
			rw += rw%2;
			rw = (rw/8)*8; // probably necessary here since we're not scaling by an integer
		}
		else {
			// LOG_info("perfect match\n");
			rw = dw;
			rh = dh;
		}
		
		rx = (dw - rw) / 2;
		ry = (dh - rh) / 2;
	}
	
#if defined(GOV_PLATFORM_H700)
	if (screen_effect != EFFECT_NONE &&
	    (scaling == SCALE_ASPECT || scaling == SCALE_FULLSCREEN)) {
		// The effect path already has a panel-space rectangle. Reuse it for the
		// menu/thumbnail instead of snapping the width to a different multiple of 8.
		rx = renderer.dst_x * dw / DEVICE_WIDTH;
		ry = renderer.dst_y * dh / DEVICE_HEIGHT;
		rw = renderer.dst_w * dw / DEVICE_WIDTH;
		rh = renderer.dst_h * dh / DEVICE_HEIGHT;
	}
#endif
	// The menu backdrop rect is computed as upstream does unless the effect path above
	// already supplied a final-resolution rect.
	// It must land on renderer.dst_x/dst_y at src*scale: the same pixels the live game occupies.
	// That is what makes opening the menu geometrically a no-op: the game does not move or
	// resize, it just dims and gains chrome. h700 briefly overrode this to fill the surface,
	// which grew a 480x432 GBC to 640x480 the instant MENU was pressed. That growth WAS the
	// "resizing on the fly" jitter (root-caused from Dan's 60fps capture, 2026-08-28).
	// Twice per menu session, not per frame. Kept enabled because this one line is the receipt
	// that the backdrop lands on the live game: it must match the platform's game rect exactly.
	LOG_info("Menu_scale backdrop: %i,%i %ix%i (surface %ix%i)\n", rx,ry,rw,rh, dw,dh);
	// LOG_info("offset: %i,%i\n", renderer.src_x, renderer.src_y);

	// dumb nearest neighbor scaling
	int mx = (sw << 16) / rw;
	int my = (sh << 16) / rh;
	int ox = (renderer.src_x << 16);
	int sx = ox;
	int sy = (renderer.src_y << 16);
	int lr = -1;
	int sr = 0;
	int dr = ry * dp;
	int cp = dp * FIXED_BPP;
	
	// LOG_info("Menu_scale (s): %i,%i %ix%i\n",sx,sy,sw,sh);
	// LOG_info("mx:%i my:%i sx>>16:%i sy>>16:%i\n",mx,my,((sx+mx) >> 16),((sy+my) >> 16));

	for (int dy=0; dy<rh; dy++) {
		sx = ox;
		sr = (sy >> 16) * sp;
		if (sr==lr) {
			memcpy(d+dr,d+dr-dp,cp);
		}
		else {
	        for (int dx=0; dx<rw; dx++) {
	            d[dr + rx + dx] = s[sr + (sx >> 16)];
				sx += mx;
	        }
		}
		lr = sr;
		sy += my;
		dr += dp;
    }
	
	// LOG_info("successful\n");
}

static void Menu_initState(void) {
	if (exists(menu.slot_path)) menu.slot = getInt(menu.slot_path);
	if (menu.slot==8) menu.slot = 0;
	
	menu.save_exists = 0;
	menu.preview_exists = 0;
}
static void Menu_updateState(void) {
	// LOG_info("Menu_updateState\n");

	int last_slot = state_slot;
	state_slot = menu.slot;

	char save_path[MAX_PATH];
	State_getPath(save_path);

	state_slot = last_slot;

	sprintf(menu.bmp_path, "%s/%s.%d.bmp", menu.minui_dir, game.name, menu.slot);
	sprintf(menu.txt_path, "%s/%s.%d.txt", menu.minui_dir, game.name, menu.slot);
	snprintf(menu.txn_path, sizeof(menu.txn_path), "%s.txn", save_path);
	
	menu.save_exists = exists(save_path) && !exists(menu.txn_path);
	menu.preview_exists = menu.save_exists && exists(menu.bmp_path);

	// LOG_info("save_path: %s (%i)\n", save_path, menu.save_exists);
	// LOG_info("bmp_path: %s txt_path: %s (%i)\n", menu.bmp_path, menu.txt_path, menu.preview_exists);
}
static int Menu_saveState(void) {
	// LOG_info("Menu_saveState\n");

	Menu_updateState();
	int transaction_started = 0;
	int result = 0;

	if (menu.total_discs) {
		if (menu.disc < 0 || menu.disc >= menu.total_discs) {
			LOG_error("Cannot save state: current disc is unknown\n");
			return 0;
		}
		// A durable marker makes a power cut between the state and disc sidecar fail closed.
		// The slot becomes visible again only after both files are durable.
		if (save_write_atomic(menu.txn_path, NULL, 0)) {
			LOG_error("Error starting state transaction: %s (%s)\n", menu.txn_path, strerror(errno));
			transaction_started = exists(menu.txn_path);
			goto done;
		}
		transaction_started = 1;
	}

	state_slot = menu.slot;
	if (!State_write()) goto done;

	if (menu.total_discs) {
		char* disc_path = menu.disc_paths[menu.disc];
		const char* relative_path = disc_path + strlen(menu.base_path);
		if (save_write_atomic(menu.txt_path, relative_path, strlen(relative_path))) {
			LOG_error("Error writing state disc identity: %s (%s)\n", menu.txt_path, strerror(errno));
			goto done;
		}
		if (save_remove_file(menu.txn_path)) {
			LOG_error("Error completing state transaction: %s (%s)\n", menu.txn_path, strerror(errno));
			goto done;
		}
		transaction_started = 0;
	}
	result = 1;

	// Preview failure is cosmetic; the state and any disc identity are already durable.
	SDL_Surface* bitmap = menu.bitmap;
	if (!bitmap) bitmap = SDL_CreateRGBSurfaceFrom(renderer.src, renderer.true_w, renderer.true_h, FIXED_DEPTH, renderer.src_p, RGBA_MASK_565);
	if (bitmap) {
		SDL_RWops* out = SDL_RWFromFile(menu.bmp_path, "wb");
		if (!out || SDL_SaveBMP_RW(bitmap, out, 1))
			LOG_error("Error writing state preview: %s (%s)\n", menu.bmp_path, SDL_GetError());
		if (bitmap!=menu.bitmap) SDL_FreeSurface(bitmap);
	}
	else LOG_error("Error creating state preview (%s)\n", SDL_GetError());
	putInt(menu.slot_path, menu.slot);

done:
	if (!result && transaction_started && exists(menu.txn_path))
		LOG_error("State slot left unavailable until a successful retry: %s\n", menu.txn_path);
	Menu_updateState();
	return result;
}
static int Menu_loadState(void) {
	// LOG_info("Menu_loadState\n");

	Menu_updateState();
	if (!menu.save_exists) return 0;

	char original_disc[MAX_PATH] = {0};
	int switched_disc = 0;
	int target_disc = menu.disc;
	if (menu.total_discs) {
		char slot_disc_name[256] = {0};
		size_t slot_disc_size = 0;
		if (save_read_file(menu.txt_path, slot_disc_name,
				sizeof(slot_disc_name)-1, 0, &slot_disc_size)) {
			LOG_error("Invalid state disc identity: %s (%s)\n", menu.txt_path, strerror(errno));
			return 0;
		}
		if (!slot_disc_size) {
			LOG_error("Empty state disc identity: %s\n", menu.txt_path);
			return 0;
		}
		slot_disc_name[slot_disc_size] = '\0';

		char slot_disc_path[MAX_PATH];
		int written = slot_disc_name[0]=='/'
			? snprintf(slot_disc_path, sizeof(slot_disc_path), "%s", slot_disc_name)
			: snprintf(slot_disc_path, sizeof(slot_disc_path), "%s%s", menu.base_path, slot_disc_name);
		if (written < 0 || (size_t)written >= sizeof(slot_disc_path)) {
			LOG_error("State disc identity is too long: %s\n", menu.txt_path);
			return 0;
		}

		int known_disc = 0;
		for (int i=0; i<menu.total_discs; i++) {
			if (exactMatch(slot_disc_path, menu.disc_paths[i])) {
				known_disc = 1;
				target_disc = i;
				break;
			}
		}
		if (!known_disc) {
			LOG_error("State references an unknown disc: %s\n", slot_disc_path);
			return 0;
		}

		if (!exactMatch(slot_disc_path, game.path)) {
			snprintf(original_disc, sizeof(original_disc), "%s", game.path);
			Game_changeDisc(slot_disc_path);
			if (!exactMatch(slot_disc_path, game.path)) {
				LOG_error("Could not switch to state disc: %s\n", slot_disc_path);
				return 0;
			}
			switched_disc = 1;
		}
	}

	state_slot = menu.slot;
	if (!State_read()) {
		if (switched_disc) Game_changeDisc(original_disc);
		return 0;
	}
	menu.disc = target_disc;
	putInt(menu.slot_path, menu.slot);
	return 1;
}

static char* getAlias(char* path, char* alias) {
	// LOG_info("alias path: %s\n", path);
	char* tmp;
	char map_path[256];
	strcpy(map_path, path);
	tmp = strrchr(map_path, '/');
	if (tmp) {
		tmp += 1;
		strcpy(tmp, "map.txt");
		// LOG_info("map_path: %s\n", map_path);
	}
	char* file_name = strrchr(path,'/');
	if (file_name) file_name += 1;
	// LOG_info("file_name: %s\n", file_name);
	
	if (exists(map_path)) {
		FILE* file = fopen(map_path, "r");
		if (file) {
			char line[256];
			while (fgets(line,256,file)!=NULL) {
				normalizeNewline(line);
				trimTrailingNewlines(line);
				if (strlen(line)==0) continue; // skip empty lines
			
				tmp = strchr(line,'\t');
				if (tmp) {
					tmp[0] = '\0';
					char* key = line;
					char* value = tmp+1;
					if (exactMatch(file_name,key)) {
						strcpy(alias, value);
						break;
					}
				}
			}
			fclose(file);
		}
	}
}

static void Menu_loop(void) {
	menu.bitmap = SDL_CreateRGBSurfaceFrom(renderer.src, renderer.true_w, renderer.true_h, FIXED_DEPTH, renderer.src_p, RGBA_MASK_565);
	// LOG_info("Menu_loop:menu.bitmap %ix%i\n", menu.bitmap->w,menu.bitmap->h);
	
	SDL_Surface* backing = SDL_CreateRGBSurface(SDL_SWSURFACE,DEVICE_WIDTH,DEVICE_HEIGHT,FIXED_DEPTH,RGBA_MASK_565); 
	Menu_scale(menu.bitmap, backing);
	Menu_dim(backing); // the dim IS the backdrop; see Menu_dim for why the overlay blit is gone
	
	int restore_w = screen->w;
	int restore_h = screen->h;
	int restore_p = screen->pitch;
	if (restore_w!=DEVICE_WIDTH || restore_h!=DEVICE_HEIGHT) {
		screen = GFX_resize(DEVICE_WIDTH,DEVICE_HEIGHT,DEVICE_PITCH);
	}
	
	// Drop the debug HUD for the duration of the menu. The overlay pointers are only refreshed
	// from the video-refresh path, which does not run while the menu is up — so without this the
	// LAST game frame's HUD strips stay live and every platform's flip keeps compositing them
	// over the menu (both tg5040 and miyoomini call drawDebugOverlay() unconditionally in flip).
	// The next rendered game frame re-arms it if the HUD is still enabled.
	PLAT_setDebugOverlay(NULL, NULL, 0, 0, 0);

	Core_flushMemory();
	PWR_warn(0);
	if (!HAS_POWER_BUTTON) PWR_enableSleep();
	// This path composites the paused game, TTF text, and save previews through GLES.
	// The powersave ceiling keeps redraws responsive while schedutil still idles low.
	PWR_setCPUSpeed(CPU_SPEED_POWERSAVE);
	GFX_setVsync(VSYNC_STRICT);
	GFX_setEffect(EFFECT_NONE);
	
	int rumble_strength = VIB_getStrength();
	VIB_setStrength(0);
	
	PWR_enableAutosleep();
	PAD_reset();
	
	// if (!HAS_POWER_BUTTON && !HAS_POWEROFF_BUTTON) {
	// 	MenuItem* item = &options_menu.items[5];
	// 	item->name = "Quicksave";
	// 	item->desc = "Automatically resume current state next power on.";
	// 	item->on_confirm = OptionQuicksave_onConfirm;
	// }
	
	// path and string things
	char* tmp;
	char rom_name[256]; // without extension or cruft
	getDisplayName(game.name, rom_name);
	getAlias(game.path, rom_name);
	
	int rom_disc = -1;
	char disc_name[16];
	if (menu.total_discs) {
		rom_disc = menu.disc;
		sprintf(disc_name, "Disc %i", menu.disc+1);
	}
		
	int selected = 0; // resets every launch
	Menu_initState();
	
	int status = STATUS_CONT; // TODO: no longer used?
	int show_setting = 0;
	int dirty = 1;
	int ignore_menu = 0;
	int menu_start = 0;
	
	SDL_Surface* preview = SDL_CreateRGBSurface(SDL_SWSURFACE,DEVICE_WIDTH/2,DEVICE_HEIGHT/2,FIXED_DEPTH,RGBA_MASK_565);
	int preview_slot = -1;
	int preview_valid = 0;
	
	while (show_menu) {
		GFX_startFrame();
		uint32_t now = SDL_GetTicks();

		PAD_poll();
		
		if (PAD_justPressed(BTN_UP)) {
			selected -= 1;
			if (selected<0) selected += MENU_ITEM_COUNT;
			dirty = 1;
		}
		else if (PAD_justPressed(BTN_DOWN)) {
			selected += 1;
			if (selected>=MENU_ITEM_COUNT) selected -= MENU_ITEM_COUNT;
			dirty = 1;
		}
		else if (PAD_justPressed(BTN_LEFT)) {
			if (menu.total_discs>1 && selected==ITEM_CONT) {
				menu.disc -= 1;
				if (menu.disc<0) menu.disc += menu.total_discs;
				dirty = 1;
				sprintf(disc_name, "Disc %i", menu.disc+1);
			}
			else if (selected==ITEM_SAVE || selected==ITEM_LOAD) {
				menu.slot -= 1;
				if (menu.slot<0) menu.slot += MENU_SLOT_COUNT;
				dirty = 1;
			}
		}
		else if (PAD_justPressed(BTN_RIGHT)) {
			if (menu.total_discs>1 && selected==ITEM_CONT) {
				menu.disc += 1;
				if (menu.disc==menu.total_discs) menu.disc -= menu.total_discs;
				dirty = 1;
				sprintf(disc_name, "Disc %i", menu.disc+1);
			}
			else if (selected==ITEM_SAVE || selected==ITEM_LOAD) {
				menu.slot += 1;
				if (menu.slot>=MENU_SLOT_COUNT) menu.slot -= MENU_SLOT_COUNT;
				dirty = 1;
			}
		}
		
		if (dirty && (selected==ITEM_SAVE || selected==ITEM_LOAD)) {
			Menu_updateState();
		}
		
		if (PAD_justPressed(BTN_B) || (BTN_WAKE!=BTN_MENU && PAD_tappedMenu(now))) {
			status = STATUS_CONT;
			show_menu = 0;
		}
		else if (PAD_justPressed(BTN_A)) {
			switch(selected) {
				case ITEM_CONT:
				if (menu.total_discs && rom_disc!=menu.disc) {
						status = STATUS_DISC;
						char* disc_path = menu.disc_paths[menu.disc];
						Game_changeDisc(disc_path);
					}
					else {
						status = STATUS_CONT;
					}
					show_menu = 0;
				break;
				
				case ITEM_SAVE: {
					if (Menu_saveState()) {
						status = STATUS_SAVE;
						show_menu = 0;
					}
				}
				break;
				case ITEM_LOAD: {
					if (Menu_loadState()) {
						status = STATUS_LOAD;
						show_menu = 0;
					}
				}
				break;
				case ITEM_OPTS: {
					if (simple_mode) {
						Core_reset();
						status = STATUS_RESET;
						show_menu = 0;
					}
					else {
						int old_scaling = screen_scaling;
						Menu_options(&options_menu);
						if (screen_scaling!=old_scaling) {
							selectScaler(renderer.true_w,renderer.true_h,renderer.src_p);
						
							restore_w = screen->w;
							restore_h = screen->h;
							restore_p = screen->pitch;
							screen = GFX_resize(DEVICE_WIDTH,DEVICE_HEIGHT,DEVICE_PITCH);
						
							SDL_FillRect(backing, NULL, 0);
							Menu_scale(menu.bitmap, backing);
							Menu_dim(backing);
						}
						dirty = 1;
					}
				}
				break;
				case ITEM_QUIT:
					status = STATUS_QUIT;
					show_menu = 0;
					quit = 1; // TODO: tmp?
				break;
			}
			if (!show_menu) break;
		}

		PWR_update(&dirty, &show_setting, Menu_beforeSleep, Menu_afterSleep);
		
		if (dirty) {
			uint32_t _mt0 = SDL_GetTicks(); // menutrace: cost of one menu redraw, ZERO_FLIP_TRACE-gated below
			GFX_clear(screen);
			
			SDL_BlitSurface(backing, NULL, screen, NULL);
			// menu.overlay blit removed: the backing is pre-dimmed by Menu_dim (see there). The
			// alpha-mod blit was platform-dependent and no-opped on the h700 SDL build.

			int ox, oy;
			int ow = GFX_blitHardwareGroup(screen, show_setting);
			int max_width = screen->w - SCALE1(PADDING * 2) - ow;
			
			char display_name[256];
			int text_width = GFX_truncateText(font.large, rom_name, display_name, max_width, SCALE1(BUTTON_PADDING*2));
			max_width = MIN(max_width, text_width);

			SDL_Surface* text;
			text = TTF_RenderUTF8_Blended(font.large, display_name, COLOR_WHITE);
			GFX_blitPill(ASSET_BLACK_PILL, screen, &(SDL_Rect){
				SCALE1(PADDING),
				SCALE1(PADDING),
				max_width,
				SCALE1(PILL_SIZE)
			});
			SDL_BlitSurface(text, &(SDL_Rect){
				0,
				0,
				max_width-SCALE1(BUTTON_PADDING*2),
				text->h
			}, screen, &(SDL_Rect){
				SCALE1(PADDING+BUTTON_PADDING),
				SCALE1(PADDING+4)
			});
			SDL_FreeSurface(text);

			if (show_setting && !GetHDMI()) GFX_blitHardwareHints(screen, show_setting);
			else GFX_blitButtonGroup((char*[]){ BTN_SLEEP==BTN_POWER?"POWER":"MENU","SLEEP", NULL }, 0, screen, 0);
			GFX_blitButtonGroup((char*[]){ "B","BACK", "A","OKAY", NULL }, 1, screen, 1);
			
			// list
			// N rows occupy (N-1) pitches plus one pill, not N pitches -- the last row ends at its own
			// height, not a full pitch later. Identical wherever ROW_PITCH==PILL_SIZE (every device but
			// the Brick Pro); there it stops the block sitting a row-gap high.
			oy = ((UNSCALE1(DEVICE_HEIGHT) - PADDING * 2) - ((MENU_ITEM_COUNT-1) * ROW_PITCH + PILL_SIZE)) / 2;
			for (int i=0; i<MENU_ITEM_COUNT; i++) {
				char* item = menu.items[i];
				SDL_Color text_color = COLOR_WHITE;
				
				if (i==selected) {
					// disc change
					if (menu.total_discs>1 && i==ITEM_CONT) {				
						GFX_blitPill(ASSET_DARK_GRAY_PILL, screen, &(SDL_Rect){
							SCALE1(PADDING),
							SCALE1(oy + PADDING),
							screen->w - SCALE1(PADDING * 2),
							SCALE1(PILL_SIZE)
						});
						text = TTF_RenderUTF8_Blended(font.large, disc_name, COLOR_WHITE);
						SDL_BlitSurface(text, NULL, screen, &(SDL_Rect){
							screen->w - SCALE1(PADDING + BUTTON_PADDING) - text->w,
							SCALE1(oy + PADDING + 4)
						});
						SDL_FreeSurface(text);
					}
					
					TTF_SizeUTF8(font.large, item, &ow, NULL);
					ow += SCALE1(BUTTON_PADDING*2);
					
					// pill
					GFX_blitPill(ASSET_WHITE_PILL, screen, &(SDL_Rect){
						SCALE1(PADDING),
						SCALE1(oy + PADDING + (i * ROW_PITCH)),
						ow,
						SCALE1(PILL_SIZE)
					});
					text_color = COLOR_BLACK;
				}
				else {
					// shadow
					text = TTF_RenderUTF8_Blended(font.large, item, COLOR_BLACK);
					SDL_BlitSurface(text, NULL, screen, &(SDL_Rect){
						SCALE1(2 + PADDING + BUTTON_PADDING),
						SCALE1(1 + PADDING + oy + (i * ROW_PITCH) + 4)
					});
					SDL_FreeSurface(text);
				}
				
				// text
				text = TTF_RenderUTF8_Blended(font.large, item, text_color);
				SDL_BlitSurface(text, NULL, screen, &(SDL_Rect){
					SCALE1(PADDING + BUTTON_PADDING),
					SCALE1(oy + PADDING + (i * ROW_PITCH) + 4)
				});
				SDL_FreeSurface(text);
			}
			
			// slot preview
			if (selected==ITEM_SAVE || selected==ITEM_LOAD) {
				#define WINDOW_RADIUS 4 // TODO: this logic belongs in blitRect?
				#define PAGINATION_HEIGHT 6
				// unscaled
				int hw = DEVICE_WIDTH / 2;
				int hh = DEVICE_HEIGHT / 2;
				int pw = hw + SCALE1(WINDOW_RADIUS*2);
				int ph = hh + SCALE1(WINDOW_RADIUS*2 + PAGINATION_HEIGHT + WINDOW_RADIUS);
				ox = DEVICE_WIDTH - pw - SCALE1(PADDING);
				oy = (DEVICE_HEIGHT - ph) / 2;
				
				// window
				GFX_blitRect(ASSET_STATE_BG, screen, &(SDL_Rect){ox,oy,pw,ph});
				ox += SCALE1(WINDOW_RADIUS);
				oy += SCALE1(WINDOW_RADIUS);
				
				int preview_ready = 0;
				if (preview && menu.preview_exists) { // has save, has preview
					if (preview_slot != menu.slot) {
						preview_slot = menu.slot;
						preview_valid = 0;
						SDL_Surface* bmp = IMG_Load(menu.bmp_path);
						SDL_Surface* raw_preview = bmp
							? SDL_ConvertSurface(bmp, screen->format, SDL_SWSURFACE)
							: NULL;
						if (raw_preview) {
							SDL_FillRect(preview, NULL, 0);
							Menu_scale(raw_preview, preview);
							preview_valid = 1;
						}
						else LOG_error("Unable to load state preview: %s (%s)\n", menu.bmp_path, SDL_GetError());
						if (raw_preview) SDL_FreeSurface(raw_preview);
						if (bmp) SDL_FreeSurface(bmp);
					}
					if (preview_valid) {
						SDL_BlitSurface(preview, NULL, screen, &(SDL_Rect){ox,oy});
						preview_ready = 1;
					}
				}
				if (!preview_ready) {
					SDL_Rect preview_rect = {ox,oy,hw,hh};
					SDL_FillRect(screen, &preview_rect, 0);
					if (menu.save_exists) GFX_blitMessage(font.large, "No Preview", screen, &preview_rect);
					else GFX_blitMessage(font.large, "Empty Slot", screen, &preview_rect);
				}
				
				// pagination
				ox += (pw-SCALE1(15*MENU_SLOT_COUNT))/2;
				oy += hh+SCALE1(WINDOW_RADIUS);
				for (int i=0; i<MENU_SLOT_COUNT; i++) {
					if (i==menu.slot)GFX_blitAsset(ASSET_PAGE, NULL, screen, &(SDL_Rect){ox+SCALE1(i*15),oy});
					else GFX_blitAsset(ASSET_DOT, NULL, screen, &(SDL_Rect){ox+SCALE1(i*15)+4,oy+SCALE1(2)});
				}
			}

			GFX_flip(screen);
			{
				static int _mtr = -1;
				if (_mtr < 0) { const char* e = getenv("ZERO_FLIP_TRACE"); _mtr = (e && e[0]=='1') ? 1 : 0; }
				if (_mtr) LOG_info("menutrace: draw+flip=%ums\n", SDL_GetTicks() - _mt0);
			}
			dirty = 0;
		}
		else GFX_sync();
		hdmimon();
	}
	
	SDL_FreeSurface(preview);
	
	PAD_reset();

	GFX_clearAll();
	PWR_warn(1);
	
	if (!quit) {
		if (restore_w!=DEVICE_WIDTH || restore_h!=DEVICE_HEIGHT) {
			screen = GFX_resize(restore_w,restore_h,restore_p);
		}
		GFX_setEffect(screen_effect);
		GFX_clear(screen);
		dup_force_present = 1; // same bytes as before the menu, but the screen must repaint
		video_refresh_callback(renderer.src, renderer.true_w, renderer.true_h, renderer.src_p);
		
		Gov_restore();
		SND_reprime(); // DAC drained the ring while the core was parked in the menu;
		               // resume through the prefill gate or the first ~2s crackles (audit 2026-08-31)
		if (rumble_strength) VIB_setStrength(rumble_strength);
		
		GFX_setVsync(prevent_tearing);
		if (!HAS_POWER_BUTTON) PWR_disableSleep();

		if (thread_video) {
			// reset the rate window while the core is still parked — it owns these
			// counters in threaded mode (a reset after resume garbles one window)
			sec_start = SDL_GetTicks();
			cpu_ticks = 0;
			fps_ticks = 0;
			gen_ticks = 0;
			cpu_double = 0;
			pthread_mutex_lock(&core_mx);
			should_run_core = 1;
			pthread_cond_signal(&core_pause_cv);
			pthread_mutex_unlock(&core_mx);
		}
	}
	else if (exists(NOUI_PATH)) PWR_powerOff(); // TODO: won't work with threaded core, only check this once per launch
	
	SDL_FreeSurface(menu.bitmap);
	menu.bitmap = NULL;
	SDL_FreeSurface(backing);
	PWR_disableAutosleep();
}

// TODO: move to PWR_*?
static unsigned getUsage(void) { // from picoarch
	long unsigned ticks = 0;
	long ticksps = 0;
	FILE *file = NULL;

	file = fopen("/proc/self/stat", "r");
	if (!file)
		goto finish;

	if (!fscanf(file, "%*d %*s %*c %*d %*d %*d %*d %*d %*u %*u %*u %*u %*u %lu", &ticks))
		goto finish;

	ticksps = sysconf(_SC_CLK_TCK);

	if (ticksps)
		ticks = ticks * 100 / ticksps;

finish:
	if (file)
		fclose(file);

	return ticks;
}

static void trackFPS(void) {
	cpu_ticks += 1;
	uint32_t now = SDL_GetTicks();
	if (now - sec_start>=1000) {
		double last_time = (double)(now - sec_start) / 1000;
		// GENERATION rate = core.run epochs, counted at the run-loop boundary — includes frames
		// the core produced with a NULL/duplicate video callback (Codex F1: fps_ticks-in-present
		// missed those). Presented rate (fps_ticks) is kept distinct for pacing diagnostics.
		fps_double = gen_ticks / last_time;
#ifdef ZERO_FRONTEND_THREADING_V2
		if (zero_ftv2_depth2) {
			// Codex #5: depth-2 generation = epochs completed, counted on MAIN in the drain
			// (non-cancelled RUN_DONE). No cross-thread counter, dupes count as generated.
			fps_double = zero_ftv2_gen_ticks / last_time;
			zero_ftv2_gen_ticks = 0;
		}
#endif
		cpu_double = cpu_ticks / last_time;
		rate_seq++; // generation-rate publication counter (gov-memory fast ladder freshness)

		// once-a-second /proc parse; consumed by the debug HUD and the pause-menu stats line.
		// Normalized to % of TOTAL CPU (all cores), not one core — multi-threaded cores
		// (supafaust spans the quad) read >100% otherwise, which looks like broken math.
		static long ncores = 0;
		if (!ncores) { ncores = sysconf(_SC_NPROCESSORS_ONLN); if (ncores < 1) ncores = 1; }
		use_ticks = getUsage();
		if (use_ticks && last_use_ticks) {
			use_double = (use_ticks - last_use_ticks) / last_time / ncores;
		}
		last_use_ticks = use_ticks;

		// MEASURE (A/B instrument): objective depth-2 vs depth-1 quality per second.
		//   d   = 0 v1.3.1 / 1 WP depth-1 / 2 WP depth-2
		//   fps = REAL frame rate (frames the core produced) — "slow" shows as < core.fps
		//   cpu = MAIN loop rate (should track fps; a spin shows as huge)
		//   use = CPU% of the whole quad
		//   under/s = audio underruns/sec — THE "choppy" signal
		//   dup/s   = duplicated (present-starved) frames/sec — pacing-quality signal
		//   ceil = governor clock ceiling (MHz) — the energy signal
		{
			// Bench instrument, OPT-IN (ZERO_MEASURE=1): a log line every second is a file write
			// to the SD card every second of EVERY session — I/O, wakeups, and card wear for data
			// nobody is reading outside an A/B. The bench scripts export the env.
			static int m_on = -1;
			if (m_on < 0) { const char* e = getenv("ZERO_MEASURE"); m_on = (e && e[0] && e[0] != '0') ? 1 : 0; }
			if (m_on) {
				int m_depth = 0;
#ifdef ZERO_FRONTEND_THREADING_V2
				m_depth = zero_ftv2_depth2 ? 2 : 1;
#endif
				SND_Stats ss; SND_getStats(&ss);
				static long m_u0 = 0; static int m_d0 = 0;
				int m_u = (int)(ss.underruns - m_u0); m_u0 = ss.underruns;
				int m_d = mb_dups_total - m_d0;       m_d0 = mb_dups_total;
				// dac = frames queued to the DAC, and whether that count MOVED since the last
				// sample. A ONE-WAY signal: dac=? or STALLED proves there is no audio, but
				// "flowing" does NOT prove audibility — the known-silent build still reported
				// flowing on every system (negative control, 2026-07-26). Treat it as a cheap
				// way to catch dead audio, never as a green light.
				int m_dac = PLAT_getAudioQueued();
				static int m_dac0 = -1;
				int m_dac_moved = (m_dac >= 0 && m_dac0 >= 0 && m_dac != m_dac0);
				m_dac0 = m_dac;
				if (m_dac < 0) {
					LOG_info("MEASURE d=%d fps=%.1f/%.1f cpu=%.1f use=%.0f under/s=%d dup/s=%d ceil=%d dac=?\n",
						m_depth, fps_double, core.fps, cpu_double, use_double, m_u, m_d, gov_state.ceil_khz/1000);
				}
				else {
					LOG_info("MEASURE d=%d fps=%.1f/%.1f cpu=%.1f use=%.0f under/s=%d dup/s=%d ceil=%d dac=%d %s\n",
						m_depth, fps_double, core.fps, cpu_double, use_double, m_u, m_d, gov_state.ceil_khz/1000,
						m_dac, m_dac_moved ? "flowing" : "STALLED");
				}
			}
		}

		sec_start = now;
		cpu_ticks = 0;
		fps_ticks = 0;
		gen_ticks = 0;

		// LOG_info("fps: %f cpu: %f\n", fps_double, cpu_double);
	}
}

static void limitFF(void) {
	static uint64_t ff_frame_time = 0;
	static uint64_t last_time = 0;
	static int last_max_speed = -1;
	// Recompute on a core.fps change too, not only on a cap change. The cached period is derived
	// from core.fps, so a runtime NTSC<->PAL switch made a 4x cap deliver 4.81x (or 3.33x the other
	// way) until the user happened to change the cap.
	static double last_fps = 0.0;
	if (last_max_speed!=max_ff_speed || last_fps!=core.fps) {
		last_max_speed = max_ff_speed;
		last_fps = core.fps;
		// Fractional speeds (D60): budget from the multiplier table, not index+1. Index 0
		// ("None" = uncapped) never paces — guard the divide (the use below is also gated
		// on max_ff_speed, but a stale inf/0 budget must never be computed).
		ff_frame_time = max_ff_speed > 0
			? (uint64_t)(1000000.0 / (core.fps * max_ff_mults[max_ff_speed]))
			: 0;
	}
	
	uint64_t now = getMicroseconds();
	if (fast_forward && max_ff_speed) {
		if (last_time == 0) last_time = now;
		int elapsed = now - last_time;
		if (elapsed>0 && elapsed<0x80000) {
			if (elapsed<ff_frame_time) {
				int delay = (ff_frame_time - elapsed) / 1000;
				if (delay>0 && delay<17) { // don't allow a delay any greater than a frame
					SDL_Delay(delay);
				}
			}
			last_time += ff_frame_time;
			return;
		}
	}
	last_time = now;
}

static void* coreThread(void *arg) {
	// (stock cleared + flipped here "for better frame pacing" — that is GL from the
	// wrong thread; EGL contexts are thread-affine and the mailbox paces us now)
	
	while (!quit && !core_thread_exit) {
		int run = 0;
		pthread_mutex_lock(&core_mx);
		while (!should_run_core && !quit && !core_thread_exit) {
			core_parked = 1;
			pthread_cond_wait(&core_pause_cv, &core_mx); // no busy-spin while paused
		}
		core_parked = 0;
		if (core_thread_exit) { pthread_mutex_unlock(&core_mx); break; }
		run = should_run_core;
		pthread_mutex_unlock(&core_mx);
		
		if (run) {
			SND_Stats snd0; SND_getStats(&snd0);
			uint64_t t0 = getMicroseconds();
			core.run();
			uint32_t w = (uint32_t)(getMicroseconds() - t0);
			SND_Stats snd1; SND_getStats(&snd1);
			long pace = (snd1.wait_ms - snd0.wait_ms) * 1000;
			if (pace > 0 && (uint32_t)pace < w) w -= (uint32_t)pace; // pacing is not work
			core_work_ring[core_work_n % CORE_WORK_RING] = w;
			core_work_n++;
			// drift-free cadence: unpaced bursts saturate the audio ring, and the long
			// blocks inside core.run read as "behind schedule" to pcsx's auto-frameskip
			// (measured: 15 real frames + 46 skips/sec). Feeding at consumption rate
			// keeps the ring level and the core's wall-clock honest.
			if (!fast_forward && core.fps > 0) {
				static uint64_t next_us = 0;
				uint64_t budget = (uint64_t)(1000000.0 / (core.fps * (1.0 + core_pace_ppm / 1000000.0)));
				uint64_t now2 = getMicroseconds();
				if (!next_us) next_us = now2;
				next_us += budget;
				if (now2 < next_us) usleep(next_us - now2);
				else if (now2 - next_us > budget*4) next_us = now2; // hopelessly behind: reset, don't chase
			}
			limitFF();
			trackFPS();
		}
	}
	pthread_exit(NULL);
}

#ifdef ZERO_FRONTEND_THREADING_V2
// zero_ftv2 handle declared early (near the frontend_core.h include) for video_refresh_callback

// The vtable maps minarch's bootstrap/runtime operations onto the lifecycle engine.
// Libretro operations execute on CORE; audio/renderer lifecycle stays on MAIN.
// Result-passing decomposition: get_system_info/get_av_info fill these shared
// statics on CORE; MAIN consumes them after the stage (serialised: CORE quiescent
// between stages, MAIN blocked during — race-free).
static struct retro_system_info    zero_ftv2_info;     // filled by GET_INFO stage
static struct retro_system_av_info zero_ftv2_av;       // filled by AV stage

// --- bootstrap stages (return 0 ok / <0 fail / >0 core-requested shutdown) ---
static int  zero_ftv2_get_system_info(void* c) { (void)c; Core_registerCallbacks(); core.get_system_info(&zero_ftv2_info); return 0; }
static int  zero_ftv2_init(void* c)            { (void)c; core.init(); core.initialized = 1; return 0; }
static int  zero_ftv2_open_content(void* c)    { (void)c; /* content/path prep is MAIN work (Game_open) interleaved by the caller; nothing on CORE here */ return 0; }
static int  zero_ftv2_load_game(void* c) {
	(void)c;
	struct retro_game_info gi;
	gi.path = game.tmp_path[0]?game.tmp_path:game.path;
	gi.data = game.data;
	gi.size = game.size;
	return core.load_game(&gi) ? 0 : -1; // <0 => bootstrap stops; MAIN runs the load-fail cleanup
}
static int  zero_ftv2_setup_memory(void* c)    { (void)c; SRAM_read(); RTC_read(); return 0; }
static int  zero_ftv2_arm_crash(void* c)       { (void)c; Crash_install(); return 0; }
static int  zero_ftv2_get_av_info(void* c) {
	(void)c;
	core.get_system_av_info(&zero_ftv2_av);
	return 0;
}
static int  zero_ftv2_set_controller(void* c)  { (void)c; core.set_controller_port_device(0, RETRO_DEVICE_JOYPAD); return 0; }
// audio_init/renderer_init run MAIN-side (D57): SND_init needs core.sample_rate (ready
// after the AV stage); the SDL renderer is set up in PLAT_initVideo already, so renderer
// init is a no-op here on this platform (watch-point: confirm on device).
static int  zero_ftv2_audio_init(void* c)      { (void)c; SND_init(core.sample_rate, core.fps); return 0; }
static int  zero_ftv2_renderer_init(void* c)   { (void)c; /* SDL renderer already up (PLAT_initVideo); MAIN-side no-op */ return 0; }
static int  zero_ftv2_resume(void* c)          { (void)c; State_resume(); return 0; /* nonfatal by policy */ }

// --- runtime ---
static void zero_ftv2_run(void* c, uint64_t gen, uint32_t slot, const uint64_t snap[4]) {
	(void)c; (void)gen;
	// WP-A: stash this epoch's input snapshot for input_state_callback (depth-2 reads it here
	// instead of the live globals). Harmless at depth-1 (input still flows via input_tick on CORE).
	zero_ftv2_isnap[0]=snap[0]; zero_ftv2_isnap[1]=snap[1]; zero_ftv2_isnap[2]=snap[2]; zero_ftv2_isnap[3]=snap[3];
	zero_ftv2_ff_snap = (int)(snap[3] & 1);  // Codex #6: CORE callbacks read THIS, not the live global
	static __thread FFVisualCadence visual_cadence;
	uint64_t emu_t0 = getMicroseconds();
	zero_ftv2_emit_visual = ff_visual_step(&visual_cadence, zero_ftv2_ff_snap,
	                                      emu_t0, (uint32_t)(snap[3] >> 8));
	SND_Stats snd0; SND_getStats(&snd0);
	core.run();  // video_refresh copies the transient core frame into the credit-owned pool
	uint32_t work = (uint32_t)(getMicroseconds() - emu_t0);
	SND_Stats snd1; SND_getStats(&snd1);
	long pace = (snd1.wait_ms - snd0.wait_ms) * 1000;
	if (pace > 0 && (uint32_t)pace < work) work -= (uint32_t)pace;
	atomic_store_explicit(&zero_ftv2_work_us[slot], work, memory_order_release);
}
static int  zero_ftv2_serialize(void* c, uint64_t a)   { (void)c; state_slot = (int)a; return State_writeDirect() ? 0 : -1; }
static int  zero_ftv2_unserialize(void* c, uint64_t a) { (void)c; state_slot = (int)a; return State_readDirect() ? 0 : -1; }
static void zero_ftv2_reset(void* c)           { (void)c; core.reset(); }
static int  zero_ftv2_runtime_service(void* c, uint64_t a) {
	(void)c;
	return Core_runtimeDirect((uint32_t)(a & 0xFFu), (uint32_t)(a >> 8));
}

// --- teardown (oracle governs which are legal from the reached state) ---
static void zero_ftv2_disarm_crash(void* c)    { (void)c; Crash_uninstall(); }
static void zero_ftv2_unload_game(void* c)     { (void)c; core.unload_game(); }
static void zero_ftv2_deinit(void* c)          { (void)c; core.deinit(); core.initialized = 0; }

static const fc_vtable zero_ftv2_vt = {
	.ctx             = NULL,
	.get_system_info = zero_ftv2_get_system_info,
	.init            = zero_ftv2_init,
	.open_content    = zero_ftv2_open_content,
	.load_game       = zero_ftv2_load_game,
	.setup_memory    = zero_ftv2_setup_memory,
	.arm_crash       = zero_ftv2_arm_crash,
	.get_av_info     = zero_ftv2_get_av_info,
	.set_controller  = zero_ftv2_set_controller,
	.audio_init      = zero_ftv2_audio_init,
	.renderer_init   = zero_ftv2_renderer_init,
	.resume          = zero_ftv2_resume,
	.run             = zero_ftv2_run,
	.serialize       = zero_ftv2_serialize,
	.unserialize     = zero_ftv2_unserialize,
	.reset           = zero_ftv2_reset,
	.runtime_service = zero_ftv2_runtime_service,
	.disarm_crash    = zero_ftv2_disarm_crash,
	.unload_game     = zero_ftv2_unload_game,
	.deinit          = zero_ftv2_deinit,
};

// zero_ftv2_running is 0 until fc_boot_finish; it gates the frame divert. CORE copies
// transient core frames into credit-owned pool buffers; MAIN drains, scales, and presents.
// zero_ftv2_running declared early (near the frontend_core.h include) for video_refresh_callback
static void zero_ftv2_drain(void* ctx, const fr_event* ev) {
	(void)ctx;
	// v2 present is MAIN-only: the GLES blit+flip path is bound to MAIN's EGL context, so
	// CORE just emits and MAIN does BOTH the scaler blit and the flip here. `renderer` is
	// the global set by video_refresh_callback (still valid: depth-1 serial, core hasn't
	// re-run). WP1 fix 2026-07-14: doing the blit on CORE left the screen black (present
	// no-op'd off-context) while audio ran — Dan's "menu showed the game" confirmed the
	// frame data was correct, only the on-CORE present failed.
	// WP-B: present from the credit-indexed pool buffer named in the FRAME payload. The
	// scaler config + HUD + flip all happen here on MAIN (present_frame). framering calls
	// zero_pool_retire(payload) AFTER this returns (D-a2), freeing the buffer.
	if (ev->kind == FR_EV_FRAME) {
		int buf = (int)ev->payload;
		if (buf >= 0 && buf < ZERO_FTV2_POOL) {
			present_frame(zero_pool_buffers[buf].px, zero_pool_buffers[buf].w,
			              zero_pool_buffers[buf].h, zero_pool_buffers[buf].pitch, 1);
			zero_ftv2_presented++;  // D61 pacer: a frame reached the screen (vsync-paced) this tick
		}
	}
	else if (fr_event_is_command(ev)) {
		// Codex #3: ordered CORE->MAIN state commands (SET_GEOMETRY / SET_SYSTEM_AV_INFO).
		// Applied HERE on MAIN, in global order against frames. Runtime service products
		// (load/reset/disc) arrive as FR_EV_SERVICE and require the same dispatcher; otherwise
		// their barrier could release while MAIN silently retained stale timing/geometry.
		int op = (int)(ev->payload >> 56);
		uint32_t bits = (uint32_t)(ev->payload & 0xFFFFFFFFu);
		float v; memcpy(&v, &bits, 4);
			switch (op) {
				case ZERO_CMD_ASPECT: core.aspect_ratio = v; renderer.dst_p = 0; break;
				// Re-apply after the fps field lands. This drain runs on MAIN and fr_drain()
				// invokes it before publishing barrier_applied, so CORE cannot resume producing
				// under the new timing until the clocks and DRC ownership are settled.
				case ZERO_CMD_FPS:    core.fps = v; renderer.dst_p = 0; Zero_applyRateMatch(); break;
				case ZERO_CMD_SRATE:  core.sample_rate = v;  break;
				case ZERO_CMD_RUMBLE: VIB_setStrength((int)v); break;
			}
	}
	else if (ev->kind == FR_EV_RUN_DONE && !ev->cancelled) {
		// The FF budget is per completed emulation epoch. Applying it in the outer MAIN loop
		// would count no-progress pumps and double-throttle the visual cadence. A frame event's
		// vsync time naturally satisfies most/all of this epoch's budget; duplicate/no-frame
		// epochs wait only for the remaining fraction.
		limitFF();
		// Codex #5: the TRUE depth-2 generation rate — epochs the core completed, counted on
		// MAIN (no cross-thread fps_ticks race; duped/undisplayed frames count as generated,
		// so internally-low-fps games don't read as slipping). trackFPS reads+resets this.
		zero_ftv2_gen_ticks++;
		uint32_t slot = (uint32_t)(ev->seq % zero_ftv2.fr.depth);
		uint32_t work = atomic_load_explicit(&zero_ftv2_work_us[slot], memory_order_acquire);
		// Governor cadence is generated epochs, not MAIN pump iterations. A depth-2 pump can
		// return without progress, so sampling in the outer loop would collapse a 30-frame
		// window into milliseconds and make decisions from stale rate data.
		if (gov_active && gov_frames < GOV_WORK_CAP) gov_work[gov_frames++] = work;
		if (tlm_enabled()) {
			SND_Stats as; SND_getStats(&as);
			tlm_frame(work);
			tlm_audio(as.queue_frames, as.underruns, as.overruns);
		}
	}
}

#endif // ZERO_FRONTEND_THREADING_V2

int main(int argc , char* argv[]) {
	uint64_t t_boot0 = getMicroseconds();
static int zero_boot_timing = -1;
#define TMARK(what) do { \
		if (zero_boot_timing < 0) { const char* _e = getenv("ZERO_BOOT_TIMING"); \
			zero_boot_timing = (_e && _e[0] && _e[0] != '0'); } \
		if (zero_boot_timing) LOG_info("boot-timing: %-14s +%llums\n", (what), \
			(unsigned long long)((getMicroseconds()-t_boot0)/1000)); \
	} while (0)
	LOG_info("MinArch\n");

	// PowerVR swap chain: 2 buffers instead of the default 3 = one frame less input
	// latency at zero CPU/heat cost (NULLWS_BUFFERS_COUNT is read by libpvrNULL_WSEGL
	// at EGL init; driver-validated range starts at 2). Overridable from the environment
	// (setenv overwrite=0). Verified on-device 2026-07-04: gov/DRC/temps unchanged.
	setenv("NULLWS_BUFFERS_COUNT", "2", 0);

	setOverclock(overclock); // default to normal
	// force a stack overflow to ensure asan is linked and actually working
	// char tmp[2];
	// tmp[2] = 'a';
	
	char core_path[MAX_PATH];
	char rom_path[MAX_PATH]; 
	char tag_name[MAX_PATH];
	
	strcpy(core_path, argv[1]);
	strcpy(rom_path, argv[2]);
	getEmuName(rom_path, tag_name);
	
	LOG_info("rom_path: %s\n", rom_path);

	screen = GFX_init(MODE_MENU);
	TMARK("gfx_init");
	PAD_init();
	DEVICE_WIDTH = screen->w;
	DEVICE_HEIGHT = screen->h;
	DEVICE_PITCH = screen->pitch;
	// LOG_info("DEVICE_SIZE: %ix%i (%i)\n", DEVICE_WIDTH,DEVICE_HEIGHT,DEVICE_PITCH);
	
	VIB_init();
	PWR_init();
	if (!HAS_POWER_BUTTON) PWR_disableSleep();
	MSG_init();
	
	// Overrides_init();
	
	Core_open(core_path, tag_name);
	TMARK("core_open");
	// Presentation-drop protects PS1 audio by SKIPPING presents (up to 6 in a row) whenever the
	// audio ring dips below 50%. That trade was measured on tg5040, whose audio path is direct SDL.
	// It is NOT automatically right elsewhere: the MMP routes through the vendor audioserver daemon
	// plus an OSS shim, so ring occupancy means something different there, and a ring that reads low
	// as a matter of course would drop presents continuously — visible chop, for audio the daemon
	// was already buffering. ZERO_NO_PRESENT_DROP (presence-only, project convention) opts a pak out
	// so the trade can be judged per platform instead of assumed.
	//
	// MEASURED on MMP/BR2, 4 min each (2026-07-31): drop ON = 64 audio underruns; drop OFF = 1581,
	// with generation pinned at 60.00 fps either way. So the drop is EARNING its keep there and must
	// stay on — the visible chop is a symptom (the device cannot both present every frame and keep
	// BR2's audio ring fed), not evidence the mechanism is misfiring. Do not disable it to chase
	// smoothness; that trades a stutter you notice for crackle you notice more.
	presentation_drop_supported = exactMatch((char*)core.tag, "PS") && getenv("ZERO_NO_PRESENT_DROP")==NULL;
	// The Lenient-vsync DRC revival can wind up against the 200ms audio ring and
	// drive a healthy low-end core below realtime. Keep it diagnostic-only until
	// its controller has an anti-windup contract and a cross-system device gauntlet.
	drc_system_allowed = !presentation_drop_supported && getenv("ZERO_ENABLE_DRC") != NULL;
	GFX_setPresentationDrop(presentation_drop_supported);
	simple_mode = exists(SIMPLE_MODE_PATH);

	// Threading v2's engine (CORE thread + ring) is used ONLY at depth-2 (the pipelined energy
	// win). At depth<2 (default, or ZERO_FTV2_DEPTH unset/1) we take the plain serial path — the
	// SAME code a guard-off build runs (init/load/run/present/quit all on MAIN, F23-consistent) —
	// so compiling the engine in adds ZERO overhead unless depth-2 is actually requested. When the
	// guard is compiled out, use_ftv2 is a const 0 and every engine branch below folds away.
	// (Measured: guard-on-depth-1 via the OLD always-engine path cost ~8pp more CPU than serial —
	// the fc_pump rendezvous — so gating the engine on depth-2 is what makes a global ship free.)
	#ifdef ZERO_FRONTEND_THREADING_V2
		int ftv2_depth = 1;
		{ const char* e = getenv("ZERO_FTV2_DEPTH"); if (e && atoi(e) >= 2) ftv2_depth = 2; }
		if (ftv2_depth >= 2) {
			// Crash policy (see decl): paths use the full game identity hash. The failure sidecar is
			// scoped to BUILD_HASH so a fixed firmware automatically requalifies a disabled game.
			// Inability to represent either complete path disables depth two for this session.
			int canary_n = snprintf(zero_ftv2_canary, sizeof(zero_ftv2_canary),
			                        "%s/.ftv2-%016llx.boot", core.states_dir,
			                        (unsigned long long)Game_identityHash(rom_path));
			int failures_n = snprintf(zero_ftv2_failures, sizeof(zero_ftv2_failures),
			                         "%s/.ftv2-%016llx.fail", core.states_dir,
			                         (unsigned long long)Game_identityHash(rom_path));
			if (canary_n < 0 || canary_n >= (int)sizeof(zero_ftv2_canary)
			 || failures_n < 0 || failures_n >= (int)sizeof(zero_ftv2_failures)) {
				zero_ftv2_canary[0] = '\0';
				zero_ftv2_failures[0] = '\0';
				LOG_info("threading v2: crash-canary path is too long — running SERIAL this session\n");
				ftv2_depth = 1;
			}
			else {
				int failures = zero_ftv2_failures_read(zero_ftv2_failures);
				if (failures >= ZERO_FTV2_CRASH_LIMIT) {
					LOG_info("threading v2: disabled for this game after %d consecutive crashes in build %s\n",
					         failures, BUILD_HASH);
					if (exists(zero_ftv2_canary)) zero_ftv2_canary_remove(zero_ftv2_canary);
					ftv2_depth = 1;
				}
				else if (exists(zero_ftv2_canary)) {
					int state = zero_ftv2_canary_state(zero_ftv2_canary);
					zero_ftv2_canary_armed = 1;
					ftv2_depth = 1;
					if (state == 1) {
						failures++;
						if (zero_ftv2_failures_write(zero_ftv2_failures, failures)) {
							// Do not clear this marker after the serial fallback: without a durable
							// count, retaining it is the only fail-safe way to prevent crash/retry loops.
							zero_ftv2_canary_clearable = 0;
							LOG_info("threading v2: cannot persist crash count — locked SERIAL by canary\n");
						}
						else if (failures >= ZERO_FTV2_CRASH_LIMIT) {
							LOG_info("threading v2: second consecutive depth-2 crash — disabled for this game/build\n");
						}
						else if (zero_ftv2_canary_write(zero_ftv2_canary, "serial\n")) {
							zero_ftv2_canary_clearable = 0;
							LOG_info("threading v2: cannot mark serial fallback — retaining crash canary\n");
						}
						else {
							LOG_info("threading v2: depth-2 crash %d/%d — running one SERIAL fallback\n",
							         failures, ZERO_FTV2_CRASH_LIMIT);
						}
					}
					else {
						LOG_info("threading v2: serial fallback did not exit cleanly — remaining SERIAL\n");
					}
				}
				else if (zero_ftv2_canary_write(zero_ftv2_canary, "depth2\n") == 0) {
					zero_ftv2_canary_armed = 1;   // armed ONLY on a synced, complete write
				}
				else {
					// Canary can't be persisted (full/RO card): running depth-2 without the net
					// would mean a crash retries forever. Run serial instead — fail SAFE.
					LOG_info("threading v2: cannot arm crash canary (write failed) — running SERIAL this session\n");
					ftv2_depth = 1;
				}
			}
		}
	const int use_ftv2 = (ftv2_depth >= 2);
#else
	const int use_ftv2 = 0;
#endif

	// Strict libretro thread affinity starts at callback registration and get_system_info, not
	// merely retro_init. Serial sessions perform both on MAIN; a depth-2 session creates CORE
	// first and runs the complete registration/info stage there before MAIN consumes its result.
	if (use_ftv2) {
#ifdef ZERO_FRONTEND_THREADING_V2
		fc_init(&zero_ftv2, &zero_ftv2_vt, ftv2_depth);
		fc_set_frame_retire_cb(&zero_ftv2, zero_pool_retire, NULL);
		zero_ftv2_depth2 = (zero_ftv2.fr.depth >= 2);
		zero_ftv2_inited = 1;
		LOG_info("threading v2: depth=%u (PIPELINED)\n", zero_ftv2.fr.depth);
		fc_boot_stage(&zero_ftv2, FC_OP_GET_INFO, zero_ftv2_drain, NULL);
		if (fc_boot_failed(&zero_ftv2)) goto finish;
		Core_applyInfo(&zero_ftv2_info);
#endif
	} else {
		struct retro_system_info info = {0};
		Core_registerCallbacks();
		core.get_system_info(&info);
		Core_applyInfo(&info);
	}

	// Game_open needs need_fullpath/valid_extensions from get_system_info. In particular,
	// opening a PS image before that stage defaults need_fullpath to false and attempts to
	// malloc/read the entire disc.
	Game_open(rom_path); // nes tries to load gamegenie setting before this returns ffs
	if (!game.is_open) goto finish;

	// restore options
	Config_load(); // before init?
	TMARK("pre_config");
	Config_init();
	Config_readOptions(); // cores with boot logo option (eg. gb) need to load options early
	setOverclock(overclock);
	GFX_setVsync(prevent_tearing);

	if (use_ftv2) {
#ifdef ZERO_FRONTEND_THREADING_V2
		fc_boot_stage(&zero_ftv2, FC_OP_INIT, zero_ftv2_drain, NULL);
		if (fc_boot_failed(&zero_ftv2)) goto finish;
#endif
	} else {
		Core_init();
		TMARK("core_init");
	}
	
	// TODO: find a better place to do this
	// mixing static and loaded data is messy
	// why not move to Core_init()?
	// ah, because it's defined before options_menu...
	options_menu.items[1].desc = (char*)core.version;
	
	if (use_ftv2) {
#ifdef ZERO_FRONTEND_THREADING_V2
		fc_boot_stage(&zero_ftv2, FC_OP_LOAD, zero_ftv2_drain, NULL);   // load_game returns -1 on failure (fc_boot_failed set)
		if (fc_boot_failed(&zero_ftv2)) goto finish;
		fc_boot_stage(&zero_ftv2, FC_OP_MEMORY, zero_ftv2_drain, NULL);      // SRAM_read + RTC_read
		fc_boot_stage(&zero_ftv2, FC_OP_ARM_CRASH, zero_ftv2_drain, NULL);   // Crash_install (pointers valid now)
		fc_boot_stage(&zero_ftv2, FC_OP_AV, zero_ftv2_drain, NULL);          // get_system_av_info on CORE
		if (fc_boot_failed(&zero_ftv2)) goto finish;
		Core_applyAV(&zero_ftv2_av);                  // consume the quiescent result on MAIN
		fc_boot_stage(&zero_ftv2, FC_OP_CONTROLLER, zero_ftv2_drain, NULL);  // set_controller_port_device (after av, matches Core_load order)
		if (fc_boot_failed(&zero_ftv2)) goto finish;
#endif
	} else {
		if (!Core_load()) {
			// game failed to load — bail cleanly. No game means SRAM/RTC/unload_game must not
			// run, but an initialized core still owes retro_deinit before dlclose: call it
			// here, then clear the flag so Core_quit skips the game teardown (audit 2026-07-11).
			core.deinit();
			core.initialized = 0;
			goto finish;
		}
	}
	TMARK("game_loaded");
	Input_init(NULL);
	Config_readOptions(); // but others load and report options later (eg. nes)
	Config_readControls(); // restore controls (after the core has reported its defaults)
	TMARK("cfg_read");
#ifndef ZERO_DISABLE_FRONTEND_THREADING
	int legacy_tv = 0; // pre-rename minarch_thread_video (v1.2 cfgs) — must read while user_cfg is alive
	{
		char lv[256]; int llock = 0; // Config_getValue writes up to 256 bytes, always
		if (config.user_cfg && Config_getValue(config.user_cfg, "minarch_thread_video", lv, &llock) && !llock)
			legacy_tv = (lv[0]=='O' && lv[1]=='n') ? 1 : 2;
	}
#endif
	Config_free();

	if (use_ftv2) {
#ifdef ZERO_FRONTEND_THREADING_V2
		fc_boot_stage(&zero_ftv2, FC_OP_AUDIO, zero_ftv2_drain, NULL);    // = SND_init MAIN-side, D57 (sample_rate ready from AV)
		fc_boot_stage(&zero_ftv2, FC_OP_RENDERER, zero_ftv2_drain, NULL); // MAIN-side no-op on this platform (SDL renderer already up)
#endif
	} else {
		SND_init(core.sample_rate, core.fps);
		TMARK("snd_init");
	}

	Zero_applyRateMatch(); // static panel rate match; re-applied whenever core.fps changes

	InitSettings(); // after we initialize audio
	TMARK("audio_ready");
	Menu_init();
	TMARK("menu_init");
	if (use_ftv2) {
#ifdef ZERO_FRONTEND_THREADING_V2
		fc_boot_stage(&zero_ftv2, FC_OP_RESUME, zero_ftv2_drain, NULL);   // = State_resume (nonfatal)
		fc_boot_finish(&zero_ftv2);                // QUIESCENT -> RUNNING; grants may now flow
		zero_ftv2_running = 1;
#endif
	} else {
		State_resume();
	}
	Menu_initState(); // make ready for state shortcuts
	
		{
		if (use_ftv2) {
			// v2 and the legacy mailbox are mutually exclusive by runtime contract, not
			// merely by the release makefile. Keep hand-rolled guard builds safe too.
			thread_video = 0;
			was_threaded = 0;
			thread_auto = 0;
			ta_phase = 2;
			ta_decided_by_user = 1;
			toggle_thread = 0;
			config.frontend.options[FE_OPT_THREAD].value = 2;
			config.frontend.options[FE_OPT_THREAD].lock = 1;
		}
		else {
	#ifdef ZERO_DISABLE_FRONTEND_THREADING
			thread_video = 0;
		was_threaded = 0;
		thread_auto = 0;
		ta_phase = 2;
		ta_decided_by_user = 1;
		config.frontend.options[FE_OPT_THREAD].value = 2;
		config.frontend.options[FE_OPT_THREAD].lock = 1;
#else
		// auto-threading bootstrap. The Threading option value carries user intent
		// directly: Auto -> honor a persisted verdict or run the trial; On/Off ->
		// explicit, machinery stands down. (Replaces cfg-layer sniffing, which broke
		// on device-tagged config filenames.)
		int tv = config.frontend.options[FE_OPT_THREAD].value;
		if (tv == 0) tv = legacy_tv; // legacy alias read above, before Config_free
		if (tv == 1) { thread_video = 1; thread_auto = 0; ta_phase = 2; ta_decided_by_user = 1; }
		else if (tv == 2) { thread_auto = 0; ta_phase = 2; ta_decided_by_user = 1; }
		else {
			int v = ta_read_verdict();
			if (v == 1) { thread_video = 1; ta_phase = 2; }
			else if (v == 0) ta_phase = 2; // decided: no benefit (re-decided only if sidecar removed)
			}
	#endif
		}
		}
	if (thread_video) {
		core_mx = (pthread_mutex_t)PTHREAD_MUTEX_INITIALIZER;
		core_rq = (pthread_cond_t)PTHREAD_COND_INITIALIZER;
		if (pthread_create(&core_pt, NULL, &coreThread, NULL) == 0) {
			core_thread_alive = 1; // without this the quit-join is skipped -> dlclose SIGSEGV
		} else { // creation failed: fall back to single-threaded rather than deadlock waiting on a thread that never ran
			LOG_info("thread_video: pthread_create failed, running single-threaded\n");
			thread_video = 0; thread_auto = 0; ta_phase = 2;
		}
	}
	toggle_thread = 0;  // config load must not leave a stale toggle armed (Codex #1)
	game_running = 1;   // runtime toggles legal from here
	{ // name the loop path ONCE per game log: the gov/drc/servo lines below mean different
	  // things per path, and an inert mechanism prints the same lines as an active one
		const char* lp = thread_video ? "threaded" : "serial";
#ifdef ZERO_FRONTEND_THREADING_V2
		if (zero_ftv2_depth2) lp = "threaded v2 depth-2 (CORE owns audio)";
#endif
		LOG_info("loop path: %s (auto-thread=%d)\n", lp, thread_auto);
	}
	
	PWR_warn(1);
	PWR_disableAutosleep();
	
	// force a vsync immediately before loop
	// for better frame pacing?
	GFX_clearAll();
	GFX_flip(screen);
	
	Special_init(); // after config

	Gov_start(); // closed-loop governor takes the clock for gameplay (overrides static overclock)
	// benchmark telemetry (no-op unless BENCH=1): budget_us from the core frame rate
	tlm_init(tag_name, core.fps>0 ? (int)(1000000.0/core.fps) : 16667);

	sec_start = SDL_GetTicks();
	TMARK("ready_to_run");
	{ static int first = 1; if (first) { first = 0; } }
	while (!quit) {
		GFX_startFrame();
		
		if (!thread_video) {
			if (use_ftv2) {
#ifdef ZERO_FRONTEND_THREADING_V2
				// depth-2 pipelined: MAIN packs THIS epoch's input snapshot (buttons + both analog
				// sticks + the FF control flag, F11; analog via uint16_t casts — shifting a negative
				// signed axis is UB), the CORE thread runs core.run() concurrently and reads the
				// snapshot via input_state_callback, MAIN drains + presents. The present's vsync is
				// the SOLE pacer (present_frame routes depth-2 through the never-skip GFX_flip) — it
				// blocks MAIN, overlapping the CORE's next epoch. fc_pump non-blocking (block=DEADLOCK).
				static uint64_t snap[4];
				// MAIN is the only credit-returning consumer. If the pipeline is full,
				// fc_pump can only drain. Keep control/power cancellation responsive at a
				// bounded 250Hz, but only publish a snapshot when a credit can be granted.
				int can_grant = atomic_load_explicit(&zero_ftv2.fr.credits_out, memory_order_acquire)
				                < zero_ftv2.fr.depth;
				static uint32_t last_input_poll = 0;
				uint32_t input_now = SDL_GetTicks();
				if (can_grant || input_now - last_input_poll >= 4) {
					input_tick();
					last_input_poll = input_now;
				}
				if (can_grant) {
					snap[0] = (uint32_t)buttons;
					snap[1] = ((uint64_t)(uint16_t)pad.laxis.x << 16) | (uint16_t)pad.laxis.y;
					snap[2] = ((uint64_t)(uint16_t)pad.raxis.x << 16) | (uint16_t)pad.raxis.y;
					uint32_t visual_period_us = core.fps > 1.0
						? (uint32_t)(1000000.0 / core.fps + 0.5) : 16667;
					snap[3] = (uint64_t)(uint32_t)fast_forward
					        | ((uint64_t)visual_period_us << 8);
				}
				uint64_t ftv2_p0 = zero_ftv2_presented;
				fc_pump(&zero_ftv2, snap, zero_ftv2_drain, NULL);
				if (atomic_load_explicit(&zero_ftv2_fatal, memory_order_acquire)) {
					LOG_error("threading v2: frame-pool allocation failed; exiting for serial fallback\n");
					quit = 1; // leave the armed canary in place
				}
				// No frame ready this tick (CORE at its floor, no headroom to buffer ahead): briefly
				// idle instead of tight-spinning. 500us adds no perceptible latency; the vsync present
				// still paces the real frames at 60. Takes MAIN off the ~4500/s spin -> lower CPU.
				if (zero_ftv2_presented == ftv2_p0) {
					struct timespec ts = {0, 500000};
					nanosleep(&ts, NULL);
				}
#endif
			} else {
				core.run();  // depth<2 (and every guard-off build): plain serial, video_refresh
				             // presents inline on MAIN — zero engine overhead (F23-consistent).
				gen_ticks++; // GENERATED epoch, counted at the run-loop on MAIN — includes frames
				             // the core emits with a NULL/duplicate video callback (Codex F1).
			}
				if (!use_ftv2) limitFF();
			trackFPS();
		}

		if (thread_video && !quit) {
			// take the newest frame from the mailbox; present OUTSIDE the lock so the
			// core never stalls behind the vsync wait. The timed wait keeps this loop
			// servicing the menu and quit even while the core is paused.
			pthread_mutex_lock(&core_mx);
			if (!frame_ready) {
				mb_waits++; mb_waits_total++;
				struct timespec ts;
				clock_gettime(CLOCK_REALTIME, &ts);
				ts.tv_nsec += 20*1000000L;
				if (ts.tv_nsec >= 1000000000L) { ts.tv_sec += 1; ts.tv_nsec -= 1000000000L; }
				pthread_cond_timedwait(&core_rq, &core_mx, &ts);
			}
			SDL_Surface* frame = NULL;
			if (frame_ready) {
				SDL_Surface* t = presentbuffer; presentbuffer = readybuffer; readybuffer = t;
				frame = presentbuffer;
				frame_ready = 0;
			}
			pthread_mutex_unlock(&core_mx);
			if (frame) {
				video_refresh_callback_main(frame->pixels,frame->w,frame->h,frame->pitch);
				GFX_flipGame(screen); // game path — skippable (see invisible-menu fix)
				mb_flips_total++;
				static uint64_t last_flip_us = 0;
				uint64_t now_us = getMicroseconds();
				// only 60fps-class content can meaningfully "dup" — internally-low-fps
				// games (THPS demos run 15fps internally) have long intervals by design
				if (last_flip_us && fps_double > 55.0 && now_us - last_flip_us > 24000) { mb_dups++; mb_dups_total++; }
				last_flip_us = now_us;
			}
		}
		
		if (show_menu) {
			park_core("menu"); // savestates must never overlap a running core.run
			gov_mem_save(); // parked boundary: persist without touching the gameplay audio reserve (review 7)
			// a menu visit invalidates any in-flight auto-threading window HERE: the
			// abort check in the tick path never observes show_menu because Menu_loop
			// is synchronous and clears it before returning (audit 2026-07-11). Without
			// this, menu wall-clock silently counted toward the timed comparison.
			if (thread_auto && ta_phase == 1) {
				ta_phase = 0; ta_phase_at = 0;
				toggle_thread = 1; // abort the trial: back to single, re-observe later
				LOG_info("auto-thread: trial aborted (menu opened mid-window)\n");
			}
			else if (thread_auto && ta_phase == 0) ta_phase_at = 0; // restart observation clock
#ifdef ZERO_FRONTEND_THREADING_V2
			// park the CORE thread (drain pending frames) while the menu runs, release after
			if (zero_ftv2_running) fc_park(&zero_ftv2, zero_ftv2_drain, NULL, 0);
#endif
			Menu_loop();
#ifdef ZERO_FRONTEND_THREADING_V2
			if (zero_ftv2_running) fc_release(&zero_ftv2);
#endif
			// reset the rate window: a second that spans the menu would read as a false
			// generation-rate drop and spuriously climb the governor on menu exit.
			// (threaded mode resets before the resume signal instead — the core owns
			// these counters there and is already running again by this point)
			if (!thread_video) {
				RunLoop_resetWindow();
			}
		}

		if (use_ftv2) toggle_thread = 0;
		if (toggle_thread) {
			toggle_thread = 0;
			if (was_threaded && !thread_video) {
				// LOG_info("was fast forwarding while previously threaded (%i) so re-enabling threading %i\n", thread_video, !thread_video);
				// revert to pre-fast_forward state before toggling
				was_threaded = 0;
				thread_video = !thread_video;
			}
			// LOG_info("toggling thread from %i to %i\n", thread_video, !thread_video);
			LOG_info("thread toggle: %d -> %d (ff=%d was=%d auto_phase=%d)\n", thread_video, !thread_video, fast_forward, was_threaded, ta_phase);
			if (!thread_video) {
				// enable
				zero_servo_release(); // MAIN still owns audio production here: hand the resampler back untrimmed
				thread_video = 1;
				core_mx = (pthread_mutex_t)PTHREAD_MUTEX_INITIALIZER;
				core_rq = (pthread_cond_t)PTHREAD_COND_INITIALIZER;
				if (pthread_create(&core_pt, NULL, &coreThread, NULL) == 0) {
					core_thread_alive = 1;
				} else {
					LOG_info("thread toggle: pthread_create failed, staying single-threaded\n");
					thread_video = 0;
				}
			}
			else {
				// disable: thread_video stays 1 until the join returns — the thread's
				// final in-flight frame must take the mailbox path, not GL from its
				// thread. Liveness guard: FF entry may have already torn it down.
				if (core_thread_alive) {
				pthread_mutex_lock(&core_mx);
				core_thread_exit = 1;
				pthread_cond_signal(&core_pause_cv);
				pthread_mutex_unlock(&core_mx);
				pthread_join(core_pt,NULL);
				core_thread_alive = 0;
				core_thread_exit = 0;
				frame_ready = 0;
				}
				thread_video = 0;
				
				// force a vsync immediately before loop
				// for better frame pacing?
				GFX_clearAll();
				GFX_flip(screen);
			}
		}
		// LOG_info("frame duration: %ims\n", SDL_GetTicks()-frame_start);

		// closed-loop governor: sample core work each gameplay frame, run the
		// controller once per GOV_TICK_FRAMES. Skipped in the menu (which owns its
		// own clock). The tick's signal is the GENERATION-RATE slip detector (D24):
		// BIGSLIP when the core's output rate falls >=10% under target, SLIP under
		// 97.5%; otherwise a per-path sink gate says SLACK or BUSY — serial: p95 core
		// work vs the budget at the next OPP down (gov_sink_fits); threaded: window
		// utilization scaled to the next OPP (<=0.85); fast-forward: the multiplier
		// band; h700: unconditional probe-down. No per-frame budget-miss threshold exists.
		if (!show_menu && (gov_active || tlm_enabled())) {
			// PURE CPU work = frame work (startFrame->flip) MINUS the audio-pacing block
			// (SND_batchSamples blocking on a full buffer during core.run) — blocked frames are
			// pacing, not load. Used by both the governor's predictive sink gate and the bench
			// percentiles. (thread_video sync waits are not subtracted: cleaner-than-raw, not perfect.)
			// History (D14/D23/D24): sinking on raw work ran PS1 warmer (saturation, no race-to-idle);
			// the blunt busy-hold then over-held NES/PS1 one OPP step high. The predictive gate
			// (gov_sink_fits: p95 pure work scaled to the next clock must fit 85% of budget) replaces
			// both — quantitative race-to-idle instead of a binary guess.
			if (gov_active) {
				// Serial mode contributes one work sample per outer iteration. Depth-2 samples
				// completed epochs in zero_ftv2_drain; pump-only iterations contribute nothing.
#ifdef ZERO_FRONTEND_THREADING_V2
				if (!zero_ftv2_depth2)
#endif
				{
					SND_Stats as; SND_getStats(&as);
					long pace_us = (as.wait_ms - gov_prev_wait_ms) * 1000; gov_prev_wait_ms = as.wait_ms;
					uint32_t raw_us = GFX_getFrameWorkUs();
					gov_work[gov_frames] = (pace_us > 0 && (uint32_t)pace_us < raw_us) ? raw_us - (uint32_t)pace_us : raw_us;
					gov_frames++;
				}
				if (gov_frames >= GOV_TICK_FRAMES) {
					// PRIMARY signal: the core's generation rate (core.run iterations/sec, from
					// trackFPS) vs its target fps — jitter-immune ground truth of game speed.
					// SECONDARY: the PREDICTIVE SINK GATE — sort the batch's pure work, take p95,
					// and only allow a sink if the workload would still fit at the lower clock
					// with >=15% idle headroom (gov_sink_fits: the quantitative form of D14's
					// race-to-idle rule; replaces the blunt busy-hold that kept NES/PS1 one OPP
					// step above their proven minimums).
					// Fast-forward is just a different target: fps x the FF multiplier. The
					// governor then finds the lowest clock that holds THAT — FF gets the
					// clocks it needs (measured: 2.2x of a 4x cap when stuck at the floor)
					// without pinning max for an hour of Pokemon grinding.
					// Max FF Speed index 0 = "None" (uncapped): there is no finite target, so
					// treat uncapped FF as a permanent slip -> the ceiling climbs to profile max
					// (Codex finding #3: fps*1 held the settled floor = clock-starved FF again)
					// The governor must budget against the rate we actually TARGET. With a static
					// panel match the core intentionally settles below core.fps, and budgeting from
					// the native rate makes the predictive sink reject a sink that would genuinely
					// fit — holding an OPP higher than necessary and persisting it via gov-memory,
					// which is precisely backwards for this fork.
					double gov_native_fps = core.fps * (1.0 + zero_static_rate_ppm / 1000000.0);
					double gov_target_fps = gov_native_fps * (fast_forward ? (max_ff_speed > 0 ? max_ff_mults[max_ff_speed] : 1000) : 1);
					double gov_gen = cpu_double;
#ifdef ZERO_FRONTEND_THREADING_V2
					if (zero_ftv2_depth2) gov_gen = fps_double;
#endif
					int fps_short = (gov_gen > 0 && gov_target_fps > 0 && gov_gen < gov_target_fps * 0.975);
					int fps_gross = (gov_gen > 0 && gov_target_fps > 0 && gov_gen < gov_target_fps * 0.90);
					// A menu/sleep reset deliberately clears the published generation rate. Do not make a
					// sink decision until trackFPS publishes a fresh wall-clock sample.
					if (gov_gen <= 0.5) { gov_frames = 0; continue; }
					int frame_overrun;
					if (fps_gross) frame_overrun = GOV_SIGNAL_BIGSLIP; // >=10% under = audible now; jump to max
					else if (fps_short) frame_overrun = GOV_SIGNAL_SLIP;
					else if (fast_forward) {
						// Capped FF that is HOLDING its finite target gets a generation-rate-driven
						// descent (Codex v1.4-ff #1): with only unreachable targets, "BUSY: never
						// sink during FF" was harmless — a reachable 1.25x target made it pin
						// f_max forever. SLACK here reuses the normal convergence machinery
						// exactly as the review prescribes: the sink ladder's 4-tick dwell gives
						// controlled one-OPP probes, presink-undo reverts on the first fps_short,
						// and fail-memory stops re-probing a clock that slipped — all driven by
						// generation rate alone (the per-frame WORK estimates stay unused during
						// FF; presentation skipping makes them garbage, which is why BUSY was
						// originally chosen). Uncapped FF (index 0) keeps BUSY: no finite target.
						// Containment (Codex re-review): the descent is enabled ONLY for the
						// fractional band (<2x). The governor tick runs per 30 GENERATED frames,
						// so FF compresses its wall cadence; cpu_double refreshes at 1Hz wall.
						// At 1.25-1.75x the sink dwell is 1.14-1.6s wall >= the sample period
						// (fresh data per probe — the regime the device traces validated). At
						// 2x-8x dwell shrinks to 0.5-0.25s: multiple sinks on one stale sample
						// and fail-holds expiring in 7-15s wall = probe/pitch wobble. Integer
						// caps keep the previously-shipped BUSY hold until FF governor timing
						// is wall-clock invariant (v1.4.1 candidate, D60).
						frame_overrun = (max_ff_speed > 0 && max_ff_mults[max_ff_speed] < 2.0)
							? GOV_SIGNAL_SLACK : GOV_SIGNAL_BUSY;
					}
					else if (thread_video) {
						// the main thread's frame window includes WAITING on the core thread, so
						// judge headroom by the core thread's own samples. Per-frame budgets
						// misjudge internally-low-fps games (THPS: one ~25ms render frame + three
						// ~2ms dupes still holds 60), so gate on WINDOW UTILIZATION instead:
						// predicted busy fraction at the next clock must leave >=15% idle.
						uint64_t sum = 0;
						int n = core_work_n < CORE_WORK_RING ? (int)core_work_n : CORE_WORK_RING;
						for (int a=0; a<n; a++) sum += core_work_ring[a];
						int next = gov_sink_target(&gov_state, &gov_profile);
						if (n > 2 && gov_target_fps > 0 && next < gov_state.ceil_khz) {
							double window_us = n * (1000000.0 / gov_target_fps);
							double util_next = ((double)sum / window_us) * ((double)gov_state.ceil_khz / (double)next);
							frame_overrun = util_next <= 0.85 ? GOV_SIGNAL_SLACK : GOV_SIGNAL_BUSY;
						}
						else frame_overrun = GOV_SIGNAL_BUSY;
					}
					else {
						for (int a=1; a<GOV_TICK_FRAMES; a++) { // insertion sort (30 ints, once per 0.5s)
							uint32_t v = gov_work[a]; int b = a-1;
							while (b>=0 && gov_work[b]>v) { gov_work[b+1]=gov_work[b]; b--; }
							gov_work[b+1] = v;
						}
						int p95 = (int)gov_work[GOV_TICK_FRAMES - 2]; // ~93rd percentile of 30
						int budget_us = gov_target_fps > 0 ? (int)(1000000.0 / gov_target_fps) : 16667;
						int next = gov_sink_target(&gov_state, &gov_profile);
#ifdef GOV_PLATFORM_H700
						// GEN-RATE DESCENT (not the frame-work gate). On the DE-layer present the
						// libretro core SELF-PACES to real time: core.run measures ~16.6ms wall for a
						// GB game (only ~40%% CPU; the rest is the core's own throttle) so p95 "work"
						// is ~15ms and the predictive gate reads BUSY forever, pinning the ceiling
						// (measured 2026-08-06). Reaching this branch already means NOT slipping
						// (fps_short/fps_gross are checked first), so the game is holding target ->
						// probe one OPP down. fail-memory + presink-undo revert a step that slips.
						(void)p95; (void)next; (void)budget_us;
						frame_overrun = GOV_SIGNAL_SLACK;
#else
						frame_overrun = gov_sink_fits(gov_state.ceil_khz, next, p95, budget_us)
							? GOV_SIGNAL_SLACK : GOV_SIGNAL_BUSY;
#endif
						{ // ZERO_GOV_DEBUG=1: periodic gate telemetry (why does/doesn't it sink?)
							static int zgd = -1, zgd_n = 0;
							if (zgd < 0) { const char* e = getenv("ZERO_GOV_DEBUG"); zgd = (e && e[0] && e[0] != '0') ? 1 : 0; }
							if (zgd && (++zgd_n % 10) == 0)
								LOG_info("gov-gate: p95=%dus budget=%dus next=%d signal=%d ceil=%d gen=%.1f\n",
									p95, budget_us, next, frame_overrun, gov_state.ceil_khz, gov_gen);
						}
					}
					// auto-threading state machine (evaluated at tick cadence; cheap).
					// A menu, sleep, or FF pause mid-window invalidates the comparison
					// (wall-clock elapsed but no gameplay measured) -> restart observation.
					if (thread_auto && ta_phase == 1 && (show_menu || fast_forward || was_threaded)) {
						ta_phase = 0; ta_phase_at = 0;
						toggle_thread = 1; // abort the trial: back to single, re-observe later
						LOG_info("auto-thread: trial aborted (menu/FF interrupted the window)\n");
					}
					// FF during OBSERVATION poisons the baseline the same way: an FF-pinned
					// ceiling makes FF-release look like a huge sink -> false "threaded"
					// commit (reconstructed from Bomberman's bogus sidecar, 2026-07-10).
					// Restart the observation clock whenever FF runs in phase 0.
					if (thread_auto && ta_phase == 0 && fast_forward) {
						ta_phase_at = 0;
					}
					if (!use_ftv2 && thread_auto && ta_phase != 2 && !fast_forward && !was_threaded) {
						uint32_t ta_now = SDL_GetTicks();
						if (!ta_phase_at) ta_phase_at = ta_now;
						if (ta_phase == 0 && ta_now - ta_phase_at >= TA_OBSERVE_MS) {
							if (!thread_video && gov_state.ceil_khz >= TA_TRIAL_THRESHOLD_KHZ) {
								// fighting for headroom: trial threading
								ta_base_ceil = gov_state.ceil_khz;
								// the trial's verdict = "did the ceiling sink a full step?" —
								// single-thread fail memory (holds up to 8 min) would block
								// the very sink being tested and falsely persist a "0"
								// verdict forever. Judge the trial from a clean slate
								// (Codex audit 2026-07-09).
								gov_state.fail_khz = 0;
								gov_state.fail_hold = 0;
								gov_state.fail_streak = 0;
								toggle_thread = 1;
								ta_phase = 1;
								LOG_info("auto-thread: trial ON (ceil %d)\n", ta_base_ceil);
							}
							else ta_phase_at = ta_now; // floor-dweller: keep watching (heavy-later games re-arm)
						}
						else if (ta_phase == 1 && ta_now - ta_phase_at >= TA_OBSERVE_MS + TA_TRIAL_MS) {
							// commit only if the ceiling verifiably sank a full step; any slip
							// storm during the trial raises the ceiling and fails this test
							if (gov_state.ceil_khz <= ta_base_ceil - 200000) {
								ta_write_verdict(1);
								ta_phase = 2;
								LOG_info("auto-thread: COMMIT (ceil %d -> %d)\n", ta_base_ceil, gov_state.ceil_khz);
							}
							else {
								toggle_thread = 1; // revert to single
								ta_write_verdict(0);
								ta_phase = 2;
								LOG_info("auto-thread: revert (ceil %d -> %d)\n", ta_base_ceil, gov_state.ceil_khz);
							}
						}
					}
					if (thread_video) {
						static uint32_t thr_log_at = 0;
						static int tl_w = 0, tl_o = 0; static long tl_u = 0;
						uint32_t tl_now = SDL_GetTicks();
						if (!thr_log_at) { thr_log_at = tl_now; tl_w = mb_dups_total; tl_o = mb_overwrites_total; SND_Stats s0; SND_getStats(&s0); tl_u = s0.underruns; }
						else if (tl_now - thr_log_at >= 60000) {
							SND_Stats s1; SND_getStats(&s1);
							LOG_info("thr-stats: dups/min=%d skips/min=%d underruns/min=%ld drc_ppm=%d\n", mb_dups_total - tl_w, mb_overwrites_total - tl_o, s1.underruns - tl_u, drc_ppm_now());
							thr_log_at = tl_now; tl_w = mb_dups_total; tl_o = mb_overwrites_total; tl_u = s1.underruns;
						}
					}
					int prev_ceil = gov_state.ceil_khz;
					gov_tick(&gov_state, &gov_profile, frame_overrun);
					if (gov_state.ceil_khz != prev_ceil) // log only when the ceiling actually moves
						LOG_info("gov: ceil %d->%d kHz (temp=%dC, signal=%d gen=%.1f/%.1f)\n", prev_ceil, gov_state.ceil_khz, gov_read_temp_c(), frame_overrun, gov_gen, gov_target_fps);
					{ // is the ceiling actually BINDING? An inert cap (schedutil sitting below it on
					  // its own) prints identical gov: lines to an active one; this is the only line
					  // that tells them apart. A cap that is never at-ceil is a passenger.
						static uint32_t cap_log_at = 0; static int cap_at_ceil = 0, cap_ticks = 0;
						int cap_cur = gov_read_cur_khz();
						if (cap_cur > 0) { cap_ticks++; if (cap_cur >= gov_state.ceil_khz) cap_at_ceil++; }
						uint32_t cl_now = SDL_GetTicks();
						if (!cap_log_at) cap_log_at = cl_now;
						else if (cl_now - cap_log_at >= 60000) {
							LOG_info("gov-cap: at-ceil %d/%d ticks ceil=%d actual=%d kHz\n", cap_at_ceil, cap_ticks, gov_state.ceil_khz, cap_cur);
							cap_log_at = cl_now; cap_at_ceil = 0; cap_ticks = 0;
						}
					}
					{
						int gm = govmem_post_tick(&gov_mem, frame_overrun, fast_forward, rate_seq, prev_ceil, gov_state.ceil_khz);
						if ((gm & GOVMEM_PRELOAD_DWELL) && gov_state.slack_run < GOV_DN_DWELL - 1)
							gov_state.slack_run = GOV_DN_DWELL - 1; // waive ONLY the dwell; gov_step keeps every other gate
						if (gm & GOVMEM_REACHED) LOG_info("gov-memory: reached remembered floor\n");
						if (gm & GOVMEM_DISARMED_SLIP) LOG_info("gov-memory: fast-sink canceled (slip before target)\n");
						if (gm & GOVMEM_EXPIRED) LOG_info("gov-memory: fast-sink expired unconsumed\n");
					}
					int carry = gov_frames - GOV_TICK_FRAMES;
					if (carry > 0)
						memmove(gov_work, gov_work + GOV_TICK_FRAMES, (size_t)carry * sizeof(gov_work[0]));
					gov_frames = carry;
				}
			}
			if (tlm_enabled()
#ifdef ZERO_FRONTEND_THREADING_V2
			 && !zero_ftv2_depth2
#endif
			) { // depth-2 telemetry is recorded once per RUN_DONE in the drain
				// us-precision pace subtraction, CLAMPED rather than skipped. The old form used
				// ms-rounded wait deltas and fell back to the RAW window whenever rounding pushed
				// the delta past it — so a fully audio-paced frame recorded its whole ~20ms as
				// "work". On MMP PS1 that painted 1-in-6 frames as over-budget on games
				// generating at full rate, and the phantom sent an evening chasing clock/dither/
				// thread/readahead fixes that all "failed" to move a number that was never work
				// (2026-07-28; the pin-verified +24% clock A/B is what exposed it).
				static uint32_t prev_wait_us = 0;
				SND_Stats as; SND_getStats(&as);
				// UNSIGNED subtraction: exact across the uint32 wrap (see SND_Stats in api.h).
				uint32_t pace_us = as.wait_us - prev_wait_us; prev_wait_us = as.wait_us;
				uint32_t raw_us  = GFX_getFrameWorkUs();
				uint32_t work_us = (pace_us < raw_us) ? raw_us - pace_us : 0;
				tlm_frame(work_us);
				tlm_audio(as.queue_frames, as.underruns, as.overruns);
			}
		}

		// Experimental dynamic rate control: the panel's true refresh runs faster than
		// the cores' 60.0 (Brick 60.8Hz, SP ~61Hz measured), and with three clocks in play
		// (audio-blocking pace, drift-free pacer, vsync) the slowest wins — so stock shows a
		// duplicated frame every ~1.3s. Feedback controller, no rate measurement needed: if
		// audio blocked during the window we are audio-bound (below panel rate) -> nudge the
		// resample ratio up; if it never blocked, vsync is the binding clock (at panel rate)
		// -> nudge down. Equilibrium hovers +/-150ppm around the true panel ratio. Games run
		// ~1.3% fast, pitch +23 cents — the industry-standard imperceptible trade (RetroArch
		// does the same). Heavy games that can't hold rate self-disable (no audio blocking ->
		// ratchets to 0 = stock). ~60fps non-PS cores whenever vsync is active; PS1 stays
		// excluded because rate adjustment audibly chopped BR2/THPS. Disabled by default;
		// ZERO_ENABLE_DRC opts into the diagnostic path and ZERO_NO_DRC remains a kill switch.
		if (!show_menu) {
			static int drc_ppm = 0;
			drc_ppm_expose(&drc_ppm);
			static int drc_frames = 0;
			static long drc_prev_wait = 0;
			static unsigned drc_window_epoch = 0;
			static int drc_disabled = -1;
			static int drc_was_fast_forward = 0;
			static int drc_restore_ppm = -1;
			if (drc_window_epoch != run_window_epoch) {
				SND_Stats das; SND_getStats(&das);
				drc_window_epoch = run_window_epoch;
				drc_frames = 0;
				drc_prev_wait = das.wait_ms;
			}
			if (drc_disabled == -1) drc_disabled = (getenv("ZERO_NO_DRC") != NULL);
			int drc_supported = (!drc_disabled && drc_system_allowed
				// A static panel match owns all three clocks. DRC only ever climbs (clamped >= 0)
				// because it was built for a panel FASTER than the core, so it cannot express a
				// slow-panel correction — and it would zero the baseline the moment it went
				// ineligible or fast-forwarded. Mutually exclusive by construction.
				&& !zero_static_rate_ppm
				&& core.fps >= 58.0 && core.fps <= 61.0
				// Lenient still presents through the same vsynced SDL renderer on tg5040;
				// only explicit VSYNC_OFF removes the panel clock DRC synchronizes to.
				&& GFX_getVsync()!=VSYNC_OFF);
			int drc_threaded = thread_video;
#ifdef ZERO_FRONTEND_THREADING_V2
			// Depth two owns audio production on CORE. MAIN may observe DRC telemetry,
			// but it must never mutate the live resampler or CORE pacer.
			drc_threaded = drc_threaded || zero_ftv2_depth2;
#endif
			int drc_eligible = (drc_supported && !fast_forward
				// a ceiling-saturated game has no headroom to run +ppm faster — asking
				// starves the audio ring on schedule (BR2 chop, ear-found 2026-07-08)
				&& gov_state.ceil_khz < gov_profile.f_max);
			if (fast_forward && !drc_was_fast_forward && drc_supported && drc_restore_ppm < 0)
				drc_restore_ppm = drc_ppm;
			drc_was_fast_forward = fast_forward;
			if (!drc_supported) drc_restore_ppm = -1;
			if (!drc_eligible) {
				// ...but never write over a static panel match. If a timing change installs one
				// while DRC happens to own a non-zero ppm, this cleanup would zero all three
				// clocks and silently erase the correction that was just applied.
				if (drc_ppm && !zero_static_rate_ppm) { // revert cleanly while ineligible
					drc_ppm = 0;
					if (!drc_threaded) {
						SND_setRateAdjustPPM(0);
						GFX_setPacePeriodUs(0);
						core_pace_ppm = 0;
					}
				}
			}
			else if (drc_restore_ppm >= 0) {
				drc_ppm = drc_restore_ppm;
				drc_restore_ppm = -1;
				drc_frames = 0;
				SND_Stats das; SND_getStats(&das);
				drc_prev_wait = das.wait_ms;
					if (!drc_threaded) {
						SND_setRateAdjustPPM(drc_ppm);
						core_pace_ppm = drc_ppm;
						GFX_setPacePeriodUs(drc_ppm ? (1000000/63) : 0);
					}
					LOG_info("drc: restored +%dppm after fast-forward\n", drc_ppm);
			}
			else if (++drc_frames >= 30) { // ~2Hz
				drc_frames = 0;
				int prev = drc_ppm;
				if (thread_video) {
					// threaded mode panel-lock: audio never blocks (core pacer) and queued
					// swapchains always block flips, so neither classic signal works. The
					// robust signal is the LONG-WINDOW FLIP RATE: measure flips over ~10s
					// (60.0 vs 60.8 differ by 6 flips per 10s — cleanly resolvable) and
					// hill-climb ppm until the rate stops rising: the plateau IS the panel
					// ceiling (vsync backpressure caps delivery there). Overwrites mean we
					// pushed past it — back off.
					static uint32_t pl_win_at = 0; static int pl_flips0 = 0;
					static double pl_prev_rate = 0; static int pl_locked = 0;
					uint32_t pl_now = SDL_GetTicks();
					if (!pl_win_at) { pl_win_at = pl_now; pl_flips0 = mb_flips_total; }
					else if (pl_now - pl_win_at >= 10000 && fps_double > 55.0) {
						double rate = (mb_flips_total - pl_flips0) * 1000.0 / (pl_now - pl_win_at);
						if (mb_overwrites > 0) { drc_ppm -= 150; pl_locked = 1; } // past the ceiling
						else if (!pl_locked)   drc_ppm += 1000;                    // climbing toward it (~80s to lock)
						else if (rate > pl_prev_rate + 0.15) pl_locked = 0;        // ceiling moved (mode change)
						if (pl_locked == 0 && pl_prev_rate > 1 && rate < pl_prev_rate + 0.15 && drc_ppm > 600) {
							pl_locked = 1; // rate stopped rising: plateau = panel-locked
							LOG_info("drc: threaded panel-lock at %.2f flips/s (+%dppm)\n", rate, drc_ppm);
						}
						pl_prev_rate = rate;
						pl_win_at = pl_now; pl_flips0 = mb_flips_total;
						mb_overwrites = 0;
					}
					mb_dups = 0; mb_waits = 0;
				}
				else {
					SND_Stats das; SND_getStats(&das);
					long dwait = das.wait_ms - drc_prev_wait;
					drc_prev_wait = das.wait_ms;
					if (dwait > 1) drc_ppm += 150; // audio-bound: still below the panel rate
					else           drc_ppm -= 150; // vsync-bound (or struggling): back off
				}
				if (drc_ppm < 0) drc_ppm = 0;
				if (drc_ppm > 25000) drc_ppm = 25000;
				{
					static uint32_t drc_log_at = 0;
					uint32_t dl_now = SDL_GetTicks();
					if (!drc_log_at) drc_log_at = dl_now;
					else if (dl_now - drc_log_at >= 60000) {
						LOG_info("drc-stats: ppm=%d mode=%s\n", drc_ppm, thread_video ? "threaded" : "single");
						drc_log_at = dl_now;
					}
				}
					if (drc_threaded) { drc_ppm = prev; } // threaded: telemetry-only for now —
				// applying ppm chopped audio (ear-verified A/B 2026-07-08); the panel-beat
				// question returns with an eyes-on session
				if (drc_ppm != prev) {
					SND_setRateAdjustPPM(drc_ppm);
					core_pace_ppm = drc_ppm;
					// pace the drift-free pacer slightly above any 60-class panel so it only
					// backstops; vsync + audio are the fine clocks while DRC is active
					GFX_setPacePeriodUs(drc_ppm ? (1000000/63) : 0);
					static int drc_logged = 0;
					if (!drc_logged && drc_ppm >= 6000) {
						LOG_info("drc: converged past +%dppm (panel-locked pacing)\n", drc_ppm);
						drc_logged = 1;
					}
				}
			}
		}

		// Audio ring occupancy servo. The exact rate match (Zero_applyRateMatch) balances
		// production and consumption ON AVERAGE, but nothing refills the ring after a stall
		// drains it: a drained ring stays drained (every later stall is a fresh underrun), and
		// a match that is off by a few ppm walks to one rail. A proportional term on ring
		// occupancy around a setpoint restores the auto-refill the audio-paced loop had:
		//   ppm = static + cubic(occupancy% - setpoint), smoothed   (audioservo.h, unit-tested)
		// Silent within a few points of the setpoint (5 points = 160ppm), the full 2% rail at
		// 50%/100%, ~2s time constant. 2% refills half a 200ms ring in ~5s: recovery after a
		// stall, not stall rescue (a present stall storm is a present-path bug, fixed there).
		// Serial path only: on the threaded/depth-2 paths CORE owns audio production and a
		// MAIN-side ppm write chopped audio (ear-verified 2026-07-08) — the same exclusion as
		// DRC. Scoped to an ACTIVE static match: an unmatched core keeps its audio-paced
		// fallback untouched, and an audio-paced loop sits at a full ring by design (a servo
		// there would just run the game +MAX fast). Present-skip makes even a matched loop
		// audio-paced during every dup streak (a skipped present has no vsync wait, so the
		// core free-runs until the ring backpressures), so a tick whose window saw the
		// producer BLOCK is not sampled: occupancy then measures the pacer, not the level
		// (review 2026-09-02). PS is excluded: presentation-drop's hysteresis (engage <50%,
		// release >=66%) was tuned against a near-full ring and a servo-held level would eat
		// its stall margin (v1.7.1 smoothness arc). No DRC term: DRC requires no static match
		// and this requires one, exclusive by construction (drc_ppm is deliberately left
		// stale when a match installs, so testing it would lock the servo out for good).
		// Governor brief 2026-09-02. ZERO_AUDIO_SERVO=1 enables (per platform where
		// ear-checked); =0 kills it for A/B.
		if (!show_menu) {
			static int servo_enabled = -1;
			static int servo_frames = 0;
			static long servo_prev_wait = -1; // SND wait_ms at the last tick; -1 = re-arm
			if (servo_enabled == -1) { const char* e = getenv("ZERO_AUDIO_SERVO"); servo_enabled = (e && *e && *e != '0'); }
			int servo_threaded = thread_video;
#ifdef ZERO_FRONTEND_THREADING_V2
			servo_threaded = servo_threaded || zero_ftv2_depth2;
#endif
			int servo_eligible = servo_enabled && !servo_threaded && zero_static_rate_ppm
				&& !fast_forward && !presentation_drop_supported
				&& GFX_getVsync() != VSYNC_OFF
				&& SND_isActive() && !SND_isPrefilling();
			if (!servo_eligible) {
				if (zero_servo_adj && !servo_threaded) zero_servo_release(); // never write under a CORE producer
				servo_frames = 0; servo_prev_wait = -1;
			}
			else if (++servo_frames >= 30) { // ~2Hz, the governor tick's cadence
				servo_frames = 0;
				SND_Stats ss; SND_getStats(&ss);
				// wall ms the producer spent blocked on a full ring this window. >0 means the
				// ring paced the loop (dup streak / overfill): hold the trim, do not sample.
				long blocked = (servo_prev_wait < 0) ? 1 : ss.wait_ms - servo_prev_wait;
				servo_prev_wait = ss.wait_ms;
				if (ss.frame_count > 0) {
					int occ = (int)((100L * ss.queue_frames) / ss.frame_count);
					if (blocked <= 0) {
						int adj = audioservo_step(zero_servo_adj, audioservo_target_ppm(occ));
						// re-apply when the trim moved OR the static match underneath changed:
						// Zero_applyRateMatch writes the bare static value, dropping our trim
						if (adj != zero_servo_adj || zero_static_rate_ppm != zero_servo_static) {
							static int servo_armed_logged = 0;
							if (!servo_armed_logged) {
								LOG_info("audio servo: armed (static %+dppm, setpoint %d%%, rail +-%dppm, smooth %d ticks)\n", zero_static_rate_ppm, AUDIOSERVO_SETPOINT, AUDIOSERVO_RAIL_PPM, AUDIOSERVO_SMOOTH);
								servo_armed_logged = 1;
							}
							zero_servo_adj = adj; zero_servo_static = zero_static_rate_ppm;
							SND_setRateAdjustPPM(zero_static_rate_ppm + adj);
						}
					}
					static uint32_t servo_log_at = 0; static int servo_held = 0;
					if (blocked > 0) servo_held++;
					uint32_t sl_now = SDL_GetTicks();
					if (!servo_log_at) servo_log_at = sl_now;
					else if (sl_now - servo_log_at >= 60000) {
						LOG_info("servo-stats: adj=%+dppm occ=%d%% held=%d/120 underruns=%ld\n", zero_servo_adj, occ, servo_held, ss.underruns);
						servo_log_at = sl_now; servo_held = 0;
					}
				}
			}
		}

		hdmimon();
	}
	
	// threaded video: the core thread executes core code — it MUST be joined before
	// Core_unload/dlclose rips that code out from under it. Audio is still running here,
	// so a core blocked in SND_batchSamples drains and exits cleanly.
	if (core_thread_alive) {
		pthread_mutex_lock(&core_mx);
		core_thread_exit = 1;
		pthread_cond_broadcast(&core_pause_cv);
		pthread_mutex_unlock(&core_mx);
		pthread_join(core_pt, NULL);
		core_thread_alive = 0;
		core_thread_exit = 0;
		SDL_Surface** mbx[3] = { &backbuffer, &readybuffer, &presentbuffer };
		for (int b=0; b<3; b++) {
			if (*mbx[b]) {
				free((*mbx[b])->pixels);
				SDL_FreeSurface(*mbx[b]);
				*mbx[b] = NULL;
			}
		}
	}

	gov_mem_save(); // persist this session's settled ceiling for the next launch
	Menu_quit();
	QuitSettings();

finish:

	// Always-safe stock voltage restore — MUST sit below the finish label so early-exit
	// paths (failed core.load_game etc.) restore too, not just the clean-quit path
	// (Codex audit 2026-07-09). Harmless when the uv engine never armed.
	PLAT_restoreCPUVolt();

	tlm_quit(); // benchmark: flush + close the CSV (no-op unless enabled)

#ifdef ZERO_FRONTEND_THREADING_V2
	if (zero_ftv2_inited) {
		// Exit ordering (Codex v1.4 final #1/#2). The run loop's LAST iteration can have
		// granted one more epoch after quit was set — CORE may still be inside core.run().
		// 1) PARK first: waits out any in-flight epoch + drains (the proven menu pattern),
		//    leaving CORE quiescent while audio and game memory are still alive.
		// 2) Terminal SRAM/RTC flush: the v2 vtable unload deliberately does NOT flush
		//    (serial Core_quit does) — without this, Save&Quit loses battery-backed saves.
		//    Safe here: core parked, pointers valid, audio untouched.
		// 3) fc_teardown: unload_game + deinit on the CORE thread, then JOIN — before
		//    Game_close/Core_unload(SND_quit) can free anything CORE might still touch.
		if (zero_ftv2_running) {
			fc_park(&zero_ftv2, zero_ftv2_drain, NULL, 0);
			Core_flushMemory();
		}
		fc_teardown(&zero_ftv2);
		Game_close();
		Core_unload();
	}
	else {
		// engine never came up (depth<2, or pre-init exit): stock serial ordering, untouched
		Game_close();
		Core_unload();
		Core_quit();
	}
#else
	Game_close();
	Core_unload();
	Core_quit();
#endif
#ifdef ZERO_FRONTEND_THREADING_V2
	// Reaching gameplay and then exiting through the normal loop is known-good. A successful
	// depth-2 session also resets its consecutive-failure count. A clean serial fallback only
	// clears the marker so depth-2 gets its one retry; a permanent build-scoped disable remains.
		if (game_running && !atomic_load_explicit(&zero_ftv2_fatal, memory_order_acquire)
		    && zero_ftv2_canary_armed && zero_ftv2_canary_clearable) {
			if (!zero_ftv2_canary_remove(zero_ftv2_canary)) zero_ftv2_canary_armed = 0;
		}
		if (game_running && zero_ftv2_depth2
		 && !atomic_load_explicit(&zero_ftv2_fatal, memory_order_acquire))
			zero_ftv2_failures_clear();
	#endif
	// NOTE: deliberately NOT clearing the panel here. Blanking on exit was worth it while the
	// launcher took 313ms to draw its first frame; it now takes 57ms (the SDL joystick open was
	// 249ms of that), so the clear only inserts a black flash between the last game frame and the
	// menu. Let the last frame hold for those few milliseconds instead (Dan 2026-08-10).
	Core_close();
	
	Config_quit();
	
	Special_quit();

	MSG_quit();
	PWR_quit();
	VIB_quit();
	SND_quit();
	PAD_quit();
	GFX_quit();
	
	buffer_dealloc();
	
	return EXIT_SUCCESS;
}
