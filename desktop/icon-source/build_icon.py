#!/usr/bin/env python3
"""Compose the Patchwork app icons from the bubble layers.

Usage: python3 build_icon.py <assets-dir> <out.png>          # macOS-shaped plate
       python3 build_icon.py --mobile <assets-dir> <out-dir>  # iOS/Android sources
Then:  npx tauri icon <out.png>

The mobile icon must be full-bleed: iOS and Android apply their own mask, so a
pre-rounded plate on a transparent canvas shows a border inside a border.
"""
import sys, math
from PIL import Image, ImageChops, ImageDraw, ImageFilter

CANVAS = 1024
PLATE = 824              # Apple's macOS icon content box inside a 1024 canvas
RADIUS_RATIO = 0.2251    # 185.4 / 824
PLATE_TOP = (253, 252, 249)     # plate gradient, lit from the top
PLATE_BOTTOM = (242, 238, 230)
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


def load_bubbles(assets, size):
    bubbles = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    for name in LAYERS:
        bubbles.alpha_composite(Image.open(f"{assets}/{name}.png").convert("RGBA"))
    return bubbles.crop(bubbles.split()[3].getbbox()).resize((size, size), Image.LANCZOS)


def plate_gradient(size):
    grad = Image.linear_gradient("L").resize((size, size), Image.BILINEAR)
    return Image.merge("RGB", [
        grad.point(lambda v, lo=lo, hi=hi: round(lo + (hi - lo) * v / 255))
        for lo, hi in zip(PLATE_TOP, PLATE_BOTTOM)
    ])


def bubbles_on(base, bubbles, inset):
    """Contact shadow + bubbles, as on the macOS plate."""
    shadow = Image.new("RGBA", base.size, (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 41), (inset, inset + 6), bubbles.split()[3])
    base.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(9)))
    base.alpha_composite(bubbles, (inset, inset))


def mobile(assets, outdir):
    """Square full-bleed icon plus a safe-zone Android adaptive foreground."""
    icon = plate_gradient(CANVAS).convert("RGBA")
    inset = round(CANVAS * 0.17)  # keeps the bubbles clear of the iOS corner mask
    bubbles_on(icon, load_bubbles(assets, CANVAS - 2 * inset), inset)
    icon.convert("RGB").save(f"{outdir}/icon.png")

    # Android shows only the middle 72/108 of the foreground, so pad to match above.
    fg_inset = round(CANVAS * (0.5 - (0.5 - 0.17) * 72 / 108))
    fg = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    bubbles_on(fg, load_bubbles(assets, CANVAS - 2 * fg_inset), fg_inset)
    fg.save(f"{outdir}/adaptive-icon.png")
    print("wrote", outdir + "/icon.png", outdir + "/adaptive-icon.png")


def main(assets, out):
    plate_mask = squircle(PLATE, int(PLATE * RADIUS_RATIO))
    plate = plate_gradient(PLATE).convert("RGBA")
    plate.putalpha(plate_mask)

    # rim: darken toward the edge, then a highlight along the top-left
    edge = plate_mask.filter(ImageFilter.GaussianBlur(40))
    rim = Image.new("RGBA", (PLATE, PLATE), (178, 170, 156, 255))
    rim.putalpha(edge.point(lambda v: round((255 - v) * 0.18)))
    plate.alpha_composite(Image.composite(rim, Image.new("RGBA", rim.size), plate_mask))
    lit = Image.new("RGBA", (PLATE, PLATE), (255, 255, 255, 255))
    shifted = Image.new("L", (PLATE, PLATE))
    shifted.paste(edge, (7, 9))
    lit.putalpha(Image.eval(ImageChops.subtract(edge, shifted), lambda v: round(v * 1.3)))
    plate.alpha_composite(Image.composite(lit, Image.new("RGBA", lit.size), plate_mask))

    # bubbles: source layers are laid out in a 1024 grid, scale into the plate
    inset = int(PLATE * BUBBLE_INSET)
    bubbles_on(plate, load_bubbles(assets, PLATE - 2 * inset), inset)

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
    if sys.argv[1:2] == ["--mobile"]:
        mobile(*sys.argv[2:4])
    else:
        main(*sys.argv[1:3])
