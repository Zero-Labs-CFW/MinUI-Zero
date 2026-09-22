#!/usr/bin/env python3
"""Render the installer/updater screens: white text centred on black, the menu font, small.

    make-install-art.py            # rewrites every installing.png / updating.png below

The originals were hand-made at ~42 px text height on 640x480 (Dan, 2026-09-16: "the message is
huge, make it much smaller everywhere"). Text height is now a fraction of the panel height so the
Brick Pro (960x720) and the 640x480 devices look the same. The h700 first-boot splash
(tools/h700-strip/make-splash.py) is rendered from the tg5040 installing.png, so it follows.
"""
import pathlib

from PIL import Image, ImageDraw, ImageFont

REPO = pathlib.Path(__file__).resolve().parent.parent
FONT = REPO / "skeleton/SYSTEM/res/BPreplayBold-unhinted.otf"
TEXT_H_FRAC = 1 / 28  # ~17 px cap height on 480 rows; the old art was ~1/11, 1/32 read tiny (Dan, 2026-09-22)

TARGETS = {
    "workspace/tg5040/install": (640, 480),
    "workspace/tg5040/install/brick": (960, 720),
    "workspace/miyoomini/install": (640, 480),
}
LINES = {"installing.png": "Installing MinUI Zero...", "updating.png": "Updating MinUI Zero..."}


def render(size, text):
    w, h = size
    im = Image.new("RGB", size, "black")
    d = ImageDraw.Draw(im)
    px = int(h * TEXT_H_FRAC * 1.35)  # font size vs cap height, tuned for this face
    font = ImageFont.truetype(str(FONT), px)
    x0, y0, x1, y1 = d.textbbox((0, 0), text, font=font)
    d.text(((w - (x1 - x0)) / 2 - x0, (h - (y1 - y0)) / 2 - y0), text, font=font, fill="white")
    return im


for rel, size in TARGETS.items():
    for name, text in LINES.items():
        out = REPO / rel / name
        render(size, text).save(out, optimize=True)
        print(f"{out.relative_to(REPO)}: {size[0]}x{size[1]}")
