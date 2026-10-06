"""Stack art (stack.lua): the STACK mat in the middle of the table and the
plate used for abilities whose source card has no picture.
Run: python tools/make_stack_art.py"""
import os
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FONT = os.path.join(ROOT, "tools", "fonts", "Orbitron.ttf")
OUT = os.path.join(ROOT, "assets", "stack")
CYAN = (90, 240, 255)


def font(px, weight=800):
    f = ImageFont.truetype(FONT, int(px))
    try:
        f.set_variation_by_axes([weight])
    except Exception:
        pass
    return f


def panel(W, H, radius, border, solid=True):
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    mask = Image.new("L", (W, H), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, W - 1, H - 1], radius=radius, fill=255)
    fill = Image.new("RGBA", (W, H))
    d = ImageDraw.Draw(fill)
    for y in range(H):
        t = y / H
        d.line([(0, y), (W, y)], fill=(int(9 + 7 * t), int(12 + 8 * t), int(20 + 12 * t), 255 if solid else 235))
    # faint grid
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


def glow_text(img, xy, text, f, color=CYAN, anchor="mm"):
    t = Image.new("RGBA", img.size, (0, 0, 0, 0))
    ImageDraw.Draw(t).text(xy, text, font=f, fill=color + (255,), anchor=anchor)
    img.alpha_composite(t.filter(ImageFilter.GaussianBlur(7)))
    ImageDraw.Draw(img).text(xy, text, font=f, fill=(235, 248, 255, 255), anchor=anchor)


# The mat: 8 x 11 table units at 60 px per unit.
def mat():
    PPU = 60
    W, H = int(8 * PPU), int(11 * PPU)
    img = panel(W, H, 40, 10)
    glow_text(img, (W / 2, 48), "THE STACK", font(46))
    ImageDraw.Draw(img).text((W / 2, 92), "DROP A SPELL HERE TO CAST IT", font=font(17, 600), fill=CYAN + (220,), anchor="mm")
    # The area the cards fan down (newest lowest, on top).
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([40, 120, W - 40, H - 76], radius=16, outline=(60, 90, 110, 255), width=2)
    ImageDraw.Draw(img).text((W / 2, H - 40), "NEWEST ON TOP - RESOLVES FIRST", font=font(15, 600),
                             fill=(140, 160, 180, 255), anchor="mm")
    return img


# Per-seat CAST mat above the tracker: 13 x 3 table units at 60 px per unit,
# bordered in the seat's color. A card dropped on it goes onto the stack.
SEAT_RGB = {"White": (220, 225, 235), "Red": (235, 80, 80), "Green": (70, 205, 110), "Blue": (80, 150, 245)}


def castzone(color):
    PPU = 60
    W, H = int(13 * PPU), int(3 * PPU)
    rgb = SEAT_RGB[color]
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    mask = Image.new("L", (W, H), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, W - 1, H - 1], radius=28, fill=255)
    fill = Image.new("RGBA", (W, H))
    d = ImageDraw.Draw(fill)
    for y in range(H):
        t = y / H
        d.line([(0, y), (W, y)], fill=(int(9 + 7 * t), int(12 + 8 * t), int(20 + 12 * t), 255))
    img.paste(fill, (0, 0), mask)
    b = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(b).rounded_rectangle([7, 7, W - 8, H - 8], radius=22, outline=rgb + (255,), width=5)
    img.alpha_composite(b.filter(ImageFilter.GaussianBlur(7)))
    img.alpha_composite(b)
    glow_text(img, (150, H / 2), "CAST", font(64), color=rgb)
    ImageDraw.Draw(img).text((290, H / 2 - 22), "DROP A SPELL HERE", font=font(26, 700), fill=(230, 240, 250, 255), anchor="lm")
    ImageDraw.Draw(img).text((290, H / 2 + 22), "IT GOES ON THE STACK  >>>", font=font(22, 600), fill=rgb + (230,), anchor="lm")
    return img


# Ability plate, card sized (2.5 x 3.5 at 100 px per unit).
def ability():
    W, H = 250, 350
    img = panel(W, H, 18, 6)
    glow_text(img, (W / 2, 40), "ABILITY", font(30))
    d = ImageDraw.Draw(img)
    d.line([(30, 70), (W - 30, 70)], fill=CYAN + (180,), width=2)
    return img


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    for name, fn in (("stack_mat", mat), ("ability", ability)):
        p = os.path.join(OUT, name + ".png")
        fn().save(p)
        print(p)
    for color in SEAT_RGB:
        p = os.path.join(OUT, "cast_%s.png" % color)
        castzone(color).save(p)
        print(p)
