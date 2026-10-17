"""The chapel around the table (table.lua TableSetup.ensureRoom): a ruined eight-sided gothic chapel on
the floor island -- stone walls with tall pointed windows (open, showing the sky), half-column pilasters,
stone rib arches overhead with the roof long gone, and the two fireplaces built into the cut corners
(the other two cut corners get one big window each).

Every wall surface faces INTO the room only. TTS doesn't draw the back of a face, so from outside the
chapel (a camera pulled far back) the walls simply aren't there and you see straight in.

Output: assets/room/room.obj (four seats / two seats) and room_2hg.obj, in world units with the floor
top at y = 0 (table.lua places it at the floor height). Stone texture: assets/table/stone.png.
"""
import os
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "assets", "room")
TILE = 8.0
T = 3.0            # wall thickness
SILL = 40.0        # window sill above the floor (the table top is 32 above the floor)
SPRING = 68.0      # window arch spring line
TOP = 92.0         # wall top (ragged)
VAULT = 45.0       # rib apex above the wall top


class Mesh:
    def __init__(self):
        self.v, self.vt, self.f = [], [], []

    def face(self, pts, uvs, normal):
        P = np.array(pts, dtype=float)
        n = np.cross(P[1] - P[0], P[2] - P[0])
        if np.dot(n, normal) < 0:
            pts, uvs = pts[::-1], uvs[::-1]
        bv, bt = len(self.v), len(self.vt)
        self.v += [tuple(map(float, p)) for p in pts]
        self.vt += [tuple(map(float, t)) for t in uvs]
        self.f.append([(bv + i + 1, bt + i + 1) for i in range(len(pts))])

    def write(self, path, header):
        with open(path, "w") as fh:
            fh.write(header)
            for p in self.v:
                fh.write("v %.3f %.3f %.3f\n" % p)
            for t in self.vt:
                fh.write("vt %.4f %.4f\n" % t)
            for fc in self.f:
                fh.write("f " + " ".join("%d/%d" % x for x in fc) + "\n")


def lancet_half(y, w, spring, apex):
    """Half width of a pointed window of width w at height y."""
    hw = w / 2
    if y <= spring:
        return hw
    if y >= apex:
        return 0.0
    H = apex - spring
    R = (hw * hw + H * H) / (2 * hw)       # arc radius through the jamb top and the apex
    cx = hw - R
    dy = y - spring
    return max(cx + np.sqrt(max(R * R - dy * dy, 0.0)), 0.0)


