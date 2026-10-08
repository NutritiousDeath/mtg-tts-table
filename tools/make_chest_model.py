"""Planechase chest (planechase.lua): a gothic stone treasure chest in the same
stone as the table frame (assets/table/stone.png), with spired corner
buttresses and a flat console on the lid for the buttons. Origin = middle of
the bottom. Writes assets/planechase/chest.obj and chest_collider.obj.
Run: python tools/make_chest_model.py"""
import os
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "assets", "planechase")
TILE = 5.0
V, VT, F = [], [], []


def solid_quad(a, b, c, d, center):
    a, b, c, d = map(np.array, (a, b, c, d))
    n = np.cross(b - a, d - a)
    if np.dot(n, (a + b + c + d) / 4 - np.array(center)) < 0:   # point outward
        a, b, c, d = d, c, b, a
        n = -n
    ax = np.argmax(np.abs(n))
    idx = []
    for p in (a, b, c, d):
        u, v = (p[2], p[1]) if ax == 0 else (p[0], p[2]) if ax == 1 else (p[0], p[1])
        V.append(p)
        VT.append((u / TILE, v / TILE))
        idx.append(len(V))
    F.append(idx)


def solid_tri(a, b, c, center):
    a, b, c = map(np.array, (a, b, c))
    n = np.cross(b - a, c - a)
    if np.dot(n, (a + b + c) / 3 - np.array(center)) < 0:
        b, c = c, b
        n = -n
    ax = np.argmax(np.abs(n))
    idx = []
    for p in (a, b, c):
        u, v = (p[2], p[1]) if ax == 0 else (p[0], p[2]) if ax == 1 else (p[0], p[1])
        V.append(p)
        VT.append((u / TILE, v / TILE))
        idx.append(len(V))
    F.append(idx)


def box(x0, x1, y0, y1, z0, z1, bottom=True):
    cen = ((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2)
    q = lambda *p: solid_quad(*p, cen)
    q((x0, y1, z0), (x0, y1, z1), (x1, y1, z1), (x1, y1, z0))
    if bottom:
        q((x0, y0, z0), (x1, y0, z0), (x1, y0, z1), (x0, y0, z1))
    q((x0, y0, z0), (x0, y1, z0), (x1, y1, z0), (x1, y0, z0))
    q((x1, y0, z1), (x1, y1, z1), (x0, y1, z1), (x0, y0, z1))
    q((x0, y0, z1), (x0, y1, z1), (x0, y1, z0), (x0, y0, z0))
    q((x1, y0, z0), (x1, y1, z0), (x1, y1, z1), (x1, y0, z1))


def pyramid(cx, cz, half, y0, y1):
    cen = (cx, (y0 + y1) / 3 * 1.0 + y0 * 0, cz)
    cen = (cx, y0 + (y1 - y0) * 0.25, cz)
    a, b, c, d = (cx - half, y0, cz - half), (cx + half, y0, cz - half), (cx + half, y0, cz + half), (cx - half, y0, cz + half)
    tip = (cx, y1, cz)
    for p, q in ((a, b), (b, c), (c, d), (d, a)):
        solid_tri(p, tip, q, cen)


def frustum(cx, cz, h0, h1, y0, y1):
    cen = (cx, (y0 + y1) / 2, cz)
    lo = [(cx - h0, y0, cz - h0), (cx + h0, y0, cz - h0), (cx + h0, y0, cz + h0), (cx - h0, y0, cz + h0)]
    hi = [(cx - h1, y1, cz - h1), (cx + h1, y1, cz - h1), (cx + h1, y1, cz + h1), (cx - h1, y1, cz + h1)]
    for i in range(4):
        j = (i + 1) % 4
        solid_quad(lo[i], hi[i], hi[j], lo[j], cen)


# --- Plinth and body
W, D = 3.8, 2.5
box(-W - 0.5, W + 0.5, 0, 0.5, -D - 0.5, D + 0.5)                 # plinth
box(-W, W, 0.5, 2.7, -D, D, bottom=False)                          # body
box(-W - 0.15, W + 0.15, 2.0, 2.2, -D - 0.15, D + 0.15, bottom=False)   # band around the body

# --- Hipped lid: cornice, sloped sides up to a flat console on top.
LW, LD, TOPY, FLAT = W + 0.2, D + 0.2, 3.5, 1.4
box(-LW, LW, 2.7, 3.0, -LD, LD)                                    # cornice
ring_lo = [(-LW + 0.25, 3.0, -LD + 0.25), (LW - 0.25, 3.0, -LD + 0.25), (LW - 0.25, 3.0, LD - 0.25), (-LW + 0.25, 3.0, LD - 0.25)]
hi_x = LW - 0.9
ring_hi = [(-hi_x, TOPY, -FLAT), (hi_x, TOPY, -FLAT), (hi_x, TOPY, FLAT), (-hi_x, TOPY, FLAT)]
cen = (0, 3.2, 0)
for i in range(4):
    j = (i + 1) % 4
    solid_quad(ring_lo[i], ring_hi[i], ring_hi[j], ring_lo[j], cen)
solid_quad(*ring_hi, cen)                                          # the flat top (console)

# --- Corner buttresses with spires, like the table's towers.
for sx in (-1, 1):
    for sz in (-1, 1):
        bx, bz = sx * (W + 0.15), sz * (D + 0.15)
        frustum(bx, bz, 0.75, 0.5, 0.5, 3.6)
        box(bx - 0.62, bx + 0.62, 3.6, 3.85, bz - 0.62, bz + 0.62, bottom=False)
        pyramid(bx, bz, 0.5, 3.85, 5.6)

# --- Keystone block on the front of the lid
box(-0.55, 0.55, 2.2, 3.1, -D - 0.45, -D + 0.1, bottom=False)

os.makedirs(OUT, exist_ok=True)
with open(os.path.join(OUT, "chest.obj"), "w") as f:
    f.write("# Planechase chest (tools/make_chest_model.py)\n")
    for v in V:
        f.write("v %.4f %.4f %.4f\n" % tuple(v))
    for t in VT:
        f.write("vt %.5f %.5f\n" % t)
    for face in F:
        f.write("f " + " ".join("%d/%d" % (i, i) for i in face) + "\n")
print("chest.obj:", len(V), "vertices,", len(F), "faces")

# Collider: one simple box around the chest (no spires), so dice and cards rest on it.
V.clear(); VT.clear(); F.clear()
box(-W - 0.5, W + 0.5, 0, 3.5, -D - 0.5, D + 0.5)
with open(os.path.join(OUT, "chest_collider.obj"), "w") as f:
    f.write("# Planechase chest collider\n")
    for v in V:
        f.write("v %.4f %.4f %.4f\n" % tuple(v))
    for t in VT:
        f.write("vt %.5f %.5f\n" % t)
    for face in F:
        f.write("f " + " ".join("%d/%d" % (i, i) for i in face) + "\n")
print("collider written")
