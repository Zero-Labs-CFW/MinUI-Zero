# Threading v2 — depth-2 integration design (the Codex review artifact)

**Status:** HISTORICAL REVIEW ARTIFACT. The implementation is now integrated; D62 and the
current source are authoritative. This document records the adversarial design inputs and must
not be read as current release status. It originally covered the work for turning the serial
depth-1 rendezvous into the depth-2 **pipeline** that is the actual energy win.

---

# REVISION 6 — post-Codex round 5 (2026-07-15) — PAPER DESIGN CONVERGED

Round 5: 7 findings (2 P0, 5 P1), **no architectural reversal**, UNRESOLVED: none. Codex drew the
explicit paper-vs-implementation line and audited the shipped cores. These are the final paper
refinements; with them folded in, the depth-2 design is architecturally converged and the remaining
risk is Codex's own "implementation/harness should adjudicate" list (below).

- **D-d3′ GET_CURRENT_SOFTWARE_FRAMEBUFFER → return false THROUGHOUT v2 (P0-1), not just depth-2.**
  PCE Fast probes it with partially-uninitialized output fields and MinArch today returns *true*
  without populating them (a latent pre-existing bug — uninitialized read). Returning false across
  all of v2 (depth-1 included) and in every service phase fixes both. **Shipped-core audit (Codex):**
  fceumm / pcsx_rearmed / mednafen_pce_fast probe it but all carry fallback buffers; no shipped core
  uses SET_AUDIO_CALLBACK or SET_FRAME_TIME_CALLBACK (only non-shipped fake-08). Leaning out is
  confirmed safe — it disables only a zero-copy path the frontend never validly implemented.

- **D-d5′ options-snapshot pin/refcount/reclamation (P0-2).** Each immutable options snapshot is
  **refcounted**: pinned while any outstanding credit (or in-flight service) may still read it; MAIN
  frees it only when the last referencing credit retires (refcount → 0). Service-phase snapshots are
  pinned for the service's duration. Same credit-scoped lifetime discipline as the frame buffers —
  MAIN never frees a snapshot an older credit can still reach.

- **D-a2′ frame-retirement ownership split (P1-3).** Retirement responsibility follows the D-c
  ownership state: a buffer that never became EVENT_OWNED (pre-publication failure / FR_DROPPED)
  is retired by **CORE**; an EVENT_OWNED (FR_OK, published) buffer is retired by **MAIN** (on
  present, DISCARD-skip, stop, or failure). Exactly-once on every path, no path where a buffer is
  acquired but neither retired party owns it.

- **D-g2′ audio commit unit = a COMPLETE accepted input frame (P1-4).** Commit only whole accepted
  input frames, including **every resampler output** each input frame generates; never a partial
  input frame's outputs. This makes ring bytes + write index + resampler `diff`/`prev` + consumed
  count advance as one transaction per input frame — no "advanced the resampler, published nothing."

- **D-d6′ rumble needs pulse preservation AND synchronization (P1-5).** Atomic latest-value alone
  still erases an on→off pulse landing between VIB polls. Use a **synchronized ordered FIFO** (or an
  explicit minimum-pulse state machine) between MAIN and `VIB_thread`. (The `VIB_setStrength`/
  `VIB_thread` plain-field access is a PRE-EXISTING single-thread race — hardening, sequenced w/ D-l.)

- **D-j2′ runtime depth-1 demotion on steady-state exhaustion (P1-6).** Pool exhaustion is handled
  not only at qualification: if it occurs post-qualification (steady state), trigger a runtime
  **demotion to depth-1** via the depth-change gate (log it). Qualification-time exhaustion still
  disables depth-2 for the session; steady-state exhaustion demotes live.

- **D61-c seqlock odd/even bracketing on the ceiling write (P1-7).** A single version increment can
  miss an epoch running *during* the write. Bracket the cpufreq ceiling write with an odd/even
  counter (→odd before the write, →even after); a work sample records the version at start and end
  and is excluded from the sink estimator if either read is odd or the two differ. Supersedes D61-b's
  single-increment; fold into DECISIONS.md D61 at implementation.

**Codex's paper-vs-implementation split (accepted as the closure boundary):**
- *Resolved on paper (this revision):* reject GET_CURRENT_SOFTWARE_FRAMEBUFFER throughout v2; options
  snapshot pin/refcount/reclamation; frame ownership transitions for FR_OK vs FR_DROPPED; complete-
  input-frame audio commit unit; synchronized pulse-preserving rumble; runtime pool-exhaustion
  demotion; odd/even clock bracketing.
- *Implementation + sanitizer harness adjudicate:* acquired-frame-count == retired-frame-count on
  every path; snapshot poisoning/refcounts across credits and services; exactly-once cleanup at every
  F31 state; cancellation with a nearly-full audio ring at every resampling ratio; post-qualification
  exhaustion + demotion; ceiling writes before/during/after work samples; command routing from every
  CORE phase.

**Status: the depth-2 integration design is architecturally CONVERGED.** Six review rounds
(13→11→8→11→7, one architectural error caught and reversed) took it from a 3-WP sketch to an 8-WP
design-of-record with the CORE-pure-producer principle, ordered frame/command streams, credit-scoped
buffers with explicit retirement, phase-routed services, refcounted snapshots, a MAIN-owned
seqlock-versioned governor, and a full decision trail (D-a…D-l, D61). What remains is
implementation under plain/TSan/ASan and the on-device A/B (gated on the demanding-scene save states).

---

# REVISION 5 — post-Codex round 4 (2026-07-15)

Round 4: 11 findings (5 P0, 6 P1). The count rose from 8 because rev-4's concrete mechanisms could
finally be attacked precisely — NOT divergence: round 4 found **zero architectural errors** (unlike
round 3's D-a), R3-F1/R3-F8 are RESOLVED, and the "sound parts" list grew (ordered frame
application, DISCARD applies commands, FR_OK/FR_ABORT ownership transfer, slot lifetime, drop-on-
exhaustion core-safe). Every remaining item is edge-completeness on a now-locked architecture.
Decisions:

