#!/usr/bin/env python3
"""Draws EchoEdge's icon art with Pillow (not run in CI; the PNGs are committed).

The glyph is a screen outline with a glowing launcher bar on its left edge holding three app
tiles, in the Echo icon family's blue-to-cyan. It writes:
  Resources/AppIcon.icon/Assets/glyph.png  transparent glyph for the Icon Composer file (macOS 26+)
  Resources/AppIcon-1024.png               flat icon: navy squircle + glyph (.icns fallback)
  docs/images/echoedge-icon.png            the same flat icon, for the README

Usage: python3 Scripts/make-icon-art.py
"""
from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
SIZE = 1024
SCALE = 4  # draw large, then shrink, for smooth edges
BLUE = (44, 125, 240)
CYAN = (140, 224, 255)
SLATE = (52, 66, 92)
NAVY = (12, 20, 40)


def lerp(a: tuple[int, int, int], b: tuple[int, int, int], t: float) -> tuple[int, int, int]:
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def vertical_gradient(width: int, height: int, top: tuple[int, int, int], bottom: tuple[int, int, int]) -> Image.Image:
    gradient = Image.new("RGB", (1, height))
    for y in range(height):
        gradient.putpixel((0, y), lerp(top, bottom, y / max(1, height - 1)))
    return gradient.resize((width, height))


def glyph() -> Image.Image:
    s = SIZE * SCALE
    art = Image.new("RGBA", (s, s), (0, 0, 0, 0))

    def box(x0: float, y0: float, x1: float, y1: float) -> tuple[int, int, int, int]:
        return tuple(round(v * SCALE) for v in (x0, y0, x1, y1))

    # The screen: a white outline, a faint fill, and a small stand.
    screen = box(232, 270, 812, 676)
    outline = Image.new("L", (s, s), 0)
    d = ImageDraw.Draw(outline)
    d.rounded_rectangle(screen, radius=46 * SCALE, fill=255)
    d.rounded_rectangle(box(256, 294, 788, 652), radius=26 * SCALE, fill=0)
    fill = Image.new("L", (s, s), 0)
    ImageDraw.Draw(fill).rounded_rectangle(box(256, 294, 788, 652), radius=26 * SCALE, fill=38)
    stand = Image.new("L", (s, s), 0)
    sd = ImageDraw.Draw(stand)
    sd.rounded_rectangle(box(482, 676, 542, 736), radius=6 * SCALE, fill=255)
    sd.rounded_rectangle(box(402, 728, 622, 760), radius=16 * SCALE, fill=255)
    white = Image.new("RGBA", (s, s), (255, 255, 255, 255))
    art.paste(white, (0, 0), fill)
    art.paste(Image.new("RGBA", (s, s), (235, 242, 255, 255)), (0, 0), outline)
    art.paste(Image.new("RGBA", (s, s), (205, 218, 240, 255)), (0, 0), stand)

    # The launcher bar sliding out from the screen's left edge, with a soft glow.
    bar = box(286, 330, 384, 616)
    bar_mask = Image.new("L", (s, s), 0)
    ImageDraw.Draw(bar_mask).rounded_rectangle(bar, radius=30 * SCALE, fill=255)
    glow = bar_mask.filter(ImageFilter.GaussianBlur(26 * SCALE)).point(lambda v: round(v * 0.55))
    art.paste(Image.new("RGBA", (s, s), CYAN + (255,)), (0, 0), glow)
    gradient = vertical_gradient(bar[2] - bar[0], bar[3] - bar[1], CYAN, BLUE).convert("RGBA")
    layer = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    layer.paste(gradient, (bar[0], bar[1]))
    art.paste(layer, (0, 0), bar_mask)

    # Three app tiles in the bar.
    tiles = Image.new("L", (s, s), 0)
    td = ImageDraw.Draw(tiles)
    for top in (356, 440, 524):
        td.rounded_rectangle(box(308, top, 362, top + 54), radius=14 * SCALE, fill=255)
    art.paste(white, (0, 0), tiles)

    # A chevron pointing out of the edge: "it slides out".
    chevron = Image.new("L", (s, s), 0)
    ImageDraw.Draw(chevron).line(
        [tuple(round(v * SCALE) for v in p) for p in ((430, 423), (476, 473), (430, 523))],
        fill=255, width=22 * SCALE, joint="curve",
    )
    art.paste(Image.new("RGBA", (s, s), CYAN + (255,)), (0, 0), chevron)
    return art.resize((SIZE, SIZE), Image.LANCZOS)


def flat_icon(art: Image.Image) -> Image.Image:
    s = SIZE * SCALE
    body = (100, 100, 924, 924)  # 824-point body on the macOS grid
    mask = Image.new("L", (s, s), 0)
    ImageDraw.Draw(mask).rounded_rectangle(tuple(v * SCALE for v in body), radius=185 * SCALE, fill=255)
    mask = mask.resize((SIZE, SIZE), Image.LANCZOS)

    icon = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    shadow = mask.filter(ImageFilter.GaussianBlur(18)).point(lambda v: round(v * 0.45))
    icon.paste(Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 255)), (0, 12), shadow)
    background = vertical_gradient(SIZE, SIZE, SLATE, NAVY).convert("RGBA")
    icon.paste(background, (0, 0), mask)
    icon.alpha_composite(art)
    return icon


def main() -> None:
    art = glyph()
    (ROOT / "Resources/AppIcon.icon/Assets").mkdir(parents=True, exist_ok=True)
    art.save(ROOT / "Resources/AppIcon.icon/Assets/glyph.png")
    icon = flat_icon(art)
    icon.save(ROOT / "Resources/AppIcon-1024.png")
    (ROOT / "docs/images").mkdir(parents=True, exist_ok=True)
    icon.save(ROOT / "docs/images/echoedge-icon.png")
    print("Wrote glyph.png, AppIcon-1024.png and echoedge-icon.png")


if __name__ == "__main__":
    main()
