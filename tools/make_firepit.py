"""Floor fire pit for the two dark corners of the room (the corners without a fireplace): a ring of
rough stone blocks around a sunken ash bed, low on the floor (fires.lua puts a hearth fire in it).

Output: assets/hearth/firepit.obj. Local space: y = 0 is the floor top, centred on the origin.
Textured with the frame's stone (assets/table/stone.png). The mesh is its own collider.
"""
import math
import os
import random
import numpy as np
from make_hearth import Mesh, OUT

random.seed(7)
N = 14            # stone blocks around the ring
R_IN = 7.0        # inside of the ring
R_OUT = 10.5      # outside of the ring
H = 2.6           # average block height
BED = 0.4         # ash bed height inside the ring


def block(m, a0, a1, r0, r1, h):
    """One wedge-shaped stone between angles a0..a1 (radians), radii r0..r1, height h (slightly tapered)."""
    inset = 0.25
    def p(a, r, y):
        return np.array([r * math.cos(a), y, r * math.sin(a)])
    lo = [p(a0, r0, 0), p(a1, r0, 0), p(a1, r1, 0), p(a0, r1, 0)]
    am = (a0 + a1) / 2
    shrink = lambda q: q + (np.array([math.cos(am) * (r0 + r1) / 2, 0, math.sin(am) * (r0 + r1) / 2]) - q) * 0.12
    hi = [shrink(q) + np.array([0, h, 0]) for q in lo]
    centre = sum(lo + hi) / 8
    T = 8.0
    def uv_side(pts):
        # along the ring, up the face
        out = []
        for q in pts:
            out.append(((math.atan2(q[2], q[0]) * 9 + math.hypot(q[0], q[2])) / T * 2, q[1] / T * 2))
        return out
    top = hi
    m.face(top, [(q[0] / T, q[2] / T) for q in top], np.array([0, 1, 0]))
    for i in range(4):
        j = (i + 1) % 4
        quad = [lo[i], lo[j], hi[j], hi[i]]
        mid = sum(quad) / 4
        m.face(quad, uv_side(quad), mid - centre)


def build():
    m = Mesh()
    gap = 0.06
    step = 2 * math.pi / N
    for k in range(N):
        a0 = k * step + gap / 2
        a1 = (k + 1) * step - gap / 2
        h = H * random.uniform(0.75, 1.3)
        r1 = R_OUT * random.uniform(0.95, 1.05)
        block(m, a0, a1, R_IN, r1, h)
    # Ash bed: a low disc inside the ring (octagon-ish polygon, top face only plus a rim).
    seg = 24
    ring = [np.array([R_IN * math.cos(2 * math.pi * i / seg), BED, R_IN * math.sin(2 * math.pi * i / seg)]) for i in range(seg)]
    centre = np.array([0.0, BED, 0.0])
    for i in range(seg):
        a, b = ring[i], ring[(i + 1) % seg]
        tri = [centre, a, b]
        m.face(tri, [(q[0] / 16 + 0.5, q[2] / 16 + 0.5) for q in tri], np.array([0, 1, 0]))
    return m


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    build().write(os.path.join(OUT, "firepit.obj"))
    print("wrote", os.path.join(OUT, "firepit.obj"))
