#!/usr/bin/env python3
"""Generates Budget's app icon into Budget/Assets.xcassets/AppIcon.appiconset.

The icon is drawn rather than hand-authored so it stays reproducible: rerun this
and you get byte-identical output, and a tweak is a diff in this file instead of
a binary nobody can review. Requires Pillow.

    python3 scripts/make-app-icon.py

Produces the three variants Xcode 26 asks for at 1024x1024:
  AppIcon.png         light / default
  AppIcon-Dark.png    dark appearance
  AppIcon-Tinted.png  grayscale; the system applies the user's tint

The mark is a two-segment donut: a budget split, and two segments for the two
people sharing it. Geometric shapes survive being scaled down to a 40pt home
screen icon in a way that fine detail and lettering do not.
"""

from PIL import Image, ImageDraw
import os

SIZE = 1024
SS = 4                      # supersample factor, downsampled for antialiasing
C = SIZE * SS // 2          # center in supersampled space
OUTER = int(340 * SS)       # donut outer radius
THICK = int(132 * SS)       # ring thickness
GAP_DEG = 7                 # gap between the two segments
SPLIT_DEG = 214             # size of the larger segment

OUT_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                       "Budget", "Assets.xcassets", "AppIcon.appiconset")


def vertical_gradient(top, bottom):
    """Full-bleed background. iOS masks the squircle itself, so this is square."""
    grad = Image.new("RGB", (1, SIZE), top)
    px = grad.load()
    for y in range(SIZE):
        t = y / (SIZE - 1)
        px[0, y] = tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
    return grad.resize((SIZE, SIZE), Image.Resampling.BILINEAR)


def draw_mark(major, minor):
    """The donut, drawn large and downsampled so the arc edges stay clean."""
    layer = Image.new("RGBA", (SIZE * SS, SIZE * SS), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    box = [C - OUTER, C - OUTER, C + OUTER, C + OUTER]

    # -90 puts the seam at 12 o'clock, where the eye expects a chart to start.
    start = -90 + GAP_DEG / 2
    d.arc(box, start, start + SPLIT_DEG - GAP_DEG, fill=major, width=THICK)

    start2 = -90 + SPLIT_DEG + GAP_DEG / 2
    d.arc(box, start2, start2 + (360 - SPLIT_DEG) - GAP_DEG, fill=minor, width=THICK)

    return layer.resize((SIZE, SIZE), Image.Resampling.LANCZOS)


def compose(bg_top, bg_bottom, major, minor, path):
    icon = vertical_gradient(bg_top, bg_bottom).convert("RGBA")
    icon.alpha_composite(draw_mark(major, minor))
    icon.convert("RGB").save(path, "PNG", optimize=True)
    print("wrote", os.path.relpath(path))


os.makedirs(OUT_DIR, exist_ok=True)

# Light: deep green ground, mint major segment, muted teal minor.
compose((17, 82, 62), (7, 40, 31),
        (94, 230, 168, 255), (42, 157, 143, 255),
        os.path.join(OUT_DIR, "AppIcon.png"))

# Dark: near-black ground so it recedes on a dark home screen; the mark keeps
# its hue but brightens slightly to hold contrast against the darker field.
compose((14, 32, 26), (5, 14, 11),
        (110, 240, 180, 255), (38, 140, 128, 255),
        os.path.join(OUT_DIR, "AppIcon-Dark.png"))

# Tinted: the system derives the tint from luminance, so this is grayscale on
# black. The two segments stay distinguishable by brightness alone.
compose((0, 0, 0), (0, 0, 0),
        (255, 255, 255, 255), (140, 140, 140, 255),
        os.path.join(OUT_DIR, "AppIcon-Tinted.png"))
