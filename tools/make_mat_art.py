"""
make_mat_art.py
Builds the playmat area images (assets/mats/mat_<area>_<Color>.png): a dark
plate with a glowing seat-colored border, corner ticks, a neon title and the
area's icon, same look as the tracker. The table lays each one flat on its
area (zones.lua). Re-run after changing an icon:
    python tools/make_mat_art.py
Area sizes must match REGIONS in src/table.lua.
"""
import os
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICONS = os.path.join(ROOT, "assets", "icons")
OUT = os.path.join(ROOT, "assets", "mats")
FONT = os.path.join(ROOT, "tools", "fonts", "Orbitron.ttf")

SEAT_RGB = {"White": (205, 212, 230), "Red": (230, 70, 80), "Green": (70, 220, 120), "Blue": (80, 150, 255)}

# area: (width, depth, title, icon file or None for the seat crown, icon size) in table units
AREAS = {
    "command1": (4.2, 5.5, "COMMANDER", None, 2.4),
    "command2": (4.2, 5.5, "PARTNER", None, 2.4),
    "battlefield": (28, 14, "BATTLEFIELD", "battlefield.png", 3.4),
    "lands": (39, 5.5, "LANDS", "lands.png", 2.6),
    "library": (6, 6.5, "LIBRARY", "library.png", 2.6),
    "graveyard": (6, 6.5, "GRAVEYARD", "graveyard.png", 2.6),
    "exile": (6, 6.5, "EXILE", "exile.png", 2.6),
}
MAX_PX = 2048


def font(px, weight=800):
    f = ImageFont.truetype(FONT, int(px))
    try:
        f.set_variation_by_axes([weight])
    except Exception:
        pass
    return f


