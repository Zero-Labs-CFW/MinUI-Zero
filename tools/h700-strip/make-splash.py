#!/usr/bin/env python3
"""Render a PNG into a raw framebuffer frame for the h700 first boot.

The ROMS expansion (expand-roms.sh) copies the payload off the card, reformats and copies it back,
minutes on a big card with only the boot logo on screen (Dan, 2026-09-16: "first boot is very very
slow, should we say installing"). fb0 is live before the card mounts, so the script just writes this
frame to it. Layout matches the panel driver: XRGB8888 little-endian, bytes B,G,R,X (platform.c
"little-endian XRGB: B,G,R,X"), one page at the panel size.

    make-splash.py <in.png> <out.raw> [width height [rotate]]

width x height is the panel's fb page (720x720 on the Cube, 480x640 on the portrait RG28XX). The art is
fitted without stretching and centered on black; rotate (90 or 270, clockwise) turns it onto a portrait
panel the same way platform.c turns frames (h700_rotate).

The source is the TrimUI installer art (workspace/tg5040/install/installing.png), already 640x480.
"""
import sys

from PIL import Image

src, dst = sys.argv[1], sys.argv[2]
w, h = (int(sys.argv[3]), int(sys.argv[4])) if len(sys.argv) > 4 else (640, 480)
rot = int(sys.argv[5]) if len(sys.argv) > 5 else 0

im = Image.open(src).convert("RGB")
if rot in (90, 270):
    im = im.rotate(-rot, expand=True)   # PIL turns counterclockwise; ours is clockwise
if im.size != (w, h):
    s = min(w / im.width, h / im.height)
    fit = im.resize((round(im.width * s), round(im.height * s)), Image.LANCZOS)
    im = Image.new("RGB", (w, h), (0, 0, 0))
    im.paste(fit, ((w - fit.width) // 2, (h - fit.height) // 2))
b, g, r = im.split()[2], im.split()[1], im.split()[0]
x = Image.new("L", (w, h), 255)
with open(dst, "wb") as f:
    f.write(Image.merge("RGBA", (b, g, r, x)).tobytes())
print(f"{dst}: {w}x{h} XRGB8888, {w * h * 4} bytes")
