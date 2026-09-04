# MinUI Zero

## Same simple MinUI. Tuned end to end.

**MinUI Zero** is a refined [MinUI](https://github.com/shauninman/MinUI) fork that keeps what makes
MinUI great: fast, simple, distraction-free gaming with almost nothing to configure. Underneath, Zero
runs cooler and lasts longer, with smoother frame pacing, cleaner audio, lower input lag, and more
dependable sleep and saves. No bloat, no menus to wrangle, just the power each game actually needs.

**Full speed. Zero tinkering.**

Runs on the **TrimUI Brick**, **Brick Pro**, and **Smart Pro**. Alpha builds for the **Anbernic RG35XX
Plus / H** and the **Miyoo Mini family**.

## Why MinUI Zero?

- **Cooler gameplay** without lowering frame rates
- **Longer battery life**: ~7.5 hours on Game Boy, ~7 on PlayStation (TrimUI, measured)
- **Smoother gameplay**: panel-matched frame pacing, better audio resampling, roughly one frame less
  input latency
- **No CPU settings to manage.** Every game is tuned automatically and continuously
- **Deep sleep by default** on TrimUI and Anbernic: near-zero draw, instant resume, never running
  hot in your bag
- **The simplicity of MinUI**: no box art, stores, accounts, or themes

For people who want to turn on a handheld and play games, not spend their time configuring one.

## Measured results

On real TrimUI hardware, against stock MinUI on the same device.

| Test | Result |
|---|---|
| Gameplay vs stock MinUI's default clock | **2-3°C cooler** |
| Gameplay vs MinUI's 2.0GHz Performance mode | **4-5°C cooler** |
| Game Boy battery life, TrimUI Brick | **~7.5 hours**, up from ~6 before tuning |
| PlayStation battery life | **~6.5-7 hours** |
| Bloody Roar II fights, ~51fps on the serial path | **Locked 60fps at stock clocks** (other firmwares reach 60 via the 2.0GHz overclock) |
| Tony Hawk's Pro Skater 2, in-level | **60fps at 1008 MHz**, half the stock clock |
| Menu idle, TrimUI Brick | **~26°C** with the GPU powered down |

Your games, silicon, and settings will vary. Raw data and the reasoning behind every claim live in
[`docs/bench/`](docs/bench/) and [`docs/DECISIONS.md`](docs/DECISIONS.md).

## On TrimUI: Zero or NextUI?

[NextUI](https://github.com/LoveRetro/NextUI) is the other major MinUI fork for these devices,
full-featured and polished where Zero is deliberately minimal. Both are good firmware; pick by
philosophy.

| | **MinUI Zero** | **NextUI** |
|---|---|---|
| Philosophy | Lowest power that holds full speed | Full-featured |
| Firmware source code | ~21,500 lines | ~51,200 lines |
| Base install download | 7 MB | 82 MB |
| Rendering | Lean pipeline; the GPU only displays the finished frame in-game, and powers down at the menu | Fully OpenGL/GPU-based, with shaders and overlays |
| CPU | Frame-aware closed loop plus a pipelined PS1 frontend; holds full speed at stock clocks, never overclocks | Dynamic scaling; performance mode is a 2.0 GHz overclock |
| Undervolting | Self-calibrating per-chip tool, finds each chip's lowest safe voltage (opt-in) | None |
| Features | Minimal by design: no box art, store, themes, or accounts | Box art, WiFi, Bluetooth audio, cheats, game switcher, Pak Store, LED effects, themes |
| Background services in-game | keymon only, rewritten for zero idle wakeups | keymon, battery monitor, audio monitor, plus WiFi and Bluetooth stacks when enabled |
| Deep sleep | Yes | Yes |
| Devices | Brick, Brick Pro, Smart Pro (+ alpha Anbernic RG35XX Plus / H and Miyoo Mini family) | Brick, Brick Pro, Smart Pro, Smart Pro S |

Measured at MinUI Zero v1.5 and NextUI v6.14.0. Source lines count each firmware's own `.c`/`.h` and
exclude the emulator cores both ship; download sizes are each project's base release zip. The NextUI
column comes from its README and its own boot and launch scripts, and the governor difference is
researched in [`docs/nextui-comparison.md`](docs/nextui-comparison.md). Code flows both ways between
these projects: deep sleep shares a lineage, and NextUI is credited in this codebase.

## How it works

There is no CPU Speed setting because the machine answers that question itself. Each system ships
with a clock bracket measured on real hardware. Where a bracket has room, the frontend watches
whether the game is holding its target frame rate and moves the CPU ceiling to the lowest clock that
still does, so Bloody Roar II pays 1800 only in the scenes that need it. The lightest systems
(Game Boy, GBC, NES, Master System, Game Gear, TurboGrafx-16) are simply pinned at a flat 1008 MHz,
because measurement showed the loop had nothing left to find below it. **Deep sleep** suspends to RAM rather than idling behind a dark
screen, and on TrimUI, **Optimize CPU** measures your specific chip's lowest safe voltage for about
20% less CPU power at identical clocks.

Full explanation of each, and the design docs behind them: [**docs/how-it-works.md**](docs/how-it-works.md).

## Quality of life

- **Stock bugs fixed**: hot-running NES settings, crackling audio, hanging quit menus, LEDs turning
  themselves back on
- **Safer failure handling**: bad ROMs exit cleanly, mid-game resolution changes are handled, and
  saves are written atomically, so a crash or a full card leaves the previous good save intact
- **Efficiency-tuned cores**, including NEON-accelerated PlayStation video decoding
- **Fast boot**: power to menu in ~10 seconds, and waking from sleep is instant
- **Menu clock** (opt-in) via Tools → Clock

## Consoles

**Ready to play:** Game Boy Color · Game Boy Advance · NES · SNES · Sega Genesis · PlayStation

**Also aboard, dormant:** Game Boy, mGBA, Super Game Boy, Game Gear, Master System, TurboGrafx-16,
Virtual Boy, PICO-8. Create the matching Roms folder (eg. "Virtual Boy (VB)") and the system appears,
tuned core already installed.

## Which download?

[The latest release](https://github.com/Zero-Labs-CFW/MinUI-Zero/releases/latest) carries four
artifacts, and they are not interchangeable.

| Device | Status | Download | Install |
|---|---|---|---|
| TrimUI Brick / Brick Pro / Smart Pro | Stable | `MinUI-Zero-trimui-*.zip` | Copy onto a card |
| Miyoo Mini / Plus / Flip | Alpha | `MinUI-Zero-miyoo-*-alpha.zip` | Copy onto a card |
| Anbernic RG35XX Plus | Alpha | `MinUI-Zero-h700-*-rg35xx-plus.img.xz` | Flash the card |
| Anbernic RG35XX H | Alpha | `MinUI-Zero-h700-*-rg35xx-h.img.xz` | Flash the card |

## Boot times, measured

Every device stamps its own boot receipt on every startup (kernel to browsable menu; the vendor
bootloader adds a moment before the kernel on all of them). From the receipts, v1.7.x builds:

| Device | Kernel to menu |
|---|---|
| Miyoo Mini Plus | **3.0s** |
| Anbernic RG35XX Plus | **3.0s** |
| Anbernic RG35XX H | **3.9s** |
| TrimUI Smart Pro | **6.9s** |
| TrimUI Brick | **7.1s** |
| TrimUI Brick Pro | **7.6s** |

The Anbernic numbers are the whole operating system booting — ours. The TrimUI gap is the vendor's
boot chain running before MinUI Zero gets control.

## Install

The two installs are genuinely different: one copies files, the other replaces the whole card.

**TrimUI and Miyoo: copy files.** MinUI Zero rides along with the firmware already on the device and
nothing is erased.

- **Fresh:** unzip the base zip onto a blank FAT32 SD card.
- **Update:** drop `MinUI.zip` on the card root and reboot.

**Anbernic: flash an image.** Here MinUI Zero *is* the operating system. Decompress the `.img.xz`
for your device and write it with [Raspberry Pi Imager](https://www.raspberrypi.com/software/),
[balenaEtcher](https://etcher.balena.io/), or `dd`.

> **Flashing erases the card.** Back up saves and roms first. The Plus and H images are not
> interchangeable: each carries its own boot chain, device tree and kernel.

Nothing is written to the device itself, so flash a spare card and swap cards to switch systems.
First boot expands the ROMS partition to fill the card, and that partition mounts on any PC or Mac.
Wi-Fi and SSH stay off until you ask for them: rename `wifi.txt.example` to `wifi.txt` at the card
root and put your network in it as `SSID:password`. Same file on every device. An idle radio is
battery you did not agree to spend, and nothing here needs the network. Once the file exists, a
**WiFi Toggle** tool appears in Tools showing the live connection (network name and IP) with
one-press on/off; cards without the file keep a clean Tools menu.
**A more minimal menu.** Zero's menu is already sparse, but a few empty files at the card root
strip it down further. Each works with or without a `.txt` extension, so it does not matter if your
computer adds one, and deleting the file restores the default.

- **`no-recents`** hides the Recently Played row and stops recording plays.
- **`hide-tools`** hides the Tools folder. Unlike simple mode it keeps an escape hatch: hold
  `L1 + R1` and press `SELECT` at the main menu to open Tools anyway.

For a full lockdown instead of a declutter (handing the device to kids, say), use simple mode: an
empty `enable-simple-mode` file in `/.userdata/shared/` hides Tools with no escape and swaps the
in-game Options for Reset.

**One card per device.** Upstream MinUI ships every platform in a single zip, so one card boots
anything it supports. Zero builds and ships each platform separately, so **a card serves the device
you installed it for**. Merging two platform downloads onto one card does not work: each install
places its own boot dispatch, and a card set up for one device has no bootstrap for the other, so the
second device stops after its firmware's loading screen. Use a card per device, and copy `Roms` and
`Saves` across if you want the same library on both. Note that battery saves move between devices but
save *states* may not, since they are tied to the emulator core's architecture.

## Anbernic RG35XX Plus / H (alpha)

Same launcher, same closed-loop governor, same cores, but newer than the TrimUI builds and less
proven. **Each device has its own image**, carrying that board's boot chain, device tree and kernel;
the H image is what makes its analog sticks work. Other H700 handhelds are untested and need their
own image.

Owning the whole OS is what lets the device boot straight into the launcher, poll input every 5ms,
and idle with nothing else running. Measured on the Plus: **95% to 6% battery over 10.1 hours of
continuous Game Boy Color**, at the lowest clock the silicon offers, at ~36°C.

Rough edges to expect: **updates are a reflash** (no in-place updater yet, and saves live on the
ROMS partition), six of the fifteen systems are verified by launch test, L3 and R3 are unmapped, and
no third-party pak has been run end to end.

## Miyoo Mini family (alpha)

A real port for the SigmaStar SSD202D: same launcher, same governor, the same eleven cores rebuilt
for ARMv7/NEON. One card serves all three models and the firmware detects which it woke up on. The
**Plus** is the model this is developed and verified on; the **Mini** and **Flip** are code-complete
but **never tested on real hardware**.

| | TrimUI Brick / Brick Pro / Smart Pro | Miyoo Mini Plus |
|---|---|---|
| Closed-loop governor | Yes | Yes |
| Emulator cores | 11 | 11 (same pinned versions) |
| **Deep sleep** | **Yes** | **Not possible**, see below |
| **Optimize CPU (undervolt)** | **Yes** | **No** |
| Tear-free, panel-accurate presentation | Yes | Yes |
| Measured battery/thermal figures | Yes, see above | **None yet** |

**None of the measured results above were taken on a Miyoo**, and an early port investigation found
the CPU is a much smaller share of total power on this SoC, so do not assume the battery numbers
transfer. They probably do not. PlayStation also leans on a 128 MB swapfile because the device has
~100 MB of usable RAM: games run at full speed, but the heaviest scenes push it to its limit. A
pin-verified 24% overclock changed that by 0%, so more clock cannot buy it.

**Why there's no deep sleep here.** This is a hardware limit, not a missing feature. The vendor
kernel is built without suspend support at all, so `/sys/power/state` is empty and there is no
suspend mode for any firmware to ask for. Every other Miyoo custom firmware works around it the same
way we do. Closing it for real would mean rebuilding the vendor kernel and reflashing SPI NOR, since
the kernel does not live on the SD card, which is a brick risk we will not take for a sleep mode.
Instead POWER blanks and idles, and after two minutes the device quicksaves and powers off.

## What's left out

No box art, Wi-Fi UI, store, achievements, LED effects, shaders, or themes. Anything that adds heat or
drain without earning it doesn't ship, and several flashy features were built, measured as
break-even, and cut. `docs/DECISIONS.md` records every verdict.

## Disclaimer

MinUI Zero is unofficial personal firmware, provided as-is, without warranty of any kind. Use it at
your own risk: custom firmware can cause data loss, failed boots, or other device issues, and the
author is not responsible for any of them. Back up your SD card before installing.

## Credits

Built on [MinUI](https://github.com/shauninman/MinUI) by Shaun Inman. Deep sleep from
[zhaofengli](https://github.com/zhaofengli/MinUI); techniques borrowed from
[MyMinUI](https://github.com/Turro75/MyMinUI) and [NextUI](https://github.com/LoveRetro/NextUI); the
dynamic rate control idea from [RetroArch](https://github.com/libretro/RetroArch); the power-off
haptic cue idea from [SpruceOS](https://github.com/spruceUI/spruceOS). The Anbernic build uses the
hardware-enablement layer from [muOS](https://muos.dev). An independent personal fork, not
affiliated with, endorsed by, or supported by any of them. See [`LICENSE.md`](LICENSE.md) for
license and provenance, and [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) for detailed
attribution.
