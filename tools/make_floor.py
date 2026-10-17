"""Cathedral floor + stone dais under the table (TableSetup.ensureFloor in table.lua).

Input:  assets/floor/source_gemini.png  (flagstone texture painted by Gemini)
Output: assets/floor/stone_floor.jpg     tileable diffuse, darkened to sit behind the table
        assets/floor/stone_floor_n.png   normal map
        assets/floor/floor.obj / floor_2hg.obj   the model (also its own non-convex collider):
            a floating slab of cathedral floor with a ragged edge and rocky underside, and a
            two-step dais under the frame's towers

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

    def face(self, pts, uvs, out):
        """Add a face, wound so its front faces the direction `out` (right-hand rule, like the frame)."""
        P = np.array(pts, dtype=float)
        n = np.cross(P[1] - P[0], P[2] - P[0])
        if np.dot(n, out) < 0:
            pts, uvs = pts[::-1], uvs[::-1]
        base_v, base_t = len(self.v), len(self.vt)
        self.v += [tuple(map(float, p)) for p in pts]
        self.vt += [tuple(map(float, t)) for t in uvs]
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


def top_uv(p):
    return (p[0] / TILE, p[2] / TILE)


def box(m, x0, x1, z0, z1, y0, y1):
    c = np.array([(x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2])
    corners = {
        "top": [(x0, y1, z0), (x0, y1, z1), (x1, y1, z1), (x1, y1, z0)],
        "-z": [(x0, y0, z0), (x1, y0, z0), (x1, y1, z0), (x0, y1, z0)],
        "+z": [(x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1)],
        "-x": [(x0, y0, z0), (x0, y0, z1), (x0, y1, z1), (x0, y1, z0)],
        "+x": [(x1, y0, z0), (x1, y0, z1), (x1, y1, z1), (x1, y1, z0)],
    }
    for k, pts in corners.items():
        if k == "top":
            uvs = [top_uv(p) for p in pts]
        else:
            ax = 0 if "z" in k else 2
            uvs = [(p[ax] / TILE, p[1] / TILE) for p in pts]
        m.face(pts, uvs, np.mean(pts, axis=0) - c)


def outline(hx, hz, rng, n=72, jag=0.06):
    ring = []
    for i in range(n):
        t = i / n * 2 * np.pi
        c, s = np.cos(t), np.sin(t)
        q = 1 / max(abs(c), abs(s)) ** 0.8          # rounded square
        k = q * (1 - jag * rng.random())
        ring.append((c * hx * k, s * hz * k))
    return ring


def island(m, hx, hz, rng):
    """The floor: a floating slab of the cathedral with a ragged edge and a rocky underside."""
    ring = outline(hx, hz, rng)
    n = len(ring)
    y1, y0 = FLOOR_Y, FLOOR_Y - 4
    for i in range(n):
        a, b = ring[i], ring[(i + 1) % n]
        pts = [(0, y1, 0), (a[0], y1, a[1]), (b[0], y1, b[1])]
        m.face(pts, [top_uv(p) for p in pts], (0, 1, 0))
    # Underside rings, tapering to a point: (scale, y)
    layers = [(1.0, y1), (1.0, y0), (0.82, FLOOR_Y - 10), (0.5, FLOOR_Y - 20), (0.18, FLOOR_Y - 30)]
    rings = []
    for sc, y in layers:
        j = 1 if sc == 1.0 else (1 - 0.08 * rng.random(n))
        rings.append([(ring[i][0] * sc * (j if np.isscalar(j) else j[i]), y, ring[i][1] * sc * (j if np.isscalar(j) else j[i])) for i in range(n)])
    for L in range(len(rings) - 1):
        up, dn = rings[L], rings[L + 1]
        for i in range(n):
            k = (i + 1) % n
            pts = [up[i], dn[i], dn[k], up[k]]
            mid = np.mean(pts, axis=0)
            out = np.array([mid[0], -abs(mid[0]) * 0 - (0 if L == 0 else 20), mid[2]])
            uvs = [((p[0] + p[1]) / TILE, (p[2] - p[1]) / TILE) for p in pts]
            m.face(pts, uvs, out)
    tip = (0, FLOOR_Y - 42, 0)
    last = rings[-1]
    for i in range(n):
        pts = [last[i], tip, last[(i + 1) % n]]
        m.face(pts, [top_uv(p) for p in pts], (0, -1, 0))


ISLAND = {"four": (100.0, 100.0), "twohg": (110.0, 100.0)}


def model(layout):
    rng = np.random.default_rng(7)
    hx, hz = FRAME_HALF[layout]
    m = Mesh()
    island(m, *ISLAND[layout], rng)
    for top, margin in DAIS:
        box(m, -hx - margin, hx + margin, -hz - margin, hz + margin, FLOOR_Y, top)
    suffix = "" if layout == "four" else "_2hg"
    # The same mesh is its own (non-convex) collider, so pieces land exactly where the stone is.
    m.write(os.path.join(OUT, "floor%s.obj" % suffix), "# Cathedral floor island and dais (tools/make_floor.py)\n")


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    texture()
    model("four")
    model("twohg")
    print("done")
