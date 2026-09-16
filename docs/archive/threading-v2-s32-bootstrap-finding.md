# Threading v2 — S3.2 candidate write: structural finding + resolution

**Status:** HISTORICAL IMPLEMENTATION NOTE. The staged bootstrap is implemented; D62 and
the current source are authoritative.

Status: the depth-1 integration was NOT written as a blob. Reason below is a genuine
structural mismatch (not a mechanical stub fill), found by reading real minarch against the
F31 model. This doc resolves it with a concrete plan so the interactive bring-up executes
cleanly. Guard-OFF remains byte-identical (no minarch.c code changes this commit).

## The finding: fc_bootstrap's monolithic stage sequence ≠ minarch's real bootstrap
`fc_bootstrap` (frontend_core.c) runs the 11 stages back-to-back on the CORE thread (except
audio/renderer, MAIN-side per F-A/D57), each a pure isolated op. Real minarch's bootstrap is
NOT isolated core calls — it is **result-consuming and frontend-interleaved**:

1. **Stage results feed MAIN frontend state.** `Core_open` calls `core.get_system_info(&info)`
   (minarch.c:3448) then MAIN consumes `info` to build `core.name/version/extensions/
   need_fullpath` and the `config_dir/states_dir/saves_dir/bios_dir` paths + `mkdir`
   (3451-3465). GET_INFO is not a fire-and-forget CORE op; its result drives MAIN directory
   setup that everything downstream depends on.
2. **Frontend work is interleaved between core stages.** main() (5271-5317):
   `Core_open`→`Game_open`→**Config_load/init/readOptions** (frontend; some cores load
   options early "ffs", 5272 comment)→setOverclock/GFX_setVsync→`Core_init`→
   `Core_load`→**Input_init / Config_readControls / SND_init / Menu_init / State_resume**.
   The controller device comes from `Config_readControls`→`core.set_controller_port_device`
   (1463) — i.e. the CONTROLLER stage is driven by MAIN config state, not a standalone call.

`fc_bootstrap` has nowhere to run Config/Input/Menu between LOAD and CONTROLLER, and no path
to return `get_system_info`'s result to MAIN. Forcing the stubs into the monolithic sequence
would either drop the frontend interleave (breaks per-core option loading) or run
Config/SDL/Menu on the CORE thread (breaks F-A and the frontend's MAIN-affinity). Either is a
speculative blob that would burn on-device debug time chasing a self-inflicted structural
bug — so it was not written (D55: unvalidated code masquerading as done).

## The resolution (recommended — for the interactive session's first move)
**MAIN drives the bootstrap stage-by-stage; the CORE thread executes only the core.* ops.**
Add one small engine helper (host-testable, forkable):

    fc_state fc_boot_stage(fc* f, fc_op stage);  // dispatch ONE bootstrap op, return state

`fc_bootstrap` becomes a thin loop over `fc_boot_stage` (keeps the fake-core gate green).
minarch's guard-ON bootstrap then interleaves its existing MAIN frontend work between stages:

    create CORE thread (owns core.* from here — F23)
    MAIN: dlopen/dlsym + symbol-validate + callback registration   (dl* are MAIN-owned per F23)
    fc_boot_stage(GET_INFO)   → CORE runs core.get_system_info into shared `core`/info
    MAIN: build core.name/paths/mkdir from the result; Game_open; Config_load/init/readOptions
    fc_boot_stage(INIT)       → CORE runs core.init
    MAIN: (options already read; setOverclock; GFX_setVsync)
    fc_boot_stage(LOAD)       → CORE runs core.load_game + SRAM/RTC read
    fc_boot_stage(ARM_CRASH)  → CORE Crash_install (pointers valid)
    fc_boot_stage(AV)         → CORE core.get_system_av_info
    MAIN: Input_init; Config_readControls → set_controller (dispatch CONTROLLER stage);
          SND_init(core.sample_rate) [F-A MAIN]; renderer already up [F-A MAIN]; Menu_init
    fc_boot_stage(RESUME)     → CORE State_resume (nonfatal)
    → RUNNING; run loop drives fc_pump.

**Why this is safe:** stages are serialized — the CORE thread is QUIESCENT between stages and
MAIN is blocked during each (fc_boot_stage waits for the service ack), so shared `core`/`game`
struct access is race-free (no concurrent CORE/MAIN touch). Preserves F23 (every core.* on the
one CORE thread) and F-A (SDL/SND on MAIN). Result-passing is just the existing shared `core`
struct, valid because of the serialization.

**Alternative (rejected):** invasively reorder minarch's bootstrap so all core.* calls are
consecutive and frontend work moves entirely before/after — risks per-core breakage (nes/gb
early-option-load, 5272 "ffs"), higher blast radius, no upside over the dispatch approach.

## Run-loop + frame handoff (S3.3, unblocked once bootstrap resolves)
Model on the PROVEN old-threaded mailbox (minarch.c:5385-5410): CORE `vt.run`=core.run whose
video_refresh writes raw pixels to a ready buffer + `fc_emit_frame(payload=buffer handle)`;
MAIN `fc_pump` drain cb presents via `video_refresh_callback_main` + `GFX_flip` (the exact
existing present path). Depth-1 serial = one in-flight frame, so a single ready/present buffer
pair suffices (same as `readybuffer`/`presentbuffer`). Audio stays the SND SPSC ring (F-B).

## Device-bringup watch-points (for when the code exists)
- get_system_info result race: confirm the shared-struct read on MAIN happens-after the CORE
  stage ack (fc_boot_stage must fully drain+ack before returning).
- Game_open ordering vs INIT (real minarch: Game_open before Core_init; the F31 seq lists
  OPEN after INIT — reconcile: OPEN maps to Game_open which is largely frontend/path work,
  keep it MAIN-side before INIT, not a CORE stage, OR split game-path-prep (MAIN) from any
  core call).  ← genuine ambiguity, decide on-device.
- CONTROLLER stage driven by Config_readControls state — dispatch it AFTER Config_readControls.
- first-frame present timing / black-screen if the drain cb path or buffer handle is wrong.
- State_resume (RESUME) touching the core on CORE while MAIN sets up Menu — ensure ordered.

## What this commit contains
This findings doc only. No minarch.c changes (guard-OFF byte-identical trivially holds). The
S3.1 skeleton stubs are left as-is because the resolution changes their contract (GET_INFO
returns a result; OPEN may be MAIN-side; CONTROLLER is config-driven) — filling them under the
old monolithic assumption would be throwaway. Next step is `fc_boot_stage` (forkable, host+
sanitizer-validatable) then the interactive minarch bring-up.