- **D-a2 retirement ≠ presentation (F1, engine).** A frame buffer's return to the pool is an
  exactly-once RETIREMENT hook, distinct from presentation, invoked for EVERY acquired FR_EV_FRAME
  buffer: normal present, DISCARD-skip, FR_DROPPED-after-acquire, stop, and every failure path.
  framering must call it whether or not the frame presents (my rev-4 conflated "don't present" with
  "don't retire" → the pool leak Codex found).
- **D-a3 DISCARD/V amendment (F7).** DISCARD suppresses only PENDING, unapplied frames; a frame
  already presented in-stream stays committed to V even if its RUN_DONE is later canceled. (Epoch
  staging is rejected — it conflicts with barrier prefix-drain.)
- **D-d2 phase×command matrix (F3).** Routing = (CORE phase → stream) × (command → payload/barrier
  class). A command type lists its behavior in EACH phase it can occur. AV_INFO/geometry emitted
  during a bootstrap/runtime/teardown SERVICE route to the service stream with a drain-driven service
  ack (a barrier that is NOT park/stop-cancelled mid-service), never `fc_emit_barrier` (which asserts
  with no open epoch). The Cat-4 "RUN command" classification holds ONLY for FCP_RUN_EPOCH.
  SET_SYSTEM_AV_INFO is explicitly known to also fire during load_game → it needs the bootstrap-
  service route, not RUN-only.
- **D-d3 GET_CURRENT_SOFTWARE_FRAMEBUFFER → return false at depth-2 (F2).** Don't hand the core a
  zero-copy target it may hold across retro_run; cores fall back to normal video_refresh. Service
  phases reject it too. Lean.
- **D-d4 registration callbacks → return false at depth-2 (F9).** SET_FRAME_TIME_CALLBACK and
  SET_AUDIO_CALLBACK: returning true obligates the frontend to invoke them; we don't wire an
  invocation model, so return false (don't advertise unimplemented support). Revisit only if a
  shipped core needs them.
- **D-d5 option getters from an epoch snapshot (F4).** GET_VARIABLE / GET_VARIABLE_UPDATE answer from
  an immutable per-epoch options snapshot (a versioned pointer swapped at a grant boundary, like
  input); CORE never clears the MAIN-owned `config.core.changed` — update-ack via a snapshot
  generation or a CORE-owned consumed flag. (Runtime SET_VARIABLE otherwise races the getter on the
  same OptionList.)
- **D-b2 exactly-once teardown (F5, engine).** ONE terminal path governed by the F31 oracle:
  callback-emitting unload/deinit run as a drain-driven service (MAIN drains their products to ack),
  set `cleanup_done`, THEN stop = thread-exit-only. `terminal_cleanup` must NOT re-invoke unload/
  deinit after stop. Failed-bootstrap cleanup uses the same exactly-once transition.
- **D-g2 audio transaction includes resampler state (F8, engine).** The commit is transactional over
  ring bytes + write index + resampler `diff`/`prev` + consumed count + output position. Rule: always
  commit the processed prefix and return its accepted-input count; never advance resampler state
  without publishing the matching output (no "process 50, publish nothing, return 0").
- **D-d6 rumble ordered + atomic to the motor (F6).** Route rumble as an ordered command AND give the
  VIB layer a minimum-pulse state machine (or atomic/mutex the `queued_strength`/current fields) so an
  on→off pulse between 17 ms polls still reaches the motor. NOTE: the `VIB_setStrength`/`VIB_thread`
  plain-field access is a PRE-EXISTING single-thread race — hardening, sequenced with D-l.
- **D-j2 fixed pool budget + drop-as-event (F10).** Pool = depth + K (fixed small K). Acquire before
  copy; if none free, drop WITHOUT publishing and do NOT mark the epoch FRAME; record exhaustion
  telemetry; if exhaustion occurs during depth-2 qualification, invalidate/disable depth-2 (never hide
  drops from the threading verdict). Drop is core-safe (video_refresh returns void) once D-a2
  retirement is in place. No claim of a "provably sufficient" spill — exhaustion is a defined event.
- **D61-b clock-version counter (F11).** Add a clock-version counter; CORE stamps the version at the
  START and END of each work sample; MAIN excludes any sample whose start≠end version (it spanned a
  ceiling change) from the sink estimator, and starts a new governor window on the first clean
  post-transition RUN_DONE. Supersedes D61's looser "effective generation" wording (fold into
  DECISIONS.md when D61 is implemented).

**Convergence read:** the architecture — CORE pure-producer, ordered frame/command streams,
credit-scoped buffers with explicit retirement, phase-routed services, MAIN-owned governor — is
LOCKED (round 4 found no architectural error, only edge-completeness, and several fixes are "return
false / stay lean"). The accumulating engine touches (retirement hook, exactly-once teardown,
`out_slot`, run signature, audio shortfall+resampler transaction) mean implementation reopens and
RE-VERIFIES framering/frontend_core under plain/TSan/ASan — where most remaining edges (retirement
leak, teardown exact-once, audio transaction, options snapshot) are caught far more decisively than
in prose. **This is the natural hand-off point from paper review to test-driven implementation.**

---

# REVISION 4 — post-Codex round 3 (2026-07-15)

Round 3 confirmed D-f/D-h/D-i/D-j "implementable as written" (governor lifecycle, terminal
poweroff, save-identity, frame OOM — CLOSED). It found the remaining P0s in D-a…D-d, including a
real architectural error in D-a and an overclaim in D-d (a table I described but never wrote).
Both accepted. Rev-4 corrects them.

