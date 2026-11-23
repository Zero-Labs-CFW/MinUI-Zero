# Candidate 7: attended RG35XX H recovery gate

Host tools only. Nothing in this directory belongs in the image. The diagnostic
loader is built from a separate copy of the 87a8edf7 loader with h-fatal.patch
applied. Preflight is intact. After H profile and memory validation, main calls
the real fatal path with ZL_FAIL_GUNZIP. It is a forced watchdog reset, not a
test of an arbitrary kernel hang. The older Plus fixture is not interchangeable.

From the host-tool worktree, with **fresh captures from the H under test**:

```sh
N="$HOME/Sites/MinUI/.notes"
D="$N/2026-11-23-h700-h-recovery"
A="$N/2026-08-05-h700-image"
T=tools/h700-stage2-recovery.py
python3 "$T" seal-h "$D/capture" --spl "$A/spl/zero-spl.bin" \
  --normal "$A/loader/zero-loader.bin" --fatal "$D/loader/zero-loader.bin" > "$D/h-manifest.json"
```

The capture directory needs board.txt (the card board file, exactly h),
card.txt (CID), cmdline.txt and the seven raw REGIONS named in the tool.
An old capture, a fresh universal distribution image, or patched-in SPL bytes
are not a live cohort. Read and freeze the generated manifest and its SHA-256
before starting. A sealed, independently explained training write-back is the
only permitted exception to identical stock bytes; never learn it from the
boot being tested.

```sh
M=$(shasum -a 256 "$D/h-manifest.json" | cut -d' ' -f1)
gate() {
  python3 "$T" "$1" --manifest "$D/h-manifest.json" --manifest-sha256 "$M" \
    --image "$D/$2.img" --status "$D/$2.json"
}
gate prepare before
gate install-fatal before
# After attended install and readback, capture installed.img and installed.json.
gate guarded-reboot installed
# After one autonomous vendor return, capture returned.img and returned.json.
gate prove returned
# Only after accepting and saving the proof:
gate cleanup returned
```

These commands never SSH. Each prints review-only device commands; do not
pipe them into a shell. Stage the three hash-checked inputs as
/tmp/zero-stage2-recovery/{installer,spl,fatal} before the attended installer
step. Recheck identity/power at the device. Existing admission guards still
apply (including an already quiescent failed policy, the exact approved SPL in
slot 16/store and >50% battery); if they don't hold, stop, don't forge the state.
The .img arguments are regular-file raw card snapshots covering the validated
regions, not a mounted volume or block device. Each JSON describes that exact
snapshot, including board=h, card CID, serial (androidboot.serialno), battery,
menu/process state, boot_id, RTC, WDT and the measured background helper state.
For return, include loader_dt_present=false from observing an absent
/chosen/zero,loader, and return.before_boot_id and return.elapsed_seconds.

Expected (not observed): after verified RTC zero before the one reboot, H's
LPDDR4 record 0xA8 and AXP2202 0xC0, two starts and restore step 0x34 give
GP13=0x02A8C034; GP14=0x5A56004E, GP15=0. Require vendor menu, different
boot ID within 180 s, stock-equivalent *identical* slot 16 + slot 512,
unchanged protected regions and no automatic rearm. No retry after timeout.
