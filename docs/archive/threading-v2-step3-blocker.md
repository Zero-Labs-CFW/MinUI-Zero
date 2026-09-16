# Threading v2 step 3 — STOP-and-report: the excise is a run-loop rewrite, not a deletion

**Status:** HISTORICAL BLOCKER REPORT. The guarded replacement strategy resolved this blocker;
D62 and the current source are authoritative. The status below is intentionally preserved.

Status: **step-3 excise-and-replace CANNOT be safely completed in one fork shot.** Per prime
directives A (byte-identical-OFF or STOP) and C (STOP on map-vs-reality contradiction), this
fork investigated the real minarch structure, confirmed a blocking finding the step-3 plan
did not account for, and did NOT touch minarch.c control flow. Delivers this finding +
a byte-identical-safe decomposition for a device-in-the-loop session to execute.

## The confirmed blocking finding (refines phase-2b)
The step-3 plan assumed the old `thread_video`/`coreThread` subsystem is cleanly excisable
("excise old thread code — one commit, guard-OFF still single-thread"). **It is not.** The
old subsystem is **always-compiled, runtime-branched code**, not `#ifdef`-walled dead code:

- Verified: **zero** `#if/#endif/#else` directives exist between minarch.c:5243 and :5540 —
  the entire run loop + auto-threading trial region. Every `if (thread_video) {...}` (run
  loop 5290+, the mailbox present at 5285-5300) and `if (thread_auto && ta_phase...)` (trial
  5320, 5474-5518) branch compiles **unconditionally**.
- The shipping single-thread build works by **runtime-forcing** `thread_video=0`,
  `thread_auto=0`, `ta_phase=2` in the *bootstrap decision only* (the one `#ifdef
  ZERO_DISABLE_FRONTEND_THREADING` block at 5220-5242). The threaded branches are compiled
  in, just never taken.
- The globals (`thread_video`, `ta_phase`, `core_mx`, `presentbuffer`, …) are always-declared
  (31, 43, 70-74). FF (1886/1891), Menu (1917/1992/4987), and sleep hooks reference them
  unconditionally.

**Consequence:** "excise the old subsystem" = **hand-rewriting the always-compiled run loop,
FF handler, Menu handler, and trial machinery**, with a behavioral-equivalence obligation for
the guard-OFF path. The v2 wire-in additionally requires restructuring the always-compiled
`Core_open`/`Core_init`/`Core_load`/`SND_init` into vtable stages (or duplicating their
sequencing in a guard-walled path). Neither is a mechanical fill; both change compiled output
of shared functions; neither is validatable without on-device iteration (deploy→observe→fix).
Directive A forbids shipping a blind hand-rewrite as byte-identical without that validation.

## Why a single fork can't finish it (and shouldn't try)
A correct excise-and-replace is a multi-round, device-in-the-loop surgery: each increment must
be built, deployed, and observed on real hardware before the next. A fire-and-forget fork that
rewrites the run loop blind and then deploys it risks exactly the broken-run-loop / latent-race
outcome the entire 4-round design process existed to prevent. The disciplined outcome is to
decompose into byte-identical-safe increments and hand them to an interactive/device session.

## Safe decomposition (each sub-step is byte-identical-OFF and independently validatable)
Key principle: **guard-wall, don't excise-first.** Keep the old code compiling under guard-OFF
until v2 is proven; remove it only after v2 is promoted to default. This makes "coexistence"
purely *compile-time-exclusive* (safe) — not the runtime third-mode the phase-2b doc rightly
warned against — and defers the risky deletion to the very end.

- **S3.1 — Guard-wall scaffold.** Wrap the existing run loop body and the `Core_*` bootstrap
  sequence in `#ifndef ZERO_FRONTEND_THREADING_V2`; open empty `#ifdef ZERO_FRONTEND_THREADING_V2`
  slots. Byte-identical OFF (the `#ifndef` branch is the unchanged existing source). Verify:
  guard-OFF build unchanged (compare object/behavior), tests pass. No functional change.
- **S3.2 — v2 bootstrap (guard-ON slot).** CORE thread + `fc_bootstrap` driving vtable stages.
  Honor divergences: `set_environment`+`get_system_info` currently run in `Core_open` on MAIN
  (F23 wants CORE — decide: call whole Core_open on CORE, or split); SDL window/renderer +
  `SND_init` stay MAIN-side at AV_READY (F-A) and `SND_init` needs `core.sample_rate` from
  `Core_load` (ordering); `Game_open` precedes `Core_init`; auto-resume unserialize as a CORE
  service op. Compile guard-ON aarch64.
- **S3.3 — v2 run loop (guard-ON slot).** `fc_pump` on MAIN + vtable `run` on CORE; route
  callbacks (video_refresh→`fc_emit_frame`, geometry/AV_INFO/SET_VARIABLE→`fc_emit_cmd`/
  `fc_emit_barrier`, audio→existing SND SPSC per F-B, menu/sleep/FF→`fc_park`/`fc_release`,
  State/reset→`fc_menu_op`). Compile guard-ON; run `check-forbidden-globals` + `__tls_get_addr`
  inspection on the guard-ON aarch64 binary.