class Wall:
    """A straight wall from A to B (x, z), inner face toward `inward`."""

    def __init__(self, m, A, B, inward):
        self.m = m
        self.A = np.array([A[0], 0.0, A[1]])
        self.B = np.array([B[0], 0.0, B[1]])
        d = self.B - self.A
        self.L = np.linalg.norm(d)
        self.u = d / self.L
        self.n = np.array([inward[0], 0.0, inward[1]], dtype=float)
        self.n /= np.linalg.norm(self.n)

    def p(self, u, y, depth=0.0):
        """Point on the wall: u along it, y up, depth back from the inner face (outward)."""
        q = self.A + self.u * u - self.n * depth
        return (q[0], y, q[2])

    def uv(self, u, y):
        return (u / TILE, y / TILE)

    def rect(self, u0, u1, y0, y1):
        if u1 - u0 < 1e-4 or y1 - y0 < 1e-4:
            return
        pts = [self.p(u0, y0), self.p(u1, y0), self.p(u1, y1), self.p(u0, y1)]
        uvs = [self.uv(u0, y0), self.uv(u1, y0), self.uv(u1, y1), self.uv(u0, y1)]
        self.m.face(pts, uvs, self.n)

    def reveal_side(self, u, y0, y1, facing):
        """Vertical strip across the wall thickness at u (a window jamb); facing = +1/-1 along u."""
        pts = [self.p(u, y0, 0), self.p(u, y0, T), self.p(u, y1, T), self.p(u, y1, 0)]
        uvs = [(0, y0 / TILE), (T / TILE, y0 / TILE), (T / TILE, y1 / TILE), (0, y1 / TILE)]
        self.m.face(pts, uvs, self.u * facing)

    def reveal_flat(self, u0, u1, y, up):
        """Horizontal strip across the thickness at height y (sill, step under the arch, wall top)."""
        if u1 - u0 < 1e-4:
            return
        pts = [self.p(u0, y, 0), self.p(u1, y, 0), self.p(u1, y, T), self.p(u0, y, T)]
        uvs = [(u0 / TILE, 0), (u1 / TILE, 0), (u1 / TILE, T / TILE), (u0 / TILE, T / TILE)]
        self.m.face(pts, uvs, np.array([0, 1.0 if up else -1.0, 0]))

    def build(self, windows, rng, top=TOP, ragged=True):
        """windows: list of (centre u, width, sill, spring, apex)."""
        L = self.L
        lo = min([w[2] for w in windows], default=top)
        self.rect(0, L, 0, lo)
        # bands from the lowest sill to the top
        levels = sorted(set([lo] + [w[2] for w in windows] + [w[3] for w in windows] + [top]))
        ys = []
        for a, b in zip(levels[:-1], levels[1:]):
            arch = any(w[3] <= a < w[4] for w in windows)
            n = 10 if arch else 1
            ys += list(np.linspace(a, b, n + 1)[:-1])
        ys.append(top)
        # extra bands through the arches
        allys = sorted(set(list(ys) + [y for w in windows for y in np.linspace(w[3], w[4], 11)]))
        allys = [y for y in allys if lo <= y <= top]
        prev_open = {}
        for a, b in zip(allys[:-1], allys[1:]):
            mid = (a + b) / 2
            opens = []
            for i, (c, wd, sill, spring, apex) in enumerate(windows):
                if sill <= mid < apex:
                    h = lancet_half(mid, wd, spring, apex)
                    if h > 0.05:
                        opens.append((i, c - h, c + h))
            opens.sort(key=lambda o: o[1])
            cur = 0.0
            for i, u0, u1 in opens:
                self.rect(cur, u0, a, b)
                self.reveal_side(u0, a, b, +1)
                self.reveal_side(u1, a, b, -1)
                cur = u1
            self.rect(cur, L, a, b)
            # sills and the little steps under the arch
            now = {i: (u0, u1) for i, u0, u1 in opens}
            for i, (c, wd, sill, spring, apex) in enumerate(windows):
                if abs(a - sill) < 1e-6 and i in now:
                    self.reveal_flat(now[i][0], now[i][1], a, True)
                if i in prev_open:
                    pu0, pu1 = prev_open[i]
                    nu0, nu1 = now.get(i, (c, c))
                    self.reveal_flat(pu0, nu0, a, False)
                    self.reveal_flat(nu1, pu1, a, False)
            prev_open = now
        # ragged top: a few broken merlons
        k = max(1, int(L / 7))
        for j in range(k):
            u0, u1 = L * j / k, L * (j + 1) / k
            h = top + (rng.uniform(0, 5) if ragged and rng.random() < 0.6 else 0)
            self.rect(u0, u1, top, h)
            self.reveal_flat(u0, u1, h, True)
            if j > 0:
                pass


