# H700 Stage-2 Loader

Experimental SPL -> loader -> vendor monitor -> Linux path. Packaging this loader
does not install or enable it. Plus development checks exist; H is host-tested only.
Other board/DRAM/panel combinations remain refused. This is not a release qualification.

## Build

The build needs Docker and a Linux arm64 toolchain image. The default image is pinned
by its local content ID in `build.sh`; there is no implicit pull or network access.
A bootstrap recipe with pinned Debian base and direct compiler packages is in
`Dockerfile`. If building that recipe as a different image, select it explicitly
with `ZERO_LOADER_BUILD_IMAGE`. Do not claim identical toolchain identity merely
because the recipe was used: the artifact records the actual image and tool versions.

```sh
sh workspace/h700/loader/build.sh /absolute/output-directory
```

Outputs: `zero-loader.bin`, ELF/map, `boot-health`, source `build-id`,
`sources.json`, compiler/linker versions, toolchain image ID and `artifacts.sha256`.
The build runs the ELF/header/checksum/no-FP/no-dynamic-link checks. Rebuild twice in
separate output directories and compare manifests before qualification. Output
directories and diagnostics are build/scratch artifacts, not source.

`profiles.json` is the reviewed input-identity allowlist. `tools/profiles.py` generates
`profiles.inc`; `--check` rejects stale generated data. New rows require review and
hardware qualification. Hash matching is accidental-mismatch protection, not secure boot
or physical model detection. The SPL separately validates the unit binding and DRAM.
Named variants keep exact hashes under the same hardware policy. The standard H
image adds a rootflags token absent from its earlier development capture; both
whole transcripts are explicit. No header bytes are masked or normalized.

## Tests

Portable, capture-free production SHA/profile-manifest checks:

```sh
python3 workspace/h700/loader/test/unit.py
python3 tools/tests/test_h700_stage2_ack.py
sh workspace/h700/boot-health/run-tests.sh
```

Full real-kernel/FDT/lifecycle tests require explicitly supplied saved fixtures, not a
device or an implicit gitignored path. Use Linux arm64 with ASan/UBSan and dtc:

```sh
make -C workspace/h700/loader captured-test FIXTURES=/captures TEST_OUTPUT=/output
python3 workspace/h700/loader/test/profile_test.py --fixtures /captures \
  --binary --artifacts /sealed-build --packaged /boards-stage
```

The fixture root contains `devices/plus-215203`, `devices/h-215206` (each with validated
manifest, package, boot image and measured RAM), `pkg/{dtb,dtbo,monitor}.bin`,
`bootimg-hdr-plus.bin`, `pin-plus.bin`, `live-dt-plus.dts` and `cmdline-plus.txt`.
Fixtures contain vendor/device captures and are deliberately not shipped. Tests compare
their transcript hashes to the tracked public identities before accepting them. Missing
fixtures are an error, not a skipped passing gate. The captured tests include the actual
production entry body; MMIO/cache/monitor entry remain modeled and cannot qualify hardware.

## Contract and Memory

`zero_params.h` must remain byte-identical to the copy embedded in
`workspace/h700/spl/zero-spl.patch`. Params ABI and image header version are both 2.
The image has a 64-byte header, entry +64, and a returning read-only preflight offset.
No extra stage-2 PMIC writes occur until the SPL accepts preflight; subsequent failures
reset through recovery, never continue with partially changed state into vendor U-Boot.

Fixed addresses: kernel 0x40080000, ramdisk 0x42000000, Android header 0x44f00000,
gzip 0x45000000, vendor monitor 0x48000000, fallback U-Boot 0x4a000000,
DTBO 0x4a100000, FDT 0x4a200000, loader 0x4c000000. Link-time and runtime checks
bound the image, stack, inflate output and disjoint regions. Kernel gzip CRC/size
and arm64 Image headers are checked. Existing panel power/reset minimum waits remain.

## Boot Acceptance

The loader adds exactly one `/chosen/zero,loader` 64-byte record: magic ZHL1,
BE32 version 1, length 64, profile ID, selected panel (old=0/boe=1), width, height,
reserved zero, then a 32-byte source-build identity. The panel is the decision already
used for bootargs; publishing metadata does not resample/reset the panel.

`boot-health` checks this record against the installed `build-id`, exactly one valid
`lcd_type` token, active LCD/manager geometry and `/run/zero-display-frame`, emitted
only by the presentation path (not the auto-resume quiet-window shortcut).
It never writes card/RTC state and does not require WiFi. The existing
`boot0-slot.sh ack` owner invokes it before clearing the attempt marker and GP15.
Stage1 behavior is unchanged. Stage2 retries acceptance up to 15 checks, one second
apart, so auto-resume may initialize its display. Missing/mismatched evidence fails closed.
This consistency check cannot prove physically illuminated/correctly oriented pixels.

The build ID hashes source/recipes, not the final image (which would be circular).
Artifact SHA256 binds the sealed binary separately. This is provenance and consistency,
not an authenticated boot chain.

## Recovery and Qualification

GP15 retains the 0x5a5600xx progress/failure contract; GP13/GP14 retain SPL meanings.
GP1 is never used. Explicit fatal paths arm the real 0.5-second watchdog; unmarked
hang recovery and post-Linux watchdog policy are distinct tests. Normal PMIC poweroff
clears volatile RTC try budgets: never present a GP5 write as a surviving cold-boot net.

Qualification still requires profile/checksum refusal, deliberate fatal/hang recovery,
repeated warm/cold first-visible-frame timing, menu/game STR, display/brightness,
speaker/headphones, WiFi, charger and natural low-battery behavior per board/DRAM/panel
revision. Keep stock slots/pins and verify every write/readback. A stock restoration
does not erase a residual fatal loader header; clear/verify it before any rearm.

The all-devices image carries the payload, but `spl-auto.sh` still installs SPL-only.
No stage2 automatic/default-on policy is introduced by this integration.
An explicit stage2 install requires the installed acknowledgment and health helper
to advertise `zero-stage2-health-v1`, plus a valid expected build ID, before card
writes. This refuses an older rootfs that could acknowledge without validation.
SPL-only installation is unchanged. A card ZIP does not upgrade the rootfs consumer.

## Provenance

Vendored inflate, libfdt and cache code derive from U-Boot v2026.10,
commit 5508406582f6f7120dce0c4b3059819a41788db2. Existing SPDX/copyright notices
are retained. Standalone shims and hardware CRC selection are local adaptations.
