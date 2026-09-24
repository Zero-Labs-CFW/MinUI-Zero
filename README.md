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
* **Cooler, longer battery**: no wasted CPU or GPU work
* **Fast**: boots in seconds, games launch almost instantly
* **Instant menu**: drawn in software, so it's snappy and the GPU sleeps while you browse
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

## Settings

Tools > Settings is the one screen for everything you can change, drawn like the in-game Options: a value on each row and a line under the list saying what it does.

| Row | Values | What it does |
|---|---|---|
| Recents | On / Off | Recently Played on the main menu |
| Favorites | Off / On / Focus | favorite a game with Y in its in-game menu (a star beside the title and a Favorited button show it is one); On adds Favorites to the main menu, Focus makes the main menu only your favorites |
| Tools | Shown / Hidden | SELECT + START at the main menu opens Tools even when hidden |
| Rumble | On / Off | Off stops game rumble (the mute switch also stops it, with the sound) |
| Deep Sleep | On / Off | suspend to RAM when idle (TrimUI, Anbernic) |
| Optimize CPU | Stock / Optimized | per-chip undervolting; A runs or manages it (TrimUI) |
| WiFi | On / Off | shown once `wifi.txt` exists; On also starts SSH |
| Date & Time | | A opens the clock setter, which also owns the menu clock |

Every setting is also a small file on the card, so you can set it from a computer, and a few things are files only. Card-root files go at the top of the SD card and work with or without a `.txt` extension; delete the file to undo.

**Card root**

| File | Settings row | Effect |
|---|---|---|
| `no-recents` | Recents: Off | hides Recently Played and stops recording plays |
| `no-favorites` | Favorites: Off | hides Favorites; the in-game Y does nothing |
| `focus` | Favorites: Focus | the main menu shows your Favorites instead of the consoles |
| `hide-tools` | Tools: Hidden | hides Tools (SELECT + START at the main menu opens it anyway) |
| `no-rumble` | Rumble: Off | games never rumble |
| `wifi.txt` | WiFi | one network per line as `SSID:password`; file only, the password is yours to type |
| `timezone` | | an IANA name like `America/New_York`, for the clock and DST (TrimUI) |
| `devmode` | | stays awake and starts SSH; for development, costs idle battery |
| `authorized_keys` | | your SSH public key (Anbernic; SSH never starts without it) |

**In `.userdata/shared/`**

| File | Settings row | Effect |
|---|---|---|
| `disable-deep-sleep` | Deep Sleep: Off | sleep works like stock instead of suspending to RAM |
| `show-clock` | Date & Time | shows a clock in the menu |
| `enable-simple-mode` | | hides Tools and replaces Options with Reset in the game menu; no escape hatch and no Settings row on purpose, for a locked-down or kid's device |

## Device Sync

Tools > Device Sync copies your saves between two handhelds directly over a hotspot one of them opens: no computer, no internet, no account. Open it on both devices and press X Sync on each. One device (the one you are holding) shows the list of games whose saves differ; press A and both sides copy in one stream, then return to Tools by themselves.

* **What it syncs**: Saves (on by default: save files, save states and their thumbnails, Favorites, Collections), and Games (with the BIOS files they need). Each device chooses what it takes: a category copies to a device only when that device has it on, so Games on one side brings games to that side only. Recently Played, game settings and device settings stay per device.
* **A save follows its game**: a save or save state goes only to a device that has that game, or is getting it in the same sync. Ones held back travel the next time, once the game is there. Saves that belong to no single game (PlayStation memory cards, PICO-8 cart data) go to a device that has games for that system.
* **Emulator check**: a system the receiving device has no emulator for starts as Skip in the system list, since its games would stay hidden there; you can still choose to sync it.
* **Lists are merged**: Favorites and Collections end up as the union of both devices, so an entry added on either side is never lost.
* **Folder names do not matter**: a game is matched by its system tag and file name, so `6) PlayStation (PS)` on one card and `Sony PlayStation (PS)` on another are the same system, and each card keeps its own folder names. A system you do not have yet is created with the sender's folder name.
* **Games by system**: with Games on, the device you are holding first shows the systems that would move, each with a count and size. Set any to Skip (say, PlayStation) and it is remembered on that device; a skipped system moves in neither direction.
* **Nothing is ever lost**: a game is never overwritten or deleted, and any save that is replaced is backed up first. Backups (Y on the Device Sync screen) lists each sync; open one to put back everything or just the files you mark, X deletes one backup, Y deletes them all. A restore backs up the current files first, so it can itself be undone from the same list.
* **Newest wins**: when a save changed on both devices, the newer copy is kept and the older one backed up; clocks are compared across devices so a device without a clock does not win by accident.
* **No setup**: the hotspot needs no `wifi.txt`. The Miyoo Mini Plus always hosts (it cannot scan), the others join or host as needed, so two Miyoo Mini Plus cannot sync with each other directly. Any two devices running Device Sync can pair, whatever their Zero version; if one is too old to talk to the other, Device Sync says which one to update.
* If a sync is interrupted (battery, a device walking out of range) nothing is half-written: reopen Device Sync and it finishes what it started, picking up big games from where they stopped.
* **Repeat syncs are quicker**: each device remembers its last partner, so pairing with the same device again connects faster, and the first screen shows when you last synced.

## Devices

* **TrimUI (Brick, Brick Pro, Smart Pro)**: the primary platform, where Zero is tuned and measured.
* **Anbernic RG35XX Plus / H**: Zero *is* the OS, so it boots straight to the launcher and idles with nothing else running. Newer and less proven: updates are a reflash, six of fifteen systems are launch-tested, and L3/R3 are unmapped.
* **Miyoo Mini family**: same launcher and governor, cores rebuilt for ARMv7. The Plus is verified; the Mini and Flip are untested on hardware. The tuning gains don't transfer here (the CPU is a small share of this SoC's power), and deep sleep is impossible (the vendor kernel has no suspend).

## Disclaimer

MinUI Zero is unofficial personal firmware, provided as-is without warranty. Custom firmware can cause data loss or failed boots; back up your card before installing. Use at your own risk.

## Credits

Built on [MinUI](https://github.com/shauninman/MinUI) by Shaun Inman. Deep sleep from [zhaofengli](https://github.com/zhaofengli/MinUI); techniques from [MyMinUI](https://github.com/Turro75/MyMinUI) and [NextUI](https://github.com/LoveRetro/NextUI); dynamic rate control from [RetroArch](https://github.com/libretro/RetroArch); the power-off haptic cue from [SpruceOS](https://github.com/spruceUI/spruceOS); the Anbernic hardware layer from [muOS](https://muos.dev). An independent fork, not affiliated with or endorsed by any of them. See [`LICENSE.md`](LICENSE.md) and [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
