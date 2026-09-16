#!/usr/bin/env python3
"""Процедурна музика головного меню → godot/assets/audio/menu_theme.wav.

Власний трек без сторонніх семплів і ліцензій: ембієнт у ре-мінорі, 60 с безшовної петлі.
Шари: пед (адитивний синтез, розстроєні голоси, повільне «відкриття фільтра»), бас, рідкі
дзвіночки з ехо, тихий сонарний пінг раз на два такти, повітря. Реверб — багатотапова лінія
затримок з циклічним зсувом, тож хвости переходять через кінець петлі без шва.
Запуск: tools/.venv/bin/python3 tools/make_menu_music.py
"""
import wave
from pathlib import Path

import numpy as np

SR = 44100
BPM = 64
BEAT = 60.0 / BPM
CHORD = 8 * BEAT                      # два такти на акорд
OUT = Path(__file__).resolve().parent.parent / "godot" / "assets" / "audio" / "menu_theme.wav"
rng = np.random.default_rng(1971)

# (бас, голоси педу) — MIDI; останній акорд: sus4 → A (розв'язання в тоніку петлі)
CHORDS = [
    (38, [50, 53, 57, 64]),   # Dm(add9)
    (34, [53, 57, 58, 62]),   # Bbmaj7
    (33, [53, 57, 60, 64]),   # F/A
    (36, [55, 60, 62, 67]),   # Csus2
    (38, [53, 57, 62, 64]),   # Dm
    (31, [53, 58, 62, 67]),   # Gm7
    (34, [53, 58, 60, 62]),   # Bb(add9)
    (33, [52, 57, 62, 64]),   # Asus4 (друга половина — A)
]
LOOP = len(CHORDS) * CHORD
TAIL = 7.0
N = int((LOOP + TAIL) * SR)
L = int(LOOP * SR)
mix = np.zeros((2, N))


def hz(m: float) -> float:
    return 440.0 * 2.0 ** ((m - 69) / 12.0)


def seg(t0: float, dur: float):
    a = int(t0 * SR)
    n = int(dur * SR)
    return a, np.arange(n) / SR


def env_ar(t: np.ndarray, attack: float, hold: float, release: float) -> np.ndarray:
    e = np.ones_like(t)
    up = t < attack
    e[up] = 0.5 - 0.5 * np.cos(np.pi * t[up] / attack)
    down = t > hold
    e[down] = 0.5 + 0.5 * np.cos(np.pi * np.clip((t[down] - hold) / release, 0, 1))
    return e


def add(ch_gain, a: int, sig: np.ndarray) -> None:
    b = min(a + sig.size, N)
    mix[0, a:b] += sig[: b - a] * ch_gain[0]
    mix[1, a:b] += sig[: b - a] * ch_gain[1]


# ---- пед ----
for ci, (bass, notes) in enumerate(CHORDS):
    t0 = ci * CHORD
    dur = CHORD + 3.0
    a, t = seg(t0, dur)
    env = env_ar(t, 2.2, CHORD + 0.4, 2.6)
    lfo = 0.5 + 0.5 * np.sin(2 * np.pi * (t + t0) / 23.0)          # повільне «дихання» тембру
    for ni, m in enumerate(notes):
        if ci == 7 and ni == 2:                                       # sus4 (D) → терція (C#) на півдорозі
            f_curve = np.where(t < CHORD * 0.5, hz(m), hz(m - 1))
        else:
            f_curve = np.full_like(t, hz(m))
        for vi, cents in enumerate((-7.0, 0.0, 7.0)):
            f = f_curve * 2 ** (cents / 1200.0)
            ph = 2 * np.pi * np.cumsum(f) / SR + rng.uniform(0, 2 * np.pi)
            s = np.zeros_like(t)
            for h in range(1, 8):
                bright = 1.0 if h <= 2 else (0.25 + 0.45 * lfo)
                s += np.sin(ph * h) * (1.0 / h) ** 1.35 * bright
            pan = 0.5 + 0.28 * (vi - 1) + 0.06 * (ni - 1.5)
            g = 0.034 * env
            add((np.sqrt(1 - pan) * 1.0, np.sqrt(pan) * 1.0), a, s * g)