**D-a REVERTED — ordered frame events + bounded pool, NOT coalesce-at-RUN_DONE (fixes R3-F1/R3-F2).**
Round-3 F1 is correct: presenting once at RUN_DONE breaks the command/frame ordering contract (a
`SET_GEOMETRY` emitted after a frame would apply, during stream drain, before that frame's deferred
present). The coalescing shortcut is abandoned. Restore the straightforward v2.4 design: **each
`video_refresh` emits an ordered `FR_EV_FRAME` carrying its own pool-buffer id; MAIN presents each
frame IN STREAM ORDER inside the drain callback** (so a command before a frame applies before its
present, a command after applies after — ordering preserved by construction). Storage: a **bounded
frame-buffer pool** (`depth` + a small spill for multi-`video_refresh` epochs); each published frame
owns its buffer until MAIN presents and returns it; pool exhaustion drops the frame (FRAME payload is
droppable by contract). This also fixes R3-F2 for free: the buffer id rides the FRAME payload (no
`gen % depth` coupling, no need to carry a slot through RUN_DONE), and **`FR_DRAIN_DISCARD` already
skips `FR_EV_FRAME`** — so a discard park never presents a canceled frame and never advances the
last-presented visual gen V. Outcome FRAME/DUP/NONE stays via `tl_ep_frames`/`fc_signal_dup`; NULL
`video_refresh` routes to `fc_signal_dup` (DUP), and MAIN re-presents the MAIN-owned last-presented
immutable frame for DUP/NONE. The integration drain callback receives the drain **mode** so it can
assert it is never asked to present under DISCARD.

**D-b EXTENDED — bootstrap & teardown phases must use REAL drains (fixes R3-F3).** Two gaps: (1)
`fc_boot_stage` routes CORE service products through `fc_noop_cb` (frontend_core.c:157) — so a typed
command emitted during `retro_init`/`load_game` (options, input descriptors, geometry) is never
applied or freed → leak + lost state. Fix: bootstrap stages pass the **real integration drain
callback**, and Category-3 bootstrap setters route through the bootstrap-service stream. (2) Terminal
cleanup runs `unload_game`/`deinit` after stop with no phase and no MAIN drain — a callback emitted
there routes as `FCP_NONE` (wrong direct path) or into a service stream MAIN no longer drains (leak/
deadlock). Fix: add phase **`FCP_TEARDOWN_SVC`**; run callback-emitting `unload`/`deinit` as
drain-driven services **before** stop, keep MAIN draining until they ack, then stop → observe
STOPPED → join. The CORE-TLS phase is set/restored by the engine immediately around every vtable op,
so it is never stale across the RUN↔SVC↔TEARDOWN boundaries.

**D-c COMMAND OWNERSHIP STATE MACHINE (fixes R3-F4).** `CORE_OWNED → EVENT_OWNED → FREED`:
- `fr_core_emit` returning **FR_OK transfers ownership** to the ring (EVENT_OWNED).
- `fr_core_emit` returning **FR_ABORT ALSO transfers ownership** — a persistent command is retained
  in the CORE-local overflow ledger and flushed to MAIN before RUN_DONE. The wrapper must NOT treat
  FR_ABORT as failure-and-free (that is the use-after-free + double-free Codex found).
- CORE frees only on a result that proves no event/overflow entry was created.
- MAIN frees **exactly once**, after the apply callback returns. Successful park/terminal drainage
  therefore leaves nothing for a second cleanup sweep (no double-free).
- Persistent-command allocation failure must **fail-closed / terminate** before CORE proceeds —
  returning false while silently losing already-applied core state is not acceptable. Fail-closed
  paths may intentionally leak at process exit (matches the existing contract).

**D-d THE ACTUAL ENVIRONMENT-CALLBACK INVENTORY (fixes R3-F5).** Built from the 36 handled cases in
minarch.c's `environment_callback`. Grouped by routing rule:

- **Cat-1 Synchronous getters** — answered ON CORE from epoch-stable data (the core blocks on the
  return, so they can NOT be async-routed to MAIN): `GET_OVERSCAN`, `GET_CAN_DUPE`,
  `GET_SYSTEM_DIRECTORY`, `GET_SAVE_DIRECTORY`, `GET_VARIABLE`, `GET_VARIABLE_UPDATE`,
  `GET_LOG_INTERFACE`, `GET_INPUT_DEVICE_CAPABILITIES`, `GET_AUDIO_VIDEO_ENABLE`,
  `GET_INPUT_BITMASKS`, `GET_CORE_OPTIONS_VERSION`, `GET_DISK_CONTROL_INTERFACE_VERSION`. Rule: read
  only state immutable during an epoch (paths + option values are fixed at bootstrap/menu, and menu =
  park, so no mid-epoch mutation). No copy, no command.
  - **HAZARD `GET_CURRENT_SOFTWARE_FRAMEBUFFER`** — hands the core a render target. At depth-2 it must
    return a **credit-owned pool buffer**, never the shared `screen`, or CORE renders into a
    MAIN-owned/aliased surface.
- **Cat-2 Registration** (bootstrap; store a callback pointer, no MAIN state): `SET_DISK_CONTROL_
  INTERFACE`, `SET_DISK_CONTROL_EXT_INTERFACE`, `SET_FRAME_TIME_CALLBACK`, `SET_AUDIO_CALLBACK`,
  `GET_RUMBLE_INTERFACE`. (Our shipped cores don't drive `SET_AUDIO_CALLBACK`; if one did, who invokes
  it and when is out-of-scope for this bring-up and must be scoped separately.)
- **Cat-3 Bootstrap setters of MAIN-owned state** — emitted during init/load_game on CORE → route via
  the **bootstrap-service** stream (D-b), deep-copied, applied+freed on MAIN: `SET_PIXEL_FORMAT`,
  `SET_INPUT_DESCRIPTORS`, `SET_VARIABLES`, `SET_CORE_OPTIONS`, `SET_CORE_OPTIONS_INTL`,
  `SET_CONTROLLER_INFO`, `SET_CONTENT_INFO_OVERRIDE`, `SET_SUPPORT_NO_GAME`, `SET_PERFORMANCE_LEVEL`.
  Deep-copy shape: option definitions carry nested key/value/description strings + arrays → copy the
  whole tree.
