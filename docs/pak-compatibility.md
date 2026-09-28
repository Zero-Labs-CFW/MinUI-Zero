# Pak compatibility — running the community's paks on MinUI Zero / MinOS

**Goal (Dan, 2026-08-10): keep the core lean, let users opt into features, and use the pak
ecosystem that already exists.** NextUI and MinUI pak authors have shipped tools and emulator
paks for years. MinUI Zero inherits the same pak contract by heritage, so most of that work
runs here unmodified — features arrive as *files a user chooses to install*, never as weight in
the base image.

## The contract (what a pak can rely on)

A pak is a folder named `<TAG>.pak` containing `launch.sh`. Emulator paks live in `Emus/`, tool
paks in `Tools/`, both under a **platform folder** at the card root. Roms map to paks by the
parenthesised tag on the rom's parent folder (`Roms/Game Boy Color (GBC)/` → `GBC.pak`).

Resolution order (`getEmuPath`, `workspace/all/common/utils.c`; `hasEmu` + Tools scan,
`workspace/all/minui/minui.c`):

1. `<card>/Emus/<PLATFORM>/<TAG>.pak/launch.sh` — our platform name
2. `<card>/Emus/<PLATFORM_ALIAS>/<TAG>.pak/launch.sh` — the scene's name, when they differ
3. `<card>/.system/<PLATFORM>/paks/Emus/<TAG>.pak/launch.sh` — shipped paks

### Platform folder names

| Device | MinOS platform | Scene folder | Needs alias |
|---|---|---|---|
| TrimUI Brick / Brick Pro / Smart Pro | `tg5040` | `tg5040` | no — identical |
| Miyoo Mini Plus | `miyoomini` | `miyoomini` | no — identical |
| Anbernic RG35XX Plus/H (+ H700 family) | `h700` | `rg35xxplus` | **yes** (`PLATFORM_ALIAS`) |

NextUI's H700 port (pvaibhav/NextUI, branch `h700`) also publishes under `h700`, so its paks land in our
`Emus/h700` and `Tools/h700` folders and are found first. That does not make them compatible: see gap 5.

A new port declares `#define PLATFORM_ALIAS "<scene name>"` in its `platform.h` **only when the
scene publishes under a different name**; internal identifiers are never renamed for branding
(upstream-merge cleanliness). That one define is the entire wiring.

### Environment a pak receives

`SDCARD_PATH`, `SYSTEM_PATH`, `USERDATA_PATH`, `SHARED_USERDATA_PATH`, `LOGS_PATH`, `SAVES_PATH`,
`BIOS_PATH`, `CHEATS_PATH`, `CORES_PATH`, `PLATFORM`, `DEVICE`, `LD_LIBRARY_PATH`.

`DEVICE` is the sub-device discriminator, consumed by minarch (`config.device_tag`) and by paks
that vary per model. Paks may ignore it. On h700 it is the muOS board name without `rg35xx-`:
`plus`, `h`, `pro`, `sp`, `rg40xx-h`, `rg40xx-v` (the RG35XX 2024 runs the Plus image and reports
`plus`). NextUI's H700 port uses different tokens (`rg35xxplus`, `rg35xxh`, `rg40xxh`, ..., no
dash), so a pak that switches on NextUI's values falls through to its default here. Renaming ours
would orphan every saved `minarch-<DEVICE>.cfg`, so it stays as is.

### Runtime helpers present on the h700 image

`jq`, `curl`, `wget`, `unzip`, `zip`, `tar`, `gzip`, `openssl`, `sed`, `awk`, `grep`, `find`,
`xargs`, `ping`. **Absent by design:** `python3` and `dialog` (stripped — see
`tools/build-h700-stripped.sh`). A pak needing those should bundle them or ship as an opt-in
compat pak; they do not belong in a base image whose whole thesis is running cold.

Verify on any target before promising compatibility — the donor OS decides this, not us.

## Will every pak just work? No. Here is the honest state

