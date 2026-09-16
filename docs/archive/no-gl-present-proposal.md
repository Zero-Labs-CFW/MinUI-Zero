# Proposal: GL-free present path (make the GPU dark) — scope, not code

> **STATUS (2026-07-01): resolved by measurement.** GPU-dark **menu shipped + validated** (software
> present to `/dev/fb0`, GPU domain suspends, 26°C). GPU-dark **games tested → shelved** — a clean drain
> A/B came out exact break-even vs GLES (the software-scale CPU cost offsets the GPU power saved). Games
> keep GLES; the only real games-win path is the DE hardware scaler (`/dev/disp`), which probed
> unavailable on this kernel. See the PROBE RESULT + UPDATE sections below and **D15/D18** in `DECISIONS.md`.

Lever ① from `zero-efficiency-roadmap.md`. Goal: stop presenting through the PowerVR GE8300 so its
power domain can suspend — the one efficiency edge NextUI (fully GPU-based) structurally can't copy.
**This is a prototype-and-measure proposal, not a "just do it" — because at 1024×768 the tradeoff can
go either way, and honesty about that is the point.**

## What we do today (measured)
`workspace/tg5040/platform/platform.c`:
- `PLAT_initVideo` (L58): `SDL_CreateRenderer(..., SDL_RENDERER_ACCELERATED|SDL_RENDERER_PRESENTVSYNC)`
  + a `STREAMING` RGB565 texture (L99/L106).
- `PLAT_flip` (L373): `SDL_UpdateTexture` (upload emu frame) → **`SDL_RenderCopy` (L436, the GPU
  scales src→1024×768 + aspect)** → `SDL_RenderPresent` (L443, GLES/KMS flip).
- `PLAT_getScaler` returns `scale1x1_c16` — a **1×1 passthrough**. So on tg5040 the **GPU does the
  scaling**, not our NEON `scaler.c`. `SDL_RENDERER_ACCELERATED` selects the KMSDRM+GLES backend.
- Device confirms it: `minarch` holds `/dev/dri/renderD128`, GPU power domain `active`, `pll_gpu`/`gpu`
  pinned at **702 MHz** during play.

So today the GPU does **texture upload + scale + present**, every frame. That's the 702 MHz we'd reclaim.

## What the device offers for a GL-free path (measured)
- **`/dev/fb0`**: present. `virtual_size = 1024,16384`, **32bpp (XRGB8888)**, stride 4096. The huge
  virtual height (21× the 768 visible) means **panning/multi-buffer is available** → tear-free
  double-buffering via `FBIOPAN_DISPLAY` + `FBIO_WAITFORVSYNC` is possible. Note: **32-bit, not
  RGB565** — a software path must convert RGB565→XRGB8888 on the way out.
- **`/dev/dri/card0`** (+ `controlD64`): full KMS. Alternative to fbdev: allocate **DRM dumb buffers**
  (CPU-mapped, no GPU) and `drmModePageFlip` + `drmWaitVBlank`. Dumb buffers can sometimes be RGB565
  (avoids the convert) depending on the plane formats the DE exposes — to be probed.

## The proposed path
Replace the GPU present with: **NEON software scale (real `scaler.c`, not 1×1) → 1024×768, RGB565→
XRGB8888 convert → write to a back buffer → page-flip (fbdev pan or DRM dumb-buffer flip) synced to
vblank.** GPU issues zero GL → `renderD128` unused → GPU power domain can suspend, `pll_gpu` gate off.
MyMinUI is the technique reference: it opens `/dev/fb0` directly and flips in `PLAT_flip`
(`mymin/main:workspace/miyoomini/platform/platform.c:297,473` and `.../m21/...:861,1173`) — **but on
640×480-class panels**, where software scaling is cheap.

## The honest tradeoff — why this must be measured, not assumed
Going GL-free **removes** GPU work (702 MHz: upload+scale+present) but **adds** CPU + DDR work:
- Software-scale each emu frame (e.g. 256×224 SNES, 160×144 GB) up to **1024×768** at 60fps — NEON,
  but ~0.79 Mpx/frame ≈ 47 Mpx/s, plus **RGB565→XRGB8888 convert** and ~3 MB/frame (180 MB/s) written
  to the framebuffer, which also loads the **DDR rail**.