def pilaster(m, wall, u, top):
    """A half column on the inner face: three faces (front and two sides) and a cap."""
    w, d = 3.2, 2.2
    q = lambda uu, y, dep: wall.p(uu, y, -dep)      # negative depth = into the room
    corners = [(u - w / 2, 0), (u + w / 2, 0), (u + w / 2, d), (u - w / 2, d)]
    # front
    pts = [q(u - w / 2, 0, d), q(u + w / 2, 0, d), q(u + w / 2, top, d), q(u - w / 2, top, d)]
    m.face(pts, [((u - w / 2) / TILE, 0), ((u + w / 2) / TILE, 0), ((u + w / 2) / TILE, top / TILE), ((u - w / 2) / TILE, top / TILE)], wall.n)
    for s in (-1, 1):
        uu = u + s * w / 2
        pts = [q(uu, 0, 0), q(uu, 0, d), q(uu, top, d), q(uu, top, 0)]
        m.face(pts, [(0, 0), (d / TILE, 0), (d / TILE, top / TILE), (0, top / TILE)], wall.u * s)
    pts = [q(u - w / 2, top, 0), q(u + w / 2, top, 0), q(u + w / 2, top, d), q(u - w / 2, top, d)]
    m.face(pts, [(0, 0), (w / TILE, 0), (w / TILE, d / TILE), (0, d / TILE)], np.array([0, 1.0, 0]))


def rib(m, P0, P1, ys, H, broken=None):
    """A pointed stone rib arching from P0 to P1 (x, z on the wall tops), springing at height ys."""
    P0, P1 = np.array(P0, float), np.array(P1, float)
    span = np.linalg.norm(P1 - P0)
    half = span / 2
    R = (half * half + H * H) / (2 * half)
    cx = half - R
    dirv = (P1 - P0) / span
    side = np.array([-dirv[1], dirv[0]])
    n = 40
    pts = []
    for i in range(n + 1):
        s = -half + span * i / n                  # -half .. half
        y = ys + np.sqrt(max(R * R - (abs(s) - cx) ** 2, 0.0)) if abs(s) >= cx else ys + H
        # (cx < 0 for a pointed arch, so the sqrt branch always applies)
        y = ys + np.sqrt(max(R * R - (abs(s) - cx) ** 2, 0.0))
        xz = P0 + dirv * (s + half)
        pts.append((xz, y))
    w, dep = 1.3, 1.8
    lastk = n if broken is None else int(n * broken)
    for i in range(lastk):
        (a, ya), (b, yb) = pts[i], pts[i + 1]
        corners = []
        for (xz, y) in ((a, ya), (b, yb)):
            for sx in (-w, w):
                for sy in (-dep, 0.0):
                    corners.append((xz[0] + side[0] * sx, y + sy, xz[1] + side[1] * sx))
        # corners: [a(-w,-d), a(-w,0), a(w,-d), a(w,0), b(-w,-d), b(-w,0), b(w,-d), b(w,0)]
        c = corners
        mid = np.mean(np.array(c), axis=0)
        quads = [(c[0], c[2], c[6], c[4]),   # underside
                 (c[1], c[3], c[7], c[5]),   # top
                 (c[0], c[1], c[5], c[4]),   # side -w
                 (c[2], c[3], c[7], c[6])]   # side +w
        L = np.linalg.norm(np.array(b) - np.array(a)) + abs(yb - ya)
        for qd in quads:
            qm = np.mean(np.array(qd), axis=0)
            m.face(list(qd), [(0, 0), (1, 0), (1, L / TILE), (0, L / TILE)], qm - mid)
    if broken is not None:
        # jagged broken end
        a, ya = pts[lastk]
        c = [(a[0] + side[0] * sx, ya + sy, a[1] + side[1] * sx) for sx in (-w, w) for sy in (-dep, 0.0)]
        m.face([c[0], c[1], c[3], c[2]], [(0, 0), (1, 0), (1, 1), (0, 1)], np.array([dirv[0], 0, dirv[1]]))


def octagon(hx, hz, d):
    """Inner corners of the room: straight walls at x = +-hx, z = +-hz, corners cut at distance d along
    the diagonals. Returned counter-clockwise from the +x wall's south end."""
    s = d * np.sqrt(2)          # x + z on a cut
    pts = []
    for (sx, sz) in ((1, -1), (1, 1), (-1, 1), (-1, -1)):
        # along the x-wall then the cut then the z-wall
        a = (sx * hx, sz * (s - hx))
        b = (sx * (s - hz), sz * hz)
        pts.append((a, b))
    return pts


