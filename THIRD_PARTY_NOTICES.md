# Third-party notices / provenance

This is an independent personal fork of `shauninman/MinUI`. It borrows and adapts code from sibling
forks freely; this file records what was taken and from where, so provenance is preserved.
Add an entry whenever code or a non-trivial technique is imported, with the donor repo,
branch, and commit SHA(s).

---

## Deep sleep (suspend-to-RAM)
- **Source:** `zhaofengli/MinUI`, branch `deep-sleep`
- **Commits:** `8266da9`..`6400c0e` (Implement deep sleep; Enable on tg3040/tg5040; platform
  suspend executable; retry on failure; faux-sleep→suspend escalation; `bin/suspend` script;
  ALSA mixer save/restore).
- **Imported into:** `workspace/all/common/api.c` (`PWR_sleep`/`PWR_deepSleep`/`PWR_waitForWake`
  escalation, weak `PLAT_deepSleep`/`PLAT_supportsDeepSleep`, resume debounce),
  `workspace/all/common/api.h`, `workspace/all/common/defines.h` (`BIN_PATH`),
  `workspace/tg5040/platform/platform.c` (`PLAT_supportsDeepSleep`),
  `skeleton/SYSTEM/tg5040/bin/suspend`.
- **Modifications:** ported onto our tree (no rename churn beyond `PWR_fauxSleep`→`PWR_sleep`),
  `DEEP_SLEEP_DELAY` made a named tunable, `bin/suspend` detach syntax made POSIX-explicit.
- See `docs/deep-sleep-design.md`.

---

## Governor evidence (referenced, not copied)
The closed-loop CPU governor (`workspace/all/common/governor.{c,h}`) is our own implementation.
NextUI commits informed the *direction* (kernel-governor architecture) but no code was copied:
`6990d474` (userspace loop → kernel governors), `afb3783d` (ondemand→schedutil + caps),
`e9e91137` (stuck-in-performance fix). See `docs/thermal-governor-design.md`.

## Sleep audio-device close (technique, reimplemented)
`SND_pause`/`SND_resume` in `workspace/all/common/api.c` (close the SDL audio device during sleep
so its thread fully stops — was ~7% CPU while "asleep" — reopen at the negotiated rate on wake)
implements the technique from MyMinUI (Turro75/MyMinUI) commit `5c0b3704` ("close audio device
during sleep"). Reimplemented against our stock-MinUI `SND_*` engine, not copied.

## Allwinner disp2 / ION UAPI headers (tools/disp-probe/)
`sunxi_display2.h` and `sunxi_ion.h` are Allwinner kernel UAPI headers, taken via MyMinUI
(Turro75/MyMinUI, `workspace/m21/platform/`). Used only by the `/dev/disp` recon probe to match the
A133P display-engine ioctl ABI. Kernel-origin headers (GPL); attribution retained as courtesy.

---

## Shipped third-party binaries (release-zip audit 2026-07-12)
The base release zip ships three prebuilt third-party programs alongside the emulator cores:

- **Info-ZIP unzip 6.0** (`.tmp_update/tg5040/unzip`) — built from `shauninman/unzip60`
  (cloned by `workspace/tg5040/makefile`); Info-ZIP license text ships in `LICENSES/unzip60/`.
- **Dropbear 2022.83** (`.system/tg5040/bin/dropbearmulti`) — SSH server/client for dev access
  (the Smart Pro firmware ships no sshd). Built from the `dropbear-2022.83` release tarball
  (https://matt.ucc.asn.au/dropbear/) with the MinUI tg5040 Docker toolchain as a dynamically
  linked multi-call binary (static builds segfault on this BSP — see docs/DECISIONS.md).
  Dropbear is MIT-licensed (per-file notices in its LICENSE); only spawned when the
  `enable-ssh` dev flag exists.
- **Dropbear 2022.83** (`.system/miyoomini/bin/dropbearmulti`) — the same thing for the Miyoo, which
  has no sshd of its own either. Built 2026-09-08 from the same upstream release tarball
  (sha256 `bc5a121ffbc94b5171ad5ebe01be42746d50aa797c9549a4639894a16749443b`) in the
  `miyoomini-toolchain-sdl2` image: `./configure --host=arm-linux-gnueabihf --disable-zlib
  --disable-lastlog --disable-utmp --disable-utmpx --disable-wtmp` then
  `make PROGRAMS="dropbear dropbearkey" MULTI=1`, armhf and DYNAMICALLY linked for the same reason
  as the tg5040 build. NOTE: that image exports `LIBNAME=libSDL2-2.0.so.0`, which silently defeats
  libtommath's `ifndef LIBNAME` and makes its default target a no-op — `unset LIBNAME` before
  building. Only spawned when the `devmode.txt` dev flag exists, never on a user card.
- **DinguxCommander** (`Tools/tg5040/Files.pak/DinguxCommander`) — the Files tool, built from
  `shauninman/DinguxCommander-sdl2` @ `8eaa0ef` (cloned, hash-pin-verified, and built by
  `workspace/tg5040/makefile`). Inherited from upstream MinUI, which ships the same program. The source tree
  carries no license file (OpenDingux-scene lineage, original by Mia); provenance and
  corresponding source are recorded here and in `LICENSES/SOURCES.txt`.
