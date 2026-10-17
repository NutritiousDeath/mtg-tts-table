"""Stained glass for the chapel windows (tools/make_room.py has the windows).

Output (into the Unity project, Assets/MTG/Glass/, given as argv[1]):
  glass_<design>.png   256 x 1024 RGBA pane images: dark lead lines, translucent coloured glass
  windows_four.json    every window of the four/two-seat chapel with its design, in game coordinates
  windows_2hg.json     the same for the Two-Headed Giant chapel
Designs: jewel_a / jewel_b / jewel_c (gothic jewel tones), broken_a / broken_b (some panes knocked
out), seat_White / seat_Blue / seat_Red / seat_Green (the window behind each seat leans to that colour,
with a motif: sun, drop, flame, leaf), corner (all five colours, a crescent moon for black).
Custom motifs: put SVGs or PNGs in assets/glass/motifs/ (see MOTIF_DIR) and they replace the built-in ones.
"""
import json
import os
import sys
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import make_room  # noqa: E402

W, H = 256, 1024
# Optional: your own medallion images, motif_White.png / motif_Blue.png / motif_Red.png / motif_Green.png /
# motif_Black.png (Black goes in the corner windows). Any colour without a file keeps the built-in design.
MOTIF_DIR = os.path.join(HERE, "..", "assets", "glass", "motifs")
SPRING_V = 0.80          # arch spring as a fraction of the window height
LEAD = (14, 12, 18)

PAL = {
    "jewel": [((0.45, 0.12, 0.75), 3), ((0.12, 0.25, 0.85), 3), ((0.75, 0.08, 0.15), 2), ((0.05, 0.55, 0.30), 2),
              ((0.95, 0.65, 0.10), 1), ((0.25, 0.05, 0.40), 2)],
    "White": [((0.96, 0.92, 0.74), 3), ((0.95, 0.80, 0.35), 3), ((0.88, 0.88, 0.95), 2), ((0.55, 0.70, 0.95), 1)],
    "Blue": [((0.10, 0.25, 0.80), 3), ((0.25, 0.55, 0.95), 3), ((0.08, 0.55, 0.70), 2), ((0.85, 0.90, 1.00), 1)],
    "Red": [((0.80, 0.08, 0.10), 3), ((0.95, 0.45, 0.10), 2), ((0.50, 0.02, 0.05), 2), ((0.98, 0.78, 0.25), 1)],
    "Green": [((0.05, 0.60, 0.25), 3), ((0.35, 0.75, 0.20), 2), ((0.02, 0.35, 0.15), 2), ((0.95, 0.80, 0.30), 1)],
    "Black": [((0.22, 0.05, 0.30), 3), ((0.10, 0.06, 0.14), 2), ((0.45, 0.12, 0.55), 1)],
}
MOTIF_COLOR = {"White": (1.0, 0.85, 0.35), "Blue": (0.55, 0.85, 1.0), "Red": (1.0, 0.55, 0.12),
               "Green": (0.55, 0.95, 0.35), "Black": (0.85, 0.80, 1.0)}


def lancet_mask():
    """1 inside the pointed window outline (pixel space, v up = row 0 at the top)."""
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    u = (xx + 0.5) / W - 0.5            # -0.5 .. 0.5
    v = 1 - (yy + 0.5) / H              # 0 bottom .. 1 top
    half = np.full_like(u, 0.5)
    # pointed top: two arcs. Work in units where the width is 1 and the height is H/W.
    hgt = H / W
    sp, ap = SPRING_V * hgt, hgt
    hh = ap - sp
    R = (0.25 + hh * hh) / 1.0
    cx = 0.5 - R
    y = v * hgt
    above = y > sp
    dy = np.clip(y - sp, 0, None)
    arc = cx + np.sqrt(np.clip(R * R - dy * dy, 0, None))
    half = np.where(above, np.clip(arc, 0, None), half)
    return (np.abs(u) <= half), u, v


def pick(rng, pal):
    cols, wts = zip(*pal)
    wts = np.array(wts, float)
    return np.array(cols[rng.choice(len(cols), p=wts / wts.sum())])