- **S3.4 — DEVICE depth-1 (serial) bring-up.** Deploy guard-ON pinned depth=1; SNES boot +
  60s + audio + clean exit. This proves the new engine runs a game correctly *before any
  pipelining*. **Needs iteration** — this is the first rung a fork cannot do fire-and-forget.
- **S3.5 — DEVICE depth-2 + gauntlet subset.** Threading trial runs; menu-during-game (the
  invisible-menu class), sleep/wake, FF, savestate, cross-system smoke.
- **S3.6 — Re-home trial policy.** Port `ta_phase`/`ta_read_verdict`/sidecar logic onto
  `fc_set_depth` in the guard-ON path (the field-tested *policy* survives; only the racy
  *mechanism* is replaced). Guard-OFF keeps the old hooks untouched.
- **S3.7 — (final, separate) Excise.** Once v2 is validated and promoted to default, delete
  the old dead branches from what was the guard-OFF path. This is the only step that breaks
  byte-identical, and it happens last, deliberately, with v2 already proven.

## What this fork delivered
- This doc (the confirmed finding + decomposition). No minarch.c control-flow changes —
  upholding directive A, same disciplined choice as phase-2b, now with harder evidence.
- Confirmed the phase-2b makefile plumbing is correct: guard default-OFF, byte-identical when
  unset (`ifeq ($(ZERO_FRONTEND_THREADING_V2),1)` gates both SOURCE and `-D`).

## Recommendation to the parent / Dan
Step 3 is a **device-in-the-loop, multi-increment surgery** (S3.1→S3.7 above), not a
single-fork job. Execute it interactively with the Brick attached, validating each increment
on hardware before the next — or as a sequence of narrowly-scoped forks, one per sub-step,
with a device-observation gate between them. S3.1 (guard-wall scaffold) is the safe, mechanical
first commit and can be done anytime; S3.2+ want eyes on the device. The measurement finale
still needs Dan's DKC/Yoshi/Mario RPG save-state scenes.

---

## S3.2 fork addendum (code-grounded confirmation of the boundary)

A fork was dispatched to "fill the bootstrap stubs and prove the new engine BOOTS AND RUNS
a game at depth-1." Reading the real code before touching anything (no build-deploy-fix
cycles spent) confirmed the directive's milestone spans doc-S3.2+S3.3+S3.4 and cannot be
fork-completed. Specifics, with line numbers:

1. The parent milestone = S3.3 + S3.4, not S3.2. "Boots and runs a game" requires routing
   the always-compiled run loop through fc_pump (doc-S3.3, the #ifndef-wall of the old
   run-loop body) and iterative on-device bring-up (doc-S3.4, explicitly "the first rung a
   fork cannot do fire-and-forget"). Unchanged from the three prior STOP-reports.

2. Even doc-S3.2 (compile-only bootstrap fill) is not a mechanical fill — it is a
   decomposition of shared functions. The fc_vtable wants fine-grained F31 stages
   (get_system_info / init / load_game / setup_memory / arm_crash / get_av_info as separate
   ops). Real minarch bundles them coarsely:
   - Core_open (minarch.c:3392) = dlopen + dlsym-all + set_environment + get_system_info +
     callback registration, in one function.
   - Core_load (:3482) = load_game + SRAM_read/RTC_read (setup_memory) + Crash_install
     (arm_crash, :3498) + av_info, in one function.
   - Boot order in main (:5271-5316): Core_open -> Game_open -> Core_init -> Core_load ->
     SND_init(MAIN, needs core.sample_rate) -> State_resume.
   Filling the fine stubs means splitting these bundles. The F31-critical orderings
   (arm_crash ONLY after memory pointers valid; get_av_info after load_game; SND_init
   MAIN-side after Core_load per finding F-A) are exactly what the split must preserve — and
   a mis-split COMPILES CLEAN but breaks only when run (wrong crash-arm point = torn
   emergency save; wrong av order = bad geometry). Compile is not validation here; only S3.4
   device bring-up is. Committing a filled-but-never-run bootstrap would be unvalidated code
   masquerading as done — the inverse of the D55 "dead code hid a live bug" lesson.

3. Additional structural note: the S3.1 skeleton block sits at minarch.c:25 (after includes),
   before every function its stubs must call (Game_open:370, SRAM_read:562, State_resume:841,
   Core_*:3392+, SND_init). The S3.2/S3.3 fill must relocate the guard-ON block below those
   definitions (or forward-declare) — a further reason it is a deliberate edit, not a stub
   swap.

Fork outcome: no minarch.c changes (byte-identical trivially held), no device work (nothing
to validate without the run-loop reroute). This addendum is the deliverable. Recommendation
unchanged and reinforced: S3.2->S3.4 is one continuous device-in-the-loop session —
decompose the bootstrap, wire fc_pump, bring up depth-1 on the Brick, iterating on hardware —
best done interactively with Dan + the Brick, not as a fork. The engines
(framering/frontend_core) and the fine-grained vtable are ready; the surgery is the
coarse<->fine bootstrap split + run-loop reroute, both device-validatable only.
