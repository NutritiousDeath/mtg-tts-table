"""Flame flipbook for the stack mat's ring of fire (tools/unity/MTGTorchBuilder.cs BuildStackFire): 4 x 4
frames of a single flame tongue, each a little different (a flickering, licking shape), white on
transparent so the particle colour tints it. Writes unity/Assets/MTG/Textures/flame_sheet.png (512 x 512).
Run: python tools/make_flame_sheet.py"""
import os
import numpy as np
from PIL import Image, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "unity", "Assets", "MTG", "Textures", "flame_sheet.png")
N, F = 4, 128          # frames per side, frame size in px

rng = np.random.default_rng(7)


def smooth_noise(n, k, seed):
    r = np.random.default_rng(seed)
    pts = r.normal(0, 1, k + 3)
    xs = np.linspace(0, k, n)
    i = np.floor(xs).astype(int)
    t = xs - i
    t = t * t * (3 - 2 * t)
    return pts[i] * (1 - t) + pts[i + 1] * t


def frame(idx):
    ys = np.linspace(0, 1, F)[:, None]          # 0 at the top of the frame, 1 at the bottom
    xs = np.linspace(-1, 1, F)[None, :]
    t = 1 - ys                                   # height up the flame: 0 at the base, 1 at the tip
    # The tongue's centre line sways, more toward the tip; its half width swells near the base and
    # narrows to a point at the tip.
    sway = (smooth_noise(F, 3, idx * 11 + 1) * 0.22)[:, None] * (t ** 1.4)
    lean = (rng.uniform(-0.12, 0.12)) * t ** 2
    half = 0.8 * np.sin(np.pi * np.clip(t * 0.8 + 0.2, 0, 1)) ** 0.6 * (1 - t) ** 0.55
    half *= 1 + (smooth_noise(F, 5, idx * 7 + 3) * 0.18)[:, None]
    d = np.abs(xs - sway - lean) / np.maximum(half, 1e-3)
    shape = np.clip(1 - d, 0, 1) ** 1.2
    # Fade in at the very bottom, out toward the tip; brightest low in the middle.
    shape *= np.clip(t / 0.06, 0, 1) * np.clip((1 - t) / 0.45, 0, 1) ** 0.7
    core = np.clip(1 - d * 1.6, 0, 1) * np.clip(1 - t * 1.4, 0, 1) * np.clip(t / 0.06, 0, 1)
    # A little licking texture inside.
    lick = 0.93 + 0.07 * np.sin(ys * 14 + idx * 1.7 + xs * 4)
    a = np.clip(shape * lick * 0.9 + core * 0.4, 0, 1)
    v = np.clip(shape * 0.8 + core * 0.9, 0, 1)
    img = np.zeros((F, F, 4), dtype=np.uint8)
    img[..., 0] = img[..., 1] = img[..., 2] = (v * 255).astype(np.uint8)
    img[..., 3] = (a * 255).astype(np.uint8)
    im = Image.fromarray(img, "RGBA").filter(ImageFilter.GaussianBlur(1.6))
    return im


if __name__ == "__main__":
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    sheet = Image.new("RGBA", (N * F, N * F), (0, 0, 0, 0))
    for k in range(N * N):
        sheet.paste(frame(k), ((k % N) * F, (k // N) * F))
    sheet.save(OUT)
    print("wrote", OUT)
