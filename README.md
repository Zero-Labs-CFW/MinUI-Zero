# MinUI Zero

**Same simple MinUI. Tuned end to end.**

MinUI Zero keeps what makes [MinUI](https://github.com/shauninman/MinUI) great (fast, simple, distraction-free gaming) while tuning the hardware underneath to run cooler, last longer, and stay full speed with no CPU modes and no tinkering.

**Full speed. Zero tinkering.**

Runs on the **TrimUI Brick**, **Brick Pro**, **Smart Pro**, **Anbernic RG35XX Plus / H**, and the **Miyoo Mini family**.

<p>
  <img src="docs/img/brickpro-menu.png" width="275" alt="Main menu" />
  <img src="docs/img/brickpro-optimize-cpu.png" width="275" alt="Optimize CPU: per-chip undervolting" />
  <img src="docs/img/brickpro-ingame-menu.png" width="275" alt="In-game menu" />
  <br>
  <em>Screenshots from TrimUI Brick Pro.</em>
  <br>
  <br>
</p>

## Why Zero

Our handhelds have more power than most retro games need. Zero uses only what the game asks for.

* **Tuned per game**: the lowest clock that holds full speed (60 fps), no CPU setting to pick
* **Fast**: boots in seconds, games launch almost instantly
* **Cool & instant menu**: software-rendered, the GPU stays idle while you browse
* **Optimize CPU**: finds your chip's lowest safe voltage (TrimUI, opt-in)
* **Deep sleep**: near-zero draw, instant resume (TrimUI, Anbernic)
* **Smooth**: even scrolling and clean audio, even under load
* **Stock bugs fixed**: hot NES settings, crackling audio, hanging quit menus
* **Hard to break**: bad ROMs exit cleanly, saves are crash-safe
* **Still MinUI**: no box art, stores, or themes

*Nothing to configure. Just play.*

[Decisions](docs/DECISIONS.md) · [NextUI Comparison](docs/nextui-comparison.md) · [Benchmarks](docs/bench/README.md)

## Consoles

**Ready to play:** Game Boy Color, Game Boy Advance, NES, SNES, Sega Genesis, PlayStation.

**Also aboard, dormant:** Game Boy, mGBA, Super Game Boy, Game Gear, Master System, TurboGrafx-16, Virtual Boy, PICO-8. Create the matching Roms folder (e.g. "Virtual Boy (VB)") and the system appears, tuned core already installed.

## Download and install

[The latest release](https://github.com/Zero-Labs-CFW/MinUI-Zero/releases/latest) carries four files. A card serves its whole family, and no card crosses families.

| Device | Download | Install |
|---|---|---|
| TrimUI Brick / Brick Pro / Smart Pro | `MinUI-Zero-trimui-*.zip` | copy onto the card |
| Miyoo Mini / Plus / Flip | `MinUI-Zero-miyoo-*.zip` | copy onto the card |
| Anbernic RG35XX Plus / H | the matching `.img.xz` | flash the card |

**TrimUI and Miyoo** ride along with the stock firmware, nothing is erased: unzip onto a blank FAT32 card, or drop `MinUI.zip` on the card root to update.

**Anbernic** *is* the operating system: flash the `.img.xz` for your exact device with Raspberry Pi Imager, balenaEtcher, or `dd`. Flashing erases the card, and the Plus and H images are not interchangeable.

WiFi and SSH stay off until you ask (rename `wifi.txt.example` to `wifi.txt` with `SSID:password`). Empty `no-recents` and `hide-tools` files at the card root strip the menu further (hold SELECT and press START to reach Tools anyway).

## Devices

* **TrimUI (Brick, Brick Pro, Smart Pro)**: the primary platform, where Zero is tuned and measured.
* **Anbernic RG35XX Plus / H**: Zero *is* the OS, so it boots straight to the launcher and idles with nothing else running. Newer and less proven: updates are a reflash, six of fifteen systems are launch-tested, and L3/R3 are unmapped.
* **Miyoo Mini family**: same launcher and governor, cores rebuilt for ARMv7. The Plus is verified; the Mini and Flip are untested on hardware. The tuning gains don't transfer here (the CPU is a small share of this SoC's power), and deep sleep is impossible (the vendor kernel has no suspend).

## Disclaimer

MinUI Zero is unofficial personal firmware, provided as-is without warranty. Custom firmware can cause data loss or failed boots; back up your card before installing. Use at your own risk.

## Credits

Built on [MinUI](https://github.com/shauninman/MinUI) by Shaun Inman. Deep sleep from [zhaofengli](https://github.com/zhaofengli/MinUI); techniques from [MyMinUI](https://github.com/Turro75/MyMinUI) and [NextUI](https://github.com/LoveRetro/NextUI); dynamic rate control from [RetroArch](https://github.com/libretro/RetroArch); the power-off haptic cue from [SpruceOS](https://github.com/spruceUI/spruceOS); the Anbernic hardware layer from [muOS](https://muos.dev). An independent fork, not affiliated with or endorsed by any of them. See [`LICENSE.md`](LICENSE.md) and [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
