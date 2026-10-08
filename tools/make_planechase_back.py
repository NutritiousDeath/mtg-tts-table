"""Planar card back (planechase.lua): a landscape card back in the table's
dark cyan style. Writes assets/planechase/back.png (936 x 672, like a plane
card picture). Run: python tools/make_planechase_back.py"""
import os
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FONT = os.path.join(ROOT, "tools", "fonts", "Orbitron.ttf")
OUT = os.path.join(ROOT, "assets", "planechase")
CYAN = (90, 240, 255)
W, H = 936, 672


def font(px, weight=800):
    f = ImageFont.truetype(FONT, int(px))
    try:
        f.set_variation_by_axes([weight])
    except Exception:
        pass
    return f


img = Image.new("RGB", (W, H), (8, 11, 18))
d = ImageDraw.Draw(img)
for y in range(H):
    t = y / H
    d.line([(0, y), (W, y)], fill=(int(8 + 8 * t), int(11 + 9 * t), int(18 + 14 * t)))
# faint hex-ish grid
for x in range(0, W, 48):
    d.line([(x, 0), (x, H)], fill=(14, 22, 32))
for y in range(0, H, 48):
    d.line([(0, y), (W, y)], fill=(14, 22, 32))
glow = Image.new("RGB", (W, H), (0, 0, 0))
g = ImageDraw.Draw(glow)
for inset, width in ((22, 6), (46, 3)):
    g.rounded_rectangle([inset, inset, W - inset, H - inset], radius=28, outline=CYAN, width=width)
g.ellipse([W / 2 - 150, H / 2 - 150, W / 2 + 150, H / 2 + 150], outline=CYAN, width=6)
g.ellipse([W / 2 - 100, H / 2 - 100, W / 2 + 100, H / 2 + 100], outline=CYAN, width=3)
import math
for a in (45, 135, 225, 315, 90, 270):
    r0, r1 = 150, 230
    g.line([(W / 2 + r0 * math.cos(math.radians(a)), H / 2 + r0 * math.sin(math.radians(a))),
            (W / 2 + r1 * math.cos(math.radians(a)), H / 2 + r1 * math.sin(math.radians(a)))], fill=CYAN, width=4)
blur = glow.filter(ImageFilter.GaussianBlur(10))
img = Image.composite(img, img, Image.new("L", (W, H), 255))
from PIL import ImageChops
img = ImageChops.add(img, blur)
img = ImageChops.add(img, glow.point(lambda v: int(v * 0.85)))
d = ImageDraw.Draw(img)
text = "PLANAR"
f = font(74)
bb = d.textbbox((0, 0), text, font=f)
d.text(((W - (bb[2] - bb[0])) / 2, H / 2 - 48), text, font=f, fill=(225, 250, 255))
f2 = font(30, 600)
t2 = "PLANECHASE"
bb = d.textbbox((0, 0), t2, font=f2)
d.text(((W - (bb[2] - bb[0])) / 2, H / 2 + 46), t2, font=f2, fill=CYAN)
os.makedirs(OUT, exist_ok=True)
img.save(os.path.join(OUT, "back.png"))
print("back.png written")
