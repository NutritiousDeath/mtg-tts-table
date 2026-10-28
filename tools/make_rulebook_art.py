"""
make_rulebook_art.py
The glowing cover of the Commander rules book on the table (tools/unity/MTGRulesBookBuilder.cs):
    rulebook_title.png  white lines and lettering on black (drawn additive and tinted in the active player's
                        colour): a double border with corner knots like the playmat edges, COMMANDER across the
                        middle, RULES OF THE TABLE beneath, and a diamond rule between them
    rulebook_halo.png   the same, blurred wide: the soft glow that pulses round it
Output: unity/Assets/MTG/Textures/.  Font: tools/fonts/Orbitron.ttf (the table's font).
    python tools/make_rulebook_art.py
"""
import os
import sys
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "unity", "Assets", "MTG", "Textures")
FONT = sys.argv[2] if len(sys.argv) > 2 else os.path.join(ROOT, "tools", "fonts", "Orbitron.ttf")
W, H = 920, 1320          # the cover is 4.6 x 6.6 table units (200 px per unit)


def text_center(d, y, s, font, fill, spacing=0):
    w = d.textlength(s, font=font) + spacing * (len(s) - 1)
    x = (W - w) / 2
    for ch in s:
        d.text((x, y), ch, font=font, fill=fill)
        x += d.textlength(ch, font=font) + spacing


def draw(img):
    d = ImageDraw.Draw(img)
    white = (255, 255, 255)
    # Double border.
    d.rounded_rectangle([34, 34, W - 35, H - 35], radius=26, outline=white, width=7)
    d.rounded_rectangle([62, 62, W - 63, H - 63], radius=16, outline=(170, 170, 170), width=3)
    # Corner knots: a small diamond in each corner between the two borders.
    for cx, cy in ((48, 48), (W - 49, 48), (48, H - 49), (W - 49, H - 49)):
        r = 22
        d.polygon([(cx, cy - r), (cx + r, cy), (cx, cy + r), (cx - r, cy)], outline=white, fill=(0, 0, 0), width=4)
    # Lettering.
    size = 118
    big = ImageFont.truetype(FONT, size)
    while d.textlength("COMMANDER", font=big) + 16 > W - 210:
        size -= 2
        big = ImageFont.truetype(FONT, size)
    small = ImageFont.truetype(FONT, 46)
    text_center(d, 560, "COMMANDER", big, white, spacing=2)
    # Diamond rule.
    y = 735
    d.line([(150, y), (W // 2 - 40, y)], fill=white, width=4)
    d.line([(W // 2 + 40, y), (W - 150, y)], fill=white, width=4)
    d.polygon([(W // 2, y - 22), (W // 2 + 22, y), (W // 2, y + 22), (W // 2 - 22, y)], outline=white, width=4)
    text_center(d, 785, "RULES OF THE TABLE", small, (215, 215, 215), spacing=6)
    # A mana-pip ring at the top, five dots for the five colours.
    cx, cy = W // 2, 330
    d.ellipse([cx - 110, cy - 110, cx + 110, cy + 110], outline=white, width=5)
    import math
    for k in range(5):
        a = -math.pi / 2 + k * 2 * math.pi / 5
        px, py = cx + 72 * math.cos(a), cy + 72 * math.sin(a)
        d.ellipse([px - 16, py - 16, px + 16, py + 16], outline=white, width=4)
    d.ellipse([cx - 14, cy - 14, cx + 14, cy + 14], fill=white)
    # Bottom flourish.
    d.line([(250, 1060), (W - 250, 1060)], fill=(200, 200, 200), width=3)
    d.polygon([(W // 2, 1060 - 14), (W // 2 + 14, 1060), (W // 2, 1060 + 14), (W // 2 - 14, 1060)], fill=(0, 0, 0), outline=(200, 200, 200), width=3)


def main():
    os.makedirs(OUT, exist_ok=True)
    img = Image.new("RGB", (W, H), (0, 0, 0))
    draw(img)
    img.save(os.path.join(OUT, "rulebook_title.png"))
    halo = img.filter(ImageFilter.GaussianBlur(22))
    halo = Image.eval(halo, lambda v: min(255, int(v * 1.8)))
    halo.save(os.path.join(OUT, "rulebook_halo.png"))
    print("wrote", OUT)


if __name__ == "__main__":
    main()
