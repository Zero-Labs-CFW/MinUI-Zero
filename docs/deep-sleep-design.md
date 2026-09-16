# Deep sleep (suspend-to-RAM) — idle-heat lever

> **STATUS (2026-07-11): shipped, validated on-device, ON BY DEFAULT** (opt-OUT via the Deep
> Sleep tool's `disable-deep-sleep` flag). Earlier drafts below describing an opt-in flag are
> historical design notes, not current behavior.
> On-device: **33 → 27°C, clean resume, no `EBUSY`.** The "On-device validation" checklist below is done.

The governor handles **active gameplay** heat. This handles the other half: **idle/menu/
pause** heat and battery drain. Stock MinUI, when "asleep", just turns the screen off and
spins a 200 ms poll loop — the SoC keeps drawing power and stays warm. Deep sleep escalates
that to **true suspend-to-RAM** (`write "mem" → /sys/power/state`): near-zero power, cool.

This is a direct **port** of `zhaofengli/MinUI`'s `deep-sleep` branch — the original, minimal
implementation, written against **stock MinUI `PWR_*`**, which is exactly our code (it maps
~1:1; our `PWR_waitForWake` is byte-identical to its pre-change version). Community fork scene:
we borrow and adapt, keep attribution.

## Mechanism (hybrid sleep)
Keep MinUI's existing faux-sleep (screen off, snappy resume) as the **first stage**; after a
delay, **escalate to suspend-to-RAM instead of powering off**:

1. `PWR_sleep()` (renamed from `PWR_fauxSleep()` — same body + records `resume_tick`):
   screen off → `PWR_enterSleep` → `PWR_waitForWake` → `PWR_exitSleep`.
2. `PWR_waitForWake()` polls for a wake button every 200 ms. After `DEEP_SLEEP_DELAY`
   (default 120 s), if **not charging** and the platform `PLAT_supportsDeepSleep()`:
   - call `PWR_deepSleep()`; on success the device has suspended+resumed → return.
   - on failure retry up to 3× at 5 s (suspend can fail with `EBUSY` right after a resume),
     then fall back to `PWR_powerOff()` (old behavior).
3. `PWR_deepSleep()` runs `${BIN_PATH}/suspend` if present (the platform choreography script),
   else falls back to `PLAT_deepSleep()` which just writes `"mem"` to `/sys/power/state`.

### Resume debounce (correctness)
Waking from suspend is a power-button press, which the UI would otherwise read as a fresh
sleep/poweroff request. `PWR_sleep()` stamps `pwr.resume_tick` on resume; `PWR_update()`
ignores a `BTN_POWER` press within 1 s of `resume_tick` (zeroes `power_pressed_at`), and the
manual-sleep trigger requires `power_pressed_at` so the spurious wake-press can't immediately
re-sleep. (On the Brick the power button *is* the sleep button, so these interlock.)

## The `bin/suspend` script — where the real-world pain lives
`skeleton/SYSTEM/tg5040/bin/suspend` (ported from zhaofengli, tg5040-specific). Order matters:
- **Save ALSA mixer** state (`alsactl store`) — there's an audio glitch on resume otherwise.
- **Quiesce radios**: stop `wpa_supplicant`, `wlan0 down`, stop Bluetooth (`hciattach`/
  `bluetoothd`), `rfkill block` — **a wifi config with no AP in range makes the kernel refuse
  suspend with `EBUSY`.** This is the non-obvious failure the script exists to prevent.
- `echo mem > /sys/power/state` (the actual suspend; the script blocks here until resume).
- On resume: **restore the mixer**, restart radios **in the background** to cut wake latency.

## Files (C side, all small, additive)
- `workspace/all/common/api.h` — `PWR_fauxSleep` → `PWR_sleep`; add `PWR_deepSleep`,
  `PLAT_supportsDeepSleep`, `PLAT_deepSleep`.
- `workspace/all/common/defines.h` — `#define BIN_PATH SYSTEM_PATH "/bin"`.
- `workspace/all/common/api.c` — `resume_tick` field; weak `PLAT_supportsDeepSleep` (→0) and
  `PLAT_deepSleep` (→ write `/sys/power/state`) fallbacks; `PWR_deepSleep`; the
  `PWR_waitForWake` escalation; the `PWR_update` resume debounce; the rename.
- `workspace/tg5040/platform/platform.c` (+ `tg3040`) — `int PLAT_supportsDeepSleep(){return 1;}`.
- macOS / every other platform — no platform impl → weak fallback `PLAT_supportsDeepSleep()==0`,
  so deep sleep is **off** there and behavior is unchanged (the `mem` write is never reached).

## Decisions
- **D1 — Port, don't reinvent.** zhaofengli's branch is on stock `PWR_*` and tg5040-tested;
  adopt its structure faithfully, adapt names/tunables to our tree.
- **D2 — Keep the rename `PWR_fauxSleep`→`PWR_sleep`.** No external callers (only `api.c`/
  `api.h`), and "hybrid sleep" is the accurate name now.
- **D3 — `DEEP_SLEEP_DELAY` is a named `#define`, default 120000 (proven value).** Lowering it
  escalates to true suspend sooner = less idle drain (our runs-cold thesis) at the cost of
  slower resume. **Tune on-device**, don't guess — keep the proven default until measured.
- **D4 — Deep sleep is opt-in per platform** via the weak `PLAT_supportsDeepSleep()` returning
  1 only on tg5040/tg3040. Everywhere else it stays off → zero behavior change off-target.

## On-device validation (needs the Brick — see docs/archive/ON-DEVICE-CHECKLIST.md)
- Confirm `/sys/power/state` exists and accepts `mem` (suspend-to-RAM supported by the kernel).
- Confirm the wake button resumes (and the resume debounce prevents an immediate re-sleep).
- Confirm the `bin/suspend` radio/mixer teardown matches the Brick (service names, `wlan0`,
  rfkill indices) and that suspend isn't refused (`EBUSY`) with wifi configured-but-no-AP.
- Measure idle power/temperature before vs after, and tune `DEEP_SLEEP_DELAY`.
