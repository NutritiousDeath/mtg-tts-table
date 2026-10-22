"""Planar Library / Planar Grave mats (planechase.lua): laid out beside the stack mat on UNPACK, in the same
style as the STACK mat. 5.4 x 4.6 table units at 100 px per unit; the label strip runs along the top
(the far side from White), the planar card sits in the area below it.
Writes assets/planechase/planar_library.png and planar_grave.png.
Run: python tools/make_planar_mats.py"""
import os
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FONT = os.path.join(ROOT, "tools", "fonts", "Orbitron.ttf")
OUT = os.path.join(ROOT, "assets", "planechase")
CYAN = (90, 240, 255)
PPU = 100
W, H = int(5.4 * PPU), int(4.6 * PPU)


def font(px, weight=800):
    f = ImageFont.truetype(FONT, int(px))
    try:
        f.set_variation_by_axes([weight])
    except Exception:
        pass
    return f


def panel(radius=36, border=9):
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    mask = Image.new("L", (W, H), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, W - 1, H - 1], radius=radius, fill=255)
    fill = Image.new("RGBA", (W, H))
    d = ImageDraw.Draw(fill)
    for y in range(H):
        t = y / H
        d.line([(0, y), (W, y)], fill=(int(9 + 7 * t), int(12 + 8 * t), int(20 + 12 * t), 255))
    for gx in range(0, W, 40):
        d.line([(gx, 0), (gx, H)], fill=(20, 26, 38, 255))
    for gy in range(0, H, 40):
        d.line([(0, gy), (W, gy)], fill=(20, 26, 38, 255))
    img.paste(fill, (0, 0), mask)
    b = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(b).rounded_rectangle([border, border, W - border - 1, H - border - 1], radius=radius - border,
                                        outline=CYAN + (255,), width=5)
    img.alpha_composite(b.filter(ImageFilter.GaussianBlur(8)))
    img.alpha_composite(b)
    return img


def glow_text(img, xy, text, f):
    t = Image.new("RGBA", img.size, (0, 0, 0, 0))
    ImageDraw.Draw(t).text(xy, text, font=f, fill=CYAN + (255,), anchor="mm")
    img.alpha_composite(t.filter(ImageFilter.GaussianBlur(6)))
    ImageDraw.Draw(img).text(xy, text, font=f, fill=(235, 248, 255, 255), anchor="mm")


def mat(title, sub, name):
    img = panel()
    glow_text(img, (W / 2, 44), title, font(34))
    d = ImageDraw.Draw(img)
    d.text((W / 2, 76), sub, font=font(14, 600), fill=CYAN + (210,), anchor="mm")
    # The card's place: a dashed outline the size of a landscape planar card (4.2 x 2.95 units).
    cw, ch = 4.4 * PPU, 3.1 * PPU
    x0, y0 = (W - cw) / 2, 92 + (H - 92 - ch) / 2
    x1, y1 = x0 + cw, y0 + ch
    dash = 18
    for x in range(int(x0), int(x1), dash * 2):
        d.line([(x, y0), (min(x + dash, x1), y0)], fill=CYAN + (120,), width=3)
        d.line([(x, y1), (min(x + dash, x1), y1)], fill=CYAN + (120,), width=3)
    for y in range(int(y0), int(y1), dash * 2):
        d.line([(x0, y), (x0, min(y + dash, y1))], fill=CYAN + (120,), width=3)
        d.line([(x1, y), (x1, min(y + dash, y1))], fill=CYAN + (120,), width=3)
    path = os.path.join(OUT, name)
    img.save(path)
    return path


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    print(mat("PLANAR LIBRARY", "THE NEXT PLANE COMES FROM HERE", "planar_library.png"))
    print(mat("PLANAR GRAVE", "RESHUFFLED WHEN THE LIBRARY RUNS OUT", "planar_grave.png"))
