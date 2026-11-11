#!/usr/bin/env python3
"""Regenerate the macOS app icon (AppIcon.icns) and menu bar template icons.

The artwork is drawn from scratch on Apple's standard macOS icon grid:
a 824x824 continuous-curvature squircle centred in a 1024x1024 canvas, with
ambient + key shadows, a vertical navy gradient and a top rim highlight.

Usage:  python3 scripts/make_icons.py [--variant=vector|upscale]
"""
import os
import sys
import subprocess

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES = os.path.join(ROOT, "Sources", "OCRLaTeX", "Resources")
DOCS = os.path.join(ROOT, "docs")

NAVY = (21, 29, 106)
NAVY_TOP = (28, 40, 124)
NAVY_BOTTOM = (11, 17, 66)
TEAL = (0, 150, 156)
WHITE = (255, 255, 255)

CANVAS = 1024
BODY = 824
RADIUS = 185
OFFSET = (CANVAS - BODY) // 2
SS = 2  # supersample factor


def squircle_mask(w, h, r):
    mask = Image.new("L", (w, h), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, w - 1, h - 1], radius=r, fill=255)
    return mask


def build_body():
    """Navy squircle with shadows and rim, on a canvas-sized RGBA layer."""
    W = CANVAS * SS
    O, B, R = OFFSET * SS, BODY * SS, RADIUS * SS

    img = Image.new("RGBA", (W, W), (0, 0, 0, 0))

    # ambient shadow
    amb = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    ImageDraw.Draw(amb).rounded_rectangle(
        [O, O + 6 * SS, O + B, O + B + 6 * SS], radius=R, fill=(0, 0, 0, 42)
    )
    amb = amb.filter(ImageFilter.GaussianBlur(9 * SS))
    img = Image.alpha_composite(img, amb)

    # key shadow
    key = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    ImageDraw.Draw(key).rounded_rectangle(
        [O, O + 22 * SS, O + B, O + B + 22 * SS], radius=R, fill=(0, 0, 0, 62)
    )
    key = key.filter(ImageFilter.GaussianBlur(20 * SS))
    img = Image.alpha_composite(img, key)

    # body gradient
    grad = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    gd = ImageDraw.Draw(grad)
    for y in range(int(O), int(O + B)):
        t = (y - O) / float(B)
        c = tuple(int(NAVY_TOP[i] * (1 - t) + NAVY_BOTTOM[i] * t) for i in range(3))
        gd.line([(O, y), (O + B, y)], fill=c + (255,))
    mask = Image.new("L", (W, W), 0)
    ImageDraw.Draw(mask).rounded_rectangle([O, O, O + B, O + B], radius=R, fill=255)
    body = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    body.paste(grad, mask=mask)
    img = Image.alpha_composite(img, body)

    # rim highlight
    rim = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    ImageDraw.Draw(rim).rounded_rectangle(
        [O, O, O + B, O + B], radius=R, outline=(255, 255, 255, 40), width=2 * SS
    )
    return Image.alpha_composite(img, rim)


def _stroke(d, points, width, fill):
    """Polyline with round caps and round joins (PIL only supports flat caps)."""
    d.line(points, fill=fill, width=width, joint="curve")
    r = width / 2.0
    for x, y in (points[0], points[-1]):
        d.ellipse([x - r, y - r, x + r, y + r], fill=fill)


