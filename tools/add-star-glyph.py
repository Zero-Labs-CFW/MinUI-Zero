#!/usr/bin/env python3
"""Add a solid rounded star (U+2605) to the UI font and rename the family.

    python3 tools/add-star-glyph.py            # rewrites skeleton/SYSTEM/res/BPreplayBold-unhinted.otf

BPreplay has no star, and SDL_ttf (SDL2) has no fallback font, so a star in any string drew an empty box.
The in-game menu marks a favorited game with it (Dan, 2026-09-23). The shape is the Heroicons v2 solid
star (MIT licence, (c) Tailwind Labs): its rounded points match BPreplay's soft terminals, where a sharp
geometric star read thin and spiky beside the text. It sits on the baseline and reaches the cap height.

BPreplay is under the SIL Open Font License, which allows modified versions; the family is renamed
"BPreplay Zero" so the modified font never carries the original name. MinUI loads the font by file
path, so the rename changes nothing at runtime. Idempotent: an existing star glyph is replaced.
"""
import pathlib

from fontTools.ttLib import TTFont
from fontTools.pens.t2CharStringPen import T2CharStringPen
from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.transformPen import TransformPen
from fontTools.svgLib.path import parse_path

REPO = pathlib.Path(__file__).resolve().parent.parent
FONT = REPO / "skeleton/SYSTEM/res/BPreplayBold-unhinted.otf"
NAME = "star"
CODE = 0x2605
HEROICON = ("M10.788 3.21c.448-1.077 1.976-1.077 2.424 0l2.082 5.006 5.404.434c1.164.093 1.636 1.545.749 2.305"
            "l-4.117 3.527 1.257 5.273c.271 1.136-.964 2.033-1.96 1.425L12 18.354 7.373 21.18c-.996.608-2.231-.29"
            "-1.96-1.425l1.257-5.273-4.117-3.527c-.887-.76-.415-2.212.749-2.305l5.404-.434 2.082-5.005Z")

f = TTFont(str(FONT))
cap = 779                      # height of "H"
adv = 820                      # a touch wider than "O" (743) so the star breathes before the name

bp = BoundsPen(None)
parse_path(HEROICON, bp)
x0, y0, x1, y1 = bp.bounds
s = (cap + 40) / (y1 - y0)     # tip to foot = cap height plus a little overshoot, like the round letters
ox = (adv - (x1 - x0) * s) / 2 - x0 * s
oy = -20 + y1 * s              # SVG is y-down: flip it, foot 20 units below the baseline

pen = T2CharStringPen(adv, None)
parse_path(HEROICON, TransformPen(pen, (s, 0, 0, -s, ox, oy)))
cs = pen.getCharString()

cff = f["CFF "].cff
top = cff.topDictIndex[0]
strings = top.CharStrings
if NAME not in strings.charStrings:
    order = list(f.getGlyphOrder()) + [NAME]   # a COPY: the glyph order and the CFF charset are one list
    top.charset = order
    f.setGlyphOrder(order)
    strings.charStrings[NAME] = len(strings.charStringsIndex)
    strings.charStringsIndex.append(cs)
else:
    strings[NAME] = cs
cs.private = top.Private
cs.globalSubrs = cff.GlobalSubrs

f["hmtx"][NAME] = (adv, round(ox + x0 * s))
for t in f["cmap"].tables:
    if t.isUnicode():
        t.cmap[CODE] = NAME
f["maxp"].numGlyphs = len(f.getGlyphOrder())

# OFL: a modified font does not keep the original family name
for rec in f["name"].names:
    txt = rec.toUnicode()
    if "BPreplay" in txt and "Zero" not in txt and rec.nameID in (1, 3, 4, 6):
        rec.string = txt.replace("BPreplay-Bold", "BPreplayZero-Bold").replace("BPreplay", "BPreplay Zero")
cff.fontNames = ["BPreplayZero-Bold"]

f.save(str(FONT))
print(f"star added as {NAME} (U+{CODE:04X}), adv {adv}, family renamed BPreplay Zero")
