"""Mana chip art (mana.lua): one round neon chip per color, plus the per-seat
dispenser tile showing all six. Letters, not Wizards' mana symbols.
Run: python tools/make_mana_art.py"""
import os
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FONT = os.path.join(ROOT, "tools", "fonts", "Orbitron.ttf")
OUT = os.path.join(ROOT, "assets", "mana")

CHIPS = [  # key, letter, rim color, face color
    ("W", "W", (255, 244, 205), (70, 64, 46)),
    ("U", "U", (70, 160, 255), (14, 36, 70)),
    ("B", "B", (176, 120, 235), (34, 20, 52)),
    ("R", "R", (255, 86, 64), (66, 16, 12)),
    ("G", "G", (70, 225, 120), (12, 52, 26)),
    ("C", "C", (200, 210, 222), (40, 44, 52)),
]


def font(px):
    f = ImageFont.truetype(FONT, int(px))
    try:
        f.set_variation_by_axes([800])
    except Exception:
        pass
    return f


def chip(letter, rim, face, size=256, counter=True):
    S = size
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    # Solid disc (TTS cuts the token's shape from the alpha: keep it opaque).
    d.ellipse([4, 4, S - 5, S - 5], fill=(12, 14, 20, 255))
    d.ellipse([14, 14, S - 15, S - 15], fill=face + (255,))
    # Neon rim with glow, inside the disc so the edge stays solid.
    ring = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(ring).ellipse([18, 18, S - 19, S - 19], outline=rim + (255,), width=10)
    glow = ring.filter(ImageFilter.GaussianBlur(7))
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).ellipse([4, 4, S - 5, S - 5], fill=255)
    for layer in (glow, glow, ring):
        clipped = Image.new("RGBA", (S, S), (0, 0, 0, 0))
        clipped.paste(layer, (0, 0), Image.composite(layer.split()[3], Image.new("L", (S, S), 0), mask))
        img.alpha_composite(clipped)
    # Notches around the edge like a poker chip.
    for k in range(8):
        import math
        a = k * math.pi / 4
        cx, cy = S / 2 + math.cos(a) * (S / 2 - 11), S / 2 + math.sin(a) * (S / 2 - 11)
        d.ellipse([cx - 6, cy - 6, cx + 6, cy + 6], fill=rim + (255,))
    # Letter with glow. On the table chip the letter sits small at the top
    # and the middle stays dark for the count (drawn live by mana.lua).
    if counter:
        f, pos = font(S * 0.17), (S / 2, S * 0.25)
        ImageDraw.Draw(img).ellipse([S * 0.3, S * 0.34, S * 0.7, S * 0.74], fill=(8, 10, 16, 255))
    else:
        f, pos = font(S * 0.46), (S / 2, S / 2 + 4)
    t = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(t).text(pos, letter, font=f, fill=rim + (255,), anchor="mm")
    img.alpha_composite(t.filter(ImageFilter.GaussianBlur(max(2, S // 50))))
    ImageDraw.Draw(img).text(pos, letter, font=f, fill=(245, 250, 255, 255), anchor="mm")
    return img


# Dispenser tile: 6.4 x 4.4 table units at 80 px per unit, 3 x 2 chips.
TILE_W, TILE_D, PPU = 6.4, 4.4, 80
CHIP_SLOTS = []   # (key, x, z) in table units from the tile center; x right, z toward the player
for i, (key, *_rest) in enumerate(CHIPS):
    col, row = i % 3, i // 3
    CHIP_SLOTS.append((key, (col - 1) * 2.0, -0.55 + row * 1.85))


def tile():
    W, H = int(TILE_W * PPU), int(TILE_D * PPU)
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    mask = Image.new("L", (W, H), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, W - 1, H - 1], radius=36, fill=255)
    panel = Image.new("RGBA", (W, H))
    pd = ImageDraw.Draw(panel)
    for y in range(H):
        t = y / H
        pd.line([(0, y), (W, y)], fill=(int(10 + 8 * t), int(13 + 9 * t), int(22 + 12 * t), 255))
    img.paste(panel, (0, 0), mask)
    border = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(border).rounded_rectangle([6, 6, W - 7, H - 7], radius=32, outline=(90, 240, 255, 255), width=4)
    img.alpha_composite(border.filter(ImageFilter.GaussianBlur(5)))
    img.alpha_composite(border)
    ImageDraw.Draw(img).text((W / 2, 22), "MANA", font=font(22), fill=(90, 240, 255, 255), anchor="mm")
    for (key, letter, rim, face), (_, x, z) in zip(CHIPS, CHIP_SLOTS):
        c = chip(letter, rim, face, 128, counter=False)
        cx, cy = W / 2 + x * PPU, H / 2 + z * PPU
        img.alpha_composite(c, (int(cx - 64), int(cy - 64)))
    return img


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    for key, letter, rim, face in CHIPS:
        p = os.path.join(OUT, "chip_%s.png" % key)
        chip(letter, rim, face).save(p)
        print(p)
    p = os.path.join(OUT, "mana_tile.png")
    tile().save(p)
    print(p)
