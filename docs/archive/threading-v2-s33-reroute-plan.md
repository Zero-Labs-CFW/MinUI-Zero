# Threading v2 — S3.3/S3.4 run-loop reroute plan (interactive device bring-up)

**Status:** HISTORICAL REROUTE PLAN. The reroute is implemented; D62 and the current source
are authoritative. Measurements quoted below describe earlier increments, not the candidate.

S3.2 landed (this commit): the guard-ON vtable is FILLED with real minarch calls and
RELOCATED to just before `main()` (it references core/game/State_*/Core_*, declared there).
Guard-ON compiles clean under -O3 -flto; guard-OFF is byte-identical (md5 bc632dcd ==
pristine). The vtable<->minarch mapping is now compile-validated. What remains — wiring
`main()` to drive it — is the interactive Dan+Brick session, because the three dataflows
below are device-validatable only. This doc is the checklist.

## Key simplification (verified in the makefile)
Guard-ON sets BOTH `ZERO_FRONTEND_THREADING_V2` AND (unconditionally) `ZERO_DISABLE_FRONTEND_
THREADING`. So under guard-ON the OLD thread_video/coreThread path is already compiled out —
the base run loop is the clean SINGLE-THREADED loop (`core.run(); limitFF(); trackFPS();` then
governor/DRC/pacing/catch-up). The reroute only has to replace that single `core.run()` and the
bootstrap — no old-mailbox tangle to fight.

## Bootstrap reroute (main() ~5271-5317) — wrap `#ifdef ZERO_FRONTEND_THREADING_V2` [v2] `#else` [orig] `#endif`
Per D58 checklist, interleaving MAIN work between fc_boot_stage calls:
1. MAIN: split `Core_open` — do dlopen/dlsym + the six `set_*_callback` registrations on MAIN
   (F23 allows dlopen/dlsym + registration on MAIN). Do NOT call `core.get_system_info` here.
2. `fc_init(&zero_ftv2,&zero_ftv2_vt,1)` (spawns CORE thread, QUIESCENT).
3. `fc_boot_stage(GET_INFO)` — CORE fills `zero_ftv2_info`.
4. MAIN: the name/version/paths/mkdir block from Core_open's tail, reading `zero_ftv2_info`
   (Core_getName, core.version, core.config_dir/states_dir/saves_dir/bios_dir, `system("mkdir")`).
   Then `Game_open(rom_path)`; `if(!game.is_open) goto finish` (teardown via fc_teardown);
   `Config_load/init/readOptions`; `setOverclock`; `GFX_setVsync`.
5. `fc_boot_stage(INIT)`; check `fc_boot_failed`.
6. `fc_boot_stage(LOAD)` — on fail (`-1`): MAIN runs the load-fail cleanup (deinit via
   fc_teardown, `goto finish`). `fc_boot_stage(MEMORY, ARM_CRASH, AV)`.
7. MAIN: `Input_init(NULL)`; `Config_readOptions`; `Config_readControls`; `Config_free`.
8. `fc_boot_stage(CONTROLLER)`.
9. `fc_boot_stage(AUDIO)` (=SND_init MAIN-side, D57), `fc_boot_stage(RENDERER)` (no-op here);
   `InitSettings`; `Menu_init`.
10. `fc_boot_stage(RESUME)` (=State_resume); `Menu_initState`.
11. `fc_boot_finish()` (QUIESCENT->RUNNING).
NOTE: the old bootstrap has a `#ifndef ZERO_DISABLE_FRONTEND_THREADING legacy_tv` block — under
guard-ON that's already dropped, so the #else branch keeps it and the #ifdef branch omits it.

## Run-loop reroute (the single `core.run()` at ~5375) — the THREE device-validatable dataflows
Replace guard-ON `core.run()` with `fc_pump(&zero_ftv2, snap, zero_ftv2_drain, NULL)`.

WATCH-POINT 1 — FRAME PRESENT: `video_refresh_callback` (~3245) currently presents directly
(GFX_flipGame). Under guard-ON + v2-running it must instead STASH the frame (pixels/w/h/pitch
into a shared slot) and `fc_emit_frame(&zero_ftv2, 0)`. The drain cb `zero_ftv2_drain(ctx,ev)`
runs on MAIN inside fc_pump: on a FRAME event, call `video_refresh_callback_main(slot.pixels,
slot.w,slot.h,slot.pitch)` + `GFX_flip(screen)`. Depth-1 is SERIAL so a single shared slot is
race-free (CORE produces, then RUN_DONE, then MAIN drains — no overlap). Add a `v2_running`
flag so the callback only diverts under v2. FIRST-BOOT CHECK: fb0 screenshot shows a game frame.

WATCH-POINT 2 — INPUT: `input_state_callback` reads MAIN-set pad globals. Depth-1 serial: MAIN
polls input before fc_pump, CORE reads during core.run — no overlap, so the existing globals
work with a trivial `snap[4]={0}`. (Depth-2 needs the real per-epoch snapshot — later.)

WATCH-POINT 3 — ENV CALLBACK: `environment_callback` fires on CORE during init/load, touching
config/options globals. Serial bootstrap = MAIN blocked during each stage, no overlap. Confirm
SET_GEOMETRY/AV_INFO mid-run are emitted via fc_emit_cmd/fc_emit_barrier (S3.3b, after boot works).

WATCH-POINT 4 — GOVERNOR/PACING: the governor tick + DRC + catch-up after core.run stay on MAIN
but read `core_work_ring` frame-work timing that now happens on the CORE thread. For a FIRST
boot they may read stale/zero and mis-govern (cosmetic, non-fatal). Layer the CORE-timing
plumbing in AFTER boot is proven.

## Lifecycle wiring
`show_menu` -> `fc_park(&zero_ftv2, drain, NULL, 0)` / `Menu_loop()` / `fc_release`. Sleep same.
State save/load/reset -> `fc_menu_op(FC_OP_SERIALIZE/UNSERIALIZE/RESET, slot, drain, NULL)`.
Quit (below `finish:`) -> `fc_teardown(&zero_ftv2)` (runs the state-keyed cleanup oracle).

## Bring-up order (device)
Deploy guard-ON, launch SUPA. Failure modes by symptom: black screen = frame-present (WP1);
bail-to-menu = bootstrap stage fail (check PS.txt for which fc_boot_stage); hang = a wait not
draining (check fc_park/pump); garbled = pitch/geometry in WP1. Fix, rebuild, redeploy. Restore
shipped 3fafd92c after each attempt.
