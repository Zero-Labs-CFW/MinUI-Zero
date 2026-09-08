MinUI Zero is a performance-focused fork of MinUI for the TrimUI Brick,
Brick Pro and Smart Pro. It runs cool, sleeps deep, and lasts longer: the
same simple MinUI, tuned underneath, with every change measured on real
hardware.

Source and releases: https://github.com/Zero-Labs-CFW/MinUI-Zero (built on
MinUI by Shaun Inman: https://github.com/shauninman/MinUI)

----------------------------------------------------------------------------
What's different

- Closed-loop governor: runs each game at the lowest clock that holds its
  frame rate, measured live. It never overclocks.
- GPU-dark menu: the launcher renders in software so the GPU powers down.
  Brick only; unverified on Brick Pro, so it stays off there.
- Zero idle waste: no polling daemons, radios and LEDs off, audio closed in
  sleep, and USB is charge-only.
- Deep sleep: on by default. Suspends to RAM and wakes instantly, with an
  opt-out tool included.
- Stock bugs fixed: NES ran hot with crackling audio, quit menus hung, and
  LEDs re-lit themselves. All fixed.
- Plays better: stutter-free panel-locked pacing, a frame less input lag,
  and smoother audio.
- Tuned everything: cores built for the chip and pinned to it.
- Hard to break: bails on a bad ROM, survives mid-game resolution changes,
  and writes crash-safe saves.

About 7.5 hours on Game Boy (measured on the Brick), up from about 6 before
tuning.

There is no CPU Speed setting. The governor measures each game's real frame
rate every half second and finds the lowest clock that verifiably holds it.
The machine answers that question better than a menu can.

----------------------------------------------------------------------------
Installing

Only the TrimUI Brick, TrimUI Brick Pro and TrimUI Smart Pro are supported.

Use a reputable SD card, freshly formatted as FAT32 (MBR). Preload the
"Bios" and "Roms" folders (see below), then copy everything in this zip to
the root of the card: the "trimui" folder, "MinUI.zip" (without unzipping),
"Bios", "Roms", "Saves", and this README. Insert the card and power on;
MinUI Zero installs automatically.

----------------------------------------------------------------------------
Updating

Copy a newer "MinUI.zip" (without unzipping) to the root of the SD card and
power on. It updates in place; your roms, saves, and settings are untouched.

----------------------------------------------------------------------------
Shortcuts

Brightness: MENU + VOLUME UP or VOLUME DOWN Sleep:      POWER Wake:
POWER Mute:       FN switch

----------------------------------------------------------------------------
Sleep, quicksave & auto-resume

A short press of POWER sleeps the device. After two minutes asleep it
suspends to RAM: the device goes fully cold and wakes instantly, right where
you left off. To disable suspend, run the "Deep Sleep" tool in the Tools
menu. Sleep then behaves like stock MinUI and the device powers off on a
timer instead.

MinUI creates a quicksave when powering off in-game and resumes from it
automatically on the next boot.

----------------------------------------------------------------------------
Roms

The "Roms" folder contains a folder for each console. You can rename these
folders but you must keep the uppercase tag in parentheses: it maps the
folder to the correct emulator (eg. "Nintendo (FC)" or "Famicom (FC)" both
work).

When two folders share a display name (eg. "Game Boy Advance (GBA)" and
"Game Boy Advance (MGBA)") they combine into a single menu item, letting you
open specific roms with an alternate pak.

----------------------------------------------------------------------------
Bios

Some emulators require or run better with official bios files. MinUI Zero is
strictly BYOB. Place each system's bios in the "Bios" folder under the
matching tag (eg. PlayStation bios goes in "/Bios/PS/").

Bios file names are case-sensitive:

FC: disksys.rom GB: gb_bios.bin GBA: gba_bios.bin GBC: gbc_bios.bin MD:
bios_CD_E.bin bios_CD_J.bin bios_CD_U.bin PS: psxonpsp660.bin

----------------------------------------------------------------------------
Disc-based games

Place bin/cue (and/or iso/wav) files in a folder named after the cue file;
MinUI launches the cue directly instead of opening the folder, eg.

Harmful Park (English v1.0)/ Harmful Park (English v1.0).bin Harmful Park
(English v1.0).cue

For multi-disc games, put every disc in one folder and add an m3u file (a
text file listing each disc's cue on its own line) named after the folder,
eg. a "Policenauts" folder:

Policenauts (English v1.0)/ Policenauts (English v1.0).m3u Policenauts
(Japan) (Disc 1).bin Policenauts (Japan) (Disc 1).cue Policenauts (Japan)
(Disc 2).bin Policenauts (Japan) (Disc 2).cue

The m3u contains just:

Policenauts (Japan) (Disc 1).cue Policenauts (Japan) (Disc 2).cue

With a multi-disc game, the in-game menu's Continue item shows the current
disc; press left or right to switch. chd and official pbp files are also
supported (multi-disc pbp over 2GB is not). All discs of a game share the
same memory card and save-state slots.

----------------------------------------------------------------------------
Collections

A collection is a text file of full rom paths, one per line, living in
"/Collections/" at the card root, eg. "/Collections/Metroid series.txt":

/Roms/GBA/Metroid Zero Mission.gba /Roms/GB/Metroid II.gb /Roms/SNES
(SFC)/Super Metroid.sfc /Roms/GBA/Metroid Fusion.gba

----------------------------------------------------------------------------
Display names

Override a file's display name by creating a map.txt in the same folder: one
line per file, "rom.ext" then a single tab then "Display Name". Start the
display name with "." to hide the file, eg.

neogeo.zip      .Neo Geo Bios mslug.zip Metal Slug

----------------------------------------------------------------------------
A more minimal menu

Two empty files at the card root strip the menu down further, and each works
with or without a ".txt" extension. Delete the file to restore the default.

no-recents   hides the Recently Played row and stops recording plays.
hide-tools   hides the Tools folder. Hold L1 + R1 and press SELECT at the
main menu to open Tools anyway.

For a full lockdown instead of a declutter, use simple mode: create an empty
file named "enable-simple-mode" (no extension) in "/.userdata/shared/". It
hides Tools with no escape hatch and replaces Options with Reset in the
in-game menu, which is handy for handing the device to kids.

----------------------------------------------------------------------------
Advanced

A user-authored shell script named "auto.sh" in "/.userdata/tg5040/" runs on
every boot. Use Unix line-endings.

----------------------------------------------------------------------------
Thanks

MinUI Zero stands on MinUI by Shaun Inman. The launcher, the frontend, and
the philosophy are his, as are the thanks owed to the wider community
documented in upstream MinUI. Deep sleep was ported from zhaofengli's MinUI
branch; techniques were borrowed from MyMinUI (Turro75) and NextUI
(LoveRetro); the rate-control idea comes from RetroArch. MinUI Zero is an
independent fork, not affiliated with or endorsed by any of them.

https://github.com/shauninman/MinUI https://github.com/zhaofengli/MinUI
https://github.com/Turro75/MyMinUI https://github.com/LoveRetro/NextUI
