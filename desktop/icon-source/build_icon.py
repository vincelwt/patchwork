#!/usr/bin/env python3
"""Compose the macOS-shaped Patchwork app icon from the bubble layers.

Usage: python3 build_icon.py <assets-dir> <out.png>
Then:  npx tauri icon <out.png>
"""
import sys, math
from PIL import Image, ImageChops, ImageDraw, ImageFilter

CANVAS = 1024
PLATE = 824              # Apple's macOS icon content box inside a 1024 canvas
RADIUS_RATIO = 0.2251    # 185.4 / 824
PLATE_TOP = (253, 252, 249)     # plate gradient, lit from the top
PLATE_BOTTOM = (234, 229, 219)
BUBBLE_INSET = 0.115     # bubble block margin inside the plate
LAYERS = ["BubbleTopLeft", "BubbleTopRight", "BubbleBottomLeft", "BubbleBottomRight"]


def squircle(size, radius, supersample=4):
    """Apple-style continuous-curvature rounded square as an L mask."""
    s = size * supersample
    r = radius * supersample
    n = 5.0  # superellipse exponent, close to Apple's squircle
    pts = []
    steps = 720
    for i in range(steps):
        t = 2 * math.pi * i / steps
        c, sn = math.cos(t), math.sin(t)
        # superellipse on the corner radius, straight edges in between
        x = math.copysign(abs(c) ** (2 / n), c)
        y = math.copysign(abs(sn) ** (2 / n), sn)
        pts.append(((x * s / 2) + s / 2, (y * s / 2) + s / 2))
    m = Image.new("L", (s, s), 0)
    ImageDraw.Draw(m).polygon(pts, fill=255)
    # blend the pure superellipse with a rounded rect so edges stay straight
    rr = Image.new("L", (s, s), 0)
    ImageDraw.Draw(rr).rounded_rectangle([0, 0, s - 1, s - 1], radius=r, fill=255)
    m = Image.composite(rr, m, m.point(lambda v: 255 if v > 127 else 0))
    return m.resize((size, size), Image.LANCZOS)


def main(assets, out):
    plate_mask = squircle(PLATE, int(PLATE * RADIUS_RATIO))
    plate = Image.new("RGBA", (PLATE, PLATE))
    grad = Image.linear_gradient("L").resize((PLATE, PLATE), Image.BILINEAR)
    plate = Image.merge("RGBA", [
        grad.point(lambda v, lo=lo, hi=hi: round(lo + (hi - lo) * v / 255))
        for lo, hi in zip(PLATE_TOP, PLATE_BOTTOM)
    ] + [plate_mask])

    # rim: darken toward the edge, then a highlight along the top-left
    edge = plate_mask.filter(ImageFilter.GaussianBlur(26))
    rim = Image.new("RGBA", (PLATE, PLATE), (150, 142, 128, 255))
    rim.putalpha(edge.point(lambda v: round((255 - v) * 0.5)))
    plate.alpha_composite(Image.composite(rim, Image.new("RGBA", rim.size), plate_mask))
    lit = Image.new("RGBA", (PLATE, PLATE), (255, 255, 255, 255))
    shifted = Image.new("L", (PLATE, PLATE))
    shifted.paste(edge, (7, 9))
    lit.putalpha(Image.eval(ImageChops.subtract(edge, shifted), lambda v: round(v * 2.2)))
    plate.alpha_composite(Image.composite(lit, Image.new("RGBA", lit.size), plate_mask))

    # bubbles: source layers are laid out in a 1024 grid, scale into the plate
    inset = int(PLATE * BUBBLE_INSET)
    inner = PLATE - 2 * inset
    bubbles = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    for name in LAYERS:
        bubbles.alpha_composite(Image.open(f"{assets}/{name}.png").convert("RGBA"))
    bubbles = bubbles.crop(bubbles.split()[3].getbbox()).resize((inner, inner), Image.LANCZOS)

    # per-bubble contact shadow (icon.json: neutral, 0.16)
    shadow = Image.new("RGBA", (PLATE, PLATE), (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 41), (inset, inset + 6), bubbles.split()[3])
    plate.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(9)))
    plate.alpha_composite(bubbles, (inset, inset))

    icon = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    x = (CANVAS - PLATE) // 2
    y = x - 8  # macOS sits the plate slightly high to leave room for the shadow
    drop = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    drop.paste((0, 0, 0, 66), (x, y + 16), plate_mask)
    icon.alpha_composite(drop.filter(ImageFilter.GaussianBlur(14)))
    icon.alpha_composite(plate, (x, y))
    icon.save(out)
    print("wrote", out)


if __name__ == "__main__":
    main(*sys.argv[1:3])