def build(area, color):
    w, d, title, icon_file, icon_size = AREAS[area]
    ppu = min(110, MAX_PX / max(w, d))           # pixels per table unit
    W, H = int(w * ppu), int(d * ppu)
    rgb = SEAT_RGB[color]
    u = ppu / 100.0                               # style scale
    pad = max(4, int(8 * u))
    radius = int(min(W, H) * 0.08)

    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    mask = Image.new("L", (W, H), 0)
    ImageDraw.Draw(mask).rounded_rectangle([pad, pad, W - pad - 1, H - pad - 1], radius=radius, fill=255)
    panel = Image.new("RGBA", (W, H))
    pd = ImageDraw.Draw(panel)
    for y in range(H):
        t = y / H
        pd.line([(0, y), (W, y)], fill=(int(11 + 6 * t), int(14 + 7 * t), int(22 + 10 * t), 215))
    img.paste(panel, (0, 0), mask)

    grid = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    g = ImageDraw.Draw(grid)
    step = max(12, int(40 * u))
    for gx in range(step, W, step):
        g.line([(gx, 0), (gx, H)], fill=rgb + (12,))
    for gy in range(step, H, step):
        g.line([(0, gy), (W, gy)], fill=rgb + (12,))
    img.alpha_composite(Image.composite(grid, Image.new("RGBA", (W, H)), mask))

    bw = max(2, int(4 * u))
    border = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(border).rounded_rectangle([pad + 2, pad + 2, W - pad - 3, H - pad - 3],
                                             radius=max(4, radius - 2), outline=rgb + (255,), width=bw)
    glow = border.filter(ImageFilter.GaussianBlur(max(3, 8 * u)))
    img.alpha_composite(glow)
    img.alpha_composite(glow)
    img.alpha_composite(border)

    tick = int(min(W, H) * 0.12)
    off = pad + int(14 * u)
    t = ImageDraw.Draw(img)
    for (x0, y0, dx, dy) in [(off, off, 1, 1), (W - off - 1, off, -1, 1), (off, H - off - 1, 1, -1), (W - off - 1, H - off - 1, -1, -1)]:
        t.line([(x0, y0 + dy * tick), (x0, y0), (x0 + dx * tick, y0)], fill=rgb + (190,), width=max(2, int(3 * u)))

    # Title along the top (far edge from the player).
    tsize = min(0.5 * ppu, (W - 2 * off) / (len(title) * 0.95))
    f = font(tsize)
    ty = off + int(tsize * 0.95)
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(layer).text((W // 2, ty), title, font=f, fill=rgb + (255,), anchor="mm")
    img.alpha_composite(layer.filter(ImageFilter.GaussianBlur(max(2, 6 * u))))
    ImageDraw.Draw(img).text((W // 2, ty), title, font=f, fill=(235, 245, 255, 255), anchor="mm")

    # Icon in the middle (a little below center, under the title).
    path = os.path.join(ICONS, icon_file or "tracker_crown_%s.png" % color)
    ic = Image.open(path).convert("RGBA")
    s = int(min(icon_size * ppu, H - ty - off))
    ic = ic.resize((s, s), Image.LANCZOS)
    cy = (ty + H) // 2 if H < W * 0.5 else H // 2 + int(tsize * 0.4)
    img.alpha_composite(ic, (W // 2 - s // 2, cy - s // 2))

    os.makedirs(OUT, exist_ok=True)
    out = os.path.join(OUT, "mat_%s_%s.png" % (area, color))
    img.save(out)
    return out


# Action tiles beside the library column (actions.lua): 3.0 x 4.2 table units.
ACTIONS = {
    "draw": ("DRAW", "CLICK 1  /  RIGHT 3"),
    "scry": ("SCRY", "SURVEIL TOO"),
    "mill": ("MILL", "CLICK 1  /  RIGHT 3"),
    "untap": ("UNTAP", "ALL PERMANENTS"),
}
ACTION_W, ACTION_D, ACTION_PPU = 3.0, 4.2, 200


def build_action(name, color):
    title, hint = ACTIONS[name]
    W, H = int(ACTION_W * ACTION_PPU), int(ACTION_D * ACTION_PPU)
    rgb = SEAT_RGB[color]
    u = ACTION_PPU / 100.0
    pad, radius = 10, 60
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    mask = Image.new("L", (W, H), 0)
    ImageDraw.Draw(mask).rounded_rectangle([pad, pad, W - pad - 1, H - pad - 1], radius=radius, fill=255)
    panel = Image.new("RGBA", (W, H))
    pd = ImageDraw.Draw(panel)
    for y in range(H):
        t = y / H
        pd.line([(0, y), (W, y)], fill=(int(10 + 8 * t), int(13 + 9 * t), int(22 + 12 * t), 240))
    img.paste(panel, (0, 0), mask)
    border = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(border).rounded_rectangle([pad + 4, pad + 4, W - pad - 5, H - pad - 5],
                                             radius=radius - 4, outline=rgb + (255,), width=6)
    glow = border.filter(ImageFilter.GaussianBlur(12))
    img.alpha_composite(glow)
    img.alpha_composite(glow)
    img.alpha_composite(border)
    ic = Image.open(os.path.join(ICONS, "action_%s.png" % name)).convert("RGBA")
    s = int(W * 0.72)
    ic = ic.resize((s, s), Image.LANCZOS)
    img.alpha_composite(ic, ((W - s) // 2, int(H * 0.10)))
    f = font(108)
    ty = int(H * 0.76)
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(layer).text((W // 2, ty), title, font=f, fill=rgb + (255,), anchor="mm")
    img.alpha_composite(layer.filter(ImageFilter.GaussianBlur(9)))
    ImageDraw.Draw(img).text((W // 2, ty), title, font=f, fill=(235, 245, 255, 255), anchor="mm")
    ImageDraw.Draw(img).text((W // 2, int(H * 0.88)), hint, font=font(40, 600), fill=rgb + (230,), anchor="mm")
    os.makedirs(OUT, exist_ok=True)
    out = os.path.join(OUT, "action_%s_%s.png" % (name, color))
    img.save(out)
    return out


if __name__ == "__main__":
    for color in SEAT_RGB:
        for area in AREAS:
            print(build(area, color))
        for name in ACTIONS:
            print(build_action(name, color))
