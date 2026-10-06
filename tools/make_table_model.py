"""3D table frame (table.lua): a gothic stone rim around the flat 100 x 100
play surface, spired pillars at the corners, and a pedestal going down into
the mist. Writes assets/table/frame.obj and assets/table/stone.png (a
tileable dark stone texture with faint cyan cracks). Units are TTS units;
the play surface's top is at y = 1.0 and the model sits around it.
The frame has no real collision: table.lua gives it assets/table/collider.obj,
a tiny cube far below the table (TTS turned the full shape into one big
invisible box that cards landed on).
Run: python tools/make_table_model.py"""
import math
import os
import numpy as np
from PIL import Image, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "assets", "table")
TOP = 1.0          # play surface top
HALF = 50.0        # play surface half size
RIM = 4.0          # rim width
TILE = 8.0         # texture repeats every TILE units

V, VT, F = [], [], []


def quad(a, b, c, d):
    """Planar quad a-b-c-d (counter-clockwise seen from outside), UVs from
    the face's dominant plane so the stone texture tiles evenly."""
    a, b, c, d = map(np.array, (a, b, c, d))
    n = np.cross(b - a, d - a)
    ax = np.argmax(np.abs(n))
    idx = []
    for p in (a, b, c, d):
        if ax == 0:
            u, v = p[2], p[1]
        elif ax == 1:
            u, v = p[0], p[2]
        else:
            u, v = p[0], p[1]
        V.append(p)
        VT.append((u / TILE, v / TILE))
        idx.append(len(V))
    F.append(idx)


def tri(a, b, c):
    a, b, c = map(np.array, (a, b, c))
    n = np.cross(b - a, c - a)
    ax = np.argmax(np.abs(n))
    idx = []
    for p in (a, b, c):
        u, v = ((p[2], p[1]) if ax == 0 else (p[0], p[2]) if ax == 1 else (p[0], p[1]))
        V.append(p)
        VT.append((u / TILE, v / TILE))
        idx.append(len(V))
    F.append(idx)


def box(x0, x1, y0, y1, z0, z1, bottom=True):
    p = lambda x, y, z: (x, y, z)
    quad(p(x0, y1, z0), p(x0, y1, z1), p(x1, y1, z1), p(x1, y1, z0))       # top
    if bottom:
        quad(p(x0, y0, z0), p(x1, y0, z0), p(x1, y0, z1), p(x0, y0, z1))   # bottom
    quad(p(x0, y0, z0), p(x0, y1, z0), p(x1, y1, z0), p(x1, y0, z0))       # -z
    quad(p(x1, y0, z1), p(x1, y1, z1), p(x0, y1, z1), p(x0, y0, z1))       # +z
    quad(p(x0, y0, z1), p(x0, y1, z1), p(x0, y1, z0), p(x0, y0, z0))       # -x
    quad(p(x1, y0, z0), p(x1, y1, z0), p(x1, y1, z1), p(x1, y0, z1))       # +x


def pyramid(cx, cz, half, y0, y1):
    a, b, c, d = (cx - half, y0, cz - half), (cx + half, y0, cz - half), (cx + half, y0, cz + half), (cx - half, y0, cz + half)
    tip = (cx, y1, cz)
    tri(a, tip, b)
    tri(b, tip, c)
    tri(c, tip, d)
    tri(d, tip, a)


def frustum(cx, cz, h0, h1, y0, y1):
    """Square column narrowing from half-size h0 at y0 to h1 at y1."""
    lo = [(cx - h0, y0, cz - h0), (cx + h0, y0, cz - h0), (cx + h0, y0, cz + h0), (cx - h0, y0, cz + h0)]
    hi = [(cx - h1, y1, cz - h1), (cx + h1, y1, cz - h1), (cx + h1, y1, cz + h1), (cx - h1, y1, cz + h1)]
    for i in range(4):
        j = (i + 1) % 4
        quad(lo[i], hi[i], hi[j], lo[j])


