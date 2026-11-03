#!/usr/bin/env python3
# h700 boot screens, both 640x480x24 BMP on the p2 RESOURCE partition (mounted /mnt/boot):
#
#   bootlogo.bmp          — shown by the boot chain on a normal boot. The OFFICIAL MinUI logo
#                           (skeleton/SYSTEM/tg5040/dat/bootlogo.bmp, the exact MIN/UI mark the
#                           Brick/Smart Pro use), centered. Scale 0.8 = HALF the previous 1.6:
#                           the 1.6 render filled the panel edge-to-edge; half matches the OG
#                           MinUI proportions (workspace/_unmaintained/rg35xxplus/boot/
#                           bootlogo.bmp is a small centered mark) (Dan 2026-08-10).
#
#   bat/battery_charge.bmp - shown by the boot chain when the charger powers the device on. The stock
#                           file was the muOS gold badge; then a vertical outline that read as an empty
#                           battery (Dan 2026-11-03). Now the battery MinUI draws on its own charging screen
#                           (minui.c ChargingScreen, same geometry at the h700 scale), centered, with a
#                           rounded filled bolt where the level fill would be: a fixed picture cannot know
#                           the level. Drawn at 4x and downsampled so the curves are smooth.
from PIL import Image, ImageDraw
import os

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
W, H = 640, 480

# ---- bootlogo.bmp: official MinUI mark at half the old size ----
logo = Image.open(os.path.join(REPO, "skeleton/SYSTEM/tg5040/dat/bootlogo.bmp")).convert("RGB")
canvas = Image.new("RGB", (W, H), (0, 0, 0))
# 0.625 makes the mark occupy the SAME fraction of the screen as it does on the Brick, which is the
# only defensible target: 216px on the Brick 1024 panel = 21.1% of width, and 216*0.625 = 135px on
# this 640 panel = 21.1%. History: 1.6 filled the panel edge to edge, 0.8 (2026-08-10) halved it but
# still read ~28% oversized against the Brick because 640x480 is a much smaller canvas than
# 1024x768, so the same nominal scale eats proportionally more screen (Dan spotted it 2026-08-13).
scale = 0.625
lw, lh = int(logo.width * scale), int(logo.height * scale)
canvas.paste(logo.resize((lw, lh), Image.LANCZOS), ((W - lw) // 2, (H - lh) // 2))
out = os.path.join(HERE, "bootlogo.bmp")
canvas.save(out)
print("saved", out, Image.open(out).size)

# ---- bat/battery_charge.bmp: the charging-screen battery with a bolt ----
X = 4  # supersample
def S(v): return (v * 15 + 4) // 8 * X  # SCALE1 at the h700 scale (15/8)
big = Image.new("RGB", (W * X, H * X), (0, 0, 0))
d = ImageDraw.Draw(big)
WHITE = (255, 255, 255)
bw, bh, t = S(92), S(44), S(4)
r = bh // 5
nw, nh = S(5), bh * 5 // 12
bx, by = (W * X - (bw + nw)) // 2, (H * X - bh) // 2  # the battery and its nub, centered
d.rounded_rectangle([bx, by, bx + bw - 1, by + bh - 1], radius=r, fill=WHITE)
d.rounded_rectangle([bx + t, by + t, bx + bw - t - 1, by + bh - t - 1], radius=r - t, fill=(0, 0, 0))
d.rounded_rectangle([bx + bw - S(1), by + (bh - nh) // 2, bx + bw + nw - 1, by + (bh - nh) // 2 + nh - 1],
                    radius=nw // 2, fill=WHITE)
# bolt: SVG path M18 13 L26 2 8 13 14 19 6 30 24 19 Z in a 32 box, filled, stroke 2 with round joins
pts = [(18, 13), (26, 2), (8, 13), (14, 19), (6, 30), (24, 19)]
k = (bh - 2 * (t + S(3))) / 30  # the inner height (the fill's gap) over the path's 28 units plus stroke
cx, cy = bx + bw / 2, by + bh / 2
P = [(cx + (x - 16) * k, cy + (y - 16) * k) for x, y in pts]
d.polygon(P, fill=WHITE)
sw = 2 * k
d.line(P + [P[0]], fill=WHITE, width=round(sw))
for x, y in P:
    d.ellipse([x - sw / 2, y - sw / 2, x + sw / 2, y + sw / 2], fill=WHITE)
chg = big.resize((W, H), Image.LANCZOS)
os.makedirs(os.path.join(HERE, "bat"), exist_ok=True)
out2 = os.path.join(HERE, "bat", "battery_charge.bmp")
chg.save(out2)
print("saved", out2, Image.open(out2).size)
