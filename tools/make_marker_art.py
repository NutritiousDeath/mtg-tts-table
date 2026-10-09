"""Marker art for counters that belong to a player (effects.lua): the contract
counter (Miss Highwater). Writes assets/ui/contract.png (256 x 256).
Run: python tools/make_marker_art.py"""
import os
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FONT = os.path.join(ROOT, "tools", "fonts", "Orbitron.ttf")
OUT = os.path.join(ROOT, "assets", "ui", "contract.png")
S = 256
C = (255, 190, 70)

def font(px):
    f = ImageFont.truetype(FONT, px)
    try:
        f.set_variation_by_axes([800])
    except Exception:
        pass
    return f

layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(layer)
d.ellipse([8, 8, S - 8, S - 8], fill=(12, 14, 22, 235), outline=C + (255,), width=7)
d.ellipse([26, 26, S - 26, S - 26], outline=C + (140,), width=3)
# scroll
d.rounded_rectangle([64, 70, 192, 186], radius=10, outline=C + (255,), width=5, fill=(30, 26, 18, 255))
for y in (96, 116, 136, 156):
    d.line([(80, y), (176, y)], fill=C + (200,), width=4)
d.ellipse([52, 62, 76, 86], outline=C + (255,), width=4)
d.ellipse([180, 170, 204, 194], outline=C + (255,), width=4)
f = font(24)
w = d.textlength("CONTRACT", font=f)
d.text(((S - w) / 2, 200), "CONTRACT", font=f, fill=C + (255,))
glow = layer.filter(ImageFilter.GaussianBlur(6))
out = Image.alpha_composite(glow, layer)
out.save(OUT)
print("wrote", OUT)
