# H700 Stage-2 Loader

Experimental SPL -> loader -> vendor monitor -> Linux path. Packaging this loader
does not install or enable it. The manifest includes eleven exact firmware profiles
covering the known H700 models; RG35XX 2024 shares the Plus artifact profile.
The added profiles are source-backed trial paths, not hardware qualification.
Unknown firmware, RAM/type or panel contracts remain refused.

The memory-layout backend separates physical RAM from the first GiB mapped by the
loader. Its bounds and FDT encoding are tested for 2 GiB, without mapping or touching
the upper GiB. The RG34XX SP profile requires 2 GiB; all other current profiles
require 1 GiB. Exact RAM-dependent transcript matching and the unit's separate SPL
binding remain mandatory. This does not qualify DRAM training or suspend on a new unit.

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
The build runs ELF/header/checksum/FP-confinement/no-dynamic-link checks. Rebuild twice in
separate output directories and compare manifests before qualification. Output
directories and diagnostics are build/scratch artifacts, not source.

`profiles.json` is the reviewed input-identity allowlist. `tools/profiles.py` generates
`profiles.inc` and `profile_policy.inc`; `--check` rejects stale generated data.
New trial rows require exact artifact and source-contract review; automatic/default-on
eligibility requires separate qualification. Hash matching is accidental-mismatch protection, not secure boot
or physical model detection. The SPL separately validates the unit binding and DRAM.
Named variants keep exact hashes under the same hardware policy. The standard H
image adds a rootflags token absent from its earlier development capture; both
whole transcripts are explicit. No header bytes are masked or normalized.

SHA-256 retains the complete transcript and scalar fallback. Its optional instruction
backend runs only at EL3 with SHA2 support, FP traps clear, MMU/data cache enabled and
alignment traps disabled. It reads, but never changes, these controls. An assembly
wrapper preserves all touched full vector registers plus FPCR/FPSR, including on
refusal. The ELF check permits FP instructions only inside the two bounded SHA
assembly functions; all C remains general-register-only. This does not qualify an
unmeasured CPU/board or replace real EL3/boot/suspend testing.

## Tests

Portable, capture-free production SHA/profile-manifest and panel-policy sanitizer checks:

```sh
python3 workspace/h700/loader/test/unit.py
python3 workspace/h700/loader/test/sha_ce_test.py
python3 tools/tests/test_h700_stage2_ack.py
sh workspace/h700/boot-health/run-tests.sh
```

On Linux arm64 with SHA2, add `--arm64` to `sha_ce_test.py` for the actual assembly
state-preservation check. The actual-image profile harness runs real hashing and
guard branches with narrowly modeled privileged MRS reads; it checks all Q0-Q31,
FPCR/FPSR and x18-x29/SP on accept and refusal. This is not an EL3 trap/cache test.

Full real-kernel/FDT/lifecycle tests require explicitly supplied saved fixtures, not a
device or an implicit gitignored path. Use Linux arm64 with ASan/UBSan and dtc:

```sh
make -C workspace/h700/loader captured-test FIXTURES=/captures TEST_OUTPUT=/output
python3 workspace/h700/loader/test/profile_test.py --fixtures /captures \
  --binary --artifacts /sealed-build --packaged /boards-stage
make -C workspace/h700/loader fleet-test PACKAGED=/boards-stage TEST_OUTPUT=/output/fleet
```

The fixture root contains `devices/plus-215203`, `devices/h-215206` (each with validated
manifest, package, boot image and measured RAM), `pkg/{dtb,dtbo,monitor}.bin`,
`bootimg-hdr-plus.bin`, `pin-plus.bin`, `live-dt-plus.dts` and `cmdline-plus.txt`.
Fixtures contain vendor/device captures and are deliberately not shipped. Tests compare
their transcript hashes to the tracked public identities before accepting them. Missing
fixtures are an error, not a skipped passing gate. The captured tests include the actual
production entry body; MMIO/cache/monitor entry remain modeled and cannot qualify hardware.
The fleet target uses archived package/boot0 metadata, not measured unit training.
It checks production FDT fixups for both strap values, preserves unrelated properties,
and passes the emitted records through the real health CLI. Display/menu evidence in
that test is explicitly synthetic expected state, not physical scanout.

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

Panel selection has four tested vendor-policy primitives: strap with pull-up, strap with
pull unchanged, constant old, and constant BOE. `panel_policy.h` maps admitted profile IDs
to the same generated policy used by memory and display acceptance:

| Models | Panel Rule | Native Scanout |
| --- | --- | --- |
| RG35XX Plus / 2024, H, Pro | Strap with pull-up | 640x480 |
| RG35XX SP, RG40XX H/V | Strap with pull unchanged | 640x480 |
| RG CubeXX | Constant BOE | 720x720 |
| RG28XX | Constant old | 480x640 |
| RG34XX, RG34XX SP, RG SP | Strap with pull-up | 720x480 |

These dimensions are code-expected contracts for the exact staged firmware, not new
on-device measurements. Logical frontend rotation is separate from scanout. Constant
policies do not sample/configure PE6; the unchanged-pull policy does not touch its pull.

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
Fixed-panel profiles additionally reject a record carrying the other panel token.

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
Non-Plus profiles require `ZERO_STAGE2_TRIAL=1`; unqualified SPL board/type pairs
also require `ZERO_SPL_TRIAL=1`. These are developer trial gates, not automatic
model detection or a recommendation to enable untested hardware.
SPL-only installation is unchanged. A card ZIP does not upgrade the rootfs consumer.

## Provenance

Vendored libfdt, cache code and the retained reference zlib derive from U-Boot v2026.10,
commit 5508406582f6f7120dce0c4b3059819a41788db2. Existing SPDX/copyright notices
are retained. Standalone shims and hardware CRC selection are local adaptations.
The linked whole-buffer decoder is libdeflate v1.26 (pin/license in
`libdeflate/README.md`); the wrapper checks FHCRC, data CRC, ISIZE and trailing data.
It uses the existing bounded allocator and runtime-selected CRC implementation.
