# Threading v2 phase 2b — minarch integration findings (STOP-and-report)

**Status:** HISTORICAL BLOCKER REPORT. Its blocker was resolved by the guarded replacement
described in D62. The status below records the state when this finding was written.

Status: **integration BLOCKED on one decision.** Per the v2.4 contract's "STOP and note
rather than improvise" rule and the step-2 prime directive ("if you cannot guarantee
byte-identical, STOP and report"), the real minarch structure diverges from the integration
map in a *fundamental* way that must be decided before the run-loop surgery is safe. This
fork delivered the safe, zero-risk parts (build-flag plumbing + aarch64 engine compile) and
this report; it did NOT touch minarch.c's control flow.

## The blocking divergence (D-log candidate)
**minarch.c already contains a complete frontend-threading subsystem** — the `thread_video`
/ `coreThread` mailbox path (the v1.3 threading, currently compiled OUT via
`ZERO_DISABLE_FRONTEND_THREADING`). The integration map (docs/threading-v2-phase2-integration.md)
was written assuming a clean single-threaded base to *add* threading to. That base does not
exist. Concretely, minarch.c already has:
- `coreThread` (minarch.c:5087) — the old CORE thread + its `should_run_core` handshake.
- `core_mx`/`core_rq` (main:5245) — the old mutex/condvar mailbox.
- `presentbuffer`/`readybuffer`/`frame_ready` — the old double-buffer present mailbox
  (video_refresh_callback:3246, main loop:5281+).
- The auto-threading trial machinery: `thread_auto`, `ta_phase`, `ta_read_verdict`,
  `FE_OPT_THREAD`, FF hooks (1886/1891), Menu hooks (1917/1992/4987) — all built around the
  OLD thread model.

**Consequence:** v2 cannot be "wired in" alongside this. It must **replace** the old
`thread_video` subsystem wholesale (recommended — the old path is already dead code under
`ZERO_DISABLE_FRONTEND_THREADING`, D52), OR coexist as a fragile third mode. Replacement is
the right call but it is a large, deliberate excision touching the run loop, FF, Menu,
sleep, and the trial machinery — not a mechanical vtable fill, and not safely done without
the iterative on-device validation this step explicitly excludes.

## Secondary divergences (real bootstrap order vs F31)
Verified against minarch.c:5171–5220:
1. `set_environment` + `get_system_info` both execute **inside `Core_open`** (3292),
   immediately after dlsym, on MAIN — not as separate CORE service ops. F23 wants them on
   CORE. Splitting them means restructuring Core_open.
2. **`SND_init` depends on `core.sample_rate`/`core.fps`, which are only populated by
   `Core_load`** (retro_load_game). So audio-init (F31 FRONTEND_READY) has a hard data
   dependency on CONTENT_LOADED — confirms F-A (audio is MAIN-side) and adds the ordering
   constraint: the vtable's `audio_init` must run after `load_game`, reading core-published
   av-info. This is compatible with F31 (AV_READY precedes FRONTEND_READY) but the real code
   interleaves `Game_open`→`Config`→`Core_init`→`Core_load`→`SND_init` in an order the
   vtable stages must be mapped onto exactly, not assumed.
3. `Game_open` (content path open) runs **before** `Core_init` in real minarch; F31 orders
   `open_content` after `init`. Path-prep-before-init is benign, but the mapping must be
   explicit.
4. Auto-resume (`State_resume`, 5216) runs on MAIN after `SND_init`/`Menu_init` — matches
   F31 RESUME_APPLIED as a late service op; fine, but it emits via the core (unserialize)
   so it must run as a CORE service op in v2 (it currently does not).

## The decision needed (for the parent / Dan)
**Q: Does v2 replace the old `thread_video`/`coreThread` subsystem entirely?**
Recommended **YES**: it is already dead (compiled out, D52), the v2.4 contract supersedes
its design, and coexistence is strictly worse. This makes step 3 an *excise-and-replace*:
remove the old mailbox/coreThread/trial-around-old-model code, then build the new run loop
on `fc_pump`/`fc_bootstrap`/`fc_menu_op` with the vtable bound to the (restructured) Core_*
functions. The auto-threading *policy* (trial → verdict → sidecar) is preserved and re-homed
onto `fc_set_depth`.

## What this fork delivered (safe, zero-risk)
1. This findings doc.
2. `ZERO_FRONTEND_THREADING_V2` makefile plumbing (default OFF; adds `framering.c` +
   `frontend_core.c` + the `-D` only when ON). **Guard-OFF SOURCE list and CFLAGS are
   unchanged → shipped build byte-identical.** No change to minarch.c control flow.
3. aarch64 toolchain compile-check of the engine (framering + frontend_core) — proves the
   phase-1 engine compiles under the real `-O3 -flto` aarch64 toolchain, not just host clang.

## Step 3 plan (post-decision)
1. Decision ratified → excise old `thread_video` subsystem (one commit, guard-OFF still the
   single-thread path).
2. Restructure `Core_open`/`Core_init`/`Core_load`/`SND_init` into vtable stages honoring
   divergences 1–4 (SDL/audio init stay MAIN-side, F-A).
3. Fill the vtable; route callbacks (video_refresh→`fr_core_emit`, env cmds→emit+barrier,
   audio→existing SND SPSC per F-B); run loop → `fc_pump` on MAIN + vtable `run` on CORE.
4. Guard-ON aarch64 compile → `__tls_get_addr` inspection → on-device SNES boot smoke →
   full gauntlet → real-core measurement against Dan's save-state scenes.
