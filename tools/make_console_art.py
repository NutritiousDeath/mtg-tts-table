"""
make_console_art.py
The console strip on the table edge in front of each seat (actions.lua): a dark plate with a glowing
seat-colored border and four cells. The labels are drawn live by the script.
    python tools/make_console_art.py
"""
import os, sys
from PIL import Image, ImageDraw, ImageFilter
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "assets", "ui")
SEAT_RGB = {"White": (205, 212, 230), "Red": (230, 70, 80), "Green": (70, 220, 120), "Blue": (80, 150, 255)}
PPU = 80
W, H = int(20 * PPU), int(2.0 * PPU)
for color, rgb in SEAT_RGB.items():
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    mask = Image.new("L", (W, H), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, W - 1, H - 1], radius=36, fill=255)
    panel = Image.new("RGBA", (W, H))
    pd = ImageDraw.Draw(panel)
    for y in range(H):
        t = y / H
        pd.line([(0, y), (W, y)], fill=(int(10 + 8 * t), int(13 + 9 * t), int(22 + 12 * t), 255))
    for i in (1, 2, 3):
        x = int(W * i / 4)
        pd.line([(x, 26), (x, H - 26)], fill=tuple(int(c * 0.45) for c in rgb) + (255,), width=3)
    img.paste(panel, (0, 0), mask)
    border = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(border).rounded_rectangle([8, 8, W - 9, H - 9], radius=30, outline=rgb + (255,), width=5)
    glow = border.filter(ImageFilter.GaussianBlur(8))
    img.alpha_composite(glow)
    img.alpha_composite(border)
    # solid alpha inside so TTS builds a clean shape
    a = img.split()[3].point(lambda v: 255 if v > 0 else 0)
    img.putalpha(Image.composite(Image.new("L", (W, H), 255), a, mask))
    p = os.path.join(OUT, "console_%s.png" % color)
    img.save(p)
    print(p)