- **Cat-4 Runtime setters** — emitted during retro_run on CORE → **RUN command** stream, ordered,
  deep-copied: `SET_GEOMETRY` (ordered, applies at its stream position — the ordering D-a-revert
  preserves), `SET_SYSTEM_AV_INFO` (RUN command + **BARRIER**: MAIN applies, CORE waits),
  `SET_MESSAGE` (copy string), `SET_VARIABLE` (copy key/value), `SET_CORE_OPTIONS_DISPLAY`,
  `SHUTDOWN` (→ quit via atomic/event; terminal, no further grant).
- **Cat-5 Rumble invocation** — the core calls the registered rumble callback during retro_run →
  **ordered stream command, NOT a coalescing atomic** (an on→off pulse must survive to the motor);
  MAIN applies in order.

**D-g AUDIO CANCELLATION EDGE (fixes R3-F6).** Add a per-epoch, acquire-loaded **cancellation token**;
include it in `SND_batchSamples`' ring-space wait predicate and **wake the SND wait on park/stop**
(waking framering's producer condvar does NOT wake a separate SND wait — that was the residual park
stall). Accepted samples are published as **one atomic prefix commit** (bytes written before the
write index is release-published once); shortfall counts only cancellation-rejected units;
`fr_core_run_done(outcome, shortfall)` carries it (currently hardcoded 0 — engine touch). A park
landing mid-copy is safe iff the callback either commits the completed prefix and returns k, or
publishes nothing and returns 0 — it must never expose written-but-unpublished samples; later batch
calls after cancellation return 0 without touching the ring.

**D-k SLOT-RETURN ASSERTIONS (from R3-F8).** `fr_core_wait_grant` gains an output-only `out_slot`:
write it only when returning FR_GRANT (unspecified on PARK/STOP); assign after acquiring the
published grant; assert `slot < depth`, `slot_owned` contains slot, `snap[slot].gen == gen`; preserve
slot ownership through the RUN_DONE drain callback; prohibit slot reuse before the callback returns
and depth resize until every slot is reclaimed. With D-a-revert the frame reaches MAIN via the FRAME
payload, so RUN_DONE need NOT also carry the slot — `out_slot` serves only CORE's pool indexing.

**D-e status: D61 LANDED** (DECISIONS.md) — MAIN owns the governor (contract-aligned to shipped
reality; the tick already runs on MAIN, `Gov_start` is init-only), CORE publishes work samples, gen
from drained RUN_DONE, plus the round-3 governor-window hardening. Resolves R3-F7.

**Convergence:** round 1 = 13, round 2 = 11, round 3 = 8. D-f/D-h/D-i/D-j implementable; D-a…D-d and
D-g now corrected/specified and D61 landed. Round 4 should confirm the D-a revert closes the ordering
+ discard + slot-transport trio, the ownership FSM is leak/double-free-free across all paths, the env
table is complete, and the audio cancellation edge is race-free.

---

# REVISION 3 — post-Codex round 2 (2026-07-15)

Round 2 CLOSED 7 round-1 findings (F1, F2-sleep, F3-pacer, F10-sig, F11, F12-init, F13); marked
F4/F5/F8/F9 partial and F6-multicallback/F7-inventory unresolved; added 11 new (6×P0). All
accepted. Rev-2 left several as "either/or" or "reconcile" — **rev-3 makes the decisions.**
Supersedes rev-2 where noted.

**D-a. One present per epoch (closes F1/F6 multi-callback).** MAIN presents at most once per epoch,
at RUN_DONE. Multiple `video_refresh` calls in one `core.run` coalesce into the single credit
buffer (last wins); outcome = FRAME if ≥1 non-null copy else DUP/NONE. MAIN presents the credit
buffer for FRAME, or re-presents the MAIN-owned last-presented immutable frame for DUP/NONE. No
per-callback frame events, no spill buffers — one buffer per credit suffices because there is
exactly one present per epoch (intermediate sub-frames are never independently shown).

**D-b. CORE execution-phase marker (closes F3, enables F5 routing).** Replace the
`zero_ftv2_on_core` bool with a CORE-TLS phase enum set at CORE-thread entry and moved by the
engine: `FCP_BOOTSTRAP_SVC` / `FCP_RUN_EPOCH` / `FCP_RUNTIME_SVC` / `FCP_NONE`. Every frontend
callback routes by phase: RUN_EPOCH→run stream, *_SVC→service stream, FCP_NONE→legacy direct
(MAIN menu redraw). Fixes callbacks raised during retro_init/load_game/unserialize that today see
the bool as 0 and wrongly take the MAIN path.

**D-c. Typed command objects + ownership (F2/F5).** A command crosses as a typed, versioned heap
object; its pointer rides `fr_event.payload`. CORE deep-copies the libretro payload *including
nested strings* (SET_VARIABLE key/value) at emit; MAIN applies in ring order in the drain cb and
frees after apply returns; alloc-failure = drop (droppable) or fail-closed (persistent), per type;
park/discard/terminal paths free undrained command objects (MAIN owns the free). Emission is
phase-aware (D-b): RUN via `fc_emit_cmd`, *_SVC via `fr_core_service_emit` — `fc_emit_cmd` during a
service op would assert (no open epoch), so AV/geometry emitted during unserialize/reset take the
service path with a service-side barrier wait.

