"""Dragon heads for the Planechase dice tower (tools/unity/MTGDiceTowerBuilder.cs).

Source: "Dragon Head | Retopologized version" by gozdemrl
  https://sketchfab.com/3d-models/dragon-head-retopologized-version-1ea43925e5b34075a0d6f8bc7c6916b8
  licensed under CC-BY-4.0 (http://creativecommons.org/licenses/by/4.0/)
  -> unity/Assets/MTG/Models/dragon_head__retopologized_version.glb (the 2k GLB from Sketchfab)

The sculpt's mouth is closed, so this opens it: the head is cut along the jaw line and everything above
the cut (skull, upper teeth, eyes) is hinged up about a point at the back of the head, like a dragon
roaring. The lower jaw stays flat; its cut face becomes the tongue (where the die comes to rest) and the
upper cut face the roof of the mouth (both a separate dark "mouth" mesh). The artist's paint is turned to
the table's blue-grey stone (keeping all the carved detail and the normal map), so the heads read as
stone statues that match the table.

Output (unity/Assets/MTG/Models/Dragon/): dragon_body.obj, dragon_teeth.obj, dragon_eyes.obj,
dragon_mouth.obj, dragon_body_albedo.png, dragon_body_normal.png, dragon_teeth_albedo.png,
dragon_teeth_normal.png, and dragon_head.json (where the eyes, the tongue and the mouth are, in the
head's own units: x across, y up from its lowest point, z forward from the back of the head).

Run: python tools/make_dragon_head.py   (needs: pip install trimesh shapely mapbox_earcut pillow)
"""
import json
import os
import sys

import numpy as np
import trimesh
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "unity", "Assets", "MTG", "Models", "dragon_head__retopologized_version.glb")
OUT = os.path.join(ROOT, "unity", "Assets", "MTG", "Models", "Dragon")
if len(sys.argv) > 2:
    SRC, OUT = sys.argv[1], sys.argv[2]

JAW_Y = -98.0        # the jaw line (model units): the cut
HINGE_Z = -110.0     # the hinge, at the back of the head
OPEN_DEG = 24.0      # how far the upper head lifts
SCALE = 0.015        # model units -> table units (the head comes out about 9 long)
TEX = 1024           # texture size

STONE = np.array([0.16, 0.21, 0.27])     # the table's stone (assets/table/stone.png averages about this)
BONE = np.array([0.62, 0.62, 0.60])


def load():
    s = trimesh.load(SRC)
    parts = {}
    for name in s.graph.nodes_geometry:
        T, g = s.graph[name]
        m = s.geometry[g].copy()
        m.apply_transform(T)
        parts[g] = m
    return parts["defaultMaterial_2"], parts["defaultMaterial_1"], parts["defaultMaterial"]


def lift(m):
    R = trimesh.transformations.rotation_matrix(np.radians(-OPEN_DEG), [1, 0, 0], [0, JAW_Y, HINGE_Z])
    m = m.copy()
    m.apply_transform(R)
    return m


def lift_points(p):
    R = trimesh.transformations.rotation_matrix(np.radians(-OPEN_DEG), [1, 0, 0], [0, JAW_Y, HINGE_Z])
    return trimesh.transform_points(np.atleast_2d(p), R)


def caps(head):
    """The cut face (y = JAW_Y), triangulated: returns (tongue facing up, roof of the mouth facing down)."""
    sec = head.section(plane_origin=[0, JAW_Y, 0], plane_normal=[0, 1, 0])
    planar, to3d = sec.to_2D()
    vs, fs, off = [], [], 0
    for poly in planar.polygons_full:
        v2, f = trimesh.creation.triangulate_polygon(poly)
        v3 = trimesh.transform_points(np.column_stack([v2, np.zeros(len(v2))]), to3d)
        vs.append(v3)
        fs.append(f + off)
        off += len(v3)
    cap = trimesh.Trimesh(np.vstack(vs), np.vstack(fs), process=False)
    cap.vertices[:, 1] = JAW_Y
    up = cap.copy()
    if up.face_normals[:, 1].mean() < 0:
        up.invert()
    down = cap.copy()
    if down.face_normals[:, 1].mean() > 0:
        down.invert()
    return up, down


def stone_tex(img, base, contrast):
    a = np.asarray(img.convert("RGB").resize((TEX, TEX), Image.LANCZOS)).astype(float) / 255
    lum = a @ np.array([0.3, 0.59, 0.11])
    lo, hi = np.percentile(lum, 2), np.percentile(lum, 98)
    t = np.clip((lum - lo) / max(hi - lo, 1e-3), 0, 1)
    rgb = base[None, None, :] * (0.45 + contrast * t[..., None])
    return Image.fromarray((np.clip(rgb, 0, 1) * 255).astype(np.uint8), "RGB")


def write_obj(path, m, with_uv):
    m = m.copy()
    v = m.vertices
    n = m.vertex_normals
    with open(path, "w") as fh:
        fh.write("# Dragon head for the Planechase dice tower (tools/make_dragon_head.py). Based on \"Dragon Head | "
                 "Retopologized version\" by gozdemrl, CC-BY-4.0.\n")
        for p in v:
            fh.write("v %.5f %.5f %.5f\n" % tuple(p))
        if with_uv:
            for t in m.visual.uv:
                fh.write("vt %.5f %.5f\n" % (t[0], t[1]))
        for q in n:
            fh.write("vn %.4f %.4f %.4f\n" % tuple(q))
        for f in m.faces + 1:
            if with_uv:
                fh.write("f %d/%d/%d %d/%d/%d %d/%d/%d\n" % (f[0], f[0], f[0], f[1], f[1], f[1], f[2], f[2], f[2]))
            else:
                fh.write("f %d//%d %d//%d %d//%d\n" % (f[0], f[0], f[1], f[1], f[2], f[2]))


