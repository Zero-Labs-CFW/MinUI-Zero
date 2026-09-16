# Undervolt spike — feasibility + safe scaffolding (NOT yet enabled)

**Spike, not a feature.** Goal: determine whether we can run the A133P's CPU at the *same*
frequency with *lower* voltage — the single biggest "make the existing clocks cooler" lever —
and lay down a safe interface + validation protocol. **Nothing here applies an undervolt:** it
ships **OFF**, with `PLAT_supportsUndervolt()` returning 0 until on-device recon proves a real
mechanism. No voltage values are fabricated.

## Why it's worth a spike
Lowering clocks (the governor) reduces heat by doing less work. Undervolt reduces heat at the
*same* work: P ∝ f·V². A modest, stable undervolt is free thermal/battery headroom that compounds
with the governor and would let the ceiling sit higher for the same temperature. `minime-os/minui`
ships an OFF/L1/L2/L3 undervolt tier — proof the lever is real (theirs is RK3566, a different SoC
and mechanism; we borrow the *idea*, not the code).

## The hard reality on the A133P (to confirm with recon)
CPU voltage is set by the PMIC, and the cpufreq OPP table (in the DTB) maps each frequency to a
voltage. On a **stock kernel the CPU-rail regulator's `microvolts` node is typically read-only**,
and the OPP voltages live in the DTB — so a *runtime* undervolt may not be possible at all. Three
candidate mechanisms, in order of preference (the extended `tools/brick-recon.sh` determines which,
if any, exists — **read-only probe, it never writes a voltage**):
1. **Writable CPU-rail regulator** (`/sys/class/regulator/regulator.N/microvolts` is `rw`): a
   bounded runtime write per OPP. Cleanest if available — likely isn't on stock.
2. **OPP-table voltage override** (debugfs `/sys/kernel/debug/opp/...`, or a writable `opp_table`):
   patch the freq→voltage map at runtime. Sometimes exposed, often not.
3. **Custom DTB / kernel** with patched OPP voltages: always works but means shipping a DTB and a
   reflash — heavy, and changes the "no kernel fork" posture. The fallback if 1 & 2 are absent.

**Feasibility verdict is recon-gated.** Expected outcome on stock: 1 & 2 read-only → undervolt
needs (3). If so, this stays a documented capability, not a shipped one, until/unless we take on a
DTB.

## Safety model (mandatory before any real value)
Undervolting too far = silent corruption / crashes, which collides head-on with the reliability
pillar. So:
- **Default OFF.** Stock voltages unless explicitly, validated-ly enabled.
- **Conservative tiers, small steps.** e.g. L1/L2/L3 ≈ −25/−50/−75 mV (placeholders; real safe
  values come only from per-device validation). Hard lower bound per OPP.
- **Per-tier stability validation via the benchmark harness** (`docs/benchmark-harness-design.md`):
  run the thermal-soak scene at each tier and require **zero new crashes, zero new audio/frame
  errors, and a real mJ/frame win** before that tier is allowed. A tier that fails any gate is
  rejected, not shipped.
- **Watchdog + auto-revert.** If a session crashes/hangs at a tier, next boot reverts to stock and
  marks that tier unsafe for this unit (silicon varies — never assume a tier is universally safe).
- **No user knob** (direction-doc rule): pick the highest *validated* tier automatically, or none.

## Interface scaffold (this spike)
```c
int  PLAT_supportsUndervolt(void);   // 1 only if a real runtime mechanism is confirmed (tg5040: 0 for now)
void PLAT_setUndervolt(int millivolts); // global offset; negative lowers voltage; 0 = stock. No-op until supported.
```
- `api.c`: weak fallbacks — `supports → 0`, `set → no-op`. So every platform is safe by default.
- `tg5040/platform.c`: `supports → 0` (no confirmed mechanism yet) and `set` is a **logged no-op**
  with the candidate write paths in comments — a clear home for the real impl once recon lands,
  and harmless if called early.
- **Not wired into minarch.** Applying a tier waits until (a) recon confirms a mechanism and (b) the
  validation protocol exists. Wiring it now would risk applying a fabricated voltage.

## On-device determination (the actual spike work)
1. Run the extended `tools/brick-recon.sh`; record the "Voltage / OPP / undervolt mechanism"
   section. Which (if any) of mechanisms 1–3 exists? Is any `microvolts`/OPP node `rw`?
2. If a mechanism exists: read the stock OPP→voltage table; that's the baseline to offset from.
3. Build the per-tier validation: soak each candidate offset with the benchmark harness + a crash
   counter; keep only tiers that pass every gate; persist the best validated tier per unit.
4. Only then flip `PLAT_supportsUndervolt()` to 1 and wire the chosen tier in.

## Decisions
- **D1 — Ship OFF, fabricate nothing.** `supports=0`, all values are placeholders; the design is the
  deliverable, not an enabled undervolt.
- **D2 — Global mV offset interface** (not per-OPP yet) — simplest model; most undervolts are a flat
  offset. Per-OPP refinement is a later step if a mechanism exists.
- **D3 — Validation is part of the feature, not optional.** An undervolt tier doesn't exist until the
  benchmark harness + crash watchdog have cleared it on real silicon.