- At MyMinUI's 640×480 this is ~2.5× cheaper; **at the Brick's 1024×768 it's genuinely borderline.**

This is exactly the project's own non-negotiable, applied in reverse: CLAUDE.md says *"GLES is
benchmarked, not auto-rejected — adopt only if it wins on total-device power, not CPU%."* The mirror
is true here — **software present wins only if the GPU it darkens costs more than the CPU+DDR it adds.**
On a high-res panel that is not obvious. The `charge_counter` meter exists precisely to settle it.

## Risks / things the change touches
1. **Whole UI, not just games.** `PLAT_flip` also presents `minui.elf` (launcher) + in-game menu +
   Tools. All must render correctly on the new path (menus are full-res software surfaces already —
   easier — but must be wired).
2. **Effects/sharpness done on GPU today**: `SHARPNESS_CRISP` uses a render-target upscale (L392) and
   scanline/grid `effect` overlays (L439) are GPU `SDL_RenderCopy`. Software path must reimplement or
   drop these (dropping is on-thesis: fewer features).
3. **Scale quality**: GPU bilinear vs NEON nearest. Nearest is fine (sharp pixel-art, matches SOFT/CRISP
   intent) and cheaper — but it's a visible change to vet.
4. **Tear-free correctness**: must double-buffer + block on vblank (fb pan or DRM flip). Get this wrong
   → tearing or frame-pacing regressions (pillar 3).
5. **DDR power**: the extra 180 MB/s fb writes load the memory rail — part of the "total power" question.

## Plan (decision-gated)
1. **Probe** (cheap, no commit): from a tiny standalone test on-device, confirm whether a DRM dumb
   buffer can be **RGB565** (skips the convert) and whether fb pan or DRM page-flip gives clean vblank
   sync. Pick fbdev-pan vs DRM-dumb accordingly.
2. **Prototype** behind a flag (e.g. `PLAT_useSoftwarePresent`, env-gated) — minimal: one core, native
   + one integer scale, nearest, no effects. Keep the GLES path intact as default.
3. **MEASURE with the meter** (10-min windows, per the drain-bench caveat), on light (GB/NES) *and*
   heavy (PS1) titles: (a) `charge_counter` drain vs GLES baseline, (b) does `pll_gpu` gate off /
   power domain suspend, (c) CPU load + `ddr_thermal_zone`, (d) frame pacing / tearing.