# --- Rim: four slabs around the surface, raised a little above it, with an
# inner chamfer down to the play surface.
lip = TOP + 0.6
bot = TOP - 2.0
O = HALF + RIM
for s in (-1, 1):
    # along x (north/south sides)
    box(-O, O, bot, lip, s * HALF if s > 0 else -O, O if s > 0 else -HALF)
    box(s * HALF if s > 0 else -O, O if s > 0 else -HALF, bot, lip, -HALF, HALF)
# Inner chamfer strips (from the lip down to the surface edge)
c = 0.6
for s in (-1, 1):
    quad((-HALF, TOP, s * HALF), (HALF, TOP, s * HALF), (HALF + c, lip, s * (HALF + c)), (-HALF - c, lip, s * (HALF + c))) if s < 0 else \
        quad((HALF, TOP, s * HALF), (-HALF, TOP, s * HALF), (-HALF - c, lip, s * (HALF + c)), (HALF + c, lip, s * (HALF + c)))
    quad((s * HALF, TOP, HALF), (s * HALF, TOP, -HALF), (s * (HALF + c), lip, -HALF - c), (s * (HALF + c), lip, HALF + c)) if s < 0 else \
        quad((s * HALF, TOP, -HALF), (s * HALF, TOP, HALF), (s * (HALF + c), lip, HALF + c), (s * (HALF + c), lip, -HALF - c))

# --- Small gothic spikes along the outer edge of the rim (low, so they don't
# block the view), skipping the corners where the pillars stand.
for k in np.arange(-HALF + 9, HALF - 8, 6.0):
    for (cx, cz) in ((k, O - 0.7), (k, -O + 0.7), (O - 0.7, k), (-O + 0.7, k)):
        box(cx - 0.45, cx + 0.45, lip, lip + 0.5, cz - 0.45, cz + 0.45, bottom=False)
        pyramid(cx, cz, 0.45, lip + 0.5, lip + 1.6)

# --- Corner pillars with spires and four pinnacles each.
P = O - 1.5
for sx in (-1, 1):
    for sz in (-1, 1):
        cx, cz = sx * P, sz * P
        box(cx - 4.2, cx + 4.2, bot, lip + 0.8, cz - 4.2, cz + 4.2)                 # plinth
        box(cx - 3.0, cx + 3.0, lip + 0.8, lip + 8.0, cz - 3.0, cz + 3.0, bottom=False)   # shaft
        for ox in (-1, 1):                                                           # corner buttresses
            for oz in (-1, 1):
                bx, bz = cx + ox * 3.0, cz + oz * 3.0
                frustum(bx, bz, 0.9, 0.5, lip + 0.8, lip + 9.0)
                pyramid(bx, bz, 0.5, lip + 9.0, lip + 11.5)
        box(cx - 3.4, cx + 3.4, lip + 8.0, lip + 8.8, cz - 3.4, cz + 3.4)          # cornice
        box(cx - 2.2, cx + 2.2, lip + 8.8, lip + 12.0, cz - 2.2, cz + 2.2, bottom=False)  # belfry
        for ox in (-1, 1):                                                           # pinnacles
            for oz in (-1, 1):
                px, pz = cx + ox * 2.6, cz + oz * 2.6
                box(px - 0.4, px + 0.4, lip + 8.8, lip + 10.0, pz - 0.4, pz + 0.4, bottom=False)
                pyramid(px, pz, 0.4, lip + 10.0, lip + 13.0)
        pyramid(cx, cz, 2.2, lip + 12.0, lip + 22.0)                                # main spire

# --- Under the table: a thick slab, then a pedestal flaring down into the mist.
box(-HALF, HALF, bot - 1.5, bot, -HALF, HALF)
frustum(0, 0, 30, 14, bot - 1.5, bot - 6)
frustum(0, 0, 14, 10, bot - 6, bot - 24)
frustum(0, 0, 10, 22, bot - 24, bot - 30)
for sx in (-1, 1):
    for sz in (-1, 1):
        # buttress legs under each corner
        frustum(sx * 40, sz * 40, 3.0, 2.0, bot - 1.5, bot - 26)