def main():
    os.makedirs(OUT, exist_ok=True)
    head, teeth, eyes = load()
    upper = head.slice_plane([0, JAW_Y, 0], [0, 1, 0])
    lower = head.slice_plane([0, JAW_Y, 0], [0, -1, 0])
    tongue, roof = caps(head)
    up_t, lo_t = [], []
    for t in teeth.split(only_watertight=False):
        (lo_t if t.vertices[:, 1].max() <= JAW_Y + 1 else up_t).append(t)
    body = trimesh.util.concatenate([lift(upper), lower])
    teeth_out = trimesh.util.concatenate([lift(t) for t in up_t] + lo_t)
    eyes_out = lift(eyes)
    mouth = trimesh.util.concatenate([tongue, lift(roof)])
    # Where things are (model units), before moving into the head's own frame.
    eye_l = lift_points([66.0, 6.7, 66.0])[0]
    eye_r = lift_points([-66.0, 6.7, 66.0])[0]
    eye_out_l = lift_points([86.0, 8.0, 70.0])[0]      # just outside each eye: where its fire burns
    eye_out_r = lift_points([-86.0, 8.0, 70.0])[0]
    roof_front = lift_points([0.0, JAW_Y, 360.0])[0]
    mouth_pt = np.array([0.0, (JAW_Y + roof_front[1]) / 2, 360.0])
    # Into the head's frame: lowest point at y = 0, back of the head at z = 0, then scaled.
    allv = np.vstack([body.vertices, teeth_out.vertices, eyes_out.vertices])
    shift = np.array([0.0, -allv[:, 1].min(), -allv[:, 2].min()])

    def tf(p):
        return ((np.asarray(p) + shift) * SCALE).tolist()

    for m in (body, teeth_out, eyes_out, mouth):
        m.vertices = (m.vertices + shift) * SCALE
    # The interior of the mouth: how wide the tongue is along its length.
    sec = head.section(plane_origin=[0, JAW_Y, 0], plane_normal=[0, 1, 0]).vertices
    halfw = []
    for z in range(60, 380, 20):
        sel = sec[np.abs(sec[:, 2] - z) < 8]
        if len(sel):
            halfw.append(float(np.abs(sel[:, 0]).max()))
    meta = {
        "scale": SCALE,
        "open_deg": OPEN_DEG,
        "length": float(body.vertices[:, 2].max()),
        "width": float(body.vertices[:, 0].max() - body.vertices[:, 0].min()),
        "height": float(max(body.vertices[:, 1].max(), teeth_out.vertices[:, 1].max())),
        "tongue_y": (JAW_Y + shift[1]) * SCALE,
        "hinge_z": (HINGE_Z + shift[2]) * SCALE,
        "tongue_half_width": min(halfw) * SCALE,
        "tongue_front_z": (370.0 + shift[2]) * SCALE,
        "rest_z": (330.0 + shift[2]) * SCALE,          # where the die comes to rest on the tongue
        "eye_left": tf(eye_l), "eye_right": tf(eye_r),
        "eye_fire_left": tf(eye_out_l), "eye_fire_right": tf(eye_out_r),
        "mouth": tf(mouth_pt),
        "breath_pitch_deg": OPEN_DEG / 2,
        "gap_at": {str(z): (z - HINGE_Z) * np.sin(np.radians(OPEN_DEG)) * SCALE for z in (0, 100, 200, 300, 360)},
    }
    write_obj(os.path.join(OUT, "dragon_body.obj"), body, True)
    write_obj(os.path.join(OUT, "dragon_teeth.obj"), teeth_out, True)
    write_obj(os.path.join(OUT, "dragon_eyes.obj"), eyes_out, False)
    write_obj(os.path.join(OUT, "dragon_mouth.obj"), mouth, False)
    stone_tex(head.visual.material.baseColorTexture, STONE * 1.25, 1.35).save(os.path.join(OUT, "dragon_body_albedo.png"))
    head.visual.material.normalTexture.convert("RGB").resize((TEX, TEX), Image.LANCZOS).save(
        os.path.join(OUT, "dragon_body_normal.png"))
    stone_tex(teeth.visual.material.baseColorTexture, BONE, 0.9).save(os.path.join(OUT, "dragon_teeth_albedo.png"))
    teeth.visual.material.normalTexture.convert("RGB").resize((TEX, TEX), Image.LANCZOS).save(
        os.path.join(OUT, "dragon_teeth_normal.png"))
    with open(os.path.join(OUT, "dragon_head.json"), "w") as fh:
        json.dump(meta, fh, indent=2)
    print(json.dumps(meta, indent=2))
    print("faces: body %d teeth %d eyes %d mouth %d" % (len(body.faces), len(teeth_out.faces), len(eyes_out.faces),
                                                         len(mouth.faces)))


if __name__ == "__main__":
    main()