4. **Decision gate:** adopt only if **total-device drain drops** AND frame pacing holds AND it's
   tear-free. If 1024×768 software-scale eats the GPU savings, **do not ship it** — record the negative
   result (it's still a real finding) and consider the fallbacks below.

## Fallbacks if full-software present loses at 1024×768
- **GPU downclock**: if `pll_gpu` can be lowered (702→lower) while GLES still presents a simple quad,
  that's a smaller, safer partial win (the GPU cost is mostly the clock being lit). Needs clk-framework
  probing; riskier but cheaper than a full rewrite.
- **Lower present resolution**: render/scale to less than 1024×768 and let the DE upscale (if the panel
  scaler is cheaper than the GPU) — trades sharpness for power.
- **Accept GPU-lit** as the honest cost of a high-res panel, and bank the wins we *can* prove
  (governor, cores, radios/LEDs-off) — still cooler + leaner than stock MinUI, on par with NextUI.

## Effort
Prototype behind a flag: **meaningful** (new present backend + NEON scale/convert + vblank sync +
UI wiring), but bounded and reversible (flag-gated, GLES stays default until measured). The measurement
is the deliverable — this is the one lever where the *answer itself is unknown* until we run it.

## UPDATE (measured): the GPU CAN suspend → and the MENU is the smart place to dark it
Probe of `/sys/devices/platform/gpu/power`: **`control = auto`**, `runtime_active_time = 8032244`,
**`runtime_suspended_time = 671016`** — i.e. the GPU **does runtime-suspend** when no GL client uses it
(~11 min suspended already this session). So "GPU dark" is *technically real*: it stays lit only because
we present (games **and menu**) via GLES. The domain suspends the moment the last GL client releases it.

This reframes the whole lever into a **hybrid**, and resolves the 1024×768 tradeoff by splitting by context:
- **Games** — per-frame upscale (256×224 → 1024×768) is *exactly* what a GPU is efficient at, and the
  CPU is often the bottleneck there. **Keep the GPU present for games** (the proven path; offloading
  scaling to the already-good GPU is the "use GPU to idle the CPU" win NextUI describes).
- **Menu / UI** — static, **native 1024×768, no scaling**. Software-presenting it is nearly free
  (a convert+copy, no per-frame scale), and it lets the **GPU power domain suspend during all the time
  spent browsing/idle in menus**. This is the low-risk, clear-win slice: the CPU-scaling cost that makes
  the games case borderline **doesn't exist** for a native-res static menu.

**Revised recommendation:** don't chase "all-software present." Do **software present for the menu/UI
(GPU sleeps while navigating), GPU present for games (efficient scaling).** Start with the menu — small,
safe, measurable — and leave the proven game path alone unless the meter later says otherwise. This is
the synthesis of "use the GPU where it's efficient (games)" + "let it sleep where it's wasteful (menus)."

## UPDATE 2 (recon, from MyMinUI audit): `/dev/disp` + `/dev/ion` EXIST → the tradeoff may dissolve
Device probe: **`/dev/disp` (Allwinner DE2 display engine, 248,0) and `/dev/ion` (10,63) are both present**
on the Brick — the exact nodes MyMinUI's **m21** uses for its zero-copy, **hardware-scaled** display layer
(`mymin/main:workspace/m21/platform/platform.c:751,414`). The A133P is the same DE2 family. This opens a
**third, better path** that wasn't on the table when this doc was written:

- **DE2 hardware-scaled layer (à la m21):** hand the emulator's RGB565 frame (in an ION buffer) to the
  display engine and let **fixed-function hardware scale crop→1024×768 and scan it out.** No GLES (GPU
  dark) **and no CPU software-scale** — which is the cost that made the games case "borderline" above.
  **If it works, it dissolves the 1024×768 tradeoff entirely: GPU-dark *without* burdening the CPU/DDR.**
- fb0 also has 21 pages of pan room (double-buffer + `FBIOPAN_DISPLAY` viable) as the fallback software path.

**So the marquee lever is more promising than first scoped** — but gated on one more recon step the shell
can't do: **cross-compile a tiny `/dev/disp` probe** (sunxi disp2 `DISP_LAYER_SET_CONFIG` + ION alloc,
lifted from m21) to confirm the DE2 will actually scale a layer crop→screen on the A133P. `modetest`/
`drm_info` aren't on the device, so a small C probe is the way. **Do that before committing to any present
rewrite** — it decides between (best) DE2 hardware layer, (fallback) fbdev software-scale, and (status quo)
GPU. Confidence: `/dev/disp`+`/dev/ion` present is strong evidence, not proof, that the m21 path ports.


## PROBE RESULT (on-device, 2026-07-01): no free hardware-scale — display is fbdev-driven
Ran `disp-probe` on the Brick. `DISP_LAYER_GET_CONFIG2` **succeeds (ret=0) but returns zero/empty for
all 32 screen/channel/layer slots**, while `/sys/class/disp` shows a live 1024x768 layer. And **nothing
holds `/dev/dri/card0`** (the KMS master) — only `renderD128` (GPU render) is held by minarch. So the
scanout is driven by the **legacy framebuffer `/dev/fb0`** (32bpp, pannable), and the GPU is used only
via **EGL->fbdev** (PowerVR NULL-WSEGL) to present+scale. Consequences:
- **The m21 `/dev/disp` hardware-scale path does NOT apply** — that userspace layer API is unused here.
- **DRM scaling-plane path is possible but heavy** — no libdrm/headers on device, nobody holds card0;
  would require becoming DRM master + raw DRM ioctls. Not a cheap probe.
- **The real path is the simplest: fbdev software present** (MyMinUI miyoomini-style — NEON-scale the
  emu frame to a `/dev/fb0` back page, `FBIOPAN_DISPLAY` + `FBIO_WAITFORVSYNC`). GPU idle -> domain
  suspends -> dark. **But this pays the CPU software-scale cost (256->1024) — i.e. back to the original
  borderline 1024x768 tradeoff.** No free hardware-scale shortcut exists on this kernel.

**Decision-gate unchanged, path now concrete:** prototype the fbdev software present behind a flag
(NEON scaler lift -> fb0 pan -> measure with `charge_counter`); ship only if total drain drops. This is
a real prototype (bigger than a probe), so it's a scoped follow-up, not this-session work.