Tested on the h700 image 2026-08-10. The resolution/env plumbing is verified; **no third-party
pak has been run end to end yet.** Five known gaps, in order of how often they will bite:

1. **Hardcoded `/mnt/SDCARD`** — the scene's canonical mount (NextUI's own HOOKS.md uses the
   literal path), while muOS mounts our card at `/mnt/mmc`. **Mitigated:** the frontend creates
   `/mnt/SDCARD -> $SDCARD_PATH` at boot when the name is free. Paks that build paths from the
   documented env vars were never affected.
2. **`SDL_VIDEODRIVER=dummy` is inherited.** The h700 frontend exports it for MinUI (which presents
   through the DE layer and uses SDL only for plumbing). Any real SDL app that inherits it
   **segfaults** — measured, not theorised. A pak that opens a window must `unset SDL_VIDEODRIVER`
   in its launch.sh; the shipped Files pak does exactly that and is the reference. This is the
   first thing to check when a community tool "does not open".
3. **NextUI helper binaries** — `minui-list`, `minui-presenter`, `minui-keyboard`. Modern
   community *tool* paks (the Pak Store family especially) shell out to these for their UI, and
   we do **not** ship them. A pak that bundles its own copies works; one that expects them
   preinstalled fails. Open decision: ship them (small, and they make the whole tool ecosystem
   work) versus an opt-in compat pak. Leaning ship-them — they are pak infrastructure, not
   features, so they do not violate the lean thesis.
4. **Libraries the lean strip removed** — `libX11`, `libsqlite3`, `libopenal`, `libsamplerate`,
   `libarchive` are gone; SDL2 + SDL2_image + SDL2_ttf remain. Standalone-emulator paks linking
   the removed set will fail to start. Policy stands: bundle, or opt-in compat pak, never
   re-fatten the base image.
5. **NextUI H700 paks expect NextUI's own SDL.** Since h700-rc11 its built-in controls reach SDL
   apps as a joystick with TrimUI button numbers (B=0, A=1, Y=2, X=3, L1=4, R1=5, SELECT=6,
   START=7, MENU=8, L3=9, R3=10, triggers on axes 2/5), through the SDL build NextUI ships, and its
   paks (Pak Store/gabagool, DraStic, ScummVM, PICO-8) are written against that. We ship muOS's
   SDL, where the built-in controls arrive as keyboard scancodes (`workspace/h700/platform/platform.h`,
   unverified for third-party SDL apps). Such a pak also inherits gap 2 first. Expect wrong or
   missing buttons even after `unset SDL_VIDEODRIVER`. Shipping a TrimUI-layout SDL is a separate
   decision.

Expected outcome by pak type: **emulator paks reusing a bundled core → very likely fine**;
**paks bundling their own libretro core → likely fine**; **tool paks → depends on helper
binaries**; **standalone-emulator paks → test individually.**

## What does NOT come for free

Pak compatibility is a *launching* contract. NextUI features implemented **inside its launcher
and minarch** do not arrive with a pak:

- box art / game art display
- RetroAchievements
- the Pak Store client UI
- shader/overlay pipelines

Each of those is a real port, judged against `docs/project-direction.md` (user-facing features
are weight). The rule this fork uses:

> **If it can be a pak or a hook, it ships as a pak or a hook. Only what cannot be either may
> ask to live in the core — and then it has to earn it.**

Standalone-emulator paks bundle their own binaries and link against donor-OS libraries. Our
strip pass may have removed a library a stock device has. Policy: test, and if a popular pak
needs a stripped library, ship an opt-in compat pak rather than fattening the base image.

## Testing a pak (the check before claiming support)

1. Copy the pak to `Emus/<scene folder>/` or `Tools/<scene folder>/` on the card.
2. Confirm it appears (Tools) or that a matching rom folder launches it (Emus).
3. Check `$LOGS_PATH/<TAG>.txt` for missing-binary or missing-library errors.
4. For emulator paks: verify resume, quicksave/auto-resume, and that MENU still works.