def draw_sigma(size, stroke_ratio=0.16, vertex=0.55, bars=(0.03, 0.93), start=0.10):
    """A crisp Σ drawn as stroked polylines (transparent background)."""
    w, h = size
    im = Image.new("RGBA", (w * SS, h * SS), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    sw = int(h * SS * stroke_ratio)
    fill = NAVY + (255,)
    half = sw / 2.0
    W, H = w * SS, h * SS

    top_y, bot_y = half, H - half
    _stroke(d, [(W * bars[0] + half, top_y), (W * bars[1] - half, top_y)], sw, fill)
    _stroke(d, [(W * bars[0] + half, bot_y), (W * bars[1] - half, bot_y)], sw, fill)
    mid = (W * vertex, H * 0.5)
    _stroke(d, [(W * start, top_y), mid], sw, fill)
    _stroke(d, [mid, (W * start, bot_y)], sw, fill)
    return im.resize((w, h), Image.Resampling.LANCZOS)


def rounded_bar(size):
    w, h = size
    im = Image.new("RGBA", (w * SS, h * SS), (0, 0, 0, 0))
    ImageDraw.Draw(im).rounded_rectangle(
        [0, 0, w * SS - 1, h * SS - 1], radius=(h * SS) // 2, fill=TEAL + (255,)
    )
    return im.resize((w, h), Image.Resampling.LANCZOS)


def build_icon(sigma_mode="vector"):
    W = CANVAS * SS
    img = build_body()

    # --- white sheet: fills most of the squircle so the mark reads at small sizes
    sheet_w = int(BODY * 0.72) * SS
    sheet_h = int(sheet_w * 1.14)
    sheet_r = int(sheet_w * 0.16)
    sheet_x = (W - sheet_w) // 2
    sheet_y = OFFSET * SS + (BODY * SS - sheet_h) // 2

    # sheet shadow
    sh = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    ImageDraw.Draw(sh).rounded_rectangle(
        [sheet_x, sheet_y + 10 * SS, sheet_x + sheet_w, sheet_y + sheet_h + 10 * SS],
        radius=sheet_r, fill=(4, 8, 36, 90),
    )
    sh = sh.filter(ImageFilter.GaussianBlur(12 * SS))
    img = Image.alpha_composite(img, sh)

    sheet = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    sd = ImageDraw.Draw(sheet)
    sd.rounded_rectangle([sheet_x, sheet_y, sheet_x + sheet_w, sheet_y + sheet_h],
                         radius=sheet_r, fill=WHITE + (255,))
    img = Image.alpha_composite(img, sheet)

    # --- teal scan bar
    bar_w = int(sheet_w * 0.62)
    bar_h = int(bar_w * 0.105)
    bar = rounded_bar((bar_w // SS, bar_h // SS)).resize((bar_w, bar_h), Image.Resampling.LANCZOS)
    bar_x = (W - bar_w) // 2
    bar_y = sheet_y + int(sheet_h * 0.165)
    img.paste(bar, (bar_x, bar_y), bar)

    # --- sigma
    sig_w = int(sheet_w * 0.35)
    if sigma_mode == "vector":
        sig = draw_sigma((sig_w // SS, int(sig_w * 1.28) // SS))
        sig = sig.resize((sig_w, int(sig_w * 1.28)), Image.Resampling.LANCZOS)
    else:  # upscale the original artwork crop
        src = Image.open(os.path.join(ROOT, "ocr_logo.png")).convert("RGBA")
        crop = src.crop((760, 799, 842, 905))
        rgb = crop.convert("RGB")
        gray = rgb.convert("L")
        alpha = gray.point(lambda v: 255 - v)
        sig_src = Image.new("RGBA", crop.size, NAVY + (0,))
        sig_src.putalpha(alpha)
        sig = sig_src.resize((sig_w, int(sig_w * 1.28)), Image.Resampling.LANCZOS)
    sig_x = (W - sig_w) // 2
    sig_y = sheet_y + int(sheet_h * 0.425)
    img.paste(sig, (sig_x, sig_y), sig)

    return img.resize((CANVAS, CANVAS), Image.Resampling.LANCZOS)


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
    mode = "vector"
    for a in sys.argv[1:]:
        if a.startswith("--variant="):
            mode = a.split("=", 1)[1]

    icon = build_icon(mode)
    icon.save(os.path.join(DOCS, "logo.png"))
    write_icns(icon)

    for px, name in [(18, "MenuBarIcon.png"), (36, "MenuBarIcon@2x.png")]:
        build_menu_bar_icon(px).save(os.path.join(RES, name))

    print("wrote AppIcon.icns, docs/logo.png, MenuBarIcon*.png")


if __name__ == "__main__":
    main()
