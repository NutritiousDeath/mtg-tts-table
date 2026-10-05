"""
make_tracker_art.py
Builds the tracker tile images (assets/icons/tracker_bg_<layout>_<Color>.png)
from the individual icons. Re-run after changing any tracker icon:
    python tools/make_tracker_art.py
Layout must match TRACKER_LAYOUT in src/trackers.lua:
  image 1400 x 480 px = tile 14 x 4.8 table units (100 px per unit),
  x to the player's right, z toward the player (image down).
"""
import os
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICONS = os.path.join(ROOT, "assets", "icons")
W, H, PX = 1400, 480, 100

SEAT_RGB = {"White": (205, 212, 230), "Red": (230, 70, 80), "Green": (70, 220, 120), "Blue": (80, 150, 255)}
CROWN_ORDER = {"Blue": ["White", "Red", "Green"], "White": ["Blue", "Green", "Red"],
               "Red": ["Blue", "Green", "White"], "Green": ["Blue", "White", "Red"]}
LAYOUTS = {"four": ["White", "Red", "Green", "Blue"], "two": ["White", "Green"]}

HEART = (0.0, 0.0, 4.2)
POISON = (-5.0, 0.0, 1.8)
PLUS_MINUS_X, RING_R = 3.1, 0.42
CROWN_X, CROWN_SIZE = 4.7, 1.3
ROWS = {1: [0.0], 2: [-0.75, 0.75], 3: [-1.45, 0.0, 1.45]}


def to_px(x, z):
    return int(W / 2 + x * PX), int(H / 2 + z * PX)


def paste_icon(base, name, x, z, size):
    icon = Image.open(os.path.join(ICONS, name)).convert("RGBA")
    s = int(size * PX)
    icon = icon.resize((s, s), Image.LANCZOS)
    cx, cy = to_px(x, z)
    base.alpha_composite(icon, (cx - s // 2, cy - s // 2))


def plate(color):
    rgb = SEAT_RGB[color]
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    # Dark panel with a vertical gradient.
    panel = Image.new("RGBA", (W, H))
    d = ImageDraw.Draw(panel)
    for y in range(H):
        t = y / H
        c = (int(10 + 8 * t), int(13 + 9 * t), int(22 + 12 * t), 255)
        d.line([(0, y), (W, y)], fill=c)
    mask = Image.new("L", (W, H), 0)
    ImageDraw.Draw(mask).rounded_rectangle([6, 6, W - 7, H - 7], radius=38, fill=255)
    img.paste(panel, (0, 0), mask)
    # Faint grid.
    grid = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    g = ImageDraw.Draw(grid)
    for gx in range(40, W, 40):
        g.line([(gx, 0), (gx, H)], fill=rgb + (10,))
    for gy in range(40, H, 40):
        g.line([(0, gy), (W, gy)], fill=rgb + (10,))
    img.alpha_composite(Image.composite(grid, Image.new("RGBA", (W, H)), mask))
    # Neon border: blurred glow plus a crisp line.
    border = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(border).rounded_rectangle([10, 10, W - 11, H - 11], radius=34, outline=rgb + (255,), width=4)
    glow = border.filter(ImageFilter.GaussianBlur(8))
    img.alpha_composite(glow)
    img.alpha_composite(glow)
    img.alpha_composite(border)
    # Corner ticks.
    t = ImageDraw.Draw(img)
    for (x0, y0, dx, dy) in [(30, 30, 1, 1), (W - 31, 30, -1, 1), (30, H - 31, 1, -1), (W - 31, H - 31, -1, -1)]:
        t.line([(x0, y0 + dy * 40), (x0, y0), (x0 + dx * 40, y0)], fill=rgb + (200,), width=3)
    return img


def ring(img, x, z, rgb):
    cx, cy = to_px(x, z)
    r = int(RING_R * PX)
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(8, 10, 16, 230), outline=rgb + (255,), width=4)
    img.alpha_composite(layer.filter(ImageFilter.GaussianBlur(6)))
    img.alpha_composite(layer)


def build(layout, color):
    img = plate(color)
    rgb = SEAT_RGB[color]
    paste_icon(img, "tracker_heart.png", *HEART[:2], HEART[2])
    paste_icon(img, "tracker_poison.png", *POISON[:2], POISON[2])
    ring(img, -PLUS_MINUS_X, 0, rgb)
    ring(img, PLUS_MINUS_X, 0, rgb)
    opponents = [c for c in CROWN_ORDER[color] if c in LAYOUTS[layout] and c != color]
    for z, opp in zip(ROWS[len(opponents)], opponents):
        paste_icon(img, "tracker_crown_%s.png" % opp, CROWN_X, z, CROWN_SIZE)
    out = os.path.join(ICONS, "tracker_bg_%s_%s.png" % (layout, color))
    img.save(out)
    return out


if __name__ == "__main__":
    for layout, seats in LAYOUTS.items():
        for color in seats:
            print(build(layout, color))
