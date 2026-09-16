# On-device checklist — closed-loop thermal governor

Everything below needs the physical TrimUI Brick (`tg5040`) and/or the Docker
cross-toolchain. None of it blocked the no-hardware implementation: the controller is
safe by construction (writes snap to the nearest OPP, the loop self-corrects, a
conservative ceiling bounds the downside). These steps replace ASSUMED placeholders
with measured values and confirm the build/behavior on real silicon.

## A. Cross-compile the firmware (DONE)
- [x] `minarch` (incl. `governor.c`) cross-compiles clean under the real
      `aarch64-linux-gnu-gcc` toolchain (`tg5040-toolchain` image via Colima, `-flto -Os`,
      zero warnings) → `workspace/all/minarch/build/tg5040/minarch.elf` (ARM aarch64 ELF).
- [ ] Optional: full release build `make tg5040` (needs a TTY for `setup`'s `tty -s` and
      `docker run -it`) to produce a flashable zip in `./releases/`. Not required to verify
      the governor compiles — the targeted minarch build above already did that.

## B. Replace the ASSUMED hardware values (run `tools/brick-recon.sh`)
Run the recon script twice — idle at the menu, and during a demanding game (PS1) — and
commit both outputs. Then fix the placeholders, all in `workspace/all/common/governor.c`
unless noted:
- [ ] **Thermal zone**: `cat /sys/class/thermal/thermal_zone*/type`. Confirm which zone
      is the CPU. If it is not `thermal_zone0`, fix `GOV_T_SENSOR`.
- [ ] **OPP ladder**: `cat .../cpufreq/policy0/scaling_available_frequencies`. Replace the
      assumed ladder reasoning and set `GOV_STEP_KHZ` to ~one real OPP step. Re-check the
      per-system brackets in the pak `launch.sh` files snap sensibly onto real OPPs.
      - **Hint to confirm (not measured):** NextUI's `skeleton/SYSTEM/tg5040/bin/governor.sh`
        implies the TG5040 OPP range is **~408–1800 MHz** (min 408, mid 1200, "second_max"
        1800; 2000 is the OC). If real, our 8-bit `f_min` could drop **480 → 408 MHz** for a
        cooler idle. This is a *fork's* claim — confirm with `brick-recon.sh` before changing
        any value (CLAUDE.md: device values come from hardware, not other forks).
- [ ] **schedutil present** (hybrid model): `cat .../policy0/scaling_available_governors` must
      list `schedutil`. `boot.sh` now sets it + a `scaling_max_freq` cap. If it's absent, the cap
      still bounds the default governor (safe), but we lose the "drop the clock in light scenes"
      win — note it and consider an alternative kernel governor.
- [ ] **No overclock**: confirm `1800000` is a real stock OPP and that nothing caps at `2000000`
      (the OC). Adjust `GOV_STOCK_MAX_KHZ` / the PERFORMANCE tier / `launch.sh` FMAX to the
      verified stock max if different. Watch `scaling_cur_freq` under load never exceeds it.
- [ ] **Cluster-wide policy**: confirm `cpu0`'s `scaling_max_freq` governs all four cores
      (recon's per-core view). MinUI already assumes this; just confirm.
- [ ] **`auto` governor present?** If the kernel exposes one, note it — not used here
      (we stay in `userspace`), but good to record.
- [ ] **Voltage/OPP exposure**: confirm undervolt is not available on the stock kernel
      (expected: hidden). No code depends on it.

## C. Tune + confirm behavior in a real game
- [ ] Watch a heavy game (PS1) from cold: the clock should climb to hold frame rate,
      then settle at the lowest stable OPP; temp should plateau below `GOV_T_CEIL_C` (72°C).
- [ ] Confirm it does **not** hunt audibly/visibly (frame-rate wobble). If it does, raise
      `GOV_DN_DWELL` or `GOV_STEP_KHZ`.
- [ ] Confirm it runs cool on light systems (NES/GB): schedutil should still idle below their
      1008 MHz ceiling without the frontend probing a ceiling that clips present bursts (D61).
- [ ] **Sub-60 Hz cores** (PAL titles, VB): `FRAME_BUDGET` is a fixed 60 Hz (17 ms) budget,
      so a frame that comfortably holds a 50 Hz core can still read as an overrun and keep
      the clock higher than necessary. Confirm whether this wastes power on those cores; if
      so, make the budget core-fps aware (`1000/core.fps`) rather than the fixed 17 ms.
- [ ] **Per-core `f_max`** for the heavier accuracy cores: MGBA, SGB (mGBA) and SUPA
      (supafaust) are bracketed 16-bit (`f_max=1320000`). If they slip persistently at
      `f_max`, raise their `f_max` in the corresponding `launch.sh`. (Safe to leave: the
      ceiling still bounds heat; raising only recovers dropped frames.)
- [ ] Adjust `GOV_T_TARGET_C` (60°C) if it shaves clock too eagerly or runs warm.

## D. Safety hatch
- [ ] Confirm `GOV_DISABLE=1` (env, e.g. exported from a `launch.sh`) disables the
      governor and leaves the static CPU-speed menu in charge.

## E. Confirm the governor wins the clock-knob fight
- [ ] With the in-game CPU-speed menu set to each tier, confirm the governor re-asserts
      its own clock within ~0.5 s (it rewrites `scaling_setspeed` every tick by design).
- [ ] Confirm entering the menu / sleeping still drops to the menu/idle clock, and resuming
      hands control back to the governor.

## MEASURED (device session 2026-06-30) — recon complete
Real values captured over SSH on the Brick; the ASSUMED placeholders above are now resolved:
- **OPP table:** `408 600 816 1008 1200 1416 1608 1800 2000` MHz (floor 408, not 480). `GOV_STEP_KHZ`
  set to 216000 (real gap ~192-216); 16-bit f_max -> 1416 (1320 was not an OPP). The original
  8-bit f_min=408 result is superseded by D61: 408 remains the idle floor, while low-end gameplay
  retains a 1008 ceiling for burst headroom.
- **schedutil: PRESENT and active** (`scaling_available_governors` includes it). Hybrid model confirmed:
  under Tony Hawk PS1, ceiling held 1800 while schedutil ran 816-1416 MHz (mostly 1008), 33-37C.
- **Thermal zone: thermal_zone0 = cpu_thermal_zone** (confirmed). zone1=gpu, zone2=ddr, zone3=battery.
- **Battery: axp2202-battery** (path fixed). `current_now` is EMPTY on the AXP2202 -> no instantaneous
  power; mJ/frame must use capacity-drain, not V*I. `voltage_now`=4.03V, `capacity`=98%.
- **Undervolt: ~~NOT feasible at runtime~~ SUPERSEDED** — sysfs regulators are read-only, but the
  shipped implementation writes the TCS4838 VSEL registers directly over i2c-6 (gated on a
  per-chip calibration table + eFUSE serial + VSEL decode match; see platform.c uv_* and the
  Optimize CPU tool). Line kept for history: the sysfs finding was correct, the verdict was not.
- **Deep sleep: `mem` supported** (`/sys/power/state` = `freeze mem`). Suspend-to-RAM will work.
- **2.0GHz** IS an exposed OPP (cpuinfo_max=2000000) but we keep the 1.8 cap (no overclock).
