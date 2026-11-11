#!/usr/bin/env python3
"""Regenerate the macOS app icon (AppIcon.icns), the menu bar template icons
and docs/logo.png from the flat artwork in new_logo.png.

The source art is a full-bleed 1024x1024 squircle on a white background. It is
cut out (white -> transparent, edge pixels un-premultiplied), placed on a
1024 px canvas and given the ambient + key shadows that the other icons in the
Dock carry.

The tile is drawn edge to edge (1024 of 1024) rather than Apple's 824/1024
grid: the app sits in the Dock next to third-party icons that fill their
entire canvas (ChatGPT, for one), and at 80.5% the mark read as undersized.
With no margin left there is nowhere to put a drop shadow, so the tile carries
its own depth from the artwork.

Usage:  python3 scripts/make_icons.py [--source=new_logo.png]
"""
import os
import sys
import subprocess

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES = os.path.join(ROOT, "Sources", "OCRLaTeX", "Resources")
DOCS = os.path.join(ROOT, "docs")

CANVAS = 1024
BODY = 1024           # full bleed: fills like third-party Dock icons
OFFSET = (CANVAS - BODY) // 2
SS = 2                # supersample factor for shadows

# Drop shadows only make sense while there is margin left to draw them in.
SHADOWS = ()

# The body colour of the artwork, used to un-premultiply antialiased edges.
BODY_MIN_CHANNEL = 31


def art_cutout(path):
    """Load the artwork and turn its white background into transparency.

    Only the region connected to the canvas border counts as background: the
    artwork's own highlights and glow are light too, and deriving alpha from
    the colour alone would leave ~25% of the tile translucent, which makes
    macOS treat the icon as artwork to re-plate instead of a full tile.

    Along the antialiased rim, alpha is solved from the blend over white
    (C = a*F + (1-a)*255) and F is recovered, so the edge stays dark on any
    desktop colour.
    """
    rgb = np.array(Image.open(path).convert("RGB")).astype(np.float32)
    h, w = rgb.shape[:2]

    near_white = (rgb.min(axis=2) >= 244)
    mask = Image.fromarray((near_white * 255).astype(np.uint8))
    flood = mask.copy()
    for seed in ((0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)):
        if flood.getpixel(seed) == 255:
            ImageDraw.floodfill(flood, seed, 128, thresh=0)
    exterior = np.array(flood) == 128

    # two-pixel band hugging the silhouette carries the antialiasing
    band = np.array(Image.fromarray((exterior * 255).astype(np.uint8))
                    .filter(ImageFilter.MaxFilter(5))) > 0
    band &= ~exterior

    alpha = np.full((h, w), 255.0, dtype=np.float32)
    alpha[exterior] = 0.0

    edge_alpha = np.clip((255.0 - rgb.min(axis=2)) / (255.0 - BODY_MIN_CHANNEL), 0.0, 1.0)
    alpha[band] = edge_alpha[band] * 255.0

    safe = np.maximum(alpha / 255.0, 1e-3)[..., None]
    straight = 255.0 + (rgb - 255.0) / safe
    rgb = np.where(band[..., None], straight, rgb)

    rgba = np.dstack([np.clip(rgb, 0, 255), alpha]).astype(np.uint8)
    return Image.fromarray(rgba)


def add_shadows(body):
    """Put ambient + key shadows behind the tile on a 1024 canvas."""
    W = CANVAS * SS
    O = OFFSET * SS
    layer_alpha = body.split()[3].resize((BODY * SS, BODY * SS), Image.Resampling.LANCZOS)

    out = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    for offset, blur, value in SHADOWS:
        shadow = Image.new("RGBA", (W, W), (0, 0, 0, 0))
        tint = Image.new("RGBA", (BODY * SS, BODY * SS), (5, 12, 30, value))
        shadow.paste(tint, (O, O + offset * SS), layer_alpha)
        out = Image.alpha_composite(out, shadow.filter(ImageFilter.GaussianBlur(blur * SS)))

    body_big = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    body_big.paste(body.resize((BODY * SS, BODY * SS), Image.Resampling.LANCZOS), (O, O))
    out = Image.alpha_composite(out, body_big)
    return out.resize((CANVAS, CANVAS), Image.Resampling.LANCZOS)


def build_icon(source):
    """Cut out the artwork and lay it on Apple's icon grid."""
    art = art_cutout(source)
    body = art.resize((BODY, BODY), Image.Resampling.LANCZOS)

    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    canvas.paste(add_shadows(body), (0, 0))
    return canvas


def build_menu_bar_icon(px):
    """Monochrome template mark: a bold Σ.

    A document frame or a scan bar next to the sigma collapses into mush at
    18 pt, so the status item carries the glyph alone — it stays legible in
    light, dark and tinted menu bars because the image is a template.
    """
    s = 8
    im = Image.new("RGBA", (px * s, px * s), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    sc = px * s / 18.0
    W = H = 18 * sc

    sigma_h = H * 0.76
    sigma_w = sigma_h * 0.80
    sx = (W - sigma_w) / 2
    sy = (H - sigma_h) / 2

    stroke = max(1.5 * sc, sigma_h * 0.155)
    half = stroke / 2
    top_y, bot_y = sy + half, sy + sigma_h - half
    mid = (sx + sigma_w * 0.60, sy + sigma_h / 2)

    d.line([(sx + half, top_y), (sx + sigma_w - half, top_y)], fill=(0, 0, 0, 255), width=int(stroke))
    d.line([(sx + half, bot_y), (sx + sigma_w - half, bot_y)], fill=(0, 0, 0, 255), width=int(stroke))
    d.line([(sx + half, top_y), mid], fill=(0, 0, 0, 255), width=int(stroke), joint="curve")
    d.line([mid, (sx + half, bot_y)], fill=(0, 0, 0, 255), width=int(stroke), joint="curve")

    return im.resize((px, px), Image.Resampling.LANCZOS)


def write_icns(icon):
    iconset = "/tmp/AppIcon.iconset"
    subprocess.run(["rm", "-rf", iconset], check=False)
    os.makedirs(iconset, exist_ok=True)
    for sz, name in [
        (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
        (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
        (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
        (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
        (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
    ]:
        icon.resize((sz, sz), Image.Resampling.LANCZOS).save(os.path.join(iconset, name))
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o",
                    os.path.join(RES, "AppIcon.icns")], check=True)
    subprocess.run(["rm", "-rf", iconset], check=False)


def main():
    source = os.path.join(ROOT, "new_logo.png")
    for a in sys.argv[1:]:
        if a.startswith("--source="):
            source = a.split("=", 1)[1]

    icon = build_icon(source)
    icon.save(os.path.join(DOCS, "logo.png"))
    write_icns(icon)

    for px, name in [(18, "MenuBarIcon.png"), (36, "MenuBarIcon@2x.png")]:
        build_menu_bar_icon(px).save(os.path.join(RES, name))

    print("wrote AppIcon.icns, docs/logo.png, MenuBarIcon*.png from %s" % os.path.basename(source))


if __name__ == "__main__":
    main()
