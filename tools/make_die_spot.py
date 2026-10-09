"""Planar die spot (planechase.lua): a glowing cyan ring with a hexagon on a
transparent square. Writes assets/planechase/die_spot.png (512 x 512).
Run: python tools/make_die_spot.py"""
import math, os
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "assets", "planechase", "die_spot.png")
S = 512
C = (90, 240, 255)
layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(layer)
c = S / 2
d.ellipse([40, 40, S - 40, S - 40], outline=C + (255,), width=8)
d.ellipse([70, 70, S - 70, S - 70], outline=C + (140,), width=3)
r = 150
pts = [(c + r * math.cos(math.radians(60 * i + 30)), c + r * math.sin(math.radians(60 * i + 30))) for i in range(6)]
d.polygon(pts, outline=C + (230,), width=5)
for i in range(0, 360, 15):
    a = math.radians(i)
    d.line([(c + 205 * math.cos(a), c + 205 * math.sin(a)), (c + 222 * math.cos(a), c + 222 * math.sin(a))], fill=C + (180,), width=3)
fill = Image.new("RGBA", (S, S), (6, 10, 16, 150))
mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).ellipse([44, 44, S - 44, S - 44], fill=255)
base = Image.new("RGBA", (S, S), (0, 0, 0, 0))
base.paste(fill, (0, 0), mask)
glow = layer.filter(ImageFilter.GaussianBlur(9))
out = Image.alpha_composite(base, glow)
out = Image.alpha_composite(out, layer)
out.save(OUT)
print("wrote", OUT)
