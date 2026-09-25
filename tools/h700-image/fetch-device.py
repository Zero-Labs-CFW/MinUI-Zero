#!/usr/bin/env python3
"""Fetch one device's definition from muOS (MustardOS/internal) into a local folder.

muOS keeps every supported handheld in one tree and picks ONE at image-build time; nothing installs a
device package at runtime (verified against the shipped scripts). So building for a different board
means fetching that board's folder and using it, which is exactly what this does.

  config/   board settings the muOS scripts read via GET_VAR (board/name, storage mounts, cpu, audio,
            battery, screen geometry, ...)
  control/  device state files, notably the alsa mixer baseline restored at boot and after suspend
  package/  the boot chain; only boot_package.fex (u-boot + device tree) is kept, the build takes
            nothing else from it and the rest (kernel.bin, ramdisk, ~19 MB) only bloated the rootfs

COMMON + BOARD (muOS e90b47d, 2026-09-06, "Added common device configuration layout"): the values shared
by every board moved to device/common/config, and a board folder now holds only what differs. Our
stripped rootfs runs the OLDER muOS scripts, which read the full per-board set (storage/*, cpu/*,
audio/*, battery/volt_*), so the tree must be common with the board's own files on top. Fetching the
board folder alone produced trees missing the card mounts, i.e. images that would not find their games
(caught in the 2026-09-25 audit).

Uses a shallow sparse git clone, not the contents API: the API rate-limits after ~60 calls and the old
code could not fetch files with spaces in their names ("Beetle GBA.cfg").

Usage:  fetch-device.py rg35xx-h  <out-dir>  [muos-git-ref]
"""
import os, shutil, subprocess, sys, tempfile

REPO = "https://github.com/MustardOS/internal.git"


def run(*cmd, cwd=None):
    subprocess.run(cmd, cwd=cwd, check=True, stdout=subprocess.DEVNULL)


def fetch(device, out, ref=None):
    tmp = tempfile.mkdtemp(prefix="muos-")
    try:
        run("git", "clone", "-q", "--depth", "1", "--filter=blob:none", "--sparse", REPO, tmp)
        if ref:
            run("git", "fetch", "-q", "--depth", "1", "origin", ref, cwd=tmp)
            run("git", "checkout", "-q", "FETCH_HEAD", cwd=tmp)
        run("git", "sparse-checkout", "set", "device/common", f"device/{device}", cwd=tmp)
        head = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=tmp, capture_output=True, text=True).stdout.strip()
        src = os.path.join(tmp, "device", device)
        if not os.path.isdir(src):
            sys.exit(f"ERROR: muOS has no device/{device} at {head}")
        if os.path.exists(out):
            shutil.rmtree(out)
        os.makedirs(out)
        common = os.path.join(tmp, "device", "common")
        if os.path.isdir(common):                    # shared values first...
            shutil.copytree(common, out, dirs_exist_ok=True)
        for d in ("config", "control"):              # ...then the board's own files on top
            if os.path.isdir(os.path.join(src, d)):
                shutil.copytree(os.path.join(src, d), os.path.join(out, d), dirs_exist_ok=True)
        bp = os.path.join(src, "package", "boot_package.fex")
        if not os.path.exists(bp):
            sys.exit(f"ERROR: device/{device}/package/boot_package.fex missing at {head}")
        os.makedirs(os.path.join(out, "package"), exist_ok=True)
        shutil.copy2(bp, os.path.join(out, "package", "boot_package.fex"))
        # provenance: which muOS commit this board came from, so a rebuild is reproducible and auditable
        open(os.path.join(out, "SOURCE"), "w").write(f"muOS MustardOS/internal {head}, device/common + device/{device}\n")
        return head
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# files the older muOS scripts in our rootfs read at boot; a tree without them boots without its card
REQUIRED = ["config/board/name", "config/board/network", "config/network/name", "config/storage/sdcard/mount",
            "config/storage/rom/mount", "config/cpu/governor", "config/audio/max", "package/boot_package.fex"]

if __name__ == "__main__":
    if len(sys.argv) not in (3, 4):
        sys.exit(f"usage: {sys.argv[0]} <device-name> <out-dir> [muos-git-ref]   e.g. rg35xx-h ./assets/device-rg35xx-h")
    device, out = sys.argv[1], sys.argv[2]
    ref = sys.argv[3] if len(sys.argv) == 4 else None
    print(f"fetching muOS device definition '{device}' (common + board) -> {out}")
    head = fetch(device, out, ref)
    missing = [f for f in REQUIRED if not os.path.exists(os.path.join(out, f))]
    if missing:
        sys.exit(f"ERROR: tree is missing {', '.join(missing)} (muOS {head})")
    got = open(os.path.join(out, "config/board/name")).read().strip()
    print(f"  muOS {head}, config/board/name = {got}")
    if got != device:
        sys.exit(f"ERROR: fetched tree says '{got}' but we asked for '{device}'")
    print("  OK")