def build(layout):
    m = Mesh()
    rng = np.random.default_rng(17 if layout == "four" else 23)
    if layout == "four":
        hx, hz, d = 100.0, 100.0, 112.0
        hearth_corners = {(1, 1), (-1, -1)}          # NE and SW: where the deck importers point
        win_x = [(-39, 14), (0, 14), (39, 14)]       # (centre offset from the wall middle, width)
        win_z = win_x
        ribs_x = [-19.5, 19.5]                       # ribs spanning between the x walls at these z
        ribs_z = [-19.5, 19.5]
        hearth_edges = {}
    else:
        hx, hz, d = 104.0, 100.0, 120.0
        hearth_corners = set()
        win_x = [(-45, 14), (45, 14)]                # short walls (x = +-hx): the fireplace in the middle
        win_z = [(-52, 14), (-17.5, 14), (17.5, 14), (52, 14)]
        ribs_x = [-30.0, 30.0]
        ribs_z = [-34.75, 0.0, 34.75]
    s = d * np.sqrt(2)
    walls = []
    # straight walls
    for sx in (1, -1):
        A, B = (sx * hx, -(s - hx)), (sx * hx, (s - hx))
        walls.append(("x", Wall(m, A, B, (-sx, 0)), win_x, sx))
    for sz in (1, -1):
        A, B = (-(s - hz), sz * hz), ((s - hz), sz * hz)
        walls.append(("z", Wall(m, A, B, (0, -sz)), win_z, sz))
    for kind, wall, wins, sgn in walls:
        L = wall.L
        mid = L / 2
        # orient window offsets in world terms (wall u may run either way); symmetric so it doesn't matter
        ws = [(mid + c, w, SILL, SPRING, SPRING + 9) for c, w in wins]
        wall.build(ws, rng)
        # pilasters between the windows
        cs = sorted([mid + c for c, _ in wins])
        piers = [(a + b) / 2 for a, b in zip(cs[:-1], cs[1:])]
        if layout == "twohg" and kind == "x":
            piers = [mid - 30, mid + 30]
        for u in piers:
            pilaster(m, wall, u, TOP)
    # cut corners
    for (sx, sz) in ((1, 1), (1, -1), (-1, 1), (-1, -1)):
        A = (sx * hx, sz * (s - hx))
        B = (sx * (s - hz), sz * hz)
        inward = (-sx, -sz)
        wall = Wall(m, A, B, inward)
        if (sx, sz) in hearth_corners:
            wall.build([], rng)                    # the fireplace stands here
        else:
            wall.build([(wall.L / 2, 20, SILL - 4, SPRING + 2, SPRING + 16)], rng)
    # rib vault: transverse ribs springing from the wall tops (over the pilasters)
    for z in ribs_x:
        rib(m, (hx - 1.5, z), (-hx + 1.5, z), TOP, VAULT)
    for i, x in enumerate(ribs_z):
        # one rib has fallen in: it ends in a broken stump
        rib(m, (x, hz - 1.5), (x, -hz + 1.5), TOP, VAULT, broken=0.38 if i == 0 else None)
    # diagonal ribs corner to corner
    c = s / 2
    rib(m, (c - 2, c - 2), (-c + 2, -c + 2), TOP, VAULT + 6)
    rib(m, (c - 2, -c + 2), (-c + 2, c - 2), TOP, VAULT + 6, broken=0.62)
    return m


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    build("four").write(os.path.join(OUT, "room.obj"), "# Ruined gothic chapel (tools/make_room.py)\n")
    build("twohg").write(os.path.join(OUT, "room_2hg.obj"), "# Ruined gothic chapel, 2HG (tools/make_room.py)\n")
    print("done")
