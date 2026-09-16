#!/usr/bin/env python3
"""Музична лабораторія меню: 5 варіантів треку за брифом
«епічно · військова перкусія · радіоефір і сонар · хвилями».

Усе синтезується з нуля (numpy), без семплів і ліцензій. Кожен трек — рівно 60 с безшовної петлі:
хвости подій за кінцем петлі дописуються на початок, реверб — циклічна багатотапова затримка.
Запуск:  tools/.venv/bin/python3 tools/music_lab.py <вихідна_тека> [номер_варіанта]
"""
import sys
import wave
from pathlib import Path

import numpy as np

SR = 44100
LOOP_S = 60.0
TAIL_S = 8.0


# ============================ ядро ============================

class Track:
    def __init__(self, seed: int):
        self.L = int(LOOP_S * SR)
        self.N = int((LOOP_S + TAIL_S) * SR)
        self.buf = np.zeros((2, self.N))
        self.rng = np.random.default_rng(seed)

    def add(self, t0: float, sig: np.ndarray, pan: float = 0.5, gain: float = 1.0) -> None:
        a = int(t0 % LOOP_S * SR)
        b = min(a + sig.size, self.N)
        s = sig[: b - a] * gain
        self.buf[0, a:b] += s * np.sqrt(1.0 - pan)
        self.buf[1, a:b] += s * np.sqrt(pan)

    def finish(self, wet: float = 0.45, rev_len: float = 1.6, bright: int = 12, keys=None) -> np.ndarray:
        out = self.buf[:, : self.L].copy()
        out[:, : self.N - self.L] += self.buf[:, self.L:]
        if keys is not None:
            # хвилі: загальна гучність іде за кривою напруги (спади ~ −9 дБ відносно піків)
            grid = np.linspace(0, LOOP_S, 1200)
            g = np.interp(np.arange(self.L) / SR, grid, [0.35 + 0.65 * curve(keys, x) for x in grid])
            out *= g
        rev = np.zeros_like(out)
        for i in range(64):
            d = self.rng.uniform(0.013, rev_len * 1.8)
            g = np.exp(-d / (rev_len * 0.55)) * self.rng.uniform(0.55, 1.0) * 0.22
            rev[(i // 2) % 2] += np.roll(out[i % 2], int(d * SR)) * g
        k = np.ones(bright) / bright
        for c in range(2):
            rev[c] = np.convolve(np.concatenate([rev[c][-bright:], rev[c]]), k, mode="valid")[: self.L]
        mix = out + rev * wet
        rms = np.sqrt(np.mean(mix ** 2))
        mix *= 10 ** (-15.0 / 20) / max(rms, 1e-9)            # рівна гучність усіх варіантів
        mix = np.tanh(mix * 1.15) / np.tanh(1.15)
        return mix * (0.95 / max(np.max(np.abs(mix)), 1e-9))


def T(dur: float) -> np.ndarray:
    return np.arange(int(dur * SR)) / SR


def hz(m: float) -> float:
    return 440.0 * 2.0 ** ((m - 69) / 12.0)


def phase(f) -> np.ndarray:
    return 2 * np.pi * np.cumsum(f) / SR


def fir_lp(fc: float, taps: int = 255) -> np.ndarray:
    n = np.arange(taps) - (taps - 1) / 2
    h = np.sinc(2 * fc / SR * n) * np.blackman(taps)
    return h / h.sum()


def bandpass(x: np.ndarray, lo: float, hi: float) -> np.ndarray:
    return np.convolve(x, fir_lp(hi) - fir_lp(lo), mode="same")


def highpass(x: np.ndarray, fc: float) -> np.ndarray:
    return x - np.convolve(x, fir_lp(fc), mode="same")


def curve(keys, t: float) -> float:
    """Гладка крива інтенсивності за ключами [(секунда, рівень)], перша і остання точки однакові."""
    for (t0, v0), (t1, v1) in zip(keys, keys[1:]):
        if t0 <= t <= t1:
            u = (t - t0) / max(t1 - t0, 1e-6)
            return v0 + (v1 - v0) * (0.5 - 0.5 * np.cos(np.pi * u))
    return keys[-1][1]


# ============================ інструменти ============================

def taiko(tr: Track, t0, pitch=58.0, vel=1.0, pan=0.5):
    t = T(1.6)
    f = pitch * (1 + 1.6 * np.exp(-t * 26))
    body = np.sin(phase(f)) * np.exp(-t * 4.2)
    sub = np.sin(2 * np.pi * pitch * 0.5 * t) * np.exp(-t * 2.6) * 0.5
    skin = np.convolve(tr.rng.standard_normal(t.size) * np.exp(-t * 45), fir_lp(2500, 63), mode="same") * 0.9
    tr.add(t0, np.tanh((body + sub + skin) * 1.6), pan, 0.55 * vel)


def tom(tr: Track, t0, pitch=120.0, vel=1.0, pan=0.5):
    t = T(0.9)
    f = pitch * (1 + 0.9 * np.exp(-t * 30))
    s = np.sin(phase(f)) * np.exp(-t * 7.5)
    s += np.convolve(tr.rng.standard_normal(t.size) * np.exp(-t * 60), fir_lp(4000, 63), mode="same") * 0.5
    tr.add(t0, s, pan, 0.32 * vel)


def snare(tr: Track, t0, vel=1.0, pan=0.5):
    t = T(0.45)
    n = bandpass(tr.rng.standard_normal(t.size), 900, 9000) * np.exp(-t * 13)
    tone = np.sin(2 * np.pi * 185 * t) * np.exp(-t * 22) * 0.6
    tr.add(t0, n * 1.4 + tone, pan, 0.22 * vel)


def kick(tr: Track, t0, vel=1.0):
    t = T(0.8)
    f = 48 * (1 + 2.2 * np.exp(-t * 35))
    tr.add(t0, np.tanh(np.sin(phase(f)) * np.exp(-t * 6.5) * 2.0), 0.5, 0.45 * vel)


def crash(tr: Track, t0, vel=1.0, swell=0.0):
    if swell > 0:
        t = T(swell)
        n = highpass(tr.rng.standard_normal(t.size), 3500) * (t / swell) ** 3
        tr.add(t0 - swell, n, 0.5, 0.10 * vel)
    t = T(4.0)
    n = highpass(tr.rng.standard_normal(t.size), 4000) * np.exp(-t * 1.1)
    tr.add(t0, n, 0.35, 0.10 * vel)
    tr.add(t0 + 0.011, highpass(tr.rng.standard_normal(t.size), 4200) * np.exp(-t * 1.1), 0.65, 0.10 * vel)


def impact(tr: Track, t0, vel=1.0):
    t = T(3.0)
    f = 62 * np.exp(-t * 0.7) + 24
    s = np.sin(phase(f)) * np.exp(-t * 1.3)
    s += np.convolve(tr.rng.standard_normal(t.size) * np.exp(-t * 9), fir_lp(900, 127), mode="same") * 1.5
    tr.add(t0, np.tanh(s * 1.8), 0.5, 0.55 * vel)


def braam(tr: Track, t0, notes, dur=3.5, vel=1.0, attack=0.25, dark=False):
    t = T(dur + 2.0)
    env = np.clip(t / attack, 0, 1) ** 1.5 * np.where(t < dur, 1.0, np.exp(-(t - dur) * 2.2))
    for m in notes:
        for cents, pan in ((-9, 0.3), (0, 0.5), (9, 0.7)):
            f = hz(m) * 2 ** (cents / 1200)
            ph = phase(np.full(t.size, f)) + tr.rng.uniform(0, 6.28)
            s = np.zeros_like(t)
            top = 9 if dark else 14
            for h in range(1, top):
                bright = np.clip(env * 1.2 - (h / top) * 0.9, 0, 1)
                s += np.sin(ph * h) / h * bright
            tr.add(t0, np.tanh(s * env * 1.4), pan, 0.075 * vel / len(notes) ** 0.5)


def pad(tr: Track, t0, notes, dur, vel=1.0):
    t = T(dur + 3.0)
    env = np.clip(t / 1.8, 0, 1) * np.where(t < dur, 1.0, np.exp(-(t - dur) * 1.2))
    for i, m in enumerate(notes):
        for cents, pan in ((-6, 0.25), (6, 0.75)):
            ph = phase(np.full(t.size, hz(m) * 2 ** (cents / 1200))) + tr.rng.uniform(0, 6.28)
            s = sum(np.sin(ph * h) * (1 / h) ** 1.6 for h in range(1, 6))
            tr.add(t0, s * env, pan, 0.022 * vel)


def ostinato(tr: Track, t0, m, dur=0.2, vel=1.0, pan=0.5):
    t = T(dur + 0.25)
    env = np.clip(t / 0.008, 0, 1) * np.exp(-t * (5.0 / dur))
    ph = phase(np.full(t.size, hz(m)))
    s = sum(np.sin(ph * h) / h * (0.85 ** h) for h in range(1, 11))
    tr.add(t0, s * env, pan, 0.07 * vel)


def horn(tr: Track, t0, m, dur, vel=1.0, pan=0.5):
    t = T(dur + 1.0)
    vib = 1 + 0.004 * np.sin(2 * np.pi * 5.2 * t) * np.clip((t - 0.25) / 0.3, 0, 1)
    env = np.clip(t / 0.09, 0, 1) * np.where(t < dur, 1.0, np.exp(-(t - dur) * 5))
    ph = phase(hz(m) * vib)
    s = sum(np.sin(ph * h) * (0.62 ** h) * (1 + 0.6 * env * (h > 2)) for h in range(1, 9))
    tr.add(t0, np.tanh(s * 1.3) * env, pan, 0.10 * vel)


def ping(tr: Track, t0, f=1318.5, vel=1.0, pan=0.5):
    t = T(3.0)
    s = np.sin(phase(f * (1 - 0.01 * (1 - np.exp(-t * 5))))) * np.exp(-t * 2.4) * (1 - np.exp(-t * 300))
    for dly, g, p in ((0, 1, pan), (0.55, 0.32, 1 - pan), (1.1, 0.12, pan)):
        tr.add(t0 + dly, s, p, 0.05 * vel * g)


def radio(tr: Track, t0, dur, vel=1.0, pan=0.3):
    """Уривок переговорів: смуговий шум 400–2800 Гц із «складовою» АМ і клацанням шумоподавлювача."""
    t = T(dur)
    n = bandpass(tr.rng.standard_normal(t.size), 400, 2800)
    syl = np.clip(np.sin(2 * np.pi * tr.rng.uniform(3.5, 6.5) * t + tr.rng.uniform(0, 6)) * 1.4 + 0.2, 0, 1)
    gate = np.clip(np.sin(np.pi * t / dur) * 3, 0, 1)
    carrier = np.sin(2 * np.pi * tr.rng.uniform(160, 260) * t) * 0.35
    s = (n * 0.8 + carrier) * syl * gate
    s = np.round(s * 9) / 9                                         # легкий «цифровий» бітрейт
    tr.add(t0, s, pan, 0.045 * vel)
    tc = T(0.05)
    tr.add(t0 + dur, highpass(tr.rng.standard_normal(tc.size), 1500) * np.exp(-tc * 60), pan, 0.06 * vel)


def morse(tr: Track, t0, code: str, unit=0.075, f=760.0, vel=1.0, pan=0.7):
    tt = t0
    for ch in code:
        if ch in ".-":
            d = unit if ch == "." else unit * 3
            t = T(d)
            s = np.sin(2 * np.pi * f * t) * np.clip(np.minimum(t, d - t) / 0.004, 0, 1)
            tr.add(tt, s, pan, 0.035 * vel)
            tt += d + unit
        else:
            tt += unit * 3


def glitch(tr: Track, t0, dur=0.35, vel=1.0, pan=0.5):
    t = T(dur)
    hold = np.repeat(tr.rng.standard_normal(int(dur * 60) + 1), SR // 60)[: t.size]
    s = np.sign(np.sin(2 * np.pi * tr.rng.uniform(300, 1200) * t)) * hold * (tr.rng.random(t.size) > 0.2)
    tr.add(t0, np.convolve(s, fir_lp(5000, 31), mode="same") * np.exp(-t * 4), pan, 0.03 * vel)


def tick(tr: Track, t0, vel=1.0, pan=0.5):
    t = T(0.04)
    tr.add(t0, bandpass(tr.rng.standard_normal(t.size), 2500, 9000) * np.exp(-t * 180), pan, 0.18 * vel)


# ============================ композиції ============================

def v1_pozyvnyi() -> np.ndarray:
    """96 BPM, ре-мінор: драйвові тайко, остинато низьких струнних, переговори в ефірі."""
    tr = Track(101)
    beat = 60 / 96
    bar = 4 * beat
    I = [(0, 0.2), (9, 0.25), (24, 1.0), (33, 0.95), (39, 0.35), (45, 1.0), (54, 0.9), (60, 0.2)]
    prog = [38, 38, 34, 34, 41, 41, 36, 36, 38, 38, 34, 33]                   # корені по 2 такти
    tri = {38: [50, 53, 57], 34: [46, 50, 53], 41: [53, 57, 60], 36: [48, 52, 55], 33: [45, 49, 52]}
    for bi in range(24):
        t0 = bi * bar
        root = prog[bi // 2]
        lv = curve(I, t0 + bar / 2)
        if bi % 2 == 0:
            pad(tr, t0, [n + 12 for n in tri[root]], bar * 2, 0.6 + 0.6 * lv)
        for k in range(8):
            if lv > 0.3:
                ostinato(tr, t0 + k * beat / 2, root + (12 if k % 4 == 3 else 0), 0.22, lv, 0.4)
        if lv > 0.5:
            for b in (0, 1.5, 2, 3.5):
                taiko(tr, t0 + b * beat, 55 if b in (0, 2) else 72, lv * (1.0 if b in (0, 2) else 0.7), 0.5)
        if lv > 0.65 and bi % 4 == 3:
            for s16 in range(8):
                tom(tr, t0 + 3 * beat + s16 * beat / 8, 150 - s16 * 8, 0.5 + s16 * 0.07, 0.3 + s16 * 0.05)
        if lv > 0.75 and bi % 2 == 0:
            braam(tr, t0, [root, root + 7], bar * 1.6, lv * 0.9)
    for tt in (24.0, 45.0):
        crash(tr, tt, 1.0, swell=2.5)
        impact(tr, tt)
    for tt in np.arange(1.0, 60, 4 * bar):
        ping(tr, tt, 1318.5, 0.7)
    for tt, d in ((4.2, 1.1), (11.5, 0.8), (36.2, 1.3), (40.8, 0.7), (57.0, 0.9)):
        radio(tr, tt, d, 1.0, tr.rng.uniform(0.2, 0.8))
    return tr.finish(keys=I, wet=0.42)


def v2_horyzont() -> np.ndarray:
    """60 BPM, ля-мінор: трейлерні «браам»-акорди, рідкі потужні удари, сонарний розгортка."""
    tr = Track(202)
    bar = 4.0
    I = [(0, 0.25), (6, 0.3), (20, 1.0), (28, 0.9), (34, 0.4), (40, 0.45), (48, 1.0), (55, 0.8), (60, 0.25)]
    prog = [(45, [57, 60, 64]), (41, [53, 57, 60]), (36, [55, 60, 64]), (43, [55, 59, 62]),
            (45, [57, 60, 64]), (41, [53, 57, 60]), (36, [55, 60, 64]), (40, [52, 55, 59]),
            (41, [53, 57, 60]), (43, [55, 59, 62]), (45, [57, 60, 64]), (41, [53, 57, 60]),
            (36, [55, 60, 64]), (43, [55, 59, 62]), (45, [57, 60, 64])]
    for bi, (root, notes) in enumerate(prog):
        t0 = bi * bar
        lv = curve(I, t0 + 1)
        pad(tr, t0, notes, bar, 0.8 + 0.5 * lv)
        if lv > 0.6:
            braam(tr, t0, [root - 12, root - 5, root], bar * 0.85, lv * 1.1, attack=0.18)
        if lv > 0.55:
            taiko(tr, t0, 46, lv * 1.1)
            taiko(tr, t0 + 2, 52, lv * 0.8)
        if lv > 0.8:
            taiko(tr, t0 + 3.5, 64, 0.6)
            taiko(tr, t0 + 3.75, 64, 0.7)
    for tt in (20.0, 48.0):
        crash(tr, tt, 1.2, swell=4.0)
        impact(tr, tt, 1.2)
    for i, tt in enumerate(np.arange(2.0, 60, 8.0)):
        for j in range(4):
            ping(tr, tt + j * 0.35, 880 * 2 ** (j * 4 / 12), 0.5, 0.3 + 0.13 * j)
    for tt, d in ((10.5, 1.2), (37.0, 1.5), (58.0, 0.8)):
        radio(tr, tt, d, 0.9, tr.rng.uniform(0.25, 0.75))
    return tr.finish(keys=I, wet=0.6, rev_len=2.4, bright=20)


def v3_kolona() -> np.ndarray:
    """84 BPM, мі-мінор: маршовий малий барабан, остинато 16-ми, морзянка й ефір."""
    tr = Track(303)
    beat = 60 / 84
    bar = 4 * beat
    I = [(0, 0.3), (8, 0.35), (20, 1.0), (28, 0.85), (33, 0.3), (40, 0.4), (51, 1.0), (57, 0.7), (60, 0.3)]
    prog = [40, 40, 36, 38, 40, 40, 36, 35, 40, 40, 36, 38, 43, 38, 40, 40, 36, 38, 35, 35, 40]
    tri = {40: [52, 55, 59], 36: [48, 52, 55], 38: [50, 54, 57], 35: [47, 50, 54], 43: [55, 59, 62]}
    cadence = [1, 0, .5, 0, 1, 0, .5, .5, 1, 0, .5, 0, 1, .5, .7, .9]         # 16-ті такту
    for bi, root in enumerate(prog):
        t0 = bi * bar
        lv = curve(I, t0 + bar / 2)
        pad(tr, t0, [n + 12 for n in tri[root]], bar, 0.5 + 0.5 * lv)
        for s in range(16):
            ostinato(tr, t0 + s * beat / 4, root + (7 if s % 8 == 6 else 0), 0.12, 0.35 + 0.55 * lv, 0.45)
        kick(tr, t0, 0.2 + 0.8 * lv ** 2)
        kick(tr, t0 + 2 * beat, 0.15 + 0.75 * lv ** 2)
        if lv > 0.45:
            for s, v in enumerate(cadence):
                if v > 0:
                    snare(tr, t0 + s * beat / 4, v * lv, 0.55)
        if lv > 0.55:
            tom(tr, t0 + 1 * beat, 95, lv * 0.8, 0.35)
            tom(tr, t0 + 3 * beat, 80, lv * 0.8, 0.65)
    for tt in (20.0, 51.0):                                                   # дріб-крещендо в удар
        for k in range(int(2 * bar / (beat / 8))):
            snare(tr, tt - 2 * bar + k * beat / 8, 0.15 + 0.85 * k / (2 * bar / (beat / 8)), 0.5)
        crash(tr, tt, 1.0)
        impact(tr, tt, 0.9)
    for tt, code in ((2.0, "-.- --- .-.. --- -. .-"), (35.0, "..- .- ...-"), (43.5, "-.-. .... . -.-")):
        morse(tr, tt, code, pan=0.72)
    for tt, d in ((6.0, 0.9), (13.7, 1.2), (30.5, 0.8), (38.2, 1.4), (58.5, 0.7)):
        radio(tr, tt, d, 1.1, tr.rng.uniform(0.2, 0.8))
    for tt in np.arange(0.5, 60, 2 * bar):
        ping(tr, tt, 1568.0, 0.45, 0.4)
    return tr.finish(keys=I, wet=0.35, rev_len=1.2)


def v4_radiotin() -> np.ndarray:
    """72 BPM, до-мінор: цокання, нескінченно висхідний тон Шепарда, глітчі ефіру, важкі удари."""
    tr = Track(404)
    beat = 60 / 72
    bar = 4 * beat
    I = [(0, 0.25), (10, 0.3), (22, 0.95), (30, 0.9), (35, 0.3), (43, 0.5), (52, 1.0), (56, 0.8), (60, 0.25)]
    # Шепард: 8 октав синусів, за 60 с рівно одна октава підйому → безшовна петля
    t = T(LOOP_S)
    shep = np.zeros_like(t)
    phs = [phase(32.7 * 2 ** (o + t / LOOP_S)) for o in range(8)]
    for o in range(8):
        pos = o + t / LOOP_S
        # у кінці петлі голос o стає голосом o+1 на початку: доводимо фазу, щоб шов був без клацання
        target = phs[o + 1][0] if o < 7 else phs[0][0]
        err = (target + 2 * np.pi * 32.7 * 2 ** (pos[-1]) / SR - phs[o][-1] + np.pi) % (2 * np.pi) - np.pi
        shep += np.sin(phs[o] + err * t / LOOP_S) * np.exp(-((pos - 4.0) ** 2) / 3.2)
    lvl = np.array([curve(I, x) for x in np.linspace(0, LOOP_S, 600)])
    shep *= np.interp(t, np.linspace(0, LOOP_S, 600), 0.35 + 0.65 * lvl)
    tr.add(0.0, shep, 0.5, 0.05)
    prog = [(36, [48, 51, 55]), (32, [44, 48, 51]), (29, [41, 44, 48]), (31, [43, 47, 50])]
    for bi in range(18):
        t0 = bi * bar
        root, notes = prog[bi % 4]
        lv = curve(I, t0 + bar / 2)
        pad(tr, t0, [n + 12 for n in notes], bar, 0.5 + 0.4 * lv)
        for e in range(8):
            tick(tr, t0 + e * beat / 2, 0.6 + (0.4 if e % 2 == 0 else 0), 0.35 if e % 2 else 0.65)
        kick(tr, t0, 0.7)
        kick(tr, t0 + beat * 0.75, 0.45)
        if lv > 0.55:
            taiko(tr, t0 + 2 * beat, 50, lv)
            braam(tr, t0, [root - 12, root], bar * 0.7, lv * 0.9, attack=0.5, dark=True)
        if lv > 0.8:
            for s in range(4):
                tom(tr, t0 + 3 * beat + s * beat / 4, 110 - s * 10, 0.7, 0.3 + 0.13 * s)
    for tt in (22.0, 52.0):
        crash(tr, tt, 0.8, swell=3.0)
        impact(tr, tt, 1.3)
    for _ in range(14):
        glitch(tr, tr.rng.uniform(0, 59), tr.rng.uniform(0.15, 0.5), 1.0, tr.rng.uniform(0.1, 0.9))
    for tt, d in ((5.0, 1.4), (17.5, 0.9), (38.0, 1.6), (47.0, 1.0)):
        radio(tr, tt, d, 1.0, tr.rng.uniform(0.2, 0.8))
    for tt in np.arange(3.0, 60, 3 * bar):
        ping(tr, tt, 987.8, 0.6, 0.55)
    return tr.finish(keys=I, wet=0.5, rev_len=2.0, bright=18)


def v5_svitanok() -> np.ndarray:
    """80 BPM, ре-мажор: героїчна тема «валторни» над барабанами, світлий підйом."""
    tr = Track(505)
    beat = 60 / 80
    bar = 4 * beat
    I = [(0, 0.25), (9, 0.35), (24, 1.0), (30, 0.9), (36, 0.35), (42, 0.5), (51, 1.0), (57, 0.75), (60, 0.25)]
    prog = [(38, [50, 54, 57]), (35, [47, 50, 54]), (43, [55, 59, 62]), (45, [57, 61, 64])]
    for bi in range(20):
        t0 = bi * bar
        root, notes = prog[bi % 4]
        lv = curve(I, t0 + bar / 2)
        pad(tr, t0, [n + 12 for n in notes], bar, 0.7 + 0.5 * lv)
        for e in range(8):
            ostinato(tr, t0 + e * beat / 2, notes[e % 3] + 12, 0.25, 0.25 + 0.4 * lv, 0.3 + 0.4 * (e % 2))
        if lv > 0.5:
            taiko(tr, t0, 60, lv)
            taiko(tr, t0 + 2.5 * beat, 70, lv * 0.7)
            snare(tr, t0 + beat, lv * 0.6)
            snare(tr, t0 + 3 * beat, lv * 0.7)
        if lv > 0.7:
            braam(tr, t0, [root - 12, root, root + 7], bar * 0.9, lv * 0.7, attack=0.35)
    # тема: (такт, долі, нота, тривалість у долях), звучить у піках
    theme = [(0, 0, 69, 1.5), (0, 1.5, 74, 0.5), (0, 2, 73, 1), (0, 3, 71, 1), (1, 0, 69, 3), (1, 3, 66, 1),
             (2, 0, 67, 1.5), (2, 1.5, 71, 0.5), (2, 2, 74, 2), (3, 0, 73, 2), (3, 2, 76, 2)]
    for start in (4, 12):
        for b, bt, m, d in theme:
            t0 = (start + b) * bar + bt * beat
            if curve(I, t0) > 0.6:
                horn(tr, t0, m, d * beat * 0.95, 1.0, 0.45)
                horn(tr, t0, m - 12, d * beat * 0.95, 0.5, 0.6)
    for tt in (24.0, 51.0):
        crash(tr, tt, 1.0, swell=3.0)
        impact(tr, tt, 0.9)
    for tt in np.arange(2.0, 60, 4 * bar):
        ping(tr, tt, 1760.0, 0.5, 0.6)
    for tt, d in ((7.0, 1.0), (38.5, 1.2), (44.0, 0.8)):
        radio(tr, tt, d, 0.8, tr.rng.uniform(0.25, 0.75))
    return tr.finish(keys=I, wet=0.5, rev_len=1.9, bright=14)


VARIANTS = [("1_pozyvnyi", v1_pozyvnyi), ("2_horyzont", v2_horyzont), ("3_kolona", v3_kolona),
            ("4_radiotin", v4_radiotin), ("5_svitanok", v5_svitanok)]


def write_wav(path: Path, x: np.ndarray) -> None:
    pcm = (np.clip(x, -1, 1).T * 32767).astype("<i2")
    with wave.open(str(path), "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())


if __name__ == "__main__":
    out_dir = Path(sys.argv[1])
    out_dir.mkdir(parents=True, exist_ok=True)
    only = int(sys.argv[2]) if len(sys.argv) > 2 else 0
    for i, (name, fn) in enumerate(VARIANTS, 1):
        if only and i != only:
            continue
        x = fn()
        write_wav(out_dir / f"{name}.wav", x)
        d = np.abs(np.diff(x, axis=1)).max()
        print(f"{name}: пік {np.max(np.abs(x)):.2f}, RMS {20 * np.log10(np.sqrt(np.mean(x ** 2))):.1f} dBFS, "
              f"шов петлі {np.abs(x[:, 0] - x[:, -1]).max():.4f}, макс. крок {d:.3f}")
