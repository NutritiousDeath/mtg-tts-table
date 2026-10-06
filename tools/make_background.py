"""360-degree background (table.lua BACKGROUND_URL): an equirectangular 2:1
image that wraps seamlessly left to right. Dark fantasy night: deep violet /
cyan nebula, stars, a ring of gothic spires on the horizon with a faint
neon rim, mist below. Everything is generated, no outside images.
Run: python tools/make_background.py"""
import os
import numpy as np
from PIL import Image, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "assets", "background", "background.jpg")
W, H = 4096, 2048
rng = np.random.default_rng(7)


def noise3(x, y, z, seed):
    """Smooth value noise on a 3D lattice (trilinear)."""
    r = np.random.default_rng(seed)
    N = 64
    lat = r.random((N, N, N))
    xi, yi, zi = np.floor(x).astype(int), np.floor(y).astype(int), np.floor(z).astype(int)
    xf, yf, zf = x - xi, y - yi, z - zi
    u, v, w = [t * t * (3 - 2 * t) for t in (xf, yf, zf)]
    def L(dx, dy, dz):
        return lat[(xi + dx) % N, (yi + dy) % N, (zi + dz) % N]
    c00 = L(0, 0, 0) * (1 - u) + L(1, 0, 0) * u
    c10 = L(0, 1, 0) * (1 - u) + L(1, 1, 0) * u
    c01 = L(0, 0, 1) * (1 - u) + L(1, 0, 1) * u
    c11 = L(0, 1, 1) * (1 - u) + L(1, 1, 1) * u
    return (c00 * (1 - v) + c10 * v) * (1 - w) + (c01 * (1 - v) + c11 * v) * w


def fbm(theta, y, scale, seed, octaves=6):
    # Sample on a cylinder so the image wraps with no seam.
    out = np.zeros_like(theta)
    amp, tot = 1.0, 0.0
    for o in range(octaves):
        f = scale * (2 ** o)
        out += amp * noise3(np.cos(theta) * f + 17, np.sin(theta) * f + 31, y * f * 2 + 7, seed + o)
        tot += amp
        amp *= 0.5
    return out / tot


# Work at half size, upscale at the end (it's soft anyway).
w, h = W // 2, H // 2
xs = np.linspace(0, 2 * np.pi, w, endpoint=False)
ys = np.linspace(0, 1, h)
theta, yy = np.meshgrid(xs, ys)
horizon = 0.56   # where the horizon sits (0 = top)

# Sky: near black at the top, deep indigo toward the horizon.
t = np.clip(yy / horizon, 0, 1)
sky = np.stack([4 + 20 * t ** 2, 5 + 10 * t ** 2, 12 + 38 * t ** 2], axis=-1)

# Nebula: two colors, strongest in a band above the horizon.
n1 = fbm(theta, yy, 1.2, 1)
n2 = fbm(theta + 1.7, yy, 1.6, 11)
band = np.exp(-((yy - 0.33) / 0.2) ** 2)
violet = np.clip((n1 - 0.45) * 3.0, 0, 1) ** 1.6 * band
cyan = np.clip((n2 - 0.52) * 3.4, 0, 1) ** 1.8 * band
sky += violet[..., None] * np.array([120, 40, 170]) + cyan[..., None] * np.array([20, 150, 170])
wisp = np.clip((fbm(theta, yy, 3.0, 21) - 0.5) * 2.5, 0, 1) * band * 0.5
sky += wisp[..., None] * np.array([60, 30, 90])

img = np.clip(sky, 0, 255)

# Below the horizon: dark ground with a cold mist.
below = yy > horizon
mist = fbm(theta, yy, 2.2, 31) * np.exp(-((yy - horizon) / 0.08) ** 2)
ground = np.stack([6 + 30 * mist, 8 + 45 * mist, 14 + 60 * mist], axis=-1)
img = np.where(below[..., None], ground, img)

# Gothic towers along the horizon (periodic so it wraps): a block body,
# battlements, and a tall needle spire on top; black with a neon rim.
cols = np.zeros(w)
def wrapdist(c):
    return np.abs(((xs - c + np.pi) % (2 * np.pi)) - np.pi)
for count, bh, bw, sh in [(5, (0.07, 0.12), (0.05, 0.08), (0.06, 0.12)),
                          (14, (0.035, 0.065), (0.025, 0.045), (0.03, 0.07)),
                          (34, (0.012, 0.03), (0.010, 0.02), (0.012, 0.035))]:
    for _ in range(count):
        c = rng.random() * 2 * np.pi
        body = bh[0] + rng.random() * (bh[1] - bh[0])
        half = bw[0] + rng.random() * (bw[1] - bw[0])
        spire = sh[0] + rng.random() * (sh[1] - sh[0])
        d = wrapdist(c)
        prof = np.where(d <= half, body, 0.0)
        # battlements: small notches across the top of the body
        notch = (np.floor((xs - c) / (half / 2.5)) % 2 == 0) & (d <= half)
        prof = np.where(notch, prof + body * 0.06, prof)
        # needle spire on top
        sw = half * 0.4
        prof = np.maximum(prof, np.where(d <= sw, body + spire * np.clip(1 - d / sw, 0, 1) ** 1.4, 0.0))
        # two small pinnacles at the corners
        for side in (-1, 1):
            dc = wrapdist(c + side * half * 0.8)
            pw = half * 0.18
            prof = np.maximum(prof, np.where(dc <= pw, body + spire * 0.3 * (1 - dc / pw), 0.0))
        cols = np.maximum(cols, prof)
cols += 0.004 + 0.004 * fbm(xs[None, :], np.zeros((1, w)), 4, 41)[0]
top = horizon - cols   # silhouette top per column
sil = yy >= top[None, :]
rim = np.exp(-((yy - top[None, :]) / 0.0025) ** 2) * (yy >= top[None, :] - 0.01)
img = np.where(sil[..., None] & ~below[..., None], np.array([5, 6, 10]), img)
img += rim[..., None] * np.array([40, 200, 220]) * 0.8

# Stars: denser and brighter toward the top.
stars = np.zeros((h, w))
n = 9000
sx = rng.integers(0, w, n)
sy = (rng.random(n) ** 1.6 * horizon * h * 0.97).astype(int)
stars[sy, sx] = rng.random(n) ** 3 * 255
img += stars[..., None] * (~sil[..., None]) * np.array([0.9, 0.95, 1.0])

out = Image.fromarray(np.clip(img, 0, 255).astype(np.uint8), "RGB")
glow = out.filter(ImageFilter.GaussianBlur(2))
out = Image.blend(out, glow, 0.25).resize((W, H), Image.LANCZOS)
os.makedirs(os.path.dirname(OUT), exist_ok=True)
out.save(OUT, quality=88)
print(OUT)