def voronoi_panes(rng, region, n, pal, img, alpha, lead_px=2.2):
    """Fill `region` (bool mask) with n glass cells and lead lines between them."""
    ys, xs = np.nonzero(region)
    if len(xs) == 0:
        return
    idx = rng.choice(len(xs), size=min(n, len(xs)), replace=False)
    seeds = np.stack([xs[idx], ys[idx]], 1).astype(np.float32)
    colors = np.array([pick(rng, pal) for _ in seeds])
    pts = np.stack([xs, ys], 1).astype(np.float32)
    d = ((pts[:, None, :] - seeds[None, :, :]) ** 2).sum(-1)
    order = np.argsort(d, axis=1)
    d1 = np.sqrt(d[np.arange(len(pts)), order[:, 0]])
    d2 = np.sqrt(d[np.arange(len(pts)), order[:, 1]]) if len(seeds) > 1 else d1 + 99
    c = colors[order[:, 0]]
    shade = 0.85 + 0.3 * rng.random(len(seeds))[order[:, 0]]
    c = np.clip(c * shade[:, None], 0, 1)
    edge = (d2 - d1) < lead_px
    img[ys, xs, :3] = np.where(edge[:, None], np.array(LEAD) / 255.0, c)
    img[ys, xs, 3] = np.where(edge, 0.95, alpha + 0.08 * (rng.random(len(xs)) - 0.5))


def draw_lead(img, mask_fn, width):
    pass


def custom_motif(colour):
    """Your own medallion image for a colour, if there is one: motif_<Colour>.svg (rendered) or .png."""
    if not MOTIF_DIR:
        return None
    svg = os.path.join(MOTIF_DIR, "motif_" + colour + ".svg")
    png = os.path.join(MOTIF_DIR, "motif_" + colour + ".png")
    if os.path.exists(svg):
        import io
        import cairosvg   # pip install cairosvg
        data = cairosvg.svg2png(url=svg, output_width=512, output_height=512)
        return Image.open(io.BytesIO(data)).convert("RGBA")
    if os.path.exists(png):
        return Image.open(png).convert("RGBA")
    return None


def motif_layer(kind):
    """A motif drawn as a (W x W) RGBA image, centred: sun, drop, flame, leaf or crescent."""
    s = W
    im = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    c = tuple(int(x * 255) for x in MOTIF_COLOR[kind]) + (235,)
    lead = LEAD + (245,)
    m = s / 2
    if kind == "White":                          # sun: disc + rays
        for i in range(12):
            a = i * np.pi / 6
            p = [(m + np.cos(a - 0.12) * 40, m + np.sin(a - 0.12) * 40), (m + np.cos(a) * 92, m + np.sin(a) * 92),
                 (m + np.cos(a + 0.12) * 40, m + np.sin(a + 0.12) * 40)]
            d.polygon(p, fill=c, outline=lead)
        d.ellipse([m - 42, m - 42, m + 42, m + 42], fill=c, outline=lead, width=5)
    elif kind == "Blue":                         # water drop
        pts = []
        for i in range(60):
            t = i / 59 * 2 * np.pi
            x = np.sin(t) * 55 * (1 - 0.0 * np.cos(t))
            y = -np.cos(t) * 70
            if y < 0:
                x *= (1 + y / 70) ** 1.6 + 0.0001
            pts.append((m + x, m + 10 + y))
        d.polygon(pts, fill=c, outline=lead, width=5)
        d.ellipse([m - 18, m + 5, m - 2, m + 30], fill=(235, 245, 255, 220))
    elif kind == "Red":                          # flame: three tongues
        for off, hgt, wd in ((-26, 80, 30), (26, 70, 28), (0, 100, 40)):
            pts = []
            for i in range(40):
                t = i / 39
                x = np.sin(t * np.pi) * wd * (1 - t) ** 0.4
                pts.append((m + off + x, m + 60 - t * hgt * 1.4))
            for i in range(39, -1, -1):
                t = i / 39
                x = np.sin(t * np.pi) * wd * (1 - t) ** 0.4
                pts.append((m + off - x, m + 60 - t * hgt * 1.4))
            d.polygon(pts, fill=c, outline=lead, width=4)
    elif kind == "Green":                        # leaf with veins
        pts = []
        for i in range(60):
            t = i / 59
            x = np.sin(t * np.pi) * 48
            pts.append((m + x, m + 80 - t * 160))
        for i in range(59, -1, -1):
            t = i / 59
            x = np.sin(t * np.pi) * 48
            pts.append((m - x, m + 80 - t * 160))
        d.polygon(pts, fill=c, outline=lead, width=5)
        d.line([(m, m + 90), (m, m - 70)], fill=lead, width=5)
        for k in range(-3, 4):
            y = m + k * 20
            d.line([(m, y), (m + 30, y - 22)], fill=lead, width=3)
            d.line([(m, y), (m - 30, y - 22)], fill=lead, width=3)
    elif kind == "Black":                        # crescent moon
        d.ellipse([m - 70, m - 70, m + 70, m + 70], fill=c, outline=lead, width=5)
        d.ellipse([m - 40, m - 85, m + 95, m + 50], fill=(0, 0, 0, 0))
        d.arc([m - 40, m - 85, m + 95, m + 50], 100, 260, fill=lead, width=5)
    return im


