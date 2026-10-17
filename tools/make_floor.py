"""Cathedral floor + stone dais under the table (TableSetup.ensureFloor in table.lua).

Input:  assets/floor/source_gemini.png  (flagstone texture painted by Gemini)
Output: assets/floor/stone_floor.jpg     tileable diffuse, darkened to sit behind the table
        assets/floor/stone_floor_n.png   normal map
        assets/floor/vignette.png        black fade decal laid over the floor's outer part
        assets/floor/floor.obj / floor_2hg.obj         the visible model
        assets/floor/floor_col.obj / floor_col_2hg.obj simple box collider (non-convex)

Heights come from the frame model: the corner towers end at y = -27 (the dais top), the
centre pedestal at y = -31 (the floor).
"""
import os
import numpy as np
from PIL import Image, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "assets", "floor")

TILE = 25.0            # world units per texture repeat
FLOOR_Y = -31.0        # floor top
DAIS = [(-27.0, 6.0), (-29.0, 12.0)]   # (top y, margin past the frame footprint), top step first
FLOOR_R = 160.0        # half-width of the floor
FRAME_HALF = {"four": (56.7, 56.7), "twohg": (66.7, 56.7)}


def texture():
    im = np.asarray(Image.open(os.path.join(OUT, "source_gemini.png")).convert("RGB")).astype(np.float32)
    h, w, _ = im.shape
    # 1. Seams: blend the border band with a half-offset copy (whose edges wrap cleanly).
    rolled = np.roll(np.roll(im, h // 2, 0), w // 2, 1)
    band = 56
    yy, xx = np.mgrid[0:h, 0:w]
    d = np.minimum.reduce([xx, w - 1 - xx, yy, h - 1 - yy]).astype(np.float32)
    k = np.clip(1 - d / band, 0, 1)[..., None]
    k = k * k * (3 - 2 * k)
    im = im * (1 - k) + rolled * k
    # 2. Darker and bluer, keeping the cyan cracks bright.
    r, g, b = im[..., 0], im[..., 1], im[..., 2]
    glow = np.clip(((g + b) / 2 - r - 35) / 60, 0, 1)[..., None]
    grey = im.mean(axis=2, keepdims=True)
    toned = grey + (im - grey) * 0.7                     # less saturated
    toned = toned * np.array([0.62, 0.66, 0.74])          # darker, cool blue-grey
    out = toned * (1 - glow) + im * 0.95 * glow
    out = np.clip(out, 0, 255).astype(np.uint8)
    Image.fromarray(out).save(os.path.join(OUT, "stone_floor.jpg"), quality=92)
    # 3. Normal map from brightness (wrapping), cracks sunk in.
    lum = np.asarray(Image.fromarray(out).convert("L").filter(ImageFilter.GaussianBlur(1.2))).astype(np.float32) / 255
    dx = np.roll(lum, -1, 1) - np.roll(lum, 1, 1)
    dy = np.roll(lum, -1, 0) - np.roll(lum, 1, 0)
    strength = 6.0
    n = np.dstack([-dx * strength, dy * strength, np.ones_like(lum)])
    n /= np.linalg.norm(n, axis=2, keepdims=True)
    Image.fromarray(((n * 0.5 + 0.5) * 255).astype(np.uint8)).save(os.path.join(OUT, "stone_floor_n.png"))


def vignette():
    s = 1024
    yy, xx = np.mgrid[0:s, 0:s].astype(np.float32)
    c = (s - 1) / 2
    r = np.sqrt((xx - c) ** 2 + (yy - c) ** 2) / c * FLOOR_R      # world units from centre
    a = np.clip((r - 80) / 75, 0, 1)
    a = a * a * (3 - 2 * a)
    img = np.zeros((s, s, 4), np.uint8)
    img[..., 3] = (a * 255).astype(np.uint8)
    Image.fromarray(img, "RGBA").save(os.path.join(OUT, "vignette.png"))


class Mesh:
    def __init__(self):
        self.v, self.vt, self.f = [], [], []

    def quad(self, pts, uvs):
        base_v, base_t = len(self.v), len(self.vt)
        self.v += pts
        self.vt += uvs
        self.f.append([(base_v + i + 1, base_t + i + 1) for i in range(len(pts))])

    def write(self, path, header):
        with open(path, "w") as fh:
            fh.write(header)
            for p in self.v:
                fh.write("v %.3f %.3f %.3f\n" % p)
            for t in self.vt:
                fh.write("vt %.4f %.4f\n" % t)
            for face in self.f:
                fh.write("f " + " ".join("%d/%d" % x for x in face) + "\n")
                # Both sides: whichever way TTS mirrors the import, every face shows.
                fh.write("f " + " ".join("%d/%d" % x for x in reversed(face)) + "\n")


def top_uv(p):
    return (p[0] / TILE, p[2] / TILE)


def box(m, x0, x1, z0, z1, y0, y1, top=True, uv=True):
    """Axis box, faces wound outward (TTS: counter-clockwise seen from outside)."""
    P = lambda x, y, z: (x, y, z)
    def side_uv(a, y):
        return (a / TILE, y / TILE)
    if top:
        pts = [P(x0, y1, z0), P(x0, y1, z1), P(x1, y1, z1), P(x1, y1, z0)]
        m.quad(pts, [top_uv(p) for p in pts])
    # sides
    s = [
        ([P(x0, y0, z0), P(x1, y0, z0), P(x1, y1, z0), P(x0, y1, z0)], 0),   # -z
        ([P(x1, y0, z1), P(x0, y0, z1), P(x0, y1, z1), P(x1, y1, z1)], 0),   # +z
        ([P(x0, y0, z1), P(x0, y0, z0), P(x0, y1, z0), P(x0, y1, z1)], 2),   # -x
        ([P(x1, y0, z0), P(x1, y0, z1), P(x1, y1, z1), P(x1, y1, z0)], 2),   # +x
    ]
    for pts, axis in s:
        m.quad(pts, [side_uv(p[axis], p[1]) for p in pts])
    bottom = [P(x0, y0, z0), P(x1, y0, z0), P(x1, y0, z1), P(x0, y0, z1)]
    m.quad(bottom, [top_uv(p) for p in bottom])


def crumbled_floor(m, rng):
    """The floor slab: a square that breaks up into an uneven stone edge."""
    n = 64
    ring = []
    for i in range(n):
        t = i / n * 2 * np.pi
        # rounded-square outline with ragged bites
        c, s = np.cos(t), np.sin(t)
        q = 1 / max(abs(c), abs(s)) ** 0.85
        rad = FLOOR_R * min(q, 1.25) * (0.86 + 0.14 * rng.random())
        ring.append((c * rad, s * rad))
    y1, y0 = FLOOR_Y, FLOOR_Y - 1.5
    # top: fan from centre
    centre = (0.0, y1, 0.0)
    for i in range(n):
        a, b = ring[i], ring[(i + 1) % n]
        pts = [centre, (b[0], y1, b[1]), (a[0], y1, a[1])]
        m.quad(pts, [top_uv(p) for p in pts])
    # rim
    for i in range(n):
        a, b = ring[i], ring[(i + 1) % n]
        pts = [(a[0], y0, a[1]), (a[0], y1, a[1]), (b[0], y1, b[1]), (b[0], y0, b[1])]
        L = np.hypot(b[0] - a[0], b[1] - a[1])
        m.quad(pts, [(0, y0 / TILE), (0, y1 / TILE), (L / TILE, y1 / TILE), (L / TILE, y0 / TILE)])
    # a few broken stones lying off the edge
    for _ in range(14):
        t = rng.random() * 2 * np.pi
        rad = FLOOR_R * (0.95 + 0.2 * rng.random())
        cx, cz = np.cos(t) * rad, np.sin(t) * rad
        sx, sz = 2 + rng.random() * 5, 2 + rng.random() * 4
        box(m, cx - sx, cx + sx, cz - sz, cz + sz, y0, y1 - rng.random() * 0.8)


def model(layout):
    rng = np.random.default_rng(7)
    hx, hz = FRAME_HALF[layout]
    vis, col = Mesh(), Mesh()
    crumbled_floor(vis, rng)
    for top, margin in DAIS:
        box(vis, -hx - margin, hx + margin, -hz - margin, hz + margin, FLOOR_Y, top)
    # Collider: the floor as one big slab, the dais steps as boxes.
    box(col, -FLOOR_R, FLOOR_R, -FLOOR_R, FLOOR_R, FLOOR_Y - 1.5, FLOOR_Y)
    for top, margin in DAIS:
        box(col, -hx - margin, hx + margin, -hz - margin, hz + margin, FLOOR_Y, top)
    suffix = "" if layout == "four" else "_2hg"
    hdr = "# Cathedral floor and dais (tools/make_floor.py)\n"
    vis.write(os.path.join(OUT, "floor%s.obj" % suffix), hdr)
    col.write(os.path.join(OUT, "floor_col%s.obj" % suffix), hdr + "# collider\n")


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    texture()
    vignette()
    model("four")
    model("twohg")
    print("done")
