"""Gothic fireplace set into a corner of ruined cathedral wall (table.lua TableSetup.ensureHearths).

Output: assets/hearth/hearth_corner.obj (in a corner: the wall wings run out at 45 degrees along the
two room walls) and hearth_edge.obj (in the middle of a wall: the wings run straight out sideways).
Local space: the hearth faces +Z (toward the table) and its base sits on y = 0 (the floor top). Textured with the frame's stone (assets/table/stone.png). The mesh is its own collider.
"""
import os
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "assets", "hearth")
TILE = 8.0

W = 34.0          # hearth front width
D = 10.0          # hearth depth (front at z = +D/2)
OPEN_W = 16.0     # firebox opening width
SPRING = 14.0     # arch spring line height (above the hearth step)
APEX = 21.0       # arch apex height
STEP = 2.0        # raised hearth step
MANTEL = 26.0     # mantel shelf height
TOP = 46.0        # chimney top
FIRE_D = 7.0      # firebox depth


class Mesh:
    def __init__(self):
        self.v, self.vt, self.f = [], [], []

    def face(self, pts, uvs, out):
        P = np.array(pts, dtype=float)
        n = np.cross(P[1] - P[0], P[2] - P[0])
        if np.dot(n, out) < 0:
            pts, uvs = pts[::-1], uvs[::-1]
        bv, bt = len(self.v), len(self.vt)
        self.v += [tuple(map(float, p)) for p in pts]
        self.vt += [tuple(map(float, t)) for t in uvs]
        self.f.append([(bv + i + 1, bt + i + 1) for i in range(len(pts))])

    def box(self, x0, x1, y0, y1, z0, z1, skip=()):
        c = np.array([(x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2])
        faces = {
            "+y": [(x0, y1, z0), (x0, y1, z1), (x1, y1, z1), (x1, y1, z0)],
            "-y": [(x0, y0, z0), (x1, y0, z0), (x1, y0, z1), (x0, y0, z1)],
            "-z": [(x0, y0, z0), (x1, y0, z0), (x1, y1, z0), (x0, y1, z0)],
            "+z": [(x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1)],
            "-x": [(x0, y0, z0), (x0, y0, z1), (x0, y1, z1), (x0, y1, z0)],
            "+x": [(x1, y0, z0), (x1, y0, z1), (x1, y1, z1), (x1, y1, z0)],
        }
        for k, pts in faces.items():
            if k in skip:
                continue
            if "y" in k:
                uvs = [(p[0] / TILE, p[2] / TILE) for p in pts]
            elif "z" in k:
                uvs = [(p[0] / TILE, p[1] / TILE) for p in pts]
            else:
                uvs = [(p[2] / TILE, p[1] / TILE) for p in pts]
            self.face(pts, uvs, np.mean(pts, axis=0) - c)

    def transformed_box(self, M, x0, x1, y0, y1, z0, z1):
        """A box in a rotated/moved frame (M: 3x4)."""
        sub = Mesh()
        sub.box(x0, x1, y0, y1, z0, z1)
        bv, bt = len(self.v), len(self.vt)
        for p in sub.v:
            q = M[:, :3] @ np.array(p) + M[:, 3]
            self.v.append(tuple(map(float, q)))
        # world-planar UVs so the stone lines up across pieces
        for i, p in enumerate(self.v[bv:]):
            pass
        self.vt += sub.vt
        for fc in sub.f:
            self.f.append([(a + bv, b + bt) for a, b in fc])

    def write(self, path):
        with open(path, "w") as fh:
            fh.write("# Gothic fireplace in a ruined corner (tools/make_hearth.py)\n")
            for p in self.v:
                fh.write("v %.3f %.3f %.3f\n" % p)
            for t in self.vt:
                fh.write("vt %.4f %.4f\n" % t)
            for fc in self.f:
                fh.write("f " + " ".join("%d/%d" % x for x in fc) + "\n")


def arch_half_width(y):
    """Half width of the opening at height y (above the step): straight sides, then a pointed arch."""
    hw = OPEN_W / 2
    if y <= SPRING:
        return hw
    if y >= APEX:
        return 0.0
    # two circle arcs meeting at the apex (lancet): radius = OPEN_W, centres at the opposite jamb
    r = OPEN_W
    cx = hw - r                      # centre of the right-hand arc (x), at the spring line
    dy = y - SPRING
    x = cx + np.sqrt(max(r * r - dy * dy, 0.0))
    return max(x, 0.0)


def build(wing_angle, wing_len):
    m = Mesh()
    zf, zb = D / 2, -D / 2
    hw = W / 2
    # plinth / raised hearth step running across the front
    m.box(-hw - 1, hw + 1, 0, STEP, zb, zf + 2)
    y0 = STEP
    # jambs (sides of the opening) up to the spring line
    m.box(-hw, -OPEN_W / 2, y0, y0 + SPRING, zb, zf, skip=("-y",))
    m.box(OPEN_W / 2, hw, y0, y0 + SPRING, zb, zf, skip=("-y",))
    # the arch: stacked thin slices, each two blocks from the opening edge outward
    n = 14
    ys = np.linspace(SPRING, APEX, n + 1)
    for i in range(n):
        a, b = ys[i], ys[i + 1]
        w = arch_half_width((a + b) / 2)
        m.box(-hw, -w, y0 + a, y0 + b, zb, zf, skip=("+y", "-y"))
        m.box(w, hw, y0 + a, y0 + b, zb, zf, skip=("+y", "-y"))
    # wall above the arch up to the mantel
    m.box(-hw, hw, y0 + APEX, MANTEL, zb, zf, skip=("-y",))
    # mantel shelf
    m.box(-hw - 1.5, hw + 1.5, MANTEL, MANTEL + 1.6, zb, zf + 1.8)
    # chimney breast, stepping in as it rises
    m.box(-hw + 3, hw - 3, MANTEL + 1.6, 36, zb, zf - 1)
    m.box(-hw + 6, hw - 6, 36, TOP, zb, zf - 2)
    m.box(-hw + 5, hw - 5, TOP, TOP + 1.2, zb - 0.5, zf - 1.5)
    # side buttresses with pinnacles
    for s in (-1, 1):
        x0, x1 = (s * hw, s * (hw + 3)) if s > 0 else (s * (hw + 3), s * hw)
        m.box(x0, x1, 0, MANTEL + 6, zb, zf + 1)
        m.box(x0 + 0.5, x1 - 0.5, MANTEL + 6, MANTEL + 12, zb + 0.5, zf + 0.5)
    # firebox: back wall, sides and floor inside the opening
    fb = zb - FIRE_D + D       # the opening goes back FIRE_D from the front
    m.box(-OPEN_W / 2, OPEN_W / 2, y0, y0 + APEX, zf - FIRE_D - 1, zf - FIRE_D, skip=())
    # wall wings: ruined walls running out from each side of the hearth along the room's walls
    # (wing_angle 45: the hearth sits in a corner; 0: it sits in the middle of a wall)
    for sd in (-1, 1):
        a_ = np.radians(wing_angle)
        dx, dz = sd * np.cos(a_), np.sin(a_)          # along the wall, away from the hearth
        nx, nz = -dz * sd, dx * sd                     # across the wall
        R = np.array([[dx, 0, nx], [0, 1, 0], [dz, 0, nz]])
        M = np.hstack([R, [[sd * (hw + 3)], [0], [zb + 1.5]]])
        seg = 7
        rng = np.random.default_rng(3 if sd > 0 else 5)
        for k in range(seg):
            a0, b0 = wing_len * k / seg, wing_len * (k + 1) / seg
            h = 36 - 22 * (k / seg) + rng.uniform(-3, 3)      # crumbling lower as it runs away
            m.transformed_box(M, a0 - 0.05, b0, 0, h, -1.5, 1.5)
    return m


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    build(45, 46).write(os.path.join(OUT, "hearth_corner.obj"))
    build(0, 40).write(os.path.join(OUT, "hearth_edge.obj"))
    print("done")
