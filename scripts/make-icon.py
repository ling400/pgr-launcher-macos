#!/usr/bin/env python3
"""Generate Resources/AppIcon.icns for PGR Launcher.

Uses Pillow (bundled Python) to draw a Yaagl-style dark app icon, then iconutil.
Run: python3 scripts/make-icon.py
"""
import os
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICONSET = os.path.join(ROOT, "build", "AppIcon.iconset")
ICNS = os.path.join(ROOT, "Resources", "AppIcon.icns")

FONT_BOLD = "/System/Library/Fonts/Supplemental/DIN Alternate Bold.ttf"
FONT_CONDENSED = "/System/Library/Fonts/Supplemental/DIN Condensed Bold.ttf"


def rounded_mask(size: int, radius: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(mask)
    d.rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    return mask


def vertical_gradient(size: int, top, bottom) -> Image.Image:
    img = Image.new("RGB", (1, size))
    for y in range(size):
        t = y / max(1, size - 1)
        c = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
        img.putpixel((0, y), c)
    return img.resize((size, size))


def draw_icon(size: int = 1024) -> Image.Image:
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))

    # Background: near-black with a warm crimson falloff.
    bg = vertical_gradient(size, (16, 8, 12), (34, 8, 18)).convert("RGBA")
    bg.putalpha(rounded_mask(size, int(size * 0.225)))
    img.alpha_composite(bg)

    # Soft crimson glow behind the monogram.
    glow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse(
        [int(size * 0.16), int(size * 0.30), int(size * 0.84), int(size * 0.94)],
        fill=(214, 32, 62, 120),
    )
    glow = glow.filter(ImageFilter.GaussianBlur(int(size * 0.09)))
    glow.putalpha(Image.composite(glow.getchannel("A"), Image.new("L", (size, size), 0),
                                  rounded_mask(size, int(size * 0.225))))
    img.alpha_composite(glow)

    # Diagonal shard.
    shard = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shard)
    sd.polygon(
        [
            (int(size * 0.10), int(size * 0.86)),
            (int(size * 0.90), int(size * 0.14)),
            (int(size * 0.90), int(size * 0.30)),
            (int(size * 0.26), int(size * 0.94)),
        ],
        fill=(226, 34, 68, 60),
    )
    img.alpha_composite(shard)

    # Monogram: P G R drawn in DIN Alternate Bold with manual tracking.
    draw = ImageDraw.Draw(img)
    font = ImageFont.truetype(FONT_BOLD, int(size * 0.34))
    text = "PGR"
    tracking = int(size * 0.035)
    widths = [draw.textlength(ch, font=font) for ch in text]
    total = sum(widths) + tracking * (len(text) - 1)
    x = (size - total) / 2
    baseline_y = size * 0.44
    for ch, w in zip(text, widths):
        draw.text((x, baseline_y), ch, font=font, fill=(244, 244, 246, 255), anchor="ls")
        x += w + tracking

    # Thin crimson rule + subtitle.
    rule_y = int(size * 0.70)
    draw.rectangle(
        [int(size * 0.30), rule_y, int(size * 0.70), rule_y + max(2, size // 220)],
        fill=(226, 34, 68, 235),
    )
    small = ImageFont.truetype(FONT_CONDENSED, int(size * 0.085))
    subtitle = "L A U N C H E R"
    sw = draw.textlength(subtitle, font=small)
    draw.text(
        ((size - sw) / 2, int(size * 0.755)),
        subtitle,
        font=small,
        fill=(196, 198, 204, 235),
    )

    return img


def main() -> int:
    os.makedirs(ICONSET, exist_ok=True)
    base = draw_icon(1024)
    for size in (16, 32, 64, 128, 256, 512):
        img = base.resize((size, size), Image.LANCZOS)
        img.save(os.path.join(ICONSET, f"icon_{size}x{size}.png"))
        img2 = base.resize((size * 2, size * 2), Image.LANCZOS)
        img2.save(os.path.join(ICONSET, f"icon_{size}x{size}@2x.png"))
    subprocess.run(["iconutil", "-c", "icns", ICONSET, "-o", ICNS], check=True)
    print("wrote", ICNS)
    return 0


if __name__ == "__main__":
    sys.exit(main())
