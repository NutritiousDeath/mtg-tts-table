"""Glowing seat-colour symbols for the Planechase dice tower (tools/unity/MTGDiceTowerBuilder.cs): the same mana
symbols as the stained glass (assets/glass/motifs/motif_<Colour>.svg), drawn white on transparent with a soft glow,
so the tower tints them in the active player's colour. Writes unity/Assets/MTG/Textures/emblem_<Colour>.png.
Run: python tools/make_tower_emblems.py   (needs: pip install cairosvg pillow)"""
import io
import os
import sys

import cairosvg
from PIL import Image, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "assets", "glass", "motifs")
OUT = os.path.join(ROOT, "unity", "Assets", "MTG", "Textures")
if len(sys.argv) > 2:
    SRC, OUT = sys.argv[1], sys.argv[2]
S = 256

for colour in ("White", "Blue", "Black", "Red", "Green"):
    png = cairosvg.svg2png(url=os.path.join(SRC, "motif_%s.svg" % colour), output_width=S - 40, output_height=S - 40)
    sym = Image.open(io.BytesIO(png)).convert("RGBA")
    # The motif is a dark symbol on a pale coloured disc: keep just the symbol.
    lum = sym.convert("L")
    alpha = Image.eval(lum, lambda v: 255 if v < 110 else 0)
    alpha = Image.composite(alpha, Image.new("L", sym.size, 0), sym.split()[3])
    white = Image.new("RGBA", sym.size, (255, 255, 255, 255))
    white.putalpha(alpha)
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    img.paste(white, (20, 20), white)
    glow = img.filter(ImageFilter.GaussianBlur(9))
    out = Image.alpha_composite(glow, glow)
    out = Image.alpha_composite(out, img)
    os.makedirs(OUT, exist_ok=True)
    out.save(os.path.join(OUT, "emblem_%s.png" % colour))
    print("emblem_%s.png" % colour)