**D-d. Full environment-callback inventory (F9).** rev-3 carries a table: every env callback →
{owner, copy policy, RUN/SVC route, persistence/barrier, return}. Covers SET_SYSTEM_AV_INFO,
SET_GEOMETRY, SET_VARIABLE(S), SET_CORE_OPTIONS(_INTL), SET_INPUT_DESCRIPTORS, SET_MESSAGE,
SHUTDOWN, rumble, … **Rumble is an on→off pulse — a latest-value atomic can erase it**, so rumble
is an ordered stream command (not a coalescing atomic); MAIN applies to the motor in order. Same-
epoch geometry/AV ordering is sound via the existing ordered stream (cmd-before-frame applies
before; cmd-after applies after; AV barrier releases only after MAIN's apply returns).

**D-e. MAIN owns the governor (F4) — amend v2.4 via D-log (D61).** The pure-producer correction
wins over v2.4's "governor on CORE": MAIN owns GovState + cpufreq application; CORE publishes
immutable per-epoch work samples into the ring; MAIN derives generation rate from drained RUN_DONE
and sets the clock. Amended into the contract by a DECISIONS entry at implementation, not left as
two conflicting contracts.

**D-f. Governor window lifecycle (F8).** gen = drained RUN_DONE that entered retro_run (DUP/NONE
included — completed runs; queued-canceled grants excluded — no RUN_DONE). Reset/freeze the rate
window at park, release, and every depth transition (symmetric — no stale history across modes). FF
comes from each epoch's control snapshot, never live. The depth predicate flips only while
QUIESCENT inside the depth-change gate.

**D-g. Audio shortfall plumbing (F5) — touches the engine.** CORE-local per-epoch shortfall
accumulator; the audio callback publishes exactly the accepted prefix, never internally retries the
rejected suffix, accumulates n−k once, returns 0 promptly after cancellation. frontend_core passes
the accumulated shortfall to `fr_core_run_done(outcome, shortfall)` (currently hardcoded 0).
Re-run plain/TSan/ASan after the engine touch.

**D-h. Terminal poweroff flow (F6).** The long-press `before_sleep()→PWR_powerOff()` path
(api.c:1780) gets its own sequence: park → drain → CORE save/autosave/memory-flush services →
stop/join (terminal quiescence) → close audio → poweroff. No release, no subsequent grant.

**D-i. State gen G + snapshot V (F7).** G = highest drained RUN_DONE gen that actually entered
retro_run (include a completed CANCELLED active epoch; exclude canceled queued grants). Freeze V
(the MAIN-owned last-presented frame's visual gen) after normal park drainage, before any
serialize-service callback can change presentation. Save the pair (state G, snapshot V) while
parked; terminal save-and-quit does not release CORE.

**D-j. Frame OOM / runtime growth (F10).** Size credit buffers from validated AV
`geometry.max_width`/`max_height` + pixel format (not the first frame's size), so well-behaved
cores never exceed capacity. If a frame still exceeds: do not write/publish stale pixels; drop the
frame; publish a MAIN resize request (a command); finish the epoch; MAIN parks and resizes the pool
or falls back to depth-1 via the gate (CORE cannot invoke the gate from inside video_refresh).

**D-k. WP-G signature reopens engine API (round-2 WP-G audit).** `run(ctx, gen, slot, snapshot)`
requires `fr_core_wait_grant` to also return `slot` → touches framering.{h,c}, frontend_core.{h,c},
and the harness fake run: a controlled reopening of reviewed engine surface, re-verified under
plain/TSan/ASan.

**D-l. F23 service inventory is mandatory-before-release (F11).** Codex's refinement accepted:
prioritizing below F1–F6 is fine for bring-up *sequencing* but is NOT optional — real unsafe paths
exist (a core reading retro_init/run TLS during serialize; serialize/unserialize emitting video/env
callbacks, which the v2.4 service contract permits; a disc callback assuming the core thread).
Complete the service routing (memory flush, disc replace, controller change, save/load/reset,
callback-emitting services) before the save/load/menu gauntlet and before release.

**Convergence:** round 1 = 13, round 2 = 11 (7 of round-1 closed). Trending like the v2.4 contract
(5 rounds: 15→7→6→4→0). Round 3 should confirm these decisions close the P0s and attack the
command-object protocol (D-c), the phase machine (D-b), and the governor-ownership amendment (D-e).

---

# REVISION 2 — post-Codex adversarial review (2026-07-15)

Codex reviewed rev-1 at commit b2858858 and returned 13 findings (8×P0, 5×P1). Spot-checked
against source and accepted: F1 (CORE calls `GFX_clearAll` + mutates global `renderer` on resize,
minarch.c:3196+), F2 (`PWR_update → Menu_beforeSleep → State_autosave` enters the core, 1959→3604),
F6 (NULL early-return, no `fc_signal_dup`, 3305) — all as cited. Rev-1 was frame+input scoped and
under-specified the command channel, the sleep/power core-entry, the depth-2 pacer, the governor
gen-signal, and frame-descriptor immutability. **This revision supersedes rev-1 where noted; the
rev-1 body is retained below for the review trail.**

## Corrected architecture principle: CORE is a PURE PRODUCER

The CORE thread does exactly three things per epoch: (1) run `core.run()`, (2) **copy** each frame
into a credit-owned buffer and publish an **immutable descriptor**, (3) emit audio + commands into
the ring. It applies **nothing**. Every application of state — renderer/scaler selection,
`GFX_resize`/`GFX_clearAll`, `renderer.dst`, HUD, geometry/AV/variables, present, save-pairing —
happens on **MAIN**, in ring order. Rev-1's shortcut (CORE did the HUD blit + renderer setup +
resize) was the root of F1 and F5. This is the v2.4 contract taken literally.

## Work packages, revised (each finding folded in)

- **WP-A — input tick to MAIN + snapshots + service routing.**
  - Split `input_poll_callback` → `input_tick_main()` on MAIN; registered libretro callback is a
    no-op when `on_core`. (rev-1)
  - **F2 sleep flow:** `PWR_update` is NOT a plain MAIN move. MAIN detects the sleep request, then
    **park → drain → run autosave/memory-flush as CORE services → close audio only after park ack
    → stay QUIESCENT through sleep → resume audio on MAIN → release CORE.**
  - **F11 control snapshots:** carry `fast_forward` (and other per-epoch control flags) in the grant
    snapshot; do NOT read them live on CORE. Pack analog axes through `uint16_t` casts —
    left-shifting a negative signed axis is UB.
  - **F3 pacer + input latching:** MAIN must not free-spin when the pipeline is full (fc_pump
    returns immediately at depth≥2 — the D59 busy-spin, pipelined). Add a MAIN-owned grant cadence
    with a lifecycle-wakeable wait; **latch edge-triggered input until a grant succeeds** so a short
    press during a failed grant is never lost.

- **WP-B — immutable per-credit frame descriptor** (replaces rev-1's bare pool).
  - CORE copies pixels into the credit's buffer and publishes an **immutable** descriptor
    `{pixels, gen, width, height, pitch, format}`. MAIN owns renderer/scaler/`GFX_resize`/
    `GFX_clearAll`/HUD/dst/present. (**F1**)
  - **F6 DUP/NONE + multi-callback:** route NULL → `fc_signal_dup`; MAIN re-presents the MAIN-owned
    **last-presented** immutable frame for DUP/NONE. A retro_run that calls video_refresh multiple
    times needs per-published-frame storage or a specified coalescing+ack — one mutable buffer per
    epoch is insufficient.
  - **F12 failure paths:** validate depth∈{1,2}; validate dims/alloc sizes (checked multiply);
    allocate+verify all slots before enabling depth-2; never publish a stale/null slot; on OOM fall
    back to depth-1 through the depth-change gate.

- **WP-C — command channel** (NEW; the biggest rev-1 omission, **F5**).
  - Route `SET_SYSTEM_AV_INFO` / `SET_GEOMETRY` / `SET_VARIABLE` / `SHUTDOWN` / rumble through
    `FR_EV_CMD` (persistent/barrier as the design specifies); `zero_ftv2_drain` applies them on MAIN
    in order (it currently ignores FR_EV_CMD, minarch.c:5294). The libretro data pointer is
    transient → **deep-copy** the payload into the event. Shutdown/quit via an atomic/event, not a
    bare CORE-write/MAIN-read. Rumble via the contracted atomic handoff.

- **WP-D — governor + telemetry at depth-2** (NEW, **F4**).
  - Derive generation rate from **drained RUN_DONE** epochs, not loop/pump iterations. Publish CORE
    work through defined atomics/events. Replace the `thread_video` predicate (always 0 under
    guard-ON, so single-thread gov/DRC branches are wrongly selected) with an explicit v2
    depth/mode predicate. Reconcile with the v2.4 governor-ownership clause.

- **WP-E — audio lifecycle** (NEW, **F8**).
  - Make `SND_batchSamples` producer waits **park/stop-cancellable** with partial-accept, and
    propagate the shortfall into RUN_DONE (the framering already models `shortfall`). Always
    park-and-ack before any pause/close/resize/free of the audio device — otherwise the F2 sleep
    ordering can wedge park (CORE waiting on a full ring MAIN has stopped draining). The bounded
    audio lead itself is fine for bring-up; the cancellation/lifecycle gaps are the bug.

- **WP-F — save-state visual identity** (**F9**).
  - Keep a MAIN-owned **immutable last-presented** snapshot tagged with visual gen V. While parked,
    save the contractual pair `(state G, snapshot V)`. Add a terminal **save-and-quit** service path
    that does NOT release CORE or grant another epoch (rev-1's `fc_menu_op`-then-quit released
    RUNNING and could grant again before quit was seen).

- **WP-G — run signature** (**F10** — rev-1's TLS-stash cannot work; `zero_ftv2_run` never receives
  gen). Extend explicitly: `run(ctx, gen, slot, snapshot)` — pass the actual credit slot too, so
  minarch is not coupled to the `gen % depth` selection and needs no hidden TLS.

- **WP-C(enable) — unchanged in intent**, but default depth stays **1**; depth-2 is a guarded
  bring-up only; requalification gate precedes any auto-trial.

- **F7 (menu/disc F23):** valid but NOT a novel depth-2 blocker — depth-1 already calls
  `core.serialize` from MAIN during menu saves (shipped + on-device-validated), and `fc_park` fully
  quiesces CORE, so there is no concurrent access; only thread-identity differs, which our shipped
  cores don't care about in serialize. Fold the full service inventory in (memory flush, disc
  replace, controller change, save/load/reset, split MAIN screenshot/file work from CORE
  serialization) as **contract-hardening**, prioritized below F1–F6.

- **F13 (harness tests the glue):** the engine harness does not exercise minarch's renderer/input/
  audio/save/pool glue. Extract the shipping glue into a testable module (or compile the real
  callbacks/pool into a harness) and add the enumerated adversarial cases (pipeline-full-no-event,
  input edge with no credit, NULL/zero/multi-callback epochs, geometry/AV during N+1 while
  presenting N, normal+discard park with pool poisoning after credit return, save/load/reset/
  save-quit, sleep with a full audio ring, pool alloc/resize failure).

## Revised work-package verdict (accepting Codex's)

WP-A not sound until sleep-service + pacer + input-latch + control snapshots land. WP-B partially
sound (the raw credit-lifetime invariant holds; incomplete for renderer metadata / DUP-NONE /
multi-callback / last-presented / OOM). WP-C(enable) sound only as a guarded bring-up; depth-1 stays
the default. New WP-C(commands)/WP-D/WP-E/WP-F/WP-G are the added surface.

**Next process step:** iterate this to zero findings with a second Codex pass (as the v2.4 contract
did over 5 rounds) BEFORE writing code; the measurement A/B remains gated on Dan's save states.

---

## What is already reviewed vs. what is new (where to aim the review)  *(rev-1, superseded above)*

- **Already at zero findings** (do not re-review): the v2.4 ownership contract (5 Codex rounds),
  the framering protocol, and the frontend_core lifecycle engine. Depth-1 rode entirely on that
  surface and came up clean. The sanitizer harness (`run-frontend-core-tests.sh {plain,tsan,asan}`)
  tests the shipping engine, not a model.
- **New, un-reviewed surface = this doc**: the concrete **minarch** integration. Three work
  packages (WP-A input, WP-B frame, WP-C enable). All hazards live here, in the glue.

Key framing fact that shrinks the risk: **most of the depth-2 machinery already exists in-tree.**
- The framering already carries a **depth-sized** per-credit input snapshot (`snap[FR_MAX_DEPTH]`,
  lifetime grant→credit-return, framering.h:113) and a slot per grant (`grantq[].slot`). The F20
  "one snapshot slot per credit" design is **already implemented** — WP2 just delivers it to
  `run()`. No storage change.
- The core-touching shortcuts (save/load/reset) map onto service ops that **already exist**:
  `FC_OP_SERIALIZE` / `FC_OP_UNSERIALIZE` / `FC_OP_RESET` via `fc_menu_op` (park→service→release).
- Frame double-buffering already exists as a proven pattern: the dormant `thread_video` mailbox
  (`backbuffer` copy + `readybuffer`/`presentbuffer` swap, minarch.c:3307–3331, 5501–5532). Depth-2
  reuses the **copy-out-of-the-transient-core-framebuffer** idea, sized to credits instead of a
  latest-wins mailbox.

Under a guard-ON build, `ZERO_DISABLE_FRONTEND_THREADING` forces `thread_video=0` and locks the
Threading option (minarch.c:5433–5440), so the old mailbox path is **dormant, not deleted** — a
clean reference, zero interference.

---

## The depth-1 → depth-2 gap, precisely

Depth-1 is a **serial rendezvous**: `fc_pump` blocks for the epoch's RUN_DONE (D59), so MAIN is
idle while the CORE thread runs `core.run()` — including `input_poll_callback`, which today runs
**on the CORE thread**. Because there is no overlap, two shortcuts are safe *only serially*:

1. **Input** — `input_poll_callback` (minarch.c:1955) reads live globals (`buttons`, `pad`) and
   the CORE reads them back in `input_state_callback` (2085) during the same `core.run()`. Safe
   because MAIN never touches them concurrently.
2. **Frame** — the CORE-side `video_refresh` sets `renderer.src = data` (the core's *transient*
   internal framebuffer) and emits; MAIN's drain reads `renderer.src` and scales. Safe because the
   core cannot start the next epoch (and overwrite `data`) until MAIN releases the credit.

Depth-2 overlaps MAIN and CORE by design (CORE runs N+1 while MAIN presents N). Both shortcuts
then race. The three work packages remove each race.

---

## WP-A — move the input tick to MAIN; snapshot per epoch; route core ops through the service channel

**Problem.** `input_poll_callback` does far more than read buttons, and it currently runs on CORE.
Enumerated (minarch.c:1955–2084), with the depth-2 disposition of each:

| Work in `input_poll_callback` today | Depth-2 home | Why |
|---|---|---|
| `PAD_poll()` | **MAIN** | reads SDL/evdev — input source is MAIN-affine |
| `PWR_update(...)` (sleep, menu-before/after-sleep) | **MAIN** | power/sleep + SDL |
| MENU/PLUS/MINUS → `ignore_menu` | **MAIN** | menu state MAIN reads |
| BTN_POWER → `toggle_thread`/`was_threaded` | **MAIN** (dead under guard-ON: `thread_video==0`) | keep for parity |
| FF toggle / HOLD_FF → `setFastForward` | **MAIN** | `fast_forward` + audio lifecycle are MAIN's |
| CYCLE_SCALE / CYCLE_EFFECT → `Config_syncFrontend` | **MAIN** | frontend/display config |
| `SAVE_STATE` / `LOAD_STATE` → `Menu_save/loadState` | **CORE via `fc_menu_op(SERIALIZE/UNSERIALIZE)`** | calls `core.serialize/unserialize` — F23: only CORE enters the core |
| `RESET_GAME` → `core.reset()` | **CORE via `fc_menu_op(RESET)`** | enters the core |
| `SAVE_QUIT` → `Menu_saveState` + `quit=1` | **CORE service** (save) then MAIN sets quit | save enters the core |
| MENU release → `show_menu = 1` | **MAIN** | `show_menu` MAIN reads |
| compute `buttons` + read `pad.laxis/raxis` | **MAIN → the per-epoch snapshot** | this IS the input handed to the epoch |

**Design.**
- Extract the body of `input_poll_callback` into `input_tick_main()` and call it on MAIN, once per
  loop iteration, **before** the grant. The registered libretro `input_poll_callback` becomes a
  **no-op when `zero_ftv2_running && zero_ftv2_on_core`** (MAIN already did the work), else
  unchanged (guard-OFF and menu-redraw paths keep today's behavior).
- After `input_tick_main()`, MAIN packs the epoch input into the 4-word snapshot and passes it to
  `fc_pump` (replacing today's `snap[4]={0}`), e.g. `snap[0]=buttons`, `snap[1]=(laxis.x<<16)|
  (uint16)laxis.y`, `snap[2]=raxis`, `snap[3]` reserved. `fr_grant` stores it in the credit's slot
  (already depth-sized).
- `input_state_callback` (minarch.c:2085), when `zero_ftv2_running && zero_ftv2_on_core`, reads the
  **delivered snapshot** (WP2: `run(void*, const uint64_t snap[4])`) instead of the live globals.
  Mechanism: stash the delivered snapshot in a CORE-TLS (`static __thread uint64_t
  zero_ftv2_isnap[4]`) inside `zero_ftv2_run`, unpack in `input_state_callback`.
- The three core-touching shortcuts, detected on MAIN, issue `fc_menu_op` (park → service on CORE →
  release). This reuses the exact path menu save/load already takes. `SAVE_QUIT` = service-save then
  `quit=1`.

**What this costs / accepts.** Input is now `depth` epochs stale (~16 ms at depth 2) — **stated and
accepted** by the v2.4 F20 contract. Save/load/reset **park the pipeline** (drain + refill hitch),
identical to a menu visit — acceptable and already how menu ops behave.

**Edit sites:** `input_poll_callback` (split), `input_state_callback` (snapshot read), the run loop
at minarch.c:5485+ (call `input_tick_main`, pack snapshot, route shortcuts), `zero_ftv2_run` (stash
`isnap`).

---

## WP-B — per-credit frame buffers (stop reading the core's transient framebuffer)

**Problem.** At depth-2 the CORE overwrites its internal framebuffer (`data`) on epoch N+1 while
MAIN is still scaling frame N from `renderer.src = data`. Tearing / use-after-overwrite.

**Design (credit-indexed pool, reusing the mailbox copy pattern):**
- The CORE owns a pool of **`depth`** RGB565 buffers (allocate/resize with the existing
  `backbuffer` logic, minarch.c:3309–3318). In the CORE-side `video_refresh` (after the HUD blit,
  which must stay on the producing thread since it writes into the frame), `memcpy` `data →
  pool[gen % depth]`, then `fc_emit_frame(&zero_ftv2, gen % depth)` — the previously-unused `payload`
  carries the slot.
- MAIN's drain, on `FR_EV_FRAME`, sets `renderer.src = pool[ev->payload]` (or `pool[ev->seq %
  depth]` — `ev->seq` already carries the epoch gen, framering.h:59), then `GFX_blitRenderer` +
  `GFX_flip`. The scaler's destination is `screen->pixels`, **MAIN-owned and single** — no
  double-buffer needed there; only the raw pool needs slots.
- Credit accounting bounds outstanding epochs to `depth`, so `pool[gen % depth]` is never reused
  while MAIN still needs it (same invariant that protects `snap[]`).
- The CORE needs its epoch gen to index the pool. `fr_core_wait_grant` returns `gen`; stash it in a
  CORE-TLS (`zero_ftv2_slot`) in `zero_ftv2_run` alongside `isnap`. **Open question for review:**
  prefer passing `gen` into the `run()` vtable signature vs. a CORE-TLS stash (see hazards).

**Edit sites:** `video_refresh_callback_main` (pool copy + emit slot, minarch.c:3196–3303),
`zero_ftv2_drain` (read `pool[slot]`, minarch.c:5286), pool alloc/resize, `zero_ftv2_run` (stash
slot).

---

## WP-C — enable depth 2 (fixed first, auto-trial later)

- **Stage 1 (this bring-up):** force depth via env `ZERO_FTV2_DEPTH` (default 1), read in
  `fc_init(&zero_ftv2, &zero_ftv2_vt, depth)`. `fc_pump` at depth ≥ 2 already keeps
  grant+prefix-drain+return (no block — D59). This validates **correctness** of the pipeline
  (picture/sound/input) before any decision logic.
- **Stage 2 (later, separate):** wire the observe→trial→verdict→sidecar machinery onto
  `fc_set_depth` (the transition gate reclaims credits safely, F24). The design's requalification
  gate (first 60 frames after load run depth 1) belongs here, not in Stage 1.

Non-goals for depth-2: user-facing toggle, depth > 2, auto-trial in Stage 1 (v2.4 §out-of-scope).

---

## Open hazards / questions for the reviewer

1. **`gen` to the CORE video_refresh** — CORE-TLS stash vs. extending the `run()` signature to
   `run(void* c, uint64_t gen, const uint64_t snap[4])`. TLS is less churn; explicit is cleaner.
   Which?
2. **`downsample` global `buffer`** (minarch.c:3281–3284) — the downsample path writes a *shared*
   global and points `renderer.src` at it. At depth-2 this races. Fix: downsample into `pool[slot]`
   (fold into the WP-B copy) or per-slot downsample buffers. Confirm no other reader of `buffer`.
3. **HUD blit reads governor globals** (`gov_state`, `cpu_double`, minarch.c:3272) on the CORE
   thread while MAIN's governor writes them — benign text-only races (garbled digit at worst).
   Accept, or snapshot the HUD inputs at grant?
4. **`fast_forward`** — written on MAIN (FF toggle), read on CORE in `audio_sample_callback`
   (minarch.c:3337) to gate audio emission. Torn read = one frame's audio wrongly emitted/dropped
   on an FF flip. Accept, or carry FF in the per-epoch snapshot?
5. **`last_flip_time`** (minarch.c:3302) and other callback-written globals — audit thread owner
   under depth-2 (which thread's clock drives pacing/governor).
6. **Audio ownership at depth-2** — `audio_sample_batch_callback` still emits from CORE (unchanged
   from depth-1); confirm the SND ring + F5 audio-ownership contract hold when CORE runs ahead of
   MAIN's present by up to `depth` epochs (audio-vs-video skew ≤ depth epochs).
7. **Menu/park during a pipelined epoch** — `fc_park` (loop at minarch.c:5548) must reclaim *all*
   outstanding credits and drain the pool; verify no in-flight `pool[slot]` is presented after
   park. (Gate F24 should cover this; confirm against the pool.)

---

## Validation plan

1. **Harness first (no device):** extend `frontend_core_test.c` to run adversarial sessions at
   **depth 2** with a frame-pool + snapshot oracle: assert MAIN presents `pool[N]`'s content while
   CORE produces N+1 (no overwrite), and that each epoch's `input_state` reads its own snapshot
   (extends INV16 to the pipelined case). Plain/TSan/ASan all green — TSan is the real gate for the
   new overlap.
2. **On-device bring-up (with Dan):** `ZERO_FTV2_DEPTH=2`, one clean single-process instance
   (reboot first — there are currently stacked `minui.elf` procs). Verify per game: picture, sound,
   **input responsiveness** (the ~16 ms lag is expected; confirm playable), menu in/out, save/load/
   reset, FF. SNES first (the beneficiary).
3. **The measurement (gated on Dan's save states):** depth-1 vs depth-2 energy A/B at demanding
   scenes — DKC (mine-cart/boss), Yoshi's Island (Super-FX2 rotate/scale boss), Mario RPG (SA-1
   battle). Save states do not yet exist and **block this step**; the code above is validatable to
   "runs correctly pipelined" without them.

## One-line summary for the reviewer

Depth-2 = (A) move the input tick to MAIN + per-epoch snapshot + route save/load/reset through the
existing service ops; (B) copy each frame into a credit-indexed pool so MAIN never reads the core's
transient buffer; (C) flip depth to 2 (fixed for bring-up, auto-trial later). Almost every
primitive already exists and is reviewed; the risk is entirely in the minarch glue enumerated here.
