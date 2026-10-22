"""A roof for the chapel (table.lua TableSetup.ensureRoof): only shown while TTS's own Flip throws the
chapel around, with a parting message painted on top (a different one every flip).

A flat eight-sided stone lid just above the rib vault, plus a band from the wall tops up to it, so from
above the chapel looks closed. Every face points OUTWARD only: TTS doesn't draw the back of a face, so
from inside the chapel it isn't there at all.

Output: assets/room/roof.obj (four / two / three seats) and roof_2hg.obj, world units, floor top at y = 0.
Shares the chapel's sizes with tools/make_room.py.
"""
import os
import numpy as np
from make_room import Mesh, octagon, TILE, T, TOP, VAULT

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "assets", "room")
LID = TOP + VAULT + 10.0      # the lid sits just above the highest rib (the diagonal ribs reach VAULT + 6)
BAND_FROM = TOP - 6.0         # the band starts a little below the ragged wall tops


def build(layout):
    if layout == "four":
        hx, hz, d = 140.0, 140.0, 155.0
    else:
        hx, hz, d = 150.0, 140.0, 165.0
    # The outside of the walls: T further out than their inner faces.
    corners = []
    for a, b in octagon(hx + T, hz + T, d + T):
        corners += [a, b]
    # In order round the middle (the octagon helper gives each corner's two points, not in ring order).
    corners.sort(key=lambda p: np.arctan2(p[1], p[0]))
    m = Mesh()
    # The lid, facing up.
    pts = [(x, LID, z) for x, z in corners]
    uvs = [(x / TILE, z / TILE) for x, z in corners]
    m.face(pts, uvs, np.array([0, 1.0, 0]))
    # The band round it, facing out.
    n = len(corners)
    run = 0.0
    for i in range(n):
        (x0, z0), (x1, z1) = corners[i], corners[(i + 1) % n]
        L = float(np.hypot(x1 - x0, z1 - z0))
        if L < 1e-4:
            continue
        mx, mz = (x0 + x1) / 2, (z0 + z1) / 2
        out = np.array([mx, 0.0, mz])
        out /= np.linalg.norm(out)
        p = [(x0, BAND_FROM, z0), (x1, BAND_FROM, z1), (x1, LID, z1), (x0, LID, z0)]
        t = [(run / TILE, BAND_FROM / TILE), ((run + L) / TILE, BAND_FROM / TILE),
             ((run + L) / TILE, LID / TILE), (run / TILE, LID / TILE)]
        m.face(p, t, out)
        run += L
    return m


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    build("four").write(os.path.join(OUT, "roof.obj"), "# Chapel roof, shown during a TTS flip (tools/make_roof.py)\n")
    build("twohg").write(os.path.join(OUT, "roof_2hg.obj"), "# Chapel roof, 2HG (tools/make_roof.py)\n")
    print("done", LID)
