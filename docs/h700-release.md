# Releasing the h700 (Anbernic RG35XX Plus/H)

The h700 does **not** ship as a zip like `tg5040` and `miyoomini`. Those are *tenants*: they drop a
payload onto a card and hijack the stock firmware's launcher. The h700 is an **owned OS**, the
release artifact is a flashable SD-card image containing our own rootfs, built by stripping a muOS
donor down to its hardware-enablement layer and replacing everything above it.

That difference is the whole reason this file exists: an image has inputs a zip does not.

## Build

```bash
make h700-build     # binaries only (on-device dev loop; see workspace/h700/README-BRINGUP.md)
make h700-image     # DEV image
make h700           # RELEASE image (requires a git tag)
```

Both image targets run `tools/build-h700-stripped.sh`, which needs **Docker running** (the strip and
the ext4 build happen in the `tg5040-toolchain` container) and the donor assets below.

### dev vs release

`H700_MODE` (set by the make targets) controls exactly the dev-loop conveniences, each of which is
actively wrong in a stranger's hands:

| | dev | release |
|---|---|---|
| `authorized_keys` baked into the rootfs | builder's `~/.ssh/tg5040_dev.pub` | **none** |
| `devmode.txt` on the card | yes (stay-awake: no autosleep, no idle power-off) | **no** |
| version stamp | `dev-YYYYMMDD` | `git describe --tags` |
| image name | `MinUI-Zero-h700-stripped-<date>.img` | `MinUI-Zero-h700-<tag>.img` |

A release build asserts both absences before it packs the card partition and aborts if either is
present. Shipping `devmode.txt` would mean a device that never sleeps, which is the precise opposite
of this fork's thesis; shipping a key would authorize one person on every user's device.

**SSH is opt-in on a release image.** There is no baked key and dropbear does not start without one.
A user drops their public key at the card root as `authorized_keys` (the image ships
`authorized_keys.example` next to `wifi.txt.example`) and the frontend installs it at boot. Password
login does not exist.

## The donor, the one input not in this repo

| | |
|---|---|
| **muOS version** | `2601.0_JACARANDA` (read from `/opt/muos/config/system/version` in the donor rootfs) |
| **Board** | `rg35xx-plus` (`/opt/muos/device/config/board/name`) |
| **Where the build expects it** | `$H700_ASSETS`, default `.notes/2026-08-05-h700-image/` |

Required files:

```
muos-p5.img            # the donor's p5 rootfs partition, raw
parts/raw-36mb.img.gz  # first 36MB of a stock card: boot chain + GPT + p1  ** carries the DTB patch **
parts/p2-boot.img.gz
parts/p3-env.img.gz
parts/p4-kernel.img.gz
```

These are raw partition extracts at muOS's own sector offsets, which the build script reuses
verbatim when it reassembles the image (`tools/build-h700-stripped.sh`, the `dd ... seek=` lines are
the source of truth):

| part | first sector | length (sectors) |
|---|---|---|
| boot chain + p1 | 0 | 73728 (36MB) |
| p2 boot | 90112 | 65536 |
| p3 env | 155648 | 32768 |
| p4 kernel | 188416 | 131072 |
| p5 rootfs | 319488 | ours, 2097152 |
| p6 ROMS (FAT32) | after p5 | ours, 524288 (expanded on first boot) |

To recreate them, flash an official muOS `rg35xx-plus` release to a card and `dd` those ranges out
(or read them from the release image directly). **Confirm the offsets against the donor's own GPT
rather than trusting this table**, it documents the 2601.0 layout, and a future muOS release is free
to move things.

### The DTB patch is baked into `raw-36mb.img.gz`, do not lose it

`raw-36mb.img.gz` is not a stock extract. It carries the **input-lag fix**: this BSP *polls* the
gpio-keys instead of using interrupts, at 20ms. The patch rewrites `poll-interval` to 5ms inside the
kernel DTB and recomputes the Allwinner toc1 additive checksum.

A freshly dumped part from a stock card silently regresses every button on the device to 20ms.
Re-run the patch after any re-dump:

```bash
python3 tools/h700-image/patch-pollinterval.py    # patches the raw-36mb part in place (idempotent)
```

It asserts the current value is 20 before writing and no-ops if already 5, so running it twice is
safe and running it on the wrong file fails loudly.

## Flashing

```bash
diskutil unmountDisk /dev/diskN
sudo dd if=<image>.img of=/dev/rdiskN bs=4m
```

Never the muOS card. The build prints this line with the real path when it finishes, and also emits
an `.xz` alongside the raw image for distribution.

First boot expands the ROMS partition to fill the card (`tools/h700-strip/expand-roms.sh`, hooked
pre-mount in `startup.sh`, it must run before muOS mounts the card, since parted refuses to resize a
partition in use).

## Known gaps

- **Donor acquisition is manual.** There is no script that turns an official muOS release into the
  `parts/` set; the current assets were dumped from a card by hand and the DTB patch applied after.
  Documented above, not automated.
- **The assets live in `.notes/` (gitignored).** A clean checkout on another machine cannot build an
  image without copying them across.
- **Deep sleep is on only when Zero owns the OS** (`PLAT_supportsDeepSleep()` returns `zero_owns_os()`): the
  choreography is `skeleton/SYSTEM/h700/bin/suspend`, validated on the Plus 2026-08-13. As a muOS guest it stays off.