# ---- бас ----
for ci, (bass, _) in enumerate(CHORDS):
    a, t = seg(ci * CHORD, CHORD + 2.0)
    env = env_ar(t, 1.4, CHORD - 0.2, 2.0)
    f = hz(bass)
    s = np.sin(2 * np.pi * f * t) + 0.28 * np.sin(4 * np.pi * f * t) + 0.08 * np.sin(6 * np.pi * f * t)
    add((0.7, 0.7), a, s * 0.16 * env)

# ---- дзвіночки: восьмі на тонах акорду вгорі, рідко, з ехо ----
EIGHTH = BEAT / 2
for ci, (_, notes) in enumerate(CHORDS):
    for k in range(16):
        if rng.random() > 0.34:
            continue
        m = int(rng.choice(notes)) + int(rng.choice([12, 12, 24]))
        if ci == 7 and k >= 8 and m % 12 == 2:
            m -= 1                                                     # у розв'язанні — C#
        vel = rng.uniform(0.45, 1.0)
        pan = rng.uniform(0.2, 0.8)
        for tap, (dly, gain, flip) in enumerate([(0.0, 1.0, False), (EIGHTH * 3, 0.32, True), (EIGHTH * 6, 0.12, False)]):
            a, t = seg(ci * CHORD + k * EIGHTH + dly, 3.2)
            f = hz(m)
            s = (np.sin(2 * np.pi * f * t) + 0.35 * np.sin(2 * np.pi * f * 2.01 * t) * np.exp(-t * 2.5)
                 + 0.12 * np.sin(2 * np.pi * f * 3.0 * t) * np.exp(-t * 4.0))
            s *= np.exp(-t * 1.7) * (1 - np.exp(-t * 400))
            p = 1 - pan if flip else pan
            add((np.sqrt(1 - p), np.sqrt(p)), a, s * 0.030 * vel * gain)

# ---- сонарний пінг раз на два акорди ----
for ci in range(0, len(CHORDS), 2):
    for dly, gain in [(0.0, 1.0), (0.62, 0.3), (1.24, 0.1)]:
        a, t = seg(ci * CHORD + BEAT * 2 + dly, 2.5)
        f = 1318.5 * (1 - 0.012 * (1 - np.exp(-t * 6)))
        s = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t * 2.8) * (1 - np.exp(-t * 300))
        add((0.55, 0.45) if dly == 0 else (0.35, 0.65), a, s * 0.014 * gain)

# ---- повітря: згладжений шум з повільною модуляцією ----
noise = rng.standard_normal((2, N))
k = np.ones(64) / 64
for c in range(2):
    noise[c] = np.convolve(noise[c], k, mode="same")
tt = np.arange(N) / SR
mix += noise * (0.010 + 0.006 * np.sin(2 * np.pi * tt / 17.0))

# ---- петля: хвіст за кінцем додається на початок ----
loop = mix[:, :L].copy()
loop[:, : N - L] += mix[:, L:]

# ---- реверб: багатотапова циклічна затримка ----
wet = np.zeros_like(loop)
for i in range(46):
    d = rng.uniform(0.021, 1.9)
    g = 0.34 * np.exp(-d / 0.85) * rng.uniform(0.6, 1.0)
    src = i % 2
    dst = (i // 2) % 2
    wet[dst] += np.roll(loop[src], int(d * SR)) * g
for c in range(2):
    wet[c] = np.convolve(np.concatenate([wet[c][-32:], wet[c]]), np.ones(32) / 32, mode="valid")[: L]
out = loop * 0.78 + wet * 0.62

# ---- мастеринг ----
out = np.tanh(out * 1.35) / np.tanh(1.35)
out *= 0.89 / np.max(np.abs(out))
OUT.parent.mkdir(parents=True, exist_ok=True)
pcm = (out.T * 32767).astype("<i2")
with wave.open(str(OUT), "wb") as w:
    w.setnchannels(2)
    w.setsampwidth(2)
    w.setframerate(SR)
    w.writeframes(pcm.tobytes())
jump = np.abs(out[:, 0] - out[:, -1]).max()
print(f"{OUT.name}: {LOOP:.1f} с, пік {np.max(np.abs(out)):.2f}, стрибок на шві петлі {jump:.4f}, "
      f"RMS {20 * np.log10(np.sqrt(np.mean(out ** 2))):.1f} dBFS")
