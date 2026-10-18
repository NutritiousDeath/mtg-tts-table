"""Draws the Banana token card (Kibo, Uktabi Prince) -> assets/tokens/banana.png.
Scryfall has no Banana token, so the table uses this picture (token_data.lua, img field)."""
import math, os
from PIL import Image, ImageDraw, ImageFont, ImageFilter

W, H = 488, 680
OUT = os.path.join(os.path.dirname(__file__), "..", "assets", "tokens", "banana.png")
SERIF_B = "/usr/share/fonts/truetype/dejavu/DejaVuSerif-Bold.ttf"
SERIF = "/usr/share/fonts/truetype/dejavu/DejaVuSerif.ttf"

img = Image.new("RGB", (W, H), (12, 12, 12))
d = ImageDraw.Draw(img)
# Silver-grey artifact frame.
d.rounded_rectangle((14, 14, W - 14, H - 14), 18, fill=(150, 156, 162))
d.rounded_rectangle((22, 22, W - 22, H - 22), 14, fill=(118, 124, 130))
# Name bar.
d.rounded_rectangle((30, 30, W - 30, 74), 10, fill=(206, 210, 214), outline=(60, 60, 60), width=2)
# Art box: warm jungle gradient.
ax0, ay0, ax1, ay1 = 36, 82, W - 36, 400
art = Image.new("RGB", (ax1 - ax0, ay1 - ay0))
ad = ImageDraw.Draw(art)
for y in range(art.height):
    k = y / art.height
    ad.line([(0, y), (art.width, y)], fill=(int(40 + 60 * k), int(90 + 50 * k), int(50 + 10 * k)))
# Soft leaves in the background.
for i in range(9):
    cx, cy = (i * 53) % art.width, 30 + (i * 97) % (art.height - 40)
    ad.ellipse((cx - 60, cy - 18, cx + 60, cy + 18), fill=(30 + i * 4, 110 + i * 5, 45))
art = art.filter(ImageFilter.GaussianBlur(6))
ad = ImageDraw.Draw(art)
# The banana: a curved body thickest in the middle, a smile shape.
cx, cy = art.width / 2, art.height / 2 - 70
R = 150
def body(off_scale, n=80):
    pts = []
    for i in range(n + 1):
        t = i / n
        a = math.radians(25 + 130 * t)
        th = 34 * math.sin(math.pi * t) ** 0.8 + 4
        r = R + off_scale * th
        pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return pts
outer, inner = body(1), body(-1)
shape = outer + inner[::-1]
ad.polygon([(x + 9, y + 11) for x, y in shape], fill=(20, 50, 25))
ad.polygon(shape, fill=(250, 214, 60), outline=(120, 90, 20))
hl = [(cx + (R - 14) * math.cos(math.radians(a)), cy + (R - 14) * math.sin(math.radians(a))) for a in range(45, 136, 3)]
ad.line(hl, fill=(255, 240, 150), width=7)
rib = [(cx + (R + 12) * math.cos(math.radians(a)), cy + (R + 12) * math.sin(math.radians(a))) for a in range(40, 141, 3)]
ad.line(rib, fill=(214, 168, 30), width=3)
# Stem (left end) and dark tip (right end).
sx, sy = outer[-1]
ad.polygon([(sx + 2, sy - 4), (sx - 26, sy - 30), (sx - 18, sy - 38), (sx + 10, sy - 10)], fill=(110, 80, 30))
tx, ty = outer[0]
ad.ellipse((tx - 9, ty - 9, tx + 5, ty + 5), fill=(70, 50, 25))
img.paste(art, (ax0, ay0))
d.rectangle((ax0, ay0, ax1, ay1), outline=(40, 40, 40), width=3)
# Type bar.
d.rounded_rectangle((30, 408, W - 30, 448), 10, fill=(206, 210, 214), outline=(60, 60, 60), width=2)
# Text box.
d.rounded_rectangle((38, 456, W - 38, H - 50), 8, fill=(232, 230, 222), outline=(70, 70, 70), width=2)
f_name = ImageFont.truetype(SERIF_B, 26)
f_type = ImageFont.truetype(SERIF_B, 21)
f_text = ImageFont.truetype(SERIF, 21)
f_small = ImageFont.truetype(SERIF, 13)
d.text((44, 38), "Banana", font=f_name, fill=(10, 10, 10))
d.text((44, 416), "Token Artifact", font=f_type, fill=(10, 10, 10))
lines = ["{T}, Sacrifice this artifact:", "Add {R} or {G}. You gain 2 life."]
y = 490
for ln in lines:
    d.text((54, y), ln, font=f_text, fill=(15, 15, 15))
    y += 34
d.text((44, H - 42), "Token for Kibo, Uktabi Prince  -  MTG table", font=f_small, fill=(230, 230, 230))
os.makedirs(os.path.dirname(OUT), exist_ok=True)
img.save(OUT)
print("wrote", OUT)
