"""Fire sounds for the turn fires (Unity: Assets/MTG/Audio): roar.wav (game start / winner) and
whoosh.wav (each turn). Synthesised: filtered noise with envelopes, no samples needed."""
import os
import sys
import wave
import numpy as np

SR = 44100
rng = np.random.default_rng(42)


def lowpass(x, cutoff):
    a = np.exp(-2 * np.pi * cutoff / SR)
    y = np.empty_like(x)
    acc = 0.0
    for i, v in enumerate(x):
        acc = (1 - a) * v + a * acc
        y[i] = acc
    return y


def sweep_band(x, f0, f1):
    """Crude moving band: lowpass at a rising cutoff minus a lower lowpass."""
    n = len(x)
    out = np.empty_like(x)
    lo = hi = 0.0
    for i, v in enumerate(x):
        f = f0 + (f1 - f0) * (i / n)
        ah = np.exp(-2 * np.pi * f / SR)
        al = np.exp(-2 * np.pi * (f * 0.25) / SR)
        hi = (1 - ah) * v + ah * hi
        lo = (1 - al) * v + al * lo
        out[i] = hi - lo
    return out


def env(n, attack, decay_pow):
    t = np.linspace(0, 1, n)
    a = np.clip(t / attack, 0, 1)
    d = (1 - t) ** decay_pow
    return a * d


def save(path, x):
    x = x / (np.abs(x).max() + 1e-9) * 0.9
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes((x * 32767).astype(np.int16).tobytes())


def whoosh():
    n = int(SR * 1.1)
    noise = rng.standard_normal(n)
    body = sweep_band(noise, 300, 2600) * env(n, 0.35, 2.2)
    rumble = lowpass(rng.standard_normal(n), 120) * env(n, 0.2, 3) * 6
    return body + rumble


def roar():
    n = int(SR * 2.6)
    noise = rng.standard_normal(n)
    rush = sweep_band(noise, 200, 3200) * env(n, 0.12, 1.6)
    rumble = lowpass(rng.standard_normal(n), 90) * env(n, 0.06, 1.3) * 9
    crackle = np.zeros(n)
    for _ in range(140):
        i = rng.integers(int(n * 0.1), n - 400)
        crackle[i:i + 200] += rng.standard_normal(200) * np.exp(-np.arange(200) / 30) * rng.uniform(0.3, 1)
    crackle *= env(n, 0.2, 1.5) * 0.6
    return rush + rumble + crackle


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "."
    os.makedirs(out, exist_ok=True)
    save(os.path.join(out, "whoosh.wav"), whoosh())
    save(os.path.join(out, "roar.wav"), roar())
    print("done")