# --- Write OBJ (y up, like TTS).
os.makedirs(OUT, exist_ok=True)
with open(os.path.join(OUT, "frame.obj"), "w") as f:
    f.write("# MTG table frame (tools/make_table_model.py)\n")
    for v in V:
        f.write("v %.4f %.4f %.4f\n" % (v[0], v[1], v[2]))
    for t in VT:
        f.write("vt %.5f %.5f\n" % (t[0], t[1]))
    for face in F:
        f.write("f " + " ".join("%d/%d" % (i, i) for i in face) + "\n")
print("frame.obj:", len(V), "vertices,", len(F), "faces")

# --- Texture: tileable dark carved stone blocks, mortar lines, and faint
# cyan glow in some of the joints and cracks.
S = 1024
rng = np.random.default_rng(3)


def tile_noise(scale, seed):
    r = np.random.default_rng(seed)
    g = r.random((scale, scale))
    tiled = np.tile(g, (3, 3))
    im = Image.fromarray((tiled * 255).astype(np.uint8)).resize((S * 3, S * 3), Image.BICUBIC)
    return np.asarray(im.crop((S, S, 2 * S, 2 * S))).astype(float) / 255


n = sum(tile_noise(k, i) / (i + 1) for i, k in enumerate((4, 8, 16, 32, 64, 128)))
n = (n - n.min()) / (n.max() - n.min())
yy, xx = np.mgrid[0:S, 0:S]
ROWS, COLS = 8, 4
bh, bw = S // ROWS, S // COLS
row = yy // bh
off = (row % 2) * (bw // 2)
bx = (xx + off) % S // bw
# per-block tone so blocks read as separate stones
tone = np.random.default_rng(9).random((ROWS, COLS + 1))
blockTone = tone[row, bx]
stone = np.stack([12 + 30 * n + 14 * blockTone, 13 + 32 * n + 15 * blockTone, 19 + 38 * n + 18 * blockTone], axis=-1)
# bevel: darken near block edges, lighten the top edge slightly
ey = (yy % bh) / bh
ex = ((xx + off) % bw) / bw
edge = np.minimum.reduce([ey, 1 - ey, ex, 1 - ex])
mortar = edge < 0.025
bevel = np.clip(edge / 0.08, 0, 1)
stone *= (0.55 + 0.45 * bevel)[..., None]
stone[mortar] = [6, 7, 10]
# glowing joints: some mortar lines carry a faint cyan glow
glowJoint = np.random.default_rng(12).random((ROWS, COLS + 1)) < 0.28
jmask = (mortar & glowJoint[row, bx]).astype(np.uint8) * 255
jglow = np.asarray(Image.fromarray(jmask).filter(ImageFilter.GaussianBlur(4))).astype(float) / 255
stone += jglow[..., None] * np.array([10, 90, 110]) + (jmask[..., None] / 255) * np.array([20, 120, 140])
# a few jagged cracks across stones
crack = np.zeros((S, S), np.uint8)
from PIL import ImageDraw
d = ImageDraw.Draw(Image.fromarray(crack))
cimg = Image.new("L", (S, S), 0)
cd = ImageDraw.Draw(cimg)
for _ in range(7):
    x, y = rng.random() * S, rng.random() * S
    ang = rng.random() * 2 * np.pi
    pts = [(x, y)]
    for _ in range(14):
        ang += (rng.random() - 0.5) * 1.2
        x += np.cos(ang) * 18
        y += np.sin(ang) * 18
        pts.append((x % S, y % S))
    for p0, p1 in zip(pts, pts[1:]):
        if abs(p0[0] - p1[0]) < S / 2 and abs(p0[1] - p1[1]) < S / 2:
            cd.line([p0, p1], fill=255, width=2)
c = np.asarray(cimg).astype(float) / 255
cg = np.asarray(cimg.filter(ImageFilter.GaussianBlur(5))).astype(float) / 255
stone += cg[..., None] * np.array([15, 110, 130]) + c[..., None] * np.array([40, 170, 190])
Image.fromarray(np.clip(stone, 0, 255).astype(np.uint8)).save(os.path.join(OUT, "stone.png"))
print("stone.png written")