def make(design, seed):
    rng = np.random.default_rng(seed)
    img = np.zeros((H, W, 4), np.float32)
    inside, u, v = lancet_mask()
    # tracery regions: two sub-lancets below, a round medallion above, filler around
    rose_c = (0.0, 0.70)                 # medallion centre (u, v)
    rose_r = 0.30                        # in width units
    du = u - rose_c[0]
    dv = (v - rose_c[1]) * (H / W)
    in_rose = (du * du + dv * dv) < rose_r * rose_r
    mull = np.abs(u) < 0.018
    sub_top = 0.52
    sub = (v < sub_top) & inside & ~mull
    # pointed tops for the two sub-lancets
    for sgn in (-1, 1):
        cu = sgn * 0.25
        half = 0.22
        dy = (v - (sub_top - 0.08)) * (H / W)
        arc = (half - 0.0) - np.clip(dy, 0, None) ** 2 * 3.2
        sub |= inside & (np.abs(u - cu) < np.clip(arc, 0, None)) & (v >= sub_top - 0.08) & (v < sub_top + 0.06) & ~mull
    filler = inside & ~sub & ~in_rose & ~mull
    if design.startswith("seat_"):
        col = design[5:]
        pal_main, pal_rose = PAL[col], PAL["jewel"]
    elif design == "corner":
        pal_main, pal_rose = None, PAL["Black"]
    else:
        pal_main, pal_rose = PAL["jewel"], PAL["jewel"]
    alpha = 0.42
    if design == "corner":
        # five vertical-ish bands of colour, one per Magic colour
        bands = ["White", "Blue", "Black", "Red", "Green"]
        for i, b in enumerate(bands):
            reg = (sub | filler) & (u >= -0.5 + i / 5) & (u < -0.5 + (i + 1) / 5)
            voronoi_panes(rng, reg, 12, PAL[b], img, alpha)
    else:
        voronoi_panes(rng, sub, 46, pal_main, img, alpha)
        voronoi_panes(rng, filler, 22, pal_main, img, alpha)
    voronoi_panes(rng, in_rose & inside, 10 if design.startswith(("seat_", "corner")) else 16, pal_rose, img, alpha + 0.05)
    # lead between the tracery regions (sub-lancets / filler / medallion)
    rid = np.zeros((H, W), np.int8)
    rid[sub] = 1
    rid[filler] = 2
    rid[in_rose & inside] = 3
    bnd = np.zeros((H, W), bool)
    for dy_, dx_ in ((0, 1), (1, 0), (0, -1), (-1, 0), (0, 2), (2, 0)):
        bnd |= (np.roll(np.roll(rid, dy_, 0), dx_, 1) != rid)
    bnd &= inside & (rid > 0)
    img[bnd, :3] = np.array(LEAD) / 255
    img[bnd, 3] = 0.97
    # lead: mullion, outline, medallion ring
    img[mull & inside, :3] = np.array(LEAD) / 255
    img[mull & inside, 3] = 0.97
    ring = inside & (np.abs(np.sqrt(du * du + dv * dv) - rose_r) < 0.018)
    img[ring, :3] = np.array(LEAD) / 255
    img[ring, 3] = 0.97
    # outer lead frame: pixels inside within a few px of the outline
    pil_in = Image.fromarray((inside * 255).astype(np.uint8)).filter(ImageFilter.MinFilter(9))
    frame = inside & (np.asarray(pil_in) < 128)
    img[frame, :3] = np.array(LEAD) / 255
    img[frame, 3] = 0.98
    # motif in the medallion
    out = Image.fromarray((np.clip(img, 0, 1) * 255).astype(np.uint8), "RGBA")
    motif = None
    if design.startswith("seat_"):
        motif = design[5:]
    elif design == "corner":
        motif = "Black"
    if motif:
        src = custom_motif(motif)
        if src is not None:
            # your own image for this colour (assets/glass/motifs/motif_<Colour>.svg or .png), fitted into the medallion
            k = (W * 0.62) / max(src.width, src.height)
            mi = src.resize((max(1, int(src.width * k)), max(1, int(src.height * k))), Image.LANCZOS)
        else:
            mi = motif_layer(motif).resize((int(W * 0.78), int(W * 0.78)), Image.LANCZOS)
        cx, cy = W // 2, int((1 - rose_c[1]) * H)
        out.alpha_composite(mi, (cx - mi.width // 2, cy - mi.height // 2))
    if design.startswith("broken"):
        # a jagged hole where panes have fallen out
        a = np.asarray(out).copy()
        hole = Image.new("L", (W, H), 0)
        hd = ImageDraw.Draw(hole)
        cx = W * (0.3 if design == "broken_a" else 0.7)
        cy = H * (0.62 if design == "broken_a" else 0.30)
        pts = []
        for i in range(18):
            t = i / 18 * 2 * np.pi
            r = (70 + rng.uniform(-35, 45))
            pts.append((cx + np.cos(t) * r * 0.9, cy + np.sin(t) * r * 2.0))
        hd.polygon(pts, fill=255)
        h = np.asarray(hole) > 0
        keep_lead = (a[..., 0] < 30) & (a[..., 3] > 230) & (rng.random(h.shape) < 0.5)
        a[h & ~keep_lead, 3] = 0
        out = Image.fromarray(a, "RGBA")
    return out


DESIGNS = ["jewel_a", "jewel_b", "jewel_c", "broken_a", "broken_b", "seat_White", "seat_Blue", "seat_Red",
           "seat_Green", "corner"]


def seats(layout):
    if layout == "four":
        return {"White": (0, -50), "Red": (-50, 0), "Green": (0, 50), "Blue": (50, 0)}
    return {"White": (-29, -50), "Red": (29, -50), "Green": (-29, 50), "Blue": (29, 50)}


def assign(layout):
    ws = make_room.windows(layout)
    out = []
    taken = {}
    for colour, (sx, sz) in seats(layout).items():
        # the window straight out behind the seat
        best, bd = None, 1e9
        for i, w in enumerate(ws):
            if w["kind"] != "wall":
                continue
            # behind = same side of the table, closest along the wall
            if abs(sx) > abs(sz) and np.sign(w["x"]) != np.sign(sx) or abs(sz) >= abs(sx) and np.sign(w["z"]) != np.sign(sz):
                continue
            if abs(sz) >= abs(sx) and abs(w["z"]) < 100 or abs(sx) > abs(sz) and abs(w["x"]) < 100:
                continue
            dd = (w["x"] - sx) ** 2 + (w["z"] - sz) ** 2
            if dd < bd:
                best, bd = i, dd
        taken[best] = "seat_" + colour
    jewels = ["jewel_a", "jewel_b", "jewel_c"]
    broken = {3: "broken_a", 14: "broken_b"}
    k = 0
    for i, w in enumerate(ws):
        if i in taken:
            d = taken[i]
        elif w["kind"] == "corner":
            d = "corner"
        elif i in broken:
            d = broken[i]
        else:
            d = jewels[k % 3]
            k += 1
        o = {key: float(val) if not isinstance(val, str) else val for key, val in w.items()}
        o["design"] = d
        out.append(o)
    return out


if __name__ == "__main__":
    dest = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "assets", "glass")
    os.makedirs(dest, exist_ok=True)
    for i, dsg in enumerate(DESIGNS):
        make(dsg, 100 + i).save(os.path.join(dest, "glass_" + dsg + ".png"))
    for layout, name in (("four", "windows_four.json"), ("twohg", "windows_2hg.json")):
        with open(os.path.join(dest, name), "w") as fh:
            json.dump({"windows": assign(layout)}, fh, indent=1)
    print("done")
